import Foundation
import Testing
@testable import FediqoCore

/// What a post says now (#125).
@Suite("Asking a post again")
struct RereadPostTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func post(on host: String) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/9",
                 originURI: "https://\(host)/users/a/statuses/9", at: 1, from: host,
                 text: "what it said when it was opened")
    }

    private func answer(_ text: String, favourites: Int) -> String {
        """
        {"id": "9", "uri": "https://again.reread.test/users/a/statuses/9",
         "url": "https://again.reread.test/@a/9", "created_at": "2026-01-01T00:00:00.000Z",
         "content": "<p>\(text)</p>", "media_attachments": [],
         "favourites_count": \(favourites),
         "account": {"id": "1", "acct": "a@again.reread.test", "username": "a",
                     "display_name": "A", "url": "https://again.reread.test/@a"}}
        """
    }

    /// **The whole of it.** This request was already being made and its answer thrown away:
    /// `stillHas` kept only whether it 404'd, and the words and the counts went with the body.
    @Test("It answers with what the post says now, not with what it said")
    func whatItSaysNow() async throws {
        let host = "again.reread.test"
        stubRoutes.on(host, "/api/v1/statuses/9", status: 200,
                      body: answer("what it says now", favourites: 41))

        let fresh = try await client.status(of: post(on: host), host: host, token: nil)
        #expect(fresh.text == "what it says now")
        #expect(fresh.counts.favourites == 41)
    }

    /// And the one that reads it is still right about the one thing it used to be right about.
    @Test("A post that has gone is still known to have gone")
    func agonePost() async throws {
        for status in [404, 410] {
            let host = "gone\(status).reread.test"
            stubRoutes.on(host, "/api/v1/statuses/9", status: status, body: "{}")
            #expect(try await client.stillHas(post(on: host), host: host, token: nil) == false)
        }
    }

    /// A server refusing to discuss a post is not a server saying it is gone. Reading one as the
    /// other would turn every private post into a deleted one.
    @Test("A refusal is not a deletion")
    func arefusalIsNotADeletion() async throws {
        let host = "refuses.reread.test"
        stubRoutes.on(host, "/api/v1/statuses/9", status: 403, body: "{}")
        await #expect(throws: (any Error).self) {
            try await client.stillHas(post(on: host), host: host, token: nil)
        }
    }

    /// A protocol that cannot be asked says so rather than handing back the post it was given —
    /// which would look exactly like a server saying nothing had changed.
    @Test("A protocol that cannot be asked does not echo the post back")
    func doesNotEcho() async throws {
        let given = post(on: "nowhere.example")
        await #expect(throws: (any Error).self) {
            try await Unaskable().status(of: given, host: "nowhere.example", token: nil)
        }
    }

    /// The conversation takes a newer reading of its own post, and only of its own: a fresher
    /// copy of some other post is not this conversation's business.
    @Test("A conversation replaces its own post and no other")
    func replacingItsOwn() {
        let mine = post(on: "again.reread.test")
        let conversation = Conversation(post: mine)
        let fresher = makePost(uri: mine.uri, originURI: mine.originURI, at: 2, from: "again.reread.test",
                               text: "edited")
        #expect(conversation.replacing(fresher).post.text == "edited")

        let somebodyElses = makePost(uri: "https://again.reread.test/api/v1/statuses/8", at: 1,
                                     from: "again.reread.test", text: "not this one")
        #expect(conversation.replacing(somebodyElses).post.text == mine.text)
    }

    private struct Unaskable: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
