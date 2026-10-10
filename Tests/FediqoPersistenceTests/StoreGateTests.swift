#if os(macOS)
import AppKit
#endif
import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// Protected data turned by hand: what the canary answers, whether somebody is in front of an
/// unlocked device, and the events — sent one at a time, to a subscriber this can wait for.
final class ProtectedByHand: Sendable {
    private struct State {
        var canary = ProtectedData.Canary.reads
        var remade = ProtectedData.Canary.refused
        var somebody = false
        var remakes = 0
        var subscribers: [AsyncStream<Void>.Continuation] = []
        var waiting: [(above: Int, resume: CheckedContinuation<Bool, Never>)] = []
        var ended = false
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ canary: ProtectedData.Canary, remade: ProtectedData.Canary = .refused, somebody: Bool = false) {
        state.withLock {
            $0.canary = canary
            $0.remade = remade
            $0.somebody = somebody
        }
    }

    func turn(canary: ProtectedData.Canary) { state.withLock { $0.canary = canary } }
    func turn(somebody: Bool) { state.withLock { $0.somebody = somebody } }
    var remakes: Int { state.withLock { $0.remakes } }

    /// The wait under test, started — and whether it is now waiting on the events. **Never an
    /// open-ended wait of this test's own**: it answers as soon as the wait has subscribed, or
    /// has returned without subscribing, whichever of the two happens — and one of them does.
    @MainActor
    func parked(_ gate: StoreGate) async -> (waiting: Task<Void, Never>, parked: Bool) {
        // Its own subscription is waited for, and not one some earlier wait made.
        let before = state.withLock { $0.subscribers.count }
        let waiting = Task { @MainActor in
            await gate.wait()
            let left = self.state.withLock { state in
                state.ended = true
                defer { state.waiting = [] }
                return state.waiting
            }
            left.forEach { $0.resume.resume(returning: false) }
        }
        let parked = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let known: Bool? = state.withLock { state in
                if state.subscribers.count > before { return true }
                if state.ended { return false }
                state.waiting.append((before, continuation))
                return nil
            }
            if let known { continuation.resume(returning: known) }
        }
        return (waiting, parked)
    }

    /// One event, to whoever listens.
    func wake() { state.withLock { $0.subscribers }.forEach { $0.yield() } }
    /// Nothing more will ever happen: whatever is still waiting on the events stops waiting.
    /// Every test that started a wait ends with this, so none outlives what it waits for.
    func end() {
        state.withLock { state in
            state.closed = true
            return state.subscribers
        }.forEach { $0.finish() }
    }

    var protected: ProtectedData {
        ProtectedData(
            flag: { true },
            canary: { [state] in state.withLock { $0.canary } },
            remade: { [state] in
                state.withLock { state in
                    state.remakes += 1
                    state.canary = state.remade
                    return state.remade
                }
            },
            unlockedForSomebody: { [state] in state.withLock { $0.somebody } },
            changes: { [state] in
                AsyncStream { continuation in
                    // Asked for after the test said nothing more will happen: nothing does.
                    if state.withLock({ $0.closed }) { return continuation.finish() }
                    let waiting = state.withLock { state in
                        state.subscribers.append(continuation)
                        let count = state.subscribers.count
                        defer { state.waiting.removeAll { count > $0.above } }
                        return state.waiting.filter { count > $0.above }
                    }
                    waiting.forEach { $0.resume.resume(returning: true) }
                }
            }
        )
    }
}

/// #344: the store is opened once, when what it holds can be read, and a launch made behind a
/// lock waits for the unlock — it never starts without its store, and it never waits where
/// there is nothing to wait for.
@MainActor
@Suite("A launch waits for its store")
struct StoreGateTests {
    /// What the gate asked of the opening, in order: whether each was told the device is unlocked.
    private final class Asked {
        var unlocked: [Bool] = []
        var answers: [StoreFile.Opened] = []
    }

    private static let whole = StoreFile.Opened(file: nil, sources: [Source(host: "alpha.test", kind: .mastodon)])
    private static let locked = StoreFile.Opened(file: nil, trouble: .unreachable(.locked))

    private func gate(
        _ hand: ProtectedByHand, waits: Bool = true, somebody: (@MainActor () -> Bool)? = nil, _ asked: Asked,
        answers: [StoreFile.Opened] = [whole]
    ) -> StoreGate {
        asked.answers = answers
        return StoreGate(protected: hand.protected, waits: waits, unlockedForSomebody: somebody) { unlocked in
            asked.unlocked.append(unlocked)
            return asked.answers.count > 1 ? asked.answers.removeFirst() : asked.answers[0]
        }
    }

