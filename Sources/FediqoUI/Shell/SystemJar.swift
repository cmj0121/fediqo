import Foundation

/// What the system's own stores keep of one source, let go of as the reader signs out of it or
/// removes it (#221).
///
/// **Why there is anything here at all.** A source read without a sign-in is read through the
/// system's shared session, and that session keeps whatever the source hands it: a forum's guest
/// session cookie, and — where a source ever asked the system for a password — a credential kept
/// for it. Neither is the reader's sign-in, but both are a session of some kind this device holds
/// for that source, and signing out or removing leaves none (#221). A signed-in source's own
/// traffic never reaches these stores (`URLSessionClient.signedIn()`); the forum's browser keeps
/// its own, dropped by `ForumSessions.forget(host:)`.
///
/// Matched as a forum's browser records are (`ForumWebEngine.holds`): a cookie's domain belongs to
/// the source when either name is the other or ends in it, so a cookie filed for the registrable
/// domain goes with it — **unless it also belongs to another source still added**: a parent
/// domain's cookie two sources share, or a sub-domain that is a source of its own, stays for the
/// one still being read.
@MainActor
struct SystemJar {
    var cookies: HTTPCookieStorage = .shared
    var credentials: URLCredentialStorage = .shared

    func forget(host raw: String, keeping others: [String]) {
        let host = raw.lowercased()
        let others = others.map { $0.lowercased() }.filter { $0 != host }
        for cookie in cookies.cookies ?? []
        where ForumWebEngine.holds(cookie.domain, for: host)
            && !others.contains(where: { Self.sent(cookie.domain, to: $0) }) {
            cookies.deleteCookie(cookie)
        }
        for (space, kept) in credentials.allCredentials where space.host.lowercased() == host {
            for credential in kept.values {
                credentials.remove(
                    credential, for: space,
                    options: [NSURLCredentialStorageRemoveSynchronizableCredentials: true]
                )
            }
        }
    }

    /// Whether a cookie filed under `domain` goes out with a request to `host`: the host is that
    /// domain, or under it. Narrower than `ForumWebEngine.holds` on purpose — what is kept for
    /// another source is only what that source is actually sent.
    static func sent(_ domain: String, to host: String) -> Bool {
        var name = domain.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
        let host = host.lowercased()
        return !name.isEmpty && (host == name || host.hasSuffix("." + name))
    }
}
