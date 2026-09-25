import CryptoKit
import FediqoCore
import FediqoPersistence
import Foundation
import Synchronization
import Testing
@testable import FediqoUI

/// #253, #6 on the shell: the steps a hold and an offer walk on two sessions joined by a pipe,
/// what each question says, that both sides record one line under the other device's name,
/// that the store is held still from the first byte to every way out, and that every word is in
/// every language.
@Suite("Moving to and from a device nearby, on the shell", .serialized)
@MainActor
struct NearbyTests {
    /// A carrier that writes a real, small package and counts what it was asked, on no store.
    final class FakeCarrier: StoreCarrier, @unchecked Sendable {
        let device: String
        var weight = PackageWeight(withoutPictures: 100, withPictures: 300, free: 1 << 40, holdsStore: false)
        private let counts = Mutex<(taken: [PackageSummary.Contents], read: [Bool])>(([], []))
        let staging: URL

        init(device: String) {
            self.device = device
            staging = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-nearby-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        var taken: [PackageSummary.Contents] { counts.withLock { $0.taken } }
        var read: [Bool] { counts.withLock { $0.read } }

        func weigh() async throws -> PackageWeight { weight }
        func stagingFolder() -> URL { staging }

        func takeAway(
            to url: URL, key: PackageKey, pictures: Bool, contents: PackageSummary.Contents,
            progress: @escaping @Sendable (PackageProgress) -> Void
        ) async throws {
            let body = Data(repeating: 5, count: 5000)
            let summary = PackageSummary(
                contents: contents, sources: [.init(host: "one.example", kind: .mastodon)], posts: 12, timelines: 1,
                takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: pictures, bytes: body.count,
                hasSecrets: true, device: device, appVersion: "0.7.0", entryCount: 1
            )
            let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: 1000)
            var offset = 0
            try writer.add(.secrets, name: "secrets", bytes: body.count) { most in
                guard offset < body.count else { return nil }
                let end = min(body.count, offset + most)
                defer { offset = end }
                return body[offset..<end]
            }
            try writer.finish()
            counts.withLock { $0.taken.append(contents) }
            progress(PackageProgress(done: body.count, total: body.count))
        }

        func preview(_ url: URL, key: PackageKey) async throws -> PackageSummary {
            try PackageReader(at: url).open(with: key)
        }

        /// Where set, a read back tells half its progress and waits here before the rest.
        var gate: Gate?

        func readBack(_ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void) async throws {
            let reader = try PackageReader(at: url)
            _ = try reader.open(with: key)
            progress(PackageProgress(done: 2_500, total: 5_000))
            await gate?.wait()
            for try await entry in reader.entries() { for try await _ in entry.chunks {} }
            progress(PackageProgress(done: 5_000, total: 5_000))
            counts.withLock { $0.read.append(replacing) }
        }
    }

    /// Opened once, and every wait on it — before or after — goes on.
    final class Gate: Sendable {
        private let opened: AsyncStream<Void>
        private let opener: AsyncStream<Void>.Continuation

        init() {
            (opened, opener) = AsyncStream<Void>.makeStream()
        }

        func open() { opener.finish() }
        func wait() async { for await _ in opened {} }
    }

    /// Two sessions' worth of flow on one pipe: the device that holds and the one that offers.
    @MainActor
    final class Two {
        let link = PipeNearbyLink()
        let holding: ShellNearby
        let offering: ShellNearby
        let onto = FakeCarrier(device: "a tablet")
        let from = FakeCarrier(device: "a laptop")
        /// What each side said about holding still, and how often the receiver adopted.
        final class Log: Sendable {
            let stillness = Mutex<[String]>([])
            let adopted = Mutex(0)
            /// What each side asked of the platform about staying awake, in order.
            let awake = Mutex<[String]>([])
        }

        let log = Log()

        init() {
            holding = ShellNearby(work: SourceWork(), awake: StayAwake { [log] on in log.awake.withLock { $0.append("hold \(on)") } })
            offering = ShellNearby(work: SourceWork(), awake: StayAwake { [log] on in log.awake.withLock { $0.append("offer \(on)") } })
            holding.holdStill = { [log] on in log.stillness.withLock { $0.append("hold \(on)") } }
            offering.holdStill = { [log] on in log.stillness.withLock { $0.append("offer \(on)") } }
        }

        func begin() async {
            // A hold put away a moment ago leaves the pipe as its stream ends; a second round
            // starts once it has, as a browser lists only devices still holding.
            for _ in 0..<600 where !link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            holding.beginHold(with: onto, link: link, device: "a tablet") { [log] in log.adopted.withLock { $0 += 1 } }
            await settle(holding) { if case .holding(let code) = $0 { !code.isEmpty } else { false } }
            offering.beginOffer(with: from, link: link)
            await settle(offering) { if case .browsing(let peers) = $0 { !peers.isEmpty } else { false } }
        }

