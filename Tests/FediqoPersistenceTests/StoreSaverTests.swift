import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

@Suite("The one save")
struct StoreSaverTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let alpha = Source(host: "alpha.test", kind: .mastodon)
    private let beta = Source(host: "beta.test", kind: .discuz, boards: [BoardSubscription(fid: 2, name: "b")])

    private func note(_ id: String, from source: Source) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: origin.addingTimeInterval(Double(id) ?? 0), origins: [.publicTimeline]
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private struct Refused: Error {}

    /// Writes into a real `StoreFile`, holding the first write back for `firstDelay` before it
    /// lands and recording which notes each write carried, in the order they landed.
    private actor Slow: IndexWriter {
        let file: StoreFile
        let firstDelay: Duration
        var landed: [[String]] = []
        private var calls = 0

        init(file: StoreFile, firstDelay: Duration) {
            self.file = file
            self.firstDelay = firstDelay
        }

        func write(sources: [Source], notes: [Note]) async throws {
            calls += 1
            if calls == 1 { try await Task.sleep(for: firstDelay) }
            try await file.write(sources: sources, notes: notes)
            landed.append(notes.map(\.id).sorted())
        }
    }

    private struct Failing: IndexWriter {
        func write(sources: [Source], notes: [Note]) async throws { throw Refused() }
    }

    @Test("A slow save and a fast one after it: the file holds the later store")
    func savesAreSerialized() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let writer = Slow(file: try StoreFile(at: dir), firstDelay: .milliseconds(100))
        let saver = StoreSaver(store: store, index: writer)

        let first = Task { try await saver.save() }
        // Let the first save start and stall inside its write before the store changes.
        try await Task.sleep(for: .milliseconds(20))
        await store.ingest([note("2", from: alpha)])
        try await saver.save()
        try await first.value

        #expect(await writer.landed.last == ["1", "2"])
        #expect(StoreFile.open(at: dir).notes.map(\.id).sorted() == ["1", "2"])
    }

    @Test("A write that fails is thrown to the caller, and the next save still lands")
    func failureIsReported() async throws {
        let store = ItemStore(sources: [alpha], notes: [note("1", from: alpha)])
        let saver = StoreSaver(store: store, index: Failing())
        await #expect(throws: Refused.self) { try await saver.save() }

        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recovering = StoreSaver(store: store, index: try StoreFile(at: dir))
        try await recovering.save()
        #expect(StoreFile.open(at: dir).notes.map(\.id) == ["1"])
    }

    @Test("A save that fails does not stop the save queued after it")
    func failureDoesNotJamTheQueue() async throws {
        actor FailOnce: IndexWriter {
            var calls = 0
            func write(sources: [Source], notes: [Note]) async throws {
                calls += 1
                if calls == 1 { throw Refused() }
            }
        }
        let writer = FailOnce()
        let saver = StoreSaver(store: ItemStore(), index: writer)
        await #expect(throws: Refused.self) { try await saver.save() }
        try await saver.save()
        #expect(await writer.calls == 2)
    }

    @Test("With no index this run, a save writes nothing and does not fail")
    func noIndexSavesNothing() async throws {
        let saver = StoreSaver(store: ItemStore(sources: [alpha], notes: []), index: nil)
        try await saver.save()
    }

    @Test("What a save wrote is what the next launch opens: the store before the quit")
    func saveThenOpenRoundTrip() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [alpha, beta], notes: [note("1", from: alpha), note("2", from: beta)])
        let saver = StoreSaver(store: store, index: StoreFile.open(at: dir).file)
        try await saver.save()

        let before = await store.snapshot()
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.sources == before.sources)
        #expect(opened.notes.sorted { $0.id < $1.id } == before.notes.sorted { $0.id < $1.id })
    }
}
