import Foundation
import Synchronization

/// One listen's hand-over rule (#253), the same for every link: who closes a peer that joined.
///
/// **A peer is the listen's until it is handed over, and the taker's after.** While it is
/// opening, the listen owns it: a listen put away — its stream ended — closes it. Once it is
/// ready it is yielded as `.joined` and released in the same step, so the listen's end never
/// reaches it: the taker, which may well end the listen on that very arrival, closes it when
/// it is done. A peer that failed to open is released too; it closed itself. A peer yielded to
/// a stream already ended has no taker, and is closed here.
///
/// No radio in it: `NWNearbyLink` and `PipeNearbyLink` both keep their listens through this,
/// so the rule a test exercises over the pipe is the rule the device runs.
final class NearbyListen<Peer: NearbyPeerConnection & AnyObject>: Sendable {
    private struct Held: Sendable {
        var open: [ObjectIdentifier: Peer] = [:]
        var ended = false
    }

    private let held = Mutex(Held())
    private let continuation: AsyncThrowingStream<NearbyArrival, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<NearbyArrival, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// A peer has begun to open, owned by the listen from now until it is handed over. False —
    /// and the peer closed — where the listen has already ended.
    @discardableResult
    func opening(_ peer: Peer) -> Bool {
        let taken = held.withLock { held -> Bool in
            guard !held.ended else { return false }
            held.open[ObjectIdentifier(peer)] = peer
            return true
        }
        if !taken { peer.close() }
        return taken
    }

    /// The peer is ready: released and handed over as `.joined`, the taker's to close from now.
    /// A listen that ended under it — before the release, or before the yield landed — closes it.
    func joined(_ peer: Peer) {
        let mine = held.withLock { $0.open.removeValue(forKey: ObjectIdentifier(peer)) != nil }
        guard mine else { return }
        if case .terminated = continuation.yield(.joined(peer)) { peer.close() }
    }

    /// The peer did not open: released, and a handshake that failed is said as a guess. `peer`
    /// is nothing where no peer was ever made — a wrong key refused before any connection.
    func failed(_ peer: Peer?, handshake: Bool) {
        if let peer { held.withLock { _ = $0.open.removeValue(forKey: ObjectIdentifier(peer)) } }
        if handshake { continuation.yield(.failedHandshake) }
    }

    /// The listen is over: every peer not yet handed over is closed, and one that begins to
    /// open after this is closed as it does.
    func end() {
        let peers = held.withLock { held in
            held.ended = true
            defer { held.open = [:] }
            return Array(held.open.values)
        }
        for peer in peers { peer.close() }
    }

    /// How many peers the listen owns right now.
    var opened: Int { held.withLock { $0.open.count } }
}
