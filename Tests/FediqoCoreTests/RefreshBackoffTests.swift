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

        _ = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 1)

        // Ten seconds later the clock ticks again. The server is not asked, and it is not
        // reported either — it is being left alone, not failing.
        let skipped = await loader.load(servers: [server], mode: .timeline, refresh: every30,
                                        now: t0.addingTimeInterval(10))
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 1)
        #expect(skipped.failures.isEmpty)

        let asked = await loader.load(servers: [server], mode: .timeline, refresh: every30,
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

        _ = await loader.load(servers: [silent, open], mode: .timeline, refresh: every30, now: t0)
        let second = await loader.load(servers: [silent, open], mode: .timeline, refresh: every30,
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

        _ = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)
        _ = await loader.load(servers: [server], mode: .timeline, now: t0.addingTimeInterval(1))

        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
    }

    @Test("A manual refresh that works brings a waiting server straight back")
    func manualAnswerClearsTheWait() async {
        let host = "back-at-once.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 503)
        let loader = stubbedLoader()
        _ = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)

        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        _ = await loader.load(servers: [server], mode: .timeline, now: t0.addingTimeInterval(1))

        // The wait was forgiven by the answer, so the very next tick asks rather than skips.
        let ticked = await loader.load(servers: [server], mode: .timeline, refresh: every30,
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

        _ = await loader.load(servers: [server], mode: .timeline, now: t0)
        _ = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)

        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
    }

    @Test("A protocol this build cannot read is not put on a timer; it is simply not spoken")
    func unsupportedIsNotAWait() async {
        let server = Server(host: "nostr-only.test", socialProtocol: .nostr, title: "nostr-only.test")
        let loader = stubbedLoader()

        _ = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)
        let second = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)

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

        let first = await loader.load(servers: [server], mode: .timeline, refresh: every30, now: t0)
        #expect(first.failures[server.endpoint] == SourceFailure.tokenRejected(host))

        let second = await loader.load(servers: [server], mode: .timeline, refresh: every30,
                                       now: t0.addingTimeInterval(1))

        // Asked again a second later — no wait was started. And the spent credential is not
        // sent a second time: the read goes straight out as a stranger, so what the account
        // needs is said once rather than every thirty seconds.
        #expect(second.posts.count == 1)
        #expect(second.failures.isEmpty)
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer expired", nil, nil])
    }
}
