import Foundation
import Testing
@testable import FediqoCore

/// A post written as the reader, and taken into the store the way a fetch already does (#56).
@Suite("Writing a post")
struct MastodonWriteTests {
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)

    private static func status(
        id: String = "9",
        content: String = "<p>hello</p>",
        visibility: String = "public",
        extra: String = ""
    ) -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/me/statuses/\(id)",
         "created_at":"2024-06-01T00:00:00.000Z","content":"\(content)",
         "visibility":"\(visibility)"\(extra),
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
    }

    /// The form as it was sent, keys decoded, repeated keys kept.
    private static func pairs(_ request: URLRequest) -> [(String, String)] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = (parts.count > 1 ? parts[1].removingPercentEncoding : "") ?? ""
            return (key, value)
        }
    }

    private func writer(
        _ routes: [String: FixtureSender.Outcome]
    ) async throws -> (MastodonWrite, ItemStore, FixtureSender, MemoryMastodonTokens) {
        let store = ItemStore()
        await store.add(source)
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(
            token: MastodonFixture.token, sender: server, store: tokens
        )
        return (MastodonWrite(door: door, store: store), store, server, tokens)
    }

    @Test("A public post is sent as the reader and lands as Home and public, without a fetch")
    func aPublicPostLands() async throws {
        let (write, store, server, _) = try await writer([
            "/api/v1/statuses": .json(Self.status()),
        ])
        let note = try await write.post("hello", visibility: .everyone)
        #expect(note.body == "hello")
        #expect(note.audience == .everyone)
        #expect(note.categories == [.home, .public])
        #expect(note.statusID == "9")
        #expect(note.source.host == host)
        #expect(await store.all().map(\.id) == [note.id])

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/statuses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        let form = await server.form("/api/v1/statuses")
        #expect(form["status"] == "hello")
        #expect(form["visibility"] == "public")
        #expect(await server.paths == ["/api/v1/statuses"], "the timeline is not asked again")
    }

    @Test("What a fetch of this post would have stamped, and the wire name the source uses")
    func categoriesMatchAFetch() {
        #expect(MastodonWrite.categories(for: .everyone) == [.home, .public])
        #expect(MastodonWrite.categories(for: .unlisted) == [.home])
        #expect(MastodonWrite.categories(for: .followers) == [.home])
        #expect(MastodonWrite.categories(for: .mentioned).isEmpty)
        #expect(Audience.everyone.mastodon == "public")
        #expect(Audience.unlisted.mastodon == "unlisted")
        #expect(Audience.followers.mastodon == "private")
        #expect(Audience.mentioned.mastodon == "direct")
        for audience in Audience.allCases {
            #expect(Audience(mastodon: audience.mastodon) == audience)
        }
        #expect(Audience(mastodon: "mystery") == nil)
    }

    @Test("An unlisted post is Home and not public, and the wire name is the source's")
    func unlistedIsHomeOnly() async throws {
        let (write, store, server, _) = try await writer([
            "/api/v1/statuses": .json(Self.status(visibility: "unlisted")),
        ])
        let note = try await write.post("quiet", visibility: .unlisted)
        #expect(note.categories == [.home])
        #expect(note.audience == .unlisted)
        #expect(await server.form("/api/v1/statuses")["visibility"] == "unlisted")
        #expect(await store.all().map(\.id) == [note.id])
    }

    @Test("A plus in the text stays a plus, not a space")
    func aPlusStaysAPlus() async throws {
        let (write, _, server, _) = try await writer([
            "/api/v1/statuses": .json(Self.status(content: "<p>a+b</p>")),
        ])
        _ = try await write.post("a+b", visibility: .everyone)
        #expect(await server.form("/api/v1/statuses")["status"] == "a+b")
    }

    @Test("A source removed while the write was on the wire does not get the post back")
    func removedSourceKeepsNothing() async throws {
        let store = ItemStore()
        await store.add(source)
        let server = FixtureSender(["/api/v1/statuses": .json(Self.status())])
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(
            token: MastodonFixture.token, sender: server, store: tokens
        )
        await store.remove(host: host)
        await #expect(throws: MastodonWriteError.noSource) {
            _ = try await MastodonWrite(door: door, store: store).post("hello", visibility: .everyone)
        }
        #expect(await store.all().isEmpty)
        #expect(await server.paths.isEmpty, "nothing is asked of a source that is gone")
    }

    @Test("A 403 is a refused write, not a sign-out, and nothing lands")
    func refusedIsNotASignOut() async throws {
        let (write, store, _, tokens) = try await writer([
            "/api/v1/statuses": .json("{}", status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await write.post("hello", visibility: .everyone)
        }
        #expect(await store.all().isEmpty)
        #expect(try tokens.signedInHosts() == [host])
    }

    @Test("A 401 the account check confirms signs out, and nothing lands")
    func signedOutOnWrite() async throws {
        let (write, store, server, tokens) = try await writer([
            "/api/v1/statuses": .json("{}", status: 401),
            "/api/v1/accounts/verify_credentials": .json("{}", status: 401),
        ])
        await #expect(throws: MastodonAuthError.signedOut) {
            _ = try await write.post("hello", visibility: .everyone)
        }
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(await store.all().isEmpty)
        #expect(await server.paths
            == ["/api/v1/statuses", "/api/v1/accounts/verify_credentials"])
    }

    @Test("A body that is not a status is unreadable, and nothing lands")
    func unreadableStatus() async throws {
        let (write, store, _, _) = try await writer([
            "/api/v1/statuses": .json("{\"not\":\"a status\"}"),
        ])
        await #expect(throws: MastodonWriteError.unreadable) {
            _ = try await write.post("hello", visibility: .everyone)
        }
        #expect(await store.all().isEmpty)
    }

    @Test("A transport miss throws and keeps the token")
    func unreachableKeepsTheToken() async throws {
        let (write, store, _, tokens) = try await writer([
            "/api/v1/statuses": .fail,
        ])
        await #expect(throws: URLError.self) {
            _ = try await write.post("hello", visibility: .everyone)
        }
        #expect(await store.all().isEmpty)
        #expect(try tokens.signedInHosts() == [host])
    }

    @Test("An advertised ceiling is used; missing or zero is 500; no answer is no answer")
    func theLimitIsAdvertisedOrFiveHundred() async throws {
        #expect(MastodonWrite.limit(advertised: 2000) == 2000)
        #expect(MastodonWrite.limit(advertised: 500) == 500)
        #expect(MastodonWrite.limit(advertised: nil) == 500)
        #expect(MastodonWrite.limit(advertised: 0) == 500)
        #expect(MastodonWrite.limit(advertised: -1) == 500)
        #expect(MastodonWrite.defaultLimit == 500)

        let advertised = FixtureHTTP([
            "/api/v2/instance": .text(#"{"configuration":{"statuses":{"max_characters":2000}}}"#),
        ])
        #expect(MastodonWrite.limit(advertised: try await MastodonClient(http: advertised, host: host).introduction().profile?.statusLimit) == 2000)

        let silent = FixtureHTTP(["/api/v2/instance": .text("{}")])
        #expect(MastodonWrite.limit(advertised: try await MastodonClient(http: silent, host: host).introduction().profile?.statusLimit) == 500)

        let down = FixtureHTTP(["/api/v2/instance": .fail])
        await #expect(throws: (any Error).self) {
            try await MastodonClient(http: down, host: host).introduction()
        }
    }

    @Test("A cover and a language are sent only when there is one, folded, and the same key still names the post")
    func aCoverAndALanguageGoWithThePost() async throws {
        let key = UUID()
        let (write, _, server, _) = try await writer([
            "/api/v1/statuses": .json(Self.status(extra: #","spoiler_text":"mind","language":"zh-tw","application":{"name":"Fediqo","website":"https://github.com/cmj0121/fediqo"}"#)),
        ])
        let note = try await write.post(
            "hello", visibility: .everyone, key: key, spoiler: " mind ", language: "zh-TW"
        )
        let request = try #require(await server.requests.first)
        let form = Self.pairs(request)
        #expect(form.contains { $0 == ("spoiler_text", "mind") })
        #expect(form.contains { $0 == ("language", "zh-tw") })
        #expect(form.contains { $0.0 == "status" && $0.1 == "hello" })
        #expect(!form.contains { $0.0 == "sensitive" })
        #expect(request.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == key.uuidString)
        #expect(request.url?.host() == host)
        #expect(note.language == "zh-tw")
        #expect(note.value(of: "language") == .option("zh-tw"))
        #expect(note.value(of: "covered") == .flag(true))
        #expect(note.covered == true)
        #expect(note.via == "Fediqo")
        #expect(Rule.field("language", is: .option("zh-TW"), in: .every)?.kind
            == .field(name: "language", is: .option("zh-tw"), in: .every))

        let (plain, _, plainServer, _) = try await writer(["/api/v1/statuses": .json(Self.status())])
        _ = try await plain.post("hello", visibility: .everyone, spoiler: "  ", language: " ")
        let bare = Self.pairs(try #require(await plainServer.requests.first))
        #expect(!bare.contains { $0.0 == "spoiler_text" || $0.0 == "language" || $0.0 == "sensitive" })
    }

    @Test("Two files are uploaded with their descriptions and no second post's key, and the post names both ids")
    func twoFilesThenThePost() async throws {
        let sender = StepSender([
            "/api/v2/media": [
                .init(status: 202, body: #"{"id":"m1"}"#),
                .init(status: 202, body: #"{"id":"m2"}"#),
            ],
            "/api/v1/statuses": [.init(body: Self.status())],
        ])
        let store = ItemStore()
        await store.add(source)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: sender, store: tokens)
        let write = MastodonWrite(door: door, store: store)
        let first = try await write.upload(bytes: Data("hill".utf8), name: "hill.png", type: "image/png", description: "a hill")
        let second = try await write.upload(bytes: Data("bird".utf8), name: "bird.png", type: "image/png", description: "a bird")
        #expect(first == "m1" && second == "m2")
        let key = UUID()
        _ = try await write.post("with pictures", visibility: .everyone, key: key, mediaIDs: [first, second])

        let requests = await sender.requests
        #expect(requests.map { $0.url?.path } == ["/api/v2/media", "/api/v2/media", "/api/v1/statuses"])
        #expect(requests.allSatisfy { $0.url?.host() == host })
        let media = requests.filter { $0.url?.path == "/api/v2/media" }
        #expect(media.allSatisfy { $0.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == nil })
        #expect(media[0].httpBody?.range(of: Data("a hill".utf8)) != nil)
        #expect(media[1].httpBody?.range(of: Data("a bird".utf8)) != nil)
        let posted = requests[2]
        #expect(posted.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == key.uuidString)
        let ids = Self.pairs(posted).filter { $0.0 == "media_ids[]" }.map(\.1)
        #expect(ids == ["m1", "m2"])
    }

    @Test("A file over a ceiling the source stated is refused here, and nothing is asked")
    func tooLargeNeverLeaves() async throws {
        let (write, _, server, _) = try await writer([:])
        await #expect(throws: MastodonWriteError.refusedHere(.tooLarge(limit: 1024))) {
            _ = try await write.upload(
                bytes: Data(count: 1025), name: "big.png", type: "image/png", description: "x", byteLimit: 1024
            )
        }
        #expect(await server.paths.isEmpty)
        #expect(MastodonWrite.bytesNamed(1024) == "1 KiB")
    }

    @Test("The app a status names is kept, and one it does not name — or names as something else — is not, and does not cost the status")
    func theAppIsReadWhenAStatusNamesOne() throws {
        func decoded(_ application: String) throws -> Note {
            let json = """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9","created_at":"2024-06-01T00:00:00.000Z",
             "content":"<p>x</p>","visibility":"public"\(application),
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
            return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
                .asNote(source: source, category: .home, sent: .now())
        }
        #expect(try decoded(#","application":{"name":"Fediqo","website":"https://github.com/cmj0121/fediqo"}"#).via == "Fediqo")
        #expect(try decoded(#","application":null"#).via == nil)
        #expect(try decoded("").via == nil)
        #expect(try decoded(#","application":"nope""#).via == nil)
        #expect(try decoded(#","application":{"name":"  "}"#).via == nil)
        #expect(try decoded(#","application":{"website":"https://example.invalid"}"#).via == nil)

        let named = try decoded(#","application":{"name":"Fediqo"}"#)
        let silent = Note(
            id: named.id, source: named.source, author: named.author, handle: named.handle,
            body: named.body, postedAt: named.postedAt, categories: named.categories
        )
        #expect(silent.refreshed(over: named).via == "Fediqo")
        let other = Note(
            id: named.id, source: named.source, author: named.author, handle: named.handle,
            body: named.body, postedAt: named.postedAt, categories: named.categories, via: "Tusky"
        )
        #expect(other.refreshed(over: named).via == "Tusky")
        #expect(named.revised(by: silent, was: named).via == "Fediqo")
        #expect(named.revised(by: other, was: named).via == "Tusky")

        let boost = """
        {"id":"2","uri":"https://social.example/users/bob/statuses/2","created_at":"2024-06-01T00:00:00.000Z",
         "content":"<p>boost</p>","visibility":"public","application":{"name":"Fediqo"},
         "account":{"username":"bob","acct":"bob","display_name":"Bob"},
         "reblog":{"id":"1","uri":"https://social.example/users/ada/statuses/1","created_at":"2024-06-01T00:00:00.000Z",
           "content":"<p>hello</p>","visibility":"public","application":{"name":"Tusky"},
           "account":{"username":"ada","acct":"ada","display_name":"Ada"}}}
        """
        let status = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(boost.utf8))
        let arrived = status.arrival(source: source, categories: [.home], sent: .now())
        #expect(arrived.item.body.isEmpty)
        #expect(arrived.item.via == "Fediqo")
        #expect(arrived.reblogged?.via == "Tusky")
        #expect(status.asNote(source: source, category: .home, sent: .now()).via == "Tusky")
    }

    @Test("What a document says of media, and nothing where it says nothing — a boolean is not a count")
    func mediaLimitsAreReadLeniently() async throws {
        let stated = MastodonMediaLimits(document: Data(#"""
        {"configuration":{"statuses":{"max_media_attachments":true,"max_characters":500},
         "media_attachments":{"image_size_limit":1024,"video_size_limit":0,"description_limit":1.5,
          "supported_mime_types":[" Image/PNG ","image/png","audio/mpeg",""]}}}
        """#.utf8))
        #expect(stated.count == 4)
        #expect(stated.descriptionLimit == 1500)
        #expect(stated.imageBytes == 1024)
        #expect(stated.videoBytes == nil)
        #expect(stated.mimeTypes == ["image/png", "audio/mpeg"])
        #expect(MastodonMediaLimits(document: Data(#"{"configuration":{"media_attachments":{"supported_mime_types":"image/png"}}}"#.utf8)).mimeTypes.isEmpty)
        #expect(MastodonMediaLimits(document: Data("{}".utf8)) == .unstated)
        #expect(MastodonMediaLimits(document: Data("nope".utf8)) == .unstated)

        let silent = FixtureHTTP(["/api/v2/instance": .text("{}")])
        #expect(try await MastodonClient(http: silent, host: host).said().limits == .unstated)
    }
}

/// Answers each path from a queue, so two uploads of one path are two answers.
private actor StepSender: HTTPSender {
    struct Answer: Sendable {
        var status: Int = 200
        var body: String
    }

    private var steps: [String: [Answer]]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [String: [Answer]]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard var queue = steps[path], !queue.isEmpty else { throw FixtureHTTPError.unmapped }
        let answer = queue.removeFirst()
        steps[path] = queue
        return (
            Data(answer.body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}
