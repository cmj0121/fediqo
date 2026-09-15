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

    @Test("A source carries the boards the reader subscribed to, and every fid only once")
    func aSourceCarriesItsSubscriptions() {
        // D26: one source per host with a set of subscribed boards, never one source per board.
        // The identity is still the host, so nothing keyed by host — the picture cache's tags,
        // the emoji catalogue, `Clear`, the join list — learns a new kind of key.
        let forum = Source(
            host: "install-c.example",
            kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "启动盘工具"), BoardSubscription(fid: 41, name: "Linux系统")]
        )
        #expect(forum.id == "install-c.example")
        #expect(forum.boards.map(\.fid) == [33, 41])
        #expect(forum.subscribes(to: 41))
        #expect(!forum.subscribes(to: 42))

        // **At most one entry per fid, guaranteed by the data rather than by a rule each caller
        // remembers.** A forum that renamed a board between two reads would otherwise hand the
        // reader two subscriptions to one board, under two names, with no way to tell which.
        let renamed = Source(
            host: "install-c.example",
            kind: .discuz,
            boards: [
                BoardSubscription(fid: 33, name: "启动盘工具"),
                BoardSubscription(fid: 33, name: "what it is called now"),
            ]
        )
        #expect(renamed.boards.map(\.name) == ["启动盘工具"])

        // And every source that has no such idea still has none, with no call site changed.
        #expect(source.boards.isEmpty)
        #expect(Source(host: "install-f.example", kind: .discourse).boards.isEmpty)
    }

    @Test("Picking boards again changes the one source rather than adding another")
    func subscribingRestatesOneSource() async {
        let store = ItemStore()
        let forum = Source(
            host: "install-c.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a")])
        await store.add(source)
        await store.add(forum)
        await store.subscribe(
            host: "install-c.example",
            to: [BoardSubscription(fid: 33, name: "a"), BoardSubscription(fid: 41, name: "b")]
        )

        #expect(await store.sources().count == 2)
        // In place: the reader built this list in this order and nothing reorders it.
        #expect(await store.sources().map(\.id) == ["first.example", "install-c.example"])
        #expect(await store.sources().last?.boards.map(\.fid) == [33, 41])
        #expect(await store.sources().last?.kind == .discuz)

        // A host nobody joined does not arrive by this door.
        await store.subscribe(host: "elsewhere.example", to: [BoardSubscription(fid: 1, name: "c")])
        #expect(await store.sources().count == 2)
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
