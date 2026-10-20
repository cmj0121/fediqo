import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #317 on disk: what the reader bookmarked and favourited at a source is two kinds of category,
/// kept with each row and the mark it is listed under; a post un-marked elsewhere leaves the
/// category even where only the file holds it; and a build that knows neither kind refuses the
/// store rather than lose them.
@Suite("Bookmarks and favourites as categories, on disk")
struct MarksStoreTests {
    private static let mastodon = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func post(_ id: String, _ categories: Set<FediqoCore.Category>, listed: [FediqoCore.Category: String], minutes: Double) -> Note {
        Note(
            id: id, source: mastodon, author: "A", handle: "a@one.example", body: "b \(id)",
            postedAt: at.addingTimeInterval(minutes * 60), categories: categories, statusID: "s-\(id)", listed: listed
        )
    }

    private static let notes = [
        post("1", [.bookmarks, .favourites], listed: [.bookmarks: "2", .favourites: "0"], minutes: 1),
        post("2", [.bookmarks], listed: [.bookmarks: "4"], minutes: 2),
        post("3", [.bookmarks, .home], listed: [.bookmarks: "0", .home: "s-3"], minutes: 3),
    ]

    private func migrations(_ index: URL) throws -> [String] {
        try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    @Test("Each kind, and the mark each row is listed under there, comes back from the file as it went in")
    func roundTrip() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: Self.notes)
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes == Self.notes)
        #expect(try migrations(dir.appendingPathComponent("index.sqlite")).last == "v17-marks")
        // And the file names the rows of a kind by it, kept or not.
        let file = try #require(opened.file)
        #expect(Set(try file.keys(host: "one.example", in: .bookmarks).map(\.id)) == ["1", "2", "3"])
        #expect(try file.keys(host: "one.example", in: .favourites).map(\.id) == ["1"])
        #expect(try file.keys(host: "two.example", in: .bookmarks).isEmpty)
    }

    @Test("Each kind of mark has an index of its rows by host, made beside the tables as the pages' are, holding only those rows, and asking for them is answered by it")
    func eachKindIsIndexed() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        try await file.makeIndexes()
        let index = dir.appendingPathComponent("index.sqlite")
        let (indexes, plan) = try await DatabaseQueue(path: index.path).read { db in
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('note_bookmarks', 'note_favourites')")
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT host, id FROM note WHERE host = ? AND \(StoreFile.markedRows("bookmarks"))", arguments: ["one.example"])
                .map { $0["detail"] as String? ?? "" }.joined(separator: " ")
            return (indexes, plan)
        }
        #expect(Set(indexes) == ["note_bookmarks", "note_favourites"])
        #expect(plan.contains("note_bookmarks"), "\(plan)")
    }

    @Test("A read that reached the end takes the category off a post it did not meet though only the file holds it, and the file says so after the next save; the post stays, with what else it came through")
    func unmarkedOnTheFileOnly() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        let pool = ItemStore(sources: [Self.mastodon], rows: file)
        #expect(await pool.all().isEmpty, "the premise: the pool holds none of them")
        #expect(await pool.marked(host: "one.example", category: .bookmarks) == [
            NoteKey(host: "one.example", id: "1"): "2", NoteKey(host: "one.example", id: "2"): "4",
            NoteKey(host: "one.example", id: "3"): "0",
        ])
        #expect(await pool.lowestMark(host: "one.example", category: .bookmarks) == "0")
        // The source now marks the second post alone.
        await pool.land(MarksRead(notes: [Self.notes[1]], covered: MarkCover(low: MastodonMarks.end), whole: true), of: .bookmarks, ifSourceHere: "one.example")
        try await StoreSaver(store: pool, file: file).save()

        let after = Dictionary(uniqueKeysWithValues: StoreFile.open(at: dir).notes.map { ($0.id, $0) })
        #expect(after.count == 3, "nothing let go")
        #expect(after["1"]?.categories == [.favourites] && after["1"]?.listed == [.favourites: "0"])
        #expect(after["2"]?.categories == [.bookmarks] && after["2"]?.listed == [.bookmarks: "4"])
        #expect(after["3"]?.categories == [.home] && after["3"]?.listed == [.home: "s-3"])
    }

    @Test("A read that stopped above a post's mark leaves it be, on the file as in the pool")
    func stoppedAboveLeavesItBe() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        let pool = ItemStore(sources: [Self.mastodon], rows: file)
        // Met nothing, and walked down to the mark `3`: only the second, listed under `4`, is passed.
        await pool.land(MarksRead(notes: [], covered: MarkCover(low: "3")), of: .bookmarks, ifSourceHere: "one.example")
        try await StoreSaver(store: pool, file: file).save()
        let after = Dictionary(uniqueKeysWithValues: StoreFile.open(at: dir).notes.map { ($0.id, $0.categories) })
        #expect(after == ["1": [.bookmarks, .favourites], "2": [], "3": [.bookmarks, .home]])
    }

    @Test("A place where marks may be missing, and the mark it is read down from, is written with its row and read back; moved down, it is written as it moved")
    func aPlaceMissingIsKept() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        let pool = ItemStore(sources: [Self.mastodon], rows: file)
        let key = NoteKey(host: "one.example", id: "2")
        _ = await pool.marked(host: "one.example", category: .bookmarks)
        await pool.land(
            MarksRead(notes: [], covered: MarkCover(low: "5"), hole: MarksRead.Hole(post: key, from: "9"), begun: 1),
            of: .bookmarks, ifSourceHere: "one.example"
        )
        try await StoreSaver(store: pool, file: file).save()
        #expect(StoreFile.open(at: dir).notes.first { $0.id == "2" }?.gaps.first?.from == "9")
        await pool.land(MarksRead(notes: [], covered: MarkCover(low: "7", high: "9"), fills: "9", begun: 2), of: .bookmarks, ifSourceHere: "one.example")
        try await StoreSaver(store: pool, file: file).save()
        #expect(StoreFile.open(at: dir).notes.first { $0.id == "2" }?.gaps.first?.from == "7")
        // Met what is held: the place goes.
        await pool.land(MarksRead(notes: [], covered: MarkCover(low: "5", high: "7"), connected: true, fills: "7", begun: 3), of: .bookmarks, ifSourceHere: "one.example")
        try await StoreSaver(store: pool, file: file).save()
        #expect(StoreFile.open(at: dir).notes.first { $0.id == "2" }?.gaps.isEmpty == true)
    }

    @Test("While the file may hold another store — a read back on its way — a read decides nothing of what only the file holds: its posts land, and the next read decides")
    func passingThroughDecidesNothing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        let pool = ItemStore(sources: [Self.mastodon], rows: file)
        await pool.mayBePutBack(true)
        await pool.land(MarksRead(notes: [], covered: MarkCover(low: MastodonMarks.end), whole: true, begun: 1), of: .bookmarks, ifSourceHere: "one.example")
        await pool.mayBePutBack(false)
        #expect(await pool.marked(host: "one.example", category: .bookmarks).count == 3, "nothing was taken off while passing through")
        await pool.land(MarksRead(notes: [], covered: MarkCover(low: MastodonMarks.end), whole: true, begun: 2), of: .bookmarks, ifSourceHere: "one.example")
        #expect(await pool.marked(host: "one.example", category: .bookmarks).isEmpty)
    }

    @Test("A build that knows no v17-marks sees this build's store as newer, and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: Self.notes)
        let before = try Data(contentsOf: index)
        var older = DatabaseMigrator()
        for id in try migrations(index) where id != "v17-marks" { older.registerMigration(id) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        #expect(try await DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded))
        #expect(try Data(contentsOf: index) == before)
    }
}
