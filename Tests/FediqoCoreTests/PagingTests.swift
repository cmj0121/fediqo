import Foundation
import Testing
@testable import FediqoCore

/// Asking for what came before: the one cursor is a post already read, and each side of the
/// app turns it into its own words — Mastodon's `max_id`, the store's `(posted_at, merge_key)`.
@Suite("Asking a server for what came before")
struct SourcePagingTests {
    private let path = "/api/v1/timelines/public"

    private var client: MastodonClient {
        MastodonClient(session: stubbedSession(), ledger: APILedger())
    }

    @Test("Without a cursor the newest page is asked for, exactly as it always was")
    func newestPageSaysNothingMore() async throws {
        let host = "newest.paging.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: nil, token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [["limit": "7"]])
    }

    @Test("A cursor is sent as max_id, read out of the address the server itself handed over")
    func cursorBecomesMaxId() async throws {
        let host = "cursor.paging.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: handedOver("42", from: host), token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [["limit": "7", "max_id": "42"]])
    }

    @Test("A boost pages by the number the server gave the boost, like any other row")
    func aBoostIsAnOrdinaryCursor() throws {
        let host = "boost.paging.test"
        let boost = makePost(uri: "https://\(host)/api/v1/statuses/99",
                             originURI: "https://elsewhere.test/users/a/statuses/1",
                             at: 100, from: host, boostedBy: "someone else")

        #expect(try MastodonClient.statusId(of: boost, on: host) == "99")
    }

    @Test("A cursor that is not a status on this server is refused, and nothing is sent")
    func aForeignCursorNeverLeaves() async throws {
        let refusing = "refuse.paging.test"
        stubRoutes.on(refusing, path, status: 200, body: oneStatusJSON)
        // What another protocol's post looks like, and what another Mastodon server's does:
        // neither carries a number this server could be asked about.
        let strangers = [
            makePost(uri: "at://did:plc:abc/app.bsky.feed.post/3k", at: 100, from: refusing, socialProtocol: .atProto),
            handedOver("7", from: "other.test"),
        ]

        for stranger in strangers {
            await #expect(throws: SourceFailure.notItsPost(stranger.uri)) {
                try await client.timeline(host: refusing, limit: 7, before: stranger, token: nil)
            }
        }
        #expect(stubRoutes.requests(for: refusing, path).isEmpty)
    }
}

/// The store read a page at a time, backwards, with nothing skipped and nothing repeated.
@Suite("Reading the store back a page at a time")
struct StorePagingTests {
    private let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")

    private func uri(_ id: String) -> String { "https://one.example/api/v1/statuses/\(id)" }

