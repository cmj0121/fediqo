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
/// a glyph in front. Selection is not held here: the page's own state is, and a press hands the
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
                ShellTabPill(tab: tab, selected: tab == selected) { onSelect(tab) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tab: its glyph, then its name, in a capsule.
struct ShellTabPill<Tab: ShellTab>: View {
    let tab: Tab
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShellSpace.tight) {
                Image(systemName: tab.symbol)
                    .accessibilityHidden(true)
                Text(L10n.t(tab.titleKey))
                    .lineLimit(1)
                    .fixedSize()
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
        .buttonStyle(.plain)
        .help(L10n.t(tab.titleKey))
        .accessibilityLabel(L10n.t(tab.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
