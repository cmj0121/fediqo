import Foundation
import Testing
@testable import FediqoCore

/// A transport that never reaches anybody — the connection breaking rather than a server
/// answering, which is the one failure `StubURLProtocol` cannot script because it always
/// answers something.
final class BrokenURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

func brokenSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BrokenURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// The counting itself is under test, so every test here brings its own ledger: the shared
/// one is counting whatever else the suite happens to be asking of the stub at the same
/// moment, and a count nobody else can touch is the only one worth asserting on.
@Suite("Counting what we ask of other people's servers")
struct APILedgerTests {
    /// A launch in the past, on a minute boundary — minute boundaries are what the window
    /// is made of, and every clock in this suite is measured from here.
    let launch = Date(timeIntervalSince1970: 1_700_000_040)

    func url(_ host: String, _ path: String = "/api/v1/timelines/public") -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    // MARK: - Counted at the transport, where every request already passes

    @Test("A request that worked is one call and nothing failed")
    func aRequestThatWorkedIsOneCallAndNoFailure() async throws {
        let ledger = APILedger()
        stubRoutes.on("ledger-ok.test", "/api/v1/timelines/public", status: 200, body: oneStatusJSON)

        _ = try await JSONTransport.get(url("ledger-ok.test"), on: stubbedSession(), ledger: ledger)

        let usage = ledger.accounting().bySource["https://ledger-ok.test"]
        #expect(usage?.callsSinceStart == 1)
        #expect(usage?.failuresSinceStart == 0)
        #expect(usage?.successRate == 1)
    }

    /// A server refusing and a server breaking are different facts to the reader and the
    /// same fact to the ledger: we asked, and nothing usable came back.
    @Test("A server that refused is a call and a failure", arguments: [401, 404, 500])
    func aRefusedRequestIsACallAndAFailure(status: Int) async throws {
        let ledger = APILedger()
        let host = "ledger-refused-\(status).test"
        stubRoutes.on(host, "/api/v1/timelines/public", status: status)

        await #expect(throws: (any Error).self) {
            _ = try await JSONTransport.get(url(host), on: stubbedSession(), ledger: ledger)
        }

