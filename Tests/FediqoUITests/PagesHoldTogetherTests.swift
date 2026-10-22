#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, the sweep: every page opened over the stream answers the one decision of what is drawn
/// (`TimelinePane.drawn`) the same way — the timelines' head, the keys that walk a list, `r`, the
/// search field — and the parts every page shares say the same thing on each.
///
/// **No check here waits on anything but what it hosts**: each asks a value, or lays a hosted
/// view out and waits with `met` for what the layout draws.
@MainActor
@Suite("The opened pages hold together", .watched)
struct PagesHoldTogetherTests {
    private static let host = "m.example"
    /// The one source: a forum, which says nobody's lists and ranks nothing, so every page that
    /// may not be drawn is not.
    private static let source = Source(host: "forum.example", kind: .discuz)
    /// A host no source of the session is at: a page asked of it cannot be drawn.
    private static let gone = "gone.example"
    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!
    private static let found = FoundAt(source: gone, words: "swift", gave: FoundWhich.allCases)

    /// One step of every kind, and whether its page may be one that cannot be drawn.
    private static let everyKind: [(step: ShellStep?, undrawable: Bool)] = [
        (nil, false),
        (.person(ada), false),
        (.tag(PostTag("#swift")!), false),
        (.link(URL(string: "https://example.org/a")!), false),
        (.thread("withdrawn"), true),
        (.people(PeopleList(directoryAt: gone)), true),
        (.found(found, .people), true),
        (.found(found, .tags), true),
        (.followedTags(FollowedTags(host: gone)), true),
        (.shared(SharedLink(link: RisingLink(link: PostLink("https://example.org/story")!), sources: [gone])), true),
    ]

    /// Names every kind of step, with no `default:`: a kind added later does not compile here
    /// until it is named, and `everyKind` is then asked to hold it.
    private static func kind(_ step: ShellStep?) -> String {
        switch step {
        case nil: "stream"
        case .person: "person"
        case .tag: "tag"
        case .link: "link"
        case .thread: "thread"
        case .people: "people"
        case .found: "found"
        case .followedTags: "followedTags"
        case .shared: "shared"
        }
    }

    @Test("The list of steps is every kind there is")
    func everyKindIsHere() {
        #expect(Set(Self.everyKind.map { Self.kind($0.step) }) == ["stream", "person", "tag", "link", "thread", "people", "found", "followedTags", "shared"])
    }

