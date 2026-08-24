import Foundation

/// Signs a reader in to a Mastodon server, and out again. Only the HTTP half of OAuth
/// lives here — the app opens the browser and catches `fediqo://oauth`; the Keychain is
/// `SecretStore`'s business — so every request here runs against a stubbed transport.
public struct MastodonAuthClient: AuthClient {
    /// Where the browser comes back to. The app registers the scheme; this client only
    /// promises it to the server, and the promise must match at every step.
    public static let redirectURI = "fediqo://oauth"

    /// The scheme of that promise — what the sign-in session watches the browser for.
    public var callbackScheme: String { URL(string: Self.redirectURI)!.scheme! }

    /// Registered and authorized alike: consent shows write once, posting later needs nothing.
    static let scope = "read write"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func registerApp(host rawHost: String) async throws -> AppCredentials {
        let data = try await postForm(endpoint(rawHost, "/api/v1/apps"), fields: [
            "client_name": "Fediqo",
            "redirect_uris": Self.redirectURI,
            "scopes": Self.scope,
        ])
        return try JSONDecoder.snakeCaseSeconds.decode(AppCredentials.self, from: data)
    }

    public func authorizationURL(host rawHost: String, app: AppCredentials, pkce: PKCE, state: String) throws -> URL {
        try endpoint(rawHost, "/oauth/authorize", query: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: app.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
    }

    public func exchangeCode(host rawHost: String, app: AppCredentials, code: String, pkce: PKCE) async throws -> OAuthToken {
        let data = try await postForm(endpoint(rawHost, "/oauth/token"), fields: [
            "grant_type": "authorization_code",
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "redirect_uri": Self.redirectURI,
            "code": code,
            "code_verifier": pkce.verifier,
        ])
        return try JSONDecoder.snakeCaseSeconds.decode(OAuthToken.self, from: data)
    }

    public func revoke(host rawHost: String, app: AppCredentials, token: OAuthToken) async throws {
        _ = try await postForm(endpoint(rawHost, "/oauth/revoke"), fields: [
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "token": token.accessToken,
        ])
    }

    public func verifyCredentials(host rawHost: String, token: OAuthToken) async throws -> SignedInAccount {
        let host = try Server.validated(rawHost)
        let data = try await JSONTransport.get(
            endpoint(host, "/api/v1/accounts/verify_credentials"),
            on: session,
            authorization: "Bearer \(token.accessToken)"
        )
        // The same DTO and the same derivations the timeline uses: whoever signed in is
        // keyed exactly as their posts are, never by a second derivation.
        let account = try MastodonClient.decoder.decode(MastodonDTO.Account.self, from: data)
        return SignedInAccount(
            authorId: account.authorId(on: host),
            handle: account.handle(on: host),
            displayName: account.name,
            avatarURL: account.avatar.flatMap(URL.init(string:))
        )
    }

    /// Every URL asked of the server: the gate `MastodonClient` keeps — nothing that is not
    /// a hostname reaches the network — and then assembly, which says so rather than
    /// stopping if a validated host still refuses to make a URL.
    private func endpoint(_ rawHost: String, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = try Server.validated(rawHost)
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SourceFailure.badHost(rawHost) }
        return url
    }

    /// A refusal mid-handshake is `signInFailed`, never a stranger being turned away: the
    /// transport stays neutral, and the OAuth reading of its refusals lives here.
    private func postForm(_ url: URL, fields: [String: String]) async throws -> Data {
        do {
            return try await JSONTransport.postForm(url, fields: fields, on: session)
        } catch SourceFailure.http(let status, let body) where [400, 401, 403, 422].contains(status) {
            throw SourceFailure.signInFailed(Self.refusalReason(in: body) ?? "The server answered \(status).")
        }
    }

    /// OAuth refusals arrive as `{"error": …, "error_description": …}`, either half optional.
    private static func refusalReason(in data: Data) -> String? {
        struct Refusal: Decodable {
            let error: String?
            let errorDescription: String?
        }
        let refusal = try? JSONDecoder.snakeCaseSeconds.decode(Refusal.self, from: data)
        return refusal?.errorDescription ?? refusal?.error
    }
}
