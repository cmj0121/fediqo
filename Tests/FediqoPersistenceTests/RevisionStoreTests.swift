import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A changed post's mark and what it said before (#286), on disk: written with its row and in
/// its row, read back by a relaunch, carried by the package, gone from the file when the row is,
/// and behind a migration id of its own so a build that knows nothing of them refuses the store.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v7-bookmarked`, frozen here, with rows inserted as raw SQL — so no live
/// record type decides what the old file looked like.
@Suite("What a changed post said before, on disk")
struct RevisionStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon
    private static let origin = PackagerFixture.origin

    /// Everything the build before this knew: seven ids, and the tables as `v7-bookmarked` left them.
    private static var v7Migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-index") { db in
            try db.create(table: "source") { t in
                t.primaryKey("host", .text)
                t.column("kind", .text).notNull()
                t.column("boards", .text).notNull()
                t.column("said", .text)
                t.column("said_at", .datetime)
            }
            try db.create(table: "note") { t in
                t.column("host", .text).notNull()
                t.column("id", .text).notNull()
                t.primaryKey(["host", "id"])
                t.column("posted_at", .datetime).notNull()
                t.column("categories", .text).notNull()
                t.column("facts", .text).notNull()
                t.column("holding", .text).notNull().defaults(to: "arrived")
                t.column("gone_at", .datetime)
                t.column("kept", .boolean).notNull().defaults(to: false)
                t.column("bookmarked", .boolean)
            }
        }
        for id in ["v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked"] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    private static let facts = #"{"attachments":[],"author":"Ada","body":"as written","emojis":[],"handle":"@ada","kind":"mastodon"}"#

    /// A store the build before wrote: one source, a post, a kept and bookmarked one, one aside.
    private static let rows: [String] = [
        #"INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')"#,
        #"INSERT INTO note VALUES ('one.example', '1', '2026-09-16 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 0, NULL)"#,
        #"INSERT INTO note VALUES ('one.example', '2', '2026-09-15 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 1, 1)"#,
        #"INSERT INTO note VALUES ('one.example', '3', '2026-09-14 12:00:00.000', '[]', '\#(facts)', 'aside', NULL, 0, 0)"#,
    ]

    private func v7Store() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v7Migrator.migrate(queue)
        try queue.write { db in
            for sql in Self.rows { try db.execute(sql: sql) }
        }
        return dir
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func at(_ minutes: Double) -> Date { origin.addingTimeInterval(minutes * 60) }

    /// A post as its source hands it over, `edited` minutes after it was published or never.
    private static func copy(_ id: String, _ body: String, edited: Double? = nil, holding: Holding = .arrived) -> Note {
        Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: body, postedAt: origin,
            categories: [.public], spoiler: "", statusID: id, holding: holding, editedAt: edited.map(at)
        )
    }

    /// A store holding one post changed twice, one already changed when read, and one never.
    private static func changed() async -> ItemStore {
        let store = ItemStore(sources: [mastodon], notes: [
            copy("1", "alpha-wording"), copy("2", "as it is now", edited: 5), copy("3", "never changed"),
        ])
        await store.ingest([copy("1", "beta-wording", edited: 10)], ifSourceHere: mastodon.host)
        await store.ingest([copy("1", "three, the secret word gone", edited: 20)], ifSourceHere: mastodon.host)
        return store
    }

    private static let earlier = [
        Wording(body: "alpha-wording", spoiler: "", until: at(10)), Wording(body: "beta-wording", spoiler: "", until: at(20)),
    ]

    // MARK: - An older store

    @Test("The store of the build before opens in place with every post as it was, none of them changed")
    func carriedForward() throws {
        let dir = try v7Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil)
        #expect(opened.setAside == nil)
        #expect(!opened.storeIsNewer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.sources == [Self.mastodon])
        #expect(opened.notes.map(\.id) == ["1", "2", "3"], "in the order they were written")
        #expect(opened.notes.allSatisfy { $0.editedAt == nil && $0.earlier.isEmpty })
        #expect(opened.notes.allSatisfy { $0.body == "as written" })
        #expect(opened.notes.map(\.kept) == [false, true, false], "what was kept is still kept")
        #expect(opened.notes.map(\.bookmarked) == [nil, true, false], "and what the source said of a bookmark")
        #expect(opened.notes.map(\.holding) == [.arrived, .arrived, .aside])
        let migrations = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrations == [
            "v1-index", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions",
        ])
    }

    @Test("A post in a carried-forward store that its source then changes keeps what it said, after a save and a reopen")
    func changedInACarriedStore() async throws {
        let dir = try v7Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let first = try #require(opened.notes.first)
        let changed = Note(
            id: first.id, source: first.source, author: first.author, handle: first.handle, body: "as changed",
            postedAt: first.postedAt, categories: first.categories, editedAt: Self.at(30)
        )
        await store.ingest([changed], ifSourceHere: Self.mastodon.host)
        let snapshot = await store.snapshot()
        try await #require(opened.file).save(sources: snapshot.sources, notes: snapshot.notes)

        let again = StoreFile.open(at: dir)

        #expect(again.notes.map(\.body) == ["as changed", "as written", "as written"])
        #expect(again.notes.first?.earlier.map(\.body) == ["as written"])
        #expect(again.notes.first?.earlier.first?.until == Self.at(30))
        #expect(again.notes.first?.editedAt == Self.at(30))
        #expect(again.notes.first?.postedAt == first.postedAt)
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v7Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        _ = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The same read-only probe `StoreFile` makes, with the build before's migrator.
        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly)
            .read(Self.v7Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    // MARK: - A relaunch

    @Test("Quit and open again: the mark and the earlier wordings are there, in order, each with when it changed")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = await Self.changed().snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == snapshot.notes)
        #expect(opened.notes.map { $0.editedAt != nil } == [true, true, false])
        #expect(opened.notes[0].earlier == Self.earlier)
        #expect(opened.notes[1].earlier.isEmpty && opened.notes[2].earlier.isEmpty)
    }

    @Test("Letting the item go takes what it said before out of the file: no row, no column and no table still holds a word of it")
    func goneFromTheFile() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = await Self.changed()
        let file = try StoreFile(at: dir)
        var snapshot = await store.snapshot()
        try await file.save(sources: snapshot.sources, notes: snapshot.notes)
        func held(_ word: String) throws -> Bool {
            try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'").contains { table in
                    try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").contains { row in
                        row.databaseValues.contains { String(describing: $0).contains(word) }
                    }
                }
            }
        }
        #expect(try held("alpha-wording") && held("beta-wording"), "the earlier wordings are in the file while the item is")

        await store.letGo(span: Self.origin.addingTimeInterval(-60)..<Self.origin.addingTimeInterval(60))
        snapshot = await store.snapshot()
        try await file.save(sources: snapshot.sources, notes: snapshot.notes)
        try await file.compact()

        #expect(snapshot.notes.isEmpty)
        #expect(try !held("alpha-wording") && !held("beta-wording") && !held("secret"), "an earlier wording outlived its item")
        #expect(StoreFile.open(at: dir).notes.isEmpty)
    }

    @Test("Read back from disk, a post read again with the same fraction-of-a-second edit moment is the same revision: nothing is added, and the row is not rewritten",
          arguments: [false, true])
    func aFractionalMomentIsTheSameMoment(roundsUp: Bool) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Moments with thirds and sevenths of a millisecond in them, as a wire date parses.
        // One that a store's milliseconds fall short of, and — in the second case — one they
        // round past: read back, the copy just parsed must be neither later nor earlier.
        let first = Self.origin.addingTimeInterval(601.987_654_3)
        let second = Self.origin.addingTimeInterval(1_203.123_456_7 + (roundsUp ? 0.000_4 : 0))
        func copy(_ body: String, _ edited: Date?) -> Note {
            Note(
                id: "1", source: Self.mastodon, author: "Ada", handle: "@ada", body: body, postedAt: Self.origin,
                categories: [.public], spoiler: "", statusID: "1", editedAt: edited
            )
        }
        let store = ItemStore(sources: [Self.mastodon], notes: [copy("one", nil)])
        await store.ingest([copy("two", first)], ifSourceHere: Self.mastodon.host)
        await store.ingest([copy("three", second)], ifSourceHere: Self.mastodon.host)
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)

        let opened = StoreFile.open(at: dir)
        let relaunched = ItemStore(sources: opened.sources, notes: opened.notes)
        let held = try #require(await relaunched.note(NoteKey(host: Self.mastodon.host, id: "1")))
        #expect(held.earlier.map(\.body) == ["one", "two"])
        let revision = await relaunched.revision

        // The same copy again, by a reload and by a read of the post, with its moment as parsed.
        await relaunched.ingest([copy("three", second)], ifSourceHere: Self.mastodon.host)
        #expect(await relaunched.refresh([copy("three", second)], ifSourceHere: Self.mastodon.host) == false)

        #expect(try #require(await relaunched.note(held.key)) == held, "the same revision read back was taken for a new one")
        #expect(await relaunched.revision == revision, "the row was rewritten for nothing")
    }

    @Test("A post whose edit moment is its publish time — what an impossible moment is taken as — read back from disk and read again is the same revision")
    func anEditAtThePublishMomentIsStable() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let published = Self.origin.addingTimeInterval(0.123_456_7)
        func copy() -> Note {
            Note(
                id: "1", source: Self.mastodon, author: "Ada", handle: "@ada", body: "hostile", postedAt: published,
                categories: [.public], spoiler: "", statusID: "1", editedAt: published
            )
        }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [copy()])
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let held = try #require(await store.note(copy().key))

        await store.ingest([copy()], ifSourceHere: Self.mastodon.host)

        #expect(try #require(await store.note(held.key)) == held)
        #expect(await store.revision == 0, "revised and written down again after a relaunch")
    }

    @Test("A wording that was covered with no line of warning is still known to have been, after a relaunch")
    func aCoveredWordingSurvives() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = Note(
            id: "1", source: Self.mastodon, author: "Ada", handle: "@ada", body: "now", postedAt: Self.origin,
            categories: [.public], sensitive: false, spoiler: "", editedAt: Self.at(10),
            earlier: [
                Wording(body: "was covered", spoiler: "", sensitive: true, until: Self.at(5)),
                Wording(body: "never said", spoiler: nil, sensitive: nil, until: Self.at(10)),
            ]
        )
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [note])
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.first?.earlier == note.earlier)
        #expect(opened.notes.first?.earlier.map(\.covered) == [true, false])
    }

    @Test("A store whose earlier wordings cannot be read, or are more than a row may hold, still opens: the row is whole, with what it may hold of them")
    func aDamagedOrOversizedCell() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = await Self.changed().snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)
        let index = dir.appendingPathComponent("index.sqlite")
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        func write(_ earlier: String) throws {
            try DatabaseQueue(path: index.path).write { db in
                try db.execute(sql: "UPDATE note SET earlier = ? WHERE id = '1'", arguments: [earlier])
            }
        }

        // Not JSON at all — where a `facts` that is not JSON sets the whole store aside.
        try write("not json")
        var opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil && opened.file != nil, "the reader's store was set aside over one cell")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.notes.map(\.id) == ["1", "2", "3"])
        #expect(opened.notes[0].earlier.isEmpty && opened.notes[0].body == snapshot.notes[0].body)
        #expect(opened.notes[0].editedAt == snapshot.notes[0].editedAt, "still marked as changed")

        // More wordings than a row keeps, and heavier than a row may hold: held to both on the way in.
        let many = (0..<(Wording.kept + 30)).map { #"{"body":"w\#($0)","until":\#($0)}"# }.joined(separator: ",")
        try write("[\(many)]")
        opened = StoreFile.open(at: dir)
        #expect(opened.notes[0].earlier.count == Wording.kept)
        #expect(opened.notes[0].earlier.last?.body == "w\(Wording.kept + 29)", "the latest are the ones kept")

        let heavy = String(repeating: "y", count: Wording.budget)
        try write(#"[{"body":"\#(heavy)","until":1},{"body":"light","until":2}]"#)
        opened = StoreFile.open(at: dir)
        #expect(opened.notes[0].earlier.map(\.body) == ["light"])
    }

    // MARK: - Taken away

    @Test("Taken away and read back on a clean device: the mark and the earlier wordings came with the post")
    func ridesThePackage() async throws {
        let snapshot = await Self.changed().snapshot()
        let from = try await Device(sources: snapshot.sources, notes: snapshot.notes)
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: false) { _ in }

        #expect(await onto.store.snapshot().notes == snapshot.notes)
        let reopened = try StoreFile(at: onto.directory).load().notes
        #expect(reopened == snapshot.notes)
        #expect(reopened[0].earlier == Self.earlier)
    }
}
