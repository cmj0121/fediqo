import FediqoCore
import Foundation
import WebKit

/// Why a page could not be handed back.
public enum ForumTransportError: Error, Equatable, Sendable {
    /// Something in front of the forum answered instead. Not a failure: an instruction.
    case wall(ForumWall)
    /// This transport belongs to one host and was asked for another.
    case wrongHost
    /// `https` and a host to reach — decision 9's rule, at this new wire boundary.
    case unfetchable
    /// The engine never finished a navigation inside the deadline.
    case timedOut
    /// WebKit said no: a name that does not resolve, a TLS failure, a dropped connection.
    case unreachable(String)
    /// The document came back as something this cannot read as text at all.
    case unreadable
}

/// One host's browser.
///
/// **Why a web view fetches at all, when this package already has a perfectly good HTTP client.**
/// `cf_clearance` — the token Cloudflare hands out when a browser check passes — is bound to the
/// agent that earned it. Lifting it into a `URLSession` that sends `Fediqo (+https://…)` presents
/// a token one client obtained under another client's name, and the only way to make that work is
/// to send a browser's agent from `URLSession`, which is the impersonation this project has
/// refused in writing and has a test standing against. Fetching *through* the engine that passed
/// the check dissolves the tension instead of trading it off: the page really is fetched by the
/// thing that was cleared, and nothing is claimed that is not true. That is D22, and it is forced
/// rather than chosen.
///
/// **A check cannot clear in here while this view is off screen, and that changes the shape of
/// the unit.** Measured against `challenge.example`: a `WKWebView` with no window reports
/// `document.visibilityState == "hidden"`, Cloudflare's challenge script runs but its Turnstile
/// widget never renders — zero iframes after sixty seconds — and **no cookie at all is set**, not
/// even the ones a challenge normally issues on its own 403. A full Safari agent reached exactly
/// the same place, so it is not the agent. What follows is that a challenged host's first read
/// through this engine *will* come back `.wall`, every time, and the only thing that can clear it
/// is putting this same engine on screen in front of the reader. Showing them the page is
/// therefore not the fallback for when the automatic path fails — for a challenged host it is how
/// the automatic path is reached at all. D24 said to do it because a silent-only sign-in strands
/// the reader; this says it would not have worked anyway.
///
/// **One view per host, for both jobs.** The same object serves the reader's sign-in and the
/// app's fetches, so the cookies the sign-in earned and the cookies the fetch sends are the same
/// jar *by construction* rather than by two objects agreeing. This branch has already written
/// that lesson down twice — `ShellSession.pictures` holds the caches Usage reads for
/// exactly this reason, and "a rule enforced at each consumer's door is a rule consumer N+1
/// misses" is one of the two conventions it earned. A second web view here would be consumer
/// N+1, and the symptom would be a reader who signs in successfully and still cannot read.
///
/// **The store is `ForumSessions`' and may persist (#5).** The app hands every engine the one
/// store kept on this device and out of its backups (`ForumWebsiteData.onDevice()`), so a
/// sign-in outlives a relaunch; tests hand a non-persistent one. Clear drops the host's records
/// from that store directly (`forget(host:in:)`), whether or not this run built an engine.
@MainActor
final class ForumWebEngine: NSObject, WKNavigationDelegate {
    /// How long one navigation may take before the transport gives up on it.
    static let loadDeadline: Duration = .seconds(20)
    /// How much longer a browser check gets to clear itself before the reader is shown it.
    static let challengeDeadline: Duration = .seconds(15)
    /// How often the document is re-read while waiting. Coarse on purpose: this is one page for
    /// one reader, and the thing being waited for takes seconds.
    static let pollInterval: Duration = .milliseconds(250)

    let host: String
    let view: WKWebView

    /// How many navigations have finished. A counter and not a flag, because a browser check
    /// finishes a navigation of its own and *then* replaces the page — so "did it finish" is not
    /// a question with one answer, and a continuation resumed on the first `didFinish` would hand
    /// back the challenge every time.
    private var finishes = 0
    private var failure: (any Error)?
    /// The main frame's own response, kept because `cf-mitigated` is Cloudflare stating in a
    /// header what it did, which beats anything guessed from the body.
    private(set) var mainResponse: HTTPURLResponse?

