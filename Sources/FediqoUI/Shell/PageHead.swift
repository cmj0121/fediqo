import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The head of a page that is one of several, on a narrow screen: **the one in front by name,
/// and under the name a dot for each of them** — so that there are others is seen, and which
/// this is among them (#304, #305).
///
///     [glyph] Name ⌄                                   [marks]
///     ● ○ ○ ○  a line about it, where it has one
///
/// The timelines' head and the head of every page with tabs are this one view. **The name is
/// the way to the rest**: pressed, it lists them, and it never does anything else. The head
/// stays where it is while what is under it is swiped, and shows the change: the dot in front
/// fades as its neighbour lights, by as much as the finger has gone, and the name and the line
/// under it leave the way the page went.
struct PageHead<Marks: View>: View {
    /// What is in front: its name, its glyph, and where it stands.
    struct Front: Equatable {
        /// What tells this one from the others, so a change of it is shown as a change.
        var id: String
        var name: String
        var symbol: String
        /// A glyph after the name, quiet and unspoken: the hint says it in words.
        var accessory: String? = nil
        /// A line about it, where it has one of its own. Nothing, and only the dots are drawn.
        var line: String? = nil
        /// Where it stands among them all, from nought, and how many there are.
        var index: Int?
        var count: Int
    }

    let front: Front
    /// What a listener is told the name's press does.
    let hint: String
    /// The words for "2 of 5", by the key they are written under.
    var positionKey = "timeline.position"
    /// How far a finger is dragging the page toward the one beside, where a swipe does that.
    var slide: PageSlide? = nil
    let onPress: () -> Void
    @ViewBuilder var marks: Marks

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the last change went, worked out as this is drawn and not a change later.
    @State private var seen = PageTravel()
    /// A line of the name's writing, near enough: what its finger's reach is worked out from.
    @ShellMetric(relativeTo: .callout) private var drawn: CGFloat = 20

