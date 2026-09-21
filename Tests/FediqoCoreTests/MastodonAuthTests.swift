import Foundation
import Security
import Testing

@testable import FediqoCore

/// A server that answers by path and remembers every request, body and headers included.
actor FixtureSender: HTTPSender {
    enum Outcome: Sendable {
        case json(String, status: Int = 200)
        case fail
    }

    private let routes: [String: Outcome]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: Outcome]) {
        self.routes = routes
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
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

    /// The form fields of the request sent to `path`.
    func form(_ path: String) -> [String: String] {
        guard let request = requests.first(where: { $0.url?.path == path }),
              let body = request.httpBody, let text = String(data: body, encoding: .utf8)
        else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }
}

/// The server's page, answered without a browser: it finishes on whatever `answer` builds from
/// the address it was opened on.
@MainActor
final class FixtureBrowser: OAuthBrowser {
    private let answer: @MainActor (URL) throws -> URL
    private(set) var opened: [URL] = []

    init(_ answer: @escaping @MainActor (URL) throws -> URL) {
        self.answer = answer
    }

    /// Approves: hands back a code and the state it was sent.
    static func approving(code: String = "the-code") -> FixtureBrowser {
        FixtureBrowser { url in
            let state = query(url, "state") ?? ""
            return URL(string: "fediqo://oauth?code=\(code)&state=\(state)")!
        }
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened.append(url)
        return try answer(url)
    }

    nonisolated static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

enum MastodonFixture {
    static let host = "social.example"
    static let apps = #"{"client_id":"cid","client_secret":"csecret"}"#
    static let issued = #"{"access_token":"tok-123","token_type":"Bearer"}"#
    static let me = #"{"id":"1","acct":"reader"}"#

    static func server(
        verify: FixtureSender.Outcome = .json(me), issued: String = issued
    ) -> FixtureSender {
        FixtureSender([
            "/api/v1/apps": .json(apps),
            "/oauth/token": .json(issued),
            "/api/v1/accounts/verify_credentials": verify,
            "/oauth/revoke": .json("{}"),
        ])
    }

    static let token = MastodonToken(
        host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )

    /// The same token, carrying what its sign-in asked for.
    static func token(scopes: String?) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: scopes
        )
    }
    static let app = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret")
}

@Suite("Signing in to a Mastodon")
struct MastodonAuthTests {
    private let host = MastodonFixture.host

    // MARK: - Registration and the page

