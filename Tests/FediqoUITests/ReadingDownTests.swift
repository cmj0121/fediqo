import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Reaching the bottom of the timeline, and what comes back.
///
/// Every test here turns on one of two promises. The reader waiting at the foot of the list is
/// answered by whichever of the store and the servers can answer first — and the servers are
/// asked either way, because a post one of them has stopped handing over is only noticeable
/// if somebody asks. And whatever arrives *joins* the list: nothing already read moves, and
/// nothing already read is replaced.
///
/// Nothing here sleeps and nothing here reaches a network. The client is a double that hands
/// over a fixed run of posts a page at a time, and where a page has to be genuinely in flight
/// it holds its own request open rather than anybody waiting on a clock.
@Suite("Reading down asks for what came before")
@MainActor
struct ReadingDownTests {
    private let server = makeServer("one.example")

    /// Six posts, newest first — `six` down to `one`. Whichever of the store and the client
    /// is stocked with them, the reader reads the same timeline.
    private static let all = (1...6).reversed()
        .map { makePost("p\($0)", at: TimeInterval($0) * 100, from: "one.example") }

    private func stocked() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save(Self.all, from: server)
        return store
    }

    private func names(_ feed: FeedModel) -> [String] { feed.visible.map(\.mergeKey) }

    // MARK: - The store first, and the servers anyway

    /// Decision 1, both halves of it. The store can answer now and the reader is waiting, so
    /// it answers; and the servers are asked behind it regardless, because that round is the
    /// evidence `reconcile` spends — the only way a post a server has stopped handing over is
    /// ever noticed at all.
    @Test("The store answers the page, and the servers are asked anyway")
    func theStoreFirstAndTheNetworkAnyway() async throws {
        // The client's own posts are all newer than the foot of the list, so anything that
        // appears below it can only have come from the store.
        let client = PagedClient([makePost("new", at: 10_000, from: "one.example")])
        let feed = freshFeed("down-store-first", client: client, store: try await stocked())
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])

        #expect(names(feed) == ["p6", "p5", "p4", "p3"])
        // The ask rides behind the page rather than in front of it, so this is what proves it
        // went out at all — and the test waits for the request rather than for a clock.
        await client.untilAsked()
        #expect(await client.asks == 1)
    }

    /// The store having run out is what puts the reader on the network's own pace, and the
    /// page that comes back joins the end exactly as the store's did.
    @Test("Where the store has run out, the servers are what answer")
    func theNetworkWhereTheStoreEnds() async {
        let client = PagedClient(Self.all)
        let feed = freshFeed("down-network", client: client)
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])

        #expect(names(feed) == ["p6", "p5", "p4", "p3"])
    }

    /// The two tabs are one screen, so both triggers fire on both — and only one of them is a
    /// thread of time. A trending list is a snapshot a server curated in the order it chose,
    /// and appending posts from the timeline under it would be the one thing that list must
    /// not have done to it: the reader would be shown the server's ranking with rows the
    /// server never ranked stuck on the end of it. The two tabs hold a loader each, so no
    /// cursor of the timeline's is at risk here; what is at risk is the list itself.
    @Test("Trending does not page: what came before a snapshot is not a question")
    func trendingNeverPages() async throws {
        let client = PagedClient(Self.all)
        let feed = freshFeed("down-trending", mode: .trending, client: client,
                             store: try await stocked())
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])

        #expect(names(feed) == ["p6", "p5"])
        #expect(await client.asks == 0)
        #expect(feed.loadingOlder == false)
    }

    // MARK: - One reach at a time

    /// `ServerPaging` keeps a server from being asked twice; this is the other guard, over the
    /// reach itself. A scroll is as tireless as a clock, and without it crossing the threshold
    /// once a frame would ask once a frame.
    @Test("A second reach arriving while the first is out sends nothing of its own",
          .timeLimit(.minutes(1)))
    func oneReachAtATime() async {
        let client = PagedClient(Self.all, holds: true)
        let feed = freshFeed("down-one-at-a-time", client: client)
        feed.show(Array(Self.all.prefix(2)))

        async let first: Void = feed.loadOlder(servers: [server])
        await client.untilAsked()
        await feed.loadOlder(servers: [server])

        // The reach still out is the only reach there has been, and the second one left the
        // list exactly as it found it. It is kept rather than thrown away — see
        // `aReachBehindARoundIsNotSwallowed` for the half of the promise that is about that.
        #expect(await client.asks == 1)
        #expect(names(feed) == ["p6", "p5"])

        await client.letGo()
        await first
    }

    /// The swallow this whole unit exists to kill, in the one arrangement that makes it.
    ///
    /// The first reach is answered by the store, so it is over in a moment — but the round it
    /// derives is still out behind it. The reader is still at the foot of the list and reaches
    /// again; this time the store has nothing, so the servers are the only ones who can
    /// answer. A guard that turned this reach away would leave no page, no spinner and nothing
    /// coming, and `onScrollGeometryChange` fires on a crossing rather than on a state, so
    /// nothing would ever fire again: the reader has to scroll away and come back by hand.
    @Test("A reach arriving behind a round that is still out is kept, not swallowed",
          .timeLimit(.minutes(1)))
    func aReachBehindARoundIsNotSwallowed() async throws {
        let store = try LocalStore.inMemory()
        // Only down to p3, so the first reach is answered from disk and the second finds the
        // store spent — the two halves the swallow needs.
        try await store.save(Array(Self.all.prefix(4)), from: server)
        let client = PagedClient(Self.all, holds: true)
        let feed = freshFeed("down-not-swallowed", client: client, store: store)
        feed.show(Array(Self.all.prefix(2)))

        async let first: Void = feed.loadOlder(servers: [server])
        await client.untilAsked()
        #expect(names(feed) == ["p6", "p5", "p4", "p3"])

        // The reach that used to vanish.
        await feed.loadOlder(servers: [server])
        await client.letGo()
        await first

        #expect(await client.asks > 1)
        #expect(names(feed) == ["p6", "p5", "p4", "p3", "p2", "p1"])
    }

    // MARK: - Joining, not replacing

    @Test("Older posts join the end; nothing already read moves or is replaced")
    func nothingAlreadyReadMoves() async throws {
        let client = PagedClient([])
        let feed = freshFeed("down-joins", client: client, store: try await stocked())
        feed.show(Array(Self.all.prefix(3)))
        let read = feed.visible

        await feed.loadOlder(servers: [server])

        #expect(Array(feed.visible.prefix(3)) == read)
        #expect(names(feed) == ["p6", "p5", "p4", "p3", "p2"])
    }

    @Test("The ring stays on the post the reader put it on while the list grows under it")
    func theRingStaysPut() async throws {
        let client = PagedClient([])
        let feed = freshFeed("down-ring-stays", client: client, store: try await stocked())
        feed.show(Array(Self.all.prefix(3)))
        feed.moveSelection(by: 1)
        feed.moveSelection(by: 1)
        #expect(feed.selection == "p5")

        await feed.loadOlder(servers: [server])

        #expect(feed.selection == "p5")
        #expect(feed.selectedPost?.mergeKey == "p5")
    }

    /// A page that comes back holding what is already on the screen is more of the timeline,
    /// not a new version of it — so the row the reader has read is left exactly where it is
    /// rather than being merged over the top of.
    @Test("A post the list already has is dropped rather than repeated at the foot")
    func nothingArrivesTwice() async {
        // Every page this client gives is its newest, so the second reach hands back the first
        // page again — the overlap a cold start makes, at its plainest.
        let client = PagedClient(Self.all, sameEveryTime: true)
        let feed = freshFeed("down-no-repeats", client: client)
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])

        #expect(names(feed) == ["p6", "p5"])
        #expect(Set(names(feed)).count == names(feed).count)
    }

    /// A refresh asks every server for its newest page, so it speaks for the top of the
    /// timeline and for nothing under it. Snapping the list back to one page under a reader
    /// who had read down five would be the clock undoing their reading every thirty seconds.
    @Test("A refresh replaces the head of the list and leaves what was read below it")
    func aRefreshKeepsTheTail() async {
        let client = PagedClient(Self.all)
        let feed = freshFeed("down-refresh-keeps-tail", client: client)
        feed.show(Self.all)

        await feed.load(servers: [server])

        #expect(names(feed) == Self.all.map(\.mergeKey))
    }

    // MARK: - The cold-start cliff

    /// Every round of a cold start lands above the reader rather than below: the cursors start
    /// empty, so a server's first page is its newest, which the store already had. One round
    /// and a shrug is "I reached the bottom and nothing happened" — so the reach keeps asking.
    /// The ceiling is what keeps it from running away when nothing will ever land.
    @Test("A reach that never lands anything below the reader stops at its ceiling")
    func theLoopHasACeiling() async {
        let client = PagedClient(Self.all, sameEveryTime: true)
        let feed = freshFeed("down-ceiling", client: client)
        // Older than everything the client has, so no round of it can ever land below.
        feed.show([makePost("floor", at: 1, from: "one.example")])

        await feed.loadOlder(servers: [server])

        #expect(await client.asks == FeedModel.roundsPerReach)
        #expect(names(feed) == ["floor"])
    }

    /// The other half: the loop is a loop until something lands, not a loop for its own sake.
    /// The cliff one round deep — the server's newest page is the page the reader has already
    /// read — is climbed by the second round, and the reach ends there rather than at eight.
    @Test("A round that lands a page below the reader is the last round of that reach")
    func theLoopStopsWhenSomethingLands() async {
        let client = PagedClient(Self.all)
        let feed = freshFeed("down-loop-stops", client: client)
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])

        #expect(await client.asks == 2)
        #expect(names(feed) == ["p6", "p5", "p4", "p3"])
    }

    /// Nobody said anything at all — every server is spent — so asking again this instant
    /// would ask the same nobody, and the ceiling is not what has to notice it.
    @Test("A server with nothing left ends the reach rather than being asked eight times")
    func nobodyLeftToAsk() async {
        let client = PagedClient([])
        let feed = freshFeed("down-nobody-left", client: client)
        feed.show(Array(Self.all.prefix(2)))

        await feed.loadOlder(servers: [server])
        #expect(await client.asks == 1)

        // And a server that has said so stops being asked at all.
        await feed.loadOlder(servers: [server])
        #expect(await client.asks == 1)
    }

    // MARK: - j past the last post

    @Test("j on the last post moves nothing and asks for more instead")
    func jPastTheEndAsks() {
        let feed = freshFeed("down-j-asks")
        feed.show(Array(Self.all.prefix(2)))
        #expect(feed.moveSelection(by: 1))
        #expect(feed.moveSelection(by: 1))
        #expect(feed.selection == "p5")

        #expect(feed.moveSelection(by: 1) == false)
        #expect(feed.awaitingOlder)
    }

    @Test("The ring lands on the first post that arrives")
    func theRingLandsOnWhatArrives() async throws {
        let client = PagedClient([])
        let feed = freshFeed("down-j-lands", client: client, store: try await stocked())
        feed.show(Array(Self.all.prefix(2)))
        feed.moveSelection(by: 1)
        feed.moveSelection(by: 1)
        #expect(feed.moveSelection(by: 1) == false)

        await feed.loadOlder(servers: [server])

        #expect(feed.selection == "p4")
        #expect(feed.awaitingOlder == false)
    }

    /// A reader who asked for more and then went somewhere else is not waiting any more, and
    /// the page landing a moment later must not drag their ring back to the bottom.
    @Test("A reader who moves on before the page arrives keeps the ring where they went",
          arguments: [-1, 1])
    func askingAndThenMovingOn(steps: Int) async throws {
        let client = PagedClient([])
        let feed = freshFeed("down-j-moved-on-\(steps)", client: client, store: try await stocked())
        feed.show(Array(Self.all.prefix(3)))
        for _ in 0..<3 { feed.moveSelection(by: 1) }
        #expect(feed.moveSelection(by: 1) == false)
        #expect(feed.awaitingOlder)

        // Up one, or asked again from somewhere that is no longer the end.
        feed.moveSelection(by: -1)
        feed.moveSelection(by: steps)
        let here = feed.selection
        await feed.loadOlder(servers: [server])

        #expect(feed.selection == here)
    }

    @Test("Going back to the top stops the ring waiting at a bottom nobody is at")
    func goingToTheTopStopsWaiting() {
        let feed = freshFeed("down-j-top")
        feed.show(Array(Self.all.prefix(2)))
        feed.moveSelection(by: 1)
        feed.moveSelection(by: 1)
        #expect(feed.moveSelection(by: 1) == false)

        feed.goToTop()
        #expect(feed.awaitingOlder == false)
    }
}

