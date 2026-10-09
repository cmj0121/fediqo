import Foundation
import os
import Testing
@testable import FediqoCore

/// A clock a test turns by hand. A sleeper is woken only by `advance`, and a test waits for the
/// pacer to *be* asleep until a given moment (`sleeping(for:)`) rather than for any time to pass.
///
/// Two hands, as `PacerClock` has: seconds that only pass, which every wait is counted in, and a
/// date, which a test can set back without a single wait growing longer.
final class HandClock: PacerClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let until: TimeInterval
        let wake: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var passed: TimeInterval = 0
        var date: Date
        var sleepers: [Sleeper] = []
        var watchers: [(until: TimeInterval, seen: CheckedContinuation<Void, Never>)] = []
        var abandoned = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(uncheckedState: State(date: start))
    }

    func elapsed() -> TimeInterval { state.withLockUnchecked { $0.passed } }
    func wall() -> Date { state.withLockUnchecked { $0.date } }

    func sleep(until moment: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let seen: [CheckedContinuation<Void, Never>] = state.withLockUnchecked { state in
                    if moment <= state.passed || Task.isCancelled || state.abandoned {
                        // Abandoned, the clock runs to whatever is waited for: nobody waiting
                        // "until then" finds it is still before then, and waits again for ever.
                        if state.abandoned { state.passed = max(state.passed, moment) }
                        wake.resume()
                        return []
                    }
                    state.sleepers.append(Sleeper(id: id, until: moment, wake: wake))
                    let ready = state.watchers.filter { abs($0.until - moment) < 0.001 }.map(\.seen)
                    state.watchers.removeAll { abs($0.until - moment) < 0.001 }
                    return ready
                }
                for watcher in seen { watcher.resume() }
            }
        } onCancel: {
            let woken = state.withLockUnchecked { state -> Sleeper? in
                guard let at = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: at)
            }
            woken?.wake.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    /// Returns once something is asleep on this clock until exactly `seconds` from now.
    func sleeping(for seconds: TimeInterval) async {
        await withCheckedContinuation { (seen: CheckedContinuation<Void, Never>) in
            let already = state.withLockUnchecked { state -> Bool in
                let until = state.passed + seconds
                if state.abandoned || state.sleepers.contains(where: { abs($0.until - until) < 0.001 }) { return true }
                state.watchers.append((until, seen))
                return false
            }
            if already { seen.resume() }
        }
    }

    /// How many seconds from now each sleeper wakes, soonest first.
    var wakes: [TimeInterval] { state.withLockUnchecked { state in state.sleepers.map { $0.until - state.passed }.sorted() } }

    func advance(by seconds: TimeInterval) {
        let due = state.withLockUnchecked { state -> [Sleeper] in
            state.passed += seconds
            state.date = state.date.addingTimeInterval(seconds)
            let due = state.sleepers.filter { $0.until <= state.passed + 0.000_001 }
            state.sleepers.removeAll { $0.until <= state.passed + 0.000_001 }
            return due
        }
        for sleeper in due { sleeper.wake.resume() }
    }

    /// Sets the date back, as somebody changing the system clock does. No second passes.
    func setDateBack(by seconds: TimeInterval) {
        state.withLockUnchecked { $0.date = $0.date.addingTimeInterval(-seconds) }
    }

    /// Stops being a clock: everybody asleep is woken, everybody watching is told, and nothing
    /// waits on it again. What a hang guard does to a test that lost its place.
    func abandon() {
        let (sleepers, watchers) = state.withLockUnchecked { state in
            state.abandoned = true
            state.passed = state.sleepers.map(\.until).max().map { max($0, state.passed) } ?? state.passed
            defer { state.sleepers = []; state.watchers = [] }
            return (state.sleepers, state.watchers.map(\.seen))
        }
        for sleeper in sleepers { sleeper.wake.resume() }
        for watcher in watchers { watcher.resume() }
    }
}

