import CryptoKit
import Foundation

/// What a pairing screen draws, in order, on either side.
public enum PairingEvent: Sendable, Equatable {
    /// The holder's code, fresh or rolled after a wrong guess, shown with `NearbyCode.mark`.
    case code(String, sessionID: String)
    case connecting
    /// Both sides agreed a secret, and this side kept it.
    case paired(PairedDevice)
    /// The first merge (D8) runs on the same channel.
    case merging(PairedDevice)
    /// Holder: the joiner is looking at the first-merge preview.
    case waitingForAnswer(PairedDevice)
    /// What the first merge came to; the pair stays kept whatever it was.
    case done(PairedDevice, SyncOutcome)
    /// The other end has this device's own id: nothing kept.
    case sameDevice
    /// `.wrongCode`, `.guessing`, `.timedOut`, `.notAllowed`, `.lost`, `.malformed`, or another.
    case refused(NearbyRefusal)
}

/// Pairing, once, with the six digits (D1). The hold works like `NearbyMove.hold`: a code and
/// session id each try, rolled on a wrong code, closed as `.guessing` after `guessCap` wrong
/// codes and as `.timedOut` after `holdTimeout`. The holder advertises under its device name
/// with TXT `id=<session>` and `p=1`; the joiner picks a `NearbyPeer.pairing` hold whose mark
/// the person confirmed. Then, inside the channel (holder = `.receiver`, joiner = `.sender`):
///
///     both ──sync(pairHello{device,name,nonce32})──▶   (sender first, then receiver)
///          secret = HKDF<SHA256>(ikm: nonceS ‖ nonceR, salt: sessionID utf8,
///                                info: "fediqo-sync-1 pair" ‖ deviceS ‖ 0x00 ‖ deviceR, 32 bytes)
///     both ──sync(paired)──▶   each keeps the pair once it has read the other's `paired`
///
/// The same id on both ends refuses (`.sameDevice`). A device already paired is replaced, its
/// first merge not yet made. Where `firstMerge` is given (`SyncSession`), the first merge runs
/// on the same channel straight after, with the joiner — the one who typed the code — confirming.
public actor SyncPairing {
    /// A channel just paired over, handed to the first merge.
    struct Opened: Sendable {
        let channel: NearbyChannel
        let pair: PairedDevice
        let dialer: Bool
        /// Closes the link: what a step that waits too long does.
        let cut: @Sendable () -> Void
    }

    /// The first merge over a channel just paired; `waiting` is told when the other side is
    /// looking at the preview.
    typealias FirstMerge = @Sendable (Opened, _ waiting: @escaping @Sendable () async -> Void) async -> SyncOutcome

    private let link: any SyncLink
    private let pairs: any PairStore
    private let device: String
    private let name: String
    private let guessCap: Int
    private let holdClock: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private let firstMerge: FirstMerge?

    private var continuation: AsyncStream<PairingEvent>.Continuation?
    private var task: Task<Void, Never>?
    /// Which start the running task belongs to: a task from an earlier start, ending late,
    /// never closes the stream a later one handed out.
    private var generation = 0

    /// `device` is this device's id, `name` what it calls itself. `holdClock`, where given, is
    /// the hold's whole wait in place of `holdTimeout`.
    public init(
        link: any SyncLink, pairs: any PairStore, device: String, name: String,
        holdTimeout: Duration = .seconds(600), guessCap: Int = 5,
        holdClock: (@Sendable () async throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            link: link, pairs: pairs, device: device, name: name, holdTimeout: holdTimeout, guessCap: guessCap,
            holdClock: holdClock, now: now, firstMerge: nil
        )
    }

    init(
        link: any SyncLink, pairs: any PairStore, device: String, name: String,
        holdTimeout: Duration = .seconds(600), guessCap: Int = 5,
        holdClock: (@Sendable () async throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        firstMerge: FirstMerge?
    ) {
        self.firstMerge = firstMerge
        self.link = link
        self.pairs = pairs
        self.device = device
        self.name = name
        self.guessCap = guessCap
        self.holdClock = holdClock ?? { try await Task.sleep(for: holdTimeout) }
        self.now = now
    }

    /// Advertises a pairing hold and waits for a device to join it. The first event is the code.
    public func hold() -> AsyncStream<PairingEvent> {
        start { [self] in await runHold() }
    }

    /// Joins `peer`, a pairing hold, with the code its screen shows.
    public func join(peer: NearbyPeer, code: String) -> AsyncStream<PairingEvent> {
        start { [self] in await runJoin(peer: peer, code: code) }
    }

    /// Whatever is running stops, and the stream ends. Nothing half agreed is kept.
    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func start(_ body: @escaping @Sendable () async -> Void) -> AsyncStream<PairingEvent> {
        stop()
        let (stream, continuation) = AsyncStream<PairingEvent>.makeStream()
        self.continuation = continuation
        generation += 1
        let started = generation
        task = Task {
            await body()
            self.finish(started)
        }
        return stream
    }

    private func finish(_ started: Int) {
        guard started == generation else { return }
        continuation?.finish()
        continuation = nil
        task = nil
    }

    /// Said on the stream, unless by a task already stopped, whose stream is gone.
    private func emit(_ event: PairingEvent) {
        guard !Task.isCancelled else { return }
        continuation?.yield(event)
    }

    private func fail(_ error: any Error) {
        guard !Task.isCancelled else { return }
        switch error {
        case is SameDevice: emit(.sameDevice)
        case is NearbyDropped: emit(.refused(.lost))
        default: emit(.refused(NearbyRefusal(error)))
        }
    }

    // MARK: - Holding

    private enum HoldEnd: Sendable {
        case opened(Opened?)
        case clock
    }

    /// The hold's clock runs only until a device pairs: the first merge after it is not held
    /// to the hold's end. A device that paired just as the time ran out is paired: its pair is
    /// kept, so it is said and merged as any other.
    private func runHold() async {
        let opened: Opened?
        do {
            opened = try await withThrowingTaskGroup(of: HoldEnd.self) { group in
                group.addTask { .opened(try await self.holdLoop()) }
                group.addTask {
                    try await self.holdClock()
                    return .clock
                }
                defer { group.cancelAll() }
                if case .opened(let opened)? = try await group.next() { return opened }
                group.cancelAll()
                if case .opened(let opened?)? = try? await group.next() { return opened }
                throw NearbyRefusal.timedOut
            }
        } catch {
            fail(error)
            return
        }
        guard let opened else { return }
        defer { opened.cut() }
        emit(.paired(opened.pair))
        await mergeFirst(opened)
    }

    /// Codes, rolled on each wrong guess, until one device pairs: the channel it paired over,
    /// still open, or nil where the hold was put away.
    private nonisolated func holdLoop() async throws -> Opened? {
        var guesses = 0
        while true {
            try Task.checkCancellation()
            let code = NearbyCode.make()
            let sessionID = NearbyCode.sessionID()
            let psk = NearbyCode.psk(code: code, sessionID: sessionID)
            await emit(.code(code, sessionID: sessionID))
            var roll = false
            while !roll {
                var joined: (any NearbyPeerConnection)?
                var guessed = false
                for try await arrival in link.advertisePairing(name: name, sessionID: sessionID, psk: psk) {
                    switch arrival {
                    case .failedHandshake: guessed = true
                    case .joined(let connection): joined = connection
                    }
                    break
                }
                if !guessed {
                    guard let connection = joined else { return nil }
                    let mailbox = Mailbox(connection)
                    let cut: @Sendable () -> Void = {
                        mailbox.close()
                        connection.close()
                    }
                    do {
                        let channel = try await NearbyChannel.open(
                            over: connection, inbox: mailbox, role: .receiver, psk: psk, sessionID: sessionID
                        )
                        let pair = try await exchange(over: channel, role: .receiver, sessionID: sessionID)
                        return Opened(channel: channel, pair: pair, dialer: false, cut: cut)
                    } catch is NearbyDropped {
                        cut()
                        try Task.checkCancellation()
                        continue
                    } catch NearbyRefusal.wrongCode {
                        cut()
                        guessed = true
                    } catch {
                        cut()
                        throw error
                    }
                }
                guesses += 1
                guard guesses < guessCap else { throw NearbyRefusal.guessing }
                roll = true
            }
        }
    }

    // MARK: - Joining

    private func runJoin(peer: NearbyPeer, code: String) async {
        emit(.connecting)
        do {
            let psk = NearbyCode.psk(code: code, sessionID: peer.sessionID)
            let connection = try await link.connect(to: peer, psk: psk)
            let mailbox = Mailbox(connection)
            defer {
                mailbox.close()
                connection.close()
            }
            let channel = try await NearbyChannel.open(
                over: connection, inbox: mailbox, role: .sender, psk: psk, sessionID: peer.sessionID
            )
            let pair = try await exchange(over: channel, role: .sender, sessionID: peer.sessionID)
            emit(.paired(pair))
            await mergeFirst(Opened(channel: channel, pair: pair, dialer: true, cut: { mailbox.close(); connection.close() }))
        } catch {
            fail(error)
        }
    }

    /// The first merge, where one is wanted, said as `merging` … `done`.
    private nonisolated func mergeFirst(_ opened: Opened) async {
        guard let firstMerge else { return }
        let pair = opened.pair
        await emit(.merging(pair))
        let outcome = await firstMerge(opened) { await self.emit(.waitingForAnswer(pair)) }
        await emit(.done(pair, outcome))
    }

    // MARK: - The exchange

    /// Hellos swapped, the secret agreed, `paired` said both ways, and then the pair kept. Any
    /// refusal is said inside the channel first, so the other side hears it rather than a drop.
    private nonisolated func exchange(over channel: NearbyChannel, role: NearbyChannel.Role, sessionID: String) async throws -> PairedDevice {
        do {
            return try await agree(over: channel, role: role, sessionID: sessionID)
        } catch is NearbyDropped {
            throw NearbyDropped()
        } catch {
            try? await channel.send(.refuse)
            throw error
        }
    }

    private nonisolated func agree(over channel: NearbyChannel, role: NearbyChannel.Role, sessionID: String) async throws -> PairedDevice {
        let mine = PairHello(device: device, name: name, nonce: PackageKeys.random(32))
        let theirs: PairHello
        if role == .sender {
            try await channel.send(.sync(SyncFrame.pairHello(mine).encode()))
            theirs = try await Self.hello(from: channel)
        } else {
            theirs = try await Self.hello(from: channel)
            try await channel.send(.sync(SyncFrame.pairHello(mine).encode()))
        }
        guard theirs.device != device else { throw SameDevice() }
        let secret = role == .sender
            ? Self.secret(sender: mine, receiver: theirs, sessionID: sessionID)
            : Self.secret(sender: theirs, receiver: mine, sessionID: sessionID)
        try await channel.send(.sync(SyncFrame.paired.encode()))
        guard case .paired = try await Self.next(from: channel) else { throw NearbyRefusal.malformed }
        let pair = PairedDevice(device: theirs.device, name: theirs.name, pairedAt: now())
        try pairs.keep(pair, secret: secret)
        return pair
    }

    private static func next(from channel: NearbyChannel) async throws -> SyncFrame {
        switch try await channel.next() {
        case .sync(let data): return try SyncFrame.decode(data)
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
    }

    private static func hello(from channel: NearbyChannel) async throws -> PairHello {
        guard case .pairHello(let hello) = try await next(from: channel) else { throw NearbyRefusal.malformed }
        return hello
    }

    /// The pair secret both ends derive from the two hellos and the session.
    static func secret(sender: PairHello, receiver: PairHello, sessionID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sender.nonce + receiver.nonce),
            salt: Data(sessionID.utf8),
            info: Data("\(SyncFrame.label) pair".utf8) + Data(sender.device.utf8) + Data([0]) + Data(receiver.device.utf8),
            outputByteCount: 32
        )
    }

    private struct SameDevice: Error {}
}
