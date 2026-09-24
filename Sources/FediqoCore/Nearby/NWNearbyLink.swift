import CryptoKit
import Foundation
import Network
import Synchronization

/// The real link (#253): Bonjour `_fediqo._tcp` with peer-to-peer on, and TLS 1.2 under a
/// pre-shared key — Apple's own documented pattern for two devices nearby, and nothing else.
/// Thin on purpose: what it does is find, advertise and join; every decision is `NearbyMove`'s,
/// and every frame is `NearbyFrame`'s. Not exercised on a runner, which has no radio; the
/// parameters it builds are (`parameters(psk:sessionID:)`).
///
/// **What a refusal reads as.** A device not allowed to look nearby — the local-network
/// permission refused — has its browser or listener fail with a policy error, and that is
/// `NearbyRefusal.notAllowed`: said as that, never as "nobody nearby". A handshake that fails
/// on the joining side is `.wrongCode`; on the holding side it is `.failedHandshake`, so the
/// code is rolled.
public final class NWNearbyLink: NearbyLink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mini-poc.fediqo.nearby")
    private let endpoints = Mutex<[String: NWEndpoint]>([:])

    public init() {}

    /// TLS 1.2 or later, under `psk` named by the session id, and only the PSK ciphersuite —
    /// so no certificate is ever asked for or trusted — over TCP, with peer-to-peer on.
    public static func parameters(psk: SymmetricKey, sessionID: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = NearbyCode.pskIdentity(sessionID: sessionID).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    public func advertise(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NearbyArrival, any Error>.makeStream()
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.parameters(psk: psk, sessionID: sessionID))
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        var txt = NWTXTRecord()
        txt["id"] = sessionID
        listener.service = NWListener.Service(name: name, type: NearbyCode.service, txtRecord: txt)
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                continuation.finish(throwing: Self.refusal(error))
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            let peer = NWPeerConnection(connection, peerName: nil, queue: queue)
            peer.open { ready in
                continuation.yield(ready ? .joined(peer) : .failedHandshake)
            }
        }
        continuation.onTermination = { _ in listener.cancel() }
        listener.start(queue: queue)
        return stream
    }

    public func browse() -> AsyncThrowingStream<[NearbyPeer], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[NearbyPeer], any Error>.makeStream()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyCode.service, domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                continuation.finish(throwing: Self.refusal(error))
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var peers: [NearbyPeer] = []
            var found: [String: NWEndpoint] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, let id = txt["id"], !id.isEmpty
                else { continue }
                let key = "\(result.endpoint)"
                found[key] = result.endpoint
                peers.append(NearbyPeer(id: key, name: name, sessionID: id))
            }
            self.endpoints.withLock { $0 = found }
            continuation.yield(peers.sorted { $0.name < $1.name })
        }
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: queue)
        return stream
    }

    public func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        guard let endpoint = endpoints.withLock({ $0[peer.id] }) else { throw NearbyDropped() }
        let connection = NWConnection(to: endpoint, using: Self.parameters(psk: psk, sessionID: peer.sessionID))
        let wrapped = NWPeerConnection(connection, peerName: peer.name, queue: queue)
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            wrapped.open { continuation.resume(returning: $0) }
        }
        guard ready else {
            // A handshake that fails against a device that is there is the code; a device that
            // cannot be reached at all is a drop, to be tried again.
            throw wrapped.failedHandshake ? NearbyRefusal.wrongCode : NearbyDropped()
        }
        return wrapped
    }

    /// The local-network permission refused, as the system reports it; anything else as itself.
    static func refusal(_ error: NWError) -> any Error {
        switch error {
        case .dns(let code) where code == kDNSServiceErr_PolicyDenied || code == kDNSServiceErr_NoAuth:
            return NearbyRefusal.notAllowed
        case .posix(let code) where code == .EPERM || code == .EACCES:
            return NearbyRefusal.notAllowed
        default:
            return NearbyRefusal.other(error.localizedDescription)
        }
    }
}

/// One `NWConnection`, framed: `u32` length, then a `NearbyFrame` as it encodes.
final class NWPeerConnection: NearbyPeerConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    let peerName: String?
    let frames: AsyncThrowingStream<NearbyFrame, any Error>
    private let incoming: AsyncThrowingStream<NearbyFrame, any Error>.Continuation
    private struct Opening: Sendable {
        var opened: (@Sendable (Bool) -> Void)?
        var failedHandshake = false
    }

    private let state = Mutex(Opening())

    init(_ connection: NWConnection, peerName: String?, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.peerName = peerName
        (frames, incoming) = AsyncThrowingStream<NearbyFrame, any Error>.makeStream()
    }

    /// Whether the handshake, rather than the reach, is what failed.
    var failedHandshake: Bool { state.withLock { $0.failedHandshake } }

    /// Starts the connection; `done` is told once whether it came up.
    func open(_ done: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.opened = done }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.take(handshakeFailed: false)?(true)
                self.receive()
            case .failed(let error):
                let handshake: Bool
                if case .tls = error { handshake = true } else { handshake = false }
                self.take(handshakeFailed: handshake)?(false)
                self.incoming.finish(throwing: NearbyDropped())
            case .cancelled:
                self.take(handshakeFailed: false)?(false)
                self.incoming.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// The opening's callback, once, and whether the handshake is what failed.
    private func take(handshakeFailed: Bool) -> (@Sendable (Bool) -> Void)? {
        state.withLock { held in
            if handshakeFailed { held.failedHandshake = true }
            defer { held.opened = nil }
            return held.opened
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, error in
            guard let self else { return }
            guard let head, head.count == 4, error == nil else {
                self.incoming.finish(throwing: NearbyDropped())
                return
            }
            let length = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard length >= 1, length <= NearbyFrame.mostFrameBytes else {
                self.incoming.finish(throwing: NearbyRefusal.malformed)
                return
            }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self else { return }
                guard let body, body.count == length, error == nil else {
                    self.incoming.finish(throwing: NearbyDropped())
                    return
                }
                do {
                    self.incoming.yield(try NearbyFrame.decode(body))
                    self.receive()
                } catch {
                    self.incoming.finish(throwing: error)
                }
            }
        }
    }

    func send(_ frame: NearbyFrame) async throws {
        let body = try frame.encode()
        var data = Data()
        data.appendLE(UInt32(body.count))
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: NearbyDropped()) } else { continuation.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
