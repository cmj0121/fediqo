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
    @ObservationIgnored private let dataStore: WKWebsiteDataStore

    /// Which hosts have a password saved, as a fact a view body may read.
    ///
    /// **Held rather than asked for.** A SwiftUI body runs on every frame that touches it and a
    /// Keychain lookup is a trip into another process; a pane that asked per row per body would
    /// be doing that dozens of times a second to draw one line of text. Refreshed where it can
    /// change — a save, a forget, a Clear — which is three places, all of them here.
    private(set) var savedHosts: Set<String> = []

    /// Which hosts a sign-in was confirmed reached on **as far as this device last saw**.
    ///
    /// That qualifier is the whole of what this can promise, and saying less than it out loud
    /// would be a control that lies. A forum's cookie expires without telling anybody: nothing
    /// asks this app, nothing arrives to say so, and the next read simply comes back signed out.
    /// So this is a record of the last thing this device witnessed, never a claim about the
    /// session's present state — and a row drawing "Sign out" from it is saying "you signed in
    /// here", which is true, rather than "you are signed in here", which nobody can know without
    /// asking the forum.
    ///
    /// **Neither existing question answers this one — decision 13, and both were checked.**
    /// `hasPassword(host:)` is about what the Keychain holds: a reader can be signed in by cookie
    /// having saved nothing, and can have a password saved while signed out. `hasEngine(host:)` is
    /// about what this run built: an engine exists the moment the reader is *offered* a sign-in,
    /// including the case where they looked at the forum's page and gave up.
    public private(set) var reachedHosts: Set<String> = []

    /// `dataStore` is where every engine keeps its cookies. The default forgets them when this
    /// object goes, which is what a test wants; the app passes `deviceDataStore()`.
    public init(
        credentials: any ForumCredentialStore = KeychainCredentials(),
        dataStore: WKWebsiteDataStore = .nonPersistent()
    ) {
        self.credentials = credentials
        self.dataStore = dataStore
        refreshSavedHosts()
    }

    /// Reads which of `hosts` the store still holds a member's session for, and counts those as
    /// reached — the launch half of `reachedHosts`.
    ///
    /// **Read off the store, not off a list this app wrote.** A list kept beside the cookies is
    /// a second record of one fact, and the two disagree the moment either changes without the
    /// other: a cookie expires, a Clear half-finishes, a file is restored. The store is the
    /// thing a fetch will actually send, so it is the only honest answer to "will this forum
    /// treat me as signed in". And a session cookie specifically, not any cookie: every forum
    /// this app has read holds a guest's (`ForumMember.isSessionCookie(named:)`).
    ///
    /// Adds and never removes, so a sign-in reached while this was reading is not undone by it.
    public func restoreSignIns(among hosts: [String]) async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        for host in hosts.map({ $0.lowercased() }) {
            let held = cookies.contains { cookie in
                ForumMember.isSessionCookie(named: cookie.name)
                    && ForumWebEngine.holds(cookie.domain, for: host)
            }
            if held { reachedHosts.insert(host) }
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

    /// Whether this device has seen a sign-in reached on that host — **signed in as far as this
    /// device last saw**, and no further. See `reachedHosts` for why that is the honest ceiling.
    func reachedSignIn(host: String) -> Bool {
        reachedHosts.contains(host.lowercased())
    }

    /// One was reached. Recorded rather than inferred, because the only two things that can see it
    /// happen are the automatic sign-in below and the reader closing the forum's own page having
    /// got there.
    func recordSignIn(host: String) {
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
        let host = host.lowercased()
        if let engine = engines[host] {
            await engine.forget()
            engines[host] = nil
        } else {
            // No engine this run is no evidence of no cookies: the store persists, and a host
            // signed in to last launch holds its session before anything asks for its page.
            await ForumWebEngine.forget(host: host, in: dataStore)
        }
        forgetPassword(host: host)
        // The cookies this run signed in with have just gone, so what this device last saw is no
        // longer true of anything it holds. Decision 13 puts the clearing here on purpose: Clear
        // and Remove both arrive through this one door, so neither can leave a row offering to
        // sign a reader out of a session that no longer exists.
        reachedHosts.remove(host)
    }

    func refreshSavedHosts() {
        savedHosts = (try? credentials.savedHosts()) ?? []
    }
}

// MARK: - The store on this device

extension ForumSessions {
    /// Stable id for this app's cookie store on this device.
    static let storeID = UUID(uuidString: "66656469-7171-4000-8000-000000000005")!

    /// The cookie store the app signs in with: kept on this device between launches, and kept
    /// out of its backups.
    ///
    /// **Out of backups because the issue says the secret stays on this device** (#5). A forum
    /// session cookie is a bearer credential; restored onto another device it signs that device
    /// in as the reader, which is the one thing the password beside it is kept from by
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. WebKit offers no switch for this, so the
    /// directory is marked by hand before WebKit opens it — see `storeDirectory` for where it is
    /// and why that is an observed path rather than a documented one. A failure to mark it is
    /// not a reason to refuse the store: the reader would be signed out every launch instead,
    /// which is worse, and the mark is retried every launch.
    public static func deviceDataStore() -> WKWebsiteDataStore {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = storeDirectory(
            library: library,
            identifier: storeID,
            sandboxed: isSandboxed,
            bundleID: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        )
        try? excludeFromBackup(directory)
        return WKWebsiteDataStore(forIdentifier: storeID)
    }

    /// Where `WKWebsiteDataStore(forIdentifier:)` keeps its files.
    ///
    /// **Observed, not documented.** Apple names no path for this store. What WebKit does, and
    /// what was checked on macOS 26 against this app's container and a bare command-line
    /// process: inside a sandbox — every iOS app and the sandboxed Mac app — it is
    /// `Library/WebKit/WebsiteDataStore/<id>`; outside one, WebKit adds the bundle identifier (or
    /// the process name) after `WebKit`. WebKit takes a directory made and marked beforehand
    /// as its own and the mark survives it writing cookies there. If a later WebKit moves the
    /// store, this marks an empty directory and the store goes back to being backed up — which
    /// is why the test pins the path and not only the mark.
    static func storeDirectory(library: URL, identifier: UUID, sandboxed: Bool, bundleID: String) -> URL {
        var directory = library.appendingPathComponent("WebKit", isDirectory: true)
        if !sandboxed { directory.appendPathComponent(bundleID, isDirectory: true) }
        return directory
            .appendingPathComponent("WebsiteDataStore", isDirectory: true)
            // WebKit spells the id in lower case; `uuidString` is upper case, and on a
            // case-sensitive volume the mark would land on a directory WebKit never opens.
            .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
    }

    static func excludeFromBackup(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = directory
        try marked.setResourceValues(values)
    }

    private static var isSandboxed: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }
}
