import AuthenticationServices
import FediqoCore
import Foundation
import Observation
import SwiftUI

/// Every Mastodon this device is signed in to.
///
/// **Signed in is "a token is in the Keychain for that host"** and nothing else — no store
/// column, no flag beside it. `grants` is that fact held for view bodies to read — who, and what
/// their sign-in bought (#69) — refreshed at the three places it can change: a sign-in saved, a
/// sign-out, and a server ending one.
@MainActor
@Observable
public final class MastodonSessions {
    @ObservationIgnored let tokens: any MastodonTokenStore
    @ObservationIgnored let sender: any HTTPSender
    /// Where each request this makes is shown while it runs (#164). The app's own; a test hands
    /// in another.
    @ObservationIgnored var work: SourceWork = .shared
    /// Bumped per host by every sign-out, so a sign-in still on the server's page when the source
    /// is cleared or removed does not save the token it comes back with.
    @ObservationIgnored private var signOuts: [String: Int] = [:]

    /// What each signed-in host's sign-in bought (#69) — **and, by its keys, who is signed in at
    /// all.**
    ///
    /// **Read from the items' attributes and never from a token**, which is what keeps the source
    /// page free of a Keychain access prompt per row — see `MastodonTokenStore.grants()`. A host
    /// with no entry is one this device holds no sign-in for at all.
    private(set) var grants: [String: MastodonGrant] = [:]

    /// Which hosts this device holds a sign-in for. **Derived and not stored beside `grants`**, so
    /// that "who is signed in" and "what their sign-in bought" cannot come to disagree by one of
    /// two assignments being forgotten — the store answers them in one query and this answers them
    /// from one value.
    var signedInHosts: Set<String> { Set(grants.keys) }

    /// Hosts that ended a sign-in on their own side, not yet told to the reader.
    private(set) var ended: [String] = []

    /// Hosts whose last write was turned away, until they are signed in again — cleared by a
    /// sign-in and by a sign-out, which are the two acts that replace what a write would use.
    private(set) var writeRefused: Set<String> = []

    /// Who the reader is on each signed-in host, as `@user@host`, **as that source said this run**
    /// (#109) — what tells a post the reader wrote from one they did not.
    ///
    /// **Asked, never kept.** It is learnt from the account check at launch and after a sign-in,
    /// and dropped with the sign-in, so a second account signed in on the same host is never
    /// handed the first one's posts to take back. A host not yet answered has no entry, and
    /// then nothing there is offered for taking back — the safe side of not knowing.
    private(set) var handles: [String: String] = [:]

    /// Hosts whose account check found the network dark (#222) — a launch with no network, most
    /// often — and so are asked again as soon as a read gets through to them, rather than going
    /// unknown until a relaunch. `learnWhoAgain(among:)` is that second ask.
    @ObservationIgnored private var unlearned: Set<String> = []

    public init(
        tokens: any MastodonTokenStore = KeychainMastodonTokens(),
        sender: any HTTPSender = URLSessionClient.signedIn()
    ) {
        self.tokens = tokens
        self.sender = sender
        refresh()
    }

