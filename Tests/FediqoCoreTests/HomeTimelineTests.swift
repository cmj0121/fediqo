import Foundation
import Testing
@testable import FediqoCore

/// A home timeline is the one reading that cannot be had as nobody, and the one whose posts
/// are filed under whoever read them.
@Suite("A home timeline is somebody's, or it is nothing")
struct HomeTimelineTests {
    private let home = "/api/v1/timelines/home"
    private let publicTimeline = "/api/v1/timelines/public"

    @Test("A server with an account on it is asked for its home timeline, as that account")
    func signedInReadsHome() async throws {
        let host = "home-read.test"
        let server = makeServer(host)
        stubRoutes.on(host, home, status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        try await signInRows("t0ken", to: server, store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets)

        let result = await loader.load(servers: [server], query: .home)

        #expect(result.posts.count == 1)
        #expect(result.failures.isEmpty)
        #expect(stubRoutes.requests(for: host, home).map(\.authorization) == ["Bearer t0ken"])
        // And it was filed under the reader, which is what makes a second account's home a
        // second timeline rather than more of this one.
        let reader = "\(server.endpoint)/@ada"
        #expect(try await count(store, """
            SELECT count(*) FROM post_origins WHERE feed = 'home' AND author_id = ?
            """, [reader]) == 1)
    }

    @Test("A server nobody is signed in to is told so, and is not handed its public timeline instead")
    func nobodySignedInIsSaidRatherThanSubstituted() async throws {
        let host = "home-stranger.test"
        let server = makeServer(host)
        stubRoutes.on(host, home, status: 200, body: oneStatusJSON)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let loader = stubbedLoader(store: try LocalStore.inMemory())

        let result = await loader.load(servers: [server], query: .home)

        #expect(result.posts.isEmpty)
        #expect(result.failures[server.endpoint] == .needsSignIn(host))
        // Nothing was sent anywhere: not to home, which needs a credential, and above all not
        // to the public timeline, which is a different timeline and not a substitute for one.
        #expect(stubRoutes.paths(for: host).isEmpty)
    }

    @Test("A credential the server turns down is not retried as a stranger")
    func aRefusedTokenIsNotAnonymised() async throws {
        let host = "home-refused.test"
        let server = makeServer(host)
        stubRoutes.on(host, home, status: 401)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        try await signInRows("stale", to: server, store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets)

        let result = await loader.load(servers: [server], query: .home)

        #expect(result.posts.isEmpty)
        #expect(result.failures[server.endpoint] == .tokenRejected(host))
        // A public read would have been a different timeline wearing this one's name.
        #expect(stubRoutes.paths(for: host) == [home])
    }
}
