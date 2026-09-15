import FediqoCore
import Foundation
import Observation

/// Why an automatic sign-in stopped and handed the reader the forum's own page.
///
/// **Every one of these is normal.** D24: a browser check that escalates to something
/// interactive, a verification code after failed attempts, and a security question are three
/// ordinary things a forum does, and a client that reports them as errors is a client that tells
/// the reader something is broken when nothing is. They are reasons to show a page, and the
/// sentence each one puts under that page is the whole of what they are for.
public enum ForumSignInStop: Equatable, Sendable {
    /// Nothing is saved for this host, so the first sign-in is the reader's. D23.
    case noCredential
    /// Something in front of the forum wants the reader present.
    case wall(ForumWall)
    /// The forum is asking for a verification code.
    case captcha
    /// This account has a security question, which no stored password answers.
    case question
    /// The forum said no, in its own words where it gave any.
    case refused(String?)
    /// The answer was a page this code cannot read either way.
    case unreadable
    /// The forum did not answer at all.
    case unreachable

    /// The line drawn under the web view. Named here rather than at the call site so that a new
    /// stop cannot be added without somebody deciding what the reader is told about it — the
    /// switch is exhaustive and the compiler asks.
    var explanationKey: String {
        switch self {
        case .noCredential: "forum.stop.first"
        case .wall: "forum.stop.wall"
        case .captcha: "forum.stop.captcha"
        case .question: "forum.stop.question"
        case .refused: "forum.stop.refused"
        case .unreadable: "forum.stop.unreadable"
        case .unreachable: "forum.stop.unreachable"
        }
    }

    /// The forum's own sentence, where it sent one. Shown beside this app's, never instead of
    /// it: a stranger's server's words go on their own line and are not this app talking.
    var forumSaid: String? {
        if case .refused(let message) = self { return message }
        return nil
    }

    /// One of each, for the harness that checks every stop has a sentence in every language.
    ///
    /// **Not `CaseIterable`, because two of these carry a value** — and a list somebody has to
    /// remember is exactly the shape this branch wrote down as a convention it had to learn
    /// twice. What holds it together is that `explanationKey` above is an exhaustive switch: a
    /// new stop does not compile until somebody decides what the reader is told about it, and the
    /// test below then fails until the sentence exists in all three bundles. This list is the
    /// third step, and it is the one a person has to take.
    static let allKinds: [ForumSignInStop] = [
        .noCredential,
        .wall(ForumWall(sort: .challenge, status: 403)),
        .captcha,
        .question,
        .refused(nil),
        .unreadable,
        .unreachable,
    ]
}

public enum ForumSignInOutcome: Equatable, Sendable {
    case signedIn
    case handOver(ForumSignInStop)
}

/// What the sheet is open for.
struct ForumSignInRequest: Identifiable, Equatable {
    let host: String
    let stop: ForumSignInStop
    var id: String { host }
}

/// Every forum this run is signed in to, one browser each.
///
/// Host-scoped throughout: an engine, its cookies and its saved password are all addressed by
/// host and nothing here is shared between two forums. That is not tidiness — a shared engine
/// would send one forum's session to another, and a shared credential store scope would hand the
/// wrong password to the wrong site.
@MainActor
@Observable
final class ForumSessions {
    /// Where a saved password lives. Injected so that a test never touches the real Keychain —
    /// see `ForumCredentialStore`.
    @ObservationIgnored let credentials: any ForumCredentialStore

    @ObservationIgnored private var engines: [String: ForumWebEngine] = [:]

    /// Which hosts have a password saved, as a fact a view body may read.
    ///
    /// **Held rather than asked for.** A SwiftUI body runs on every frame that touches it and a
    /// Keychain lookup is a trip into another process; a pane that asked per row per body would
    /// be doing that dozens of times a second to draw one line of text. Refreshed where it can
    /// change — a save, a forget, a Clear — which is three places, all of them here.
    private(set) var savedHosts: Set<String> = []

    init(credentials: any ForumCredentialStore = KeychainCredentials()) {
        self.credentials = credentials
        refreshSavedHosts()
    }

    func engine(host: String) -> ForumWebEngine {
        let host = host.lowercased()
        if let held = engines[host] { return held }
        let made = ForumWebEngine(host: host)
        engines[host] = made
        return made
    }

