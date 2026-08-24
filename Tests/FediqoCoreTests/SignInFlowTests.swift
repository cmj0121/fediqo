import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// An `AuthClient` that answers from fixtures and writes down what was asked of it — the
/// seam's tests care about what reaches the store and the secret store, not about HTTP.
private final class ScriptedAuthClient: AuthClient, @unchecked Sendable {
    private let lock = NSLock()
    private var account: SignedInAccount
    private var revokeError: Error?
    private(set) var registeredHosts: [String] = []
    private(set) var exchangedCodes: [String] = []
    private(set) var revokedTokens: [String] = []
    private(set) var networkCalls = 0

    init(account: SignedInAccount) {
        self.account = account
    }

    var redirectURI: URL { URL(string: "fediqo://oauth")! }

    func answers(as account: SignedInAccount) {
        lock.withLock { self.account = account }
    }

    func refusesRevoke(with error: Error) {
        lock.withLock { revokeError = error }
    }

    func registerApp(host: String) async throws -> AppCredentials {
        lock.withLock {
            networkCalls += 1
            registeredHosts.append(host)
            return AppCredentials(clientId: "id-\(registeredHosts.count)", clientSecret: "secret")
        }
    }

    func authorizationURL(host: String, app: AppCredentials, pkce: PKCE, state: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: app.clientId),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Tokens are numbered, not derived from the code — two sign-ins with the same code
    /// still get tokens a test can tell apart.
    func exchangeCode(host: String, app: AppCredentials, code: String, pkce: PKCE) async throws -> OAuthToken {
        let serial = lock.withLock {
            networkCalls += 1
            exchangedCodes.append(code)
            return exchangedCodes.count
        }
        return OAuthToken(accessToken: "token-\(serial)", scope: "read write", createdAt: Date(timeIntervalSince1970: 1))
    }

    func revoke(host: String, app: AppCredentials, token: OAuthToken) async throws {
        let refused = lock.withLock {
            networkCalls += 1
            return revokeError
        }
        if let refused { throw refused }
        lock.withLock { revokedTokens.append(token.accessToken) }
    }

    func verifyCredentials(host: String, token: OAuthToken) async throws -> SignedInAccount {
        lock.withLock {
            networkCalls += 1
            return account
        }
    }
}

/// The browser, boiled down: reads the `state` off the consent URL and comes straight back
/// approved. What the real one does through ASWebAuthenticationSession, minus the person.
@Sendable private func approving(_ consent: URL, _ scheme: String) async throws -> URL {
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let state = query.first { $0.name == "state" }?.value ?? ""
    return URL(string: "\(scheme)://oauth?code=c0de&state=\(state)")!
}

/// Everything one sign-in test stands on, built fresh per test.
private struct Harness {
    let store: LocalStore
    let secrets = InMemorySecretStore()
    let auth: ScriptedAuthClient
    let coordinator: SignInCoordinator

    init(answering account: SignedInAccount) throws {
        store = try LocalStore.inMemory()
        auth = ScriptedAuthClient(account: account)
        coordinator = SignInCoordinator(store: store)
    }

    @discardableResult
    func signIn(to server: Server,
                authenticate: @Sendable (URL, String) async throws -> URL = approving) async throws -> SignedInAccount {
        try await coordinator.signIn(server: server, using: auth, secrets: secrets, authenticate: authenticate)
    }

    func signOut(_ authorId: String) async {
        await coordinator.signOut(authorId: authorId, using: auth, secrets: secrets)
    }

    func ownedRows() async throws -> [String] {
        try await store.read { db in
            try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts ORDER BY author_id")
        }
    }
}

@Suite("Signing in, as the store remembers it")
struct SignInFlowTests {
    private let server = makeServer("owned.test")
    private let ada = SignedInAccount(
        authorId: "https://owned.test/@ada",
        handle: "@ada@owned.test",
        displayName: "Ada",
        avatarURL: URL(string: "https://owned.test/a.png")
    )
    private let bee = SignedInAccount(
        authorId: "https://owned.test/@bee",
        handle: "@bee@owned.test",
        displayName: "Bee",
        avatarURL: nil
    )

