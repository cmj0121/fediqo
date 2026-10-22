import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347 — a part held in part: a sign-in with one word of it and not the other, as signing in
/// again to read only leaves follows. It stands so, with a line of its own whose press asks
/// for the rest — where the rest was never asked, and the sign-in is one a page can be built
/// over.
///
/// Every word a page is held against is written out here.
@MainActor
@Suite("A part held in part is asked for the rest where the sign-in stands")
struct PartRestTests {
    private typealias S = PartServer
    private let host = "social.example"
    private static let r = "read:statuses read:lists read:accounts"
    private static let reads = "\(r) read:search"
    private static let sees = "\(reads) read:follows"

    /// A session holding `scopes` at the host under the token string `held-1`, asked for
    /// `asked` — for what it holds, where nothing else is said.
    private func shell(
        holding scopes: String, asked: String? = nil
    ) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes, asked: asked ?? scopes
        ))
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    private func kept(_ tokens: MemoryMastodonTokens) throws -> [String?] {
        let token = try tokens.token(host: host)
        return [token?.accessToken, token?.scopes, token?.asked, token?.refused, token?.stamp]
    }

    /// The press for `part` as a place makes it, and the yes to its question.
    private func allow(_ part: MastodonPart, _ session: ShellSession, through page: PartPage) async throws {
        #expect(session.askFor([part], host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)
    }

    @Test("A sign-in that sees who the person follows and cannot follow is asked for the rest where it stands: its page asks what it holds and the one word it lacks, the sign-in that comes back holds follows whole, and the one it had is left live with nothing ended")
    func theRestOfFollows() async throws {
        let (session, server, tokens) = try await shell(holding: Self.sees)
        #expect(session.mastodon.standing(.follows, host: host) == .partly)
        #expect(session.mastodon.mayAsk(.follows, host: host))
        #expect(session.askFor([.follows], host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.said == "read:statuses read:lists read:accounts read:search read:follows write:follows")
        #expect(await server.requests.isEmpty, "a press sent something")

        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == ["read:statuses read:lists read:accounts read:search read:follows write:follows"])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(session.mastodon.standing(.follows, host: host) == .held)
        #expect(!session.mastodon.mayAsk(.follows, host: host))
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        #expect(session.mastodon.grants[host] == .reading)
    }

    @Test("The other word alone is asked for the same way, and so is the rest of writing: the page adds the word lacked and no other", arguments: [0, 1])
    func theOtherHalf(_ index: Int) async throws {
        let cases: [(held: String, part: MastodonPart, page: String)] = [
            ("\(Self.reads) write:follows", .follows, "\(Self.reads) read:follows write:follows"),
            ("\(Self.reads) write:statuses", .acting, "\(Self.reads) write:statuses write:favourites"),
        ]
        let use = cases[index]
        let (session, server, _) = try await shell(holding: use.held)
        #expect(session.mastodon.standing(use.part, host: host) == .partly)
        let page = PartPage()
        try await allow(use.part, session, through: page)
        #expect(page.scopes == [use.page])
        #expect(session.mastodon.standing(use.part, host: host) == .held)
        #expect(await server.revoked.isEmpty)
    }

    @Test("Reading held in part is not asked for where the sign-in stands, and neither is any part held in part by a sign-in that does not read word for word: no page can be built over such a sign-in, so no line offers one and no press raises a question — while a part it was never asked for is still pressed for, and told that the sign-in cannot be added to", arguments: [0, 1])
    func aSignInThatDoesNotReadIsNotAskedForTheRest(_ index: Int) async throws {
        let held = ["read:statuses read:lists read:follows", "read read:follows"][index]
        let (session, server, tokens) = try await shell(holding: held)
        let before = try kept(tokens)
        #expect(session.mastodon.standing(.follows, host: host) == .partly)
        #expect(!session.mastodon.mayAsk(.follows, host: host))
        #expect(!session.askFor([.follows], host: host))
        if index == 0 {
            #expect(session.mastodon.standing(.reading, host: host) == .partly)
            #expect(!session.mastodon.mayAsk(.reading, host: host))
            #expect(!session.askFor([.reading], host: host))
        }
        let page = PartPage()
        let partly: Set<MastodonPart> = index == 0 ? [.reading, .follows] : [.follows]
        #expect(await session.mastodon.ask(partly, host: host, through: page) == .nothingLeft)

        // Never asked, it is pressed for as it always was — and the yes says why no page opens.
        #expect(session.mastodon.mayAsk(.acting, host: host))
        try await allow(.acting, session, through: page)
        #expect(page.opened == 0)
        // A source's account of a sign-in without the words of reading is no account of one;
        // one naming its one word for every read is, of a sign-in no page is built over.
        let said = [
            "Fediqo could not confirm whose sign-in this is at social.example, so it was not asked. Try again later, or sign out and sign in again, choosing what to allow.",
            "This sign-in at social.example cannot be added to where it stands. Sign out and sign in again, choosing what to allow.",
        ]
        #expect(session.toast?.text == said[index])
        #expect(try kept(tokens) == before)
        #expect(await server.revoked.isEmpty)
    }

    @Test("A part held in part whose missing word was asked for and not given is not asked for again: the source would answer the same, and what is held of it goes on being offered")
    func askedAndNotGivenIsNotAskedAgain() async throws {
        let (session, _, _) = try await shell(holding: Self.sees, asked: "\(Self.sees) write:follows")
        #expect(session.mastodon.standing(.follows, host: host) == .partly)
        #expect(!session.mastodon.mayAsk(.follows, host: host))
        #expect(!session.askFor([.follows], host: host))
        #expect(session.partAsks.open == nil)
    }

    @Test("The rest refused on the source's page stands refused and is asked again by its own line; a source whose list has none of the word lacked is said to have none, once, and is not paged or asked again — and either way the sign-in held is the one it was, still seeing who the person follows")
    func refusedOrNone() async throws {
        let (refusing, _, refusedTokens) = try await shell(holding: Self.sees)
        let no = PartPage(.refuse)
        try await allow(.follows, refusing, through: no)
        #expect(no.opened == 1)
        #expect(refusing.mastodon.standing(.follows, host: host) == .refused)
        #expect(refusing.mastodon.mayAsk(.follows, host: host))
        let after = try #require(try refusedTokens.token(host: host))
        #expect(after.accessToken == "held-1" && after.scopes == Self.sees)
        #expect(after.refused == "read:follows write:follows")

        let (session, server, tokens) = try await shell(holding: Self.sees)
        let words = Self.sees.split(separator: " ").map(String.init)
        await server.lists(words + ["write:statuses", "write:favourites", "write:bookmarks", "read:notifications", "write:notifications"])
        let page = PartPage()
        try await allow(.follows, session, through: page)
        #expect(page.opened == 0)
        #expect(session.toast?.text == "social.example has none to allow.")
        #expect(!session.mastodon.mayAsk(.follows, host: host))
        #expect(!session.askFor([.follows], host: host))
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "held-1" && now.scopes == Self.sees)
        #expect(MastodonParts.holds(.reading, in: now.scopes))
        #expect(await server.revoked.isEmpty)

        // A source with no list, which registers for none of it: said for this run, and
        // written nowhere — the source named no word.
        let (quiet, silent, unlisted) = try await shell(holding: Self.sees)
        await silent.registersNone(of: ["write:follows"])
        let unopened = PartPage()
        try await allow(.follows, quiet, through: unopened)
        #expect(unopened.opened == 0)
        #expect(quiet.toast?.text == "social.example has none to allow.")
        #expect(try unlisted.token(host: host)?.asked == Self.sees)
        #expect(quiet.mastodon.standing(.follows, host: host) == .partly)
        #expect(!quiet.mastodon.mayAsk(.follows, host: host))
        #expect(quiet.mastodon.place(.follows, host: host) == nil)
    }

    // MARK: - The line, and the question

    @Test("A part held in part whose rest may be asked for draws a line of its own, derived from the never-asked one, and its press asks; while the source is being asked it cannot be pressed; and where the rest may not be asked for — asked and not given, or a sign-in no page is built over — nothing is drawn, and what is held goes on being offered")
    func theLine() async throws {
        let (session, _, _) = try await shell(holding: Self.sees)
        let place = try #require(session.mastodon.place(.follows, host: host))
        // Its line says the half it lacks: this one sees, and was not asked to change.
        #expect(place.kind == .partly && place.asks)
        #expect(String(format: L10n.t(place.key, language: .english), host) == "This sign-in was not asked to follow or unfollow. Update permission")
        #expect(String(format: L10n.t(place.key, language: .taiwanese), host) == "這個登入還沒被問過追蹤與取消追蹤。更新權限")
        // And one that changes, and was not asked to see.
        let (blind, _, _) = try await shell(holding: "\(Self.reads) write:follows")
        let unseen = try #require(blind.mastodon.place(.follows, host: host))
        #expect(unseen.kind == .partly && unseen.asks)
        #expect(unseen.key != place.key)
        #expect(String(format: L10n.t(unseen.key, language: .english), host) == "This sign-in was not asked to see who you follow. Update permission")
        #expect(String(format: L10n.t(unseen.key, language: .taiwanese), host) == "這個登入還沒被問過查看你追蹤的對象。更新權限")
        // A part with no such halves says it was asked for part of it.
        let (half, _, _) = try await shell(holding: "\(Self.reads) write:statuses")
        let acting = try #require(half.mastodon.place(.acting, host: host))
        #expect(acting == PartWords.Place(kind: .partly, key: "part.acting.partly"))
        #expect(acting == PartWords.place(.partly, of: .acting, rest: true))
        #expect(L10n.t("part.acting.partly", language: .english) == "This sign-in was asked for only part of writing as you. Update permission")
        #expect(L10n.t("part.acting.partly", language: .taiwanese) == "這個登入只被問過以你的身分寫入的一部分。更新權限")
        let asking = PartWords.place(.partly, of: .follows, asking: true, rest: true)
        #expect(asking == PartWords.Place(kind: .asking, key: "part.ask.asking") && asking?.asks == false)
        // Not to be asked for, it draws nothing — whatever else is going on.
        #expect(PartWords.place(.partly, of: .follows) == nil)
        #expect(PartWords.place(.partly, of: .follows, asking: true) == nil)
        // A whole standing draws what it drew, whatever is said of a rest it has none of.
        #expect(PartWords.place(.unasked, of: .follows, rest: true) == PartWords.place(.unasked, of: .follows))
        #expect(PartWords.place(.held, of: .follows, rest: true) == nil)

        let (given, _, _) = try await shell(holding: Self.sees, asked: "\(Self.sees) write:follows")
        #expect(given.mastodon.place(.follows, host: host) == nil)
        let (coarse, _, _) = try await shell(holding: "read read:follows")
        #expect(coarse.mastodon.place(.follows, host: host) == nil)
        #expect(coarse.mastodon.place(.reading, host: host)?.kind == .unasked)
        #expect(session.mastodon.place(.follows, host: "nobody.example") == nil)
        // Every part that can be held in part and asked for the rest has its line written.
        let multi = MastodonPart.allCases.filter { $0.words.count > 1 && $0 != .reading }
        #expect(multi == [.acting, .follows, .marks, .blocks, .tending])
        let marks = PartWords.place(.partly, of: .marks, rest: true)
        #expect(marks?.key == "part.marks.partly")
        for key in [place.key, unseen.key, acting.key, marks?.key ?? ""] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key)
            }
        }
    }

    @Test("A yes that finds nothing left to ask of a part held in part says how the sign-in stands to it, as every other standing is said: it has part of it, and the rest is not asked for where it stands")
    func nothingLeftOfAPartHeldInPartIsSaid() async throws {
        let (session, server, _) = try await shell(holding: Self.sees, asked: "\(Self.sees) write:follows")
        let ask = PartAsk(host: host, ticked: [.follows], said: "\(Self.sees) write:follows", givesUp: [], stamp: session.mastodon.heldParts[host]?.stamp)
        let page = PartPage()
        await session.allow(ask, through: page)
        #expect(page.opened == 0)
        #expect(await server.requests.isEmpty)
        #expect(session.toast?.text == "This sign-in at social.example has part of this, and the rest cannot be asked for where it stands. Sign out and sign in again, choosing what to allow.")
        #expect(String(format: L10n.t("part.ask.partly", language: .taiwanese), host) == "social.example 上的這個登入已經有這一項的一部分，剩下的無法在原處再問。請登出後重新登入，並選擇要允許的項目。")
    }

    @Test("The question about the rest of a part says the sign-in already has part of it and the page adds only the rest — in English and in Traditional Chinese — and a question about a part never asked says no such thing")
    func theQuestionSaysItIsTheRest() async throws {
        let (session, _, _) = try await shell(holding: Self.sees)
        #expect(session.askFor([.follows], host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.rest == [.follows])
        let english = ShellQuestion.part(ask, language: .english)
        let said = english.line + " " + (english.help ?? "")
        #expect(said.contains("This sign-in already has part of this, and the page adds only the rest."))
        #expect(english.title == "Ask social.example to allow following?")
        let chinese = ShellQuestion.part(ask, language: .taiwanese)
        #expect((chinese.line + (chinese.help ?? "")).contains("這個登入已經有這一項的一部分，那一頁只會加上剩下的。"))

        let (never, _, _) = try await shell(holding: Self.reads)
        #expect(never.askFor([.follows], host: host))
        let whole = try #require(never.partAsks.open)
        #expect(whole.rest.isEmpty)
        let plain = ShellQuestion.part(whole, language: .english)
        #expect(!(plain.line + " " + (plain.help ?? "")).contains("already has part of this"))
    }
}
