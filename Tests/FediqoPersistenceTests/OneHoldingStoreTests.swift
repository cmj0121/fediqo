import CryptoKit
import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// One way of holding, on disk (#296): the store of the build before — which wrote, for each
/// row, whether it was held apart from the timelines — opens with every row it held, each an
/// item standing in All; nothing in the file says "held apart" afterwards; and the build before
/// refuses what this one wrote.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v10-references`, frozen here, with rows inserted as raw SQL — so no live
/// record type decides what the old file looked like.
@Suite("One way of holding, on disk")
struct OneHoldingStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon
    private static let forum = Source(host: "forum.example", kind: .discuz)

    /// Everything the build before this knew: ten ids, and the tables as `v10-references` left them.
    private static var v10Migrator: DatabaseMigrator {
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
                t.column("language", .text)
                t.column("refs", .text)
                t.column("refs_due", .boolean).notNull().defaults(to: false)
            }
        }
        for id in [
            "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions", "v9-language",
            "v10-references",
        ] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    private static func facts(_ body: String) -> String {
        #"{"attachments":[],"author":"Ada","body":"\#(body)","emojis":[],"handle":"@ada","kind":"mastodon"}"#
    }

    private static func row(_ id: String, categories: String, holding: String, kept: Int = 0) -> String {
        #"INSERT INTO note (host, id, posted_at, categories, facts, holding, kept, refs) VALUES ('one.example', '\#(id)', '2026-09-16 12:00:0\#(id).000', '\#(categories)', '\#(facts("post \(id)"))', '\#(holding)', \#(kept), '[]')"#
    }

    /// A reply of a forum topic as a row's cells: written by this build's own save, whose facts
    /// the build before wrote the same way, and read out to be put into the older file.
    private static func replyCells() async throws -> (id: String, postedAt: String, categories: String, facts: String) {
        let file = try StoreFile(database: DatabaseQueue())
        let reply = DiscuzPost(
            pid: 71, tid: 5, floor: 21, author: "linlu", handle: "@linlu@forum.example",
            postedAt: PackagerFixture.origin, body: "a reply", page: 3
        ).asNote(host: forum.host, read: PackagerFixture.origin)
        try await file.save(sources: [forum], notes: [reply])
        return try await file.db.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT id, CAST(posted_at AS TEXT) AS at, categories, facts FROM note"))
            return (row["id"], row["at"], row["categories"], row["facts"])
        }
    }

    /// A store the build before wrote: a post that came through Home, and — each held apart —
    /// what a search brought, an answer read in a thread that the person keeps, and a reply of a
    /// forum topic.
    private func v10Store() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reply = try await Self.replyCells()
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v10Migrator.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')")
            try db.execute(sql: "INSERT INTO source (host, kind, boards) VALUES ('forum.example', 'discuz', '[]')")
            try db.execute(sql: Self.row("1", categories: #"[{"kind":"home"}]"#, holding: "arrived"))
            try db.execute(sql: Self.row("2", categories: "[]", holding: "aside"))
            try db.execute(sql: Self.row("3", categories: "[]", holding: "aside", kept: 1))
            try db.execute(
                sql: "INSERT INTO note (host, id, posted_at, categories, facts, holding, refs) VALUES ('forum.example', ?, ?, ?, ?, 'aside', '[]')",
                arguments: [reply.id, reply.postedAt, reply.categories, reply.facts]
            )
        }
        try queue.close()
        return dir
    }

    private func columns(_ index: URL) throws -> [String] {
        try DatabaseQueue(path: index.path).read { db in try db.columns(in: "note").map(\.name) }
    }

    private func migrations(_ index: URL) throws -> [String] {
        try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// Whether the build before, reading `index` and writing nothing, finds it newer than itself.
    private func supersededForTheBuildBefore(_ index: URL) throws -> Bool {
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(Self.v10Migrator.hasBeenSuperseded)
    }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every row it held: what it held apart stands in All at its own time, kept as it was, and nothing is lost")
    func carriedForward() async throws {
        let dir = try await v10Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.setAside == nil && !opened.storeIsNewer && opened.trouble == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.notes.count == 4, "every row, held apart or not")
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let all = await store.all().sorted { $0.id < $1.id }
        #expect(all.map(\.id) == ["1", "2", "3"], "what was held apart stands in All")
        #expect(all.map(\.body) == ["post 1", "post 2", "post 3"])
        #expect(all.map(\.kept) == [false, false, true])
        #expect(all.map(\.categories) == [[.home], [], []], "through no category, as they came")
        let origin = try #require(all.first).postedAt
        #expect(all.map { $0.postedAt.timeIntervalSince(origin) } == [0, 1, 2], "each at its own time")
        let replies = await store.replies()
        #expect(replies.count == 1 && DiscuzPost(held: replies[0])?.body == "a reply", "a forum topic's reply is still that topic's")
    }

    @Test("Nothing in the file says a row is held apart afterwards: the column is gone, and so is every value it held")
    func nothingLeftThatMeansApart() async throws {
        let dir = try await v10Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        #expect(try columns(index).contains("holding"), "the premise: the build before wrote it")
        #expect(try Data(contentsOf: index).range(of: Data("aside".utf8)) != nil, "the premise: and wrote the word")

        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()

        #expect(try !columns(index).contains("holding"))
        #expect(try Data(contentsOf: index).range(of: Data("aside".utf8)) == nil, "the word is still readable in the file")
        #expect(try migrations(index) == [
            "v1-index", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions",
            "v9-language", "v10-references", "v11-one-holding",
        ])
    }

    @Test("A save by this build and a relaunch leave them where they stood")
    func savedAndOpenedAgain() async throws {
        let dir = try await v10Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        try opened.file?.db.close()
        let again = StoreFile.open(at: dir)
        #expect(again.notes == opened.notes && again.trouble == nil)
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() async throws {
        let dir = try await v10Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        #expect(try !supersededForTheBuildBefore(index), "the premise: its own store is its own")
        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()
        let before = try Data(contentsOf: index)

        #expect(try supersededForTheBuildBefore(index))
        #expect(try Data(contentsOf: index) == before)
    }

    @Test("A store this build made from nothing is refused by the build before too")
    func aNewStoreIsRefusedToo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        try file.db.close()
        let index = dir.appendingPathComponent("index.sqlite")
        #expect(try !columns(index).contains("holding"))
        #expect(try supersededForTheBuildBefore(index))
    }

    // MARK: - Taken away, and moved nearby

    @Test(
        "A package the build before took away — under a file's password, and under a key handed over as a move nearby is; onto a device with a store open, and onto one where the package's index is moved into place — is read back with what it held apart standing in All",
        arguments: [PackageKey.password("password"), .direct(SymmetricKey(data: Data(repeating: 7, count: 32)))], [false, true]
    )
    func anOlderPackage(_ key: PackageKey, movedIntoPlace: Bool) async throws {
        let old = try await v10Store()
        let onto = try await Device(noFile: movedIntoPlace)
        let url = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: old); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let index = try Data(contentsOf: old.appendingPathComponent("index.sqlite"))
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let summary = PackageSummary(
            sources: [.init(host: Self.mastodon.host, kind: .mastodon), .init(host: Self.forum.host, kind: .discuz)],
            posts: 4, timelines: 0, takenAt: PackagerFixture.origin, withPictures: false,
            bytes: index.count + settings.count, hasSecrets: false, device: "an older build", appVersion: "0.0.9",
            entryCount: 3
        )
        let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: 1000)
        for (kind, name, data) in [
            (PackageFormat.Entry.Kind.store, "index.sqlite", index), (.settings, "settings", settings), (.secrets, "secrets", Data()),
        ] {
            var offset = 0
            try writer.add(kind, name: name, bytes: data.count) { most in
                guard offset < data.count else { return nil }
                let end = min(data.count, offset + most)
                defer { offset = end }
                return data[offset..<end]
            }
        }
        try writer.finish()

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        #expect(await onto.store.all().map(\.id).sorted() == ["1", "2", "3"])
        #expect(await onto.store.all().first { $0.id == "3" }?.kept == true)
        #expect(await onto.store.replies().count == 1)
        // And on disk, where the next launch reads: the same, with no column left to say otherwise.
        #expect(try !columns(onto.directory.appendingPathComponent("index.sqlite")).contains("holding"))
        #expect(StoreFile.open(at: onto.directory).notes.count == 4)
    }

    @Test("This build's own package carries what a search brought as the item it is")
    func ridesThePackage() async throws {
        let found = Note(
            id: "22", source: Self.mastodon, author: "Ada", handle: "@ada", body: "found",
            postedAt: PackagerFixture.origin, categories: []
        )
        let from = try await Device(sources: [Self.mastodon], notes: [PackagerFixture.note("1"), found])
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("password"), replacing: false) { _ in }
        #expect(await onto.store.all().map(\.id).sorted() == ["1", "22"])
        #expect(await onto.store.all().first { $0.id == "22" }?.categories == [])
    }
}