/// What a source does with each try of each load: when it was asked, what it answers, and one
/// load it can be made to hold on the wire until the test lets it through.
actor LoadWire {
    private let clock: HandClock
    private var scripted: [String: [LoadAnswer]] = [:]
    private(set) var tries: [(id: String, at: TimeInterval)] = []
    private var held: Set<String> = []
    private var holding: [String: CheckedContinuation<Void, Never>] = [:]
    private var watchers: [(count: Int, seen: CheckedContinuation<Void, Never>)] = []
    private var abandoned = false

    /// Lets everything through and tells everybody waiting: a hang guard's, as `HandClock.abandon`.
    func abandon() {
        abandoned = true
        held = []
        for held in holding.values { held.resume() }
        holding = [:]
        for watcher in watchers { watcher.seen.resume() }
        watchers = []
    }

    init(_ clock: HandClock) {
        self.clock = clock
    }

    /// The answers `id`'s tries get, in order; the last one is given for every try after it.
    func script(_ id: String, _ answers: [LoadAnswer]) { scripted[id] = answers }
    func hold(_ id: String) { held.insert(id) }
    func release(_ id: String) {
        held.remove(id)
        holding.removeValue(forKey: id)?.resume()
    }

    var ids: [String] { tries.map(\.id) }
    var times: [TimeInterval] { tries.map(\.at) }

    /// Returns once `count` tries have been asked.
    func asked(_ count: Int) async {
        guard tries.count < count, !abandoned else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func answer(_ id: String) async -> LoadAnswer {
        tries.append((id, clock.elapsed()))
        let ready = watchers.filter { $0.count <= tries.count }
        watchers.removeAll { $0.count <= tries.count }
        for watcher in ready { watcher.seen.resume() }
        if held.contains(id), !abandoned { await withCheckedContinuation { holding[id] = $0 } }
        guard var answers = scripted[id], !answers.isEmpty else { return .answered() }
        let next = answers.count > 1 ? answers.removeFirst() : answers[0]
        scripted[id] = answers
        return next
    }

    nonisolated func work(_ id: String) -> @Sendable () async -> LoadAnswer {
        { await self.answer(id) }
    }
}

/// #293: a source is asked for what items refer to no faster than it is for timelines — one
/// load at a time, no closer together than the pace a timeline is read at, slower at the
/// source's own word, and not at all once it has failed too often.
///
/// Every test turns the clock by hand and waits for the pacer to be asleep until a moment the
/// test names, or for a try to have been asked: nothing sleeps, and nothing is given a time to
/// finish in.
@Suite("A source's loads wait their turn")
struct LoadPacerTests {
    private static let host = "one.example"
    /// The pace as the limits state it, so no test here says the figure but the one that is about it.
    private static let pace = LoadLimits().interval

    /// A pacer on a clock the test turns, a wire to ask, and a hang guard already armed.
    ///
    /// **The guard is not a clock** (`hangGuard`'s rule, and its fifty seconds). Every wait here
    /// is for the pacer to do something; a pacer that never does it would park the test for
    /// good, so past any honest wait the guard says so, lets everything through, and the test
    /// ends failed rather than never.
    private func made(_ change: (inout LoadLimits) -> Void = { _ in }) -> (LoadPacer, HandClock, LoadWire) {
        var limits = LoadLimits()
        // A try's deadline is a sleeper on the clock too, for as long as the try is out. Kept
        // well clear of every other figure here, so a test waiting for "asleep for thirty
        // seconds" is never answered by a try's own timer; the test of the deadline sets it.
        limits.deadline = 7_777
        change(&limits)
        let clock = HandClock()
        let wire = LoadWire(clock)
        guards.arm(clock, wire)
        return (LoadPacer(limits: limits, clock: clock), clock, wire)
    }

    private let guards = Guards()

    /// The hang guards of one test, cancelled as the test's value goes.
    private final class Guards: @unchecked Sendable {
        private let tasks = OSAllocatedUnfairLock(uncheckedState: [Task<Void, Never>]())
        private let tickets = OSAllocatedUnfairLock(uncheckedState: [LoadTicket]())

        /// A ticket a test will wait on: ended by the guard, with an end no load has, if the
        /// pacer never ends it — so a test waiting on it fails rather than parks.
        func watch(_ ticket: LoadTicket) { tickets.withLockUnchecked { $0.append(ticket) } }

        func arm(_ clock: HandClock, _ wire: LoadWire) {
            // **`[weak self]`, or the guard is never cancelled.** The task is what `deinit` below
            // cancels, and a task that holds `self` keeps `self` from ever reaching `deinit`: every
            // guard then ran its fifty seconds and recorded its issue against a test that had
            // passed. Nobody saw it where this target's tests are a process of their own that is
            // over in seconds; a runner that runs every target in one process, for longer than
            // fifty seconds, failed all of them.
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled else { return }
                Issue.record("watchdog let everything through; the test lost its synchronisation")
                clock.abandon()
                await wire.abandon()
                // After everything was let through and had its chance to end for itself.
                try? await Task.sleep(for: .seconds(1))
                for ticket in self?.tickets.withLockUnchecked({ $0 }) ?? [] { ticket.finish(.notTaken(.already)) }
            }
            tasks.withLockUnchecked { $0.append(task) }
        }

        deinit { for task in tasks.withLockUnchecked({ $0 }) { task.cancel() } }
    }

    /// Takes a load into the line — it is in, in the order asked, by the time this returns —
    /// and hands back its ticket.
    private func asking(_ pacer: LoadPacer, _ wire: LoadWire, _ id: String, of host: String = host) async throws -> LoadTicket {
        guard case .taken(let ticket) = await pacer.ask(host: host, id: id, wire.work(id)) else {
            Issue.record("\(id) was not taken")
            throw CancellationError()
        }
        guards.watch(ticket)
        return ticket
    }

    /// Why a load was not taken, or nothing where it was.
    private func refused(_ pacer: LoadPacer, _ wire: LoadWire, _ id: String, of host: String = host) async -> LoadEnd? {
        if case .not(let end) = await pacer.ask(host: host, id: id, wire.work(id)) { return end }
        return nil
    }

    @Test("The limits: one at a time, three seconds apart — a third of what a Mastodon allows by default — one stretch waiting, a try no longer than any read is given")
    func theLimits() {
        let limits = LoadLimits()
        #expect(limits.inFlight == 1)
        #expect(limits.interval == 3)
        // Twenty a minute is a hundred in five: a third of a Mastodon's default 300.
        #expect(5 * 60 / limits.interval == 300 / 3)
        #expect(limits.queued == MastodonReadOn.limit)
        #expect(limits.attempts == 3 && limits.failures == 5 && limits.backoff == 30 && limits.longestPause == 900)
        #expect(limits.perRun == 600 && limits.reserve == 0.25 && limits.deadline == 30)
    }

    // MARK: - The pace

    @Test("Loads of one source start no closer than the pace apart, in the order they were asked; turning the clock short of it starts nothing")
    func spacedApart() async throws {
        let (pacer, clock, wire) = made()
        var ends: [LoadTicket] = []
        for id in ["a", "b", "c"] { ends.append(try await asking(pacer, wire, id)) }
        await wire.asked(1)
        await clock.sleeping(for: Self.pace)
        #expect(await wire.ids == ["a"], "the first has nothing to wait for; the second waits")
        clock.advance(by: Self.pace - 1)
        #expect(await wire.ids == ["a"])
        #expect(clock.wakes == [1], "a second short is not the pace, and nothing of the first try is left on the clock")
        clock.advance(by: 1)
        await wire.asked(2)
        await clock.sleeping(for: Self.pace)
        clock.advance(by: Self.pace)
        await wire.asked(3)
        #expect(await wire.ids == ["a", "b", "c"])
        #expect(await wire.times == [0, Self.pace, 2 * Self.pace])
        for end in ends { #expect(await end.end() == .done) }
        #expect(await pacer.standing(host: Self.host).tried == 3)
    }

    @Test("The pace is one number: set to five seconds, loads start five seconds apart")
    func thePaceIsOneNumber() async throws {
        let (pacer, clock, wire) = made { $0.interval = 5 }
        var ends: [LoadTicket] = []
        for id in ["a", "b", "c"] { ends.append(try await asking(pacer, wire, id)) }
        for asked in 1...2 {
            await wire.asked(asked)
            await clock.sleeping(for: 5)
            clock.advance(by: 5)
        }
        for end in ends { #expect(await end.end() == .done) }
        #expect(await wire.times == [0, 5, 10])
    }

    @Test("Setting the date back makes no wait longer: the pace is counted in seconds that only pass")
    func theDateSetBack() async throws {
        let (pacer, clock, wire) = made()
        let ends = [try await asking(pacer, wire, "a"), try await asking(pacer, wire, "b")]
        await wire.asked(1)
        await clock.sleeping(for: Self.pace)
        clock.setDateBack(by: 86_400)
        clock.advance(by: Self.pace)
        for end in ends { #expect(await end.end() == .done) }
        #expect(await wire.times == [0, Self.pace])
    }

    @Test("One load of a source is on the wire at a time: while it is, no amount of time starts the next")
    func oneAtATime() async throws {
        let (pacer, clock, wire) = made()
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        await wire.asked(1)
        clock.advance(by: 600)
        let standing = await pacer.standing(host: Self.host)
        #expect(standing.onTheWire == 1 && standing.waiting == 1)
        #expect(await wire.ids == ["a"])
        await wire.release("a")
        #expect(await first.end() == .done)
        #expect(await second.end() == .done)
        #expect(await wire.times == [0, 600], "the pace had long passed: the second went as soon as the first was back")
    }

    @Test("Each source has its own line: one held on the wire holds up nothing asked of another")
    func perSource() async throws {
        let (pacer, _, wire) = made()
        await wire.hold("slow")
        let held = try await asking(pacer, wire, "slow", of: "slow.example")
        await wire.asked(1)
        #expect(await pacer.load(host: "quick.example", id: "q", wire.work("q")) == .done)
        #expect(await pacer.standing(host: "slow.example").onTheWire == 1)
        await wire.release("slow")
        #expect(await held.end() == .done)
    }

    // MARK: - The bounds

    @Test("The line never grows past its bound: a thousand asked at once leave one stretch waiting and one on the wire, and every other is told at once that it was not taken")
    func neverUnbounded() async throws {
        let (pacer, _, wire) = made()
        await wire.hold("0")
        let first = try await asking(pacer, wire, "0")
        await wire.asked(1)
        var waiting: [LoadTicket] = []
        var refusals = 0
        for id in 1..<1_000 {
            switch await pacer.ask(host: Self.host, id: "\(id)", wire.work("\(id)")) {
            case .taken(let ticket): waiting.append(ticket)
            case .not(let end):
                #expect(end == .notTaken(.full))
                refusals += 1
            }
        }
        let standing = await pacer.standing(host: Self.host)
        #expect(waiting.count == 40 && standing.waiting == 40 && standing.onTheWire == 1 && refusals == 959)
        #expect(await refused(pacer, wire, "7") == .notTaken(.already), "the same load is never in the line twice")
        #expect(await refused(pacer, wire, "0") == .notTaken(.already), "nor while it is on the wire")
        #expect(await wire.ids == ["0"], "and nothing that was not taken was asked")
        await pacer.letGo(host: Self.host)
        #expect(await first.end() == .letGo)
        for ticket in waiting { #expect(await ticket.end() == .letGo) }
        await wire.release("0")
    }

    @Test("A run asks one source only so many times, every try counted: past that a load is not taken, and one already taken is not tried again")
    func spentForTheRun() async throws {
        let (pacer, clock, wire) = made { $0.perRun = 4 }
        await wire.script("a", [.failed, .failed, .answered()])
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        // a: three tries, thirty then sixty seconds apart; b: the fourth.
        for (asked, wait) in [(1, 30.0), (2, 60), (3, Self.pace)] {
            await wire.asked(asked)
            await clock.sleeping(for: wait)
            // One try made and two loads waiting leave room for one more; two made, none.
            #expect(await refused(pacer, wire, "c") == (asked < 2 ? nil : .notTaken(.spent)), "tries made, counted with what is waiting")
            if asked < 2 { await pacer.withdraw(host: Self.host, id: "c") }
            clock.advance(by: wait)
        }
        #expect(await first.end() == .done)
        #expect(await second.end() == .done)
        #expect(await wire.ids == ["a", "a", "a", "b"])
        #expect(await pacer.standing(host: Self.host).tried == 4)
        #expect(await refused(pacer, wire, "c") == .notTaken(.spent), "three tries of one load are three of the run's share")
        #expect(await pacer.load(host: "two.example", id: "c", wire.work("c")) == .done, "another source's share is its own")
    }

    @Test("A load whose next try would be past the run's share is given up, not tried")
    func aRetryPastTheShare() async throws {
        let (pacer, clock, wire) = made { $0.perRun = 2 }
        await wire.script("a", [.failed])
        let end = try await asking(pacer, wire, "a")
        await wire.asked(1)
        await clock.sleeping(for: 30)
        clock.advance(by: 30)
        await wire.asked(2)
        await clock.sleeping(for: 60)
        clock.advance(by: 60)
        #expect(await end.end() == .gaveUp)
        #expect(await wire.ids == ["a", "a"], "the third try was never made")
    }

    // MARK: - The source's own word

    @Test("Told to slow down and when to ask again, the load is tried again then — not at the pace, not at the backoff — and ends done")
    func retryAfter() async throws {
        let (pacer, clock, wire) = made()
        await wire.script("a", [.slowDown(SourceWord(retryAfter: clock.wall().addingTimeInterval(90))), .answered()])
        let end = try await asking(pacer, wire, "a")
        await wire.asked(1)
        await clock.sleeping(for: 90)
        clock.advance(by: 89)
        #expect(await wire.ids == ["a"])
        clock.advance(by: 1)
        #expect(await end.end() == .done)
        #expect(await wire.times == [0, 90])
    }

    @Test("Told to slow down with no time given, or with one sooner than the backoff, the load waits the backoff")
    func slowDownWithoutATime() async throws {
        for sooner in [false, true] {
            let (pacer, clock, wire) = made()
            let word = sooner ? SourceWord(retryAfter: clock.wall().addingTimeInterval(5)) : nil
            await wire.script("a", [.slowDown(word), .answered()])
            let end = try await asking(pacer, wire, "a")
            await wire.asked(1)
            await clock.sleeping(for: 30)
            clock.advance(by: 30)
            #expect(await end.end() == .done)
            #expect(await wire.times == [0, 30])
        }
    }

    @Test("A source that says to wait longer than a load waits is taken at its word: it is not asked again this run, what was waiting is told, and nothing more is taken until the reader asks")
    func toldToWaitTooLong() async throws {
        let (pacer, clock, wire) = made()
        await wire.script("a", [.slowDown(SourceWord(retryAfter: clock.wall().addingTimeInterval(3_600)))])
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a")
        await wire.asked(1)
        let second = try await asking(pacer, wire, "b")
        await wire.release("a")
        #expect(await first.end() == .sourceGivenUp)
        #expect(await second.end() == .sourceGivenUp)
        #expect(await pacer.standing(host: Self.host).givenUp)
        clock.advance(by: 7_200)
        #expect(await refused(pacer, wire, "c") == .sourceGivenUp)
        #expect(await wire.ids == ["a"], "asked once, and never again")
        await pacer.readmit(host: Self.host)
        #expect(await pacer.load(host: Self.host, id: "c", wire.work("c")) == .done)
    }

    @Test("Where the source says how much of its allowance is left and little is, the next load waits for it to be renewed; with plenty left it keeps the pace")
    func allowance() async throws {
        let (pacer, clock, wire) = made()
        let reset = clock.wall().addingTimeInterval(200)
        await wire.script("a", [.answered(SourceWord(remaining: 75, limit: 300, reset: reset))])
        await wire.script("b", [.answered(SourceWord(remaining: 290, limit: 300, reset: reset.addingTimeInterval(300)))])
        var ends: [LoadTicket] = []
        for id in ["a", "b", "c"] { ends.append(try await asking(pacer, wire, id)) }
        await wire.asked(1)
        await clock.sleeping(for: 200)
        clock.advance(by: 199)
        #expect(await wire.ids == ["a"], "a quarter left: the rest is the reader's own reads'")
        clock.advance(by: 1)
        await wire.asked(2)
        await clock.sleeping(for: Self.pace)
        #expect(clock.wakes == [Self.pace], "plenty left: the pace, and nothing longer")
        clock.advance(by: Self.pace)
        for end in ends { #expect(await end.end() == .done) }
        #expect(await wire.times == [0, 200, 200 + Self.pace])
    }

    @Test("An allowance all but spent that renews further off than a load waits rests the source for the run: the answer that said so is taken, and nothing more is asked")
    func allowanceFarOff() async throws {
        let (pacer, clock, wire) = made()
        await wire.script("a", [.answered(SourceWord(remaining: 0, limit: 300, reset: clock.wall().addingTimeInterval(86_400)))])
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        #expect(await first.end() == .done)
        // Asked of the line before the ticket: were the source only resting, the second load
        // would be waiting and its end would not come.
        let rested = await pacer.standing(host: Self.host).givenUp
        #expect(rested)
        guard rested else { return }
        #expect(await second.end() == .sourceGivenUp)
        clock.advance(by: 900)
        #expect(await wire.ids == ["a"], "not asked again at the longest wait: the source said later than that")
        #expect(clock.wakes.isEmpty)
    }

    // MARK: - Failing

    @Test("A load that fails is tried again after a wait that doubles, three times in all, and then given up; the load behind it waits out the same quiet")
    func backsOffAndGivesUp() async throws {
        let (pacer, clock, wire) = made()
        await wire.script("a", [.failed])
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        await wire.asked(1)
        await clock.sleeping(for: 30)
        clock.advance(by: 29)
        #expect(await wire.ids == ["a"])
        clock.advance(by: 1)
        await wire.asked(2)
        await clock.sleeping(for: 60)
        clock.advance(by: 60)
        await wire.asked(3)
        #expect(await first.end() == .gaveUp)
        await clock.sleeping(for: 120)
        #expect(await pacer.standing(host: Self.host).failures == 3)
        clock.advance(by: 120)
        #expect(await second.end() == .done)
        #expect(await wire.ids == ["a", "a", "a", "b"])
        #expect(await wire.times == [0, 30, 90, 210])
        #expect(await pacer.standing(host: Self.host).failures == 0, "an answer is the source working again")
    }

    @Test("A source that fails five tries in a row is given up for the run: the load on the wire and every one waiting are told, and no more is asked of it")
    func givenUpForTheRun() async throws {
        let (pacer, clock, wire) = made()
        for id in ["a", "b", "c"] { await wire.script(id, [.failed]) }
        var ends: [LoadTicket] = []
        for id in ["a", "b", "c"] { ends.append(try await asking(pacer, wire, id)) }
        // a: three tries; b: two more makes five.
        for (tries, wait) in [(1, 30.0), (2, 60), (3, 120), (4, 240)] {
            await wire.asked(tries)
            await clock.sleeping(for: wait)
            clock.advance(by: wait)
        }
        await wire.asked(5)
        #expect(await ends[0].end() == .gaveUp)
        #expect(await ends[1].end() == .sourceGivenUp)
        #expect(await ends[2].end() == .sourceGivenUp, "never asked: the source was given up while it waited")
        #expect(await wire.ids == ["a", "a", "a", "b", "b"])
        #expect(await refused(pacer, wire, "d") == .sourceGivenUp)
        #expect(clock.wakes.isEmpty, "and nothing is left waiting to try")
    }

    @Test("A try that never comes back is a failed try at the deadline: the slot is free, the load is tried again and then given up, and the next load goes — while the first request is still open")
    func aTryThatNeverReturns() async throws {
        let (pacer, clock, wire) = made { $0.deadline = LoadLimits().deadline }
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        // Three tries of thirty seconds each, with the backoff between.
        for (asked, backoff) in [(1, 30.0), (2, 60), (3, 120)] {
            await wire.asked(asked)
            await clock.sleeping(for: 30)
            #expect(await pacer.standing(host: Self.host).onTheWire == 1)
            clock.advance(by: 30)
            await clock.sleeping(for: backoff)
            #expect(await pacer.standing(host: Self.host).onTheWire == 0, "the slot is free at the deadline")
            clock.advance(by: backoff)
        }
        #expect(await first.end() == .gaveUp)
        #expect(await second.end() == .done)
        #expect(await wire.ids == ["a", "a", "a", "b"])
        #expect(await wire.times == [0, 60, 150, 300])
        // Nothing was ever let through: the three requests are still open, and nobody waits on them.
        await wire.abandon()
    }

    // MARK: - Let go, taken back, moved forward

    @Test("Letting a source go ends what waits and what is on the wire at once — nobody waits for a request that may never come back — and forgets what was known of it: added again, it is asked from the start")
    func letGo() async throws {
        let (pacer, clock, wire) = made()
        await wire.script("a", [.failed, .answered()])
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a"), second = try await asking(pacer, wire, "b")
        await wire.asked(1)
        await pacer.letGo(host: Self.host)
        #expect(await second.end() == .letGo)
        #expect(await first.end() == .letGo, "ended while its request is still out")
        #expect(await pacer.standing(host: Self.host) == LoadStanding())
        await wire.release("a")
        #expect(await pacer.load(host: Self.host, id: "b", wire.work("b")) == .done, "a new line: no quiet carried over, nothing counted")
        let standing = await pacer.standing(host: Self.host)
        #expect(standing.tried == 1 && standing.failures == 0, "the late answer landed nowhere: not as a failure, not as a try to repeat")
        #expect(clock.wakes.isEmpty)
    }

    @Test("Letting a source go while its next load waits its turn wakes nothing later: the wait ends with the line")
    func letGoWhileWaitingItsTurn() async throws {
        let (pacer, clock, wire) = made()
        let ends = [try await asking(pacer, wire, "a"), try await asking(pacer, wire, "b")]
        await wire.asked(1)
        await clock.sleeping(for: Self.pace)
        await pacer.letGo(host: Self.host)
        #expect(await ends[0].end() == .done)
        #expect(await ends[1].end() == .letGo)
        clock.advance(by: 3_600)
        #expect(await wire.ids == ["a"])
        #expect(await pacer.standing(host: "ONE.example") == LoadStanding(), "and a host is one host however it is spelled")
    }

    @Test("A waiting load can be taken back: it is never asked; one on the wire, or one not there, cannot")
    func withdrawn() async throws {
        let (pacer, clock, wire) = made()
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a")
        let second = try await asking(pacer, wire, "b"), third = try await asking(pacer, wire, "c")
        await wire.asked(1)
        #expect(await pacer.withdraw(host: Self.host, id: "b"))
        #expect(await second.end() == .withdrawn)
        #expect(await !pacer.withdraw(host: Self.host, id: "a"), "already asked: it runs to its end")
        #expect(await !pacer.withdraw(host: Self.host, id: "b"))
        #expect(await !pacer.withdraw(host: Self.host, id: "nobody"))
        #expect(await pacer.standing(host: Self.host).waiting == 1)
        clock.advance(by: Self.pace)
        await wire.release("a")
        #expect(await first.end() == .done)
        #expect(await third.end() == .done)
        #expect(await wire.ids == ["a", "c"])
        #expect(await refused(pacer, wire, "b") == nil, "taken back, it can be asked for again")
    }

    @Test("Whoever waits for a load and is cancelled takes it back with them, where it has not been asked yet")
    func theWaiterCancelled() async throws {
        let (pacer, _, wire) = made()
        await wire.hold("a")
        let first = try await asking(pacer, wire, "a")
        await wire.asked(1)
        let waiter = Task { await pacer.load(host: Self.host, id: "b", wire.work("b")) }
        waiter.cancel()
        #expect(await waiter.value == .withdrawn)
        #expect(await pacer.standing(host: Self.host).waiting == 0)
        await wire.release("a")
        #expect(await first.end() == .done)
        #expect(await wire.ids == ["a"], "and it was never asked")
    }

    @Test("A waiting load can be moved to the front: it is the next asked, at the same pace; the rest keep their order")
    func promoted() async throws {
        let (pacer, clock, wire) = made()
        await wire.hold("a")
        var ends = [try await asking(pacer, wire, "a")]
        for id in ["b", "c", "d"] { ends.append(try await asking(pacer, wire, id)) }
        await wire.asked(1)
        #expect(await pacer.promote(host: Self.host, id: "d"))
        #expect(await !pacer.promote(host: Self.host, id: "a"))
        #expect(await !pacer.promote(host: Self.host, id: "nobody"))
        #expect(await pacer.standing(host: Self.host).waiting == 3, "moved, not added")
        await wire.release("a")
        for asked in 2...4 {
            await clock.sleeping(for: Self.pace)
            clock.advance(by: Self.pace)
            await wire.asked(asked)
        }
        for end in ends { #expect(await end.end() == .done) }
        #expect(await wire.ids == ["a", "d", "b", "c"])
        #expect(await wire.times == [0, Self.pace, 2 * Self.pace, 3 * Self.pace], "going first is not going faster")
    }

    @Test("The system's clock for the pacer counts seconds that only pass, and a wait until a moment already past returns at once")
    func theSystemClock() async throws {
        let clock = SystemPacerClock()
        let before = clock.elapsed()
        try await clock.sleep(until: before - 5)
        try await clock.sleep(until: 0)
        #expect(clock.elapsed() >= before && before >= 0)
        #expect(abs(clock.wall().timeIntervalSinceNow) < 5)
    }

    // MARK: - Reading the source's word

    @Test("A source's word is read off its headers leniently: seconds or a date to ask again after, what is left of an allowance and when it renews; anything else is no word")
    func readingHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func word(_ headers: [String: String]) -> SourceWord? {
            let response = HTTPURLResponse(url: URL(string: "https://one.example/x")!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
            return SourceWord(response, now: now)
        }
        #expect(word(["Retry-After": "120"])?.retryAfter == now.addingTimeInterval(120))
        #expect(word(["Retry-After": " 7 "])?.retryAfter == now.addingTimeInterval(7))
        #expect(word(["Retry-After": "-5"])?.retryAfter == now, "a time already past is now")
        #expect(word(["Retry-After": "Sat, 15 Jan 2028 08:00:30 GMT"])?.retryAfter == Date(timeIntervalSince1970: 1_831_536_030))
        #expect(word(["Retry-After": "soon"]) == nil && word(["Retry-After": "inf"]) == nil && word(["Retry-After": "nan"]) == nil)
        #expect(word([:]) == nil)
        let mastodon = try #require(word([
            "X-RateLimit-Limit": "300", "X-RateLimit-Remaining": "12", "X-RateLimit-Reset": "2027-01-15T08:05:00.000000Z",
        ]))
        #expect(mastodon.limit == 300 && mastodon.remaining == 12 && mastodon.retryAfter == nil)
        #expect(mastodon.reset == ISO8601DateFormatter().date(from: "2027-01-15T08:05:00Z"))
        #expect(word(["X-RateLimit-Reset": "45"])?.reset == now.addingTimeInterval(45))
        #expect(word(["X-RateLimit-Reset": "1800000300"])?.reset == Date(timeIntervalSince1970: 1_800_000_300))
        #expect(word(["X-RateLimit-Remaining": "many", "X-RateLimit-Limit": "300"]) == nil)
    }
}
