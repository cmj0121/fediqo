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
public final class NWNearbyLink: SyncLink, @unchecked Sendable {
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
    /// What each kind of browse last found, by the id it lists: holds apart from sync listeners.
    private let endpoints = Mutex<[Kind: [String: NWEndpoint]]>([:])

    /// The two kinds of listener on the one service: a hold, which a code joins, and a sync
    /// listener, which a pair's tag joins.
    private enum Kind {
        case hold, sync
    }

    /// One listener, as it advertises and is joined: a hold under its session (`pairing`, TXT
    /// `p=1`, for paired devices rather than a Move), or a sync listener under its tag.
    private enum Listing {
        case hold(sessionID: String, pairing: Bool = false)
        case sync(tag: String)

        var kind: Kind {
            switch self {
            case .hold: .hold
            case .sync: .sync
            }
        }

        var txt: [String: String] {
            switch self {
            case .hold(let sessionID, let pairing): pairing ? ["id": sessionID, SyncDiscovery.pairingKey: "1"] : ["id": sessionID]
            case .sync(let tag): [SyncDiscovery.tagKey: tag]
            }
        }

        func parameters(psk: SymmetricKey) -> NWParameters {
            switch self {
            case .hold(let sessionID, _): NWNearbyLink.parameters(psk: psk, sessionID: sessionID)
            case .sync(let tag): NWNearbyLink.parameters(psk: psk, identity: SyncDiscovery.pskIdentity(tag: tag))
            }
        }
    }

    public init() {}

    /// TLS 1.2 exactly, under `psk` named by the session id, asking for the ECDHE-PSK suite —
    /// so no certificate is ever asked for or trusted — over TCP, with peer-to-peer on.
    public static func parameters(psk: SymmetricKey, sessionID: String) -> NWParameters {
        parameters(psk: psk, identity: NearbyCode.pskIdentity(sessionID: sessionID))
    }