    func isSignedIn(host: String) -> Bool {
        grants[host.lowercased()] != nil
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
    ///
    /// **A server that refuses `read:search`** (Decision 32) is asked once more, on a
    /// registration made without it and kept with the scopes it was made for, so each later
    /// sign-in reuses it rather than registering again. Only finding an old post again needs
    /// search; the thread says so and asks for a sign-in again.
    ///
    /// **`writing` is the reader's own answer and is never assumed** (#69). It decides what the
    /// server's page asks for and what the registration is made for, and it is written down with
    /// the token. `false` asks for exactly the scopes this app asked for before it could write at
    /// all, so refusing the writing part leaves reading as it was, down to the string.
    ///
    /// **A registration made for the other answer is not reused**: a page asking to write on a
    /// registration made for reading is `invalid_scope`, so the choice changing means registering
    /// again. A server that refuses the writing part outright fails the sign-in and says so —
    /// it is **never** quietly retried for reading alone, because a reader who asked to write
    /// and was handed a read-only sign-in without being told has been answered for.
    ///
    /// **What that reader actually sees, said plainly:** a server that refuses the writing part
    /// answers `invalid_scope`, which is indistinguishable here from a server that refuses
    /// `read:search`, so decision 32's one retry runs first — the reader is sent to the server's
    /// page a second time, on a registration that drops `read:search` and still carries the
    /// writing part, and is refused there too before the sign-in fails and says so. Two pages for
    /// one refusal. Telling the two apart needs something the callback does not carry.
    ///
    /// **A sign-in made while a token is already held replaces it here and revokes it there**
    /// (#69). `tokens.save` is delete-then-add, so the superseded token would otherwise stay live
    /// on the server — and a reader narrowing their answer from writing back to reading would
    /// have left a write-capable grant behind, which is the opposite of what they just asked for.
    func signIn(
        host raw: String, through browser: any OAuthBrowser, writing: Bool = false
    ) async -> MastodonSignInError? {
        let host = raw.lowercased()
        let before = signOuts[host, default: 0]
        let oauth = MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: .signIn, in: work))
        var kept = (try? tokens.app(host: host)) ?? nil
        // A registration made for scopes this sign-in does not ask for is made again: the server
        // would refuse the page with `invalid_scope`.
        let asked = MastodonOAuth.known(writing: writing)
        if let app = kept, !asked.contains(app.scopes ?? "") {
            try? tokens.forgetApp(host: host)
            kept = nil
        }
        // The one ladder, from the one place that owns it: what this answer registers for, and
        // what it falls back to where the server refuses `read:search`.
        let (wide, narrow) = MastodonOAuth.registrations(writing: writing)
        let token: MastodonToken
        do {
            let app: MastodonApp
            if let kept {
                app = kept
            } else {
                app = try await oauth.register(scopes: wide)
                if signOuts[host, default: 0] == before { try? tokens.save(app) }
            }
            do {
                token = try await oauth.signIn(as: app, through: browser)
            } catch MastodonSignInError.invalidScope where app.scopes == wide {
                try? tokens.forgetApp(host: host)
                kept = nil
                let narrower = try await oauth.register(scopes: narrow)
                if signOuts[host, default: 0] == before { try? tokens.save(narrower) }
                token = try await oauth.signIn(as: narrower, through: browser)
            }
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
        // The token this one supersedes, read before `save` deletes it.
        let superseded = (try? tokens.token(host: host)) ?? nil
        do {
            try tokens.save(token)
        } catch {
            await oauth.revoke(token)
            return .keychain
        }
        // **After the new one is safely kept, and never a token with the same string**: what is
        // held now is what a write will use, and revoking it would sign the reader out of a
        // sign-in the row says they have. The keychain arm above leaves the superseded token
        // alone for the same reason — nothing there knows whether it is still the one held.
        if let superseded, superseded.accessToken != token.accessToken {
            await oauth.revoke(superseded)
        }
        // A fresh sign-in is a fresh answer from the server about what this device may do, so
        // whatever it turned away before this is spent.
        writeRefused.remove(host)
        handles[host] = nil
        refresh()
        // Who the reader is matters only to taking back what they wrote, which needs the writing
        // part — so a sign-in that did not buy it asks nothing more than it always did.
        if grants[host] == .writing { await learnWho(host: host) }
        return nil
    }

    /// Asks the source who the reader is on it (#109). Silent on any failure: not knowing offers
    /// nothing for taking back, which is the one safe answer, and a 401 is told as `verifyAll`
    /// tells it.
    func learnWho(host raw: String, within limit: Duration? = nil) async {
        let host = raw.lowercased()
        unlearned.remove(host)
        guard let door = authorized(host: host, within: limit, for: .signInCheck) else { return }
        do {
            let handle = try await door.handle()
            if isSignedIn(host: host) { handles[host] = handle }
        } catch MastodonAuthError.signedOut {
            endedByServer(host: host)
        } catch where DarkNetwork.caused(error) {
            if isSignedIn(host: host) { unlearned.insert(host) }
        } catch {}
    }

    /// Asks who the reader is again on each of `hosts` whose last account check the network was
    /// dark for (#222). A reload calls it with the hosts it just read, so the network coming back
    /// is noticed by the first read that gets through; a host asked and answered is not asked
    /// again, and one never dark is never asked here at all.
    func learnWhoAgain(among hosts: Set<String>, within limit: Duration) async {
        let due = unlearned.intersection(hosts.map { $0.lowercased() })
        // Claimed before the first await, so two reloads landing together ask each host once.
        unlearned.subtract(due)
        for host in due.sorted() {
            await learnWho(host: host, within: limit)
        }
    }

