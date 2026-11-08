import CryptoKit
import Foundation

/// What a pairing screen draws, in order, on either side.
public enum PairingEvent: Sendable, Equatable {
    /// The holder's code, fresh or rolled after a wrong guess, shown with `NearbyCode.mark`.
    case code(String, sessionID: String)
    case connecting
    /// Both sides agreed a secret, and this side kept it.
    case paired(PairedDevice)
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
/// first merge not yet made.
public actor SyncPairing {
    private let link: any SyncLink
    private let pairs: any PairStore
    private let device: String
    private let name: String
    private let guessCap: Int
    private let holdClock: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date

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

    private func runHold() async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.holdLoop() }
                group.addTask {
                    try await self.holdClock()
                    throw NearbyRefusal.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            fail(error)
        }
    }

    /// Codes, rolled on each wrong guess, until one device pairs.
    private nonisolated func holdLoop() async throws {
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
                    guard let connection = joined else { return }
                    let mailbox = Mailbox(connection)
                    defer {
                        mailbox.close()
                        connection.close()
                    }
                    do {
                        let channel = try await NearbyChannel.open(
                            over: connection, inbox: mailbox, role: .receiver, psk: psk, sessionID: sessionID
                        )
                        await emit(.paired(try await exchange(over: channel, role: .receiver, sessionID: sessionID)))
                        return
                    } catch is NearbyDropped {
                        try Task.checkCancellation()
                        continue
                    } catch NearbyRefusal.wrongCode {
                        guessed = true
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
            emit(.paired(try await exchange(over: channel, role: .sender, sessionID: peer.sessionID)))
        } catch {
            fail(error)
        }
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