    /// The gate that makes this one-at-a-time.
    ///
    /// One web view can display one document, so two overlapping fetches would each read
    /// whatever the other had just loaded. Accepted for a forum's front page, per D22.
    ///
    /// A waiter cancelled while queued stays queued and discovers its cancellation when its turn
    /// comes, which it then gives straight up. That is a late cancellation, not a leak, and it is
    /// the version with no second failure mode — this branch's own log says every unit that added
    /// machinery on its own initiative introduced a defect with it, and a cancellation-aware
    /// queue is exactly that machinery.
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Which of `PageRules`' lists is on this view: put on before its first page, and changed as
    /// the person's sign-in comes and goes.
    private(set) var ruledAs: PageRules.Kind?
    /// The rules that list holds: what the person's list said when it was put on (#226).
    private(set) var ruledWith: String?
    /// Whether the person has this forum's sign-in in front of them (#220): what else the page
    /// may pull in, and where it may go, is `Allowance`'s `signingIn` entries then.
    private(set) var signingIn = false
    /// Where what this browser reaches beyond its forum is written (#218, #220). The app's own; a
    /// test hands in another.
    var work: SourceWork = .shared
    /// The launch's sweep of an earlier run's store, while it runs (#219): nothing is loaded
    /// until it is done, so no page is swept out from under.
    var sweeping: Task<Void, Never>?

