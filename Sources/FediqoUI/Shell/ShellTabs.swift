import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What a page's tabs are made of: a name and the glyph it leads with.
///
/// A page's own purpose enum conforms — Preferences', Usage's, the keys guide's — so the tabs are
/// `ShellTabs(Purpose.allCases, selected: purpose) { … }` and nothing is copied.
protocol ShellTab: Hashable, Identifiable {
    var titleKey: String { get }
    var symbol: String { get }
}

/// A page's tabs (#232) — **rule 4 of #231, and rule 1 on every tab.** One pill per tab, each led
/// by its glyph; the one the page is on sits on the lamp's wash in the lamp's ink, the rest on the
/// milled well.
///
/// **The pills Usage, Preferences, the keys guide and the timeline drew one copy each of**, with
/// a glyph in front. The first three are this; the timeline's are `ShellTabPill`s in a row of its
/// own, for the reasons that type gives. Selection is not held here: the page's own state is, and a press hands the
/// tab back through `onSelect`. That is what keeps the keyboard as it is — Tab and ⇧Tab rotate
/// the same state (`ShellSession.rotatePreferencesTab` and its siblings), so the pills follow a
/// key and a press alike without knowing which it was.
///
/// Scrolled sideways only where the row does not fit — a phone at the largest type — rather than
/// cut; a row that fits is laid out as it is and measures as it is.
struct ShellTabs<Tab: ShellTab>: View {
    let tabs: [Tab]
    let selected: Tab
    /// How far a swipe has the page under the tabs, and whether the list of them is up: the
    /// page's own, where it is swiped; nothing, and the tabs keep one of their own.
    var slide: PageSlide?
    let onSelect: (Tab) -> Void

    init(_ tabs: [Tab], selected: Tab, slide: PageSlide? = nil, onSelect: @escaping (Tab) -> Void) {
        self.tabs = tabs
        self.selected = selected
        self.slide = slide
        self.onSelect = onSelect
    }

    @Environment(\.shellLayout) private var shellLayout
    @Environment(\.shellTabsSlide) private var handed
    @State private var own = PageSlide()

    /// Whether the tabs are one head that names the one in front, with a dot for each (#305):
    /// on a narrow page, where there is more than one. A wide page writes them all in a row.
    static func headed(_ layout: ShellLayout, count: Int) -> Bool {
        layout == .narrow && PageHead<EmptyView>.drawn(count: count)
    }

    /// What the name lists: every tab by name and glyph, the one in front marked.
    static func listed(_ tabs: [Tab], selected: Tab, language: DummyLanguage? = nil) -> [PageListEntry] {
        tabs.map { tab in
            PageListEntry(
                id: String(describing: tab.id), name: L10n.t(tab.titleKey, language: language),
                symbol: tab.symbol, current: tab == selected
            )
        }
    }

    @ViewBuilder
    private var head: some View {
        @Bindable var slide = slide ?? handed ?? own
        let index = tabs.firstIndex(of: selected)
        PageHead(
            front: PageHead<EmptyView>.Front(
                id: String(describing: selected.id), name: L10n.t(selected.titleKey), symbol: selected.symbol,
                index: index, count: tabs.count
            ),
            hint: L10n.t("tabs.list.hint"), positionKey: "tabs.position", slide: slide,
            onPress: { slide.listShown = true },
            marks: { EmptyView() }
        )
        .sheet(isPresented: $slide.listShown) {
            PageListSheet(
                title: L10n.t("tabs.list.title"), entries: Self.listed(tabs, selected: selected),
                choose: { chosen in
                    if let tab = tabs.first(where: { String(describing: $0.id) == chosen.id }) { onSelect(tab) }
                }
            ) { EmptyView() }
        }
        .onDisappear { if slide.listShown { slide.listShown = false } }
        .modifier(TabsScroll(step: { step in
            guard let index, let to = TimelineSwipe.target(from: index, count: tabs.count, step: step) else { return nil }
            onSelect(tabs[to])
            return TimelineSwipe.announcement(name: L10n.t(tabs[to].titleKey), position: to, count: tabs.count, key: "tabs.position")
        }))
    }

    /// Which ends of a scrolled row have more beyond them. See `ShellTabsMore`.
    @State private var more = ShellTabsMore(leading: false, trailing: true)

    var body: some View {
        if Self.headed(shellLayout, count: tabs.count) {
            head.headOfPage()
        } else {
            strip
        }
    }

