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
        "content": "<p>hello &amp; welcome</p>",
        "account": { "username": "a", "acct": "a", "display_name": "Ada", "avatar": "https://one.example/a.png" },
        "media_attachments": [
          { "type": "image", "url": "https://one.example/full.png", "preview_url": "https://one.example/small.png" }
        ]
      },
      {
        "id": "2",
        "uri": "https://one.example/users/b/statuses/2/activity",
        "url": null,
        "created_at": "2026-08-21T11:00:00Z",
        "content": "",
        "account": { "username": "b", "acct": "b", "display_name": "", "avatar": null },
        "media_attachments": [],
        "reblog": {
          "id": "1",
          "uri": "https://one.example/users/a/statuses/1",
          "url": "https://one.example/@a/1",
          "created_at": "2026-08-21T10:00:00.000Z",
          "content": "<p>hello &amp; welcome</p>",
          "account": { "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
          "media_attachments": []
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
        #expect(posts[1].uri == posts[0].uri)
        #expect(posts[1].authorName == "Ada")
    }
}
