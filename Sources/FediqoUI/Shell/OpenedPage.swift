import SwiftUI

/// The one tab of a page that has none: what `OpenedPage` is handed where there is nothing to
/// turn. It is never drawn — a page with one tab has no strip.
enum SoleTab: String, ShellTab, Sendable {
    case sole

    /// What such a page has: the one, in front. **One and not none**, so a sideways swipe
    /// begins on something — a swipe that began on nothing is never acted on
    /// (`TimelineSwipe.completes`) — and, being on the first, leaves the page.
    static let tabs: [SoleTab] = [.sole]

    var id: String { rawValue }
    var titleKey: String { "" }
    var symbol: String { "" }
}

/// What the frame of an opened page presses: each answered by whoever holds the walk.
struct OpenedPageActs<Tab: ShellTab> {
    var onBack: () -> Void = {}
    /// A tab's pill pressed, or swiped to: that tab, brought in front.
    var onTab: (Tab) -> Void = { _ in }
    /// The bar's mark: the page, asked again.
    var onReload: () -> Void = {}
    /// The same, pulled for: it returns when the answers have landed.
    var onPull: () async -> Void = {}
    /// What stops the asking the reader pressed for, while one is running: the bar's mark is
    /// then Stop. Nothing on a page with nothing to stop.
    var onStop: (() -> Void)?
}

/// Where a hosted frame laid its parts out, in the page's own space.
@MainActor
final class OpenedPageProbe {
    enum Part: Hashable {
        case bar, strip, front
    }

    static let space = "OpenedPage.parts"
    var frames: [Part: CGRect] = [:]
}

extension EnvironmentValues {
    /// Where a hosted frame reports what it laid out. Nothing in the app.
    @Entry var openedPageProbe: OpenedPageProbe? = nil
}

/// Reports where one part of the frame was laid out to a probe, where one is handed in; draws
/// nothing either way.
private struct PageProbed: ViewModifier {
    let part: OpenedPageProbe.Part
    let probe: OpenedPageProbe?

    init(_ part: OpenedPageProbe.Part, probe: OpenedPageProbe?) {
        self.part = part
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = probe.frames[part] = room.frame(in: .named(OpenedPageProbe.space))
                Color.clear
            })
        } else {
            content
        }
    }
}

/// What every opened page measures itself by, whichever tabs it has.
enum PageFrame {
    /// Whether the head scrolls away with what is in front, at `size`.
    static func headScrolls(at size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    /// Whether the strip of tabs is drawn: only where there is more than one.
    static func stripDrawn<Tab>(_ tabs: [Tab]) -> Bool { tabs.count > 1 }

    /// The lamp a tab is handed back, where it is still on one of the rows that tab walks —
    /// and no lamp where it is not.
    static func lamp(_ kept: String?, among walked: [String]) -> String? {
        kept.flatMap { walked.contains($0) ? $0 : nil }
    }

    /// What Tab or ⇧Tab does on a page with `tabs` and `front` in front, `step` on or back —
    /// **the one place it is decided, for every page that has tabs.** Round the ring where
    /// there are two or more; taken, turning nothing, where there is one, so the timelines are
    /// never turned from under the page; and nothing at all while the page is `covered`.
    static func keyed<Tab: Equatable>(_ tabs: [Tab], front: Tab, by step: Int, covered: Bool) -> PageKeyed<Tab> {
        if covered { return .unheard }
        guard tabs.count > 1 else { return .taken }
        return .turn(DummyCommand.advanced(tabs, from: front, by: step))
    }
}

/// What Tab or ⇧Tab does on an opened page (`PageFrame.keyed`).
enum PageKeyed<Tab: Equatable>: Equatable {
    /// That tab is brought in front.
    case turn(Tab)
    /// The key is the page's, and turns nothing: the page has one tab.
    case taken
    /// Something is drawn over the page: the key is not the page's at all.
    case unheard
}

extension PageKeyed: Sendable where Tab: Sendable {}

/// A page opened over the stream (F10): the frame every one of them stands in — a way back,
/// the page's own head, its tabs where it has more than one, and what is in front — the whole
/// height of the pane, with no timeline's names over it.
///
///     ‹ Back   title, where the page has no head       [marks] [↻]   Esc or q
///     ─────────────────────────────────────────────────────────────────────────
///     head — the page's own, with the page's line under it where it has one
///     ─────────────────────────────────────────────────────────────────────────
///     (tab)  (tab)                                    only where two or more
///     ─────────────────────────────────────────────────────────────────────────
///     what is in front
///
/// **It is handed everything it draws and asks nothing**: which tabs there are and which is in
/// front are decided where the source is asked, and the head and what is in front are the
/// page's own, handed in as they are. **A page handed one tab draws no strip.**
///
/// **At an accessibility text size the head is the first rows of what is in front**, and
/// scrolls away with it: fixed, it would fill a small screen. The bar and the tabs stay. What
/// is in front is handed the head to lead with there, and nothing everywhere else.
struct OpenedPage<Tab: ShellTab, Head: View, Front: View>: View {
    let tabs: [Tab]
    let front: Tab
    /// How far a sideways swipe has slid what is under the tabs.
    let slide: PageSlide
    /// What the page is, said in the bar: only where the page has no head that says it.
    var title: String?
    /// The page's own marks in the bar, before the one that asks again.
    var marks: [PageMark] = []
    /// What the bar's mark is called — whom it asks again — or nothing where there is nobody
    /// to ask: then the mark is absent, and a pull asks nothing.
    var reload: String?
    var acts = OpenedPageActs<Tab>()
    @ViewBuilder var head: () -> Head
    /// What is in front, with what it is handed as the first rows of its list.
    @ViewBuilder var inFront: (Head?) -> Front

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openedPageProbe) private var probe

