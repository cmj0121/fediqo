import SwiftUI

/// One item, in four bands of a fixed shape: what happened to it, who wrote it and
/// what it arrived with, the words and the attachment, and what can be done to it.
struct DummyItemRow: View {
    let item: DummyItem
    @Binding var marks: DummyMarks
    var selected: Bool = false
    /// Which attachment is on top. It belongs to the app rather than to this view, so that a
    /// refresh that replaces the list leaves a reader who turned to the third one looking at the
    /// third one. See `ShellDecks`.
    var top: Int = 0
    /// Whether the reader has taken the author's cover off this row, for this run.
    var lifted: Bool = false
    var onSelect: (() -> Void)?
    var onToggleCover: () -> Void = {}
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
    /// How far a covered row is smeared. Scaled with the words for the same reason every other
    /// fitting here is, and here the reason is not proportion but correctness: a fixed radius that
    /// hides the default size leaves the largest size legible, and a cover that can be read
    /// through is not a cover.
    @ScaledMetric(relativeTo: .body) private var smear: CGFloat = 10

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

    /// The author's own picture, and the plate where there is none.
    ///
    /// Filled rather than fitted: a face in a small square is a face, and the parts of it outside
    /// the square are the parts nobody looks at. That is the opposite of the slot's rule and for
    /// the opposite reason — the slot holds a photograph somebody composed, and this holds a head.
    ///
    /// **The cover does not reach here.** One cover over the row means the author's words and what
    /// they attached; who wrote it is not what `sensitive` is a fact about, and a timeline of
    /// blurred faces would say something about the authors that nobody said.
    private var avatar: some View {
        Group {
            if let url = item.avatarURL {
                RemoteImage(
                    url: url,
                    tier: .deck,
                    // **The source the post arrived through, not the author's own instance.** The
                    // Clear button can only ever name a server the reader added, and an author's
                    // home instance generally is not one — filing an avatar under it would make
                    // exactly the entry no Clear can reach that I10 exists to prevent.
                    host: item.source.host,
                    standing: .avatar,
                    alt: nil,
                    radius: Box.plate
                )
            } else {
                // Nothing to draw and nothing on its way: the bare plate, which is what this row
                // has always drawn for an author who sent no picture.
                RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
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
                coveredWords
                if item.hasThumb { coveredThumb }
            }
        } else {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                coveredWords
                coveredThumb
            }
            .frame(height: thumbSide, alignment: .top)
            // The frame fixes what this band *takes*; this fixes what it can *draw*. A fixed
            // frame does not stop a child rendering outside it, so the worst case the line limit
            // still allows — the longest warning an instance may send, with the words under it —
            // would have drawn over the marks below rather than made the row taller. Both halves
            // are needed for "server text never changes a row's height" to mean anything.
            .clipped()
        }
    }

    /// Whether the blur is on: the author put a cover here and the reader has not taken it off.
    /// Distinct from `item.covered`, which is whether there is a cover at all — the notice is
    /// drawn in both states and only this one blurs anything.
    private var covered: Bool { item.covered && !lifted }

    /// The author's line and the control above, the words below.
    ///
    /// **A band, not an overlay, and it does not go away when the row is lifted.** The spoiler
    /// line is the author's own text and belongs on the post either way; keeping it means the
    /// control that puts the cover back is the same control in the same place as the one that
    /// took it off, rather than a second one somewhere else. Not the same *size*: `Show it` and
    /// `Hide it` happen to match in English and 掀開 and 蓋回去 do not, so what stays put is the
    /// control and its band, not its width. A control that exists only while the row is covered is
    /// lift-only for anybody not using the keyboard — which is the fault this row has just been
    /// fixed for once, and adding a second one deliberately would be the wrong direction.
    ///
    /// **Blurred words are still words.** A `Text` behind a blur is in the accessibility tree and
    /// on the pasteboard, so a cover made of blur alone hides the post from the reader who can see
    /// it and from nobody else. The blur is what a covered row *looks* like; the two lines under
    /// it are what it *is*. `textSelection` is set even though nothing here turns selection on
    /// today: it is a standing answer, so that enabling selection somewhere above this row cannot
    /// quietly make the covered ones copyable.
    ///
    /// Clipped because a blur draws outside the box it was given, and what is beside this box is
    /// the slot and the next post.
    @ViewBuilder
    private var coveredWords: some View {
        if item.covered {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                notice
                if covered {
                    words
                        .blur(radius: smear)
                        .clipped()
                        .accessibilityHidden(true)
                        .textSelection(.disabled)
                } else {
                    words
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            words
        }
    }

    /// The slot, smeared with the same hand as the words. One cover over the row means one
    /// radius: two blurs of different strengths would read as two covers.
    ///
    /// Clipped back to the card's own corner rather than to a rectangle. A blur takes the rounded
    /// edge with it, and what was left was a hard-cornered smudge against the row's margin — a
    /// covered picture should still look like the picture it is covering.
    @ViewBuilder
    private var coveredThumb: some View {
        if covered {
            thumb
                .blur(radius: smear)
                .clipShape(RoundedRectangle(cornerRadius: Box.plate, style: .continuous))
                // And hidden, for the same reason the words are. What the author wrote for
                // somebody who cannot see the picture describes the picture — read out from
                // behind the cover, it is the cover lifted for exactly the reader who cannot
                // lift it back. The notice names what is under there without describing it.
                .accessibilityHidden(true)
        } else {
            thumb
        }
    }

    /// The author's own line, and the key that takes the cover off or puts it back.
    ///
    /// One control with two labels. It is a button as well as a key: a reader who never touches
    /// the keyboard would otherwise be told which key works and have no way to press it, and on a
    /// phone there is no `s` to be told about at all.
    private var notice: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(coverLine)
                .font(ShellType.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(coverLines)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onToggleCover) {
                HStack(spacing: ShellSpace.snug) {
                    Text(verbatim: "s")
                        .font(ShellType.keycap)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .padding(.horizontal, ShellSpace.snug)
                        .padding(.vertical, ShellSpace.hair * 2)
                        .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
                    Text(L10n.t(covered ? "item.covered.show" : "item.covered.hide"))
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Ignored rather than combined, and then said properly: combining would read the key cap
        // out as the letter "s" in the middle of a sentence.
        //
        // **Ignoring the children throws the real button's activation away with them**, and a
        // hand-added `.isButton` trait with nothing behind it is a control that announces itself
        // and then does nothing when it is pressed. On a phone there is no `s` to fall back on,
        // so without this action a reader using VoiceOver could not uncover a post at all — the
        // one reader decision 6 is most for, with no way in.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCover)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onToggleCover() }
    }

    /// How many lines the author's line may have: one fewer than the words are allowed, because
    /// the control takes the last one. Derived from the words' own rule rather than chosen, so
    /// the two cannot drift apart.
    ///
    /// **Server text never changes a row's height. Only a reader's own action does.** A
    /// `spoiler_text` is up to five hundred characters that a hostile instance picks, so any rule
    /// that lets it size a row is a layout attack that lands on every row of a timeline at once —
    /// which is a stronger reason for the limit than rows looking uniform. What is left over is a
    /// warning long enough that it has stopped being a warning and become the post; a reader who
    /// wants all of it uncovers, and a screen reader is given every character regardless.
    private var coverLines: Int { max(1, bodyLines - 1) }

    /// What the row says out loud: the author's line **in full**, what is under the cover named
    /// but not described, and the way to work the control.
    ///
    /// **The full `spoiler_text`, never the truncated string.** A visual limit is a fact about
    /// this column's height and about nothing else; inheriting it here would hide from a screen
    /// reader exactly the text that exists to let somebody decide.
    ///
    /// The middle clause is the one that is easy to leave out. While the row is covered the words
    /// and the attachment are both out of the accessibility tree, so without it a covered row
    /// carrying four photographs announces a warning and nothing else, and a reader cannot tell
    /// there is anything there to uncover. `AttachmentDeck.named` carries the kind and the count
    /// and never the alt text, which is what keeps the cover a cover. Once the row is lifted the
    /// deck speaks for itself and the clause would only say it twice.
    private var spokenCover: String {
        let attached = covered ? AttachmentDeck.named(item.attachments, top: top) : nil
        let how = L10n.t(covered ? "item.covered.label" : "item.lifted.label")
        return [coverLine, attached, how].compactMap { $0 }.joined(separator: ". ")
    }

    /// What the author wrote on the cover, or what to say where they wrote nothing but flagged it.
    private var coverLine: String {
        let spoiler = item.spoiler ?? ""
        return spoiler.isEmpty ? L10n.t("item.covered.title") : spoiler
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
            AttachmentDeck(
                attachments: item.attachments,
                top: top,
                side: thumbSide,
                host: item.source.host,
                radius: Box.plate
            )
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
