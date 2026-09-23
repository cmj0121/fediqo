import FediqoCore
import Foundation

/// A post its source deleted: kept, marked, and let go on the reader's wait or press (#179).
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
    /// keep-for window (`GoneWait`). Nothing where neither is set. Returns how many went.
    @discardableResult
    func letGoneGo(waitingDays days: Int?, keepingMonths months: Int?, from now: Date = Date()) async -> Int {
        guard let cutoff = GoneWait.cutoff(days: days, keepingMonths: months, from: now).cutoff else {
            return 0
        }
        return await letGoneGo(markedBy: cutoff)
    }

    /// How many posts are marked gone from their source, held aside or not — what the press asks
    /// about before it lets them go.
    func goneHeld() async -> Int {
        await store.goneCount()
    }

    /// Lets go of every post marked gone from its source, now — the reader's press. Returns how
    /// many went, which is what the press says back.
    @discardableResult
    func letAllGoneGo() async -> Int {
        await letGoneGo(markedBy: nil)
    }

    private func letGoneGo(markedBy cutoff: Date?) async -> Int {
        let went = await store.letGoneGo(markedBy: cutoff)
        guard went > 0 else { return 0 }
        await reloadFromStore()
        await persist?()
        return went
    }
}
