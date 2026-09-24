import FediqoCore
import Foundation

/// What the system's own stores keep of one source, let go of as the reader signs out of it or
/// removes it (#221).
///
/// **Why there is anything here at all.** A source read without a sign-in is read through the
/// one session every unsigned client shares (`URLSessionClient.memoryOnly`, #219), and that
/// session keeps, in memory for the run, whatever the source hands it: a forum's guest session
/// cookie. It is not the reader's sign-in, but it is a session of some kind this device holds for
/// that source, and signing out or removing leaves none (#221). That session keeps no credential
/// at all, so there is none to drop unless a test hands a store in. A signed-in source's own
/// traffic never reaches this jar (`URLSessionClient.signedIn()`); the forum's browser keeps its
/// own, dropped by `ForumSessions.forget(host:)`. What an older build left in the system's shared
/// stores is emptied once at launch (`SharedStores.forgetOnce`).
///
/// Matched as a forum's browser records are (`ForumWebEngine.holds`): a cookie's domain belongs to
/// the source when either name is the other or ends in it, so a cookie filed for the registrable
/// domain goes with it, even where another source still added shares it: a shared session ends
/// for both. Kept is only what is not sent to this source — a sub-domain that is a source of its
/// own, when its parent goes (`ForumWebEngine.goes`).
@MainActor
struct SystemJar {
    /// The jar the live session actually uses. `memoryOnly` is ephemeral, and an ephemeral
    /// configuration always carries an in-memory jar of its own — hence the `!`; the system's
    /// shared jar is no longer written by anything this app sends.
    var cookies: HTTPCookieStorage = URLSessionClient.memoryOnly.configuration.httpCookieStorage!
    /// Nil in the app: the live session keeps no credentials (`memoryOnlyConfiguration`).
    var credentials: URLCredentialStorage? = URLSessionClient.memoryOnly.configuration.urlCredentialStorage

    func forget(host raw: String, keeping others: [String]) {
        let host = raw.lowercased()
        let others = others.map { $0.lowercased() }.filter { $0 != host }
        for cookie in cookies.cookies ?? []
        where ForumWebEngine.goes(cookie.domain, forgetting: host, keeping: others) {
            cookies.deleteCookie(cookie)
        }
        guard let credentials else { return }
        for (space, kept) in credentials.allCredentials where space.host.lowercased() == host {
            for credential in kept.values {
                credentials.remove(
                    credential, for: space,
                    options: [NSURLCredentialStorageRemoveSynchronizableCredentials: true]
                )
            }
        }
    }
}