        func offer(rides: ShellNearby.Rides = .withoutPictures) async {
            guard case .holding(let code) = holding.step else { Issue.record("no code"); return }
            offering.picked = offering.peers.first
            offering.offer(code: code, rides: rides)
            guard case .checkingMark(let check) = offering.step else { Issue.record("no mark asked"); return }
            #expect(check.mark == holding.mark, "the sender works the receiver's mark out from the digits")
            #expect(offering.asking == offering.step)
            offering.markMatched(with: from, link: link, device: "a laptop") {}
            await settle(offering) { if case .asking = $0 { true } else { false } }
            await settle(holding) { if case .asking = $0 { true } else { false } }
        }

        /// Waits for the step `done` names, woken by the step changing rather than by a clock:
        /// a bound of a few seconds is for a runner that is slow, never a wait a test pays.
        /// Waits for the step `done` names. **The budget is turns, not wall time**: sixteen
        /// half-second periods in which this test held the main actor and the step did not come.
        /// A step is delivered on the main actor, so while other suites hold it for forty
        /// seconds — which a slow runner does — no step can arrive and none of that is the
        /// move's delay; such a stall is one turn, not the whole budget.
        func settle(_ nearby: ShellNearby, until done: (ShellNearby.Step?) -> Bool) async {
            // Bounded both ways: sixteen idle turns, and — for a step that changes without end
            // and never to the one named — two thousand changes or two minutes of the wall.
            var turns = 16
            var changes = 2000
            let ceiling = ContinuousClock.now + .seconds(120)
            while turns > 0, changes > 0, ContinuousClock.now < ceiling {
                // Armed before the check, so a step assigned between the two is not missed.
                let changed = StepSignal()
                withObservationTracking { _ = nearby.step } onChange: { changed.fire() }
                if done(nearby.step) { return }
                if await changed.wait(most: .milliseconds(500)) == .clock {
                    turns -= 1
                    // Whatever was queued on the main actor behind this wake runs before it is judged.
                    await Task.yield()
                } else {
                    changes -= 1
                }
            }
            if !done(nearby.step) { Issue.record("never settled: \(String(describing: nearby.step))") }
        }

        /// One wake, fired by the step changing or by a clock, whichever is first — and which.
        final class StepSignal: Sendable {
            enum Wake: Sendable { case change, clock }

            private let held = Mutex<(fired: Wake?, waiter: CheckedContinuation<Wake, Never>?)>((nil, nil))

            func fire(_ wake: Wake = .change) {
                let (waiter, first) = held.withLock { held -> (CheckedContinuation<Wake, Never>?, Wake?) in
                    guard held.fired == nil else { return (nil, nil) }
                    held.fired = wake
                    defer { held.waiter = nil }
                    return (held.waiter, wake)
                }
                if let waiter, let first { waiter.resume(returning: first) }
            }

            func wait(most: Duration) async -> Wake {
                let clock = Task { [self] in
                    try? await Task.sleep(for: most)
                    fire(.clock)
                }
                defer { clock.cancel() }
                return await withCheckedContinuation { (continuation: CheckedContinuation<Wake, Never>) in
                    let now = held.withLock { held -> Wake? in
                        if let fired = held.fired { return fired }
                        held.waiter = continuation
                        return nil
                    }
                    if let now { continuation.resume(returning: now) }
                }
            }
        }

        func end() {
            holding.dismiss()
            offering.dismiss()
            try? FileManager.default.removeItem(at: onto.staging)
            try? FileManager.default.removeItem(at: from.staging)
        }
    }