    init(host: String, dataStore: WKWebsiteDataStore) {
        self.host = host.lowercased()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // **What this calls itself, and what it does not.** WebKit composes an agent naming
        // itself and the platform; this appends the app's name to it, so an administrator
        // reading a log can see which client this is — the same courtesy `Fediqo.userAgent`
        // extends, and the reason that agent carries a contact URL. What is deliberately *not*
        // done is appending `Version/… Safari/…` to make it read as Safari. That is the
        // impersonation this project refuses, and it would also buy nothing: measured against
        // `challenge.example`, a full Safari agent and WebKit's bare one reached exactly the same place.
        configuration.applicationNameForUserAgent = Fediqo.name
        // The forum's own "remember me", ticked on every login form this browser shows — #153.
        // Without it a sign-in made by hand is answered with a cookie that ends when the app does.
        for script in Self.userScripts { configuration.userContentController.addUserScript(script) }
        view = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768),
                         configuration: configuration)
        super.init()
        view.navigationDelegate = self
        configuration.userContentController.add(
            PulledInHandler(self), contentWorld: .defaultClient, name: Self.pulledInMessage
        )
        // The person's list changing puts the rules it makes on at once, on the page in front of
        // them too (#226). Taken off by the centre itself when this goes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(allowancesChanged(_:)), name: SourceWork.allowancesChanged, object: nil
        )
    }

    @objc private func allowancesChanged(_ note: Notification) {
        guard note.object as AnyObject? === work, ruledWith != nil else { return }
        Task { await applyRules() }
    }

    /// The rules for what this browser is doing now, under the person's list as it is now.
    private var wantedRules: String {
        PageRules.rules(signingIn ? .signIn : .forum, of: host, allowing: work.allowances)
    }

    // MARK: - Fetching

    /// The forum's page at `url`, or the wall in front of it.
    ///
    /// **A browser check is returned as itself.** Cloudflare's interstitial is well-formed HTML
    /// with a title and a body, so every parser in this project would read it happily and find no
    /// topics — and the reader would be told their forum is empty when it is in fact asking them
    /// something. Naming it here is what makes that impossible further up.
    func page(at url: URL) async throws -> ForumPage {
        guard Host.allowsFetch(url) else { throw ForumTransportError.unfetchable }
        guard belongsHere(url) else { throw ForumTransportError.wrongHost }

        await acquire()
        defer { release() }
        return try await settled(url)
    }

    /// Loads, waits for a navigation to finish, then waits out a browser check if there is one.
    private func settled(_ url: URL) async throws -> ForumPage {
        await sweeping?.value
        // Nothing but the forum's own site is loaded beside its page (#220). Refused outright
        // where the rules could not be put on: a page that could reach anybody is not loaded.
        var tries = 0
        while ruledWith != wantedRules {
            tries += 1
            guard tries <= 3, await applyRules() else {
                throw ForumTransportError.unreachable("PageRules")
            }
        }
        let mark = finishes
        failure = nil
        mainResponse = nil
        view.load(URLRequest(url: url))

        try await waitForNavigation(past: mark)
        var page = try await read()

        // A managed check usually clears in a few seconds with nothing asked of the reader. It
        // replaces the document when it does, so re-reading is all that is needed to notice.
        if case .wall(let wall) = page, wall.sort == .challenge {
            page = try await waitOutChallenge(from: page)
        }
        return page
    }

    private func waitForNavigation(past mark: Int) async throws {
        let until = ContinuousClock.now + Self.loadDeadline
        while finishes == mark {
            if let failure { throw Self.translate(failure) }
            if ContinuousClock.now >= until {
                view.stopLoading()
                throw ForumTransportError.timedOut
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func waitOutChallenge(from first: ForumPage) async throws -> ForumPage {
        let until = ContinuousClock.now + Self.challengeDeadline
        var page = first
        while ContinuousClock.now < until {
            try await Task.sleep(for: Self.pollInterval)
            page = try await read()
            if case .content = page { return page }
        }
        return page
    }

    /// Reads the settled document and classifies it.
    ///
    /// **A document, not a body.** The engine hands back what it rendered, and for anything that
    /// is not HTML — a forum's JSON endpoint, an RSS feed — WebKit renders the text inside a
    /// wrapper document of its own making. Returning that wrapper's `outerHTML` as the response
    /// body would hand every JSON decoder in this package `<html><body><pre>{…}</pre>`, which
    /// decodes as nothing at all. So the content type decides which of the two is read, and the
    /// answer is the bytes the server sent either way.
    private func read() async throws -> ForumPage {
        let isHTML = (mainResponse?.mimeType ?? "text/html").contains("html")
        let script = isHTML ? ForumLoginScript.document : "document.body ? document.body.innerText : ''"
        guard let text = try await evaluate(script) as? String else {
            throw ForumTransportError.unreadable
        }
        return ForumWallReader.read(
            html: text,
            status: mainResponse?.statusCode,
            mitigated: mainResponse?.value(forHTTPHeaderField: "cf-mitigated")
        )
    }

    // MARK: - Signing in

    /// The person has this forum's sign-in in front of them, or no longer has (#220). While they
    /// do, the check a sign-in shows may load and a page they follow away from it may open — each
    /// written to the run's record under this forum; after, neither.
    ///
    /// **One browser, both jobs** (see the type): while the sheet is up, a background read of this
    /// forum goes through this same view and so runs under the sign-in's rules too — the check a
    /// sign-in shows may load beside it, and it is written like any other act of this browser.
    func signingIn(_ on: Bool) async {
        signingIn = on
        await applyRules()
    }

    /// Bumped by every change of rules asked for, so one that finishes compiling after a newer
    /// one was asked puts nothing on: a stale "signing in" cannot land over a later "no longer".
    private var rulesEpoch = 0

    /// Puts on the list for what this browser is doing now. False only where WebKit would not
    /// compile it; a request overtaken by a newer one puts nothing on and leaves it to that one.
    @discardableResult
    private func applyRules() async -> Bool {
        rulesEpoch += 1
        let mine = rulesEpoch
        let wanted: PageRules.Kind = signingIn ? .signIn : .forum
        let rules = wantedRules
        guard let list = await PageRules.compiled(rules) else {
            if mine == rulesEpoch { ruledAs = nil; ruledWith = nil }
            return false
        }
        guard mine == rulesEpoch else { return true }
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(list)
        ruledAs = wanted
        ruledWith = rules
        return true
    }

    /// Whether this browser goes to `url`, and what is written of it (#220).
    ///
    /// **The main frame stays on the forum's host**, except while the person signs in: then it
    /// may go anywhere they follow (`Allowance.ID.signInPage`), and every page it lands on is
    /// written under this forum. A frame is left to `PageRules`, which blocks every other site's
    /// but what an entry lets through; a frame an entry lets through is written under this forum.
    /// Nothing moves for a forum the gate no longer admits.
    ///
    /// **The list is the person's as it is this instant** (#226): an entry switched off lets
    /// nothing through, and a host they added for this forum lets its frames in, each written
    /// under this forum naming that entry.
    func decide(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" { return true }
        guard Host.allowsFetch(url), let there = url.host()?.lowercased(),
              work.admits(reached: there, source: host)
        else { return false }
        // Its own site is its host or that host's `www.` spelling (`belongs`), and no wider: a
        // guess at the registrable domain without the public suffix list would take two strangers
        // under `com.tw` for one site.
        let own = Self.belongs(url, to: host)
        let applying = Allowance.applying(signingIn ? .signingIn : .forumPage, in: work.allowances, of: host)
        if mainFrame {
            guard signingIn else { return own }
            let entry = own ? nil : applying.first { $0.reach == .navigation && $0.allows(url) }
            guard own || entry != nil else { return false }
            work.note(host: there, for: own ? .signIn : .signInPage, source: host, allowedBy: entry?.id)
            return true
        }
        if !own, let entry = applying.first(where: { $0.reach == .frame && $0.allows(url) }) {
            work.note(host: there, for: entry.source == nil ? .personCheck : .pagePart, source: host, allowedBy: entry.id)
        }
        return true
    }

    /// Where the page says what it pulled in (`pulledIn`).
    static let pulledInMessage = "fediqoPulledIn"

    /// What a page of this forum pulled in beside itself, as it loads — its pictures, scripts and
    /// styles, which never pass `decide` — said by the page's own resource timing, read in a world
    /// the page's scripts cannot reach. Only what came from another site is said.
    static let pulledIn = """
        (() => {
          const own = location.host;
          const say = (entries) => {
            const names = entries.map((e) => e.name).filter((n) => {
              try { return new URL(n).host !== own; } catch (_) { return false; }
            });
            if (names.length) { window.webkit.messageHandlers.\(pulledInMessage).postMessage(names); }
          };
          try {
            new PerformanceObserver((list) => say(list.getEntries())).observe({ type: "resource", buffered: true });
          } catch (_) {}
        })();
        """

    /// What the page pulled in from a host the person added for this forum is written under this
    /// forum, naming the entry (#226). Anything else it names is left: its own site is the
    /// forum's, and what the rules let through for the app is written by `decide`. **Only a host
    /// is written**, never the address the page said.
    func pulledIn(_ addresses: [String]) {
        let own = Allowance.applying(signingIn ? .signingIn : .forumPage, in: work.allowances, of: host)
            .filter { $0.source != nil }
        guard !own.isEmpty else { return }
        for address in addresses {
            guard let url = URL(string: address), let there = url.host()?.lowercased(),
                  !Self.belongs(url, to: host),
                  let entry = own.first(where: { $0.allows(url) })
            else { continue }
            work.note(host: there, for: .pagePart, source: host, allowedBy: entry.id)
        }
    }

    /// Whether the settled document shows a signed-in member. Used to notice a session that
    /// lapsed mid-scroll, which a forum reports by quietly serving the guest's page.
    func isSignedIn() async -> Bool {
        guard let html = try? await evaluate(ForumLoginScript.document) as? String else {
            return false
        }
        return ForumMember.isSignedIn(html)
    }

    /// Types a saved credential into the forum's own form and posts it.
    ///
    /// The secret is passed as a bound argument, never spliced into script text — see
    /// `ForumLoginScript`. Nothing here returns it, prints it, or puts it in an error.
    ///
    /// **Holds the same gate a fetch does**, because this navigates the one view a fetch would
    /// also be navigating; without it a timeline read landing mid-sign-in would replace the form
    /// under the script and the post would go to whatever had arrived.
    ///
    /// What is deliberately *not* made atomic is the pair "read the form, then submit it": the
    /// caller acquires twice, and a fetch can land between. That is accepted rather than
    /// overlooked, because the failure it allows is a stale `formhash`, and a stale `formhash` is
    /// exactly what Discuz! answers with a refusal — which this reads as `.refused` and answers
    /// by showing the reader the page. The race's worst outcome is already the safe outcome, and
    /// a lock held across two awaits to prevent it is the machinery this branch's own log says
    /// arrives with a defect of its own.
    func submitLogin(_ credential: ForumCredential) async throws -> ForumLoginVerdict {
        await acquire()
        defer { release() }
        let mark = finishes
        let filled = try await view.callAsyncJavaScript(
            ForumLoginScript.fill,
            arguments: ["username": credential.username, "password": credential.password],
            contentWorld: .page
        )
        guard (filled as? String) == "submitted" else { return .unreadable }
        try await waitForNavigation(past: mark)
        guard let html = try await evaluate(ForumLoginScript.document) as? String else {
            return .unreadable
        }
        return ForumLoginVerdict.read(html)
    }

    /// Types a blog's password into the form the blog's page answers with, and posts it (#213).
    ///
    /// **This forum's page, over `https`, and nothing past it.** The page is loaded under the
    /// same rules a fetch is — `https`, this host — and read only where it settled there; the post
    /// is `DiscuzBlogPasswordScript`'s, which goes to that page's own origin and follows no
    /// redirect. The password is a bound argument in a content world the page's own scripts
    /// cannot reach: nothing here writes it into the page, returns it, prints it, or puts it in an
    /// error. Whether it opened the blog is for the next read of the blog to say.
    func sendBlogPassword(_ password: String, on page: URL) async throws {
        guard Host.allowsFetch(page) else { throw ForumTransportError.unfetchable }
        guard belongsHere(page) else { throw ForumTransportError.wrongHost }
        await acquire()
        defer { release() }
        if case .wall(let wall) = try await settled(page) { throw ForumTransportError.wall(wall) }
        // The origin is pinned from where the page settled — this forum, `www.` or not — and
        // checked again inside the script, so a page that moves between this look and the run
        // is refused there.
        guard let origin = Self.passwordOrigin(settledAt: view.url, host: host) else {
            throw ForumTransportError.wrongHost
        }
        let answer: Any?
        do {
            answer = try await view.callAsyncJavaScript(
                DiscuzBlogPasswordScript.send,
                arguments: ["password": password, "origin": origin],
                contentWorld: .defaultClient
            )
        } catch {
            throw Self.translate(error)
        }
        guard (answer as? String) == "sent" else { throw ForumTransportError.unreadable }
    }

    /// The origin a blog's password may go to: where the blog page settled, where that is `https`
    /// and this forum — its `www.` spelling included, as `belongs` allows — and nothing otherwise.
    static func passwordOrigin(settledAt there: URL?, host: String) -> String? {
        guard let there, Host.allowsFetch(there), belongs(there, to: host),
              let settled = there.host()?.lowercased()
        else { return nil }
        return "https://" + settled + (there.port.map { ":\($0)" } ?? "")
    }

    /// What the reader typed into the forum's own form.
    ///
    /// **Called from one place, only after the reader opted in.** This is the line where the
    /// honest sentence changes, so it is a named method somebody can grep for rather than a
    /// field read on the way past.
    func typedCredential() async -> ForumCredential? {
        guard let typed = try? await view.callAsyncJavaScript(
            ForumLoginScript.readTyped, arguments: [:], contentWorld: .page
        ) as? [String: String] else { return nil }
        let credential = ForumCredential(
            host: host,
            username: typed["username"] ?? "",
            password: typed["password"] ?? ""
        )
        return credential.isComplete ? credential : nil
    }

    /// Starts or stops handing back what the reader types into the forum's own login form, at the
    /// moment they submit it — #153. See `ForumLoginScript.watchTyped`.
    ///
    /// **On only while the reader has the switch on**, which is where D23's honest sentence
    /// changes. Turned off, the handler goes, so a listener already in the page finds nobody to
    /// hand anything to; the script is taken out of documents still to come.
    ///
    /// Put into the document already on screen as well as into those to come, because the reader
    /// turns the switch on with the form already in front of them.
    func watchTyped(_ on: Bool, into typed: @escaping @MainActor (ForumCredential) -> Void) {
        let content = view.configuration.userContentController
        content.removeScriptMessageHandler(forName: ForumLoginScript.typedMessage, contentWorld: .defaultClient)
        content.removeAllUserScripts()
        for script in Self.userScripts { content.addUserScript(script) }
        guard on else { return }
        let host = host
        content.add(
            TypedHandler { username, password in
                typed(ForumCredential(host: host, username: username, password: password))
            },
            contentWorld: .defaultClient,
            name: ForumLoginScript.typedMessage
        )
        content.addUserScript(WKUserScript(
            source: ForumLoginScript.watchTyped, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        view.evaluateJavaScript(ForumLoginScript.watchTyped, in: nil, in: .defaultClient) { _ in }
    }

    /// Every script this browser's pages always run: the forum's "remember me" ticked, and what
    /// they pulled in said (#226).
    static var userScripts: [WKUserScript] {
        [
            remembering,
            WKUserScript(source: pulledIn, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient),
        ]
    }

    static var remembering: WKUserScript {
        WKUserScript(
            source: ForumLoginScript.remember, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        )
    }

    /// The forum's own sign-in page, which is where the reader is sent and where an automatic
    /// attempt reads its `formhash` and `loginhash` from.
    var loginURL: URL? {
        Host.https(host: host, path: "/member.php", query: [
            URLQueryItem(name: "mod", value: "logging"),
            URLQueryItem(name: "action", value: "login"),
        ])
    }

    // MARK: - Clearing

    /// Stops this view and leaves it on a blank page, for a Clear pressed while it is still
    /// open. What the host left in the store is dropped by `forget(host:in:)`.
    func stopAndBlank() {
        view.stopLoading()
        view.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Removes every record `store` keeps for `host`: cookies, storage, cache.
    ///
    /// WebKit files its records under a site's registrable domain, not the host a reader typed,
    /// so a record belongs here when either name is the other or ends in it. That is coarser
    /// than a host: two forums under one registrable domain share their records.
    ///
    /// **Every cookie a request to this host would carry goes, whoever else it is sent to.** A
    /// parent-domain cookie two forums share is one session for both, and forgetting one ends it
    /// for both: keeping a session a sign-out should have dropped is the worse error.
    ///
    /// **What is not sent to this host is all that is kept** (#221), and only where another forum
    /// still added shares the record (`keeping`): a neighbour's own host-only cookie, or the
    /// sub-domain cookie of a forum under this one. Where none shares it, the record goes whole.
    /// What else a shared record holds — local storage, IndexedDB, cache — stays with it, since
    /// it cannot be told apart per host.
    static func forget(host: String, in store: WKWebsiteDataStore, keeping: Set<String> = []) async {
        let host = host.lowercased()
        let others = keeping.map { $0.lowercased() }.filter { $0 != host }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { holds($0.displayName, for: host) }
        let shared = mine.filter { record in others.contains { holds(record.displayName, for: $0) } }
        let whole = mine.filter { record in !shared.contains { $0.displayName == record.displayName } }
        if !whole.isEmpty { await store.removeData(ofTypes: types, for: whole) }
        guard !shared.isEmpty else { return }
        let jar = store.httpCookieStore
        for cookie in await jar.allCookies()
        where goes(cookie.domain, forgetting: host, keeping: others) {
            await jar.deleteCookie(cookie)
        }
    }

    /// Whether a cookie filed under `domain` goes as `host` is forgotten: it is sent to that host,
    /// or it belongs to it and no forum still added is sent it.
    static func goes(_ domain: String, forgetting host: String, keeping others: [String]) -> Bool {
        sent(domain, to: host)
            || (holds(domain, for: host) && !others.contains(where: { sent(domain, to: $0) }))
    }

    /// Whether a cookie filed under `domain` goes out with a request to `host`: the host is that
    /// domain, or under it. Narrower than `holds` on purpose.
    static func sent(_ domain: String, to host: String) -> Bool {
        var name = domain.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
        let host = host.lowercased()
        return !name.isEmpty && (host == name || host.hasSuffix("." + name))
    }

    /// Drops from `store` everything that is not a sign-in to one of `hosts` (#219).
    ///
    /// **The store is kept between runs for one thing: a forum's session cookie**, so a sign-in
    /// outlives a relaunch (#5, #153). Everything else WebKit files there beside it — its disk
    /// cache of every page and picture it fetched, local and session storage, service workers,
    /// its own tracking-prevention statistics — is a record of which page of which forum was
    /// read, and when. That goes. So do the cookies of any site that is not one of `hosts`: they
    /// name somewhere this device went and are nobody's sign-in here.
    static func sweep(_ store: WKWebsiteDataStore, keeping hosts: some Sequence<String>) async {
        let hosts = Array(hosts)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        var kept: [WKWebsiteDataRecord] = []
        var dropped: [WKWebsiteDataRecord] = []
        for record in records {
            if hosts.contains(where: { holds(record.displayName, for: $0) }) {
                kept.append(record)
            } else {
                dropped.append(record)
            }
        }
        if !dropped.isEmpty {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: dropped)
        }
        if !kept.isEmpty {
            await store.removeData(ofTypes: leftBehind, for: kept)
        }
        // A record is filed by site, coarser than a host (see `forget`): of the cookies left in
        // one, only those a request to a source would carry are a sign-in (#221's `sent`).
        let jar = store.httpCookieStore
        for cookie in await jar.allCookies() where !hosts.contains(where: { sentToSite(cookie.domain, $0) }) {
            await jar.deleteCookie(cookie)
        }
    }

    /// Whether a cookie filed under `domain` goes out with a request to `host` in either of its
    /// spellings — bare or `www.` — the two a forum routinely moves between (`belongs`). A forum
    /// added as `example.com` whose sign-in is a host-only cookie on `www.example.com` keeps it.
    static func sentToSite(_ domain: String, _ host: String) -> Bool {
        let bare = bare(host.lowercased())
        return sent(domain, to: bare) || sent(domain, to: "www." + bare)
    }

    /// What `sweep` drops even for a source's own site: everything but its cookies.
    ///
    /// **That includes the forum's own local storage and IndexedDB**, which a forum's scripts may
    /// use to remember a draft, a dismissed banner or a theme. They are dropped all the same: what
    /// a page stores there is its own record of this device's visits, and nothing a sign-in rests
    /// on — Discuz! and Cloudflare's clearance both live in cookies. The cost is a forum that
    /// forgets such a nicety between runs.
    static var leftBehind: Set<String> {
        WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeCookies])
    }

    /// What a run dropped as it goes to the background (#219): the copies WebKit keeps of what it
    /// fetched, and nothing a sign-in or a browser check in progress rests on — no cookie, no
    /// storage. The rest waits for the quit, or for the next launch.
    static let cache: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
    ]

    /// Whether a record or cookie filed under `name` belongs to `host`. A cookie's domain may
    /// carry a leading dot, which says "and every subdomain" and is not part of the name.
    static func holds(_ name: String, for host: String) -> Bool {
        var name = name.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
        let host = host.lowercased()
        return !name.isEmpty && (host == name || host.hasSuffix("." + name) || name.hasSuffix("." + host))
    }

    // MARK: - Plumbing

    /// Whether this transport will go there. A host-scoped session must not be spent on a
    /// stranger: a signed-in jar sent to another host is the reader's forum credentials leaving
    /// the forum. `www.` is allowed to differ because a forum routinely redirects between the
    /// two spellings of itself — `challenge.example` answers by sending the reader to `www.challenge.example`.
    func belongsHere(_ url: URL) -> Bool { Self.belongs(url, to: host) }

    /// Static so the rule can be asked about without standing a web process up to ask it. A
    /// `WKWebView` in a test is a second process, a render surface and a source of flake; the
    /// decision it embodies is four lines of string comparison and deserves none of that.
    static func belongs(_ url: URL, to host: String) -> Bool {
        guard let there = url.host()?.lowercased() else { return false }
        let host = host.lowercased()
        if there == host { return true }
        return bare(there) == bare(host)
    }

    nonisolated static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func evaluate(_ script: String) async throws -> Any? {
        do {
            return try await view.evaluateJavaScript(script)
        } catch {
            throw Self.translate(error)
        }
    }

    private static func translate(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return CancellationError() }
        return ForumTransportError.unreachable((error as NSError).domain + "/\(code)")
    }

    private func acquire() async {
        if !running {
            running = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let allowed = decide(
                navigationAction.request.url,
                mainFrame: navigationAction.targetFrame?.isMainFrame ?? true
            )
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse
            {
                mainResponse = http
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishes += 1 }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        MainActor.assumeIsolated { failure = error }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        MainActor.assumeIsolated { failure = error }
    }
}

/// Where `ForumLoginScript.watchTyped` hands the pair. A class of its own because the protocol
/// wants an `NSObject`. **Nothing here prints, logs or keeps the message**: it is passed on and
/// dropped, and a body that is not two strings is dropped unread.
private final class TypedHandler: NSObject, WKScriptMessageHandler {
    let typed: @MainActor (String, String) -> Void

    init(_ typed: @escaping @MainActor (String, String) -> Void) {
        self.typed = typed
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let username = body["username"] as? String,
                  let password = body["password"] as? String,
                  !username.isEmpty, !password.isEmpty
            else { return }
            typed(username, password)
        }
    }
}

