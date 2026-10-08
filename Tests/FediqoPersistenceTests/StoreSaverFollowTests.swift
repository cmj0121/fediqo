import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// The saver following the store: a change is saved with nobody asking, late and seldom.
///
/// **No clock.** Each wait the follower asks for is held until the test ends it, so "inside the
/// quiet" and "inside the gap" are where the test put the change, not where a timer happened to be.
@Suite("The store is saved behind every change, with nobody asking")
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
        private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var stopped = false

        func sleep(_ wait: Duration) async throws {
            asked.append(wait)
            let count = asked.count
            for watcher in watchers where watcher.count <= count { watcher.continuation.resume() }
            watchers.removeAll { $0.count <= count }
            guard !stopped, await withCheckedContinuation({ held.append($0) }) else { throw CancellationError() }
        }

        /// Returns once `count` waits have been asked for.
        func asked(_ count: Int) async {
            guard asked.count < count else { return }
            await withCheckedContinuation { watchers.append((count, $0)) }
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
        let saver = StoreSaver(store: store) { _, notes, _ in await landed.record(notes) }
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
        private var entered: [Int: [CheckedContinuation<Void, Never>]] = [:]
        private var seen: Set<Int> = []
        private var held: [CheckedContinuation<Void, Never>] = []
        private var count = 0
        private let holding: Int?

        init(holding: Int? = nil) { self.holding = holding }

        /// The number of the write passing, held here where it is the one to hold.
        func pass() async -> Int {
            count += 1
            let number = count
            seen.insert(number)
            for watcher in entered[number] ?? [] { watcher.resume() }
            entered[number] = nil
            if number == holding { await withCheckedContinuation { held.append($0) } }
            return number
        }

        /// Returns once write `number` has begun.
        func began(_ number: Int) async {
            guard !seen.contains(number) else { return }
            await withCheckedContinuation { entered[number, default: []].append($0) }
        }

        func open() {
            for wait in held { wait.resume() }
            held = []
        }
    }

    private struct Refused: Error {}

    @Test("A change is saved once the quiet is out, and nobody asked")
    func aChangeIsSaved() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1)
        #expect(await waits.asked == [Self.quiet])
        #expect(await landed.writes == [[]], "written before the quiet was out")

        await waits.wake()
        await waits.asked(2)
        #expect(await landed.writes == [[], ["1"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet], "the save is owed its gap")
        await end(following, waits)
    }

    @Test("Changes landing while a save is armed are one write, and do not push it out")
    func aBurstIsOneWrite() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1)
        await store.ingest([note("2")])
        await store.ingest([note("3")])
        #expect(await waits.asked == [Self.quiet], "a later change armed a second save, or put the first off")

        await waits.wake()
        await waits.asked(2)
        #expect(await landed.writes == [[], ["1", "2", "3"]])
        await end(following, waits)
    }

    @Test("A change inside the gap after a followed save waits the gap out, and is then saved")
    func theNextWaitsOutTheGap() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1)
        await waits.wake()
        await waits.asked(2)

        // Inside the gap: heard, and nothing written for it yet.
        await store.ingest([note("2")])
        await store.ingest([note("3")])
        #expect(await landed.writes.count == 2)
        #expect(await waits.asked.count == 2)

        await waits.wake()
        await waits.asked(3)
        #expect(await landed.writes.count == 2, "saved the moment the gap ended, with no quiet")
        await waits.wake()
        await waits.asked(4)
        #expect(await landed.writes == [[], ["1"], ["1", "2", "3"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet, Self.quiet, Self.gap - Self.quiet])
        await end(following, waits)
    }

    @Test("A save asked for while one is armed takes it along: the follower writes nothing for it and owes no gap")
    func anAskedSaveDisarms() async throws {
        let (store, saver, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1)
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
        let saver = StoreSaver(store: store) { _, notes, _ in
            _ = await door.pass()
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1)
        let asked = Task { try await saver.save() }
        await door.began(2)

        await waits.wake()
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
        let saver = StoreSaver(store: store) { _, notes, _ in
            _ = await door.pass()
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1)
        await waits.wake()
        await door.began(2)
        // The snapshot is taken; this is not in it.
        await store.ingest([note("2")])
        await door.open()

        await waits.asked(2)
        #expect(await landed.writes == [[], ["1"]])
        await waits.wake()
        await waits.asked(3)
        await waits.wake()
        await waits.asked(4)
        #expect(await landed.writes == [[], ["1"], ["1", "2"]])
        #expect(await waits.asked == [Self.quiet, Self.gap - Self.quiet, Self.quiet, Self.gap - Self.quiet])
        await end(following, waits)
    }

    @Test("A followed save that fails is not tried again by itself and owes no gap; the next change is written")
    func aFailedFollowedSave() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let door = Door()
        let saver = StoreSaver(store: store) { _, notes, _ in
            if await door.pass() == 2 { throw Refused() }
            await landed.record(notes)
        }
        try await saver.save()
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await store.ingest([note("1")])
        await waits.asked(1)
        await waits.wake()
        await door.began(2)

        // After the write that fails has begun, so this is a change the failed save never saw.
        await store.ingest([note("2")])
        await waits.asked(2)
        #expect(await landed.writes == [[]])
        await waits.wake()
        await waits.asked(3)
        #expect(await landed.writes == [[], ["1", "2"]])
        #expect(
            await waits.asked == [Self.quiet, Self.quiet, Self.gap - Self.quiet],
            "the failure was tried again by itself, or was owed a gap"
        )
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
        await waits.asked(1)
        await waits.wake()
        await end(following, waits)
        #expect(await waits.asked == [Self.quiet])
        #expect(await saver.flush(deadline: .seconds(60)) == .saved)
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
        // The follower was told as this was; a turn of every queue, and it has asked for no wait.
        for _ in 0..<200 { await Task.yield() }
        #expect(await waits.asked.isEmpty)

        await store.ingest([note("2")])
        await waits.asked(1)
        await waits.wake()
        await waits.asked(2)
        #expect(await landed.writes == [["1"], ["1", "2"]])
        await end(following, waits)
    }

    @Test("What changed after the last write and before anything listened is saved too")
    func changedBeforeListening() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let saver = StoreSaver(store: store) { _, notes, _ in await landed.record(notes) }
        try await saver.save()
        await store.ingest([note("1")])
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await waits.asked(1)
        await waits.wake()
        await waits.asked(2)
        #expect(await landed.writes == [[], ["1"]])
        await end(following, waits)
    }

    @Test("Nothing written yet this run, and a change before anything listened: saved all the same")
    func changedBeforeTheFirstWrite() async throws {
        let store = ItemStore(sources: [alpha], notes: [])
        let landed = Landed()
        let waits = Waits()
        let saver = StoreSaver(store: store) { _, notes, _ in await landed.record(notes) }
        await store.ingest([note("1")])
        let following = Task {
            await saver.follow(quiet: Self.quiet, gap: Self.gap) { try await waits.sleep($0) }
        }
        await waits.asked(1)
        await waits.wake()
        await waits.asked(2)
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
        await waits.asked(1)
        #expect(StoreFile.open(at: dir).notes.isEmpty)
        await waits.wake()
        await waits.asked(2)
        #expect(StoreFile.open(at: dir).notes.map(\.id) == ["1"])
        await end(following, waits)
    }

    @Test("Cancelled in a wait, the follower ends and writes nothing more")
    func cancelledEnds() async throws {
        let (store, _, waits, landed, following) = try await followed()
        await store.ingest([note("1")])
        await waits.asked(1)
        await end(following, waits)
        #expect(await landed.writes == [[]])
    }
}
