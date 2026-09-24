import SwiftUI

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
    let onSelect: (Tab) -> Void

    init(_ tabs: [Tab], selected: Tab, onSelect: @escaping (Tab) -> Void) {
        self.tabs = tabs
        self.selected = selected
        self.onSelect = onSelect
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.never)
        }
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
    }
}

extension DummyShortcutGroup: ShellTab {}
