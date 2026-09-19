import FediqoCore
import Foundation
import Observation
import WebKit

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
public final class ForumSessions {
    /// Where a saved password lives. Injected so that a test never touches the real Keychain —
    /// see `ForumCredentialStore`.
    @ObservationIgnored let credentials: any ForumCredentialStore

    @ObservationIgnored private var engines: [String: ForumWebEngine] = [:]
    @ObservationIgnored private let makeStore: () -> WKWebsiteDataStore
    @ObservationIgnored private var madeStore: WKWebsiteDataStore?
    @ObservationIgnored private var watcher: CookieWatcher?
    /// The forums among the reader's sources: the hosts `reachedHosts` is asked about.
    @ObservationIgnored private var forumHosts: Set<String> = []
    /// Bumped by every read of the cookie store, so a read that started before a Clear cannot
    /// land after it and put back a sign-in the Clear took away.
    @ObservationIgnored private var readings = 0
    /// Hosts this run saw a sign-in reached on, by the forum's own page and not by a cookie
    /// name — so a forum whose session cookie is not `*_auth` still reads signed in until a
    /// forget, and falls back to the cookie rule after a relaunch.
    @ObservationIgnored private var witnessed: Set<String> = []

    /// Which hosts have a password saved, as a fact a view body may read.
    ///
    /// **Held rather than asked for.** A SwiftUI body runs on every frame that touches it and a
    /// Keychain lookup is a trip into another process; a pane that asked per row per body would
    /// be doing that dozens of times a second to draw one line of text. Refreshed where it can
    /// change — a save, a forget, a Clear — which is three places, all of them here.
    private(set) var savedHosts: Set<String> = []

    /// Which of the reader's forums this device holds a member's session for.
    ///
    /// **A view of the cookie store, not a list kept beside it.** A second record of one fact
    /// disagrees with the first the moment either changes without the other — a Clear that lands
    /// while a launch is still reading, a Clear of one forum that takes a sibling on the same
    /// registrable domain with it, a forum added after launch. So this is recomputed from the
    /// store whenever the store says its cookies changed, whenever the set of forums changes, and
    /// after every forget. And a member's session cookie specifically, not any cookie: every
    /// forum this app has read holds a guest's (`ForumMember.isSessionCookie(named:)`).
    ///
    /// **Plus what this run witnessed.** A sign-in reached here — the automatic path's verdict, or
    /// the reader closing the forum's page having got there — counts until a forget, whatever
    /// the forum named its cookie; the cookie rule is only what survives a relaunch.
    ///
    /// **The store's change notification is a hint only.** The reads that keep this true are the
    /// ones on a change of sources, a sign-in and a forget; see `CookieWatcher`.
    ///
    /// It is still only **as far as this device can see**. A forum can end a session on its own
    /// side without telling anybody, and the next read simply comes back signed out; a row
    /// drawing "Sign out" from this is saying "this device holds your sign-in", which is true.
    ///
    /// **Neither existing question answers this one — decision 13, and both were checked.**
    /// `hasPassword(host:)` is about what the Keychain holds: a reader can be signed in by cookie
    /// having saved nothing, and can have a password saved while signed out. `hasEngine(host:)` is
    /// about what this run built: an engine exists the moment the reader is *offered* a sign-in,
    /// including the case where they looked at the forum's page and gave up.
    private(set) var reachedHosts: Set<String> = []

    /// `dataStore` is where every engine keeps its cookies, and is not built until a forum is
    /// among the sources or a browser is asked for: a reader with no forum never opens the
    /// store. The default forgets its cookies when this object goes, which is what a test wants;
    /// the app passes the one kept on this device (`ForumWebsiteData.onDevice()`).
    public init(
        credentials: any ForumCredentialStore = KeychainCredentials(),
        dataStore: @autoclosure @escaping () -> WKWebsiteDataStore = .nonPersistent()
    ) {
        self.credentials = credentials
        self.makeStore = dataStore
        refreshSavedHosts()
    }

