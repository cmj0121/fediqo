import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// An act on a row two sources carried goes through a source the reader can write on (#136).
///
/// Every row here is one post held from `a.example`, which arrived first and is what the row is
/// drawn as, and from `b.example`, which gave the post a different id. What a test can reach:
/// which copy each act goes through and under which host, token and id; that the mark's state,
/// its name and what VoiceOver hears are that copy's; that taking back goes through the reader's
/// own copy and lets go of both; that a row nothing can act on says why; and on its way, failed
/// and tried again. What it cannot: the marks drawn on a Mac and a phone, in light and dark, and
/// VoiceOver reaching them — that lives in a view body.
@Suite("Acting on a row two sources carried")
@MainActor
struct MergedRowActTests {
    init() {
        L10n.language = .english
    }

    private let first = "a.example"
    private let second = "b.example"
    private let writing = MastodonOAuth.scopes(writing: true)

    /// The post as a source answers a press on it: the one `uri`, under that source's own id.
    static func answered(
        _ statusID: String, reblogged: Bool? = nil, favourited: Bool? = nil, acct: String = "ada@origin.example",
        uri: String = "https://origin.example/users/ada/statuses/1"
    ) -> String {
        let flag = (reblogged.map { #","reblogged":\#($0)"# } ?? "")
            + (favourited.map { #","favourited":\#($0)"# } ?? "")
        return """
        {"id":"\(statusID)","uri":"\(uri)",
         "created_at":"2023-11-14T22:13:20.000Z","content":"<p>hello</p>",
         "visibility":"public"\(flag),
         "account":{"username":"ada","acct":"\(acct)","display_name":"Ada"}}
        """
    }

    private func copy(
        on host: String, _ statusID: String, boosted: Bool? = false, favourited: Bool? = false,
        handle: String = "@ada@origin.example", id: String = "https://origin.example/users/ada/statuses/1"
    ) -> Note {
        Note(
            id: id,
            source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: handle, body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            boosted: boosted, favourited: favourited, statusID: statusID
        )
    }

    /// A shell holding `copies` in the order given, signed in with writing on `signed`, having
    /// asked each of those who the reader is where `me` is given.
    private func shell(
        signed: [String],
        holding copies: [Note],
        routes: [String: ActServer.Outcome] = [:],
        me: String? = nil,
        held path: String? = nil,
        gate: Gate? = nil
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        for host in signed {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-\(host)", clientID: "cid", clientSecret: "csecret",
                scopes: writing
            ))
        }
        var all = routes
        if let me { all["/api/v1/accounts/verify_credentials"] = .json(#"{"acct":"\#(me)"}"#) }
        let server = ActServer(all, holding: path, gate: gate)
        let store = ItemStore()
        for host in [first, second] { await store.add(Source(host: host, kind: .mastodon)) }
        for note in copies { await store.ingest([note]) }
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        if me != nil { await session.mastodon.verifyAll() }
        await session.reloadFromStore()
        return (session, server)
    }

    private func row(_ session: ShellSession) throws -> DummyItem {
        let rows = DummyItem.merged(session.notes)
        let row = try #require(rows.first)
        try #require(rows.count == 1 && row.otherCopies.count == 1, "one row for two copies")
        try #require(row.source.host == first, "drawn as the copy that arrived first")
        return row
    }

    private func held(_ session: ShellSession, on host: String) -> Note? {
        session.notes.first { $0.source.host == host }
    }

    // MARK: - Which copy

    @Test("Writable only through the second source, the row offers boosting, favouriting and answering")
    func onlyTheSecondIsWritable() async throws {
        let (session, _) = try await shell(
            signed: [second], holding: [copy(on: first, "111"), copy(on: second, "222")]
        )
        let row = try row(session)
        let acts = session.acts(on: row)
        #expect(acts.refused == nil)
        for act in [PostAct.boost, .favourite, .answer] {
            #expect(acts.offers(act), "\(act) is offered")
            #expect(session.actingCopy(of: row, for: act)?.source.host == second)
            #expect(session.actingCopy(of: row, for: act)?.statusID == "222")
        }
        #expect(!acts.offers(.withdraw), "somebody else's post")
    }

    @Test("A boost and a favourite go to the second source, under the id it gave the post")
    func theActsGoToTheSecond() async throws {
        let (session, server) = try await shell(
            signed: [second], holding: [copy(on: first, "111"), copy(on: second, "222")],
            routes: [
                "/api/v1/statuses/222/reblog": .json(Self.answered("222", reblogged: true)),
                "/api/v1/statuses/222/favourite": .json(Self.answered("222", favourited: true)),
            ]
        )
        let row = try row(session)

        await session.toggle(.boost, on: row)
        await session.toggle(.favourite, on: try self.row(session))
        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/statuses/222/reblog", "/api/v1/statuses/222/favourite",
        ], "never the drawn copy's id, 111, which names nothing on the second source")
        #expect(requests.allSatisfy { $0.url?.host == second })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok-\(second)"
        })
        #expect(held(session, on: second)?.boosted == true)
        #expect(held(session, on: second)?.favourited == true)
        #expect(held(session, on: first)?.boosted == false, "the first source was not asked")
        #expect(session.acts.standings.isEmpty, "what landed is the source's word")
    }

