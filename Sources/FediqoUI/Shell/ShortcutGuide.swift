import SwiftUI

/// The dummy keys, written down over the page, one tab per purpose (#152).
struct ShortcutGuide: View {
    @Binding var tab: DummyShortcutGroup
    var onClose: () -> Void

    enum Metrics {
        /// The plate at its widest, and the height its tallest tab is held to (#152).
        ///
        /// **The width is a ceiling and the height is a budget.** The plate is as wide as this
        /// wherever the window leaves `ShellSpace.room` on both sides of it; narrower than that —
        /// down to `ShellLayout.floor` since #110 — it gives up width rather than its edges. Its
        /// height is its own content's, and `ShortcutGuideHostedTests` measures that every tab
        /// fits inside this at the standard type size, so none of them scrolls. Where a narrow
        /// window or a larger type size makes a tab longer than the window, the page scrolls
        /// instead of being cut off.
        ///
        /// 440 since #124 gave Read a ninth line, `t`; the width is unchanged.
        static let plate = CGSize(width: 600, height: 440)
        /// Between the heading's parts and the page below them.
        static let gap: CGFloat = 12
    }

    var body: some View {
        ZStack {
            ShellGround(popUp: .shortcutGuide, dismiss: onClose)
            Plate(tab: $tab, onClose: onClose)
                .padding(ShellSpace.room)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    /// The plate itself, without the ground behind it or the room around it: what is measured.
    struct Plate: View {
        @Binding var tab: DummyShortcutGroup
        var onClose: () -> Void
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HStack {
                    Text(L10n.t("shortcut.title"))
                        .shellFont(.pane)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                    Spacer()
                    Button(L10n.t("shortcut.close"), action: onClose)
                        .buttonStyle(.plain)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }

                Text(L10n.t("shortcut.note"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                tabs

                ViewThatFits(in: .vertical) {
                    pages
                    ScrollView {
                        pages
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(ShellSpace.pad)
            .frame(maxWidth: Metrics.plate.width, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ShellChrome.page(colorScheme))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: 1)
            )
        }

        /// The same pills the timeline uses for All and Trends: one selected, the rest a well.
        private var tabs: some View {
            HStack(spacing: ShellSpace.tight) {
                ForEach(DummyShortcutGroup.allCases) { group in
                    let selected = group == tab
                    Button {
                        tab = group
                    } label: {
                        Text(L10n.t(group.titleKey))
                            .lineLimit(1)
                            .fixedSize()
                            .shellFont(.meta, weight: selected ? .semibold : .regular)
                            .foregroundStyle(
                                selected
                                    ? ShellChrome.selectInk(colorScheme)
                                    : ShellChrome.inkDim(colorScheme)
                            )
                            .padding(.horizontal, ShellSpace.snug)
                            .padding(.vertical, ShellSpace.tight)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        selected
                                            ? ShellChrome.selectFill(colorScheme)
                                            : ShellChrome.well(colorScheme)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }

        /// Every tab is laid out, and only the current one is drawn. The plate then keeps the
        /// tallest tab's height instead of jumping when Tab rotates the pills.
        private var pages: some View {
            ZStack(alignment: .topLeading) {
                ForEach(DummyShortcutGroup.allCases) { group in
                    Page(group: group)
                        .opacity(group == tab ? 1 : 0)
                        .accessibilityHidden(group != tab)
                }
            }
        }
    }

    /// One tab's lines: its keys, and what each does.
    struct Page: View {
        let group: DummyShortcutGroup
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(DummyShortcut.lines(in: group)) { line in
                    GridRow {
                        keys(of: line)
                        Text(line.detail)
                            .shellFont(.body)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }

        private func keys(of line: DummyShortcut) -> some View {
            HStack(spacing: 4) {
                ForEach(line.keys, id: \.self) { cap in
                    Text(cap)
                        .shellFont(.keycap)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .padding(.horizontal, ShellSpace.snug)
                        .padding(.vertical, ShellSpace.tight)
                        .background(
                            Capsule(style: .continuous)
                                .fill(ShellChrome.well(colorScheme))
                        )
                }
            }
            .fixedSize()
        }
    }
}
