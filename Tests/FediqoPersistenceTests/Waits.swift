import Foundation
import Testing

// What a check waits with (#346). A wait says what it waits for, and gives up where that can no
// longer happen — the work it waited on has ended without it — and never because some number of
// seconds went by: a bound in seconds is a guess about a machine, and a machine slow or busy
// enough makes the guess wrong with nothing the matter.
//
// **The same text in every test target.** One test target cannot import another's fixtures, so
// this file is in each of them, whole. It imports nothing of the app for that reason, and
// `WaitsTests` reads the copies and fails where one of them has been changed alone. The copies
// are one text and, in a run, one list of waits: see `RunWaits.processWide`.
//
// **How a check is written with it, and how an older one is brought over.**
//
// - A gate the check holds: `let guardTask = watching(gate, "the boost, held on the wire")` and
//   `defer { guardTask.cancel() }` — what `hangGuard(gate)` was, with a name.
// - Waiting for a thing: `await met("the reload is on the wire", by: running) { await http.asks == 1 }`
//   — what `#expect(await spun { … })` was. **Name `by:` wherever a `Task`, or anything else that
//   is an `Ending`, stands for the work**: the wait then fails the moment that work has ended
//   without the thing. **Leave `by:` out only where nothing can be named** — a hosted view's own
//   `.task`, a run loop the check turns itself — and know what that costs: such a wait has
//   nothing to give up by, and a broken line fails it only when the run has gone still, minutes
//   later.
// - A loop that sleeps and looks again is the same `met`, the look as its condition.
// - A sleep after which nothing is to have happened, or a deadline the check raced: the app is
//   handed `clock.sleep` of a `TurnedClock` through its `sleep:` seam, the check waits with `met`
//   until `clock.sleeping == 1`, and then turns it. "Nothing happened" is then "it looked again
//   and is asleep again".
// - A run loop turned by hand goes inside the condition: `await met("the row is drawn") {
//   settle(view); return … }`, the turn itself made with `before: .distantPast`, not for ten
//   milliseconds.
// - `.timeLimit` becomes `.watched`. **Every suite a conversion touches is `.watched`**, on the
//   suite: a check parked where no helper of this file is — awaiting the very call it checks —
//   is named by nothing else.
//
// **The seams the app is given for it** are a defaulted `sleep:` in the shape of
// `ShellReload.keepAsking`'s, with what the app does unchanged. Where the function is `public`
// (`StoreSaver.flush`, `NearbyMove.init`) the new parameter goes on a `package` overload and the
// public one forwards to it: nothing becomes more public. `Deadline`'s clock is a stored
// property on the two places that build one, and not a parameter through every `within:`.
//
// **`FEDIQO_WAITS_STILL`**, in seconds, is how long the run may be still before its waits are let
// go — five minutes where it is not said. It is for a person who has broken a line on purpose,
// or is looking for a hang, and would rather wait ten seconds than five minutes to be told. One
// second at the least; anything that is not a number of seconds is not listened to.

// MARK: - The run's own bound

/// Every wait a check is parked on, and the one bound left that is a clock.
///
/// **Counted from the last time anything moved, not from when a wait began.** A wait that sits
/// behind everything else on the main actor answers when the whole run does, so a bound counted
/// from its own start is a bound on the length of the run — which is how fifty seconds, and then
/// a hundred and seventy, came to fail checks that were right. What is counted here is how long
/// *no* wait in the run has been entered or left: a run that is slow goes on moving, and only one
/// that has stopped goes still.
///
/// **Counted in looks that were made, not in time that went by.** A thread wakes every `tick`
/// and counts one more look in which nothing had moved. A machine put to sleep, or a process
/// stopped in a debugger, makes no looks — so an hour of either is not an hour of stillness, as
/// it would be to a clock read before and after.
///
/// **What it does when the run has gone still**, in two steps:
///
/// 1. Every wait still parked is written to the run's output — what each waits for, where, and
///    in which check — and then let go: each gives up, records that against its own check at its
///    own line, and the check goes on to fail in the ordinary way. A check under `.watched` is
///    cancelled, as a time limit would cancel it.
/// 2. Where a wait was let go and is parked still when the run has been still that long again,
///    nothing in this process is going to end it — a main actor that is blocked, a continuation
///    nobody holds. The list is written once more and the run is ended, because a run that hangs
///    says nothing at all, and the list is all that will ever be known of it.
///
/// **A thread of its own**, not a task: what it watches for is a run in which tasks have stopped
/// getting turns.
///
/// **What it keeps is kept in Foundation's own objects**, not in Swift ones, for `processWide`'s
/// reason: each test target's copy of this class is a class of its own, and they must all read
/// one list.
final class RunWaits: @unchecked Sendable {
    /// The run's. Every helper below parks here unless a check of the helpers themselves hands
    /// in one of its own.
    static let run = RunWaits(still: patience, keptIn: processWide())

