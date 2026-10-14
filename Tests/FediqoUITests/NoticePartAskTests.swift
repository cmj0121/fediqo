import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347 — notices are asked of a sign-in the one way every part is (`ShellPartAsk`): what the
/// press on the notices page raises, what its yes opens, and what the page then says of each
/// thing that can come of it. And what every ask in place owes whoever it asks: a question
/// that names all its page will ask, a reason where it is put twice, and no yes that ends in
/// silence.
@MainActor
@Suite("Notices asked of a sign-in where it stands", .watched)
struct NoticePartAskTests {
    private typealias S = PartServer
    private let host = "social.example"
    private let forum = "bbs.example.org"
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let acts = reads + " write:statuses write:favourites"
    private static let whole = acts + " write:bookmarks"
    /// The two sentences every question about an ask in place ends on, as they were approved.
    private static let stays = "If you allow it, the sign-in this device had stays live at social.example — so your other devices go on working — until you sign out here."
    private static let same = "Where social.example already holds a sign-in for exactly this, its page asks nothing more once you have signed in."

    private func shell(
        holding scopes: String? = NoticePartAskTests.reads, asked: String? = nil
    ) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes,
                asked: asked ?? scopes
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

    private func kept(_ tokens: MemoryMastodonTokens) throws -> [String?] {
        let token = try tokens.token(host: host)
        return [token?.accessToken, token?.scopes, token?.asked, token?.refused, token?.stamp]
    }

    private func said(_ key: String) -> String {
        String(format: L10n.t(key, language: .english), host)
    }

    /// What the notices page says of itself above its list, in English.
    private func pageSays(_ session: ShellSession) -> [String] {
        NoticesPane.said(in: session, language: .english).map(\.words)
    }

    private static func table(_ language: String) throws -> String {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        return try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
    }

    private static func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - The press, the question and the page

    @Test("The press raises the one question every part is asked by, in the words notices were asked in before, and sends nothing; its yes opens one page for what the sign-in holds and notices — dismissing only where it acts — and the sign-in it had is left live, not ended")
    func askedTheOneWay() async throws {
        let cases: [(held: String, line: String, page: String, dismisses: Bool)] = [
            (Self.reads, "Its page asks again for what you allowed, and to read notices.", Self.reads + " read:notifications", false),
            (Self.whole, "Its page asks for what you allowed, and to read and dismiss notices.",
             Self.whole + " read:notifications write:notifications", true),
        ]
        for use in cases {
            let (session, server, tokens) = try await shell(holding: use.held)
            #expect(session.askForNotices(host: host))
            let ask = try #require(session.partAsks.open, "the press for notices raised no question of the one kind")
            #expect(ask.ticked == [.notices])
            #expect(await server.paths.isEmpty, "the press itself asked the source something")
            let question = ShellQuestion.part(ask, language: .english)
            #expect(question.title == "Ask social.example for your notices?")
            #expect(question.line == use.line)
            #expect(question.choices.map(\.label) == ["Ask"] && question.cancel == "Cancel")
            let help = try #require(question.help)
            #expect(help.contains("the sign-in you have goes on as it is"))
            #expect(help.hasSuffix(Self.stays + " " + Self.same))

            let page = PartPage()
            session.partAsks.answer(ask, through: page, in: session)
            await session.partAsks.landed(host: host)

            #expect(page.scopes == [use.page])
            #expect(try tokens.token(host: host)?.accessToken == "new-1")
            #expect(await server.revoked.isEmpty, "the sign-in the person had was ended to ask it for notices")
            #expect(try tokens.left(host: host).map(\.state) == [.left])
            #expect(session.mastodon.notices(host: host) == .allowed)
            #expect(session.mastodon.dismisses(host: host) == use.dismisses)
            #expect(pageSays(session).isEmpty && session.rowRefusal == nil && session.toast == nil)
        }
    }

