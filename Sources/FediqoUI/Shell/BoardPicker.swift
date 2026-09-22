import FediqoCore
import SwiftUI

/// A forum read, and the reader deciding what of it they want. D28's pause, as a value the sheet
/// is presented from.
///
/// Identified by host, so a second offer for the same forum replaces the first rather than
/// stacking a second sheet on it — one source per host is D26, and one sheet per host follows.
struct BoardChoice: Identifiable, Equatable {
    let offer: JoinOffer
    var id: String { offer.host }
}

/// The boards themselves: *list them, select one or more to subscribe*.
///
/// **The list and not the sheet.** The header, the footer and the sheet's own sizing moved to
/// `JoinSheet` when the picker became a stage rather than a presentation of its own — two frames
/// on macOS is a window that resizes as the reader steps between stages. Everything below the
/// hairline is unchanged, and deliberately so.
///
/// **The chassis, one level in.** Nothing here invents a look — the shell is a milled instrument
/// and a board is another plate on it, so the tick is a square well with a radius of 3 like the
/// rail's, the figures are `ShellType.reading` because that is the role built for a column of
/// numbers that must not wobble, and the only colour that moves is the one the query pills
/// already use for "this is the one". The phosphor stays on the rail, where it is the only one.
///
/// **What a reader is actually choosing between.** On `install-a.example` this list is 33 boards in
/// 11 categories, and on `install-c.example` it is 32 in 4. A name alone does not tell anybody which
/// of those to read, so each row carries what the index stated about it — how many threads, how
/// many posts, when somebody last wrote in it — grouped under the forum's own headings, because
/// the grouping is itself information the forum spent effort on.
///
/// **A figure the forum did not state is drawn as nothing, never as a zero.** `DiscuzBoard` makes
/// that distinction in the data and this is where it has to survive contact with a screen:
/// `install-b.example` has a board with a true, stated `0 threads` and another with `...` where the
/// figure goes, and a row that drew both as "0" would be telling the reader something the forum
/// never said. A board that stated nothing at all says so in words instead.
struct BoardPickerList: View {
    let offer: JoinOffer
    /// What the reader has ticked, held by the sheet — the footer's count and its Subscribe both
    /// read it, and the footer belongs to the frame rather than to this list.
    @Binding var picked: Set<Int>

    @Environment(\.colorScheme) private var colorScheme
    /// The tick's own size, **scaling with the name beside it**. It was a fixed `18` against a
    /// `ShellType.name` that reaches `.accessibility1`, where the box read as a bullet rather than
    /// as a control. 20 at the default rung, one point over the name's cap height, so the box is
    /// the loudest thing on the row at every rung rather than only at the smallest.
    @ShellMetric(relativeTo: .callout) private var tickSize: CGFloat = 20
    /// Half a callout's cap height, scaling with it — `SourceRowView.capHalf`'s value and its
    /// reason, one file over. See `row(_:)`.
    @ShellMetric(relativeTo: .callout) private var capHalf: CGFloat = 6

