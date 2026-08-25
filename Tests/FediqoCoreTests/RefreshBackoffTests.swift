import Foundation
import Testing
@testable import FediqoCore

/// Fediqo is a guest on other people's machines. A server that could not answer is asked
/// again later rather than sooner — and a reader who asks is never made to wait for it.
///
/// Every test here hands the clock in, so nothing sleeps: `now` is a parameter of a load,
/// the same way it already is of `stored(mode:now:)`.
@Suite("A server that cannot answer is asked later, not sooner")
struct RefreshBackoffTests {
    private let publicTimeline = "/api/v1/timelines/public"
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private let every30 = Refresh.automatic(every: .seconds(30))

    @Test("The wait doubles every time nothing arrives, and stops at a quarter of an hour")
    func waitDoublesToTheCeiling() async {
        let backoff = ServerBackoff()
        let endpoint = "https://doubling.test"
        var now = t0

        // Thirty seconds, then a minute, then two — and never past a quarter of an hour,
        // however many times in a row nothing arrives.
        for length in [30.0, 60, 120, 240, 480, 900, 900] {
            await backoff.failed([endpoint], base: .seconds(30), at: now)
            #expect(await backoff.blocked(at: now.addingTimeInterval(length - 1)) == [endpoint])
            #expect(await backoff.blocked(at: now.addingTimeInterval(length)).isEmpty)
            now = now.addingTimeInterval(length)
        }
    }

    @Test("The first wait is however often the page refreshes itself")
    func firstWaitIsTheInterval() async {
        let backoff = ServerBackoff()
        let endpoint = "https://interval.test"

        await backoff.failed([endpoint], base: .seconds(300), at: t0)

        #expect(await backoff.blocked(at: t0.addingTimeInterval(299)) == [endpoint])
        #expect(await backoff.blocked(at: t0.addingTimeInterval(300)).isEmpty)
    }

    @Test("An answer forgets the whole thing, however long the wait had grown")
    func anAnswerForgets() async {
        let backoff = ServerBackoff()
        let endpoint = "https://forgiven.test"
        await backoff.failed([endpoint], base: .seconds(30), at: t0)
        await backoff.failed([endpoint], base: .seconds(30), at: t0)

        await backoff.answered([endpoint])

        #expect(await backoff.blocked(at: t0).isEmpty)
    }

    @Test("A server that gave nothing is skipped by the next tick, and asked again once its wait is up")
    func silenceIsSkippedUntilTheWaitIsUp() async {
        let host = "silent.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 503, body: "gateway wept")
        let loader = stubbedLoader()

        _ = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 1)

