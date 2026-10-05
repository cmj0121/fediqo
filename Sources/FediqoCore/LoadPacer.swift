import Foundation
import os

// How fast a source is asked for what an item refers to (#293).
//
// A timeline is read because the reader asked, or on the wait they chose. What an item refers
// to is read because the item arrived — nobody pressed anything — and one stretch can refer to
// forty posts this device does not hold. Left to itself that is forty requests the moment a
// timeline lands, of a server somebody else pays for, set off by whoever wrote the stretch. So
// every such load goes through here, and here is where it waits its turn.
//
// **Loads only.** Timeline reads, reading on, acts and signing in are the reader's own and are
// not paced by this; see `LoadLimits` for what putting them behind it would take.
//
// **Per source.** Each source has its own line, its own clock and its own standing: one slow or
// refusing server holds up nothing asked of another.

/// Time as the pacer counts it — handed in, so a test turns the hands itself.
///
/// **A clock that only goes forward.** Every wait here is an interval: between two loads, after
/// a failure, until a source's allowance renews. Counted on the date, a wait would stretch by
/// however far somebody set the system clock back. So intervals are counted in seconds that
/// only pass (`elapsed`), and the date is asked for one thing alone: to turn a moment a source
/// states — "ask again after this date" — into how long from now that is (`wall`).
public protocol PacerClock: Sendable {
    /// Seconds passed since this clock began, never going back.
    func elapsed() -> TimeInterval
    /// Returns once `elapsed()` has reached `moment`. Throws where the task was cancelled.
    func sleep(until moment: TimeInterval) async throws
    /// The date now, for reading a source's stated date as an interval. Nothing waits on it.
    func wall() -> Date
}

/// The system's clocks: the continuous one for intervals, the date for a source's dates.
public struct SystemPacerClock: PacerClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func elapsed() -> TimeInterval {
        let passed = origin.duration(to: .now).components
        return Double(passed.seconds) + Double(passed.attoseconds) / 1e18
    }

    public func sleep(until moment: TimeInterval) async throws {
        try await Task.sleep(until: origin.advanced(by: .seconds(moment)), clock: .continuous)
    }

    public func wall() -> Date { Date() }
}

/// The bounds one source's loads are held to.
///
/// **Three seconds between two loads starting, one at a time** — the person's figure (#293).
/// That is about twenty a minute at the very most: a hundred in five minutes, a third of what
/// a Mastodon allows a reader by default (300 requests in five minutes), so two thirds are
/// left for what the reader asks for themselves. And where a source states its allowance,
/// loads stop of themselves once a quarter or less of it is left (`reserve`), until it renews.
///
/// **What putting other reads behind this would take**: a timeline read is several requests the
/// reader is waiting on, in order, with a deadline and a line of its own on screen — it would
/// need a way to go to the front, to hold a turn across its stretches, and to count against the
/// source's stated allowance without being delayed by loads. None of that is here.
public struct LoadLimits: Sendable, Equatable {
    /// **A bound on loads on the wire**: how many of one source's may be out at once.
    public var inFlight = 1
    /// **A bound on how often a try starts**: the least time, in seconds, between two tries of
    /// one source starting — a first try or a later one alike. The one figure the pace is.
    public var interval: TimeInterval = 3
    /// **A bound on loads waiting**: how many of one source's may wait their turn. One
    /// stretch's worth: a full line means the next is not taken, and whoever asked keeps it.
    public var queued = MastodonReadOn.limit
    /// **A bound on tries of one load**: after this many it is given up for the run.
    public var attempts = 3
    /// **A bound on tries failing in a row, of one source**: after this many the source is given
    /// up for the run. An answer in between starts the count again.
    public var failures = 5
    /// **A bound on how long one try may take**, in seconds, on the pacer's own clock: past it
    /// the try is a failed one and the source's slot is free again, whatever became of the
    /// request. The same thirty seconds every other read here is given (`ShellReload.deadline`).
    public var deadline: TimeInterval = 30
    /// How long a source is left alone after one failed try; doubled for each further one in a row.
    public var backoff: TimeInterval = 30
    /// **A bound on any one wait**: the longest a source is left alone and then asked again. A
    /// source that says to wait longer — by a time to ask again after, or by an allowance that
    /// renews later than this — is taken at its word: it is not asked again this run.
    public var longestPause: TimeInterval = 15 * 60
    /// Where a source states an allowance, the share of it left at which loads stop until it is
    /// renewed — so loads never spend what the reader's own reads would need.
    public var reserve = 0.25
    /// **A bound on requests, not on loads**: how many tries of one source may start in one run
    /// of the app, every try of every load counted. At the pace above that is half an hour of
    /// asking without a pause — and a count, not a time: it is the ceiling on what a source can
    /// be made to answer by what it sends, whatever the pace, so a faster pace reaches it sooner
    /// and does not raise it.
    public var perRun = 600

