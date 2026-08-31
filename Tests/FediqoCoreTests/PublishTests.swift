import Foundation
import Testing
@testable import FediqoCore

/// Sending a post, and what comes back of it.
@Suite("A post that leaves")
struct PublishTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")
    }

    private func answered(_ host: String, id: String = "9") {
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
        {
          "id": "\(id)",
          "uri": "https://\(host)/users/ada/statuses/\(id)",
          "url": "https://\(host)/@ada/\(id)",
          "created_at": "2026-08-31T10:00:00.000Z",
          "content": "<p>hello</p>",
          "visibility": "private",
          "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada", "acct": "ada",
                       "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": []
        }
        """)
    }

    @Test("What was written is what is sent, with who it is for")
    func theDraftIsWhatGoes() async throws {
        let host = "publish-one.test"
        answered(host)

        _ = try await client.publish(Draft(text: "hello", audience: .followers), as: acting(on: host))

        let sent = try #require(stubRoutes.requests(for: host, "/api/v1/statuses").first)
        #expect(sent.method == "POST")
        #expect(sent.fields["status"] == "hello")
        #expect(sent.fields["visibility"] == "private")
        // Told nothing about a warning, which is not the same as told there is an empty one.
        #expect(sent.fields["spoiler_text"] == nil)
    }

    @Test("A warning goes when there is one, and a warning of spaces is not one")
    func theWarningIsAWarningOrNothing() async throws {
        let host = "publish-warning.test"
        answered(host)
        _ = try await client.publish(Draft(text: "hello", warning: "  bones  "), as: acting(on: host))
        #expect(stubRoutes.requests(for: host, "/api/v1/statuses").first?.fields["spoiler_text"] == "bones")

        let quiet = "publish-quiet.test"
        answered(quiet)
        _ = try await client.publish(Draft(text: "hello", warning: "   "), as: acting(on: quiet))
        #expect(stubRoutes.requests(for: quiet, "/api/v1/statuses").first?.fields["spoiler_text"] == nil)
    }

    /// The answer is a post, not a receipt: the reader's own timeline should have it now, and
    /// with the same shape as everything beside it.
    @Test("What comes back is a post like any other")
    func theAnswerIsAPost() async throws {
        let host = "publish-back.test"
        answered(host)

        let post = try await client.publish(Draft(text: "hello"), as: acting(on: host))

        #expect(post.text == "hello")
        #expect(post.uri == "https://\(host)/api/v1/statuses/9")
        #expect(post.originURI == "https://\(host)/users/ada/statuses/9")
        #expect(post.audience == .followers)   // the server's word for it, read back
        #expect(post.sources == [host])
    }

    /// The one failure a composer must not have: a request that arrived and whose answer did
    /// not. The header is what Mastodon offers for it, and the same draft carries the same key.
    @Test("The same draft carries the same key, and a different one does not")
    func sendingTwiceIsNotPostingTwice() async throws {
        let host = "publish-key.test"
        answered(host)
        let account = acting(on: host)

        _ = try await client.publish(Draft(text: "hello"), as: account)
        _ = try await client.publish(Draft(text: "hello"), as: account)
        _ = try await client.publish(Draft(text: "something else"), as: account)

        let keys = stubRoutes.requests(for: host, "/api/v1/statuses").map(\.idempotency)
        #expect(keys.allSatisfy { $0 != nil })
        #expect(keys[0] == keys[1])
        #expect(keys[0] != keys[2])
    }

    /// Whitespace is not a post, and the round trip would only be a slower way of saying so.
    @Test("A draft with nothing in it never leaves")
    func nothingIsNotSent() async throws {
        let host = "publish-empty.test"
        let actions = PostActions(registry: SourceRegistry(clients: [.mastodon: client]))

        await #expect(throws: SourceFailure.emptyDraft) {
            try await actions.publish(Draft(text: "   \n  "), as: acting(on: host))
        }
        #expect(stubRoutes.paths(for: host).isEmpty)
    }

    /// It lands in the store as an arrival from that server, into the feed a home timeline
    /// lands in — so the reader's own timeline has it without waiting for a refresh.
    @Test("What was sent is kept, and is in the reader's own timeline")
    func itIsKept() async throws {
        let host = "publish-kept.test"
        answered(host)
        let store = try LocalStore.inMemory()
        let actions = PostActions(registry: SourceRegistry(clients: [.mastodon: client]), store: store)

        let post = try await actions.publish(Draft(text: "hello"), as: acting(on: host))

        #expect(try await store.posts(named: [post.mergeKey]).first?.post.text == "hello")
        #expect(try await count(store, """
            SELECT count(*) FROM post_origins WHERE merge_key = ? AND feed = 'home'
            """, [post.mergeKey]) == 1)
    }
}
