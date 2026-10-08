import Foundation
import Testing
@testable import FediqoCore

/// A server that answers every request with one status, remembering what it was asked.
private actor OneStatus: HTTPSender {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = """
        {"id":"9","uri":"https://social.example/users/me/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>","visibility":"public",
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// What the person pressed to send is held beside the items, and sent under its own name.
@Suite("A text pressed to send, held until it lands")
struct UnsentTests {
    private static let source = Source(host: "social.example", kind: .mastodon)

    private static func note(_ id: String) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )
    }

    @Test("Held in the order pressed, replaced in its place, and let go by name — and none of it moves the revision a save of the posts reads")
    func heldBesideTheItems() async {
        let store = ItemStore(sources: [Self.source], notes: [Self.note("1")])
        let first = Unsent(host: "Social.Example", text: "one", audience: .everyone)
        let second = Unsent(host: "social.example", text: "two", audience: .followers, answers: Self.note("1").key)
        let revision = await store.revision

        await store.hold(first)
        await store.hold(second)
        #expect(await store.unsentHeld() == [first, second])
        #expect(first.host == "social.example", "the host is folded")
        #expect(await store.unsentRevision == 2)

        var asked = first
        asked.standing = .asked
        await store.hold(asked)
        #expect(await store.unsentHeld() == [asked, second], "what is known of it changed in its place")
        await store.hold(asked)
        #expect(await store.unsentRevision == 3, "held again as it is, nothing moved")

        await store.letGo(unsent: first.id)
        await store.letGo(unsent: first.id)
        #expect(await store.unsentHeld() == [second])
        #expect(await store.unsentRevision == 4)
        #expect(await store.revision == revision, "no post is written again for a text")
    }

    @Test("A read back, a source removed and a limit leave every text where it is; a relaunch reads them back")
    func nothingButThePersonLetsOneGo() async {
        let text = Unsent(host: "social.example", text: "mine", audience: .everyone)
        let store = ItemStore(sources: [Self.source], notes: [Self.note("1")], unsent: [text, text])
        #expect(await store.unsentHeld() == [text], "one named twice is held once")

        await store.replace(sources: [], notes: [])
        #expect(await store.unsentHeld() == [text])
        await store.add(Self.source)
        await store.ingest([Self.note("2")])
        _ = await store.letGoOldest(count: 10)
        await store.remove(host: "social.example")
        #expect(await store.unsentHeld() == [text])
        #expect(await store.unsentRevision == 0, "and nothing said they had changed")
    }

    @Test("A post sent under a name carries it as its Idempotency-Key, the same each time; one sent under none carries no such header")
    func theKeyRidesTheRequest() async throws {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: "social.example", accessToken: "tok", clientID: "c", clientSecret: "s")
        try tokens.save(token)
        let server = OneStatus()
        let store = ItemStore(sources: [Self.source], notes: [])
        let write = MastodonWrite(door: MastodonAuthorized(token: token, sender: server, store: tokens), store: store)
        let key = UUID()

        try await write.post("hello", visibility: .everyone, key: key)
        try await write.post("hello", visibility: .everyone, key: key)
        try await write.post("hello", visibility: .everyone)

        let sent = await server.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        #expect(sent == [key.uuidString, key.uuidString, nil])
        #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" },
                "the door's own headers are not replaced")
    }

    @Test("Whose sign-in it is rides with the sign-in as it is kept, and a sign-in kept before that was written down reads as it always did")
    func whoRidesWithTheSignIn() throws {
        let token = MastodonToken(
            host: "social.example", accessToken: "tok", clientID: "c", clientSecret: "s", scopes: "read write",
            accountID: "4711", handle: "@me@social.example"
        )
        let kept = try #require(MastodonKeychain.Wire.decode(MastodonKeychain.Wire.encode(token), host: "social.example"))
        #expect(kept == token)
        #expect(token.recorded(asked: "read").accountID == "4711", "what else is written beside it leaves it")

        // As a build before this one wrote it: no word of who, and nothing else read differently.
        let before = Data(#"{"accessToken":"tok","clientID":"c","clientSecret":"s","scopes":"read write"}"#.utf8)
        let old = try #require(MastodonKeychain.Wire.decode(before, host: "social.example"))
        #expect(old.accountID == nil && old.handle == nil)
        #expect(old.named(accountID: "4711", handle: "@me@social.example") == token)
        // And unnamed, it is written with no key an older build has not seen.
        let written = String(decoding: MastodonKeychain.Wire.encode(old), as: UTF8.self)
        #expect(!written.contains("accountID") && !written.contains("handle"))
    }
}
