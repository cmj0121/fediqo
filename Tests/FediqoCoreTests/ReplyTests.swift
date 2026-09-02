import Foundation
import Testing
@testable import FediqoCore

/// Answering somebody, and the two things about it that are not like posting.
///
/// A reply is not a post that happens to mention a number. It goes to one account rather than to
/// every one the reader chose, and **it may not be heard by more people than the post it
/// answers** — which is the assertion in here worth having, because getting it wrong hands
/// somebody's private words to a public timeline and nothing on the screen would have said so.
@Suite("A reply, and how far it may reach")
struct ReplyTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/ada", token: "t")
    }

    /// A post as the acting server itself handed it over, so its own number is already in the
    /// address and nothing has to be looked up (#46).
    private func handedOver(_ id: String, from host: String, audience: Audience? = nil) -> Post {
        Post(uri: "https://\(host)/api/v1/statuses/\(id)", socialProtocol: .mastodon,
             sourceURL: "https://\(host)", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://\(host)/@tove", authorName: "Tove",
             authorHandle: "@tove@\(host)", text: "one", audience: audience)
    }

    // MARK: - how far it reaches

    /// The whole point. A reply to something only the people named in it can read is not a post
    /// for everybody, whatever the composer was last set to.
    @Test("A reply is never wider than what it answers")
    func neverWiderThanTheParent() {
        let private_ = handedOver("1", from: "h", audience: .mentioned)
        let draft = Draft(text: "quietly", audience: .everyone, answering: private_)

        #expect(draft.audience == .mentioned)
    }

    /// Narrower is the reader's to choose. Answering a public post privately is an ordinary
    /// thing to want, and this is not here to stop it.
    @Test("Narrower than what it answers is left alone")
    func narrowerIsKept() {
        let open = handedOver("1", from: "h", audience: .everyone)
        let draft = Draft(text: "just you", audience: .mentioned, answering: open)

        #expect(draft.audience == .mentioned)
    }

    /// Every step of the ladder, so that a future reordering of the enum cannot quietly widen
    /// anything: the order of `Audience` is the fact this rests on.
    @Test("Every pair takes the narrower of the two", arguments: [
        (Audience.everyone, Audience.unlisted, Audience.unlisted),
        (Audience.everyone, Audience.followers, Audience.followers),
        (Audience.unlisted, Audience.followers, Audience.followers),
        (Audience.followers, Audience.mentioned, Audience.mentioned),
        (Audience.mentioned, Audience.everyone, Audience.mentioned),
        (Audience.followers, Audience.followers, Audience.followers),
    ])
    func theLadder(chosen: Audience, parent: Audience, expected: Audience) {
        #expect(Audience.narrower(of: chosen, parent) == expected)
    }

    /// Every post stored before 009, and every protocol with no such idea. There is nothing to
    /// be narrower than, and guessing either way is a mistake: `mentioned` would quietly make a
    /// public answer private, and `everyone` is the thing this rule exists to prevent.
    @Test("A post that never said how far it reached leaves the reader's own choice standing")
    func unknownParentAudienceKeepsTheChoice() {
        let silent = handedOver("1", from: "h", audience: nil)
        let draft = Draft(text: "hello", audience: .followers, answering: silent)

        #expect(draft.audience == .followers)
    }

    // MARK: - what is sent

    @Test("It carries the acting server's own number for what it answers")
    func sendsInReplyTo() async throws {
        let host = "reply-send.test"
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
        { "id": "9", "uri": "https://\(host)/users/ada/statuses/9", "url": null,
          "created_at": "2026-09-02T10:00:00.000Z", "content": "<p>yes</p>",
          "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                       "acct": "ada", "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": [] }
        """)
        let parent = handedOver("42", from: host)

        _ = try await client.publish(Draft(text: "yes", answering: parent), as: acting(on: host))

        let asked = try #require(stubRoutes.requests(for: host, "/api/v1/statuses").first)
        #expect(asked.fields["in_reply_to_id"] == "42")
        // The post's own server handed it over, so its number was already in the address and
        // nothing was searched for.
        #expect(!stubRoutes.paths(for: host).contains("/api/v2/search"))
    }

    @Test("A post with nothing to answer carries no reply at all")
    func plainPostCarriesNothing() async throws {
        let host = "reply-plain.test"
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
        { "id": "9", "uri": "https://\(host)/users/ada/statuses/9", "url": null,
          "created_at": "2026-09-02T10:00:00.000Z", "content": "<p>hi</p>",
          "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                       "acct": "ada", "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": [] }
        """)

        _ = try await client.publish(Draft(text: "hi"), as: acting(on: host))

        #expect(stubRoutes.requests(for: host, "/api/v1/statuses").first?.fields["in_reply_to_id"] == nil)
    }

    /// A reply to a post the acting server has never heard of. It is refused rather than sent
    /// without its `in_reply_to_id` — a post that was meant as an answer and arrives as an
    /// announcement is worse than one that did not arrive, and nobody would be told.
    @Test("A reply the server cannot place is refused, not sent as a post of its own")
    func unplaceableReplyIsRefused() async throws {
        let host = "reply-elsewhere.test"
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: "{}")
        let elsewhere = handedOver("42", from: "other.example")

        await #expect(throws: SourceFailure.self) {
            _ = try await client.publish(Draft(text: "yes", answering: elsewhere),
                                         as: acting(on: host))
        }
        #expect(stubRoutes.requests(for: host, "/api/v1/statuses").isEmpty)
    }

    // MARK: - joining the conversation it answered

    @Test("An answer joins the conversation without anybody being asked again")
    func replyJoinsTheThread() {
        let root = handedOver("1", from: "h")
        let reply = handedOver("2", from: "h")
        let thread = Conversation(post: root).with(reply)

        #expect(thread.descendants.map(\.uri) == [reply.uri])
    }

    /// A refresh landing between the send and this would otherwise leave the answer in the
    /// conversation twice.
    @Test("An answer already there does not arrive a second time")
    func replyIsNotDoubled() {
        let root = handedOver("1", from: "h")
        let reply = handedOver("2", from: "h")
        let thread = Conversation(post: root, descendants: [reply]).with(reply)

        #expect(thread.descendants.count == 1)
    }
}
