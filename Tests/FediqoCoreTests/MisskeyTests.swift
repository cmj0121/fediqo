import Foundation
import Testing

@testable import FediqoCore

/// A Misskey read the way the app reads it: by POST, with the arguments in a JSON body.
///
/// **The JSON is written out here, not captured**, with invented people and invented notes. It
/// keeps the relations a real local timeline has — a person with no `host` because they live
/// there, `createdAt` with fractional seconds, a pure renote carrying the note it renotes — and
/// is a record of the shape this app was built to read, not evidence of what every Misskey sends.
@Suite("Misskey")
struct MisskeyTests {
    private static let host = "misskey.example"
    private static let source = Source(host: Self.host, kind: .misskey)
    private static let timeline = "/api/notes/local-timeline"

    private static func client(_ fixture: FixtureHTTP) -> MisskeyClient {
        MisskeyClient(sender: fixture, host: host)
    }

    private static let plain = #"""
    {
      "id": "9xk2a1b2c3",
      "createdAt": "2026-11-06T09:15:30.123Z",
      "user": {
        "id": "9aaa", "username": "wren", "name": "Wren Makar", "host": null,
        "avatarUrl": "https://misskey.example/avatar/wren.webp"
      },
      "text": "Kettle's on. **Who** wants tea?",
      "cw": null,
      "files": [],
      "repliesCount": 2,
      "renoteCount": 5,
      "uri": null,
      "url": null
    }
    """#

    @Test("A plain note becomes a note under the host's prefix, listed on the public timeline")
    func aPlainNote() async throws {
        let fixture = FixtureHTTP([Self.timeline: .text("[\(Self.plain)]")])
        let notes = try await Self.client(fixture).localTimeline(source: Self.source)

        let note = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(note.id == "misskey:misskey.example:9xk2a1b2c3")
        #expect(note.statusID == "9xk2a1b2c3")
        #expect(note.author == "Wren Makar")
        #expect(note.handle == "@wren")
        // MFM is the author's text, and left as they typed it.
        #expect(note.body == "Kettle's on. **Who** wants tea?")
        #expect(note.spoiler == nil)
        #expect(note.attachments.isEmpty)
        #expect(note.categories == [.public])
        #expect(note.listed == [.public: "9xk2a1b2c3"])
        #expect(note.counts == Counts(replies: 2, reblogs: 5))
        #expect(note.avatarURL == URL(string: "https://misskey.example/avatar/wren.webp"))
        #expect(note.url == URL(string: "https://misskey.example/notes/9xk2a1b2c3"))
        #expect(note.postedAt == MastodonJSON.date(from: "2026-11-06T09:15:30.123Z"))
        #expect(note.refs.isEmpty)
    }

    @Test("A warning is the spoiler, files are attachments, and one sensitive file makes it sensitive")
    func aWarningAndFiles() async throws {
        let body = #"""
        [{
          "id": "9xk2a1b2d4",
          "createdAt": "2026-11-06T09:20:00.000Z",
          "user": { "username": "ines", "name": null, "host": "elsewhere.example", "avatarUrl": null },
          "text": "the view from the ridge",
          "cw": "mountains, lots of them",
          "files": [
            {
              "url": "https://files.misskey.example/a.jpg",
              "thumbnailUrl": "https://files.misskey.example/a-thumb.webp",
              "type": "image/jpeg", "isSensitive": false, "comment": "a ridge at dusk",
              "properties": { "width": 1600, "height": 900 }
            },
            {
              "url": "https://files.misskey.example/b.mp4", "thumbnailUrl": null,
              "type": "video/mp4", "isSensitive": true, "comment": null, "properties": {}
            }
          ],
          "repliesCount": 0, "renoteCount": 0,
          "uri": "https://elsewhere.example/notes/abc",
          "url": "https://elsewhere.example/@ines/abc"
        }]
        """#
        let fixture = FixtureHTTP([Self.timeline: .text(body)])
        let note = try #require(try await Self.client(fixture).localTimeline(source: Self.source).first)

        #expect(note.author == "ines")
        #expect(note.handle == "@ines@elsewhere.example")
        #expect(note.spoiler == "mountains, lots of them")
        #expect(note.sensitive == true)
        #expect(note.url == URL(string: "https://elsewhere.example/@ines/abc"))
        #expect(note.attachments == [
            Attachment(
                kind: .image, url: URL(string: "https://files.misskey.example/a.jpg"),
                previewURL: URL(string: "https://files.misskey.example/a-thumb.webp"),
                alt: "a ridge at dusk", width: 1600, height: 900
            ),
            Attachment(kind: .video, url: URL(string: "https://files.misskey.example/b.mp4")),
        ])
    }

    @Test("A pure renote is a reference to the note it carries, and that note arrives beside it")
    func aPureRenote() async throws {
        let body = #"""
        [{
          "id": "9xk2a1b2e5",
          "createdAt": "2026-11-06T10:00:00.000Z",
          "user": { "username": "jo", "name": "Jo Ferrando", "host": null, "avatarUrl": null },
          "text": null, "cw": null, "files": [],
          "renoteId": "9xk2a1b2c3",
          "renote": \#(Self.plain),
          "repliesCount": 0, "renoteCount": 0
        }]
        """#
        let fixture = FixtureHTTP([Self.timeline: .text(body)])
        let notes = try await Self.client(fixture).localTimeline(source: Self.source)

        #expect(notes.count == 2)
        let renote = try #require(notes.first)
        #expect(renote.id == "misskey:misskey.example:9xk2a1b2e5")
        #expect(renote.author == "Jo Ferrando")
        #expect(renote.body == "")
        #expect(renote.refs == [
            Reference(kind: .reblogs, id: "misskey:misskey.example:9xk2a1b2c3", statusID: "9xk2a1b2c3")
        ])
        #expect(renote.listed == [.public: "9xk2a1b2e5"])
        #expect(renote.categories == [.public])

        let target = try #require(notes.last)
        #expect(target.id == "misskey:misskey.example:9xk2a1b2c3")
        #expect(target.body == "Kettle's on. **Who** wants tea?")
        // It came in the payload, not through the timeline.
        #expect(target.categories.isEmpty)
        #expect(target.listed.isEmpty)
    }

    @Test("A renote with a poll is a quote: a note of its own, not a renote with an empty body")
    func aRenoteWithAPollIsAQuote() async throws {
        let body = #"""
        [{
          "id": "9xk2a1b2f6",
          "createdAt": "2026-11-06T10:05:00.000Z",
          "user": { "username": "jo", "name": "Jo Ferrando", "host": null, "avatarUrl": null },
          "text": null, "cw": null, "files": [],
          "poll": { "multiple": false, "expiresAt": null, "choices": [{ "text": "tea", "votes": 0, "isVoted": false }] },
          "renoteId": "9xk2a1b2c3",
          "renote": \#(Self.plain),
          "repliesCount": 0, "renoteCount": 0
        }]
        """#
        let fixture = FixtureHTTP([Self.timeline: .text(body)])
        let notes = try await Self.client(fixture).localTimeline(source: Self.source)

        let note = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(note.id == "misskey:misskey.example:9xk2a1b2f6")
        #expect(!note.refs.contains { $0.kind == .reblogs })
        #expect(note.listed == [.public: "9xk2a1b2f6"])
    }

    @Test("A renote whose note did not come with it is still listed, naming the note it renotes")
    func aRenoteWithoutItsNoteIsKept() async throws {
        let body = #"""
        [{
          "id": "9xk2a1b2g7",
          "createdAt": "2026-11-06T10:10:00.000Z",
          "user": { "username": "jo", "name": "Jo Ferrando", "host": null, "avatarUrl": null },
          "text": null, "cw": null, "files": [],
          "renoteId": "9xk2a1b2c3",
          "repliesCount": 0, "renoteCount": 0
        }]
        """#
        let fixture = FixtureHTTP([Self.timeline: .text(body)])
        let notes = try await Self.client(fixture).localTimeline(source: Self.source)

        let renote = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(renote.listed == [.public: "9xk2a1b2g7"])
        #expect(renote.refs == [
            Reference(kind: .reblogs, id: "misskey:misskey.example:9xk2a1b2c3", statusID: "9xk2a1b2c3")
        ])
    }

    @Test("The newest page asks with a limit and no untilId, by POST with JSON")
    func theNewestPageIsAsked() async throws {
        let fixture = FixtureHTTP([Self.timeline: .text("[]")])
        _ = try await Self.client(fixture).localTimeline(source: Self.source)

        let request = try #require(await fixture.sent.first)
        #expect(await fixture.sent.count == 1)
        #expect(request.url == URL(string: "https://misskey.example/api/notes/local-timeline"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let sentBody = try #require(request.httpBody)
        let asked = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(asked["limit"] as? Int == MisskeyClient.limit)
        #expect(asked["untilId"] == nil)
    }

    @Test("Reading on asks below the last note held")
    func readingOnAsksBelow() async throws {
        let fixture = FixtureHTTP([Self.timeline: .text("[]")])
        _ = try await Self.client(fixture).localTimeline(source: Self.source, untilID: "9xk2a1b2c3")

        let request = try #require(await fixture.sent.first)
        let sentBody = try #require(request.httpBody)
        let asked = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(asked["untilId"] as? String == "9xk2a1b2c3")
    }

    @Test(
        "A timeline kept from guests is refused, in Misskey's own words",
        arguments: [(400, "LTL_DISABLED"), (401, "CREDENTIAL_REQUIRED")]
    )
    func aClosedTimelineIsRefused(status: Int, code: String) async throws {
        let body = #"{"error":{"message":"no","code":"\#(code)","id":"x"}}"#
        let fixture = FixtureHTTP([Self.timeline: .text(body, status: status)])
        await #expect(throws: MisskeyRequestError.refused(status)) {
            try await Self.client(fixture).localTimeline(source: Self.source)
        }
    }

    @Test("Any other 400 is a failed request, not a refusal")
    func anotherFailureIsNotARefusal() async throws {
        let body = #"{"error":{"message":"bad","code":"INVALID_PARAM","id":"x"}}"#
        let fixture = FixtureHTTP([Self.timeline: .text(body, status: 400)])
        await #expect(throws: MisskeyRequestError.http(400)) {
            try await Self.client(fixture).localTimeline(source: Self.source)
        }
    }

    @Test("A body that is not a timeline is a decoding error")
    func malformedJSONFails() async throws {
        let fixture = FixtureHTTP([Self.timeline: .text(#"{"notes": "#)])
        await #expect(throws: DecodingError.self) {
            try await Self.client(fixture).localTimeline(source: Self.source)
        }
    }

    @Test("The profile is POST /api/meta with an empty body")
    func theProfileIsMeta() async throws {
        let meta = #"""
        {
          "name": "Misskey Example",
          "description": "A place to try things.",
          "iconUrl": "https://misskey.example/icon.png",
          "bannerUrl": null,
          "disableRegistration": false,
          "maxNoteTextLength": 3000
        }
        """#
        let fixture = FixtureHTTP(["/api/meta": .text(meta)])
        let profile = try await Self.client(fixture).profile()

        #expect(profile.host == Self.host)
        #expect(profile.kind == .misskey)
        #expect(profile.title == "Misskey Example")
        #expect(profile.summary == "A place to try things.")
        #expect(profile.thumbnail == URL(string: "https://misskey.example/icon.png"))
        #expect(profile.registration == .open)

        let request = try #require(await fixture.sent.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://misskey.example/api/meta"))
        #expect(request.httpBody == Data("{}".utf8))
    }
}
