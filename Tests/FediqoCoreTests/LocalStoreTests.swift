import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Opening the store: the schema file is the migration, and the database it leaves behind is
/// the one the document describes.
@Suite("Opening the local store")
struct LocalStoreTests {
    /// `docs/schema.sql`, found by walking up from this file to the package root.
    private var documentedSchema: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir.deleteLastPathComponent()
        }
        return dir.appendingPathComponent("docs/schema.sql")
    }

    @Test("The bundled schema is docs/schema.sql, byte for byte")
    func bundledSchemaMatchesDocs() throws {
        let bundled = try Data(contentsOf: Bundle.module.url(forResource: "schema", withExtension: "sql")!)
        #expect(bundled == (try Data(contentsOf: documentedSchema)))
    }

    @Test("A fresh store has every table, the triggers, and the three protocols")
    func freshStoreMatchesSchema() async throws {
        let store = try LocalStore.inMemory()
        let (tables, triggers, protocols) = try await store.read { db in
            let tables = try String.fetchSet(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'posts_fts_%' AND name != 'grdb_migrations'
                """)
            let triggers = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
            let rows = try Row.fetchAll(db, sql: "SELECT proto, created_at FROM protocols ORDER BY proto")
            return (tables, triggers, rows.map { ($0["proto"] as String, $0["created_at"] as Int64) })
        }

        #expect(tables == ["protocols", "servers", "accounts", "posts", "tags", "post_tags",
                           "server_trends", "tag_buckets", "posts_fts"])
        #expect(triggers == ["posts_fts_insert", "posts_fts_delete", "posts_fts_update"])
        #expect(protocols.map(\.0) == ["atproto", "mastodon", "nostr"])
        #expect(protocols.allSatisfy { $0.1 > 0 })
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
        #expect(again.2 == 1)
    }
}