    /// Six posts, two of them posted in the same millisecond — the case `merge_key` is in the
    /// index for. Newest first, the order is 5, 4, 3a, 3b, 2, 1.
    private func stocked() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save([
            makePost(uri: uri("5"), at: 500),
            makePost(uri: uri("4"), at: 400),
            makePost(uri: uri("3a"), at: 300),
            makePost(uri: uri("3b"), at: 300),
            makePost(uri: uri("2"), at: 200),
            makePost(uri: uri("1"), at: 100),
        ], from: one)
        return store
    }

    @Test("Without a cursor, the newest page, exactly as it always was")
    func noCursorIsTheNewestPage() async throws {
        let store = try await stocked()

        let page = try await store.timeline(limit: 2)

        #expect(page.map(\.uri) == [uri("5"), uri("4")])
    }

    @Test("Page after page reads the whole timeline once: no post skipped, none read twice")
    func pagesJoinWithoutSeamOrHole() async throws {
        let store = try await stocked()
        let whole = try await store.timeline()

        var paged: [Post] = []
        var cursor: Post?
        while true {
            let page = try await store.timeline(limit: 2, before: cursor)
            guard !page.isEmpty else { break }
            paged += page
            cursor = page.last
        }

        #expect(paged == whole)
        #expect(Set(paged.map(\.mergeKey)).count == paged.count)
    }

    @Test("A page boundary inside one instant neither repeats the post before it nor skips the one after")
    func oneInstantAcrossTwoPages() async throws {
        let store = try await stocked()

        let first = try await store.timeline(limit: 3)
        let second = try await store.timeline(limit: 3, before: first.last)

        // The boundary falls between two posts sharing a timestamp: `posted_at` alone could
        // not tell them apart, so one of them would have been lost or handed over twice.
        #expect(first.map(\.uri) == [uri("5"), uri("4"), uri("3a")])
        #expect(second.map(\.uri) == [uri("3b"), uri("2"), uri("1")])
    }

    /// What a reach for the bottom actually calls, rather than the store underneath it: the
    /// store's page comes back the size a server's page is, so the list grows by the same step
    /// whichever answered and a reader cannot tell from its length where it came from.
    @Test("The loader reads the store's page before a post, a server's page-worth at a time")
    func theLoaderReadsTheStoreBackwards() async throws {
        let store = try await stocked()
        let loader = TimelineLoader(limit: 2, store: store, secrets: InMemorySecretStore())
        let head = try await loader.stored(mode: .timeline)

        let page = await loader.storedOlder(than: head[1])

        #expect(page.posts.map(\.uri) == [uri("3a"), uri("3b")])
        #expect(page.failure == nil)
        // Nothing older, which is the store spent — and not the same answer as a store that
        // would not say, which is what the reach has to be able to tell apart.
        let past = await loader.storedOlder(than: head.last!)
        #expect(past.posts.isEmpty)
        #expect(past.failure == nil)
    }

    /// The order is written three times — as the store's cut, as its `ORDER BY`, and as
    /// `Post.isOlder` for whoever joins one page to the page before it. Two of them
    /// disagreeing is a post falling between the pages and never being read, so the three are
    /// pinned to each other here rather than kept in step by hand.
    @Test("The store's pages and Post.isOlder are the one order, tiebreak and all")
    func oneOrderInThreeSpellings() async throws {
        let store = try await stocked()

        let whole = try await store.timeline()

        #expect(zip(whole, whole.dropFirst()).allSatisfy { Post.isOlder($1, than: $0) })
        // And the fold every merged page goes through lands in that same order, so a page
        // from the network and a page from disk cannot disagree about where one ends.
        #expect(whole.shuffled().merged() == whole)
    }

    @Test("Before the oldest post there is nothing, and it says so rather than starting again")
    func pastTheEndIsEmpty() async throws {
        let store = try await stocked()
        let whole = try await store.timeline()

        #expect(try await store.timeline(limit: 2, before: whole.last).isEmpty)
    }
}

/// Where each server has got to, and the three reasons one goes unasked: it has run out, its
/// page is still out, or it is inside its wait. Nothing here sleeps — the clock is a parameter.
@Suite("Reading down, one thread of time per server")
struct ServerPagingTests {
    private let path = "/api/v1/timelines/public"
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    /// What each request to one host asked for as its cursor, in order — nil where it asked
    /// for that server's newest page.
    private func cursors(_ host: String) -> [String?] {
        stubRoutes.requests(for: host, path).map { $0.query["max_id"] }
    }

    @Test("Each server is asked for what came before its own last post, never anybody else's")
    func cursorsAreNeverCrossed() async {
        let one = makeServer("one.downward.test")
        let two = makeServer("two.downward.test")
        stubRoutes.on(one.host, path, status: 200, body: statusesJSON(["11", "10"], from: one.host))
        stubRoutes.on(two.host, path, status: 200, body: statusesJSON(["22", "20"], from: two.host))
        let loader = stubbedLoader(limit: 2)

        _ = await loader.loadOlder(servers: [one, two], now: t0)
        _ = await loader.loadOlder(servers: [one, two], now: t0.addingTimeInterval(1))

        // Nothing the first time — that is each server's newest page — and then each one's own
        // number, which is the whole of what a per-server cursor is for.
        #expect(cursors(one.host) == [nil, "10"])
        #expect(cursors(two.host) == [nil, "20"])
    }

    @Test("A page shorter than the one asked for is not an end, and is asked past")
    func aShortPageIsNotAnEnd() async {
        let short = makeServer("short.downward.test")
        stubRoutes.on(short.host, path, status: 200, body: statusesJSON(["9"], from: short.host))
        let loader = stubbedLoader(limit: 2)

        let result = await loader.loadOlder(servers: [short], now: t0)

        // A range with a blocked account in it comes back short from a server with plenty
        // left, so the only thing this page proves is what is in it.
        #expect(result.posts.count == 1)
        #expect(await loader.reachedTheEnd(of: [short]) == false)

        _ = await loader.loadOlder(servers: [short], now: t0.addingTimeInterval(1))
        #expect(cursors(short.host) == [nil, "9"])
    }

    @Test("An empty page says so too")
    func nothingAtAllIsAnEnd() async {
        let empty = makeServer("empty.downward.test")
        stubRoutes.on(empty.host, path, status: 200, body: "[]")
        let loader = stubbedLoader(limit: 2)

        _ = await loader.loadOlder(servers: [empty], now: t0)

        #expect(await loader.reachedTheEnd(of: [empty]))
    }