        // Ten seconds later the clock ticks again. The server is not asked, and it is not
        // reported either — it is being left alone, not failing.
        let skipped = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                        now: t0.addingTimeInterval(10))
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 1)
        #expect(skipped.failures.isEmpty)

        let asked = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                      now: t0.addingTimeInterval(30))
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
        #expect(asked.failures[server.endpoint] == SourceFailure.http(503, Data("gateway wept".utf8)))
    }

    @Test("One server waiting does not stop the ones that answered")
    func aWaitIsPerServer() async {
        let silent = makeServer("silent-one.test")
        let open = makeServer("open-again.test")
        stubRoutes.on(silent.host, publicTimeline, status: 503)
        stubRoutes.on(open.host, publicTimeline, status: 200, body: oneStatusJSON)
        let loader = stubbedLoader()

        _ = await loader.load(servers: [silent, open], query: .publicPosts, refresh: every30, now: t0)
        let second = await loader.load(servers: [silent, open], query: .publicPosts, refresh: every30,
                                       now: t0.addingTimeInterval(10))

        #expect(stubRoutes.requests(for: silent.host, publicTimeline).count == 1)
        #expect(stubRoutes.requests(for: open.host, publicTimeline).count == 2)
        #expect(second.posts.map(\.sources) == [[open.host]])
    }

    @Test("Pulling to refresh asks a server that is still waiting, because you asked")
    func manualIgnoresTheWait() async {
        let host = "asked-anyway.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 503)
        let loader = stubbedLoader()

        _ = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        _ = await loader.load(servers: [server], query: .publicPosts, now: t0.addingTimeInterval(1))

        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
    }

    @Test("A manual refresh that works brings a waiting server straight back")
    func manualAnswerClearsTheWait() async {
        let host = "back-at-once.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 503)
        let loader = stubbedLoader()
        _ = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)

        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        _ = await loader.load(servers: [server], query: .publicPosts, now: t0.addingTimeInterval(1))

        // The wait was forgiven by the answer, so the very next tick asks rather than skips.
        let ticked = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                       now: t0.addingTimeInterval(2))
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 3)
        #expect(ticked.posts.count == 1)
    }

    @Test("A manual refusal is nobody's schedule: the clock's wait is only ever the clock's own")
    func manualFailureStartsNoWait() async {
        let host = "manual-refusal.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 503)
        let loader = stubbedLoader()

        _ = await loader.load(servers: [server], query: .publicPosts, now: t0)
        _ = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)

        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
    }

    @Test("A protocol this build cannot read is not put on a timer; it is simply not spoken")
    func unsupportedIsNotAWait() async {
        let server = Server(host: "nostr-only.test", socialProtocol: .nostr, title: "nostr-only.test")
        let loader = stubbedLoader()

        _ = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        let second = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)

        // Nothing was sent anywhere, so the row keeps saying why rather than falling silent.
        #expect(second.failures[server.endpoint] == SourceFailure.unsupported(.nostr))
    }

    @Test("A server that turned a credential down has answered: it is asked again next tick, as a stranger")
    func rejectedTokenIsNotAWait() async throws {
        let host = "refused-credential.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        stubRoutes.onAuthorized(host, publicTimeline, status: 401)
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        try await signInRows("expired", to: server, store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets)

        let first = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        #expect(first.failures[server.endpoint] == SourceFailure.tokenRejected(host))

        let second = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                       now: t0.addingTimeInterval(1))

        // Asked again a second later — no wait was started. And the spent credential is not
        // sent a second time: the read goes straight out as a stranger, so what the account
        // needs is said once rather than every thirty seconds.
        #expect(second.posts.count == 1)
        #expect(second.failures.isEmpty)
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer expired", nil, nil])
    }

    @Test("A wait that has run out is still remembered, so the next silence is twice as long")
    func anExpiredWaitStillDoubles() async {
        let backoff = ServerBackoff()
        let endpoint = "https://remembered.test"
        await backoff.failed([endpoint], base: .seconds(30), at: t0)

        // The tick that finds the wait up asks the server, and is given nothing again.
        let asking = t0.addingTimeInterval(30)
        #expect(await backoff.blocked(at: asking).isEmpty)
        await backoff.failed([endpoint], base: .seconds(30), at: asking)

        #expect(await backoff.blocked(at: asking.addingTimeInterval(59)) == [endpoint])
        #expect(await backoff.blocked(at: asking.addingTimeInterval(60)).isEmpty)
    }

    @Test("A server nobody asked for a whole ceiling is forgotten rather than kept forever")
    func aLongIgnoredWaitIsDropped() async {
        let backoff = ServerBackoff()
        let endpoint = "https://left-the-list.test"
        await backoff.failed([endpoint], base: .seconds(30), at: t0)

        // The wait ran out at t0 + 30 and nothing asked in the quarter of an hour that
        // followed. That is a server which left the list, not one being left alone, so
        // looking here drops it — and the ladder starts at the bottom if it ever comes back.
        let muchLater = t0.addingTimeInterval(30 + ServerBackoff.ceiling.seconds + 1)
        #expect(await backoff.blocked(at: muchLater).isEmpty)

        await backoff.failed([endpoint], base: .seconds(30), at: muchLater)
        #expect(await backoff.blocked(at: muchLater.addingTimeInterval(29)) == [endpoint])
        #expect(await backoff.blocked(at: muchLater.addingTimeInterval(30)).isEmpty)
    }
}

/// A server inside its wait is in no load's failures, because no load asked it. Left at that,
/// a screen would take its reason down and put it back up every cycle while nothing about the
/// server changed — so the reason is carried across the loads that skipped it, and only an
/// answer, or leaving the list, takes it away.
@Suite("A broken server goes on saying so, even on the loads that leave it alone")
struct StandingFailureTests {
    private let publicTimeline = "/api/v1/timelines/public"
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private let every30 = Refresh.automatic(every: .seconds(30))

    @Test("A load that skipped a server keeps saying what was already known about it")
    func aSkippedServerKeepsItsReason() async {
        let server = makeServer("still-broken.test")
        stubRoutes.on(server.host, publicTimeline, status: 503)
        let loader = stubbedLoader()

        let failing = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        let standing = failing.failures(carrying: [:], of: [server])
        #expect(standing[server.endpoint] == SourceFailure.http(503, Data("[]".utf8)))

        let skipped = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                        now: t0.addingTimeInterval(10))

