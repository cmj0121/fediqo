import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// What a load hands over, the store keeps — and nothing a server refused to give.
@Suite("A load leaves its posts in the store")
struct TimelinePersistenceTests {
    private func tableLoader(_ lists: [String: [Post]], store: LocalStore) -> TimelineLoader {
        TimelineLoader(registry: SourceRegistry(clients: [.mastodon: TableClient(lists: lists)]), store: store)
    }

    @Test("A successful load is read back from the store, and loading again does not double it")
    func persistedOnce() async throws {
        let host = "keeps.test"
        stubRoutes.on(host, "/api/v1/timelines/public", status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let loader = stubbedLoader(store: store)

        let first = await loader.load(servers: [makeServer(host)], mode: .timeline)
        #expect(first.failures.isEmpty)
        #expect(try await store.timeline() == first.posts)
        #expect(try await loader.stored(mode: .timeline) == first.posts)

        let second = await loader.load(servers: [makeServer(host)], mode: .timeline)
        #expect(second.posts == first.posts)
        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
        #expect(try await count(store, "SELECT count(*) FROM server_trends") == 0)
    }

    @Test("A trending load records the server's ranking")
    func trendingWritesTrends() async throws {
        let host = "ranks.test"
        stubRoutes.on(host, "/api/v1/trends/statuses", status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let loader = stubbedLoader(store: store)

        let result = await loader.load(servers: [makeServer(host)], mode: .trending)

        #expect(result.posts.count == 1)
        #expect(try await count(store, "SELECT count(*) FROM server_trends WHERE source_url = 'https://\(host)'") == 1)
        #expect(try await loader.stored(mode: .trending) == result.posts)
    }

    @Test("A server that refuses leaves nothing behind and is still reported as a refusal")
    func refusalPersistsNothing() async throws {
        let host = "refuses-store.test"
        stubRoutes.on(host, "/api/v1/timelines/public", status: 403)
        let store = try LocalStore.inMemory()

        let result = await stubbedLoader(store: store).load(servers: [makeServer(host)], mode: .timeline)

        #expect(result.posts.isEmpty)
        #expect(result.failures[host] == SourceFailure.needsSignIn(host))
        #expect(try await count(store, "SELECT count(*) FROM posts") == 0)
        #expect(try await count(store, "SELECT count(*) FROM servers WHERE host = '\(host)'") == 0)
    }

    @Test("What the store holds is there before any server is asked")
    func storedBeforeNetwork() async throws {
        let host = "quiet.test"
        let store = try LocalStore.inMemory()
        let posts = [makePost(uri: "https://a.example/2", at: 200, from: host), makePost(uri: "https://a.example/1", at: 100, from: host)]
        try await store.save(posts, from: makeServer(host))

        #expect(try await stubbedLoader(store: store).stored(mode: .timeline) == posts)
        #expect(stubRoutes.paths(for: host).isEmpty)
    }

    @Test("A store that will not keep a host's posts says so for that host; the posts and the other host are untouched")
    func storeFailureIsReported() async throws {
        let store = try LocalStore.inMemory()
        let loader = tableLoader([
            "nameless.test": [makePost(uri: "https://x.example/1", at: 50, from: "nameless.test", authorId: "")],
            "fine.test": [makePost(uri: "https://a.example/1", at: 100, from: "fine.test")],
        ], store: store)

        let result = await loader.load(servers: [makeServer("nameless.test"), makeServer("fine.test")], mode: .timeline)

        #expect(result.posts.map(\.uri).sorted() == ["https://a.example/1", "https://x.example/1"])
        #expect(result.failures["fine.test"] == nil)
        guard case .store(let reason)? = result.failures["nameless.test"] else {
            Issue.record("expected a .store failure, got \(String(describing: result.failures["nameless.test"]))")
            return
        }
        #expect(!reason.contains("INSERT"))
        #expect(try await store.timeline().map(\.uri) == ["https://a.example/1"])
    }

    @Test("Trending from two servers interleaves by rank, not by time, and the store reads it back the same way")
    func trendingKeepsServerOrder() async throws {
        let store = try LocalStore.inMemory()
        let loader = tableLoader([
            "alpha.test": [makePost(uri: "https://a.example/a0", at: 100, from: "alpha.test"),
                           makePost(uri: "https://a.example/a1", at: 400, from: "alpha.test")],
            "beta.test": [makePost(uri: "https://b.example/b0", at: 200, from: "beta.test"),
                          makePost(uri: "https://b.example/b1", at: 300, from: "beta.test")],
        ], store: store)

        let result = await loader.load(servers: [makeServer("alpha.test"), makeServer("beta.test")], mode: .trending)

        // Rank 0 first (the newer of the two breaks the tie), then rank 1 — never 400, 300, 200, 100.
        let byRank = ["https://b.example/b0", "https://a.example/a0", "https://a.example/a1", "https://b.example/b1"]
        #expect(result.posts.map(\.uri) == byRank)
        #expect(try await loader.stored(mode: .trending).map(\.uri) == byRank)
    }

    @Test("Without a store there is nothing stored")
    func noStore() async throws {
        let loader = stubbedLoader()
        #expect(try await loader.stored(mode: .timeline).isEmpty)
        #expect(try await loader.stored(mode: .trending).isEmpty)
    }
}

/// A client that hands each host its own list, for both the timeline and trending.
private struct TableClient: SourceClient {
    let lists: [String: [Post]]

    func instance(host: String) async throws -> InstanceInfo { throw SourceFailure.badHost(host) }
    func timeline(host: String, limit: Int) async throws -> [Post] { lists[host] ?? [] }
    func trending(host: String, limit: Int) async throws -> [Post] { lists[host] ?? [] }
}
