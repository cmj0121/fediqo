import Foundation
import Testing
@testable import FediqoCore

/// Opening a person, and what it costs the people around them.
///
/// The assertions worth having here are about **which endpoint was reached and which was not**.
/// #88 settles that looking at somebody may not make the reader's server go and fetch them —
/// `/api/v1/accounts/lookup` answers about accounts a server already holds and 404s about
/// everybody else, while `/api/v2/search` answers the same question by introducing the two
/// servers first. Both would put a name on the screen. Only one of them does it without telling
/// anybody, and no assertion about the returned value can tell them apart.
@Suite("Opening somebody, and what it asks of whom")
struct PeopleTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/ada", token: "t")
    }

    private func person(_ id: String, _ acct: String) -> String {
        """
        { "id": "\(id)", "url": "https://cedar.example/@\(acct)", "username": "\(acct)",
          "acct": "\(acct)", "display_name": "Tove", "avatar": null,
          "statuses_count": 3, "followers_count": 2, "following_count": 1 }
        """
    }

    // MARK: - who they are

    @Test("Somebody a server knows is looked up, and nothing is searched for")
    func lookupNeverSearches() async throws {
        let host = "people-known.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 200, body: person("10", "tove"))

        let found = try await client.profile(handle: "@tove@cedar.example", host: host, token: nil)

        #expect(found?.id == "10")
        #expect(found?.authorId == "https://cedar.example/@tove")
        // The whole of the privacy design, as an assertion: no search was sent, so this server
        // was never asked to go and get anybody.
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
        // And the handle reached it bare, which is the form the endpoint takes.
        #expect(stubRoutes.requests(for: host, "/api/v1/accounts/lookup").first?.query["acct"]
                == "tove@cedar.example")
    }

    /// The ordinary state of a stranger on the reader's own server. It is an answer rather than
    /// a failure, and the page says so instead of showing an error.
    @Test("Somebody a server has never heard of is nothing, not an error")
    func unknownIsNil() async throws {
        let host = "people-unknown.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 404, body: "{}")

        let found = try await client.profile(handle: "@tove@cedar.example", host: host, token: nil)

        #expect(found == nil)
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
    }

    /// Everything that is not a 404 is a server having trouble, and is passed on rather than
    /// flattened into "does not know them" — which would tell a reader the wrong thing about
    /// somebody who is there.
    @Test("A server having trouble is not a server that does not know them")
    func troubleIsNotAbsence() async throws {
        let host = "people-trouble.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 503, body: "{}")

        await #expect(throws: SourceFailure.self) {
            _ = try await client.profile(handle: "@tove@cedar.example", host: host, token: nil)
        }
    }

    // MARK: - what they wrote

    @Test("Their posts are asked for without their replies, and paged like any other stretch")
    func postsExcludeReplies() async throws {
        let host = "people-posts.test"
        stubRoutes.on(host, "/api/v1/accounts/10/statuses", status: 200, body: "[]")

        _ = try await client.posts(by: "10", host: host, limit: 20, before: nil, token: nil)

        let asked = try #require(stubRoutes.requests(for: host, "/api/v1/accounts/10/statuses").first)
        #expect(asked.query["exclude_replies"] == "true")
        #expect(asked.query["limit"] == "20")
        // Nothing invents a cursor for the first page.
        #expect(asked.query["max_id"] == nil)
    }

    // MARK: - what you are to them

    @Test("A relationship is asked of the reader's own server, by the id that server uses")
    func relationshipIsLocal() async throws {
        let host = "people-rel.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 200, body: person("77", "tove"))
        stubRoutes.on(host, "/api/v1/accounts/relationships", status: 200,
                      body: "[{ \"id\": \"77\", \"following\": true, \"followed_by\": false }]")

        let what = try await client.relationship(with: "@tove@cedar.example", as: acting(on: host))

        #expect(what?.following == true)
        #expect(what?.isOn == true)
        #expect(stubRoutes.requests(for: host, "/api/v1/accounts/relationships").first?.query["id[]"]
                == "77")
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
    }

    /// Two facts that are the same shape and are not the same fact. A server that has never
    /// heard of somebody has not said the reader does not follow them.
    @Test("A server that does not know them answers nothing, not `not following`")
    func unknownRelationshipIsNil() async throws {
        let host = "people-rel-unknown.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 404, body: "{}")

        let what = try await client.relationship(with: "@tove@cedar.example", as: acting(on: host))

        #expect(what == nil)
        // And it did not go on to ask about a relationship with nobody.
        #expect(!stubRoutes.paths(for: host).contains("/api/v1/accounts/relationships"))
    }

    // MARK: - changing it

    @Test("Following somebody the server already knows sends one write and no search")
    func followKnownPerson() async throws {
        let host = "people-follow.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 200, body: person("77", "tove"))
        stubRoutes.on(host, "/api/v1/accounts/77/follow", status: 200,
                      body: "{ \"id\": \"77\", \"following\": true }")

        let now = try await client.setFollow(true, with: "@tove@cedar.example", as: acting(on: host))

        #expect(now.following)
        #expect(stubRoutes.requests(for: host, "/api/v1/accounts/77/follow").first?.method == "POST")
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
    }

    /// The one request on this page that is allowed to reach further than the reader has looked,
    /// and it happens on the press rather than on the glance.
    @Test("Following a stranger resolves them, which is the one fetch this page ever makes")
    func followStrangerResolves() async throws {
        let host = "people-follow-new.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 404, body: "{}")
        stubRoutes.on(host, "/api/v2/search", status: 200,
                      body: "{ \"accounts\": [{ \"id\": \"90\" }] }")
        stubRoutes.on(host, "/api/v1/accounts/90/follow", status: 200,
                      body: "{ \"id\": \"90\", \"following\": true }")

        let now = try await client.setFollow(true, with: "@tove@cedar.example", as: acting(on: host))

        #expect(now.following)
        // It resolved, and it resolved the way #46's comment says the endpoint has to be asked.
        #expect(stubRoutes.requests(for: host, "/api/v2/search").first?.query["resolve"] == "true")
    }

    /// A server that has never heard of somebody is not following them. Asking it to unfollow
    /// would be asking it to go and fetch a stranger in order to not follow them.
    @Test("Unfollowing somebody the server has never heard of asks nobody anything")
    func unfollowStrangerIsFree() async throws {
        let host = "people-unfollow-new.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 404, body: "{}")

        let now = try await client.setFollow(false, with: "@tove@cedar.example", as: acting(on: host))

        #expect(!now.following)
        #expect(!now.isOn)
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
    }

    /// What comes back is read rather than assumed. A locked account answers `requested`, and a
    /// control that took the press for an answer would announce an approval nobody has given.
    @Test("A locked account answers asked, and asked is not following")
    func lockedAccountAnswersRequested() async throws {
        let host = "people-locked.test"
        stubRoutes.on(host, "/api/v1/accounts/lookup", status: 200, body: person("77", "tove"))
        stubRoutes.on(host, "/api/v1/accounts/77/follow", status: 200,
                      body: "{ \"id\": \"77\", \"following\": false, \"requested\": true }")

        let now = try await client.setFollow(true, with: "@tove@cedar.example", as: acting(on: host))

        #expect(!now.following)
        #expect(now.requested)
        #expect(now.isOn)
    }
}
