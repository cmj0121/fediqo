import SwiftUI

/// The dummy keys, written down over the page, grouped by what they are for.
struct ShortcutGuide: View {
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ShellChrome.dim(colorScheme)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("shortcut.title"))
                    .font(.headline)
                Spacer()
                Button(L10n.t("shortcut.close"), action: onClose)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.t("shortcut.note"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    private var shortcutGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(DummyShortcutGroup.allCases) { group in
                GridRow {
                    Text(L10n.t(group.titleKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, group == DummyShortcutGroup.allCases.first ? 0 : 8)
                        .gridCellColumns(2)
                }
                ForEach(DummyShortcut.all.filter { $0.group == group }) { line in
                    GridRow {
                        keys(of: line)
                        Text(line.detail)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func keys(of line: DummyShortcut) -> some View {
        HStack(spacing: 4) {
            ForEach(line.keys, id: \.self) { cap in
                Text(cap)
                    .font(.body.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(ShellChrome.well(colorScheme))
                    )
            }
        }
        .fixedSize()
    }
}
