import Foundation
import Testing
@testable import FediqoCore

@Suite("The in-memory store")
struct StoreTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let other = Source(host: "second.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A retention window drops what is older, says how many went, and keeps every source")
    func retentionPrunes() async {
        let store = ItemStore()
        await store.add(source)
        await store.add(other)
        await store.ingest([
            note(id: "old", postedAt: origin, categories: [.public], from: other),
            note(id: "new", postedAt: origin.addingTimeInterval(200 * 86_400), categories: [.public]),
        ])
        let now = origin.addingTimeInterval(210 * 86_400)
        #expect(await store.setRetention(months: 3, from: now) == 1)
        #expect(await store.sources().map(\.host) == ["first.example", "second.example"])
        #expect(await store.all().map(\.id) == ["new"])
        #expect(await store.setRetention(months: 3, from: now) == 0, "nothing left to drop")
    }

    @Test("Inside a window, a note older than it is refused by ingest")
    func retentionRefusesOldNotes() async {
        let store = ItemStore()
        await store.add(source)
        let now = origin.addingTimeInterval(400 * 86_400)
        await store.setRetention(months: 1, from: now)
        await store.ingest([
            note(id: "old", postedAt: origin, categories: [.public]),
            note(id: "new", postedAt: now, categories: [.public]),
        ])
        #expect(await store.all().map(\.id) == ["new"])
    }

    @Test("No window is forever: nothing is dropped and nothing refused", arguments: [nil, 0, -3] as [Int?])
    func noRetentionIsForever(months: Int?) async {
        let store = ItemStore(sources: [source], notes: [note(id: "old", postedAt: origin, categories: [.public])])
        #expect(await store.setRetention(months: months, from: origin.addingTimeInterval(999 * 86_400)) == 0)
        await store.ingest([note(id: "older", postedAt: origin.addingTimeInterval(-86_400), categories: [.public])])
        #expect(await store.all().map(\.id) == ["old", "older"])
        #expect(await store.retention == nil)
    }

    @Test("A relaunch builds the store from a snapshot")
    func initLoadsASnapshot() async {
        let forum = Source(host: "forum.example", kind: .discuz)
        let kept = note(id: "kept", postedAt: origin, categories: [.trends], from: forum)
        let store = ItemStore(sources: [forum, source], notes: [kept])
        #expect(await store.sources().map(\.host) == ["forum.example", "first.example"])
        #expect(await store.all().map(\.id) == ["kept"])
        #expect(await store.trends().map(\.id) == ["kept"])
    }

    @Test("snapshot() hands back what init took, for a save to write")
    func snapshotRoundTrips() async {
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        let one = note(id: "1", postedAt: origin, categories: [.trends], from: forum)
        let two = note(id: "2", postedAt: origin.addingTimeInterval(60), categories: [.public])
        let store = ItemStore(sources: [source, forum], notes: [one, two])
        await store.ingest([note(id: "3", postedAt: origin, categories: [])])
        await store.remove(host: "forum.example")
        let snapshot = await store.snapshot()
        #expect(snapshot.sources == [source])
        #expect(Set(snapshot.notes.map(\.key)) == Set(["2", "3"].map { NoteKey(host: "first.example", id: $0) }))
        let reloaded = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(await reloaded.all() == store.all())
    }

    @Test("Every change moves the revision a save reads; a call that changes nothing does not")
    func revisionCountsChanges() async {
        let store = ItemStore(sources: [source], notes: [])
        var last = await store.snapshot().revision
        func moved() async -> Bool {
            let now = await store.snapshot().revision
            defer { last = now }
            return now != last
        }
        await store.add(source)
        #expect(await !moved(), "adding a host already here changed nothing")
        await store.ingest([])
        #expect(await !moved())
        await store.add(other)
        #expect(await moved())
        await store.subscribe(host: other.host, to: [BoardSubscription(fid: 1, name: "b")])
        #expect(await moved())
        await store.ingest([note(id: "old", postedAt: origin, categories: [.public])])
        #expect(await moved())
        await store.setRetention(months: 1, from: origin.addingTimeInterval(400 * 86_400))
        #expect(await moved())
        await store.setRetention(months: nil)
        #expect(await !moved(), "widening the window drops nothing")
        await store.remove(host: other.host)
        #expect(await moved())
    }

    @Test("A snapshot with duplicates loads instead of trapping")
    func initToleratesDuplicates() async {
        let first = note(id: "1", postedAt: origin, categories: [.public], body: "first")
        let second = note(id: "1", postedAt: origin, categories: [.trends], body: "second")
        let store = ItemStore(
            sources: [source, Source(host: "First.Example", kind: .pleroma)],
            notes: [first, second]
        )
        #expect(await store.sources() == [source])
        let all = await store.all()
        #expect(all.map(\.body) == ["second"])
        #expect(all.first?.categories == [.trends])
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
        let older = note(id: "b", postedAt: origin, categories: [.public])
        let newer = note(id: "a", postedAt: origin.addingTimeInterval(60), categories: [.public])
        let sameTime = note(id: "c", postedAt: origin.addingTimeInterval(60), categories: [.public])
        await store.ingest([older, newer, sameTime])
        #expect(await store.all().map(\.id) == ["a", "c", "b"])
    }

    /// Two sources carrying one status are two rows with the same time and the same id, and what
    /// orders them is the order they arrived in — the copy a merged row is drawn as (#114). It
    /// was the host's name until then, which was stable and said nothing; arrival is as stable,
    /// and is the fact the row needs. Either way round, so neither order is the host's by luck.
    @Test("One item through two hosts sorts by which arrived first, and keeps its place when met again")
    func sameTimeAndIdSortsByArrival() async {
        let uri = "https://origin.example/users/ada/statuses/1"
        for firstIn in [source, other] {
            let store = ItemStore()
            let secondIn = firstIn == source ? other : source
            await store.ingest([note(id: uri, postedAt: origin, categories: [.public], from: firstIn)])
            await store.ingest([note(id: uri, postedAt: origin, categories: [.public], from: secondIn)])
            #expect(await store.all().map(\.source.host) == [firstIn.host, secondIn.host])
            await store.ingest([note(id: uri, postedAt: origin, categories: [.trends], from: secondIn)])
            #expect(await store.all().map(\.source.host) == [firstIn.host, secondIn.host])
        }
    }

    /// The rule the store keys its rows by and a drawn row takes its id from, stated once. Folded
    /// by `Source` and by nothing after it, so a host typed in capitals keys the same row.
    @Test("A note's key is the host it came through and its id, and two hosts are two keys")
    func aNoteIsKeyedByHostAndID() {
        let uri = "https://origin.example/users/ada/statuses/1"
        let first = note(id: uri, postedAt: origin, categories: [.public])
        let second = note(id: uri, postedAt: origin, categories: [.public], from: other)
        let shouted = note(
            id: uri, postedAt: origin, categories: [.public],
            from: Source(host: "FIRST.Example", kind: .mastodon)
        )
        #expect(first.key == NoteKey(host: "first.example", id: uri))
        #expect(first.key != second.key)
        #expect(first.key.rowID != second.key.rowID)
        #expect(shouted.key == first.key)
        #expect(first.key.rowID == "first.example\u{1e}\(uri)")
    }

    @Test("Overlapping uri ingest on one host is one row with both categories, and it is a trend")
    func overlappingURIMergesCategories() async {
        let store = ItemStore()
        let publicNote = note(
            id: "https://first.example/users/ada/statuses/1",
            postedAt: origin,
            categories: [.public],
            author: "Ada",
            body: "first",
            reply: Reply(handle: "@you@second.example"),
            boostedBy: nil,
            audience: .everyone
        )
        let trendingNote = note(
            id: "https://first.example/users/ada/statuses/1",
            postedAt: origin.addingTimeInterval(9_000),
            categories: [.trends],
            author: "Other",
            body: "second"
        )
        await store.ingest([publicNote])
        await store.ingest([trendingNote])
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all[0].categories == [.public, .trends])
        #expect(all[0].author == "Ada")
        #expect(all[0].body == "first")
        #expect(all[0].reply?.handle == "@you@second.example")
        let trends = await store.trends()
        #expect(trends.map(\.id) == all.map(\.id))
        #expect(trends[0].categories.contains(.trends))
    }

    @Test("trends() is the store order of notes that arrived as trending")
    func trendsFollowsStoreOrder() async {
        let store = ItemStore()
        await store.ingest([
            note(id: "old-trend", postedAt: origin, categories: [.trends]),
            note(id: "public-only", postedAt: origin.addingTimeInterval(30), categories: [.public]),
            note(id: "new-trend", postedAt: origin.addingTimeInterval(60), categories: [.trends, .public]),
        ])
        #expect(await store.trends().map(\.id) == ["new-trend", "old-trend"])
        #expect(await store.all().map(\.id) == ["new-trend", "public-only", "old-trend"])
    }

    // MARK: - Categories (#25)

    @Test("A later fetch through fewer categories takes none away")
    func categoriesOnlyGrow() async {
        let store = ItemStore()
        await store.ingest([note(id: "1", postedAt: origin, categories: [.public, .trends])])
        await store.ingest([note(id: "1", postedAt: origin, categories: [.public])])
        await store.ingest([note(id: "1", postedAt: origin, categories: [])])
        #expect(await store.all().map(\.categories) == [[.public, .trends]])
    }

    @Test("Dropping a board keeps it on the posts that arrived through it")
    func unsubscribingKeepsTheBoard() async {
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 37, name: "News")])
        let store = ItemStore(sources: [forum], notes: [])
        await store.ingest([note(id: "t1", postedAt: origin, categories: [.board(id: "37")], from: forum)])
        await store.subscribe(host: forum.host, to: [])
        #expect(await store.all().map(\.categories) == [[.board(id: "37")]])
    }

    @Test("One id from two hosts keeps each host's own categories")
    func twoHostsKeepTheirOwnCategories() async {
        let store = ItemStore()
        let uri = "https://origin.example/users/ada/statuses/1"
        await store.ingest([
            note(id: uri, postedAt: origin, categories: [.public]),
            note(id: uri, postedAt: origin, categories: [.trends], from: other),
        ])
        let byHost = Dictionary(uniqueKeysWithValues: await store.all().map { ($0.source.host, $0.categories) })
        #expect(byHost == ["first.example": [.public], "second.example": [.trends]])
    }

    @Test("trends() holds only what arrived through trends, never a forum post")
    func trendsIsOnlyTrends() async {
        let forum = Source(host: "forum.example", kind: .discuz)
        let store = ItemStore()
        await store.ingest([
            note(id: "trend", postedAt: origin, categories: [.trends]),
            note(id: "public", postedAt: origin, categories: [.public]),
            note(id: "board", postedAt: origin, categories: [.board(id: "37")], from: forum),
            note(id: "front", postedAt: origin, categories: [], from: forum),
        ])
        #expect(await store.trends().map(\.id) == ["trend"])
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
            note(id: "mine", postedAt: origin, categories: [.public]),
            note(id: "theirs", postedAt: origin, categories: [.public], from: forum),
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
        await store.ingest([note(id: "mine", postedAt: origin, categories: [.public])])

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
        await store.ingest([note(id: "mine", postedAt: origin, categories: [.public])])

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
        await store.ingest([note(id: uri, postedAt: origin, categories: [.public])])
        await store.ingest([
            note(id: uri, postedAt: origin, categories: [.trends], from: other),
            note(id: "only-second", postedAt: origin, categories: [.public], from: other),
        ])
        let both = await store.all()
        #expect(both.filter { $0.id == uri }.count == 2)
        #expect(Set(both.filter { $0.id == uri }.map(\.source.host)) == ["first.example", "second.example"])

        await store.remove(host: source.host)

        let left = await store.all()
        #expect(Set(left.map(\.id)) == [uri, "only-second"])
        let shared = left.first { $0.id == uri }
        #expect(shared?.source.host == "second.example")
        #expect(shared?.categories == [.trends])

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
            note(id: uri, postedAt: origin, categories: [.public]),
            note(id: onlyFirst, postedAt: origin, categories: [.public]),
        ])
        await store.ingest([note(id: uri, postedAt: origin, categories: [.public], from: third)])
        await store.ingest([
            note(id: "shared-by-two-survivors", postedAt: origin, categories: [.public], from: other)
        ])
        await store.ingest([
            note(id: "shared-by-two-survivors", postedAt: origin, categories: [.public], from: third)
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

    @Test("A relaunch reads the copies back in the order the last run took them")
    func arrivalSurvivesASnapshot() async {
        let uri = "https://first.example/users/ada/statuses/1"
        let store = ItemStore()
        await store.ingest([note(id: uri, postedAt: origin, categories: [.public], from: other)])
        await store.ingest([note(id: uri, postedAt: origin, categories: [.public])])

        let snapshot = await store.snapshot()
        #expect(snapshot.notes.map(\.source.host) == ["second.example", "first.example"])
        let reloaded = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(await reloaded.all().map(\.source.host) == ["second.example", "first.example"])
    }

    private func note(
        id: String,
        postedAt: Date,
        categories: Set<FediqoCore.Category>,
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
            categories: categories,
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
