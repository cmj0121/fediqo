import SwiftUI

/// The conversation around one item: the way up, the post, then answers related-on.
struct DummyThreadPane: View {
    let root: DummyItem
    @Binding var selectedID: String?
    var marks: (DummyItem) -> Binding<DummyMarks>
    @Binding var decks: ShellDecks
    var jumpToTop: Int
    var onToast: (String) -> Void
    var onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let step: CGFloat = 16
    private let deepest = 4

    private var conversation: DummyConversation { root.dummyConversation() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ShellSpace.snug) {
                Button(action: onBack) {
                    Label(L10n.t("thread.back"), systemImage: "chevron.left")
                        .font(ShellType.meta.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                Text(L10n.t("thread.title"))
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer()
                Text(L10n.t("thread.leaveHint"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(conversation.ancestors) { above in
                            threaded(above, dimmed: true)
                        }
                        threaded(conversation.post, dimmed: false)
                        ForEach(conversation.descendants, id: \.item.id) { entry in
                            threaded(entry.item, dimmed: false)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: jumpToTop) { _, _ in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(conversation.post.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func threaded(_ item: DummyItem, dimmed: Bool) -> some View {
        let depth = conversation.depth(of: item.id)
        return DummyItemRow(
            item: item,
            marks: marks(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            onSelect: { selectedID = item.id },
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onToast: onToast
        )
        .opacity(dimmed ? 0.85 : 1)
        .padding(.leading, indent(depth))
        .overlay(alignment: .leading) { rail(depth) }
        .id(item.id)
    }

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, deepest)) * step
    }

    @ViewBuilder
    private func rail(_ depth: Int) -> some View {
        if depth > 0 {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: ShellSpace.hair)
                .padding(.leading, indent(depth) - ShellSpace.snug)
                .padding(.vertical, 6)
        }
    }
}
