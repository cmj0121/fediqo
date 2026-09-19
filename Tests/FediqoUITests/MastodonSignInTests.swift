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
    }

    private let routes: [String: Outcome]
    private let tokens: MemoryMastodonTokens
    private(set) var requests: [URLRequest] = []
    /// Whether a token was held for the request's host when it was sent, per request.
    private(set) var heldWhenSent: [Bool] = []

    init(tokens: MemoryMastodonTokens, _ overrides: [String: Outcome] = [:]) {
        self.tokens = tokens
        self.routes = [
            "/api/v1/apps": .json(#"{"client_id":"cid","client_secret":"csecret"}"#),
            "/oauth/token": .json(#"{"access_token":"tok-123"}"#),
            "/api/v1/accounts/verify_credentials": .json(#"{"id":"1"}"#),
            "/oauth/revoke": .json("{}"),
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
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(body.utf8), response)
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// The server's own page, answered by the test: approves with the state it was sent, or closes,
/// or waits at a gate first.
@MainActor
private final class Page: OAuthBrowser {
    enum Answer { case approve, close }

    private let answer: Answer
    private let gate: Gate?
    private(set) var opened = 0

    init(_ answer: Answer = .approve, gate: Gate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened += 1
        await gate?.wait()
        guard answer == .approve else { throw MastodonSignInError.cancelled }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

@MainActor
@Suite("Signing in to a Mastodon source")
struct MastodonSignInTests {
    private let host = "social.example"
    private let forum = "bbs.example.org"

    private func token(_ host: String) -> MastodonToken {
        MastodonToken(host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret")
    }

    private var app: MastodonApp { token(host).app }

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
        #expect(try tokens.token(host: host) == token(host))
        #expect(session.isSignedIn(host: host))
        #expect(session.mastodon.signedInHosts == [host])
        #expect(await server.paths
            == ["/api/v1/apps", "/oauth/token", "/api/v1/accounts/verify_credentials"])
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
        #expect(sessions.authorized(host: host) == nil)
        try tokens.save(token(host))
        #expect(sessions.authorized(host: host)?.token.host == host)
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