    /// How long the run may be still: five minutes, or `FEDIQO_WAITS_STILL` (the head of this
    /// file).
    static var patience: Duration { patience(said: ProcessInfo.processInfo.environment["FEDIQO_WAITS_STILL"]) }

    static func patience(said: String?) -> Duration {
        guard let seconds = said.flatMap(Double.init), seconds.isFinite, seconds > 0 else { return .seconds(300) }
        return .seconds(max(seconds, 1))
    }

    /// The one list of a whole run, whichever copy of this file asks for it.
    ///
    /// **A run is a process, and a process may hold every test target.** Some toolchains build
    /// one bundle of them all. Three lists there would be three runs to each other: a check of
    /// one target, queued behind another target's work, would see nothing move in *its* list for
    /// the whole bound and be let go with nothing wrong, and step 2 would then end everybody's
    /// run on one target's word. So the list hangs from something every copy can reach by a
    /// name — the process's own `ProcessInfo` — and whoever comes first makes it.
    static func processWide() -> NSMutableDictionary {
        let anchor = ProcessInfo.processInfo
        // A selector's name is one address in a process, whoever registers it.
        let key = UnsafeRawPointer(sel_getName(sel_registerName("fediqoRunWaits")))
        objc_sync_enter(anchor)
        defer { objc_sync_exit(anchor) }
        if let kept = objc_getAssociatedObject(anchor, key) as? NSMutableDictionary { return kept }
        let made = NSMutableDictionary()
        objc_setAssociatedObject(anchor, key, made, .OBJC_ASSOCIATION_RETAIN)
        return made
    }

    /// One wait: what it is for, where it was asked, and in which check. The file is said with
    /// its test target in front, so a list of several targets' waits says whose each is.
    struct Parked: Sendable, CustomStringConvertible {
        let what: String
        let file: String
        let line: Int
        let check: String?

        var description: String {
            "\(what) — \(file):\(line)" + (check.map { ", in \"\($0)\"" } ?? "")
        }
    }

    let still: Duration
    /// The list, the count of still looks, and whether a thread is looking: `processWide`'s for
    /// the run's own, and one of its own for a check of this class.
    let kept: NSMutableDictionary
    private let looks: Int
    private let tick: Duration
    private let threaded: Bool
    private let say: @Sendable (String) -> Void
    private let end: @Sendable (String) -> Void

    /// `still` is counted in looks `tick` apart. `say` is what step 1 does with the list and
    /// `end` what step 2 does: the run's own write it to the run's output, and the second then
    /// ends the process. A check of this class hands in something it can look at afterwards —
    /// and `threaded: false`, to make each look itself with `look()`: the one clock in this file
    /// is not checked against a clock either.
    init(
        still: Duration, tick: Duration = .seconds(1), threaded: Bool = true,
        keptIn kept: NSMutableDictionary = NSMutableDictionary(),
        saying say: @escaping @Sendable (String) -> Void = RunWaits.write,
        ending end: @escaping @Sendable (String) -> Void = RunWaits.endTheRun
    ) {
        self.still = still
        self.tick = tick
        self.looks = max(1, Int((Self.seconds(still) / Self.seconds(tick)).rounded(.up)))
        self.threaded = threaded
        self.kept = kept
        self.say = say
        self.end = end
    }

    private static func seconds(_ time: Duration) -> Double {
        Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
    }

    /// Everything read or written in `kept` is inside this: the lock is the list's own, so every
    /// copy of this class takes the same one.
    private func locked<T>(_ body: () -> T) -> T {
        objc_sync_enter(kept)
        defer { objc_sync_exit(kept) }
        return body()
    }

    private var entries: NSMutableDictionary {
        if let entries = kept["entries"] as? NSMutableDictionary { return entries }
        let entries = NSMutableDictionary()
        kept["entries"] = entries
        return entries
    }

    private static func parked(_ entry: NSDictionary) -> Parked {
        Parked(
            what: entry["what"] as? String ?? "", file: entry["file"] as? String ?? "",
            line: entry["line"] as? Int ?? 0, check: entry["check"] as? String
        )
    }