    @Test("Both say yes: the package moves, the receiver adopts, both record one line under the other's name, and the store was held still from the first byte to the end")
    func wholeWalk() async throws {
        let two = Two()
        defer { two.end() }
        await two.begin()
        #expect(two.holding.sheet != nil && two.offering.sheet == .pick)
        #expect(two.holding.side == .holding && two.offering.side == .offering)
        #expect(two.offering.peers.map(\.name) == ["a tablet"])
        #expect(two.offering.weight == two.from.weight)
        await two.offer()

        guard case .asking(let there) = two.holding.step, case .asking(let here) = two.offering.step else { return }
        #expect(there.receiving && !here.receiving)
        #expect(there.peer == "a laptop" && here.peer == "a tablet")
        #expect(there.offer.summary.posts == 12 && !there.held)
        #expect(two.holding.asking == two.holding.step && two.holding.sheet == nil, "the code sheet gave way to the question")
        #expect(two.offering.code == two.holding.code, "both screens show the same code")
        #expect(two.from.taken == [.whole])

        two.offering.answer(true)
        #expect(two.offering.step == .waiting(peer: "a tablet"))
        two.holding.answer(true)
        await two.settle(two.holding) { if case .done = $0 { true } else { false } }
        await two.settle(two.offering) { if case .done = $0 { true } else { false } }
        #expect(two.onto.read == [false])
        for _ in 0..<50 where two.log.adopted.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(two.log.adopted.withLock { $0 } == 1)
        #expect(two.offering.asking == two.offering.step)

        // One line each, under the other device's name, ended.
        let held = two.holding.work.record
        let sent = two.offering.work.record
        #expect(held.count == 1 && held[0].purpose == .nearbyMove && held[0].source == SourceWork.nearbyKey("a laptop"))
        #expect(sent.count == 1 && sent[0].purpose == .nearbyMove && sent[0].source == SourceWork.nearbyKey("a tablet"))
        #expect(SourceWork.nearbyKey("Rex's iPad") == SourceWork.foldKey(SourceWork.nearbyKey("Rex's iPad")), "a device's name keeps its case")
        #expect(SourceWork.foldKey("A.Example") == "a.example")
        #expect(SourceAct.shown(held[0].source) == "a laptop", "drawn by its name, keyed so it never reads as a host")
        #expect(two.holding.work.log.sources == [SourceWork.nearbyKey("a laptop")], "renamed from the unnamed join, not added beside it")
        #expect(two.holding.mark.count == 4)
        #expect(two.holding.work.now.isEmpty && two.offering.work.now.isEmpty)
        // Held still on the sender from the package's writing, on the receiver from its yes, and let go once.
        #expect(two.log.stillness.withLock { $0 }.filter { $0.hasPrefix("offer") }.map { $0.hasSuffix("true") } == [true, false])
        #expect(two.log.stillness.withLock { $0 }.filter { $0.hasPrefix("hold") }.map { $0.hasSuffix("true") } == [true, false])
        two.holding.dismiss()
        two.offering.dismiss()
        #expect(two.holding.step == nil && !two.holding.isUp && two.offering.step == nil)
    }

    @Test("The receiver's read back arrives as progress on its sheet, Cancel dimmed; neither side's progress sheet taken down by the system stops the move")
    func readBackProgress() async throws {
        let two = Two()
        let gate = Gate()
        two.onto.gate = gate
        defer {
            gate.open()
            two.end()
        }
        await two.begin()
        await two.offer()
        two.offering.answer(true)
        #expect(two.offering.sheet == .progress, "the sender waits on its progress sheet")
        two.offering.sheetPutAway()
        #expect(two.offering.step == .waiting(peer: "a tablet"), "taken down by the system, the move goes on")
        let waiting = try #require(NearbyFlow.progress(two.offering, language: .english))
        #expect(waiting.title == "Moving to a tablet" && waiting.stage == "Waiting for the other device to agree" && waiting.canCancel)
        #expect(waiting.code == "Code " + NearbyCode.spaced(two.holding.code), "the code on both")
        two.holding.answer(true)
        await two.settle(two.holding) { if case .settling(let progress?, _) = $0 { progress.done == 2_500 } else { false } }
        #expect(two.holding.sheet == .progress)
        let reading = try #require(NearbyFlow.progress(two.holding, language: .english))
        #expect(reading.title == "Holding from a laptop" && reading.stage == "Reading it back")
        #expect(reading.fraction == 0.5 && !reading.canCancel)
        #expect(reading.code == waiting.code)
        #expect(NearbySection.measured(two.holding.step) == PackageProgress(done: 2_500, total: 5_000), "the tab's row draws a bar too")
        two.holding.sheetPutAway()
        two.holding.dismiss()
        if case .settling = two.holding.step {} else { Issue.record("the read back was stopped") }
        gate.open()
        await two.settle(two.holding) { if case .done = $0 { true } else { false } }
        await two.settle(two.offering) { if case .done = $0 { true } else { false } }
        #expect(two.onto.read == [false])
    }

    @Test("Both devices stay awake from the first press to the end of the run, a drop and a refusal included, and are let sleep once on every way out")
    func staysAwake() async throws {
        let two = Two()
        defer { two.end() }
        func asked(_ side: String) -> [Bool] {
            two.log.awake.withLock { $0 }.filter { $0.hasPrefix(side) }.map { $0.hasSuffix("true") }
        }
        // Put away with the code and the list up.
        await two.begin()
        #expect(two.holding.awake.on && two.offering.awake.on, "awake while the code and the list are up")
        two.holding.dismiss()
        two.offering.dismiss()
        #expect(!two.holding.awake.on && !two.offering.awake.on)
        #expect(asked("hold") == [true, false] && asked("offer") == [true, false])

        // A no: the side that said it ends at once, the other on its refusal.
        await two.begin()
        await two.offer()
        #expect(two.offering.awake.on && two.holding.awake.on, "awake through the mark and the question")
        two.holding.answer(false)
        two.offering.answer(true)
        await two.settle(two.offering) { $0 == .refused(.refusedThere) }
        #expect(!two.holding.awake.on && !two.offering.awake.on, "a refusal on screen is the run ended")
        two.offering.dismiss()
        #expect(asked("hold") == [true, false, true, false] && asked("offer") == [true, false, true, false])

        // A drop midway, back to waiting for the other, and on to the end.
        await two.begin()
        await two.offer()
        two.link.cutNext(afterBytesFrames: 0)
        two.offering.answer(true)
        two.holding.answer(true)
        await two.settle(two.holding) { if case .done = $0 { true } else { false } }
        await two.settle(two.offering) { if case .done = $0 { true } else { false } }
        #expect(asked("hold") == [true, false, true, false, true, false], "awake across the drop, told once each way")
        #expect(asked("offer") == [true, false, true, false, true, false])
    }