    @Test("The app registers by name, callback and the narrow read scopes")
    func registers() async throws {
        let server = MastodonFixture.server()
        let app = try await MastodonOAuth(host: host, sender: server).register()
        #expect(app == MastodonApp(
            host: host, clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading
        ), "a registration records the scopes it was made for")

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://social.example/api/v1/apps")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")
        let form = await server.form("/api/v1/apps")
        #expect(form["client_name"] == "Fediqo")
        #expect(form["redirect_uris"] == "fediqo://oauth")
        #expect(form["scopes"] == "read:statuses read:lists read:accounts read:search")
    }

    @Test("A refused registration is its status; an unreadable one is unreadable")
    func refusedRegistration() async {
        let refused = FixtureSender(["/api/v1/apps": .json("{}", status: 422)])
        await #expect(throws: MastodonSignInError.http(422)) {
            _ = try await MastodonOAuth(host: host, sender: refused).register()
        }
        let garbled = FixtureSender(["/api/v1/apps": .json("<html>")])
        await #expect(throws: MastodonSignInError.unreadable) {
            _ = try await MastodonOAuth(host: host, sender: garbled).register()
        }
        let offline = FixtureSender(["/api/v1/apps": .fail])
        await #expect(throws: MastodonSignInError.unreachable) {
            _ = try await MastodonOAuth(host: host, sender: offline).register()
        }
    }

    @Test("The page asked for carries every parameter, the challenge as S256")
    func authorizePage() throws {
        let oauth = MastodonOAuth(host: host, sender: MastodonFixture.server())
        let url = try #require(oauth.authorizeURL(clientID: "cid", challenge: "chal", state: "st"))
        #expect(url.scheme == "https")
        #expect(url.host() == host)
        #expect(url.path == "/oauth/authorize")
        let expected: [String: String] = [
            "response_type": "code",
            "client_id": "cid",
            "redirect_uri": "fediqo://oauth",
            "scope": "read:statuses read:lists read:accounts read:search",
            "state": "st",
            "code_challenge": "chal",
            "code_challenge_method": "S256",
        ]
        for (name, value) in expected {
            #expect(FixtureBrowser.query(url, name) == value, "\(name)")
        }
    }

    @Test("PKCE's challenge is RFC 7636's own example, and each pair is fresh")
    func pkce() {
        let pair = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        let one = PKCE.make(), two = PKCE.make()
        #expect(one != two)
        #expect(one.verifier.count == 43)
        #expect(!one.verifier.contains(where: { "+/=".contains($0) }))
        #expect(PKCE(verifier: one.verifier).challenge == one.challenge)
    }

    // MARK: - The answer

    @Test("The code is taken only from an answer carrying this attempt's state")
    func callback() throws {
        let good = URL(string: "fediqo://oauth?code=abc&state=st")!
        #expect(try MastodonOAuth.code(from: good, state: "st") == "abc")

        #expect(throws: MastodonSignInError.stateMismatch) {
            try MastodonOAuth.code(from: URL(string: "fediqo://oauth?code=abc&state=other")!, state: "st")
        }
        #expect(throws: MastodonSignInError.stateMismatch) {
            try MastodonOAuth.code(from: URL(string: "fediqo://oauth?code=abc")!, state: "st")
        }
        #expect(throws: MastodonSignInError.denied) {
            try MastodonOAuth.code(
                from: URL(string: "fediqo://oauth?error=access_denied&state=st")!, state: "st"
            )
        }
        #expect(throws: MastodonSignInError.invalidScope) {
            try MastodonOAuth.code(
                from: URL(string: "fediqo://oauth?error=invalid_scope&state=st")!, state: "st"
            )
        }
        #expect(throws: MastodonSignInError.unreadable) {
            try MastodonOAuth.code(from: URL(string: "fediqo://oauth?state=st")!, state: "st")
        }
    }

    @Test("An answer anywhere but this app's own callback is not read", arguments: [
        "https://oauth?code=abc&state=st", "other://oauth?code=abc&state=st",
        "fediqo://elsewhere?code=abc&state=st", "fediqo:oauth?code=abc&state=st",
    ])
    func callbackElsewhere(address: String) {
        #expect(throws: MastodonSignInError.unreadable) {
            try MastodonOAuth.code(from: URL(string: address)!, state: "st")
        }
    }

    // MARK: - The whole sign-in

    private func signIn(_ server: FixtureSender, _ browser: FixtureBrowser) async throws
        -> MastodonToken
    {
        try await MastodonOAuth(host: host, sender: server)
            .signIn(as: MastodonFixture.app, through: browser)
    }

    @Test("Page, token, check — in that order, and the token is the one issued to the app")
    func signsIn() async throws {
        let server = MastodonFixture.server()
        let browser = await FixtureBrowser.approving()
        let token = try await signIn(server, browser)
        // **The scopes it asked for travel with it** (#69). The registration in hand records
        // none — it is one kept before they were written down — so the sign-in falls to the
        // reading pair and the token says so.
        #expect(token == MastodonFixture.token(scopes: MastodonOAuth.reading))
        #expect(token.grant == .reading)
        #expect(token.app == MastodonFixture.app)
        #expect(await server.paths == ["/oauth/token", "/api/v1/accounts/verify_credentials"])

        let page = try #require(await browser.opened.first)
        let exchange = await server.form("/oauth/token")
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["code"] == "the-code")
        #expect(exchange["client_id"] == "cid")
        #expect(exchange["client_secret"] == "csecret")
        #expect(exchange["redirect_uri"] == "fediqo://oauth")
        #expect(exchange["scope"] == "read:statuses read:lists read:accounts read:search")
        // The verifier sent is the one whose challenge the page carried.
        let verifier = try #require(exchange["code_verifier"])
        #expect(PKCE(verifier: verifier).challenge == FixtureBrowser.query(page, "code_challenge"))

        let check = try #require(await server.requests.last)
        #expect(check.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    /// **What a token records is what the server granted** (#69). A server may issue a narrower
    /// grant than the page asked for, and a token keeping the asked string would leave every row
    /// on Account answering from this device's intent — "read and write" over a token that cannot
    /// write. It cannot go the other way: the page the reader answered asked for `asked`, and a
    /// server cannot grant past it.
    @Test("A server granting less than was asked for is taken at its word")
    func granted() async throws {
        let asked = MastodonOAuth.scopes(writing: true)
        let server = MastodonFixture.server(
            issued: #"{"access_token":"tok-123","scope":"\#(MastodonOAuth.reading)"}"#
        )
        let app = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: asked)
        let token = try await MastodonOAuth(host: host, sender: server)
            .signIn(as: app, through: await FixtureBrowser.approving())
        #expect(await server.form("/oauth/token")["scope"] == asked, "the page asked for both parts")
        #expect(token.scopes == MastodonOAuth.reading)
        #expect(token.grant == .reading, "a token that cannot write read as one that can")
    }

    /// The other arm: RFC 6749 lets a server leave `scope` out when the grant is exactly the
    /// request, so nothing back means what was asked for.
    @Test("A server that answers with no scope leaves the asked string standing", arguments: [
        MastodonFixture.issued, #"{"access_token":"tok-123","scope":""}"#,
    ])
    func grantedNothingSaid(issued: String) async throws {
        let asked = MastodonOAuth.scopes(writing: true)
        let app = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: asked)
        let token = try await MastodonOAuth(host: host, sender: MastodonFixture.server(issued: issued))
            .signIn(as: app, through: await FixtureBrowser.approving())
        #expect(token.scopes == asked)
        #expect(token.grant == .writing)
    }

    @Test("A registration made without read:search records it, and its page and exchange ask only for that")
    func withoutSearch() async throws {
        let server = MastodonFixture.server()
        let oauth = MastodonOAuth(host: host, sender: server)
        let app = try await oauth.register(scopes: MastodonOAuth.readingWithoutSearch)
        #expect(app.scopes == "read:statuses read:lists read:accounts")
        #expect(await server.form("/api/v1/apps")["scopes"] == "read:statuses read:lists read:accounts")
        let browser = await FixtureBrowser.approving()
        _ = try await oauth.signIn(as: app, through: browser)
        let page = try #require(await browser.opened.first)
        #expect(FixtureBrowser.query(page, "scope") == "read:statuses read:lists read:accounts")
        #expect(await server.form("/oauth/token")["scope"] == "read:statuses read:lists read:accounts")
    }

    @Test("A closed page stops the sign-in before any token is asked for")
    func cancelled() async {
        let server = MastodonFixture.server()
        let browser = await FixtureBrowser { _ in throw MastodonSignInError.cancelled }
        await #expect(throws: MastodonSignInError.cancelled) {
            _ = try await signIn(server, browser)
        }
        #expect(await server.paths.isEmpty)
    }

    @Test("An answer with another state is refused and no code is traded")
    func forgedAnswer() async {
        let server = MastodonFixture.server()
        let browser = await FixtureBrowser { _ in URL(string: "fediqo://oauth?code=x&state=forged")! }
        await #expect(throws: MastodonSignInError.stateMismatch) {
            _ = try await signIn(server, browser)
        }
        #expect(await server.paths.isEmpty)
    }

    @Test("A token the account check refuses is not a sign-in, and is revoked")
    func refusedCheck() async {
        let server = MastodonFixture.server(verify: .json("{}", status: 403))
        let browser = await FixtureBrowser.approving()
        await #expect(throws: MastodonSignInError.http(403)) {
            _ = try await signIn(server, browser)
        }
        #expect(await server.paths.last == "/oauth/revoke")
        #expect(await server.form("/oauth/revoke")["token"] == "tok-123")
    }

    @Test("A server that no longer knows the app says so as a rejected client")
    func clientRejected() async {
        let server = FixtureSender([
            "/oauth/token": .json(#"{"error":"invalid_client"}"#, status: 401),
        ])
        let browser = await FixtureBrowser.approving()
        await #expect(throws: MastodonSignInError.clientRejected) {
            _ = try await signIn(server, browser)
        }
        let other = FixtureSender(["/oauth/token": .json(#"{"error":"invalid_grant"}"#, status: 400)])
        await #expect(throws: MastodonSignInError.http(400)) {
            _ = try await signIn(other, browser)
        }
    }

    @Test("Revoking sends the token with the app it was issued to, and never throws")
    func revokes() async {
        let server = MastodonFixture.server()
        await MastodonOAuth(host: host, sender: server).revoke(MastodonFixture.token)
        let form = await server.form("/oauth/revoke")
        #expect(form == ["client_id": "cid", "client_secret": "csecret", "token": "tok-123"])

        let offline = FixtureSender(["/oauth/revoke": .fail])
        await MastodonOAuth(host: host, sender: offline).revoke(MastodonFixture.token)
    }

    // MARK: - The signed-in door

    @Test("A signed-in request carries the token to its own host only")
    func authorizedGet() async throws {
        let server = FixtureSender(["/api/v1/timelines/home": .json("[]")])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        let body = try await door.get(
            path: "/api/v1/timelines/home", query: [URLQueryItem(name: "limit", value: "40")]
        )
        #expect(body == Data("[]".utf8))
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://social.example/api/v1/timelines/home?limit=40")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test("A signed-in POST carries the token and the form to its own host only")
    func authorizedPost() async throws {
        let server = FixtureSender(["/api/v1/statuses": .json("{}")])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        let body = try await door.post(path: "/api/v1/statuses", form: [
            ("status", "hello+world"),
            ("visibility", "public"),
        ])
        #expect(body == Data("{}".utf8))
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://social.example/api/v1/statuses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(await server.form("/api/v1/statuses") == [
            "status": "hello+world", "visibility": "public",
        ])
    }

    @Test("A 401 the account check confirms means the server ended it: the token goes")
    func revokedByServer() async throws {
        let server = FixtureSender([
            "/api/v1/timelines/home": .json("{}", status: 401),
            "/api/v1/accounts/verify_credentials": .json("{}", status: 401),
        ])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        await #expect(throws: MastodonAuthError.signedOut) {
            _ = try await door.get(path: "/api/v1/timelines/home")
        }
        #expect(try store.signedInHosts().isEmpty)
        #expect(await server.paths
            == ["/api/v1/timelines/home", "/api/v1/accounts/verify_credentials"])
    }

    @Test("A 401 the account check does not confirm leaves the token alone", arguments: [200, 0])
    func unconfirmed401(check: Int) async throws {
        let server = FixtureSender([
            "/api/v1/timelines/home": .json("{}", status: 401),
            "/api/v1/accounts/verify_credentials": check == 0 ? .fail : .json("{}", status: check),
        ])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        await #expect(throws: MastodonAuthError.http(401)) {
            _ = try await door.get(path: "/api/v1/timelines/home")
        }
        #expect(try store.signedInHosts() == [host])
    }

    @Test("The account check's own 401 needs no second asking")
    func accountCheck401() async throws {
        let server = FixtureSender([
            "/api/v1/accounts/verify_credentials": .json("{}", status: 401),
        ])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        await #expect(throws: MastodonAuthError.signedOut) {
            _ = try await door.get(path: "/api/v1/accounts/verify_credentials")
        }
        #expect(await server.paths.count == 1)
        #expect(try store.signedInHosts().isEmpty)
    }

    /// Token A's request is on the wire; the reader signs out and in again and token B is saved;
    /// A's 401 lands. Only A was refused, so B stays.
    @Test("A late 401 for a replaced token does not take the new one")
    func late401KeepsTheNewToken() async throws {
        let store = MemoryMastodonTokens()
        let gate = Gate()
        let server = HeldSender(gate: gate)
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        let request = Task { try await door.get(path: "/api/v1/timelines/home") }
        #expect(await spin { await server.waiting })

        let replacement = MastodonToken(
            host: host, accessToken: "tok-456", clientID: "cid", clientSecret: "csecret"
        )
        try store.save(replacement)
        await gate.open()

        await #expect(throws: MastodonAuthError.http(401)) { _ = try await request.value }
        #expect(try store.token(host: host) == replacement)
    }

    @Test("403, 500 and no connection are not a sign-out", arguments: [403, 500, 0])
    func otherFailuresKeepTheToken(status: Int) async throws {
        let outcome: FixtureSender.Outcome = status == 0 ? .fail : .json("{}", status: status)
        let server = FixtureSender(["/api/v1/timelines/home": outcome])
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store)
        do {
            _ = try await door.get(path: "/api/v1/timelines/home")
            Issue.record("expected a failure")
        } catch let error as MastodonAuthError {
            #expect(error == .http(status))
        } catch {
            #expect(status == 0)
        }
        #expect(try store.signedInHosts() == [host])
    }

    // MARK: - What is kept, and what it says

    @Test("The Keychain item is a generic password of this app's, kept on this device only")
    func keychainItem() throws {
        let attributes = MastodonKeychain.attributes(for: MastodonFixture.token)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "fediqo.mastodon")
        #expect(attributes[kSecAttrAccount as String] as? String == host)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrLabel as String] as? String == "Fediqo — social.example")

        let lookup = MastodonKeychain.lookup(host: "Social.Example")
        #expect(lookup[kSecAttrAccount as String] as? String == host)
        #expect(lookup[kSecAttrService as String] as? String == "fediqo.mastodon")
        #expect(lookup[kSecAttrSynchronizable as String] as? Bool == false)

        let all = MastodonKeychain.allItems()
        #expect(all[kSecReturnData as String] == nil)
        #expect(all[kSecAttrService as String] as? String == "fediqo.mastodon")
        #expect(all[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("The app registration is kept apart from the token, under the same protections")
    func keychainAppItem() {
        let attributes = MastodonKeychain.attributes(for: MastodonFixture.app)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "fediqo.mastodon.app")
        #expect(attributes[kSecAttrAccount as String] as? String == host)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        // Listing who is signed in never counts a registration.
        #expect(MastodonKeychain.allItems()[kSecAttrService as String] as? String
            != MastodonKeychain.appService)
    }

    @Test("The items' values come back as what they were written from")
    func wireRoundTrip() throws {
        let data = try #require(
            MastodonKeychain.attributes(for: MastodonFixture.token)[kSecValueData as String] as? Data
        )
        #expect(MastodonKeychain.Wire.decode(data, host: host) == MastodonFixture.token)
        #expect(MastodonKeychain.Wire.decode(Data("junk".utf8), host: host) == nil)
        let app = try #require(
            MastodonKeychain.attributes(for: MastodonFixture.app)[kSecValueData as String] as? Data
        )
        #expect(MastodonKeychain.Wire.decodeApp(app, host: host) == MastodonFixture.app)
        // The scopes a registration was made for go with it; one kept before they were recorded
        // reads back with none.
        let scoped = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading)
        let scopedData = try #require(MastodonKeychain.attributes(for: scoped)[kSecValueData as String] as? Data)
        #expect(MastodonKeychain.Wire.decodeApp(scopedData, host: host)?.scopes == MastodonOAuth.reading)
        let older = Data(#"{"clientID":"cid","clientSecret":"csecret"}"#.utf8)
        #expect(MastodonKeychain.Wire.decodeApp(older, host: host)?.scopes == nil)
        #expect(MastodonKeychain.Wire.decodeApp(Data("junk".utf8), host: host) == nil)
    }

    @Test("A token and a registration print as their host, however they are printed")
    func neverPrintsTheSecret() {
        let token = MastodonFixture.token
        let app = MastodonFixture.app
        var dumped = ""
        dump(token, to: &dumped)
        dump(app, to: &dumped)
        for said in ["\(token)", String(reflecting: token), "\(app)", String(reflecting: app), dumped] {
            #expect(said.contains(host))
            #expect(!said.contains(token.accessToken))
            #expect(!said.contains(token.clientSecret))
        }
    }

    @Test("The memory store keeps, lists and forgets by host, and forgets a token only if held")
    func memoryStore() throws {
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        try store.save(MastodonFixture.app)
        #expect(try store.token(host: "SOCIAL.example") == MastodonFixture.token)
        #expect(try store.signedInHosts() == [host])
        let other = MastodonToken(host: host, accessToken: "x", clientID: "cid", clientSecret: "c")
        #expect(try store.forget(other) == false)
        #expect(try store.token(host: host) == MastodonFixture.token)
        #expect(try store.forget(MastodonFixture.token) == true)
        #expect(try store.token(host: host) == nil)
        #expect(try store.signedInHosts().isEmpty)
        #expect(try store.app(host: host) == MastodonFixture.app, "a sign-out keeps the registration")
        try store.forgetApp(host: host)
        #expect(try store.app(host: host) == nil)
    }
}

