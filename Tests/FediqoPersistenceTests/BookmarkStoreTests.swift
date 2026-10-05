import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What a source said of a bookmark (#285), on disk: written with its row as it was said — yes,
/// no, or nothing — read back by a relaunch, carried by the package, and behind a migration id
/// of its own so a build that knows nothing of it refuses the store rather than saving every
/// row back without it.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v6-kept`, frozen here, with rows inserted as raw SQL — so no live record
/// type decides what the old file looked like.
@Suite("What a source said of a bookmark, on disk")
struct BookmarkStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    /// Everything the build before this knew: six ids, and the tables as `v6-kept` left them.
    private static var v6Migrator: DatabaseMigrator {
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
            }
        }
        for id in ["v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept"] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    private static let facts = #"{"attachments":[],"author":"Ada","body":"hello","emojis":[],"favourited":true,"handle":"@ada","kind":"mastodon"}"#

    /// A store the build before wrote: one source, a post, a kept one, and one held aside.
    private static let rows: [String] = [
        #"INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')"#,
        #"INSERT INTO note VALUES ('one.example', '1', '2026-09-16 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 0)"#,
        #"INSERT INTO note VALUES ('one.example', '2', '2026-09-15 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL, 1)"#,
        #"INSERT INTO note VALUES ('one.example', '3', '2026-09-14 12:00:00.000', '[]', '\#(facts)', 'aside', NULL, 0)"#,
    ]

    private func v6Store() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v6Migrator.migrate(queue)
        try queue.write { db in
            for sql in Self.rows { try db.execute(sql: sql) }
        }
        return dir
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func note(_ id: String, bookmarked: Bool?) -> Note {
        let base = PackagerFixture.note(id)
        return Note(
            id: base.id, source: base.source, author: base.author, handle: base.handle, body: base.body,
            postedAt: base.postedAt, categories: base.categories, bookmarked: bookmarked,
            attachments: base.attachments
        )
    }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every post as it was, and no source heard about a bookmark")
    func carriedForward() throws {
        let dir = try v6Store()
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
        #expect(opened.notes.allSatisfy { $0.bookmarked == nil }, "nothing is no, and nothing was said")
        #expect(opened.notes.map(\.kept) == [false, true, false], "what was kept is still kept")
        #expect(opened.notes.allSatisfy { $0.favourited == true }, "and what the source said before is still said")
        let migrations = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrations == ["v1-index", "v10-references", "v11-one-holding", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions", "v9-language"])
    }

    @Test("What a source says of a bookmark in a carried-forward store is there after a save and a reopen")
    func saidInACarriedStore() async throws {
        let dir = try v6Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let first = try #require(opened.notes.first)
        await store.refresh([Self.note(first.id, bookmarked: true)], ifSourceHere: Self.mastodon.host)
        let snapshot = await store.snapshot()
        try await #require(opened.file).save(sources: snapshot.sources, notes: snapshot.notes)

        let again = StoreFile.open(at: dir)

        #expect(again.notes.map(\.bookmarked) == [true, nil, nil])
        #expect(again.notes.map(\.kept) == [false, true, false])
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v6Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        _ = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The same read-only probe `StoreFile` makes, with the build before's migrator.
        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly)
            .read(Self.v6Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    // MARK: - A relaunch

    @Test("Quit and open again: each mark is as the source last said it — yes, no, and never said")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = [
            Self.note("1", bookmarked: true), Self.note("2", bookmarked: false),
            Self.note("3", bookmarked: nil), Self.note("4", bookmarked: true),
        ]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.bookmarked) == [true, false, nil, true])
    }

    // MARK: - Taken away

    @Test("Taken away and read back on a clean device: what the source said of each bookmark came with it")
    func ridesThePackage() async throws {
        let from = try await Device(
            sources: [Self.mastodon],
            notes: [Self.note("1", bookmarked: true), Self.note("2", bookmarked: false), Self.note("3", bookmarked: nil)]
        )
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: false) { _ in }

        #expect(await onto.store.snapshot().notes.map(\.bookmarked) == [true, false, nil])
        #expect(try StoreFile(at: onto.directory).load().notes.map(\.bookmarked) == [true, false, nil])
    }
}
