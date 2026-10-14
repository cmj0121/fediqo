import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Where a hosted frame reports what it laid out: its head and what is in front, each by
/// where it stands in the page.
@MainActor
private final class FrameProbe {
    static let space = "OpenedPageTests.page"
    var head: CGRect?
    var front: CGRect?
    /// Whether what is in front was handed the head to lead with.
    var led: Bool?
}

/// F10's frame: the bar, the head, the strip and what is in front, as every opened page is
/// drawn — which of its parts stand where, what a figure is in each of its two forms, a tab
/// that is the step's own value turned in place, and whom Tab is asked of.
///
/// **No check here waits**: each hosts a view and lays it out, or asks a value.
@MainActor
@Suite("An opened page's frame", .watched)
struct OpenedPageTests {
    private static let ada = DummyPerson(handle: "@ada@m.example", host: "m.example")!
    private static let bob = DummyPerson(handle: "@bob@m.example", host: "m.example")!

    // MARK: - The frame

    private func hosted<Page: View>(
        _ page: Page, width: CGFloat = 390, layout: ShellLayout = .narrow, size: DynamicTypeSize = .large
    ) {
        let view = NSHostingView(
            rootView: page.frame(width: width, height: 700).coordinateSpace(.named(FrameProbe.space))
                .environment(\.shellLayout, layout).environment(\.dynamicTypeSize, size)
        )
        view.layoutSubtreeIfNeeded()
    }

    private func marked(_ write: @escaping (CGRect) -> Void) -> some View {
        Color.clear.frame(height: 40).background(GeometryReader { room in
            let _ = write(room.frame(in: .named(FrameProbe.space)))
            Color.clear
        })
    }

    /// The frame with `tabs`, its head and what is in front each a plate that says where it stands.
    private func frame<Tab: ShellTab>(_ tabs: [Tab], front: Tab, probe: FrameProbe) -> some View {
        OpenedPage(
            tabs: tabs, front: front, slide: PageSlide(),
            head: { marked { probe.head = $0 } },
            inFront: { lead in
                let _ = probe.led = lead != nil
                VStack(spacing: 0) {
                    lead
                    marked { probe.front = $0 }
                }
            }
        )
    }

