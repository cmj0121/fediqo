import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Opening the store: the schema file is the migration, and the database it leaves behind is
/// the one the document describes.
@Suite("Opening the local store")
struct LocalStoreTests {
    /// `docs/<name>.sql`, found by walking up from this file to the package root.
    private func documentedSchema(_ name: String) -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir.deleteLastPathComponent()
        }
        return dir.appendingPathComponent("docs/\(name).sql")
    }

    @Test("Each bundled schema is its docs copy, byte for byte", arguments: ["schema", "schema-002", "schema-003", "schema-004", "schema-005",
                                "schema-006", "schema-007", "schema-008", "schema-009", "schema-010", "schema-011"])
    func bundledSchemaMatchesDocs(name: String) throws {
        let bundled = try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "sql")!)
        #expect(bundled == (try Data(contentsOf: documentedSchema(name))))
    }

    @Test("A fresh store has every table, the triggers, and the three protocols")
    func freshStoreMatchesSchema() async throws {
        let store = try LocalStore.inMemory()
        let (tables, triggers, protocols, migrations, feeds, seeded) = try await store.read { db in
            let tables = try String.fetchSet(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'posts_fts_%' AND name != 'grdb_migrations'
                """)
            let triggers = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
            let rows = try Row.fetchAll(db, sql: "SELECT proto, created_at FROM protocols ORDER BY proto")
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            let feedRows = try Row.fetchAll(db, sql: "SELECT feed, ranked, created_at FROM feeds ORDER BY feed")
            let seeded = try Bool.fetchOne(db, sql: "SELECT min(created_at) > 0 FROM filter_kinds")!
            return (tables, triggers, rows.map { ($0["proto"] as String, $0["created_at"] as Int64) }, migrations,
                    feedRows.map { ($0["feed"] as String, ($0["ranked"] as Int) == 1, $0["created_at"] as Int64) },
                    seeded)
        }

        #expect(tables == ["protocols", "servers", "accounts", "posts", "tags", "post_tags",
                           "server_trends", "tag_buckets", "posts_fts", "owned_accounts",
                           "feeds", "post_origins", "post_mentions", "timelines", "filter_kinds",
                           "timeline_filters", "media_kinds", "post_media",
                           "post_marks", "mutes", "post_emojis", "visibilities", "publications",
                           "notice_kinds", "notices", "notice_marks", "post_cards"])
        #expect(triggers == ["posts_fts_insert", "posts_fts_delete", "posts_fts_update"])
        #expect(protocols.map(\.0) == ["atproto", "mastodon", "nostr"])
        #expect(protocols.allSatisfy { $0.1 > 0 })
        #expect(migrations == ["001", "002", "003", "004", "005", "006", "007", "008", "009", "010", "011", "012", "013", "014"])
        #expect(feeds.map(\.0) == ["author", "home", "notice", "public", "thread", "trend"])
        // Order is the base source's: only trending is handed over already ranked.
        #expect(feeds.filter { $0.1 }.map(\.0) == ["trend"])
        #expect(seeded)
    }

    @Test("Foreign keys are on, so a post without its server is refused")
    func foreignKeysEnforced() async throws {
        let store = try LocalStore.inMemory()
        #expect(try await store.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") } == 1)

        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(sql: """
                    INSERT INTO posts (merge_key, proto, uri, source_url, posted_at, author_id,
                                       last_seen_at, created_at)
                    VALUES ('k', 'mastodon', 'u', 'https://nowhere.test', 0, 'a', 0, 0)
                    """)
            }
        }
    }

    @Test("Opening the same file twice migrates once")
    func reopeningIsIdempotent() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fediqo.sqlite").path

        let first = try await LocalStore(path: path).read { db in
            try Int64.fetchOne(db, sql: "SELECT created_at FROM protocols WHERE proto = 'mastodon'")
        }
        try await Task.sleep(for: .milliseconds(5))
        let again = try await LocalStore(path: path).read { db in
            (try Int64.fetchOne(db, sql: "SELECT created_at FROM protocols WHERE proto = 'mastodon'"),
             try String.fetchOne(db, sql: "PRAGMA journal_mode"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"))
        }

        #expect(again.0 == first)
        #expect(again.1 == "wal")
        #expect(again.2 == 14)
    }

    @Test("A 001 store upgrades in place: owned_accounts appears, what was there stays")
    func upgradingFrom001KeepsPriorData() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fediqo.sqlite").path

        do {  // yesterday's app: migrated to 001 only, with a server, an account, and a post
            let old = try LocalStore(path: path, upTo: "001")
            try old.writeSync { db in
                try db.execute(sql: """
                    INSERT INTO servers (url, host, proto, created_at)
                    VALUES ('https://a.test', 'a.test', 'mastodon', 0)
                    """)
                try db.execute(sql: """
                    INSERT INTO accounts (author_id, proto, server_url, created_at)
                    VALUES ('https://a.test/users/a', 'mastodon', 'https://a.test', 0)
                    """)
                try db.execute(sql: """
                    INSERT INTO posts (merge_key, proto, uri, source_url, posted_at, author_id,
                                       last_seen_at, created_at)
                    VALUES ('k', 'mastodon', 'u', 'https://a.test', 0, 'https://a.test/users/a', 0, 0)
                    """)
            }
            #expect(try old.readSync { db in
                try Bool.fetchOne(db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE name = 'owned_accounts'")
            } == false)
        }

        let (hasTable, posts, migrations) = try await LocalStore(path: path).read { db in
            (try Bool.fetchOne(db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE name = 'owned_accounts'")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM posts")!,
             try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"))
        }
        #expect(hasTable)
        #expect(posts == 1)
        #expect(migrations == ["001", "002", "003", "004", "005", "006", "007", "008", "009", "010", "011", "012", "013", "014"])
    }

    @Test("owned_accounts records a fact about an account we have; a ghost is refused")
    func ownedAccountWithoutAccountIsRefused() async throws {
        let store = try LocalStore.inMemory()
        try await store.write { db in
            try db.execute(sql: """
                INSERT INTO servers (url, host, proto, created_at)
                VALUES ('https://a.test', 'a.test', 'mastodon', 0)
                """)
        }
        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(sql: """
                    INSERT INTO owned_accounts (author_id, server_url, created_at)
                    VALUES ('https://a.test/users/ghost', 'https://a.test', 0)
                    """)
            }
        }
    }
}
