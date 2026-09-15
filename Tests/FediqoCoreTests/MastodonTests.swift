import Foundation
import Testing
@testable import FediqoCore

@Suite("Mastodon read")
struct MastodonTests {
    private let source = Source(host: "first.example", kind: .mastodon)

    @Test("Public timeline is origin public, limited to 40")
    func publicTimelineMaps() async throws {
        let http = FixtureHTTP([
            "/api/v1/timelines/public": .body(Fixtures.json("public-timeline")),
        ])
        let notes = try await MastodonClient(http: http, host: "first.example")
            .publicTimeline(source: source)
        #expect(notes.map(\.id) == [
            "https://first.example/users/ada/statuses/old",
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/bob/statuses/new",
        ])
        #expect(notes.allSatisfy { $0.origins == [.publicTimeline] })
        #expect(notes[0].handle == "@ada@first.example")
        #expect(notes[2].handle == "@bob@second.example")
        #expect(notes[1].previewURL == URL(string: "https://first.example/preview.jpg"))
        let requested = await http.requested
        #expect(requested.first?.path == "/api/v1/timelines/public")
        #expect(requested.first?.query == "limit=40")
    }

    @Test("Trending is origin trending, limited to 20")
    func trendingMaps() async throws {
        let http = FixtureHTTP([
            "/api/v1/trends/statuses": .body(Fixtures.json("trending-statuses")),
        ])
        let notes = try await MastodonClient(http: http, host: "first.example")
            .trending(source: source)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.origins == [.trending] })
        #expect(await http.requested.first?.query == "limit=20")
    }

    @Test("A boost unwraps the inner note and names the booster")
    func reblogUnwraps() throws {
        let json = """
        {
          "id": "9",
          "uri": "https://first.example/users/bob/statuses/boost",
          "created_at": "2024-08-01T00:00:00.000Z",
          "content": "",
          "account": { "username": "bob", "acct": "bob", "display_name": "Bob" },
          "reblog": {
            "id": "1",
            "uri": "https://first.example/users/ada/statuses/1",
            "url": "https://first.example/@ada/1",
            "created_at": "2024-01-15T12:00:00Z",
            "content": "<p>Original</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
            "media_attachments": [],
            "mentions": []
          }
        }
        """
        let note = try Self.note(json)
        #expect(note.id == "https://first.example/users/ada/statuses/1")
        #expect(note.author == "Ada")
        #expect(note.body == "Original")
        #expect(note.boostedBy == "Bob")
        #expect(note.postedAt == MastodonJSON.date(from: "2024-01-15T12:00:00Z"))
    }

    @Test("A reply names the first mention, or is unnamed")
    func replyHandleOrUnnamed() throws {
        let named = try Self.note("""
        {
          "id": "2",
          "uri": "https://first.example/users/ada/statuses/2",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>hi</p>",
          "in_reply_to_id": "1",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "mentions": [{ "acct": "bob@second.example" }]
        }
        """)
        #expect(named.reply?.handle == "@bob@second.example")

        let unnamed = try Self.note("""
        {
          "id": "3",
          "uri": "https://first.example/users/ada/statuses/3",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>hi</p>",
          "in_reply_to_id": "1",
          "account": { "username": "ada", "acct": "ada", "display_name": "" },
          "mentions": []
        }
        """)
        #expect(unnamed.reply != nil)
        #expect(unnamed.reply?.handle == nil)
        #expect(unnamed.author == "ada")
    }

    @Test("Visibility maps, and a missing uri falls back to host/statuses/id")
    func visibilityAndFallbackID() throws {
        #expect(try Self.note(Self.status(visibility: "public")).audience == .everyone)
        #expect(try Self.note(Self.status(visibility: "unlisted")).audience == .unlisted)
        #expect(try Self.note(Self.status(visibility: "private")).audience == .followers)
        #expect(try Self.note(Self.status(visibility: "direct")).audience == .mentioned)
        #expect(try Self.note(Self.status(visibility: "mystery")).audience == nil)

        let missing = try Self.note("""
        {
          "id": "local-1",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>x</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
        }
        """)
        #expect(missing.id == "https://first.example/statuses/local-1")
        #expect(missing.reply == nil)
    }

    @Test("A non-success public fetch throws")
    func publicHTTPError() async {
        let http = FixtureHTTP([
            "/api/v1/timelines/public": .text("no", status: 404),
        ])
        await #expect(throws: MastodonRequestError.http(404)) {
            try await MastodonClient(http: http, host: "first.example")
                .publicTimeline(source: source)
        }
    }

    private static func note(_ json: String) throws -> Note {
        let dto = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
        return dto.asNote(source: Source(host: "first.example", kind: .mastodon), origin: .publicTimeline)
    }

    private static func status(visibility: String) -> String {
        """
        {
          "id": "1",
          "uri": "https://first.example/users/ada/statuses/1",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>x</p>",
          "visibility": "\(visibility)",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
        }
        """
    }
}
