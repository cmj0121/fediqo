import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Asking the store for the posts whose words match.
///
/// `WordsTests` holds the tokenizer's promise; this holds the reading built on it — that it is
/// a page of the timeline like any other, that it answers from the index rather than by
/// scanning, and that a query nobody wrote finds nothing rather than everything.
@Suite("Searching what is kept")
struct SearchTests {
    private let server = Server(host: "one.example", socialProtocol: .mastodon)

    private func post(_ id: Int, saying text: String) -> Post {
        makePost(uri: "https://one.example/api/v1/statuses/\(id)",
                 originURI: "https://one.example/users/a/statuses/\(id)",
                 at: TimeInterval(id), text: text)
    }

    private func stored(_ said: [String]) async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save(said.enumerated().map { post($0.offset + 1, saying: $0.element) },
                             from: server)
        return store
    }

    @Test("A word finds the posts it is in, in both languages")
    func aWordFindsItsPosts() async throws {
        let store = try await stored(["a server's own emoji", "another server, another emoji",
                                      "一個伺服器公開給所有人的貼文", "沒有關係的一句話"])

        #expect(try await store.search("server").count == 2)
        #expect(try await store.search("公開").count == 1)
        #expect(try await store.search("貼文").first?.text.contains("伺服器") == true)
    }

    /// The words, all of them, anywhere — not the phrase. Two English words in either order is
    /// the commonest thing anybody types into a search box.
    @Test("Two words mean both of them, in any order")
    func twoWordsMeanBoth() async throws {
        let store = try await stored(["a server's own emoji", "another server, no pictures"])

        #expect(try await store.search("server emoji").count == 1)
        #expect(try await store.search("emoji server").count == 1)
        #expect(try await store.search("server pictures").count == 1)
        #expect(try await store.search("emoji pictures").isEmpty)
    }

    /// The failure a substring index makes easy, and the one a bad escape makes easy. A word in
    /// no post finds no post; so does a query of nothing at all.
    @Test("A query that matches nothing finds nothing, and so does an empty one")
    func nothingFindsNothing() async throws {
        let store = try await stored(["a server's own emoji", "一個伺服器公開給所有人的貼文"])

        #expect(try await store.search("database").isEmpty)
        #expect(try await store.search("資料庫").isEmpty)
        #expect(try await store.search("").isEmpty)
        #expect(try await store.search("   ").isEmpty)
    }

    /// FTS5 has a syntax of its own and a reader typing into a search box is not writing in it.
    /// Each of these is an operator or a piece of punctuation, and each is read here as what it
    /// looks like to somebody typing: a character in a word.
    ///
    /// The two halves of the promise are both here. `*` and `-` and a stray quote are dropped
    /// by the tokenizer the way punctuation always is, so the word beside them still finds its
    /// post — none of them turns into a wildcard, a negation, or a broken query. And `OR` and
    /// `AND` are words rather than operators, so asking for `server OR nothing` asks for three
    /// words at once and finds the post that has all three, which is none of them.
    @Test("What somebody typed is words, never FTS5's own syntax",
          arguments: [("server*", 1), ("-server", 1), ("\"server", 1),
                      ("server OR nothing", 0), ("server AND", 0)])
    func syntaxIsNotSmuggledIn(query: String, found: Int) async throws {
        let store = try await stored(["a server's own emoji", "nothing to see"])
        #expect(try await store.search(query).count == found)
    }

    /// A page, cut where every other page here is cut. The same three posts, asked for two at a
    /// time, come back in the timeline's order and without repeating one.
    @Test("It is a page of the timeline, with the timeline's own cursor")
    func itPagesLikeEverythingElse() async throws {
        let store = try await stored(["one server", "two server", "three server"])

        let first = try await store.search("server", limit: 2)
        #expect(first.count == 2)
        // Newest first, which is the order of every page in this store.
        #expect(first.map(\.text) == ["three server", "two server"])

        let next = try await store.search("server", limit: 2, before: first.last)
        #expect(next.map(\.text) == ["one server"])
        #expect(try await store.search("server", limit: 2, before: next.last).isEmpty)
    }

    /// It answers from the index and not by reading every post. Asked of SQLite itself rather
    /// than inferred from how long it took — a plan is a fact and a duration is weather.
    @Test("The answer comes from the index, not from a scan")
    func theIndexIsWhatAnswers() async throws {
        let store = try await stored(["a server's own emoji"])
        let plan = try await store.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT p.id FROM posts p JOIN posts_fts ON posts_fts.rowid = p.id
                WHERE posts_fts MATCH ? AND p.deleted_at IS NULL
                ORDER BY p.posted_at DESC, p.merge_key LIMIT 20
                """, arguments: ["\"server\""])
                .map { $0["detail"] as String }.joined(separator: " | ")
        }
        // Asserted as what it must say rather than as what it must not. The plan reads
        // `SCAN posts_fts VIRTUAL TABLE INDEX 0:M1 | SEARCH p USING INTEGER PRIMARY KEY` —
        // "SCAN posts_fts" is FTS5 walking its own match list, which is the index doing the
        // work, and `p` is reached by rowid one row at a time rather than read through.
        //
        // Worth knowing, and the reason the benchmark beside this exists: the plan ends
        // `USE TEMP B-TREE FOR ORDER BY`. The order is not free — every post the words match
        // is sorted before the page is cut — so what this costs is a question about how many
        // match, not about how many are stored.
        #expect(plan.contains("posts_fts VIRTUAL TABLE INDEX"), "the index is not driving: \(plan)")
        #expect(plan.contains("SEARCH p USING INTEGER PRIMARY KEY"),
                "the posts are not reached by rowid: \(plan)")
    }
}
