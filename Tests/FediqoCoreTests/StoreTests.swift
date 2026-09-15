import Foundation
import Testing
@testable import FediqoCore

@Suite("The in-memory store")
struct StoreTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let other = Source(host: "second.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Adding a host twice keeps the first and insertion order")
    func addIsIdempotentByHost() async {
        let store = ItemStore()
        await store.add(source)
        await store.add(Source(host: "first.example", kind: .pleroma))
        await store.add(other)
        #expect(await store.sources().map(\.id) == ["first.example", "second.example"])
        #expect(await store.sources().first?.kind == .mastodon)
        #expect(source.id == source.host)
    }

    @Test("all() is postedAt descending, then id, not insert order")
    func allSortsByTimeNotInsert() async {
        let store = ItemStore()
        let older = note(id: "b", postedAt: origin, origins: [.publicTimeline])
        let newer = note(id: "a", postedAt: origin.addingTimeInterval(60), origins: [.publicTimeline])
        let sameTime = note(id: "c", postedAt: origin.addingTimeInterval(60), origins: [.publicTimeline])
        await store.ingest([older, newer, sameTime])
        #expect(await store.all().map(\.id) == ["a", "c", "b"])
    }

    @Test("Overlapping uri ingest is one row with both origins, and it is a trend")
    func overlappingURIMergesOrigins() async {
        let store = ItemStore()
        let publicNote = note(
            id: "https://first.example/users/ada/statuses/1",
            postedAt: origin,
            origins: [.publicTimeline],
            author: "Ada",
            body: "first",
            reply: Reply(handle: "@you@second.example"),
            boostedBy: nil,
            audience: .everyone
        )
        let trendingNote = note(
            id: "https://first.example/users/ada/statuses/1",
            postedAt: origin.addingTimeInterval(9_000),
            origins: [.trending],
            author: "Other",
            body: "second"
        )
        await store.ingest([publicNote])
        await store.ingest([trendingNote])
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all[0].origins == [.publicTimeline, .trending])
        #expect(all[0].author == "Ada")
        #expect(all[0].body == "first")
        #expect(all[0].reply?.handle == "@you@second.example")
        let trends = await store.trends()
        #expect(trends.map(\.id) == all.map(\.id))
        #expect(trends[0].origins.contains(.trending))
    }

    @Test("trends() is the store order of notes that arrived as trending")
    func trendsFollowsStoreOrder() async {
        let store = ItemStore()
        await store.ingest([
            note(id: "old-trend", postedAt: origin, origins: [.trending]),
            note(id: "public-only", postedAt: origin.addingTimeInterval(30), origins: [.publicTimeline]),
            note(id: "new-trend", postedAt: origin.addingTimeInterval(60), origins: [.trending, .publicTimeline]),
        ])
        #expect(await store.trends().map(\.id) == ["new-trend", "old-trend"])
        #expect(await store.all().map(\.id) == ["new-trend", "public-only", "old-trend"])
    }

    private func note(
        id: String,
        postedAt: Date,
        origins: Set<FetchOrigin>,
        author: String = "Ada",
        body: String = "hello",
        reply: Reply? = nil,
        boostedBy: String? = nil,
        audience: Audience? = .everyone
    ) -> Note {
        Note(
            id: id,
            source: source,
            author: author,
            handle: "@ada@first.example",
            body: body,
            postedAt: postedAt,
            origins: origins,
            reply: reply,
            boostedBy: boostedBy,
            audience: audience,
            avatarURL: URL(string: "https://first.example/avatar.png"),
            attachments: [
                Attachment(
                    kind: .image,
                    url: URL(string: "https://first.example/full.jpg"),
                    previewURL: URL(string: "https://first.example/preview.jpg")
                ),
            ],
            url: URL(string: id),
            counts: Counts(replies: 1, reblogs: 2, favourites: 3)
        )
    }
}
