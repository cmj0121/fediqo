import CryptoKit
import Foundation
import Network
import Synchronization

/// The real link (#253): Bonjour `_fediqo._tcp` with peer-to-peer on, and TLS 1.2 under a
/// pre-shared key with an ephemeral key exchange — Apple's own documented pattern for two
/// devices nearby, and nothing else. Thin on purpose: what it does is find, advertise and
/// join; every decision is `NearbyMove`'s, every word is `NearbyChannel`'s, and every frame is
/// `NearbyFrame`'s. Not exercised on a runner, which has no radio; the parameters it builds
/// and the refusals it maps are (`parameters(psk:sessionID:)`, `refusal(_:)`, `suiteHolds`).
///
/// **The suite is checked, not assumed.** The options ask for
/// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` on TLS 1.2 exactly; once a connection is
/// ready, the suite it actually negotiated is read back, and any other — a default the
/// framework still offered, a certificate path — is refused as a failed handshake rather than
/// used. A device that cannot negotiate it fails closed.
///
/// **What a refusal reads as.** A device not allowed to look nearby — the local-network
/// permission refused — has its browser or listener fail with a policy error, and that is
/// `NearbyRefusal.notAllowed`: said as that, never as "nobody nearby". A handshake that fails
/// on the joining side is `.wrongCode`; on the holding side it is `.failedHandshake`, so the
/// code is rolled — and only a handshake: a probe that never got that far rolls nothing.
public final class NWNearbyLink: NearbyLink, @unchecked Sendable {
    /// How long a join may take before it is a device out of reach.
    public static let connectTimeout: Duration = .seconds(20)
    /// The suites this link speaks, in order of preference: ECDHE-PSK with ChaCha20-Poly1305,
    /// and plain PSK with AES-128-GCM for a device that cannot negotiate the first. Forward
    /// secrecy is the in-band channel's job either way — every frame is sealed under a key
    /// agreed fresh on each join — so the transport's part is to keep a stranger off the
    /// connection at all. **To be confirmed on two devices**: which of the two they settle on.
    public static let suite = tls_ciphersuite_t(rawValue: 0xCCAC)!
    public static let fallbackSuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    private let queue = DispatchQueue(label: "dev.mini-poc.fediqo.nearby")
    private let endpoints = Mutex<[String: NWEndpoint]>([:])

    public init() {}

    /// TLS 1.2 exactly, under `psk` named by the session id, asking for the ECDHE-PSK suite —
    /// so no certificate is ever asked for or trusted — over TCP, with peer-to-peer on.
    public static func parameters(psk: SymmetricKey, sessionID: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = NearbyCode.pskIdentity(sessionID: sessionID).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, fallbackSuite)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Whether a negotiated suite is one of the two asked for. Anything else — a certificate
    /// suite, a default the framework still offered — is refused.
    public static func suiteHolds(_ negotiated: tls_ciphersuite_t?) -> Bool {
        negotiated == suite || negotiated == fallbackSuite
    }

