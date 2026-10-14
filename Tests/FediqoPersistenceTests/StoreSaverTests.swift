import FediqoCore
import Foundation
import Synchronization
import Testing
@testable import FediqoPersistence

@Suite("A read back inside the saver's queue", .watched) struct SaverExclusiveTests {
    @Test("What runs exclusively runs after every save before it and before every save after")
    func exclusively() async throws {
        let store = ItemStore()
        let order = Order()
        // The first write waits at it; the one after the commit finds it open.
        let gate = Gate()
        let guardTask = watching(gate, "the first save's write")
        defer { guardTask.cancel() }
        let saver = StoreSaver(store: store, write: { _, _, _ in
            order.add("save")
            await gate.wait()
        })
        await store.add(Source(host: "a.example", kind: .mastodon))
        // The first save is under way — its write has begun and is held — when the commit is asked.
        let first = Task { try await saver.save() }
        await met("the first save's write has begun", by: first) { order.all == ["save"] }
        let commit = Task { try await saver.exclusively { order.add("commit"); return 7 } }
        // Counted turns: a commit that waits its turn in the saver's queue says nothing of
        // waiting, and one that did not wait would have run inside them.
        for _ in 0..<1_000 { await Task.yield() }
        #expect(order.all == ["save"], "the commit waits for the save under way")
        await gate.open()
        let result = try await commit.value
        try await first.value
        await store.add(Source(host: "b.example", kind: .mastodon))
        try await saver.save()
        #expect(result == 7)
        #expect(order.all == ["save", "commit", "save"])
    }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("The one save", .watched)
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

    /// A flush's deadline on a clock nobody turns: a write that is slow, or held, is not given
    /// up on by one.
    private static func flushed(_ saver: StoreSaver) async -> StoreSaver.Outcome {
        await saver.flush(deadline: StoreSaver.deadline, sleep: TurnedClock().sleep)
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
        let begun = Order()
        let release = Gate()
        let guardTask = watching(release, "the first save's write")
        defer { guardTask.cancel() }
        let landed = Landed()
        let calls = Mutexed()
        let saver = StoreSaver(store: store) { sources, notes, _ in
            if calls.next() == 1 {
                begun.add("first")
                await release.wait()
            }
            try await file.save(sources: sources, notes: notes)
            _ = await landed.record(notes)
        }

        let first = Task { try await saver.save() }
        await met("the first save's write has begun", by: first) { begun.all == ["first"] }
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
        let begun = Order()
        let release = Gate()
        let guardTask = watching(release, "the first save's write")
        defer { guardTask.cancel() }
        let landed = Landed()
        let calls = Mutexed()
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let saver = StoreSaver(store: store) { _, notes, _ in
            if calls.next() == 1 {
                begun.add("first")
                await release.wait()
            }
            _ = await landed.record(notes)
        }
        let first = Task { try await saver.save() }
        await met("the first save's write has begun", by: first) { begun.all == ["first"] }
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
        #expect(await Self.flushed(saver) == .saved)
    }

