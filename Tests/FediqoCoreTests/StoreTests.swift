import Foundation
import Testing
@testable import FediqoCore

@Suite("The in-memory store")
struct StoreTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let other = Source(host: "second.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Dropping by time keeps the latest notes")
    func dropPostedBeforeKeepsNewer() async {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([
            note(id: "old", postedAt: origin, origins: [.publicTimeline]),
            note(id: "new", postedAt: origin.addingTimeInterval(86_400), origins: [.publicTimeline]),
        ])
        await store.dropPosted(before: origin.addingTimeInterval(60))
        #expect(await store.all().map(\.id) == ["new"])
    }

    @Test("Dropping by time keeps every source joined, even one left with nothing")
    func dropPostedKeepsSources() async {
        let store = ItemStore()
        await store.add(source)
        await store.add(other)
        await store.ingest([
            note(id: "old", postedAt: origin, origins: [.publicTimeline], from: other),
            note(id: "new", postedAt: origin.addingTimeInterval(86_400), origins: [.publicTimeline]),
        ])
        await store.dropPosted(before: origin.addingTimeInterval(60))
        #expect(await store.sources().map(\.host) == ["first.example", "second.example"])
        #expect(await store.all().map(\.id) == ["new"])
    }

    @Test("A relaunch builds the store from a snapshot")
    func initLoadsASnapshot() async {
        let forum = Source(host: "forum.example", kind: .discuz)
        let kept = note(id: "kept", postedAt: origin, origins: [.trending], from: forum)
        let store = ItemStore(sources: [forum, source], notes: [kept])
        #expect(await store.sources().map(\.host) == ["forum.example", "first.example"])
        #expect(await store.all().map(\.id) == ["kept"])
        #expect(await store.trends().map(\.id) == ["kept"])
    }

    @Test("snapshot() hands back what init took, for a save to write")
    func snapshotRoundTrips() async {
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        let one = note(id: "1", postedAt: origin, origins: [.trending], from: forum)
        let two = note(id: "2", postedAt: origin.addingTimeInterval(60), origins: [.publicTimeline])
        let store = ItemStore(sources: [source, forum], notes: [one, two])
        await store.ingest([note(id: "3", postedAt: origin, origins: [])])
        await store.remove(host: "forum.example")
        let snapshot = await store.snapshot()
        #expect(snapshot.sources == [source])
        #expect(Set(snapshot.notes.map(\.key)) == Set(["2", "3"].map { NoteKey(host: "first.example", id: $0) }))
        let reloaded = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(await reloaded.all() == store.all())
    }

    @Test("A snapshot with duplicates loads instead of trapping")
    func initToleratesDuplicates() async {
        let first = note(id: "1", postedAt: origin, origins: [.publicTimeline], body: "first")
        let second = note(id: "1", postedAt: origin, origins: [.trending], body: "second")
        let store = ItemStore(
            sources: [source, Source(host: "First.Example", kind: .pleroma)],
            notes: [first, second]
        )
        #expect(await store.sources() == [source])
        let all = await store.all()
        #expect(all.map(\.body) == ["second"])
        #expect(all.first?.origins == [.trending])
    }

    @Test("Adding a host twice keeps the first and insertion order")
    func addIsIdempotentByHost() async {
        let store = ItemStore()
        await store.add(source)
        await store.add(Source(host: "First.Example", kind: .pleroma))
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
            boards: [BoardSubscription(fid: 33, name: "启动盘工具"), BoardSubscription(fid: 41, name: "自由系统")]
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
            host: "Install-C.EXAMPLE",
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

    /// Two sources carrying one status are two rows with the same time and the same id, so the
    /// host is what is left to order them by. Without it their order would be whatever the
    /// dictionary iterates to, and a timeline would swap the pair between one build and the next.
    @Test("One item through two hosts sorts by host, whichever arrived first")
    func sameTimeAndIdSortsByHost() async {
        let uri = "https://origin.example/users/ada/statuses/1"
        for firstIn in [source, other] {
            let store = ItemStore()
            let secondIn = firstIn == source ? other : source
            await store.ingest([note(id: uri, postedAt: origin, origins: [.publicTimeline], from: firstIn)])
            await store.ingest([note(id: uri, postedAt: origin, origins: [.publicTimeline], from: secondIn)])
            #expect(await store.all().map(\.source.host) == ["first.example", "second.example"])
        }
    }

    /// The rule the store keys its rows by and a drawn row takes its id from, stated once. Folded
    /// by `Source` and by nothing after it, so a host typed in capitals keys the same row.
    @Test("A note's key is the host it came through and its id, and two hosts are two keys")
    func aNoteIsKeyedByHostAndID() {
        let uri = "https://origin.example/users/ada/statuses/1"
        let first = note(id: uri, postedAt: origin, origins: [.publicTimeline])
        let second = note(id: uri, postedAt: origin, origins: [.publicTimeline], from: other)
        let shouted = note(
            id: uri, postedAt: origin, origins: [.publicTimeline],
            from: Source(host: "FIRST.Example", kind: .mastodon)
        )
        #expect(first.key == NoteKey(host: "first.example", id: uri))
        #expect(first.key != second.key)
        #expect(first.key.rowID != second.key.rowID)
        #expect(shouted.key == first.key)
        #expect(first.key.rowID == "first.example\u{1e}\(uri)")
    }

    @Test("Overlapping uri ingest on one host is one row with both origins, and it is a trend")
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

    // MARK: - Letting go of a server

    /// Remove takes the three things Clear deliberately keeps apart: the source, the boards the
    /// reader picked on it, and the notes it served. `ShellSession.clear`'s comment argues for
    /// keeping the boards under *that* button; this is the act it named as the one that takes
    /// them, so a Remove that left a subscription behind would leave the rail drawing a tab for a
    /// server nobody reads.
    @Test("Remove takes the source, the boards picked on it, and the notes it carried")
    func removeTakesTheSourceItsBoardsAndItsNotes() async {
        let store = ItemStore()
        let forum = Source(host: "third.example", kind: .discuz)
        await store.add(source)
        await store.add(forum)
        await store.subscribe(host: forum.host, to: [BoardSubscription(fid: 33, name: "a")])
        await store.ingest([
            note(id: "mine", postedAt: origin, origins: [.publicTimeline]),
            note(id: "theirs", postedAt: origin, origins: [.publicTimeline], from: forum),
        ])
        #expect(await store.sources().last?.boards.count == 1)

        await store.remove(host: forum.host)

        #expect(await store.sources().map(\.host) == ["first.example"])
        #expect(await store.all().map(\.id) == ["mine"])
    }

    /// The host is folded on the way in, as it is everywhere else this app keys by server.
    @Test("Remove finds the server whatever case it is asked for in")
    func removeFoldsTheHost() async {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([note(id: "mine", postedAt: origin, origins: [.publicTimeline])])

        await store.remove(host: "First.EXAMPLE")

        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    /// Silent for a host nobody joined, for the reason `subscribe(host:to:)` is: nothing here
    /// takes a source out of the list by a side door, and a sweep that ran anyway would be a
    /// sweep nobody asked for.
    @Test("Removing a server that was never joined changes nothing")
    func removingAStrangerChangesNothing() async {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([note(id: "mine", postedAt: origin, origins: [.publicTimeline])])

        await store.remove(host: "elsewhere.example")

        #expect(await store.sources().map(\.host) == ["first.example"])
        #expect(await store.all().map(\.id) == ["mine"])
    }

    /// #10: two sources, two rows. The same URI through two hosts is two notes. Removing one
    /// host takes only that host's row.
    @Test("The same content from two sources is two rows, and Remove takes only that source's row")
    func twoSourcesGiveTwoRows() async {
        let store = ItemStore()
        let uri = "https://origin.example/users/ada/statuses/1"
        await store.add(source)
        await store.add(other)
        await store.ingest([note(id: uri, postedAt: origin, origins: [.publicTimeline])])
        await store.ingest([
            note(id: uri, postedAt: origin, origins: [.trending], from: other),
            note(id: "only-second", postedAt: origin, origins: [.publicTimeline], from: other),
        ])
        let both = await store.all()
        #expect(both.filter { $0.id == uri }.count == 2)
        #expect(Set(both.filter { $0.id == uri }.map(\.source.host)) == ["first.example", "second.example"])

        await store.remove(host: source.host)

        let left = await store.all()
        #expect(Set(left.map(\.id)) == [uri, "only-second"])
        let shared = left.first { $0.id == uri }
        #expect(shared?.source.host == "second.example")
        #expect(shared?.origins == [.trending])

        await store.remove(host: other.host)

        #expect(await store.all().isEmpty)
        #expect(await store.sources().isEmpty)
    }

    @Test("Removing a server drops only that server's rows")
    func removingDropsOnlyThatServersRows() async {
        let store = ItemStore()
        let third = Source(host: "third.example", kind: .pleroma)
        let uri = "https://origin.example/users/ada/statuses/1"
        let onlyFirst = "https://origin.example/users/ada/statuses/2"
        await store.add(source)
        await store.add(other)
        await store.add(third)
        await store.ingest([
            note(id: uri, postedAt: origin, origins: [.publicTimeline]),
            note(id: onlyFirst, postedAt: origin, origins: [.publicTimeline]),
        ])
        await store.ingest([note(id: uri, postedAt: origin, origins: [.publicTimeline], from: third)])
        await store.ingest([
            note(id: "shared-by-two-survivors", postedAt: origin, origins: [.publicTimeline], from: other)
        ])
        await store.ingest([
            note(id: "shared-by-two-survivors", postedAt: origin, origins: [.publicTimeline], from: third)
        ])

        await store.remove(host: source.host)

        let left = await store.all()
        #expect(left.allSatisfy { $0.source.host != "first.example" })
        #expect(left.filter { $0.id == uri }.map(\.source.host) == ["third.example"])
        #expect(left.map(\.id).contains(onlyFirst) == false)
        #expect(
            Set(left.filter { $0.id == "shared-by-two-survivors" }.map(\.source.host))
                == ["second.example", "third.example"]
        )
    }

    private func note(
        id: String,
        postedAt: Date,
        origins: Set<FetchOrigin>,
        author: String = "Ada",
        body: String = "hello",
        reply: Reply? = nil,
        boostedBy: String? = nil,
        audience: Audience? = .everyone,
        from: Source? = nil
    ) -> Note {
        Note(
            id: id,
            source: from ?? source,
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
