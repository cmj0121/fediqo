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
    @ViewBuilder var marks: Marks

    @Environment(\.colorScheme) private var colorScheme

    private var timeline: TimelineQuery { session.currentTimeline }

    /// A line of the name's writing, near enough: what its finger's reach is worked out from.
    @ShellMetric(relativeTo: .callout) private var drawn: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                name
                standing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            marks
        }
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

    private var name: some View {
        let missing = session.hasMissingRule(timeline)
        return Button {
            guard TimelineList.raises(pressed: session.timelineListPressed, editing: session.editing != nil) else { return }
            session.timelineListShown = true
        } label: {
            HStack(spacing: ShellSpace.tight) {
                Image(systemName: timeline.symbol)
                    .symbolVariant(.fill)
                    .accessibilityHidden(true)
                Text(session.name(of: timeline))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if missing {
                    Image(systemName: "circle.dashed")
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
        .help(L10n.t("timeline.list.hint"))
        .accessibilityLabel(session.name(of: timeline))
        .accessibilityHint(Self.hint(missing: missing))
    }

    /// What VoiceOver adds after the name: that pressing it lists the timelines, and before
    /// that, where a rule has lost its source, that one has. Each a sentence written whole in
    /// its language, so neither is joined by another language's full stop.
    static func hint(missing: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(missing ? "timeline.list.hint.missing" : "timeline.list.hint", language: language)
    }

    @ViewBuilder
    private var standing: some View {
        let rule = session.rule(of: timeline)
        let place = session.timelinePosition
        let dots = place.index.flatMap { TimelineDots.dots(position: $0, of: place.count) }
        HStack(spacing: ShellSpace.snug) {
            if let dots { TimelineDotsRow(dots: dots) }
            Text(rule)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(rule: rule, position: place.index, of: place.count))
    }

    /// The second line as it is heard: the rules, then "2 of 5".
    static func spoken(rule: String, position: Int?, of total: Int, language: DummyLanguage? = nil) -> String {
        guard let position, total > 1 else { return rule }
        return rule + " " + String(format: L10n.t("timeline.position", language: language), position + 1, total)
    }
}

/// The dots themselves. Drawn, never heard: the line they stand in says "2 of 5".
struct TimelineDotsRow: View {
    let dots: TimelineDots

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .caption) private var side: CGFloat = 6

    var body: some View {
        HStack(spacing: side * 0.6) {
            ForEach(0 ..< dots.count, id: \.self) { index in
                Circle()
                    .fill(index == dots.lit ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkFaint(colorScheme))
                    .frame(width: side, height: side)
                    .scaleEffect(dots.fades(index) ? 0.5 : 1)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Every timeline, one to a row, and under them the two acts: a new one, and changing this one.
///
/// **One press on a row goes to that timeline** and the list closes. The rows are the faces
/// every list in the app draws (`ShellListRowFace`), with the timeline's rules as the row's
/// second line, so a timeline is chosen knowing what it is.
struct TimelineListSheet: View {
    @Bindable var session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = session.timelineList
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    ForEach(list.entries) { entry in
                        row(entry)
                    }
                    ShellRule().padding(.vertical, ShellSpace.snug)
                    if list.offersNew {
                        act("plus", "timeline.new.title", .new)
                    }
                    if list.offersEdit {
                        act("pencil", "shortcut.edit", .edit(session.currentTimeline))
                    }
                }
                .padding(ShellSpace.step)
            }
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(L10n.t("timeline.list.title"))
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
        #endif
    }

    private func row(_ entry: TimelineList.Entry) -> some View {
        Button {
            session.goToTimeline(entry.query)
            dismiss()
        } label: {
            ShellListRowFace(
                title: entry.name, brief: entry.rule, figure: nil, selected: entry.current,
                mark: Image(systemName: entry.missing ? "circle.dashed" : entry.query.symbol)
            )
            .background(
                RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
                    .fill(entry.current ? ShellChrome.selectFill(colorScheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.missing ? L10n.t("timeline.pill.missing.hint") : "")
        .accessibilityAddTraits(entry.current ? .isSelected : [])
    }

    /// An act of the list's: written down with the timeline it was pressed for, and done by
    /// the head when the list has gone (`ShellSession.timelineListDismissed`) — so the editor
    /// it raises is never a sheet asked for over one that is still leaving.
    private func act(_ symbol: String, _ key: String, _ pressed: TimelineList.Act) -> some View {
        Button {
            session.timelineListPressed = pressed
            dismiss()
        } label: {
            Label(L10n.t(key), systemImage: symbol)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .padding(.horizontal, ShellSpace.step)
                .padding(.vertical, ShellSpace.snug)
                .frame(maxWidth: .infinity, minHeight: ShellTouchFloor.finger, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