// MARK: - Redirects of a request that carries a token
//
// On `HTTPTests` so they share its serialisation: `StubURLProtocol` is one global stub.
extension HTTPTests {
    private func authorized(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://urlprotocol.test\(path)")!)
        request.setValue("Bearer tok-123", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test("A token is never carried to another host, scheme or port", arguments: [
        "https://elsewhere.test/x", "https://urlprotocol.test:8443/x",
    ])
    func authorizedRedirectLeavingOriginRefused(target: String) async {
        StubURLProtocol.prepare(status: 200, body: Data("home".utf8), http: true, redirect: target)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        do {
            _ = try await client.send(authorized("/api/v1/timelines/home"))
            Issue.record("followed a redirect to \(target) with the token")
        } catch let error as URLError {
            #expect(error.code == .unsupportedURL)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(StubURLProtocol.lastRequest()?.url?.host() == "urlprotocol.test")
    }

    /// A source never signed in to — and a signed-in one's All and Trends — read through
    /// `data(from:)`, which takes an address and nothing else.
    @Test("A public read carries no token")
    func publicReadCarriesNoToken() async throws {
        StubURLProtocol.prepare(status: 200, body: Data("[]".utf8), http: true)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        _ = try await client.data(from: URL(string: "https://urlprotocol.test/api/v1/timelines/public")!)
        #expect(StubURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A token's redirect within its own origin is followed")
    func authorizedRedirectSameOriginFollowed() async throws {
        StubURLProtocol.prepare(
            status: 200, body: Data("home".utf8), http: true,
            redirect: "https://urlprotocol.test/moved"
        )
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        let (data, response) = try await client.send(authorized("/api/v1/timelines/home"))
        #expect(String(data: data, encoding: .utf8) == "home")
        #expect(response.url?.path == "/moved")
    }

    @Test("The origin rule reads scheme, host and port, and leaves a request with no token alone")
    func redirectOriginRule() {
        let from = authorized("/a")
        #expect(CappedBody.mayFollow(from: from, to: URL(string: "https://URLPROTOCOL.test/b")!))
        #expect(CappedBody.mayFollow(from: from, to: URL(string: "https://urlprotocol.test:443/b")!))
        #expect(!CappedBody.mayFollow(from: from, to: URL(string: "https://evil.test/b")!))
        #expect(!CappedBody.mayFollow(from: from, to: URL(string: "http://urlprotocol.test/b")!))
        #expect(!CappedBody.mayFollow(from: from, to: URL(string: "https://urlprotocol.test:8443/b")!))

        let plain = URLRequest(url: URL(string: "https://urlprotocol.test/a")!)
        #expect(CappedBody.mayFollow(from: plain, to: URL(string: "https://evil.test/b")!))
        #expect(CappedBody.mayFollow(from: nil, to: URL(string: "https://evil.test/b")!))

        // The sign-in's client holds every request to its origin, token or not.
        let evil = URL(string: "https://evil.test/b")!
        #expect(!CappedBody.mayFollow(from: plain, to: evil, sameOriginOnly: true))
        #expect(!CappedBody.mayFollow(from: nil, to: evil, sameOriginOnly: true))
        #expect(CappedBody.mayFollow(
            from: plain, to: URL(string: "https://urlprotocol.test/b")!, sameOriginOnly: true
        ))
    }

    /// The token exchange and the revoke carry the client secret, the code and the token in
    /// their bodies, so the sign-in's client refuses every redirect off the origin.
    @Test("The sign-in's client refuses a redirect off its origin with no token on it")
    func signInClientHoldsToItsOrigin() async {
        StubURLProtocol.prepare(
            status: 200, body: Data("{}".utf8), http: true, redirect: "https://elsewhere.test/token"
        )
        defer { StubURLProtocol.reset() }

        #expect(URLSessionClient.signedIn().sameOriginOnly)
        let client = URLSessionClient(session: StubURLProtocol.session(), sameOriginOnly: true)
        let form = MastodonOAuth.form(
            host: "urlprotocol.test", path: "/oauth/token", [("client_secret", "csecret")]
        )!
        do {
            _ = try await client.send(form)
            Issue.record("followed a redirect off the origin with the client secret")
        } catch let error as URLError {
            #expect(error.code == .unsupportedURL)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("The signed-in client keeps no cookie and no cached response on disk")
    func signedInClientIsEphemeral() {
        let configuration = URLSessionClient.signedIn().session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
    }
}

/// Holds every request at a gate, then answers 401.
private actor HeldSender: HTTPSender {
    private let gate: Gate
    private(set) var waiting = false

    init(gate: Gate) {
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        waiting = true
        await gate.wait()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
}

private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// Yields until `condition` holds, and gives up rather than hanging the suite.
private func spin(until condition: () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
