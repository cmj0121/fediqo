import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Somebody's page built from values, as the timeline pane builds it from the pages: what a
/// hosted check lays out.
@MainActor
enum HostedPersonPage {
    static func page(
        _ person: DummyPerson, said: PersonSaid?, standing: PersonActing? = nil, own: Bool = false, front: PersonTab? = nil,
        held: [DummyItem] = [], pinned: PersonPinnedSaid? = nil, people: PeopleSaid? = nil, canReload: Bool = false,
        home: PersonHomeSaid? = nil, homeLine: PersonHomeLine? = nil
    ) -> PersonPage {
        let tabs = ShellPersonTabs.tabs(said: said, own: own)
        let hidden = said?.person.map { $0.hidesLists && !tabs.contains(.following) } ?? false
        return PersonPage(
            person: person, tabs: tabs, front: front ?? tabs[0],
            head: PersonHeadSaid.made(of: person, said: said, tabs: tabs, held: held.count, standing: standing),
            said: said,
            about: said.map { PersonAboutSaid.made(of: $0, home: home, homeLine: homeLine, standing: standing, followed: nil, hidden: hidden) },
            posts: PostRowsSaid.posts(of: said, held: held, standing: standing),
            pinned: pinned.map { PostRowsSaid.pinned($0) }, people: people, home: homeLine,
            rows: PersonPageRows(
                catalogues: EmojiCatalogueStore(), posts: ForumPosts(), playback: ShellPlayback(),
                onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in }
            ),
            selectedID: .constant(nil), decks: .constant(ShellDecks()), jumpToTop: 0, slide: PageSlide(), canReload: canReload
        )
    }
}