    @Test("A sign-in that acts and was never asked for bookmarks is asked for them on the notices page's question, which names them in the words it had; one that was refused them before, or has none to be given, is asked for notices alone, by a question that names what its page asks and no bookmarks")
    func bookmarksAreTickedOnlyWhereNeverAsked() async throws {
        let (session, _, _) = try await shell(holding: Self.acts)
        #expect(session.askForNotices(host: host))
        let both = try #require(session.partAsks.open)
        #expect(both.ticked == [.notices, .bookmarks])
        #expect(both.said == Self.whole + " read:notifications write:notifications")
        let named = ShellQuestion.part(both, language: .english)
        #expect(named.line == "Its page asks for what you allowed, and for bookmarks and notices.")
        #expect(named.help?.contains("and for bookmarks as well, and for two things more") == true)

        // Refused on the page before: offered at its own place, and not ticked again here.
        let (refused, _, kept) = try await shell(holding: Self.acts)
        _ = try kept.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", asked: Self.whole, refused: "write:bookmarks"
        ))
        refused.mastodon.refresh()
        #expect(refused.mastodon.standing(.bookmarks, host: host) == .refused)
        #expect(refused.askForNotices(host: host))
        #expect(refused.partAsks.open?.ticked == [.notices])

        let (given, _, _) = try await shell(holding: Self.acts, asked: Self.whole)
        #expect(given.askForNotices(host: host))
        let alone = try #require(given.partAsks.open)
        #expect(alone.ticked == [.notices])
        #expect(alone.said == Self.acts + " read:notifications write:notifications")
        let question = ShellQuestion.part(alone, language: .english)
        let text = question.line + " " + (question.help ?? "")
        #expect(!text.contains("bookmark"), "a question named bookmarks its page does not ask for")
        #expect(text.contains("to dismiss"), "the page asks to dismiss notices and its question did not say so")
    }

    @Test("At a source with no bookmarks, the notices question that ticked them does not cost the person their notices: bookmarks are said to be none there, notices are not, and the question is put again at once for notices alone, saying why — one page, and notices held, in one run; where the source said which word it lacks that is written beside the sign-in, and where it gave no proof it is kept for the run", arguments: [true, false])
    func aSourceWithoutBookmarksStillGivesNotices(_ proof: Bool) async throws {
        let (session, server, tokens) = try await shell(holding: Self.acts)
        if proof {
            await server.lists(MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "write:bookmarks" })
        } else {
            await server.registersNone(of: ["write:bookmarks"])
        }
        #expect(session.askForNotices(host: host))
        let both = try #require(session.partAsks.open)
        #expect(both.ticked == [.notices, .bookmarks])
        let page = PartPage()

        session.partAsks.answer(both, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.opened == 0)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .notGiven)
        #expect(session.mastodon.standing(.notices, host: host) == .unasked, "a source with no bookmarks was said to have given no notices")
        #expect(NoticesPane.lines(in: session) == [.unasked(host: host)])
        #expect(pageSays(session).isEmpty && session.toast == nil)
        let asked = try tokens.token(host: host)?.asked
        let noted = proof ? Self.acts + " write:bookmarks" : Self.acts
        #expect(asked == noted)
        let alone = try #require(session.partAsks.open, "notices were not asked for again by themselves")
        #expect(alone.ticked == [.notices] && alone.again)
        let why = "social.example has none of something that question asked for, so here is the question again without it."
        let question = ShellQuestion.part(alone, language: .english)
        let text: String = question.line + " " + (question.help ?? "")
        #expect(text.contains(why))
        #expect(!text.contains("bookmark"), "a question named bookmarks its page does not ask for")
        #expect(!text.contains(L10n.t("part.ask.again", language: .english)), "a sign-in that holds what it held was said to have turned out otherwise")

        session.partAsks.answer(alone, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [Self.acts + " read:notifications write:notifications"])
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(session.mastodon.notices(host: host) == .allowed)
        #expect(session.mastodon.dismisses(host: host))
        #expect(session.mastodon.bookmarks(host: host) == .unavailable, "bookmarks were offered again at a source found to have none this run")
        #expect(session.mastodon.standing(.bookmarks, host: host) == .notGiven)
        #expect(await server.revoked.isEmpty)
        #expect(pageSays(session).isEmpty && session.rowRefusal == nil && session.toast == nil)
        #expect(session.partAsks.open == nil)
    }

    @Test("Where the source itself says it has none of what was pressed for, the part ticked beside it is neither said to be none nor asked for by itself: nobody pressed for it")
    func whatWasPressedForIsNone() async throws {
        let (session, server, _) = try await shell(holding: Self.acts)
        await server.lists(MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "read:notifications" })
        let page = PartPage()

        await session.allowNotices(host: host, through: page)

        #expect(page.opened == 0)
        #expect(NoticesPane.lines(in: session) == [.refused(host: host)])
        #expect(session.mastodon.standing(.bookmarks, host: host) == .unasked, "a source that has bookmarks was said to have none")
        #expect(session.partAsks.open == nil, "a question about bookmarks was put, nobody having pressed for them")
    }

    // MARK: - What each thing that can come of it says, and where

    /// What can come of the yes, and how a test brings it about.
    enum Outcome: String, CaseIterable, Sendable {
        case closed, refused, hasNone, another, unnamed, less, unconfirmed, stranded, failed
    }

    @Test("Whatever comes of the yes, the sign-in held is the one it was, and what is true is said on the notices page — never under the source's row, and never as a sign-in that failed", arguments: Outcome.allCases)
    func whatIsSaid(_ outcome: Outcome) async throws {
        let (session, server, tokens) = try await shell()
        let before = try kept(tokens)
        var page = PartPage()
        switch outcome {
        case .closed: page = PartPage(.close)
        case .refused: page = PartPage(.refuse)
        case .hasNone: await server.lists(MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "read:notifications" })
        case .another: await server.name("new-1", as: "2")
        case .unnamed: await server.name("new-1", as: nil)
        case .less: await server.grant("read:statuses read:lists read:notifications")
        case .unconfirmed: await server.name("held-1", as: nil)
        case .stranded:
            await server.echoesNothing()
            await session.allowNotices(host: host, through: PartPage(.close))
            page = PartPage(.close)
        case .failed: await server.answer(S.apps, .body("{}", 503))
        }

        await session.allowNotices(host: host, through: page)

        let now = try kept(tokens)
        if outcome == .refused {
            #expect(Array(now.prefix(2)) == Array(before.prefix(2)))
            #expect(now[3] == "read:notifications")
        } else if outcome == .hasNone {
            #expect(Array(now.prefix(2)) == Array(before.prefix(2)))
        } else {
            #expect(now == before)
        }
        #expect(session.rowRefusal == nil && session.toast == nil, "what came of asking for notices was said away from the notices page")
        let lines = NoticesPane.lines(in: session)
        let says = pageSays(session)
        switch outcome {
        case .closed:
            #expect(says.isEmpty && lines == [.unasked(host: host)])
        case .refused:
            // The line is the press: it says what happened and asks again.
            #expect(lines == [.declined(host: host)])
            #expect(lines.first?.words(language: .english) == "This was refused on social.example's page. Ask again")
            #expect(says.isEmpty, "a refusal was said twice")
            #expect(session.askForNotices(host: host), "a part refused on the page could not be asked again")
        case .hasNone:
            #expect(lines == [.refused(host: host)])
            #expect(lines.first?.words(language: .english) == "social.example was asked for your notices and gave none.")
            #expect(says.isEmpty)
            #expect(!session.askForNotices(host: host))
        case .another: #expect(says == [said("part.ask.another")])
        case .unnamed: #expect(says == [said("part.ask.unnamed")])
        case .less: #expect(says == [said("part.ask.less")])
        case .unconfirmed: #expect(says == [said("part.ask.unconfirmed")])
        case .stranded: #expect(says == ["social.example could not be asked for this in this run."])
        case .failed: #expect(says == ["Notices were not allowed on social.example. Its sign-in works as it did."])
        }
        let ended: [String] = await server.revoked
        #expect(!ended.contains("held-1"), "asking for notices ended the sign-in the person had")
    }

    @Test("Nobody is asked for notices who has them, has been told the source has none, or is not signed in; a forum source is asked nothing and reads as it did")
    func whoIsNotAsked() async throws {
        for scopes in [nil, Self.reads + " read:notifications"] as [String?] {
            let (session, server, _) = try await shell(holding: scopes)
            #expect(!session.askForNotices(host: host))
            #expect(!session.askForNotices(host: forum))
            #expect(session.partAsks.open == nil)
            #expect(NoticesPane.hosts(in: session).allSatisfy { $0.host != forum })
            #expect(session.mastodon.standing(.notices, host: forum) == nil)
            #expect(session.rows.first { $0.source.host == forum }?.owed == .nothing)
            #expect(await server.paths.isEmpty)
        }
        let (asked, _, _) = try await shell(holding: Self.reads, asked: Self.reads + " read:notifications")
        #expect(asked.mastodon.notices(host: host) == .unavailable)
        #expect(!asked.askForNotices(host: host))
    }

    // MARK: - A sign-in whose reading no page can carry

    @Test("A sign-in holding the source's one word for every read is not asked where it stands — for notices or for any other part: no page opens, since its page could carry what was pressed for and no reading at all, and it is told to sign in again, choosing what to allow", arguments: [MastodonPart.notices, .acting, .search])
    func aCoarseSignInIsNotAskedInPlace(_ part: MastodonPart) async throws {
        let (session, server, tokens) = try await shell(holding: "read write", asked: "read write")
        let before = try kept(tokens)
        let page = PartPage()
        #expect(session.askFor([part], host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.putDown()

        await session.allow(ask, through: page)

        #expect(page.opened == 0, "a page of \(page.scopes) was put to a sign-in that reads by one word")
        #expect(try kept(tokens) == before)
        #expect(await server.revoked.isEmpty)
        let told: [String] = part == .notices ? pageSays(session) : [session.toast?.text ?? ""]
        #expect(told == ["This sign-in at social.example cannot be added to where it stands. Sign out and sign in again, choosing what to allow."])
        #expect(L10n.t("part.ask.coarse", language: .taiwanese) == "%@ 上的這個登入無法在原處再加上項目。請登出後重新登入，並選擇要允許的項目。")
        // Whose it is was confirmed, and trying later changes nothing: neither is said.
        #expect(!told.contains { $0.contains("confirm") || $0.contains("later") })
        // Its own check and its words made here, this run, change nothing of that.
        let direct = await session.mastodon.ask([part], host: host, through: page)
        #expect(PartWords.said(direct, of: [part]) == "part.ask.coarse")
        #expect(page.opened == 0)

        // A sign-in made this run, which its source gave less than every word of reading: its
        // words are this device's own, and it is still not one a page is built over. (Search
        // was asked for by that very sign-in, so there it is not a part left to ask.)
        guard part != .search else { return }
        let (short, source, held) = try await shell(holding: nil)
        let less = "read:statuses read:accounts read:search"
        await source.grant(less)
        await short.signIn(host: host, through: PartPage(), writing: false)
        #expect(try held.token(host: host)?.scopes == less)
        await source.grant(nil)
        let again = PartPage()
        let answer = await short.mastodon.ask([part], host: host, through: again)
        #expect(PartWords.said(answer, of: [part]) == "part.ask.coarse")
        #expect(again.opened == 0)
    }

    // MARK: - What every question owes

    @Test("A page that adds dismissing because it brings notices and acting together is put by a question that says so, whichever of the two was pressed")
    func theActBesideIsNamed() async throws {
        let (session, _, _) = try await shell(holding: Self.reads + " read:notifications")
        #expect(session.askFor([.acting], host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.said == Self.acts + " read:notifications write:notifications")
        #expect(ask.beside == [.notices])
        for language in [DummyLanguage.english, .taiwanese] {
            let question = ShellQuestion.part(ask, language: language)
            let text = question.line + (question.help ?? "")
            let beside = String(format: L10n.t("part.notices.ask.beside", language: language), host)
            #expect(beside != "part.notices.ask.beside" && text.contains(beside), "the question did not say its page asks to dismiss notices")
        }
        // Held already, it is not something more the page asks, and is not named as one.
        let (held, _, _) = try await shell(holding: Self.acts + " read:notifications write:notifications")
        #expect(held.askFor([.bookmarks], host: host))
        #expect(try #require(held.partAsks.open).beside.isEmpty)
    }

    @Test("A page is put only by a question that named every act it brings in beside acting: where the sign-in has come to hold less since the question was drawn, so that the same page would now add dismissing, no page opens and the question is put again, naming it")
    func anActTheQuestionDidNotName() async throws {
        let dismissing = Self.reads + " read:notifications write:notifications"
        let (session, server, tokens) = try await shell(holding: dismissing)
        #expect(session.askFor([.acting], host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.beside.isEmpty && ask.said == Self.acts + " read:notifications write:notifications")
        // The same sign-in, found to hold no dismissing: the page is the same, word for word.
        _ = try tokens.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret",
            scopes: Self.reads + " read:notifications", asked: dismissing
        ))
        session.mastodon.refresh()
        await server.answer(S.info, .body(PartAskFixture.info(Self.reads + " read:notifications")))
        let page = PartPage()

        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.opened == 0, "a page asked to dismiss notices on a question that never said so")
        let again = try #require(session.partAsks.open)
        #expect(again.said == ask.said && again.beside == [.notices] && again.again)
        session.partAsks.answer(again, through: page, in: session)
        await session.partAsks.landed(host: host)
        #expect(page.scopes == [ask.said])
    }

    @Test("Every question about a part with no earlier words of its own is the approved one with only the clause naming the part changed: it says nothing is signed out here or elsewhere, that the sign-in this device had stays live until a sign-out here, and that a source already holding one for exactly this asks nothing more — in both languages, under keys that are the part's own", arguments: [MastodonPart.reading, .search, .acting, .bookmarks, .notices, .follows])
    func everyDetailCarriesWhatIsOwed(_ part: MastodonPart) async throws {
        let ask = PartAsk(host: host, ticked: [part], said: "x", givesUp: [], stamp: nil)
        guard PartWords.own(ask.ticked)?.question(ask, .english) == nil else { return }
        let english = try #require(ShellQuestion.part(ask, language: .english).help)
        #expect(english.hasPrefix("social.example's own sign-in page opens. It asks for what this sign-in already has, and for one thing more — "))
        #expect(english.contains(" Nothing is signed out first, on this device or another: close the page, or refuse on it, and the sign-in you have goes on as it is. "))
        #expect(english.hasSuffix(Self.stays + " " + Self.same))
        let chinese = try #require(ShellQuestion.part(ask, language: .taiwanese).help)
        #expect(chinese.hasPrefix("social.example 自己的登入頁面會打開，問這個登入已經有的，再多問一件事——"))
        #expect(chinese.contains("不會先登出，這台裝置和其他裝置都不會：關掉那一頁，或在上面拒絕，你原有的登入都照舊。"))
        #expect(chinese.hasSuffix("如果你允許，這台裝置原本的登入在 social.example 那邊仍然有效——你的其他裝置才能照常使用——直到你在這裡登出為止。如果 social.example 已經有一個內容完全相同的登入，你登入之後那一頁不會再多問。"))

        // Where asking gives a word up, the sign-in before is ended — and is not said to stay.
        let gives = PartAsk(host: host, ticked: [part], said: "x", givesUp: ["push"], stamp: nil)
        let ends = try #require(ShellQuestion.part(gives, language: .english).help)
        #expect(ends.contains("the sign-in this device had is ended at social.example"))
        #expect(!ends.contains("stays live"), "one question said the sign-in before both stays and is ended")
        #expect(ends.hasSuffix(Self.same))
    }

    @Test("The keys the approved wording is filed under are left for it: no general sentence is written under them")
    func noGeneralKeyShadowsTheTable() throws {
        for language in ["en", "zh-TW", "zh-Hant"] {
            let table = try Self.table(language)
            for key in ["part.ask.title", "part.ask.line", "part.ask.detail"] {
                #expect(!table.contains("\n\"\(key)\" = "), "\(key) is written in \(language) with words that are not the table's")
            }
        }
    }

    @Test("A question put again because what is held turned out other than it was drawn from says so in one short line, and the first did not")
    func aQuestionPutAgainSaysWhy() async throws {
        let (session, server, _) = try await shell(holding: Self.reads, asked: Self.acts)
        await server.answer(S.info, .body(PartAskFixture.info(Self.acts)))
        #expect(session.askForNotices(host: host))
        let first = try #require(session.partAsks.open)
        #expect(!first.again)
        let why = "This sign-in turned out to hold something other than what you were asked about, so here is the question again."
        let put = ShellQuestion.part(first, language: .english)
        let firstText: String = put.line + " " + (put.help ?? "")
        #expect(!firstText.contains(why))
        let page = PartPage()

        session.partAsks.answer(first, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.opened == 0)
        let again = try #require(session.partAsks.open)
        #expect(again.again)
        let question = ShellQuestion.part(again, language: .english)
        let againText: String = question.line + " " + (question.help ?? "")
        #expect(againText.contains(why))
        #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength)
        #expect(L10n.t("part.ask.again", language: .taiwanese) == "這個登入實際有的，和剛才問你的不一樣，所以再問一次。")
    }

    @Test("A yes that finds nothing left to ask does not end in silence: allowed already, it says so; and where what is held turned out to be a sign-in that only reads, it says that")
    func aYesWithNothingLeftSaysSo() async throws {
        let (session, _, tokens) = try await shell(holding: Self.acts)
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.putDown()
        // Allowed meanwhile, by the same sign-in: another window's ask, noted in place.
        _ = try tokens.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.whole, asked: Self.whole
        ))
        session.mastodon.refresh()
        let page = PartPage()
        await session.allow(ask, through: page)
        #expect(page.opened == 0)
        #expect(session.toast?.text == "social.example already allows this.")

        // Allowed meanwhile, and nobody has looked since: the sign-in itself says so where
        // what rides beside it, as last read, still offers the press.
        let (stale, _, held) = try await shell(holding: Self.acts)
        #expect(stale.askBookmarks(host: host))
        let late = try #require(stale.partAsks.open)
        stale.partAsks.putDown()
        _ = try held.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.whole, asked: Self.whole
        ))
        await stale.allow(late, through: page)
        #expect(page.opened == 0)
        #expect(stale.toast?.text == "social.example already allows this.", "a yes ended in silence")
        #expect(stale.mastodon.bookmarks(host: host) == .allowed, "the place went on offering what the sign-in holds")

        let (reads, server, _) = try await shell(holding: Self.acts)
        await server.answer(S.info, .body(PartAskFixture.info(Self.reads)))
        await reads.allowBookmarks(host: host, through: page)
        #expect(page.opened == 0 && reads.partAsks.open == nil)
        #expect(reads.toast?.text == "This sign-in at social.example only reads, so it was not asked. Sign in to read and write to add this.")
    }

    // MARK: - One way

    @Test("There is one way a sign-in held is asked for more: the door an ordinary sign-in goes through takes no word for asking in place, the session's row is its one caller and presses for no notices there, and one place alone starts an ask")
    func oneCallSite() throws {
        let door = try Self.source("Shell/MastodonSignIn.swift")
        #expect(!door.contains("inPlace"), "the ordinary sign-in can still be told to ask in place")
        // Nor to press for notices: a sign-in held would be replaced and ended by it, with no question put.
        #expect(door.contains("host raw: String, through browser: any OAuthBrowser, writing: Bool = false, noticesSaid said: Bool? = nil\n"))
        for gone in ["notices wanted", "noticesPressed", "wanted == true"] {
            #expect(!door.contains(gone), "the ordinary sign-in still knows a press for notices (\(gone))")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        var signIns: [String] = []
        var asks: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("mastodon.signIn(") { signIns.append(file.lastPathComponent + ":" + line.trimmingCharacters(in: .whitespaces)) }
                if line.contains("mastodon.ask(") { asks.append(file.lastPathComponent) }
            }
        }
        #expect(signIns.count == 1 && signIns.first?.hasPrefix("ShellSession.swift:") == true)
        #expect(signIns.allSatisfy { !$0.contains("notices:") }, "a sign-in presses for notices by the old door")
        #expect(asks == ["ShellPartAsk.swift"])
        let notices = try Self.source("Shell/ShellNoticeAsk.swift")
        #expect(notices.contains("askFor(") && !notices.contains("mastodon.signIn("))
        #expect(!(try Self.source("FediqoRootView.swift")).contains("NoticeQuestion"), "two presenters still put questions about a sign-in asked for more")
    }

    // MARK: - While the ask is out

    enum Meanwhile: String, CaseIterable, Sendable { case signOut, remove, replaced, readBack }

    @Test("Signed out, removed, replaced, or a package read back from another thread while the ask for notices waits — at each place it can wait: nothing is put over what is then held, what was made is ended, and the page says nothing of a sign-in that is gone",
          arguments: PartAskTests.Step.allCases, Meanwhile.allCases)
    func whileItWaits(_ step: PartAskTests.Step, _ meanwhile: Meanwhile) async throws {
        let (session, server, tokens) = try await shell(holding: Self.whole)
        let gate = Gate()
        defer { Task { await gate.open() } }
        let page = PartPage(gate: step == .page ? gate : nil)
        let path: String? = switch step {
        case .check, .newCheck: S.check
        case .info: S.info
        case .register: S.apps
        case .trade: S.trade
        case .page: nil
        }
        if step == .newCheck {
            await server.holdCheck(of: "new-1", at: gate)
        } else if let path {
            await server.hold(path, at: gate)
        }
        #expect(session.askForNotices(host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.answer(ask, through: page, in: session)
        let asking = Task { await session.partAsks.landed(host: host) }
        await met("the ask is waiting at \(step.rawValue)", by: asking) {
            if let path { await server.waiting.contains(path) } else { page.opened == 1 }
        }

        // Shown first: while it is out a press — for notices or for another part — raises
        // nothing, and the place reads as asking instead of offering a press that is dead.
        #expect(!session.askForNotices(host: host))
        #expect(session.partAsks.open == nil)
        #expect(session.toast?.text == "Fediqo is asking social.example now.")
        #expect(NoticesPane.lines(in: session) == [.asking(host: host)])

        let other = MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reads)
        var leaving: Task<Void, Never>?
        switch meanwhile {
        case .signOut: leaving = Task { await session.signOut(host: host) }
        case .remove: leaving = Task { await session.mastodon.signOut(host: host, forgettingApp: true) }
        case .replaced: try tokens.save(other)
        case .readBack: try await Task.detached { try tokens.save(other) }.value
        }
        let gone = meanwhile == .signOut || meanwhile == .remove
        if let leaving {
            await met("the sign-in is off this device", by: leaving) { (try? tokens.token(host: self.host)) == .some(nil) }
        }
        await gate.open()
        await session.partAsks.landed(host: host)
        await session.mastodon.leftSettled()

        let held = try tokens.token(host: host)?.accessToken
        #expect(held == (gone ? nil : "other-1"), "an ask put its sign-in over what the person had come to hold")
        #expect(page.opened <= 1)
        let made = [PartAskTests.Step.page, .trade, .newCheck].contains(step)
        let ended = await server.revoked
        if made {
            #expect(ended.contains("new-1"), "a sign-in nobody kept was left live")
        } else {
            #expect(page.opened == 0, "a page opened about a sign-in the person no longer held")
        }
        if !gone { #expect(!ended.contains("other-1") && !ended.contains("held-1")) }
        #expect(pageSays(session).isEmpty && session.rowRefusal == nil, "something was said of a sign-in that is no longer there")
        #expect(session.mastodon.asking.isEmpty, "the claim on the source outlived its ask")
    }

    @Test("A question standing open is taken down when its sign-in is signed out of, and when another takes its place; and a press for another part while one is open puts that one in its place")
    func aQuestionOpenIsTakenDown() async throws {
        let (session, _, tokens) = try await shell(holding: Self.acts)
        #expect(session.askForNotices(host: host))
        await session.mastodon.signOut(host: host)
        #expect(session.partAsks.open == nil, "a question about a sign-in signed out of was left standing")

        let (other, _, held) = try await shell(holding: Self.acts)
        #expect(other.askForNotices(host: host))
        #expect(other.askBookmarks(host: host))
        #expect(other.partAsks.open?.ticked == [.bookmarks])
        try held.save(MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acts))
        other.mastodon.refresh()
        #expect(other.partAsks.open == nil, "a question about a sign-in since replaced was left standing")
        _ = tokens
    }

    // MARK: - The place, for every standing

    @Test("What a place draws where a part's act would be is decided once, by how the sign-in stands to it: held and partly held draw no lock; never asked and refused on the page each draw their own line, whose press asks; a source with none draws its line and no press; and while the source is being asked, nothing can be pressed", arguments: MastodonPart.allCases)
    func everyStandingHasItsLine(_ part: MastodonPart) throws {
        #expect(PartWords.place(.held, of: part) == nil)
        #expect(PartWords.place(.partly, of: part) == nil)
        let unasked = try #require(PartWords.place(.unasked, of: part))
        #expect(unasked.asks)
        #expect(unasked.kind == .unasked)
        let refused = try #require(PartWords.place(.refused, of: part))
        #expect(refused == PartWords.Place(kind: .refused, key: "part.ask.refused") && refused.asks)
        let none = try #require(PartWords.place(.notGiven, of: part))
        #expect(none.kind == .none && !none.asks)
        for standing in [MastodonPartStanding.unasked, .refused] {
            let asking = try #require(PartWords.place(standing, of: part, asking: true))
            #expect(asking == PartWords.Place(kind: .asking, key: "part.ask.asking") && !asking.asks)
        }
        #expect(PartWords.place(.notGiven, of: part, asking: true) == none)
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        for key in [unasked.key, refused.key, none.key] {
            for table in tables { #expect(table.contains("\n\"\(key)\""), "\(key) is written in no table") }
        }
        // Where the part kept no line from before, its lock's is its own, by its name.
        guard PartWords.earlier[part] == nil else { return }
        let own = "part.\(part.rawValue).unasked"
        #expect(unasked.key == own)
        #expect(L10n.t(own, language: .english).hasPrefix("This sign-in was not asked "))
        #expect(L10n.t(own, language: .english).hasSuffix(". Update permission"))
        #expect(L10n.t(own, language: .taiwanese).hasPrefix("這個登入還沒被問過") && L10n.t(own, language: .taiwanese).hasSuffix("。更新權限"))
    }

    @Test("The notices page draws each standing by that one reading, in the words of its line: never asked with its press, refused on the page as one press that is the line, and a source with none and no press")
    func theNoticesPageDrawsEachStanding() async throws {
        let cases: [(asked: String?, refused: String?, line: NoticesLine, kind: PartWords.Place.Kind)] = [
            (nil, nil, .unasked(host: host), .unasked),
            (Self.reads + " read:notifications", "read:notifications", .declined(host: host), .refused),
            (Self.reads + " read:notifications", nil, .refused(host: host), .none),
        ]
        for use in cases {
            let (session, _, tokens) = try await shell()
            _ = try tokens.update(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", asked: use.asked, refused: use.refused
            ))
            session.mastodon.refresh()
            let standing = try #require(session.mastodon.standing(.notices, host: host))
            let place = try #require(PartWords.place(standing, of: .notices))
            #expect(place.kind == use.kind)
            #expect(NoticesPane.lines(in: session) == [use.line])
            #expect(use.line.words(language: .english) == String(format: L10n.t(place.key, language: .english), host))
            #expect(session.askForNotices(host: host) == place.asks, "what the line offers and what its press does disagree")
        }
    }

    // MARK: - The ordinary sign-in

    @Test("An ordinary sign-in at a source that cannot be asked again this run says exactly that under its row, in the words for it, and not that the sign-in did not finish")
    func theStrandIsSaid() async throws {
        let (session, server, _) = try await shell(holding: nil)
        await server.echoesNothing()
        await session.signIn(host: host, through: PartPage(.close), writing: false)
        #expect(session.rowRefusal == nil, "a page closed once was said to be more")
        await session.signIn(host: host, through: PartPage(.close), writing: false)
        #expect(session.rowRefusal?.key == "part.ask.stranded")
        let page = PartPage()
        await session.signIn(host: host, through: page, writing: true)
        #expect(page.opened == 0)
        #expect(session.rowRefusal?.key == "part.ask.stranded")
        let lines = SourceRow.statusLines(waiting: nil, refusal: session.rowRefusal, notice: nil, host: host, language: .english)
        #expect(lines == ["social.example could not be asked for this in this run."])
    }

    // MARK: - The words

    @Test("Every sentence this step says is written in English and in Traditional Chinese with the same arguments, the approved ones to the letter, and the third table is the second byte for byte; a key missing from a table fails")
    func theWords() throws {
        let english = [
            "part.ask.stays": "If you allow it, the sign-in this device had stays live at %1$@ — so your other devices go on working — until you sign out here.",
            "part.ask.same": "Where %1$@ already holds a sign-in for exactly this, its page asks nothing more once you have signed in.",
            "part.ask.refused": "This was refused on %@'s page. Ask again",
            "part.ask.none": "%@ has none to allow.",
            "part.ask.stranded": "%@ could not be asked for this in this run.",
            "part.ask.again": "This sign-in turned out to hold something other than what you were asked about, so here is the question again.",
            "part.ask.again.without": "%@ has none of something that question asked for, so here is the question again without it.",
            "part.ask.coarse": "This sign-in at %@ cannot be added to where it stands. Sign out and sign in again, choosing what to allow.",
            "part.notices.ask.beside": "Because this sign-in will then both write as you and read your notices, its page also asks to dismiss them, and to let through or let go the ones held back.",
            "part.ask.held": "%@ already allows this.",
            "part.ask.reads": "This sign-in at %@ only reads, so it was not asked. Sign in to read and write to add this.",
            "part.ask.asking": "Fediqo is asking %@ now.",
            "part.several.ask.title": "Ask %@ to allow more?",
        ]
        let chinese = [
            "part.ask.stays": "如果你允許，這台裝置原本的登入在 %1$@ 那邊仍然有效——你的其他裝置才能照常使用——直到你在這裡登出為止。",
            "part.ask.same": "如果 %1$@ 已經有一個內容完全相同的登入，你登入之後那一頁不會再多問。",
            "part.ask.refused": "這一項在 %@ 的頁面上被拒絕了。再問一次",
            "part.ask.none": "%@ 沒有這一項可以允許。",
            "part.ask.stranded": "這次執行期間無法向 %@ 詢問這一項。",
            "part.ask.again": "這個登入實際有的，和剛才問你的不一樣，所以再問一次。",
            "part.ask.again.without": "%@ 沒有剛才那個問題問的其中一項，所以去掉那一項再問一次。",
            "part.ask.coarse": "%@ 上的這個登入無法在原處再加上項目。請登出後重新登入，並選擇要允許的項目。",
            "part.notices.ask.beside": "因為這個登入之後既能以你的身分寫入，又能讀取通知，它的頁面還會問移除通知，以及放行或放下被擋下的通知。",
            "part.ask.held": "%@ 已經允許這一項了。",
            "part.ask.reads": "%@ 上的這個登入只能讀取，所以沒有詢問。要加上這一項，請先登入來讀與寫。",
            "part.ask.asking": "Fediqo 正在詢問 %@。",
            "part.several.ask.title": "請 %@ 允許更多？",
        ]
        func specifiers(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%(\\d\\$)?[@d]")
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        var keys = Array(english.keys)
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        for part in MastodonPart.allCases {
            keys += ["title", "line", "detail"].map { "part.\(part.rawValue).ask.\($0)" }
            // A part that kept the line its lock always had draws that one, and has no other.
            let own = "part.\(part.rawValue).unasked"
            if PartWords.earlier[part] == nil {
                keys.append(own)
            } else {
                for table in tables { #expect(!table.contains("\n\"\(own)\""), "\(own) is written and drawn nowhere") }
            }
        }
        for key in keys.sorted() {
            for table in tables { #expect(table.contains("\n\"\(key)\" = \""), "\(key) is missing from a table") }
            let en = L10n.t(key, language: .english)
            let zh = L10n.t(key, language: .taiwanese)
            #expect(en != key && zh != key && en != zh)
            #expect(specifiers(en) == specifiers(zh), "\(key) takes other arguments in Chinese")
            if let words = english[key] { #expect(en == words) }
            if let words = chinese[key] { #expect(zh == words) }
        }
        #expect(tables[1] == tables[2])
    }
}