    @Test("A strip of tabs is drawn only where there is more than one: with one tab or none, what is in front stands straight under the head")
    func noStripForOneTabOrNone() throws {
        #expect(!PageFrame.stripDrawn(SoleTab.tabs) && !PageFrame.stripDrawn([PersonTab.posts]))
        #expect(PageFrame.stripDrawn([PersonTab.about, .posts]))
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
            let none = FrameProbe(), one = FrameProbe(), two = FrameProbe()
            hosted(frame(SoleTab.tabs, front: .sole, probe: none), width: width, layout: layout)
            hosted(frame([PersonTab.posts], front: .posts, probe: one), width: width, layout: layout)
            hosted(frame([PersonTab.about, .posts], front: .posts, probe: two), width: width, layout: layout)
            let headEnds = try #require(none.head?.maxY)
            // Nothing between the head and what is in front.
            #expect(none.front?.minY == headEnds, "no tabs at \(width)")
            #expect(one.front?.minY == headEnds && one.head?.maxY == headEnds, "one tab at \(width)")
            // The strip and its rule stand between them.
            let under = try #require(two.front?.minY)
            #expect(two.head?.maxY == headEnds && under > headEnds + ShellSpace.snug * 2, "two tabs at \(width)")
            #expect(none.led == false && one.led == false && two.led == false)
        }
    }

    @Test("At an accessibility text size the head is handed to what is in front as its first rows, and the strip stays over it")
    func theHeadScrollsAtTheLargestText() throws {
        #expect(PageFrame.headScrolls(at: .accessibility1) && !PageFrame.headScrolls(at: .xxxLarge))
        let fixed = FrameProbe(), scrolls = FrameProbe(), sole = FrameProbe()
        hosted(frame([PersonTab.about, .posts], front: .about, probe: fixed), width: 320, size: .large)
        hosted(frame([PersonTab.about, .posts], front: .about, probe: scrolls), width: 320, size: .accessibility5)
        hosted(frame(SoleTab.tabs, front: .sole, probe: sole), width: 320, size: .accessibility5)
        #expect(fixed.led == false && scrolls.led == true && sole.led == true)
        // Fixed, the head is over the strip; scrolling, it is under it and leads the list.
        let fixedHead = try #require(fixed.head), fixedFront = try #require(fixed.front)
        #expect(fixedFront.minY > fixedHead.maxY)
        let scrolledHead = try #require(scrolls.head), soleHead = try #require(sole.head)
        #expect(scrolls.front?.minY == scrolledHead.maxY)
        #expect(scrolledHead.minY > soleHead.minY)
    }

    @Test("A page with no tabs is left by a sideways swipe: it is handed its one tab, in front, so the swipe begins on something and, let go, leaves")
    func aPageWithNoTabsIsLeftByASwipe() {
        let page = OpenedPage(slide: PageSlide(), head: { EmptyView() }, inFront: { _ in EmptyView() })
        #expect(page.tabs == SoleTab.tabs && page.tabs == [.sole] && !PageFrame.stripDrawn(page.tabs))
        let index = page.tabs.firstIndex(of: page.front)
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: page.tabs.count, leaves: true) == .beside)
        #expect(TimelineSwipe.leavesPage(from: index, leaves: true))
        // What the swipe began on is what is still in front when it is let go, so it is acted on.
        let began = TimelineSwipe.tabInFront(.beside, index: index)
        #expect(began != nil && TimelineSwipe.completes(startedOn: began, inFront: TimelineSwipe.tabInFront(.beside, index: index)))
        #expect(TimelineSwipe.tabStep(from: index, count: page.tabs.count, step: -1, leaves: true) == .leave)
        #expect(TimelineSwipe.tabStep(from: index, count: page.tabs.count, step: 1, leaves: true) == nil)
        // Handed no tab at all it would begin on nothing: nothing slides, and nothing is left.
        #expect(!TimelineSwipe.leavesPage(from: nil, leaves: true) && TimelineSwipe.tabStep(from: nil, count: 0, step: -1, leaves: true) == nil)
        #expect(!TimelineSwipe.completes(startedOn: TimelineSwipe.tabInFront(.beside, index: nil), inFront: nil))
        // A page with tabs: the tab beside, and from the first the way out.
        #expect(TimelineSwipe.tabStep(from: 1, count: 2, step: -1, leaves: true) == .tab(0))
        #expect(TimelineSwipe.tabStep(from: 0, count: 2, step: 1, leaves: true) == .tab(1))
        #expect(TimelineSwipe.tabStep(from: 0, count: 2, step: -1, leaves: true) == .leave)
        #expect(TimelineSwipe.tabStep(from: 0, count: 2, step: -1, leaves: false) == nil)
    }

    // MARK: - Somebody's page, through the frame

    /// The page as it was drawn before the frame was taken out of it (F9), part for part: the
    /// bar, the head and its rule, the strip and its rule, and the room left for the tab in front.
    private struct AsItWas: View {
        let head: PersonHeadSaid
        let tabs: [PersonTab]
        let front: PersonTab
        let canReload: Bool
        let probe: OpenedPageProbe

        @Environment(\.dynamicTypeSize) private var typeSize

        private func marked(_ part: OpenedPageProbe.Part) -> some View {
            GeometryReader { room in
                let _ = probe.frames[part] = room.frame(in: .named(OpenedPageProbe.space))
                Color.clear
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: ShellSpace.snug) {
                    ShellBackButton("person.back", action: {})
                    Spacer()
                    if canReload {
                        Button(action: {}) { Image(systemName: ReloadMark.reload.symbol).modifier(ShellGlyphBox()) }.buttonStyle(.plain)
                    }
                    ShellKeyHint("person.leaveHint")
                }
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
                .background(marked(.bar))
                ShellRule()
                if !typeSize.isAccessibilitySize {
                    PersonHead(head: head, front: tabs.count > 1 ? front : nil, onTab: { _ in }, onAct: { _ in })
                    ShellRule()
                }
                if tabs.count > 1 {
                    ShellTabs(tabs, selected: front, slide: PageSlide(), onSelect: { _ in })
                        .padding(.horizontal, ShellSpace.pad)
                        .padding(.vertical, ShellSpace.snug)
                        .background(marked(.strip))
                    ShellRule()
                }
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).background(marked(.front))
            }
            .coordinateSpace(.named(OpenedPageProbe.space))
        }
    }

    private func laidOut<Page: View>(
        _ page: Page, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize, probe: OpenedPageProbe
    ) -> [OpenedPageProbe.Part: CGRect] {
        let view = NSHostingView(
            rootView: page.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe)
        )
        view.layoutSubtreeIfNeeded()
        return probe.frames
    }

    @Test("Somebody's page drawn through the frame stands where it stood before: its bar, its strip and the room for the tab in front, at 720, 390 and 320, at the largest text, in light and in dark")
    func somebodysPageStandsWhereItStood() throws {
        let source = Source(host: "m.example", kind: .mastodon)
        let ada = Person(
            source: source, accountID: "42", handle: "@ada@m.example", name: "Ada", words: "<p>Counts things</p>",
            tally: Person.Tally(posts: 1_204_000, following: 310, followers: 2_811_000), locked: true
        )
        let said = PersonSaid(source: "m.example", reading: .said(ada))
        let author = try #require(DummyPerson(making: Note(
            id: "https://forum.example/bob/1", source: Source(host: "forum.example", kind: .discuz), author: "bob", handle: "", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        )))
        // Five tabs with each end in front and the mark in the bar; and a forum author's one tab.
        let pages: [(String, DummyPerson, PersonSaid?, PersonTab, Bool)] = [
            ("about in front", Self.ada, said, .about, true), ("posts in front", Self.ada, said, .posts, false),
            ("a forum's author", author, nil, .posts, false),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .large), (.narrow, 320, .accessibility5),
            ] {
                for (name, person, said, front, canReload) in pages {
                    let at = "\(name) at \(width), \(scheme), \(size)"
                    let page = HostedPersonPage.page(person, said: said, front: front, canReload: canReload)
                    let now = laidOut(page, width: width, layout: layout, scheme: scheme, size: size, probe: OpenedPageProbe())
                    let then = OpenedPageProbe()
                    let before = laidOut(
                        AsItWas(head: page.head, tabs: page.tabs, front: front, canReload: canReload, probe: then),
                        width: width, layout: layout, scheme: scheme, size: size, probe: then
                    )
                    // **One thing moved, and only there** (F10 §2): at the largest text the bar with
                    // its mark was a point wider than the narrowest page, and pushed the page that
                    // far off its edge. The bar now gives up its hint about a key where it does not
                    // fit, so it is as wide as the page and everything stands at the edge — each
                    // part as tall and as far down as it was.
                    let was = try #require(before[.bar])
                    if was.width > width {
                        #expect(layout == .narrow && PageFrame.headScrolls(at: size) && canReload && was.width < width + 1, "\(at): \(was)")
                        #expect(Set(now.keys) == Set(before.keys), "\(at)")
                        for (part, then) in before {
                            let stands = try #require(now[part])
                            #expect(stands.minX == 0 && stands.minY == then.minY && stands.height == then.height, "\(at): \(part) \(stands) was \(then)")
                            #expect(stands.width == width, "\(at): \(part) \(stands)")
                        }
                    } else {
                        #expect(now == before, "\(at): \(now) was \(before)")
                    }
                    let bar = try #require(now[.bar]), room = try #require(now[.front])
                    #expect(bar.minY == 0 && room.maxY == 700 && room.width == width, "\(at): \(bar), \(room)")
                    #expect(bar.minX == 0 && bar.width == width, "\(at): \(bar)")
                    #expect((now[.strip] != nil) == (page.tabs.count > 1), "\(at)")
                    if let strip = now[.strip] {
                        // The head stands between the bar and the strip — and at the largest text
                        // it does not: it is the first rows under the strip.
                        #expect(strip.maxY < room.minY && (strip.minY - bar.maxY > ShellSpace.pad) == !PageFrame.headScrolls(at: size), "\(at)")
                    } else {
                        #expect((room.minY - bar.maxY > ShellSpace.pad) == !PageFrame.headScrolls(at: size), "\(at)")
                    }
                }
            }
        }
    }

    // MARK: - A figure

    /// Where the screens' source is, from wherever the package stands.
    private static func sources() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    @Test("A figure that opens its tab is a press on a well; one that opens nothing is no press, stands on no well, is never lit, and says its sentence to a pointer and a listener")
    func aFigureInItsTwoForms() throws {
        // Lit is of a figure that opens its tab: one that opens nothing cannot be made lit.
        let plain = PageFigure(symbol: "person.2", figure: "2,811", spoken: "2,811 followers", opens: false, lit: true)
        #expect(!plain.opens && !plain.lit)
        #expect(plain == PageFigure(symbol: "person.2", figure: "2,811", spoken: "2,811 followers", opens: false))
        let front = PageFigure(symbol: "person.2", figure: "2,811", spoken: "2,811 followers", lit: true)
        #expect(front.opens && front.lit && !PageFigure(symbol: "person.2", figure: nil, spoken: "Followers").lit)
        // Both forms are called by the figure's sentence, to a pointer and to a listener.
        let text = try String(contentsOf: Self.sources().appending(path: "Shell/PageFigure.swift"), encoding: .utf8)
        #expect(text.components(separatedBy: ".accessibilityLabel(figure.spoken)").count == 3)
        #expect(text.contains(".help(figure.spoken)") && text.contains("ShellIconButton.hover(name: figure.spoken, help: PageFigure.hint())"))
        // The well is the press's: the figure that opens nothing is narrower by the well's two
        // sides and no shorter, at every size of text; and neither form is lost with no figure said.
        for size in [DynamicTypeSize.large, .accessibility5] {
            func sized(_ figure: PageFigure) -> CGSize {
                NSHostingView(rootView: PageFigureView(figure: figure).environment(\.dynamicTypeSize, size)).fittingSize
            }
            let press = sized(PageFigure(symbol: "person.2", figure: "2,811", spoken: "2,811 followers"))
            let bare = sized(plain)
            #expect(press.width - bare.width == ShellSpace.snug * 2 && press.height == bare.height, "\(size)")
            let alone = sized(PageFigure(symbol: "person.2", figure: nil, spoken: "Followers"))
            #expect(alone.width > ShellSpace.snug * 2 && alone.width < press.width && alone.height > 0, "\(size)")
        }
    }

    @Test("Somebody's figure is drawn lit only where it opens the tab in front, and says what it said: a hidden list's figure opens nothing and says why")
    func somebodysFigureAsThePageDrawsIt() {
        let en = DummyLanguage.english
        let posts = PersonSaid.Figure(tab: .posts, figure: "1,204", words: "1,204 posts")
        #expect(posts.drawn(front: .posts, language: en) == PageFigure(symbol: "text.bubble", figure: "1,204", spoken: "1,204 posts", opens: true, lit: true))
        #expect(!posts.drawn(front: .about).lit && !posts.drawn(front: nil).lit)
        let hidden = PersonSaid.Figure(tab: .followers, figure: "2,811", words: "2,811 followers", opens: false, hidden: true)
        let drawn = hidden.drawn(front: .followers, language: en)
        #expect(!drawn.opens && !drawn.lit && drawn.symbol == "person.2" && drawn.spoken == "2,811 followers. They hide this list.")
        #expect(PageFigure.hint(language: en) == "Shows it on this page" && PageFigure.hint(language: .taiwanese) == "在這一頁顯示")
    }

    // MARK: - The walk

    @Test("A tab that is the step's own value replaces the step in front: the walk is no deeper, and leaving gives back the row the page was opened from")
    func aTabTurnedInPlace() {
        var walk = ShellWalk()
        let onTheStream = walk.turned(to: .rising(.links))
        #expect(!onTheStream && walk.isEmpty)
        _ = walk.walk(to: .person(Self.ada), from: "row-1")
        _ = walk.walk(to: .rising(.tags), from: "row-7")
        let turned = walk.turned(to: .rising(.links))
        #expect(turned && walk.standing == .rising(.links) && walk.depth == 2)
        // The tab already in front is not turned to.
        let again = walk.turned(to: .rising(.links))
        #expect(!again && walk.depth == 2)
        let there = walk.turned(to: .rising(.tags)), back = walk.turned(to: .rising(.links))
        #expect(there && back && walk.depth == 2)
        // The step beneath is not turned to: the reader is never twice on one step.
        let beneath = walk.turned(to: .person(Self.ada))
        #expect(!beneath && walk.standing == .rising(.links) && walk.depth == 2)
        // Leaving never passes through the other tab, and the step under it is as it was left.
        let left = walk.back()
        #expect(left?.step == .rising(.links) && left?.lamp == "row-7")
        #expect(walk.standing == .person(Self.ada) && walk.depth == 1)
        let first = walk.back()
        #expect(first?.lamp == "row-1" && walk.isEmpty)
    }

    @Test("Tab is asked of the walk whatever step is in front: somebody's page answers with its own tabs, and a step with no answer yet leaves the key where it was")
    func tabIsAskedOfTheWalk() throws {
        var walk = ShellWalk()
        #expect(walk.tabKey == nil)
        _ = walk.walk(to: .person(Self.ada), from: nil)
        #expect(walk.tabKey == .person(Self.ada))
        // A conversation's page has no tabs: the key is taken there, and turns nothing.
        _ = walk.walk(to: .thread("post-1"), from: "post-1")
        #expect(walk.tabKey == .sole(.thread))
        _ = walk.walk(to: .person(Self.bob), from: "post-1")
        #expect(walk.tabKey == .person(Self.bob))
        let tag = try #require(PostTag("#swift"))
        // A hashtag's page answers for itself: its tabs where it has two, and taken where one.
        #expect(ShellStep.tag(tag).tabKey == .tag(tag))
        // What is rising answers with its tab, the step's own value (F10).
        #expect(ShellStep.rising(.links).tabKey == .rising(.links))
        // And so does what a search found (F10).
        let found = FoundAt(source: "m.example", words: "swift", gave: FoundWhich.allCases)
        #expect(ShellStep.found(found, .tags).tabKey == .found(found, .tags))
        // The hashtags followed have no tabs: the key is taken there, as on a conversation (F10).
        #expect(ShellStep.followedTags(FollowedTags(host: "m.example")).tabKey == .sole(.rising))
        // A page read out of a post is no page of its own here: it has no answer.
        #expect(ShellStep.link(URL(string: "https://example.org/")!).tabKey == nil)
        // The root asks the walk once, before any place's own tabs, and names no page there.
        let ui = try Self.sources()
        let root = try String(contentsOf: ui.appending(path: "FediqoRootView.swift"), encoding: .utf8)
        let asked = "private func rotatePlaceTab(by step: Int) -> Bool {\n        if place == .timeline, let key = walk.tabKey {\n            switch Self.stepTab(key, drawn: TimelinePane.drawn(walk.standing, of: people, in: session).drawn, open: openLayers) {\n            case .page: return rotateStepTab(key, by: step)\n            case .covered: return false\n            case .timelines: break\n            }\n        }\n        return switch place {"
        #expect(root.components(separatedBy: asked).count == 2)
        // The frame and the figure draw, and learn no kind of source.
        for file in ["OpenedPage.swift", "PageBar.swift", "PageFigure.swift"] {
            let text = try String(contentsOf: ui.appending(path: "Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.draws(text) && DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }
}