    private var strip: some View {
        ViewThatFits(in: .horizontal) {
            row
            // **A row that scrolls says so** (#302): the end with more beyond it fades out, so a
            // pill cut by the edge of the page reads as one that goes on rather than one that
            // was cut. An end with nothing beyond it is drawn whole.
            ScrollView(.horizontal) { row.notToTop() }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: ShellTabsMore.self) { geometry in
                    ShellTabsMore(
                        offset: geometry.contentOffset.x, across: geometry.containerSize.width,
                        content: geometry.contentSize.width
                    )
                } action: { _, now in
                    more = now
                }
                .mask(ShellTabsFade(more: more))
        }
        // The row stays where it is and shows the change: a swipe begins under it (#305).
        .headOfPage()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private var row: some View {
        HStack(spacing: ShellSpace.tight) {
            ForEach(tabs) { tab in
                ShellTabPill(L10n.t(tab.titleKey), symbol: tab.symbol, selected: tab == selected) { onSelect(tab) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tab: its glyph, its name, and a mark after it where the tab has something to own up to —
/// in a capsule. The glyph fills when the tab is the page's, the way the rail's glyphs do.
///
/// **Public to the file's callers, not only to `ShellTabs`**, because the timeline's tabs are the
/// reader's own: named by them rather than by a key, reordered, pressed twice to be edited. That
/// row builds itself from these pills and adds its own gestures and named actions on the outside
/// — a modifier after the pill reaches the button inside it — so there is one pill and not two.
struct ShellTabPill: View {
    let title: String
    let symbol: String
    let selected: Bool
    /// A glyph after the name, quiet and unspoken: the hint says it in words.
    var accessory: String?
    /// What VoiceOver adds after the name, where the tab has more to say than its name.
    var hint: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String, symbol: String, selected: Bool, accessory: String? = nil, hint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.accessory = accessory
        self.hint = hint
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(traits)
    }

    /// Selected is said as well as drawn.
    var traits: AccessibilityTraits { selected ? .isSelected : [] }

    private var face: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: symbol)
                .symbolVariant(selected ? .fill : .none)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .fixedSize()
            if let accessory {
                Image(systemName: accessory)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .shellFont(.meta, weight: selected ? .semibold : .regular)
        .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
        .padding(.horizontal, ShellSpace.snug)
        .padding(.vertical, ShellSpace.tight)
        .background(
            Capsule(style: .continuous)
                .fill(selected ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
        )
        .contentShape(Capsule(style: .continuous))
        // The tab chosen is shown changing, and does not snap, however it was chosen (#305).
        .animation(.easeInOut(duration: TimelineDots.moves), value: selected)
    }
}

extension DummyShortcutGroup: ShellTab {}

/// Which ends of a row scrolled sideways have more beyond them.
struct ShellTabsMore: Hashable, Sendable {
    var leading: Bool
    var trailing: Bool

    init(leading: Bool, trailing: Bool) {
        self.leading = leading
        self.trailing = trailing
    }

    /// Read off where the row stands: `offset` in from its start, in a page `across` wide, over
    /// a row `content` wide. A point of slack either way, so a row at rest at an end is at it.
    init(offset: CGFloat, across: CGFloat, content: CGFloat) {
        leading = offset > 1
        trailing = offset + across < content - 1
    }
}

/// What a scrolled row is drawn through: whole in the middle, fading out over `reach` at each
/// end that has more beyond it.
private struct ShellTabsFade: View {
    let more: ShellTabsMore
    private let reach: CGFloat = ShellSpace.room

    var body: some View {
        HStack(spacing: 0) {
            edge(more.leading, from: .leading)
            Color.black
            edge(more.trailing, from: .trailing)
        }
    }

    private func edge(_ fades: Bool, from end: UnitPoint) -> some View {
        LinearGradient(
            colors: [fades ? .clear : .black, .black],
            startPoint: end, endPoint: end == .leading ? .trailing : .leading
        )
        .frame(width: reach)
    }
}

/// VoiceOver's scroll on the tabs' head goes to the tab beside, and says which it is and where
/// it stands — the way without a gesture, as on the timeline. Nothing on a Mac.
private struct TabsScroll: ViewModifier {
    /// One on or back: says what was arrived at, or nothing at an end.
    let step: (Int) -> String?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.accessibilityScrollAction { edge in
            let way = ScrollsToNeighbour.step(toward: edge)
            guard way != 0, let said = step(way) else { return }
            UIAccessibility.post(notification: .pageScrolled, argument: said)
        }
        #else
        content
        #endif
    }
}

/// A list under a page's tabs, on a narrow page: **the tabs are one head over the list, and not
/// a row in it** (#305). The head stays where it is, the whole list under it follows a sideways
/// swipe as one, and scrolled up the list goes under the head and is not read through it.
///
/// The head starts where the timeline's does, a page's edge in, so the name is in one place on
/// every page. Nothing where the page is wide: its tabs are a row in the list, as they were.
struct TabsOverForm<Tabs: View>: ViewModifier {
    let headed: Bool
    let slide: PageSlide
    @ViewBuilder var tabs: Tabs

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .modifier(ProbedPane(part: .under))
            .modifier(Slid(slide: slide, applies: headed ? nil : false))
            .safeAreaInset(edge: .top, spacing: 0) {
                if headed {
                    tabs
                        .padding(.horizontal, Self.inset)
                        .padding(.top, ShellSpace.step)
                        .padding(.bottom, ShellSpace.snug)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // What the page is drawn on, so the list goes under the head and
                        // is not read through it.
                        .background(ShellChrome.page(colorScheme))
                        .modifier(ProbedPane(part: .head))
                }
            }
    }

    /// How far in the head starts from the list's own edge: the page's margin, less the room
    /// the list already stands in from the page.
    static var inset: CGFloat { ShellSpace.pad - ShellSpace.snug }
}
