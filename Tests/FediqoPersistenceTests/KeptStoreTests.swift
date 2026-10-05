import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What the person keeps (#284), on disk: written with its row, read back by a relaunch, carried
/// by the package, and behind a migration id of its own so a build that knows nothing of it
/// refuses the store rather than letting a kept post go.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v5-said`, frozen here, with rows inserted as raw SQL — so no live record
/// type decides what the old file looked like.
@Suite("What the person keeps, on disk")
struct KeptStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    /// Everything the build before this knew: five ids, and the tables as `v5-said` left them.
    private static var v5Migrator: DatabaseMigrator {
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
            }
        }
        for id in ["v2-categories", "v3-holding", "v4-gone", "v5-said"] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    private static let facts = #"{"attachments":[],"author":"Ada","body":"hello","emojis":[],"handle":"@ada","kind":"mastodon"}"#

    /// A store the build before wrote: one source, a post a timeline drew, one held aside, one
    /// its source said had gone, and one kept past its source's removal (#250).
    private static let rows: [String] = [
        #"INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')"#,
        #"INSERT INTO note VALUES ('one.example', '1', '2026-09-16 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL)"#,
        #"INSERT INTO note VALUES ('one.example', '2', '2026-09-15 12:00:00.000', '[]', '\#(facts)', 'aside', NULL)"#,
        #"INSERT INTO note VALUES ('one.example', '3', '2026-09-14 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', '2026-09-20 12:00:00.000')"#,
        #"INSERT INTO note VALUES ('left.example', '4', '2026-09-13 12:00:00.000', '[{"kind":"public"}]', '\#(facts)', 'arrived', NULL)"#,
    ]

    private func v5Store() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v5Migrator.migrate(queue)
        try queue.write { db in
            for sql in Self.rows { try db.execute(sql: sql) }
        }
        return dir
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func note(_ id: String, kept: Bool = false, holding: Holding = .arrived) -> Note {
        var note = PackagerFixture.note(id, holding: holding)
        note.kept = kept
        return note
    }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every post as it was, and none of them kept")
    func carriedForward() throws {
        let dir = try v5Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil)
        #expect(opened.setAside == nil)
        #expect(!opened.storeIsNewer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.sources == [Self.mastodon])
        #expect(opened.notes.map(\.id) == ["1", "2", "3", "4"], "in the order they were written")
        #expect(opened.notes.allSatisfy { !$0.kept }, "nobody kept a post before there was keeping")
        #expect(opened.notes.map(\.holding) == [.arrived, .aside, .arrived, .arrived])
        #expect(opened.notes.map { $0.goneSince != nil } == [false, false, true, false])
        #expect(opened.notes.last?.source == Source(host: "left.example", kind: .mastodon))
        let migrations = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrations == ["v1-index", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions", "v9-language"])
    }

    @Test("A post kept in a carried-forward store is still kept after a save and a reopen, and no other is")
    func keptInACarriedStore() async throws {
        let dir = try v5Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        #expect(await store.setKept(true, for: NoteKey(host: "one.example", id: "3")))
        let snapshot = await store.snapshot()
        try await #require(opened.file).save(sources: snapshot.sources, notes: snapshot.notes)

        let again = StoreFile.open(at: dir)

        #expect(again.notes.map(\.id) == ["1", "2", "3", "4"])
        #expect(again.notes.map(\.kept) == [false, false, true, false])
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v5Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        _ = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The same read-only probe `StoreFile` makes, with the build before's migrator.
        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly)
            .read(Self.v5Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    // MARK: - A relaunch

    @Test("Quit and open again: what was kept is still kept, held aside or not, and what was un-kept is not")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = [Self.note("1", kept: true), Self.note("2"), Self.note("3", kept: true, holding: .aside)]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)
        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.kept) == [true, false, true])

        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        #expect(await store.setKept(false, for: notes[0].key))
        let snapshot = await store.snapshot()
        try await #require(opened.file).save(sources: snapshot.sources, notes: snapshot.notes)
        #expect(StoreFile.open(at: dir).notes.map(\.kept) == [false, false, true])
    }

    @Test("A kept post whose source was removed with its posts is read back by a relaunch, kept, naming the source that went")
    func keptPastItsSource() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [Self.mastodon], notes: [Self.note("1"), Self.note("2")])
        await store.setKept(true, for: Self.note("1").key)
        await store.remove(host: Self.mastodon.host)
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.sources.isEmpty)
        #expect(opened.notes.map(\.id) == ["1"])
        #expect(opened.notes.first?.kept == true)
        #expect(opened.notes.first?.source == Source(host: Self.mastodon.host, kind: .mastodon))
    }

    // MARK: - Taken away

    @Test("Taken away and read back on a clean device: what was kept is still kept, in memory and on disk")
    func ridesThePackage() async throws {
        let from = try await Device(
            sources: [Self.mastodon],
            notes: [Self.note("1", kept: true), Self.note("2"), Self.note("3", kept: true, holding: .aside)]
        )
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: false) { _ in }

        let held = await onto.store.snapshot().notes
        #expect(held.map(\.id) == ["1", "2", "3"])
        #expect(held.map(\.kept) == [true, false, true])
        let reopened = try StoreFile(at: onto.directory).load().notes
        #expect(reopened.map(\.kept) == [true, false, true])
    }
}
