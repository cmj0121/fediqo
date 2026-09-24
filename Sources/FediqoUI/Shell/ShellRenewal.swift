import FediqoCore
import Foundation

// An opened post reads its thread at once, and the thread renews itself while it stays open — #198.
//
// **At once, for every source.** A Mastodon conversation was already asked for as its pane opened
// (#90); a forum topic showed its opening post alone until the reader pressed for the replies
// (D31). Both now read as the pane opens: the topic's kept replies are drawn, and where it kept
// none its first page is asked for with no press.
//
// **Again, on the wait this device keeps** (#95) — its one clock, and not a second one for
// threads. Each time the wait's sources have been asked, the thread in front of each window is
// asked again: a conversation read again, a topic's last page read again. What that brings lands
// in the store first, and the thread draws from what the store holds — a topic its replies, a
// conversation each of its posts (`ShellConversations.renew(from:)`) — so an answer edited, or
// marked gone from its source, by any read shows in the open thread with no key pressed. New
// replies are laid in where they belong; what is drawn stays where it is, and so does the lamp.
//
// **Said where the thread says what it is doing** — at its foot, not in the toast: a renewal on
// its way is the foot's "on its way", and one that did not arrive is the foot's failure, with
// everything already drawn still above it.
//
// **Only the thread in front, and only while it is.** Leaving it takes it off the wait and ends a
// renewal still on the wire. Nor beside another ask of the same thread or the same sources: not
// while `r` reads the thread, the timeline or its next stretch — a stranger's forum is never asked
// in parallel — and never twice at once; `r` on the thread or the timeline ends one on the wire.
// Esc does not stop it, as it does not stop the wait.

extension ShellReload {
    /// The pane of `item` opening: in front from now, and its thread read at once — a topic's kept
    /// replies drawn and its first page asked for where none were kept, a conversation asked for.
    func opened(_ item: DummyItem, in session: ShellSession) async {
        inFront = item
        if let ref = ForumThreadRef(item) {
            await session.posts.open(ref)
        } else if DiscuzBlogRow.isBlog(item.noteID) {
            // A ranked blog's page, read now that the reader has opened it (#209) — and not again
            // where this device already holds what it said.
            await session.blogs.open(item)
        } else {
            await session.conversations.open(item, in: session)
            // A thread read earlier this run, drawn from what is held now.
            if inFront?.id == item.id { session.renewConversation() }
            // A quote post kept before quotes were read, read again so its quote shows (#214).
            if inFront?.id == item.id { await readQuoteIfHeldBefore(item, in: session) }
        }
    }

    /// The pane of `item` gone: no longer in front, and a renewal of it still on the wire ended.
    /// Only its own: a reply's thread opened from inside it may be in front by now, whichever of
    /// the two panes the platform told first.
    func left(_ item: DummyItem) {
        if inFront?.id == item.id { inFront = nil }
        if renewing == item.id { end(.renew) }
    }

    /// The thread in front of this window, asked again — a round of the wait (#198). Nothing with
    /// no thread in front, or beside another ask of it or of its sources.
    ///
    /// **Once a round, however many windows have it open**: `asked` is what this round asked
    /// already, and a thread in it is drawn again from what that ask landed instead of asked a
    /// second time. Returns the thread this window renewed, or nothing.
    @discardableResult
    func renew(in session: ShellSession, asked: Set<String> = []) async -> String? {
        guard let item = inFront, session.editing == nil else { return nil }
        // A thread from a source that has since been removed is not asked again, however long the
        // pane stays up (#221).
        let host = item.source.host.lowercased()
        guard session.sources.contains(where: { $0.host == host }) else { return nil }
        // A blog has no thread to renew — no replies this app reads (#209) — and its page is read
        // when the reader asks, never on the wait: the points guard's rule, one step on.
        guard !DiscuzBlogRow.isBlog(item.noteID) else { return nil }
        guard !asked.contains(item.id) else {
            if let ref = ForumThreadRef(item) {
                await session.posts.redraw(ref)
            } else {
                await session.conversations.redraw(item, in: session)
            }
            return nil
        }
        guard asking.isDisjoint(with: [.renew, .thread, .timeline, .more]) else { return nil }
        renewing = item.id
        defer { renewing = nil }
        await run(.renew) {
            if let ref = ForumThreadRef(item) {
                await session.posts.renew(ref)
            } else {
                await session.conversations.renew(item, in: session)
            }
        }
        return item.id
    }
}
