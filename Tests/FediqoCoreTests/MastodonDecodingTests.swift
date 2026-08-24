import Foundation
import Testing
@testable import FediqoCore

@Suite("A Mastodon status becomes one timeline row")
struct MastodonDecodingTests {
    private let json = """
    [
      {
        "id": "1",
        "uri": "https://one.example/users/a/statuses/1",
        "url": "https://one.example/@a/1",
        "created_at": "2026-08-21T10:00:00.000Z",
        "in_reply_to_id": "7",
        "content": "<p>hello &amp; welcome</p>",
        "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": "https://one.example/a.png" },
        "media_attachments": [
          { "type": "image", "url": "https://one.example/full.png", "preview_url": "https://one.example/small.png" }
        ],
        "tags": [ { "name": "Swift", "url": "https://one.example/tags/swift" }, { "name": "swift", "url": "https://one.example/tags/swift" } ]
      },
      {
        "id": "2",
        "uri": "https://one.example/users/b/statuses/2/activity",
        "url": null,
        "created_at": "2026-08-21T11:00:00Z",
        "in_reply_to_id": null,
        "content": "",
        "account": { "id": "11", "url": "https://one.example/@b", "username": "b", "acct": "b", "display_name": "", "avatar": null },
        "media_attachments": [],
        "tags": [],
        "reblog": {
          "id": "1",
          "uri": "https://one.example/users/a/statuses/1",
          "url": "https://one.example/@a/1",
          "created_at": "2026-08-21T10:00:00.000Z",
          "in_reply_to_id": "7",
          "content": "<p>hello &amp; welcome</p>",
          "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
          "media_attachments": [],
          "tags": [ { "name": "Swift", "url": "https://one.example/tags/swift" } ]
        }
      }
    ]
    """

    /// Deliberately the client's own decoder: date handling is part of reading a status, so
    /// a test that builds its own is not testing the thing that ships.
    private func decode() throws -> [Post] {
        try MastodonClient.decoder
            .decode([MastodonDTO.Status].self, from: Data(json.utf8))
            .map { $0.asPost(from: "one.example") }
    }

    @Test("Content, handle, media and source are carried across")
    func fields() throws {
        let posts = try decode()
        #expect(posts[0].text == "hello & welcome")
        #expect(posts[0].authorName == "Ada")
        #expect(posts[0].authorHandle == "@a@one.example")
        #expect(posts[0].mediaURLs.map(\.absoluteString) == ["https://one.example/small.png"])
        #expect(posts[0].sources == ["one.example"])
    }

    @Test("What the store will never backfill is read on the first pass")
    func storedFields() throws {
        let posts = try decode()
        #expect(posts[0].socialProtocol == .mastodon)
        #expect(posts[0].sourceURL == "https://one.example")
        #expect(posts[0].uri == "https://one.example/api/v1/statuses/1")
        #expect(posts[0].originURI == "https://one.example/users/a/statuses/1")
        #expect(posts[0].authorId == "https://one.example/@a")
        #expect(posts[0].inReplyToURI == "https://one.example/api/v1/statuses/7")
        #expect(posts[0].tags == ["swift"])
        #expect(posts[0].boostedById == nil)
    }

    @Test("Dates parse with and without fractional seconds")
    func dates() throws {
        let posts = try decode()
        #expect(posts[1].createdAt > posts[0].createdAt)
    }

    @Test("A boost keeps the original's identity and names who boosted it")
    func boost() throws {
        let posts = try decode()
        #expect(posts[1].isBoost)
        #expect(posts[1].boostedBy == "b")
        #expect(posts[1].boostedById == "https://one.example/@b")
        #expect(posts[1].uri == "https://one.example/api/v1/statuses/2")
        #expect(posts[1].originURI == posts[0].originURI)
        #expect(posts[1].authorId == posts[0].authorId)
        #expect(posts[1].authorName == "Ada")
        #expect(posts[1].inReplyToURI == posts[0].inReplyToURI)
        #expect(posts[1].mergeKey != posts[0].mergeKey)
    }

    @Test("A status with no tags and an account with no url is still a row")
    func sparseStatus() throws {
        let sparse = """
        [
          {
            "id": "3",
            "uri": "https://one.example/users/c/statuses/3",
            "url": null,
            "created_at": "2026-08-21T12:00:00Z",
            "content": "<p>hi</p>",
            "account": { "id": "12", "username": "c", "acct": "c", "display_name": "", "avatar": null },
            "media_attachments": []
          },
          {
            "id": "4",
            "uri": "https://far.example/users/d/statuses/4",
            "url": null,
            "created_at": "2026-08-21T12:00:00Z",
            "content": "<p>hi</p>",
            "account": { "id": "13", "username": "d", "acct": "d@far.example", "display_name": "", "avatar": null },
            "media_attachments": []
          }
        ]
        """
        let posts = try MastodonClient.decoder
            .decode([MastodonDTO.Status].self, from: Data(sparse.utf8))
            .map { $0.asPost(from: "one.example") }
        #expect(posts[0].tags == [])
        #expect(posts[0].authorId == "https://one.example/@c")
        #expect(posts[1].authorId == "https://far.example/@d")
        #expect(posts[0].inReplyToURI == nil)
    }
}
