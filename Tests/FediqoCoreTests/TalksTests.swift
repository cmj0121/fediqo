import Foundation
import Testing
@testable import FediqoCore

/// Who you are talking to (#109).
///
/// The reading that is not a timeline. What is asserted here is mostly what it does *not* do.
@Suite("Who you are talking to")
struct TalksTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/me", token: "t")
    }

    private func body(unread: Bool, withLast: Bool) -> String {
        let last = withLast ? """
        , "last_status": {"id": "9", "uri": "https://talks.test/users/a/statuses/9",
          "created_at": "2026-01-01T00:00:00.000Z", "content": "<p>see you then</p>",
          "media_attachments": [],
          "account": {"id": "1", "acct": "a@talks.test", "username": "a",
                      "display_name": "A", "url": "https://talks.test/@a"}}
        """ : ""
        return """
        [{"id": "5", "unread": \(unread),
          "accounts": [{"id": "1", "acct": "a@talks.test", "username": "a",
                        "display_name": "A", "url": "https://talks.test/@a"}]\(last)}]
        """
    }

    @Test("A conversation is the people in it, what was last said, and whether it is read")
    func whatAconversationIs() async throws {
        let host = "talks.test"
        stubRoutes.on(host, "/api/v1/conversations", status: 200, body: body(unread: true, withLast: true))

        let talk = try #require(try await client.conversations(as: account(host)).first)
        #expect(talk.id == "5")
        #expect(talk.host == host)
        #expect(talk.people.map(\.handle) == ["@a@talks.test"])
        #expect(talk.last?.text == "see you then")
        #expect(talk.unread)
    }

    /// A conversation whose last post has been deleted is still a conversation, and the page
    /// says so rather than dropping it or inventing a line.
    @Test("A conversation with nothing left in it is still a conversation")
    func withNothingLeft() async throws {
        let host = "gone.talks.test"
        stubRoutes.on(host, "/api/v1/conversations", status: 200, body: body(unread: false, withLast: false))

        let talk = try #require(try await client.conversations(as: account(host)).first)
        #expect(talk.last == nil)
        #expect(!talk.unread)
    }

    /// **Unread is the server's answer, not this app's guess.** Read is a fact about an account
    /// rather than about a device: a reader who read it on their phone has read it.
    @Test("Unread is what the server said")
    func unreadIsTheirs() async throws {
        for unread in [true, false] {
            let host = "read\(unread).talks.test"
            stubRoutes.on(host, "/api/v1/conversations", status: 200,
                          body: body(unread: unread, withLast: true))
            #expect(try await client.conversations(as: account(host)).first?.unread == unread)
        }
    }

    /// A protocol with no private conversations has none to list, and empty is the true answer
    /// rather than a refusal — unlike the unsent posts, where nobody having looked and nothing
    /// being queued are different facts a reader is shown differently.
    @Test("A protocol with no conversations has none, and that is an answer")
    func aprotocolWithout() async throws {
        #expect(try await Unspoken().conversations(as: account("nowhere.example")).isEmpty)
    }

    private struct Unspoken: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