    /// A write this source turned away (#69). The row says so and keeps saying it until the source
    /// is signed in again — **it does not sign the reader out**, because reading is untouched by
    /// it and a 403 is not a revoked token.
    func refusedWrite(host raw: String) {
        writeRefused.insert(raw.lowercased())
    }

    /// What may be done on one source, from what its sign-in bought and what it has refused since.
    ///
    /// **The one place the three facts meet**, so the row, its spoken sentence and anything that
    /// later asks whether a write may be attempted read one answer rather than three derivations
    /// of it.
    func writing(host raw: String, kind: ProtocolKind) -> SourceWriting {
        let host = raw.lowercased()
        return SourceWriting.of(
            kind: kind, grant: grants[host], refused: writeRefused.contains(host)
        )
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
        do {
            try tokens.forget(host: host)
        } catch {
            // The token is still in the Keychain, so the row still reads signed in — `refresh`
            // reads it back rather than claiming a sign-out that did not happen. The server is
            // still asked to forget it.
            NetLog.auth.error("\(NetLog.line("sign-out", host: host, error: error), privacy: .public)")
        }
        if forgettingApp { try? tokens.forgetApp(host: host) }
        writeRefused.remove(host)
        handles[host] = nil
        refresh()
        if let token {
            await MastodonOAuth(host: host, sender: WatchedHTTP(sender: sender, for: .signOut, in: work))
                .revoke(token)
        }
    }

    /// The door a signed-in request goes through, or nothing where no token can be read.
    /// `within` puts a deadline on each request — a reload's (#29). `purpose` is what each request
    /// through it is shown as while it runs (#164): only the caller knows what it is for — and,
    /// where it reads one timeline, which, by the name the reader knows it by (#170).
    func authorized(
        host: String, within limit: Duration? = nil, for purpose: SourceWork.Purpose,
        name: SourceWork.Name? = nil
    ) -> MastodonAuthorized? {
        guard let token = token(host: host) else { return nil }
        return authorized(token: token, within: limit, for: purpose, name: name)
    }

    /// The token kept for a host, or nothing where none can be read. One Keychain read, for a
    /// caller about to build several doors with `authorized(token:within:for:name:)`.
    func token(host: String) -> MastodonToken? {
        (try? tokens.token(host: host)) ?? nil
    }

    /// A door through a token already read — `authorized(host:within:for:name:)` without the
    /// Keychain, so a reload building one door per timeline reads the token once.
    func authorized(
        token: MastodonToken, within limit: Duration? = nil, for purpose: SourceWork.Purpose,
        name: SourceWork.Name? = nil
    ) -> MastodonAuthorized {
        let watched = WatchedHTTP(sender: sender, for: purpose, name: name, in: work)
        let wire: any HTTPSender = limit.map { Deadline(watched as any HTTPSender, within: $0) } ?? watched
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
    /// server that cannot be reached leaves the sign-in as it was, and is asked again by the first
    /// read that reaches it (`learnWhoAgain`).
    ///
    /// **The same answer says who the reader is there** (#109), so asking it is not a second
    /// request: `learnWho` reads the account check's own body.
    public func verifyAll() async {
        for host in grants.keys.sorted() {
            await learnWho(host: host)
        }
    }

    func endedSeen() {
        ended = []
    }

    /// Reads who is signed in again. Also asked when the app comes to the front: a Keychain read
    /// at launch on a locked device finds nothing, and that is not a sign-out.
    func refresh() {
        // **One query, one value, and it reads no token** — see `MastodonTokenStore.grants()`. Who
        // is signed in is this dictionary's keys, so a row can never draw a sign-in this object
        // does not also have a grant for.
        let grants = (try? tokens.grants()) ?? [:]
        if grants != self.grants { self.grants = grants }
        // Who the reader is goes with the sign-in it was learnt through.
        let kept = handles.filter { grants[$0.key] != nil }
        if kept != handles { handles = kept }
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