    @Test("A server that has run out stops being asked, and the others carry on without it")
    func anEndedServerStopsBeingAsked() async {
        let spent = makeServer("spent.downward.test")
        let going = makeServer("going.downward.test")
        stubRoutes.on(spent.host, path, status: 200, body: "[]")
        stubRoutes.on(going.host, path, status: 200, body: statusesJSON(["8", "7"], from: going.host))
        let loader = stubbedLoader(limit: 2)

        _ = await loader.loadOlder(servers: [spent, going], now: t0)
        let second = await loader.loadOlder(servers: [spent, going], now: t0.addingTimeInterval(1))

        // One of the two has run out, which is a fact about that server: the reading is not
        // over, and the one still going has been asked a second time.
        #expect(await loader.reachedTheEnd(of: [spent, going]) == false)
        #expect(await loader.reachedTheEnd(of: [spent]))
        #expect(cursors(spent.host).count == 1)
        #expect(cursors(going.host) == [nil, "7"])
        #expect(second.posts.allSatisfy { $0.sources == [going.host] })
    }

    /// A server that has run out was not asked, and a round that asked nothing about it has
    /// nothing to say about it. Leaving it out of `skipped` as well as out of `failures` is
    /// the round claiming otherwise, and `failures(carrying:of:)` reads that claim as good
    /// news: the reason the server was carrying is struck off the screen until the next
    /// refresh. `.tokenRejected` is the case that reaches it — it counts as having arrived,
    /// so it starts no wait, so nothing else was keeping the server out of a round.
    @Test("A server that has run out is still a server this round never asked")
    func aSpentServerIsUnaskedRatherThanCleared() async {
        let spent = makeServer("spent-standing.downward.test")
        let going = makeServer("going-standing.downward.test")
        stubRoutes.on(spent.host, path, status: 200, body: "[]")
        stubRoutes.on(going.host, path, status: 200, body: statusesJSON(["8", "7"], from: going.host))
        let loader = stubbedLoader(limit: 2)
        let standing = [spent.endpoint: SourceFailure.tokenRejected(spent.host)]

        _ = await loader.loadOlder(servers: [spent, going], now: t0)
        let second = await loader.loadOlder(servers: [spent, going], now: t0.addingTimeInterval(1))

        #expect(second.skipped.contains(spent.endpoint))
        #expect(second.failures[spent.endpoint] == nil)
        #expect(second.failures(carrying: standing, of: [spent, going])[spent.endpoint]
                    == .tokenRejected(spent.host))
        // The one that was asked is judged by this round alone, exactly as it always was.
        #expect(second.skipped.contains(going.endpoint) == false)
    }

    @Test("Only when every server has said so is the reading over")
    func everyServerHasToSaySo() async {
        let one = makeServer("one.ending.test")
        let two = makeServer("two.ending.test")
        stubRoutes.on(one.host, path, status: 200, body: "[]")
        stubRoutes.on(two.host, path, status: 200, body: statusesJSON(["2", "3"], from: two.host))
        let loader = stubbedLoader(limit: 2)

        _ = await loader.loadOlder(servers: [one, two], now: t0)
        #expect(await loader.reachedTheEnd(of: [one, two]) == false)

        stubRoutes.on(two.host, path, status: 200, body: "[]")
        _ = await loader.loadOlder(servers: [one, two], now: t0.addingTimeInterval(1))

        #expect(await loader.reachedTheEnd(of: [one, two]))
        // And with everyone at their end there is nobody left to ask.
        let again = await loader.loadOlder(servers: [one, two], now: t0.addingTimeInterval(2))
        #expect(again.posts.isEmpty)
        #expect(cursors(one.host).count == 1)
        #expect(cursors(two.host).count == 2)
    }

    @Test("A server dropped from the chosen list comes back a stranger, not a spent one")
    func leavingTheListForgetsTheEnd() async {
        let gone = makeServer("dropped.downward.test")
        let other = makeServer("kept.downward.test")
        stubRoutes.on(gone.host, path, status: 200, body: "[]")
        stubRoutes.on(other.host, path, status: 200, body: statusesJSON(["2", "1"], from: other.host))
        let loader = stubbedLoader(limit: 2)

        _ = await loader.loadOlder(servers: [gone], now: t0)
        #expect(await loader.reachedTheEnd(of: [gone]))

        // Removed for one reach and added back for the next: what it said about its own
        // bottom went with it, so it is asked again rather than passed over for the rest of
        // the run — and the server chosen throughout keeps where it had got to.
        _ = await loader.loadOlder(servers: [other], now: t0.addingTimeInterval(1))
        _ = await loader.loadOlder(servers: [gone, other], now: t0.addingTimeInterval(2))

        #expect(cursors(gone.host).count == 2)
        #expect(cursors(other.host) == [nil, "1"])
    }

    @Test("A server whose page is still out is not asked for another one")
    func aPageInFlightIsAskedOnce() async {
        let paging = ServerPaging()
        let held = makeServer("held.inflight.test")
        let free = makeServer("free.inflight.test")

        #expect(await paging.claim([held, free]).map(\.server) == [held, free])
        #expect(await paging.claim([held, free]).isEmpty)

        // Only the one that came back is free again; the other's page is still out.
        await paging.gave([makePost(uri: "https://\(free.host)/api/v1/statuses/1", at: 100)],
                          free.endpoint)
        #expect(await paging.claim([held, free]).map(\.server) == [free])
    }

    @Test("A cursor that was not the server's own is dropped, not asked about a second time")
    func aStrayCursorIsForgotten() async {
        let paging = ServerPaging()
        let server = makeServer("forgotten.cursor.test")
        let its = handedOver("1", from: "forgotten.cursor.test")

        _ = await paging.claim([server])
        await paging.gave([its], server.endpoint)
        #expect(await paging.claim([server]).map(\.cursor) == [its])

        // What the loader does when a server refuses the cursor it was handed: the cursor
        // goes, so the next page asked for is that server's newest rather than the same
        // refusal again.
        await paging.forget(server.endpoint)
        await paging.gaveNothing(server.endpoint)
        #expect(await paging.claim([server]).map(\.cursor) == [nil])
    }

    @Test("However fast a reader scrolls, the second reach finds the first still in flight",
          .timeLimit(.minutes(1)))
    func scrollingHardAsksOnce() async {
        let server = makeServer("scrolled.inflight.test")
        let client = HeldClient()
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                    limit: 2, secrets: InMemorySecretStore())

        async let first = loader.loadOlder(servers: [server], now: t0)
        await client.untilAsked()
        let second = await loader.loadOlder(servers: [server], now: t0)

        #expect(second.posts.isEmpty)
        #expect(second.failures.isEmpty)
        await client.letGo()
        _ = await first
        #expect(await client.cursors.count == 1)
    }

    @Test("A server that fails while paging backs off exactly as it does on a refresh")
    func failingWhilePagingBacksOff() async {
        let host = "falls-over.downward.test"
        let server = makeServer(host)
        stubRoutes.on(host, path, status: 200, body: statusesJSON(["5", "4"], from: host))
        let loader = stubbedLoader(limit: 2)
        _ = await loader.loadOlder(servers: [server], every: .seconds(30), now: t0)

        stubRoutes.on(host, path, status: 503, body: "gateway wept")
        let failed = await loader.loadOlder(servers: [server], every: .seconds(30),
                                            now: t0.addingTimeInterval(1))
        #expect(failed.failures[server.endpoint] == SourceFailure.http(503, Data("gateway wept".utf8)))

        // Inside its wait it is left alone rather than asked, and says so where a refresh
        // says it — so a screen keeps the reason up rather than blinking it off.
        let waiting = await loader.loadOlder(servers: [server], every: .seconds(30),
                                             now: t0.addingTimeInterval(2))
        #expect(waiting.skipped == [server.endpoint])
        #expect(waiting.failures.isEmpty)

        stubRoutes.on(host, path, status: 200, body: statusesJSON(["3", "2"], from: host))
        _ = await loader.loadOlder(servers: [server], every: .seconds(30),
                                   now: t0.addingTimeInterval(31))

        // Silence is not an end: the cursor stood through the failure, so the page that was
        // missed is asked for again rather than skipped over.
        #expect(cursors(host) == [nil, "4", "4"])
    }

    @Test("A cursor from somewhere else is ours to fix: asked again without one, and never shown")
    func aStrayCursorIsRetriedNotReported() async {
        let host = "stray.cursor.test"
        let server = makeServer(host)
        let elsewhere = handedOver("7", from: "somewhere-else.test", at: 300)
        let mine = handedOver("6", from: host, at: 200)
        let client = StrayCursorClient(pages: [[elsewhere], [mine]])
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                    limit: 1, secrets: InMemorySecretStore())

        _ = await loader.loadOlder(servers: [server], now: t0)
        let retried = await loader.loadOlder(servers: [server], now: t0.addingTimeInterval(1))

        // Refused, then asked again with no cursor at all — which puts a cursor of the
        // server's own back in place.
        #expect(await client.cursors.map { $0?.uri } == [nil, elsewhere.uri, nil])
        #expect(retried.posts.map(\.uri) == [mine.uri])
        // Our mistake, so the reader is told nothing and no wait is started for it.
        #expect(retried.failures.isEmpty)
        _ = await loader.loadOlder(servers: [server], now: t0.addingTimeInterval(2))
        #expect(await client.cursors.map { $0?.uri } == [nil, elsewhere.uri, nil, mine.uri])
    }

    @Test("A stray cursor refused on the anonymous retry is ours to fix as well")
    func aStrayCursorIsOursWhicheverReadRefusedIt() async {
        let host = "rejected.stray.test"
        let server = makeServer(host)
        let client = RejectingStrayCursorClient(page: [handedOver("6", from: host, at: 200)])
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                    limit: 1, secrets: InMemorySecretStore())

        _ = await loader.loadOlder(servers: [server], now: t0)
        let retried = await loader.loadOlder(servers: [server], now: t0.addingTimeInterval(1))

        // The credential is turned down, the stranger's read is refused the cursor, and the
        // cursor is still ours: dropped, asked again without one, and never shown.
        #expect(await client.cursors.map { $0?.uri } == [nil, "https://\(host)/api/v1/statuses/6",
                                                         "https://\(host)/api/v1/statuses/6", nil])
        #expect(retried.posts.count == 1)
        #expect(retried.failures.isEmpty)
    }
}

