import FediqoCore
import Foundation
import Synchronization
import Testing
@testable import FediqoPersistence

@Suite("A read back inside the saver's queue") struct SaverExclusiveTests {
    @Test("What runs exclusively runs after every save before it and before every save after")
    func exclusively() async throws {
        let store = ItemStore()
        let order = Order()
        let gate = Gate()
        let saver = StoreSaver(store: store, write: { _, _, _ in
            order.add("save")
            await gate.passOnce()
        })
        await store.add(Source(host: "a.example", kind: .mastodon))
        // The first save is under way — its write has begun and is held — when the commit is asked.
        let first = Task { try await saver.save() }
        await gate.entered()
        let commit = Task { try await saver.exclusively { order.add("commit"); return 7 } }
        await Task.yield()
        #expect(order.all == ["save"], "the commit waits for the save under way")
        gate.open()
        let result = try await commit.value
        try await first.value
        await store.add(Source(host: "b.example", kind: .mastodon))
        try await saver.save()
        #expect(result == 7)
        #expect(order.all == ["save", "commit", "save"])
    }
}

/// A door the first write waits at, and the test opens.
private actor Gate {
    private var passed = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    /// The first caller waits until `open`; every later one passes.
    func passOnce() async {
        guard !passed else { return }
        passed = true
        for watcher in watchers { watcher.resume() }
        watchers = []
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once the first caller is waiting.
    func entered() async {
        guard !passed else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    nonisolated func open() {
        Task { await self.release() }
    }

    private func release() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("The one save")
struct StoreSaverTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let alpha = Source(host: "alpha.test", kind: .mastodon)
    private let beta = Source(host: "beta.test", kind: .discuz, boards: [BoardSubscription(fid: 2, name: "b")])

    private func note(_ id: String, from source: Source) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: origin.addingTimeInterval(Double(id) ?? 0), categories: [.public]
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private struct Refused: Error {}

    /// A door a test holds shut until it chooses to open it: no sleeps, so what runs first is
    /// what the test said runs first.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Which notes each write carried, in the order the writes landed.
    private actor Landed {
        var writes: [[String]] = []
        func record(_ notes: [Note]) -> Int {
            writes.append(notes.map(\.id).sorted())
            return writes.count
        }
    }

    @Test("A held first save and a quick one after it: the file holds the later store")
    func savesAreSerialized() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let entered = Gate()
        let release = Gate()
        let landed = Landed()
        let calls = Mutexed()
        let saver = StoreSaver(store: store) { sources, notes, _ in
            if calls.next() == 1 {
                await entered.open()
                await release.wait()
            }
            try await file.save(sources: sources, notes: notes)
            _ = await landed.record(notes)
        }

        let first = Task { try await saver.save() }
        await entered.wait()
        await store.ingest([note("2", from: alpha)])
        let second = Task { try await saver.save() }
        await release.open()
        try await first.value
        try await second.value

        #expect(await landed.writes.last == ["1", "2"])
        #expect(StoreFile.open(at: dir).notes.map(\.id).sorted() == ["1", "2"])
    }

    @Test("Two saves with nothing changed between them write once")
    func unchangedIsNotWrittenAgain() async throws {
        let landed = Landed()
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let saver = StoreSaver(store: store) { _, notes, _ in _ = await landed.record(notes) }
        try await saver.save()
        try await saver.save()
        #expect(await landed.writes.count == 1)

        await store.ingest([note("2", from: alpha)])
        try await saver.save()
        #expect(await landed.writes == [["1"], ["1", "2"]])
    }

    @Test("Saves asked for while one is held run after it, and write what the store holds then")
    func savesWhileOneIsHeld() async throws {
        let entered = Gate()
        let release = Gate()
        let landed = Landed()
        let calls = Mutexed()
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let saver = StoreSaver(store: store) { _, notes, _ in
            if calls.next() == 1 {
                await entered.open()
                await release.wait()
            }
            _ = await landed.record(notes)
        }
        let first = Task { try await saver.save() }
        await entered.wait()
        await store.ingest([note("2", from: alpha)])
        let waiting = (0..<3).map { _ in Task { try await saver.save() } }
        await release.open()
        try await first.value
        for task in waiting { try await task.value }
        #expect(await landed.writes == [["1"], ["1", "2"]])
    }

    @Test("A write that fails is thrown to the caller, and the next save still lands")
    func failureIsReported() async throws {
        let landed = Landed()
        let calls = Mutexed()
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [note("1", from: alpha)])) { _, notes, _ in
            if calls.next() == 1 { throw Refused() }
            _ = await landed.record(notes)
        }
        await #expect(throws: Refused.self) { try await saver.save() }
        try await saver.save()
        #expect(await landed.writes == [["1"]])
    }

    @Test("With no index this run, a save writes nothing and does not fail")
    func noIndexSavesNothing() async throws {
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: []), file: nil)
        try await saver.save()
        #expect(await saver.flush() == .saved)
    }

    @Test("What a save wrote is what the next launch opens: the store before the quit")
    func saveThenOpenRoundTrip() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [alpha, beta], notes: [note("1", from: alpha), note("2", from: beta)])
        let saver = StoreSaver(store: store, file: StoreFile.open(at: dir).file)
        #expect(await saver.flush() == .saved)

        let before = await store.snapshot()
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.sources == before.sources)
        #expect(opened.notes.sorted { $0.id < $1.id } == before.notes.sorted { $0.id < $1.id })
    }

    // MARK: Flush, the quit's save

    @Test("A flush answers only once the write has landed")
    func flushWaitsForTheWrite() async {
        let release = Gate()
        let landed = Landed()
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [note("1", from: alpha)])) { _, notes, _ in
            await release.wait()
            _ = await landed.record(notes)
        }
        let flush = Task { await saver.flush(deadline: .seconds(60)) }
        await release.open()
        #expect(await flush.value == .saved)
        #expect(await landed.writes == [["1"]])
    }

    /// **A hang guard, not a clock.** The write is still hanging when the flush answers — its
    /// gate opens only after — so answering `.timedOut` at all is the deadline, not the write,
    /// ending it. How soon after 50 ms it answers is how soon the deadline's own task gets a
    /// thread, which on a shared runner with every other suite at work took six seconds (#203).
    /// A flush that did wait for the write would never answer, and the time limit says so.
    @Test("A write that hangs does not hold a flush past the deadline", .timeLimit(.minutes(1)))
    func flushTimesOut() async {
        let never = Gate()
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [])) { _, _, _ in await never.wait() }
        #expect(await saver.flush(deadline: .milliseconds(50)) == .timedOut)
        await never.open()
    }

    @Test("A write that fails still lets a flush answer, and says so")
    func flushReportsFailure() async {
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [])) { _, _, _ in throw Refused() }
        #expect(await saver.flush(deadline: .seconds(60)) == .failed)
    }
}

/// Numbers calls from inside a `@Sendable` write, without a hop.
private final class Mutexed: Sendable {
    private let count = Mutex(0)
    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}
