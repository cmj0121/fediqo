import CryptoKit
import Foundation
import Security

// Signing in to a Mastodon server: OAuth 2 authorization code with PKCE (S256) and `state`, on
// the server's own page, asking only to read.
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
    public static let scopes = "read:statuses read:lists read:accounts read:search"

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
        guard let page = authorizeURL(
            clientID: app.clientID, challenge: pkce.challenge, state: state
        ) else { throw MastodonSignInError.unreadable }
        let callback = try await browser.authorize(page, callbackScheme: Self.callbackScheme)
        let code = try Self.code(from: callback, state: state)
        let token = MastodonToken(
            host: host,
            accessToken: try await exchange(
                code: code, verifier: pkce.verifier, clientID: app.clientID,
                clientSecret: app.clientSecret
            ),
            clientID: app.clientID,
            clientSecret: app.clientSecret
        )
        do {
            try await verify(token)
        } catch {
            await revoke(token)
            throw error
        }
        return token
    }

    /// This app, registered on the server with the callback and the read scopes.
    public func register() async throws -> MastodonApp {
        struct Registered: Decodable {
            let client_id: String
            let client_secret: String
        }
        let answer: Registered = try await post("/api/v1/apps", [
            ("client_name", Fediqo.name),
            ("redirect_uris", Self.redirect),
            ("scopes", Self.scopes),
        ])
        return MastodonApp(
            host: host, clientID: answer.client_id, clientSecret: answer.client_secret, scopes: Self.scopes
        )
    }

    func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        Host.httpsURL(host: host, path: "/oauth/authorize", query: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "scope", value: Self.scopes),
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

    func exchange(
        code: String, verifier: String, clientID: String, clientSecret: String
    ) async throws -> String {
        struct Issued: Decodable { let access_token: String }
        let answer: Issued = try await post("/oauth/token", [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", Self.redirect),
            ("code_verifier", verifier),
            ("scope", Self.scopes),
        ])
        guard !answer.access_token.isEmpty else { throw MastodonSignInError.unreadable }
        return answer.access_token
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
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(
            fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8
        )
        return request
    }

    /// Form encoding: everything but RFC 3986's unreserved characters is escaped, so a `+`, `&`
    /// or `=` inside a secret stays inside it.
    private static func escape(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
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
        let (body, status) = try await send(path: path, query: query)
        switch status {
        case 200..<300:
            return body
        case 401:
            if path != Self.accountCheck,
               (try? await send(path: Self.accountCheck, query: []))?.status != 401
            {
                throw MastodonAuthError.http(401)
            }
            guard (try? store.forget(token)) == true else { throw MastodonAuthError.http(401) }
            throw MastodonAuthError.signedOut
        default:
            throw MastodonAuthError.http(status)
        }
    }

    private func send(path: String, query: [URLQueryItem]) async throws -> (Data, status: Int) {
        guard let url = Host.httpsURL(host: token.host, path: path, query: query) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await sender.send(request)
        return (body, response.statusCode)
    }
}
