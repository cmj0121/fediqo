import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347, #313 — follows, asked of a sign-in where it stands: the first part no place asked for
/// before there was a table, and so the first that is its entry and its sentences and nothing
/// more. Nothing presses for it yet; what is here is what the place that will press calls —
/// the standing, the line that standing draws, the question and its one page — held through
/// the session's own objects, with no view.
///
/// Every word a page is held against, and every sentence, is written out here.
@MainActor
@Suite("Follows asked of a sign-in where it stands")
struct FollowsPartTests {
    private typealias S = PartServer
    private let host = "social.example"
    private let forum = "bbs.example.org"
    private static let r = "read:statuses read:lists read:accounts"
    private static let s = "read:search"
    private static let w = "write:statuses write:favourites"
    private static let b = "write:bookmarks"
    private static let n = "read:notifications"
    private static let d = "write:notifications"
    private static let f = "read:follows write:follows"
    private static let reads = "\(r) \(s)"
    /// What this app registered for before follows was a part.
    private static let before = "\(r) \(s) \(w) \(b) \(n) \(d)"

    /// The question's detail as the person approved it (the plan's wording table), whole.
    private static let detail = "%1$@'s own sign-in page opens. It asks for what this sign-in already has, and for one thing more — who you follow: to see how you and someone stand, to follow and unfollow people and hashtags, to answer requests to follow you, and to remove a follower. Nothing is signed out first, on this device or another: close the page, or refuse on it, and the sign-in you have goes on as it is. If you allow it, the sign-in this device had stays live at %1$@ — so your other devices go on working — until you sign out here. Where %1$@ already holds a sign-in for exactly this, its page asks nothing more once you have signed in."
    private static let detailTW = "%1$@ 自己的登入頁面會打開，問這個登入已經有的，再多問一件事——你追蹤的對象：看你和某個人之間的關係、追蹤與取消追蹤人和主題標籤、回覆別人的追蹤請求，以及移除追蹤你的人。不會先登出，這台裝置和其他裝置都不會：關掉那一頁，或在上面拒絕，你原有的登入都照舊。如果你允許，這台裝置原本的登入在 %1$@ 那邊仍然有效——你的其他裝置才能照常使用——直到你在這裡登出為止。如果 %1$@ 已經有一個內容完全相同的登入，你登入之後那一頁不會再多問。"

