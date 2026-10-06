import SwiftUI

/// The post being read, where there is nothing but a finger (#303): the first row wholly on
/// screen, changing as the list scrolls.
///
/// **A mark and not a selection.** With a keyboard or a pointer a post is selected — walked to,
/// pressed, kept until the reader moves it — and acts are done to it. Under a finger nothing is
/// done to the marked post: a press opens the row it lands on and a mark under a post acts on
/// that post. So this is drawn, by the one row that holds it, and read by nothing else.
///
/// **Held past observation, with a lamp for each row.** The scroll view moves the mark on every
/// row that passes the top. Were it a value the list read, every row on screen would be drawn
/// again each time; and were it the root's selection, the whole shell would. A row reads its
/// own lamp and no other, so a mark that moves redraws two rows: the one that lost it and the
/// one that gained it.
@MainActor
final class ShellReadingMark {
    /// One row's share of the mark: whether it is the one being read.
    @MainActor
    @Observable
    final class Lamp {
        fileprivate(set) var lit = false
    }

    private var lamps: [String: Lamp] = [:]
    /// The row marked, or nothing where the list has no rows on screen.
    private(set) var id: String?

    /// What the list last said of its rows: those wholly on screen, and those at least half on.
    private(set) var whole: [String] = []
    private(set) var visible: [String] = []

    /// The rows of the list in front. The mark is only ever one of them, and only they have lamps.
    private(set) var rows: Set<String> = []

    /// The post a timeline returned to was left at, kept as the one being read **until the
    /// person scrolls**. A post near the end of its list cannot be put at the top, so the first
    /// row wholly on screen is an earlier one; were that marked, it would be the place written
    /// down on the way out, and the place would creep up the list a little with every return.
    private(set) var kept: String?

    /// Whether the person has moved the list by hand since there was last nothing but a finger.
    /// A keyboard that turns up before they have is one that was there all along (`handover`).
    private(set) var used = false

    /// The row that was marked as the list in front became another timeline's, until the
    /// switch that made it so has asked for it. The list says its rows have changed and the
    /// pane says the timeline has, in an order nobody promises: whichever comes first, the post
    /// the timeline was left at is this one.
    ///
    /// **Written down before anything of the new list is heard.** Two timelines can share
    /// posts, and the mark would otherwise settle on one of the arriving list's rows and be
    /// taken for where the last one was left (#305).
    private var departing: String??
    /// Which timeline the rows in front are of, as the list last said.
    private var timeline: String?
    /// The timeline a switch has just asked about and forgotten for, until the list says its
    /// rows are that timeline's: the list coming second must not write the mark down again.
    private var switched: String?

    /// The post the timeline in front was left at, asked once as it is switched away from.
    func left() -> String? {
        defer { departing = nil }
        if let departing { return departing }
        return id
    }

    /// The row a timeline returned to is put back at the top on, until the list has done it.
    var returning: String?
    /// The row handed to the selection as a keyboard was attached, until the list has seen that
    /// change and left it where it is.
    var handed: String?

    /// The lamp `row` reads. Made lit where the row is already the one marked: a lazy list
    /// builds a row long after the mark came to rest on it.
    func lamp(for row: String) -> Lamp {
        if let lamp = lamps[row] { return lamp }
        let lamp = Lamp()
        lamp.lit = row == id
        lamps[row] = lamp
        return lamp
    }

    /// Moves the mark, telling the row that lost it and the row that gained it and no other.
    func mark(_ row: String?) {
        guard row != id else { return }
        if let id { lamps[id]?.lit = false }
        if let row { lamps[row]?.lit = true }
        id = row
    }

    /// Whether the post kept has been on screen since it was kept.
    private var keptSeen = false

    /// Whether a post kept is kept no longer (#308): it has been on screen and is not now.
    /// The person's own scroll lets it go at once (`scrolledByHand`); this is for the list
    /// being moved away from it by something else — the system's press on the top of the
    /// screen, which is no hand on the list — so the mark is never left on a post out of sight.
    nonisolated static func letsGo(kept: String?, seen: Bool, visible: [String]) -> Bool {
        guard let kept, seen, !visible.isEmpty else { return false }
        return !visible.contains(kept)
    }

    private func remark() {
        if let kept, visible.contains(kept) { keptSeen = true }
        if Self.letsGo(kept: kept, seen: keptSeen, visible: visible) {
            kept = nil
            keptSeen = false
        }
        mark(Self.marked(whole: whole, visible: visible, standing: id, kept: kept))
    }

    /// The rows wholly on screen changed.
    func whole(_ reported: [String]) {
        whole = reported.filter(rows.contains)
        remark()
    }

    /// The rows at least half on screen changed.
    func visible(_ reported: [String]) {
        visible = reported.filter(rows.contains)
        remark()
    }

    /// The list in front is these rows. What the mark was told of rows that are not among them
    /// is forgotten, and so are their lamps: a list just replaced can be reported once more
    /// with the rows it had, and a lamp for every row ever drawn would be kept for the session.
    ///
    /// **A lamp of a row that is still here is kept, the object itself** — a row already drawn
    /// holds it, and a new one in its place would be a lamp no row reads.
    func list(_ rows: Set<String>, of timeline: String? = nil) {
        if timeline != self.timeline {
            // Only where the switch has not already asked: it then took the mark as it stood.
            if self.timeline != nil, switched != timeline { departing = .some(id) }
            self.timeline = timeline
        }
        switched = nil
        guard rows != self.rows else { return }
        self.rows = rows
        lamps = lamps.filter { rows.contains($0.key) }
        whole = whole.filter(rows.contains)
        visible = visible.filter(rows.contains)
        if let kept, !rows.contains(kept) { self.kept = nil }
        if let id, !rows.contains(id) { mark(nil) }
        remark()
    }

