import Foundation
import Testing
@testable import FediqoCore

@Suite("Join")
struct JoinTests {
    @Test("Overlapping uri is one All row with both origins, and it is a trend")
    func overlappingURI() async throws {
        let store = ItemStore()
        try await MastodonJoin(http: Self.joinHTTP(), store: store, catalogues: EmojiCatalogueStore())
            .join(host: "first.example")
        let all = await store.all()
        #expect(all.map(\.id) == [
            "https://first.example/users/bob/statuses/new",
            "https://first.example/users/ada/statuses/trend-only",
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/ada/statuses/old",
        ])
        let shared = all.first { $0.id.hasSuffix("/shared") }
        #expect(shared?.origins == [.publicTimeline, .trending])
        #expect(shared?.author == "Ada")
        #expect(shared?.body == "Shared with trends")
        let trends = await store.trends()
        #expect(trends.map(\.id) == [
            "https://first.example/users/ada/statuses/trend-only",
            "https://first.example/users/ada/statuses/shared",
        ])
        #expect(await store.sources().map(\.host) == ["first.example"])
    }

    /// **Decision 9 on the real path, which is where it stops being a hypothesis.**
    ///
    /// Two instances, both carrying the same statuses — the ordinary case on a federated network,
    /// and the one a path-keyed fixture reproduces exactly, because a canonical URI is the same
    /// string whichever server hands it over. Every row is therefore stored once and stamped with
    /// `first.example`, the instance that joined first.
    ///
    /// A Remove that went by that stamp would empty the timeline of a reader who removed one of
    /// two instances and is still reading the other. What makes the failure quiet rather than
    /// loud is that the source list would be right: one server left, and nothing under it.
    @Test("Removing one of two instances carrying the same statuses leaves the timeline standing")
    func removingOneOfTwoInstancesKeepsWhatTheOtherCarries() async throws {
        let store = ItemStore()
        let http = Self.joinHTTP()
        for host in ["first.example", "second.example"] {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: host)
        }
        let before = await store.all()
        #expect(before.count == 4)
        #expect(before.allSatisfy { $0.source.host == "first.example" }, "the premise: one stamp")
        #expect(before.allSatisfy { $0.hosts == ["first.example", "second.example"] })

        await store.remove(host: "first.example")

        #expect(await store.sources().map(\.host) == ["second.example"])
        let after = await store.all()
        #expect(after.map(\.id) == before.map(\.id), "rows second.example still serves were deleted")
        #expect(after.allSatisfy { $0.hosts == ["second.example"] })
        #expect(await store.trends().count == 2, "Trends went with the stamp too")

        await store.remove(host: "second.example")

        #expect(await store.all().isEmpty, "rows nobody is left reading were stranded")
        #expect(await store.sources().isEmpty)
    }

    @Test("All and Trends sort by postedAt descending, not API array order")
    func storeTimeNotAPIOrder() async throws {
        let store = ItemStore()
        try await MastodonJoin(http: Self.joinHTTP(), store: store, catalogues: EmojiCatalogueStore())
            .join(host: "first.example")
        let allTimes = await store.all().map(\.postedAt)
        let trendIDs = await store.trends().map(\.id)
        let trendTimes = await store.trends().map(\.postedAt)
        #expect(allTimes == allTimes.sorted(by: >))
        #expect(trendTimes == trendTimes.sorted(by: >))
        #expect(trendIDs != [
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/ada/statuses/trend-only",
        ])
    }

    @Test("Trending 404 still joins; Trends empty, All is public")
    func trending404() async throws {
        let store = ItemStore()
        try await MastodonJoin(
            http: Self.joinHTTP(trending: .text("no", status: 404)),
            store: store,
            catalogues: EmojiCatalogueStore()
        ).join(host: "first.example")
        #expect(await store.trends().isEmpty)
        #expect(await store.all().map(\.id) == [
            "https://first.example/users/bob/statuses/new",
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/ada/statuses/old",
        ])
        #expect(await store.all().allSatisfy { $0.origins == [.publicTimeline] })
    }

    @Test("Public 404 fails the join and leaves the store empty")
    func public404() async {
        let store = ItemStore()
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await MastodonJoin(
                http: Self.joinHTTP(publicTimeline: .text("no", status: 404)),
                store: store,
                catalogues: EmojiCatalogueStore()
            ).join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("HTML names Pleroma: join refuses Pleroma")
    func refusesPleromaByName() async {
        let store = ItemStore()
        // A front page that names Pleroma, with a working Mastodon API behind it — the probe
        // and the timeline are here so that a join which read past the front page would put
        // something in the store, rather than failing for want of a route.
        let front = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="generator" content="Pleroma">
          <title>Pleroma</title>
        </head>
        <body>
          <p>A Pleroma instance. Mastodon clients can talk to it.</p>
        </body>
        </html>
        """
        let http = FixtureHTTP([
            "/": .body(Data(front.utf8)),
            "/api/v2/instance": .body(Data(#"{"domain":"pleroma.example","title":"A server","version":"4.3.0"}"#.utf8)),
            "/api/v1/timelines/public": .body(Data("""
            [
              {
                "id": "100",
                "uri": "https://pleroma.example/users/ada/statuses/old",
                "created_at": "2024-01-01T00:00:00.000Z",
                "content": "<p>Oldest public</p>",
                "visibility": "public",
                "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
              }
            ]
            """.utf8)),
        ])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "pleroma.example")
        }
        #expect(JoinError.unsupportedKind(.pleroma) != .unsupportedKind(.unknown))
        #expect(ProtocolKind.pleroma.displayName == "Pleroma")
        #expect(await store.sources().isEmpty)
        #expect(await http.paths == ["/"])
    }

    @Test("Unknown HTML and a Pleroma v2 instance is refused as Pleroma")
    func refusesPleromaFromProbe() async {
        let store = ItemStore()
        // A front page that names no software at all — "Mastodon" in prose is not a marker —
        // so the answer has to come from the probe, which names Pleroma in its version string.
        let front = """
        <!DOCTYPE html>
        <html>
        <head>
          <title>A personal site</title>
        </head>
        <body>
          <p>Welcome. This mentions Mastodon in passing, which is not enough.</p>
        </body>
        </html>
        """
        let probe = """
        {
          "version": "2.7.2 (compatible; Pleroma 2.6.3)",
          "title": "Pleroma"
        }
        """
        let http = FixtureHTTP([
            "/": .body(Data(front.utf8)),
            "/api/v2/instance": .body(Data(probe.utf8)),
        ])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "pleroma.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Joining the same host again ingests and does not duplicate the source")
    func joinTwice() async throws {
        let store = ItemStore()
        let join = MastodonJoin(http: Self.joinHTTP(), store: store, catalogues: EmojiCatalogueStore())
        try await join.join(host: "https://first.example/about")
        try await join.join(host: "First.Example")
        #expect(await store.sources().count == 1)
        #expect(await store.all().count == 4)
    }

    @Test("A bad host and an unreachable one are named as join errors")
    func hostAndUnreachable() async {
        let store = ItemStore()
        let dead = FixtureHTTP(["/": .fail, "/api/v2/instance": .fail])
        await #expect(throws: JoinError.invalidHost) {
            try await MastodonJoin(http: dead, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "http://first.example")
        }
        await #expect(throws: JoinError.unreachable) {
            try await MastodonJoin(http: dead, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "gone.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A host that answers and refuses is not a host that could not be reached")
    func refusalIsNotSilence() async {
        // Detection succeeds either way: the difference is what the public timeline
        // does afterwards. A status says the host answered; a dead socket does not.
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await MastodonJoin(
                http: Self.joinHTTP(publicTimeline: .text("no", status: 401)),
                store: ItemStore(),
                catalogues: EmojiCatalogueStore()
            ).join(host: "first.example")
        }
        await #expect(throws: JoinError.unreachable) {
            try await MastodonJoin(
                http: Self.joinHTTP(publicTimeline: .fail),
                store: ItemStore(),
                catalogues: EmojiCatalogueStore()
            ).join(host: "first.example")
        }
        // 200, and a body that is not a timeline. The host answered; the reader must
        // not be sent to look at a network that is working.
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await MastodonJoin(
                http: Self.joinHTTP(publicTimeline: .text("<html>a proxy page</html>")),
                store: ItemStore(),
                catalogues: EmojiCatalogueStore()
            ).join(host: "first.example")
        }
    }

    // A whole Mastodon written out here rather than a page taken off one: a front page that
    // names itself, the probe behind it, and the two timelines a join reads. It is one server,
    // not a sample document, and the only thing more than one test can share is a server.
    //
    // Shared with `ForumJoinTests`, which needs the same server to prove that the dispatcher did
    // not break the path that already worked.
    static func joinHTTP(
        publicTimeline: FixtureHTTP.Outcome? = nil,
        trending: FixtureHTTP.Outcome? = nil
    ) -> FixtureHTTP {
        let front = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="application-name" content="Mastodon">
          <link rel="help" href="https://joinmastodon.org/">
          <title>Mastodon</title>
        </head>
        <body>
          <div id="mastodon"></div>
        </body>
        </html>
        """
        let instance = """
        {
          "domain": "first.example",
          "title": "The first server",
          "version": "4.3.0",
          "description": "A server this test wrote"
        }
        """
        // Three public posts, oldest first on the wire, so that a store which kept API order
        // rather than sorting by time would be caught. `200` is also in the trends payload.
        let publicBody = """
        [
          {
            "id": "100",
            "uri": "https://first.example/users/ada/statuses/old",
            "created_at": "2024-01-01T00:00:00.000Z",
            "content": "<p>Oldest public</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          },
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          },
          {
            "id": "300",
            "uri": "https://first.example/users/bob/statuses/new",
            "created_at": "2024-12-01T00:00:00.000Z",
            "content": "<p>Newest public</p>",
            "visibility": "unlisted",
            "account": { "username": "bob", "acct": "bob@second.example", "display_name": "Bob" }
          }
        ]
        """
        // `200` again, with a later payload and a different author, so that a join which let the
        // second sighting overwrite the first would be caught; and `400`, seen only here.
        let trendingBody = """
        [
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends, later payload</p>",
            "visibility": "public",
            "account": { "username": "other", "acct": "other", "display_name": "Other" }
          },
          {
            "id": "400",
            "uri": "https://first.example/users/ada/statuses/trend-only",
            "created_at": "2024-09-01T00:00:00.000Z",
            "content": "<p>Trend only</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          }
        ]
        """
        return FixtureHTTP([
            "/": .body(Data(front.utf8)),
            "/api/v2/instance": .body(Data(instance.utf8)),
            "/api/v1/timelines/public": publicTimeline ?? .body(Data(publicBody.utf8)),
            "/api/v1/trends/statuses": trending ?? .body(Data(trendingBody.utf8)),
        ])
    }
}