    /// A session holding `scopes` at the host under the token string `held-1`, filed as an
    /// earlier run files one — on the registration `registered`, where one is kept.
    private func shell(
        holding scopes: String? = FollowsPartTests.reads, registered: String? = nil
    ) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let registered {
            try tokens.save(MastodonApp(host: host, clientID: "cid-old", clientSecret: "csecret-old", scopes: registered))
        }
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid-old", clientSecret: "csecret-old", scopes: scopes, asked: scopes
            ))
        }
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        for source in [Source(host: host, kind: .mastodon), Source(host: forum, kind: .discuz)] {
            await session.store.add(source)
        }
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    /// What is held, as a line a test compares before and after.
    private func kept(_ tokens: MemoryMastodonTokens) throws -> [String?] {
        let token = try tokens.token(host: host)
        return [token?.accessToken, token?.clientID, token?.scopes, token?.asked, token?.refused, token?.stamp]
    }

    /// The press for follows as a place makes it, and the yes to its question.
    private func allow(_ session: ShellSession, through page: PartPage) async throws {
        #expect(session.askFor([.follows], host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)
    }

    private static func table(_ language: String) throws -> String {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        return try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
    }

    // MARK: - The question

    @Test("The press raises one question and sends nothing: it asks for the two words of follows over what is held, under the approved title and line, and its detail is the approved paragraph word for word — the part's own sentences and the two every question ends on — in English and in Traditional Chinese")
    func theQuestionIsTheApprovedOne() async throws {
        let (session, server, _) = try await shell()
        #expect(session.partAsks.raise([.follows], host: host, in: session))
        let ask = try #require(session.partAsks.open)
        #expect(ask.ticked == [.follows])
        #expect(ask.said == "\(Self.reads) \(Self.f)")
        #expect(ask.beside.isEmpty)
        #expect(ask.with.isEmpty)
        #expect(ask.givesUp.isEmpty)
        #expect(await server.paths.isEmpty, "the press asked the source something")

        let english = ShellQuestion.part(ask, language: .english)
        #expect(english.title == "Ask social.example to allow following?")
        #expect(english.line == "Its page asks for what you allowed, and for who you follow.")
        #expect(english.help == String(format: Self.detail, host))
        #expect(english.choices.map(\.label) == ["Ask"])
        #expect(english.cancel == "Cancel")
        #expect(english.symbol == SourceRow.permissionSymbol)

        let chinese = ShellQuestion.part(ask, language: .taiwanese)
        #expect(chinese.title == "請 social.example 允許追蹤？")
        #expect(chinese.line == "它的頁面會問你已允許的，並加上你追蹤的對象。")
        #expect(chinese.help == String(format: Self.detailTW, host))
        #expect(chinese.choices.map(\.label) == ["詢問"])
        #expect(chinese.cancel == "取消")
    }

    @Test("The approved paragraph is filed as the part's own three sentences and the two every question ends on: joined as a question joins them they are the paragraph, with its arguments still in it, in each table — and the third table is the second byte for byte")
    func theDetailComposesToTheTable() throws {
        for (language, whole) in [(DummyLanguage.english, Self.detail), (.taiwanese, Self.detailTW)] {
            let join = L10n.t("question.join", language: language)
            let own = L10n.t("part.follows.ask.detail", language: language)
            let stays = L10n.t("part.ask.stays", language: language)
            let same = L10n.t("part.ask.same", language: language)
            let composed = String(format: join, String(format: join, own, stays), same)
            #expect(composed == whole)
            #expect(whole.hasPrefix(own), "the part's own sentences are not the head of the approved paragraph")
        }
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        for key in ["name", "ask.title", "ask.line", "ask.detail", "unasked"] {
            for table in tables { #expect(table.contains("\n\"part.follows.\(key)\" = \""), "part.follows.\(key) is missing from a table") }
        }
        #expect(tables[1] == tables[2])
        #expect(L10n.t("part.follows.name", language: .english) == "who you follow")
        #expect(L10n.t("part.follows.name", language: .taiwanese) == "你追蹤的對象")
    }

    // MARK: - What the place draws

    @Test("Where following would be, each standing draws its line: never asked, the approved sentence and a press that asks; refused on the page, the line that asks again; a source with none, its sentence and no press; held and held in part, nothing; and while the source is being asked, nothing to press")
    func theLineForEachStanding() throws {
        let unasked = try #require(PartWords.place(.unasked, of: .follows))
        #expect(unasked == PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        #expect(unasked.asks)
        #expect(L10n.t(unasked.key, language: .english) == "This sign-in was not asked how you stand to people. Update permission")
        #expect(L10n.t(unasked.key, language: .taiwanese) == "這個登入還沒被問過你和別人的關係。更新權限")

        let refused = try #require(PartWords.place(.refused, of: .follows))
        #expect(refused.asks)
        #expect(String(format: L10n.t(refused.key, language: .english), host) == "This was refused on social.example's page. Ask again")
        #expect(String(format: L10n.t(refused.key, language: .taiwanese), host) == "這一項在 social.example 的頁面上被拒絕了。再問一次")

        let none = try #require(PartWords.place(.notGiven, of: .follows))
        #expect(!none.asks)
        #expect(String(format: L10n.t(none.key, language: .english), host) == "social.example has none to allow.")
        #expect(String(format: L10n.t(none.key, language: .taiwanese), host) == "social.example 沒有這一項可以允許。")

        #expect(PartWords.place(.held, of: .follows) == nil)
        #expect(PartWords.place(.partly, of: .follows) == nil)
        let asking = try #require(PartWords.place(.unasked, of: .follows, asking: true))
        #expect(asking.kind == .asking)
        #expect(!asking.asks)
        #expect(PartWords.earlier[.follows] == nil, "follows was given words from before there was a table")
    }

    // MARK: - The page, for every sign-in it can be asked of

    /// A sign-in as it may be held when follows is pressed for, and the one page that asks it.
    private static let pages: [(held: String, page: String, acts: Bool)] = [
        (r, "\(r) \(f)", false),
        ("\(r) \(s)", "\(r) \(s) \(f)", false),
        ("\(r) \(s) \(n)", "\(r) \(s) \(n) \(f)", false),
        ("\(r) \(s) \(w)", "\(r) \(s) \(w) \(f)", true),
        ("\(r) \(s) \(w) \(b)", "\(r) \(s) \(w) \(b) \(f)", true),
        ("\(r) \(s) \(w) \(n)", "\(r) \(s) \(w) \(n) \(f)", true),
        ("\(r) \(s) \(w) \(b) \(n) \(d)", "\(r) \(s) \(w) \(b) \(n) \(d) \(f)", true),
    ]

    @Test("Whatever the sign-in holds, its yes opens one page for what it holds and the two words of follows — no word of acting, bookmarks, notices or dismissing it did not have — and the sign-in that comes back holds follows beside all it held, while the one it had is left live and nothing is ended; a sign-in that only reads is asked as any other", arguments: 0..<7)
    func thePageForEachHeldState(_ index: Int) async throws {
        let state = Self.pages[index]
        let (session, server, tokens) = try await shell(holding: state.held)
        #expect(session.mastodon.standing(.follows, host: host) == .unasked)
        #expect(session.mastodon.mayAsk(.follows, host: host))
        #expect(session.partAsks.raise([.follows], host: host, in: session))
        let ask = try #require(session.partAsks.open)
        #expect(ask.said == state.page)
        #expect(ask.beside.isEmpty, "a question about follows brought in an act beside acting")

        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [state.page])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(now.scopes == state.page)
        #expect(session.mastodon.standing(.follows, host: host) == .held)
        #expect(PartWords.place(.held, of: .follows) == nil)
        #expect(await server.revoked.isEmpty)
        let left = try tokens.left(host: host)
        #expect(left.map(\.state) == [.left])
        #expect(await server.registered.count == 1)
        // What the sign-in is called is what it was called: follows makes no sign-in act.
        let grant: MastodonGrant = state.acts ? .writing : .reading
        let writing: SourceWriting = state.acts ? .writes : .reads
        #expect(session.mastodon.grants[host] == grant)
        #expect(session.mastodon.writing(host: host, kind: .mastodon) == writing)
    }

    // MARK: - Holding follows is not acting

    @Test("A sign-in that reads and holds follows posts, favourites, boosts, bookmarks and dismisses nothing: its row reads, no source is offered to write on, no post offers it an act or asks for one, bookmarks are not asked of it, and its notices say it only reads — filed so, and after being allowed where it stood", arguments: [false, true])
    func holdingFollowsEnablesNoAct(_ askedInPlace: Bool) async throws {
        let wide = "\(Self.reads) \(Self.n) \(Self.f)"
        let (session, _, tokens) = try await shell(holding: askedInPlace ? "\(Self.reads) \(Self.n)" : wide)
        if askedInPlace { try await allow(session, through: PartPage()) }
        #expect(try tokens.token(host: host)?.scopes == wide)
        #expect(session.mastodon.standing(.follows, host: host) == .held)

        let mastodon = session.mastodon
        #expect(mastodon.grants[host] == .reading)
        #expect(mastodon.writing(host: host, kind: .mastodon) == .reads)
        #expect(mastodon.bookmarks(host: host) == .unavailable)
        #expect(!mastodon.mayAsk(.bookmarks, host: host))
        #expect(!session.askBookmarks(host: host))
        #expect(!mastodon.dismisses(host: host))
        #expect(mastodon.standing(.acting, host: host) == .unasked)
        #expect(NoticeActs.why(host: host, in: session, language: .english) == String(format: L10n.t("notices.acts.why.reads", language: .english), host))

        // The composer and the outbox offer the sources that write, and this is none.
        #expect(session.writableSources.isEmpty)
        let row = try #require(session.rows.first { $0.source.host == host })
        #expect(row.writing == .reads)
        #expect(SourceRow.writingKey(row.writing) == "account.source.writing.read")
        #expect(row.owed == .nothing)

        let note = Note(
            id: "https://social.example/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: "9"
        )
        await session.store.ingest([note])
        await session.reloadFromStore()
        let item = DummyItem(note)
        let acts = session.acting(on: item).acts
        #expect(acts.offered.isEmpty)
        #expect(acts.asking.isEmpty)
        #expect(acts.refused == .notSignedIn)
        for act in PostAct.allCases { #expect(session.actingCopy(of: item, for: act) == nil, "\(act)") }

        // And it is said: the listing names follows beside a sign-in its row calls reading.
        #expect(mastodon.holds(host: host, language: .english) == "This sign-in allows reading as you, searching as you, your notices, who you follow.")
    }

    // MARK: - What the place that presses will call

    @Test("Nobody is asked for follows who has it, has no sign-in, or reads a forum; a sign-in that only reads is — and its press raises the question and sends nothing")
    func whoIsAsked() async throws {
        let (none, server, _) = try await shell(holding: nil)
        #expect(none.mastodon.standing(.follows, host: host) == nil)
        #expect(!none.mastodon.mayAsk(.follows, host: host))
        #expect(!none.askFor([.follows], host: host))
        #expect(!none.askFor([.follows], host: forum))
        #expect(none.mastodon.standing(.follows, host: forum) == nil)
        #expect(none.partAsks.open == nil)
        #expect(await server.paths.isEmpty)

        let (holding, _, _) = try await shell(holding: "\(Self.reads) \(Self.f)")
        #expect(holding.mastodon.standing(.follows, host: host) == .held)
        #expect(!holding.askFor([.follows], host: host))
        #expect(holding.partAsks.open == nil)

        let (reading, asked, _) = try await shell(holding: Self.r)
        #expect(reading.mastodon.standing(.follows, host: host) == .unasked)
        #expect(reading.askFor([.follows], host: host.uppercased()))
        #expect(reading.partAsks.open?.ticked == [.follows])
        #expect(await asked.paths.isEmpty)
    }

    @Test("A no on the source's page is written beside the sign-in, which is the one it was: follows then stands refused, its line asks again, and the next yes allows it; a page closed writes nothing")
    func refusedAndAskedAgain() async throws {
        let (session, server, tokens) = try await shell()
        let was = try kept(tokens)

        try await allow(session, through: PartPage(.close))
        #expect(try kept(tokens) == was)
        #expect(session.mastodon.standing(.follows, host: host) == .unasked)

        try await allow(session, through: PartPage(.refuse))
        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "held-1")
        #expect(token.scopes == Self.reads)
        #expect(token.asked == "\(Self.reads) \(Self.f)")
        #expect(token.refused == Self.f)
        #expect(session.mastodon.standing(.follows, host: host) == .refused)
        let place = try #require(PartWords.place(.refused, of: .follows))
        #expect(place.key == "part.ask.refused")
        #expect(session.toast?.text == "This was refused on social.example's page.")
        #expect(await server.revoked.isEmpty)

        let page = PartPage()
        try await allow(session, through: page)
        #expect(page.scopes == ["\(Self.reads) \(Self.f)"])
        #expect(session.mastodon.standing(.follows, host: host) == .held)
        #expect(try tokens.token(host: host)?.refused == nil)
    }

    @Test("A source whose own list has no follows is not paged: it is said once that it has none to allow, the sign-in is the one it was, the line there says so with no press, and a second press sends nothing")
    func aSourceWithNone() async throws {
        let (session, server, tokens) = try await shell()
        await server.lists(Self.before.split(separator: " ").map(String.init))
        let was = try kept(tokens)
        let page = PartPage()

        try await allow(session, through: page)

        #expect(page.opened == 0)
        #expect(session.toast?.text == "social.example has none to allow.")
        #expect(try tokens.token(host: host)?.accessToken == was[0])
        #expect(try tokens.token(host: host)?.scopes == was[2])
        #expect(session.mastodon.standing(.follows, host: host) == .notGiven)
        #expect(PartWords.place(.notGiven, of: .follows)?.asks == false)
        let asked: Int = await server.paths.count
        #expect(!session.askFor([.follows], host: host))
        #expect(await server.paths.count == asked)
        #expect(await server.registered.isEmpty, "a host that lists no follows was registered with to be told so again")
    }

    // MARK: - The ordinary sign-in

    /// **Re-pinned with the unit that first lets a person press for follows.** This used to
    /// hold the read-or-act sign-in to what it always asked: follows was left off its page,
    /// the sign-in that came back was without it, and the one before was ended — with no
    /// word of it in the question. Now the sign-in held is carried (#347): reading and acting
    /// keeps every word of it, and reading alone keeps the words that read.
    @Test("Signing in again to read and act over a sign-in that holds follows asks for follows with the rest: the sign-in that comes back holds it, the one before is left live and nothing is ended — where both are shown to be one account; where nobody has said whose the sign-in held is, the page is the same and the one before is ended", arguments: [true, false])
    func readingAndActingKeepsFollows(_ named: Bool) async throws {
        let (session, server, tokens) = try await shell(holding: "\(Self.reads) \(Self.f)", registered: "\(Self.before) \(Self.f)")
        if named { await session.mastodon.learnWho(host: host) }
        await server.forget()
        let page = PartPage()

        await session.signIn(host: host, through: page, writing: true)

        let wanted = "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks read:follows write:follows"
        #expect(page.scopes == [wanted])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(now.scopes == wanted)
        #expect(session.mastodon.standing(.follows, host: host) == .held)
        let ended: [String] = named ? [] : ["held-1"]
        let left: [MastodonLeft.State] = named ? [.left] : []
        #expect(await server.revoked == ended)
        #expect(try tokens.left(host: host).map(\.state) == left)
    }

    @Test("Signing in again to read only over a sign-in that holds follows asks for no word that acts, the one for following among them, and keeps the one that reads: the sign-in that comes back sees who the person follows and cannot follow, the one before is ended, and the rest of follows is asked for where the sign-in stands", arguments: [false, true])
    func readingAloneKeepsWhatReads(_ acts: Bool) async throws {
        let held = acts ? "\(Self.reads) \(Self.w) \(Self.b) \(Self.n) \(Self.d) \(Self.f)" : "\(Self.reads) \(Self.f)"
        let (session, server, tokens) = try await shell(holding: held, registered: "\(Self.before) \(Self.f)")
        await session.mastodon.learnWho(host: host)
        let page = PartPage()

        await session.signIn(host: host, through: page, writing: false)

        let notices = acts ? " read:notifications" : ""
        let wanted = "read:statuses read:lists read:accounts read:search\(notices) read:follows"
        #expect(page.scopes == [wanted])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(now.scopes == wanted)
        #expect(await server.revoked == ["held-1"])
        #expect(try tokens.left(host: host).isEmpty)
        #expect(session.mastodon.standing(.follows, host: host) == .partly)
        #expect(session.mastodon.mayAsk(.follows, host: host), "the way back to following is not offered")
        #expect(session.mastodon.grants[host] == .reading)
    }

    // MARK: - A registration kept from before follows was a part

    @Test("At launch a sign-in and the registration kept with it are asked who the sign-in is and nothing else — one request, as before — whether the registration is from before follows was a part or the sign-in holds follows: nothing is registered, listed or ended", arguments: [false, true])
    func leftAloneAtLaunch(_ holdsFollows: Bool) async throws {
        let scopes = holdsFollows ? "\(Self.reads) \(Self.f)" : Self.reads
        let registered = holdsFollows ? "\(Self.before) \(Self.f)" : Self.before
        let (session, server, tokens) = try await shell(holding: scopes, registered: registered)
        let was = try kept(tokens)
        let app = try tokens.app(host: host)

        await session.mastodon.verifyAll()
        session.mastodon.refresh()

        #expect(await server.paths == [S.check])
        #expect(try tokens.app(host: host) == app)
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        #expect(try tokens.token(host: host)?.scopes == was[2])
        #expect(try tokens.left(host: host).isEmpty)
    }

    @Test("A registration kept from before follows was a part serves every ask it can carry and is made again only at the press for follows — once, for everything; that page closed leaves the sign-in held exactly as it was and ends nothing, and the next yes goes through the registration then kept, leaving the earlier sign-in live under its own")
    func anEarlierRegistrationIsMadeAgainAtThePress() async throws {
        let (session, server, tokens) = try await shell(holding: Self.reads, registered: Self.before)
        let old = try #require(try tokens.app(host: host))

        // A part its words hold: asked through it, and nothing registered.
        #expect(await session.mastodon.ask([.notices], host: host, through: PartPage(.refuse)) == .refused)
        #expect(await server.registered.isEmpty)
        #expect(try tokens.app(host: host) == old)
        let was = try kept(tokens)

        try await allow(session, through: PartPage(.close))
        #expect(await server.registered == [MastodonParts.everything])
        #expect(MastodonParts.everything.hasPrefix("\(Self.before) \(Self.f)"))
        #expect(try kept(tokens) == was, "the sign-in held was touched by a page closed")
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).isEmpty)
        #expect(session.mastodon.isSignedIn(host: host))
        #expect(session.mastodon.standing(.follows, host: host) == .unasked)

        let page = PartPage()
        try await allow(session, through: page)
        #expect(await server.registered.count == 1, "the registration made at the first press was not the one used at the second")
        #expect(page.scopes == ["\(Self.reads) \(Self.f)"])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(now.clientID == "cid")
        #expect(now.scopes == "\(Self.reads) \(Self.f)")
        // The one it had is left live, to be ended later by the registration that made it.
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        #expect(session.mastodon.standing(.follows, host: host) == .held)
    }
}
