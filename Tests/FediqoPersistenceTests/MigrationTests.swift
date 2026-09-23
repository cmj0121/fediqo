import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #31: what a 0.1.0 store held is still held once 0.2.0 opens it, carried forward in place.
///
/// The store is made the way 0.1.0 made it — its migrator, frozen here with the DDL verbatim, and
/// rows inserted as raw SQL with the JSON 0.1.0 wrote — so no live record type decides what the
/// old file looked like.
@Suite("Carrying a 0.1.0 store forward")
struct MigrationTests {
    /// 0.1.0's migrator, and all a 0.1.0 build knows.
    private static var v1Migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-index") { db in
            try db.create(table: "source") { t in
                t.primaryKey("host", .text)
                t.column("kind", .text).notNull()
                t.column("boards", .text).notNull()
            }
            try db.create(table: "note") { t in
                t.column("host", .text).notNull()
                t.column("id", .text).notNull()
                t.primaryKey(["host", "id"])
                t.column("posted_at", .datetime).notNull()
                t.column("origins", .text).notNull()
                t.column("facts", .text).notNull()
            }
        }
        return migrator
    }

    private static let plain = #"{"attachments":[],"author":"Ada","body":"hello","emojis":[],"handle":"@ada"}"#
    private static let faceted = #"""
        {"attachments":[{"alt":"a cat","height":800,"kind":"image","previewURL":"https:\/\/cdn.example\/p-small.jpg","url":"https:\/\/cdn.example\/p.jpg","width":1200}],"author":"Ada","avatarURL":"https:\/\/cdn.example\/ada.png","body":"hello","boostedBy":"Carol","emojis":[{"shortcode":"blobcat","staticURL":"https:\/\/cdn.example\/blobcat.png","url":"https:\/\/cdn.example\/blobcat.gif"}],"handle":"@ada","reply":{"handle":"@bob@mastodon.example"},"sensitive":true,"spoiler":"cover","url":"https:\/\/mastodon.example\/@ada\/5"}
        """#

    /// Everything 0.1.0 could hold: a microblog's four origin shapes and a fully faceted post, a
    /// Discuz! forum with a chosen board and one post that recorded it and one that did not, a
    /// Discourse topic, and a note whose source is gone.
    private static let rows: [String] = [
        #"INSERT INTO source VALUES ('mastodon.example', 'mastodon', '[]')"#,
        #"INSERT INTO source VALUES ('forum.example', 'discuz', '[{"fid":37,"name":"News"}]')"#,
        #"INSERT INTO source VALUES ('discourse.example', 'discourse', '[]')"#,
        #"INSERT INTO note VALUES ('mastodon.example', 'm1', '2026-09-16 12:00:00.000', '["publicTimeline"]', '\#(plain)')"#,
        #"INSERT INTO note VALUES ('mastodon.example', 'm2', '2026-09-14 12:00:00.000', '["publicTimeline","trending"]', '\#(plain)')"#,
        #"INSERT INTO note VALUES ('mastodon.example', 'm3', '2026-07-30 12:00:00.000', '["trending"]', '\#(plain)')"#,
        #"INSERT INTO note VALUES ('mastodon.example', 'm4', '2026-08-01 12:00:00.000', '[]', '\#(plain)')"#,
        #"INSERT INTO note VALUES ('mastodon.example', 'm5', '2026-09-01 12:00:00.000', '["publicTimeline"]', '\#(faceted)')"#,
        #"INSERT INTO note VALUES ('forum.example', 'discuz:forum.example:1', '2026-09-02 12:00:00.000', '["publicTimeline"]', '{"attachments":[],"author":"青木","board":"News","boardID":"37","body":"","emojis":[],"handle":"@青木@forum.example","title":"board post"}')"#,
        #"INSERT INTO note VALUES ('forum.example', 'discuz:forum.example:2', '2026-09-03 12:00:00.000', '["publicTimeline"]', '{"attachments":[],"author":"晚归","board":"闲谈茶座","body":"","emojis":[],"handle":"@晚归@forum.example","title":"guide post"}')"#,
        #"INSERT INTO note VALUES ('discourse.example', 'discourse:discourse.example:9', '2026-06-20 12:00:00.000', '["publicTimeline"]', '{"attachments":[],"author":"Sam","board":"Dev","body":"","emojis":[],"handle":"@sam@discourse.example","title":"topic"}')"#,
        #"INSERT INTO note VALUES ('gone.example', 'orphan', '2026-09-16 12:00:00.000', '["publicTimeline"]', '\#(plain)')"#,
    ]

    private static let mastodon = Source(host: "mastodon.example", kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 37, name: "News")])
    private static let discourse = Source(host: "discourse.example", kind: .discourse)

    private static func day(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + "T12:00:00Z")!
    }

    private static func plainNote(_ id: String, _ posted: String, _ categories: Set<FediqoCore.Category>) -> Note {
        Note(id: id, source: mastodon, author: "Ada", handle: "@ada", body: "hello",
             postedAt: day(posted), categories: categories)
    }

    /// What 0.2.0 must read back: every fact as 0.1.0 held it, and the categories mapped.
    private static var expected: Set<Note> {
        [
            plainNote("m1", "2026-09-16", [.public]),
            plainNote("m2", "2026-09-14", [.public, .trends]),
            plainNote("m3", "2026-07-30", [.trends]),
            plainNote("m4", "2026-08-01", []),
            Note(
                id: "m5", source: mastodon, author: "Ada", handle: "@ada", body: "hello",
                postedAt: day("2026-09-01"), categories: [.public],
                reply: Reply(handle: "@bob@mastodon.example"), boostedBy: "Carol",
                avatarURL: URL(string: "https://cdn.example/ada.png"),
                attachments: [FediqoCore.Attachment(
                    kind: .image, url: URL(string: "https://cdn.example/p.jpg"),
                    previewURL: URL(string: "https://cdn.example/p-small.jpg"), alt: "a cat",
                    width: 1200, height: 800
                )],
                sensitive: true, spoiler: "cover",
                emojis: [CustomEmoji(shortcode: "blobcat", url: URL(string: "https://cdn.example/blobcat.gif")!,
                                     staticURL: URL(string: "https://cdn.example/blobcat.png"))],
                url: URL(string: "https://mastodon.example/@ada/5")
            ),
            Note(id: "discuz:forum.example:1", source: forum, author: "青木", handle: "@青木@forum.example",
                 body: "", title: "board post", board: "News", postedAt: day("2026-09-02"),
                 categories: [.board(id: "37")]),
            // A cross-board listing's post: 0.1.0's `publicTimeline` on a forum meant only "read
            // from its front page", and it recorded no board, so it carries none.
            Note(id: "discuz:forum.example:2", source: forum, author: "晚归", handle: "@晚归@forum.example",
                 body: "", title: "guide post", board: "闲谈茶座", postedAt: day("2026-09-03"),
                 categories: []),
            Note(id: "discourse:discourse.example:9", source: discourse, author: "Sam",
                 handle: "@sam@discourse.example", body: "", title: "topic", board: "Dev",
                 postedAt: day("2026-06-20"), categories: []),
        ]
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Writes a 0.1.0 store into a new directory and returns the directory.
    private func v1Store(_ rows: [String] = MigrationTests.rows) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v1Migrator.migrate(queue)
        try queue.write { db in
            for sql in rows { try db.execute(sql: sql) }
        }
        return dir
    }

    /// What #7 counts, taken off the 0.1.0 file before anything opens it with 0.2.0.
    private func v1Holdings(_ index: URL) throws -> Holdings {
        var readOnly = Configuration()
        readOnly.readonly = true
        let notes = try DatabaseQueue(path: index.path, configuration: readOnly).read { db in
            try Row.fetchAll(db, sql: """
                SELECT note.host, note.id, note.posted_at, source.kind
                FROM note JOIN source USING (host)
                """).map { row in
                Note(id: row["id"], source: Source(host: row["host"], kind: ProtocolKind(rawValue: row["kind"])!),
                     author: "", handle: "", body: "", postedAt: row["posted_at"], categories: [])
            }
        }
        return Holdings(notes: notes, per: .month, calendar: utc)
    }

    private func migrations(_ index: URL) throws -> [String] {
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    @Test("A 0.1.0 store opens in place with every source, board, post and count, and categories mapped")
    func carriedForward() async throws {
        let dir = try v1Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let counted = try v1Holdings(index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil)
        #expect(opened.setAside == nil)
        #expect(!opened.storeIsNewer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.sources == [Self.mastodon, Self.forum, Self.discourse])
        #expect(Set(opened.notes) == Self.expected, "the orphan stays dropped; every other post is here")
        #expect(opened.notes.count == 8)
        // 0.1.0 kept the booster's name only, so a carried boost matches on its author alone.
        #expect(opened.notes.first { $0.id == "m5" }?.boosterHandle == nil)
        #expect(Holdings(notes: opened.notes, per: .month, calendar: utc) == counted)
        #expect(counted.posts == 8)
        #expect(try migrations(index) == ["v1-index", "v2-categories", "v3-holding", "v4-gone"])
        // Every row 0.1.0 kept arrived through a timeline, which is what the new column says.
        #expect(opened.notes.allSatisfy { $0.holding == .arrived })
        // And no source has said any of them went (#179).
        #expect(opened.notes.allSatisfy { $0.goneSince == nil })

        // Written the way a 0.2.0 save writes it, so the next save changes nothing about a row.
        let written = try await DatabaseQueue(path: index.path).read { db in
            try String.fetchOne(db, sql: "SELECT categories FROM note WHERE id = 'm2'")
        }
        #expect(written == #"[{"kind":"public"},{"kind":"trends"}]"#)
    }

    @Test("A second open of a carried-forward store changes nothing on disk")
    func secondOpenIsANoOp() async throws {
        let dir = try v1Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let first = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let again = StoreFile.open(at: dir)

        #expect(again.setAside == nil)
        #expect(Set(again.notes) == Set(first.notes))
        #expect(again.sources == first.sources)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    @Test("A carried-forward store saved and reopened still holds the same")
    func saveAndReopen() async throws {
        let dir = try v1Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        let again = StoreFile.open(at: dir)
        #expect(again.sources == opened.sources)
        #expect(Set(again.notes) == Self.expected)
    }

    /// #31a still holds after #31b: the store 0.2.0 wrote is one a 0.1.0-only build refuses.
    @Test("A build that knows only 0.1.0 sees the carried-forward store as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v1Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        _ = StoreFile.open(at: dir)
        let before = try Data(contentsOf: index)
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The same read-only probe `StoreFile` makes, with 0.1.0's migrator in place of this one.
        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly)
            .read(Self.v1Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
    }

    @Test("A 0.1.0 row the migration cannot read sets the file aside unchanged, not half carried", arguments: [
        // Origins that are not JSON, on a microblog.
        #"INSERT INTO note VALUES ('mastodon.example', 'bad', '2026-09-16 12:00:00.000', 'not json', '\#(MigrationTests.plain)')"#,
        // Facts that are not JSON, on a forum, where the migration reads them for the board.
        #"INSERT INTO note VALUES ('forum.example', 'bad', '2026-09-16 12:00:00.000', '["publicTimeline"]', 'not json')"#,
    ])
    func failedMigrationSetsAsideTheV1File(bad: String) throws {
        let dir = try v1Store(Self.rows + [bad])
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: dir.appendingPathComponent("index.sqlite"))

        let opened = StoreFile.open(at: dir)

        let aside = try #require(opened.setAside)
        #expect(try Data(contentsOf: aside) == before)
        #expect(try migrations(aside) == ["v1-index"])
        #expect(opened.file != nil)
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
    }
}
