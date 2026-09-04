import Foundation
import Observation
import FediqoCore

/// Where the reader is standing in their inbox (#122).
///
/// **Deliberately not `FeedPlace`, and this is the one place in the app with two of these.**
/// The ring in a timeline names a `Post` by its merge key, and half of what `FeedPlace` does
/// follows from that: landing the ring on an arriving page, keeping it where the reader left it
/// while older posts are fetched underneath, asking to be scrolled to a post.
///
/// An inbox is none of that. **A notice is not a post** — somebody following you is a notice with
/// no post at all — so the ring here names the notice, and a copy of `FeedPlace` keyed on merge
/// keys would have skipped every follow in the list. And an inbox only ever grows at the top,
/// from a connection nobody asked, so there is no page arriving underneath to land on and nothing
/// to page towards.
///
/// What is left is small enough to be read in one sitting, which is the honest shape: a
/// selection, two ways to move it, and the top.
@MainActor
@Observable
final class NoticePlace {
    /// Which row the ring is on, by `NoticeGroup.id`, or nothing.
    private(set) var selection: String?
    /// Bumped when something asks to be scrolled back to the top, the way the timeline's is.
    private(set) var topRequests = 0

    /// The list the ring is moving through. Handed in on every move rather than held, because
    /// the inbox's list is the model's and a second copy of it here is a second answer to
    /// "what is on the screen".
    private var rows: () -> [NoticeGroup]

    init(rows: @escaping () -> [NoticeGroup]) {
        self.rows = rows
    }

    /// The notice the ring is on, if it is still in the list. A notice can leave — rotation
    /// takes old ones — and a ring pointing at one that has gone is a ring pointing at nothing.
    var selected: NoticeGroup? {
        selection.flatMap { key in rows().first { $0.id == key } }
    }

    func select(_ row: NoticeGroup) {
        selection = row.id
    }

    /// Moves the ring, and says whether it moved. From nothing it lands on the first, whichever
    /// direction was asked for — a reader pressing `k` on a list they have not entered means
    /// "start", not "go back past the beginning".
    @discardableResult
    func move(by steps: Int) -> Bool {
        let list = rows()
        guard !list.isEmpty else { return false }
        guard let key = selection, let at = list.firstIndex(where: { $0.id == key }) else {
            selection = list[0].id
            return true
        }
        let next = at + steps
        guard list.indices.contains(next) else { return false }
        selection = list[next].id
        return true
    }

    func goToTop() {
        selection = rows().first?.id
        topRequests += 1
    }

    /// The ring lets go — the list emptied, or the reader left the page.
    func clear() { selection = nil }
}
