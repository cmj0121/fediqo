import AuthenticationServices
import FediqoCore
import Foundation
import Observation
import SwiftUI

/// Every Mastodon this device is signed in to.
///
/// **Signed in is "a token is in the Keychain for that host"** and nothing else — no store
/// column, no flag beside it. `signedInHosts` is that fact held for view bodies to read, refreshed
/// at the three places it can change: a sign-in saved, a sign-out, and a server ending one.
@MainActor
@Observable
public final class MastodonSessions {
    @ObservationIgnored let tokens: any MastodonTokenStore
    @ObservationIgnored let sender: any HTTPSender
    /// Bumped per host by every sign-out, so a sign-in still on the server's page when the source
    /// is cleared or removed does not save the token it comes back with.
    @ObservationIgnored private var signOuts: [String: Int] = [:]

    private(set) var signedInHosts: Set<String> = []
    /// Hosts that ended a sign-in on their own side, not yet told to the reader.
    private(set) var ended: [String] = []

    public init(
        tokens: any MastodonTokenStore = KeychainMastodonTokens(),
        sender: any HTTPSender = URLSessionClient.signedIn()
    ) {
        self.tokens = tokens
        self.sender = sender
        refresh()
    }

    func isSignedIn(host: String) -> Bool {
        signedInHosts.contains(host.lowercased())
    }

    /// Signs in on the server's own page and keeps the token. Nothing where it worked, or where the
    /// reader closed the page or said no there; otherwise why it did not.
    ///
    /// **One registration per host.** The app is registered the first time and the registration
    /// kept, so signing out and in again does not leave a trail of apps on the reader's account.
    /// It is dropped — and the next attempt registers afresh — where the server rejects it at
    /// the token exchange or its page answers `invalid_scope`, where it was made for other scopes
    /// than this build asks for, or where a sign-in through it ends with the page closed: a server that
    /// no longer knows the client shows an error page with no way back, and closing it is the
    /// only thing the reader can do there.
    func signIn(host raw: String, through browser: any OAuthBrowser) async -> MastodonSignInError? {
        let host = raw.lowercased()
        let before = signOuts[host, default: 0]
        let oauth = MastodonOAuth(host: host, sender: sender)
        var kept = (try? tokens.app(host: host)) ?? nil
        // A registration made for other scopes than this build asks for is made again: the
        // server would refuse the page with `invalid_scope`.
        if let app = kept, app.scopes != MastodonOAuth.scopes {
            try? tokens.forgetApp(host: host)
            kept = nil
        }
        let token: MastodonToken
        do {
            let app: MastodonApp
            if let kept {
                app = kept
            } else {
                app = try await oauth.register()
                if signOuts[host, default: 0] == before { try? tokens.save(app) }
            }
            token = try await oauth.signIn(as: app, through: browser)
        } catch let error as MastodonSignInError {
            if error == .clientRejected || error == .invalidScope || (kept != nil && error == .cancelled) {
                try? tokens.forgetApp(host: host)
            }
            return error == .cancelled || error == .denied ? nil : error
        } catch {
            return .unreachable
        }
        guard signOuts[host, default: 0] == before else {
            await oauth.revoke(token)
            return nil
        }
        do {
            try tokens.save(token)
        } catch {
            await oauth.revoke(token)
            return .keychain
        }
        refresh()
        return nil
    }

    /// The token leaves this device first; then the server is asked to forget it, and whatever it
    /// answers changes nothing here.
    ///
    /// **This signs the app out, not the browser.** The sign-in page ran in the shared Safari
    /// session (decision 9), so the reader stays signed in to the server's website in Safari, and
    /// the next sign-in here can be one tap. Signing out of the website is Safari's business.
    ///
    /// `forgettingApp` drops the app registration too — Clear and Remove, after which nothing of
    /// this source's sign-in is left on the device. A plain sign-out keeps it for next time.
    func signOut(host raw: String, forgettingApp: Bool = false) async {
        let host = raw.lowercased()
        signOuts[host, default: 0] += 1
        let token = (try? tokens.token(host: host)) ?? nil
        try? tokens.forget(host: host)
        if forgettingApp { try? tokens.forgetApp(host: host) }
        refresh()
        if let token {
            await MastodonOAuth(host: host, sender: sender).revoke(token)
        }
    }

    /// The door a signed-in request goes through, or nothing where no token can be read.
    /// `within` puts a deadline on each request — a reload's (#29).
    func authorized(host: String, within limit: Duration? = nil) -> MastodonAuthorized? {
        guard let token = (try? tokens.token(host: host)) ?? nil else { return nil }
        let wire: any HTTPSender = limit.map { Deadline(sender, within: $0) } ?? sender
        return MastodonAuthorized(token: token, sender: wire, store: tokens)
    }

    /// A request answered `.signedOut`: the token is already gone, so the row and the reader are
    /// told.
    func endedByServer(host raw: String) {
        let host = raw.lowercased()
        refresh()
        if !ended.contains(host) { ended.append(host) }
    }

    /// At launch: asks each server whether it still honours its token. Only a 401 signs out; a
    /// server that cannot be reached leaves the sign-in as it was.
    public func verifyAll() async {
        for host in signedInHosts.sorted() {
            guard let door = authorized(host: host) else { continue }
            do {
                _ = try await door.get(path: "/api/v1/accounts/verify_credentials")
            } catch MastodonAuthError.signedOut {
                endedByServer(host: host)
            } catch {}
        }
    }

    func endedSeen() {
        ended = []
    }

    /// Reads who is signed in again. Also asked when the app comes to the front: a Keychain read
    /// at launch on a locked device finds nothing, and that is not a sign-out.
    func refresh() {
        let hosts = (try? tokens.signedInHosts()) ?? []
        if hosts != signedInHosts { signedInHosts = hosts }
    }
}

/// The system's web authentication sheet, in the shared Safari session (decision 9): a reader
/// already signed in to their server in Safari is one tap from done.
///
/// **The cost of that, accepted in decision 9:** the server's web session outlives an app
/// sign-out. Signing out here forgets the token and revokes it; the reader is still signed in to
/// the website in Safari, and a second account on the same server means signing out there first.
struct WebAuthBrowser: OAuthBrowser {
    let session: WebAuthenticationSession

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(
                using: url,
                callback: .customScheme(callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw MastodonSignInError.cancelled
        } catch {
            // The sheet could not be shown or could not finish: the row's generic sentence.
            throw MastodonSignInError.unreadable
        }
    }
}
