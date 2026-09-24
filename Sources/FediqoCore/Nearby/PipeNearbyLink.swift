import CryptoKit
import Foundation
import Synchronization

/// Two ends joined in one process, with no radio: the link a test or a preview hands
/// `NearbyMove`. One `PipeNearbyLink` is a room; every device built on it sees every other
/// device holding in it. Frames cross through their wire encoding, so what the codec refuses is
/// refused here too.
///
/// A wrong key never joins: `connect` throws `NearbyRefusal.wrongCode` and the device holding
/// is told `.failedHandshake`, as the real handshake would. `cut()` drops every joined pair at
/// once, as a walk out of range would, and `deny()` makes the next look nearby refused.
public final class PipeNearbyLink: NearbyLink, @unchecked Sendable {
    private struct Holding {
        let peer: NearbyPeer
        let psk: SymmetricKey
        let arrivals: AsyncThrowingStream<NearbyArrival, any Error>.Continuation
    }

    private struct Room {
        var holding: [String: Holding] = [:]
        var browsers: [Int: AsyncThrowingStream<[NearbyPeer], any Error>.Continuation] = [:]
        var pairs: [PipePair] = []
        var next = 0
        var denied = false
        /// How many joins to refuse as out of reach before the next one lands.
        var unreachable = 0
        /// The next pair drops itself after this many `bytes` frames, as a walk out of range
        /// midway would.
        var cutAfterBytesFrames: Int?
        /// The next pair drops itself as the holding side sends its last word, so the sender
        /// never hears it.
        var cutBeforeLastWord = false
        /// Every frame that crossed any pair, as bytes: what a recording of the wire would hold.
        var transcript: [Data] = []
    }

    private let room = Mutex(Room())

    public init() {}

    /// Every device holding right now, as a browser lists them.
    public var peers: [NearbyPeer] {
        room.withLock { $0.holding.values.map(\.peer).sorted { $0.name < $1.name } }
    }

    /// From now on, looking nearby is refused: what a denied local-network permission does.
    public func deny() {
        room.withLock { $0.denied = true }
    }

    /// The next `count` joins fail as out of reach, and a join after them lands.
    public func unreachable(for count: Int) {
        room.withLock { $0.unreachable = count }
    }

    /// The next pair joined drops itself, without a word, after `frames` frames of the package
    /// have crossed.
    public func cutNext(afterBytesFrames frames: Int) {
        room.withLock { $0.cutAfterBytesFrames = frames }
    }

    /// The next pair joined drops itself as the holding side's last frame is sent, so the
    /// joining side never hears that word.
    public func cutNextBeforeLastWord() {
        room.withLock { $0.cutBeforeLastWord = true }
    }

    /// Every frame that crossed, in order, as it would be recorded off the wire.
    public var transcript: [Data] {
        room.withLock { $0.transcript }
    }

    /// Every joined pair drops at once, without a word.
    public func cut() {
        let pairs = room.withLock { room in
            defer { room.pairs = [] }
            return room.pairs
        }
        for pair in pairs { pair.cut() }
    }

    public func advertise(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NearbyArrival, any Error>.makeStream()
        let peer = NearbyPeer(id: sessionID, name: name, sessionID: sessionID)
        let denied = room.withLock { room in
            guard !room.denied else { return true }
            room.holding[sessionID] = Holding(peer: peer, psk: psk, arrivals: continuation)
            return false
        }
        if denied {
            continuation.finish(throwing: NearbyRefusal.notAllowed)
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.room.withLock { $0.holding[sessionID] = nil }
            self?.tellBrowsers()
        }
        tellBrowsers()
        return stream
    }

    public func browse() -> AsyncThrowingStream<[NearbyPeer], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[NearbyPeer], any Error>.makeStream()
        let (denied, id, peers) = room.withLock { room -> (Bool, Int, [NearbyPeer]) in
            guard !room.denied else { return (true, 0, []) }
            room.next += 1
            room.browsers[room.next] = continuation
            return (false, room.next, room.holding.values.map(\.peer).sorted { $0.name < $1.name })
        }
        if denied {
            continuation.finish(throwing: NearbyRefusal.notAllowed)
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.room.withLock { $0.browsers[id] = nil }
        }
        continuation.yield(peers)
        return stream
    }

    public func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        let (holding, unreachable) = room.withLock { room -> (Holding?, Bool) in
            if room.unreachable > 0 {
                room.unreachable -= 1
                return (nil, true)
            }
            return (room.holding[peer.sessionID], false)
        }
        if unreachable { throw NearbyDropped() }
        guard let holding else { throw NearbyDropped() }
        guard holding.psk == psk else {
            holding.arrivals.yield(.failedHandshake)
            throw NearbyRefusal.wrongCode
        }
        let pair = PipePair(record: { [weak self] data in self?.room.withLock { $0.transcript.append(data) } })
        room.withLock { room in
            room.pairs.append(pair)
            pair.cutAfterBytesFrames = room.cutAfterBytesFrames
            room.cutAfterBytesFrames = nil
            pair.cutBeforeLastWord = room.cutBeforeLastWord
            room.cutBeforeLastWord = false
        }
        let (ours, theirs) = pair.ends(name: peer.name)
        holding.arrivals.yield(.joined(theirs))
        return ours
    }

    private func tellBrowsers() {
        let (browsers, peers) = room.withLock { room in
            (Array(room.browsers.values), room.holding.values.map(\.peer).sorted { $0.name < $1.name })
        }
        for browser in browsers { browser.yield(peers) }
    }
}