    @Test("A no on either side closes with nothing written, and the sign-ins-only choice rides as that")
    func refusals() async throws {
        let two = Two()
        defer { two.end() }
        await two.begin()
        await two.offer(rides: .signInsOnly)
        guard case .asking(let there) = two.holding.step else { return }
        #expect(there.offer.summary.contents == .signInsOnly)
        #expect(two.from.taken == [.signInsOnly])
        two.holding.answer(false)
        #expect(two.holding.step == nil && two.holding.work.now.isEmpty)
        two.offering.answer(true)
        await two.settle(two.offering) { $0 == .refused(.refusedThere) }
        #expect(two.onto.read.isEmpty)
        #expect(two.holding.work.record.count == 1 && two.offering.work.record.count == 1)
        #expect(two.log.stillness.withLock { $0 }.last?.hasSuffix("false") == true)
        two.offering.dismiss()

        await two.begin()
        await two.offer()
        two.offering.answer(false)
        #expect(two.offering.step == nil)
        two.holding.answer(true)
        await two.settle(two.holding) { $0 == .refused(.refusedThere) }
        #expect(two.onto.read.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: two.onto.staging.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("incoming-") })
    }

    @Test("A wrong code is its own refusal, and a denied look nearby reads as not allowed")
    func wrongCodeAndDenied() async throws {
        let two = Two()
        defer { two.end() }
        await two.begin()
        guard case .holding(let code) = two.holding.step else { return }
        two.offering.picked = two.offering.peers.first
        two.offering.offer(code: code == "000000" ? "000001" : "000000", rides: .withoutPictures)
        guard case .checkingMark(let check) = two.offering.step else { return }
        #expect(check.mark != two.holding.mark, "a wrong code shows a different mark before anything joins")
        two.offering.markMismatched()
        #expect(two.offering.sheet == .pick && two.offering.work.record.isEmpty, "not the same: back to the list, nothing joined")
        two.offering.offer(code: code == "000000" ? "000001" : "000000", rides: .withoutPictures)
        two.offering.markMatched(with: two.from, link: two.link, device: "a laptop") {}
        await two.settle(two.offering) { $0 == .refused(.wrongCode) }
        await two.settle(two.holding) { if case .holding(let next) = $0 { next != code } else { false } }
        #expect(two.offering.work.record.count == 1, "the try is on the record, under the device pointed at")
        two.offering.dismiss()
        two.holding.dismiss()

        let denied = PipeNearbyLink()
        denied.deny()
        let nearby = ShellNearby(work: SourceWork())
        nearby.beginOffer(with: two.from, link: denied)
        await two.settle(nearby) { $0 == .refused(.notAllowed) }
        nearby.dismiss()
        nearby.beginHold(with: two.onto, link: denied, device: "a tablet") {}
        await two.settle(nearby) { $0 == .refused(.notAllowed) }
        nearby.dismiss()
        // An ill-formed code or no device picked goes nowhere.
        nearby.beginOffer(with: two.from, link: two.link)
        nearby.offer(code: "12345", rides: .withoutPictures)
        if case .browsing = nearby.step {} else { Issue.record("went with five digits") }
        nearby.dismiss()
    }

