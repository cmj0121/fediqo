import FediqoCore
import Foundation

// A source's public timeline, read as the reader where signed in there (#283).
//
// A source may keep its public timeline for signed-in readers — g0v.social and mastodon.social
// answer an ask without a token 422, "This method requires an authenticated user", every time.
// So every read of it — `r` and the wait reading on, an ask for more, a place reached and read
// down — goes through the reader's sign-in where one is held there that reads, and is then the
// reader's own read, ended by a sign-out as Home is. Unsigned, it is asked as it always was.
//
// **A reload's read of it catches up** (`MastodonReadOn.read`'s `catchingUp`): a busy server's
// public timeline outruns reading on, so its newest stretch is read too at the bound.

extension ShellReload {
    /// The public timeline read on from the newest id it listed, and landed with what it says
    /// about where it is not whole. A reader walking away is not a failure; anything else is.
    ///
    /// **As the reader where signed in** (`publicReader`), and ended by a sign-out as every read
    /// as the reader is. A source that reads it only to a signed-in reader, asked by one who is
    /// not, is said in the log in those words: its Trends may still come, and a join takes such a
    /// source as one with a timeline of its own closed (`MastodonJoin`).
    func readOnPublic(_ client: MastodonClient, stamp: Source, in session: ShellSession) async -> Bool {
        let host = stamp.host
        let reader = publicReader(client, of: host, in: session)
        do {
            let store = session.store
            let read = try await asReader(host, if: reader.asYou) {
                let anchor = await store.newestListedID(host: host, category: .public)
                let held = anchor == nil ? await store.held(host: host, category: .public) : []
                return try await reader.client.publicTimeline(
                    source: stamp, readingOnFrom: anchor, holding: held, catchingUp: true
                )
            }
            try Task.checkCancellation()
            await session.store.land(read, of: .public, ifSourceHere: host)
            // What came before a stretch that failed has landed; the read still did not come back.
            guard let stopped = read.stopped else { return true }
            _ = walkedAway(from: .public, of: host, stopped)
            return false
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            noteSignedOut(.public, of: host)
            return false
        } catch {
            if !reader.asYou, MastodonClient.asksSignIn(error) {
                noteUnread(.public, of: host, error)
                NetLog.network.notice(
                    "\(NetLog.line("public timeline asks a sign-in", host: host, category: .public, error: error), privacy: .public)"
                )
                return false
            }
            return walkedAway(from: .public, of: host, error)
        }
    }

    /// What reads `host`'s public timeline: `client`, through the reader's sign-in where one is
    /// held there that reads (`MastodonSessions.readsTimelines`) — a source may keep that timeline
    /// for signed-in readers — and as it is otherwise. `asYou` is whether it reads as the reader.
    func publicReader(
        _ client: MastodonClient, of host: String, in session: ShellSession
    ) -> (client: MastodonClient, asYou: Bool) {
        guard session.mastodon.readsTimelines(host: host), let token = session.mastodon.token(host: host) else {
            return (client, false)
        }
        let door = session.mastodon.authorized(token: token, within: deadline, for: .timeline, name: .public)
        return (client.reading(as: door), true)
    }

    /// `read`, as the reader's (`asReader`) where `asYou`, so a sign-out ends it; as it is
    /// otherwise.
    func asReader<T: Sendable>(
        _ host: String, if asYou: Bool, _ read: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        asYou ? try await asReader(host, read) : try await read()
    }
}
