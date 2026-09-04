import Foundation
import Testing
@testable import FediqoCore

/// Who is waiting, and what the reader subscribed to (#114).
@Suite("Waiting, and subscribed")
struct SubscriptionsTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/me", token: "t")
    }

    private func someone(_ host: String) -> String {
        """
        [{"id": "7", "acct": "a@\(host)", "username": "a", "display_name": "A",
          "url": "https://\(host)/@a"}]
        """
    }

    @Test("Who is waiting is asked of the account and nobody else")
    func whoIsWaiting() async throws {
        let host = "waiting.subs.test"
        stubRoutes.on(host, "/api/v1/follow_requests", status: 200, body: someone(host))
        let people = try await client.followRequests(as: account(host))
        #expect(people.map(\.handle) == ["@a@\(host)"])
    }

    /// **Two answers and no third.** Each is its own endpoint, and sending one where the other
    /// was meant is not a mistake anybody can take back.
    @Test("Yes and no are two different requests", arguments: [true, false])
    func yesAndNo(accept: Bool) async throws {
        let host = "answer\(accept).subs.test"
        // The id on the server being told is found the way a mute finds it: `/api/v2/search`,
        // which is what `searchAccount` asks and why this route is here.
        stubRoutes.on(host, "/api/v2/search", status: 200,
                      body: #"{"accounts": [{"id": "7"}], "statuses": [], "hashtags": []}"#)
        let verb = accept ? "authorize" : "reject"
        stubRoutes.on(host, "/api/v1/follow_requests/7/\(verb)", status: 200, body: "{}")

        try await client.answerFollowRequest(
            Profile(id: "7", authorId: "7", name: "A", handle: "@a@\(host)"),
            accept: accept, as: account(host))

        #expect(stubRoutes.paths(for: host).contains("/api/v1/follow_requests/7/\(verb)"))
        // And not the other one. There is no request that means "either".
        let theOther = accept ? "reject" : "authorize"
        #expect(!stubRoutes.paths(for: host).contains("/api/v1/follow_requests/7/\(theOther)"))
    }

    /// A followed `#Swift` and a timeline made of `swift` are recognisably the same subject, so
    /// what comes back is kept the one way this store keeps a tag.
    @Test("A followed hashtag is kept the way tags are kept")
    func afollowedTag() async throws {
        let host = "tags.subs.test"
        stubRoutes.on(host, "/api/v1/followed_tags", status: 200,
                      body: #"[{"name": "Swift"}, {"name": "slowWeb"}]"#)
        #expect(try await client.followedTags(as: account(host)) == ["swift", "slowweb"])
    }

    /// The name and not an id, because a hashtag has no id anywhere — and it is escaped, because
    /// a normalised tag is still somebody else's text.
    @Test("Letting a hashtag go names it in the address")
    func unfollowingATag() async throws {
        let host = "untag.subs.test"
        stubRoutes.on(host, "/api/v1/tags/libraries/unfollow", status: 200, body: "{}")
        try await client.unfollowTag("libraries", as: account(host))
        #expect(stubRoutes.paths(for: host) == ["/api/v1/tags/libraries/unfollow"])
    }

    @Test("Lists carry the server that keeps them")
    func listsCarryTheirServer() async throws {
        let host = "lists.subs.test"
        stubRoutes.on(host, "/api/v1/lists", status: 200,
                      body: #"[{"id": "1", "title": "People who make things"}]"#)
        let made = try await client.lists(as: account(host))
        #expect(made.map(\.title) == ["People who make things"])
        // A reader signed in to three servers has three sets of lists, and they are not one.
        #expect(made.map(\.host) == [host])
    }

    /// A protocol with no such thing has none to list — but answering one it does not have is
    /// refused rather than quietly doing nothing, because *nothing happened* and *it worked*
    /// must not look the same to somebody waiting on the other end of it.
    @Test("Nothing to list is an answer; nothing done is not")
    func nothingToList() async throws {
        let bare = Bare()
        #expect(try await bare.followRequests(as: account("nowhere.example")).isEmpty)
        #expect(try await bare.followedTags(as: account("nowhere.example")).isEmpty)
        #expect(try await bare.lists(as: account("nowhere.example")).isEmpty)
        await #expect(throws: (any Error).self) {
            try await bare.answerFollowRequest(
                Profile(id: "1", authorId: "1", name: "A", handle: "@a@nowhere.example"),
                accept: true, as: account("nowhere.example"))
        }
    }

    private struct Bare: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
