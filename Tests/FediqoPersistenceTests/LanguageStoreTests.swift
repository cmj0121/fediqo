import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// The language a post's source says it is in (#287), on disk: written with its row, read back
/// by a relaunch, carried by the package, and behind a migration id of its own so a build that
/// knows nothing of it refuses the store rather than saving every row back without it.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v8-revisions`, frozen here, with rows inserted as raw SQL — so no live
/// record type decides what the old file looked like.
@Suite("The language a post says it is in, on disk")
struct LanguageStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    /// Everything the build before this knew: eight ids, and the tables as `v8-revisions` left them.
    private static var v8Migrator: DatabaseMigrator {
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
                t.column("edited_at", .datetime)
                t.column("earlier", .text)
            }
        }
        for id in ["v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions"] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    private static let facts = #"{"attachments":[],"audience":"followers","author":"Ada","body":"as written","emojis":[],"handle":"@ada","kind":"mastodon","sensitive":true}"#

    /// A store the build before wrote: one source, a post, a kept and changed one, one aside.
    private static let rows: [String] = [
        #"INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')"#,
        #"INSERT INTO note VALUES ('one.example', '1', '2026-09-16 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 0, NULL, NULL, NULL)"#,
        #"INSERT INTO note VALUES ('one.example', '2', '2026-09-15 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 1, 1, '2026-09-15 13:00:00.000', '[{"body":"before","until":1789477200000}]')"#,
        #"INSERT INTO note VALUES ('one.example', '3', '2026-09-14 12:00:00.000', '[]', '\#(facts)', 'aside', NULL, 0, 0, NULL, NULL)"#,
    ]

    private func v8Store() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v8Migrator.migrate(queue)
        try queue.write { db in
            for sql in Self.rows { try db.execute(sql: sql) }
        }
        return dir
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func note(_ id: String, language: String?) -> Note {
        Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: PackagerFixture.origin, categories: [.public], audience: .everyone, sensitive: false,
            spoiler: "", language: language
        )
    }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every post as it was, none of them saying a language")
    func carriedForward() throws {
        let dir = try v8Store()
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
        #expect(opened.notes.allSatisfy { $0.language == nil }, "nothing is not a language")
        #expect(opened.notes.allSatisfy { $0.value(of: "language") == nil })
        // And everything a rule could already be asked of is as it was.
        #expect(opened.notes.allSatisfy { $0.audience == .followers && $0.sensitive == true })
        #expect(opened.notes.map(\.kept) == [false, true, false])
        #expect(opened.notes.map(\.bookmarked) == [nil, true, false])
        #expect(opened.notes[1].earlier.map(\.body) == ["before"] && opened.notes[1].editedAt != nil)
        let migrations = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrations == [
            "v1-index", "v10-references", "v11-one-holding", "v12-references-only", "v13-unsent", "v14-notices", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions",
            "v9-language",
        ])
    }

    @Test("A post in a carried-forward store that is read again saying its language keeps it, after a save and a reopen")
    func saidInACarriedStore() async throws {
        let dir = try v8Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        await store.ingest([Self.note("1", language: "ja")], ifSourceHere: Self.mastodon.host)
        let snapshot = await store.snapshot()
        try await #require(opened.file).save(sources: snapshot.sources, notes: snapshot.notes)

        let again = StoreFile.open(at: dir)

        #expect(again.notes.map(\.language) == ["ja", nil, nil])
        #expect(again.notes.map(\.kept) == [false, true, false])
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v8Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        _ = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The same read-only probe `StoreFile` makes, with the build before's migrator.
        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly)
            .read(Self.v8Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    // MARK: - A relaunch, and taken away

    @Test("Quit and open again: each post says the language its source said, and one that said none says none")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = [Self.note("1", language: "ja"), Self.note("2", language: nil), Self.note("3", language: "zh-TW")]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.language) == ["ja", nil, "zh-tw"])
        #expect(opened.notes.map { $0.value(of: "language") } == [.option("ja"), nil, .option("zh-tw")])
    }

    @Test("A language cell that is no language tag reads back as no language: the row is whole, and nothing of the cell is offered or drawn")
    func aCellThatIsNoLanguage() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [
            Self.note("1", language: "ja"), Self.note("2", language: "en"), Self.note("3", language: "fr"),
        ])
        let index = dir.appendingPathComponent("index.sqlite")
        try await DatabaseQueue(path: index.path).write { db in
            try db.execute(sql: "UPDATE note SET language = ? WHERE id = '1'", arguments: [String(repeating: "x", count: 500_000)])
            try db.execute(sql: "UPDATE note SET language = ? WHERE id = '2'", arguments: ["ja\u{7}\n<script>"])
        }

        let opened = StoreFile.open(at: dir)

        #expect(opened.setAside == nil && opened.file != nil)
        #expect(opened.notes.map(\.id) == ["1", "2", "3"])
        #expect(opened.notes.map(\.language) == [nil, nil, "fr"])
        #expect(opened.notes.map(\.body) == ["hello 1", "hello 2", "hello 3"])
    }

    @Test("Taken away and read back on a clean device: the language each post says, and a timeline's rule on a field, came with it")
    func ridesThePackage() async throws {
        let notes = [Self.note("1", language: "ja"), Self.note("2", language: nil)]
        let from = try await Device(sources: [Self.mastodon], notes: notes)
        // A written timeline with a rule on a field, as the app keeps it: carried as it is kept.
        let timelines = Data(#"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"No covers","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"exclude","kind":"field","field":"covered","type":"flag","value":"yes"}]}]}"#.utf8)
        from.defaults.set(timelines, forKey: "fediqo.timelines")
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: false) { _ in }

        #expect(onto.defaults.data(forKey: "fediqo.timelines") == timelines, "the rule did not come with what the device holds")
        #expect(await onto.store.snapshot().notes.map(\.language) == ["ja", nil])
        #expect(try StoreFile(at: onto.directory).load().notes.map(\.language) == ["ja", nil])
    }
}
