import Foundation
import Testing
@testable import FediqoCore

/// One journey towards the bottom of a timeline.
///
/// The point of #66 is that this suite can exist at all: the budget, the order of the store and
/// the servers, and the stop condition used to live on an `@Observable` view model, where none
/// of it could be asked a question without a main actor. Nothing here has one.
@Suite("Reaching for what came before")
struct ReachTests {
    private let server = Server(host: "reach.example", socialProtocol: .mastodon)

    private func foot(_ id: String = "foot") -> Post {
        makePost(uri: "https://reach.example/api/v1/statuses/\(id)",
                 originURI: "https://reach.example/users/a/statuses/\(id)", at: 100)
    }

    /// A server that counts how many times it was asked, and hands back whatever it was told to.
    private actor Counting: StubClient {
        private(set) var asks = 0
        /// What the screen said about each arrival, in order. Kept here rather than in a
        /// captured variable: the callback is `@Sendable`, so it needs somewhere that is.
        private(set) var arrivals: [String] = []
        private let pages: [[Post]]

        init(pages: [[Post]] = []) { self.pages = pages }

        func saw(_ what: String) -> Int {
            arrivals.append(what)
            return 0
        }

        /// Nothing lands until the second round, and then something does.
        func landsOnTheSecondRound(_ what: String) -> Int {
            arrivals.append(what)
            return arrivals.filter { $0 == "servers" }.count >= 2 ? 1 : 0
        }

        func timeline(host: String, limit: Int, before: Post?, after: Post?, token: String?) async throws -> [Post] {
            defer { asks += 1 }
            return asks < pages.count ? pages[asks] : []
        }
    }

    private func loader(_ client: Counting, store: LocalStore? = nil) -> TimelineLoader {
        TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]), limit: 40,
                       store: store, secrets: InMemorySecretStore())
    }

    /// The cold-start cliff, and the only thing the budget is the answer to: an empty store and
    /// servers whose pages are all above the reader.
    @Test("An empty store spends the whole budget when nothing lands below the reader")
    func anEmptyStoreSpendsTheBudget() async throws {
        // Every page has something in it, so the reach is never stopped by silence — and
        // nothing lands, because the screen says so.
        let client = Counting(pages: Array(repeating: [foot("above")], count: 20))
        _ = await loader(client).reachOlder(than: foot(), matching: .publicPosts,
                                            servers: [server]) { _ in 0 }

        #expect(await client.asks == TimelineLoader.roundsPerReach)
    }

    /// A store that answered has already given the reader something, so the servers are asked
    /// once — for the evidence a reconcile needs, not for a page.
    @Test("A store that answered asks the servers once, not eight times")
    func aStoreThatAnsweredAsksOnce() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://reach.example/api/v1/statuses/older",
                                       originURI: "https://reach.example/users/a/statuses/older",
                                       at: 50)], from: server)
        let client = Counting(pages: Array(repeating: [foot("above")], count: 20))

        _ = await loader(client, store: store).reachOlder(than: foot(), matching: .publicPosts,
                                                          servers: [server]) { _ in 0 }

        #expect(await client.asks == 1)
    }

    /// A round that landed something is a round the reader can see, so the journey stops there
    /// rather than spending the rest of the budget at somebody's server for nothing.
    @Test("A round that lands something ends the reach")
    func landingEndsIt() async throws {
        let client = Counting(pages: Array(repeating: [foot("above")], count: 20))

        _ = await loader(client).reachOlder(than: foot(), matching: .publicPosts,
                                            servers: [server]) { arrival in
            if case .fromServers = arrival {
                return await client.landsOnTheSecondRound("servers")
            }
            return await client.landsOnTheSecondRound("store")
        }

        #expect(await client.asks == 2)
    }

    /// A round in which nobody said anything is a round that asked nobody — every server is
    /// spent, waiting or still out — so asking again this instant would ask the same nobody.
    @Test("A round nobody answered ends the reach")
    func silenceEndsIt() async throws {
        // No pages at all: every round comes back empty, with no failure either.
        let client = Counting()
        _ = await loader(client).reachOlder(than: foot(), matching: .publicPosts,
                                            servers: [server]) { _ in 0 }

        #expect(await client.asks == 1)
    }

    /// With nobody to ask, the store is still asked — a reader reaching down on a device with
    /// no servers on it is still reading what is here.
    @Test("With no servers, the store is still asked and nobody else is")
    func noServersIsNotNoReach() async throws {
        let client = Counting()

        _ = await loader(client).reachOlder(than: foot(), matching: .publicPosts,
                                            servers: []) { arrival in
            if case .fromTheStore = arrival { return await client.saw("store") }
            return await client.saw("servers")
        }

        #expect(await client.arrivals == ["store"])
        #expect(await client.asks == 0)
    }
}