/// A client that holds its first request open until it is let go — the only way to have a page
/// genuinely in flight while the next reach for the bottom arrives, with nothing sleeping.
///
/// Only the first. A second request arriving is the in-flight guard having let one through,
/// which is the thing the test watches for: answering it at once turns that into an
/// expectation that fails in milliseconds, where holding it too would leave a continuation
/// nobody resumes and a suite that never finishes. The time limit on the test is the backstop
/// — it marks the test red after a minute, but the run stays stuck behind the held request.
actor HeldClient: SourceClient {
    private(set) var cursors: [Post?] = []
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }

    /// Nothing in this suite reconciles, and a double that answered "gone" would mark posts
    /// no test asked it to. Still there is the answer that decides nothing.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] {
        cursors.append(before)
        arrival?.resume()
        arrival = nil
        guard cursors.count == 1 else { return [] }
        await withCheckedContinuation { release = $0 }
        return []
    }

    /// Back once a request is genuinely out and waiting to be let go.
    func untilAsked() async {
        guard cursors.isEmpty else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func letGo() {
        release?.resume()
        release = nil
    }
}

/// A client that hands over a post belonging to another server, and then refuses to be asked
/// what came before it — the wiring mistake per-server cursors make impossible, staged so the
/// belt underneath them can be tested at all.
actor StrayCursorClient: SourceClient {
    private(set) var cursors: [Post?] = []
    private var pages: [[Post]]

    init(pages: [[Post]]) { self.pages = pages }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }

    /// Nothing in this suite reconciles, and a double that answered "gone" would mark posts
    /// no test asked it to. Still there is the answer that decides nothing.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] {
        cursors.append(before)
        // Refused by the real rule rather than a copy of it, so the belt in `TimelineLoader`
        // is tested against what a client actually turns down.
        if let before { _ = try MastodonClient.statusId(of: before, on: host) }
        return pages.isEmpty ? [] : pages.removeFirst()
    }
}

/// A client that turns the credential down and then refuses the cursor: `.tokenRejected` to
/// the read as whoever is signed in, `.notItsPost` to the same read as a stranger. No real
/// client answers this pair — it is what a mis-wired one would, and decision 8 is that our
/// wiring never reaches the reader wearing a server's fault.
actor RejectingStrayCursorClient: SourceClient {
    private(set) var cursors: [Post?] = []
    private let page: [Post]
    private var refusals = 2

    init(page: [Post]) { self.page = page }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }

    /// Nothing in this suite reconciles, and a double that answered "gone" would mark posts
    /// no test asked it to. Still there is the answer that decides nothing.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] {
        cursors.append(before)
        guard let before else { return page }
        refusals -= 1
        let refusal: SourceFailure = refusals > 0 ? .tokenRejected(host) : .notItsPost(before.uri)
        throw refusal
    }
}
