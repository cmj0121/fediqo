import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Everything one signed-in read stands on: the rows that say who is signed in where, the
/// secret store that says what proves it, and a loader wired to both through the stub.
private struct Owned {
    let store: LocalStore
    let secrets = InMemorySecretStore()
    let loader: TimelineLoader

    init() throws {
        store = try LocalStore.inMemory()
        loader = stubbedLoader(store: store, secrets: secrets)
    }

    /// One account signed in to `server`, without the handshake — see `signInRows`.
    func signIn(_ token: String, to server: Server) async throws {
        try await signInRows(token, to: server, store: store, secrets: secrets)
    }
}

/// A read of a server you signed in to goes out as you; a token the server has stopped
/// accepting costs you the account, never the column.
@Suite("A timeline read as whoever you signed in as")
struct TimelineTokenTests {
    private let publicTimeline = "/api/v1/timelines/public"
    private let trends = "/api/v1/trends/statuses"

    @Test("A signed-in server is read as its account: the token rides along, the posts arrive")
    func signedInReadCarriesTheToken() async throws {
        let host = "carries.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let owned = try Owned()
        try await owned.signIn("t0ken", to: server)

        let result = await owned.loader.load(servers: [server], query: .publicPosts)

        #expect(result.posts.count == 1)
        #expect(result.failures.isEmpty)
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer t0ken"])
    }

    @Test("Trending is read as the account too")
    func trendingCarriesTheToken() async throws {
        let host = "carries-trends.test"
        let server = makeServer(host)
        stubRoutes.on(host, trends, status: 200, body: oneStatusJSON)
        let owned = try Owned()
        try await owned.signIn("t0ken", to: server)

        let result = await owned.loader.load(servers: [server], query: .trending)

        #expect(result.posts.count == 1)
        #expect(stubRoutes.requests(for: host, trends).map(\.authorization) == ["Bearer t0ken"])
    }

    @Test("A server nobody is signed in to is read as a stranger")
    func strangerCarriesNothing() async throws {
        let host = "stranger.test"
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let owned = try Owned()

        let result = await owned.loader.load(servers: [makeServer(host)], query: .publicPosts)

        #expect(result.posts.count == 1)
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == [nil])
    }

    @Test("A loader without a store is signed in to nobody, so it asks as nobody")
    func withoutAStoreNoTokenIsResolved() async {
        let host = "storeless.test"
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)

        let result = await stubbedLoader().load(servers: [makeServer(host)], query: .publicPosts)

        #expect(result.posts.count == 1)
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == [nil])
    }

    @Test("A token the server turns down is asked again as a stranger, and those posts are the ones you see")
    func rejectedTokenFallsBackToAnonymous() async throws {
        let host = "stale.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        stubRoutes.onAuthorized(host, publicTimeline, status: 401)
        let owned = try Owned()
        try await owned.signIn("expired", to: server)

        let result = await owned.loader.load(servers: [server], query: .publicPosts)

        // Two requests, the second as nobody — and the failure still names the token, so a
        // screen marks the account while showing the posts that did arrive.
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer expired", nil])
        #expect(result.posts.map(\.sources) == [[host]])
        #expect(result.failures[server.endpoint] == SourceFailure.tokenRejected(host))
        #expect(try await owned.store.timeline().count == 1)
    }

    @Test("A stranger turned away is asked once: there was no token for the retry to drop")
    func refusedStrangerIsNotAskedTwice() async throws {
        // What that refusal is called is `TimelineNoFallbackTests`' business; here it is only
        // whether the anonymous retry fires for a read that was already anonymous.
        let host = "shut-out.test"
        stubRoutes.on(host, publicTimeline, status: 401)
        let owned = try Owned()

        _ = await owned.loader.load(servers: [makeServer(host)], query: .publicPosts)

        #expect(stubRoutes.requests(for: host, publicTimeline).count == 1)
    }

    @Test("422 is the request being refused, not the token, even when a token was sent")
    func unprocessableIsNotARejectedToken() async throws {
        let host = "unprocessable.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 422)
        let owned = try Owned()
        try await owned.signIn("t0ken", to: server)

        let result = await owned.loader.load(servers: [server], query: .publicPosts)

        // Nothing about the credential was said, so nothing is retried and no account is marked.
        #expect(result.failures[server.endpoint] == SourceFailure.needsSignIn(host))
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer t0ken"])
    }

    @Test("When the anonymous retry is refused too, that refusal is what is reported")
    func retryFailureIsWhatIsReported() async throws {
        let host = "shut-both-ways.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 403)
        stubRoutes.onAuthorized(host, publicTimeline, status: 401)
        let owned = try Owned()
        try await owned.signIn("expired", to: server)

        let result = await owned.loader.load(servers: [server], query: .publicPosts)

        #expect(result.posts.isEmpty)
        #expect(result.failures[server.endpoint] == SourceFailure.needsSignIn(host))
        #expect(stubRoutes.requests(for: host, publicTimeline).count == 2)
    }

    @Test("One hostname, two protocols: the rejection lands on the endpoint that earned it")
    func rejectionIsPerEndpointNotPerHost() async throws {
        let host = "both-ways.test"
        let signedIn = Server(host: host, socialProtocol: .mastodon, title: host)
        // The same hostname, taken as a second kind of source. Its endpoint is `wss://`, so
        // it is a different server — nobody is signed in to it and nothing rejected it.
        let alsoNostr = Server(host: host, socialProtocol: .nostr, title: host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        stubRoutes.onAuthorized(host, publicTimeline, status: 401)
        let owned = try Owned()
        try await owned.signIn("expired", to: signedIn)
        // One client, two protocols, so both rows actually read rather than one of them
        // failing as `.unsupported` and muddying what `failures` is being asked to prove.
        let client = MastodonClient(session: stubbedSession())
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client, .nostr: client]),
                                    store: owned.store, secrets: owned.secrets)

        let result = await loader.load(servers: [signedIn, alsoNostr], query: .publicPosts)

        // Keyed by endpoint, the two fates stay apart: only the Mastodon row is marked, and
        // the Nostr row on the same hostname is left alone.
        #expect(result.failures.keys.sorted() == [signedIn.endpoint])
        #expect(result.failures[signedIn.endpoint] == SourceFailure.tokenRejected(host))
        #expect(result.failures[alsoNostr.endpoint] == nil)
    }

    @Test("One server's stale token neither silences nor infects another server")
    func rejectionIsPerServer() async throws {
        let stale = makeServer("stale-one.test")
        let open = makeServer("open-one.test")
        stubRoutes.on(stale.host, publicTimeline, status: 200, body: oneStatusJSON)
        stubRoutes.onAuthorized(stale.host, publicTimeline, status: 401)
        stubRoutes.on(open.host, publicTimeline, status: 200, body: oneStatusJSON)
        let owned = try Owned()
        try await owned.signIn("expired", to: stale)

        let result = await owned.loader.load(servers: [stale, open], query: .publicPosts)

        #expect(result.failures.keys.sorted() == [stale.endpoint])
        #expect(stubRoutes.requests(for: open.host, publicTimeline).map(\.authorization) == [nil])
    }
}