    @Test("On a session, the move holds the room limit still (#249) and lets it go on every way out")
    func holdsTheSessionStill() async throws {
        let session = ShellSession(http: FixtureHTTP())
        let link = PipeNearbyLink()
        let onto = FakeCarrier(device: "a tablet")
        let from = FakeCarrier(device: "a laptop")
        defer { try? FileManager.default.removeItem(at: onto.staging); try? FileManager.default.removeItem(at: from.staging) }
        let holding = ShellNearby(work: SourceWork())
        holding.beginHold(with: onto, link: link, device: "a tablet") {}
        for _ in 0..<200 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        session.nearby.beginOffer(with: from, link: link)
        for _ in 0..<200 where session.nearby.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!session.holdsStill)
        guard case .holding(let code) = holding.step else { Issue.record("no code"); return }
        session.nearby.picked = session.nearby.peers.first
        session.nearby.offer(code: code, rides: .withoutPictures)
        #expect(!session.holdsStill, "nothing held while the mark is asked")
        session.nearby.markMatched(with: from, link: link, device: "a laptop") {}
        #expect(session.holdsStill, "not held before the first byte moved")
        for _ in 0..<400 { if case .asking = session.nearby.step { break }; try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.holdsStill)
        session.nearby.answer(false)
        #expect(!session.holdsStill && session.nearby.step == nil)
        holding.dismiss()
    }

    /// A few turns of the main actor: long enough for a put-away judged a turn later to act.
    static func turns() async {
        for _ in 0..<4 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A sender's session over `two`'s pipe, its question up, answered the way the card answers:
    /// through `settle`, which takes the question down before it hands over the answer.
    private static func sender(_ two: Two) async -> (ShellSession, NearbyFlow)? {
        let session = ShellSession(http: FixtureHTTP())
        session.carrier = two.from
        session.nearbyLink = two.link
        session.deviceName = "a laptop"
        two.holding.beginHold(with: two.onto, link: two.link, device: "a tablet") {}
        await two.settle(two.holding) { if case .holding(let code) = $0 { !code.isEmpty } else { false } }
        session.nearby.beginOffer(with: two.from, link: two.link)
        await two.settle(session.nearby) { if case .browsing(let peers) = $0 { !peers.isEmpty } else { false } }
        guard case .holding(let code) = two.holding.step else { Issue.record("no code"); return nil }
        session.nearby.picked = session.nearby.peers.first
        session.nearby.offer(code: code, rides: .withoutPictures)
        guard case .checkingMark = session.nearby.step else { Issue.record("no mark asked"); return nil }
        return (session, NearbyFlow(session: session))
    }

    private static func press(_ answer: ShellConfirmAnswer, on flow: NearbyFlow, _ nearby: ShellNearby) {
        guard let asked = nearby.asking else { Issue.record("nothing asked"); return }
        ShellConfirmAnswer.settle(answer, asked: asked, item: flow.asking, onChoice: flow.answer)
    }

    @Test("\"The same\" and a yes, pressed on the card, move the step on: the question going down first does not undo them")
    func yesThroughTheCard() async throws {
        let two = Two()
        defer { two.end() }
        guard let (session, flow) = await Self.sender(two) else { return }
        defer { session.nearby.dismiss() }
        Self.press(.choice(ShellQuestion.yes), on: flow, session.nearby)
        await Self.turns()
        #expect(session.nearby.sheet != .pick, "\"The same\" was not taken as put away")
        switch session.nearby.step {
        case .packing, .connecting, .asking: break
        default: Issue.record("the mark's yes did nothing: \(String(describing: session.nearby.step))")
        }
        await two.settle(session.nearby) { if case .asking = $0 { true } else { false } }
        await two.settle(two.holding) { if case .asking = $0 { true } else { false } }
        Self.press(.choice(ShellQuestion.yes), on: flow, session.nearby)
        await Self.turns()
        #expect(session.nearby.step == .waiting(peer: "a tablet"), "the ask's yes waits for the other screen")
        // The sheet let down after the yes writes the clearing back once more, with no question up.
        flow.asking.wrappedValue = nil
        await Self.turns()
        #expect(session.nearby.step == .waiting(peer: "a tablet"), "a clearing with no question up stops nothing")
    }

    @Test("Put away on the card, the mark question goes back to the list and the ask closes")
    func cancelThroughTheCard() async throws {
        let two = Two()
        defer { two.end() }
        guard let (session, flow) = await Self.sender(two) else { return }
        defer { session.nearby.dismiss() }
        Self.press(.cancel, on: flow, session.nearby)
        await Self.turns()
        #expect(session.nearby.sheet == .pick, "not the same: back to the list")
        if case .browsing = session.nearby.step {} else { Issue.record("not back to the list: \(String(describing: session.nearby.step))") }

        guard case .holding(let code) = two.holding.step else { Issue.record("no code"); return }
        session.nearby.offer(code: code, rides: .withoutPictures)
        Self.press(.choice(ShellQuestion.yes), on: flow, session.nearby)
        await two.settle(session.nearby) { if case .asking = $0 { true } else { false } }
        Self.press(.cancel, on: flow, session.nearby)
        await Self.turns()
        #expect(session.nearby.step == nil, "the ask put away closes the move")
    }

    @Test("A hold put away before its yes gives back no copies it never took")
    func cancelledHoldLeavesTheCopiesRunning() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-nearby-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try MediaCache(directory: folder)
        let disk = DiskCopies(cache)
        let link = PipeNearbyLink()
        let onto = FakeCarrier(device: "a tablet")
        defer { try? FileManager.default.removeItem(at: onto.staging) }
        // Put away with the code up: the copies were never held, so nothing is resumed (a resume
        // of a queue not suspended traps the process — this test would not come back).
        let nearby = ShellNearby(work: SourceWork())
        nearby.beginHold(with: onto, link: link, device: "a tablet", pictures: disk) {}
        nearby.dismiss()
        nearby.beginHold(with: onto, link: link, device: "a tablet", pictures: disk) {}
        nearby.dismiss()
        disk.store(Data("x".utf8), host: "a.example", url: URL(string: "https://a.example/one.jpg")!)
        await disk.settled()
        #expect(cache.bytes(host: "a.example") == 1, "the copies still run after a hold put away twice")
    }

    /// The receiver's question up over `two`'s pipe, with `disk` as the copies a yes holds.
    private static func asked(_ two: Two, pictures disk: DiskCopies) async -> Bool {
        two.holding.beginHold(with: two.onto, link: two.link, device: "a tablet", pictures: disk) {}
        await two.settle(two.holding) { if case .holding(let code) = $0 { !code.isEmpty } else { false } }
        two.offering.beginOffer(with: two.from, link: two.link)
        await two.settle(two.offering) { if case .browsing(let peers) = $0 { !peers.isEmpty } else { false } }
        await two.offer()
        guard case .asking = two.holding.step else { Issue.record("no question on the receiver"); return false }
        return true
    }

    /// Whether the copies run: a write and a read of it come back within a couple of seconds.
    /// A queue left suspended never answers, so this asks off to the side and stops looking.
    private static func running(_ disk: DiskCopies, _ cache: MediaCache, _ name: String) async -> Bool {
        let done = Mutex(false)
        Task.detached {
            disk.store(Data("x".utf8), host: "a.example", url: URL(string: "https://a.example/\(name).jpg")!)
            await disk.settled()
            done.withLock { $0 = true }
        }
        for _ in 0..<200 where !done.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        return done.withLock { $0 }
    }

    @Test("A yes put away before its hold of the copies returns, or after, leaves them running; at most one hold is ever out")
    func yesThenPutAwayLeavesTheCopiesRunning() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-nearby-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try MediaCache(directory: folder)
        let disk = DiskCopies(cache)
        let two = Two()
        defer { two.end() }

        // Before: the test holds the copies first, so the yes's hold is left pending behind it.
        guard await Self.asked(two, pictures: disk) else { return }
        await disk.hold()
        two.holding.answer(true)
        await Self.turns()
        two.holding.dismiss()
        disk.release()
        #expect(await Self.running(disk, cache, "one"), "a pending hold that returns after its move is given straight back")
        two.offering.dismiss()

        // After: the yes's hold has returned, and the put-away releases it, once.
        guard await Self.asked(two, pictures: disk) else { return }
        two.holding.answer(true)
        await Self.turns()
        two.holding.dismiss()
        #expect(await Self.running(disk, cache, "two"), "a returned hold is released on the way out")
        #expect(cache.bytes(host: "a.example") == 2)
    }

    // MARK: - What is said

    private static let offer = NearbyOffer(
        id: "o", summary: PackageSummary(
            sources: [.init(host: "one.example", kind: .mastodon), .init(host: "forum.example", kind: .discuz)],
            posts: 12, timelines: 2, takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: true,
            bytes: 3_000, hasSecrets: true, device: "a laptop", appVersion: "0.7.0", entryCount: 5
        ), fileBytes: 1_300_000
    )

    @Test("The question names the count, the other device and the size; replaces only on a loss; sign-ins alone are asked as that")
    func questions() {
        let hold = ShellQuestion.nearbyAsk(.init(offer: Self.offer, peer: "a laptop", held: false, receiving: true), language: .english)
        #expect(hold.title == "Hold 12 posts from a laptop?")
        #expect(hold.line.contains("one.example, forum.example") && hold.line.contains(UsagePane.size(1_300_000, language: .english)))
        #expect(!hold.warns && hold.choices.map(\.role) == [.primary] && hold.cancel == "Refuse")
        #expect(hold.help?.contains("cannot be stopped") == true)

        let replace = ShellQuestion.nearbyAsk(.init(offer: Self.offer, peer: "a laptop", held: true, receiving: true), language: .english)
        #expect(replace.warns && replace.choices.map(\.role) == [.destructive] && replace.help?.contains("replaced") == true)

        let move = ShellQuestion.nearbyAsk(.init(offer: Self.offer, peer: "a tablet", held: true, receiving: false), language: .english)
        #expect(move.title == "Move 12 posts to a tablet?")
        #expect(!move.warns, "the sender loses nothing")
        #expect(move.help?.contains("nowhere else") == true)

        let one = NearbyOffer(id: "o", summary: PackageSummary(
            sources: [], posts: 1, timelines: 0, takenAt: Self.offer.summary.takenAt, withPictures: false, bytes: 0,
            hasSecrets: false, device: "", appVersion: "", entryCount: 0
        ), fileBytes: 10)
        #expect(ShellQuestion.nearbyAsk(.init(offer: one, peer: "a tablet", held: false, receiving: false), language: .english).title == "Move one post to a tablet?")
        #expect(ShellQuestion.nearbyAsk(.init(offer: one, peer: "a tablet", held: false, receiving: true), language: .taiwanese).title == "要從 a tablet 接收 1 則貼文嗎？")

        let signIns = NearbyOffer(id: "o", summary: PackageSummary(
            contents: .signInsOnly, sources: [.init(host: "one.example", kind: .mastodon)], posts: 0, timelines: 0,
            takenAt: Self.offer.summary.takenAt, withPictures: false, bytes: 40, hasSecrets: true, device: "a laptop",
            appVersion: "0.7.0", entryCount: 1
        ), fileBytes: 200)
        let held = ShellQuestion.nearbyAsk(.init(offer: signIns, peer: "a laptop", held: true, receiving: true), language: .english)
        #expect(held.title == "Hold the sign-ins from a laptop?")
        #expect(!held.warns, "sign-ins alone replace no store")
        #expect(ShellQuestion.nearbyDone(signIns.summary, peer: "a laptop", language: .english).line.contains("nothing else"))
        #expect(ShellQuestion.nearbyDone(Self.offer.summary, peer: "a tablet", language: .english).title == "Done with a tablet")
    }

    @Test("Each refusal is its own sentence; not allowed says this device was not allowed to look, not that nobody is there")
    func refusalsAreEachTheirOwn() {
        let refusals: [NearbyRefusal] = [
            .notAllowed, .wrongCode, .refusedThere, .lost, .malformed, .unsure, .guessing, .timedOut, .package(.altered), .package(.newer),
            .noRoom(needed: 2_000_000, free: 1_000), .other("the disk said no"),
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            let said = refusals.map { ShellQuestion.nearbyRefused($0, language: language) }
            #expect(Set(said.map(\.title)).count == refusals.count, "each has its own title in \(language)")
            for question in said {
                #expect(question.choices.isEmpty && question.cancel != nil)
                #expect(!question.title.contains("nearby.") && !question.line.contains("nearby.") && !question.line.contains("%"))
            }
        }
        let denied = ShellQuestion.nearbyRefused(.notAllowed, language: .english)
        #expect(denied.title == "This device was not allowed to look nearby")
        #expect(!denied.title.lowercased().contains("nobody") && !denied.line.lowercased().contains("nobody"))
        #expect(ShellQuestion.nearbyRefused(.package(.altered), language: .english) == ShellQuestion.carryRefused(.package(.altered), language: .english))
        let mark = ShellQuestion.nearbyMark("AB12", peer: "a tablet", language: .english)
        #expect(mark.title == "Does the other screen show AB12?" && mark.line.contains("a tablet"))
        #expect(!mark.warns && mark.cancel == "Not the same" && mark.choices.map(\.id) == [ShellQuestion.yes])
    }

    @Test("The progress line says which way, how far, and a plain estimate from the pace; the code reads by threes")
    func progressLine() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let progress = PackageProgress(done: 1_000_000, total: 3_000_000)
        let early = NearbySection.progressLine(progress, peer: "a tablet", sending: true, since: start, now: start, language: .english)
        #expect(early == "Moving to a tablet · \(UsagePane.size(1_000_000, language: .english)) of \(UsagePane.size(3_000_000, language: .english))")
        let later = NearbySection.progressLine(progress, peer: "a tablet", sending: false, since: start, now: start.addingTimeInterval(10), language: .english)
        #expect(later.hasPrefix("Moving from a tablet") && later.hasSuffix("under a minute left"))
        #expect(NearbySection.estimate(progress, since: start, now: start.addingTimeInterval(100)) == .minutes(4))
        #expect(NearbySection.estimate(progress, since: start, now: start.addingTimeInterval(40)) == .minutes(2))
        #expect(NearbySection.estimate(PackageProgress(done: 0, total: 5), since: start, now: start.addingTimeInterval(30)) == nil)
        #expect(NearbySection.estimate(progress, since: nil, now: start) == nil)
        #expect(NearbySection.Estimate.minutes(1).text(language: .english) == "about a minute left")
        #expect(NearbySection.Estimate.minutes(4).text(language: .taiwanese) == "大約還要 4 分鐘")
        #expect(NearbyCode.spaced("123456") == "123 456" && NearbyCode.spaced("12") == "12")
        #expect(NearbySection.statusKey(.settling(nil, peer: "x")) == "nearby.settling" && NearbySection.statusKey(nil) == nil)
        #expect(NearbyPickSheet.ridesLabel(.withPictures, weight: PackageWeight(withoutPictures: 1, withPictures: 2_000_000, free: 0, holdsStore: false), language: .english)
            == "Everything, with pictures (\(UsagePane.size(2_000_000, language: .english)))")
        #expect(NearbyPickSheet.ridesLabel(.signInsOnly, weight: nil, language: .english) == "Sign-ins only")
    }

    @Test("Every word said is there in every language, and the purpose has its glyph")
    func theWords() throws {
        let keys = [
            "work.purpose.nearbyMove", "nearby.title", "nearby.line", "nearby.help", "nearby.idle",
            "nearby.hold", "nearby.hold.help", "nearby.offer", "nearby.offer.help",
            "nearby.packing", "nearby.connecting", "nearby.waiting", "nearby.reconnecting", "nearby.settling",
            "nearby.moving.to", "nearby.moving.from", "nearby.code.line", "nearby.left.soon", "nearby.left.minutes",
            "nearby.code.spoken", "nearby.hold.sheet.title", "nearby.hold.sheet.line", "nearby.hold.sheet.help",
            "nearby.pick.sheet.title", "nearby.pick.sheet.line", "nearby.pick.sheet.help", "nearby.pick.looking",
            "nearby.pick.row.brief", "nearby.pick.code", "nearby.pick.rides", "nearby.pick.go",
            "nearby.rides.withPictures", "nearby.rides.withoutPictures", "nearby.rides.signInsOnly",
            "nearby.ask.hold.title", "nearby.ask.move.title", "nearby.ask.hold.signIns.title", "nearby.ask.move.signIns.title",
            "nearby.ask.line", "nearby.ask.hold.help", "nearby.ask.move.help", "nearby.ask.hold.go", "nearby.ask.move.go",
            "nearby.ask.refuse", "nearby.done.title", "nearby.done.signIns.line",
            "nearby.unnamed", "nearby.mark.spoken", "nearby.mark.line",
            "nearby.mark.ask.title", "nearby.mark.ask.line", "nearby.mark.ask.help", "nearby.mark.ask.same", "nearby.mark.ask.different",
        ] + ["notAllowed", "wrongCode", "refusedThere", "lost", "malformed", "unsure", "guessing", "timedOut", "other"]
            .flatMap { ["nearby.refused.\($0).title", "nearby.refused.\($0).line"] }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
        #expect(SourceWork.Purpose.nearbyMove.symbol != SourceWork.Purpose.readBack.symbol)
        #expect(L10n.t("work.purpose.nearbyMove", language: .taiwanese).contains("鄰近"))
    }

    @Test("The group is on Preferences' Move tab under Take away, its flow is one modifier on the pane whatever tab is in front, the root's chain is untouched, and the plists ask what the system asks")
    func whereItLives() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = root.appendingPathComponent("Sources/FediqoUI")
        let prefs = try String(contentsOf: shell.appendingPathComponent("Shell/PreferencesPane.swift"), encoding: .utf8)
        let move = try #require(prefs.range(of: "private var move: some View {"))
        let next = try #require(prefs.range(of: "\n    }\n", range: move.upperBound..<prefs.endIndex))
        let tab = prefs[move.upperBound..<next.lowerBound]
        #expect(tab.contains("CarrySection(session: session)\n            NearbySection(session: session)"), "beside Take away, under it")
        let choices = try #require(prefs.range(of: "private var choices: some View {"))
        let choicesEnd = try #require(prefs.range(of: "\n    }\n", range: choices.upperBound..<prefs.endIndex))
        #expect(!prefs[choices.upperBound..<choicesEnd.lowerBound].contains("Section(session: session)"), "off the first tab")
        #expect(prefs.contains("case .move: move"))
        // On the pane, after the page's switch: a tab changed mid-move tears nothing down.
        let flow = try #require(prefs.range(of: ".modifier(NearbyFlow(session: session))"))
        let form = try #require(prefs.range(of: "var body: some View {\n        Form {"))
        let page = try #require(prefs.range(of: "private var page: some View {"))
        #expect(form.upperBound < flow.lowerBound && flow.upperBound < page.lowerBound)
        let rootView = try String(contentsOf: shell.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(!rootView.contains("Nearby") || !rootView.contains("NearbyFlow"), "the root's chain grows by nothing")
        let section = try String(contentsOf: shell.appendingPathComponent("Shell/NearbySection.swift"), encoding: .utf8)
        #expect(section.contains("ShellSectionHead(title: \"nearby.title\", line: \"nearby.line\", help: \"nearby.help\")"))
        #expect(section.contains("ShellListRow(") && section.contains(".shellConfirm("))
        for reach in ["http", "URLSession", "SecItem", "import Network"] {
            #expect(!section.contains(reach), "the screen reaches for \(reach)")
        }
        for plist in ["Apps/iOS/Info.plist", "Apps/macOS/Info.plist"] {
            let text = try String(contentsOf: root.appendingPathComponent(plist), encoding: .utf8)
            #expect(text.contains("NSLocalNetworkUsageDescription") && text.contains("<string>_fediqo._tcp</string>"), "\(plist)")
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("ENABLE_INCOMING_NETWORK_CONNECTIONS: YES") && project.contains("NSBonjourServices: [_fediqo._tcp]"))
    }
}
