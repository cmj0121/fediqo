import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// What the reader just did to a post is not undone on screen by a read already on its way
/// (#291), asked of the session: a reload really sent, held on the wire while the press is made
/// and answered, and let land afterwards.
///
/// What a test can reach: the row the session draws from, before the reload lands and after, for
/// each of the three marks put and taken back; and the next reload, asked afterwards, being
/// taken. What it cannot: the mark drawn on a Mac and a phone, in light and dark.
@Suite("A press is not undone by a reload already on its way")
@MainActor
struct ActBeforeReadLandsTests {
    private static let host = "social.example"

    /// One source as its signed-in reader sees it: Home holding post 9, and the three acts on it.
    ///
    /// **Home answers with what was true when it was asked**, however long the answer is held:
    /// that is what a read on its way is.
    private actor Server: HTTPSender {
        /// What the source says the reader has done to post 9, each mark.
        private var marks: [PostAct: Bool]
        /// The gate the next Home ask waits on, where one is set.
        private var holding: Gate?
        private(set) var homeAsks = 0
        private(set) var acts: [String] = []

        init(_ said: Bool) { marks = [.favourite: said, .boost: said, .bookmark: said] }

        func hold(_ gate: Gate?) { holding = gate }

        /// The mark moved somewhere else — another app — with nothing asked from here.
        func elsewhere(_ act: PostAct, _ on: Bool) { marks[act] = on }

        private var status: String {
            """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9",
             "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>","visibility":"public",
             "favourited":\(marks[.favourite]!),"reblogged":\(marks[.boost]!),"bookmarked":\(marks[.bookmark]!),
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw FixtureHTTPError.unmapped }
            let body: String
            switch url.path {
            case "/api/v1/timelines/home":
                homeAsks += 1
                body = "[\(status)]"
                if let gate = holding {
                    holding = nil
                    await gate.wait()
                }
            case "/api/v1/statuses/9/favourite": body = act(.favourite, true)
            case "/api/v1/statuses/9/unfavourite": body = act(.favourite, false)
            case "/api/v1/statuses/9/reblog": body = act(.boost, true)
            case "/api/v1/statuses/9/unreblog": body = act(.boost, false)
            case "/api/v1/statuses/9/bookmark": body = act(.bookmark, true)
            case "/api/v1/statuses/9/unbookmark": body = act(.bookmark, false)
            default: throw FixtureHTTPError.unmapped
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        private func act(_ act: PostAct, _ on: Bool) -> String {
            acts.append("\(act) \(on)")
            marks[act] = on
            return status
        }
    }

    private static let token = MastodonToken(
        host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
        scopes: MastodonOAuth.scopes(writing: true)
    )

    private static func mark(_ act: PostAct, _ note: Note?) -> Bool? {
        switch act {
        case .favourite: note?.favourited
        case .boost: note?.boosted
        case .bookmark: note?.bookmarked
        case .answer, .withdraw: nil
        }
    }

    /// A session signed in to act, holding post 9 as Home last brought it — every mark `said` —
    /// and the timeline that reads Home.
    private func shell(
        _ said: Bool, tokens: MemoryMastodonTokens = MemoryMastodonTokens()
    ) async throws -> (ShellSession, Server, TimelineQuery) {
        try tokens.save(Self.token)
        let server = Server(said)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        let home = TimelineDefinition(name: "Home", rules: [
            try #require(Rule.category(.home, in: .source(host: Self.host), sources: session.sources)),
        ])
        session.written = [home]
        await session.reload.timeline(.written(home.id), in: session)
        #expect(session.notes.count == 1, "the premise: Home brought the post")
        return (session, server, .written(home.id))
    }

    @Test(
        "The mark a press set is still drawn when a reload asked before the press lands after it — put or taken back; and the next reload is the source's word",
        .timeLimit(.minutes(1)),
        arguments: [PostAct.favourite, .boost, .bookmark], [true, false]
    )
    func aReloadOnItsWay(act: PostAct, on: Bool) async throws {
        let (session, server, home) = try await shell(!on)
        #expect(Self.mark(act, session.notes.first) == !on)
        let asked = await server.homeAsks

        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        await server.hold(gate)
        let reloading = Task { await session.reload.timeline(home, in: session) }
        #expect(await spun { await server.homeAsks == asked + 1 }, "the reload is on the wire")

        await session.toggle(act, on: DummyItem(try #require(session.notes.first)))
        #expect(await server.acts == ["\(act) \(on)"], "the premise: the press went, the way it was meant")
        #expect(Self.mark(act, session.notes.first) == on, "the source's answer is drawn")

        await gate.open()
        await reloading.value
        #expect(Self.mark(act, session.notes.first) == on, "the reload on its way put the mark back")
        #expect(Self.mark(act, await session.store.all().first) == on)

        // Undone elsewhere, and a reload asked now: the source's word, and taken.
        await server.elsewhere(act, !on)
        await session.reload.timeline(home, in: session)
        #expect(Self.mark(act, session.notes.first) == !on, "a reload asked afterwards did not change the mark")
    }

    /// The three marks of the one row, as the store holds them.
    private func marks(_ session: ShellSession) async -> [Bool?] {
        let row = await session.store.all().first
        return [row?.favourited, row?.boosted, row?.bookmarked]
    }

    @Test(
        "A reload on its way when the reader signs out brings none of their marks back; the next sign-in's reload says its own",
        .timeLimit(.minutes(1))
    )
    func aReloadOnItsWayAtSignOut() async throws {
        let tokens = MemoryMastodonTokens()
        let (session, server, home) = try await shell(true, tokens: tokens)
        #expect(await marks(session) == [true, true, true], "the premise: the reader's marks are held")
        let asked = await server.homeAsks

        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        await server.hold(gate)
        let reloading = Task { await session.reload.timeline(home, in: session) }
        #expect(await spun { await server.homeAsks == asked + 1 }, "the reload is on the wire")

        await session.signOut(host: Self.host)
        #expect(await marks(session) == [nil, nil, nil], "the premise: signing out took the marks off")

        await gate.open()
        await reloading.value
        #expect(await marks(session) == [nil, nil, nil], "the reload on its way brought the marks back")

        // Somebody signs in, and their first reload is theirs.
        try tokens.save(Self.token)
        session.mastodon.refresh()
        await session.forgetReaderMarksDue()
        await server.elsewhere(.favourite, false)
        await session.reload.timeline(home, in: session)
        #expect(await marks(session) == [false, true, true], "the next sign-in's own reload did not land")
    }
}
