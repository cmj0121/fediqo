import Foundation
import Testing

@testable import FediqoCore

/// One post read again (#29): which addresses are asked, and what the store keeps of the answer.
@Suite("A post read again")
struct ReadAgainTests {
    private let host = MastodonFixture.host
    private var source: Source { Source(host: host, kind: .mastodon) }

    private static func status(_ id: String, _ text: String, spoiler: String = "") -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/ada/statuses/\(id)",
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>\(text)</p>",
         "spoiler_text":"\(spoiler)","sensitive":\(spoiler.isEmpty ? "false" : "true"),
         "replies_count":2,"favourites_count":9,
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static let context = """
        {"ancestors":[\(status("7", "before"))],"descendants":[\(status("11", "after"))]}
        """

    private func held(statusID: String?) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/9", source: source, author: "Ada",
            handle: "@ada@social.example", body: "first words", postedAt: Date(timeIntervalSince1970: 0),
            categories: [.home], boostedBy: "Bob", boosterHandle: "@bob@social.example",
            statusID: statusID
        )
    }

    @Test("A status read from a timeline carries its id on that server, the boosted one's on a boost")
    func statusIDIsKept() throws {
        let plain = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status("9", "x").utf8))
        #expect(plain.asNote(source: source, category: .public).statusID == "9")
        let boost = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data("""
            {"id":"50","created_at":"2024-01-02T00:00:00.000Z","content":"",
             "account":{"username":"bob","acct":"bob","display_name":"Bob"},
             "reblog":\(Self.status("9", "x"))}
            """.utf8))
        #expect(boost.asNote(source: source, category: .public).statusID == "9")
    }

    @Test("With its id held, the post and its context are asked unsigned, and nothing else")
    func unsignedWithID() async throws {
        let http = FixtureHTTP([
            "https://social.example/api/v1/statuses/9": .text(Self.status("9", "edited")),
            "https://social.example/api/v1/statuses/9/context": .text(Self.context),
        ])
        let post = MastodonPost(http: http, host: host)
        let id = try await post.id(of: held(statusID: "9"))
        #expect(id == "9")
        let notes = [try await post.post(id: "9", source: source)]
            + (try await post.context(id: "9", source: source))
        #expect(await http.requested.map(\.absoluteString) == [
            "https://social.example/api/v1/statuses/9",
            "https://social.example/api/v1/statuses/9/context",
        ])
        #expect(notes.map(\.body) == ["edited", "before", "after"])
        #expect(notes.allSatisfy { $0.categories.isEmpty })
    }

    @Test("Without an id, a signed-in reader finds it by its URI through search, as themselves")
    func signedInSearch() async throws {
        let server = FixtureSender([
            "/api/v2/search": .json(#"{"accounts":[],"hashtags":[],"statuses":["# + Self.status("9", "x") + "]}"),
            "/api/v1/statuses/9": .json(Self.status("9", "edited")),
            "/api/v1/statuses/9/context": .json(Self.context),
        ])
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let post = MastodonPost(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens))
        let id = try await post.id(of: held(statusID: nil))
        #expect(id == "9")
        _ = try await post.post(id: "9", source: source)
        _ = try await post.context(id: "9", source: source)
        let requests = await server.requests
        let search = try #require(requests.first?.url)
        let query = URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(search.path == "/api/v2/search")
        #expect(query.first { $0.name == "q" }?.value == "https://social.example/users/ada/statuses/9")
        #expect(query.first { $0.name == "resolve" }?.value == "true")
        #expect(query.first { $0.name == "type" }?.value == "statuses")
        #expect(query.first { $0.name == "limit" }?.value == "1")
        #expect(requests.map { $0.url!.path } == ["/api/v2/search", "/api/v1/statuses/9", "/api/v1/statuses/9/context"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123" })
    }

    @Test("Without an id and signed out, nothing is asked and nothing is guessed")
    func signedOutWithoutID() async throws {
        let http = FixtureHTTP()
        let id = try await MastodonPost(http: http, host: host).id(of: held(statusID: nil))
        #expect(id == nil)
        #expect(await http.requested.isEmpty)
    }

    @Test("An id that is not one path segment is never asked")
    func strangeID() async {
        let http = FixtureHTTP()
        await #expect(throws: MastodonRequestError.self) {
            _ = try await MastodonPost(http: http, host: host).post(id: "9/../x", source: source)
        }
        #expect(await http.requested.isEmpty)
    }

    @Test("A post read again replaces what is held: new words and cover, same categories and booster")
    func refreshReplaces() async throws {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([held(statusID: "9")])
        let edited = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status("9", "edited", spoiler: "cw").utf8))
            .asNote(source: source, categories: [])
        let reply = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status("11", "after").utf8))
            .asNote(source: source, categories: [])
        await store.refresh([edited, reply], ifSourceHere: host)
        let notes = await store.all()
        let row = try #require(notes.first { $0.id.hasSuffix("/9") })
        #expect(row.body == "edited")
        #expect(row.spoiler == "cw")
        #expect(row.sensitive == true)
        #expect(row.counts.favourites == 9)
        #expect(row.categories == [.home])
        #expect(row.boostedBy == "Bob")
        #expect(row.boosterHandle == "@bob@social.example")
        #expect(notes.count == 1, "a reply this device never held is dropped, not landed")

        // `ingest` still keeps the first copy.
        await store.ingest([held(statusID: "9")])
        #expect(await store.all().first { $0.id.hasSuffix("/9") }?.body == "edited")
    }

    @Test("A post read again for a source removed meanwhile lands nothing")
    func refreshNeedsTheSource() async {
        let store = ItemStore()
        await store.refresh([held(statusID: "9")], ifSourceHere: host)
        #expect(await store.all().isEmpty)
    }

    @Test("A post read again replaces only a row of the host it was read for")
    func refreshKeepsToItsHost() async {
        let store = ItemStore()
        let other = Source(host: "other.example", kind: .mastodon)
        await store.add(source)
        await store.add(other)
        let stranger = Note(
            id: "https://social.example/users/ada/statuses/9", source: other, author: "Ada",
            handle: "@ada@social.example", body: "other copy", postedAt: Date(timeIntervalSince1970: 0),
            categories: [.public]
        )
        await store.ingest([stranger])
        var edited = held(statusID: "9")
        edited = Note(
            id: edited.id, source: other, author: "Ada", handle: edited.handle, body: "rewritten",
            postedAt: edited.postedAt, categories: []
        )
        await store.refresh([edited], ifSourceHere: host)
        #expect(await store.all().first?.body == "other copy", "asked for social.example, stamped other.example")
    }

    @Test("Search is believed only where what it found is this post, by its URI")
    func searchMustMatch() async throws {
        let server = FixtureSender([
            "/api/v2/search": .json(#"{"statuses":["# + Self.status("12", "someone else") + "]}"),
        ])
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let post = MastodonPost(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens))
        #expect(try await post.id(of: held(statusID: nil)) == nil)
    }

    @Test("A URI with + in it is searched for as written, not with a space")
    func plusIsEncoded() async throws {
        let server = FixtureSender(["/api/v2/search": .json(#"{"statuses":[]}"#)])
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let post = MastodonPost(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens))
        let plus = Note(
            id: "https://social.example/users/a+b/statuses/9?x=1&y=2", source: source, author: "A",
            handle: "@a+b@social.example", body: "", postedAt: Date(timeIntervalSince1970: 0), categories: []
        )
        _ = try await post.id(of: plus)
        let url = try #require(await server.requests.first?.url)
        #expect(url.query?.contains("q=https://social.example/users/a%2Bb/statuses/9?x%3D1%26y%3D2") == true)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }
        #expect(q?.value == plus.id)
    }

    @Test("A token that cannot search is refused with a 403, for the caller to say so")
    func searchScopeRefused() async throws {
        let server = FixtureSender(["/api/v2/search": .json("{}", status: 403)])
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let post = MastodonPost(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens))
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await post.id(of: held(statusID: nil)) }
        #expect(try tokens.signedInHosts() == [host], "a 403 is not a sign-out")
    }

    @Test("A Discourse topic is read from its own page, with its opening post's words")
    func discourseTopic() async throws {
        let http = FixtureHTTP([
            "https://forum.example/t/17.json": .text("""
                {"id":17,"title":"Tools","slug":"tools","created_at":"2024-01-01T00:00:00.000Z",
                 "posts_count":3,"reply_count":2,"like_count":4,
                 "post_stream":{"posts":[
                   {"post_number":1,"username":"ada","name":"Ada","cooked":"<p>edited opening</p>",
                    "avatar_template":"/user_avatar/forum.example/ada/{size}/1.png",
                    "created_at":"2024-01-01T00:00:00.000Z"},
                   {"post_number":2,"username":"bob","cooked":"<p>reply</p>","created_at":"2024-01-02T00:00:00.000Z"}]}}
                """),
        ])
        let forum = Source(host: "forum.example", kind: .discourse)
        let note = try await DiscourseClient(http: http, host: "forum.example")
            .topic(17, source: forum, board: "Help")
        #expect(await http.requested.map(\.absoluteString) == ["https://forum.example/t/17.json"])
        #expect(note.id == "discourse:forum.example:17")
        #expect(note.body == "edited opening")
        #expect(note.title == "Tools")
        #expect(note.board == "Help")
        #expect(note.handle == "@ada@forum.example")
        #expect(note.counts.replies == 2)
        #expect(note.avatarURL?.absoluteString == "https://forum.example/user_avatar/forum.example/ada/96/1.png")
    }
}
