import CryptoKit
import Foundation

/// Signing in to a server, as HTTP only.
///
/// The browser half of OAuth — opening the consent page, catching the redirect — never
/// enters Core: the app does that and hands the code back in. Everything here is a plain
/// request, so all of it runs against a stubbed transport in tests.
public protocol AuthClient: Sendable {
    /// Registers this app with the server; the credentials come back for keeping.
    func registerApp(host: String) async throws -> AppCredentials

    /// The consent page to hand the browser, PKCE challenge and state included.
    func authorizationURL(host: String, app: AppCredentials, pkce: PKCE, state: String) throws -> URL

    /// Trades the code the browser came back with for a token, proving the verifier.
    func exchangeCode(host: String, app: AppCredentials, code: String, pkce: PKCE) async throws -> OAuthToken

    /// Tells the server the token is finished. The caller decides how hard to insist.
    func revoke(host: String, app: AppCredentials, token: OAuthToken) async throws

    /// Who the token belongs to, keyed the same way the post path keys authors.
    func verifyCredentials(host: String, token: OAuthToken) async throws -> SignedInAccount
}

/// What a server issued this app at registration. Kept in the Keychain, JSON-encoded,
/// under `app:<endpoint>` — never in the database.
public struct AppCredentials: Codable, Sendable, Hashable {
    public let clientId: String
    public let clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// A token as the server granted it. Kept in the Keychain, JSON-encoded, under the
/// author_id it belongs to — the database keeps only the fact of being signed in.
public struct OAuthToken: Codable, Sendable, Hashable {
    public let accessToken: String
    public let scope: String
    public let createdAt: Date

    public init(accessToken: String, scope: String, createdAt: Date) {
        self.accessToken = accessToken
        self.scope = scope
        self.createdAt = createdAt
    }
}

/// Who signed in, said the way the timeline says it — the same author_id, or the store
/// would count a signed-in reader and their posts as two people.
public struct SignedInAccount: Sendable, Hashable {
    public let authorId: String
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?

    public init(authorId: String, handle: String, displayName: String, avatarURL: URL?) {
        self.authorId = authorId
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// One PKCE pair, S256 always. Generated fresh per sign-in: the consent page sees only the
/// challenge, and the verifier leaves the app only at the exchange.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes, spelt base64url — 43 characters of the allowed alphabet.
    public init() {
        self.init(verifier: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL)
    }

    /// The challenge is derived, never chosen: S256 over the ASCII verifier.
    public init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    /// base64 as RFC 7636 spells it: `-` and `_` for the two odd characters, no padding.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