    var body: some View {
        list
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // A category the forum listed with nothing under it is not a heading worth a
                // reader's screen. It is rare and it is not an error — a moderator emptied it.
                ForEach(offer.categories.filter { !$0.boards.isEmpty }) { category in
                    Section {
                        ForEach(category.boards) { board in
                            row(board)
                            Rectangle()
                                .fill(ShellChrome.hairline(colorScheme))
                                .frame(height: ShellSpace.hair)
                        }
                    } header: {
                        categoryHeader(category)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func categoryHeader(_ category: DiscuzCategory) -> some View {
        Text(category.name)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .background(ShellChrome.well(colorScheme))
    }

    /// How far a board under a board is set in.
    ///
    /// One step and only one: `DiscuzBoard.depth` stops at 1 because this device reads a board's
    /// *direct* children and no further, so a second rung here would be a claim it cannot
    /// support. `ShellSpace.room` rather than a new number — it is the scale's own
    /// "around something that has to stand alone", and a child board is exactly that.
    private static let rung = ShellSpace.room

    /// One board, and — **D29** — one board under a board, set in and pickable in its own right.
    ///
    /// **Indented, and still individually selectable.** A parent's `forumdisplay` does not
    /// include its children's threads, verified live: `install-d.example` board 300 is a
    /// child of 297 and answers with sixty-three threads of its own, none of which appear under
    /// 297. So a tick on the parent that quietly meant nine boards would be either a lie about
    /// what the reader subscribed to or nine boards' worth of traffic they did not ask for. They
    /// are separate `fid`s in Discuz! and they are separate picks here.
    ///
    /// **Found in two places, drawn the same way (#161).** Some forums name a board's children on
    /// the front page; others only on the parent's own page, which is read when the reader ticks
    /// the parent — so those rows appear under it a moment after the tick, unticked.
    ///
    /// **These rows can be emptier than their neighbours and that is the honest cost of listing
    /// them.** On the front page a sub-board is a bare name: no thread count, no post count, no
    /// last-post time. On the parent's own page it has all three, and they are drawn. `figures` already draws a stated figure and nothing at all where the forum
    /// stated nothing, so a child row usually falls to the "this forum stated no figures" line —
    /// which is true, and is what makes the row judgeable rather than merely present.
    ///
    /// Only one of the four installs measured has any children at all — `install-d.example`, 23 boards
    /// with 39 under them — so on three of four forums nothing on this screen changes.
    private func row(_ board: DiscuzBoard) -> some View {
        let on = picked.contains(board.fid)
        // Read out before the `alignmentGuide` closure: that closure is `@Sendable` and a
        // `@ScaledMetric` is main-actor isolated, so the number crosses rather than the property.
        // `SourceRowView.actionsTrailing` states the same rule one file over.
        let anchor = capHalf
        return Button {
            if on { picked.remove(board.fid) } else { picked.insert(board.fid) }
        } label: {
            // **Two stacks, because the rule and the tick want different alignments.** The tick
            // belongs on the board name's first line, which is the only line it is about — it sat
            // ~3pt above the name's cap top on every row under `.top`. The set-in rule belongs to
            // the whole row and has no text baseline of its own, so leaving it in a
            // `firstTextBaseline` stack would ask SwiftUI to baseline-align a flexible rectangle.
            HStack(alignment: .top, spacing: ShellSpace.step) {
                // The set-in is a leading pad on the row's own content rather than on the button,
                // so the whole width of the row stays pressable: a child board whose hit area
                // started a rung in would be a smaller target than its parent for no reason a
                // reader could see.
                if board.depth > 0 {
                    Rectangle()
                        .fill(ShellChrome.hairline(colorScheme))
                        .frame(width: ShellSpace.hair)
                        .padding(.leading, Self.rung - ShellSpace.snug)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                    tick(on)
                        // The tick has no baseline of its own, so its own centre is mapped onto
                        // the name's — the guide `SourceRowView` uses for the row's trailing
                        // group, and for the same reason.
                        .alignmentGuide(.firstTextBaseline) {
                            $0[VerticalAlignment.center] + anchor
                        }
                    VStack(alignment: .leading, spacing: ShellSpace.tight) {
                        Text(board.name)
                            .shellFont(.name)
                            .foregroundStyle(
                                on
                                    ? ShellChrome.selectInk(colorScheme)
                                    : ShellChrome.ink(colorScheme)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        figures(board)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? ShellChrome.selectFill(colorScheme) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityHint(Text(L10n.t(on ? "board.choose.hint.off" : "board.choose.hint.on")))
        // The set-in says "under that one" to a reader who can see the list. A reader who cannot
        // gets one row after another with no geometry at all, so the nesting has to be in words
        // or it is not there for them — and it is the fact that decides whether a pick is
        // sensible, because a child is not included in its parent.
        .accessibilityLabel(Text(spoken(board)))
    }

    /// What a row says out loud: its name, and whose board it sits under where it sits under one.
    ///
    /// Named by the **parent's name and not its number**: a reader is being told where they are
    /// in a list they can see the rest of, and `fid` 297 means nothing to anybody. Where the
    /// parent is not on this list — which the index's own reading order makes impossible, and
    /// which is checked rather than assumed — the row falls back to its name alone rather than to
    /// a sentence with a hole in it.
    func spoken(_ board: DiscuzBoard) -> String {
        guard let parent = board.parent,
              let above = offer.boards.first(where: { $0.fid == parent })
        else { return board.name }
        return String(format: L10n.t("board.choose.under"), board.name, above.name)
    }

    /// What the tick is drawn in, for the state it is in. **The one place either state's three
    /// colours are decided**, and the reason it is a `static func` rather than three ternaries in
    /// a `View` body is that a `View` body is reachable from no test — which is precisely how a
    /// checkbox with no tick in it survived a green suite (risk 12).
    static func tick(_ on: Bool, _ scheme: ColorScheme) -> BoardTick {
        on
            ? .on(
                plate: ShellChrome.selectInk(scheme),
                border: ShellChrome.selectInk(scheme),
                mark: ShellChrome.page(scheme)
            )
            : .off(
                plate: ShellChrome.well(scheme),
                // **`inkFaint` and not `hairline`, which is the one substitution worth
                // defending.** `hairline` is the token for a *rule between rows* and measures
                // 1.30:1 on the page in light — a control whose own boundary a reader cannot
                // find. A control's boundary is a different job, and `inkFaint`'s own doc
                // already states the principle: the faintest step is still text, and text has a
                // floor. Measured after: **4.78:1** light, 6.69:1 dark.
                border: ShellChrome.inkFaint(scheme)
            )
    }

    private func tick(_ on: Bool) -> some View {
        PickTick(on: on, size: tickSize)
    }

    /// What the index stated about this board, and **only** what it stated.
    ///
    /// Each figure is drawn where the forum gave one and left out entirely where it did not, so a
    /// row reading "9 posts" with no thread count is a forum that said one and not the other —
    /// which is true, and is not the same row as one reading "0 threads · 9 posts". Where nothing
    /// at all was stated the row says that in words, so the gap is a fact rather than a blank.
    @ViewBuilder
    private func figures(_ board: DiscuzBoard) -> some View {
        if board.threads == nil, board.posts == nil, board.lastPostAt == nil {
            Text(L10n.t("board.choose.unstated"))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        } else {
            stated(board)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The stated figures, joined. `Text` concatenation rather than a formatted `String` so the
    /// numbers and the date follow the language the shell is set to, which is the reader's
    /// preference and not the device's — `UsagePane.catalogueLine` states the same rule.
    private func stated(_ board: DiscuzBoard) -> Text {
        var line = Text(verbatim: "")
        var first = true
        func add(_ piece: Text) {
            line = first ? piece : line + Text(verbatim: " · ") + piece
            first = false
        }
        if let threads = board.threads {
            add(Text(String(format: L10n.t("board.choose.threads"), threads)))
        }
        if let posts = board.posts {
            add(Text(String(format: L10n.t("board.choose.posts"), posts)))
        }
        if let last = board.lastPostAt {
            add(Text(last, format: .relative(presentation: .named)))
        }
        return line
    }
}

/// The tick: a milled plate, filled when it is on. A square well and not a round checkmark,
/// because every other pressable plate in this shell is one. The board picker's and the list
/// picker's, so the two choices look like the one kind of choice they are.
struct PickTick: View {
    let on: Bool
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let drawn = BoardPickerList.tick(on, colorScheme)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(drawn.plate)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(drawn.border, lineWidth: ShellSpace.hair)
            }
            .overlay {
                if let mark = drawn.mark {
                    Image(systemName: "checkmark")
                        // Sized from the plate rather than fixed at 11, so the mark and the box
                        // it is cut out of grow together.
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(mark)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A signed-in Mastodon's lists, and the reader deciding which of them this device reads (#25) —
/// the board choice's counterpart, as a value the sheet is presented from.
///
/// `offered` is what the server has now; `ticked` opens as what is chosen, intersected with it,
/// so a list the server no longer has is dropped by the next Done, as a board is.
struct ListChoice: Equatable {
    let host: String
    let offered: [ListSubscription]
    var ticked: Set<String>

    /// What Done hands on: the ticked lists, in the server's order and under its names now.
    var picks: [ListSubscription] { offered.filter { ticked.contains($0.id) } }
}

/// The lists themselves: one tick per list, the board rows' look without their figures — a list
/// has none to state.
struct ListPickerList: View {
    let offered: [ListSubscription]
    @Binding var picked: Set<String>

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .callout) private var tickSize: CGFloat = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if offered.isEmpty {
                    Text(L10n.t("list.choose.none"))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(ShellSpace.pad)
                }
                ForEach(offered) { list in
                    row(list)
                    Rectangle()
                        .fill(ShellChrome.hairline(colorScheme))
                        .frame(height: ShellSpace.hair)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ list: ListSubscription) -> some View {
        let on = picked.contains(list.id)
        return Button {
            if on { picked.remove(list.id) } else { picked.insert(list.id) }
        } label: {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                PickTick(on: on, size: tickSize)
                Text(list.name)
                    .shellFont(.name)
                    .foregroundStyle(
                        on ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? ShellChrome.selectFill(colorScheme) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityHint(Text(L10n.t(on ? "list.choose.hint.off" : "list.choose.hint.on")))
        .accessibilityLabel(Text(list.name))
    }
}

/// How the board picker's tick is drawn, in whichever of its two states it is in.
///
/// **`RowActionState`'s shape, applied to the other control this branch shipped invisible.** The
/// mark's ink exists only in `.on`, so **a mark on an unticked box cannot be spelled**.
///
/// **What the type does not prevent, said plainly rather than claimed away**: `.on(plate: p,
/// border: b, mark: p)` compiles, so a mark in the plate's own hue — the defect this closes — is
/// caught by the *contrast test* and not by this enum. They are two guarantees and not one, and
/// this unit argues the structural-versus-guarded distinction everywhere else, so it must not
/// overstate it here. Closing the second half in the type would mean carrying the `ColorScheme`
/// in the case so the mark could be derived from the ground — a second spelling of `tick(_:_:)`,
/// bought to retire a test that measures the real thing.
///
/// **What was there, measured rather than judged.** The plate was filled `ShellChrome.selectInk`,
/// which is `phosphor`, and the checkmark was drawn in `ShellChrome.selectFill`, which is *that
/// same phosphor at 10% (light) / 22% (dark)*. A translucent colour composited over itself at full
/// strength is that colour: **1.00:1, in both schemes**. There was no tick in the checkbox, and in
/// light mode the only visible effect of ticking a board was the name turning teal — a change of
/// hue, which a reader with a colour deficiency or a glary screen does not get at all.
///
/// The mark is `ShellChrome.page` and deliberately not white: the tick is the plate **not being
/// there**, cut out of it, which is what a milled instrument does. `ShellChrome.overPicture` is the
/// white one and is for a stranger's photograph, where the ground is unknown; here the ground is
/// this app's own.
enum BoardTick: Equatable {
    /// Not picked. A milled well with a boundary of its own, and nothing in it.
    case off(plate: Color, border: Color)
    /// Picked. The plate filled, and the mark cut out of it. `page` on `selectInk` measures
    /// **5.37:1** light and **9.60:1** dark, against the 1.00:1 it replaces.
    case on(plate: Color, border: Color, mark: Color)

    var plate: Color {
        switch self {
        case .off(let plate, _), .on(let plate, _, _): plate
        }
    }

    var border: Color {
        switch self {
        case .off(_, let border), .on(_, let border, _): border
        }
    }

    /// The mark, where there is one. **Nothing is the only answer `.off` can give**, which is what
    /// makes "ticked" and "not ticked" differ by a *shape* rather than by a hue — so the column
    /// reads at a glance in 中文 at `.accessibility1` exactly as it does in English at `.medium`.
    ///
    /// **Do not flatten this type into a struct with a `mark: Color?` field.** That is the tidier
    /// spelling and it gives back the one thing this type does prevent: a struct can be built with
    /// a mark and no fill, or a fill and no mark, and this app shipped a checkbox whose mark
    /// nobody could see. The `Optional` here is a *reading* of two closed cases, not a field
    /// anybody can set.
    var mark: Color? {
        switch self {
        case .off: nil
        case .on(_, _, let mark): mark
        }
    }
}