        #expect(skipped.skipped == [server.endpoint])
        #expect(skipped.failures.isEmpty)
        #expect(skipped.failures(carrying: standing, of: [server]) == standing)
    }

    @Test("A server that answers loses its line, however long it had been carrying one")
    func anAnswerClearsTheLine() async {
        let server = makeServer("mended.test")
        stubRoutes.on(server.host, publicTimeline, status: 503)
        let loader = stubbedLoader()
        let failing = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)
        let standing = failing.failures(carrying: [:], of: [server])
        #expect(!standing.isEmpty)

        stubRoutes.on(server.host, publicTimeline, status: 200, body: oneStatusJSON)
        let answered = await loader.load(servers: [server], query: .publicPosts, refresh: every30,
                                         now: t0.addingTimeInterval(30))

        #expect(answered.skipped.isEmpty)
        #expect(answered.failures(carrying: standing, of: [server]).isEmpty)
    }

    @Test("A server that is nobody's source now is forgotten rather than carried")
    func aRemovedServerIsForgotten() async {
        let leaving = makeServer("no-longer-mine.test")
        let staying = makeServer("still-mine.test")
        stubRoutes.on(staying.host, publicTimeline, status: 200, body: oneStatusJSON)
        let loader = stubbedLoader()
        let known = [leaving.endpoint: SourceFailure.badHost(leaving.host)]

        let result = await loader.load(servers: [staying], query: .publicPosts, refresh: every30, now: t0)

        #expect(result.failures(carrying: known, of: [staying]).isEmpty)
    }

    @Test("What a server said this time is the newer news, and replaces what was known")
    func thisLoadOverridesWhatWasKnown() async {
        let server = makeServer("newer-news.test")
        stubRoutes.on(server.host, publicTimeline, status: 404)
        let loader = stubbedLoader()
        let known = [server.endpoint: SourceFailure.http(503, Data("[]".utf8))]

        let result = await loader.load(servers: [server], query: .publicPosts, refresh: every30, now: t0)

        #expect(result.failures(carrying: known, of: [server])[server.endpoint]
                == SourceFailure.http(404, Data("[]".utf8)))
    }
    @Test("A refresh that brought nothing leaves the rows that were already there")
    func nothingNewLeavesWhatIsThere() async {
        let host = "gone.test"
        let server = makeServer(host)
        stubRoutes.on(host, "/api/v1/timelines/public", status: 503, body: "")
        let shown = [makePost(uri: "kept", at: 100, from: host)]

        let failed = await stubbedLoader().load(servers: [server], query: .publicPosts)

        // The server is unreachable, not empty — and the store still holds what it held.
        #expect(failed.posts.isEmpty)
        #expect(failed.posts(carrying: shown, asked: [server]).map(\.uri) == ["kept"])
    }

    /// A refresh asks every server for its newest page, so it speaks for the top of the
    /// timeline and for nothing under it. A reader who has read down five pages must not have
    /// four of them taken away every time the clock ticks.
    @Test("A refresh replaces the stretch it covers and leaves what was read below it")
    func aRefreshKeepsWhatWasReadBelowIt() async {
        let host = "deep.test"
        let server = makeServer(host)
        stubRoutes.on(host, "/api/v1/timelines/public", status: 200,
                      body: statusesJSON(["5", "4"], from: host, authority: host, at: [500, 400]))
        let shown = ["4", "3", "2"].enumerated().map {
            handedOver($1, from: host, authority: host, at: 400 - TimeInterval($0) * 100)
        }

        let refreshed = await stubbedLoader(limit: 2).load(servers: [server], query: .publicPosts)

        // The page's own rows, then the tail below them — and the row the page and the screen
        // both had is the page's, once.
        #expect(refreshed.posts(carrying: shown, asked: [server]).map(\.uri)
                == ["5", "4", "3", "2"].map { "https://\(host)/api/v1/statuses/\($0)" })
    }

    @Test("With no sources left there is nobody whose rows those were")
    func noSourcesClearsTheScreen() async {
        let shown = [makePost(uri: "orphan", at: 100, from: "gone.test")]
        let empty = await stubbedLoader().load(servers: [], query: .publicPosts)

        #expect(empty.posts(carrying: shown, asked: []).isEmpty)
    }

}
