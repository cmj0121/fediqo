import CryptoKit
import Foundation
import Security

// Signing in to a Mastodon server: OAuth 2 authorization code with PKCE (S256) and `state`, on
// the server's own page, asking for what reading needs and — where the reader said so — for what
// writing needs.
//
// The app is registered once per host and its registration kept (`MastodonApp`), so a sign-in
// after a sign-out does not register again; Mastodon tokens do not expire, so there is no
// refresh. PKCE is always sent: a server older than 4.3 ignores it,
// and `state` and the client secret still bind the flow there.

/// Opens the server's authorization page and hands back the address it finished on.
@MainActor
public protocol OAuthBrowser: Sendable {
    /// Throws `MastodonSignInError.cancelled` where the reader closed it.
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL
}

/// Why a sign-in did not finish. **Status codes only** — no token, code, state or verifier ever
/// travels in an error.
public enum MastodonSignInError: Error, Equatable, Sendable {
    /// The reader closed the page.
    case cancelled
    /// The reader said no on the server's page.
    case denied
    /// The callback's `state` is not the one sent: not this attempt's answer.
    case stateMismatch
    case unreachable
    case http(Int)
    case unreadable
    /// The token was issued and this device could not keep it.
    case keychain
    /// The server no longer knows this app's registration (`invalid_client`): register again.
    case clientRejected
    /// The server answered `invalid_scope`: the registration was made for other scopes than
    /// this build asks for. It is dropped, so the next attempt registers afresh.
    case invalidScope
}

/// A request made with a token, answered.
public enum MastodonAuthError: Error, Equatable, Sendable {
    /// 401: the server no longer honours this token. The token is already gone from this device.
    case signedOut
    /// Any other refusal — 403 included, which is a token outside its scope or a suspended
    /// login, not a revoked one.
    case http(Int)
}

/// A PKCE pair (RFC 7636): a random verifier and its S256 challenge.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func make() -> PKCE { PKCE(verifier: random(bytes: 32)) }

    /// Unpadded base64url of `bytes` random bytes.
    static func random(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "no randomness to sign in with")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One host's sign-in, each step a function a test can drive.
public struct MastodonOAuth: Sendable {
    public static let callbackScheme = "fediqo"
    public static let redirect = "fediqo://oauth"
    /// Decision 8: what Home, lists, the account check and finding a post again by its address
    /// (#29) need, and no more. A token issued before `read:search` was asked for lacks it.
    public static let reading = "read:statuses read:lists read:accounts read:search"
    /// Decision 32: what is asked of a server that refuses `read:search` (`invalid_scope`), once.
    /// Everything but finding an old post again works; that says to sign in again.
    public static let readingWithoutSearch = "read:statuses read:lists read:accounts"
    /// What writing needs (#69), and no more: `write:statuses` is a post, a boost, a reply and
    /// taking any of them back; `write:favourites` is a favourite. **Nothing here follows anybody,
    /// changes a profile or touches a filter** — those are other `write:` scopes and this app asks
    /// for none of them.
    ///
    /// **Asked for only where the reader said so.** It is never part of the reading pair above, so
    /// a sign-in that refuses the writing part is byte-for-byte the sign-in this app made before
    /// this existed.
    public static let writing = "write:statuses write:favourites"

    /// The whole of what one sign-in asks for: reading, and the writing part after it where the
    /// reader agreed to it.
    ///
    /// **Reading first and writing last, always in this order**, because the string is also what a
    /// registration records and what `known(writing:)` compares against — two spellings of one ask
    /// would register twice for one choice.
    public static func scopes(reading: String = reading, writing wanted: Bool) -> String {
        wanted ? "\(reading) \(Self.writing)" : reading
    }

    /// The ladder one answer is asked on: what a sign-in registers for, and what it falls back to
    /// where the server refuses `read:search` (decision 32).
    ///
    /// **One owner for both rungs.** `MastodonSessions.signIn` needs them in order and needs to
    /// know which registrations it may reuse, and those were two derivations of one ladder in two
    /// files — true together only by inspection. `known(writing:)` is this, as a set.
    public static func registrations(writing wanted: Bool) -> (wide: String, narrow: String) {
        (scopes(writing: wanted), scopes(reading: readingWithoutSearch, writing: wanted))
    }

    /// The registrations this build may reuse for a sign-in that wants `writing`, or not.
    ///
    /// **It is per writing choice and not one list of everything.** A registration made for
    /// reading alone cannot carry a page that asks to write — the server answers `invalid_scope` —
    /// so a reader who signs in again to add writing must register again. The two rungs inside one
    /// choice are decision 32's: a host that refused `read:search` keeps its narrower registration
    /// rather than registering afresh every time.
    public static func known(writing wanted: Bool) -> Set<String> {
        let ladder = registrations(writing: wanted)
        return [ladder.wide, ladder.narrow]
    }