    @Test("The happy path keeps the token, the app credentials, and the fact — and says who")
    func happyPath() async throws {
        let h = try Harness(answering: ada)

        let signedIn = try await h.signIn(to: server)

        #expect(signedIn == ada)
        #expect(try h.secrets.token(for: ada.authorId)?.accessToken == "token-1")
        #expect(try h.secrets.appCredentials(for: "https://owned.test") != nil)
        #expect(try await h.ownedRows() == [ada.authorId])
        #expect(h.auth.exchangedCodes == ["c0de"])
    }

    @Test("A state that comes back changed ends the flow: no token, no row, no exchange")
    func stateMismatch() async throws {
        let h = try Harness(answering: ada)

        await #expect(throws: SourceFailure.signInFailed("the state came back changed")) {
            try await h.signIn(to: server) { _, scheme in
                URL(string: "\(scheme)://oauth?code=c0de&state=someone-elses")!
            }
        }

        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try await h.ownedRows().isEmpty)
        #expect(h.auth.exchangedCodes.isEmpty)
    }

    @Test("A second account on the same server signs the first out: revoked, token and row gone")
    func secondAccountDisplacesTheFirst() async throws {
        let h = try Harness(answering: ada)

        try await h.signIn(to: server)
        h.auth.answers(as: bee)
        try await h.signIn(to: server)

        #expect(h.auth.revokedTokens == ["token-1"])
        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try h.secrets.token(for: bee.authorId)?.accessToken == "token-2")
        #expect(try await h.ownedRows() == [bee.authorId])
    }

    @Test("A displaced revoke the server refuses does not stop the new sign-in")
    func displacedRevokeFailureKeepsTheNewSignIn() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)
        h.auth.refusesRevoke(with: URLError(.notConnectedToInternet))
        h.auth.answers(as: bee)

        try await h.signIn(to: server)

        #expect(h.auth.revokedTokens.isEmpty)
        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try h.secrets.token(for: bee.authorId) != nil)
        #expect(try await h.ownedRows() == [bee.authorId])
    }

    @Test("The app is registered once; a second sign-in reuses the kept credentials")
    func appCredentialsAreReused() async throws {
        let h = try Harness(answering: ada)

        try await h.signIn(to: server)
        try await h.signIn(to: server)

        #expect(h.auth.registeredHosts == ["owned.test"])
        #expect(try h.secrets.appCredentials(for: "https://owned.test")?.clientId == "id-1")
    }

    @Test("Signing out revokes, forgets the token, and deletes the row")
    func signOut() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)

        await h.signOut(ada.authorId)

        #expect(h.auth.revokedTokens == ["token-1"])
        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try await h.ownedRows().isEmpty)
    }

    @Test("A revoke the server refuses still signs out locally — decision 6")
    func signOutSurvivesFailingRevoke() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)
        h.auth.refusesRevoke(with: URLError(.notConnectedToInternet))

        await h.signOut(ada.authorId)

        #expect(h.auth.revokedTokens.isEmpty)
        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try await h.ownedRows().isEmpty)
    }

    @Test("Signing out of a whole server takes every owned account with it")
    func signOutAll() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)

        await h.coordinator.signOutAll(for: server.endpoint, using: h.auth, secrets: h.secrets)

        #expect(try h.secrets.token(for: ada.authorId) == nil)
        #expect(try await h.ownedRows().isEmpty)
    }

    @Test("signedIn() answers from the rows alone: handle, name, avatar, and no network")
    func signedInRoundTrips() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)
        let callsBefore = h.auth.networkCalls

        let accounts = try await h.store.signedIn()

        #expect(accounts == [ada])
        #expect(h.auth.networkCalls == callsBefore)
    }

    @Test("The fact never lands alone: the account and server rows are in the same transaction")
    func foreignKeysHold() async throws {
        let h = try Harness(answering: ada)
        try await h.signIn(to: server)

        let (accountRows, serverRows, violations) = try await h.store.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts WHERE author_id = ?",
                              arguments: ["https://owned.test/@ada"]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM servers WHERE url = 'https://owned.test'") ?? 0,
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
        #expect(accountRows == 1)
        #expect(serverRows == 1)
        #expect(violations == 0)
    }
}
