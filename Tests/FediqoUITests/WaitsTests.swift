import Foundation
import Testing

/// #346: what a check waits with — `Waits.swift`, the same text in every test target, and this
/// file with it, so that each target's copy is checked where it is compiled.
///
/// **No check here waits on a clock either.** The run's bound is counted in looks, and these
/// checks make each look themselves, on waits that have no thread: "the run has gone still" is
/// where a check put it. A wait that is to fail by its work ending is given a bound of an hour:
/// where it comes back at all, it was not the bound that brought it.
@Suite("A wait says what it waits for, and gives up where that can no longer happen", .watched)
struct WaitsTests {
    private final class Kept<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        var all: [Value] { lock.withLock { values } }
        func add(_ value: Value) { lock.withLock { values.append(value) } }
    }

    /// Work that ends when a check says so, and not a moment to either side.
    private final class Stepped: Ending, @unchecked Sendable {
        private let lock = NSLock()
        private var told: [@Sendable () -> Void] = []
        private var over = false

        func whenEnded(_ over: @escaping @Sendable () -> Void) {
            let already = lock.withLock {
                if !self.over { told.append(over) }
                return self.over
            }
            if already { over() }
        }

        func end() {
            let telling = lock.withLock {
                over = true
                defer { told = [] }
                return told
            }
            for tell in telling { tell() }
        }
    }

    /// Five minutes, a look a second: three hundred looks.
    private static let still = Duration.seconds(300)
    private static let looks = 300

    /// Waits of its own with no thread, and what step 2 was handed. What step 1 says is kept out
    /// of the run's output: here it is said on purpose.
    private func waits(
        saying said: Kept<String> = Kept(), keptIn kept: NSMutableDictionary = NSMutableDictionary()
    ) -> (RunWaits, Kept<String>) {
        let ended = Kept<String>()
        let waits = RunWaits(
            still: Self.still, threaded: false, keptIn: kept, saying: { said.add($0) }, ending: { ended.add($0) }
        )
        return (waits, ended)
    }

    /// `count` looks in which nothing moved.
    private static func look(_ waits: RunWaits, _ count: Int = looks) {
        for _ in 0..<count { waits.look() }
    }

    /// Waits nobody looks at: nothing comes back by their bound.
    private static func far() -> RunWaits {
        RunWaits(still: .seconds(3_600), threaded: false, saying: { _ in }, ending: { _ in })
    }

    /// What `body` recorded against this check, each taken as expected so that the check itself
    /// passes. Where it records nothing, that is a failure of its own.
    private func failures(_ body: () async throws -> Void) async -> [Issue] {
        let kept = Kept<Issue>()
        try? await withKnownIssue {
            try await body()
        } matching: { issue in
            kept.add(issue)
            return true
        }
        return kept.all
    }

    private func said(_ issue: Issue?) -> String { issue?.comments.map(\.rawValue).joined(separator: " ") ?? "" }

    // MARK: - Waiting for a thing

    @Test("A wait for a thing that happens comes back saying so, on the main actor as off it")
    @MainActor
    func theThingHappens() async {
        let gate = Gate()
        let seen = Kept<Int>()
        let work = Task {
            await gate.wait()
            seen.add(1)
        }
        let waiting = Task { await met("the work has been let through", by: work, in: Self.far()) { !seen.all.isEmpty } }
        await gate.open()
        #expect(await waiting.value)
        #expect(await met("something already so", in: Self.far()) { true })
    }

    @Test("A wait whose work has ended without the thing fails at once, naming what it waited for, at the line that asked")
    func theWorkEnded() async {
        let waits = Self.far()
        let work = Task {}
        let line = Kept<Int>()
        let found = await failures {
            line.add(#line + 1)
            let came = await met("the reload is on the wire", by: work, in: waits) { false }
            #expect(!came)
        }
        #expect(found.count == 1)
        #expect(said(found.first) == "gave up waiting for the reload is on the wire: the work it waited on ended without it")
        #expect(found.first?.sourceLocation?.line == line.all.first)
        #expect(found.first?.sourceLocation?.fileID == #fileID)
        #expect(waits.parked.isEmpty, "and it is parked no longer")
    }

    @Test("Work whose last act is the thing itself is never failed for having ended")
    func theLastActIsTheThing() async {
        let waits = Self.far()
        for _ in 0..<500 {
            let seen = Kept<Int>()
            let work = Task { seen.add(1) }
            #expect(await met("the work's last act", by: work, in: waits) { !seen.all.isEmpty })
        }
    }

    @Test("Work that does the thing and ends between two looks is not failed: whether it has ended is read before the look, never after")
    func endedIsReadBeforeTheLook() async {
        let work = Stepped()
        var looks = 0
        let came = await met("the work's last act, done between two looks", by: work, in: Self.far()) {
            looks += 1
            guard looks == 2 else { return looks > 2 }
            // This look finds nothing — and before the next one, the thing is done and the work
            // is over. A wait that asked "has it ended?" after looking would give up here.
            work.end()
            return false
        }
        #expect(came)
        #expect(looks == 3)
    }

    @Test("A wait is over only when every piece of the work it names has ended")
    func everyPieceOfTheWork() async {
        let waits = Self.far()
        let first = Stepped(), second = Stepped()
        let seen = Kept<Int>(), looked = Kept<Int>()
        first.end()
        let waiting = Task {
            await met("the second piece's word", by: first, second, in: waits) {
                looked.add(1)
                return !seen.all.isEmpty
            }
        }
        // Looked at again and again with one piece over, and still waiting.
        await met("the wait has looked several times", by: waiting, in: Self.far()) { looked.all.count >= 4 }
        seen.add(1)
        second.end()
        #expect(await waiting.value, "the first piece ending did not end the wait")
    }

    @Test("A wait that has turned over a thousand times goes on looking, and sleeps between its looks")
    func aLongWait() async {
        var looks = 0
        #expect(await met("a thing a long time coming", in: Self.far()) {
            looks += 1
            return looks > 1_050
        })
        #expect(looks == 1_051)
    }

    @Test("A wait whose check is cancelled gives up at once, and says that it was cancelled, at the line that asked")
    func cancelled() async {
        let waits = Self.far()
        let line = Kept<Int>()
        let found = await failures {
            line.add(#line + 1)
            let waiting = Task { await met("a thing nobody does", in: waits) { false } }
            await met("the wait is parked", by: waiting, in: Self.far()) { !waits.parked.isEmpty }
            waiting.cancel()
            #expect(await waiting.value == false)
        }
        #expect(found.count == 1)
        #expect(said(found.first) == "cancelled while waiting for a thing nobody does")
        #expect(found.first?.sourceLocation?.line == line.all.first)
        #expect(waits.parked.isEmpty)
    }

    // MARK: - The run's own bound

    @Test("A check that would wait for ever fails when the run has gone still, naming what it waited for, at the line that asked")
    func aHungCheck() async {
        let (waits, _) = waits()
        let never = Stepped()
        let line = Kept<Int>()
        let found = await failures {
            let looking = Task {
                await met("the hung wait is parked", in: Self.far()) { !waits.parked.isEmpty }
                Self.look(waits)
            }
            line.add(#line + 1)
            let came = await met("an answer nobody sends", by: never, in: waits) { false }
            #expect(!came)
            await looking.value
        }
        #expect(found.count == 1)
        #expect(said(found.first) == "gave up waiting for an answer nobody sends: nothing the run waits for had moved for 300.0 seconds")
        #expect(found.first?.sourceLocation?.line == line.all.first)
    }

    @Test("What is parked is listed by what it waits for, where — its test target first — and in which check")
    func theList() async throws {
        let (waits, _) = waits()
        let line = #line + 1
        let id = waits.park("the boost, held on the wire", at: #_sourceLocation)
        let parked = try #require(waits.parked.first)
        #expect("\(parked)" == "the boost, held on the wire — \(#fileID):\(line), in "
            + #""What is parked is listed by what it waits for, where — its test target first — and in which check""#)
        #expect(#fileID.hasSuffix("Tests/WaitsTests.swift"))
        waits.leave(id)
        #expect(waits.parked.isEmpty)
    }

    @Test("A run that is slow is not a run that is still: a wait is let go only when no wait at all has been entered or left for the whole bound")
    func slowIsNotStill() {
        let (waits, ended) = waits()
        let old = waits.park("the oldest wait", at: #_sourceLocation)
        // Far longer than the bound in all, and something moved inside every stretch of it.
        for _ in 0..<10 {
            Self.look(waits, Self.looks - 1)
            waits.leave(waits.park("another check's wait", at: #_sourceLocation))
        }
        #expect(!waits.gaveUp(old), "ten bounds' worth of a moving run let nothing go")
        Self.look(waits, Self.looks - 1)
        #expect(!waits.gaveUp(old), "a look short of still")
        waits.look()
        #expect(waits.gaveUp(old))
        #expect(ended.all.isEmpty, "letting go is not ending the run")
    }

    @Test("Stillness is looks that were made: with nothing parked there is nothing to be still about, and a look that is not made — a machine asleep, a process stopped — counts for nothing")
    func stillnessIsLooks() {
        let (waits, _) = waits()
        Self.look(waits, Self.looks * 2)
        #expect(waits.stillLooks == 0, "nothing parked, nothing counted")
        let id = waits.park("a wait", at: #_sourceLocation)
        // However long ago it was parked, it has been still for as many looks as were made.
        #expect(waits.stillLooks == 0 && !waits.gaveUp(id))
        Self.look(waits, 7)
        #expect(waits.stillLooks == 7)
        waits.leave(id)
    }

    @Test("Let go and parked still when the run has been still that long again, the run is ended with the list of what was waited for and a last line a script can find; let go and gone, it is not")
    func theRunIsEnded() {
        let said = Kept<String>()
        let (waits, ended) = waits(saying: said)
        let released = Kept<Int>()
        let line = #line + 1
        let stuck = waits.park("an actor that is blocked", at: #_sourceLocation) { released.add(1) }
        Self.look(waits)
        #expect(released.all == [1] && waits.gaveUp(stuck))
        #expect(said.all.count == 1, "every wait parked is written out as it is let go")
        #expect(said.all.first?.contains("  - an actor that is blocked — \(#fileID):\(line)") == true)
        Self.look(waits, Self.looks - 1)
        #expect(ended.all.isEmpty)
        waits.look()
        #expect(ended.all.count == 1)
        let lines = ended.all.first?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.contains { $0.hasPrefix("  - an actor that is blocked — \(#fileID):\(line)") })
        #expect(lines.last?.hasPrefix("Ending it. ") == true, "what scripts/coverage.sh looks for")
        #expect(released.all == [1], "it is let go once")

        let (others, never) = self.waits()
        let gone = others.park("a wait that gives up when let go", at: #_sourceLocation)
        Self.look(others)
        others.leave(gone)
        Self.look(others, Self.looks * 3)
        #expect(never.all.isEmpty)
    }

    @Test("The script that runs the checks on a runner knows the last line of a run ended here")
    func theScriptKnowsTheLastLine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/coverage.sh"), encoding: .utf8)
        #expect(RunWaits.lastWords == "Ending it.")
        #expect(script.contains(#"'^Ending it\.'"#))
    }

    @Test("The bound is watched by a thread of its own, which nobody has to turn")
    func theThreadLooks() async {
        let waits = RunWaits(still: .milliseconds(20), tick: .milliseconds(5), saying: { _ in }, ending: { _ in })
        let found = await failures {
            let guardTask = watching("what only the thread will let go of", in: waits) {}
            await guardTask.value
        }
        #expect(found.count == 1)
        #expect(said(found.first).hasPrefix("gave up waiting for what only the thread will let go of"))
    }

    @Test("A run has one list, whichever test target's copy of this file a wait was parked through: a wait entered through one is the run moving for every other")
    func oneListForAProcess() {
        // The run's own is what hangs from the process, found here as another copy finds it.
        let key = UnsafeRawPointer(sel_getName(sel_registerName("fediqoRunWaits")))
        let hung = objc_getAssociatedObject(ProcessInfo.processInfo, key) as? NSMutableDictionary
        #expect(RunWaits.run.kept === RunWaits.processWide())
        #expect(hung != nil && hung === RunWaits.run.kept)

        // Two copies are two objects over one list.
        let list = NSMutableDictionary()
        let (mine, _) = waits(keptIn: list)
        let (theirs, ended) = waits(keptIn: list)
        let released = Kept<Int>()
        let id = mine.park("a wait of one target's", at: #_sourceLocation) { released.add(1) }
        #expect(theirs.parked.map(\.what) == ["a wait of one target's"])
        Self.look(theirs, Self.looks - 1)
        #expect(mine.stillLooks == Self.looks - 1)
        theirs.leave(theirs.park("a wait of another's", at: #_sourceLocation))
        #expect(mine.stillLooks == 0, "the other target moving is the run moving")
        Self.look(mine, Self.looks - 1)
        #expect(!mine.gaveUp(id))
        theirs.look()
        #expect(mine.gaveUp(id) && released.all == [1], "let go by whichever copy made the look")
        mine.leave(id)
        #expect(theirs.parked.isEmpty && ended.all.isEmpty)
    }

    @Test("How long the run may be still is five minutes, or what a person said in seconds: a second at the least, and nothing that is not a number of seconds")
    func patience() {
        #expect(RunWaits.patience(said: nil) == .seconds(300))
        #expect(RunWaits.patience(said: "10") == .seconds(10))
        #expect(RunWaits.patience(said: "0.2") == .seconds(1))
        for said in ["0", "-3", "nan", "inf", "-inf", "soon", ""] {
            #expect(RunWaits.patience(said: said) == .seconds(300), "\(said)")
        }
    }

    // MARK: - A gate's guard

    @Test("A gate nobody opens is opened when the run has gone still, and the check that was parked behind it fails naming the gate, at the line that armed the guard")
    func theGuardOpens() async {
        let (waits, _) = waits()
        let gate = Gate()
        let line = Kept<Int>()
        let found = await failures {
            line.add(#line + 1)
            let guardTask = watching(gate, "the boost, held on the wire", in: waits)
            let looking = Task {
                await met("the guard is armed", in: Self.far()) { !waits.parked.isEmpty }
                Self.look(waits)
            }
            // The check itself is behind the gate: nothing but the guard will ever let it on.
            await gate.wait()
            await guardTask.value
            await looking.value
        }
        #expect(found.count == 1)
        #expect(said(found.first) == "gave up waiting for the boost, held on the wire: nothing the run waits for had moved for 300.0 seconds")
        #expect(found.first?.sourceLocation?.line == line.all.first)
    }

    @Test("A guard cancelled on the passing path says nothing, opens nothing, and is parked no longer")
    func theGuardIsCancelled() async {
        let (waits, _) = waits()
        let opened = Kept<Int>()
        let guardTask = watching("a gate the check opened itself", in: waits) { opened.add(1) }
        await met("the guard is armed", by: guardTask, in: Self.far()) { !waits.parked.isEmpty }
        guardTask.cancel()
        await guardTask.value
        #expect(waits.parked.isEmpty)
        Self.look(waits, Self.looks * 2)
        #expect(opened.all.isEmpty)
    }

    // MARK: - A check that may not hang the run

    @Test("A watched check that never ends is cancelled when the run has gone still, and fails where it is declared; one that ends, or throws, does as it would have")
    func aWatchedCheck() async throws {
        struct Thrown: Error {}
        let (waits, _) = waits()
        let trait = WatchedTrait(waits: waits)
        let this = try #require(Test.current)
        let never = Gate()
        let found = await failures {
            let looking = Task {
                await met("the check is parked", in: Self.far()) { !waits.parked.isEmpty }
                #expect(waits.parked.first?.what == "the check itself to end")
                Self.look(waits)
            }
            try await trait.provideScope(for: this, testCase: nil) {
                // Parked for ever, but for being cancelled.
                await withTaskCancellationHandler {
                    await never.wait()
                } onCancel: {
                    Task { await never.open() }
                }
            }
            await looking.value
        }
        #expect(found.count == 1)
        #expect(said(found.first).hasPrefix("gave up waiting for the check itself to end"))
        #expect(found.first?.sourceLocation?.line == this.sourceLocation.line)
        #expect(waits.parked.isEmpty)

        let ran = Kept<Int>()
        try await trait.provideScope(for: this, testCase: nil) { ran.add(1) }
        #expect(ran.all == [1] && waits.parked.isEmpty)
        await #expect(throws: Thrown.self) {
            try await trait.provideScope(for: this, testCase: nil) { throw Thrown() }
        }
    }

    // MARK: - A clock turned by hand

    @Test("A clock turned by hand holds every sleep asked of it until it is turned, keeps what was asked for, and breaks a sleep whose sleeper is cancelled")
    func theTurnedClock() async {
        let clock = TurnedClock()
        let woke = Kept<Int>()
        let sleeper = Task {
            try? await clock.sleep(.seconds(30))
            woke.add(1)
            try? await clock.sleep(.seconds(60))
            woke.add(2)
        }
        await met("the first sleep is asked for", by: sleeper, in: Self.far()) { clock.sleeping == 1 }
        #expect(clock.asked == [.seconds(30)] && woke.all.isEmpty)
        clock.turn()
        await met("the second sleep is asked for", by: sleeper, in: Self.far()) { clock.asked.count == 2 && clock.sleeping == 1 }
        #expect(woke.all == [1])
        clock.turn()
        await sleeper.value
        #expect(woke.all == [1, 2])

        let broken = Task { () -> Bool in
            do { try await clock.sleep(.seconds(1)) } catch { return error is CancellationError }
            return false
        }
        await met("the sleep to be broken is asked for", by: broken, in: Self.far()) { clock.sleeping == 1 }
        broken.cancel()
        #expect(await broken.value)
        #expect(clock.sleeping == 0)
    }

    // MARK: - One text

    @Test("Every test target waits with the same text, and checks it with the same checks")
    func oneText() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let targets = try FileManager.default.contentsOfDirectory(atPath: tests.path).filter { $0.hasSuffix("Tests") }.sorted()
        #expect(targets == ["FediqoCoreTests", "FediqoPersistenceTests", "FediqoUITests"], "a test target this check does not know")
        for file in ["Waits.swift", "WaitsTests.swift"] {
            let texts = try targets.map { try String(contentsOf: tests.appendingPathComponent("\($0)/\(file)"), encoding: .utf8) }
            for (target, text) in zip(targets, texts) {
                #expect(text == texts[0], "\(target)/\(file) is not the text of \(targets[0])/\(file)")
            }
        }
    }
}
