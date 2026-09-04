import Foundation
import Testing
@testable import FediqoCore

/// What somebody asked you to read first (#112).
@Suite("What somebody pinned")
struct PinnedPostsTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    /// A separate ask, and what makes it one: `pinned=true`, no `exclude_replies`, and no
    /// cursor. A pinned set is somebody's choice rather than a stretch of time, so there is no
    /// page before it to walk to — and Mastodon ignores paging here anyway.
    @Test("It asks for the pinned ones, and asks for no page of them")
    func whatIsAsked() async throws {
        let host = "pins.test"
        stubRoutes.on(host, "/api/v1/accounts/7/statuses", status: 200, body: "[]")

        _ = try await client.pinned(by: "7", host: host, token: nil)

        let sent = try #require(stubRoutes.requests(for: host, "/api/v1/accounts/7/statuses").first)
        #expect(sent.query["pinned"] == "true")
        #expect(sent.query["max_id"] == nil)
        // Not the other ask's parameter. A pinned reply is still pinned.
        #expect(sent.query["exclude_replies"] == nil)
    }

    /// Somebody who pinned nothing, which is most people. The page draws nothing rather than an
    /// empty band under a heading.
    @Test("Pinning nothing answers nothing")
    func pinnedNothing() async throws {
        let host = "empty.test"
        stubRoutes.on(host, "/api/v1/accounts/7/statuses", status: 200, body: "[]")
        #expect(try await client.pinned(by: "7", host: host, token: nil).isEmpty)
    }

    /// A protocol that cannot be asked answers the same thing a server does for somebody who
    /// pinned nothing — so the page draws the same thing either way and nothing has to know
    /// which of the two happened.
    @Test("A protocol with no pinning has no start-here to miss")
    func aprotocolWithoutPinning() async throws {
        #expect(try await Unpinnable().pinned(by: "7", host: "nowhere.example",
                                              token: nil).isEmpty)
    }

    private struct Unpinnable: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