    /// A session with one source and five posts on the stream; the pages held beside it.
    private func streamSession() -> (ShellSession, ShellPersonPages) {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: TogetherDefaults()))
        session.sources = [Self.source]
        session.rebuildQueries()
        session.notes = (0..<5).map { at in
            Note(id: "n\(at)", source: Self.source, author: "Ada", handle: "@ada@m.example", body: "post \(at)",
                 postedAt: Date(timeIntervalSince1970: Double(100 - at)), categories: [.public])
        }
        session.timelineID = .all
        return (session, ShellPersonPages())
    }

    // MARK: - The timelines' head

    @Test("The timelines' head is drawn over the stream and over a page read out of a post, and over a page that cannot be drawn — which draws the stream — and over no page drawn")
    func theHeadIsOverTheStreamAlone() {
        for (step, undrawable) in Self.everyKind {
            let name = Self.kind(step)
            let overStream = step == nil || name == "link"
            #expect(TimelinePane.headDrawn(over: step, drawn: true) == overStream, "\(name), drawn")
            if undrawable {
                #expect(TimelinePane.headDrawn(over: step, drawn: false), "\(name), not drawn: the stream is, under the head")
            }
        }
        // A person's page and a hashtag's are always drawn, and so are the stream and a link.
        let (session, pages) = streamSession()
        for (step, undrawable) in Self.everyKind where !undrawable {
            #expect(TimelinePane.drawn(step, of: pages, in: session).drawn, "\(Self.kind(step))")
        }
    }

    // MARK: - The keys over a page that cannot be drawn

    @Test("Over every page that cannot be drawn the keys have the stream: j and k walk its posts, the lamp enters on its first, a mark's key lands on it and Return reads it as a post — and over each page drawn, the page's own rows")
    func theKeysWalkTheStreamOverAnUndrawnPage() throws {
        let (session, pages) = streamSession()
        let stream = session.timelineItems(latest: nil)
        let streamIDs = stream.map(\.id)
        try #require(streamIDs.count == 5)
        for (step, undrawable) in Self.everyKind where undrawable {
            let step = try #require(step)
            let name = Self.kind(step)
            var walk = ShellWalk()
            let walked = walk.walk(to: step, from: nil)
            #expect(walked)
            let shown = TimelinePane.drawn(step, of: pages, in: session)
            try #require(!shown.drawn, "\(name) cannot be drawn here")
            // The walk as the keys have it is none: the stream drawn in its stead.
            let keyed = FediqoRootView.keyed(walk, drawn: shown.drawn)
            #expect(keyed.isEmpty && keyed.standing == nil, "\(name)")
            #expect(keyed.openedPeople == nil && keyed.openedFoundTags == nil && keyed.openedFollowedTags == nil, "\(name): Return reads no row of the page")
            let items = FediqoRootView.listItems(on: keyed, pages: pages, stream: stream, latest: nil, in: session)
            let ids = FediqoRootView.listIDs(on: keyed, pages: pages, found: [], items: items, in: session)
            #expect(items.map(\.id) == streamIDs && ids == streamIDs, "\(name): the stream's posts are walked")
            let open = FediqoRootView.drawnLayers([step.layer], standing: step, drawn: shown.drawn)
            #expect(FediqoRootView.moved(in: ids, from: nil, by: 1, open: open) == streamIDs.first, "\(name): j enters on the first post")
            #expect(FediqoRootView.moved(in: ids, from: streamIDs[1], by: 1, open: open) == streamIDs[2], "\(name): and moves on")
            #expect(FediqoRootView.focused(in: items, selected: streamIDs[3], open: open) == .post(stream[3]), "\(name): a mark's key lands on the lit post")
            // As it was: the page's own rows, which are none to be had.
            if name != "thread" {
                let walked = FediqoRootView.listIDs(
                    on: walk, pages: pages, found: [],
                    items: FediqoRootView.listItems(on: walk, pages: pages, stream: stream, latest: nil, in: session), in: session
                )
                #expect(walked == nil, "\(name): the step's own rows are none")
            }
            // Where it is drawn, the walk is the keys' as it stands.
            #expect(FediqoRootView.keyed(walk, drawn: true) == walk, "\(name), drawn")

            // With a search open under it, what the sources found stands first, over the posts.
            let found = ["found:person", "found:tag"]
            let rows = FediqoRootView.foundRows(on: keyed, searching: true, found: found)
            #expect(rows == found, "\(name): the found rows of the search drawn")
            #expect(FediqoRootView.listIDs(on: keyed, pages: pages, found: rows, items: items, in: session) == found + streamIDs, "\(name)")
            #expect(FediqoRootView.foundRows(on: walk, searching: true, found: found).isEmpty, "\(name), drawn: none, a page stands over them")
            #expect(FediqoRootView.foundRows(on: keyed, searching: false, found: found).isEmpty, "\(name): none with no pattern")
        }
    }

    @Test("A press on the stream drawn over a page that cannot be drawn lets go of the walk first, for every kind: Return opens a conversation over the stream, and Back gives the stream back with the lamp on the post — no step left under it; over a page drawn, nothing is let go of")
    func aPressOverAnUndrawnPageLetsGoOfTheWalk() throws {
        let person = ShellStep.person(Self.ada)
        for (step, undrawable) in Self.everyKind where undrawable {
            let step = try #require(step)
            let name = Self.kind(step)
            // Taken from somebody's page, so a step stands under the one that cannot be drawn.
            var walk = ShellWalk()
            _ = walk.walk(to: person, from: "row-0")
            _ = walk.walk(to: step, from: "figure")
            #expect(FediqoRootView.letsGoOfWalk(walk, drawn: false), "\(name)")
            #expect(!FediqoRootView.letsGoOfWalk(walk, drawn: true), "\(name), drawn")
            // Return on a post of the stream, as the root does it: let go, then one step.
            if FediqoRootView.letsGoOfWalk(walk, drawn: false) { walk.clear() }
            let opened = walk.walk(to: .thread("n2"), from: "n2")
            #expect(opened)
            #expect(walk.depth == 1 && walk.standing == .thread("n2"), "\(name): one step over the stream")
            let left = walk.back()
            #expect(left?.lamp == "n2" && walk.isEmpty, "\(name): Back is the stream, the lamp on the post")
        }
        #expect(!FediqoRootView.letsGoOfWalk(ShellWalk(), drawn: true) && !FediqoRootView.letsGoOfWalk(ShellWalk(), drawn: false))
    }

    /// The root's share of the pane, standing where it is handed, with the pages held.
    private struct Host: View {
        let session: ShellSession
        let pages: ShellPersonPages
        let standing: ShellStep?
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: TogetherDefaults())

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: standing, onOpenPerson: { _ in }, decks: $decks,
                playback: playback, onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                jumpToTop: 0, onBack: {}, ways: TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {}),
                search: ShellSearch(), people: pages
            )
            .environment(prefs)
        }
    }

    /// One pass of the hosted pane: laid out, and its run loop given a turn.
    private func turn(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    @Test("Hosted over the hashtags followed of a source no longer there: the stream is drawn under the timelines' head, and its posts are the rows the keys walk")
    func theStreamDrawnIsTheStreamWalked() async throws {
        let (session, pages) = streamSession()
        let step = ShellStep.followedTags(FollowedTags(host: Self.gone))
        try #require(!TimelinePane.drawn(step, of: pages, in: session).drawn)
        let probe = PaneProbe()
        let hosted = NSHostingView(rootView: Host(session: session, pages: pages, standing: step).environment(\.shellPaneProbe, probe))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        defer { hosted.removeFromSuperview() }
        await met("the head and the stream under it laid out") {
            turn(hosted)
            return probe.head != .zero && probe.under.height > 0
        }
        #expect(probe.under.minY >= probe.head.maxY - 1, "the stream stands under the head")
        var walk = ShellWalk()
        _ = walk.walk(to: step, from: nil)
        let keyed = FediqoRootView.keyed(walk, drawn: TimelinePane.drawn(step, of: pages, in: session).drawn)
        let stream = session.timelineItems(latest: nil)
        let items = FediqoRootView.listItems(on: keyed, pages: pages, stream: stream, latest: nil, in: session)
        #expect(FediqoRootView.listIDs(on: keyed, pages: pages, found: [], items: items, in: session) == stream.map(\.id))
    }

    // MARK: - `r` over an undrawn conversation over a search

    @Test("A conversation that cannot be drawn over an open search has no reload: the search's results are what is drawn, and they are this device's")
    func anUndrawnConversationOverASearchHasNoReload() {
        let step = ShellStep.thread("withdrawn")
        let open = FediqoRootView.drawnLayers([.thread, .search], standing: step, drawn: false)
        #expect(open == [.search])
        #expect(!FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: open, personAsked: false))
        // Drawn, it is the conversation's to read again.
        #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [.thread, .search], personAsked: false))
    }

    @Test("`/` and the head's search mark ask what is drawn: over every page that cannot be drawn they search the stream — and give an open search's field the keys back — and over a page drawn they do nothing; opening lets go of the step, so Esc then closes the search")
    func searchAsksWhatIsDrawn() throws {
        for (step, undrawable) in Self.everyKind where undrawable {
            let step = try #require(step)
            let name = Self.kind(step)
            for open in [[step.layer], [step.layer, .selection], [step.layer, .search], [step.layer, .search, .selection]] as [Set<DummyLayer>] {
                let undrawn = FediqoRootView.drawnLayers(open, standing: step, drawn: false)
                #expect(FediqoRootView.canSearch(place: .timeline, open: undrawn), "\(name), \(open): not drawn")
                #expect(!FediqoRootView.canSearch(place: .timeline, open: FediqoRootView.drawnLayers(open, standing: step, drawn: true)), "\(name), \(open): drawn")
            }
            // Opened: the step goes, so the search is what is outermost and Esc closes it.
            var walk = ShellWalk()
            _ = walk.walk(to: step, from: nil)
            #expect(FediqoRootView.letsGoOfWalk(walk, drawn: false), "\(name)")
            if FediqoRootView.letsGoOfWalk(walk, drawn: false) { walk.clear() }
            #expect(walk.isEmpty && DummyCommand.outermost(of: [.search]) == .search, "\(name)")
        }
    }

    // MARK: - About's lit block

    @Test("The lit block of an About tab — a hashtag's, somebody's — is told to a listener as the lit one, as every other lit row is, and the others are not")
    func theLitBlockSaysSo() {
        #expect(AboutBlockLit(lit: true).traits == .isSelected)
        #expect(AboutBlockLit(lit: false).traits == [])
    }

    // MARK: - The search field under a page

    @Test("The search field is drawn where the timelines' head is — over the stream, a link, and a page that cannot be drawn — and under no page drawn; never with no search open")
    func theSearchFieldIsTheStreams() {
        for (step, undrawable) in Self.everyKind {
            let name = Self.kind(step)
            #expect(TimelinePane.searchFieldDrawn(open: true, over: step, drawn: true) == TimelinePane.headDrawn(over: step, drawn: true), "\(name)")
            #expect(TimelinePane.searchFieldDrawn(open: true, over: step, drawn: true) == (step == nil || name == "link"), "\(name)")
            if undrawable { #expect(TimelinePane.searchFieldDrawn(open: true, over: step, drawn: false), "\(name), not drawn") }
            #expect(!TimelinePane.searchFieldDrawn(open: false, over: step, drawn: true) && !TimelinePane.searchFieldDrawn(open: false, over: step, drawn: false))
        }
    }

    @Test("The field takes the keys as the search opens, and, drawn again after a page, only if it had them when it went; closed, it takes them on no return")
    func theFieldComesBackAsItWent() {
        let search = ShellSearch()
        search.open(from: nil, over: [])
        #expect(search.appeared(), "opened: the field has the keys")
        #expect(!search.appeared(), "once")
        // Holding the keys as a page is opened in front of it.
        #expect(search.fieldFocus(true, during: nil))
        search.disappeared()
        #expect(!search.fieldFocused, "the keys are not a field's that is not drawn")
        #expect(search.appeared(), "back, with the keys")
        // Not holding them.
        _ = search.fieldFocus(false, during: nil)
        search.disappeared()
        #expect(!search.appeared(), "back, and the keys stay the list's")
        // Closed behind a page: nothing to come back to.
        #expect(search.fieldFocus(true, during: nil))
        _ = search.close()
        search.disappeared()
        #expect(!search.appeared())
    }

    @Test("A Return still waiting for the index when a page is opened in front is let go of: back from the page, nothing is lit over the lamp the walk handed back — where the field stays, the Return lights the first result once the index lands")
    func aWaitingReturnGoesWithTheField() async {
        let kept = ShellSearch()
        kept.open(from: nil, over: [])
        kept.text = "swift"
        kept.submit()
        await kept.indexed()
        #expect(kept.takeLitWhenIndexed(), "the field stayed: the Return lights its first result")

        let left = ShellSearch()
        left.open(from: nil, over: [])
        left.text = "swift"
        left.submit()
        left.disappeared()
        await left.indexed()
        #expect(!left.takeLitWhenIndexed(), "a page came in front: nothing waits to be lit")
        #expect(!left.appeared() && left.isOpen && left.pattern == "swift")
    }

    // MARK: - The keys guide

    /// The size a view takes when offered `width` and all the height it could want.
    private func size(of view: some View, offered width: CGFloat) -> CGSize {
        let host = NSHostingController(rootView: view.dynamicTypeSize(.large))
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @Test("The keys guide says what Tab does on every kind of page, in each language; the line wraps inside its tab at the guide's narrowest, and the tab still fits the plate at its full width")
    func theGuideSaysWhatTabDoesOnEachPage() throws {
        let line = try #require(DummyShortcut.all.first { $0.commands.contains(.nextTab) })
        let english = line.words(language: .english)
        for page in ["timelines", "Posts, Hashtags and Links on Trends", "somebody's page", "a hashtag", "what a search found", "A conversation", "a list of people", "the hashtags you follow", "does nothing"] {
            #expect(english.contains(page), "\(page)")
        }
        let taiwanese = line.words(language: .taiwanese)
        for page in ["時間軸", "「趨勢」的貼文、主題標籤和連結", "某人的頁面", "主題標籤", "搜尋找到的", "討論串", "一份名單", "你追蹤的主題標籤", "不做任何事"] {
            #expect(taiwanese.contains(page), "\(page)")
        }

        let plate = ShortcutGuide.Metrics.plate
        let inner = plate.width - 2 * ShellSpace.pad
        let floor = ShellLayout.floor - 2 * ShellSpace.room - 2 * ShellSpace.pad
        let heading = size(of: ShortcutGuide.Plate(tab: .constant(line.group), onClose: {}), offered: plate.width + 2 * ShellSpace.room).height
            - size(of: ShortcutGuide.Page(group: line.group), offered: inner).height
        for language in [DummyLanguage.english, .taiwanese] {
            let roomy = size(of: ShortcutGuide.Page(group: line.group, language: language), offered: inner)
            let tight = size(of: ShortcutGuide.Page(group: line.group, language: language), offered: floor)
            #expect(tight.width <= floor && tight.height > roomy.height, "\(language): \(tight) at the floor, \(roomy) with room")
            #expect(heading + roomy.height <= plate.height, "\(language): \(roomy.height) under \(heading)")
        }
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class TogetherDefaults: UserDefaults, @unchecked Sendable {
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
#endif