    public init() {}
}

/// What a source said about how often it may be asked, read off one answer's headers.
public struct SourceWord: Sendable, Equatable {
    /// When the source said to ask again (`Retry-After`), as seconds or as a date.
    public var retryAfter: Date?
    /// How many requests it says are left before `reset`, and of how many.
    public var remaining: Int?
    public var limit: Int?
    public var reset: Date?

    public init(retryAfter: Date? = nil, remaining: Int? = nil, limit: Int? = nil, reset: Date? = nil) {
        self.retryAfter = retryAfter
        self.remaining = remaining
        self.limit = limit
        self.reset = reset
    }

    /// The word in `response`'s headers, or nothing where it carries none this reads.
    ///
    /// **Read leniently and believed narrowly.** A header that is not a number or a date is no
    /// word. A number of seconds is taken from `now`; a negative one, or a date already past,
    /// is now. Nothing here is trusted to be near: how long a source may make a load wait is
    /// `LoadLimits.longestPause`'s to bound.
    public init?(_ response: HTTPURLResponse, now: Date) {
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces)
        }
        if let after = header("Retry-After") {
            if let seconds = Double(after), seconds.isFinite {
                retryAfter = now.addingTimeInterval(max(0, seconds))
            } else if let date = Self.httpDate(after) ?? Self.isoDate(after) {
                retryAfter = max(now, date)
            }
        }
        remaining = header("X-RateLimit-Remaining").flatMap(Int.init)
        limit = header("X-RateLimit-Limit").flatMap(Int.init)
        if let at = header("X-RateLimit-Reset") {
            if let date = Self.isoDate(at) ?? Self.httpDate(at) {
                reset = date
            } else if let seconds = Double(at), seconds.isFinite {
                // Some servers send seconds from now, some the moment as a Unix time.
                reset = seconds > 1_000_000_000 ? Date(timeIntervalSince1970: seconds) : now.addingTimeInterval(max(0, seconds))
            }
        }
        if retryAfter == nil, remaining == nil, reset == nil { return nil }
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// How a source answered one try of a load, as whoever made the request reports it.
public enum LoadAnswer: Sendable, Equatable {
    /// The source answered the question — with the item, or by saying there is none (404, 410).
    /// Either is the source working: nothing is tried again.
    case answered(SourceWord? = nil)
    /// The source said to slow down (429, or 503 with a wait): the try did not count as asked.
    case slowDown(SourceWord? = nil)
    /// Nothing usable came: no network, a timeout, a server error.
    case failed
}

/// How a load ended.
public enum LoadEnd: Sendable, Equatable {
    /// The source answered.
    case done
    /// Tried as often as a load is, and given up for the run.
    case gaveUp
    /// The source itself is given up for the run: it failed too often in a row, or said to wait
    /// longer than a load waits.
    case sourceGivenUp
    /// Not taken, and so not asked: the caller still has it to ask later.
    case notTaken(NotTaken)
    /// The source was let go of — removed, cleared, signed out — while this waited or ran.
    case letGo
    /// Taken back by whoever asked, while it waited: never asked.
    case withdrawn

    public enum NotTaken: Sendable, Equatable {
        /// As many are waiting as may wait.
        case full
        /// The same load is already waiting or on the wire.
        case already
        /// As many tries have started this run as may.
        case spent
    }
}

/// A value settled once and waited for by anybody: the first word stands.
final class Once<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func value() async -> Value {
        await withCheckedContinuation { waiter in
            let settled = state.withLockUnchecked { state -> Value? in
                if let value = state.value { return value }
                state.waiters.append(waiter)
                return nil
            }
            if let settled { waiter.resume(returning: settled) }
        }
    }

    func settle(_ value: Value) {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Value, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }
}

/// One load taken into a source's line: how it ends is asked of this.
public final class LoadTicket: Sendable {
    private let ended = Once<LoadEnd>()

    init() {}

    /// How the load ended, once it has.
    public func end() async -> LoadEnd { await ended.value() }

    /// Ends the load. Once: a second word changes nothing.
    func finish(_ end: LoadEnd) { ended.settle(end) }
}

/// Whether a load was taken into the line.
public enum LoadAsked: Sendable {
    /// Taken: it will be asked when its turn comes, and its ticket says how that ended.
    case taken(LoadTicket)
    /// Not taken, and why — `.notTaken`, or `.sourceGivenUp`. Nothing was or will be asked.
    case not(LoadEnd)
}

