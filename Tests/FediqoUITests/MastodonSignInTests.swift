import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon server answering the sign-in by path, remembering every request and what the token
/// store held at the moment each one was sent.
private actor MastodonServer: HTTPSender {
    enum Outcome: Sendable {
        case json(String, status: Int = 200)
        case fail
        /// A fresh access token per exchange, as a server issues one: `tok-123`, then `tok-124`.
        /// **What makes a sign-in made in place tell itself apart from the one it supersedes** —
        /// with one string for every exchange, a token revoked and a token kept are the same
        /// bytes and no test can say which went.
        case issuesToken
    }

    private let routes: [String: Outcome]
    private let tokens: MemoryMastodonTokens
    private(set) var requests: [URLRequest] = []
    /// Whether a token was held for the request's host when it was sent, per request.
    private(set) var heldWhenSent: [Bool] = []
    private var issued = 0

    init(tokens: MemoryMastodonTokens, _ overrides: [String: Outcome] = [:]) {
        self.tokens = tokens
        self.routes = [
            "/api/v1/apps": .json(#"{"client_id":"cid","client_secret":"csecret"}"#),
            "/oauth/token": .issuesToken,
            "/api/v1/accounts/verify_credentials": .json(#"{"id":"1"}"#),
            "/oauth/revoke": .json("{}"),
            "/api/v1/timelines/home": .json("[]"),
        ].merging(overrides) { $1 }
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let host = request.url?.host() ?? ""
        heldWhenSent.append(((try? tokens.token(host: host)) ?? nil) != nil)
        guard let url = request.url, let outcome = routes[url.path] else {
            throw FixtureHTTPError.unmapped
        }
        switch outcome {
        case .json(let body, let status):
            return (Data(body.utf8), Self.answered(url, status))
        case .issuesToken:
            issued += 1
            return (
                Data(#"{"access_token":"tok-\#(122 + issued)"}"#.utf8), Self.answered(url, 200)
            )
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Which tokens this server was asked to forget, in the order it was asked.
    var revoked: [String] {
        requests.filter { $0.url?.path == "/oauth/revoke" }.map {
            let form = String(decoding: $0.httpBody ?? Data(), as: UTF8.self)
            return form.split(separator: "&").first { $0.hasPrefix("token=") }
                .map { String($0.dropFirst("token=".count)) } ?? ""
        }
    }

    private static func answered(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// The server's own page, answered by the test: approves with the state it was sent, or closes,
/// or waits at a gate first.
@MainActor
private final class Page: OAuthBrowser {
    /// `refusesSearch` answers `invalid_scope` to a page asking for `read:search`, and approves
    /// any other.
    enum Answer { case approve, close, invalidScope, refusesSearch }

    private let answer: Answer
    private let gate: Gate?
    private(set) var opened = 0
    /// What each page this browser was handed asked the reader to agree to, in order.
    private(set) var scopes: [String] = []

    init(_ answer: Answer = .approve, gate: Gate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened += 1
        await gate?.wait()
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value ?? ""
        scopes.append(scope)
        if answer == .invalidScope || (answer == .refusesSearch && scope.contains("read:search")) {
            return URL(string: "fediqo://oauth?error=invalid_scope&state=\(state)")!
        }
        if answer == .refusesSearch { return URL(string: "fediqo://oauth?code=c&state=\(state)")! }
        guard answer == .approve else { throw MastodonSignInError.cancelled }
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

@MainActor
@Suite("Signing in to a Mastodon source")
struct MastodonSignInTests {
    private let host = "social.example"
    private let forum = "bbs.example.org"

    /// `scopes` left out is a token kept before this app asked about writing — which is what
    /// every test here that saves a token directly is standing in for.
    private func token(_ host: String, scopes: String? = nil) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: scopes
        )
    }

    /// A registration made for the scopes this build asks for.
    private var app: MastodonApp {
        MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading)
    }

    private func shell(
        _ overrides: [String: MastodonServer.Outcome] = [:],
        credentials: MemoryCredentials = MemoryCredentials()
    ) async -> (ShellSession, MastodonServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        let server = MastodonServer(tokens: tokens, overrides)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(),
            forums: ForumSessions(credentials: credentials),
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        for source in [Source(host: host, kind: .mastodon), Source(host: forum, kind: .discuz)] {
            await session.store.add(source)
        }
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    private func row(_ session: ShellSession, _ host: String) -> SourceRow {
        session.rows.first { $0.source.host == host }!
    }

    // MARK: - In and out

    @Test("A Mastodon row offers a sign-in, and pressing it signs in on the server's own page")
    func signsIn() async throws {
        let (session, server, tokens) = await shell()
        #expect(row(session, host).canSignIn)
        #expect(!session.isSignedIn(host: host))

        let page = Page()
        await session.signIn(host: host, through: page)
        #expect(page.opened == 1)
        #expect(try tokens.token(host: host) == token(host, scopes: MastodonOAuth.reading))
        #expect(session.isSignedIn(host: host))
        #expect(session.mastodon.signedInHosts == [host])
        #expect(await server.paths == [
            "/api/v1/apps", "/oauth/token", "/api/v1/accounts/verify_credentials",
            "/api/v1/timelines/home",
        ])
        #expect(session.rowRefusal == nil)
        #expect(try tokens.app(host: host) == app, "the registration was not kept")
    }

    @Test("Signing in again after a sign-out uses the registration it kept")
    func reusesTheRegistration() async throws {
        let (session, server, tokens) = await shell()
        await session.signIn(host: host, through: Page())
        await session.signOut(host: host)
        #expect(try tokens.app(host: host) == app, "a plain sign-out dropped the registration")
        await session.signIn(host: host, through: Page())
        #expect(session.isSignedIn(host: host))
        #expect(await server.paths.filter { $0 == "/api/v1/apps" }.count == 1)
    }

    @Test("A registration the server rejects is dropped, and the next sign-in registers afresh")
    func rejectedRegistration() async throws {
        let (session, server, tokens) = await shell(
            ["/oauth/token": .json(#"{"error":"invalid_client"}"#, status: 401)]
        )
        try tokens.save(app)
        await session.signIn(host: host, through: Page())
        #expect(try tokens.app(host: host) == nil)
        #expect(!session.isSignedIn(host: host))
        #expect(session.rowRefusal?.key == "account.mastodon.failed")
        #expect(await !server.paths.contains("/api/v1/apps"))
    }

    @Test("A registration kept for other scopes is made again, for the scopes asked now",
          arguments: [nil, "read", "read:statuses read:accounts"])
    func registrationForOtherScopes(scopes: String?) async throws {
        let (session, server, tokens) = await shell()
        try tokens.save(MastodonApp(host: host, clientID: "old", clientSecret: "old", scopes: scopes))
        await session.signIn(host: host, through: Page())
        #expect(await server.paths.first == "/api/v1/apps")
        #expect(try tokens.app(host: host) == app)
        #expect(session.isSignedIn(host: host))
    }

    @Test("A page answering invalid_scope drops the kept registration and says the sign-in failed")
    func invalidScope() async throws {
        let (session, server, tokens) = await shell()
        try tokens.save(app)
        await session.signIn(host: host, through: Page(.invalidScope))
        #expect(try tokens.app(host: host) == nil, "the next sign-in registers afresh")
        #expect(!session.isSignedIn(host: host))
        #expect(session.rowRefusal?.key == "account.mastodon.failed", "never a silent nothing")
        #expect(await !server.paths.contains("/oauth/token"))
    }

    @Test("A server refusing read:search: registered once more without it, the reduced scopes kept, and signed in")
    func refusesSearch() async throws {
        let (session, server, tokens) = await shell()
        let page = Page(.refusesSearch)
        await session.signIn(host: host, through: page)
        #expect(page.opened == 2)
        #expect(await server.paths == [
            "/api/v1/apps", "/api/v1/apps", "/oauth/token", "/api/v1/accounts/verify_credentials",
            "/api/v1/timelines/home",
        ])
        let registered = await server.requests.filter { $0.url?.path == "/api/v1/apps" }
            .map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(registered.first?.contains("search") == true)
        #expect(registered.last?.contains("search") == false, "the second registration leaves search out")
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.readingWithoutSearch)
        #expect(session.isSignedIn(host: host))
        #expect(session.rowRefusal == nil)

        // Signing in again reuses the reduced registration: no app piles up per attempt.
        await session.signOut(host: host)
        let again = Page(.refusesSearch)
        await session.signIn(host: host, through: again)
        #expect(again.opened == 1)
        #expect(await server.paths.filter { $0 == "/api/v1/apps" }.count == 2)
        #expect(session.isSignedIn(host: host))
    }

    @Test("A server refusing even the reduced scopes: two registrations at most, none kept, and a sentence")
    func refusesEveryScope() async throws {
        let (session, server, tokens) = await shell()
        let page = Page(.invalidScope)
        await session.signIn(host: host, through: page)
        #expect(page.opened == 2)
        #expect(await server.paths == ["/api/v1/apps", "/api/v1/apps"])
        #expect(try tokens.app(host: host) == nil)
        #expect(!session.isSignedIn(host: host))
        #expect(session.rowRefusal?.key == "account.mastodon.failed")
    }

    /// A server that no longer knows the client shows an error page with no way back, so a closed
    /// page on a kept registration is the one sign of it this app can see.
    @Test("A page closed on a kept registration drops it; on a fresh one keeps it")
    func closedOnAKeptRegistration() async throws {
        let (session, _, tokens) = await shell()
        await session.signIn(host: host, through: Page(.close))
        #expect(try tokens.app(host: host) == app, "a fresh registration was dropped")
        await session.signIn(host: host, through: Page(.close))
        #expect(try tokens.app(host: host) == nil)
        #expect(session.rowRefusal == nil)
    }

    @Test("Closing the page says nothing and keeps nothing")
    func closedPage() async throws {
        let (session, server, tokens) = await shell()
        await session.signIn(host: host, through: Page(.close))
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(!session.isSignedIn(host: host))
        #expect(session.rowRefusal == nil)
        #expect(await server.paths == ["/api/v1/apps"])
    }

    @Test("A server that cannot be reached is one sentence under its row")
    func unreachable() async throws {
        let (session, _, tokens) = await shell(["/api/v1/apps": .fail])
        await session.signIn(host: host, through: Page())
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(session.rowRefusal?.host == host)
        #expect(session.rowRefusal?.key == "account.mastodon.failed.unreachable")
    }

    @Test("A token the account check refuses is not kept, and is revoked")
    func refusedCheck() async throws {
        let (session, server, tokens) = await shell(
            ["/api/v1/accounts/verify_credentials": .json("{}", status: 401)]
        )
        await session.signIn(host: host, through: Page())
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(!session.isSignedIn(host: host))
        #expect(await server.paths.last == "/oauth/revoke")
    }

    @Test("Signing out deletes the token first, then asks the server to revoke it")
    func signsOut() async throws {
        let (session, server, tokens) = await shell()
        try tokens.save(token(host))
        await session.signOut(host: host)
        #expect(try tokens.token(host: host) == nil)
        #expect(!session.isSignedIn(host: host))
        #expect(await server.paths == ["/oauth/revoke"])
        #expect(await server.heldWhenSent == [false], "the token was still here when revoke went")
        let body = try #require(await server.requests.first?.httpBody)
        let form = String(decoding: body, as: UTF8.self)
        #expect(form.contains("client_id=cid"))
        #expect(form.contains("client_secret=csecret"))
        #expect(form.contains("token=tok-123"))
    }

    @Test("A token the Keychain would not delete: the row stays signed in, as the Keychain says, and the server is asked to revoke it")
    func keychainKeepsTheToken() async throws {
        let tokens = StuckTokens()
        try tokens.save(token(host))
        let server = MastodonServer(tokens: MemoryMastodonTokens())
        let sessions = MastodonSessions(tokens: tokens, sender: server)
        #expect(sessions.isSignedIn(host: host))
        await sessions.signOut(host: host)
        #expect(sessions.isSignedIn(host: host), "not claimed signed out while the token is still kept")
        #expect(await server.paths == ["/oauth/revoke"])
    }

    @Test("A revoke the server refuses or never hears still signs out", arguments: [false, true])
    func revokeFails(offline: Bool) async throws {
        let (session, _, tokens) = await shell(
            ["/oauth/revoke": offline ? .fail : .json("{}", status: 500)]
        )
        try tokens.save(token(host))
        await session.signOut(host: host)
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(!session.isSignedIn(host: host))
    }

    @Test("Signing out of a Mastodon leaves the forum's sign-in and password alone")
    func signOutIsPerSource() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: forum, username: "r", password: "p"))
        let (session, _, tokens) = await shell(credentials: credentials)
        try tokens.save(token(host))
        await session.signOut(host: host)
        #expect(try credentials.savedHosts() == [forum])
    }

    // MARK: - Relaunch, and a server ending it

    @Test("After a relaunch the source still reads signed in")
    func relaunch() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host))
        let next = MastodonSessions(tokens: tokens, sender: MastodonServer(tokens: tokens))
        #expect(next.isSignedIn(host: host))
        #expect(next.isSignedIn(host: "SOCIAL.example"))
    }

    @Test("A sign-in the server revoked reads signed out, and the reader is told once")
    func revokedByServer() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host))
        try tokens.save(token("other.example"))
        let server = MastodonServer(
            tokens: tokens, ["/api/v1/accounts/verify_credentials": .json("{}", status: 401)]
        )
        let sessions = MastodonSessions(tokens: tokens, sender: server)
        await sessions.verifyAll()
        #expect(sessions.signedInHosts.isEmpty)
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(sessions.ended == ["other.example", host])

        sessions.endedByServer(host: host)
        #expect(sessions.ended == ["other.example", host], "one notice per host, not per request")
        sessions.endedSeen()
        #expect(sessions.ended.isEmpty)
    }

    @Test("403 and no connection at launch are not a sign-out", arguments: [403, 0])
    func notRevoked(status: Int) async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host))
        let outcome: MastodonServer.Outcome = status == 0 ? .fail : .json("{}", status: status)
        let server = MastodonServer(
            tokens: tokens, ["/api/v1/accounts/verify_credentials": outcome]
        )
        let sessions = MastodonSessions(tokens: tokens, sender: server)
        await sessions.verifyAll()
        #expect(sessions.isSignedIn(host: host))
        #expect(sessions.ended.isEmpty)
    }

    @Test("A sign-in the launch could not read is read when the app comes to the front")
    func readAgainWhenActive() throws {
        let tokens = MemoryMastodonTokens()
        let sessions = MastodonSessions(tokens: tokens, sender: MastodonServer(tokens: tokens))
        #expect(!sessions.isSignedIn(host: host))
        // What a locked device's Keychain would have answered at launch, and then did not.
        try tokens.save(token(host))
        sessions.refresh()
        #expect(sessions.isSignedIn(host: host))
    }

    @Test("The door hands out the token's own host and nothing where there is no token")
    func door() throws {
        let tokens = MemoryMastodonTokens()
        let sessions = MastodonSessions(tokens: tokens, sender: MastodonServer(tokens: tokens))
        #expect(sessions.authorized(host: host, for: .timeline) == nil)
        try tokens.save(token(host))
        #expect(sessions.authorized(host: host, for: .timeline)?.token.host == host)
    }

    // MARK: - Clear and Remove

    @Test("Clear signs a Mastodon out and keeps its posts; the forum's password is untouched")
    func clearSignsOut() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: forum, username: "r", password: "p"))
        let (session, _, tokens) = await shell(credentials: credentials)
        try tokens.save(token(host))
        try tokens.save(app)
        await session.store.ingest([Note(
            id: "1", source: Source(host: host, kind: .mastodon), author: "a", handle: "@a",
            body: "kept", postedAt: Date(), categories: [.public]
        )])
        await session.clear(host: host)
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(!session.isSignedIn(host: host))
        #expect(await session.store.all().count == 1, "signing out dropped a post")
        #expect(try credentials.savedHosts() == [forum])
        #expect(try tokens.app(host: host) == nil, "Clear left the registration behind")
    }

    @Test("Remove signs a Mastodon out and leaves nothing of its sign-in")
    func removeSignsOut() async throws {
        let (session, _, tokens) = await shell()
        try tokens.save(token(host))
        try tokens.save(app)
        await session.remove(host: host)
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(try tokens.app(host: host) == nil)
    }

    @Test("A source removed while its page is up is not signed in to")
    func removedMidSignIn() async throws {
        let (session, server, tokens) = await shell()
        let gate = Gate()
        let page = Page(gate: gate)
        let pressing = Task { await session.signIn(host: host, through: page) }
        #expect(await spun { page.opened == 1 })
        await session.remove(host: host)
        await gate.open()
        await pressing.value

        #expect(try tokens.signedInHosts().isEmpty)
        #expect(!session.isSignedIn(host: host))
        #expect(await server.paths.last == "/oauth/revoke", "the orphan token was not revoked")
        #expect(session.rowRefusal == nil)
        #expect(try tokens.app(host: host) == nil)
    }

    // MARK: - What the page says

    @Test("A signed-in Mastodon draws its row signed in, and Clear says it signs out")
    func rowReadsSignedIn() async throws {
        let (session, _, tokens) = await shell()
        try tokens.save(token(host))
        let signedIn = MastodonSessions(tokens: tokens, sender: MastodonServer(tokens: tokens))
        let fresh = ShellSession(http: FixtureHTTP(), store: session.store, mastodon: signedIn)
        fresh.sources = session.sources
        #expect(fresh.isSignedIn(host: host))
        #expect(!fresh.isSignedIn(host: forum))
        #expect(AccountPane(session: fresh).glance?.first { $0.id == host }?.signedIn == true)
        #expect(SourceRow.clearDetailKey(
            hasPassword: false, reachedSignIn: fresh.isSignedIn(host: host)
        ) == "account.clear.detail.signedout")
        #expect(!L10n.t("account.clear.detail.signedout", language: .english).contains("forum"))
    }

    // MARK: - #69: what a sign-in asks for, and what a row says may be done

    /// **The question is put before anything is opened or asked of anybody.** A choice made after
    /// the server's page has already asked for something is this app deciding and the server
    /// reporting, which is the one shape #69 is against.
    @Test("A Mastodon's Sign in puts the question and contacts nobody")
    func theQuestionComesFirst() async throws {
        let (session, server, tokens) = await shell()
        let pane = AccountPane(session: session)
        await pane.press(row(session, host))
        #expect(session.signInChoice == host)
        #expect(await server.paths.isEmpty, "the page was opened before the reader had answered")
        #expect(try tokens.signedInHosts().isEmpty)

        // Cancelling it opens nothing and changes nothing.
        session.signInChoice = nil
        #expect(await server.paths.isEmpty)
        #expect(!session.isSignedIn(host: host))
    }

    /// A protocol this app cannot write to has no question to put — decision 4's rule about
    /// absent controls, applied to a dialog.
    @Test("A forum's sign-in puts no writing question")
    func aForumIsNotAsked() async {
        let (session, _, _) = await shell()
        #expect(!row(session, forum).asksWriting, "a forum was asked about writing")
        #expect(row(session, host).asksWriting)
        #expect(!ProtocolKind.discuz.canWrite)
        #expect(!ProtocolKind.discourse.canWrite)
        #expect(ProtocolKind.mastodon.canWrite)
    }

    /// **Refusing the writing part leaves reading exactly as it was**, and this is where that is
    /// proved rather than promised: the page, the exchange and the registration all ask for the
    /// reading string and no request in the whole sign-in carries the word.
    @Test("Signing in to read asks for the reading scopes and nothing else")
    func signsInToRead() async throws {
        let (session, server, tokens) = await shell()
        let page = Page()
        await session.signIn(host: host, through: page, writing: false)
        #expect(page.scopes == [MastodonOAuth.reading])
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.reading)
        #expect(try tokens.token(host: host)?.grant == .reading)
        for request in await server.requests {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains("write"), "a read-only sign-in asked to write")
        }
        #expect(row(session, host).writing == .reads)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon).isEmpty,
                "a reader who answered is asked again")
    }

    @Test("Signing in to write asks for both parts, and the row says both")
    func signsInToWrite() async throws {
        let (session, server, tokens) = await shell()
        let page = Page()
        await session.signIn(host: host, through: page, writing: true)
        #expect(page.scopes == [MastodonOAuth.scopes(writing: true)])
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.scopes(writing: true))
        #expect(try tokens.token(host: host)?.grant == .writing)
        // The registration and the exchange say the same thing the page did — read off the
        // forms, so a page that asked for one thing and a token issued for another fails here.
        for path in ["/api/v1/apps", "/oauth/token"] {
            let sent = await server.requests.filter { $0.url?.path == path }
                .map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
            #expect(sent.count == 1)
            #expect(sent.first?.contains("write%3Astatuses") == true, "\(path)")
            #expect(sent.first?.contains("write%3Afavourites") == true, "\(path)")
        }

        let row = row(session, host)
        #expect(row.writing == .writes)
        #expect(SourceRow.spoken(row).contains(L10n.t("account.source.writing.write")))
    }

    /// A registration made for the other answer cannot carry this one's page — the server would
    /// answer `invalid_scope` — so the choice changing means registering again.
    @Test("Changing the answer registers again rather than reusing the other one")
    func changingTheAnswerRegistersAgain() async throws {
        let (session, server, tokens) = await shell()
        await session.signIn(host: host, through: Page(), writing: false)
        await session.signOut(host: host)
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.reading)

        await session.signIn(host: host, through: Page(), writing: true)
        #expect(await server.paths.filter { $0 == "/api/v1/apps" }.count == 2)
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.scopes(writing: true))
        #expect(try tokens.token(host: host)?.grant == .writing)
    }

    /// Decision 32's fallback is per answer: a host that will not grant `read:search` still grants
    /// the writing part, and the reader keeps what they asked for.
    @Test("A server refusing read:search keeps the writing part in the narrower registration")
    func refusesSearchWhileWriting() async throws {
        let (session, _, tokens) = await shell()
        let page = Page(.refusesSearch)
        await session.signIn(host: host, through: page, writing: true)
        #expect(page.opened == 2)
        let narrow = MastodonOAuth.scopes(
            reading: MastodonOAuth.readingWithoutSearch, writing: true
        )
        #expect(page.scopes == [MastodonOAuth.scopes(writing: true), narrow])
        #expect(try tokens.app(host: host)?.scopes == narrow)
        #expect(try tokens.token(host: host)?.grant == .writing)
        #expect(row(session, host).writing == .writes)
    }

    /// **A reader signed in before this app could write is told, and nothing of theirs moves.**
    /// The token kept by that build recorded no scopes at all, which is what tells it apart from a
    /// reader who was offered the writing part and said no.
    @Test("A sign-in made before the question reads as before, and is asked again in the open")
    func askedAgain() async throws {
        let (session, _, tokens) = await shell()
        try tokens.save(token(host))
        session.mastodon.refresh()

        #expect(session.isSignedIn(host: host), "reading stopped working")
        #expect(session.mastodon.grants[host] == .unasked)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon) == [host])
        #expect(row(session, host).writing == .reads, "it writes nothing until they agree")

        // Answering it — either way — takes the line off the page.
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(session.mastodon.grants[host] == .writing)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon).isEmpty)
        #expect(row(session, host).writing == .writes)
    }

    /// **Being told is not being asked.** The only route to the question was sign out → sign in,
    /// and a sign-out revokes the token at the server — so reaching the choice cost a working
    /// read-only sign-in, and cancelling on the server's page left the reader with less than they
    /// had before the question existed. The sentence carries the question now.
    @Test("The standing sentence asks in place: nobody is signed out and nothing is asked of the server")
    func theSentenceAsksInPlace() async throws {
        let (session, server, tokens) = await shell()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret"
        ))
        session.mastodon.refresh()
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon) == [host])

        AccountPane(session: session).askWriting(host)
        #expect(session.signInChoice == host, "the question was not put")
        #expect(session.isSignedIn(host: host), "asking signed the reader out")
        #expect(await server.paths.isEmpty, "the server heard about a question the reader has not answered")

        // Cancelling it costs nothing, which is the whole of why it is asked in place.
        session.signInChoice = nil
        #expect(try tokens.token(host: host)?.accessToken == "tok-old")
        #expect(await server.paths.isEmpty)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon) == [host])

        // Answering it: the new token replaces the old one here, and revokes it there.
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(try tokens.token(host: host)?.accessToken == "tok-123")
        #expect(session.mastodon.grants[host] == .writing)
        #expect(row(session, host).writing == .writes)
        #expect(await server.revoked == ["tok-old"], "the sign-in it replaced is still live")
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon).isEmpty)
    }

    /// **A sign-in made in place must not leave the token it replaces alive**, and narrowing is
    /// the case that proves it: a reader going from writing back to reading who left a
    /// write-capable token honoured by the server has been given the opposite of what they asked
    /// for. `tokens.save` is delete-then-add, so this is the only thing that revokes it.
    @Test("Signing in again without signing out revokes the token it supersedes")
    func supersededTokenIsRevoked() async throws {
        let (session, server, tokens) = await shell()
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(try tokens.token(host: host)?.accessToken == "tok-123")
        #expect(await server.revoked.isEmpty, "a first sign-in revoked something")

        await session.signIn(host: host, through: Page(), writing: false)
        #expect(try tokens.token(host: host)?.accessToken == "tok-124", "the new token was not kept")
        #expect(session.mastodon.grants[host] == .reading)
        #expect(row(session, host).writing == .reads)
        #expect(await server.revoked == ["tok-123"], "the write-capable token is still live")
        #expect(session.isSignedIn(host: host), "narrowing signed the reader out")
    }

    /// **The row answers from the server and not from this device's intent** (#69). A server may
    /// issue a narrower grant than the page asked for; a row reading back the asked string would
    /// say "read and write" over a token that cannot write.
    @Test("A server granting less than was asked for is what the row says")
    func theRowSaysWhatWasGranted() async throws {
        let (session, _, tokens) = await shell([
            "/oauth/token": .json(#"{"access_token":"tok-123","scope":"\#(MastodonOAuth.reading)"}"#),
        ])
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(try tokens.token(host: host)?.scopes == MastodonOAuth.reading)
        #expect(session.mastodon.grants[host] == .reading)
        #expect(row(session, host).writing == .reads)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon).isEmpty,
                "a reader who answered is asked again")
    }

    /// A token left behind for a server the reader has since removed must not put a stranger's
    /// name on the page: the line is drawn from the rows.
    @Test("The line names only sources this page draws")
    func askedAgainNamesOnlyItsOwnRows() async throws {
        let (session, _, tokens) = await shell()
        try tokens.save(token("gone.example"))
        session.mastodon.refresh()
        #expect(session.mastodon.grants["gone.example"] == .unasked)
        #expect(AccountPane.askedAgain(session.sources, in: session.mastodon).isEmpty)
    }

    /// **A source that turns a write away says so and keeps saying it.** Nothing this device holds
    /// can tell whether it was the token, the account or the server's mind, so the row stops
    /// claiming writing until the source is signed in to again — and reading is untouched by it.
    @Test("A write turned away marks the row until the source is signed in again")
    func aWriteTurnedAway() async throws {
        let (session, _, _) = await shell()
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(row(session, host).writing == .writes)

        session.mastodon.refusedWrite(host: host)
        #expect(row(session, host).writing == .refused)
        #expect(SourceRow.marksWriting(.refused))
        #expect(!SourceRow.marksWriting(.writes))
        #expect(session.isSignedIn(host: host), "a refused write signed the reader out")
        #expect(SourceRow.spoken(row(session, host))
            .contains(L10n.t("account.source.writing.refused")))

        // Signing in again is what clears it, which is what the row says to do.
        await session.signIn(host: host, through: Page(), writing: true)
        #expect(row(session, host).writing == .writes)

        // And a sign-out spends it too: there is nothing left for a write to use.
        session.mastodon.refusedWrite(host: host)
        await session.signOut(host: host)
        #expect(!session.mastodon.writeRefused.contains(host))
    }

    /// The forum row on this page, which says read only for a reason that is about the protocol.
    @Test("A forum row says read only however its reader is signed in")
    func aForumRowReadsOnly() async throws {
        let (session, _, _) = await shell()
        let forumRow = row(session, forum)
        #expect(forumRow.writing == .never)
        #expect(SourceRow.writingKey(forumRow.writing) == "account.source.writing.never")
        #expect(SourceRow.spoken(forumRow).contains(L10n.t("account.source.writing.never")))
    }

    /// Every word this unit put on a screen, in every language the app ships.
    @Test("Every word #69 added is translated")
    func everyWordIsTranslated() {
        var keys = Set(SourceWriting.allCases.map(SourceRow.writingKey))
        #expect(keys.count == SourceWriting.allCases.count, "two states share a word")
        keys.formUnion([
            "account.sources.writing", "account.sources.writing.again",
            "account.sources.writing.again.choose",
            "account.signin.ask.title", "account.signin.ask.detail",
            "account.signin.ask.read", "account.signin.ask.write",
        ])
        for key in keys {
            for language in DummyLanguage.allCases {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
            }
        }
        // The one promise the README made that this unit had to withdraw, withdrawn in the words
        // the reader actually meets as well: what a sign-in asks for is named, not denied.
        let detail = L10n.t("account.signin.ask.detail", language: .english)
        #expect(detail.contains("post") && detail.contains("Reading"))
    }

    @Test("Every failure has a sentence, and every sentence is translated")
    func sentences() {
        let failures: [MastodonSignInError] = [
            .cancelled, .denied, .stateMismatch, .unreachable, .http(500), .unreadable, .keychain,
            .clientRejected,
        ]
        let keys = Set(failures.map(ShellSession.signInFailureKey)).union([
            "account.mastodon.ended.title", "account.mastodon.ended.detail",
        ])
        for key in keys {
            for language in DummyLanguage.allCases {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
            }
        }
        #expect(ShellSession.signInFailureKey(.http(503)) == "account.mastodon.failed.unreachable")
    }
}

/// A token store whose Keychain will not delete a token by host.
private final class StuckTokens: MastodonTokenStore, @unchecked Sendable {
    private let held = MemoryMastodonTokens()

    func token(host: String) throws -> MastodonToken? { try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { throw ForumCredentialError.keychain(-25_308) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}
