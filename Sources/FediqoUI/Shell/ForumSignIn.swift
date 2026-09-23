import FediqoCore
import Foundation
import Observation
import Security
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
    /// The kept username and password are there and this device could not read them back — #153.
    /// The Keychain's own reason goes with it, because "it did not work" is not a reason.
    case keychain(ForumCredentialError)

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
        case .keychain: "forum.stop.keychain"
        }
    }

    /// The sheet's sentence, with the Keychain's reason put into it where there is one.
    func explanation(language: DummyLanguage? = nil) -> String {
        said(explanationKey, language: language)
    }

    /// The sentence behind `key`, with the Keychain's reason put into it where this stop is the
    /// Keychain's — the one step the sheet's line and the row's lapsed line share.
    func said(_ key: String, language: DummyLanguage? = nil) -> String {
        let said = L10n.t(key, language: language)
        guard case .keychain(let error) = self else { return said }
        return String(format: said, ForumKeychainReason.of(error, language: language))
    }

    /// What the row says when a launch did not sign this forum in again — #153. One per stop, for
    /// the reason `explanationKey` is one per stop: the compiler asks for each.
    var lapsedKey: String {
        switch self {
        case .noCredential: "forum.lapsed.first"
        case .wall: "forum.lapsed.wall"
        case .captcha: "forum.lapsed.captcha"
        case .question: "forum.lapsed.question"
        case .refused: "forum.lapsed.refused"
        case .unreadable: "forum.lapsed.unreadable"
        case .unreachable: "forum.lapsed.unreachable"
        case .keychain: "forum.lapsed.keychain"
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
        .keychain(.keychain(-25_308)),
    ]
}

/// Why the Keychain would not keep, read or delete a forum's password, in the reader's words.
///
/// **The status is always said, and a few are said in words as well.** An `OSStatus` alone is
/// nothing a reader can act on, and a sentence alone is nothing anybody can look up; the ones
/// named here are the ones this app has actually met or can expect to — a locked keychain, a
/// build not allowed to use it (an ad-hoc Debug build answers `-34018` wherever the
/// data-protection keychain is asked for; see `MastodonKeychain`), access refused or cancelled at
/// the system's own prompt, and no keychain there at all. Everything else is "the Keychain
/// refused", with its number.
enum ForumKeychainReason {
    static func key(for status: Int32) -> String {
        switch status {
        case errSecInteractionNotAllowed: "forum.keychain.locked"
        case errSecMissingEntitlement: "forum.keychain.entitlement"
        case errSecAuthFailed, errSecUserCanceled: "forum.keychain.denied"
        case errSecNoSuchKeychain, errSecNotAvailable: "forum.keychain.missing"
        default: "forum.keychain.other"
        }
    }

    static func of(_ error: ForumCredentialError, language: DummyLanguage? = nil) -> String {
        switch error {
        case .keychain(let status):
            String(format: L10n.t(key(for: status), language: language), Int(status))
        case .incomplete: L10n.t("forum.keychain.incomplete", language: language)
        case .unreadable: L10n.t("forum.keychain.unreadable", language: language)
        }
    }

    /// Whatever a store threw, as the one error type a sentence is written for. A store that
    /// is not the Keychain — none ships — is reported as a Keychain that refused.
    static func error(_ thrown: any Error) -> ForumCredentialError {
        thrown as? ForumCredentialError ?? .keychain(errSecInternalComponent)
    }
}

/// Why a username and password the reader asked to keep were not kept — #153.
public enum ForumKeepFailure: Equatable, Sendable {
    /// Nothing typed could be read from the forum's page, so there was nothing to keep.
    case nothingTyped
    /// The Keychain refused to take it.
    case store(ForumCredentialError)

    func sentence(language: DummyLanguage? = nil) -> String {
        let reason = switch self {
        case .nothingTyped: L10n.t("forum.unkept.nothing", language: language)
        case .store(let error): ForumKeychainReason.of(error, language: language)
        }
        return String(format: L10n.t("forum.unkept", language: language), reason)
    }
}

/// What a forum's row says about its sign-in that nothing else on the row can — #153.
///
/// **Held per host, until the thing it is about changes.** A launch that did not sign a forum
/// in again, a password that was not kept, and a password that could not be deleted are each a
/// standing fact about one forum, and a reader who opens Accounts an hour later is owed it then.
/// A sign-in reached takes the first; a keep that works takes the second; a forget takes all
/// three and may leave the third.
enum ForumRowNotice: Equatable, Sendable {
    case lapsed(ForumSignInStop)
    case unkept(ForumKeepFailure)
    case unforgotten(ForumCredentialError)

