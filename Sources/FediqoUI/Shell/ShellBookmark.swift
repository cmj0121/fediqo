import FediqoCore
import Foundation

/// A bookmark is kept at the source (#285): the act itself is `toggle(.bookmark, on:)`, beside
/// the boost and the favourite, and the mark is what the source last said, under a press still out. What lives here is the
/// one thing only a bookmark needs — asking a sign-in made before bookmarks were asked for to
/// allow them, **without signing anybody out**.
///
/// It is asked as every part is (`ShellPartAsk`, #347): a question, then the source's own page
/// for what the sign-in holds and bookmarks, and the sign-in the person had left exactly as it
/// was by a page closed, a no on it, or any failure. Allowed, the wider sign-in takes its
/// place here and the one it had stays live at the source until the person signs out.
extension ShellSession {
    /// The press on a row's bookmark mark where its sign-in has to be asked again: raises the
    /// question about the source of the first copy that is true of. Sends nothing. Returns
    /// whether a question was raised.
    @discardableResult
    func askToBookmark(_ item: DummyItem) -> Bool {
        guard let copy = askingCopy(of: item, for: .bookmark) else { return false }
        return askBookmarks(host: copy.source.host)
    }

    /// The bookmark question about `host`, from a post's row and from Account alike. Nothing
    /// where that sign-in is not one to ask — and where its source is being asked for
    /// something already, the press says so (`askFor`).
    @discardableResult
    func askBookmarks(host: String) -> Bool {
        guard mastodon.bookmarks(host: host) == .unasked else { return false }
        return askFor([.bookmarks], host: host)
    }

    /// The source whose sign-in is being asked to allow bookmarks, where one is (#285).
    var bookmarkAsk: String? {
        partAsks.open.flatMap { $0.ticked.contains(.bookmarks) ? $0.host : nil }
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
        if moved { await saveNow(.reader) }
    }
}

extension ShellSession {
    /// What a take-away and a move nearby call before the store is packed: whatever is still due
    /// to be let go of an ended sign-in's reader goes first (#285), and then the store is written,
    /// so no package carries what a source said of somebody who has signed out.
    func saveForCarry() async {
        await forgetReaderMarksDue()
        // Waited for: what is packed next is read from the file this writes.
        await write()
    }
}

extension MastodonSessions {
    /// What a place draws where the bookmark would be (#347), for how the sign-in at `host`
    /// stands to bookmarks — `PartWords.place`, the one reading every place draws from: never
    /// asked, refused on the source's own page, none there, or the source being asked now.
    ///
    /// Nothing where the bookmark is offered, and nothing where bookmarks are not what is
    /// in the way: no sign-in; one that does not act, which has nothing to add them to and
    /// whose row already says to sign in to act; and a source that turned a bookmark away
    /// this run — its sign-in holds bookmarks, so that is no standing, and it is said in its
    /// own words until the next sign-in.
    func bookmarkPlace(host raw: String) -> PartWords.Place? {
        let host = raw.lowercased()
        guard let held = heldParts[host], MastodonParts.holds(.acting, in: held.scopes),
              let standing = standing(.bookmarks, host: host)
        else { return nil }
        return PartWords.place(standing, of: .bookmarks, asking: asking.contains(host))
    }
}

extension ShellSession {
    /// The locks of a row's marks (`ItemActing.locks`): the bookmark's, where the row offers
    /// its other acts and not that one. It is about the source the press asks (`askingCopy`);
    /// where no copy's sign-in can be asked, about the first whose source has none.
    func locks(on item: DummyItem, acts: PostActs) -> [PostAct: ItemActing.Lock] {
        guard !acts.offers(.bookmark), !acts.offered.isEmpty else { return [:] }
        let asked = askingCopy(of: item, for: .bookmark)
        for copy in asked.map({ [$0] }) ?? item.actCopies {
            let host = copy.source.host.lowercased()
            guard let place = mastodon.bookmarkPlace(host: host), asked != nil || place.kind == PartWords.Place.Kind.none else { continue }
            return [.bookmark: ItemActing.Lock(place: place, host: host)]
        }
        return [:]
    }
}