    /// No check here calls the flush the app calls, because its deadline is a real one and a
    /// real one can win on a machine that is busy enough (#203). So what it does is read: it is
    /// the flush every check above turns by hand, handed `Task.sleep` and nothing of its own.
    @Test("The flush the app calls is the one these checks turn, waiting its deadline on the real clock")
    func theAppsFlushIsTheSame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StoreSaver.swift"), encoding: .utf8
        )
        let squeezed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(squeezed.contains(
            "public nonisolated func flush(deadline: Duration = StoreSaver.deadline) async -> Outcome { "
                + "await flush(deadline: deadline) { try await Task.sleep(for: $0) } }"
        ))
        #expect(StoreSaver.deadline == .seconds(3))
    }

    @Test("What a save wrote is what the next launch opens: the store before the quit")
    func saveThenOpenRoundTrip() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [alpha, beta], notes: [note("1", from: alpha), note("2", from: beta)])
        let saver = StoreSaver(store: store, file: StoreFile.open(at: dir).file)
        // The round trip, not the quit's deadline: a shared runner stretches this write past 3 s (#203).
        #expect(await Self.flushed(saver) == .saved)

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
        let guardTask = watching(release, "the write the flush waits for")
        defer { guardTask.cancel() }
        let begun = Order()
        let landed = Landed()
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [note("1", from: alpha)])) { _, notes, _ in
            begun.add("write")
            await release.wait()
            _ = await landed.record(notes)
        }
        let flush = Task { await Self.flushed(saver) }
        await met("the flush's write is held", by: flush) { begun.all == ["write"] }
        #expect(await landed.writes.isEmpty)
        await release.open()
        #expect(await flush.value == .saved)
        #expect(await landed.writes == [["1"]])
    }

    /// **The deadline is turned by hand.** The write is still hanging when the flush answers —
    /// its gate opens only after — so answering `.timedOut` at all is the deadline, not the
    /// write, ending it; and the deadline waited on is the one the flush was handed. A flush that
    /// did wait for the write would never answer, and the suite's watch says so.
    @Test("A write that hangs does not hold a flush past the deadline")
    func flushTimesOut() async {
        let never = Gate()
        let guardTask = watching(never, "the write that hangs")
        defer { guardTask.cancel() }
        let begun = Order()
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [])) { _, _, _ in
            begun.add("write")
            await never.wait()
        }
        let clock = TurnedClock()
        let deadline: Duration = .milliseconds(4_321)
        let flush = Task { await saver.flush(deadline: deadline, sleep: clock.sleep) }
        await met("the write hangs, and the flush's deadline is being waited on", by: flush) {
            begun.all == ["write"] && clock.sleeping == 1
        }
        #expect(clock.asked == [deadline], "the deadline the flush was handed, and nothing else")
        clock.turn()
        #expect(await flush.value == .timedOut)
        await never.open()
    }

    @Test("A write that fails still lets a flush answer, and says so")
    func flushReportsFailure() async {
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: [])) { _, _, _ in throw Refused() }
        #expect(await Self.flushed(saver) == .failed)
    }

    /// Which parts a save wrote, in the order they landed.
    private actor Parts {
        private(set) var wrote: [String] = []
        func add(_ part: String) { wrote.append(part) }
    }

    @Test("A part that cannot be written keeps no other from the file: with the notices failing, or the texts, the posts are still saved, the flush answers that it failed, and the part is tried again by the next save",
          arguments: ["notices", "texts"])
    func eachPartIsWrittenWhateverBecameOfTheOthers(_ failing: String) async throws {
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        await store.hold(Unsent(host: alpha.host, text: "words", audience: .everyone))
        await store.hold(NoticeReach(host: alpha.host, before: "9", gathered: true))
        let parts = Parts()
        let broken = Mutex(true)
        let saver = StoreSaver(
            store: store,
            write: { _, notes, _ in await parts.add("items:\(notes.count)") },
            writeUnsent: { texts in
                if failing == "texts", broken.withLock({ $0 }) { throw Refused() }
                await parts.add("texts:\(texts.count)")
            },
            writeNotices: { reaches in
                if failing == "notices", broken.withLock({ $0 }) { throw Refused() }
                await parts.add("notices:\(reaches.count)")
            }
        )

        #expect(await Self.flushed(saver) == .failed, "a save that left a part unwritten said it saved")
        let other = failing == "notices" ? "texts:1" : "notices:1"
        #expect(await parts.wrote == [other, "items:1"], "the part that failed kept another from the file")

        // Nothing moved since: the parts that landed are not written again, and the one that did not is.
        broken.withLock { $0 = false }
        #expect(await Self.flushed(saver) == .saved)
        #expect(await parts.wrote == [other, "items:1", failing == "notices" ? "notices:1" : "texts:1"])
    }
}

/// Numbers calls from inside a `@Sendable` write, without a hop.
private final class Mutexed: Sendable {
    private let count = Mutex(0)
    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}
