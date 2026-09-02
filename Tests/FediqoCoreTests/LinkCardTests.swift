import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// What a link says it is: read off the status the server sent, kept, and read back.
@Suite("A link, as the server that handed the post over read it")
struct LinkCardTests {
    private let host = "one.example"

    private let json = """
    [
      {
        "id": "1",
        "uri": "https://one.example/users/a/statuses/1",
        "url": "https://one.example/@a/1",
        "created_at": "2026-08-21T10:00:00.000Z",
        "in_reply_to_id": null,
        "content": "<p>worth reading https://slowweb.example/piece</p>",
        "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
        "media_attachments": [],
        "tags": [],
        "card": {
          "url": "https://slowweb.example/piece",
          "title": "At the pace things were written",
          "description": "A timeline that does not rank you is a timeline you can finish.",
          "type": "link",
          "provider_name": "The Slow Web",
          "image": "https://one.example/system/preview_cards/images/000/001/original/a.jpg",
          "image_description": "A reading room."
        }
      },
      {
        "id": "2",
        "uri": "https://one.example/users/a/statuses/2",
        "url": null,
        "created_at": "2026-08-21T11:00:00.000Z",
        "in_reply_to_id": null,
        "content": "<p>no link at all</p>",
        "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
        "media_attachments": [],
        "tags": []
      },
      {
        "id": "3",
        "uri": "https://one.example/users/a/statuses/3",
        "url": null,
        "created_at": "2026-08-21T12:00:00.000Z",
        "in_reply_to_id": null,
        "content": "<p>a link the server could make nothing of</p>",
        "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
        "media_attachments": [],
        "tags": [],
        "card": { "url": "https://nothing.example/", "title": "", "description": "", "type": "link", "provider_name": "", "image": null }
      }
    ]
    """

    private func decode() throws -> [Post] {
        try MastodonClient.decoder
            .decode([MastodonDTO.Status].self, from: Data(json.utf8))
            .map { $0.asPost(from: host) }
    }

    @Test("A status with a card becomes a post with one, and every word of it is the server's")
    func aCardIsRead() throws {
        let card = try #require(try decode().first?.card)
        #expect(card.url.absoluteString == "https://slowweb.example/piece")
        #expect(card.title == "At the pace things were written")
        #expect(card.provider == "The Slow Web")
        #expect(card.imageAlt == "A reading room.")
    }

    /// The whole design of #77 in one assertion: the picture is served from the server that
    /// handed the post over, not from the site being linked to. Drawing it therefore asks no
    /// host the post did not already come from — and nothing anywhere builds a card out of a
    /// URL, because that would mean asking the site.
    @Test("The picture is on the server's own storage, never on the linked site")
    func thePictureIsTheServers() throws {
        let card = try #require(try decode().first?.card)
        #expect(card.imageURL?.host() == host)
        #expect(card.imageURL?.host() != "slowweb.example")
    }

    @Test("A status with no card is a post with none, and that is not a failure")
    func noCardIsNoCard() throws {
        #expect(try decode()[1].card == nil)
    }

    /// A card carrying an address and nothing else is the link the words already carry, drawn a
    /// second time in a box.
    @Test("A card that says nothing is not drawn as a card")
    func anEmptyCardIsDropped() throws {
        #expect(try decode()[2].card == nil)
        #expect(Card(url: URL(string: "https://x.example")!).saysAnything == false)
        #expect(Card(url: URL(string: "https://x.example")!, title: "Something").saysAnything)
    }

    @Test("A card is kept with its post, and read back whole")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: host, socialProtocol: .mastodon, title: "One")
        let post = try #require(try decode().first)

        try await store.save([post], from: server)
        let read = try await store.timeline()
        #expect(read.first?.card == post.card)
    }

    /// A server re-reads a link's tags, and a card that has since been corrected should be the
    /// corrected one — unlike the tags and emojis beside it, which are ignored on conflict.
    @Test("A card the server has since corrected replaces the one we held")
    func aCorrectedCardWins() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: host, socialProtocol: .mastodon, title: "One")
        let post = try #require(try decode().first)
        try await store.save([post], from: server)

        let corrected = Post(
            uri: post.uri, originURI: post.originURI, socialProtocol: .mastodon,
            sourceURL: post.sourceURL, createdAt: post.createdAt, authorId: post.authorId,
            authorName: post.authorName, authorHandle: post.authorHandle, text: post.text,
            card: Card(url: post.card!.url, title: "The piece, retitled",
                       summary: post.card!.summary, provider: "The Slow Web"),
            sources: post.sources)
        try await store.save([corrected], from: server)

        let read = try await store.timeline()
        #expect(read.first?.card?.title == "The piece, retitled")
        // A picture the newer sighting did not carry is not erased by its silence.
        #expect(read.first?.card?.imageURL == post.card?.imageURL)
    }
}
