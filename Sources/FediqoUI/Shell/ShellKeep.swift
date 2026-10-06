import FediqoCore
import Foundation

/// What the person keeps (#284): an item kept is never let go — by a limit, by a letting go, or
/// by its source being removed — until they un-keep it.
///
/// **The mark is the store's and nothing here draws it.** A row carries `kept` from the note it
/// was built from, as it carries `goneSince` (`ShellGone`), so the timeline, a thread, a search
/// and a person's page all draw it off the one fact. What lives here is the one way it is moved
/// from the session. Nothing is sent to any source, so there is no sign-in to ask for, nothing
/// on its way and nothing to fail.
extension ShellSession {
    /// Keeps `item`, or un-keeps it, and writes it down where it was. Adopted at once rather than
    /// left for the store's change notice, so the screen that asked is the screen that shows it.
    /// Returns whether anything changed: nothing does where the store holds no copy of the row.
    ///
    /// **Every copy of a row two sources carried** (#114): the row is one post to the person who
    /// kept it, and a copy left out would go with its source's limit and take the row's picture
    /// of itself with it. A copy laid into an open thread is laid in again as it now is.
    @discardableResult
    func setKept(_ kept: Bool, on item: DummyItem) async -> Bool {
        var moved = false
        for copy in item.copies {
            let key = NoteKey(host: copy.source.host, id: copy.noteID)
            guard await store.setKept(kept, for: key) else { continue }
            moved = true
            if let held = await store.note(key) { conversations.replace(held) }
        }
        guard moved else { return false }
        await reloadFromStore()
        await persist?()
        return true
    }

    /// Stops keeping every post kept, or every one from `host` — a source here or one removed
    /// (#294). Returns what that did. One act: the store is changed once, adopted once and
    /// written down once, however many posts.
    ///
    /// **Lets nothing go.** Each post is an ordinary one from here, and the next limit or letting
    /// go may take it. A copy laid into an open thread is laid in again as it now is.
    ///
    /// **One source's copies and no other's.** A post two sources carry is kept while either
    /// copy is, so un-keeping this source's leaves it kept through the other — and that is said
    /// (`StoppedKeeping.elsewhere`) rather than undone here: the other source's copies are that
    /// source's, and the act that reaches them is the one for every source.
    @discardableResult
    func stopKeeping(host: String?) async -> StoppedKeeping {
        let folded = host?.lowercased()
        let elsewhere = folded.map(holdings.keptElsewhere(host:)) ?? 0
        let keys = (notes + heldReplies).filter { $0.kept && (folded == nil || $0.key.host == folded) }.map(\.key)
        let stopped = await store.stopKeeping(host: host)
        guard stopped > 0 else { return StoppedKeeping() }
        for held in await store.notes(keys).values { conversations.replace(held) }
        await reloadFromStore()
        await persist?()
        return StoppedKeeping(ordinary: max(0, stopped - elsewhere), elsewhere: min(stopped, elsewhere))
    }

    /// The press on the keep mark, and `y`: keeps a row not kept, un-keeps one that is. Returns
    /// what the row now is, or nothing where the store took nothing.
    ///
    /// **Says what happened, here**, in the timeline's one sentence — so the mark and the key are
    /// one act with one outcome, and the line is said only once the store has taken the change,
    /// never ahead of the mark.
    @discardableResult
    func toggleKept(_ item: DummyItem) async -> Bool? {
        let kept = !item.kept
        guard await setKept(kept, on: item) else { return nil }
        showToast(L10n.t(kept ? "item.toast.kept.on" : "item.toast.kept.off"))
        return kept
    }
}

/// What stopping keeping did (#294): how many posts are ordinary posts now, and how many of the
/// copies un-kept are of posts still kept through another source's copy.
struct StoppedKeeping: Equatable, Sendable {
    var ordinary = 0
    var elsewhere = 0
}