    @Test("Where the canary reads the store is opened at once, before anything is waited for, and once")
    func reads() async {
        let hand = ProtectedByHand(.reads), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened?.sources.map(\.host) == ["alpha.test"])
        #expect(asked.unlocked == [false])
        let (waiting, parked) = await hand.parked(gate)
        #expect(!parked, "opened already: nothing to wait for")
        hand.wake()
        hand.end()
        await waiting.value
        #expect(asked.unlocked == [false], "set once, and never asked again")
    }

    @Test("A canary that refuses with nobody there is the lock: the launch waits, and opens when something says the device is back")
    func waitsForTheUnlock() async throws {
        let hand = ProtectedByHand(.refused), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened == nil && asked.unlocked.isEmpty, "nothing of the store is asked behind a lock")
        let (waiting, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        // An event that changes nothing: still locked, still waiting.
        hand.wake()
        hand.turn(canary: .reads)
        hand.wake()
        hand.end()
        await waiting.value
        #expect(gate.opened?.sources.map(\.host) == ["alpha.test"])
        #expect(asked.unlocked == [false])
        #expect(hand.remakes == 0, "a lock is waited out, and the canary is not written over for it")
    }

    @Test("The level is read after subscribing: a device somebody already unlocked sends no event to say so")
    func theLevelIsRead() async {
        let hand = ProtectedByHand(.refused, remade: .reads), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened == nil)
        // The scene became active before anything listened; no event will come.
        hand.turn(somebody: true)
        // No event is sent: only "nothing more will happen". It opens by what it read.
        let (waiting, _) = await hand.parked(gate)
        hand.end()
        await waiting.value
        #expect(gate.opened != nil)
        #expect(hand.remakes == 1 && asked.unlocked == [false], "written anew once, and it reads: an ordinary open")
    }

    @Test("A canary that refuses in front of a person and will not be made again is no canary: the store opens, told so")
    func noCanaryForSomebody() async {
        let hand = ProtectedByHand(.refused, remade: .refused, somebody: true), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened != nil, "never left on the launch ground in front of a person")
        #expect(hand.remakes == 1)
        #expect(asked.unlocked == [true])
    }

    @Test("Written anew and then not to be read is the lock itself: the launch waits, whoever is said to be in front of it")
    func theLocksOwnSignature() async throws {
        // A Mac whose session will not say it is locked: somebody is "there", and the canary,
        // written anew, cannot be read.
        let hand = ProtectedByHand(.refused, remade: .closed, somebody: true), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened == nil && asked.unlocked.isEmpty, "not opened as a store with no canary")
        #expect(hand.remakes == 1)
        let (waiting, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        hand.turn(canary: .reads)
        hand.wake()
        hand.end()
        await waiting.value
        #expect(gate.opened != nil && asked.unlocked == [false])
    }

    @Test("Whether somebody is there is read live, where the gate is asked — not taken from what was last heard")
    func theLevelIsLive() {
        // What was last heard says nobody; the application, asked now, says somebody.
        let hand = ProtectedByHand(.refused, remade: .reads, somebody: false), asked = Asked()
        var somebody = false
        let gate = gate(hand, somebody: { somebody }, asked)
        #expect(gate.opened == nil)
        somebody = true
        let again = self.gate(hand, somebody: { somebody }, asked)
        #expect(again.opened != nil && hand.remakes == 1)
    }

    @Test("Two windows waiting on one gate, both woken: the store is opened once")
    func twoWaits() async throws {
        let hand = ProtectedByHand(.refused), asked = Asked()
        let gate = gate(hand, asked)
        let (first, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        // The second window's wait, waited for until it too is listening: both hear each wake.
        let (second, alsoParked) = await hand.parked(gate)
        try #require(alsoParked, "the second wait returned without waiting for anything")
        hand.turn(canary: .reads)
        hand.wake()
        hand.wake()
        hand.end()
        await first.value
        await second.value
        #expect(gate.opened != nil)
        #expect(asked.unlocked == [false], "opened once, however many were waiting and however many times they were woken")
    }

    @Test("No canary at all is nothing to wait for: the store is opened at once, with no event and no remaking")
    func none() async {
        let hand = ProtectedByHand(.none), asked = Asked()
        let gate = gate(hand, asked)
        #expect(gate.opened != nil)
        #expect(asked.unlocked == [false] && hand.remakes == 0)
        let (waiting, parked) = await hand.parked(gate)
        #expect(!parked)
        hand.end()
        await waiting.value
    }

    @Test("A device that locks while the store is being opened sets nothing, and the launch waits like any other")
    func lockedWhileOpening() async throws {
        let hand = ProtectedByHand(.reads), asked = Asked()
        let gate = gate(hand, asked, answers: [Self.locked, Self.locked, Self.whole])
        #expect(gate.opened == nil && asked.unlocked == [false])
        let (waiting, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        hand.wake()
        hand.end()
        await waiting.value
        #expect(gate.opened?.sources.map(\.host) == ["alpha.test"])
        #expect(asked.unlocked == [false, false, false], "at the making, after subscribing, and at the event")
    }

    @Test("In the simulator a canary that refuses is never a lock: nothing is waited for")
    func theSimulator() {
        let hand = ProtectedByHand(.refused, remade: .refused), asked = Asked()
        let gate = gate(hand, waits: false, asked)
        #expect(gate.opened != nil && asked.unlocked == [true])
    }

    @Test("Where nothing can any longer wake it the wait ends, with nothing opened and nothing asked of the store")
    func nothingMoreWillHappen() async throws {
        let hand = ProtectedByHand(.refused), asked = Asked()
        let gate = gate(hand, asked)
        let (waiting, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        hand.end()
        await waiting.value
        #expect(gate.opened == nil && asked.unlocked.isEmpty)
    }

    // MARK: - Over a real folder

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The canary of a real folder, refused as a lock refuses it — `chmod 000` gives the same
    /// answer — with the events and the level turned by hand.
    private func real(_ dir: URL, _ hand: ProtectedByHand) -> ProtectedData {
        ProtectedData.canary(in: dir, flag: { true }, unlockedForSomebody: hand.protected.unlockedForSomebody, changes: hand.protected.changes)
    }

    private func permissions(_ mode: Int, _ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.appendingPathComponent(Guarded.canaryName).path)
    }

    @Test("A store that reads as damaged behind a refused canary is not touched; unlocked, it is opened as it is")
    func aRealLaunchBehindALock() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [PackagerFixture.mastodon], notes: [])
        try file.db.close()
        #expect(Guarded.probeCanary(in: dir) == .reads)
        try permissions(0o000, dir)
        let hand = ProtectedByHand(.reads)
        let protected = real(dir, hand)
        #expect(protected.canary() == .refused)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        var asked = 0
        let gate = StoreGate(protected: protected) { unlocked in
            asked += 1
            // What a lock might make of the index: anything at all.
            return StoreFile.open(at: dir, now: Date(), protected: protected, unlocked: unlocked) { _ in
                throw DatabaseErrorStandIn.notADatabase
            }
        }
        #expect(gate.opened == nil && asked == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
        let (waiting, parked) = await hand.parked(gate)
        try #require(parked, "the wait returned without waiting for anything")
        try permissions(0o600, dir)
        hand.wake()
        hand.end()
        await waiting.value
        #expect(asked == 1)
        #expect(gate.opened?.trouble != .unreachable(.locked))
    }

    @Test("A canary that will not read in front of a person is written anew, whole, and the store opens as on any day")
    func aRealCanaryWrittenAnew() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [PackagerFixture.mastodon], notes: [])
        try file.db.close()
        #expect(Guarded.probeCanary(in: dir) == .reads)
        try permissions(0o000, dir)
        let hand = ProtectedByHand(.reads, somebody: true)
        let protected = real(dir, hand)
        let gate = StoreGate(protected: protected) { unlocked in
            StoreFile.open(at: dir, protected: protected, unlocked: unlocked)
        }
        #expect(gate.opened?.sources.map(\.host) == [PackagerFixture.mastodon.host])
        #expect(gate.opened?.trouble == nil)
        #expect(protected.canary() == .reads)
    }

    // MARK: - The app

    /// **Held to the source**, the app target being nothing a package's tests can run: the
    /// store is opened in one place, by the gate, and the run is made from what it opened.
    @Test("The app opens its store once, through the gate, and nothing of the run exists before it has")
    func theApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code = ""
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Apps/Shared").path).sorted()
        where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent("Apps/Shared/\(name)"), encoding: .utf8)
            code += text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        // One opening of the store, inside what the gate is handed.
        #expect(count("openApplicationSupport(") == 1)
        let gate = try #require(code.range(of: "protected: protected, waits: ProtectedSignals.waits, unlockedForSomebody: ProtectedSignals.unlockedForSomebody\n        ) { unlocked in"))
        let opening = try #require(code.range(of: "return StoreFile.openApplicationSupport(protected: protected, unlocked: unlocked)"))
        let kept = try #require(code.range(of: "gate = made"))
        #expect(gate.upperBound < opening.lowerBound && opening.upperBound < kept.lowerBound)
        #expect(count("StoreGate(") == 1 && count("StoreFile.open(") == 0 && count("StoreFile(") == 0)
        // The sweep asks the canary, and is asked before the open.
        let sweep = try #require(code.range(of: "StorePackager.sweepLeftovers(directory: directory, media: media?.location, protected: protected)"))
        #expect(gate.upperBound < sweep.lowerBound && sweep.upperBound < opening.lowerBound)
        // The run is made of what was opened, once, and is nobody's to find before that.
        #expect(code.contains("private(set) static var shared: Launch?"))
        #expect(code.contains("private init(_ opened: StoreFile.Opened) {"))
        #expect(code.contains("precondition(shared == nil,"))
        #expect(count(" Launch(") == 1 && count("= Launch(opened)") == 1, "made in one place")
        // One store of the run's; the other is a launch staged for a picture, which opens nothing.
        #expect(count("ItemStore(") == 2 && count("store = ItemStore(") == 1 && count("store: ItemStore(") == 1)
        let made = try #require(code.range(of: "private init(_ opened: StoreFile.Opened) {"))
        let store = try #require(code.range(of: "store = ItemStore("))
        #expect(made.upperBound < store.lowerBound)
        #expect(count("Launch.shared.") == 0, "a quit or a backgrounding before the store is opened must not build the run")
        #expect(count("Launch.shared?.end()") == 2 && count("Launch.shared?.pause()") == 1)
        // The gate is made from a body, never from a static or the app's initializer.
        #expect(code.contains("private static var gate: StoreGate?"))
        #expect(code.contains("@State private var launch = Launch.atOnce()"))
        #expect(!code.contains("static let shared"))
        // The walk of everything else is set going once, however often the gate asks.
        #expect(count("ProtectedFolders.rest()") == 1 && code.contains("if !walked {\n                walked = true"))
        // And the launch ground itself wakes the gate: a finger, a key, a pointer.
        #expect(count("ProtectedSignals.somebodyIsHere()") == 1)
        #expect(code.contains("listening = ProtectedSignals.listenForSomebody()") && code.contains("ProtectedSignals.stop(listening)"))
        #expect(code.contains(".map { make($0) }") && !code.contains(".map(make)"))
        // What takes the store away and reads one back asks the same canary, and what a lock
        // kept it from putting back is done at a wake-up.
        #expect(code.contains("saver: saver, protected: protected\n        )"))
        // And a save a lock refused is written at a wake-up too: both ask the canary themselves.
        #expect(code.contains("for await _ in protected.changes() {\n                await carrier.finishOwed()\n                await saver.owedNow()\n            }"))
        #expect(code.contains("saver = StoreSaver(store: store, file: opened.file, protected: protected)"))
    }

    // MARK: - The platform's signals

    @Test("Every event listened for wakes the wait, and all are subscribed to before the stream is handed over")
    func events() async throws {
        let center = NotificationCenter()
        let names = ["one", "two", "three"].map { Notification.Name("fediqo.test.\($0)") }
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        let stream = ProtectedSignals.changes(names.map { (center, $0) }) { name in heard.withLock { $0.append(name) } }
        // Posted with nothing awaited since the stream was made: it was listening already, and
        // each is heard as it is posted — so nothing below waits for what may not come.
        for name in names { center.post(name: name, object: nil) }
        try #require(heard.withLock { $0 } == names.map(\.rawValue))
        // And what was heard is in the stream: one wake-up, however many arrived together.
        var woken = stream.makeAsyncIterator()
        await woken.next()
    }

    @Test("The platform's own events are named, and its level is asked without anything being launched")
    func thePlatform() {
        #if os(macOS)
        let names = ProtectedSignals.events.map(\.name.rawValue)
        #expect(names.contains("com.apple.screenIsUnlocked") && names.contains("com.apple.screenIsLocked"))
        #expect(names.contains("NSApplicationProtectedDataDidBecomeAvailableNotification"))
        // What a person coming back produces, whatever the system announces.
        #expect(names.contains(NSApplication.didChangeOcclusionStateNotification.rawValue))
        #expect(names.contains(NSWindow.didBecomeKeyNotification.rawValue))
        #expect(names.count == 10)
        #endif
        #expect(ProtectedSignals.events.map(\.name).contains(ProtectedSignals.somebody))
        // A touch on the launch ground is heard by the platform's own stream.
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        let stream = ProtectedSignals.changes { name in heard.withLock { $0.append(name) } }
        ProtectedSignals.somebodyIsHere()
        #expect(heard.withLock { $0 } == [ProtectedSignals.somebody.rawValue])
        _ = stream
        _ = ProtectedSignals.unlockedForSomebody()
        let store = scratch().appendingPathComponent("never-made-\(UUID().uuidString)")
        _ = ProtectedSignals.protected(store: store)
        // Whatever it says here — locked, not, or nothing — asking it is safe from any process.
        _ = ProtectedSignals.screenLocked()
        let protected = ProtectedSignals.protected(store: store)
        _ = protected.flag()
        _ = protected.unlockedForSomebody()
    }
}

/// What SQLite says of a file that is not a database — which a lock might make it say.
enum DatabaseErrorStandIn {
    static let notADatabase = DatabaseError(resultCode: .SQLITE_NOTADB)
}
