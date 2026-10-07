import SwiftUI

/// Where a timeline stands among the person's timelines, as a row of dots (#304).
///
/// **No more than `most`.** Past that the row is a window on the timelines around the one in
/// front, and a smaller dot at an end says there are more that way — so the row is the same
/// width however many timelines there are, and never the thing that pushes a name off a phone.
struct TimelineDots: Hashable, Sendable {
    /// How many dots are drawn.
    let count: Int
    /// Which of them is the timeline in front, from nought.
    let lit: Int
    /// Whether there are timelines before the first dot, and after the last.
    let moreBefore: Bool
    let moreAfter: Bool

    static let most = 7

    /// The dots for the timeline at `position` (from nought) of `total`. Nothing for fewer than
    /// two timelines: one timeline stands nowhere among others.
    static func dots(position: Int, of total: Int) -> TimelineDots? {
        guard total > 1, position >= 0, position < total else { return nil }
        guard total > most else { return TimelineDots(count: total, lit: position, moreBefore: false, moreAfter: false) }
        // A window with the one in front in its middle, held inside the ends.
        let first = min(max(0, position - most / 2), total - most)
        return TimelineDots(count: most, lit: position - first, moreBefore: first > 0, moreAfter: first + most < total)
    }

    /// Whether the dot at `index` is one of the small ones that say there are more past it.
    func fades(_ index: Int) -> Bool {
        (index == 0 && moreBefore) || (index == count - 1 && moreAfter)
    }
}

/// What the list of timelines offers (#304): every timeline, and the two acts on them.
struct TimelineList: Equatable {
    struct Entry: Identifiable, Equatable {
        let query: TimelineQuery
        let name: String
        let rule: String
        let current: Bool
        /// One of its rules has lost its source.
        let missing: Bool
        var id: String { query.id }
    }

    let entries: [Entry]
    /// A new timeline can be made: what `[+]` does.
    let offersNew: Bool
    /// The timeline in front can be changed: what `e` does. Only one of the person's own — the
    /// two every source brings are not theirs to change, and a row that only said so would be
    /// a row that does nothing.
    let offersEdit: Bool

    static func offered(
        _ queries: [TimelineQuery], current: TimelineQuery, name: (TimelineQuery) -> String,
        rule: (TimelineQuery) -> String, missing: (TimelineQuery) -> Bool
    ) -> TimelineList {
        let entries = queries.map {
            Entry(query: $0, name: name($0), rule: rule($0), current: $0 == current, missing: missing($0))
        }
        let own = if case .written = current { true } else { false }
        return TimelineList(entries: entries, offersNew: !queries.isEmpty, offersEdit: own && queries.contains(current))
    }

    /// Where the timeline in front stands, from nought, or nothing where it is not among them.
    var position: Int? { entries.firstIndex(where: \.current) }

    /// One of the list's two acts, with the timeline it was pressed for.
    enum Act: Equatable, Sendable {
        case new
        /// Changing this timeline: the one in front when the press was made, whatever is in
        /// front by the time the list has gone.
        case edit(TimelineQuery)
    }

    /// What is done once the list has gone, given what was pressed in it and what is there now.
    ///
    /// **Nothing where the head is no longer drawn** — the person turned the device to a wide
    /// page, or went to another place, while the list was leaving — and nothing for a timeline
    /// that has since gone. An editor raised over a page nobody is on would be a sheet from
    /// nowhere.
    static func afterDismissal(_ pressed: Act?, among queries: [TimelineQuery], headShown: Bool) -> Act? {
        guard headShown, let pressed else { return nil }
        if case .edit(let query) = pressed, !queries.contains(query) { return nil }
        return pressed
    }

    /// Whether a press on the name raises the list: not while an act pressed in it is still to
    /// be done, and not while the editor is up — either would be a second sheet over the first.
    static func raises(pressed: Act?, editing: Bool) -> Bool {
        pressed == nil && !editing
    }

    /// The notice for a timeline that cannot be changed, which also says where a new one is
    /// made: the `[+]` on a wide page, and the timeline's name where there is none.
    static func fixedNoticeKey(narrow: Bool) -> String {
        narrow ? "timeline.edit.fixed.narrow" : "timeline.edit.fixed"
    }
}