/// Where one source's loads stand. For a screen and a test to read.
public struct LoadStanding: Sendable, Equatable {
    public var waiting = 0
    public var onTheWire = 0
    /// How many tries have started this run — what `LoadLimits.perRun` bounds.
    public var tried = 0
    /// How many seconds more it is left alone: between two tries, after a failure, or at the
    /// source's word. Nothing where it may be asked now.
    public var quietFor: TimeInterval?
    public var givenUp = false
    /// How many tries have failed in a row.
    public var failures = 0

    public init(
        waiting: Int = 0, onTheWire: Int = 0, tried: Int = 0, quietFor: TimeInterval? = nil, givenUp: Bool = false,
        failures: Int = 0
    ) {
        self.waiting = waiting
        self.onTheWire = onTheWire
        self.tried = tried
        self.quietFor = quietFor
        self.givenUp = givenUp
        self.failures = failures
    }
}

/// One line per source for what items refer to.
public actor LoadPacer {
    public let limits: LoadLimits
    private let clock: any PacerClock

    private struct Job {
        let id: String
        let work: @Sendable () async -> LoadAnswer
        let end: LoadTicket
        var tries = 0
    }

    private struct Line {
        var waiting: [Job] = []
        /// What is on the wire, kept so letting the source go can end it at once.
        var running: [String: Job] = [:]
        var workers: [UUID: Task<Void, Never>] = [:]
        var tried = 0
        var nextStart: TimeInterval?
        var quietUntil: TimeInterval?
        var failures = 0
        var givenUp = false
        /// A number no other line has had: a try that comes back to an older one lands nowhere.
        var generation = 0
    }

    private var lines: [String: Line] = [:]
    /// Counts the lines ever made.
    private var generations = 0

    public init(limits: LoadLimits = LoadLimits(), clock: any PacerClock = SystemPacerClock()) {
        self.limits = limits
        self.clock = clock
    }

    /// Takes one thing to ask `host` for when its turn comes. `id` names the load within its
    /// source, so the same one is never in the line twice. `work` makes the request and reports
    /// how the source answered; it is called once per try.
    ///
    /// Answers at once: taken, with a ticket that says how it ends — or not taken, because the
    /// line is full, the load is already there, the run's share is spent, or the source is
    /// given up. What is not taken is not asked, and whoever asked still has it to ask later.
    public func ask(host raw: String, id: String, _ work: @escaping @Sendable () async -> LoadAnswer) -> LoadAsked {
        let host = raw.lowercased()
        var line = lines[host] ?? Line()
        if line.givenUp { return .not(.sourceGivenUp) }
        if line.running[id] != nil || line.waiting.contains(where: { $0.id == id }) { return .not(.notTaken(.already)) }
        if line.tried + line.waiting.count >= limits.perRun { return .not(.notTaken(.spent)) }
        if line.waiting.count >= limits.queued { return .not(.notTaken(.full)) }
        let ticket = LoadTicket()
        line.waiting.append(Job(id: id, work: work, end: ticket))
        lines[host] = line
        staff(host)
        return .taken(ticket)
    }

    /// `ask`, waited for: how the load ended, or why it was not taken. **Whoever is waiting and
    /// is cancelled takes the load back** where it has not been asked yet (`withdraw`); one
    /// already on the wire runs to its end.
    public func load(host: String, id: String, _ work: @escaping @Sendable () async -> LoadAnswer) async -> LoadEnd {
        switch ask(host: host, id: id, work) {
        case .not(let end):
            return end
        case .taken(let ticket):
            return await withTaskCancellationHandler {
                await ticket.end()
            } onCancel: {
                Task { await self.withdraw(host: host, id: id) }
            }
        }
    }

    /// Takes one waiting load back: it is never asked, and ends `.withdrawn`. Whether there was
    /// one — a load already on the wire is not taken back, and runs to its end.
    @discardableResult
    public func withdraw(host raw: String, id: String) -> Bool {
        let host = raw.lowercased()
        guard let at = lines[host]?.waiting.firstIndex(where: { $0.id == id }) else { return false }
        lines[host]?.waiting.remove(at: at).end.finish(.withdrawn)
        return true
    }

    /// Moves one waiting load to the front of its source's line: the next to be asked, at the
    /// pace every load keeps. Whether there was one to move. For what the reader is looking at
    /// now, which should not wait behind what they scrolled past.
    @discardableResult
    public func promote(host raw: String, id: String) -> Bool {
        let host = raw.lowercased()
        guard var line = lines[host], let at = line.waiting.firstIndex(where: { $0.id == id }) else { return false }
        line.waiting.insert(line.waiting.remove(at: at), at: 0)
        lines[host] = line
        return true
    }

    /// Lets go of everything waiting or on the wire for `host`, and of what was known of it: the
    /// source was removed, cleared or signed out. Each of its loads ends `.letGo` **now** — the
    /// one on the wire too, whose request is cancelled and whose answer, whenever it comes,
    /// lands nowhere. A source added again starts a new line.
    public func letGo(host raw: String) {
        let host = raw.lowercased()
        guard let line = lines.removeValue(forKey: host) else { return }
        for job in line.waiting { job.end.finish(.letGo) }
        for job in line.running.values { job.end.finish(.letGo) }
        for worker in line.workers.values { worker.cancel() }
    }

    /// Lets a source that was given up for the run be asked again: the reader asked.
    public func readmit(host raw: String) {
        let host = raw.lowercased()
        guard var line = lines[host], line.givenUp else { return }
        line.givenUp = false
        line.failures = 0
        line.quietUntil = nil
        lines[host] = line
        staff(host)
    }

    /// What some other read of `host` heard the source say about how often it may be asked — a
    /// timeline read told to slow down, an answer's rate headers. **Loads give way to it**: the
    /// source's line is left alone until the moment it named, or until its allowance is
    /// renewed, exactly as if a load had been told. It counts as no failure: nothing of the
    /// line was asked. A wait longer than a load waits gives the source up for the run.
    public func heard(host: String, _ answer: HTTPURLResponse) {
        heard(host: host, slowDown: answer.statusCode == 429, SourceWord(answer, now: clock.wall()))
    }

    /// `heard(host:_:)`, with the answer already read: whether it said to slow down, and its word.
    public func heard(host raw: String, slowDown: Bool, _ word: SourceWord?) {
        let host = raw.lowercased()
        var line = lines[host] ?? Line()
        guard !line.givenUp else { return }
        let now = clock.elapsed()
        func moment(_ date: Date?) -> TimeInterval? {
            date.map { now + max(0, $0.timeIntervalSince(clock.wall())) }
        }
        var until: TimeInterval?
        if slowDown {
            until = moment(word?.retryAfter) ?? moment(word?.reset) ?? now + limits.backoff
        } else if let word, let remaining = word.remaining, let renewed = moment(word.reset), renewed > now {
            let floor = word.limit.map { Int((Double($0) * limits.reserve).rounded(.up)) } ?? 1
            if remaining <= max(1, floor) { until = renewed }
        }
        guard let until else { return }
        if until - now > limits.longestPause {
            giveUp(&line, host)
            return
        }
        line.quietUntil = max(line.quietUntil ?? until, until)
        lines[host] = line
    }

    public func standing(host raw: String) -> LoadStanding {
        guard let line = lines[raw.lowercased()] else { return LoadStanding() }
        let quiet = [line.nextStart, line.quietUntil].compactMap { $0 }.max().map { $0 - clock.elapsed() }
        return LoadStanding(
            waiting: line.waiting.count, onTheWire: line.running.count, tried: line.tried,
            quietFor: quiet.flatMap { $0 > 0 ? $0 : nil }, givenUp: line.givenUp, failures: line.failures
        )
    }

    // MARK: - The line

    /// Puts as many workers on `host`'s line as it may have and has work for.
    private func staff(_ host: String) {
        guard var line = lines[host] else { return }
        if line.generation == 0 {
            generations += 1
            line.generation = generations
        }
        // A worker for each load that could start now, and never more than may be on the wire.
        while line.workers.count < max(1, limits.inFlight), line.workers.count - line.running.count < line.waiting.count {
            let worker = UUID()
            let generation = line.generation
            line.workers[worker] = Task { await self.work(host, as: worker, generation: generation) }
        }
        lines[host] = line
    }

    private func current(_ host: String, _ generation: Int) -> Bool {
        lines[host]?.generation == generation
    }

    /// One worker: waits for the line's turn, takes the next load, tries it, and reads the answer.
    private func work(_ host: String, as worker: UUID, generation: Int) async {
        while current(host, generation), let waiting = lines[host], !waiting.waiting.isEmpty, !waiting.givenUp {
            // Wait for the turn, and look at everything again after: the source may have said
            // to wait longer, or the load been taken back, while this slept.
            if let until = [waiting.nextStart, waiting.quietUntil].compactMap({ $0 }).max(), until > clock.elapsed() {
                do { try await clock.sleep(until: until) } catch { break }
                continue
            }
            guard !Task.isCancelled, var line = lines[host] else { break }
            var job = line.waiting.removeFirst()
            // Every try counts against the run's share, a later one as a first one.
            guard line.tried < limits.perRun else {
                lines[host] = line
                job.end.finish(job.tries == 0 ? .notTaken(.spent) : .gaveUp)
                continue
            }
            job.tries += 1
            line.tried += 1
            line.running[job.id] = job
            line.nextStart = clock.elapsed() + limits.interval
            lines[host] = line

            let answer = await attempt(job.work)

            // Let go of meanwhile: the ticket was ended there, and this answer lands nowhere.
            guard current(host, generation), lines[host]?.running.removeValue(forKey: job.id) != nil else { return }
            settle(job, answer, on: host)
        }
        lines[host]?.workers[worker] = nil
        // Work may have come in while this one was leaving.
        if current(host, generation), lines[host]?.waiting.isEmpty == false, lines[host]?.givenUp == false { staff(host) }
    }

    /// One try, held to `LoadLimits.deadline` on the pacer's clock. **The request is raced, not
    /// waited for**: a try that never returns — a server holding the connection open — is a
    /// failed try at the deadline, its task is cancelled and left behind, and the source's slot
    /// is free. Whatever it answers later is nobody's.
    private func attempt(_ work: @escaping @Sendable () async -> LoadAnswer) async -> LoadAnswer {
        let first = Once<LoadAnswer>()
        let asking = Task { first.settle(await work()) }
        let until = clock.elapsed() + limits.deadline
        let clock = self.clock
        let timer = Task {
            guard (try? await clock.sleep(until: until)) != nil else { return }
            first.settle(.failed)
        }
        let answer = await withTaskCancellationHandler {
            await first.value()
        } onCancel: {
            first.settle(.failed)
        }
        asking.cancel()
        timer.cancel()
        // The timer ends at once when cancelled, so nothing of this try is still on the clock
        // by the time the line moves on.
        await timer.value
        return answer
    }

    /// Reads one try's answer into the line's standing, and ends the load or puts it back.
    private func settle(_ job: Job, _ answer: LoadAnswer, on host: String) {
        guard var line = lines[host] else { return }
        let now = clock.elapsed()
        /// A date the source stated, as a moment on the pacer's clock.
        func moment(_ date: Date?) -> TimeInterval? {
            date.map { now + max(0, $0.timeIntervalSince(clock.wall())) }
        }
        switch answer {
        case .answered(let word):
            line.failures = 0
            // Where the source states an allowance and little of it is left, loads stop until
            // it is renewed: what is left is the reader's own reads'. Renewed within the
            // longest wait, the line waits for it; later than that, the source is taken at its
            // word as one that says to wait too long is — no more is asked of it this run.
            if let word, let remaining = word.remaining, let renewed = moment(word.reset), renewed > now {
                let floor = word.limit.map { Int((Double($0) * limits.reserve).rounded(.up)) } ?? 1
                if remaining <= max(1, floor) {
                    if renewed - now > limits.longestPause {
                        giveUp(&line, host)
                        job.end.finish(.done)
                        return
                    }
                    line.quietUntil = max(line.quietUntil ?? renewed, renewed)
                }
            }
            lines[host] = line
            job.end.finish(.done)
        case .slowDown, .failed:
            line.failures += 1
            var said: TimeInterval?
            if case .slowDown(let word) = answer { said = moment(word?.retryAfter) ?? moment(word?.reset) }
            let backoff = now + limits.backoff * pow(2, Double(line.failures - 1))
            let until = max(said ?? backoff, backoff)
            let tooLong = said.map { $0 - now > limits.longestPause } ?? false
            if line.failures >= limits.failures || tooLong {
                giveUp(&line, host)
                job.end.finish(.sourceGivenUp)
                return
            }
            let bounded = min(until, now + limits.longestPause)
            line.quietUntil = max(line.quietUntil ?? bounded, bounded)
            if job.tries >= limits.attempts {
                lines[host] = line
                job.end.finish(.gaveUp)
            } else {
                line.waiting.insert(job, at: 0)
                lines[host] = line
            }
        }
    }

    /// Gives `host` up for the run: every load waiting is told, and nothing more is taken for
    /// it until the reader asks again (`readmit`).
    private func giveUp(_ line: inout Line, _ host: String) {
        line.givenUp = true
        let waiting = line.waiting
        line.waiting = []
        lines[host] = line
        for other in waiting { other.end.finish(.sourceGivenUp) }
    }
}