        let usage = ledger.accounting().bySource["https://\(host)"]
        #expect(usage?.callsSinceStart == 1)
        #expect(usage?.failuresSinceStart == 1)
        #expect(usage?.successRate == 0)
    }

    @Test("A connection that broke is a call and a failure too")
    func aConnectionThatBrokeIsACallAndAFailure() async throws {
        let ledger = APILedger()

        await #expect(throws: SourceFailure.self) {
            _ = try await JSONTransport.get(url("ledger-broken.test"), on: brokenSession(), ledger: ledger)
        }

        let usage = ledger.accounting().bySource["https://ledger-broken.test"]
        #expect(usage?.callsSinceStart == 1)
        #expect(usage?.failuresSinceStart == 1)
    }

    /// Signing in is still something asked of somebody else's machine, so it counts.
    @Test("Signing in counts: a form post is a request like any other")
    func aFormPostIsCountedToo() async throws {
        let ledger = APILedger()
        stubRoutes.on("ledger-post.test", "/oauth/token", status: 200, body: "{}")
        stubRoutes.on("ledger-post.test", "/oauth/revoke", status: 500, body: "{}")

        _ = try await JSONTransport.postForm(url("ledger-post.test", "/oauth/token"), fields: [:],
                                             on: stubbedSession(), ledger: ledger)
        await #expect(throws: SourceFailure.self) {
            _ = try await JSONTransport.postForm(url("ledger-post.test", "/oauth/revoke"), fields: [:],
                                                 on: stubbedSession(), ledger: ledger)
        }

        let usage = ledger.accounting().bySource["https://ledger-post.test"]
        #expect(usage?.callsSinceStart == 2)
        #expect(usage?.failuresSinceStart == 1)
    }

    /// Two servers are two accounts, not one column of requests.
    @Test("Two servers are counted apart, and the total is both of them")
    func eachServerIsCountedOnItsOwn() async throws {
        let ledger = APILedger()
        stubRoutes.on("ledger-a.test", "/api/v1/timelines/public", status: 200, body: oneStatusJSON)
        stubRoutes.on("ledger-b.test", "/api/v1/timelines/public", status: 500)
        let client = MastodonClient(session: stubbedSession(), ledger: ledger)

        _ = try await client.timeline(host: "ledger-a.test", limit: 5, token: nil)
        await #expect(throws: SourceFailure.self) {
            _ = try await client.timeline(host: "ledger-b.test", limit: 5, token: nil)
        }

        let accounting = ledger.accounting()
        #expect(accounting.bySource["https://ledger-a.test"]?.callsSinceStart == 1)
        #expect(accounting.bySource["https://ledger-a.test"]?.failuresSinceStart == 0)
        #expect(accounting.bySource["https://ledger-b.test"]?.callsSinceStart == 1)
        #expect(accounting.bySource["https://ledger-b.test"]?.failuresSinceStart == 1)
        #expect(accounting.total.callsSinceStart == 2)
        #expect(accounting.total.failuresSinceStart == 1)
        #expect(accounting.total.successRate == 0.5)
    }

    /// The address a call is filed under is the address that server's rows are filed under —
    /// for every protocol, not only the one this build happens to have an https client for.
    @Test("A call is filed under the address its server's rows are filed under")
    func aCallIsFiledUnderTheSameAddressAsItsServer() {
        #expect(Server.endpoint(of: url("Ledger-Case.test")) == makeServer("ledger-case.test").endpoint)
        let relay = URL(string: "wss://Relay.Ledger.test")!
        #expect(Server.endpoint(of: relay) == Server(host: "relay.ledger.test", socialProtocol: .nostr).endpoint)
    }

    // MARK: - Rates and the window, over a clock we hand it

    @Test("The success rate is the whole launch, not the last few minutes of it")
    func successRateIsTheWholeLaunchAndNotJustTheWindow() {
        let ledger = APILedger(windowMinutes: 2, startedAt: launch)
        // Three refusals an hour ago and one answer now: long out of the window, still counted.
        for _ in 0..<3 { ledger.record(endpoint: "https://a.test", failed: true, at: launch) }
        let later = launch.addingTimeInterval(3600)
        ledger.record(endpoint: "https://a.test", failed: false, at: later)

        let usage = ledger.accounting(now: later).bySource["https://a.test"]
        #expect(usage?.callsSinceStart == 4)
        #expect(usage?.failuresSinceStart == 3)
        #expect(usage?.succeededSinceStart == 1)
        #expect(usage?.successRate == 0.25)
    }

    @Test("Calls a minute averages over the minutes there have actually been")
    func callsPerMinuteAveragesOverTheMinutesThereHaveBeen() {
        let ledger = APILedger(windowMinutes: 15, startedAt: launch)
        // Four calls across four consecutive minutes, read at the fourth.
        for minute in 0..<4 {
            ledger.record(endpoint: "https://a.test", failed: false,
                          at: launch.addingTimeInterval(Double(minute) * 60))
        }
        let now = launch.addingTimeInterval(3 * 60)
        #expect(ledger.accounting(now: now).bySource["https://a.test"]?.callsPerMinute == 1)

        // Two more inside that same fourth minute: six calls over the four minutes there have been.
        ledger.record(endpoint: "https://a.test", failed: false, at: now)
        ledger.record(endpoint: "https://a.test", failed: true, at: now)
        #expect(ledger.accounting(now: now).bySource["https://a.test"]?.callsPerMinute == 1.5)
    }

    @Test("The window forgets what fell out of it, and stops holding it")
    func theWindowForgetsWhatFellOutOfIt() {
        let ledger = APILedger(windowMinutes: 3, startedAt: launch)
        for minute in 0..<10 {
            ledger.record(endpoint: "https://a.test", failed: false,
                          at: launch.addingTimeInterval(Double(minute) * 60))
        }
        let now = launch.addingTimeInterval(9 * 60)
        let usage = ledger.accounting(now: now).bySource["https://a.test"]

        // All ten calls stay on the lifetime count; the rate sees only the minutes it is
        // allowed to, and what it cannot see is not being kept either.
        #expect(usage?.callsSinceStart == 10)
        #expect(usage?.callsPerMinute == 1)
        #expect(ledger.retainedBuckets == 3)
    }

    /// A short launch reads as a short launch, not as a quiet one.
    @Test("A launch a minute old is not averaged over a window it never filled")
    func aRateFromOneMinuteDoesNotAverageOverTheWholeWindow() {
        let ledger = APILedger(windowMinutes: 15, startedAt: launch)
        for _ in 0..<5 { ledger.record(endpoint: "https://a.test", failed: false, at: launch) }

        #expect(ledger.accounting(now: launch).total.callsPerMinute == 5)
    }

    @Test("Nothing asked is nothing refused, not a rate of nothing over nothing")
    func aSourceNobodyAskedAnythingOfIsNotAFailure() {
        let empty = APILedger(startedAt: launch).accounting(now: launch)
        #expect(empty.bySource.isEmpty)
        #expect(empty.total.callsSinceStart == 0)
        // Not 100%: an address nobody has spoken to has no rate at all, and the screen shows
        // a dash rather than claiming everything went fine.
        #expect(empty.total.successRate == nil)
        #expect(empty.total.callsPerMinute == 0)
    }

    // MARK: - Nowhere but memory

    /// The counts are this launch's and no older. There is no store behind them, so a ledger
    /// made a moment after a busy one starts at nothing and dates itself from its own start.
    @Test("The counts live in the ledger and nowhere else, this launch and no further back")
    func nothingIsKeptAnywhereButThisLedger() async throws {
        let store = try LocalStore.inMemory()
        let ledger = APILedger(startedAt: launch)
        stubRoutes.on("ledger-memory.test", "/api/v1/timelines/public", status: 200, body: oneStatusJSON)
        let loader = TimelineLoader(
            registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession(), ledger: ledger)]),
            store: store, secrets: InMemorySecretStore()
        )

        _ = await loader.load(servers: [makeServer("ledger-memory.test")], mode: .timeline)
        #expect(ledger.accounting().total.callsSinceStart == 1)

        let fresh = APILedger()
        #expect(fresh.accounting().total.callsSinceStart == 0)
        #expect(fresh.startedAt > launch)
        #expect(ledger.accounting().startedAt == launch)

        // The posts were kept, as they should be; the counting left nothing of its own behind.
        let tables = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(!tables.contains { $0.contains("api") || $0.contains("ledger") })
    }
}