    func sentence(language: DummyLanguage? = nil) -> String {
        switch self {
        case .lapsed(let stop):
            return stop.said(stop.lapsedKey, language: language)
        case .unkept(let failure):
            return failure.sentence(language: language)
        case .unforgotten(let error):
            return String(
                format: L10n.t("forum.unforgotten", language: language),
                ForumKeychainReason.of(error, language: language)
            )
        }
    }
}

/// What asking to keep the typed pair came to.
public enum ForumKeeping: Equatable, Sendable {
    case kept
    case failed(ForumKeepFailure)
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

    /// Where a launch's signing in again is shown while it runs (#164). The app's own; a test
    /// hands in another.
    @ObservationIgnored var work: SourceWork = .shared

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

    /// What each forum's row owes the reader about its sign-in. See `ForumRowNotice`.
    private(set) var notices: [String: ForumRowNotice] = [:]

    /// What the reader typed and submitted on the forum's own page, while they have asked for it
    /// to be kept — #153. **In memory, one pair per host, never written anywhere** until the
    /// forum's page confirms the sign-in and `saveTyped` hands it to the Keychain; dropped by the
    /// switch going off, the sheet closing, and a forget.
    @ObservationIgnored private var typed: [String: ForumCredential] = [:]

    /// Each forum's sign-in at launch, while it is still running. See `signInAgain(hosts:)`.
    @ObservationIgnored private var relaunching: [String: Task<Void, Never>] = [:]

    /// How many sign-ins this run has seen land on each host. Read by a post fetch to notice
    /// that the answer it is carrying was asked for as a guest — see `ForumPosts`.
    @ObservationIgnored private var landed: [String: Int] = [:]

    /// Who is told when a sign-in lands. See `whenSignedIn(_:)`.
    @ObservationIgnored private var landings: [@MainActor (String) -> Void] = []

    /// The Keychain could not even say which forums have something kept. Logged at launch, and
    /// not drawn on any row: which rows it is about is exactly what could not be found out.
    @ObservationIgnored private(set) var listingFailure: ForumCredentialError?

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

    /// Whether a read of that host has to go through its browser: this run built one, or this
    /// device holds a sign-in for it.
    ///
    /// **`hasEngine` alone is only this run.** A sign-in made before a relaunch leaves its
    /// cookies in the store and no engine behind, so the row reads signed in while every thread
    /// is read by `URLSession` — which a challenge-fronted forum answers with 403 and the reader
    /// is told the forum would not let this app read it. A signed-in host is a forum, so this
    /// still starts no web process for a microblog.
    func readsThroughEngine(host: String) -> Bool {
        hasEngine(host: host) || reachedSignIn(host: host)
    }

    /// The client a read of that host goes through: the forum's own browser where
    /// `readsThroughEngine(host:)` says so, else `plain`.
    ///
    /// **One door for every read** — a reload, a post fetch and a join — so that none of them can
    /// ask a narrower question than the others. A join used to ask `hasEngine` alone, and after a
    /// relaunch with a sign-in kept on a challenge-fronted forum its board picker read through
    /// `URLSession` and got back the 403 the rest of the app had stopped getting. Asked without
    /// building anything, so a microblog still starts no web process.
    func readTransport(host: String, else plain: any HTTPClient) -> any HTTPClient {
        guard readsThroughEngine(host: host) else { return plain }
        return ForumJoinTransport(transport(host: host))
    }

    /// Types a blog's password into that forum, through the browser that holds its sign-in —
    /// **only where there is one** (#213). A forum read without one never sees a password here:
    /// what a signed-out reader is offered is signing in.
    func sendBlogPassword(_ password: String, host: String, page: URL) async throws {
        guard readsThroughEngine(host: host) else { throw ForumBlogs.NotSignedIn() }
        try await engine(host: host).sendBlogPassword(password, on: page)
    }

    /// Lets go of what a right password left in this forum's jar — the session cookie that
    /// opens that one blog, holding a hash of the password. Nothing else is touched.
    func forgetBlogPassword(host: String, blog id: Int) async {
        let jar = dataStore.httpCookieStore
        for cookie in await jar.allCookies()
        where DiscuzBlogPasswordScript.isUnlock(cookie: cookie.name, blog: id)
            && ForumWebEngine.holds(cookie.domain, for: host) {
            await jar.deleteCookie(cookie)
        }
    }

    // MARK: - Signing in