/// The head of a timeline on a narrow page (#304): the one timeline it shows, by name, and under
/// the name its rules in one line and where it stands among the others.
///
///     [glyph] Name ⌄                          [search] [reload]
///     ● ○ ○ ○  In time order, nothing filtered.
///
/// **The name is the way to every other timeline.** Pressing it lists them — it never does
/// anything else — and the list is where a new one is made and this one changed, so the row of
/// every name and the `[+]` beside it, which a phone has no room for, are not drawn here.
///
/// **Both lines shorten and neither pushes.** The name and the rules each give up letters; the
/// glyph, the dots and the marks at the far end keep their size.
struct TimelineNarrowHead<Marks: View>: View {
    @Bindable var session: ShellSession
    /// How far a finger is dragging what is under the head toward the timeline beside.
    var slide: PageSlide? = nil
    @ViewBuilder var marks: Marks

    private var timeline: TimelineQuery { session.currentTimeline }

    var body: some View {
        let missing = session.hasMissingRule(timeline)
        let place = session.timelinePosition
        PageHead(
            front: PageHead<Marks>.Front(
                id: timeline.id, name: session.name(of: timeline), symbol: timeline.symbol,
                accessory: missing ? "circle.dashed" : nil, line: session.rule(of: timeline),
                index: place.index, count: place.count
            ),
            hint: Self.hint(missing: missing), slide: slide,
            onPress: {
                guard TimelineList.raises(pressed: session.timelineListPressed, editing: session.editing != nil) else { return }
                session.timelineListShown = true
            },
            marks: { marks }
        )
        // What was pressed in the list is done when the list has gone, and not on a clock.
        .sheet(isPresented: $session.timelineListShown, onDismiss: { session.timelineListDismissed() }) {
            TimelineListSheet(session: session)
        }
        .onAppear { session.timelineHeadShown = true }
        // The head gone — a wide page now, or another place — its list goes with it, and so
        // does anything pressed in it: neither comes back by itself later.
        .onDisappear {
            session.timelineHeadShown = false
            session.timelineListPressed = nil
            if session.timelineListShown { session.timelineListShown = false }
        }
    }

    /// What VoiceOver adds after the name: that pressing it lists the timelines, and before
    /// that, where a rule has lost its source, that one has. Each a sentence written whole in
    /// its language, so neither is joined by another language's full stop.
    static func hint(missing: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(missing ? "timeline.list.hint.missing" : "timeline.list.hint", language: language)
    }

    /// The second line as it is heard: the rules, then "2 of 5".
    static func spoken(rule: String, position: Int?, of total: Int, language: DummyLanguage? = nil) -> String {
        PageHead<Marks>.spoken(line: rule, position: position, of: total, language: language)
    }
}