    var dataStore: WKWebsiteDataStore {
        if let madeStore { return madeStore }
        let made = makeStore()
        let watcher = CookieWatcher { [weak self] in
            Task { await self?.readReached() }
        }
        made.httpCookieStore.add(watcher)
        self.watcher = watcher
        madeStore = made
        return made
    }

    /// The forums among the reader's sources. Handed over whenever the sources change; the first
    /// non-empty set is what opens the store.
    func watch(forums hosts: [String]) {
        let hosts = Set(hosts.map { $0.lowercased() })
        guard hosts != forumHosts else { return }
        forumHosts = hosts
        Task { await readReached() }
    }

    /// Recomputes `reachedHosts` from the store, and returns with the latest answer in place.
    ///
    /// A read overtaken by a later one — a Clear landing while the launch is still reading —
    /// does not apply what it saw, which is from before; it reads again. So nothing stale is
    /// ever written, and every caller, overtaken or not, returns with a current answer.
    func readReached() async {
        readings += 1
        while true {
            let reading = readings
            guard !forumHosts.isEmpty else {
                if reachedHosts != witnessed { reachedHosts = witnessed }
                return
            }
            let cookies = await dataStore.httpCookieStore.allCookies()
            guard reading == readings else { continue }
            let sessions = cookies.filter { ForumMember.isSessionCookie(named: $0.name) }
            let reached = forumHosts.filter { host in
                sessions.contains { ForumWebEngine.holds($0.domain, for: host) }
            }.union(witnessed)
            // Assigned only when it differs: every row reading this redraws on an assignment.
            if reached != reachedHosts { reachedHosts = reached }
            return
        }
    }

    func engine(host: String) -> ForumWebEngine {
        let host = host.lowercased()
        if let held = engines[host] { return held }
        let made = ForumWebEngine(host: host, dataStore: dataStore)
        engines[host] = made
        return made
    }

    /// What F1 hands to a reader built against a host. See `ForumWebTransport`.
    func transport(host: String) -> any HTTPClient {
        ForumWebTransport(engine: engine(host: host))
    }

    /// Whether this run has a browser for that host at all, without making one. Lets Clear and
    /// the Usage pane ask without quietly starting a web process per server listed.
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

    /// Whether this device has seen a sign-in reached on that host — **signed in as far as this
    /// device can see**, and no further. See `reachedHosts` for why that is the honest ceiling.
    func reachedSignIn(host: String) -> Bool {
        reachedHosts.contains(host.lowercased())
    }

    /// A sign-in was reached on the forum's own page this run. See `witnessed`.
    func recordSignIn(host: String) {
        witnessed.insert(host.lowercased())
        reachedHosts.insert(host.lowercased())
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
        engines.removeValue(forKey: host.lowercased())?.stopAndBlank()
        // No engine this run is no evidence of no cookies: the store persists, and a host signed
        // in to last launch holds its session before anything asks for its page. A store never
        // built this run holds nothing this run could have put there, and is left unopened.
        if let madeStore { await ForumWebEngine.forget(host: host, in: madeStore) }
        forgetPassword(host: host)
        witnessed.remove(host.lowercased())
        // The cookies have just gone, so what the row says goes with them — for this host and
        // for any sibling whose records WebKit filed under the same domain. Decision 13 puts it
        // here on purpose: Clear and Remove both arrive through this one door.
        await readReached()
    }

    func refreshSavedHosts() {
        savedHosts = (try? credentials.savedHosts()) ?? []
    }
}


/// Tells `ForumSessions` the store's cookies changed. A class of its own because the protocol
/// wants an `NSObject`, and `ForumSessions` is not one.
///
/// **A nudge, not the mechanism.** Outside an app — a command-line probe, `swift test` — WebKit
/// was seen not to deliver this for cookies set through `setCookie`, so nothing correct rests
/// on it: every place this app knows a cookie changed (a sign-in, a sheet closing, a forget, the
/// forums changing) reads the store itself. What this adds is the change nobody here caused, a
/// forum ending a session on a page it served.
private final class CookieWatcher: NSObject, WKHTTPCookieStoreObserver {
    let changed: @MainActor () -> Void

    init(_ changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in changed() }
    }
}
