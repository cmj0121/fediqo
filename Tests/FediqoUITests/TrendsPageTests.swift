import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Trends, a place of its own (decisions 1–4, 7, 13, 18, 20): on the rail between Timeline and
/// Notices where some source has anything trending, with Posts · Hashtags · Links where its
/// sources have them — a tab no source has absent — Posts the old Trends timeline, Hashtags
/// and Links what the rising page asked; `h` from anywhere; and each stream place its own walk.
///
/// **No check here waits on anything but the call it makes**, but the hosted pane's: that one
/// waits with `met` on its own `.task` asking, the run loop turned inside the condition.
@MainActor
@Suite("Trends, a place of its own", .watched)
struct TrendsPageTests {
    private static let one = "m.example", two = "n.example"
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let talk = Source(host: "talk.example", kind: .discourse)
    private static let tags = "/api/v1/trends/tags?limit=20"
    private static let links = "/api/v1/trends/links?limit=20"
    private static let tagsAnswer = PageServer.Answer(body: #"[{"name":"birds","history":[]}]"#)
    private static let linksAnswer = PageServer.Answer(body: #"[{"url":"https://far.example/story","title":"A story"}]"#)

    /// Two sources that say who people are and a forum, each with a server of its own, and
    /// the person pages the session asks for what is rising.
    private func session(sources: [Source]? = nil) async -> (ShellSession, ShellPersonPages, [String: PageServer]) {
        let routes = [Self.tags: Self.tagsAnswer, Self.links: Self.linksAnswer]
        let servers = [
            Self.one: PageServer(routes), Self.two: PageServer(routes), Self.forum.host: PageServer([:]), Self.talk.host: PageServer([:]),
        ]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.work = SourceWork()
        let joined = sources ?? [Source(host: Self.one, kind: .mastodon), Source(host: Self.two, kind: .mastodon), Self.forum]
        for source in joined { await session.store.add(source) }
        session.sources = await session.store.sources()
        session.rebuildQueries()
        let pages = ShellPersonPages()
        session.personPages = pages
        return (session, pages, servers)
    }

    /// Every source of `session` answers that it has no ranking of `which`, for the run.
    private func absent(_ which: RisingWhich, in pages: ShellPersonPages, _ session: ShellSession) {
        for source in session.sources {
            pages.more.hosts.notFound(which.thing, at: source.host, round: pages.more.hosts.round(at: source.host))
        }
    }

    // MARK: - The place

    @Test("Trends stands on the rail between Timeline and Notices where some source has anything trending, and is absent — not dim — where none has: a Discourse-only store has no Trends, so neither the rail, the places nor `h` reach it")
    func thePlace() async {
        #expect(ShellPlace.allCases == [.timeline, .trends, .notices, .admin, .account, .usage, .preferences])
        #expect(ShellPlace.trends.symbolName == "chart.line.uptrend.xyaxis")
        #expect(ShellPlace.timeline.isStream && ShellPlace.trends.isStream)
        #expect(ShellPlace.allCases.filter(\.isStream) == [.timeline, .trends])
        #expect(ShellStream(.trends) == .trends && ShellStream(.timeline) == .timeline && ShellStream(.notices) == nil)
        for language in DummyLanguage.allCases {
            for key in ["shell.trends.title", "shell.trends.summary", "trends.tab.posts"] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
        #expect(ShellPlace.trends.title(language: .english) == "Trends" && ShellPlace.trends.title(language: .taiwanese) == "趨勢")

        let (all, pages, _) = await session()
        // The pages are the session's weakly, as the root's are: held for the check.
        let held = withExtendedLifetime(pages) { all.availability }
        #expect(held.trendsTabs == [.posts, .tags, .links] && held.allows(.trends))
        #expect(held.railPlaces == ShellPlace.allCases && held.enabledPlaces.prefix(3) == [.timeline, .trends, .notices])
        #expect(held.reasonKey(for: .trends) == nil)
        #expect(FediqoRootView.opensTrends(held, open: []) && FediqoRootView.opensTrends(held, open: [.thread, .selection]))

        let (talk, _, _) = await session(sources: [Self.talk])
        let none = talk.availability
        #expect(none.trendsTabs.isEmpty && !none.allows(.trends))
        #expect(!none.railPlaces.contains(.trends) && !none.enabledPlaces.contains(.trends), "absent, never grey")
        #expect(none.railPlaces == [.timeline, .notices, .admin, .account, .usage, .preferences])
        #expect(none.placing(.trends, as: .trends) == .timeline, "a reader standing on it as it goes is moved off")
        #expect(!FediqoRootView.opensTrends(none, open: []))
        #expect(!ShellAvailability.empty.allows(.trends) && !ShellAvailability.empty.railPlaces.contains(.trends))
    }

    @Test("`h` brings Trends in front from any place, but not under the picture opened or the keys' guide, and never in a text field; it is named in the keys' list")
    func theKey() async throws {
        #expect(DummyCommand.from("h") == .openTrends && DummyCommand.from("h", typing: true) == nil && DummyCommand.from("h", fieldFocused: true) == nil)
        let line = try #require(DummyShortcut.all.first { $0.commands == [.openTrends] })
        #expect(line.keys == ["h"] && line.group == .move)
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let keys = try String(contentsOf: url.appending(path: "Sources/FediqoUI/Shell/DummyShellKeys.swift"), encoding: .utf8)
        #expect(keys.contains(#""o", "h", "l", "y""#), "the key reaches the shell")
        let (session, _, _) = await session()
        let availability = session.availability
        for open in [Set<DummyLayer>(), [.selection], [.person], [.tag, .selection], [.search], [.rising]] {
            #expect(FediqoRootView.opensTrends(availability, open: open), "\(open)")
        }
        for over in [DummyLayer.viewer, .shortcuts] {
            #expect(!FediqoRootView.opensTrends(availability, open: [over]), "\(over)")
            #expect(!FediqoRootView.opensTrends(availability, open: [over, .thread]), "\(over)")
        }
    }

    // MARK: - Which tabs

    @Test("Trends' tabs are Posts where a source has a trending timeline, then each kind of thing some source ranks, in the order Posts · Hashtags · Links: all three for microblogs, Posts alone for a forum's rankings, none for a Discourse — and a tab every source said it has none of is gone")
    func whichTabs() async {
        #expect(TrendsTab.tabs(posts: true, rising: RisingWhich.allCases) == [.posts, .tags, .links])
        #expect(TrendsTab.tabs(posts: true, rising: [.links]) == [.posts, .links])
        #expect(TrendsTab.tabs(posts: false, rising: [.links, .tags]) == [.tags, .links])
        #expect(TrendsTab.tabs(posts: false, rising: []).isEmpty)
        #expect(TrendsTab.posts.rising == nil && TrendsTab.tags.rising == .tags && TrendsTab.links.rising == .links)
        #expect(TrendsTab(.tags) == .tags && TrendsTab(.links) == .links)
        #expect(TrendsTab.tags.titleKey == "rising.tab.tags" && TrendsTab.links.symbol == "link" && TrendsTab.posts.titleKey == "trends.tab.posts")

        let (microblogs, pages, _) = await session(sources: [Source(host: Self.one, kind: .mastodon)])
        #expect(TrendsTab.tabs(in: microblogs) == [.posts, .tags, .links])
        absent(.links, in: pages, microblogs)
        #expect(TrendsTab.tabs(in: microblogs) == [.posts, .tags])
        let (forum, _, _) = await session(sources: [Self.forum])
        #expect(TrendsTab.tabs(in: forum) == [.posts] && !PageFrame.stripDrawn(TrendsTab.tabs(in: forum)), "one tab, no strip")
        let (talk, _, _) = await session(sources: [Self.talk])
        #expect(TrendsTab.tabs(in: talk).isEmpty)
        let (both, _, _) = await session(sources: [Self.forum, Self.talk])
        #expect(TrendsTab.tabs(in: both) == [.posts])
    }

    @Test("The tab in front is the one left in front while Trends still has it, and the first left where it has not; it starts on Posts, and nothing is written down")
    func theFront() {
        #expect(TrendsFront().tab == .posts && TrendsFront().lamps.isEmpty)
        #expect(TrendsTab.front(.links, among: [.posts, .tags, .links]) == .links)
        #expect(TrendsTab.front(.links, among: [.posts, .tags]) == .posts)
        #expect(TrendsTab.front(.posts, among: [.tags, .links]) == .tags)
        #expect(TrendsTab.front(.tags, among: []) == nil)
    }

    @Test("Tab turns Trends' tabs round their ring, is taken and turns nothing with one tab, and is nobody's while something covers the page")
    func tabTurnsTheTabs() {
        let three = TrendsTab.allCases
        #expect(TrendsTab.keyed(three, front: .posts, by: 1, covered: false) == .turn(.tags))
        #expect(TrendsTab.keyed(three, front: .links, by: 1, covered: false) == .turn(.posts), "round the ring")
        #expect(TrendsTab.keyed(three, front: .posts, by: -1, covered: false) == .turn(.links))
        #expect(TrendsTab.keyed([.posts], front: .posts, by: 1, covered: false) == .taken)
        #expect(TrendsTab.keyed(three, front: .posts, by: 1, covered: true) == .unheard)
    }

    @Test("Each tab keeps its own lamp: turned to, it is lit where it was left while that row is still the tab's, and a tab not in front before is lit nowhere; a tab Trends has not, or the one in front, turns nothing")
    func eachTabKeepsItsLamp() {
        var front = TrendsTab.posts
        var lamps: [TrendsTab: String] = [:]
        var lamp: String? = "post"
        #expect(TrendsTab.turned(&front, to: .tags, among: TrendsTab.allCases, rows: ["tag"], lamps: &lamps, lamp: &lamp))
        #expect(front == .tags && lamp == nil && lamps[.posts] == "post")
        lamp = "tag"
        #expect(!TrendsTab.turned(&front, to: .tags, among: TrendsTab.allCases, rows: ["tag"], lamps: &lamps, lamp: &lamp) && lamp == "tag", "the tab in front")
        #expect(TrendsTab.turned(&front, to: .posts, among: TrendsTab.allCases, rows: ["post"], lamps: &lamps, lamp: &lamp) && lamp == "post")
        #expect(TrendsTab.turned(&front, to: .tags, among: TrendsTab.allCases, rows: ["tag"], lamps: &lamps, lamp: &lamp) && lamp == "tag")
        // A kept lamp on a row the tab no longer has is handed back as none.
        #expect(TrendsTab.turned(&front, to: .posts, among: TrendsTab.allCases, rows: ["other"], lamps: &lamps, lamp: &lamp) && lamp == nil)
        // A tab Trends no longer has is not turned to.
        #expect(!TrendsTab.turned(&front, to: .links, among: [.posts, .tags], rows: [], lamps: &lamps, lamp: &lamp) && front == .posts)
    }

    // MARK: - The streams

    @Test("Posts is the old Trends timeline: the session following Trends draws the `.trends` query whatever the timeline's selection, and following the timeline again draws that selection; the timeline offers All and the reader's own timelines only, and a remembered Trends selection opens All")
    func postsIsTheOldTab() async {
        let (session, _, _) = await session()
        #expect(session.queries == [.all], "no Trends tab on the timeline")
        #expect(session.stream == .timeline && session.currentTimeline == .all)
        session.stream = .trends
        #expect(session.currentTimeline == .trends)
        #expect(session.timelineID == .all, "the timeline's own selection is not Trends'")
        session.stream = .timeline
        #expect(session.currentTimeline == .all)
        session.timelineID = .trends
        session.rebuildQueries()
        #expect(session.timelineID == .all, "a remembered Trends opens All")
        #expect(TimelineQuery(id: "trends") == .trends, "the query still parses, for Trends' own lamp")
    }

    @Test("Each stream place keeps its own walk and lamp: a step taken on Trends is not under the timeline, and the timeline's is where it was left")
    func eachStreamItsOwnWalk() throws {
        var sides = StreamSides()
        _ = sides[.timeline].walk.walk(to: .thread("a"), from: "row-a")
        sides[.timeline].lamp = "row-a"
        let tag = try #require(PostTag("#birds"))
        _ = sides[.trends].walk.walk(to: .tag(tag), from: "rising-row")
        sides[.trends].lamp = "rising-row"
        #expect(sides[.timeline].walk.standing == .thread("a") && sides[.timeline].lamp == "row-a")
        #expect(sides[.trends].walk.standing == .tag(tag) && sides[.trends].lamp == "rising-row")
        _ = sides[.trends].walk.back()
        #expect(sides[.trends].walk.isEmpty && sides[.timeline].walk.depth == 1)
        // A notice's errand is the timeline's, from a place that draws no stream — and from a
        // stream place a step is only that place's own.
        var walk = ShellWalk()
        #expect(PlaceErrand.setOut(to: .thread("b"), from: .trends, on: &walk, lamp: nil) == nil && walk.isEmpty)
        #expect(PlaceErrand.setOut(to: .thread("b"), from: .notices, on: &walk, lamp: nil) != nil)
    }

    @Test("On Hashtags or Links the keys walk the tab's rows, `r` and its mark ask its sources again where they may be asked, and nothing else is asked of the stream; the walk and the search keys are Trends' as the timeline's")
    func theKeysOnARisingTab() async throws {
        let (session, pages, _) = await session()
        await pages.rising.opened(.tags, in: session)
        let rows = pages.rising.walked(.tags, in: session)
        #expect(!rows.isEmpty)
        let ids = FediqoRootView.listIDs(on: ShellWalk(), pages: pages, found: [], items: [], drawn: ["post"], rising: rows, in: session)
        #expect(ids == rows, "the tab's rows, not the stream's")
        var walked = ShellWalk()
        _ = walked.walk(to: .thread("post"), from: rows.first)
        #expect(FediqoRootView.listIDs(on: walked, pages: pages, found: [], items: [], rising: rows, in: session) == nil, "over a step, the step's")
        func reloads(_ open: Set<DummyLayer>, rising: Bool?) -> Bool {
            FediqoRootView.canReload(place: .trends, editing: false, hasSources: true, open: open, risingAsked: rising)
        }
        #expect(reloads([], rising: true) && reloads([.selection], rising: true))
        #expect(!reloads([.selection], rising: false), "every source of the tab on the wire: refused")
        #expect(reloads([.selection], rising: nil), "Posts: the stream")
        #expect(!reloads([.viewer], rising: true))
        for place in [ShellPlace.timeline, .trends] {
            #expect(FediqoRootView.canWalk(place: place, open: [.selection]) && FediqoRootView.canSearch(place: place, open: []))
            #expect(FediqoRootView.canOpenAuthor(place: place, open: [.selection]))
            #expect(FediqoRootView.escapeSees([.thread, .selection], place: place) == [.thread, .selection])
        }
        #expect(FediqoRootView.escapeSees([.thread, .selection], place: .notices) == [.selection])
        var selected: String? = rows.last
        var jump = 0
        #expect(FediqoRootView.jumpedToTop(in: rows, standing: nil, place: .trends, selected: &selected, jump: &jump) && selected == rows.first)
    }

    @Test("A place switch keeps each stream place's walk, lamp and top row on its own side, and the search is closed on the side it was opened over before the session follows the other")
    func aSwitchKeepsEachSide() async throws {
        let (session, _, _) = await session()
        var sides = StreamSides()
        _ = sides[.timeline].walk.walk(to: .thread("a"), from: "row-a")
        sides[.timeline].lamp = "row-a"
        session.scrolledTop = "top-a"
        #expect(!FediqoRootView.follow(.timeline, sides: &sides, in: session), "the stream followed already: nothing moves")
        #expect(!FediqoRootView.follow(.trends, sides: &sides, in: session))
        #expect(session.stream == .trends && session.currentTimeline == .trends && session.scrolledTop == nil)
        #expect(sides[.timeline].walk.standing == .thread("a") && sides[.timeline].lamp == "row-a" && sides[.timeline].top == "top-a")
        let tag = try #require(PostTag("#birds"))
        _ = sides[.trends].walk.walk(to: .tag(tag), from: "rising-row")
        sides[.trends].lamp = "rising-row"
        session.scrolledTop = "top-b"
        #expect(!FediqoRootView.follow(.timeline, sides: &sides, in: session))
        #expect(session.stream == .timeline && session.currentTimeline == .all && session.scrolledTop == "top-a")
        #expect(sides[.trends].walk.standing == .tag(tag) && sides[.trends].lamp == "rising-row" && sides[.trends].top == "top-b")
        #expect(sides.holdsTag(tag) && !sides.holdsPerson("nobody"))

        // The search is the stream's it was opened over, closed before the other is followed.
        let root = try String(contentsOf: Self.ui.appending(path: "FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains("if search.closes(leaving: old, for: accepted) { closeSearch() }\n                if let stream = ShellStream(accepted) { follow(stream) }"))
    }

    @Test("A notice's errand after Trends was followed is the timeline's: the step is taken on the timeline's walk, and Trends' walk is as it was left")
    func anErrandAfterTrends() async throws {
        let (session, _, _) = await session()
        var sides = StreamSides()
        session.stream = .trends
        let tag = try #require(PostTag("#birds"))
        _ = sides[.trends].walk.walk(to: .tag(tag), from: "rising-row")
        _ = FediqoRootView.follow(.timeline, sides: &sides, in: session)
        let errand = PlaceErrand.setOut(to: .thread("post"), from: .notices, line: "notice", on: &sides[.timeline].walk, lamp: nil)
        #expect(errand?.from == .notices && session.stream == .timeline)
        #expect(sides[.timeline].walk.standing == .thread("post") && sides[.trends].walk.standing == .tag(tag))
        // The root follows the timeline before the step, whichever stream was followed last.
        let root = try String(contentsOf: Self.ui.appending(path: "FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains("follow(.timeline)\n        errand = PlaceErrand.setOut(to: step, from: .notices,"))
        #expect(root.contains("follow(.timeline)\n        errand = PlaceErrand.setOut(to: step, from: place,"))
    }

    @Test("A page read out of a post is left with the stream it was read over: following the other takes its step back, its lamp given back, and says so for the one reader to be closed; the steps under it stay")
    func aLinkStaysOnItsSide() async throws {
        let (session, _, _) = await session()
        var sides = StreamSides()
        _ = sides[.timeline].walk.walk(to: .thread("a"), from: "row-a")
        _ = sides[.timeline].walk.walk(to: .link(URL(string: "https://example.org/a")!), from: "reply-1")
        sides[.timeline].lamp = "reply-1"
        #expect(FediqoRootView.follow(.trends, sides: &sides, in: session), "a link was left: the reader is closed")
        #expect(sides[.timeline].walk.openedLink == nil && sides[.timeline].walk.standing == .thread("a"))
        #expect(sides[.timeline].lamp == "reply-1" && sides[.trends].walk.openedLink == nil)
        #expect(!FediqoRootView.follow(.timeline, sides: &sides, in: session), "back: no link to leave on Trends")
        #expect(sides[.timeline].walk.standing == .thread("a"))
        let root = try String(contentsOf: Self.ui.appending(path: "FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains("if Self.follow(stream, sides: &sides, in: session) { linkReader.close() }"))
    }

    @Test("Somebody's page still a step of the other stream place's walk keeps its tab in front when this side leaves it, or ends in one go; once neither side holds it, it is forgotten")
    func aPersonsTabStaysWhileEitherSideHoldsIt() throws {
        let pages = ShellPersonPages()
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.one))
        let tabs: [PersonTab] = [.about, .followers, .posts]
        var lamp: String?
        #expect(pages.tabs.turn(ada.id, to: .followers, among: tabs, lamp: &lamp))
        var here = ShellWalk(), there = ShellWalk()
        _ = here.walk(to: .person(ada), from: "row")
        _ = there.walk(to: .person(ada), from: "post")
        let left = here.back()
        pages.left(try #require(left).step, of: here, besides: there)
        #expect(pages.tabs.front(of: ada.id, among: tabs) == .followers, "the other side still holds the page")
        pages.leftAll(besides: there)
        #expect(pages.tabs.front(of: ada.id, among: tabs) == .followers, "ended in one go, the other side's page keeps its tab")
        pages.left(try #require(left).step, of: here, besides: ShellWalk())
        #expect(pages.tabs.front(of: ada.id, among: tabs) == .about, "neither side holds it: forgotten")
        #expect(pages.tabs.turn(ada.id, to: .followers, among: tabs, lamp: &lamp))
        pages.leftAll(besides: ShellWalk())
        #expect(pages.tabs.front(of: ada.id, among: tabs) == .about)
    }

    @Test("The timeline switched while Trends is followed ends the timeline's side whole — walk, lamp and top row — and Trends' not at all; a hashtag's ask of a timeline ends, one of Trends' does not")
    func aSwitchUnderTrends() throws {
        let tag = try #require(PostTag("#birds"))
        let list = FollowedTags(host: Self.one)
        func sides() -> StreamSides {
            var sides = StreamSides()
            _ = sides[.timeline].walk.walk(to: .followedTags(list), from: "row-a")
            _ = sides[.timeline].walk.walk(to: .link(URL(string: "https://example.org/a")!), from: "tag-row")
            sides[.timeline].lamp = "tag-row"
            sides[.timeline].top = "top-a"
            _ = sides[.trends].walk.walk(to: .tag(tag), from: "rising-row")
            sides[.trends].lamp = "rising-row"
            sides[.trends].top = "top-b"
            return sides
        }
        var under = sides()
        let trends = under[.trends]
        let cleared = FediqoRootView.timelineSwitchedUnderTrends(&under, tagAsk: .all)
        #expect(under[.timeline] == StreamSide(), "walk cleared, lamp and top none")
        #expect(under[.trends] == trends, "Trends' side untouched")
        #expect(cleared.side == .timeline && cleared.leftLink && cleared.endsTag && cleared.lists == [list])
        #expect(cleared.other == trends.walk)
        var owned = sides()
        #expect(!FediqoRootView.timelineSwitchedUnderTrends(&owned, tagAsk: .trends).endsTag, "Trends' ask is not the timeline's to end")
        var written = sides()
        #expect(FediqoRootView.timelineSwitchedUnderTrends(&written, tagAsk: .written(UUID())).endsTag)
        var none = sides()
        #expect(FediqoRootView.timelineSwitchedUnderTrends(&none, tagAsk: nil).endsTag, "with no ask, ending says nothing")
        // A list held on both sides is not closed with the one.
        var both = sides()
        _ = both[.trends].walk.walk(to: .followedTags(list), from: nil)
        #expect(FediqoRootView.timelineSwitchedUnderTrends(&both, tagAsk: nil).lists.isEmpty)
    }

    @Test("Trends gone with its last source ends its side whole — its steps no longer open over anything — and the timeline's not at all; a side with nothing on it owes nothing")
    func trendsGoneEndsItsSide() throws {
        let tag = try #require(PostTag("#birds"))
        var sides = StreamSides()
        _ = sides[.timeline].walk.walk(to: .thread("a"), from: "row-a")
        sides[.timeline].lamp = "row-a"
        _ = sides[.trends].walk.walk(to: .tag(tag), from: "rising-row")
        _ = sides[.trends].walk.walk(to: .thread("b"), from: "b")
        sides[.trends].lamp = "b"
        sides[.trends].top = "top-b"
        #expect(FediqoRootView.openSteps(sides) == [.thread("a"), .tag(tag), .thread("b")])
        let timeline = sides[.timeline]
        let cleared = try #require(FediqoRootView.trendsGone(&sides, tagAsk: .trends))
        #expect(sides[.trends] == StreamSide() && sides[.timeline] == timeline)
        #expect(FediqoRootView.openSteps(sides) == [.thread("a")], "Trends' steps are no longer open")
        #expect(cleared.side == .trends && cleared.endsTag && !cleared.leftLink && cleared.other == timeline.walk)
        #expect(FediqoRootView.trendsGone(&sides, tagAsk: nil) == nil, "nothing left on it: nothing owed")
        var lampOnly = StreamSides()
        lampOnly[.trends].lamp = "post"
        #expect(FediqoRootView.trendsGone(&lampOnly, tagAsk: .all)?.endsTag == false, "the timeline's ask is not Trends'")
        #expect(lampOnly[.trends] == StreamSide())
    }

    @Test("A rising row opens its hashtag as a step of Trends' walk, from that row; Back gives the tab's lamp back on that row")
    func aRowToATagAndBack() async throws {
        let (session, pages, _) = await session()
        await pages.rising.opened(.tags, in: session)
        let row = try #require(pages.rising.said(.tags, in: session)?.rows.first)
        guard case .tag(let tag, _) = row.row else { Issue.record("a hashtag's row"); return }
        var side = StreamSide()
        side.lamp = ShellRising.lamp(after: true, of: row.id, before: nil)
        #expect(side.lamp == row.id)
        let took = side.walk.walk(to: .tag(tag.tag), from: side.lamp)
        #expect(took)
        let back = side.walk.back()
        let left = try #require(back)
        side.lamp = FediqoRootView.lampBack(left.lamp, onto: side.walk.standing, rows: pages.rising.walked(.tags, in: session))
        #expect(side.walk.isEmpty && side.lamp == row.id)
        #expect(ShellRising.lamp(after: false, of: row.id, before: "was") == "was", "a press that opens nothing moves nothing")
    }

    @Test("The tab in front gone, the first left comes in front as a turn would: the gone tab's lamp kept, and the one the arrived tab was left with given back where it still has that row")
    func theFrontFalls() {
        var front = TrendsFront(tab: .links, lamps: [.posts: "post-1"])
        var lamp: String? = "link-1"
        #expect(!front.fell(among: TrendsTab.allCases, lamp: &lamp, rows: { _ in [] }) && front.tab == .links && lamp == "link-1")
        #expect(front.fell(among: [.posts, .tags], lamp: &lamp, rows: { _ in ["post-1"] }))
        #expect(front.tab == .posts && lamp == "post-1" && front.lamps[.links] == "link-1")
        var gone = TrendsFront(tab: .tags, lamps: [.links: "old"])
        lamp = "tag-1"
        #expect(gone.fell(among: [.links], lamp: &lamp, rows: { _ in ["new"] }) && lamp == nil, "a row the tab no longer has")
        var unread = TrendsFront(tab: .tags, lamps: [.posts: "post-9"])
        lamp = nil
        #expect(unread.fell(among: [.posts], lamp: &lamp, rows: { _ in nil }) && lamp == "post-9", "rows not to be had: kept as left")
        #expect(FediqoRootView.trendsHead(tabs: [.posts, .tags], kept: .links, onTurn: { _ in }).front == .posts)
        #expect(FediqoRootView.trendsHead(tabs: TrendsTab.allCases, kept: .links, onTurn: { _ in }).front == .links)
    }

    private static var ui: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    // MARK: - Hosted

    /// The tab in front, which a check moves — and the pane turns — as the root would.
    @Observable
    final class Front {
        var tab: TrendsTab
        init(_ tab: TrendsTab) { self.tab = tab }
    }

    /// The root's share of Trends, on the tab `front` says, with the pages held.
    private struct Host: View {
        let session: ShellSession
        let pages: ShellPersonPages
        let front: Front
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: TrendsDefaults())

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: nil, onOpenPerson: { _ in }, decks: $decks,
                playback: playback, onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                jumpToTop: 0, onBack: {}, ways: TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {}),
                search: ShellSearch(), people: pages,
                serverFilters: true,
                trends: FediqoRootView.trendsHead(tabs: TrendsTab.tabs(in: session), kept: front.tab) { front.tab = $0 }
            )
            .environment(prefs)
        }
    }

    @Test("Brought in front, Hashtags asks its sources and Links nothing; Links, brought in front, asks its own; Posts asks neither — and Trends' head is drawn over each, with no timeline's names")
    func aTabNeverInFrontAskedNothing() async {
        for (first, then) in [(TrendsTab.tags, TrendsTab.links), (.links, .tags)] {
            let (session, pages, servers) = await session()
            session.stream = .trends
            let front = Front(.posts)
            let probe = PaneProbe()
            let hosted = NSHostingView(rootView: Host(session: session, pages: pages, front: front).environment(\.shellPaneProbe, probe))
            hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
            turn(hosted)
            turn(hosted)
            for host in [Self.one, Self.two] {
                #expect(await rising(servers[host]).isEmpty, "Posts in front: \(host) asked nothing of what is rising")
            }
            #expect(probe.head != .zero, "Trends' head is drawn over Posts")
            let path = [TrendsTab.tags: Self.tags, .links: Self.links]
            front.tab = first
            await met("\(first) asked of both sources, and landed") {
                turn(hosted)
                return first.rising.flatMap { pages.rising.said($0, in: session) }?.answers.allSatisfy { $0.reading == .said } == true
            }
            for host in [Self.one, Self.two] {
                #expect(await rising(servers[host]) == [path[first]!], "\(first) in front: \(host) asked nothing of \(then)")
            }
            #expect(await rising(servers[Self.forum.host]).isEmpty, "a forum is asked nothing of what is rising")
            #expect(probe.head != .zero, "Trends' head is drawn over \(first)")

            front.tab = then
            await met("\(then) asked once in front") {
                turn(hosted)
                return then.rising.flatMap { pages.rising.said($0, in: session) }?.answers.allSatisfy { $0.reading == .said } == true
            }
            for host in [Self.one, Self.two] {
                #expect(await rising(servers[host]) == [path[first]!, path[then]!], "\(host)")
            }
        }
    }

    @Test("Every source answering, with Links in front, that it has no such address: Links goes, the first tab left comes in front — no step more, Links not asked again — and Hashtags, brought in front, is drawn and asked")
    func theTabLeftComesInFront() async {
        let (session, pages, servers) = await session()
        session.stream = .trends
        let off = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)
        for host in [Self.one, Self.two] { await servers[host]?.answer(Self.links, off) }
        let front = Front(.links)
        let hosted = NSHostingView(rootView: Host(session: session, pages: pages, front: front))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        await met("Links asked of both sources and gone") {
            turn(hosted)
            return TrendsTab.tabs(in: session) == [.posts, .tags]
        }
        #expect(FediqoRootView.trendsHead(tabs: TrendsTab.tabs(in: session), kept: front.tab, onTurn: { _ in }).front == .posts)
        turn(hosted)
        turn(hosted)
        for host in [Self.one, Self.two] {
            #expect(await rising(servers[host]) == [Self.links], "\(host): Links once, and nothing more")
        }
        front.tab = .tags
        await met("Hashtags in front, asked and landed") {
            turn(hosted)
            return pages.rising.said(.tags, in: session)?.answers.allSatisfy { $0.reading == .said } == true
        }
        for host in [Self.one, Self.two] {
            #expect(await rising(servers[host]) == [Self.links, Self.tags], "\(host)")
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

    @Test("On Trends with nothing walked, a swipe turns its tabs and stops at either end — Trends is a place, and no swipe leaves it")
    func theSwipe() {
        let three = TrendsTab.allCases
        #expect(TimelineSwipe.means(touch: true, page: .timeline, searching: false, listShown: false, editing: false) == .beside)
        let ways = TimelineSwipe.ways(.beside, index: three.firstIndex(of: .posts), count: three.count)
        #expect(ways.next && !ways.previous, "Posts, the first: nothing before it")
        #expect(TimelineSwipe.target(from: three.firstIndex(of: .tags), count: three.count, step: 1) == 2)
        #expect(TimelineSwipe.target(from: three.firstIndex(of: .links), count: three.count, step: 1) == nil)
    }

    // MARK: - Laid out

    @Test("Trends draws to the width it is given and never past it, on each tab, at 720, 390 and 320, in light and in dark")
    func laidOut() async {
        let (session, pages, _) = await session()
        session.stream = .trends
        await pages.rising.opened(.tags, in: session)
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
                for tab in TrendsTab.allCases {
                    let hosted = NSHostingView(
                        rootView: Host(session: session, pages: pages, front: Front(tab))
                            .frame(width: width, height: 700)
                            .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                    )
                    hosted.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                    hosted.layoutSubtreeIfNeeded()
                    #expect(hosted.fittingSize.width == width, "\(tab) at \(width), \(scheme)")
                }
            }
        }
    }

    @Test("The tabs of what is rising draw and learn no kind of source")
    func drawsNotKnowingKind() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        for file in ["RisingPane.swift", "RisingTab.swift"] {
            let text = try String(contentsOf: url.appending(path: "Sources/FediqoUI/Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class TrendsDefaults: UserDefaults, @unchecked Sendable {
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
