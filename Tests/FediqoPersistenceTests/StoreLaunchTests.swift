import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #357, H3b: a launch opens the store without reading a row, the scrub waits until it is due,
/// and a pool over the file hands over no row past the months limit that the whole store would
/// have let go.
@Suite("A launch that reads no row")
struct StoreLaunchTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func post(_ id: String, daysAgo: Double, kept: Bool = false, refs: [Reference] = []) -> Note {
        Note(
            id: id, source: one, author: "A", handle: "a@one.example", body: "b \(id)",
            postedAt: now.addingTimeInterval(-daysAgo * 86_400), categories: [.home], kept: kept, refs: refs
        )
    }

    @Test("Opened for a launch, the store reads its sources and what they said, and no row")
    func opensWithoutRows() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.one], notes: [Self.post("a", daysAgo: 1), Self.post("b", daysAgo: 2)])
        }
        let launch = StoreFile.open(at: dir, rows: false)
        #expect(launch.file != nil && launch.trouble == nil)
        #expect(launch.sources.map(\.host) == ["one.example"])
        #expect(launch.notes.isEmpty && launch.skipped.isEmpty)
        let whole = StoreFile.open(at: dir)
        #expect(whole.notes.count == 2, "read whole where asked, as a read back reads it")
    }

    @Test("The scrub is due once for a file never rebuilt, and after that only past its share of free pages")
    func scrubDue() {
        #expect(StoreFile.scrubDue(version: 0, free: 0, pages: 100, pageSize: 4096))
        #expect(!StoreFile.scrubDue(version: StoreFile.scrubbed, free: 0, pages: 100, pageSize: 4096))
        #expect(!StoreFile.scrubDue(version: StoreFile.scrubbed, free: 5, pages: 100, pageSize: 4096), "a few pages")
        #expect(StoreFile.scrubDue(version: StoreFile.scrubbed, free: 11, pages: 100, pageSize: 4096), "past a tenth")
        #expect(StoreFile.scrubDue(version: StoreFile.scrubbed, free: 5000, pages: 1_000_000, pageSize: 4096), "past 16 MB")
    }

    @Test("Opening scrubs nothing; asked once the timeline shows, a file never rebuilt is rebuilt and marked")
    func scrubAfterOpen() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.one], notes: [Self.post("a", daysAgo: 1)])
            try await file.db.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 0") }
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 0, "not by the open")
        await file.scrubIfDue()
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == StoreFile.scrubbed)
    }

    @Test("Without the pages' index, a provisional page is the newest by arrival the rules show; with it, none")
    func provisionalPage() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let other = Source(host: "two.example", kind: .mastodon)
        var notes: [Note] = []
        for n in 0..<300 {
            notes.append(Note(
                id: "p\(n)", source: n.isMultiple(of: 3) ? other : Self.one, author: "A", handle: "a@one.example",
                body: "b", postedAt: Self.now.addingTimeInterval(Double(n)), categories: [.home]
            ))
        }
        try await file.save(sources: [Self.one, other], notes: notes)
        let definition = TimelineDefinition(name: "One", rules: [try #require(Rule.source("one.example"))])
        let query = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: []))
        let page = try #require(try await file.provisionalPage(query, limit: 50))
        #expect(page.rows.count == 50 && page.rows.allSatisfy { $0.note.source.host == "one.example" })
        #expect(page.rows.first?.note.id == "p299" && page.rows.map(\.arrival) == page.rows.map(\.arrival).sorted(by: >))
        #expect(page.next == nil && page.newest == nil && page.oldest == nil && !page.exhausted, "no place to read on from")
        try await file.makePageIndex()
        #expect(try await file.provisionalPage(query, limit: 50) == nil)
    }

    @Test("A read beside the index being made that cannot be made is made on the store's own: the row is still laid in")
    func besideGoneMidRead() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let note = Self.post("a", daysAgo: 1)
        try await file.save(sources: [Self.one], notes: [note])
        let pool = ItemStore(sources: [Self.one], rows: file)
        // The connection beside, closed under the read that took it.
        let side = try file.readingConnection()
        try side.close()
        file.beside = side
        defer { file.beside = nil }
        #expect(await pool.note(note.key) != nil, "turned away for the run")
    }

    @Test("The pages' index is made once, whoever asks, and asked again once made it is not made twice")
    func pageIndexMadeOnce() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.one], notes: [Self.post("a", daysAgo: 1)])
        async let one: Void = file.makePageIndex()
        async let two: Void = file.makePageIndex()
        _ = try await (one, two)
        try await file.makePageIndex()
        let names = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name = 'note_page'") }
        #expect(names == ["note_page"])
        #expect(file.beside == nil, "let go once made")
    }

    @Test("Over the file, a row past the months limit is handed over only where kept, or held by a row that stays")
    func monthsLimitOverTheFile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let notes = [
            Self.post("new", daysAgo: 1, refs: [Reference(kind: .quotes, id: "old-quoted", state: .accepted)]),
            Self.post("old", daysAgo: 90),
            Self.post("old-kept", daysAgo: 90, kept: true),
            Self.post("old-quoted", daysAgo: 90),
        ]
        try await file.save(sources: [Self.one], notes: notes)
        let pool = ItemStore(sources: [Self.one], rows: file)
        _ = await pool.notes(notes.map(\.key))
        await pool.letGoBeyond(months: 1, from: Self.now)
        #expect(Set(await pool.all().map(\.id)) == ["new", "old-kept", "old-quoted"])
        #expect(await pool.keepFrom != nil)
        // The whole store lets go of the same one.
        let whole = ItemStore(sources: [Self.one], notes: notes)
        await whole.letGoBeyond(months: 1, from: Self.now)
        #expect(Set(await whole.all().map(\.id)) == Set(await pool.all().map(\.id)))
        // And the row goes from the file with the save that follows (#360).
        #expect(try file.rowCount() == 4)
        try await file.save(await pool.takeChanges().changes)
        #expect(try file.rowCount() == 3)
    }
}
