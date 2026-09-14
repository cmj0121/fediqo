import SwiftUI

/// The dummy conversation under one item. Esc or q returns to the list.
struct DummyThreadPane: View {
    let root: DummyItem
    var marks: (DummyItem) -> Binding<DummyMarks>
    var onToast: (String) -> Void
    var onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label(L10n.t("thread.back"), systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                Text(L10n.t("thread.title"))
                    .font(.headline)
                Spacer()
                Text(L10n.t("thread.leaveHint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DummyItemRow(item: root, marks: marks(root), onToast: onToast)
                    Rectangle()
                        .fill(ShellChrome.hairline(colorScheme))
                        .frame(height: 1)
                    Text(L10n.t("thread.replies"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    ForEach(root.dummyReplies()) { reply in
                        DummyItemRow(item: reply, marks: marks(reply), onToast: onToast)
                            .padding(.leading, 24)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: 1)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