    @Test("An answer opens on the second source's copy and is sent there, answering its id")
    func theAnswerGoesToTheSecond() async throws {
        let (session, server) = try await shell(
            signed: [second], holding: [copy(on: first, "111"), copy(on: second, "222")],
            routes: [
                "/api/v1/statuses": .json(Self.answered(
                    "333", acct: "me", uri: "https://b.example/users/me/statuses/333"
                )),
            ]
        )
        let row = try row(session)

        #expect(session.openAnswer(to: row, in: row))
        let target = try #require(session.answering)
        #expect(target.item.source.host == second, "the sheet names the source it goes to")
        #expect(target.item.statusID == "222")
        session.answerDrafts[target.id] = "@ada@origin.example yes"
        try await session.answer(target)

        let request = try #require(await server.requests.first)
        #expect(request.url?.host == second)
        #expect(request.url?.path == "/api/v1/statuses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-\(second)")
        #expect(await server.form("/api/v1/statuses")["in_reply_to_id"] == "222")
    }

    @Test("Writable through both, every act goes through the copy the row is drawn as, every time")
    func bothWritableIsTheDrawnCopy() async throws {
        let (session, server) = try await shell(
            signed: [first, second], holding: [copy(on: first, "111"), copy(on: second, "222")],
            routes: [
                "/api/v1/statuses/111/reblog": .json(Self.answered("111", reblogged: true)),
                "/api/v1/statuses/111/unreblog": .json(Self.answered("111", reblogged: false)),
                "/api/v1/statuses/111/favourite": .json(Self.answered("111", favourited: true)),
            ]
        )
        for act in [PostAct.boost, .favourite, .answer] {
            #expect(session.actingCopy(of: try row(session), for: act)?.source.host == first)
        }
        #expect(session.acting(on: try row(session)).through.isEmpty, "the row is its own acting copy")

        await session.toggle(.boost, on: try row(session))
        await session.toggle(.boost, on: try row(session))
        await session.toggle(.favourite, on: try row(session))
        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/statuses/111/reblog", "/api/v1/statuses/111/unreblog",
            "/api/v1/statuses/111/favourite",
        ])
        #expect(requests.allSatisfy { $0.url?.host == first })
    }

    // MARK: - What the mark says

    @Test("The mark shows the state of the copy it acts through, and names that source")
    func theMarkIsTheActingCopys() async throws {
        let (session, _) = try await shell(
            signed: [second],
            holding: [
                copy(on: first, "111", boosted: false, favourited: false),
                copy(on: second, "222", boosted: true, favourited: true),
            ]
        )
        let row = try row(session)
        let acting = session.acting(on: row)
        #expect(acting.through[.boost]?.source.host == second)

        let boost = ItemActs.mark(.boost, on: row, acting: acting)
        #expect(boost.done, "the second source says it is boosted, and that is where a press goes")
        #expect(boost.spoken == "Take the boost back through b.example")
        let favourite = ItemActs.mark(.favourite, on: row, acting: acting)
        #expect(favourite.done && favourite.symbol == "star.fill")
        #expect(favourite.spoken == "Take the favourite back through b.example")
        #expect(ItemActs.mark(.answer, on: row, acting: acting).spoken == "Answer through b.example")
        for language in [DummyLanguage.english, .taiwanese] {
            for act in PostAct.allCases where acting.acts.offers(act) {
                let said = ItemActs.mark(act, on: row, acting: acting, language: language).spoken
                #expect(said.contains(second), "\(act) in \(language) names the source: \(said)")
                #expect(!said.contains("item.act."), "untranslated in \(language): \(said)")
            }
        }
    }

    @Test("A row of one names no source on its marks, since the row already names it once")
    func aRowOfOneIsUnchanged() async throws {
        let (session, _) = try await shell(signed: [first], holding: [copy(on: first, "111")])
        let row = try #require(DummyItem.merged(session.notes).first)
        let acting = session.acting(on: row)
        #expect(acting.through.isEmpty)
        #expect(ItemActs.mark(.boost, on: row, acting: acting).spoken == "Boost")
    }

    // MARK: - On its way, failed, tried again

    @Test("On its way and failed read on the acting copy; a failure leaves the row and tries again",
          .timeLimit(.minutes(1)))
    func standingsAreTheActingCopys() async throws {
        let gate = Gate()
        let (session, server) = try await shell(
            signed: [second], holding: [copy(on: first, "111"), copy(on: second, "222")],
            routes: ["/api/v1/statuses/222/reblog": .fail],
            held: "/api/v1/statuses/222/reblog", gate: gate
        )
        let row = try row(session)
        let watchdog = hangGuard(gate)
        let press = Task { await session.toggle(.boost, on: row) }
        #expect(await spun { await server.paths.count == 1 })
        let out = session.acting(on: row)
        #expect(out.standings[.boost] == .onItsWay)
        #expect(ItemActs.mark(.boost, on: row, acting: out).spoken == "Boost through b.example on its way")
        await session.toggle(.boost, on: row)
        #expect(await server.paths.count == 1, "one act, not two")
        await gate.open()
        await press.value
        watchdog.cancel()

        #expect(session.acting(on: row).standings[.boost] == .failed)
        #expect(held(session, on: second)?.boosted == false, "the row is as it was")
        #expect(held(session, on: first)?.boosted == false)
        await session.toggle(.boost, on: try self.row(session))
        #expect(await server.paths == [
            "/api/v1/statuses/222/reblog", "/api/v1/statuses/222/reblog",
        ], "tried again, through the same source")
    }

    // MARK: - Taking back

    @Test("Taking back is offered through the reader's own copy, names it, and both copies go")
    func takingBackGoesThroughTheReadersCopy() async throws {
        let mine = "https://b.example/users/me/statuses/222"
        let (session, server) = try await shell(
            signed: [second],
            holding: [
                copy(on: first, "111", handle: "@me@b.example", id: mine),
                copy(on: second, "222", handle: "@me@b.example", id: mine),
            ],
            routes: ["/api/v1/statuses/222": .json("{}")],
            me: "me"
        )
        let row = try row(session)
        #expect(session.acts(on: row).offers(.withdraw))
        #expect(session.actingCopy(of: row, for: .withdraw)?.source.host == second)

        #expect(session.askToWithdraw(row))
        let asked = try #require(session.withdrawingCopy)
        #expect(asked.source.host == second)
        #expect(ItemActs.withdrawQuestion(asked).detail.contains(second), "the question names where it goes from")
        let item = try #require(session.withdrawing)
        await session.withdraw(item)

        let deletes = await server.requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1, "one source is asked")
        #expect(deletes.first?.url?.host == second)
        #expect(deletes.first?.url?.path == "/api/v1/statuses/222")
        #expect(session.notes.isEmpty, "the row does not come back drawn as the other copy")
        #expect(await session.store.all().isEmpty)
    }

    // MARK: - Nothing to act through

    @Test("A row no source behind it can act on offers no mark and says why")
    func nothingWritableIsRefused() async throws {
        let (session, server) = try await shell(
            signed: [], holding: [copy(on: first, "111"), copy(on: second, "222")]
        )
        let row = try row(session)
        let acts = session.acts(on: row)
        #expect(acts.offered.isEmpty)
        #expect(acts.refused == .notSignedIn)
        for act in PostAct.allCases { #expect(session.actingCopy(of: row, for: act) == nil) }

        await session.toggle(.boost, on: row)
        await session.toggle(.favourite, on: row)
        #expect(!session.openAnswer(to: row, in: row))
        #expect(!session.askToWithdraw(row))
        #expect(await server.requests.isEmpty)
    }
}
