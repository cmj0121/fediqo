import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, what a search found at one source: one page of its own in the frame every opened page
/// stands in, with People · Hashtags where the source gave both and one list where it gave one;
/// either press for all of one kind opening it on that kind's tab; a tab the step's own value,
/// turned in place; a tab never in front having asked nothing; no timelines' head over it; Tab,
/// the swipe and the way back; and the search's results under it as they were.
///
/// **No check here waits on anything but the call it makes**, but the hosted pane's: that one
/// waits with `met` on its own `.task` asking, the run loop turned inside the condition.
@MainActor
@Suite("What a search found at a source, a page of its own", .watched)
struct FoundPageTests {
    private static let one = "m.example", two = "n.example"

    init() {
        L10n.language = .english
    }

    /// An ask of a source's search, as the one signed-in door spells it.
    private static func ask(_ words: [(String, String)]) -> String {
        let url = Host.httpsURL(host: one, path: "/api/v2/search", query: words.map { URLQueryItem(name: $0.0, value: $0.1) })
        return "/api/v2/search?" + (url?.query(percentEncoded: true) ?? "")
    }

    /// The one ask a Return makes of a source.
    private static let returned = ask([("q", "cats"), ("resolve", "false"), ("limit", "40")])
    /// The ask of all the people a source found.
    private static let people = ask([("q", "cats"), ("resolve", "false"), ("type", "accounts"), ("limit", "40")])

