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
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("pleroma")),
            "/api/v2/instance": .body(Fixtures.json("instance-v2")),
            "/api/v1/timelines/public": .body(Fixtures.json("public-timeline")),
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
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("unknown")),
            "/api/v2/instance": .body(Fixtures.json("instance-pleroma")),
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
        try await join.join(host: "first.example")
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

    private static func joinHTTP(
        publicTimeline: FixtureHTTP.Outcome = .body(Fixtures.json("public-timeline")),
        trending: FixtureHTTP.Outcome = .body(Fixtures.json("trending-statuses"))
    ) -> FixtureHTTP {
        FixtureHTTP([
            "/": .body(Fixtures.html("mastodon")),
            "/api/v2/instance": .body(Fixtures.json("instance-v2")),
            "/api/v1/timelines/public": publicTimeline,
            "/api/v1/trends/statuses": trending,
        ])
    }
}
