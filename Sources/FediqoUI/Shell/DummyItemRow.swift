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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A phone held upright, where the picture beside the words leaves the words a
    /// column four characters wide. Everywhere else the row keeps its full width.
    private var narrow: Bool { sizeClass == .compact }
    #else
    private var narrow: Bool { false }
    #endif

    /// The row's fittings, in points at the standard type size and scaled from there.
    /// They used to be fixed: the words grew with the reader's preference and the
    /// avatar, the thumbnail and every mark stayed exactly where they were, so at the
    /// largest size a row was big text wrapped around small furniture.
    ///
    /// The spine is the same width on every row, so the column beside it never moves.
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var thumbSide: CGFloat = 96
    @ScaledMetric(relativeTo: .caption) private var vis: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var glyph: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var countBox: CGFloat = 20
    /// What a finger gets, whatever the glyph drawn inside it measures.
    @ScaledMetric(relativeTo: .caption) private var touch: CGFloat = 32

    private enum Box {
        /// The lamp is a lamp at every type size, and a corner is a corner.
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
            // The row itself is an accessibility container, and a container is not an
            // element — a trait put on it is announced to nobody. The headline is the
            // row's identity, so it is the element that carries the selection.
            headline
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// The name is what the row is; the handle is how to find it again. When there is
    /// not room for both, the handle loses its middle rather than the row losing its
    /// edge — an author clipped by the screen is an author nobody can read at all.
    private var names: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(item.author)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .layoutPriority(1)
            if let handle = item.handle {
                Text(handle)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nothing in here is pinned to a width any more, but nothing may overflow
    /// either: the host gives way first and truncates, and the age — the one reading
    /// that is useless half-drawn — keeps its own size and its place at the end.
    private var meta: some View {
        HStack(spacing: ShellSpace.snug) {
            sourcePills
                .layoutPriority(0)
            visibility
            postedAgo
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
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
        .frame(width: gutter, height: gutter)
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
        .frame(width: vis, height: vis)
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
    @ViewBuilder
    private var mainBox: some View {
        if narrow {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                words
                thumb
            }
        } else {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                words
                thumb
            }
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
                .frame(width: thumbSide, height: thumbSide)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                }
        }
    }

    /// Every mark is a press, and a press has a floor it cannot be squeezed below. On
    /// a narrow row the two groups take a line each rather than the last of them
    /// sliding off the edge.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ShellSpace.room) { passOn; keep; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: ShellSpace.tight) { passOn; keep }
        }
    }

    private var passOn: some View {
        HStack(spacing: ShellSpace.snug) {
            counted("arrowshape.turn.up.left", count: item.counts.replies,
                    label: "item.act.reply", on: false) {
                onToast(L10n.t("item.toast.reply"))
            }
            counted("arrow.2.squarepath", count: item.counts.reblogs,
                    label: "item.act.reblog", on: false) {
                onToast(L10n.t("item.toast.reblog"))
            }
            mark("quote.bubble", label: "item.act.quote", on: false) {
                onToast(L10n.t("item.toast.quote"))
            }
            counted(marks.favourited ? "star.fill" : "star",
                    count: item.counts.favourites,
                    label: "item.act.favourite", on: marks.favourited) {
                marks.favourited.toggle()
                onToast(L10n.t(marks.favourited ? "item.toast.favourite.on" : "item.toast.favourite.off"))
            }
        }
    }

    private var keep: some View {
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
    }

    /// Nothing is not a reading. A count of zero is left off rather than drawn as a
    /// nought beside every glyph in the list.
    private func counted(_ symbol: String, count: Int?, label: String, on: Bool,
                         action: @escaping () -> Void) -> some View {
        let shown = (count ?? 0) > 0 ? count : nil
        return DummyMarkButton(symbol: symbol, count: shown, labelKey: label,
                               on: on, quiet: !reading, glyph: glyph,
                               countWidth: countBox, touch: touch, action: action)
    }

    private func mark(_ symbol: String, label: String, on: Bool,
                      action: @escaping () -> Void) -> some View {
        DummyMarkButton(symbol: symbol, count: nil, labelKey: label,
                        on: on, quiet: !reading, glyph: glyph,
                        countWidth: countBox, touch: touch, action: action)
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
