import Foundation
import Testing
@testable import FediqoCore

/// What a Mastodon server says happened, as one row of an inbox.
@Suite("A Mastodon notification becomes one notice")
struct MastodonNoticeTests {
    private let owner = "https://one.example/users/me"

    private let json = """
    [
      {
        "id": "34",
        "type": "mention",
        "created_at": "2026-08-21T10:00:00.000Z",
        "account": { "id": "10", "url": "https://who.example/@who", "username": "who", "acct": "who@who.example", "display_name": "Who", "avatar": "https://who.example/who.png" },
        "status": {
          "id": "1",
          "uri": "https://one.example/users/who/statuses/1",
          "url": "https://one.example/@who/1",
          "created_at": "2026-08-21T10:00:00.000Z",
          "in_reply_to_id": null,
          "content": "<p>at you</p>",
          "account": { "id": "10", "url": "https://who.example/@who", "username": "who", "acct": "who@who.example", "display_name": "Who", "avatar": null },
          "media_attachments": [],
          "tags": []
        }
      },
      {
        "id": "33",
        "type": "reblog",
        "created_at": "2026-08-21T09:00:00.000Z",
        "account": { "id": "11", "url": "https://who.example/@b", "username": "b", "acct": "b@who.example", "display_name": "B", "avatar": null },
        "status": {
          "id": "2", "uri": "https://one.example/users/me/statuses/2", "url": null,
          "created_at": "2026-08-21T08:00:00.000Z", "in_reply_to_id": null,
          "content": "<p>mine</p>",
          "account": { "id": "12", "url": "https://one.example/@me", "username": "me", "acct": "me", "display_name": "Me", "avatar": null },
          "media_attachments": [], "tags": []
        }
      },
      {
        "id": "32",
        "type": "follow",
        "created_at": "2026-08-21T08:00:00.000Z",
        "account": { "id": "13", "url": "https://who.example/@c", "username": "c", "acct": "c@who.example", "display_name": "C", "avatar": null }
      },
      {
        "id": "31",
        "type": "admin.sign_up",
        "created_at": "2026-08-21T07:00:00.000Z",
        "account": { "id": "14", "url": "https://one.example/@d", "username": "d", "acct": "d", "display_name": "D", "avatar": null }
      }
    ]
    """

    private func decode(arrivedAt: Date = Date(timeIntervalSince1970: 2_000_000)) throws -> [Notice] {
        try MastodonClient.decoder
            .decode([MastodonDTO.Notification].self, from: Data(json.utf8))
            .compactMap { $0.asNotice(from: "one.example", owner: owner, arrivedAt: arrivedAt) }
    }

    @Test("A mention carries its status, and the status is a post like any other")
    func mentionCarriesItsPost() throws {
        let mention = try #require(try decode().first)
        #expect(mention.kind == .mention)
        #expect(mention.remoteId == "34")
        #expect(mention.serverURL == "https://one.example")
        #expect(mention.ownerId == owner)
        #expect(mention.actorHandle == "@who@who.example")
        #expect(mention.actorAvatarURL?.absoluteString == "https://who.example/who.png")
        #expect(mention.post?.text.contains("at you") == true)
    }

    /// `reblog` is the only kind spelled differently on the two sides. This app says boost
    /// everywhere a reader can see, so it says boost the moment the word crosses the edge.
    @Test("A reblog is a boost, and the translation happens once")
    func reblogIsABoost() throws {
        let notices = try decode()
        #expect(notices.first(where: { $0.remoteId == "33" })?.kind == .boost)
        #expect(MastodonClient.askedFor.contains("reblog"))
        #expect(!MastodonClient.askedFor.contains("boost"))
    }

    @Test("A follow is about a person, so there is nothing to quote")
    func followHasNoPost() throws {
        let follow = try #require(try decode().first { $0.remoteId == "32" })
        #expect(follow.kind == .follow)
        #expect(follow.post == nil)
        #expect(follow.kind.isAboutAPost == false)
    }

    /// A moderation notice is meant for somebody running a server. A client that cannot draw
    /// it must not store it as a kind with no row — a screen that cannot say what happened
    /// should show nothing, never a blank line.
    @Test("A kind this build cannot draw is dropped where it is decoded")
    func unknownKindsAreDropped() throws {
        #expect(try decode().map(\.remoteId) == ["34", "33", "32"])
        #expect(MastodonDTO.Notification.kind(of: "admin.report") == nil)
        #expect(MastodonDTO.Notification.kind(of: "follow_request") == nil)
        #expect(MastodonDTO.Notification.kind(of: "status") == nil)
    }

    /// `arrived_at` is a fact about this device, not about the payload — which is why it is
    /// passed in. The difference between the two is what lets a screen say how late a notice
    /// was rather than guess.
    @Test("When it happened and when we heard are two different times")
    func latenessIsMeasuredNotGuessed() throws {
        let heard = Date(timeIntervalSince1970: 1_787_306_400 + 90)
        let mention = try #require(try decode(arrivedAt: heard).first)
        #expect(mention.arrivedAt == heard)
        #expect(mention.noticedAt < mention.arrivedAt)
        #expect(mention.lateness > 0)
    }

    /// A clock ahead of ours is a thing that happens. "Arrived nine seconds before it
    /// happened" is not a thing to show a reader.
    @Test("A server's clock running ahead is not negative lateness")
    func latenessIsNeverNegative() throws {
        let early = Date(timeIntervalSince1970: 0)
        let mention = try #require(try decode(arrivedAt: early).first)
        #expect(mention.lateness == 0)
    }

    // MARK: - The stream

    private func frame(_ text: String) -> URLSessionWebSocketTask.Message { .string(text) }

    /// The payload is a JSON document inside a JSON string. That is the streaming API's own
    /// shape, and not a mistake to be corrected on the way past.
    @Test("A streamed notification is a notice, payload-inside-a-string and all")
    func streamedFrame() throws {
        let payload = """
        {"id":"34","type":"mention","created_at":"2026-08-21T10:00:00.000Z",
         "account":{"id":"10","url":"https://who.example/@who","username":"who","acct":"who@who.example","display_name":"Who","avatar":null}}
        """
        // Encoded rather than hand-quoted: the payload really is a string in that field, and
        // a test that spells the escaping by hand is testing its own spelling.
        let quoted = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let text = #"{"stream":["user:notification"],"event":"notification","payload":"# + quoted + "}"
        let notices = MastodonClient.notices(in: frame(text), from: "one.example", owner: owner)
        #expect(notices.map(\.remoteId) == ["34"])
        #expect(notices.first?.kind == .mention)
    }

    /// A stream carries frames this build has no use for. One of them is silence, not a
    /// broken connection.
    @Test("A frame that is not a notification is silence, not an error")
    func otherFramesAreSilence() {
        let merged = #"{"stream":["user:notification"],"event":"notifications_merged","payload":"{}"}"#
        #expect(MastodonClient.notices(in: frame(merged), from: "one.example", owner: owner).isEmpty)
        #expect(MastodonClient.notices(in: frame("not json at all"), from: "one.example", owner: owner).isEmpty)
        #expect(MastodonClient.notices(in: .data(Data([0x01])), from: "one.example", owner: owner).isEmpty)
    }
}
