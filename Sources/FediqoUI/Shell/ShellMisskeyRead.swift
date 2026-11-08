import FediqoCore
import Foundation

// A Misskey's local timeline, read as a guest (#486).
//
// Its one read, filed as its public timeline: `r` and the wait land its newest notes, and reading
// it down goes on below the oldest of them with `untilId`, as a Mastodon's public timeline goes
// on with `max_id` (#470). Here rather than beside the Mastodon's, because the files those live in
// draw, and a file that draws is not to learn one more kind of source (#289).

extension ShellReload {
    /// Whether a read for `categories` reaches a Misskey's local timeline, filed as its public
    /// one: the one stretch a guest has.
    static func readsLocal(_ categories: Set<FediqoCore.Category>?) -> Bool {
        categories?.contains(.public) ?? true
    }

    /// The newest of a Misskey's local timeline, landed: **as a Mastodon's public timeline is**
    /// (`readOnPublic`), so reading it down starts over from the oldest of them — an `ingest`
    /// alone would record no place, and a Misskey would never be read on. Asked only where the
    /// timeline reaches `.public`; a reader walking away is not a failure, and anything else is.
    func readMisskey(
        _ stamp: Source, for categories: Set<FediqoCore.Category>?, in session: ShellSession
    ) async -> Bool {
        guard Self.readsLocal(categories) else { return true }
        let host = stamp.host
        do {
            let read = try await localTimeline(of: stamp, in: session).localTimeline(source: stamp)
            try Task.checkCancellation()
            await session.store.landNewest(read, of: .public, ifSourceHere: host)
            return true
        } catch {
            return walkedAway(from: .public, of: host, error)
        }
    }

    /// The stretch of a Misskey's local timeline below `id`.
    func misskey(_ due: Due, before id: String, stamp: Source, in session: ShellSession) async throws {
        guard due.stretch.category == .public else { return }
        // `id` is the raw id the server gave — what `listed` keeps, and so what the place holds —
        // and not the note's own `misskey:<host>:` id, which no Misskey would know.
        let notes = try await localTimeline(of: stamp, in: session).localTimeline(source: stamp, untilID: id)
        try Task.checkCancellation()
        await session.store.landOlder(notes, of: .public, below: id, ifSourceHere: stamp.host)
    }

    /// What a Misskey's local timeline is read through: listed as its public timeline, and ended
    /// within the deadline.
    private func localTimeline(of stamp: Source, in session: ShellSession) -> MisskeyClient {
        session.reach.misskey(stamp.host, for: .timeline, name: .public, within: deadline)
    }
}