    /// The same, under any PSK identity: a sync listener's is `SyncDiscovery.pskIdentity(tag:)`.
    public static func parameters(psk: SymmetricKey, identity: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = identity.withUnsafeBytes { DispatchData(bytes: $0) }
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

    public func advertise(name: String, sessionID: String, psk: SymmetricKey, pairing: Bool) -> AsyncThrowingStream<NearbyArrival, any Error> {
        listen(name: name, as: .hold(sessionID: sessionID, pairing: pairing), psk: psk)
    }

    public func advertise(name: String, tag: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        listen(name: name, as: .sync(tag: tag), psk: psk)
    }

    private func listen(name: String, as listing: Listing, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NearbyArrival, any Error>.makeStream()
        let listener: NWListener
        do {
            listener = try NWListener(using: listing.parameters(psk: psk))
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        var txt = NWTXTRecord()
        for (key, value) in listing.txt { txt[key] = value }
        listener.service = NWListener.Service(name: name, type: NearbyCode.service, txtRecord: txt)
        // A connection still opening is the listen's, cancelled with it so a stream put away
        // leaves no socket open; one that is ready is handed over and is its taker's — the
        // hold ends this listen on its one join, and must keep the connection it took.
        let listen = NearbyListen<NWPeerConnection>(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NearbyLog.note(.receiver, "listening")
            case .failed(let error):
                NearbyLog.note(.receiver, "listen failed", Self.kind(error))
                continuation.finish(throwing: Self.refusal(error))
            case .waiting(let error):
                NearbyLog.note(.receiver, "listen waiting", Self.kind(error))
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
            NearbyLog.note(.receiver, "connection arriving")
            guard listen.opening(peer) else { return }
            peer.open { ready in
                if ready {
                    listen.joined(peer)
                } else {
                    // Only a handshake that failed is a guess; a probe that never got that
                    // far, or the framework's own racing attempt, rolls nothing.
                    listen.failed(peer, handshake: peer.failedHandshake)
                }
            }
        }
        continuation.onTermination = { _ in
            listener.cancel()
            listen.end()
        }
        listener.start(queue: queue)
        return stream
    }

    public func browse(pairing: Bool) -> AsyncThrowingStream<[NearbyPeer], any Error> {
        look(.hold, failed: "browse failed") { key, name, txt in
            // A sync listener (TXT `t`) is never a hold. Every hold is kept to be joined; only
            // the kind asked for is listed.
            guard let id = txt["id"], !id.isEmpty, txt[SyncDiscovery.tagKey] == nil else { return nil }
            return (NearbyPeer(id: key, name: name, sessionID: id), (txt[SyncDiscovery.pairingKey] == "1") == pairing)
        }
    }

    public func browseTags() -> AsyncThrowingStream<[SyncPeer], any Error> {
        look(.sync, failed: "sync browse failed") { key, name, txt in
            guard let tag = txt[SyncDiscovery.tagKey], !tag.isEmpty else { return nil }
            return (SyncPeer(id: key, name: name, tag: tag), true)
        }
    }

    /// Every listener of `kind` on the service, as the list changes, kept to be joined by the id
    /// it is listed under; `read` makes one of a result, or nil where it is not of this kind,
    /// and says whether it is listed. In name order.
    private func look<Peer: Sendable>(
        _ kind: Kind, failed: StaticString,
        _ read: @escaping @Sendable (_ key: String, _ name: String, _ txt: NWTXTRecord) -> (peer: Peer, listed: Bool)?
    ) -> AsyncThrowingStream<[Peer], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[Peer], any Error>.makeStream()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyCode.service, domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                NearbyLog.note(.sender, failed, Self.kind(error))
                continuation.finish(throwing: Self.refusal(error))
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var listed: [(name: String, peer: Peer)] = []
            var found: [String: NWEndpoint] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata else { continue }
                let key = "\(result.endpoint)"
                guard let read = read(key, name, txt) else { continue }
                found[key] = result.endpoint
                if read.listed { listed.append((name, read.peer)) }
            }
            self.endpoints.withLock { $0[kind] = found }
            continuation.yield(listed.sorted { $0.name < $1.name }.map(\.peer))
        }
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: queue)
        return stream
    }

    public func connect(to peer: SyncPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        try await connect(peer.id, as: .sync(tag: peer.tag), name: peer.name, psk: psk)
    }

    public func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        try await connect(peer.id, as: .hold(sessionID: peer.sessionID), name: peer.name, psk: psk)
    }

    /// Joins the listener a browse of its kind listed as `id`.
    private func connect(_ id: String, as listing: Listing, name: String, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        guard let endpoint = endpoints.withLock({ $0[listing.kind]?[id] }) else { throw NearbyDropped() }
        return try await join(endpoint, parameters: listing.parameters(psk: psk), name: name)
    }

    private func join(_ endpoint: NWEndpoint, parameters: NWParameters, name: String) async throws -> any NearbyPeerConnection {
        let connection = NWConnection(to: endpoint, using: parameters)
        let wrapped = NWPeerConnection(connection, peerName: name, queue: queue)
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
            let wrong = wrapped.failedHandshake || wrapped.reset
            NearbyLog.note(.sender, wrong ? "join refused as the code" : "join not reached")
            throw wrong ? NearbyRefusal.wrongCode : NearbyDropped()
        }
        return wrapped
    }

    /// A transport error's kind — its domain and code, `posix 54` (ECONNRESET), `tls -9806` — and
    /// never its description, which can name an address.
    static func kind(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix \(code.rawValue)"
        case .dns(let code): return "dns \(code)"
        case .tls(let status): return "tls \(status)"
        default: return "other"
        }
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

    /// A connection nobody closed — a join handed to a listen that ended before it was read —
    /// is cancelled as it goes, so no socket outlives what held it.
    deinit {
        connection.cancel()
    }

    /// The side this end is on: the joining side knows its peer's name.
    private var side: NearbyLog.Side { peerName == nil ? .receiver : .sender }

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
                    NearbyLog.note(self.side, "tls suite refused")
                    self.take(handshakeFailed: true)?(false)
                    self.connection.cancel()
                    return
                }
                self.state.withLock { $0.ready = true }
                NearbyLog.note(self.side, "tls ready")
                self.take(handshakeFailed: false)?(true)
            case .waiting(let error) where !NWNearbyLink.isPolicy(error):
                // Not there yet: the attempt stands until the timeout ends it.
                break
            case .failed(let error), .waiting(let error):
                // A handshake refused reads as a TLS error, or — on the joining side, where the
                // holder closed on the proof — as the connection reset under it; a device out
                // of reach reads as anything else. On the holding side a reset is a bare probe.
                NearbyLog.note(self.side, "connection failed", NWNearbyLink.kind(error))
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
                NearbyLog.note(self.side, "join timed out")
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
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [side] data, _, complete, error in
                guard let data, data.count == length, error == nil else {
                    if let error {
                        NearbyLog.note(side, "dropped on read", NWNearbyLink.kind(error))
                    } else {
                        NearbyLog.note(side, complete ? "dropped on read: peer closed" : "dropped on read: short")
                    }
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
            connection.send(content: data, completion: .contentProcessed { [side] error in
                guard let error else {
                    continuation.resume()
                    return
                }
                NearbyLog.note(side, "dropped on write", NWNearbyLink.kind(error))
                continuation.resume(throwing: NearbyDropped())
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