/// Where a forum's page says what it pulled in (`ForumWebEngine.pulledIn`). Holds its browser
/// weakly — the page's controller holds this — and hands on only a list of strings.
final class PulledInHandler: NSObject, WKScriptMessageHandler {
    weak var engine: ForumWebEngine?

    init(_ engine: ForumWebEngine) {
        self.engine = engine
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let names = message.body as? [String] else { return }
            engine?.pulledIn(names)
        }
    }
}

/// The seam back to everything that already reads a server.
///
/// **The hard part of this unit, written down.** `WKWebView` is main-actor and `HTTPClient` is
/// not: it is a `Sendable` protocol whose one requirement is `nonisolated`, because every client
/// of it — the detector, a join, a timeline read — is ordinary async code with no actor of its
/// own, and giving it one would drag SwiftUI's isolation into the whole of Core. Three shapes
/// were available and only one of them is honest:
///
/// 1. *Make `HTTPClient` main-actor.* Every existing caller becomes main-actor, `URLSessionClient`
///    stops being usable off the main thread, and a timeline fetch hops to the main actor to do
///    network I/O. One forum's requirement paid for by the whole app.
/// 2. *Hold the web view behind `@unchecked Sendable` and lock it.* A lock around an object whose
///    every method must run on the main actor is a lie the compiler has been told to stop
///    checking, and the first method called off the main thread is a crash in WebKit rather than
///    a diagnostic here.
/// 3. *Let the boundary be the boundary.* This type is `Sendable` because its only stored
///    property is a `@MainActor` class, which is `Sendable` by construction; `data(from:)` stays
///    `nonisolated async` and the `await` on the engine is the hop. Nothing is unchecked, nothing
///    else in the app changes isolation, and the one place the two worlds meet is one line long.
///
/// The third is what this is. The cost is real and is D22's stated cost: a fetch through here is
/// main-actor and one-at-a-time.
///
/// **What F1 has to call: nothing.** This conforms to the `HTTPClient` the package already has,
/// so a reader built against a host — `DiscuzClient(http:host:)`, `Detector(http:)`,
/// `SourceJoin(http:store:catalogues:)` — takes this in place of `URLSessionClient` and is
/// otherwise untouched. What it must *handle* is one new error: `ForumTransportError.wall`, which
/// is a page that was not served rather than a page that failed, and which the shell answers by
/// showing the reader the forum's own page.
struct ForumWebTransport: HTTPClient {
    private let engine: ForumWebEngine