    /// Whether a scope string bought the writing part.
    ///
    /// **Compared scope by scope and never as a substring**, so a server that hands back the
    /// scopes in another order still reads as writing, and a scope that merely contains one of
    /// these words does not.
    public static func writes(_ scopes: String?) -> Bool {
        guard let scopes else { return false }
        let granted = Set(scopes.split(separator: " "))
        return writingScopes.allSatisfy(granted.contains)
    }

    /// `writing`, split once. This is asked of every held token at launch and again whenever the
    /// app comes to the front, so the constant is split once rather than once per item.
    private static let writingScopes: [Substring] = writing.split(separator: " ")

    let host: String
    private let sender: any HTTPSender

    public init(host: String, sender: any HTTPSender) {
        self.host = host.lowercased()
        self.sender = sender
    }

    /// Opens the server's page for `app`, checks the answer, trades the code for a token and
    /// proves the token works. Nothing is saved here. A token that fails the check is revoked
    /// before the failure is reported, so no working token is left behind on the server.
    public func signIn(as app: MastodonApp, through browser: any OAuthBrowser) async throws
        -> MastodonToken
    {
        let pkce = PKCE.make()
        let state = PKCE.random(bytes: 16)
        let scopes = app.scopes ?? Self.reading
        guard let page = authorizeURL(
            clientID: app.clientID, challenge: pkce.challenge, state: state, scopes: scopes
        ) else { throw MastodonSignInError.unreadable }
        let callback = try await browser.authorize(page, callbackScheme: Self.callbackScheme)
        let code = try Self.code(from: callback, state: state)
        let issued = try await exchange(
            code: code, verifier: pkce.verifier, clientID: app.clientID,
            clientSecret: app.clientSecret, scopes: scopes
        )
        let token = MastodonToken(
            host: host,
            accessToken: issued.accessToken,
            clientID: app.clientID,
            clientSecret: app.clientSecret,
            // What this token may actually do, kept with it — the one record of what the reader
            // agreed to. Without it a token kept by an earlier build and a token whose reader
            // refused the writing part are the same thing, and one of them has been asked and the
            // other has not.
            //
            // **The server's own answer where it sent one, and what was asked for only where it
            // did not.** A server may issue a narrower grant than it was asked for, and a row
            // reading back the asked string would say "read and write" about a token that cannot
            // write — the row's job is to say what may be done on the source, not what this
            // device intended. It cannot widen what the reader agreed to: the page they answered
            // asked for `scopes` and a server cannot grant past it.
            scopes: issued.scope.flatMap { $0.isEmpty ? nil : $0 } ?? scopes
        )
        do {
            try await verify(token)
        } catch {
            await revoke(token)
            throw error
        }
        return token
    }

    /// This app, registered on the server with the callback and `scopes`, which it records.
    public func register(scopes: String = MastodonOAuth.reading) async throws -> MastodonApp {
        struct Registered: Decodable {
            let client_id: String
            let client_secret: String
        }
        let answer: Registered = try await post("/api/v1/apps", [
            ("client_name", Fediqo.name),
            ("redirect_uris", Self.redirect),
            ("scopes", scopes),
        ])
        return MastodonApp(
            host: host, clientID: answer.client_id, clientSecret: answer.client_secret, scopes: scopes
        )
    }

    func authorizeURL(
        clientID: String, challenge: String, state: String, scopes: String = MastodonOAuth.reading
    ) -> URL? {
        Host.httpsURL(host: host, path: "/oauth/authorize", query: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
    }

    /// The code in the server's answer, once the answer is shown to be this attempt's: at this
    /// app's own callback, carrying the state it was sent.
    static func code(from callback: URL, state: String) throws -> String {
        guard callback.scheme?.lowercased() == callbackScheme,
              callback.host()?.lowercased() == "oauth"
        else { throw MastodonSignInError.unreadable }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "invalid_scope" ? MastodonSignInError.invalidScope : MastodonSignInError.denied
        }
        guard value("state") == state else { throw MastodonSignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw MastodonSignInError.unreadable }
        return code
    }

    /// The token, and **what the server says it granted** — which is not always what was asked
    /// for. `scope` is nothing where the server sent none; RFC 6749 lets it out only when the
    /// grant is exactly the request.
    func exchange(
        code: String, verifier: String, clientID: String, clientSecret: String,
        scopes: String = MastodonOAuth.reading
    ) async throws -> (accessToken: String, scope: String?) {
        struct Issued: Decodable {
            let access_token: String
            let scope: String?
        }
        let answer: Issued = try await post("/oauth/token", [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", Self.redirect),
            ("code_verifier", verifier),
            ("scope", scopes),
        ])
        guard !answer.access_token.isEmpty else { throw MastodonSignInError.unreadable }
        return (answer.access_token, answer.scope)
    }

    func verify(_ token: MastodonToken) async throws {
        guard let url = Host.httpsURL(host: host, path: "/api/v1/accounts/verify_credentials")
        else { throw MastodonSignInError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonSignInError.http(response.statusCode)
        }
    }

