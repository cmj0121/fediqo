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
/// that lesson down twice — `ShellSession.pictures` holds the caches Preferences reads for
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
        view = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768),
                         configuration: configuration)
        super.init()
        view.navigationDelegate = self
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
    /// than a host: two forums under one registrable domain share their records, and clearing
    /// one clears both. The alternative — keeping records a Clear should have dropped — is the
    /// worse error.
    static func forget(host: String, in store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { holds($0.displayName, for: host) }
        guard !mine.isEmpty else { return }
        await store.removeData(ofTypes: types, for: mine)
    }

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

    static func bare(_ host: String) -> String {
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

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
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
