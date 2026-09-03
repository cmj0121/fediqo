import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// What counts as a word, in the two languages this app is read in.
///
/// There is no search yet — that is #60 — so these ask `posts_fts` directly. What is being held
/// is the tokenizer's promise: a reader looking for a word from inside a post finds the post,
/// whichever language they wrote it in.
@Suite("What counts as a word")
struct WordsTests {
    private func post(_ id: String, saying text: String) -> Post {
        makePost(uri: "https://one.example/api/v1/statuses/\(id)",
                 originURI: "https://one.example/users/a/statuses/\(id)",
                 at: TimeInterval(Int(id) ?? 1), text: text)
    }

    /// Two posts, one in each language, so every question below is asked of a store that has
    /// something to find and something to leave alone.
    private func stored() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save([
            post("1", saying: "一個伺服器公開給所有人的貼文，新的在最上面。"),
            post("2", saying: "Custom emoji are a server's own, and a client that cannot draw them."),
        ], from: Server(host: "one.example", socialProtocol: .mastodon))
        return store
    }

    private func matches(_ store: LocalStore, _ query: String) async throws -> Int {
        try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM posts_fts WHERE posts_fts MATCH ?",
                             arguments: ["\"\(query)\""]) ?? 0
        }
    }

    /// The whole reason 010 exists. Every one of these is 0 under `unicode61`, which is what
    /// "undecided" meant, and every one of them is a word a reader would actually type.
    @Test("A word of Chinese finds the post it is in, at one character or three",
          arguments: ["伺服器", "公開", "貼文", "新"])
    func chineseIsFound(word: String) async throws {
        #expect(try await matches(stored(), word) == 1)
    }

    /// And the language the stock tokenizer already answered for is not lost on the way.
    @Test("A word of English still finds the post it is in", arguments: ["emoji", "server", "client"])
    func englishIsFound(word: String) async throws {
        #expect(try await matches(stored(), word) == 1)
    }

    /// A search is not a scan. Two posts and a word in neither of them is nothing found, not
    /// everything found — which is the failure a substring index makes easy.
    @Test("A word in no post finds no post")
    func nothingIsFoundForNothing() async throws {
        #expect(try await matches(stored(), "нет") == 0)
        #expect(try await matches(stored(), "資料庫") == 0)
    }

    /// Two characters that are next to each other in a post, and two that are not. This is what
    /// makes the per-character cut a phrase match rather than a bag of characters: `貼文` is in
    /// the post and `文貼` is the same two characters the other way round.
    @Test("Characters are matched in the order they were written")
    func orderMatters() async throws {
        let store = try await stored()
        #expect(try await matches(store, "貼文") == 1)
        #expect(try await matches(store, "文貼") == 0)
    }

    /// The migration's other half. A store that has been collecting since 001 has its posts in
    /// `posts`, and 010 has to make them findable without emptying anything — so this writes a
    /// post into yesterday's database and looks for it in today's.
    @Test("A post written before 010 is searchable after it")
    func nothingHasToBeCollectedAgain() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let old = try LocalStore(path: path, upTo: "009")
        // Written the way a build of that age wrote it — the columns 009 had and no others.
        // `save` is today's, and today's names columns later migrations added, so a store this
        // old cannot take it. That is not a fault in either: it is what "yesterday's database"
        // means, and writing the row by hand is what makes this test about 010 rather than
        // about whichever migration came last.
        let server = Server(host: "one.example", socialProtocol: .mastodon)
        try await old.write { db in
            let now = LocalStore.milliseconds(Date())
            try LocalStore.upsertServer(db, LocalStore.serverRow(server), now: now)
            try LocalStore.upsertAccount(db, LocalStore.AccountRow(
                id: "https://one.example/@a", proto: "mastodon", serverURL: "https://one.example",
                handle: "@a@one.example", displayName: "A", avatarURL: nil), now: now)
            try db.execute(sql: """
                INSERT INTO posts (merge_key, proto, uri, source_url, posted_at, author_id,
                                   text, last_seen_at, created_at)
                VALUES (?, 'mastodon', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["1", "1", "https://one.example", now,
                                 "https://one.example/@a",
                                 "一個伺服器公開給所有人的貼文", now, now])
        }
        let before = try await old.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(before.last == "009")

        let upgraded = try LocalStore(path: path)
        #expect(try await matches(upgraded, "公開") == 1)
        #expect(try await matches(upgraded, "伺服器") == 1)
    }
}