    /// Asks the server to forget the token. Best effort: signing out is done on this device
    /// before this is asked, and nothing it answers changes that.
    public func revoke(_ token: MastodonToken) async {
        guard let request = Self.form(host: host, path: "/oauth/revoke", [
            ("client_id", token.clientID),
            ("client_secret", token.clientSecret),
            ("token", token.accessToken),
        ]) else { return }
        _ = try? await sender.send(request)
    }

    private struct Refusal: Decodable { let error: String }

    private func post<Answer: Decodable>(
        _ path: String, _ fields: [(String, String)]
    ) async throws -> Answer {
        guard let request = Self.form(host: host, path: path, fields) else {
            throw MastodonSignInError.unreadable
        }
        let (body, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if (try? JSONDecoder().decode(Refusal.self, from: body))?.error == "invalid_client" {
                throw MastodonSignInError.clientRejected
            }
            throw MastodonSignInError.http(response.statusCode)
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: body) else {
            throw MastodonSignInError.unreadable
        }
        return answer
    }

    /// A transport failure is `.unreachable`; a reader walking away is `.cancelled`.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await sender.send(request)
        } catch {
            if Task.isCancelled || Cancellation.happened(error) {
                throw MastodonSignInError.cancelled
            }
            throw MastodonSignInError.unreachable
        }
    }

    static func form(host: String, path: String, _ fields: [(String, String)]) -> URLRequest? {
        guard let url = Host.httpsURL(host: host, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setForm(fields)
        return request
    }
}

extension URLRequest {
    /// `fields` as this request's form body, and the header that says so — the one encoding a
    /// sign-in and a signed-in write both send.
    ///
    /// Everything but RFC 3986's unreserved characters is escaped, so a `+`, `&` or `=` inside
    /// a secret or a status stays inside it.
    mutating func setForm(_ fields: [(String, String)]) {
        func escape(_ value: String) -> String {
            var unreserved = CharacterSet.alphanumerics
            unreserved.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        httpBody = Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }
}

/// The one door a signed-in request goes through (#25b reads Home and lists here).
///
/// The address is built from the token's own host, so the token is only ever sent there; a
/// redirect that leaves that origin is refused by `CappedBody`.
///
/// **Only a confirmed 401 signs out.** A 401 from any endpoint but the account check is asked
/// again of the account check, because a proxy in front of one path, or one endpoint's own rule,
/// must not wipe a token that works. Confirmed, the token is forgotten — only if it is still the
/// one held, so a late answer about a replaced token cannot take the new one — and `.signedOut`
/// is thrown. 403, 5xx and a failed connection leave it alone.
public struct MastodonAuthorized: Sendable {
    public let token: MastodonToken
    private let sender: any HTTPSender
    private let store: any MastodonTokenStore

    public init(token: MastodonToken, sender: any HTTPSender, store: any MastodonTokenStore) {
        self.token = token
        self.sender = sender
        self.store = store
    }

    static let accountCheck = "/api/v1/accounts/verify_credentials"

    public func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await finish(try await send(path: path, query: query), path: path)
    }

    /// A form POST through the same door: the token, the 401 rule, and never off this host.
    public func post(path: String, form: [(String, String)]) async throws -> Data {
        try await finish(try await send(path: path, method: "POST", form: form), path: path)
    }

    /// Who the reader is on this source, as `@user@host` — the spelling `Note.handle` takes, so a
    /// post can be told to be theirs by comparing the two (#109).
    ///
    /// **Asked of the source and never written down.** It is the account check's own answer, and
    /// a sign-in to a different account on the same host is a different answer: remembering it
    /// would be this device deciding whose posts are whose.
    public func handle() async throws -> String {
        struct Me: Decodable { let acct: String }
        let data = try await get(path: Self.accountCheck)
        guard let me = try? MastodonJSON.decoder.decode(Me.self, from: data) else {
            throw MastodonWriteError.unreadable
        }
        return StatusDTO.handle(me.acct, host: token.host)
    }

    /// A DELETE through the same door (#109): taking back what the reader wrote.
    public func delete(path: String) async throws -> Data {
        try await finish(try await send(path: path, method: "DELETE"), path: path)
    }

    private func finish(_ result: (Data, status: Int), path: String) async throws -> Data {
        switch result.status {
        case 200..<300:
            return result.0
        case 401:
            if path != Self.accountCheck,
               (try? await send(path: Self.accountCheck))?.status != 401
            {
                throw MastodonAuthError.http(401)
            }
            guard (try? store.forget(token)) == true else { throw MastodonAuthError.http(401) }
            throw MastodonAuthError.signedOut
        default:
            throw MastodonAuthError.http(result.status)
        }
    }

    private func send(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        form: [(String, String)]? = nil
    ) async throws -> (Data, status: Int) {
        guard let url = Host.httpsURL(host: token.host, path: path, query: query) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form { request.setForm(form) }
        let (body, response) = try await sender.send(request)
        return (body, response.statusCode)
    }
}
