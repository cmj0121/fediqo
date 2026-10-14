import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, what is rising: one page of its own in the frame every opened page stands in, with
/// Hashtags · Links where its sources have both and one list where they have one; the tab
/// pressed at the stream in front; a tab the step's own value, turned in place; a tab never in
/// front having asked nothing; no timelines' head over it; Tab, the swipe and the way back.
///
/// **No check here waits on anything but the call it makes**, but the hosted pane's: that one
/// waits with `met` on its own `.task` asking, the run loop turned inside the condition.
@MainActor
@Suite("What is rising, a page of its own", .watched)
struct RisingPageTests {
    private static let one = "m.example", two = "n.example"
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let tags = "/api/v1/trends/tags?limit=20"
    private static let links = "/api/v1/trends/links?limit=20"
    private static let tagsAnswer = PageServer.Answer(body: #"[{"name":"birds","history":[]}]"#)
    private static let linksAnswer = PageServer.Answer(body: #"[{"url":"https://far.example/story","title":"A story"}]"#)

    /// Two sources that say who people are and a forum, each with a server of its own.
    private func session(sources: [Source]? = nil) async -> (ShellSession, [String: PageServer]) {
        let routes = [Self.tags: Self.tagsAnswer, Self.links: Self.linksAnswer]
        let servers = [Self.one: PageServer(routes), Self.two: PageServer(routes), Self.forum.host: PageServer([:])]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.work = SourceWork()
        let joined = sources ?? [Source(host: Self.one, kind: .mastodon), Source(host: Self.two, kind: .mastodon), Self.forum]
        for source in joined { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, servers)
    }

    /// Every source of `session` answers that it has no ranking of `which`, for the run.
    private func absent(_ which: RisingWhich, in pages: ShellPersonPages, _ session: ShellSession) {
        for source in session.sources {
            pages.more.hosts.notFound(which.thing, at: source.host, round: pages.more.hosts.round(at: source.host))
        }
    }

    // MARK: - The walk

    @Test("A tab is turned in place only to another value of the same kind of step: what is rising's other tab, never another page — and a step of the same kind is one, whatever its value")
    func turnedOnlyToTheSameKind() throws {
        let tag = try #require(PostTag("#swift")), other = try #require(PostTag("#birds"))
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.one))
        let steps: [ShellStep] = [
            .person(ada), .thread("post"), .link(URL(string: "https://example.org/")!), .tag(tag),
            .people(PeopleList(directoryAt: Self.one)), .rising(.tags),
            .found(FoundAt(source: Self.one, words: "swift", gave: FoundWhich.allCases), .people), .followedTags(FollowedTags(host: Self.one)),
        ]
        for (i, step) in steps.enumerated() {
            for (j, beside) in steps.enumerated() {
                #expect(step.isKind(of: beside) == (i == j), "\(step) against \(beside)")
            }
        }
        #expect(ShellStep.rising(.tags).isKind(of: .rising(.links)) && ShellStep.tag(tag).isKind(of: .tag(other)))

        var walk = ShellWalk()
        _ = walk.walk(to: .rising(.tags), from: "row")
        for elsewhere in steps where !elsewhere.isKind(of: .rising(.links)) {
            let turned = walk.turned(to: elsewhere)
            #expect(!turned && walk.standing == .rising(.tags) && walk.depth == 1, "\(elsewhere)")
        }
        let links = walk.turned(to: .rising(.links))
        #expect(links && walk.standing == .rising(.links) && walk.depth == 1)
        let left = walk.back()
        #expect(left?.step == .rising(.links) && left?.lamp == "row" && walk.isEmpty, "Back from the second tab is one step")
    }

