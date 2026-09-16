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

/// The screen the reader actually asked for: *list the boards, select one or more to subscribe*.
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
struct BoardPickerSheet: View {
    let choice: BoardChoice
    /// The reader pressed Subscribe, with what they ticked, in the order the forum listed it.
    let subscribe: ([DiscuzBoard]) -> Void
    /// The reader left. Nothing has been added and nothing is taken back.
    let cancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var picked: Set<Int> = []

    private var offer: JoinOffer { choice.offer }

    /// What they ticked, in the index's order rather than in the order they tapped — the rail
    /// reads this straight through, and a forum's own ordering is a better rail than a record of
    /// which board somebody happened to notice first.
    private var picks: [DiscuzBoard] {
        offer.boards.filter { picked.contains($0.fid) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)
            list
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)
            footer
        }
        .background(ShellChrome.page(colorScheme))
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("board.choose.title"), offer.host))
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("board.choose.detail"))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
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
            .font(ShellType.name)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .background(ShellChrome.well(colorScheme))
    }

    private func row(_ board: DiscuzBoard) -> some View {
        let on = picked.contains(board.fid)
        return Button {
            if on { picked.remove(board.fid) } else { picked.insert(board.fid) }
        } label: {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                tick(on)
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    Text(board.name)
                        .font(ShellType.name)
                        .foregroundStyle(
                            on ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    figures(board)
                }
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
        .accessibilityHint(Text(L10n.t(on ? "board.choose.hint.off" : "board.choose.hint.on")))
    }

    /// The tick: a milled plate, filled when it is on. A square well and not a round checkmark,
    /// because every other pressable plate in this shell is one.
    private func tick(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(on ? ShellChrome.selectInk(colorScheme) : ShellChrome.well(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
            }
            .overlay {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ShellChrome.selectFill(colorScheme))
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
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
                .font(ShellType.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        } else {
            stated(board)
                .font(ShellType.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The stated figures, joined. `Text` concatenation rather than a formatted `String` so the
    /// numbers and the date follow the language the shell is set to, which is the reader's
    /// preference and not the device's — `PreferencesPane.catalogueLine` states the same rule.
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

    private var footer: some View {
        HStack(spacing: ShellSpace.step) {
            Text(String(format: L10n.t("board.choose.count"), picked.count, offer.boards.count))
                .font(ShellType.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            Spacer(minLength: ShellSpace.snug)
            Button(L10n.t("board.choose.cancel")) { cancel() }
            Button(L10n.t("board.choose.subscribe")) { subscribe(picks) }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
        }
        .padding(ShellSpace.pad)
    }
}
