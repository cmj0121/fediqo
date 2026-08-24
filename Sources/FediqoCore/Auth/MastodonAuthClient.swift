import Foundation

/// Signs a reader in to a Mastodon server, and out again. Only the HTTP half of OAuth
/// lives here — the app opens the browser and catches `fediqo://oauth`; the Keychain is
/// `SecretStore`'s business — so every request here runs against a stubbed transport.
public struct MastodonAuthClient: AuthClient {
    /// Where the browser comes back to. The app registers the scheme; this client only
    /// promises it to the server, and the promise must match at every step.
    public static let redirectURI = "fediqo://oauth"

    /// Registered and authorized alike: consent shows write once, posting later needs nothing.
    static let scope = "read write"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Token answers carry `created_at` as whole epoch seconds, unlike statuses, so the
    /// auth path has a decoder of its own.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public func registerApp(host rawHost: String) async throws -> AppCredentials {
        let host = try normalised(rawHost)
        let data = try await JSONTransport.postForm(endpoint(host, "/api/v1/apps"), fields: [
            "client_name": "Fediqo",
            "redirect_uris": Self.redirectURI,
            "scopes": Self.scope,
        ], on: session)
        return try Self.decoder.decode(AppCredentials.self, from: data)
    }

    public func authorizationURL(host rawHost: String, app: AppCredentials, pkce: PKCE, state: String) throws -> URL {
        let host = try normalised(rawHost)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: app.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw SourceFailure.badHost(rawHost) }
        return url
    }

    public func exchangeCode(host rawHost: String, app: AppCredentials, code: String, pkce: PKCE) async throws -> OAuthToken {
        let host = try normalised(rawHost)
        let data = try await JSONTransport.postForm(endpoint(host, "/oauth/token"), fields: [
            "grant_type": "authorization_code",
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "redirect_uri": Self.redirectURI,
            "code": code,
            "code_verifier": pkce.verifier,
        ], on: session)
        return try Self.decoder.decode(OAuthToken.self, from: data)
    }

    public func revoke(host rawHost: String, app: AppCredentials, token: OAuthToken) async throws {
        let host = try normalised(rawHost)
        _ = try await JSONTransport.postForm(endpoint(host, "/oauth/revoke"), fields: [
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "token": token.accessToken,
        ], on: session)
    }

    public func verifyCredentials(host rawHost: String, token: OAuthToken) async throws -> SignedInAccount {
        let host = try normalised(rawHost)
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

    /// The same gate `MastodonClient` keeps: nothing that is not a hostname reaches the network.
    private func normalised(_ rawHost: String) throws -> String {
        let host = Server.normalise(rawHost)
        guard Server.looksLikeHost(host) else { throw SourceFailure.badHost(rawHost) }
        return host
    }

    /// A normalised host always assembles: the guard above already refused anything that would not.
    private func endpoint(_ host: String, _ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        return components.url!
    }
}
