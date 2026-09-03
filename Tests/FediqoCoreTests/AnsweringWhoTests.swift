import Foundation
import Testing
@testable import FediqoCore

/// Whom a post answers, where the post it answers is not here (#87).
///
/// A row already says that a post is an answer. Saying *whose* it is needs the post it answers,
/// and for a reply that arrived from a server the reader has not joined that post is not here and
/// never will be — which is the ordinary case rather than a corner of one.
///
/// **Both halves arrive in the status itself**: `in_reply_to_account_id`, and the `mentions` that
/// map that number to a handle. They are matched where they arrive, so nothing is fetched and no
/// server the reader has not added is asked anything. What is kept is the handle, because an
/// account id means something on one server and nothing anywhere else.
@Suite("Whom a post answers")
struct AnsweringWhoTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func status(on host: String, replyingTo account: String?,
                        naming mentions: [(id: String, acct: String)]) -> String {
        let named = mentions.map {
            """
            { "id": "\($0.id)", "url": "https://\(host)/@\($0.acct)",
              "username": "\($0.acct)", "acct": "\($0.acct)" }
            """
        }.joined(separator: ",")
        return """
        [{ "id": "9", "uri": "https://\(host)/users/a/statuses/9", "url": null,
           "created_at": "2026-09-03T10:00:00.000Z", "content": "<p>answering</p>",
           "in_reply_to_id": "8",
           "in_reply_to_account_id": \(account.map { "\"\($0)\"" } ?? "null"),
           "account": { "id": "1", "url": "https://\(host)/@a", "username": "a",
                        "acct": "a", "display_name": "A", "avatar": null },
           "mentions": [\(named)], "media_attachments": [], "tags": [] }]
        """
    }

    private func read(_ host: String, _ body: String) async throws -> Post? {
        stubRoutes.on(host, "/api/v1/timelines/public", status: 200, body: body)
        return try await client.timeline(host: host, limit: 20, before: nil, token: nil).first
    }

    /// The case this is for: a reply from a server the reader has not joined, whose parent is
    /// nowhere in the app. The status names the account it answers and names that account in its
    /// mentions, and the two are matched here.
    @Test("A reply says whom it answers, from what the status itself carries")
    func itSaysWhom() async throws {
        let host = "answering.test"
        let post = try await read(host, status(on: host, replyingTo: "42",
                                               naming: [("42", "tove"), ("7", "ines")]))

        #expect(post?.answering == "@tove@\(host)")
    }

    /// A remote account is spelled with its own host, the way every handle in this app is.
    @Test("Somebody on another server keeps their own host")
    func aremoteAccountKeepsItsHost() async throws {
        let host = "answering-remote.test"
        let body = status(on: host, replyingTo: "42", naming: [])
            .replacingOccurrences(of: "\"mentions\": []", with: """
            "mentions": [{ "id": "42", "url": "https://elsewhere.example/@wren",
                           "username": "wren", "acct": "wren@elsewhere.example" }]
            """)
        let post = try await read(host, body)

        #expect(post?.answering == "@wren@elsewhere.example")
    }

    /// Three different silences, and a row must not tell them apart by guessing.
    @Test("A post that answers nobody says nobody")
    func answeringNobody() async throws {
        let host = "answering-none.test"
        let body = status(on: host, replyingTo: nil, naming: [("7", "ines")])
            .replacingOccurrences(of: "\"in_reply_to_id\": \"8\",", with: "")
        #expect(try await read(host, body)?.answering == nil)
    }

    @Test("A server that did not say leaves it unsaid")
    func theServerDidNotSay() async throws {
        let host = "answering-silent.test"
        #expect(try await read(host, status(on: host, replyingTo: nil,
                                            naming: [("7", "ines")]))?.answering == nil)
    }

    /// The one that would tempt a guess: the id is there and nothing matches it, because the
    /// author took the mention out. Naming whoever happened to be first would be this app
    /// inventing who somebody was talking to.
    @Test("An id with no name against it is not guessed at")
    func anidWithNoNameIsNotGuessed() async throws {
        let host = "answering-gone.test"
        let post = try await read(host, status(on: host, replyingTo: "42",
                                               naming: [("7", "ines"), ("8", "wren")]))

        #expect(post?.answering == nil)
    }

    /// It survives being written down and read back, or a row would say whom a post answers
    /// until the app was closed.
    @Test("It is kept, and comes back")
    func itIsKept() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: "answering-store.example", socialProtocol: .mastodon)
        let post = makePost(uri: "https://answering-store.example/api/v1/statuses/1",
                            originURI: "https://answering-store.example/users/a/statuses/1",
                            at: 100)
        let answering = Post(uri: post.uri, originURI: post.originURI,
                             socialProtocol: .mastodon, sourceURL: post.sourceURL,
                             createdAt: post.createdAt, authorId: post.authorId,
                             authorName: post.authorName, authorHandle: post.authorHandle,
                             text: post.text, answering: "@tove@cedar.example")

        try await store.save([answering], from: server)

        let back = try await store.timeline(matching: TimelineQuery(source: .public)).first
        #expect(back?.answering == "@tove@cedar.example")
    }
}
