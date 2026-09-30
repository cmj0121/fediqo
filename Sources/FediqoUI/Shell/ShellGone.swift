import FediqoCore
import Foundation

/// A post its source deleted: kept, marked, and let go on the reader's wait or press (#179).
/// A place in a timeline whose source no longer has what lay there is let go the same way (#204):
/// its mark goes, and the post it sits by stays.
///
/// **The mark is the store's and nothing here draws it.** A row carries `goneSince` from the note
/// it was built from, so the timeline, a thread, a search and a person's page all mark it by
/// the one fact — none of them asks a second question of its own. What lives here is the two
/// ways a mark is set or acted on from the session: a read that heard the source say so, and a
/// letting go.
extension ShellSession {
    /// One post, marked as gone from its source, and written down where it was. Adopted at once
    /// rather than left for the store's change notice, so the screen that asked is the screen that
    /// shows it.
    func markGone(_ key: NoteKey, at moment: Date = Date()) async {
        guard await store.markGone(key, at: moment) else { return }
        await reloadFromStore()
        await persist?()
    }

    /// Whether `error`, from reading `held` by its server id `id`, is its source saying it no longer
    /// has it — `MastodonPost.saysGone`, and where that is only a question, the same id asked again
    /// with no token, within `limit`. **The one rule** `r` on a thread and a thread opening both go
    /// by, so neither marks a post the other would not.
    func sourceSaysGone(
        _ error: any Error, of held: Note, id: String, signedIn: Bool, within limit: Duration
    ) async -> Bool {
        switch MastodonPost.saysGone(error, about: held, signedIn: signedIn) {
        case .gone: return true
        case .no: return false
        case .ask:
            let watched = WatchedHTTP(http, for: .conversation, in: work)
            let unsigned = MastodonPost(
                http: Deadline(watched as any HTTPClient, within: limit), host: held.source.host
            )
            return await unsigned.confirmsGone(held, id: id)
        }
    }

    /// Lets go of what this device's wait says has waited long enough — the shorter of it and the
    /// keep-for window (`GoneWait`). Nothing where neither is set. Returns what went: the posts,
    /// and the places a read down settled (#204), which go by the same wait.
    @discardableResult
    func letGoneGo(waitingDays days: Int?, keepingMonths months: Int?, from now: Date = Date()) async -> WentGone {
        guard let cutoff = GoneWait.cutoff(days: days, keepingMonths: months, from: now).cutoff else {
            return WentGone()
        }
        return await letGoneGo(markedBy: cutoff)
    }

    /// What is marked gone from its source, held aside or not — the posts, and the places whose
    /// source no longer has what lay there (#204). What the press asks about before it lets go.
    func goneHeld() async -> WentGone {
        WentGone(posts: await store.goneCount(), places: await store.settledCount())
    }

    /// Lets go of everything marked gone from its source, now — the reader's press. Returns what
    /// went, which is what the press says back.
    @discardableResult
    func letAllGoneGo() async -> WentGone {
        await letGoneGo(markedBy: nil)
    }

    /// The posts first: a place on a post that goes goes with it, and is not counted twice.
    private func letGoneGo(markedBy cutoff: Date?) async -> WentGone {
        let posts = await store.letGoneGo(markedBy: cutoff)
        let went = WentGone(posts: posts, places: await store.letSettledGo(markedBy: cutoff))
        guard !went.isNone else { return went }
        await reloadFromStore()
        await persist?()
        await readStoreBytes()
        return went
    }
}

/// What is marked gone from its source, counted (#179, #204): posts, and the places in a timeline
/// whose source no longer has what lay there. Counted apart, so what the press says stays true.
struct WentGone: Equatable, Sendable {
    var posts = 0
    var places = 0

    var isNone: Bool { posts == 0 && places == 0 }
}