    /// Whether an error is the local-network permission refused.
    static func isPolicy(_ error: NWError) -> Bool {
        (refusal(error) as? NearbyRefusal) == .notAllowed
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
        // Every connection handed over and not yet closed by its taker: cancelled with the
        // listen, so a stream put away leaves no socket open.
        let open = Mutex<[ObjectIdentifier: NWPeerConnection]>([:])
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                continuation.finish(throwing: Self.refusal(error))
            case .waiting(let error):
                // Waiting is a network not there yet, unless it is the permission refused.
                if Self.isPolicy(error) { continuation.finish(throwing: NearbyRefusal.notAllowed) }
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            let peer = NWPeerConnection(connection, peerName: nil, queue: queue)
            open.withLock { $0[ObjectIdentifier(peer)] = peer }
            peer.open { ready in
                if ready {
                    continuation.yield(.joined(peer))
                } else {
                    open.withLock { $0[ObjectIdentifier(peer)] = nil }
                    // Only a handshake that failed is a guess; a probe that never got that
                    // far, or the framework's own racing attempt, rolls nothing.
                    if peer.failedHandshake { continuation.yield(.failedHandshake) }
                }
            }
        }
        continuation.onTermination = { _ in
            listener.cancel()
            let peers = open.withLock { held in
                defer { held = [:] }
                return Array(held.values)
            }
            for peer in peers { peer.close() }
        }
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
        // A join put away — the person pressed Cancel — cancels the attempt, and one that takes
        // longer than a device in reach would is a device out of reach.
        let ready = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                wrapped.open(timeout: Self.connectTimeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            wrapped.close()
        }
        guard ready else {
            // A handshake that fails against a device that is there is the code; a device that
            // cannot be reached at all is a drop, to be tried again.
            throw wrapped.failedHandshake || wrapped.reset ? NearbyRefusal.wrongCode : NearbyDropped()
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
///
/// **Pulled, not pushed.** A frame is read off the socket only when the consumer asks for the
/// next one, so a disk slower than the radio holds the radio back rather than filling memory.
final class NWPeerConnection: NearbyPeerConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    let peerName: String?

    private struct Opening: Sendable {
        var opened: (@Sendable (Bool) -> Void)?
        var failedHandshake = false
        /// The other side closed the connection under the handshake: on the joining side, the
        /// holder refusing the proof; on the holding side, a bare probe, which is not a guess.
        var reset = false
        var ready = false
    }

    private let state = Mutex(Opening())

    init(_ connection: NWConnection, peerName: String?, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.peerName = peerName
    }

    /// Whether the handshake itself — TLS bytes exchanged and refused — is what failed.
    var failedHandshake: Bool { state.withLock { $0.failedHandshake } }

    /// Whether the other side closed under the handshake.
    var reset: Bool { state.withLock { $0.reset } }

    /// Starts the connection; `done` is told once whether it came up — and it comes up only on
    /// the one suite asked for. `timeout` is how long that may take.
    func open(timeout: Duration? = nil, _ done: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.opened = done }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.suiteHolds() else {
                    self.take(handshakeFailed: true)?(false)
                    self.connection.cancel()
                    return
                }
                self.state.withLock { $0.ready = true }
                self.take(handshakeFailed: false)?(true)
            case .waiting(let error) where !NWNearbyLink.isPolicy(error):
                // Not there yet: the attempt stands until the timeout ends it.
                break
            case .failed(let error), .waiting(let error):
                // A handshake refused reads as a TLS error, or — on the joining side, where the
                // holder closed on the proof — as the connection reset under it; a device out
                // of reach reads as anything else. On the holding side a reset is a bare probe.
                let handshake: Bool
                switch error {
                case .tls: handshake = true
                case .posix(let code):
                    handshake = false
                    if self.peerName != nil, code == .ECONNRESET || code == .EPIPE { self.state.withLock { $0.reset = true } }
                default: handshake = false
                }
                self.take(handshakeFailed: handshake)?(false)
                self.connection.cancel()
            case .cancelled:
                self.take(handshakeFailed: false)?(false)
            default:
                break
            }
        }
        if let timeout {
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout / .nanoseconds(1)))) { [weak self] in
                guard let self, let opened = self.take(handshakeFailed: false) else { return }
                opened(false)
                self.connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    /// Whether the suite the connection negotiated is the one asked for.
    private func suiteHolds() -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return false
        }
        return NWNearbyLink.suiteHolds(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata))
    }

    /// The opening's callback, once, and whether the handshake is what failed.
    private func take(handshakeFailed: Bool) -> (@Sendable (Bool) -> Void)? {
        state.withLock { held in
            if handshakeFailed { held.failedHandshake = true }
            defer { held.opened = nil }
            return held.opened
        }
    }

    /// Every frame, one read per frame asked for.
    var frames: AsyncThrowingStream<NearbyFrame, any Error> {
        AsyncThrowingStream { try await self.readFrame() }
    }

    private func receive(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard let data, data.count == length, error == nil else {
                    continuation.resume(throwing: NearbyDropped())
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func readFrame() async throws -> NearbyFrame {
        let head = try await receive(4)
        let length = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length >= 1, length <= NearbyFrame.mostFrameBytes else { throw NearbyRefusal.malformed }
        return try NearbyFrame.decode(try await receive(length))
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
