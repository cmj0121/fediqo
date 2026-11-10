import CryptoKit
import Foundation
import Synchronization

/// D6: how often paired devices are looked for, while Fediqo is in front.
public enum SyncPeriod: String, CaseIterable, Sendable {
    case tenMinutes = "10m", hour = "1h", sixHours = "6h", never

    /// nil for `never`: no listening, no dialing; "Sync now" still works.
    public var interval: Duration? {
        switch self {
        case .tenMinutes: .seconds(600)
        case .hour: .seconds(3600)
        case .sixHours: .seconds(21_600)
        case .never: nil
        }
    }

    /// One hour: a change made on one device shows on the other within one sitting.
    public static let standard: SyncPeriod = .hour
}

/// How long the session waits for each thing.
public struct SyncTiming: Sendable {
    /// How often "is a pair due?" is asked in front.
    public var dueCheck: Duration
    /// Sync now: advertise and browse this long; also how long `dialDue` looks.
    public var syncNowWindow: Duration
    /// The first-merge yes/no.
    public var answerWait: Duration
    /// Any other frame.
    public var stepWait: Duration
    /// `SyncMerge.runsAhead`.
    public var mostAhead: Duration

    public init(
        dueCheck: Duration = .seconds(60), syncNowWindow: Duration = .seconds(60), answerWait: Duration = .seconds(120),
        stepWait: Duration = .seconds(30), mostAhead: Duration = .seconds(600)
    ) {
        self.dueCheck = dueCheck
        self.syncNowWindow = syncNowWindow
        self.answerWait = answerWait
        self.stepWait = stepWait
        self.mostAhead = mostAhead
    }

    public static let standard = SyncTiming()
}

/// What a merge with one device came to.
public enum SyncOutcome: Sendable, Equatable {
    case merged(here: SyncSummary, there: SyncSummary)
    /// Both already equal (still counts as merged).
    case nothingToMerge
    case notMerged(SyncRefusal)
}

/// What the session tells the app as it goes.
public enum SyncEvent: Sendable, Equatable {
    /// Sync now window open.
    case looking
    case joined(PairedDevice)
    /// The other device shows the first-merge preview (D8).
    case waitingForAnswer(PairedDevice)
    case done(PairedDevice, SyncOutcome)
    /// Sync now window closed, no paired device seen.
    case nobodyFound
    /// `.notAllowed`, said as that.
    case refusedLooking(NearbyRefusal)
}

/// What the session asks of the app; `ShellSync` is the one implementation.
public protocol SyncLocal: Sendable {
    /// This device's entries now. Throws `SyncRefusal.unreadableHere` where the timelines
    /// cannot be read or the store did not open.
    func snapshot() async throws -> SyncSnapshot
    /// Whether every timeline body in `remote` reads here and every kind is known.
    func readable(_ remote: SyncSnapshot) async -> Bool
    /// The first-merge question (D8) on this device's front window. nil where nobody answers
    /// within `answerWait`, or no window is in front — taken as no.
    func confirm(_ preview: SyncPreview, with peer: PairedDevice) async -> Bool?
    /// Applies `changes`. Throws where nothing could be written; partial is not possible per store.
    func apply(_ changes: SyncChanges, from peer: PairedDevice) async throws
    func said(_ event: SyncEvent) async
}

