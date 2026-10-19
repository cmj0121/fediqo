import Foundation

/// A walk begun from a place that is not the timeline's: which place the press was made on,
/// which line of it where it has lines, and how deep the timeline place's walk stood before
/// the step.
///
/// **A conversation and somebody's page are drawn in the timeline place and nowhere else.** So a
/// press that opens one from another place — a line of Notices (#323), "Your page there" on
/// Account (#310) — moves the reader there, takes one step, and remembers this; and leaving the
/// last step it took puts them back on the place they pressed, on the line they pressed where
/// there was one. Whatever the walk held before the errand is under it, untouched.
///
/// **One errand for every such press**: a notice's is this from `.notices` with its line.
struct PlaceErrand: Hashable, Sendable {
    /// The place the press was made on, and the one come back to.
    let from: ShellPlace
    /// The line pressed, by its id, where the place has lines: a notice's.
    let line: String?
    /// How many steps the walk held before this one.
    let base: Int

    /// One step from `place`, on the walk as it stands. `lamp` is the timeline's own lamp,
    /// handed back when the step is left.
    ///
    /// **Nothing where the walk already stands on `step`**: no step was taken, so there is none
    /// to come back by. That step is the timeline's own, and leaving it is leaving it there.
    /// And nothing from a stream place itself — the timeline, Trends — where a step is only a
    /// step of that place's own walk.
    static func setOut(
        to step: ShellStep, from place: ShellPlace, line: String? = nil, on walk: inout ShellWalk, lamp: String?
    ) -> PlaceErrand? {
        guard !place.isStream else { return nil }
        let base = walk.depth
        guard walk.walk(to: step, from: lamp) else { return nil }
        return PlaceErrand(from: place, line: line, base: base)
    }

    /// Whether every step the errand took has been left.
    func isOver(_ walk: ShellWalk) -> Bool {
        walk.depth <= base
    }
}
