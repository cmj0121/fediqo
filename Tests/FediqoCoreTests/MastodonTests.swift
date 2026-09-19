import Foundation
import Testing
@testable import FediqoCore

@Suite("Mastodon read")
struct MastodonTests {
    private let source = Source(host: "first.example", kind: .mastodon)

    @Test("Public timeline is origin public, limited to 40")
    func publicTimelineMaps() async throws {
        let timeline = """
        [
          {
            "id": "100",
            "uri": "https://first.example/users/ada/statuses/old",
            "url": "https://first.example/@ada/old",
            "created_at": "2024-01-01T00:00:00.000Z",
            "content": "<p>Oldest public</p>",
            "visibility": "public",
            "in_reply_to_id": null,
            "account": {
              "username": "ada", "acct": "ada", "display_name": "Ada",
              "avatar": "https://first.example/ada.png"
            },
            "media_attachments": [],
            "mentions": [],
            "reblog": null
          },
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "url": "https://first.example/@ada/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends</p>",
            "visibility": "public",
            "in_reply_to_id": null,
            "account": {
              "username": "ada", "acct": "ada", "display_name": "Ada",
              "avatar": "https://first.example/ada.png"
            },
            "media_attachments": [
              {
                "type": "image",
                "url": "https://first.example/full.jpg",
                "preview_url": "https://first.example/preview.jpg"
              }
            ],
            "mentions": [],
            "reblog": null
          },
          {
            "id": "300",
            "uri": "https://first.example/users/bob/statuses/new",
            "url": "https://first.example/@bob/new",
            "created_at": "2024-12-01T00:00:00.000Z",
            "content": "<p>Newest public</p>",
            "visibility": "unlisted",
            "in_reply_to_id": null,
            "account": {
              "username": "bob", "acct": "bob@second.example",
              "display_name": "Bob", "avatar": null
            },
            "media_attachments": [],
            "mentions": [],
            "reblog": null
          }
        ]
        """
        let http = FixtureHTTP([
            "/api/v1/timelines/public": .body(Data(timeline.utf8)),
        ])
        let notes = try await MastodonClient(http: http, host: "first.example")
            .publicTimeline(source: source)
        #expect(notes.map(\.id) == [
            "https://first.example/users/ada/statuses/old",
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/bob/statuses/new",
        ])
        #expect(notes.allSatisfy { $0.categories == [.public] })
        #expect(notes[0].handle == "@ada@first.example")
        #expect(notes[2].handle == "@bob@second.example")
        #expect(notes[0].attachments.isEmpty)
        #expect(notes[1].attachments.map(\.displayURL) == [URL(string: "https://first.example/preview.jpg")])
        #expect(notes[1].attachments.map(\.url) == [URL(string: "https://first.example/full.jpg")])
        #expect(notes[1].attachments.allSatisfy { $0.kind == .image })
        let requested = await http.requested
        #expect(requested.first?.path == "/api/v1/timelines/public")
        #expect(requested.first?.query == "limit=40")
    }

    @Test("Trending is origin trending, limited to 20")
    func trendingMaps() async throws {
        let trending = """
        [
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          },
          {
            "id": "400",
            "uri": "https://first.example/users/ada/statuses/trend-only",
            "created_at": "2024-09-01T00:00:00.000Z",
            "content": "<p>Trend only</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          }
        ]
        """
        let http = FixtureHTTP([
            "/api/v1/trends/statuses": .body(Data(trending.utf8)),
        ])
        let notes = try await MastodonClient(http: http, host: "first.example")
            .trending(source: source)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.categories == [.trends] })
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

    @Test("An attachment with no address at all is not one this device carries")
    func addresslessAttachmentIsDropped() throws {
        let note = try Self.note("""
        {
          "id": "4",
          "uri": "https://first.example/users/ada/statuses/4",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>hi</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "media_attachments": [
            { "url": null, "preview_url": null },
            { "url": "https://first.example/full.jpg", "preview_url": null }
          ]
        }
        """)
        #expect(note.attachments.map(\.displayURL) == [URL(string: "https://first.example/full.jpg")])
    }

    @Test("An address this device will not fetch is no address")
    func onlyHTTPSSurvivesTheWire() throws {
        let note = try Self.note("""
        {
          "id": "5",
          "uri": "https://first.example/users/ada/statuses/5",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>hi</p>",
          "account": {
            "username": "ada", "acct": "ada", "display_name": "Ada",
            "avatar": "javascript:alert(1)"
          },
          "media_attachments": [
            { "url": "file:///etc/passwd", "preview_url": "data:image/png;base64,AAAA" },
            { "url": "http://first.example/plain.jpg", "preview_url": null },
            { "url": null, "preview_url": "https://" },
            { "url": "file:///etc/passwd", "preview_url": "https://first.example/ok.jpg" }
          ]
        }
        """)
        #expect(note.avatarURL == nil)
        // The first three carried nothing this device can fetch and are gone — `https://` among
        // them, which parses but names no host, and which kept would fill a slot for a fetch
        // that can never finish. The fourth keeps the still it was allowed and loses the file
        // it was not.
        #expect(note.attachments.count == 1)
        #expect(note.attachments[0].url == nil)
        #expect(note.attachments[0].previewURL == URL(string: "https://first.example/ok.jpg"))
    }

    /// **Decision 9 at the field it had been missed at.**
    ///
    /// Every other address on a status went through `Host.fetchableURL`; `url` went through a bare
    /// `URL(string:)`, so a hostile instance could put `javascript:` where the canonical address
    /// goes and have it kept. It had been harmless for exactly one reason — nothing in the app
    /// opened it — and unit F7 gives the reader a button that does.
    ///
    /// The check belongs here rather than only at that button, which is this branch's second
    /// convention: a rule enforced at each consumer's door is a rule consumer N+1 misses. The
    /// button checks as well, but as a second reading of the same function, not as the rule.
    @Test("A status's own address is admitted under the same rule as everything else on it")
    func theCanonicalAddressIsAdmittedToo() throws {
        #expect(try Self.note(Self.status(extra: #""url": "https://first.example/@ada/1""#)).url
            == URL(string: "https://first.example/@ada/1"))
        // Each one of these `URL(string:)` builds happily, and each one would have been handed
        // straight to the system browser.
        for hostile in ["javascript:alert(1)", "file:///etc/passwd",
                        "data:text/html;base64,PHNjcmlwdD4=",
                        "http://first.example/@ada/1", "https://"] {
            let note = try Self.note(Self.status(extra: "\"url\": \"\(hostile)\""))
            #expect(note.url == nil, "\(hostile) survived into a Note")
        }
        // Nothing said is still nothing, rather than an address invented for it.
        #expect(try Self.note(Self.status()).url == nil)
    }

    @Test("Every type a server sends, and one nobody has heard of — and a gifv is a video")
    func everyKindDecodes() throws {
        // Every `type` a Mastodon sends, one no server has ever sent, one entry that names no
        // type at all, and a last one with neither address. Kind and playability turn on
        // nothing else, so nothing else is here.
        let note = try Self.note("""
        {
          "id": "media",
          "uri": "https://first.example/users/ada/statuses/media",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>Everything a server calls an attachment</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "media_attachments": [
            { "type": "image", "url": "https://first.example/0.jpg" },
            { "type": "gifv", "url": "https://first.example/1.mp4" },
            { "type": "video", "url": "https://first.example/2.mp4" },
            { "type": "audio", "url": "https://first.example/3.mp3" },
            { "type": "unknown", "url": "https://first.example/4.bin" },
            { "type": "hologram", "url": "https://first.example/5.holo" },
            { "url": "https://first.example/6.jpg" },
            { "type": "image", "url": null, "preview_url": null }
          ]
        }
        """)
        // The eighth came with neither address and is gone; seven is what is left.
        #expect(note.attachments.map(\.kind) == [
            .image, .video, .video, .audio, .unknown, .unknown, .unknown,
        ])
        // A gifv is a silent looping MP4, so it plays; the still beside it does not.
        #expect(note.attachments.map(\.isPlayable) == [
            false, true, true, true, false, false, false,
        ])
    }

    @Test("Alt text written, written empty, and never written are three different answers")
    func altTextIsWhatTheAuthorWrote() throws {
        // Written; written and left empty; never sent at all — and the eighth, described at
        // length but addressed nowhere, which is dropped before its words can reach a row.
        let note = try Self.note("""
        {
          "id": "media",
          "uri": "https://first.example/users/ada/statuses/media",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>Everything a server calls an attachment</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "media_attachments": [
            { "url": "https://first.example/0.jpg", "description": "a cat asleep on a wall" },
            { "url": "https://first.example/1.mp4", "description": "" },
            { "url": "https://first.example/2.mp4" },
            { "url": "https://first.example/3.mp3", "description": "a field recording" },
            { "url": "https://first.example/4.bin" },
            { "url": "https://first.example/5.holo" },
            { "url": "https://first.example/6.jpg" },
            { "url": null, "preview_url": null,
              "description": "described at length, and nowhere to be found" }
          ]
        }
        """)
        #expect(note.attachments.map(\.alt) == [
            "a cat asleep on a wall", "", "", "a field recording", "", "", "",
        ])
    }

    @Test("A shape is both halves, both positive, or it is no shape at all")
    func pixelSizeNeedsBothHalves() throws {
        let note = try Self.note("""
        {
          "id": "media",
          "uri": "https://first.example/users/ada/statuses/media",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>Everything a server calls an attachment</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "media_attachments": [
            { "url": "https://first.example/0.jpg",
              "meta": { "original": { "width": 1920, "height": 1080 } } },
            { "url": "https://first.example/1.mp4",
              "meta": { "original": { "width": 480, "height": 480 } } },
            { "url": "https://first.example/2.mp4" },
            { "url": "https://first.example/3.mp3",
              "meta": { "original": { "width": 0, "height": 0 } } },
            { "url": "https://first.example/4.bin",
              "meta": { "original": { "width": 640 } } },
            { "url": "https://first.example/5.holo", "meta": { "original": null } },
            { "url": "https://first.example/6.jpg" },
            { "url": null, "preview_url": null }
          ]
        }
        """)
        // Told properly; told about a square; not told; told zero; told half; told nothing
        // inside `meta`; and sent no `meta` at all. Only the first two said a shape.
        #expect(note.attachments.map(\.width) == [1920, 480, nil, nil, nil, nil, nil])
        #expect(note.attachments.map(\.height) == [1080, 480, nil, nil, nil, nil, nil])
        #expect(note.attachments[0].aspect == 0.5625)
        #expect(note.attachments[2].aspect == nil)
    }

    @Test("An attachment described at length and addressed nowhere is still nothing to draw")
    func describedButAddresslessIsDropped() throws {
        let note = try Self.note("""
        {
          "id": "media",
          "uri": "https://first.example/users/ada/statuses/media",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>Everything a server calls an attachment</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" },
          "media_attachments": [
            { "type": "image", "url": "https://first.example/0.jpg" },
            { "type": "gifv", "url": "https://first.example/1.mp4" },
            { "type": "video", "url": "https://first.example/2.mp4" },
            { "type": "audio", "url": "https://first.example/3.mp3" },
            { "type": "unknown", "url": "https://first.example/4.bin" },
            { "type": "hologram", "url": "https://first.example/5.holo" },
            { "url": "https://first.example/6.jpg" },
            { "type": "image", "url": null, "preview_url": null,
              "description": "described at length, and nowhere to be found" }
          ]
        }
        """)
        #expect(note.attachments.count == 7)
        #expect(note.attachments.allSatisfy { !$0.alt.contains("nowhere to be found") })
    }

    @Test("Sensitive is true, false, or never said — and never said is not false")
    func sensitiveKeepsItsThirdAnswer() throws {
        #expect(try Self.note(Self.status(extra: #""sensitive": true"#)).sensitive == true)
        #expect(try Self.note(Self.status(extra: #""sensitive": false"#)).sensitive == false)

        let silent = try Self.note(Self.status())
        #expect(silent.sensitive == nil)
        // The whole point of the option: a server with no such idea has not said the post is
        // safe to look at, and reading its silence as a no would uncover what nobody uncovered.
        #expect(silent.sensitive != false)
    }

    @Test("A spoiler line, an empty one, and none at all are three different answers")
    func spoilerKeepsItsThirdAnswer() throws {
        #expect(try Self.note(Self.status(extra: #""spoiler_text": "eye contact""#)).spoiler == "eye contact")

        let said = try Self.note(Self.status(extra: #""spoiler_text": """#))
        #expect(said.spoiler == "")

        let silent = try Self.note(Self.status())
        #expect(silent.spoiler == nil)
        // A server saying the line is empty is a server that answered; one that never sent the
        // key did not. Collapsed together, the second would draw a cover nobody put on.
        #expect(silent.spoiler != "")
    }

    @Test("A status's pictures and its author's are one alphabet, and a shortcode means one of them")
    func statusAndAccountEmojiFoldTogether() throws {
        let note = try Self.note("""
        {
          "id": "6",
          "uri": "https://first.example/users/ada/statuses/6",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>:blobcat: and :wave:</p>",
          "account": {
            "username": "ada", "acct": "ada", "display_name": "Ada :wave:",
            "emojis": [
              { "shortcode": "wave", "url": "https://first.example/wave.png" },
              { "shortcode": "blobcat", "url": "https://first.example/other-blobcat.png" }
            ]
          },
          "emojis": [
            { "shortcode": "blobcat", "url": "https://first.example/blobcat.png",
              "static_url": "https://first.example/blobcat-still.png" }
          ]
        }
        """)
        #expect(note.emojis.map(\.shortcode) == ["blobcat", "wave"])
        // Named twice, drawn once, and the status's own spelling is the one kept.
        #expect(note.emojis[0].url == URL(string: "https://first.example/blobcat.png"))
        #expect(note.emojis[0].staticURL == URL(string: "https://first.example/blobcat-still.png"))
        #expect(note.emojis[1].staticURL == nil)
    }

    @Test("An emoji this device will not fetch is an emoji with no picture")
    func unfetchableEmojiIsDropped() throws {
        let note = try Self.note("""
        {
          "id": "boost",
          "uri": "https://first.example/users/cyd/statuses/boost",
          "created_at": "2024-08-01T00:00:00.000Z",
          "content": "",
          "account": { "username": "cyd", "acct": "cyd", "display_name": "Cyd" },
          "reblog": {
            "id": "original",
            "uri": "https://author.example/users/ada/statuses/1",
            "created_at": "2024-01-15T12:00:00Z",
            "content": "<p>A post written partly in :blobcat:</p>",
            "visibility": "public",
            "account": {
              "username": "ada", "acct": "ada@author.example", "display_name": "Ada :wave:",
              "emojis": [
                { "shortcode": "wave", "url": "https://author.example/wave.png",
                  "static_url": "file:///tmp/wave.png" }
              ]
            },
            "emojis": [
              { "shortcode": "blobcat", "url": "https://author.example/blobcat.png",
                "static_url": "https://author.example/blobcat-still.png" },
              { "shortcode": "nowhere", "url": "file:///etc/passwd", "static_url": null },
              { "shortcode": "plain", "url": "http://author.example/plain.png",
                "static_url": null },
              { "shortcode": "", "url": "https://author.example/nameless.png",
                "static_url": null }
            ],
            "media_attachments": [],
            "mentions": []
          }
        }
        """)
        // `file:` and `http:` are refused at the wire exactly as an attachment's address is —
        // the same cache fetches both. A shortcode kept with no picture behind it draws a
        // blank where the author wrote a word, so it goes with the address.
        #expect(!note.emojis.map(\.shortcode).contains("nowhere"))
        #expect(!note.emojis.map(\.shortcode).contains("plain"))
        // A picture with no name is one nothing in the words can ever spell.
        #expect(note.emojis.allSatisfy { !$0.shortcode.isEmpty })
        // A refused *still* is only a still we have not got; the emoji itself still has a file.
        let wave = try #require(note.emojis.first { $0.shortcode == "wave" })
        #expect(wave.url == URL(string: "https://author.example/wave.png"))
        #expect(wave.staticURL == nil)
    }

    @Test("A boost draws three accounts' words, so it carries three accounts' pictures")
    func boostCarriesEveryAlphabetTheRowDraws() throws {
        let note = try Self.note("""
        {
          "id": "boost",
          "uri": "https://first.example/users/cyd/statuses/boost",
          "created_at": "2024-08-01T00:00:00.000Z",
          "content": "",
          "sensitive": true,
          "spoiler_text": "the wrapper's own line",
          "account": {
            "username": "cyd", "acct": "cyd", "display_name": "Cyd :trumpet:",
            "emojis": [
              { "shortcode": "trumpet", "url": "https://booster.example/trumpet.png",
                "static_url": "https://booster.example/trumpet-still.png" },
              { "shortcode": "blobcat", "url": "https://booster.example/blobcat.png",
                "static_url": null }
            ]
          },
          "emojis": [
            { "shortcode": "wrapper", "url": "https://booster.example/wrapper.png",
              "static_url": null }
          ],
          "media_attachments": [],
          "mentions": [],
          "reblog": {
            "id": "original",
            "uri": "https://author.example/users/ada/statuses/1",
            "url": "https://author.example/@ada/1",
            "created_at": "2024-01-15T12:00:00Z",
            "content": "<p>A post written partly in :blobcat:</p>",
            "visibility": "public",
            "sensitive": false,
            "spoiler_text": "",
            "account": {
              "username": "ada", "acct": "ada@author.example", "display_name": "Ada :wave:",
              "avatar": "https://author.example/ada.png",
              "emojis": [
                { "shortcode": "wave", "url": "https://author.example/wave.png",
                  "static_url": "file:///tmp/wave.png" }
              ]
            },
            "emojis": [
              { "shortcode": "blobcat", "url": "https://author.example/blobcat.png",
                "static_url": "https://author.example/blobcat-still.png" },
              { "shortcode": "nowhere", "url": "file:///etc/passwd", "static_url": null },
              { "shortcode": "plain", "url": "http://author.example/plain.png",
                "static_url": null },
              { "shortcode": "", "url": "https://author.example/nameless.png",
                "static_url": null }
            ],
            "media_attachments": [],
            "mentions": []
          }
        }
        """)
        // The boosted status's own list spells its body and its spoiler line; its author's
        // spells the name drawn as the author; and the booster's spells the name drawn as
        // `boostedBy`. All three reach the row, so all three are here.
        #expect(note.emojis.map(\.shortcode) == ["blobcat", "wave", "trumpet"])
        #expect(note.author == "Ada :wave:")
        #expect(note.boostedBy == "Cyd :trumpet:")
        // The booster's *status* emojis are not among them: nothing on the row is written in
        // the wrapper's words, because a boost has no words of its own.
        #expect(!note.emojis.map(\.shortcode).contains("wrapper"))
        // `blobcat` is registered on both servers. One list per note cannot hold two pictures
        // for one name, and the boosted status wins because the body is what it spells.
        #expect(note.emojis[0].url == URL(string: "https://author.example/blobcat.png"))
        // The cover is the boosted post's, never the wrapper's: a booster cannot uncover
        // somebody else's post, and the wrapper here says `true` and a line of its own.
        #expect(note.sensitive == false)
        #expect(note.spoiler == "")
    }

    private static func note(_ json: String) throws -> Note {
        let dto = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
        return dto.asNote(source: Source(host: "first.example", kind: .mastodon), category: .public)
    }

    /// The smallest status a decoder will take, with one more key spliced in. For the cases
    /// that turn on a single field and would otherwise be a file of boilerplate around it.
    private static func status(extra: String = "") -> String {
        """
        {
          "id": "1",
          "uri": "https://first.example/users/ada/statuses/1",
          "created_at": "2024-01-01T00:00:00.000Z",
          "content": "<p>x</p>",
          "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }\(extra.isEmpty ? "" : ",\n  " + extra)
        }
        """
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
