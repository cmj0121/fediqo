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
        visibility: String = "public"
    ) -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/me/statuses/\(id)",
         "created_at":"2024-06-01T00:00:00.000Z","content":"\(content)",
         "visibility":"\(visibility)",
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
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
        #expect(try await MastodonClient(http: advertised, host: host).statusLimit() == 2000)

        let silent = FixtureHTTP(["/api/v2/instance": .text("{}")])
        #expect(try await MastodonClient(http: silent, host: host).statusLimit() == 500)

        let down = FixtureHTTP(["/api/v2/instance": .fail])
        await #expect(throws: (any Error).self) {
            try await MastodonClient(http: down, host: host).statusLimit()
        }
    }
}