    /// Another timeline: nothing the last one said of its rows is true of this one's. The lamps
    /// are put out and kept, for `list(_:)` to let go of those whose rows have gone.
    func forget(for timeline: String? = nil) {
        switched = timeline
        kept = nil
        whole = []
        visible = []
        mark(nil)
    }

    /// The post a timeline returned to was left at: marked, and kept so until the person scrolls.
    func keep(_ row: String?) {
        kept = row
        keptSeen = false
        returning = row
        mark(row)
    }

    /// Where a pull to read again has got to (#307). A pull is made with the list at rest at
    /// its top, and what it brings is wanted there: the newest posts shown, not held off above
    /// the post that was first.
    enum Pull: Equatable, Sendable {
        case none
        /// Pulled, and its read still running; `landed` once what it brought has been shown.
        case running(landed: Bool)
        /// Its read ended with nothing shown yet: the next landing is still its own, unless
        /// the person moves the list first.
        case ended
    }

    private(set) var pull = Pull.none

    /// The list was pulled.
    func pulled() { pull = .running(landed: false) }

    /// The pull's read ended.
    func pullSettled() { pull = Self.settled(pull) }

    /// Posts landed. Says whether the list shows the newest of them at its top — a pull's — or
    /// holds the place it was read at, as every other landing does.
    func landing() -> Bool {
        let shows = Self.showsNewest(pull)
        pull = Self.landed(pull)
        return shows
    }

    nonisolated static func showsNewest(_ pull: Pull) -> Bool { pull != .none }

    nonisolated static func landed(_ pull: Pull) -> Pull {
        switch pull {
        case .none, .ended: .none
        case .running: .running(landed: true)
        }
    }

    nonisolated static func settled(_ pull: Pull) -> Pull {
        switch pull {
        case .running(landed: false): .ended
        case .none, .ended, .running(landed: true): .none
        }
    }

    /// The person moved the list by hand: what was kept gives way to what is on screen.
    func scrolledByHand() {
        used = true
        // A pull whose read has ended and brought nothing yet is over once the list is moved.
        if pull == .ended { pull = .none }
        guard kept != nil else { return }
        kept = nil
        remark()
    }

    /// Nothing but a finger again, and the list not yet touched.
    func becameTouch() {
        used = false
    }

    // MARK: - The rules

    /// Which row is marked, of what the list says is on screen, top first.
    ///
    /// **The first wholly on screen.** A row cut by the top of the list is one the reader has
    /// read past or not yet reached; the first whole one is where the eye is. **Where none is
    /// whole** — a post taller than the screen — the row holding the top, which is the first at
    /// least half on. **And where the list says nothing at all**, the mark stays: a row taller
    /// than two screens has nothing whole and nothing half on while its middle goes by.
    ///
    /// **A post kept is the one, whatever is on screen** (`kept`), until the person scrolls.
    nonisolated static func marked(
        whole: [String], visible: [String], standing: String?, kept: String? = nil
    ) -> String? {
        if let kept { return kept }
        if let first = whole.first { return first }
        if let top = visible.first { return top }
        return standing
    }

    /// Whether `row` is drawn as the one being read: the mark's under a finger, the selection's
    /// with a keyboard or a pointer. Never both, so a selection left behind by a press that
    /// opened something is not a second lit row.
    nonisolated static func lit(selected: Bool, marked: Bool, touch: Bool) -> Bool {
        touch ? marked : selected
    }

    /// Whether the list moves to bring a newly selected row into its middle.
    ///
    /// Not under a finger, where a selection is only where a press came from; and not for the
    /// row a keyboard just attached was handed, which is on screen where the reader left it.
    nonisolated static func centres(onSelecting row: String?, touch: Bool, handed: String?) -> Bool {
        guard let row, !touch else { return false }
        return row != handed
    }

    /// What the selection becomes as a keyboard comes or goes.
    ///
    /// **Attached, after the list was moved by hand:** the marked row is the selected one, so
    /// `j` starts from where the reader was reading. **Attached before that:** the selection is
    /// left as it is. An iPad's keyboard is often not reported until a moment after launch, and
    /// a keyboard that was there from the start must select nothing, as a launch with one never
    /// has. **Removed:** nothing is selected — the mark is the list's again, and a selection
    /// nobody can see or move would be a thing acts could be done to by accident.
    nonisolated static func handover(touchNow touch: Bool, marked: String?, used: Bool, selected: String?) -> String? {
        if touch { return nil }
        return used ? marked : selected
    }

    /// Whether a scroll in this phase is the person's own hand on the list, and not the list
    /// being put somewhere.
    nonisolated static func byHand(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .decelerating
    }

    /// The row a list holds at its top when the store renews it under the reader (#175): the
    /// marked row under a finger, so a landing moves neither the lamp nor what it is on; the
    /// row at the top with a keyboard or a pointer, as it was.
    nonisolated static func heldAtTop(top: String?, marked: String?, touch: Bool) -> String? {
        touch ? marked ?? top : top
    }
}

/// A row drawn with its own share of the reading mark, so only this row is drawn again when the
/// mark comes to it or leaves it. With a keyboard or a pointer the lamp is never read, and the
/// row is the selection's as it always was.
struct ReadRow<Row: View>: View {
    let lamp: ShellReadingMark.Lamp
    let touch: Bool
    let selected: Bool
    @ViewBuilder let row: (_ lit: Bool) -> Row

    var body: some View {
        row(touch ? ShellReadingMark.lit(selected: selected, marked: lamp.lit, touch: true) : selected)
    }
}

extension EnvironmentValues {
    /// Whether there is nothing here but a finger: an iPhone or iPad with no hardware keyboard
    /// attached (`ShellHands`). Never on a Mac.
    @Entry var shellTouch: Bool = false
}