    /// The entries, the oldest first. Inside `locked`.
    private var inOrder: [(id: Int, entry: NSMutableDictionary)] {
        entries.compactMap { key, value in
            guard let id = key as? Int, let entry = value as? NSMutableDictionary else { return nil }
            return (id, entry)
        }
        .sorted { $0.id < $1.id }
    }

    /// Every wait parked now, the oldest first.
    var parked: [Parked] {
        locked { inOrder.map { Self.parked($0.entry) } }
    }

    /// How many looks in a row have found nothing moved. Nothing since the last wait was
    /// entered or left.
    var stillLooks: Int {
        locked { kept["quiet"] as? Int ?? 0 }
    }

    /// Parks a wait and returns what to `leave` with. `release` is called, off every actor, when
    /// the run has gone still — for a wait that sits on a continuation and so cannot look for
    /// itself. A wait that turns over need hand in nothing, and asks `gaveUp` each turn.
    func park(_ what: String, at: SourceLocation, release: (@Sendable () -> Void)? = nil) -> Int {
        let entry = NSMutableDictionary()
        entry["what"] = what
        entry["file"] = at.fileID
        entry["line"] = at.line
        entry["check"] = Test.current.map { $0.displayName ?? $0.name }
        // An operation, because that is a closure every copy of this class can be handed.
        entry["release"] = release.map { release in BlockOperation { release() } }
        return locked {
            let id = (kept["next"] as? Int ?? 0) + 1
            kept["next"] = id
            entries[id] = entry
            kept["quiet"] = 0
            if threaded, kept["watched"] == nil {
                kept["watched"] = true
                watch()
            }
            return id
        }
    }

    /// The wait is over, however it ended. This is the run moving.
    func leave(_ id: Int) {
        locked {
            entries.removeObject(forKey: id)
            kept["quiet"] = 0
        }
    }

    /// Whether the run went still while this wait was parked, and it has been let go.
    func gaveUp(_ id: Int) -> Bool {
        locked { (entries[id] as? NSDictionary)?["released"] as? Bool ?? false }
    }

    /// Parks until the run goes still or whoever is waiting is cancelled. `true` where it was
    /// the run going still. For a guard, which has nothing to wait for but that.
    func stillness(_ what: String, at: SourceLocation) async -> Bool {
        let once = Resumed()
        let id = park(what, at: at) { once.resume(true) }
        defer { leave(id) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { once.wait($0) }
        } onCancel: {
            once.resume(false)
        }
    }

    /// The sentence a wait that was let go records against its check.
    func said(_ what: String) -> Comment {
        "gave up waiting for \(what): nothing the run waits for had moved for \(still)"
    }

    /// One thread for the list, started by whichever copy parked in it first. It ends with the
    /// one that started it — which the run's own never does.
    private func watch() {
        let tick = Self.seconds(tick)
        let thread = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: tick)
                guard let self else { return }
                self.look()
            }
        }
        thread.name = "the run's waits"
        thread.start()
    }

    /// One look: what the thread does each time it wakes, and what a check of this class does
    /// by hand. Nothing parked is nothing to be still about.
    func look() {
        var releases: [BlockOperation] = []
        var letGo: String?
        var over: String?
        locked {
            let all = inOrder
            guard !all.isEmpty else { return }
            let quiet = (kept["quiet"] as? Int ?? 0) + 1
            kept["quiet"] = quiet
            guard quiet >= looks else { return }
            kept["quiet"] = 0
            let list = all.map { "  - \(Self.parked($0.entry))" }.joined(separator: "\n")
            let fresh = all.filter { $0.entry["released"] == nil }
            if fresh.isEmpty {
                over = "The run has not moved for \(still) more, with these let go and parked still:\n\(list)\n"
                    + "\(Self.lastWords) \(all.count) let go and not come back: nothing in this process will end them.\n"
            } else {
                for (_, entry) in fresh {
                    entry["released"] = true
                    if let release = entry["release"] as? BlockOperation { releases.append(release) }
                }
                letGo = "The run has not moved for \(still). Still waiting, and now let go:\n\(list)\n"
            }
        }
        if let letGo { say(letGo) }
        for release in releases { release.start() }
        if let over { end(over) }
    }

    /// How the last line a run ended here writes begins. `scripts/coverage.sh` looks for it, to
    /// say of a run that died this way that it did, and what it had been waiting for.
    static let lastWords = "Ending it."

    /// Step 1, for the run's own: the list, where a run's failures are read.
    static let write: @Sendable (String) -> Void = { list in
        fputs(list, stderr)
        fflush(stderr)
    }

    /// Step 2, for the run's own: the list, and then no more run. `_exit`, because this is a
    /// thread of a process that is stuck: what `exit` would run on the way out is as likely to
    /// be waiting on the same thing, and nothing that has been written is to be lost to it.
    static let endTheRun: @Sendable (String) -> Void = { list in
        write(list)
        fflush(stdout)
        _exit(EXIT_FAILURE)
    }
}

