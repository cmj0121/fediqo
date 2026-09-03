import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The hole between what a launch loads and what the last one left behind.
///
/// Reported from a real account: the home timeline read *35 minutes ago*, and the next row down
/// read *a week ago*. Nothing is wrong with either — the first is what the server handed over on
/// this launch and the second is what the store had from the last one. **What is missing is
/// everything in between, and nobody asked for it.**
///
/// `FeedPaging` already walks a server back to where the reader is, and did it only for a server
/// that had just been added: the ones already known "have been read down to here already". On the
/// first load of a session nothing is known, so nothing was walked — and the place the reader is
/// coming back to is wherever they closed the app, which may be a week ago.
@Suite("The gap a launch leaves")
@MainActor
struct TheGapOnLaunchTests {
    private let host = "gap.example"

    private func post(_ id: String, minutesAgo: Double, now: Date) -> Post {
        makePost("https://\(host)/statuses/\(id)",
                 at: now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970,
                 from: host)
    }

    private func feed(_ client: PagedClient, store: LocalStore) -> FeedModel {
        FeedModel(timeline: .publicFixture,
                  preferences: Preferences(defaults: scratch("gap-\(UUID().uuidString)")),
                  loader: TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                         limit: PagedClient.pageSize, store: store,
                                         secrets: InMemorySecretStore()))
    }

    /// **The reproduction.** The store holds a week-old post; the server's newest page reaches
    /// back only half an hour. Between them is a week nobody has asked about.
    @Test("A launch closes the hole between the newest page and what was already here")
    func itClosesTheHole() async throws {
        let now = Date()
        let store = try LocalStore.inMemory()
        let server = makeServer(host)
        try await store.save([post("old", minutesAgo: 7 * 24 * 60, now: now)], from: server)

        let onTheServer = [post("a", minutesAgo: 35, now: now),
                           post("b", minutesAgo: 60, now: now),
                           post("c", minutesAgo: 24 * 60, now: now),
                           post("d", minutesAgo: 3 * 24 * 60, now: now),
                           post("e", minutesAgo: 8 * 24 * 60, now: now)]
        let client = PagedClient(onTheServer)
        let reading = feed(client, store: store)

        await reading.loadIfNeeded(servers: [server])

        // More than the one page a launch used to ask for: it kept going until it had reached
        // past what was already here.
        #expect(await client.asks > 1)
        // And what it fetched on the way is on the screen, so there is no jump to walk over.
        #expect(reading.posts.visible.count > PagedClient.pageSize)
    }

    /// It does not walk where there is nothing to walk. A reader who was here half an hour ago
    /// has no hole, and a launch that asked anyway would spend somebody's server on nothing.
    @Test("A launch that lands on top of what it had asks once")
    func noHoleAsksOnce() async throws {
        let now = Date()
        let store = try LocalStore.inMemory()
        let server = makeServer(host)
        try await store.save([post("recent", minutesAgo: 40, now: now)], from: server)

        let client = PagedClient([post("a", minutesAgo: 35, now: now),
                                  post("b", minutesAgo: 60, now: now)])
        let reading = feed(client, store: store)

        await reading.loadIfNeeded(servers: [server])

        #expect(await client.asks == 1)
    }

    /// An empty store is a first launch ever. There is nothing behind the reader to reach, so
    /// there is nothing to walk towards.
    @Test("A first launch ever has nothing to close")
    func afirstLaunchEver() async throws {
        let now = Date()
        let client = PagedClient([post("a", minutesAgo: 35, now: now),
                                  post("b", minutesAgo: 60, now: now)])
        let reading = feed(client, store: try LocalStore.inMemory())

        await reading.loadIfNeeded(servers: [makeServer(host)])

        #expect(await client.asks == 1)
    }
}