/// Two ends of one pipe: what one sends, the other reads, encoded and decoded on the way.
final class PipePair: Sendable {
    private struct Wires {
        var toA: AsyncThrowingStream<NearbyFrame, any Error>.Continuation?
        var toB: AsyncThrowingStream<NearbyFrame, any Error>.Continuation?
        var cut = false
        var bytesFrames = 0
        var cutAfterBytesFrames: Int?
        var cutBeforeLastWord = false
        /// How many frames the holding side has sent past the channel's opening.
        var sealedFromB = 0
    }

    private let wires = Mutex(Wires())
    private let framesA: AsyncThrowingStream<NearbyFrame, any Error>
    private let framesB: AsyncThrowingStream<NearbyFrame, any Error>
    private let record: @Sendable (Data) -> Void

    init(record: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.record = record
        let (a, toA) = AsyncThrowingStream<NearbyFrame, any Error>.makeStream()
        let (b, toB) = AsyncThrowingStream<NearbyFrame, any Error>.makeStream()
        framesA = a
        framesB = b
        wires.withLock {
            $0.toA = toA
            $0.toB = toB
        }
    }

    /// The sender's end and the receiver's end. `name` is what the sender knows the receiver by.
    func ends(name: String) -> (PipeConnection, PipeConnection) {
        (PipeConnection(pair: self, side: .a, frames: framesA, peerName: name),
         PipeConnection(pair: self, side: .b, frames: framesB, peerName: nil))
    }

    enum Side { case a, b }

    /// Set before the first frame: after this many `bytes` frames, the pair drops itself.
    var cutAfterBytesFrames: Int? {
        get { wires.withLock { $0.cutAfterBytesFrames } }
        set { wires.withLock { $0.cutAfterBytesFrames = newValue } }
    }

    /// Set before the first frame: the holding side's last word is cut rather than delivered.
    var cutBeforeLastWord: Bool {
        get { wires.withLock { $0.cutBeforeLastWord } }
        set { wires.withLock { $0.cutBeforeLastWord = newValue } }
    }

    func send(_ frame: NearbyFrame, from side: Side) throws {
        let data = try frame.encode()
        let decoded = try NearbyFrame.decode(data)
        record(data)
        let (to, cutNow) = wires.withLock { wires -> (AsyncThrowingStream<NearbyFrame, any Error>.Continuation?, Bool) in
            guard !wires.cut else { return (nil, false) }
            if case .sealed = decoded {
                // Sealed frames are opaque here; what is counted is their number, and the
                // holding side's last word is the third it sends after `have`: accept, have,
                // done — where nothing dropped before.
                if side == .b {
                    wires.sealedFromB += 1
                    if wires.cutBeforeLastWord, wires.sealedFromB == 3 { return (nil, true) }
                }
                wires.bytesFrames += side == .a ? 1 : 0
                if side == .a, let limit = wires.cutAfterBytesFrames, wires.bytesFrames > limit + 2 { return (nil, true) }
            }
            return (side == .a ? wires.toB : wires.toA, false)
        }
        if cutNow { cut() }
        guard let to else { throw NearbyDropped() }
        to.yield(decoded)
    }

    /// Both ends' streams end, and nothing more goes through.
    func cut() {
        let (toA, toB) = wires.withLock { wires in
            wires.cut = true
            defer { wires.toA = nil; wires.toB = nil }
            return (wires.toA, wires.toB)
        }
        toA?.finish()
        toB?.finish()
    }
}

final class PipeConnection: NearbyPeerConnection, Sendable {
    private let pair: PipePair
    private let side: PipePair.Side
    let frames: AsyncThrowingStream<NearbyFrame, any Error>
    let peerName: String?

    init(pair: PipePair, side: PipePair.Side, frames: AsyncThrowingStream<NearbyFrame, any Error>, peerName: String?) {
        self.pair = pair
        self.side = side
        self.frames = frames
        self.peerName = peerName
    }

    func send(_ frame: NearbyFrame) async throws {
        try pair.send(frame, from: side)
    }

    func close() {
        pair.cut()
    }
}