/// A continuation resumed once, by whichever of two callers comes first — and one that comes
/// before the continuation is there is kept for it.
private final class Resumed: @unchecked Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Bool, Never>)
        case done(Bool)
    }

    private let lock = NSLock()
    private var state = State.empty

    func wait(_ continuation: CheckedContinuation<Bool, Never>) {
        let already: Bool? = lock.withLock {
            if case .done(let value) = state { return value }
            state = .waiting(continuation)
            return nil
        }
        if let already { continuation.resume(returning: already) }
    }

    func resume(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { if case .done = state {} else { state = .done(value) } }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        waiting?.resume(returning: value)
    }
}

// MARK: - Waiting for a thing

/// Work a wait can be tied to: something that ends, and says so.
///
/// A `Task` is one. So is anything a suite keeps that knows when it is done.
protocol Ending: Sendable {
    /// Calls `over` once, when the work has ended, however it ended — and at once where it
    /// already has.
    func whenEnded(_ over: @escaping @Sendable () -> Void)
}

extension Task: Ending {
    func whenEnded(_ over: @escaping @Sendable () -> Void) {
        // Left to end when the work does. Where the work never ends, neither does this, and it
        // goes with the process: a task parked on another's result costs nothing and cannot be
        // cancelled off it.
        Task<Void, Never> {
            _ = await self.result
            over()
        }
    }
}

