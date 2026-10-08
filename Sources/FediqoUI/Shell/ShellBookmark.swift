import AuthenticationServices
import FediqoCore
import Foundation
import SwiftUI

/// A bookmark is kept at the source (#285): the act itself is `toggle(.bookmark, on:)`, beside
/// the boost and the favourite, and the mark is what the source last said, under a press still out. What lives here is the
/// one thing only a bookmark needs — asking a sign-in made before bookmarks were asked for to
/// allow them, **without signing anybody out**.
///
/// The sign-in it asks for is the ordinary one to read and act (`signIn(host:through:writing:)`),
/// which already copes with a host that holds a token: the new token replaces it here, the one it
/// supersedes is revoked at the server, and a reader who closes the server's page still has the
/// sign-in they had. Nothing is widened until the reader has said yes twice — to the question
/// here, and on the source's own page.
extension ShellSession {
    /// The press on a row's bookmark mark where its sign-in has to be asked again: raises the
    /// question about the source of the first copy that is true of. Sends nothing. Returns
    /// whether a question was raised.
    @discardableResult
    func askToBookmark(_ item: DummyItem) -> Bool {
        guard let copy = askingCopy(of: item, for: .bookmark) else { return false }
        bookmarkAsk = copy.source.host
        return true
    }

    /// The question answered no: everything stays as it was.
    func cancelBookmarkAsk() {
        if let bookmarkAsk { noticesSaid[bookmarkAsk.lowercased()] = nil }
        bookmarkAsk = nil
    }

    /// The question answered yes: the source's own page, asking for reading, acting and
    /// bookmarks.
    ///
    /// **Only while that sign-in is still one to ask** — one that acts, was made before bookmarks
    /// were asked for, and has not been asked since. A question left open over a source that was
    /// signed out, narrowed to reading or already answered asks nothing: this press is never the
    /// way a sign-in comes to write.
    ///
    /// **What it says afterwards is what is true.** The sign-in the reader had is still held and
    /// still does everything it did, whatever happened on the page — so a failure is "bookmarks
    /// were not allowed", never "the sign-in failed", and a source with none to give is said to
    /// have none. A page closed says nothing, as any sign-in's does.
    ///
    /// `noticesSaid` is what the question said of notices (`SignInAsked`): said to carry none,
    /// the page asks for none.
    func allowBookmarks(host raw: String, through browser: any OAuthBrowser, noticesSaid said: Bool? = nil) async {
        cancelBookmarkAsk()
        let host = raw.lowercased()
        guard mastodon.bookmarks(host: host) == .unasked else { return }
        if rowRefusal?.host == host { rowRefusal = nil }
        let failure = await mastodon.signIn(host: host, through: browser, writing: true, noticesSaid: said)
        await forgetReaderMarksDue()
        if let failure {
            NetLog.auth.notice("\(NetLog.line("bookmarks", host: host, error: failure), privacy: .public)")
            if isAdded(host) { rowRefusal = (host: host, key: "account.bookmarks.failed") }
            showToast(L10n.t("account.bookmarks.failed"))
            return
        }
        if mastodon.isSignedIn(host: host) { await readAsYou(host: host) }
        if mastodon.bookmarksRefused.contains(host) {
            showToast(L10n.t("account.bookmarks.unavailable"))
        }
    }