    /// What F1 hands to a reader built against a host. See `ForumWebTransport`.
    func transport(host: String) -> any HTTPClient {
        ForumWebTransport(engine: engine(host: host))
    }

    /// Whether this run has a browser for that host at all, without making one. Lets Clear and
    /// the Preferences pane ask without quietly starting a web process per server listed.
    func hasEngine(host: String) -> Bool {
        engines[host.lowercased()] != nil
    }

    // MARK: - Signing in

    /// Signs in from the saved credential, or says why the reader has to.
    ///
    /// The order is the order the facts arrive in and it cannot be rearranged: there is no point
    /// reading a login form off a browser check, and no point filling a form that is asking for
    /// something a stored password does not contain.
    func signIn(host: String) async -> ForumSignInOutcome {
        let host = host.lowercased()
        guard let credential = try? credentials.credential(host: host), credential.isComplete else {
            return .handOver(.noCredential)
        }
        let engine = engine(host: host)
        guard let url = engine.loginURL else { return .handOver(.unreachable) }

        let page: ForumPage
        do {
            page = try await engine.page(at: url)
        } catch let error as ForumTransportError {
            if case .wall(let wall) = error { return .handOver(.wall(wall)) }
            return .handOver(.unreachable)
        } catch {
            return .handOver(.unreachable)
        }

        guard case .content(let html) = page else {
            if case .wall(let wall) = page { return .handOver(.wall(wall)) }
            return .handOver(.unreadable)
        }
        // Already signed in — a run that signed in a moment ago and asked again. Answering
        // "signed in" here rather than posting the form is what stops a refresh from spending a
        // sign-in attempt, which is how a forum's lockout counter gets reached by an app nobody
        // touched.
        if ForumMember.isSignedIn(html) { return .signedIn }

        guard let form = ForumLoginForm.read(html) else { return .handOver(.unreadable) }
        if form.asksCaptcha { return .handOver(.captcha) }
        guard form.canFillItself else { return .handOver(.unreadable) }

        let verdict: ForumLoginVerdict
        do {
            verdict = try await engine.submitLogin(credential)
        } catch {
            return .handOver(.unreachable)
        }

        switch verdict {
        case .signedIn: return .signedIn
        case .needsCaptcha: return .handOver(.captcha)
        case .needsQuestion: return .handOver(.question)
        case .refused(let said): return .handOver(.refused(said))
        case .unreadable: return .handOver(.unreadable)
        }
    }

    /// Reads what the reader typed into the forum's own form and keeps it — **only** when they
    /// have said so. See `ForumWebEngine.typedCredential`.
    @discardableResult
    func saveTyped(host: String) async -> Bool {
        guard let credential = await engine(host: host).typedCredential() else { return false }
        do {
            try credentials.save(credential)
            refreshSavedHosts()
            return true
        } catch {
            // Deliberately silent about what failed. A Keychain refusal is an `OSStatus` and
            // nothing else worth a reader's time, and an error path is the likeliest place for a
            // secret to escape into a log.
            return false
        }
    }

    func forgetPassword(host: String) {
        try? credentials.forget(host: host.lowercased())
        refreshSavedHosts()
    }

    func hasPassword(host: String) -> Bool {
        savedHosts.contains(host.lowercased())
    }

    // MARK: - Clearing

    /// D25: everything this host left here goes, including the cookies and the saved password.
    ///
    /// **This is heavier than decision 14 describes and it should be said out loud.** Decision 14
    /// is "Clear empties; it does not remove" — the server stays added and the pictures come back
    /// as they are wanted. A password does not come back: the reader types it again. Dropping it
    /// here is what D25 asks for, and the reason is the one D25 gives — a password left behind
    /// for a server nobody is reading any more is the kind of thing nobody finds again. The
    /// screen is what makes that fair: the row says a password is held before the button is
    /// pressed, and there is a Forget of its own for the reader who wants only that.
    func forget(host: String) async {
        let host = host.lowercased()
        if let engine = engines[host] {
            await engine.forget()
            engines[host] = nil
        }
        forgetPassword(host: host)
    }

    func refreshSavedHosts() {
        savedHosts = (try? credentials.savedHosts()) ?? []
    }
}
