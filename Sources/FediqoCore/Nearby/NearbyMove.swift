import CryptoKit
import Foundation
import Synchronization

/// One store moving between two devices nearby (#253, #6): the steps, on either side, with
/// every decision in one place and no radio in it.
///
/// **The receiver holds** (`hold`): it advertises under a fresh session id, shows a six-digit
/// code, and waits. **The sender offers** (`offer`): it writes the package to its own scratch
/// space, joins the device the person picked under the key both derive from the code, and
/// sends what the package holds. Both screens then ask #252's question; both people press yes;
/// the package streams from the sender's disk to `incoming-<uuid>/package.fdq` under the
/// receiver's staging folder; and the receiver reads it back exactly as it would a file the
/// person carried over — proven whole before anything on it changes. Either no closes the
/// link with nothing written.
///
/// **Every word crosses inside `NearbyChannel`**: a fresh key agreement on each join, bound to
/// the code, proven both ways before the offer, and every frame after sealed under it — so a
/// recording of the wire and the code together open nothing, and a proof that fails is a wrong
/// code on the joining side and a guess on the holding side.
///
/// **A dropped link resumes.** The receiver keeps what it holds and goes on listening under the
/// same session and key; the sender joins again, offers the same offer by its id, and is told
/// `have: <bytes>` to go on from. Once the receiver has read the package back it keeps
/// listening, and answers the same offer with `done` — so a link that dropped on the last word
/// still ends on both screens the same way. A wrong code fails the handshake: the receiver
/// rolls its code and session, so a code that failed opens nothing — one guess per code — and
/// after `guessCap` wrong codes in one hold the hold is closed as someone guessing. A hold that
/// nobody joins closes after `holdTimeout`.
///
/// **The package's key is never the code.** A random 256-bit key locks the package
/// (`PackageKey.direct`); it crosses only inside the channel the code proved.
public actor NearbyMove {
    /// What a screen draws, in order, on either side.
    public enum Event: Sendable, Equatable {
        /// The receiver's code, fresh or rolled after a wrong guess, and the session it is
        /// bound to, whose mark is shown beside it.
        case code(String, sessionID: String)
        /// A device joined the receiver and proved the code, before its offer named it.
        case joined
        /// The sender is writing the package to its scratch space.
        case packing(PackageProgress)
        /// The sender is joining the device the person picked.
        case connecting
        /// #252's question, on both sides: what would move, to or from `peer`, and — on the
        /// receiver — whether a store held here would be replaced.
        case asking(NearbyOffer, peer: String, held: Bool)
        /// This side said yes; the other has not yet.
        case waiting(peer: String)
        /// Bytes on the wire, both sides.
        case moving(PackageProgress, peer: String)
        /// The link dropped; waiting for it to come back.
        case reconnecting(peer: String)
        /// Every byte is there: the receiver is proving and reading it back; the sender waits.
        case settling(peer: String)
        case done(PackageSummary, peer: String)
        case refused(NearbyRefusal)
        /// This side said no, or stopped: nothing written on either.
        case closed
    }

    private let link: any NearbyLink
    private let carrier: any StoreCarrier
    private let device: String
    private let retryDelay: Duration
    private let retries: Int
    private let holdTimeout: Duration
    private let guessCap: Int

    private var continuation: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private var answered: Bool?
    /// The receiver's person said yes to an offer this hold: the timeout no longer applies.
    private var holdAccepted = false

    /// `device` is what this device calls itself, advertised and written into the header.
    /// `retryDelay` and `retries` bound how long a dropped link is waited for; `holdTimeout`
    /// how long a hold waits for anyone; `guessCap` how many wrong codes one hold takes. Tests
    /// shorten them.
    public init(
        link: any NearbyLink, carrier: any StoreCarrier, device: String,
        retryDelay: Duration = .seconds(2), retries: Int = 45,
        holdTimeout: Duration = .seconds(600), guessCap: Int = 5
    ) {
        self.link = link
        self.carrier = carrier
        self.device = device
        self.retryDelay = retryDelay
        self.retries = retries
        self.holdTimeout = holdTimeout
        self.guessCap = guessCap
    }

    // MARK: - Driving

    /// The person's answer to the question, on this side. Heard once; a later one is nothing.
    public func answer(_ yes: Bool) {
        guard answered == nil else { return }
        answered = yes
        resumeWaiters(yes)
    }

    /// Whatever is running stops, and the stream ends. Nothing half done is kept.
    public func stop() {
        task?.cancel()
        task = nil
        resumeWaiters(false)
        continuation?.finish()
        continuation = nil
    }

    private func resumeWaiters(_ yes: Bool) {
        let waiters = pending
        pending = []
        for waiter in waiters { waiter.resume(returning: yes) }
    }

    /// The answer, once given. Every waiter — one per connection the question was up on — is
    /// resumed by the one answer, so a link that dropped while asking leaves nothing hanging.
    fileprivate func awaitAnswer() async -> Bool {
        if let answered { return answered }
        return await withCheckedContinuation { pending.append($0) }
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }

    private func start(_ body: @escaping @Sendable () async -> Void) -> AsyncStream<Event> {
        stop()
        answered = nil
        holdAccepted = false
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        task = Task {
            await body()
            self.finish()
        }
        return stream
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
        task = nil
    }

    private func accepted() {
        holdAccepted = true
    }

    // MARK: - Holding (the receiver)

    /// Advertises this device and waits for a sender. The first event is the code to show.
    public func hold() -> AsyncStream<Event> {
        start { [self] in await runHold() }
    }

    /// What the receiver keeps across connections once its person said yes.
    private struct Accepted: Sendable {
        let offer: NearbyOffer
        let folder: URL
        let file: URL
        let held: Bool
        var key: Data?
        /// Read back whole: a join with the same offer is answered `done`.
        var finished = false
    }

    private func runHold() async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.holdLoop() }
                group.addTask {
                    try await Task.sleep(for: self.holdTimeout)
                    guard await self.holdAccepted else { throw NearbyRefusal.timedOut }
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            guard !Task.isCancelled else { return }
            emit(.refused(NearbyRefusal(error)))
        }
    }

    /// Codes, rolled on each wrong guess until one is proven; then one move under it.
    private nonisolated func holdLoop() async throws {
        var guesses = 0
        while !Task.isCancelled {
            let code = NearbyCode.make()
            let sessionID = NearbyCode.sessionID()
            let psk = NearbyCode.psk(code: code, sessionID: sessionID)
            await emit(.code(code, sessionID: sessionID))
            var accepted: Accepted?
            // Whatever was staged goes on every way out of this code: done, refused, stopped.
            defer { if let accepted { try? FileManager.default.removeItem(at: accepted.folder) } }
            var roll = false
            for try await arrival in link.advertise(name: device, sessionID: sessionID, psk: psk) {
                switch arrival {
                case .failedHandshake:
                    guesses += 1
                    guard guesses < guessCap else { throw NearbyRefusal.guessing }
                    // One guess per code — until the code was proven, when a stranger's guess
                    // must not cut the move.
                    if accepted == nil { roll = true }
                case .joined(let connection):
                    let mailbox = Mailbox(connection)
                    defer {
                        mailbox.close()
                        connection.close()
                    }
                    do {
                        let channel = try await NearbyChannel.open(
                            over: connection, inbox: mailbox, role: .receiver, psk: psk, sessionID: sessionID
                        )
                        if try await serve(channel, mailbox: mailbox, accepted: &accepted) { return }
                    } catch is NearbyDropped {
                        // The link dropped: what is held stays, and the next join goes on.
                        try Task.checkCancellation()
                        if accepted != nil { await emit(.reconnecting(peer: accepted?.offer.summary.device ?? "")) }
                    } catch NearbyRefusal.wrongCode {
                        // The proof did not match: a guess, counted like a failed handshake.
                        guesses += 1
                        guard guesses < guessCap else { throw NearbyRefusal.guessing }
                        if accepted == nil { roll = true }
                    } catch {
                        try Task.checkCancellation()
                        try? await connection.send(.refuse)
                        throw error
                    }
                }
                if roll { break }
            }
            guard roll else { return }
        }
    }

    /// One connection on the receiving side, the channel open. True once the hold is over —
    /// this side said no; false where the link dropped or the move finished, and a later join
    /// carries on or is answered `done`.
    private nonisolated func serve(_ channel: NearbyChannel, mailbox: Mailbox, accepted: inout Accepted?) async throws -> Bool {
        await emit(.joined)
        guard case .offer(let offer) = try await channel.next() else { throw NearbyRefusal.malformed }
        let peer = offer.summary.device
        var fresh = false
        if let held = accepted {
            // The same offer, back after a drop: no second question — and, once read back, the
            // answer it missed.
            guard held.offer.id == offer.id else {
                try? await channel.send(.refuse)
                return false
            }
            if held.finished {
                try? await channel.send(.done)
                return false
            }
        } else {
            let weight = try await carrier.weigh()
            // The file, its staging, and what is moved in beside what was there.
            let (needed, overflow) = offer.fileBytes.multipliedReportingOverflow(by: 3)
            guard !overflow, needed <= Int64(Int.max) else { throw NearbyRefusal.malformed }
            guard weight.free >= Int(needed) else { throw NearbyRefusal.noRoom(needed: Int(needed), free: weight.free) }
            await emit(.asking(offer, peer: peer, held: weight.holdsStore))
            guard try await mailbox.waitAnswer(of: self, sealed: channel) else {
                try? await channel.send(.refuse)
                await emit(.closed)
                return true
            }
            await self.accepted()
            try await channel.send(.accept)
            fresh = true
            // Staged only once the yes was heard on the wire: a link that drops on the way
            // leaves nothing to sweep.
            let folder = carrier.stagingFolder().appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("package.fdq")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            accepted = Accepted(offer: offer, folder: folder, file: file, held: weight.holdsStore)
        }
        guard var held = accepted else { throw NearbyRefusal.malformed }
        if !fresh { try await channel.send(.accept) }
        let key: Data
        switch try await channel.next() {
        case .key(let sent): key = sent
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
        if let known = held.key {
            guard known == key else { throw NearbyRefusal.malformed }
        } else {
            held.key = key
            accepted = held
        }
        // Asked of the file system each time, never of a cached resource value: what was
        // written before a drop is exactly what the sender must go on from.
        var have = Self.bytesOnDisk(held.file)
        try await channel.send(.have(have))
        await emit(.moving(PackageProgress(done: Int(have), total: Int(held.offer.fileBytes)), peer: peer))
        let handle = try FileHandle(forWritingTo: held.file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        while true {
            switch try await channel.next() {
            case .bytes(let data):
                guard have + Int64(data.count) <= held.offer.fileBytes else { throw NearbyRefusal.malformed }
                try handle.write(contentsOf: data)
                have += Int64(data.count)
                await emit(.moving(PackageProgress(done: Int(have), total: Int(held.offer.fileBytes)), peer: peer))
            case .done:
                guard have == held.offer.fileBytes, Self.bytesOnDisk(held.file) == held.offer.fileBytes else {
                    throw NearbyRefusal.malformed
                }
                try handle.synchronize()
                try handle.close()
                await emit(.settling(peer: peer))
                let packageKey = PackageKey.direct(SymmetricKey(data: key))
                // The identical read back (#252): proven whole here before anything changes —
                // and the header proven to be the one the question was asked from.
                let summary = try await carrier.preview(held.file, key: packageKey)
                guard summary == held.offer.summary else { throw NearbyRefusal.malformed }
                try await carrier.readBack(held.file, key: packageKey, replacing: held.held) { _ in }
                // Read back: said here whatever the wire does next, and remembered for a join
                // that missed the word.
                held.finished = true
                accepted = held
                // The staging goes now, not at the hold's end: nothing of the package stays
                // on disk past its read back.
                try? FileManager.default.removeItem(at: held.folder)
                try? await channel.send(.done)
                await emit(.done(summary, peer: peer))
                return false
            case .refuse:
                throw NearbyRefusal.refusedThere
            default:
                throw NearbyRefusal.malformed
            }
        }
    }

    // MARK: - Offering (the sender)

    /// Writes the package, joins `peer` under `code`, and sends it. `pictures` and `contents`
    /// are what rides (#247, #6).
    public func offer(
        to peer: NearbyPeer, code: String, pictures: Bool, contents: PackageSummary.Contents
    ) -> AsyncStream<Event> {
        start { [self] in await runOffer(to: peer, code: code, pictures: pictures, contents: contents) }
    }

    private func runOffer(to peer: NearbyPeer, code: String, pictures: Bool, contents: PackageSummary.Contents) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appendingPathComponent("package.fdq")
            let key = SymmetricKey(size: .bits256)
            emit(.packing(PackageProgress(done: 0, total: 0)))
            // Progress goes straight to the stream, in order: a task hopping onto the actor could
            // land a "still packing" after the join had been said.
            let events = continuation
            try await carrier.takeAway(to: file, key: .direct(key), pictures: pictures, contents: contents) { progress in
                events?.yield(.packing(progress))
            }
            let summary = try await carrier.preview(file, key: .direct(key))
            let offer = NearbyOffer(summary: summary, fileBytes: Self.bytesOnDisk(file))
            let psk = NearbyCode.psk(code: code, sessionID: peer.sessionID)
            var attempt = 0
            var joinedOnce = false
            var sentDone = false
            while true {
                try Task.checkCancellation()
                emit(joinedOnce ? .reconnecting(peer: peer.name) : .connecting)
                let connection: any NearbyPeerConnection
                do {
                    connection = try await link.connect(to: peer, psk: psk)
                } catch is NearbyDropped {
                    // Not there yet: wait, and try again while there are tries left.
                    attempt += 1
                    guard joinedOnce, attempt <= retries else { throw sentDone ? NearbyRefusal.unsure : .lost }
                    try await Task.sleep(for: retryDelay)
                    continue
                }
                let mailbox = Mailbox(connection)
                defer {
                    mailbox.close()
                    connection.close()
                }
                do {
                    let channel = try await NearbyChannel.open(
                        over: connection, inbox: mailbox, role: .sender, psk: psk, sessionID: peer.sessionID
                    )
                    joinedOnce = true
                    if try await send(offer, file: file, key: key, over: channel, mailbox: mailbox, peer: peer.name, sentDone: &sentDone) {
                        return
                    }
                    emit(.closed)
                    return
                } catch is NearbyDropped {
                    // The link dropped: join again and go on from what the receiver holds — or,
                    // after the last word was sent, to hear whether it was read back.
                    attempt += 1
                    guard attempt <= retries else { throw sentDone ? NearbyRefusal.unsure : .lost }
                    try await Task.sleep(for: retryDelay)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            emit(.refused(NearbyRefusal(error)))
        }
    }

    /// One connection on the sending side, the channel open. True once the receiver said done;
    /// false where this side said no; throws where the link dropped (to be joined again) or the
    /// move was refused.
    private nonisolated func send(
        _ offer: NearbyOffer, file: URL, key: SymmetricKey, over channel: NearbyChannel, mailbox: Mailbox,
        peer: String, sentDone: inout Bool
    ) async throws -> Bool {
        try await channel.send(.offer(offer))
        if await answered == nil { await emit(.asking(offer, peer: peer, held: false)) }
        guard try await mailbox.waitAnswer(of: self, sealed: channel) else {
            try? await channel.send(.refuse)
            return false
        }
        await emit(.waiting(peer: peer))
        switch try await channel.next() {
        case .accept: break
        case .done:
            // Read back before the link dropped: the word that was missed.
            await emit(.done(offer.summary, peer: peer))
            return true
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
        // The key leaves as bytes only here, sealed, and the receiver holds it from then on.
        try await channel.send(.key(key.withUnsafeBytes { Data($0) }))
        guard case .have(let have) = try await channel.next(), have <= offer.fileBytes else { throw NearbyRefusal.malformed }
        await emit(.moving(PackageProgress(done: Int(have), total: Int(offer.fileBytes)), peer: peer))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(have))
        var sent = have
        while let chunk = try handle.read(upToCount: NearbyFrame.mostBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            try await channel.send(.bytes(chunk))
            sent += Int64(chunk.count)
            await emit(.moving(PackageProgress(done: Int(sent), total: Int(offer.fileBytes)), peer: peer))
        }
        try await channel.send(.done)
        sentDone = true
        await emit(.settling(peer: peer))
        switch try await channel.next() {
        case .done:
            await emit(.done(offer.summary, peer: peer))
            return true
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
    }

    /// The file's length now, as the file system says it.
    private nonisolated static func bytesOnDisk(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

/// A connection's frames and the person's answer, merged: either can be waited on, so a
/// refusal from the other side is heard while the question is up here, and a drop while asking
/// is a drop and not a wait.
///
/// One reader at a time, by design; the pump that reads the connection is its own task,
/// cancelled when the mailbox closes.
final class Mailbox: NearbyInbox, Sendable {
    enum Incoming: Sendable {
        case frame(NearbyFrame)
        case ended
        case answer(Bool)
    }

    private struct Held {
        var queue: [Incoming] = []
        var waiter: CheckedContinuation<Incoming, Never>?
        var closed = false
    }

    private let held = Mutex(Held())
    private let pump = Mutex<Task<Void, Never>?>(nil)

    init(_ connection: any NearbyPeerConnection) {
        let task = Task { [self] in
            do {
                for try await frame in connection.frames { push(.frame(frame)) }
            } catch {}
            push(.ended)
        }
        pump.withLock { $0 = task }
    }

    func close() {
        pump.withLock { $0?.cancel() }
        push(.ended)
    }

    private func push(_ incoming: Incoming) {
        let waiter = held.withLock { held -> CheckedContinuation<Incoming, Never>? in
            if let waiter = held.waiter {
                held.waiter = nil
                return waiter
            }
            held.queue.append(incoming)
            return nil
        }
        waiter?.resume(returning: incoming)
    }

    private func take() async -> Incoming {
        await withCheckedContinuation { continuation in
            let ready = held.withLock { held -> Incoming? in
                if !held.queue.isEmpty { return held.queue.removeFirst() }
                held.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// The next frame. An answer that lands here is one nobody was waiting on — a stale waiter
    /// resumed by `stop` — and is passed over.
    func next() async throws -> NearbyFrame {
        while true {
            switch await take() {
            case .frame(let frame): return frame
            case .answer: continue
            case .ended: throw NearbyDropped()
            }
        }
    }

    /// The person's answer, or what the peer said first: a refusal is `refusedThere`, anything
    /// else it says is out of turn, and an ending is a drop. `sealed` is the channel the peer's
    /// word rides in, once one is open.
    func waitAnswer(of move: NearbyMove, sealed channel: NearbyChannel? = nil) async throws -> Bool {
        let waiter = Task { [self] in
            let yes = await move.awaitAnswer()
            push(.answer(yes))
        }
        defer { waiter.cancel() }
        while true {
            switch await take() {
            case .answer(let yes): return yes
            case .frame(let frame):
                let word = try channel.map { try $0.unseal(frame) } ?? frame
                if case .refuse = word { throw NearbyRefusal.refusedThere }
                throw NearbyRefusal.malformed
            case .ended: throw NearbyDropped()
            }
        }
    }
}
