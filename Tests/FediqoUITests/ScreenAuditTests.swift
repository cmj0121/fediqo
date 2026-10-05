import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #178: the screens #175 plainly broke — found by looking at every screen that shows what a
/// source sent, and fixed here where the fix is the screen reading the store it already has.
@MainActor
@Suite("Every screen reads what this device holds")
struct ScreenAuditTests {
    private static let host = "one.example"

    private static func note(_ id: String) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(host)", body: "post \(id)",
            postedAt: Date(timeIntervalSince1970: 0), categories: [], statusID: id
        )
    }

    private func shell(_ notes: [Note], http: FixtureHTTP = FixtureHTTP([:])) async -> ShellSession {
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest(notes)
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return session
    }

    /// A search hit the sources sent (#176), or an answer read in a thread (#177), is an item
    /// like any other (#296). Pressed, it has to open — the conversation around it is the
    /// one thing a press on a post means — and it opened nothing: the pane looked for its root
    /// among what All draws, found none, and drew the page under the press instead.
    @Test("A post a search brought opens into its conversation, and is in All before and after")
    func aPostASearchBroughtOpens() async {
        let aside = Self.note("20")
        let http = FixtureHTTP([
            "/api/v1/statuses/20/context": .text(#"{"ancestors":[],"descendants":[]}"#),
        ])
        let session = await shell([Self.note("1"), aside], http: http)

        let root = session.held(aside.key.rowID)
        #expect(root?.body == "post 20", "the conversation's root is found among what this device holds")

        await session.conversations.open(root!, in: session)
        #expect(await http.paths == ["/api/v1/statuses/20/context"], "and its conversation is asked for")
        #expect(session.conversations.standing(of: aside.key.rowID) == ShellConversationStanding.none)
        #expect(Set(session.notes.map(\.key)) == [Self.note("1").key, aside.key], "All is what it was: both")
    }

    /// The same post as a row to act on: the boost reaches its source, what the source answers is
    /// laid over the store's row — still through no category: a boost is not a timeline bringing
    /// it. Pressed again, the boost is taken back.
    @Test("A post a search brought is boosted and unboosted, and arrives through no category for it")
    func aPostASearchBroughtIsActedOn() async throws {
        let host = "social.example"
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = ActServer([
            "/api/v1/statuses/9/reblog": .json(ActTests.status(reblogged: true)),
            "/api/v1/statuses/9/unreblog": .json(ActTests.status(reblogged: false)),
        ])
        var aside = Note(
            id: "https://\(host)/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(host)", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [],
            boosted: false, statusID: "9"
        )
        aside.asked = .now()
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.ingest([aside])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()

        let row = try #require(session.held(aside.key.rowID))
        #expect(session.acts(on: row).offers(.boost), "a post a search brought offers its marks")
        await session.toggle(.boost, on: row)
        #expect(await server.paths == ["/api/v1/statuses/9/reblog"], "the boost reached its source")
        #expect(await store.note(aside.key)?.boosted == true, "the source's answer is the row's")
        #expect(await store.note(aside.key)?.categories.isEmpty == true, "and no category is added by a boost")
        #expect(session.notes.count == 1)

        await session.toggle(.boost, on: try #require(session.held(aside.key.rowID)))
        #expect(await server.paths == ["/api/v1/statuses/9/reblog", "/api/v1/statuses/9/unreblog"])
        #expect(await store.note(aside.key)?.boosted == false)
        #expect(session.notes.count == 1)
    }

    /// A post a search brought and later let go of — a Clear of its source's notes, a keep-for window —
    /// is gone from the lookup the moment the store says so, like a post in All.
    @Test("A post a search brought that the store lets go of is no longer found")
    func aPostLetGoIsNotFound() async {
        let aside = Self.note("20")
        let session = await shell([aside])
        await session.store.forget(aside.key)
        await session.reloadFromStore()
        #expect(session.held(aside.key.rowID) == nil)
    }
}