    private static func answer(people: Int, tags: Int) -> PageServer.Answer {
        let accounts = (0..<people).map { #"{"id":"\#($0 + 1)","acct":"p\#($0 + 1)","display_name":"Person \#($0 + 1)"}"# }
        let hashtags = (0..<tags).map { #"{"name":"cat\#($0 + 1)","history":[]}"# }
        return PageServer.Answer(
            body: #"{"accounts":[\#(accounts.joined(separator: ","))],"statuses":[],"hashtags":[\#(hashtags.joined(separator: ","))]}"#
        )
    }

    /// Two sources that say who people are, both signed in, each answering a Return with
    /// `answers` of its own.
    private func session(_ first: PageServer.Answer, _ second: PageServer.Answer = answer(people: 1, tags: 0)) async throws
        -> (ShellSession, PageServer)
    {
        let server = PageServer([Self.returned: first, Self.people: Self.answer(people: 6, tags: 0)])
        let servers = [Self.one: server, Self.two: PageServer([Self.returned: second])]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.work = SourceWork()
        for host in [Self.one, Self.two] { await session.store.add(Source(host: host, kind: .mastodon)) }
        session.sources = await session.store.sources()
        for host in [Self.one, Self.two] {
            try session.mastodon.tokens.save(MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        }
        session.mastodon.refresh()
        return (session, server)
    }

    private func signOut(_ session: ShellSession, at host: String = one) throws {
        if let held = try session.mastodon.tokens.token(host: host) {
            _ = try session.mastodon.tokens.forget(held)
            session.mastodon.refresh()
        }
    }

    /// The step a band's press for all of `which` opens, after a Return for "cats".
    private func opened(_ which: FoundWhich, in pages: ShellPersonPages, _ session: ShellSession) throws -> ShellStep {
        let band = try #require(pages.found.said(for: "cats", in: session).first { $0.source == Self.one })
        let press = try #require(band.rows.first { row in
            switch row {
            case .allPeople: which == .people
            case .allTags: which == .tags
            case .person, .tag: false
            }
        })
        return try #require(pages.found.step(opening: press, in: session))
    }

    // MARK: - The ways in

    @Test("Both presses for all of one kind open the one page of that source's answer, each on its own tab, with the kinds the answer gave — a row of somebody or of a hashtag opens no such page, nor does a press whose answer is gone")
    func bothPressesOpenOnePage() async throws {
        let (session, _) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let both = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        #expect(try opened(.people, in: pages, session) == .found(both, .people))
        #expect(try opened(.tags, in: pages, session) == .found(both, .tags))
        #expect(ShellStep.found(both, .people).isKind(of: .found(both, .tags)))
        let band = try #require(pages.found.said(for: "cats", in: session).first)
        for row in band.rows {
            if case .person = row { #expect(pages.found.step(opening: row, in: session) == nil) }
            if case .tag = row { #expect(pages.found.step(opening: row, in: session) == nil) }
        }
        // The press is what the walk remembers, and leaving gives it back: one step, from either tab.
        let press = try #require(band.rows.first { if case .allTags = $0 { true } else { false } })
        var walk = ShellWalk()
        let walked = walk.walk(to: .found(both, .tags), from: press.id)
        let turned = walk.turned(to: .found(both, .people))
        #expect(walked && turned && walk.depth == 1)
        let left = walk.back()
        #expect(left?.lamp == press.id && walk.isEmpty)

        session.reload.endSearch()
        #expect(pages.found.step(opening: press, in: session) == nil, "the answer is gone")
    }

    // MARK: - Which tabs

    @Test("The page's tabs are each kind the source gave, decided where the answer is held: both where it gave both, one where it gave one — then one list and no strip — and a kind it gave none of has no tab")
    func whichTabs() async throws {
        #expect(FoundWhich.tabs(gave: [.people, .tags]) { _ in true } == [.people, .tags])
        #expect(FoundWhich.tabs(gave: [.tags, .people]) { _ in true } == [.people, .tags], "in the order they stand")
        #expect(FoundWhich.tabs(gave: [.tags]) { _ in true } == [.tags])
        #expect(FoundWhich.tabs(gave: [.people, .tags]) { $0 == .people } == [.people])
        #expect(FoundWhich.front(.tags, among: [.people, .tags]) == .tags && FoundWhich.front(.tags, among: [.people]) == .people)
        #expect(FoundWhich.front(.people, among: []) == nil)
        #expect(FoundWhich.people.titleKey == "search.found.tab.people" && FoundWhich.people.symbol == "person.2" && FoundWhich.tags.symbol == "number")

        for (people, tags, gave) in [(5, 5, [FoundWhich.people, .tags]), (5, 0, [.people]), (0, 5, [.tags]), (5, 2, [.people, .tags])] {
            let (session, _) = try await session(Self.answer(people: people, tags: tags))
            let pages = ShellPersonPages()
            await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
            let at = FoundAt(source: Self.one, words: "cats", gave: gave)
            let which = try #require(gave.first(where: { $0 == .people ? people > 3 : tags > 3 }))
            #expect(try opened(which, in: pages, session) == .found(at, which), "\(people) people, \(tags) hashtags")
            let tabs = pages.found.tabs(of: at, in: session)
            #expect(tabs == gave && PageFrame.stripDrawn(tabs) == (gave.count > 1), "\(people) people, \(tags) hashtags")
            let drawn = TimelinePane.drawn(.found(at, which), of: pages, in: session)
            #expect(drawn.drawn && drawn.found?.which == which && drawn.found?.tabs == gave)
            #expect((drawn.found?.people != nil) == (which == .people) && (drawn.found?.tags != nil) == (which == .tags))
        }
    }

    @Test("Where the tab in front loses everything its source gave, the tab left is drawn: the hashtags go with the answer, and the people stay while somebody is signed in there to be answered; signed out, neither is left — no People tab that could only fail — and the stream is drawn under the head, as the old page of hashtags fell back to it; with the source gone, the same")
    func theTabLeft() async throws {
        let (session, _) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        #expect(TimelinePane.drawn(.found(at, .tags), of: pages, in: session).found?.which == .tags)
        // The answer no longer awaited — another Return — and the reader still signed in.
        pages.found.ended()
        let fallen = TimelinePane.drawn(.found(at, .tags), of: pages, in: session)
        #expect(fallen.drawn && fallen.found?.which == .people && fallen.found?.tabs == [.people])
        #expect(TimelinePane.headDrawn(over: .found(at, .tags), drawn: fallen.drawn) == false)

        // Signed out there: a search is answered to nobody, so People has no tab either.
        try signOut(session)
        #expect(pages.found.tabs(of: at, in: session).isEmpty)
        for which in FoundWhich.allCases {
            let gone = TimelinePane.drawn(.found(at, which), of: pages, in: session)
            #expect(!gone.drawn && gone.found == nil, "\(which)")
            #expect(TimelinePane.headDrawn(over: .found(at, which), drawn: false) && TimelinePane.page(.found(at, which), drawn: false) == .opened)
            #expect(FediqoRootView.stepTab(.found(at, which), drawn: gone.drawn, open: [ShellStep.found(at, which).layer]) == .timelines)
        }
        session.sources = session.sources.filter { $0.host != Self.one }
        #expect(!TimelinePane.drawn(.found(at, .people), of: pages, in: session).drawn, "the source removed")
    }

    // MARK: - The walk

    @Test("Each tab keeps its own lamp while the page is in the walk, and the lamps are forgotten when the walk leaves it; a tab the page has not, or the one in front, turns nothing — and a list of people opened on its own is a step of its own kind, as it was")
    func eachTabKeepsItsLamp() async throws {
        let (session, _) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        await pages.lists.opened(at.people, in: session)
        let person = try #require(pages.lists.walked(at.people, in: session).first)
        let tag = try #require(pages.found.walked(at.tags, in: session).first)
        var walk = ShellWalk()
        _ = walk.walk(to: .found(at, .people), from: "press")
        var lamp: String? = person
        #expect(pages.found.turn(&walk, to: .tags, lamp: &lamp, in: session) && walk.standing == .found(at, .tags) && lamp == nil)
        lamp = tag
        #expect(!pages.found.turn(&walk, to: .tags, lamp: &lamp, in: session) && lamp == tag, "the tab in front")
        #expect(pages.found.turn(&walk, to: .people, lamp: &lamp, in: session) && lamp == person)
        #expect(pages.found.turn(&walk, to: .tags, lamp: &lamp, in: session) && lamp == tag && walk.depth == 1)

        let left = walk.back()
        #expect(left?.lamp == "press")
        if let left { pages.left(left.step, of: walk) }
        _ = walk.walk(to: .found(at, .people), from: "press")
        lamp = nil
        #expect(pages.found.turn(&walk, to: .tags, lamp: &lamp, in: session) && lamp == nil, "opened afresh, no tab remembers a lamp")

        // A tab the page no longer has is not turned to: the hashtags go with the answer.
        #expect(pages.found.turn(&walk, to: .people, lamp: &lamp, in: session) && walk.standing == .found(at, .people))
        session.reload.endSearch()
        lamp = person
        #expect(!pages.found.turn(&walk, to: .tags, lamp: &lamp, in: session) && walk.standing == .found(at, .people) && lamp == person)
        var bare = ShellWalk()
        var kept: [FoundWhich: String] = [:]
        #expect(!FoundWhich.turned(&bare, to: .tags, among: FoundWhich.allCases, rows: [], lamps: &kept, lamp: &lamp) && bare.isEmpty)

        // The list a person's page or a source's page opens is still a list of people of its own.
        let directory = PeopleList(directoryAt: Self.one)
        #expect(!ShellStep.people(directory).isKind(of: .found(at, .people)) && ShellStep.people(directory).tabKey == .sole(.people))
    }

    @Test("On People the page is a list of people to the keys — Return opens a person, `r` asks the list again — and on Hashtags it is the hashtags found, with nothing to ask: each tab is the layer its old page was")
    func eachTabIsItsOldPagesLayer() {
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        var walk = ShellWalk()
        _ = walk.walk(to: .found(at, .people), from: nil)
        #expect(walk.openedPeople == at.people && walk.openedFoundTags == nil && walk.standing?.layer == .people)
        _ = walk.turned(to: .found(at, .tags))
        #expect(walk.openedPeople == nil && walk.openedFoundTags == at.tags && walk.standing?.layer == .rising)
        #expect(ShellWalk().openedPeople == nil)

        func reloads(_ open: Set<DummyLayer>, asked: Bool) -> Bool {
            FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: open, personAsked: asked)
        }
        #expect(reloads([.people, .selection], asked: true), "People: the list asked again")
        #expect(!reloads([.rising, .selection], asked: false), "Hashtags: nobody asked")
        let undrawn = FediqoRootView.drawnLayers([.rising, .search], standing: .found(at, .tags), drawn: false)
        #expect(undrawn == [.search], "a page that cannot be drawn is the stream's, under the search")
    }

    // MARK: - Where it stands

    @Test("Tab turns the two tabs round their ring, is taken and turns nothing with one tab, is nobody's while something covers the page, and the timelines' over a page that cannot be drawn")
    func tabTurnsTheTabs() async throws {
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        #expect(ShellStep.found(at, .tags).tabKey == .found(at, .tags))
        #expect(FoundWhich.keyed([.people, .tags], front: .people, by: 1, covered: false) == .turn(.tags))
        #expect(FoundWhich.keyed([.people, .tags], front: .tags, by: 1, covered: false) == .turn(.people), "round the ring")
        #expect(FoundWhich.keyed([.people, .tags], front: .people, by: -1, covered: false) == .turn(.tags))
        #expect(FoundWhich.keyed([.tags], front: .tags, by: 1, covered: false) == .taken)
        #expect(FoundWhich.keyed([.people, .tags], front: .tags, by: 1, covered: true) == .unheard)
        #expect(FoundWhich.keyed([.people], front: .people, by: 1, covered: true) == .unheard)
        #expect(FediqoRootView.stepTab(.found(at, .tags), drawn: true, open: [.rising, .selection]) == .page)
        #expect(FediqoRootView.stepTab(.found(at, .tags), drawn: false, open: [.rising]) == .timelines)
        for (which, layer) in [(FoundWhich.people, DummyLayer.people), (.tags, .rising)] {
            #expect(FediqoRootView.pageInFront(ShellStep.found(at, which).layer, open: [layer, .selection]))
            for over in [DummyLayer.viewer, .shortcuts] {
                #expect(!FediqoRootView.pageInFront(ShellStep.found(at, which).layer, open: [over, layer]), "\(which) under \(over)")
            }
        }

        let (session, _) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        var walk = ShellWalk()
        _ = walk.walk(to: .found(at, .people), from: nil)
        var lamp: String?
        #expect(!pages.found.rotate(&walk, by: 1, covered: true, lamp: &lamp, in: session) && walk.standing == .found(at, .people))
        #expect(pages.found.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.standing == .found(at, .tags))
        #expect(pages.found.rotate(&walk, by: -1, covered: false, lamp: &lamp, in: session) && walk.standing == .found(at, .people))
        #expect(walk.depth == 1, "turning adds no step")
        session.reload.endSearch()
        #expect(pages.found.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.standing == .found(at, .people), "taken, nothing turned")
    }

    @Test("With the page drawn the timelines' head is not over it and the swipe is the page's: from Hashtags to People, from People out — two swipes, one Back — and with one tab the swipe leaves; over a page that cannot be drawn the swipe goes back, as before")
    func theHeadAndTheSwipe() {
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        for which in FoundWhich.allCases {
            let step = ShellStep.found(at, which)
            #expect(!TimelinePane.headDrawn(over: step) && TimelinePane.headDrawn(over: step, drawn: false))
            #expect(TimelinePane.page(step) == .tabbed && TimelinePane.page(step, drawn: false) == .opened)
        }
        #expect(TimelinePane.openedID(.found(at, .people)) != TimelinePane.openedID(.found(at, .tags)))
        let two = FoundWhich.allCases
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: two.count, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: two.firstIndex(of: .tags), count: two.count, step: -1, leaves: false) == .tab(0), "on Hashtags the swipe goes to People")
        #expect(TimelineSwipe.tabStep(from: two.firstIndex(of: .people), count: two.count, step: -1, leaves: true) == .leave, "on People it leaves")
        #expect(TimelineSwipe.tabStep(from: 0, count: two.count, step: 1, leaves: true) == .tab(1))
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 1, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: 0, count: 1, step: -1, leaves: true) == .leave, "one tab: the swipe leaves")
    }

    @Test("The bar's mark asks the source again on People where `r` would, named by the source to a pointer and a listener, and is absent — not dim — on Hashtags and where `r` would not; Stop only where the page hands one; the page's words are written in every language")
    func theBarsMarkAndTheWords() {
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let onPeople = FoundSaid(at: at, tabs: [.people, .tags], which: .people, people: PeopleSaid(list: at.people))
        let onTags = FoundSaid(at: at, tabs: [.people, .tags], which: .tags, tags: FoundTagsSaid(page: at.tags, tags: []))
        #expect(FoundPage.reloadName(of: onPeople, canReload: true, language: .english) == "Ask m.example again")
        #expect(FoundPage.reloadName(of: onPeople, canReload: false) == nil)
        #expect(FoundPage.reloadName(of: onTags, canReload: true) == nil)
        let acts = FoundPage.acts(onBack: {}, onTab: { _ in }, onReload: {}, onPull: {})
        #expect(acts.onStop == nil && ReloadMark.shown(canReload: true, stoppable: acts.onStop != nil) == .reload)
        let stops = FoundPage.acts(onBack: {}, onTab: { _ in }, onReload: {}, onPull: {}, onStop: {})
        #expect(ReloadMark.shown(canReload: true, stoppable: stops.onStop != nil) == .stop, "the people's ask, stopped from the bar")

        #expect(FoundAt.title(Self.one, language: .english) == "What m.example found" && FoundAt.title(Self.one, language: .taiwanese) == "m.example 找到的")
        #expect(at.headLine(language: .english) == "Its answer to “cats”.")
        #expect(L10n.t(FoundWhich.people.titleKey, language: .english) == "People" && L10n.t(FoundWhich.tags.titleKey, language: .english) == "Hashtags")
        #expect(L10n.t(FoundWhich.people.titleKey, language: .taiwanese) == "人" && L10n.t(FoundWhich.tags.titleKey, language: .taiwanese) == "主題標籤")
        for language in DummyLanguage.allCases {
            for key in ["search.found.title", "search.found.tab.people", "search.found.tab.tags"] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
        // The people a search found say no line of their own any more: the head says it once.
        let found = PeopleSaid(list: at.people)
        #expect(found.sorting.map { PeopleSaid.sortingLine($0, source: found.source) } == nil)
    }

    // MARK: - Hosted

    /// The walk the pane stands on, which a check moves — and the pane turns — as the root would.
    @Observable
    final class Standing {
        var walk = ShellWalk()
        var lamp: String?
        init(_ step: ShellStep) { _ = walk.walk(to: step, from: "press") }
    }

    /// The root's share of the pane, standing where `standing` says, with the pages held.
    private struct Pane: View {
        let session: ShellSession
        let pages: ShellPersonPages
        let standing: Standing
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: FoundDefaults())

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: standing.walk.standing, onOpenPerson: { _ in }, decks: $decks,
                playback: playback, onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                jumpToTop: 0, onBack: {}, ways: TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {}),
                search: ShellSearch(), people: pages,
                onTurnFound: { which in pages.found.turn(&standing.walk, to: which, lamp: &standing.lamp, in: session) },
                serverFilters: true
            )
            .environment(prefs)
        }
    }

    /// One pass of the hosted pane: laid out, and its run loop given a turn.
    private func turn(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    /// What `server` was asked for the people it found.
    private func asked(_ server: PageServer) async -> Int {
        await server.asked.filter { $0 == Self.people }.count
    }

    @Test("Opened on Hashtags the page asks nobody, and draws no timelines' head; People, brought in front, asks its list once — and opened on People it is asked at once")
    func aTabNeverInFrontAskedNothing() async throws {
        let (session, server) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let standing = Standing(.found(at, .tags))
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: Pane(session: session, pages: pages, standing: standing).environment(\.shellPaneProbe, probe))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        // The pane's own tasks have run once its emoji are asked for: the page's came with them.
        await met("the pane's tasks begun") {
            turn(hosted)
            return await server.asked.contains { $0.hasPrefix("/api/v1/custom_emojis") }
        }
        turn(hosted)
        #expect(await asked(server) == 0, "Hashtags in front: nothing asked")
        #expect(probe.head == .zero, "the timelines' head is not drawn over the page")
        #expect(pages.lists.said(of: at.people, in: session)?.reading == .asking)

        standing.walk.turned(to: .found(at, .people))
        await met("People asked once in front, and landed") {
            turn(hosted)
            return pages.lists.said(of: at.people, in: session)?.reading == .said
        }
        #expect(await asked(server) == 1)
        _ = standing.walk.turned(to: .found(at, .tags))
        turn(hosted)
        _ = standing.walk.turned(to: .found(at, .people))
        turn(hosted)
        #expect(await asked(server) == 1, "asked once a run")
        #expect(standing.walk.depth == 1)
    }

    @Test("With Hashtags in front and the answer let go — another Return — the walk is turned to People, no step more, and People is drawn and asked, as the reader signed in there")
    func theTabLeftComesInFront() async throws {
        let (session, server) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let standing = Standing(.found(at, .tags))
        let hosted = NSHostingView(rootView: Pane(session: session, pages: pages, standing: standing))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        turn(hosted)
        pages.found.ended()
        await met("Hashtags gone, People in front and landed") {
            turn(hosted)
            return standing.walk.standing == .found(at, .people) && pages.lists.said(of: at.people, in: session)?.reading == .said
        }
        #expect(standing.walk.depth == 1 && pages.found.tabs(of: at, in: session) == [.people])
        #expect(await asked(server) == 1)
        var lamp: String?
        #expect(pages.found.rotate(&standing.walk, by: 1, covered: false, lamp: &lamp, in: session) && standing.walk.standing == .found(at, .people), "Tab taken, nothing turned")
    }

    @Test("With Hashtags in front and the reader signed out there, nothing of the page is left: the stream is drawn under the timelines' head, as the old page of hashtags fell back to it, and no People tab is turned to that could only fail — nothing is asked")
    func signedOutLeavesTheStream() async throws {
        let (session, server) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let standing = Standing(.found(at, .tags))
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: Pane(session: session, pages: pages, standing: standing).environment(\.shellPaneProbe, probe))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        turn(hosted)
        #expect(probe.head == .zero, "the page is drawn first")
        try signOut(session)
        await met("the stream drawn under the timelines' head") {
            turn(hosted)
            return probe.head != .zero
        }
        #expect(standing.walk.standing == .found(at, .tags) && standing.walk.depth == 1, "the walk is not turned to a tab that is not there")
        #expect(!TimelinePane.drawn(standing.walk.standing, of: pages, in: session).drawn)
        #expect(await asked(server) == 0)
    }

    /// A sign-in at `host` whose words hold reading and acting, and search only where `searches`.
    private func signIn(_ session: ShellSession, at host: String = one, as access: String, searches: Bool) throws {
        try signOut(session, at: host)
        let words = "read:statuses read:lists read:accounts write:statuses write:favourites" + (searches ? " read:search" : "")
        try session.mastodon.tokens.save(MastodonToken(host: host, accessToken: access, clientID: "c", clientSecret: "s", scopes: words))
        session.mastodon.refresh()
    }

    @Test("People is a tab only where the sign-in there may search: a whole sign-in without search has none — the hashtags held stay, or the stream is drawn — and one that may search has it")
    func peopleOnlyWhereTheSignInSearches() async throws {
        let (session, _) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        try signIn(session, as: "tok", searches: true)
        #expect(pages.lists.searchable(at.people, in: session) && pages.found.tabs(of: at, in: session).contains(.people))
        try signIn(session, as: "tok", searches: false)
        #expect(session.mastodon.signedInHosts.contains(Self.one), "a whole sign-in, without search")
        #expect(!pages.lists.searchable(at.people, in: session) && !pages.found.tabs(of: at, in: session).contains(.people))
        let drawn = TimelinePane.drawn(.found(at, .people), of: pages, in: session)
        #expect(drawn.found?.people == nil, "no People drawn that could only fail")
        try signOut(session)
        #expect(!pages.lists.searchable(at.people, in: session))
    }

    @Test("Hosted, People in front and the sign-in there replaced by one that may not search: People is no longer drawn and nothing more is asked of it")
    func peopleGoesWithoutSearch() async throws {
        let (session, server) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let standing = Standing(.found(at, .people))
        let hosted = NSHostingView(rootView: Pane(session: session, pages: pages, standing: standing))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        await met("People asked and landed") {
            turn(hosted)
            return pages.lists.said(of: at.people, in: session)?.reading == .said
        }
        try signIn(session, as: "other", searches: false)
        await met("People no longer drawn") {
            turn(hosted)
            return TimelinePane.drawn(standing.walk.standing, of: pages, in: session).found?.people == nil
        }
        #expect(standing.walk.depth == 1)
        #expect(await asked(server) == 1)
    }

    @Test("Hosted, on Hashtags: signed out the stream is drawn and the walk stays where it was; signed in again as the reader the answer was given to, the page is back on Hashtags with both tabs and nothing asked; Tab brings People, asked once, no step more — and Esc goes one step back, to the press")
    func signedInAgain() async throws {
        let (session, server) = try await session(Self.answer(people: 5, tags: 5))
        let pages = ShellPersonPages()
        await session.reload.search("cats", timeline: .all, found: pages.found, in: session)
        let at = FoundAt(source: Self.one, words: "cats", gave: [.people, .tags])
        let standing = Standing(.found(at, .tags))
        let probe = PaneProbe(), page = OpenedPageProbe()
        let hosted = NSHostingView(
            rootView: Pane(session: session, pages: pages, standing: standing)
                .environment(\.shellPaneProbe, probe).environment(\.openedPageProbe, page)
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        turn(hosted)
        try signOut(session)
        await met("the stream drawn under the timelines' head") {
            turn(hosted)
            return probe.head != .zero
        }
        #expect(standing.walk.standing == .found(at, .tags))
        page.frames = [:]
        try signIn(session, as: "again", searches: true)
        await met("the page drawn again, in its frame") {
            turn(hosted)
            return page.frames[.bar] != nil
        }
        let back = TimelinePane.drawn(standing.walk.standing, of: pages, in: session).found
        #expect(standing.walk.standing == .found(at, .tags) && back?.which == .tags && back?.tabs == [.people, .tags])
        #expect(await asked(server) == 0, "Hashtags in front: nothing asked")
        var lamp: String?
        #expect(pages.found.rotate(&standing.walk, by: 1, covered: false, lamp: &lamp, in: session))
        await met("People drawn, the walk on it, and landed") {
            turn(hosted)
            return standing.walk.standing == .found(at, .people) && pages.lists.said(of: at.people, in: session)?.reading == .said
        }
        #expect(standing.walk.depth == 1)
        #expect(await asked(server) == 1)
        let left = standing.walk.back()
        #expect(left?.step == .found(at, .people) && left?.lamp == "press" && standing.walk.isEmpty)
    }

    // MARK: - Laid out

    private func laidOut(_ page: FoundPage, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize) -> [OpenedPageProbe.Part: CGRect] {
        let probe = OpenedPageProbe()
        let view = NSHostingView(
            rootView: page.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return probe.frames
    }

    @Test("The page takes the pane's whole height through the frame: its bar at the top and as wide as the page, the strip only with two tabs, the head between the bar and the list — and at the largest text the head is the list's first rows — at 720, 390 and 320, in light and in dark, with and without the mark")
    func thePageTakesTheWholeHeight() throws {
        let long = String(repeating: "word ", count: 40)
        let at = FoundAt(source: Self.one, words: long, gave: [.people, .tags])
        let source = Source(host: Self.one, kind: .mastodon)
        let people = (1...3).map { Person(source: source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "Person \($0)") }
        let tags = (1...3).map { RisingTag(tag: PostTag("#cat\($0)")!) }
        let saids = [
            FoundSaid(at: at, tabs: [], which: .people, people: PeopleSaid(list: at.people, reading: .said, people: people, foot: .more)),
            FoundSaid(at: at, tabs: [], which: .people, people: PeopleSaid(list: at.people, signedIn: true, reading: .asking)),
            FoundSaid(at: at, tabs: [], which: .people, people: PeopleSaid(list: at.people, signedIn: true, reading: .failed)),
            FoundSaid(at: at, tabs: [], which: .tags, tags: FoundTagsSaid(page: at.tags, tags: tags)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .xxxLarge), (.narrow, 320, .accessibility5),
            ] {
                for base in saids {
                    for tabs in [FoundWhich.allCases, [base.which]] {
                        let said = FoundSaid(at: at, tabs: tabs, which: base.which, people: base.people, tags: base.tags)
                        for reload in [FoundPage.reloadName(of: said, canReload: true), nil] {
                            let state = said.people.map { " (\($0.reading))" } ?? ""
                            let at = "\(said.which)\(state) of \(tabs) at \(width), \(scheme), \(size), \(reload == nil ? "without" : "with") the mark"
                            let page = FoundPage(said: said, selectedID: .constant(nil), reload: reload)
                            let parts = laidOut(page, width: width, layout: layout, scheme: scheme, size: size)
                            let bar = try #require(parts[.bar], "\(at)"), room = try #require(parts[.front], "\(at)")
                            #expect(bar.minX == 0 && abs(bar.minY) < 0.5 && bar.width == width, "\(at): \(bar)")
                            #expect(room.minX == 0 && room.width == width && room.maxY == 700, "\(at): \(room)")
                            if tabs.count > 1 {
                                let strip = try #require(parts[.strip], "\(at): two tabs draw the strip")
                                #expect(strip.minY >= bar.maxY && room.minY >= strip.maxY, "\(at)")
                            } else {
                                #expect(parts[.strip] == nil, "\(at): one tab draws no strip")
                            }
                            let above = parts[.strip]?.maxY ?? bar.maxY
                            if PageFrame.headScrolls(at: size) {
                                #expect(room.minY - above <= 1.5, "\(at): the head scrolls with the list")
                            } else {
                                #expect((parts[.strip]?.minY ?? room.minY) - bar.maxY > 20, "\(at): the head stands under the bar")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("The page and its tabs draw and learn no kind of source")
    func drawsNotKnowingKind() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        for file in ["FoundPage.swift", "FoundTab.swift"] {
            let text = try String(contentsOf: url.appending(path: "Sources/FediqoUI/Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class FoundDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
