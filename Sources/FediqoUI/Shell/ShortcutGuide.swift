import SwiftUI

/// The dummy keys, written down over the page.
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

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(DummyShortcut.all) { line in
                    GridRow {
                        keys(of: line)
                        Text(line.detail)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 420, alignment: .leading)
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
