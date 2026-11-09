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
///
/// **Sync listeners** (`advertise(name:tag:psk:)`) sit in the same room beside the holds, each
/// under its instance name: `browseTags` lists only them and `browse` never does.
/// `holdJoins()` keeps every join waiting until `releaseJoins()`, so two devices dial at once.
///
/// **A listen hands over as the real one does**, through the same `NearbyListen`: the end that
/// joined is the holder's once it is yielded, and a listen put away closes only an end not yet
/// handed over.
public final class PipeNearbyLink: SyncLink, @unchecked Sendable {
    private enum Kind {
        case hold, sync
    }

    /// Where a listener sits in the room: a hold under its session, a sync listener under its
    /// instance name.
    private enum Listing: Hashable {
        case hold(sessionID: String)
        case sync(name: String)

        var kind: Kind {
            switch self {
            case .hold: .hold
            case .sync: .sync
            }
        }
    }

    /// What a browser lists of a listener.
    private enum Advert: Sendable {
        case hold(NearbyPeer, pairing: Bool)
        case sync(SyncPeer)
    }

    private struct Listed {
        let advert: Advert
        let psk: SymmetricKey
        let listen: NearbyListen<PipeConnection>
    }

    private struct Browser {
        let kind: Kind
        let tell: @Sendable ([Advert]) -> Void
    }

    private struct Room {
        /// Holds and sync listeners side by side, each listed only to a browse of its kind.
        var listed: [Listing: Listed] = [:]
        var browsers: [Int: Browser] = [:]
        /// While set, every join waits here until `releaseJoins()`.
        var gated = false
        var gate: [(to: String, join: CheckedContinuation<Void, Never>)] = []
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