    var body: some View {
        let travel = seen.note(front.index)
        HStack(alignment: .center, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                name(travel)
                standing(travel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            marks
        }
    }

    private func name(_ travel: Int) -> some View {
        Button(action: onPress) {
            HStack(spacing: ShellSpace.tight) {
                Image(systemName: front.symbol)
                    .symbolVariant(.fill)
                    // One room for every glyph, so the head is one height and the name starts
                    // in one place whichever of them is in front.
                    .frame(width: drawn, height: drawn * 0.6)
                    .accessibilityHidden(true)
                ChangingLine(text: front.name, id: front.id, travel: travel, still: reduceMotion)
                if let accessory = front.accessory {
                    Image(systemName: accessory)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.down")
                    .shellFont(.mark, weight: .semibold)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .accessibilityHidden(true)
            }
            .shellFont(.name, weight: .semibold)
            .foregroundStyle(ShellChrome.selectInk(colorScheme))
            // The whole line, glyph to chevron, and a finger's reach round it on a phone —
            // reached, not drawn, so the head is no taller for it.
            .modifier(ShellTouchFloor(drawn: drawn))
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(front.name)
        .accessibilityHint(hint)
    }

    @ViewBuilder
    private func standing(_ travel: Int) -> some View {
        HStack(spacing: ShellSpace.snug) {
            if let index = front.index, Self.drawn(count: front.count) {
                TimelineDotsRow(index: index, total: front.count, slide: slide)
            }
            if let line = front.line {
                ChangingLine(text: line, id: front.id, travel: travel, still: reduceMotion)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(line: front.line, position: front.index, of: front.count, key: positionKey))
    }

    /// The second line as it is heard: the line about it, where there is one, then "2 of 5".
    static func spoken(
        line: String?, position: Int?, of total: Int, key: String = "timeline.position", language: DummyLanguage? = nil
    ) -> String {
        let place: String? = position.flatMap { position in
            total > 1 ? String(format: L10n.t(key, language: language), position + 1, total) : nil
        }
        return [line, place].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether a page that is one of `count` draws this head at all: only where there are
    /// others to go to. One alone has no dots, no list and nothing to press its name for.
    static func drawn(count: Int) -> Bool { count > 1 }
}

/// Which way the page in front last changed, kept by whatever draws its head.
///
/// **Asked as the head is drawn**, with the place it is being drawn for, so the answer is for
/// this change and not the one before: a thing worked out after the drawing — on the change
/// being noticed — is right only from the next change on.
@MainActor
final class PageTravel {
    private var last: Int?
    private(set) var travel = 1

    /// Notes where the page now stands and says which way it went to get there: `1` on, `-1`
    /// back. The same place again says what was said last.
    func note(_ index: Int?) -> Int {
        guard let index else { return travel }
        if let last, index != last { travel = index < last ? -1 : 1 }
        last = index
        return travel
    }
}

/// One line of writing that, when what it is about changes, leaves toward the side the page
/// left by and comes back in from the other with the new words; with motion reduced it fades.
///
/// **It holds the words it is showing**, and changes them itself half-way: the way out and the
/// way in are then both for *this* change. A transition put on the words would take its way out
/// from the drawing before, which is the change before.
struct ChangingLine: View {
    let text: String
    let id: String
    let travel: Int
    let still: Bool

    /// The words on show and what they are about, kept as this is drawn: so that the drawing
    /// in which what it is about has just changed still shows the old words, and not the new
    /// ones for a frame before they leave.
    @State private var held = Held()
    /// Counted up when the words on show are let go for the new ones, to draw it again.
    @State private var turned = 0
    @State private var offset: CGFloat = 0
    @State private var faint = false

    @MainActor
    final class Held {
        var id: String?
        var text = ""

        /// The words to draw for `text` about `id`: the new ones where it is about the same
        /// thing as before or nothing was on show, and the old ones while it has just changed.
        func showing(_ text: String, about id: String) -> String {
            if self.id == nil || self.id == id {
                self.id = id
                self.text = text
            }
            return self.text
        }

        /// The old words let go: what is drawn next is the new.
        func turn() { id = nil }
    }

    var body: some View {
        let _ = turned
        Text(held.showing(text, about: id))
            .lineLimit(1)
            .truncationMode(.tail)
            .offset(x: offset)
            .opacity(faint ? 0 : 1)
            .onChange(of: id) { _, _ in change() }
    }

    private func change() {
        let step = still ? 0 : CGFloat(travel) * TimelineDots.shift
        withAnimation(.easeIn(duration: TimelineDots.moves / 2)) {
            offset = -step
            faint = true
        } completion: {
            var none = Transaction()
            none.disablesAnimations = true
            withTransaction(none) {
                held.turn()
                turned += 1
                offset = step
            }
            withAnimation(.easeOut(duration: TimelineDots.moves / 2)) {
                offset = 0
                faint = false
            }
        }
    }
}

/// One of the things a page's name lists: a timeline, or a tab.
struct PageListEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// A line about it, under its name, where it has one.
    var brief: String? = nil
    let symbol: String
    let current: Bool
    /// What VoiceOver adds, where there is more to say than the name.
    var hint: String? = nil
}

/// What a page's name opens: every one of them, one to a row, the one in front marked — and
/// under them whatever else the page offers there. **One press on a row goes to it** and the
/// list closes.
struct PageListSheet<Extra: View>: View {
    let title: String
    let entries: [PageListEntry]
    let choose: (PageListEntry) -> Void
    @ViewBuilder var extra: Extra

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    extra
                }
                .padding(ShellSpace.step)
            }
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("compose.cancel")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        // The list comes up from the foot of the screen, where a keyboard stands: what was
        // being typed is let go, so the keyboard is not over its rows.
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        #endif
    }

    private func row(_ entry: PageListEntry) -> some View {
        Button {
            choose(entry)
            dismiss()
        } label: {
            ShellListRowFace(
                title: entry.name, brief: entry.brief, figure: nil, selected: entry.current,
                mark: Image(systemName: entry.symbol)
            )
            .background(
                RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
                    .fill(entry.current ? ShellChrome.selectFill(colorScheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.hint ?? "")
        .accessibilityAddTraits(entry.current ? .isSelected : [])
    }
}