/// The same last press, asked of the app rather than of one feed: the feed knows it is
/// waiting, and the app is what has the servers to ask.
@Suite("j past the last post, from the keyboard")
@MainActor
struct ReadingDownKeyTests {
    private static let posts = ["a", "b"].map { makePost($0, at: 100) }

    @Test("j on the last post says nothing moved, and leaves the feed asking for more")
    func theLastPressAsks() {
        let app = freshApp("down-key-asks")
        app.railItem = .timeline
        app.feedTab = .timeline
        let feed = app.feed(for: .timeline)
        feed.show(Self.posts)

        while app.perform(.nextPost) {}

        #expect(feed.selection == Self.posts.last?.mergeKey)
        #expect(feed.awaitingOlder)
    }

    /// The top is not the bottom: what is above the newest post is a refresh, and refreshing
    /// already exists.
    @Test("k at the top asks for nothing — there is nothing above the newest post but a refresh")
    func theFirstPressAsksForNothing() {
        let app = freshApp("down-key-top")
        app.railItem = .timeline
        app.feedTab = .timeline
        let feed = app.feed(for: .timeline)
        feed.show(Self.posts)

        #expect(app.perform(.previousPost))
        #expect(app.perform(.previousPost) == false)
        #expect(feed.awaitingOlder == false)
    }
}