    @Test("Each tab keeps its own lamp while the page is in the walk — turned to, it is lit where it was left while that row is still the tab's, and a tab not in front before is lit nowhere — and the lamps are forgotten when the walk leaves the page; a tab the page has not, or the one in front, turns nothing")
    func eachTabKeepsItsLamp() async throws {
        let (session, _) = await session()
        let pages = ShellPersonPages()
        let rising = pages.rising
        await rising.opened(.tags, in: session)
        await rising.opened(.links, in: session)
        let tagRow = try #require(rising.walked(.tags, in: session).first), linkRow = try #require(rising.walked(.links, in: session).first)
        var walk = ShellWalk()
        _ = walk.walk(to: .rising(.tags), from: "stream-row")
        var lamp: String? = tagRow
        #expect(rising.turn(&walk, to: .links, lamp: &lamp, in: session))
        #expect(walk.standing == .rising(.links) && walk.depth == 1 && lamp == nil)
        lamp = linkRow
        #expect(!rising.turn(&walk, to: .links, lamp: &lamp, in: session) && lamp == linkRow, "the tab in front")
        #expect(rising.turn(&walk, to: .tags, lamp: &lamp, in: session) && lamp == tagRow)
        #expect(rising.turn(&walk, to: .links, lamp: &lamp, in: session) && lamp == linkRow)

        // The walk leaves the page: the lamps go with it.
        let left = walk.back()
        #expect(left?.lamp == "stream-row")
        if let left { pages.left(left.step, of: walk) }
        _ = walk.walk(to: .rising(.tags), from: "stream-row")
        lamp = nil
        #expect(rising.turn(&walk, to: .links, lamp: &lamp, in: session) && lamp == nil, "opened afresh, no tab remembers a lamp")

        // A kept lamp on a row the tab no longer has is handed back as none.
        var kept: [RisingWhich: String] = [.tags: "gone-row"]
        var bare = ShellWalk()
        _ = bare.walk(to: .rising(.links), from: nil)
        lamp = linkRow
        #expect(RisingWhich.turned(&bare, to: .tags, among: RisingWhich.allCases, rows: [tagRow], lamps: &kept, lamp: &lamp))
        #expect(lamp == nil && kept[.links] == linkRow)
        #expect(PageFrame.lamp("a", among: ["a"]) == "a" && PageFrame.lamp("a", among: ["b"]) == nil && PageFrame.lamp(nil, among: ["a"]) == nil)

        // A tab no source ranks any more is not turned to.
        absent(.tags, in: pages, session)
        lamp = linkRow
        #expect(!rising.turn(&walk, to: .tags, lamp: &lamp, in: session) && walk.standing == .rising(.links) && lamp == linkRow)
        // Nor is anything turned on a walk not standing on the page.
        var elsewhere = ShellWalk()
        #expect(!RisingWhich.turned(&elsewhere, to: .links, among: RisingWhich.allCases, rows: [], lamps: &kept, lamp: &lamp) && elsewhere.isEmpty)
    }

    // MARK: - Which tabs

    @Test("The page's tabs are each kind of thing some source ranks, decided where the sources are asked: both where they have both, one where every source said it has none of the other — then one list and no strip, and a page stood on the tab gone draws the one left — and none for a forum, where there is no page to draw")
    func whichTabs() async {
        #expect(RisingWhich.front(.links, among: [.tags, .links]) == .links && RisingWhich.front(.links, among: [.links]) == .links)
        #expect(RisingWhich.front(.links, among: [.tags]) == .tags && RisingWhich.front(.tags, among: [.links]) == .links)
        #expect(RisingWhich.front(.tags, among: []) == nil)
        #expect(RisingWhich.tabs { _ in true } == [.tags, .links] && RisingWhich.tabs { $0 == .links } == [.links] && RisingWhich.tabs { _ in false }.isEmpty)
        #expect(RisingWhich.tags.titleKey == "rising.tab.tags" && RisingWhich.tags.symbol == "number" && RisingWhich.links.symbol == "link")
        let (session, _) = await session()
        let pages = ShellPersonPages()
        #expect(pages.rising.tabs(in: session) == [.tags, .links] && PageFrame.stripDrawn(pages.rising.tabs(in: session)))
        absent(.links, in: pages, session)
        let alone = pages.rising.tabs(in: session)
        #expect(alone == [.tags] && !PageFrame.stripDrawn(alone), "one list, no strip — absent, not grey")
        #expect(TimelinePane.drawn(.rising(.tags), of: pages, in: session).drawn)
        let fallen = TimelinePane.drawn(.rising(.links), of: pages, in: session)
        #expect(fallen.drawn && fallen.rising?.which == .tags, "a page stood on a tab no source ranks draws the one left")

        let (forum, _) = await self.session(sources: [Self.forum])
        let none = ShellPersonPages()
        #expect(none.rising.tabs(in: forum).isEmpty)
        for which in RisingWhich.allCases {
            #expect(!TimelinePane.drawn(.rising(which), of: none, in: forum).drawn)
        }
    }

