import SwiftUI

/// One item, on a spine. The gutter carries the avatar and the lamp; everything the
/// reader actually reads lines up in the column beside it, decorator to marks.
struct DummyItemRow: View {
    let item: DummyItem
    @Binding var marks: DummyMarks
    var selected: Bool = false
    var onSelect: (() -> Void)?
    var onToast: (String) -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private enum Box {
        /// The spine. The same width on every row, so the column beside it never moves.
        static let gutter: CGFloat = 36
        static let thumb: CGFloat = 96
        static let vis: CGFloat = 16
        static let glyph: CGFloat = 17
        static let count: CGFloat = 20
        /// What a finger gets, whatever the glyph drawn inside it measures.
        static let touch: CGFloat = 32
        static let lamp: CGFloat = 2
        static let plate: CGFloat = 6
    }

    var body: some View {
        HStack(alignment: .top, spacing: ShellSpace.step) {
            avatar
            content
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) { lamp }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Where the reader is. Two points in the row's own margin, and no geometry of its
    /// own — walking the list with j and k must not move the list.
    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: Box.lamp)
        }
    }

    /// The row being read. Its marks come up one notch; nothing appears or disappears.
    private var reading: Bool { selected || hovering }

    private var content: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            decorator
            headline
            mainBox
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var decorator: some View {
        if item.answering != .nothing || item.boostedBy != nil {
            HStack(spacing: ShellSpace.snug) {
                if item.answering != .nothing { answered }
                if let who = item.boostedBy { boosted(by: who) }
            }
            .font(ShellType.mark)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
        }
    }

    private var answered: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "arrowshape.turn.up.left")
            switch item.answering {
            case .handle(let handle):
                Text(String(format: L10n.t("item.replyingTo"), handle))
            default:
                Text(L10n.t("item.isReply"))
            }
        }
    }

    private func boosted(by who: String) -> some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "arrow.2.squarepath")
            Text(String(format: L10n.t("item.boostedBy"), who))
        }
    }

    /// Wide, the name and what the post arrived with share a line. Narrow, the meta
    /// drops below rather than squeezing the name it belongs to into an ellipsis.
    private var headline: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                names
                Spacer(minLength: ShellSpace.snug)
                meta
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                names
                meta
            }
        }
    }

    private var names: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(item.author)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
            if let handle = item.handle {
                Text(handle)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
            }
        }
    }

    private var meta: some View {
        HStack(spacing: ShellSpace.snug) {
            sourcePills
            visibility
            postedAgo
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
            if item.hasAvatar {
                Image(systemName: "person.fill")
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
        }
        .frame(width: Box.gutter, height: Box.gutter)
    }

    private var postedAgo: some View {
        Text(item.postedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            .font(ShellType.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
            .help(exactPostedAt)
            .accessibilityLabel(exactPostedAt)
    }

    private var exactPostedAt: String {
        item.postedAt.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    private var visibility: some View {
        Group {
            if let audience = item.audience {
                Image(systemName: audience.symbolName)
                    .font(ShellType.meta.weight(.medium))
                    .foregroundStyle(ShellChrome.vis(audience, colorScheme))
                    .help(L10n.t("item.visibility.\(audience.rawValue)"))
                    .accessibilityLabel(L10n.t("item.visibility.\(audience.rawValue)"))
            }
        }
        .frame(width: Box.vis, height: Box.vis)
    }

    private var sourcePills: some View {
        let hosts = item.shownHosts
        return HStack(spacing: ShellSpace.tight) {
            if let first = hosts.first {
                pill(first)
            }
            if hosts.count > 1 {
                pill("+\(hosts.count - 1)")
                    .accessibilityLabel(L10n.t("item.sources"))
                    .help(hosts.joined(separator: "\n"))
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(ShellType.mark)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .padding(.horizontal, ShellSpace.tight)
            .padding(.vertical, ShellSpace.hair * 2)
            .background(
                Capsule(style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            )
    }

    /// What came attached sits beside the words, never under them, and against the
    /// right edge of the row. A picture below the text pushes the next post off the
    /// screen; out on the edge it is a column you can run your eye down.
    private var mainBox: some View {
        HStack(alignment: .top, spacing: ShellSpace.step) {
            words
            thumb
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if item.source.kind == .board, let board = item.board {
                Text(board)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            if let title = item.title {
                Text(title)
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.body)
                .font(ShellType.body)
                .foregroundStyle(
                    item.title == nil ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme)
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var thumb: some View {
        if item.hasThumb {
            RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
                .frame(width: Box.thumb, height: Box.thumb)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                }
        }
    }

    private var actions: some View {
        HStack(spacing: ShellSpace.room) {
            HStack(spacing: ShellSpace.snug) {
                counted("arrowshape.turn.up.left", count: item.counts.replies,
                        label: "item.act.reply", on: false) {
                    onToast(L10n.t("item.toast.reply"))
                }
                counted("arrow.2.squarepath", count: item.counts.reblogs,
                        label: "item.act.reblog", on: false) {
                    onToast(L10n.t("item.toast.reblog"))
                }
                counted(marks.favourited ? "star.fill" : "star",
                        count: item.counts.favourites,
                        label: "item.act.favourite", on: marks.favourited) {
                    marks.favourited.toggle()
                    onToast(L10n.t(marks.favourited ? "item.toast.favourite.on" : "item.toast.favourite.off"))
                }
            }
            HStack(spacing: ShellSpace.snug) {
                mark(marks.bookmarked ? "bookmark.fill" : "bookmark",
                     label: "item.act.bookmark", on: marks.bookmarked) {
                    marks.bookmarked.toggle()
                    onToast(L10n.t(marks.bookmarked ? "item.toast.bookmark.on" : "item.toast.bookmark.off"))
                }
                mark(marks.kept ? "archivebox.fill" : "archivebox",
                     label: "item.act.kept", on: marks.kept) {
                    marks.kept.toggle()
                    onToast(L10n.t(marks.kept ? "item.toast.kept.on" : "item.toast.kept.off"))
                }
                mark("ellipsis", label: "item.act.more", on: false) {
                    onToast(L10n.t("item.toast.more"))
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Nothing is not a reading. A count of zero is left off rather than drawn as a
    /// nought beside every glyph in the list.
    private func counted(_ symbol: String, count: Int?, label: String, on: Bool,
                         action: @escaping () -> Void) -> some View {
        let shown = (count ?? 0) > 0 ? count : nil
        return DummyMarkButton(symbol: symbol, count: shown, labelKey: label,
                               on: on, quiet: !reading, glyph: Box.glyph,
                               countWidth: Box.count, touch: Box.touch, action: action)
    }

    private func mark(_ symbol: String, label: String, on: Bool,
                      action: @escaping () -> Void) -> some View {
        DummyMarkButton(symbol: symbol, count: nil, labelKey: label,
                        on: on, quiet: !reading, glyph: Box.glyph,
                        countWidth: Box.count, touch: Box.touch, action: action)
    }
}

private struct DummyMarkButton: View {
    let symbol: String
    let count: Int?
    let labelKey: String
    let on: Bool
    /// True on every row but the one being read. Emphasis only — the control is always
    /// here, always the same size, and always reachable.
    let quiet: Bool
    let glyph: CGFloat
    let countWidth: CGFloat
    /// The smallest a press is allowed to be. The glyph stays the size it is drawn;
    /// what grows is the area a finger can land on.
    let touch: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShellSpace.hair * 2) {
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .medium))
                    .frame(width: glyph, height: glyph)
                if let count {
                    Text(String(count))
                        .font(ShellType.reading)
                        .frame(minWidth: countWidth, alignment: .leading)
                }
            }
            .frame(minWidth: touch, minHeight: touch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .animation(.easeInOut(duration: 0.15), value: quiet)
        .help(L10n.t(labelKey))
        .accessibilityLabel(L10n.t(labelKey))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var tint: Color {
        if on { return ShellChrome.filament(colorScheme) }
        return quiet ? ShellChrome.inkFaint(colorScheme) : ShellChrome.inkDim(colorScheme)
    }
}