/// Merges with paired devices nearby (D6, D7, D8). One per run, app-wide.
///
/// **Who dials.** Every side dials a pair that is due. Where a join arrives for a pair this
/// side is already dialing, the session dialed by the lower device id goes on and the other is
/// closed `.busy`; both ends apply the same rule, so exactly one survives. Whichever join lands
/// first: the higher id's dial is closed for the lower's join, or hears `.busy` from the lower
/// and adopts the merge it serves for the lower's dial. A pair already merging — the first merge
/// of a pairing included — refuses a second join `.busy`, and a dial of it waits for it.
///
/// **What counts as met.** A pair is met only by a dial that gets past the handshake: one that
/// fails it (a stranger replaying the tag under its own name, a drop) is said nowhere, and the
/// other listeners showing the pair's tag are tried — at most `mostListenersTried` of them per
/// pair in one look, so a room full of strangers replaying a tag cannot keep it dialing. A
/// listener that failed is remembered for the pair until a merge or the next tag bucket, and
/// the next look tries the ones not yet tried first, so strangers listed first cannot take
/// every look's dials.
///
/// **Exchange** (both roles, over `NearbyChannel` keyed by `SyncDiscovery.psk(secret:tag:)`
/// with `sessionID: tag`): hello → snapshot → `runsAhead` / `readable` checks → `plan`. Only
/// this side's hello (who it is, no records) is sent before the other's hello reads, so a peer
/// on another version or under another pair gets no snapshot. On a first merge (either hello says not merged) whose preview is not empty, the
/// dialer asks `confirm` and sends `answer`; a no, or no answer within `answerWait`, is
/// `.declined` and the pair stays unmerged, to be asked at the next join. Then `apply` →
/// `applied`. Both true → `firstMerged`, `lastMerged = now`, and the clock witnesses the merge.
public actor SyncSession {
    private let link: any SyncLink
    private let pairs: any PairStore
    private let clock: SyncClock
    private let name: String
    private let local: any SyncLocal
    private let timing: SyncTiming
    private let now: @Sendable () -> Date

    /// The one merge under way per pair, and whether this side dialed it.
    private struct Active {
        let id: Int
        let dialing: Bool
        /// nil: never got past the handshake.
        let task: Task<SyncOutcome?, Never>
    }

    private var active: [String: Active] = [:]
    /// A dial closed for a join that won the tie-break, and the merge that join runs.
    private var supersededBy: [Int: Task<SyncOutcome?, Never>] = [:]
    /// The latest merge served for each pair (a join from it, or a pairing's first merge).
    private var lastServed: [String: (id: Int, task: Task<SyncOutcome?, Never>)] = [:]
    private var nextID = 0
    /// When each pair was last dialed this run: a pair said no to is asked again a period on.
    private var tried: [String: Date] = [:]
    /// This device's own listeners, never dialed — kept a bucket past their end, while a browse
    /// may still list them.
    private var ownNames: Set<String> = []
    private var listens = 0
    private var pairing: SyncPairing?

    /// How many of a pair's listeners one look dials before it leaves the pair for the next.
    static let mostListenersTried = 3
    /// The listeners each pair's dials could not get past, in the tag bucket they failed in.
    private var failedListeners: [String: (bucket: Int64, ids: Set<String>)] = [:]

    public init(
        link: any SyncLink, pairs: any PairStore, clock: SyncClock, name: String,
        local: any SyncLocal, timing: SyncTiming = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.link = link
        self.pairs = pairs
        self.clock = clock
        self.name = name
        self.local = local
        self.timing = timing
        self.now = now
    }

    private nonisolated var device: String { clock.device }

    // MARK: - Listening

    /// Advertises every pair (one listener each, `instanceName()` fresh each start, the tag of
    /// the current bucket, restarted at each bucket boundary) and serves each join. Runs until
    /// cancelled; throws `SyncRefusal.notAllowed`.
    public func listen() async throws {
        listens += 1
        defer { listens -= 1 }
        try await advertiseAll()
    }

    private func advertiseAll() async throws {
        let kept = keptPairs()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (pair, secret) in kept {
                    group.addTask { try await self.advertise(pair.device, secret: secret) }
                }
                if kept.isEmpty {
                    group.addTask { while true { try await Task.sleep(for: .seconds(3600)) } }
                }
                for try await _ in group {}
            }
        } catch NearbyRefusal.notAllowed {
            throw SyncRefusal.notAllowed
        }
    }

    /// One pair's listener, made again with a fresh name and tag at every bucket boundary.
    private nonisolated func advertise(_ device: String, secret: SymmetricKey) async throws {
        while true {
            try Task.checkCancellation()
            let at = now()
            let bucket = SyncDiscovery.bucket(at: at)
            let tag = SyncDiscovery.tag(secret: secret, bucket: bucket)
            let psk = SyncDiscovery.psk(secret: secret, tag: tag)
            let instance = SyncDiscovery.instanceName()
            let untilNext = Double((bucket + 1) * SyncDiscovery.bucketSeconds) - at.timeIntervalSince1970
            await own(instance, true)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await arrival in self.link.advertise(name: instance, tag: tag, psk: psk) {
                            if case .joined(let connection) = arrival {
                                await self.arrived(connection, for: device, tag: tag, psk: psk, secret: secret)
                            }
                        }
                    }
                    group.addTask { try await Task.sleep(for: .seconds(max(untilNext, 1))) }
                    try await group.next()
                    group.cancelAll()
                }
                await own(instance, false)
            } catch {
                await own(instance, false)
                throw error
            }
        }
    }

    private func own(_ instance: String, _ held: Bool) {
        guard !held else {
            ownNames.insert(instance)
            return
        }
        let linger = SyncDiscovery.bucketSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            await self?.retire(instance)
        }
    }

    private func retire(_ instance: String) {
        ownNames.remove(instance)
    }

    /// A join under one pair's listener: refused `.notPaired` where the pair was forgotten since,
    /// `.busy` where a merge with it is under way, unless this side's own dial loses the
    /// tie-break — then that dial is closed and the join is served.
    private func arrived(_ connection: any NearbyPeerConnection, for device: String, tag: String, psk: SymmetricKey, secret: SymmetricKey) {
        guard let (pair, kept) = try? pairs.kept(device), kept == secret else {
            refuse(connection, tag: tag, psk: psk, .notPaired)
            return
        }
        let serve: @Sendable () async -> SyncOutcome? = {
            await self.run(over: connection, pair: pair, tag: tag, psk: psk, dialer: false)
        }
        guard let running = active[device] else {
            _ = start(device, dialing: false, serve)
            return
        }
        guard running.dialing, self.device > device else {
            refuse(connection, tag: tag, psk: psk, .busy)
            return
        }
        running.task.cancel()
        supersededBy[running.id] = start(device, dialing: false, serve).task
    }

    /// Opens the channel only to say why not, then closes.
    private nonisolated func refuse(_ connection: any NearbyPeerConnection, tag: String, psk: SymmetricKey, _ refusal: SyncRefusal) {
        let wait = timing.stepWait
        Task {
            let mailbox = Mailbox(connection)
            defer { mailbox.cut() }
            let timer = Self.timer(wait, mailbox.cut)
            defer { timer.cancel() }
            guard let channel = try? await NearbyChannel.open(
                over: connection, inbox: mailbox, role: .receiver, psk: psk, sessionID: tag
            ) else { return }
            await Self.say(.refused(refusal), over: channel, within: wait, cut: mailbox.cut)
        }
    }

    private func start(_ device: String, dialing: Bool, _ body: @escaping @Sendable () async -> SyncOutcome?) -> Active {
        nextID += 1
        let id = nextID
        let task = Task {
            let outcome = await body()
            self.finished(device, id)
            return outcome
        }
        let running = Active(id: id, dialing: dialing, task: task)
        active[device] = running
        if !dialing { lastServed[device] = (id, task) }
        return running
    }

    private func finished(_ device: String, _ id: Int) {
        if active[device]?.id == id { active[device] = nil }
    }

    // MARK: - Dialing

    /// Browses, and dials each pair found whose `lastMerged` (or last try this run) is nil or
    /// older than `period`; at most one merge per pair. Returns as soon as every due pair was
    /// met or `syncNowWindow` ran out (pairs not seen are left for the next check).
    public func dialDue(period: SyncPeriod) async -> [String: SyncOutcome] {
        guard period.interval != nil else { return [:] }
        let at = now()
        return await look(advertising: false) { pair, tried in Self.due(pair, tried: tried, period: period, at: at) }.outcomes
    }

    /// Whether any of `paired` is due under `period` by what is known already — each one's
    /// `lastMerged` and this run's last try of it — without reading the pairs again: what tells
    /// a check whether `dialDue` has anything to look for.
    public func anyDue(_ paired: [PairedDevice], period: SyncPeriod) -> Bool {
        let at = now()
        return paired.prefix(PairLimit.most).contains { Self.due($0, tried: tried[$0.device], period: period, at: at) }
    }

    /// Never merged nor tried, or the last of the two a whole `period` ago; never for `never`.
    private static func due(_ pair: PairedDevice, tried: Date?, period: SyncPeriod, at: Date) -> Bool {
        guard let interval = period.interval else { return false }
        guard let last = [pair.lastMerged, tried].compactMap({ $0 }).max() else { return true }
        return at.timeIntervalSince(last) >= Double(interval.components.seconds)
    }

    /// "Sync now": advertise (where not already listening) and browse for `syncNowWindow`,
    /// dialing every paired device found, whatever the period and whether merged or not. Says
    /// `.nobodyFound` where none was seen.
    public func syncNow() async -> [String: SyncOutcome] {
        await local.said(.looking)
        let looked = await look(advertising: listens == 0) { _, _ in true }
        if looked.outcomes.isEmpty, !looked.refused { await local.said(.nobodyFound) }
        return looked.outcomes
    }

    private enum Looked: Sendable {
        case peers([SyncPeer])
        /// A dial's outcome; nil where it did not get past the handshake.
        case done(String, peer: String, SyncOutcome?)
        case over
        case refused(NearbyRefusal)
    }

    private func look(
        advertising: Bool, due: (PairedDevice, _ tried: Date?) -> Bool
    ) async -> (outcomes: [String: SyncOutcome], refused: Bool) {
        let wanted = keptPairs().filter { due($0.pair, tried[$0.pair.device]) }
        guard !wanted.isEmpty else { return ([:], false) }
        let (events, sink) = AsyncStream<Looked>.makeStream()
        let browser = Task { [link] in
            do {
                for try await peers in link.browseTags() { sink.yield(.peers(peers)) }
            } catch {
                sink.yield(.refused(NearbyRefusal(error)))
            }
        }
        let window = timing.syncNowWindow
        let timer = Task {
            try? await Task.sleep(for: window)
            sink.yield(.over)
        }
        let advertiser: Task<Void, Never>? = advertising ? Task { try? await self.advertiseAll() } : nil
        defer {
            browser.cancel()
            timer.cancel()
            advertiser?.cancel()
            sink.finish()
        }
        /// Pairs met, no longer due, or whose `mostListenersTried` dials all failed.
        var settled: Set<String> = []
        var dialing: Set<String> = []
        /// The listeners each pair's dials could not get past.
        var missed: [String: Set<String>] = [:]
        var seen: [SyncPeer] = []
        var outcomes: [String: SyncOutcome] = [:]
        var over = false
        var refused = false

        let bucket = SyncDiscovery.bucket(at: now())
        let failedBefore = failedListeners.values.filter { $0.bucket == bucket }.reduce(into: Set<String>()) { $0.formUnion($1.ids) }

        func dialSeen() {
            guard !over else { return }
            let order = seen.filter { !failedBefore.contains($0.id) } + seen.filter { failedBefore.contains($0.id) }.shuffled()
            for peer in order where !ownNames.contains(peer.name) {
                guard let (pair, secret) = wanted.first(where: {
                    let device = $0.pair.device
                    return !settled.contains(device) && !dialing.contains(device) && !missed[device, default: []].contains(peer.id)
                        && SyncDiscovery.accepts(peer.tag, secret: $0.secret, at: now())
                }) else { continue }
                // Merged meanwhile by the other's join, or forgotten: not dialed.
                guard let fresh = (try? pairs.kept(pair.device))?.pair,
                      due(fresh, tried[fresh.device])
                else {
                    settled.insert(pair.device)
                    continue
                }
                dialing.insert(fresh.device)
                Task {
                    let outcome = await self.dial(fresh, at: peer, secret: secret)
                    sink.yield(.done(fresh.device, peer: peer.id, outcome))
                }
            }
        }

        for await event in events {
            switch event {
            case .peers(let peers):
                seen = peers
                dialSeen()
            case .done(let device, let peer, let outcome):
                dialing.remove(device)
                if let outcome {
                    settled.insert(device)
                    outcomes[device] = outcome
                    failedListeners[device] = nil
                } else {
                    missed[device, default: []].insert(peer)
                    remember(peer, failedFor: device, in: bucket)
                    if missed[device, default: []].count >= Self.mostListenersTried { settled.insert(device) }
                    dialSeen()
                }
            case .over:
                over = true
            case .refused(let refusal):
                refused = true
                over = true
                await local.said(.refusedLooking(refusal))
            }
            if dialing.isEmpty, over || settled.count == wanted.count { break }
        }
        return (outcomes, refused)
    }

    private func remember(_ listener: String, failedFor device: String, in bucket: Int64) {
        var failed = failedListeners[device].flatMap { $0.bucket == bucket ? $0.ids : nil } ?? []
        failed.insert(listener)
        failedListeners[device] = (bucket, failed)
    }

    /// One dial, or the merge already under way with that pair. nil where it did not get past
    /// the handshake.
    private func dial(_ pair: PairedDevice, at peer: SyncPeer, secret: SymmetricKey) async -> SyncOutcome? {
        if let running = active[pair.device] { return await running.task.value }
        let psk = SyncDiscovery.psk(secret: secret, tag: peer.tag)
        let running = start(pair.device, dialing: true) {
            guard let connection = try? await self.link.connect(to: peer, psk: psk) else { return nil }
            return await self.run(over: connection, pair: pair, tag: peer.tag, psk: psk, dialer: true)
        }
        let outcome = await running.task.value
        if let winner = supersededBy.removeValue(forKey: running.id) { return await winner.value }
        guard let outcome else { return nil }
        tried[pair.device] = now()
        if outcome == .notMerged(.busy), pair.device < device {
            // The lower id refused this dial for its own: the merge is the one served for it.
            if let served = await served(for: pair.device, after: running.id) { return await served.value }
            await local.said(.done(pair, outcome))
        }
        return outcome
    }

    /// The merge served for `device` since dial `id` began, once one is, within `stepWait`.
    private func served(for device: String, after id: Int) async -> Task<SyncOutcome?, Never>? {
        let deadline = ContinuousClock.now + timing.stepWait
        while ContinuousClock.now < deadline {
            if let served = lastServed[device], served.id > id { return served.task }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// One merge over a joined connection, said as `joined` … `done` — unless it never got past
    /// the handshake (nil), was closed for a join that won the tie-break, or heard `.busy` from
    /// the lower id (the dial adopts the merge served instead).
    private nonisolated func run(
        over connection: any NearbyPeerConnection, pair: PairedDevice, tag: String, psk: SymmetricKey, dialer: Bool
    ) async -> SyncOutcome? {
        let mailbox = Mailbox(connection)
        let cut = mailbox.cut
        defer { cut() }
        let outcome: SyncOutcome? = await withTaskCancellationHandler {
            let timer = Self.timer(timing.stepWait, cut)
            let channel = try? await NearbyChannel.open(
                over: connection, inbox: mailbox, role: dialer ? .sender : .receiver, psk: psk, sessionID: tag
            )
            timer.cancel()
            guard let channel else { return nil }
            return await exchange(
                over: channel, pair: pair, dialer: dialer, cut: cut,
                joined: { await self.local.said(.joined($0)) },
                waiting: { await self.local.said(.waitingForAnswer(pair)) }
            )
        } onCancel: {
            cut()
        }
        guard let outcome, !Task.isCancelled else { return outcome }
        if dialer, outcome == .notMerged(.busy), pair.device < device { return outcome }
        await local.said(.done(pair, outcome))
        return outcome
    }

    // MARK: - Pairing

    /// Pairing (U4): hold, or join a hold the person picked and whose mark they confirmed.
    /// The first merge runs on the same channel; the joiner confirms.
    public func holdPairing() async -> AsyncStream<PairingEvent> {
        await pairer().hold()
    }

    public func joinPairing(peer: NearbyPeer, code: String) async -> AsyncStream<PairingEvent> {
        await pairer().join(peer: peer, code: code)
    }

    public func stopPairing() async {
        await pairing?.stop()
    }

    private func pairer() -> SyncPairing {
        if let pairing { return pairing }
        let made = SyncPairing(
            link: link, pairs: pairs, device: clock.device, name: name, now: now,
            firstMerge: { [weak self] opened, waiting in
                guard let self else { return .notMerged(.lost) }
                return await self.mergePaired(opened, waiting: waiting)
            }
        )
        pairing = made
        return made
    }

    /// A pairing's first merge, held as the pair's merge under way: a dial of the pair waits for
    /// it, and a join from it is refused `.busy`.
    private func mergePaired(_ opened: SyncPairing.Opened, waiting: @escaping @Sendable () async -> Void) async -> SyncOutcome {
        let running = start(opened.pair.device, dialing: false) {
            await withTaskCancellationHandler {
                await self.exchange(
                    over: opened.channel, pair: opened.pair, dialer: opened.dialer, cut: opened.cut,
                    joined: { _ in }, waiting: waiting
                )
            } onCancel: {
                opened.cut()
            }
        }
        return await withTaskCancellationHandler {
            await running.task.value ?? .notMerged(.lost)
        } onCancel: {
            running.task.cancel()
        }
    }

    // MARK: - The exchange

    /// Runs the exchange over an opened channel (also used straight after pairing). Any refusal
    /// of this side's is said inside the channel first, so the other side hears why.
    nonisolated func exchange(
        over channel: NearbyChannel, pair: PairedDevice, dialer: Bool, cut: @escaping @Sendable () -> Void,
        joined: @Sendable (PairedDevice) async -> Void, waiting: @Sendable () async -> Void
    ) async -> SyncOutcome {
        do {
            return try await merge(over: channel, pair: pair, dialer: dialer, cut: cut, joined: joined, waiting: waiting)
        } catch let heard as Heard {
            return .notMerged(heard.refusal)
        } catch SyncRefusal.otherVersion(let theirs) {
            await Self.say(.versionRefused(newest: SyncFrame.version), over: channel, within: timing.stepWait, cut: cut)
            return .notMerged(theirs > SyncFrame.version ? .peerNewer : .peerOlder)
        } catch let refusal as SyncRefusal {
            await Self.say(.refused(refusal), over: channel, within: timing.stepWait, cut: cut)
            return .notMerged(refusal)
        } catch NearbyRefusal.malformed {
            await Self.say(.refused(.malformed), over: channel, within: timing.stepWait, cut: cut)
            return .notMerged(.malformed)
        } catch {
            return .notMerged(.lost)
        }
    }

    private nonisolated func merge(
        over channel: NearbyChannel, pair: PairedDevice, dialer: Bool, cut: @escaping @Sendable () -> Void,
        joined: @Sendable (PairedDevice) async -> Void, waiting: @Sendable () async -> Void
    ) async throws -> SyncOutcome {
        try await send(.hello(SyncHello(device: device, name: name, firstMerged: pair.firstMerged)), over: channel)
        guard case .hello(let theirs) = try await read(channel, within: timing.stepWait, cut: cut) else {
            throw NearbyRefusal.malformed
        }
        guard theirs.device == pair.device else { throw SyncRefusal.notPaired }
        var pair = pair
        if pair.name != theirs.name {
            pair.name = theirs.name
            try? pairs.update(pair)
        }
        await joined(pair)
        let first = !pair.firstMerged || !theirs.firstMerged

        let here: SyncSnapshot
        do {
            here = try await local.snapshot().shared
        } catch let refusal as SyncRefusal {
            throw refusal
        } catch {
            throw SyncRefusal.unreadableHere
        }
        try await send(.snapshot(here), over: channel)
        guard case .snapshot(let there) = try await read(channel, within: timing.stepWait, cut: cut) else {
            throw NearbyRefusal.malformed
        }
        guard !SyncMerge.runsAhead(there, now: now(), mostAhead: timing.mostAhead) else { throw SyncRefusal.clockAhead }
        guard await local.readable(there) else { throw SyncRefusal.peerNewer }
        let plan = SyncMerge.plan(local: here, remote: there)

        if first, !plan.preview.isEmpty {
            if dialer {
                let preview = plan.preview
                let asked = pair
                let yes = await Self.within(timing.answerWait) { await self.local.confirm(preview, with: asked) } ?? nil
                try await send(.answer(yes == true), over: channel)
                guard yes == true else { return .notMerged(.declined) }
            } else {
                await waiting()
                guard case .answer(let yes) = try await read(channel, within: timing.answerWait + timing.stepWait, cut: cut) else {
                    throw NearbyRefusal.malformed
                }
                guard yes else { return .notMerged(.declined) }
            }
        }

        var failure: SyncRefusal?
        if !plan.here.isEmpty {
            do {
                try await local.apply(plan.here, from: pair)
            } catch {
                failure = (error as? SyncRefusal) ?? .unreadableHere
            }
        }
        try await send(.applied(failure == nil), over: channel)
        guard case .applied(let appliedThere) = try await read(channel, within: timing.stepWait, cut: cut) else {
            throw NearbyRefusal.malformed
        }
        if let failure { return .notMerged(failure) }
        guard appliedThere else { return .notMerged(.unreadableThere) }
        clock.witness(plan.merged.newest)
        pair.firstMerged = true
        pair.lastMerged = now()
        try? pairs.update(pair)
        return plan.here.isEmpty && plan.there.isEmpty
            ? .nothingToMerge
            : .merged(here: plan.here.summary, there: plan.there.summary)
    }

    /// Says a last word and stays until the other side hangs up on hearing it (the caller's
    /// timer bounds the wait), so the word is never lost under a send of theirs.
    private static func say(_ frame: SyncFrame, over channel: NearbyChannel, within wait: Duration, cut: @escaping @Sendable () -> Void) async {
        let timer = timer(wait, cut)
        defer { timer.cancel() }
        guard (try? await channel.send(.sync(frame.encode()))) != nil else { return }
        while (try? await channel.next()) != nil {}
    }

    private nonisolated func send(_ frame: SyncFrame, over channel: NearbyChannel) async throws {
        try await channel.send(.sync(frame.encode()))
    }

    /// The next sync frame, within `wait` or the link is cut. A refusal the other side said is
    /// thrown as `Heard`, from this side's view.
    private nonisolated func read(_ channel: NearbyChannel, within wait: Duration, cut: @escaping @Sendable () -> Void) async throws -> SyncFrame {
        let timer = Self.timer(wait, cut)
        defer { timer.cancel() }
        guard case .sync(let data) = try await channel.next() else { throw NearbyRefusal.malformed }
        switch try SyncFrame.decode(data) {
        case .refused(let refusal):
            throw Heard(refusal: refusal.mirrored)
        case .versionRefused(let newest):
            if newest > SyncFrame.version { throw Heard(refusal: .peerNewer) }
            if newest < SyncFrame.version { throw Heard(refusal: .peerOlder) }
            throw Heard(refusal: .malformed)
        case let frame:
            return frame
        }
    }

    /// A refusal the other side said: nothing is said back.
    private struct Heard: Error {
        let refusal: SyncRefusal
    }

    /// Cuts the link once `wait` passes, unless cancelled first.
    private static func timer(_ wait: Duration, _ cut: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: wait)
            if !Task.isCancelled { cut() }
        }
    }

    /// `operation`'s value, or nil once `limit` passes first — whether or not it heeds cancellation.
    static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let once = Mutex<CheckedContinuation<T?, Never>?>(nil)
        let tasks = Mutex<[Task<Void, Never>]>([])
        let settle: @Sendable (T?) -> Void = { value in
            guard let waiter = once.withLock({ held -> CheckedContinuation<T?, Never>? in
                defer { held = nil }
                return held
            }) else { return }
            for task in tasks.withLock({ $0 }) { task.cancel() }
            waiter.resume(returning: value)
        }
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.withLock { $0 = continuation }
                // Cancelled between the check and here: `onCancel` found nothing to resume.
                if Task.isCancelled {
                    settle(nil)
                    return
                }
                let work = Task { settle(await operation()) }
                let clock = Task {
                    try? await Task.sleep(for: limit)
                    settle(nil)
                }
                tasks.withLock { $0 = [work, clock] }
            }
        } onCancel: {
            settle(nil)
        }
    }

    private func keptPairs() -> [(pair: PairedDevice, secret: SymmetricKey)] {
        Array(((try? pairs.kept()) ?? []).prefix(PairLimit.most))
    }
}

extension SyncRefusal {
    /// The same refusal as the other side says it.
    var mirrored: SyncRefusal {
        switch self {
        case .peerOlder: .peerNewer
        case .peerNewer: .peerOlder
        case .unreadableHere: .unreadableThere
        case .unreadableThere: .unreadableHere
        case .otherVersion, .notPaired, .declined, .clockAhead, .busy, .tooLarge, .malformed, .notAllowed, .lost: self
        }
    }
}
