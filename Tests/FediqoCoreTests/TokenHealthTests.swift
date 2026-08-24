import Foundation
import Testing
@testable import FediqoCore

/// One signed-in account, and the coordinator that checks on it — the launch check's whole
/// world. The secret store is in-memory, so no test here goes near the real Keychain.
private struct Checked {
    let store: LocalStore
    let secrets = InMemorySecretStore()
    let auth: ScriptedAuthClient
    let coordinator: SignInCoordinator
    let registry: SourceRegistry

    init(answering account: SignedInAccount) throws {
        store = try LocalStore.inMemory()
        auth = ScriptedAuthClient(account: account)
        coordinator = SignInCoordinator(store: store, secrets: secrets)
        registry = SourceRegistry(clients: [:], authClients: [.mastodon: auth])
    }

    /// Signed in for real through the coordinator, so the rows and the token are exactly
    /// what the app would have left behind.
    func signIn(to server: Server) async throws {
        _ = try await coordinator.signIn(server: server, using: auth) { consent, scheme in
            let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = query.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme)://oauth?code=c0de&state=\(state)")!
        }
    }

    func rejected(among servers: [Server]) async -> Set<String> {
        await coordinator.rejectedEndpoints(among: servers, using: registry)
    }
}

/// Whether a token still works is the server's answer, asked once. Only a refusal counts.
@Suite("The launch check on a signed-in account")
struct TokenHealthTests {
    private let server = makeServer("checked.test")
    private let ada = SignedInAccount(
        authorId: "https://checked.test/@ada",
        handle: "@ada@checked.test",
        displayName: "Ada",
        avatarURL: nil
    )

    @Test("A server that turns the credential down names its endpoint")
    func rejectedTokenIsReported() async throws {
        let c = try Checked(answering: ada)
        try await c.signIn(to: server)
        c.auth.refusesVerify(with: SourceFailure.tokenRejected(server.host))

        #expect(await c.rejected(among: [server]) == [server.endpoint])
    }

    @Test("A server that still accepts the credential names nothing")
    func acceptedTokenIsNotReported() async throws {
        let c = try Checked(answering: ada)
        try await c.signIn(to: server)

        #expect(await c.rejected(among: [server]).isEmpty)
    }

    @Test("A server that cannot answer is not a verdict on the credential")
    func offlineServerReportsNothing() async throws {
        let c = try Checked(answering: ada)
        try await c.signIn(to: server)
        c.auth.refusesVerify(with: URLError(.notConnectedToInternet))

        #expect(await c.rejected(among: [server]).isEmpty)
    }

    @Test("Nobody signed in, nothing asked")
    func nothingOwnedAsksNothing() async throws {
        let c = try Checked(answering: ada)
        let callsBefore = c.auth.networkCalls

        #expect(await c.rejected(among: [server]).isEmpty)
        #expect(c.auth.networkCalls == callsBefore)
    }

    @Test("A server nobody owns an account on is not asked, even beside one that is")
    func onlyOwnedServersAreAsked() async throws {
        let c = try Checked(answering: ada)
        try await c.signIn(to: server)
        let callsBefore = c.auth.networkCalls
        c.auth.refusesVerify(with: SourceFailure.tokenRejected(server.host))

        #expect(await c.rejected(among: [server, makeServer("stranger.test")]) == [server.endpoint])
        #expect(c.auth.networkCalls == callsBefore + 1)
    }
}