    // MARK: - Where it stands

    @Test("With the page drawn the timelines' head is not over it and the swipe is the page's: from the second tab to the first, from the first out — so leaving from the second tab is two swipes and one Back — and with one tab the swipe leaves; a page that cannot be drawn draws the stream under the head, left by the swipe as before, and `r` and its mark are the stream's there")
    func theHeadAndTheSwipe() async {
        let step = ShellStep.rising(.links)
        #expect(!TimelinePane.headDrawn(over: step) && TimelinePane.headDrawn(over: step, drawn: false))
        #expect(TimelinePane.page(step) == .tabbed && TimelinePane.page(step, drawn: false) == .opened)
        let two = RisingWhich.allCases
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: two.count, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: two.firstIndex(of: .links), count: two.count, step: -1, leaves: false) == .tab(0), "on Links the swipe goes to Hashtags")
        #expect(TimelineSwipe.leavesPage(from: two.firstIndex(of: .tags), leaves: true))
        #expect(TimelineSwipe.tabStep(from: 0, count: two.count, step: -1, leaves: true) == .leave, "on Hashtags it leaves")
        #expect(TimelineSwipe.tabStep(from: 0, count: two.count, step: 1, leaves: true) == .tab(1))
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 1, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: 0, count: 1, step: -1, leaves: true) == .leave, "one tab: the swipe leaves")

        func reloads(_ open: Set<DummyLayer>, asked: Bool) -> Bool {
            FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: open, personAsked: asked)
        }
        let undrawn = FediqoRootView.drawnLayers([.rising, .selection], standing: step, drawn: false)
        #expect(undrawn == [.selection] && reloads(undrawn, asked: false), "over the stream drawn instead, the timeline is asked")
        #expect(!reloads([.rising, .selection], asked: false) && reloads([.rising, .selection], asked: true), "drawn, the page's sources")
    }

    @Test("Tab turns the two tabs round their ring, is taken and turns nothing with one tab, is nobody's while something covers the page, and the timelines' over a page that cannot be drawn")
    func tabTurnsTheTabs() async {
        #expect(ShellStep.rising(.tags).tabKey == .rising(.tags))
        #expect(RisingWhich.keyed([.tags, .links], front: .tags, by: 1, covered: false) == .turn(.links))
        #expect(RisingWhich.keyed([.tags, .links], front: .links, by: 1, covered: false) == .turn(.tags), "round the ring")
        #expect(RisingWhich.keyed([.tags, .links], front: .tags, by: -1, covered: false) == .turn(.links))
        #expect(RisingWhich.keyed([.tags], front: .tags, by: 1, covered: false) == .taken)
        #expect(RisingWhich.keyed([.tags, .links], front: .tags, by: 1, covered: true) == .unheard)
        #expect(RisingWhich.keyed([.tags], front: .tags, by: 1, covered: true) == .unheard)
        #expect(FediqoRootView.stepTab(.rising(.tags), drawn: true, open: [.rising, .selection]) == .page)
        #expect(FediqoRootView.stepTab(.rising(.tags), drawn: false, open: [.rising]) == .timelines)
        #expect(FediqoRootView.pageInFront(.rising, open: [.rising, .selection]))
        for over in [DummyLayer.viewer, .shortcuts] {
            #expect(!FediqoRootView.pageInFront(.rising, open: [over, .rising]), "\(over)")
        }

        let (session, _) = await session()
        let pages = ShellPersonPages()
        var walk = ShellWalk()
        _ = walk.walk(to: .rising(.tags), from: nil)
        var lamp: String?
        #expect(!pages.rising.rotate(&walk, by: 1, covered: true, lamp: &lamp, in: session) && walk.standing == .rising(.tags))
        #expect(pages.rising.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.standing == .rising(.links))
        #expect(pages.rising.rotate(&walk, by: -1, covered: false, lamp: &lamp, in: session) && walk.standing == .rising(.tags))
        #expect(walk.depth == 1, "turning adds no step")
        absent(.links, in: pages, session)
        #expect(pages.rising.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.standing == .rising(.tags), "taken, nothing turned")
    }

    @Test("The bar's mark asks the sources again where `r` would, named so to a pointer and a listener, and is absent — not dim — where it would not; the page's words are written in every language")
    func theBarsMarkAndTheWords() {
        #expect(RisingPage.reloadName(canReload: true, language: .english) == "Ask the sources again")
        #expect(RisingPage.reloadName(canReload: true, language: .taiwanese) == "再問各來源一次")
        #expect(RisingPage.reloadName(canReload: false) == nil)
        // A timeline reload left running under the page (`r` on the stream, then `h`) is the
        // stream's to stop: the bar is handed no Stop, so its mark stays the one that asks the
        // page's sources, which is what `r` there does.
        #expect(ShellReload.stoppable([.timeline]) == [.timeline])
        let acts = RisingPage.acts(onBack: {}, onTab: { _ in }, onReload: {}, onPull: {})
        #expect(acts.onStop == nil && ReloadMark.shown(canReload: true, stoppable: acts.onStop != nil) == .reload)
        #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [.rising, .selection], personAsked: true))
        #expect(DummyCommand.outermost(of: [.rising, .selection]) == .rising, "`r` there asks the page's sources, not the timeline")
        // A band's Try again is called by its words, and whom it asks is told after them.
        let again = RisingSaid.Band(source: Self.two, reading: .failed).again(language: .english)
        #expect(again.words == "Try again" && again.hint == "Ask n.example again")
        #expect(RisingSaid.pageTitle(language: .english) == "What is rising" && RisingSaid.pageTitle(language: .taiwanese) == "正在竄升的")
        #expect(L10n.t(RisingWhich.tags.titleKey, language: .english) == "Hashtags" && L10n.t(RisingWhich.links.titleKey, language: .english) == "Links")
        #expect(L10n.t(RisingWhich.tags.titleKey, language: .taiwanese) == "主題標籤" && L10n.t(RisingWhich.links.titleKey, language: .taiwanese) == "連結")
        for language in DummyLanguage.allCases {
            for key in ["rising.title", "rising.tab.tags", "rising.tab.links", "rising.reload"] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
        // The ways in at the stream keep their own words: each opens the page on its own tab.
        #expect(RisingSaid.title(.tags, language: .english) == "Rising hashtags" && RisingSaid.title(.links, language: .english) == "Rising links")
    }

    // MARK: - Hosted

    /// The walk the pane stands on, which a check moves — and the pane turns — as the root would.
    @Observable
    final class Standing {
        var walk = ShellWalk()
        var lamp: String?
        init(_ step: ShellStep) { _ = walk.walk(to: step, from: nil) }
    }

    /// The root's share of the pane, standing where `standing` says, with the pages held.
    private struct Host: View {
        let session: ShellSession
        let pages: ShellPersonPages
        let standing: Standing
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: RisingDefaults())

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: standing.walk.standing, onOpenPerson: { _ in }, decks: $decks,
                playback: playback, onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                jumpToTop: 0, onBack: {}, ways: TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {}),
                search: ShellSearch(), people: pages,
                onTurnRising: { which in _ = pages.rising.turn(&standing.walk, to: which, lamp: &standing.lamp, in: session) }
            )
            .environment(prefs)
        }
    }

    @Test("Opened on the tab pressed, the page asks that tab's sources and the other's nothing; the other tab, brought in front, asks its own — and with the page in front no timelines' head is drawn")
    func aTabNeverInFrontAskedNothing() async {
        for (first, then) in [(RisingWhich.tags, RisingWhich.links), (.links, .tags)] {
            let (session, servers) = await session()
            let pages = ShellPersonPages()
            let standing = Standing(.rising(first))
            let probe = PaneProbe()
            let hosted = NSHostingView(rootView: Host(session: session, pages: pages, standing: standing).environment(\.shellPaneProbe, probe))
            hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
            let path = [RisingWhich.tags: Self.tags, .links: Self.links]
            await met("\(first) asked of both sources, and landed") {
                turn(hosted)
                return pages.rising.said(first, in: session)?.bands.allSatisfy { $0.reading == .said } == true
            }
            for host in [Self.one, Self.two] {
                #expect(await rising(servers[host]) == [path[first]!], "\(first) opened: \(host) asked nothing of \(then)")
            }
            #expect(await rising(servers[Self.forum.host]).isEmpty, "a forum is asked nothing of what is rising")
            #expect(probe.head == .zero, "the timelines' head is not drawn over the page")

            _ = standing.walk.turned(to: .rising(then))
            await met("\(then) asked once in front") {
                turn(hosted)
                return pages.rising.said(then, in: session)?.bands.allSatisfy { $0.reading == .said } == true
            }
            for host in [Self.one, Self.two] {
                #expect(await rising(servers[host]) == [path[first]!, path[then]!], "\(host)")
            }
        }
    }

    /// What `server` was asked of what is rising, in order: the pane asks a source for its
    /// emoji besides, which is not this page's.
    private func rising(_ server: PageServer?) async -> [String] {
        await server?.asked.filter { $0.hasPrefix("/api/v1/trends/") } ?? []
    }

    /// One pass of the hosted pane: laid out, and its run loop given a turn.
    private func turn(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    @Test("Every source answering, with Links in front, that it has no such address: Links goes, the walk is turned to Hashtags — no step more — and Hashtags is drawn and asked; the stream is drawn only where no tab is left")
    func theTabLeftComesInFront() async {
        let (session, servers) = await session()
        let off = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)
        for host in [Self.one, Self.two] { await servers[host]?.answer(Self.links, off) }
        let pages = ShellPersonPages()
        let standing = Standing(.rising(.links))
        let hosted = NSHostingView(rootView: Host(session: session, pages: pages, standing: standing))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        await met("Links gone, and Hashtags in front and landed") {
            turn(hosted)
            return standing.walk.standing == .rising(.tags)
                && pages.rising.said(.tags, in: session)?.bands.allSatisfy { $0.reading == .said } == true
        }
        #expect(pages.rising.tabs(in: session) == [.tags] && standing.walk.depth == 1)
        for host in [Self.one, Self.two] {
            #expect(await rising(servers[host]) == [Self.links, Self.tags], "\(host)")
        }
        // Tab is the page's again, taken and turning nothing with the one tab left.
        var lamp: String?
        #expect(pages.rising.rotate(&standing.walk, by: 1, covered: false, lamp: &lamp, in: session) && standing.walk.standing == .rising(.tags))
        #expect(FediqoRootView.stepTab(.rising(.tags), drawn: TimelinePane.drawn(standing.walk.standing, of: pages, in: session).drawn, open: [.rising]) == .page)
    }

    // MARK: - Laid out

    private func laidOut(_ page: RisingPage, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize) -> [OpenedPageProbe.Part: CGRect] {
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
        let row = RisingRow.tag(RisingTag(tag: PostTag("#birds")!), source: Self.one)
        let saids = [
            RisingSaid(which: .tags, bands: [RisingSaid.Band(source: Self.one, reading: .said, rows: [row]), RisingSaid.Band(source: Self.two, reading: .failed)]),
            RisingSaid(which: .links, bands: [RisingSaid.Band(source: Self.one)]),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .xxxLarge), (.narrow, 320, .accessibility5),
            ] {
                for said in saids {
                    for tabs in [RisingWhich.allCases, [said.which]] {
                        for reload in [RisingPage.reloadName(canReload: true), nil] {
                            let at = "\(said.which) of \(tabs) at \(width), \(scheme), \(size), \(reload == nil ? "without" : "with") the mark"
                            let page = RisingPage(said: said, tabs: tabs, selectedID: .constant(row.id), reload: reload)
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
                            } else if tabs.count == 1 {
                                #expect(room.minY - bar.maxY > 20, "\(at): the head stands between the bar and the list")
                            } else {
                                #expect(parts[.strip]!.minY - bar.maxY > 20, "\(at): the head stands between the bar and the strip")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("The page, its tab and its list draw and learn no kind of source")
    func drawsNotKnowingKind() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        for file in ["RisingPage.swift", "RisingPane.swift", "RisingTab.swift"] {
            let text = try String(contentsOf: url.appending(path: "Sources/FediqoUI/Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class RisingDefaults: UserDefaults, @unchecked Sendable {
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
