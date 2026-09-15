import SwiftUI

/// One item, in four bands of a fixed shape: what happened to it, who wrote it and
/// what it arrived with, the words and the attachment, and what can be done to it.
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
    @ScaledMetric(relativeTo: .body) private var avatarSide: CGFloat = 36
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

    /// Four bands, and every row has all four whether or not it has anything to put
    /// in them:
    ///
    ///     [decorator                                                            ]
    ///     [avatar][name                   ]     [source][visibility][timestamp  ]
    ///     [words                          ]                        [ attachment ]
    ///     [marks                                                                ]
    ///
    var body: some View {
        content
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

    /// What happened to this post before it got here — that it is a reply, that
    /// somebody passed it on. Drawn only when there is something to say: an empty
    /// line held open on every row costs the list a line per post to say nothing.
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

    /// Who wrote it at one end, what it arrived with at the other, on one line. The
    /// name gives up letters before the line gives up the meta: where a post came from
    /// and when is what a reader scans down the list for, and a name they can only
    /// half read is still a name they recognise.
    private var headline: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            avatar
            names
            Spacer(minLength: ShellSpace.snug)
            meta
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
        .frame(width: avatarSide, height: avatarSide)
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
    /// Two columns of a fixed size. The attachment slot is drawn on every row whether
    /// or not the post brought one, so the words start and stop at the same place all
    /// the way down the list — a column that moves with the content is a column the
    /// eye has to find again on every row.
    ///
    /// A phone has no room for the second column, so it keeps the stack, and an empty
    /// slot there would be most of a screen of nothing.
    @ViewBuilder
    private var mainBox: some View {
        if narrow {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                words
                if item.hasThumb { thumb }
            }
        } else {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                words
                thumb
            }
            .frame(height: thumbSide, alignment: .top)
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
                    .lineLimit(1)
            }
            Text(item.body)
                .font(ShellType.body)
                .foregroundStyle(
                    item.title == nil ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme)
                )
                .lineLimit(narrow ? nil : bodyLines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What fits in the slot's height beside it. A row that grows to whatever somebody
    /// wrote makes the list a series of unrelated heights; the rest of the post is a
    /// press away, which is what the thread is for.
    private var bodyLines: Int {
        var lines = 4
        if item.title != nil { lines -= 1 }
        if item.source.kind == .board, item.board != nil { lines -= 1 }
        return max(1, lines)
    }

    /// The slot every row keeps open. Filled when the post brought something, and
    /// otherwise nothing at all: what the slot is for is holding the words' column
    /// still, and a box drawn around a space that is empty on purpose says the
    /// picture is missing rather than absent.
    @ViewBuilder
    private var thumb: some View {
        if item.hasThumb {
            RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                }
                .frame(width: thumbSide, height: thumbSide)
        } else {
            Color.clear
                .frame(width: thumbSide, height: thumbSide)
                .accessibilityHidden(true)
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