/// Waits until `condition` holds, and says so. `what` is the thing waited for, in words a
/// failure can be read by: "the reload is on the wire", not "asks == 1".
///
/// **It gives up where the thing can no longer happen**: when all of `work` has ended and the
/// condition still does not hold. Whether the work has ended is read *before* each look at the
/// condition, never after, so work whose last act was the thing itself is not failed for having
/// ended a moment before the look that would have seen it. It then records the failure against
/// the check, at the line that asked, and returns `false` so the check can go on and say what
/// else it found.
///
/// **With no `work` named it has nothing to give up by, and fails only when the run has gone
/// still** (`RunWaits`) — minutes after the line it waits on was broken, not at once. Name `by:`
/// wherever a `Task`, or any other `Ending`, stands for the work. Leave it out only where
/// nothing can be named: a hosted view's own `.task`, a run loop the check turns itself.
///
/// **It gives up where the check itself is cancelled**, and says that: a cancelled wait that
/// went on looking would never sleep between looks again, and would spin.
///
/// **No count of turns.** `spun` gave up after a hundred thousand yields, which is a clock that
/// runs faster on a faster machine. This yields for its first thousand turns, which is where
/// every honest wait on the main actor ends, and after that sleeps a millisecond between looks
/// so that a long wait does not take the processor from the work it is waiting for. That
/// millisecond is how often it looks, not how long it will go on looking.
///
/// **The condition may await**, so an actor's own state can be the thing: `await http.asks == 1`
/// is the only way to ask whether a request has reached the wire. It runs where the check runs.
@discardableResult
func met(
    _ what: String, by work: any Ending..., in waits: RunWaits = .run,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    until condition: () async -> Bool
) async -> Bool {
    if await condition() { return true }
    let id = waits.park(what, at: sourceLocation)
    defer { waits.leave(id) }
    let unended = Unended(work.count)
    for one in work { one.whenEnded { unended.one() } }
    var turns = 0
    while true {
        // Read before the condition is, so "ended" is never newer than the look that follows it.
        let ended = !work.isEmpty && unended.none
        if await condition() { return true }
        if ended {
            Issue.record("gave up waiting for \(what): the work it waited on ended without it", sourceLocation: sourceLocation)
            return false
        }
        if waits.gaveUp(id) {
            Issue.record(waits.said(what), sourceLocation: sourceLocation)
            return false
        }
        if Task.isCancelled {
            Issue.record("cancelled while waiting for \(what)", sourceLocation: sourceLocation)
            return false
        }
        turns += 1
        if turns < 1_000 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

/// How many pieces of a wait's work have not ended yet.
private final class Unended: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(_ count: Int) { left = count }

    var none: Bool { lock.withLock { left == 0 } }
    func one() { lock.withLock { left -= 1 } }
}

// MARK: - A gate, and its guard

/// Opens only when a test lets it, so a press can be caught mid-flight.
///
/// The flag is set **before** the waiters are resumed, so a caller arriving after the gate is
/// open does not park on a continuation nobody will resume.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// Opens a gate nobody else will, so a check that lost its synchronisation fails instead of
/// hanging the run. Armed before anything awaits, and cancelled on the passing path.
///
/// **It has no clock of its own.** It is parked with the run's waits, and it is the run going
/// still that opens the gate — so a check that is merely slow, or queued behind a thousand
/// others, is never opened early to measure an order it did not set up. A run that does reach
/// it says which gate, by `what`, at the line that armed the guard.
///
/// `what` is what is held behind the gate: "the boost, held on the wire".
func watching(
    _ gate: Gate, _ what: String = "a gate nobody opened", in waits: RunWaits = .run,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Task<Void, Never> {
    watching(what, in: waits, sourceLocation: sourceLocation) { await gate.open() }
}

/// `watching(_:_:)` for whatever a suite holds its work with that is not a `Gate`: `open` is
/// what lets go of it.
func watching(
    _ what: String = "a gate nobody opened", in waits: RunWaits = .run,
    sourceLocation: SourceLocation = #_sourceLocation,
    opening open: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
    Task {
        guard await waits.stillness(what, at: sourceLocation) else { return }
        Issue.record(waits.said(what), sourceLocation: sourceLocation)
        await open()
    }
}

// MARK: - A check that may not hang the run

/// What `.timeLimit` was there for, without its clock: a check that never ends is ended, and
/// named.
///
/// The check is parked with the run's waits for as long as it runs. Where the run goes still it
/// is cancelled — which ends anything that was waiting on a sleep or a request — and a failure
/// is recorded at its own declaration. Where cancelling does not end it, `RunWaits` ends the run
/// and names it.
///
/// **Why a check needs it though its waits are all `met`**: a check can be parked where no
/// helper of this file is — awaiting the very call it is checking. Nothing would name that one.
struct WatchedTrait: TestTrait, SuiteTrait, TestScoping {
    let waits: RunWaits

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // A suite is not a check: its checks are each given this scope of their own.
        guard !test.isSuite else { return try await function() }
        try await withoutActuallyEscaping(function) { function in
            let body = Task { try await function() }
            let id = waits.park("the check itself to end", at: test.sourceLocation) { body.cancel() }
            defer { waits.leave(id) }
            let result = await withTaskCancellationHandler {
                await body.result
            } onCancel: {
                body.cancel()
            }
            if waits.gaveUp(id) {
                Issue.record(waits.said("the check itself to end"), sourceLocation: test.sourceLocation)
                return
            }
            try result.get()
        }
    }
}

extension Trait where Self == WatchedTrait {
    /// On a check, or on a suite for every check in it.
    static var watched: Self { WatchedTrait(waits: .run) }
}

// MARK: - A clock turned by hand

/// What a check hands the app in place of `Task.sleep`, so that "the wait has passed" is where
/// the check put it and not where a timer happened to be.
///
/// Every sleep asked of it is held until `turn` lets it go, or until whoever is asleep is
/// cancelled — which throws, as a cancelled `Task.sleep` does. It keeps what was asked for, so a
/// check can say *how long* the app meant to wait without waiting it.
final class TurnedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var asks: [Duration] = []

    /// What to hand a `sleep:` seam.
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] in try await self.sleep(for: $0) }
    }

    /// Every wait asked for so far, in the order asked.
    var asked: [Duration] { lock.withLock { asks } }

    /// How many are asleep now.
    var sleeping: Int { lock.withLock { held.count } }

    /// Everything asleep now wakes: its time has passed. What is asked for afterwards is held
    /// again.
    func turn() {
        let waking = lock.withLock {
            defer { held = [:] }
            return Array(held.values)
        }
        for continuation in waking { continuation.resume() }
    }

    func sleep(for wait: Duration) async throws {
        let id = lock.withLock {
            asks.append(wait)
            return asks.count
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gone = lock.withLock {
                    if cancelled.contains(id) { return true }
                    held[id] = continuation
                    return false
                }
                if gone { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let asleep = lock.withLock {
                cancelled.insert(id)
                return held.removeValue(forKey: id)
            }
            asleep?.resume(throwing: CancellationError())
        }
    }
}
