import Foundation
import Testing
@testable import FediqoCore

/// The timeline is the timeline. A server that will not publish one contributes nothing, and
/// is never topped up with whatever else it was willing to hand over.
@Suite("The timeline never stands in something else for itself")
struct TimelineNoFallbackTests {
    @Test("A server that refuses the public timeline yields nothing, and trends are not asked for")
    func refusalIsNotPapered() async {
        let host = "refuses.test"
        let server = makeServer(host)
        stubRoutes.on(host, "/api/v1/timelines/public", status: 401)
        stubRoutes.on(host, "/api/v1/trends/statuses", status: 200, body: oneStatusJSON)

        let result = await stubbedLoader().load(servers: [server], query: .publicPosts)

        #expect(result.posts.isEmpty)
        #expect(result.failures[server.endpoint] == SourceFailure.needsSignIn(host))
        #expect(stubRoutes.paths(for: host) == ["/api/v1/timelines/public"])
    }

    @Test("One server refusing does not silence the ones that did not")
    func refusalIsPerServer() async {
        let shut = makeServer("shut.test")
        let open = makeServer("open.test")
        stubRoutes.on(shut.host, "/api/v1/timelines/public", status: 401)
        stubRoutes.on(open.host, "/api/v1/timelines/public", status: 200, body: oneStatusJSON)

        let result = await stubbedLoader().load(servers: [shut, open], query: .publicPosts)

        #expect(result.posts.map(\.sources) == [[open.host]])
        #expect(result.failures.keys.sorted() == [shut.endpoint])
    }

    @Test("Trending asks for trends, and only for trends")
    func trendingIsItsOwnRequest() async {
        let host = "trends.test"
        stubRoutes.on(host, "/api/v1/trends/statuses", status: 200, body: oneStatusJSON)

        let result = await stubbedLoader().load(servers: [makeServer(host)], query: .trending)

        #expect(result.posts.count == 1)
        #expect(stubRoutes.paths(for: host) == ["/api/v1/trends/statuses"])
    }

    @Test("A server that is simply broken says so as itself, not as a refusal")
    func brokenIsNotRefusal() async {
        let server = makeServer("broken.test")
        stubRoutes.on(server.host, "/api/v1/timelines/public", status: 503, body: "gateway wept")

        let result = await stubbedLoader().load(servers: [server], query: .publicPosts)

        #expect(result.failures[server.endpoint] == SourceFailure.http(503, Data("gateway wept".utf8)))
    }

    @Test("Asking with no servers asks nothing of anyone")
    func noServers() async {
        let result = await stubbedLoader().load(servers: [], query: .publicPosts)
        #expect(result.isEmpty)
        #expect(result.failures.isEmpty)
    }
}
