import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// The saver following the store: a change is saved with nobody asking, late and seldom.
///
/// **No clock.** Each wait the follower asks for is held until the test ends it, so "inside the
/// quiet" and "inside the gap" are where the test put the change, not where a timer happened to be.
@Suite("The store is saved behind every change, with nobody asking", .watched)
struct StoreSaverFollowTests {
    private static let quiet = Duration.seconds(2)
    private static let gap = Duration.seconds(60)
    private let alpha = Source(host: "alpha.test", kind: .mastodon)

    private func note(_ id: String, favourites: Int = 0) -> Note {
        Note(
            id: id, source: alpha, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000 + (Double(id) ?? 0)), categories: [.public],
            counts: Counts(replies: 0, reblogs: 0, favourites: favourites)
        )
    }

    /// The waits a follower asked for, each held until `wake` ends it — or `stop` breaks it, as a
    /// cancelled `Task.sleep` is broken. A wait asked for after `stop` is counted and thrown.
    private actor Waits {
        private(set) var asked: [Duration] = []
        private var held: [CheckedContinuation<Bool, Never>] = []
        private var stopped = false

        func sleep(_ wait: Duration) async throws {
            asked.append(wait)
            guard !stopped, await withCheckedContinuation({ held.append($0) }) else { throw CancellationError() }
        }

        /// Returns once `count` waits have been asked for — by `following`, which is the
        /// follower: it ends only when a check ends it, so a wait it never asks for is given up
        /// on where it has.
        nonisolated func asked(
            _ count: Int, by following: Task<Void, Never>, sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            await met("the follower has asked for its wait number \(count)", by: following, sourceLocation: sourceLocation) {
                await self.asked.count >= count
            }
        }

        /// Ends the wait under way: it is out, and the follower goes on.
        func wake() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume(returning: true)
        }

        func stop() {
            stopped = true
            for wait in held { wait.resume(returning: false) }
            held = []
        }
    }

    /// Which notes each write carried, in the order the writes landed.
    private actor Landed {
        private(set) var writes: [[String]] = []
        func record(_ notes: [Note]) { writes.append(notes.map(\.id).sorted()) }
    }

    /// A store already written once and followed from there, as the app's is after its first
    /// save: `landed` holds that write, and every one after it is the follower's or the test's.
    private func followed(
        holding notes: [Note] = []
    ) async throws -> (store: ItemStore, saver: StoreSaver, waits: Waits, landed: Landed, following: Task<Void, Never>) {
        let store = ItemStore(sources: [alpha], notes: notes)
        let landed = Landed()
        let waits = Waits()
        let saver = StoreSaver(store: store) { changes in let notes = changes.upserts; await landed.record(notes) }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        return (store, saver, waits, landed, following)
    }

    /// The follower stopped, once it has finished what it was in the middle of: a wait under way
    /// is broken, and one it goes on to ask for is counted and refused — so what `asked` holds
    /// afterwards is everything it would have waited for.
    private func end(_ following: Task<Void, Never>, _ waits: Waits) async {
        await waits.stop()
        following.cancel()
        await following.value
    }

    /// A write a test holds, fails, or counts, by which write it is.
    private actor Door {
        private var seen: Set<Int> = []
        private var held: [CheckedContinuation<Void, Never>] = []
        private var count = 0
        private var opened = false
        private let holding: Int?

        init(holding: Int? = nil) { self.holding = holding }

        /// The number of the write passing, held here where it is the one to hold.
        func pass() async -> Int {
            count += 1
            let number = count
            seen.insert(number)
            if number == holding, !opened { await withCheckedContinuation { held.append($0) } }
            return number
        }

        private func has(begun number: Int) -> Bool { seen.contains(number) }

        /// Returns once write `number` has begun — by `work`, whoever is to make it.
        nonisolated func began(
            _ number: Int, by work: any Ending, sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            await met("write number \(number) has begun", by: work, sourceLocation: sourceLocation) {
                await self.has(begun: number)
            }
        }

        /// Holds nothing any more, now or later.
        func open() {
            opened = true
            for wait in held { wait.resume() }
            held = []
        }
    }

    private struct Refused: Error {}

    private actor Flag {
        private(set) var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
        func set(_ value: Bool) { isOn = value }
    }

    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test("A change is saved once the quiet is out, and nobody asked")
    func aChangeIsSaved() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        #expect(await waits.asked == [Self.quiet])
        #expect(await landed.writes == [[]], "written before the quiet was out")

        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [[], ["1"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet], "the save is owed its gap")
        await end(following, waits)
    }

    @Test("Changes landing while a save is armed are one write, and do not push it out")
    func aBurstIsOneWrite() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await store.ingest([note("2")])
        await store.ingest([note("3")])
        #expect(await waits.asked == [Self.quiet], "a later change armed a second save, or put the first off")

        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [[], ["1", "2", "3"]])
        await end(following, waits)
    }

    @Test("A change inside the gap after a followed save waits the gap out, and is then saved")
    func theNextWaitsOutTheGap() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await waits.wake()
        await waits.asked(2, by: following)

        // Inside the gap: heard, and nothing written for it yet.
        await store.ingest([note("2")])
        await store.ingest([note("3")])
        #expect(await landed.writes.count == 2)
        #expect(await waits.asked.count == 2)

        await waits.wake()
        await waits.asked(3, by: following)
        #expect(await landed.writes.count == 2, "saved the moment the gap ended, with no quiet")
        await waits.wake()
        await waits.asked(4, by: following)
        #expect(await landed.writes == [[], ["1"], ["2", "3"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet, Self.quiet, Self.gap - Self.quiet])
        await end(following, waits)
    }

    @Test("A save asked for while one is armed takes it along: the follower writes nothing for it and owes no gap")
    func anAskedSaveDisarms() async throws {
        let (store, saver, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        try await saver.save()
        #expect(await landed.writes == [[], ["1"]])

        await waits.wake()
        await end(following, waits)
        #expect(await landed.writes == [[], ["1"]], "the armed save wrote the store a second time")
        #expect(await waits.asked == [Self.quiet], "a save that wrote nothing was owed a gap")
    }

    /// The asked save is being written — its snapshot taken, with the change in it — as the
    /// quiet ends. The turns given before the door opens are for the follower to get in behind
    /// it; had it not, it wakes to a store already written, and the same two lines hold.
    @Test("An asked save still being written as the quiet ends: the follower's own writes nothing, and owes no gap")
    func anAskedSaveUnderWayDisarms() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door(holding: 2)
        let guardTask = watching("the second write, held") { await door.open() }
        defer { guardTask.cancel() }
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            _ = await door.pass()
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        let asked = Task { try await saver.save() }
        await door.began(2, by: asked)

        await waits.wake()
        // Counted turns: a follower behind the write under way waits in the saver's queue, which
        // says nothing of who is waiting — and the same two lines hold had it not got there.
        for _ in 0..<200 { await Task.yield() }
        await door.open()
        try await asked.value
        await end(following, waits)
        #expect(await landed.writes == [[], ["1"]])
        #expect(await waits.asked == [Self.quiet], "a followed save that wrote nothing was owed a gap")
    }

    @Test("A change landing while a followed save is being written is written by the next, after the gap")
    func changedDuringTheWrite() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door(holding: 2)
        let guardTask = watching("the second write, held") { await door.open() }
        defer { guardTask.cancel() }
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            _ = await door.pass()
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await waits.wake()
        await door.began(2, by: following)
        // The snapshot is taken; this is not in it.
        await store.ingest([note("2")])
        await door.open()

        await waits.asked(2, by: following)
        #expect(await landed.writes == [[], ["1"]])
        await waits.wake()
        await waits.asked(3, by: following)
        await waits.wake()
        await waits.asked(4, by: following)
        #expect(await landed.writes == [[], ["1"], ["2"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet, Self.quiet, Self.gap - Self.quiet])
        await end(following, waits)
    }

    @Test("A followed save that fails is tried again by itself a gap later, and takes with it what changed meanwhile")
    func aFailedFollowedSave() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door()
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            if await door.pass() == 2 { throw Refused() }
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await waits.wake()
        await door.began(2, by: following)

        // After the write that fails has begun, so this is a change the failed save never saw.
        await store.ingest([note("2")])
        await waits.asked(2, by: following)
        #expect(await landed.writes == [[]])
        #expect(await waits.asked == [Self.quiet, Self.gap], "the failure was tried again at once, or not at all")
        await waits.wake()
        await waits.asked(3, by: following)
        #expect(await landed.writes == [[], ["1", "2"]], "nobody asked, and nothing changed after the failure was owed")
        #expect(await waits.asked == [Self.quiet, Self.gap, Self.gap], "a try that wrote is owed its gap")
        await end(following, waits)
    }

    @Test("A write that keeps failing is tried a gap apart, a handful of times, and then let be until something lands")
    func aFailureIsRetriedWithinBounds() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let failing = Flag(true)
        let tries = Counter()
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            await tries.bump()
            if await failing.isOn { throw Refused() }
            await landed.record(notes)
        }
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        for wait in 1...StoreSaver.retries {
            await waits.wake()
            await waits.asked(wait + 1, by: following)
        }
        #expect(await waits.asked == [Self.quiet] + Array(repeating: Self.gap, count: StoreSaver.retries))
        await waits.wake()
        await met("the last try has been made", by: following) { await tries.count >= StoreSaver.retries + 1 }
        // Counted turns, behind the last try: a follower that has given up asks for nothing, and
        // says nothing of having given up.
        for _ in 0..<200 { await Task.yield() }
        #expect(await tries.count == StoreSaver.retries + 1, "the follower went on trying past its bound")
        #expect(await waits.asked.count == StoreSaver.retries + 1, "the follower went on waiting past its bound")
        #expect(await landed.writes.isEmpty)

        // A save somebody asks for lands, and the count starts again: the next failure is owed its tries.
        await failing.set(false)
        try await saver.save()
        #expect(await landed.writes == [["1"]])
        await failing.set(true)
        await store.ingest([note("2")])
        await waits.asked(StoreSaver.retries + 2, by: following)
        await waits.wake()
        await waits.asked(StoreSaver.retries + 3, by: following)
        #expect(await waits.asked.suffix(2) == [Self.quiet, Self.gap])
        await end(following, waits)
    }

    @Test("A notices write that always fails is under the same bound as every part's: tried once behind the change and then a gap apart, a handful of times, and nothing more is slept for or written until the store changes — which starts the count again")
    func aNoticesFailureIsRetriedWithinBounds() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let waits = Waits()
        let tries = Counter()
        let posts = Counter()
        let saver = StoreSaver(
            store: store, write: { _ in await posts.bump() },
            writeNotices: { _ in
                await tries.bump()
                throw Refused()
            }
        )
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.hold(NoticeReach(host: alpha.host, before: "9", gathered: true))
        await waits.asked(1, by: following)
        for wait in 1...StoreSaver.retries {
            await waits.wake()
            await waits.asked(wait + 1, by: following)
        }
        await waits.wake()
        await met("the last try has been made", by: following) { await tries.count >= StoreSaver.retries + 1 }
        // Counted turns, behind the last try: a follower that has given up asks for nothing, and
        // says nothing of having given up.
        for _ in 0..<500 { await Task.yield() }
        #expect(await tries.count == StoreSaver.retries + 1, "the notices went on being tried past the bound")
        #expect(await waits.asked == [Self.quiet] + Array(repeating: Self.gap, count: StoreSaver.retries))
        #expect(await posts.count == 1, "no post was written again for a notice")

        // A change: one try behind it, and its handful again.
        await store.hold(NoticeReach(host: alpha.host, before: "8", gathered: true))
        await waits.asked(StoreSaver.retries + 2, by: following)
        await waits.wake()
        await met("the try behind the change has been made", by: following) { await tries.count >= StoreSaver.retries + 2 }
        // The gap before the next try is the count having started again: waited for, by name.
        await waits.asked(StoreSaver.retries + 3, by: following)
        #expect(await waits.asked.suffix(2) == [Self.quiet, Self.gap], "a change did not start the count again")
        await end(following, waits)
    }

    @Test("A save that writes every part after one had failed is told to whoever listens, once, whoever made it; a save with nothing behind it to make good is not")
    func aLandingAfterAFailureIsTold() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let failing = Flag(true)
        let saver = StoreSaver(store: store) { _ in
            if await failing.isOn { throw Refused() }
        }
        let told = Counter()
        let landings = await saver.landings()
        let listening = Task {
            for await _ in landings { await told.bump() }
        }
        await #expect(throws: Refused.self) { try await saver.save() }
        // Counted turns: a landing is told down a stream, and a save with nothing to tell sends
        // nothing down it.
        for _ in 0..<200 { await Task.yield() }
        #expect(await told.count == 0)

        await failing.set(false)
        try await saver.save()
        await met("the landing after the failure is told", by: listening) { await told.count >= 1 }
        await store.ingest([note("1")])
        try await saver.save()
        // Counted turns, as above: a save with nothing to make good sends nothing down the stream.
        for _ in 0..<200 { await Task.yield() }
        #expect(await told.count == 1, "a save with nothing to make good was told as one that did")
        listening.cancel()
    }

    @Test("A save somebody asked for that fails is tried again by the follower, with no change and nobody asking")
    func anAskedSaveThatFailsIsRetried() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door()
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            if await door.pass() == 1 { throw Refused() }
            await landed.record(notes)
        }
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await #expect(throws: Refused.self) { try await saver.save() }
        await waits.asked(1, by: following)
        #expect(await waits.asked == [Self.gap])
        #expect(await landed.writes.isEmpty)
        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [[]])
        await end(following, waits)
    }

    @Test("A save that landed while the retry waited leaves it nothing to write")
    func aRetryFindsItLanded() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door()
        let saver = StoreSaver(store: store) { changes in
            let notes = changes.upserts
            if await door.pass() == 1 { throw Refused() }
            await landed.record(notes)
        }
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await #expect(throws: Refused.self) { try await saver.resave() }
        await waits.asked(1, by: following)
        try await saver.resave()
        await waits.wake()
        // Counted turns: a retry that finds the store written writes nothing and waits for
        // nothing, so there is no end of it to wait for.
        for _ in 0..<200 { await Task.yield() }
        #expect(await landed.writes == [[]], "the retry wrote the store a second time")
        #expect(await waits.asked == [Self.gap])
        await end(following, waits)
    }

    @Test("With no index this run, the follower writes nothing, owes nothing and ends when stopped")
    func noIndexFollowsNothing() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let waits = Waits()
        let saver = StoreSaver(store: store, file: nil)
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await waits.wake()
        await end(following, waits)
        #expect(await waits.asked == [Self.quiet])
        // The deadline, on a clock nobody turns.
        #expect(await saver.flush(deadline: StoreSaver.deadline, sleep: TurnedClock().sleep) == .saved)
    }

    @Test("A change that moved nothing a save writes arms nothing")
    func aRecountArmsNothing() async throws {
        let (store, _, waits, landed, following) = try await followed(holding: [note("1")])
        let before = await store.revision
        let changes = await store.changes()
        await store.ingest([note("1", favourites: 7)])
        #expect(await store.revision == before, "the recount is no longer the change a save skips")
        var heard = changes.makeAsyncIterator()
        _ = await heard.next()
        // Counted turns, behind the change having been told: the follower was told as this was,
        // and one that arms nothing asks for no wait and says nothing.
        for _ in 0..<200 { await Task.yield() }
        #expect(await waits.asked.isEmpty)

        await store.ingest([note("2")])
        await waits.asked(1, by: following)
        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [["1"], ["1", "2"]])
        await end(following, waits)
    }

    @Test("What changed after the last write and before anything listened is saved too")
    func changedBeforeListening() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let saver = StoreSaver(store: store) { changes in let notes = changes.upserts; await landed.record(notes) }
        try await saver.save()
        await store.ingest([note("1")])
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await waits.asked(1, by: following)
        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [[], ["1"]])
        await end(following, waits)
    }

    @Test("Nothing written yet this run, and a change before anything listened: saved all the same")
    func changedBeforeTheFirstWrite() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let saver = StoreSaver(store: store) { changes in let notes = changes.upserts; await landed.record(notes) }
        await store.ingest([note("1")])
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await waits.asked(1, by: following)
        await waits.wake()
        await waits.asked(2, by: following)
        #expect(await landed.writes == [["1"]])
        await end(following, waits)
    }

    @Test("A landing nobody asked to save is in the file once the quiet is out")
    func aLandingReachesTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [alpha], notes: [])
        let waits = Waits()
        let saver = StoreSaver(store: store, file: try StoreFile(at: dir))
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        #expect(StoreFile.open(at: dir).notes.isEmpty)
        await waits.wake()
        await waits.asked(2, by: following)
        #expect(StoreFile.open(at: dir).notes.map(\.id) == ["1"])
        await end(following, waits)
    }

    @Test("Cancelled in a wait, the follower ends and writes nothing more")
    func cancelledEnds() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1, by: following)
        await end(following, waits)
        #expect(await landed.writes == [[]])
    }
}
