import Foundation
import Testing
@testable import FediqoCore

/// The HTTP half of signing in, browser not included: every request the OAuth dance makes,
/// against a stubbed transport, plus the PKCE arithmetic and the secret store's namespaces.
@Suite("Signing in over HTTP, browser not included")
struct AuthClientTests {
    private var client: MastodonAuthClient {
        MastodonAuthClient(session: stubbedSession())
    }

    private let app = AppCredentials(clientId: "id123", clientSecret: "sekrit")
    private let token = OAuthToken(accessToken: "tok3n", scope: "read write", createdAt: Date(timeIntervalSince1970: 1_755_856_800))

    /// The worked example in RFC 7636 appendix B, so the challenge is checked against
    /// someone else's arithmetic and not our own.
    private let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    @Test("Registering the app posts who we are, and keeps what came back")
    func registerApp() async throws {
        let host = "auth-register.test"
        stubRoutes.on(host, "/api/v1/apps", status: 200, body: """
        {"id": "5", "name": "Fediqo", "client_id": "id123", "client_secret": "sekrit", "redirect_uri": "fediqo://oauth"}
        """)

        let credentials = try await client.registerApp(host: "HTTPS://Auth-Register.test/")

        #expect(credentials == app)
        let request = try #require(stubRoutes.requests(for: host, "/api/v1/apps").first)
        #expect(request.method == "POST")
        #expect(request.fields == [
            "client_name": "Fediqo",
            "redirect_uris": "fediqo://oauth",
            "scopes": "read write",
        ])
    }

    @Test("The consent URL carries every parameter, challenge and state included")
    func authorizationURL() throws {
        let url = try client.authorizationURL(host: "consent.test", app: app, pkce: PKCE(verifier: rfcVerifier), state: "st4te")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "consent.test")
        #expect(components.path == "/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "response_type": "code",
            "client_id": "id123",
            "redirect_uri": "fediqo://oauth",
            "scope": "read write",
            "state": "st4te",
            "code_challenge": rfcChallenge,
            "code_challenge_method": "S256",
        ])
    }

    @Test("Exchanging the code proves the verifier, and reads the token back")
    func exchangeCode() async throws {
        let host = "auth-token.test"
        stubRoutes.on(host, "/oauth/token", status: 200, body: """
        {"access_token": "tok3n", "token_type": "Bearer", "scope": "read write", "created_at": 1755856800}
        """)

        let granted = try await client.exchangeCode(host: host, app: app, code: "c0de", pkce: PKCE(verifier: rfcVerifier))

        #expect(granted == token)
        let request = try #require(stubRoutes.requests(for: host, "/oauth/token").first)
        #expect(request.fields == [
            "grant_type": "authorization_code",
            "client_id": "id123",
            "client_secret": "sekrit",
            "redirect_uri": "fediqo://oauth",
            "code": "c0de",
            "code_verifier": rfcVerifier,
        ])
    }

    @Test("A refused exchange fails as itself, not as a stranger being turned away")
    func exchangeRefused() async {
        let host = "auth-refused.test"
        stubRoutes.on(host, "/oauth/token", status: 401, body: """
        {"error": "invalid_grant", "error_description": "code is spent"}
        """)

        await #expect(throws: SourceFailure.signInFailed("code is spent")) {
            _ = try await client.exchangeCode(host: host, app: app, code: "c0de", pkce: PKCE())
        }
    }

    @Test("Revoking posts the token with the app's credentials")
    func revoke() async throws {
        let host = "auth-revoke.test"
        stubRoutes.on(host, "/oauth/revoke", status: 200, body: "{}")

        try await client.revoke(host: host, app: app, token: token)

        let request = try #require(stubRoutes.requests(for: host, "/oauth/revoke").first)
        #expect(request.fields == [
            "client_id": "id123",
            "client_secret": "sekrit",
            "token": "tok3n",
        ])
    }

    @Test("Whoever signed in is keyed as the post path keys them: by the actor URI")
    func verifyCredentials() async throws {
        let host = "auth-me.test"
        stubRoutes.on(host, "/api/v1/accounts/verify_credentials", status: 200, body: """
        {"id": "10", "url": "https://auth-me.test/@ada", "username": "ada", "acct": "ada",
         "display_name": "Ada", "avatar": "https://auth-me.test/a.png"}
        """)

        let account = try await client.verifyCredentials(host: host, token: token)

        #expect(account.authorId == "https://auth-me.test/@ada")
        #expect(account.handle == "@ada@auth-me.test")
        #expect(account.displayName == "Ada")
        #expect(account.avatarURL == URL(string: "https://auth-me.test/a.png"))
        let request = try #require(stubRoutes.requests(for: host, "/api/v1/accounts/verify_credentials").first)
        #expect(request.authorization == "Bearer tok3n")
    }

    @Test("Without an actor URI, the stand-in is the very one the post path derives")
    func verifyCredentialsWithoutActorURI() async throws {
        let host = "auth-noactor.test"
        let body = """
        {"id": "10", "username": "bee", "acct": "bee", "display_name": "", "avatar": null}
        """
        stubRoutes.on(host, "/api/v1/accounts/verify_credentials", status: 200, body: body)

        let account = try await client.verifyCredentials(host: host, token: token)

        let dto = try MastodonClient.decoder.decode(MastodonDTO.Account.self, from: Data(body.utf8))
        #expect(account.authorId == dto.authorId(on: host))
        #expect(account.authorId == "https://auth-noactor.test/@bee")
        #expect(account.displayName == "bee")
    }

    @Test("The RFC 7636 vector: verifier to S256 challenge")
    func pkceVector() {
        #expect(PKCE(verifier: rfcVerifier).challenge == rfcChallenge)
    }

    @Test("A fresh pair is 43 characters of the base64url alphabet, and fresh every time")
    func pkceFresh() {
        let one = PKCE()
        let two = PKCE()
        #expect(one.verifier != two.verifier)
        #expect(one.verifier.count == 43)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(one.verifier.allSatisfy { alphabet.contains($0) })
        #expect(one.challenge == PKCE(verifier: one.verifier).challenge)
    }

    @Test("The standard registry can sign in wherever it can read")
    func registryHasAuthClient() {
        #expect(SourceRegistry.standard().authClient(for: .mastodon) != nil)
        #expect(SourceRegistry.standard().authClient(for: .nostr) == nil)
    }
}

@Suite("Keeping secrets by name")
struct SecretStoreTests {
    @Test("A secret round-trips, and forgetting is idempotent")
    func roundTrip() throws {
        let store = InMemorySecretStore()
        try store.setSecret(Data("s3cret".utf8), for: "a-name")
        #expect(try store.secret(for: "a-name") == Data("s3cret".utf8))
        try store.removeSecret(for: "a-name")
        #expect(try store.secret(for: "a-name") == nil)
        try store.removeSecret(for: "a-name")
    }

    @Test("App credentials and a token under the same name never collide")
    func namespaces() throws {
        let store = InMemorySecretStore()
        let credentials = AppCredentials(clientId: "id", clientSecret: "secret")
        let token = OAuthToken(accessToken: "tok", scope: "read write", createdAt: Date(timeIntervalSince1970: 1))

        try store.setAppCredentials(credentials, for: "x.test")
        try store.setToken(token, for: "x.test")

        #expect(try store.appCredentials(for: "x.test") == credentials)
        #expect(try store.token(for: "x.test") == token)

        try store.removeToken(for: "x.test")
        #expect(try store.token(for: "x.test") == nil)
        #expect(try store.appCredentials(for: "x.test") == credentials)
    }
}