    /// Every device holding right now, pairing or not.
    public var peers: [NearbyPeer] {
        room.withLock { Self.holds($0.listed.values.map(\.advert), pairing: nil) }
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

    /// From now on every join waits, so two devices can be made to dial at once.
    public func holdJoins() {
        room.withLock { $0.gated = true }
    }

    /// How many joins are waiting at the gate.
    public var joinsHeld: Int {
        room.withLock { $0.gate.count }
    }

    /// Every join waiting goes on together, and later joins no longer wait.
    public func releaseJoins() {
        let waiting = room.withLock { room in
            room.gated = false
            defer { room.gate = [] }
            return room.gate
        }
        for held in waiting { held.join.resume() }
    }

    /// The joins waiting to reach the listener or hold named `name` go on; the rest wait still.
    public func releaseJoins(to name: String) {
        let waiting = room.withLock { room in
            defer { room.gate.removeAll { $0.to == name } }
            return room.gate.filter { $0.to == name }
        }
        for held in waiting { held.join.resume() }
    }

    /// Every sync listener right now, as `browseTags` lists them.
    public var listeners: [SyncPeer] {
        room.withLock { Self.listeners($0.listed.values.map(\.advert)) }
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

    public func advertise(name: String, sessionID: String, psk: SymmetricKey, pairing: Bool) -> AsyncThrowingStream<NearbyArrival, any Error> {
        listen(.hold(sessionID: sessionID), .hold(NearbyPeer(id: sessionID, name: name, sessionID: sessionID), pairing: pairing), psk: psk)
    }

    public func browse(pairing: Bool) -> AsyncThrowingStream<[NearbyPeer], any Error> {
        browse(.hold) { Self.holds($0, pairing: pairing) }
    }

    public func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        try await connect(to: .hold(sessionID: peer.sessionID), name: peer.name, psk: psk)
    }

    public func advertise(name: String, tag: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        listen(.sync(name: name), .sync(SyncPeer(id: name, name: name, tag: tag)), psk: psk)
    }

    public func browseTags() -> AsyncThrowingStream<[SyncPeer], any Error> {
        browse(.sync, Self.listeners)
    }

    public func connect(to peer: SyncPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        try await connect(to: .sync(name: peer.name), name: peer.name, psk: psk)
    }

    /// The holds among `adverts`, in name order: the pairing ones or the others, or (nil) all.
    private static func holds(_ adverts: [Advert], pairing: Bool?) -> [NearbyPeer] {
        adverts.compactMap { advert -> NearbyPeer? in
            guard case .hold(let peer, let held) = advert, pairing.map({ $0 == held }) ?? true else { return nil }
            return peer
        }.sorted { $0.name < $1.name }
    }

    /// The sync listeners among `adverts`, in name order.
    private static func listeners(_ adverts: [Advert]) -> [SyncPeer] {
        adverts.compactMap { advert -> SyncPeer? in
            guard case .sync(let peer) = advert else { return nil }
            return peer
        }.sorted { $0.name < $1.name }
    }

    /// One listener in the room, until its stream is put away; a denied look nearby refuses it.
    private func listen(_ listing: Listing, _ advert: Advert, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NearbyArrival, any Error>.makeStream()
        let listen = NearbyListen<PipeConnection>(continuation)
        let denied = room.withLock { room in
            guard !room.denied else { return true }
            room.listed[listing] = Listed(advert: advert, psk: psk, listen: listen)
            return false
        }
        if denied {
            continuation.finish(throwing: NearbyRefusal.notAllowed)
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.room.withLock { room in
                if room.listed[listing]?.listen === listen { room.listed[listing] = nil }
            }
            listen.end()
            self?.tell(listing.kind)
        }
        tell(listing.kind)
        return stream
    }

    /// The listeners of `kind`, as `list` lists them, now and at every change of that kind.
    private func browse<Peer: Sendable>(
        _ kind: Kind, _ list: @escaping @Sendable ([Advert]) -> [Peer]
    ) -> AsyncThrowingStream<[Peer], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[Peer], any Error>.makeStream()
        let tell: @Sendable ([Advert]) -> Void = { continuation.yield(list($0)) }
        let (denied, id, adverts) = room.withLock { room -> (Bool, Int, [Advert]) in
            guard !room.denied else { return (true, 0, []) }
            room.next += 1
            room.browsers[room.next] = Browser(kind: kind, tell: tell)
            return (false, room.next, room.listed.values.map(\.advert))
        }
        if denied {
            continuation.finish(throwing: NearbyRefusal.notAllowed)
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.room.withLock { $0.browsers[id] = nil }
        }
        tell(adverts)
        return stream
    }

    private func connect(to listing: Listing, name: String, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        await passGate(to: name)
        let (listed, unreachable) = room.withLock { room -> (Listed?, Bool) in
            if room.unreachable > 0 {
                room.unreachable -= 1
                return (nil, true)
            }
            return (room.listed[listing], false)
        }
        if unreachable { throw NearbyDropped() }
        guard let listed else { throw NearbyDropped() }
        return try join(listed.listen, under: listed.psk, with: psk, name: name)
    }

    private func passGate(to name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = room.withLock { room in
                guard room.gated else { return false }
                room.gate.append((name, continuation))
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    /// One join into `listen`, held under `held`: refused as the real handshake would where
    /// `psk` is not it.
    private func join(_ listen: NearbyListen<PipeConnection>, under held: SymmetricKey, with psk: SymmetricKey, name: String) throws -> any NearbyPeerConnection {
        guard held == psk else {
            listen.failed(nil, handshake: true)
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
        let (ours, theirs) = pair.ends(name: name)
        // A listen that ended while this join was on its way has nobody to take it: the end is
        // closed there, and this side sees the drop it would on the air.
        guard listen.opening(theirs) else { throw NearbyDropped() }
        listen.joined(theirs)
        return ours
    }

    /// Every browser of `kind` told what is listed now.
    private func tell(_ kind: Kind) {
        let (browsers, adverts) = room.withLock { room in
            (room.browsers.values.filter { $0.kind == kind }, room.listed.values.map(\.advert))
        }
        for browser in browsers { browser.tell(adverts) }
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
