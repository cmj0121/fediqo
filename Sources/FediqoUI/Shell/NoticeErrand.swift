import FediqoCore
import Foundation

/// A walk begun from the notices page (#323): which line was pressed, and how deep the timeline
/// place's walk stood before the step.
///
/// **A notice opens by walking in the timeline place.** A conversation and somebody's page are
/// drawn there and nowhere else, so the press moves the reader there, takes one step, and
/// remembers this — and leaving the last step it took puts them back on Notices, on the line
/// they pressed. Whatever the walk held before the errand is under it, untouched.
struct NoticeErrand: Hashable, Sendable {
    /// The line pressed, by its id.
    let notice: String
    /// How many steps the walk held before this one.
    let base: Int

    /// One step from Notices, on the walk as it stands. `lamp` is the timeline's own lamp,
    /// handed back when the step is left.
    ///
    /// **Nothing where the walk already stands on `step`**: no step was taken, so there is none
    /// to come back by. That step is the timeline's own, and leaving it is leaving it there.
    static func setOut(
        to step: ShellStep, for notice: String, on walk: inout ShellWalk, lamp: String?
    ) -> NoticeErrand? {
        let base = walk.depth
        guard walk.walk(to: step, from: lamp) else { return nil }
        return NoticeErrand(notice: notice, base: base)
    }

    /// Whether every step the errand took has been left.
    func isOver(_ walk: ShellWalk) -> Bool {
        walk.depth <= base
    }
}

extension ShellSession {
    /// The post a notice is about, held as a thread's posts are held — through the store, saved,
    /// and what is drawn renewed from it — and the row it now is. **Held on opening and not
    /// before**: a favourite of an old post does not put that post in a timeline unasked.
    ///
    /// Nothing where the store would not take it: a post older than the person keeps, which a
    /// conversation cannot open from. The page says so on the line.
    func landed(noticePost note: Note) async -> String? {
        let row = note.key.rowID
        if heldNote(row) == nil {
            await store.ingest([note], ifSourceHere: note.source.host)
            await persist?()
            await reloadFromStore()
        }
        return heldNote(row) == nil ? nil : row
    }
}