    var body: some View {
        let scrolls = PageFrame.headScrolls(at: typeSize)
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            if !scrolls { head() }
            if PageFrame.stripDrawn(tabs) {
                strip
                ShellRule()
            }
            inFront(scrolls ? head() : nil)
                // One list per tab, so a tab brought in front is drawn afresh at its own lamp.
                .id(front)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(PageProbed(.front, probe: probe))
                .modifier(Slid(slide: slide))
                .modifier(PullsToReload(offered: { reload != nil }, reload: {}, settled: acts.onPull))
        }
        .coordinateSpace(.named(OpenedPageProbe.space))
        // A sideways swipe goes to the tab beside; on the first — the only one, on a page
        // with no strip — it leaves the page.
        .modifier(SwipesTabs(slide: slide, tabs: tabs, selected: front, leave: acts.onBack, select: acts.onTab))
    }

    /// The way back and the way out of the page, on one line for every opened page — so a
    /// reader who has learnt to leave one has learnt to leave them all — with the page's title
    /// and marks where it has them and, where there is anybody to ask, the mark that asks
    /// them again (`PageBar`).
    private var bar: some View {
        PageBar(title: title, marks: marks, reload: reload, onBack: acts.onBack, onReload: acts.onReload, onStop: acts.onStop)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .modifier(PageProbed(.bar, probe: probe))
    }

    /// The page's tabs, as every page with tabs draws them (`ShellTabs`): a pill each on a
    /// wide page, and on a narrow one the tab in front by name with a dot for each.
    private var strip: some View {
        ShellTabs(tabs, selected: front, slide: slide, onSelect: acts.onTab)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .modifier(PageProbed(.strip, probe: probe))
    }
}

extension OpenedPage where Tab == SoleTab {
    /// A page with no tabs: its head over the one thing it shows.
    init(
        slide: PageSlide, title: String? = nil, marks: [PageMark] = [], reload: String? = nil, onBack: @escaping () -> Void = {}, onReload: @escaping () -> Void = {},
        onPull: @escaping () async -> Void = {}, onStop: (() -> Void)? = nil, @ViewBuilder head: @escaping () -> Head,
        @ViewBuilder inFront: @escaping (Head?) -> Front
    ) {
        self.init(
            tabs: SoleTab.tabs, front: .sole, slide: slide, title: title, marks: marks, reload: reload,
            acts: OpenedPageActs(onBack: onBack, onReload: onReload, onPull: onPull, onStop: onStop), head: head, inFront: inFront
        )
    }
}
