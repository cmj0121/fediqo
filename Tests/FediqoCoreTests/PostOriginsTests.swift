import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// Where a post came from, kept beside it. One post is one row however many base sources
/// carried it; what grows is the list of sightings, and being told again moves nothing but
/// the instant it was last seen.
@Suite("What a post remembers besides itself")
struct PostOriginsTests {
    private func stocked() async throws -> (LocalStore, Server) {
        (try LocalStore.inMemory(), makeServer("one.example"))
    }

    private func origins(_ store: LocalStore) async throws -> [(feed: String, account: String?, key: String)] {
        try await store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT feed, author_id, merge_key FROM post_origins ORDER BY feed, merge_key
                """).map { ($0["feed"] as String, $0["author_id"] as String?, $0["merge_key"] as String) }
        }
    }

    @Test("A post carried by two base sources is one post and two origins")
    func twoSourcesOnePost() async throws {
        let (store, server) = try await stocked()
        let post = makePost(uri: "https://one.example/1", at: 100)
        try await store.save([post], from: server, into: .public)
        try await store.save([post], from: server, into: .trend)

        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
        let kept = try await origins(store)
        #expect(kept.map(\.feed) == ["public", "trend"])
        #expect(kept.allSatisfy { $0.account == nil })
    }

    @Test("A home read is filed under whoever it was read as; a public read under nobody")
    func homeIsKeptPerAccount() async throws {
        let (store, server) = try await stocked()
        let secrets = InMemorySecretStore()
        try await signInRows("t0ken", to: server, store: store, secrets: secrets)
        let reader = "\(server.endpoint)/@ada"
        let post = makePost(uri: "https://one.example/1", at: 100)

        try await store.save([post], from: server, into: .home, as: reader)
        try await store.save([post], from: server, into: .public, as: reader)

        let kept = try await origins(store)
        #expect(kept.count == 2)
        #expect(kept.first { $0.feed == "home" }?.account == reader)
        // A public timeline belongs to nobody, whoever happened to be signed in when it was
        // read — so the reader is dropped rather than written down beside it.
        #expect(kept.first { $0.feed == "public" }?.account == nil)
    }

    @Test("Being told again moves the last sighting and adds no row")
    func repeatedSightingIsOneRow() async throws {
        let (store, server) = try await stocked()
        let post = makePost(uri: "https://one.example/1", at: 100)
        let t0 = Date(timeIntervalSince1970: 1_000)
        try await store.save([post], from: server, into: .public, now: t0)
        try await store.save([post], from: server, into: .public, now: t0.addingTimeInterval(60))

        let seen = try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT first_seen_at, last_seen_at FROM post_origins")
                .map { ($0["first_seen_at"] as Int64, $0["last_seen_at"] as Int64) }
        }
        #expect(seen.count == 1)
        #expect(seen[0].0 == 1_000_000)
        #expect(seen[0].1 == 1_060_000)
    }

    @Test("Who a post names is kept beside it, and an account we have never seen is fine")
    func mentionsAreKept() async throws {
        let (store, server) = try await stocked()
        let named = Mention(uri: "https://elsewhere.example/users/ada", handle: "@ada@elsewhere.example")
        let post = Post(uri: "https://one.example/1", socialProtocol: .mastodon,
                        sourceURL: server.endpoint, createdAt: Date(timeIntervalSince1970: 100),
                        authorId: "https://one.example/users/someone", authorName: "someone",
                        authorHandle: "@someone@one.example", text: "hello @ada",
                        mentions: [named, named])
        try await store.save([post], from: server)

        // Named twice in one post is named once here, and no `accounts` row was invented for
        // somebody this device has never been handed.
        #expect(try await count(store, "SELECT count(*) FROM post_mentions") == 1)
        #expect(try await count(store, "SELECT count(*) FROM accounts WHERE author_id = '\(named.uri)'") == 0)

        let read = try await store.timeline()
        #expect(read.first?.mentions == [named])
    }
}