/// F9: somebody's page as a page of its own — which tabs it has in each state, the figures
/// and the marks of its head, what each tab asks of the source and when, how its tabs are
/// turned and the page left, what it says in each language, and that it lays out.
///
/// **No check here waits on the clock.** Each waits on an ask arriving at `PageServer` or on
/// the call that made it returning; a held ask is let go by the check, and by the server after
/// its patience.
@MainActor
@Suite("Somebody's page, a page of its own", .serialized, .timeLimit(.minutes(1)))
struct PersonPageTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!

    private static let who = "/api/v1/accounts/verify_credentials"
    private static let lookup = "/api/v1/accounts/lookup?acct=ada"
    private static let statuses = "/api/v1/accounts/42/statuses"
    private static let pinned = "/api/v1/accounts/42/statuses?pinned=true"
    private static let following = "/api/v1/accounts/42/following?limit=80"
    private static let followers = "/api/v1/accounts/42/followers?limit=80"
    private static func stands(_ id: Int) -> String { "/api/v1/accounts/relationships?id%5B%5D=\(id)" }

    private static func account(_ more: String = "") -> String {
        #"{"id":"42","acct":"ada","display_name":"Ada","note":"<p>Counts things</p>","followers_count":2811,"following_count":310,"statuses_count":1204\#(more)}"#
    }

    private static func status(_ id: Int) -> String {
        #"""
        {"id":"\#(id)","uri":"https://m.example/users/ada/statuses/\#(id)","created_at":"2026-10-0\#(id % 9 + 1)T00:00:00.000Z",
         "content":"<p>post \#(id)</p>","visibility":"public","account":{"acct":"ada","display_name":"Ada"}}
        """#
    }

    private static func posts(_ ids: [Int], link: String? = nil) -> PageServer.Answer {
        PageServer.Answer(body: "[" + ids.map(status).joined(separator: ",") + "]", link: link)
    }

    private static func people(_ id: Int, _ name: String) -> PageServer.Answer {
        PageServer.Answer(body: #"[{"id":"\#(id)","acct":"\#(name)"}]"#)
    }

    private static func served(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            who: PageServer.Answer(body: #"{"id":"1","acct":"me","username":"me"}"#),
            lookup: PageServer.Answer(body: account()), statuses: posts([9, 8, 7]),
            // As the source lists them: the post pinned last first, which is not the order of their ids.
            pinned: posts([3, 9, 5]),
            following: people(7, "bo"), followers: people(8, "cy"),
            stands(42): PageServer.Answer(body: #"[{"id":"42","following":true,"followed_by":true}]"#),
            stands(7): PageServer.Answer(body: "[]"), stands(8): PageServer.Answer(body: "[]"),
        ].merging(more) { $1 }
    }

    private func session(_ routes: [String: PageServer.Answer] = served()) async -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.work = SourceWork()
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server)
    }

    /// Signs in holding who the reader follows, and has the source say who the reader is.
    private func signIn(_ session: ShellSession) async throws {
        let scopes = "read:statuses read:lists read:accounts read:search read:follows write:follows"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    /// Brings `tab` in front on ada's page and lets it ask, as its task does when it is drawn.
    private func bring(_ tab: PersonTab, in pages: ShellPersonPages, _ session: ShellSession) async {
        var lamp: String?
        pages.turn(Self.ada, to: tab, lamp: &lamp, in: session)
        await pages.fronted(Self.ada, in: session)
    }

    private func person(_ more: String = "") throws -> Person {
        try MastodonPeople.person(from: Data(Self.account(more).utf8), source: Self.source)
    }

    // MARK: - Which tabs a page has

    @Test("The strip is About · Following · Followers · Pinned · Posts, in that order, once the source has said who they are; About · Posts until then, and for good where it has not heard of them, could not be asked, or suspended them; where the account hides its lists both list tabs are absent — never on the reader's own page; and a page handed no word of a source has their posts alone")
    func theStripInEachState() throws {
        #expect(PersonTab.allCases == [.about, .following, .followers, .pinned, .posts])
        #expect(ShellPersonTabs.tabs(said: nil, own: false) == [.posts])
        for reading in [PersonSaid.Reading.asking, .unheardOf, .failed] {
            #expect(ShellPersonTabs.tabs(said: PersonSaid(source: Self.host, reading: reading), own: false) == [.about, .posts], "\(reading)")
        }
        func said(_ more: String) throws -> PersonSaid { PersonSaid(source: Self.host, reading: .said(try person(more))) }
        #expect(ShellPersonTabs.tabs(said: try said(""), own: false) == PersonTab.allCases)
        #expect(ShellPersonTabs.tabs(said: try said(#","hide_collections":true"#), own: false) == [.about, .pinned, .posts])
        #expect(ShellPersonTabs.tabs(said: try said(#","hide_collections":true"#), own: true) == PersonTab.allCases)
        #expect(ShellPersonTabs.tabs(said: try said(#","suspended":true"#), own: false) == [.about, .posts])
        // Asked again and failed: what it said stands, and so do its tabs.
        var troubled = try said("")
        troubled.again = .failed
        #expect(ShellPersonTabs.tabs(said: troubled, own: false) == PersonTab.allCases)

        // A strip only where there is more than one tab, and the names and glyphs each tab has.
        #expect(!PersonPage.stripDrawn([.posts]) && PersonPage.stripDrawn([.about, .posts]))
        #expect(PersonTab.allCases.map(\.symbol) == ["person.text.rectangle", "person.line.dotted.person", "person.2", "pin", "text.bubble"])
        #expect(PersonTab.allCases.map { L10n.t($0.titleKey, language: .english) } == ["About", "Following", "Followers", "Pinned", "Posts"])
        #expect(PersonTab.allCases.map { L10n.t($0.titleKey, language: .taiwanese) } == ["關於", "跟隨中", "跟隨者", "釘選", "貼文"])
        #expect(ShellTabs<PersonTab>.listed(PersonTab.allCases, selected: .about, language: .english).map(\.current) == [true, false, false, false, false])
    }

    @Test("About is in front on opening and does not move when the other tabs arrive; a page keeps the tab it was left on by who they are, and falls back to its first where it no longer has that tab; a forum author's page has their posts alone, asks nobody, and is in front of nothing else")
    func aboutIsInFront() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        #expect(pages.tabs(of: Self.ada, in: session) == [.about, .posts] && pages.front(of: Self.ada, in: session) == .about)
        await pages.opened(Self.ada, in: session)
        #expect(pages.tabs(of: Self.ada, in: session) == PersonTab.allCases && pages.front(of: Self.ada, in: session) == .about)

        var lamp: String? = "about.words"
        let turned = pages.turn(Self.ada, to: .followers, lamp: &lamp, in: session)
        #expect(turned && lamp == nil && pages.front(of: Self.ada, in: session) == .followers)
        lamp = "somebody"
        let again = pages.turn(Self.ada, to: .followers, lamp: &lamp, in: session)
        #expect(!again && lamp == "somebody", "the tab already in front changes nothing")
        // Each tab keeps its own lamp.
        _ = pages.turn(Self.ada, to: .about, lamp: &lamp, in: session)
        #expect(lamp == "about.words")
        _ = pages.turn(Self.ada, to: .followers, lamp: &lamp, in: session)
        #expect(lamp == "somebody")

        // The account turns out suspended: the tab it was left on is gone, and About is in front.
        await server.answer(Self.lookup, PageServer.Answer(body: Self.account(#","suspended":true"#)))
        await pages.again(Self.ada, in: session)
        #expect(pages.tabs(of: Self.ada, in: session) == [.about, .posts] && pages.front(of: Self.ada, in: session) == .about)
        let refused = pages.turn(Self.ada, to: .pinned, lamp: &lamp, in: session)
        #expect(!refused, "a tab the page has not is not brought in front")

        let author = DummyPerson(making: Note(
            id: "https://forum.example/bob/1", source: Self.forum, author: "bob", handle: "", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))!
        #expect(pages.tabs(of: author, in: session) == [.posts] && pages.front(of: author, in: session) == .posts)
        let before = await server.asked.count
        await pages.opened(author, in: session)
        await pages.fronted(author, in: session)
        await pages.again(author, in: session)
        #expect(await server.asked.count == before && !pages.rotate(author, by: 1, lamp: &lamp, in: session))
    }

    // MARK: - The head

    @Test("The figures are glyph and number in the order posts, followers, following — each the source's figure whole, its thousands apart, wearing its tab's glyph and bringing that tab in front; one the source did not say is the glyph alone and still a press; a list the account hides keeps its figure, opens nothing and says so; a suspended account has its posts' figure alone")
    func theFigures() throws {
        let en = DummyLanguage.english
        let all = PersonTab.allCases
        let figures = PersonSaid.figures(of: try person(), tabs: all, language: en)
        #expect(figures.map(\.tab) == [.posts, .followers, .following])
        #expect(figures.map(\.figure) == ["1,204", "2,811", "310"])
        #expect(figures.map(\.words) == ["1,204 posts", "2,811 followers", "Follows 310"])
        #expect(figures.allSatisfy { $0.opens && !$0.hidden } && figures.map { $0.spoken(language: en) } == figures.map(\.words))
        #expect(PersonSaid.Figure.hint(language: en) == "Shows it on this page" && PersonSaid.Figure.hint(language: .taiwanese) == "在這一頁顯示")
        let large = Person(source: Self.source, accountID: "1", handle: "@a@m.example", name: "a", tally: Person.Tally(followers: 3_000_000_000))
        #expect(PersonSaid.figures(of: large, tabs: all, language: en).map(\.figure) == [nil, "3,000,000,000", nil], "never shortened, never made up")

        // No figure said: each is its glyph alone, named by what it would count, and still a press.
        let unsaid = PersonSaid.figures(of: Person(source: Self.source, accountID: "1", handle: "@a@m.example", name: "a"), tabs: all, language: en)
        #expect(unsaid.map(\.figure) == [nil, nil, nil] && unsaid.allSatisfy(\.opens))
        #expect(unsaid.map(\.words) == ["Posts", "Who follows them", "Who they follow"])

        // Hidden lists: no tab, so the figures stay as said, open nothing, and say why.
        let hides = try person(#","hide_collections":true"#)
        let hidden = PersonSaid.figures(of: hides, tabs: ShellPersonTabs.tabs(said: PersonSaid(source: Self.host, reading: .said(hides)), own: false), language: en)
        #expect(hidden.map(\.opens) == [true, false, false] && hidden.map(\.hidden) == [false, true, true])
        #expect(hidden.map { $0.spoken(language: en) } == ["1,204 posts", "2,811 followers. They hide this list.", "Follows 310. They hide this list."])
        let bare = Person(source: Self.source, accountID: "1", handle: "@a@m.example", name: "a", hidesLists: true)
        #expect(PersonSaid.figures(of: bare, tabs: [.about, .pinned, .posts], language: en).map(\.tab) == [.posts], "a figure nobody said, that opens nothing, is nothing")

        let gone = try person(#","suspended":true"#)
        #expect(PersonSaid.figures(of: gone, tabs: [.about, .posts], language: en).map(\.words) == ["1,204 posts"])
    }

    @Test("A figure pressed brings its tab in front, and the tab's own task then asks what it needs: the press itself asks the source nothing")
    func aFigureBringsItsTabInFront() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        let head = pages.head(of: Self.ada, in: session)
        #expect(head.figures.map(\.tab) == [.posts, .followers, .following] && head.figures.allSatisfy(\.opens))
        var lamp: String?
        for figure in head.figures {
            let turned = pages.turn(Self.ada, to: figure.tab, lamp: &lamp, in: session)
            #expect(turned && pages.front(of: Self.ada, in: session) == figure.tab)
        }
        #expect(await asked(server) == [Self.lookup])
        #expect(pages.fronting(Self.ada, in: session).tab == .following && pages.fronting(Self.ada, in: session).accountID == "42")
    }

    @Test("The marks after the name each have their words — the lock, an automated or group account, a limited one, one living elsewhere — and so has every way the reader stands, in the order the head draws them; the head is one element of who they are to a listener, and how the reader stands another")
    func everyGlyphHasItsWords() throws {
        let en = DummyLanguage.english
        let every = try MastodonPeople.person(
            from: Data(#"{"id":"1","acct":"a@far.example","locked":true,"bot":true,"limited":true}"#.utf8), source: Self.source
        )
        let marks = PersonSaid.marks(of: every, source: Self.host, language: en)
        #expect(marks.map(\.symbol) == ["lock", "eye.slash", "gearshape.2", "point.3.connected.trianglepath.dotted"])
        #expect(marks.map(\.words) == [
            "Asks before anyone may follow", "m.example limits this account.", "An automated account.",
            "m.example knows only part of someone who lives elsewhere.",
        ])
        let said = PersonSaid(source: Self.host, reading: .said(every))
        let head = PersonHeadSaid.made(of: Self.ada, said: said, tabs: PersonTab.allCases, held: 0, standing: nil, language: en)
        #expect(head.marks == marks && head.whose == "m.example")
        #expect(head.spoken(language: en) == every.lineName + ", @a@far.example, As m.example says. They live on far.example., " + marks.map(\.words).joined(separator: ", "))
        // Suspended and moved are the page's line over every tab, and no mark after the name.
        let moved = try person(#","suspended":true,"moved":{"id":"7","acct":"ada@new.example"}"#)
        #expect(PersonSaid.marks(of: moved, source: Self.host).isEmpty)
        #expect(PersonSaid.standing(of: moved, source: Self.host)?.symbol == PersonSaid.gone)

        let until = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")
        let standing = PersonStanding(
            accountID: "42", following: true, followedBy: true, requested: true, muting: true, mutedUntil: until, blocking: true
        )
        let stands = PersonActing.marks(of: standing, language: en)
        #expect(stands.map(\.symbol) == ["person.fill.checkmark", "person.badge.plus", "person.badge.clock", "speaker.slash", "hand.raised"])
        #expect(stands.map(\.words).prefix(3) == ["You follow them", "Follows you", "Asked"] && stands[3].words.hasPrefix("Muted until") && stands[4].words == "Blocked")
        #expect(Set(stands.map(\.words)) == Set(PersonActing.pills(of: standing, language: en)), "the words a row says them in")
        #expect(PersonActing.spoken(stands, language: en) == stands.map(\.words).joined(separator: ", "))
        // A way the reader does not stand has no glyph: there is no glyph for "not".
        #expect(PersonActing.marks(of: PersonStanding(accountID: "42"), language: en).isEmpty)
        let asking = PersonActing(source: Self.host, named: "@ada", reading: .asking, changes: true)
        #expect(asking.marks().isEmpty && asking.askingWords(language: en) == "Asking m.example how you stand to them…")
        let neither = PersonActing(source: Self.host, named: "@ada", reading: .said(PersonStanding(accountID: "42")), changes: true)
        #expect(neither.neitherWords(language: en) == "Neither of you follows the other." && asking.neitherWords() == nil)
        #expect(PersonPage.reloadName("m.example", language: en) == "Ask m.example again")
    }

    @Test("The page's line is one at a time, the first that applies: asking, could not ask with the press that asks again, not heard of, asked again and failed, suspended, moved with where its press opens — and nothing once the source has said who an ordinary account is")
    func thePagesLine() throws {
        let en = DummyLanguage.english
        func line(_ said: PersonSaid) -> PersonLineSaid? { PersonLineSaid.made(of: said, named: "@ada@m.example", language: en) }
        let asking = try #require(line(PersonSaid(source: Self.host, reading: .asking)))
        #expect(asking.faint && !asking.again && asking.words == "Asking m.example for @ada@m.example…")
        let failed = try #require(line(PersonSaid(source: Self.host, reading: .failed)))
        #expect(!failed.faint && failed.again && failed.words == "Could not ask m.example for @ada@m.example. What this device holds of theirs is under Posts.")
        let unheard = try #require(line(PersonSaid(source: Self.host, reading: .unheardOf)))
        #expect(!unheard.again && unheard.words == "m.example has not heard of them. What this device holds of theirs is under Posts.")
        #expect(line(PersonSaid(source: Self.host, reading: .said(try person()))) == nil)

        let gone = try person(#","suspended":true,"moved":{"id":"7","acct":"ada@new.example"}"#)
        let suspended = try #require(line(PersonSaid(source: Self.host, reading: .said(gone))))
        #expect(suspended.words == "m.example says this account is suspended." && suspended.symbol == PersonSaid.gone && suspended.moved == nil)
        // Asked again and failed comes before what has become of the account.
        let troubled = try #require(line(PersonSaid(source: Self.host, reading: .said(gone), again: .failed)))
        #expect(troubled.again && troubled.words == "Could not ask m.example again. What it said before is still here.")
        let moved = try #require(line(PersonSaid(source: Self.host, reading: .said(try person(#","moved":{"id":"7","acct":"ada@new.example"}"#)))))
        #expect(moved.moved?.handle == "@ada@new.example" && moved.words == "They moved to @ada@new.example.")
        // The ask being out is said to the press: it is drawn, and takes none.
        #expect(line(PersonSaid(source: Self.host, reading: .failed, asking: true))?.busy == true)
    }

    // MARK: - About

    @Test("About says, top to bottom: whose view this is, the account's sentences, their picture, their words, their fields, how the reader stands, and the line about their own server — each a block the lamp stops on; the words of each standing beside the glyph the head draws alone; that neither follows the other; that it is being asked; that the account hides its lists; and where the source said nothing more, that")
    func whatAboutSays() throws {
        let en = DummyLanguage.english
        let plain = PersonSaid(source: Self.host, reading: .said(try person()))
        func about(_ said: PersonSaid, standing: PersonActing? = nil, home: PersonHomeLine? = nil, hidden: Bool = false) -> PersonAboutSaid {
            PersonAboutSaid.made(of: said, home: nil, homeLine: home, standing: standing, followed: nil, hidden: hidden, language: en)
        }
        let bare = about(plain)
        #expect(bare.view == "As m.example says." && bare.blocks == [.view, .words] && bare.none == nil)
        #expect(bare.walked == ["about.view", "about.words"])

        let full = try person(#","locked":true,"bot":true,"header":"https://m.example/h.png","fields":[{"name":"Site","value":"example.org"}]"#)
        let stands = PersonActing(
            source: Self.host, named: "@ada@m.example", reading: .said(PersonStanding(accountID: "42", following: true)), changes: true
        )
        let line = PersonHomeLine(words: nil, press: .ask, pressWords: "Ask far.example")
        let every = about(PersonSaid(source: Self.host, reading: .said(full)), standing: stands, home: line, hidden: true)
        #expect(every.blocks == [.view, .sentences, .picture, .words, .fields, .stands, .home])
        #expect(every.sentences.map(\.words) == [
            "Asks before anyone may follow", "An automated account.", "@ada@m.example hides who they follow and who follows them.",
        ])
        #expect(every.press(on: "about.home") == .home(.ask) && every.press(on: "about.words") == nil && every.press(on: "about.stands") == nil)

        // The source said who they are and nothing more.
        let silent = Person(source: Self.source, accountID: "1", handle: "@a@m.example", name: "a")
        let none = about(PersonSaid(source: Self.host, reading: .said(silent)))
        #expect(none.blocks == [.view, .none] && none.none == "m.example said nothing more of them.")
        // Before it has said, whose view the page is and nothing else — and never that it said nothing.
        #expect(about(PersonSaid(source: Self.host, reading: .asking)).blocks == [.view])
        #expect(about(PersonSaid(source: Self.host, reading: .failed)).none == nil)
        // Not heard of: the line about their own server stands over the tabs, and not here.
        #expect(about(PersonSaid(source: Self.host, reading: .unheardOf), home: line).blocks == [.view])

        // How the reader stands: only where somebody stands to them here, and only what there is to say.
        func acting(_ reading: PersonActing.Reading?, lock: PartWords.Place? = nil) -> PersonActing {
            PersonActing(source: Self.host, named: "@ada@m.example", reading: reading, lock: lock, changes: lock == nil)
        }
        #expect(!about(plain).standsDrawn && about(plain, standing: acting(.asking)).standsDrawn)
        #expect(about(plain, standing: acting(.said(PersonStanding(accountID: "42")))).standsDrawn, "neither is said in words")
        #expect(!about(plain, standing: acting(.unsaid)).standsDrawn && about(plain, standing: acting(.failed)).standsDrawn)
        let locked = about(plain, standing: acting(nil, lock: PartWords.Place(kind: .unasked, key: "part.follows.unasked")))
        #expect(locked.standsDrawn && locked.standing?.lockWords(language: en)?.isEmpty == false)
        #expect((locked.press(on: "about.stands") == .askFollows) == (locked.standing?.lock?.asks == true))
    }

    // MARK: - What is asked of the source, and when

    @Test("Opening asks who they are and — signed in — how the reader stands: two asks, one with no sign-in, and none of their posts. Each tab asks when it is first in front and never before: their posts one, what they pinned one, a list its stretch and how the reader stands to the people in it. A page with every tab visited once has cost eight, and nothing is asked by a tab in front again")
    func whatEachTabAsksAndWhen() async throws {
        // With no sign-in: one ask at opening, and one for each tab first in front.
        let (plain, unsigned) = await session()
        let nobody = ShellPersonPages()
        await nobody.opened(Self.ada, in: plain)
        await nobody.standsOpened(to: Self.ada, in: plain)
        await nobody.fronted(Self.ada, in: plain)
        #expect(await asked(unsigned) == [Self.lookup])
        for tab in [PersonTab.posts, .pinned, .following, .followers] { await bring(tab, in: nobody, plain) }
        #expect(await asked(unsigned) == [Self.lookup, Self.statuses, Self.pinned, Self.following, Self.followers])

        // Signed in: two at opening.
        let (session, server) = await session()
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        await pages.standsOpened(to: Self.ada, in: session)
        await pages.fronted(Self.ada, in: session)
        #expect(await asked(server) == [Self.lookup, Self.stands(42)])
        #expect(pages.said(of: Self.ada, in: session)?.posts == nil, "About needs none of their posts")

        await bring(.posts, in: pages, session)
        #expect(await asked(server) == [Self.lookup, Self.stands(42), Self.statuses])
        await bring(.pinned, in: pages, session)
        #expect(await asked(server) == [Self.lookup, Self.stands(42), Self.statuses, Self.pinned])
        await bring(.following, in: pages, session)
        #expect(await asked(server).suffix(2) == [Self.following, Self.stands(7)])
        await bring(.followers, in: pages, session)
        #expect(await asked(server).suffix(2) == [Self.followers, Self.stands(8)])
        #expect(await asked(server).count == 8)

        // Every tab brought in front again, and About: nothing.
        for tab in PersonTab.allCases { await bring(tab, in: pages, session) }
        #expect(await asked(server).count == 8)
        #expect(pages.walked(of: Self.ada, in: session).map(\.statusID) == ["9", "8", "7"])
    }

    @Test("Until their posts answer, what this device holds of theirs stays drawn and the foot says a stretch is on its way; a stretch that does not come is said at the foot, takes nothing away, and is asked again only by the foot's press — never by the tab coming in front again")
    func heldPostsStayUntilTheSourceAnswers() async throws {
        let (session, server) = await session(Self.served([Self.statuses: PageServer.Answer(body: "<html>", status: 500)]))
        let note = Note(
            id: "https://m.example/users/ada/statuses/2", source: Self.source, author: "Ada", handle: "@ada@m.example", body: "held",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        )
        await session.store.ingest([note], ifSourceHere: Self.host)
        await session.reloadFromStore()
        let held = session.heldPosts(of: Self.ada)
        #expect(held.count == 1)
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)

        await server.hold(Self.statuses)
        let fronted = Task { await bring(.posts, in: pages, session) }
        await server.arrival(of: Self.statuses)
        let out = try #require(pages.said(of: Self.ada, in: session))
        #expect(out.askingPosts && out.posts == nil && out.foot == .reading)
        #expect(pages.walked(of: Self.ada, in: session) == held, "what is held stays drawn, and is what the keys walk")
        await server.release(Self.statuses)
        await fronted.value

        let failed = try #require(pages.said(of: Self.ada, in: session))
        #expect(!failed.askingPosts && failed.posts == nil && failed.foot == .failed && pages.walked(of: Self.ada, in: session) == held)
        #expect(PostRowsSaid.posts(of: failed, held: held, standing: nil).items == held)
        await bring(.about, in: pages, session)
        await bring(.posts, in: pages, session)
        #expect(await asked(server) == [Self.lookup, Self.statuses], "a failure is not asked again by looking")

        await server.answer(Self.statuses, Self.posts([9, 8]))
        await pages.readOn(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8"])
    }

    @Test("What they pinned is drawn in the source's own order, never sorted; none pinned is said as what the source gave; a source that passes the word over has no such thing — said the same, written down for the run, and not asked again, by the tab or by asking again; and one that fails says so with a press that asks again")
    func whatTheyPinned() async throws {
        let en = DummyLanguage.english
        let (session, _) = await session()
        let pages = ShellPersonPages()
        #expect(pages.pinned(of: Self.ada, in: session) == nil, "nothing until the source has said who they are")
        await pages.opened(Self.ada, in: session)
        let before = try #require(pages.pinned(of: Self.ada, in: session))
        #expect(!before.answered && before.stateLine(language: en) == "Asking m.example for what they pinned…" && before.nothing() == nil)
        await bring(.pinned, in: pages, session)
        let said = try #require(pages.pinned(of: Self.ada, in: session))
        #expect(said.answered && said.posts.map(\.statusID) == ["3", "9", "5"] && said.foot == .end && said.stateLine() == nil)
        #expect(said.footWords(.end, language: en) == "No more pinned posts: m.example has sent all it gives.")
        #expect(said.footWords(.more, language: en) == "More pinned posts can be read. Press here to read them.")
        #expect(pages.walkedIDs(of: Self.ada, in: session) == said.posts.map(\.id) && pages.walked(of: Self.ada, in: session) == said.posts)
        #expect(pages.isOnlyOnPage(said.posts[0].id, of: Self.ada, in: session), "a pinned post is held when it is opened, as any post of the page")
        let rows = PostRowsSaid.pinned(said, language: en)
        #expect(rows.items == said.posts && rows.line == nil && rows.quiet == nil && rows.foot?.presses == false)

        // None pinned.
        let (empty, _) = await self.session(Self.served([Self.pinned: Self.posts([])]))
        let none = ShellPersonPages()
        await none.opened(Self.ada, in: empty)
        await bring(.pinned, in: none, empty)
        let nothing = try #require(none.pinned(of: Self.ada, in: empty))
        #expect(nothing.answered && nothing.posts.isEmpty && nothing.foot == nil)
        #expect(nothing.nothing(language: en) == "m.example gave no pinned posts of theirs.")

        // A source that does not know the word answers their ordinary posts: never drawn as pinned.
        let ordinary = Self.posts([9, 8, 7], link: #"<https://m.example/api/v1/accounts/42/statuses?max_id=7>; rel="next""#)
        let (deaf, other) = await self.session(Self.served([Self.pinned: ordinary]))
        let absent = ShellPersonPages()
        await absent.opened(Self.ada, in: deaf)
        await bring(.pinned, in: absent, deaf)
        let gave = try #require(absent.pinned(of: Self.ada, in: deaf))
        #expect(gave.answered && gave.posts.isEmpty && gave.nothing(language: en) == "m.example gave no pinned posts of theirs.")
        #expect(absent.tabs(of: Self.ada, in: deaf).contains(.pinned), "the tab stays, and says so")
        await bring(.about, in: absent, deaf)
        await bring(.pinned, in: absent, deaf)
        await absent.again(Self.ada, in: deaf)
        #expect(await asked(other) == [Self.lookup, Self.pinned, Self.lookup], "that host is not asked for it again this run")

        // A failure, and the press that asks again.
        let (broken, flaky) = await self.session(Self.served([Self.pinned: PageServer.Answer(body: "<html>", status: 500)]))
        let failing = ShellPersonPages()
        await failing.opened(Self.ada, in: broken)
        await bring(.pinned, in: failing, broken)
        let failed = try #require(failing.pinned(of: Self.ada, in: broken))
        #expect(failed.failed && failed.stateLine(language: en) == "Could not ask m.example for what they pinned.")
        #expect(PostRowsSaid.pinned(failed, language: en).line == PostRowsSaid.Line(words: "Could not ask m.example for what they pinned.", failed: true, again: true))
        await bring(.about, in: failing, broken)
        await bring(.pinned, in: failing, broken)
        #expect(await asked(flaky) == [Self.lookup, Self.pinned], "not asked again by looking")
        await flaky.answer(Self.pinned, Self.posts([5]))
        await failing.tabs.asked(Self.ada, beside: failing.said(of: Self.ada, in: broken), again: true, in: broken)
        #expect(failing.pinned(of: Self.ada, in: broken)?.posts.map(\.statusID) == ["5"])
    }

    @Test("Asking again asks who they are and the tab in front from its top; every other tab forgets what it held and asks when it is next in front; and a press while an ask is out asks nothing")
    func askingAgain() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        await pages.again(Self.ada, in: session)
        #expect(await asked(server) == [Self.lookup, Self.lookup], "About in front: who they are, and nothing else")

        for tab in [PersonTab.posts, .pinned, .followers] { await bring(tab, in: pages, session) }
        #expect(await asked(server).suffix(3) == [Self.statuses, Self.pinned, Self.followers])
        let list = try #require(pages.list(.followers, of: Self.ada, in: session))
        #expect(pages.lists.said(of: list, in: session)?.people.map(\.accountID) == ["8"])

        await pages.again(Self.ada, in: session)
        #expect(await asked(server).suffix(2) == [Self.lookup, Self.followers], "the tab in front, from its top")
        #expect(pages.lists.said(of: list, in: session)?.reading == .said)
        #expect(pages.said(of: Self.ada, in: session)?.posts == nil && pages.pinned(of: Self.ada, in: session)?.answered == false)
        let count = await asked(server).count
        await bring(.posts, in: pages, session)
        await bring(.pinned, in: pages, session)
        #expect(await asked(server).suffix(2) == [Self.statuses, Self.pinned])
        #expect(await asked(server).count == count + 2)

        // Pinned in front: its posts stay drawn until the answer lands, and the list is forgotten.
        await pages.again(Self.ada, in: session)
        #expect(await asked(server).suffix(2) == [Self.lookup, Self.pinned])
        #expect(pages.lists.said(of: list, in: session)?.reading == .asking && pages.said(of: Self.ada, in: session)?.posts == nil)

        // A press while an ask is out asks nothing.
        await server.hold(Self.lookup)
        let pressed = Task { await pages.again(Self.ada, in: session) }
        await server.arrival(of: Self.lookup, times: 5)
        let out = await asked(server).count
        for _ in 0..<3 { await pages.again(Self.ada, in: session) }
        #expect(await asked(server).count == out)
        await server.release(Self.lookup)
        await pressed.value
    }

    @Test("Asking again and failing — or being told the source no longer knows them — changes nothing held: their posts, what they pinned and a list read before all stand, though none of them is in front, and nothing but who they are was asked")
    func askingAgainAndFailingChangesNothingHeld() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        for tab in [PersonTab.posts, .pinned, .followers, .about] { await bring(tab, in: pages, session) }
        let list = try #require(pages.list(.followers, of: Self.ada, in: session))
        let count = await asked(server).count
        for (answer, trouble) in [(nil, PersonSaid.Trouble.failed), (PageServer.Answer(body: "{}", status: 404), .unheardOf)] as [(PageServer.Answer?, PersonSaid.Trouble)] {
            await server.answer(Self.lookup, answer)
            await pages.again(Self.ada, in: session)
            let said = try #require(pages.said(of: Self.ada, in: session))
            #expect(said.again == trouble && said.posts?.map(\.statusID) == ["9", "8", "7"], "\(trouble)")
            #expect(pages.pinned(of: Self.ada, in: session)?.posts.map(\.statusID) == ["3", "9", "5"], "\(trouble)")
            #expect(pages.lists.said(of: list, in: session)?.people.map(\.accountID) == ["8"], "\(trouble)")
            #expect(pages.tabs(of: Self.ada, in: session) == PersonTab.allCases)
        }
        #expect(await asked(server).suffix(2) == [Self.lookup, Self.lookup])
        #expect(await asked(server).count == count + 2)
        // Each tab brought in front again is drawn from what it held.
        for tab in [PersonTab.posts, .pinned, .followers] { await bring(tab, in: pages, session) }
        #expect(await asked(server).count == count + 2)
    }

    // MARK: - As whoever asked

    /// A sign-in the source has not named: told from the one before by nothing but itself.
    private func signIn(_ session: ShellSession, as access: String) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) {
            _ = try session.mastodon.tokens.forget(held)
            session.mastodon.refresh()
        }
        try session.mastodon.tokens.save(MastodonToken(host: Self.host, accessToken: access, clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    /// The bearers of every ask of `ask`, in the order they were made.
    private func bearers(_ server: PageServer, of ask: String) async -> [String] {
        let asked = await server.asked, bearers = await server.bearers
        return zip(asked, bearers).filter { $0.0 == ask }.map(\.1)
    }

    @Test("What somebody pinned is what the source gave whoever asked: read as one reader it is not there for the next — not to draw, not to hold a post from, not to read on — it is asked once as them, and the first reader's answer, come late, lands nowhere; so with a stretch read on")
    func whatTheyPinnedIsAsWhoeverAsked() async throws {
        let more = "\(Self.pinned)&max_id=5"
        let onward = #"<https://m.example\#(Self.pinned)&max_id=5>; rel="next""#
        let (session, server) = await session(Self.served([Self.pinned: Self.posts([3, 9, 5], link: onward), more: Self.posts([2])]))
        let pages = ShellPersonPages()
        try signIn(session, as: "first")
        await pages.opened(Self.ada, in: session)
        await bring(.pinned, in: pages, session)
        let first = try #require(pages.said(of: Self.ada, in: session))
        let theirs = try #require(pages.pinned(of: Self.ada, in: session))
        #expect(theirs.posts.map(\.statusID) == ["3", "9", "5"] && theirs.foot == .more)
        #expect(pages.tabs.pinnedRead(of: Self.ada, beside: first, in: session)?.posts.count == 3)
        #expect(pages.isOnlyOnPage(theirs.posts[0].id, of: Self.ada, in: session))

        // Another sign-in takes the source, and nothing is pressed: nothing of the first's is the second's.
        try signIn(session, as: "second")
        #expect(pages.pinned(of: Self.ada, in: session) == nil, "the page itself is not drawn for them")
        #expect(pages.tabs.said(of: Self.ada, beside: first, in: session)?.answered == false, "even beside what the first was told")
        #expect(pages.tabs.pinnedRead(of: Self.ada, beside: first, in: session) == nil, "no post of the first's is theirs to hold")
        #expect(!pages.isOnlyOnPage(theirs.posts[0].id, of: Self.ada, in: session))
        // The foot pressed by them reads nothing on, and lets what the first was given go.
        await pages.tabs.readOn(Self.ada, beside: first, in: session)
        #expect(await bearers(server, of: more).isEmpty)

        // Asked afresh, once, as them.
        await pages.opened(Self.ada, in: session)
        #expect(pages.front(of: Self.ada, in: session) == .pinned, "which tab is in front is the person's, whoever reads")
        #expect(pages.pinned(of: Self.ada, in: session)?.answered == false)
        await pages.fronted(Self.ada, in: session)
        await pages.fronted(Self.ada, in: session)
        #expect(await bearers(server, of: Self.pinned) == ["Bearer first", "Bearer second"])
        #expect(pages.pinned(of: Self.ada, in: session)?.posts.count == 3)

        // A reading-on of theirs still out when the next reader comes: its answer lands nowhere.
        await server.hold(more)
        let reading = Task { await pages.pinnedReadOn(Self.ada, in: session) }
        await server.arrival(of: more)
        #expect(pages.pinned(of: Self.ada, in: session)?.foot == .reading)
        try signIn(session, as: "third")
        await pages.opened(Self.ada, in: session)
        await server.release(more)
        await reading.value
        let third = try #require(pages.pinned(of: Self.ada, in: session))
        #expect(!third.answered && third.posts.isEmpty, "the second reader's stretch is nobody's now")

        // And an ask from the top still out: the reader before is answered late, and to nobody.
        await server.hold(Self.pinned)
        let theirsOut = Task { await pages.fronted(Self.ada, in: session) }
        await server.arrival(of: Self.pinned, times: 3)
        try signIn(session, as: "fourth")
        await pages.opened(Self.ada, in: session)
        let fourth = Task { await pages.fronted(Self.ada, in: session) }
        await server.arrival(of: Self.pinned, times: 4)
        await server.releaseOne(Self.pinned)
        await theirsOut.value
        #expect(pages.pinned(of: Self.ada, in: session)?.answered == false, "the third reader's answer is not the fourth's")
        await server.answer(Self.pinned, Self.posts([5]))
        await server.release(Self.pinned)
        await fourth.value
        #expect(pages.pinned(of: Self.ada, in: session)?.posts.map(\.statusID) == ["5"])
        #expect(await bearers(server, of: Self.pinned) == ["Bearer first", "Bearer second", "Bearer third", "Bearer fourth"])
    }

    @Test("A tab brought in front by another reader than the page was opened as shows them nothing of the first's: the page has About and Posts alone until the source has answered them, no figure brings a list in front and nothing is asked by looking; opened again it is asked as them, and the list its tab is, once")
    func aTabBroughtInFrontByAnotherReader() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        try signIn(session, as: "first")
        await pages.opened(Self.ada, in: session)
        await bring(.followers, in: pages, session)
        let list = try #require(pages.list(.followers, of: Self.ada, in: session))
        #expect(pages.lists.said(of: list, in: session)?.people.map(\.accountID) == ["8"])
        let before = await asked(server)

        try signIn(session, as: "second")
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking))
        #expect(pages.tabs(of: Self.ada, in: session) == [.about, .posts] && pages.front(of: Self.ada, in: session) == .about)
        #expect(pages.head(of: Self.ada, in: session).figures.isEmpty && pages.list(.followers, of: Self.ada, in: session) == nil)
        var lamp: String?
        for tab in [PersonTab.followers, .following, .pinned] {
            let turned = pages.turn(Self.ada, to: tab, lamp: &lamp, in: session)
            #expect(!turned, "\(tab)")
        }
        await pages.fronted(Self.ada, in: session)
        #expect(pages.walkedIDs(of: Self.ada, in: session) == ["about.view"] && pages.walked(of: Self.ada, in: session).isEmpty)
        #expect(pages.lists.said(of: list, in: session)?.reading == .asking, "the list the first was given is not drawn for them")
        #expect(await asked(server) == before, "and looking asks nothing")

        await pages.opened(Self.ada, in: session)
        #expect(pages.front(of: Self.ada, in: session) == .followers, "the tab it was left on")
        await pages.fronted(Self.ada, in: session)
        await pages.fronted(Self.ada, in: session)
        #expect(await bearers(server, of: Self.lookup) == ["Bearer first", "Bearer second"])
        #expect(await bearers(server, of: Self.followers) == ["Bearer first", "Bearer second"])
        #expect(pages.lists.said(of: list, in: session)?.people.map(\.accountID) == ["8"])
    }

    // MARK: - Keys, and leaving

    @Test("Tab and ⇧Tab turn the page's own tabs round their ring — ⇧Tab once from About is Posts — only with the page in front and nothing drawn over it; j and k walk the rows of the tab in front: About's blocks, the people of a list, posts; a mark's key has nothing to act on but a post; and Return on a block of About presses it only where it is a press")
    func theKeys() async throws {
        let (session, _) = await session()
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        var lamp: String?
        var seen: [PersonTab] = []
        for _ in 0..<5 {
            let turned = pages.rotate(Self.ada, by: 1, lamp: &lamp, in: session)
            #expect(turned)
            seen.append(pages.front(of: Self.ada, in: session))
        }
        #expect(seen == [.following, .followers, .pinned, .posts, .about], "round the ring, in the strip's order")
        let back = pages.rotate(Self.ada, by: -1, lamp: &lamp, in: session)
        #expect(back && pages.front(of: Self.ada, in: session) == .posts, "⇧Tab once from About is Posts")
        _ = pages.rotate(Self.ada, by: 1, lamp: &lamp, in: session)

        #expect(FediqoRootView.turnsPersonTabs(open: [.person]) && FediqoRootView.turnsPersonTabs(open: [.person, .selection]))
        #expect(!FediqoRootView.turnsPersonTabs(open: [.viewer, .person]) && !FediqoRootView.turnsPersonTabs(open: [.shortcuts, .person]))

        // About: its blocks, the first where j lands; no post for a mark's key; Return on words does nothing.
        let blocks = pages.walkedIDs(of: Self.ada, in: session)
        #expect(blocks == ["about.view", "about.words"] && pages.entry(of: Self.ada, in: session) == "about.view")
        #expect(FediqoRootView.moved(in: blocks, from: nil, by: 1, open: [.person], entry: pages.entry(of: Self.ada, in: session)) == "about.view")
        #expect(pages.walked(of: Self.ada, in: session).isEmpty)
        #expect(FediqoRootView.focused(in: pages.walked(of: Self.ada, in: session), selected: "about.view", open: [.person, .selection]) == .nothing)
        #expect(!pages.pressAbout("about.words", of: Self.ada, in: session) && !pages.pressAbout("about.view", of: Self.ada, in: session))
        var top: String? = "about.words", jump = 0
        let jumped = FediqoRootView.jumpedToTop(in: blocks, standing: .person(Self.ada), place: .timeline, selected: &top, jump: &jump)
        #expect(jumped && top == "about.view" && jump == 1)

        // A list: its people, and Return's row is somebody the list holds.
        await bring(.followers, in: pages, session)
        let list = try #require(pages.list(.followers, of: Self.ada, in: session))
        let people = pages.walkedIDs(of: Self.ada, in: session)
        #expect(people.count == 1 && people == pages.lists.walked(list, in: session) && pages.walked(of: Self.ada, in: session).isEmpty)
        #expect(pages.lists.person(people[0], on: list, in: session)?.accountID == "8")
        #expect(pages.list(.about, of: Self.ada, in: session) == nil && pages.list(.posts, of: Self.ada, in: session) == nil)

        // Posts: post rows, the first where j lands, and the marks' keys act on them.
        await bring(.posts, in: pages, session)
        let posts = pages.walked(of: Self.ada, in: session)
        #expect(posts.map(\.statusID) == ["9", "8", "7"] && pages.walkedIDs(of: Self.ada, in: session) == posts.map(\.id))
        #expect(pages.entry(of: Self.ada, in: session) == posts[0].id)
        #expect(FediqoRootView.focused(in: posts, selected: posts[1].id, open: [.person, .selection]) == .post(posts[1]))
        #expect(!pages.pressAbout("about.view", of: Self.ada, in: session), "About's presses are About's")
    }

    @Test("A tab is not a step: turning tabs takes none, and somebody opened from a row of a list tab is one step out — leaving gives the first page back on the tab it was left on, the lamp on that row")
    func aTabIsNotAStep() async throws {
        let (session, _) = await session()
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        var walk = ShellWalk()
        _ = walk.walk(to: .person(Self.ada), from: "a row of the stream")
        var lamp: String?
        _ = pages.rotate(Self.ada, by: 1, lamp: &lamp, in: session)
        await bring(.followers, in: pages, session)
        #expect(walk.depth == 1 && walk.openedPerson == Self.ada)

        let list = try #require(pages.list(.followers, of: Self.ada, in: session))
        let row = try #require(pages.lists.said(of: list, in: session)?.people.first)
        lamp = row.id
        let stepped = walk.walk(to: .person(DummyPerson(row)), from: row.id)
        #expect(stepped && walk.depth == 2 && pages.front(of: DummyPerson(row), in: session) == .about, "their own page opens on About")
        let wentBack = walk.back()
        let left = try #require(wentBack)
        #expect(left.lamp == row.id && walk.openedPerson == Self.ada && pages.front(of: Self.ada, in: session) == .followers)
        #expect(pages.walkedIDs(of: Self.ada, in: session).contains(row.id), "and the lamp is on a row that tab draws")
        // Leaving the page itself is one step, from whichever tab.
        let out = walk.back()
        #expect(out?.lamp == "a row of the stream" && walk.isEmpty)
    }

    @Test("The page takes the whole place: the timelines' head is not drawn over it and is over every other step; its sideways is its own — the tab beside, and on the first tab the swipe back leaves the page, as it leaves a page with one tab; a page that is a place is left by no swipe")
    func thePageAndItsSwipe() {
        #expect(!TimelinePane.headDrawn(over: .person(Self.ada)))
        for step in [nil, ShellStep.thread("a"), .tag(PostTag("#birds")!), .rising(.tags), .link(URL(string: "https://example.org")!)] as [ShellStep?] {
            #expect(TimelinePane.headDrawn(over: step), "\(String(describing: step))")
        }
        #expect(TimelinePane.page(.person(Self.ada)) == .tabbed && TimelinePane.page(.thread("a")) == .opened)
        #expect(TimelineSwipe.means(touch: true, page: .tabbed, searching: false, listShown: false, editing: false) == nil, "the timeline's swipe is not heard on it")
        #expect(TimelinePane.openedID(.person(Self.ada)) == "person:" + Self.ada.id)

        // The page's own swipe.
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 5, leaves: true) == .beside)
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 1, leaves: true) == .beside, "a forum author's page is still left by a swipe")
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 1) == nil && TimelineSwipe.means(touch: false, detail: false, tabs: 5, leaves: true) == nil)
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 5, leaves: true, covered: true) == nil)
        #expect(TimelineSwipe.leavesPage(from: 0, leaves: true) && !TimelineSwipe.leavesPage(from: 1, leaves: true))
        #expect(!TimelineSwipe.leavesPage(from: 0, leaves: false) && TimelineSwipe.leavesPage(from: nil, leaves: true))
        // From any other tab the swipe back is the tab before.
        #expect(TimelineSwipe.target(from: 1, count: 5, step: -1) == 0 && TimelineSwipe.target(from: 0, count: 5, step: -1) == nil)
    }

    /// Where the screens' source is, from wherever the package stands.
    private static func sources() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    @Test("The page asks through three tasks and no more — who they are, how the reader stands, and what the tab in front needs — and the root asks the walk before it turns the timelines")
    func whereThePageIsAsked() throws {
        let ui = try Self.sources()
        let pane = try String(contentsOf: ui.appending(path: "Shell/TimelinePane.swift"), encoding: .utf8)
        for call in [
            ".task(id: ShellPersonPages.opening(person, in: session)) { await people?.opened(person, in: session) }",
            ".task(id: people?.standsOpening(to: person, in: session)) { await people?.standsOpened(to: person, in: session) }",
            ".task(id: people?.fronting(person, in: session)) { await people?.fronted(person, in: session) }",
            "if Self.headDrawn(over: standing) {",
        ] {
            #expect(pane.components(separatedBy: call).count == 2, "the pane has \(call) once")
        }
        let root = try String(contentsOf: ui.appending(path: "FediqoRootView.swift"), encoding: .utf8)
        for call in [
            "if place == .timeline, let person = walk.openedPerson {\n            guard Self.turnsPersonTabs(open: openLayers) else { return false }\n            return people.rotate(person, by: step, lamp: &selectedItemID, in: session)",
            "walk.openedPerson.map { people.walkedIDs(of: $0, in: session) }",
            "people.followByKey(\n            place: place, open: openLayers, person: walk.openedPerson, tag: walk.openedTag, in: session",
        ] {
            #expect(root.components(separatedBy: call).count == 2, "the root has \(call) once")
        }
        // Which tabs a page has is decided in a file that does not draw.
        let tabs = try String(contentsOf: ui.appending(path: "Shell/ShellPersonTabs.swift"), encoding: .utf8)
        #expect(!DrawsNotKnowingKindTests.draws(tabs) && tabs.contains("static func tabs(said: PersonSaid?, own: Bool) -> [PersonTab]"))
        for file in ["PersonPage.swift", "PersonHead.swift", "PersonAbout.swift", "PeopleRows.swift", "PersonPane.swift", "PersonTab.swift"] {
            let text = try String(contentsOf: ui.appending(path: "Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }

    // MARK: - Written, and laid out

    @Test("Every sentence the page gained is written in each language the app speaks, with the places it fills; and the two that said held posts are below now say where they are")
    func writtenInEveryLanguage() throws {
        let keys = [
            "person.tab.about", "person.tab.following", "person.tab.followers", "person.tab.pinned", "person.tab.posts",
            "person.figure.hint", "person.figure.hidden", "person.lists.hidden", "person.reload", "person.about.none",
            "person.stands.neither", "person.stands.asking", "person.pinned.asking", "person.pinned.failed", "person.pinned.none",
            "person.pinned.foot.more", "person.pinned.foot.end", "person.unheardOf", "person.failed",
        ]
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let english = L10n.t(key, language: .english)
            #expect(english != key, "\(key) is not written")
            for language in DummyLanguage.allCases {
                let written = L10n.t(key, language: language)
                #expect(written != key && places(written) == places(english), "\(key) in \(language)")
            }
            #expect(L10n.t(key, language: .taiwanese) != english, "\(key) is English in zh-TW")
        }
        // Each is written in all three tables, and the two Chinese ones are the same.
        let resources = try Self.sources().appending(path: "Resources")
        let tables = try ["en", "zh-TW", "zh-Hant"].map { name in
            try String(contentsOf: resources.appending(path: "\(name).lproj/Localizable.strings"), encoding: .utf8)
        }
        for key in keys {
            for (table, name) in zip(tables, ["en", "zh-TW", "zh-Hant"]) {
                #expect(table.components(separatedBy: "\n\"\(key)\" = \"").count == 2, "\(key) is written once in \(name)")
            }
        }
        #expect(tables[1] == tables[2])
        for key in ["person.unheardOf", "person.failed"] {
            #expect(L10n.t(key, language: .english).hasSuffix("What this device holds of theirs is under Posts."))
            #expect(L10n.t(key, language: .taiwanese).hasSuffix("這台裝置上有的他們的貼文在「貼文」分頁。"))
        }
    }

    private func hosted(
        _ page: PersonPage, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize = .large
    ) -> (CGFloat, PersonHeadProbe) {
        let probe = PersonHeadProbe()
        let view = NSHostingView(
            rootView: page.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.personHeadProbe, probe)
        )
        view.layoutSubtreeIfNeeded()
        return (view.fittingSize.height, probe)
    }

    @Test("The page lays out in every state it has — opening, said with every tab in front, hidden lists, not heard of, failed, suspended, moved, a forum's author — at 720, 390 and 320, in light and in dark, and at the largest text: the head's parts stand inside the page, no part over another, and at the largest text the head scrolls with the tab in front")
    func laidOut() throws {
        let every = try person(#","locked":true,"bot":true,"header":"https://m.example/h.png","fields":[{"name":"Site","value":"example.org"}]"#)
        let large = Person(
            source: Self.source, accountID: "42", handle: "@ada_with_a_long_name@a-long-host-name.example", name: "Ada with a long name indeed",
            tally: Person.Tally(posts: 3_000_000_000, following: 3_000_000_000, followers: 3_000_000_000), locked: true
        )
        let standing = PersonActing(
            source: Self.host, named: "@ada@m.example",
            reading: .said(PersonStanding(accountID: "42", following: true, followedBy: true, muting: true, showsBoosts: true, notifies: false)), changes: true
        )
        let rows = [DummyItem(Note(
            id: "https://m.example/a/1", source: Self.source, author: "Ada", handle: "@ada@m.example", body: "a post",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))]
        var pages: [(String, PersonPage)] = [
            ("opening", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .asking), held: rows)),
            ("not heard of", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .unheardOf), front: .posts, held: rows)),
            ("failed", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .failed), canReload: true)),
            ("suspended", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .said(try person(#","suspended":true"#))))),
            ("moved", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .said(try person(#","moved":{"id":"7","acct":"ada@new.example"}"#))))),
            ("hidden lists", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .said(try person(#","hide_collections":true"#))))),
            ("large figures", HostedPersonPage.page(Self.ada, said: PersonSaid(source: Self.host, reading: .said(large)), standing: standing, canReload: true)),
            ("a forum's author", HostedPersonPage.page(Self.ada, said: nil, held: rows)),
        ]
        let said = PersonSaid(source: Self.host, reading: .said(every), posts: rows, foot: .more)
        let list = PeopleList(.followers, of: every)
        for tab in PersonTab.allCases {
            pages.append(("said, \(tab) in front", HostedPersonPage.page(
                Self.ada, said: said, standing: standing, front: tab,
                pinned: PersonPinnedSaid(source: Self.host, answered: true, posts: rows, foot: .end),
                people: PeopleSaid(list: list, reading: .said, people: [large]), canReload: true
            )))
        }
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
                for size in [DynamicTypeSize.large, .accessibility5] where size == .large || width == 320 {
                    for (name, page) in pages {
                        let (height, probe) = hosted(page, width: width, layout: layout, scheme: scheme, size: size)
                        let at = "\(name) at \(width), \(scheme), \(size)"
                        #expect(height == 700, "\(at)")
                        // At the largest text the head is a row of the tab's list: where that list
                        // is lazy it may not be laid out with no window, and then nothing is said.
                        guard !probe.frames.isEmpty else {
                            #expect(PersonPage.headScrolls(at: size), "the head was not laid out: \(at)")
                            continue
                        }
                        #expect(probe.width > 0 && probe.width <= width - 2 * ShellSpace.pad + 0.5, "\(at)")
                        for (part, frame) in probe.frames {
                            #expect(frame.minX >= -0.5 && frame.maxX <= probe.width + 0.5, "\(part) stands outside the head: \(frame) in \(probe.width), \(at)")
                            #expect(frame.height > 0 && frame.width > 0, "\(part) has no room: \(at)")
                        }
                        let parts = probe.frames
                        for (one, other) in [(PersonHeadProbe.Part.figures, PersonHeadProbe.Part.stands), (.figures, .acts), (.stands, .acts), (.name, .acts), (.face, .name), (.face, .figures)] {
                            if let first = parts[one], let second = parts[other] {
                                #expect(!first.insetBy(dx: 0.5, dy: 0.5).intersects(second), "\(one) over \(other): \(first) and \(second), \(at)")
                            }
                        }
                    }
                }
            }
        }
        #expect(PersonPage.headScrolls(at: .accessibility1) && PersonPage.headScrolls(at: .accessibility5))
        #expect(!PersonPage.headScrolls(at: .xxxLarge) && !PersonPage.headScrolls(at: .large))
    }

    @Test("A forum author's page is the bar, the heading it always had and what this device holds: no strip, no figure, no mark of how anybody stands, no mark in the bar; and what stands where its posts would is about this device")
    func aForumAuthorsPage() {
        let author = DummyPerson(making: Note(
            id: "https://forum.example/bob/1", source: Self.forum, author: "bob", handle: "", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))!
        let tabs = ShellPersonTabs.tabs(said: nil, own: false)
        let head = PersonHeadSaid.made(of: author, said: nil, tabs: tabs, held: 2, standing: nil, language: .english)
        #expect(tabs == [.posts] && !PersonPage.stripDrawn(tabs))
        #expect(head.through == "Read through forum.example" && head.held == "2 posts here" && head.whose == nil)
        #expect(head.figures.isEmpty && head.marks.isEmpty && head.standing == nil)
        #expect(head.spoken(language: .english) == "bob, Read through forum.example")
        #expect(PostRowsSaid.posts(of: nil, held: [], standing: nil, language: .english).quiet == "Nothing of theirs has reached this device yet.")
        let (height, probe) = hosted(HostedPersonPage.page(author, said: nil), width: 390, layout: .narrow, scheme: .light)
        #expect(height == 700 && probe.frames[.figures] == nil && probe.frames[.stands] == nil && probe.frames[.acts] == nil && probe.frames[.whose] == nil)
    }
}