    init(engine: ForumWebEngine) {
        self.engine = engine
    }

    /// Refused where the gate did not let it through, as `URLSessionClient` refuses (#220): a
    /// forum's browser is a way out like any other.
    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard Outward.admitted else { throw OutwardRefusal.unwatched }
        let page = try await engine.page(at: url)
        switch page {
        case .wall(let wall):
            throw ForumTransportError.wall(wall)
        case .content(let text):
            let response = await engine.response(for: url)
            return (Data(text.utf8), response)
        }
    }
}

extension ForumWebEngine {
    /// The response the main frame actually got, or a synthesised 200 for the case where WebKit
    /// finished a navigation without handing one over (a document restored from the back/forward
    /// cache does that). Synthesised rather than thrown, because the bytes are real either way
    /// and a caller asking for a page should not be failed over bookkeeping.
    ///
    /// **The synthesised one carries where the view actually ended up, not where it was sent.**
    /// A caller reads the response's address to tell "here is your thread" from "here is the
    /// sign-in page instead" — `DiscuzPage.isSignInPage` does exactly that, and it is how a
    /// members-only board is reported as needing an account rather than as unreadable. Handing
    /// back the requested address would make every redirect invisible to that check, and it would
    /// be invisible **only** on the path that matters most: a forum read through the engine is a
    /// forum the reader signed in to, which is where a session lapsing mid-read sends them.
    func response(for url: URL) -> HTTPURLResponse {
        if let mainResponse { return mainResponse }
        return HTTPURLResponse(
            url: view.url ?? url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
    }
}
