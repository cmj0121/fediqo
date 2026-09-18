import SwiftUI

/// The dummy keys, written down over the page, grouped by tab.
struct ShortcutGuide: View {
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: DummyShortcutGroup = .timeline

    var body: some View {
        ZStack {
            ShellGround(popUp: .shortcutGuide, dismiss: onClose)
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("shortcut.title"))
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer()
                Button(L10n.t("shortcut.close"), action: onClose)
                    .buttonStyle(.plain)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }

            Text(L10n.t("shortcut.note"))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            tabs

            ViewThatFits(in: .vertical) {
                shortcutGrid
                ScrollView {
                    shortcutGrid
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(20)
        .frame(maxWidth: 440, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ShellChrome.page(colorScheme))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: 1)
        )
        .padding(24)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
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
                        .font(ShellType.meta.weight(selected ? .semibold : .regular))
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

    private var shortcutGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(DummyShortcut.lines(in: tab)) { line in
                GridRow {
                    keys(of: line)
                    Text(line.detail)
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func keys(of line: DummyShortcut) -> some View {
        HStack(spacing: 4) {
            ForEach(line.keys, id: \.self) { cap in
                Text(cap)
                    .font(ShellType.keycap)
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