    /// Lets go of what a source said a reader had done to its posts — boosted, favourited,
    /// bookmarked — for every source whose reader is no longer that one (#285): signed out, ended
    /// by the server, cleared, or signed in to as somebody not shown to be the same. And once a
    /// run, for every source nobody is signed in to, which is what a store written before this
    /// existed may still hold.
    ///
    /// **Those words were said to one reader.** Left on the rows they would ride every package
    /// and every move, and be told to the next account on that host — whose first press on a
    /// filled mark would undo an act they never made. The posts stay, and so does `kept`, which
    /// is this device's own. A signed-in read says them again.
    ///
    /// **Asked for wherever a sign-in ends or changes, and not left to the next read of the
    /// store**: right after a sign-out, a Clear or a Remove, after a sign-in and before its first
    /// read, and before a take-away or a move nearby saves the store (`saveForCarry`).
    ///
    /// **One at a time, and a caller is past every one begun before it.** Who changed is
    /// taken once, by whichever call comes first, and that call waits for the write; a second
    /// call arriving meanwhile — a sign-out's own, while a server-ended sign-in's sweep is in
    /// flight and has taken its host too — would otherwise find nothing left to do and say it
    /// was done while the first was still writing. Nothing to do is still no wait at all.
    func forgetReaderMarksDue() async {
        while let running = readerSweep {
            await running.value
            // Whoever is first past it lets go of it: a finished sweep answers at once, and
            // left standing would be waited on for ever by a caller that never gives way.
            if readerSweep == running { readerSweep = nil }
        }
        let changed = mastodon.takeReadersChanged().sorted()
        let first = !readerMarksSwept && mastodon.grantsKnown
        guard !changed.isEmpty || first else { return }
        let sweep = Task { await forgetReaderMarks(of: changed) }
        readerSweep = sweep
        await sweep.value
        if readerSweep == sweep { readerSweep = nil }
    }

    private func forgetReaderMarks(of changed: [String]) async {
        var moved = false
        for host in changed {
            if await store.forgetReaderMarks(host: host) { moved = true }
            // What the source said happened to that reader is theirs alone too (#323).
            noticeList.forget(host: host)
            // And so is what that reader pressed, and what was said of what they asked of it.
            acts.forget(host: host)
            said.forget(host: host)
            // The reader of this source changed (#293). Gone — signed out, or ended by the
            // server — its line of loads is dropped, as the reader's own sign-out drops it.
            // Signed in — again, or as somebody new — the source is asked again from the start.
            if mastodon.isSignedIn(host: host) {
                await loads.readmit(host: host)
                await store.unstall(host: host)
            } else {
                await loads.letGo(host: host)
                refs.letGo(host: host)
            }
        }
        // Only once who is signed in could be read: a locked Keychain is not everybody leaving.
        if !readerMarksSwept, mastodon.grantsKnown {
            readerMarksSwept = true
            if await store.forgetReaderMarks(keeping: mastodon.signedInHosts) { moved = true }
        }
        // Before any read for whoever signs in next can land: its first stretch is written
        // under the epoch the letting go left (`ShellNoticeList.learnEpochs`).
        await noticeList.learnEpochs()
        // Waited for: what a source said of a reader who has left is not on disk a moment
        // longer than it is in the store (#285, #292).
        if moved { await persist?() }
    }
}

extension ShellSession {
    /// What a take-away and a move nearby call before the store is packed: whatever is still due
    /// to be let go of an ended sign-in's reader goes first (#285), and then the store is written,
    /// so no package carries what a source said of somebody who has signed out.
    func saveForCarry() async {
        await forgetReaderMarksDue()
        // Waited for: what is packed next is read from the file this writes.
        await persist?()
    }
}

/// Bookmarks, asked of a source already signed in to act — a modifier, so the root's chain gains
/// one plain call and no presenter closure of its own. On the root, because the question is put
/// from a post's row and from Account alike, and one presenter answers both.
struct BookmarkQuestion: ViewModifier {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let session: ShellSession

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: question) { ask, _ in
            Task {
                await session.allowBookmarks(
                    host: ask.host, through: WebAuthBrowser(session: webAuthenticationSession), noticesSaid: ask.notices
                )
            }
        }
    }

    private func question(_ ask: SignInAsked) -> ShellConfirmation {
        session.bookmarkQuestion(host: ask.host)
    }

    private var asked: Binding<SignInAsked?> {
        Binding(get: { session.bookmarkAsk.map(session.signInAsked) }, set: { if $0 == nil { session.cancelBookmarkAsk() } })
    }
}
