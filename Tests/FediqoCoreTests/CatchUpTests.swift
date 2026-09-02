import Foundation
import Testing
@testable import FediqoCore

/// Walking a server the reader has just added back to where the reader already is (#92).
///
/// A load asks every server for its newest page. For one that has just been added, that page is
/// the top of a timeline the reader scrolled past an hour ago — everything it carried in between
/// sits below the fold, and the only way to it was to scroll to the bottom and back.
///
/// **`min_id` cannot help here and that is the point of these tests.** A stretch is asked for with
/// a server's own numbers, and a server just added has never handed this device anything to number
/// either end with. What there is, is a time.
@Suite("Catching a new server up to where the reader is")
struct CatchUpTests {
    private let host = "catchup.example"

    private func page(_ ids: ClosedRange<Int>, at seconds: (Int) -> TimeInterval) -> [Post] {
        ids.map { id in
            makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
                     originURI: "https://\(host)/users/a/statuses/\(id)",
                     at: seconds(id))
        }
    }

    private var server: Server { Server(host: host, socialProtocol: .mastodon) }

    private func loader(_ client: CountingPages) -> TimelineLoader {
        TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]), limit: 40,
                       store: nil, secrets: InMemorySecretStore())
    }

    /// The whole behaviour: keep asking for the page before the last one until what comes back
    /// has reached past the oldest post the reader is holding.
    @Test("It walks back until it has passed where the reader is")
    func walksBackToTheReader() async throws {
        // Three pages, each older than the last. The reader is holding down to t=300.
        let pages = [page(1...2, at: { 500 + TimeInterval($0) }),
                     page(3...4, at: { 380 + TimeInterval($0) }),
                     page(5...6, at: { 250 + TimeInterval($0) })]
        let client = CountingPages(pages: pages)
        let reading = loader(client)

        _ = await reading.catchUp(server, downTo: Date(timeIntervalSince1970: 300),
                                 query: TimelineQuery(source: .public))

        // Three pages: the first two are still newer than the reader's foot, the third reaches
        // past it and stops the walk.
        #expect(await client.asks == 3)
    }

    /// A server with less to say than the reader has read stops the walk itself. Asking a server
    /// that has run out for another page is asking it for nothing, twice.
    @Test("A server that runs out stops being asked")
    func runningOutStops() async throws {
        let client = CountingPages(pages: [page(1...2, at: { 500 + TimeInterval($0) })])
        let reading = loader(client)

        _ = await reading.catchUp(server, downTo: Date(timeIntervalSince1970: 0),
                                 query: TimelineQuery(source: .public))

        // One page with something in it, one that came back empty, and then it stops.
        #expect(await client.asks == 2)
    }

    /// A reader who has scrolled for an hour has a stretch nobody should backfill in one go. The
    /// walk is bounded, and stopping short is not a failure — reaching the bottom fills the rest
    /// the ordinary way.
    @Test("It is bounded, however far the reader has read")
    func boundedWalk() async throws {
        // Every page is newer than the foot, so nothing here would ever stop it but the bound.
        let far = (0..<20).map { round in page(1...2, at: { _ in 900 - TimeInterval(round) }) }
        let client = CountingPages(pages: far)
        let reading = loader(client)

        _ = await reading.catchUp(server, downTo: Date(timeIntervalSince1970: 0),
                                 query: TimelineQuery(source: .public), rounds: 3)

        #expect(await client.asks == 3)
    }

    /// The cursor is the last post of the page before, which is what makes it a walk rather than
    /// the same page asked for over and over.
    @Test("Each page is asked for by the foot of the one before it")
    func eachPageFollowsTheLast() async throws {
        let pages = [page(1...2, at: { 500 + TimeInterval($0) }),
                     page(3...4, at: { 100 + TimeInterval($0) })]
        let client = CountingPages(pages: pages)
        let reading = loader(client)

        _ = await reading.catchUp(server, downTo: Date(timeIntervalSince1970: 200),
                                 query: TimelineQuery(source: .public))

        // Nothing for the first page, and the foot of it for the second.
        #expect(await client.cursors == [nil, "2"])
    }
}

/// The other half: a server already read, asked again about the stretch it has already answered.
///
/// This is what `min_id` is for, and what it can be used for — unlike a server just added, one
/// that has been read has handed over numbers this app may name either end with.
@Suite("Asking a server again about a stretch it has answered")
struct RefillTests {
    private let host = "refill.example"

    private func post(_ id: Int, at seconds: TimeInterval) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
                 originURI: "https://\(host)/users/a/statuses/\(id)", at: seconds)
    }

    @Test("Both ends are sent, and they are that server's own numbers")
    func bothEndsAreSent() async throws {
        let client = CountingPages(pages: [[]])
        let reading = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                     limit: 40, store: nil, secrets: InMemorySecretStore())

        _ = await reading.refill(Server(host: host, socialProtocol: .mastodon),
                                 between: post(9, at: 900), and: post(1, at: 100),
                                 query: TimelineQuery(source: .public))

        #expect(await client.cursors == ["9"])
        #expect(await client.farEnds == ["1"])
    }

    /// One round and no walking: what is between two posts the reader is holding is bounded, and
    /// a server with more of it than a page hands back the part nearest what they are looking at.
    @Test("It asks once rather than walking")
    func oneRound() async throws {
        let client = CountingPages(pages: [[post(5, at: 500)], [post(4, at: 400)]])
        let reading = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                     limit: 40, store: nil, secrets: InMemorySecretStore())

        _ = await reading.refill(Server(host: host, socialProtocol: .mastodon),
                                 between: post(9, at: 900), and: post(1, at: 100),
                                 query: TimelineQuery(source: .public))

        #expect(await client.asks == 1)
    }
}

/// A server with a fixed set of pages, which remembers what it was asked for.
actor CountingPages: StubClient {
    private(set) var asks = 0
    /// The `max_id` of each request in order, as the server's own number, or nothing where the
    /// newest page was asked for.
    private(set) var cursors: [String?] = []
    private let pages: [[Post]]

    init(pages: [[Post]]) { self.pages = pages }

    /// The `min_id` of each request, where one was sent — the far end of a stretch.
    private(set) var farEnds: [String?] = []

    func timeline(host: String, limit: Int, before: Post?, after: Post?,
                  token: String?) async throws -> [Post] {
        cursors.append(before.flatMap { try? MastodonClient.statusId(of: $0, on: host) })
        farEnds.append(after.flatMap { try? MastodonClient.statusId(of: $0, on: host) })
        defer { asks += 1 }
        return asks < pages.count ? pages[asks] : []
    }
}