    /// Signs in from the saved credential, or says why the reader has to.
    ///
    /// The order is the order the facts arrive in and it cannot be rearranged: there is no point
    /// reading a login form off a browser check, and no point filling a form that is asking for
    /// something a stored password does not contain.
    func signIn(host: String) async -> ForumSignInOutcome {
        let host = host.lowercased()
        let kept: ForumCredential?
        do {
            kept = try credentials.credential(host: host)
        } catch {
            // Said, and the forum's page is still handed over: a Keychain that will not answer
            // is no reason the reader cannot sign in by hand.
            return .handOver(.keychain(ForumKeychainReason.error(error)))
        }
        guard let credential = kept, credential.isComplete else {
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

    /// Starts or stops holding what the reader submits on the forum's own page — the sheet's
    /// switch. See `ForumWebEngine.watchTyped`. Off drops whatever was held.
    func watchTyped(host: String, on: Bool) {
        let host = host.lowercased()
        if !on { typed[host] = nil }
        guard on || hasEngine(host: host) else { return }
        engine(host: host).watchTyped(on) { [weak self] credential in
            self?.typed[credential.host] = credential
        }
    }

    /// Keeps what the reader typed — **only** when they have said so, and only once the forum's
    /// page has confirmed the sign-in (the sheet asks it first).
    ///
    /// **What they submitted, held from the moment they submitted it**, and failing that what is
    /// still in the form on screen. It used to be only the second, and by the time a sign-in
    /// can be confirmed the forum has moved the page on, so there was nothing to read and
    /// nothing was kept, silently (#153; `ForumSignInPageTests` has the sequence).
    ///
    /// **A failure is answered, and says what went wrong.** It is a status, or "nothing typed
    /// could be read" — never the query, the attributes or the credential, because an error is
    /// what gets logged. The row keeps the sentence until a keep that works or a forget.
    @discardableResult
    func saveTyped(host: String) async -> ForumKeeping {
        let host = host.lowercased()
        var credential = typed[host]
        if credential == nil, hasEngine(host: host) {
            credential = await engine(host: host).typedCredential()
        }
        guard let credential, credential.isComplete else {
            notices[host] = .unkept(.nothingTyped)
            return .failed(.nothingTyped)
        }
        do {
            try credentials.save(credential)
        } catch {
            let failure = ForumKeepFailure.store(ForumKeychainReason.error(error))
            notices[host] = .unkept(failure)
            refreshSavedHosts()
            return .failed(failure)
        }
        typed[host] = nil
        if case .unkept? = notices[host] { notices[host] = nil }
        refreshSavedHosts()
        return .kept
    }

    /// What the forum's page would have handed over on a submit, for a test that has no page.
    func holdTyped(_ credential: ForumCredential) {
        typed[credential.host] = credential
    }

    /// Whether a submitted pair is being held for this host. Asked by tests only.
    func holdsTyped(host: String) -> Bool {
        typed[host.lowercased()] != nil
    }

    func forgetPassword(host: String) {
        let host = host.lowercased()
        do {
            try credentials.forget(host: host)
            if case .unforgotten? = notices[host] { notices[host] = nil }
        } catch {
            // Said on the row: a password the reader asked to be rid of and still held is the one
            // failure here they would most want to hear about.
            notices[host] = .unforgotten(ForumKeychainReason.error(error))
        }
        refreshSavedHosts()
    }

    func notice(host: String) -> ForumRowNotice? {
        notices[host.lowercased()]
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
        let host = host.lowercased()
        witnessed.insert(host)
        reachedHosts.insert(host)
        landed[host, default: 0] += 1
        if case .lapsed? = notices[host] { notices[host] = nil }
        for landing in landings { landing(host) }
    }

    /// Tells `landing` whenever a sign-in lands on a host — the automatic path, the reader's
    /// own page, or a launch signing a forum in again. `ForumPosts` listens, so that nothing it
    /// read as a guest stays read as a guest (#153).
    func whenSignedIn(_ landing: @escaping @MainActor (String) -> Void) {
        landings.append(landing)
    }

    /// How many sign-ins have landed on this host this run. See `landed`.
    func signIns(host: String) -> Int {
        landed[host.lowercased()] ?? 0
    }

    // MARK: - At launch

    /// Signs in again, by itself, every forum here whose sign-in did not survive the relaunch and
    /// whose username and password the reader kept — #153. The app calls this once, at launch,
    /// the way it asks each Mastodon whether its token still holds.
    ///
    /// **Only a forum with something kept is touched.** Which forums those are is the Keychain's
    /// list of attributes, which reads no password — so a forum with nothing kept never has its
    /// store opened or a browser stood up for it, and one whose session cookie survived is
    /// asked nothing at all: its password is read only when there is a sign-in to make, which on
    /// a Mac's login keychain is also the one read that may put a prompt in front of the reader.
    ///
    /// **Started here and not awaited**, and registered before this returns, so a post fetch for
    /// the same forum that starts a moment later finds it running and waits for it —
    /// `settled(host:within:)`. What it cannot do is said on the row (`notices`), and the row
    /// still offers Sign in, because it reads signed out.
    ///
    /// `attempt` is the sign-in itself, handed in by a test; the app's is `signIn(host:)`.
    public func signInAgain(
        hosts: [String],
        attempt: (@MainActor (String) async -> ForumSignInOutcome)? = nil
    ) {
        if let listingFailure {
            NetLog.auth.notice(
                "\(NetLog.line("keychain list", host: "-", error: listingFailure), privacy: .public)"
            )
        }
        // The store's sessions, read once for every forum signed in again here rather than
        // once per forum — and only where there is one, so a launch with nothing kept opens no
        // store.
        var sessions: Task<[String], Never>?
        for host in Set(hosts.map { $0.lowercased() }) where savedHosts.contains(host) {
            guard relaunching[host] == nil else { continue }
            let held = sessions ?? Task { [weak self] in await self?.sessionDomains() ?? [] }
            sessions = held
            // On `SourceWork` for the whole of it (#164): the forum's browser is not an
            // `HTTPClient` a request could be watched through, so the work is registered itself.
            let token = work.begin(host: host, for: .signIn)
            relaunching[host] = Task { [weak self, work] in
                defer { work.end(token) }
                await self?.relaunch(host: host, sessions: held, attempt: attempt)
                self?.relaunching[host] = nil
            }
        }
    }

    private func relaunch(
        host: String, sessions: Task<[String], Never>,
        attempt: (@MainActor (String) async -> ForumSignInOutcome)?
    ) async {
        guard !(await holdsSession(host: host, sessions: sessions)) else { return }
        let outcome: ForumSignInOutcome
        if let attempt {
            outcome = await attempt(host)
        } else {
            outcome = await signIn(host: host)
        }
        switch outcome {
        case .signedIn:
            recordSignIn(host: host)
        case .handOver(let stop):
            notices[host] = .lapsed(stop)
        }
    }

    /// Whether the store holds a member's session for this host, asked of the store directly
    /// rather than of `reachedHosts`, which waits on the forums having been handed over.
    /// `sessions` is the store's read, shared by every forum `signInAgain(hosts:)` started.
    private func holdsSession(host: String, sessions: Task<[String], Never>) async -> Bool {
        if witnessed.contains(host) { return true }
        return await sessions.value.contains { ForumWebEngine.holds($0, for: host) }
    }

    /// The domains the store holds a member's session cookie under.
    private func sessionDomains() async -> [String] {
        await dataStore.httpCookieStore.allCookies()
            .filter { ForumMember.isSessionCookie(named: $0.name) }
            .map(\.domain)
    }

    /// Returns once this host's launch sign-in has settled, or once `limit` has passed, whichever
    /// is first. Immediately where there is none.
    ///
    /// **Bounded**, because a forum behind a browser check can hold a sign-in for most of a
    /// minute before it gives up, and a reader should not look at empty rows for that long. What
    /// is read before the sign-in lands is read again when it does — `ForumPosts.signedIn`.
    func settled(host: String, within limit: Duration = ForumSessions.launchHold) async {
        guard let running = relaunching[host.lowercased()] else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await running.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    /// How long a forum's posts wait for its launch sign-in. See `settled(host:within:)`.
    nonisolated static let launchHold: Duration = .seconds(12)

    /// Whether this host's launch sign-in is still running.
    func isSigningInAgain(host: String) -> Bool {
        relaunching[host.lowercased()] != nil
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
        typed[host.lowercased()] = nil
        notices[host.lowercased()] = nil
        forgetPassword(host: host)
        witnessed.remove(host.lowercased())
        // The cookies have just gone, so what the row says goes with them — for this host and
        // for any sibling whose records WebKit filed under the same domain. Decision 13 puts it
        // here on purpose: Clear and Remove both arrive through this one door.
        await readReached()
    }

    func refreshSavedHosts() {
        do {
            savedHosts = try credentials.savedHosts()
            listingFailure = nil
        } catch {
            // What is drawn falls back to "nothing kept", which is all that can be drawn; why is
            // kept for the launch to log, rather than dropped.
            savedHosts = []
            listingFailure = ForumKeychainReason.error(error)
        }
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