/// The dots themselves. Drawn, never heard: the line they stand in says "2 of 5".
///
/// **A row of dots and nothing over them.** Each is as lit as the page in front is near it
/// (`TimelineDots.drawn`): at rest one is lit and the rest are faint, and while a finger slides
/// the page the one in front fades as its neighbour lights, by as much as the finger has gone.
/// There was one lit dot carried over a row of faint ones, and between two places it showed
/// beside the faint dot it had left and the one it was coming to — three where there are two.
///
/// **Nothing here is animated by the row.** What a finger moves is drawn where the finger has
/// it, and a thing that also animated itself would chase the finger a fifth of a second behind.
/// The one animation is the letting go, made where the page is let go (`PageSwipeCatcher`) and
/// together with the page's own. With motion reduced nothing leans, and the dot lit is simply
/// the other one once the page has changed.
///
/// It is the only thing that reads the slide here, so a drag draws this row again and nothing else.
struct TimelineDotsRow: View {
    /// Which of them is in front, from nought, and how many there are.
    let index: Int
    let total: Int
    var slide: PageSlide? = nil

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .caption) private var side: CGFloat = 6

    var body: some View {
        let drawn = TimelineDots.drawn(position: CGFloat(index) + TimelineDots.leaning(slide?.lean ?? 0), of: total)
        let faint = ShellChrome.inkFaint(colorScheme), lit = ShellChrome.selectInk(colorScheme)
        // Laid out by the row's own direction, so in a language read from the right the next
        // dot is the one to the left, as the next page is.
        HStack(spacing: side * 0.6) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { _, dot in
                Circle()
                    .fill(faint.mix(with: lit, by: Double(dot.lit)))
                    .frame(width: side, height: side)
                    // Drawn smaller, never laid out smaller: the row is one size whatever it shows.
                    .scaleEffect(1 - dot.small / 2)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

extension TimelineDots {
    /// How long the head takes to show a change, in seconds.
    static let moves: Double = 0.2
    /// How far the name and the rules travel as they change, in points.
    static let shift: CGFloat = 14

    /// One dot as it is drawn.
    struct Drawn: Equatable, Sendable {
        /// How lit it is: `1` the page in front, `0` any other, and between the two while the
        /// page is between them.
        var lit: CGFloat
        /// How far it is one of the small ones that say there are more past it: `0` to `1`.
        var small: CGFloat = 0
    }

    /// How far a finger leans the row, of the page's width it has slid the page: never past the
    /// one beside.
    static func leaning(_ progress: CGFloat) -> CGFloat {
        min(1, max(-1, progress))
    }

    /// The row for a page standing at `position` among `total` — a whole number at rest, and
    /// between two while a finger has the page between them. Nothing for fewer than two.
    ///
    /// **Each dot is lit by how near the page is to it**: wholly at its own place, not at all a
    /// whole place away, and in between by the share — so two neighbours are lit between them
    /// by exactly as much as one is at rest, and no third is ever lit. A position past either
    /// end is the end.
    ///
    /// **With more than `most` the row is a window that goes with the page**, by the rule
    /// `dots(position:of:)` places it by, asked of the same position: in the middle of a long
    /// row the window moves under a lit dot that stays where it is, and nothing is seen to
    /// change — which is what it looks like once arrived, too. Near an end the window has
    /// stopped and the lit dot goes on, and the small dot at that end grows as there stops
    /// being anything past it.
    static func drawn(position: CGFloat, of total: Int) -> [Drawn] {
        guard total > 1 else { return [] }
        let count = min(total, most)
        let hidden = CGFloat(total - count)
        let place = min(CGFloat(total - 1), max(0, position))
        let first = min(hidden, max(0, place - CGFloat(most / 2)))
        var row = (0 ..< count).map { Drawn(lit: max(0, 1 - abs(place - first - CGFloat($0)))) }
        row[0].small = min(1, first)
        row[count - 1].small = min(1, hidden - first)
        return row
    }
}

/// Every timeline, one to a row, and under them the two acts: a new one, and changing this one.
/// The rows are `PageListSheet`'s, with the timeline's rules as the row's second line, so a
/// timeline is chosen knowing what it is.
struct TimelineListSheet: View {
    @Bindable var session: ShellSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = session.timelineList
        PageListSheet(
            title: L10n.t("timeline.list.title"),
            entries: list.entries.map { entry in
                PageListEntry(
                    id: entry.id, name: entry.name, brief: entry.rule,
                    symbol: entry.missing ? "circle.dashed" : entry.query.symbol, current: entry.current,
                    hint: entry.missing ? L10n.t("timeline.pill.missing.hint") : nil
                )
            },
            choose: { chosen in
                if let entry = list.entries.first(where: { $0.id == chosen.id }) { session.goToTimeline(entry.query) }
            }
        ) {
            ShellRule().padding(.vertical, ShellSpace.snug)
            if list.offersNew {
                act("plus", "timeline.new.title", .new)
            }
            if list.offersEdit {
                act("pencil", "shortcut.edit", .edit(session.currentTimeline))
            }
        }
    }

    /// An act of the list's: written down with the timeline it was pressed for, and done by
    /// the head when the list has gone (`ShellSession.timelineListDismissed`) — so the editor
    /// it raises is never a sheet asked for over one that is still leaving.
    private func act(_ symbol: String, _ key: String, _ pressed: TimelineList.Act) -> some View {
        Button {
            session.timelineListPressed = pressed
            dismiss()
        } label: {
            ShellListRowFace(title: L10n.t(key), brief: nil, figure: nil, selected: false, mark: Image(systemName: symbol))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
