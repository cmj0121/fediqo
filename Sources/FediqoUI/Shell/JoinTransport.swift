import FediqoCore
import Foundation

/// A forum's own browser, speaking the language a join understands.
///
/// **Why this exists at all.** Once the reader has signed in to a forum, every read of that host
/// has to go through the engine that holds the session — a cookie jar is not something a
/// `URLSession` may borrow, and D22 is the long form of why. `ForumSessions.transport(host:)`
/// already gives that. What it does not give is a *refusal* the join can act on: it throws
/// `ForumTransportError.wall`, which is not a `DiscuzRequestError`, so `DiscuzBoardJoin.index`
/// files it under `catch { throw JoinError.unreachable }` — and `unreachable` is the one message
/// that sends a reader to check their network when the truth is that a filter turned this app
/// away and signing in is what would change the answer.
///
/// So a wall arrives here as **403**, which is what `DiscuzJoin.refusal` already decides a
/// challenge and a notice page are worth: *"403 is the number that refusal means"*. The rule is
/// not restated — it is handed to the one place that states it, by giving Core an answer it
/// already knows how to read.
///
/// **A wall carries its own status and it is deliberately not used.** A challenge is routinely
/// dressed as a 200 — that is judgement 2 in `DiscuzClient.page`, and the reason it looks at the
/// markup before the number. Passing a challenge's literal 200 through would tell the join "that
/// worked" and leave it hunting for a thread table in an interstitial.
///
/// Everything else the engine can fail with — a name that does not resolve, a TLS failure, a
/// navigation that never finished — is left exactly as it is. Those really are unreachable, and
/// dressing them up as a refusal would offer the reader a sign-in for a host that never answered.
struct ForumJoinTransport: HTTPClient {
    private let inner: any HTTPClient

    init(_ inner: any HTTPClient) {
        self.inner = inner
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await inner.data(from: url)
        } catch let error as ForumTransportError {
            // **No `default:`.** A transport failure falling through to "refused" would offer a
            // sign-in for a host that is simply down, and one falling through to "unreachable"
            // would hide a wall. Every case is named so the next one breaks the build here.
            switch error {
            case .wall:
                guard let refusal = HTTPURLResponse(
                    url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil
                ) else { throw error }
                // No body. There is nothing honest to put in one — the engine handed back a
                // wall rather than a page — and `DiscuzHTML.text` decodes empty bytes to an
                // empty string, so the status is what gets judged, which is the whole point.
                return (Data(), refusal)
            case .wrongHost, .unfetchable, .timedOut, .unreachable, .unreadable:
                throw error
            }
        }
    }
}
