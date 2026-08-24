import AuthenticationServices
import Foundation
import Observation
import FediqoCore

/// The sign-in half of the server list: who is signed in where, and the two verbs.
///
/// The browser stays the view's business — `signIn` takes an `authenticate` closure because
/// `ASWebAuthenticationSession` lives in the SwiftUI environment, which only a view can read.
@MainActor
@Observable
final class SignInModel {
    private let store: LocalStore
    private let registry: SourceRegistry
    private let secrets: any SecretStore
    private let coordinator: SignInCoordinator

    /// Who is signed in, keyed by `Server.endpoint` — one account per server (decision 9).
    private(set) var accounts: [String: SignedInAccount] = [:]

    /// Why the last sign-in gave nothing. Cleared when it is retried.
    private(set) var failure: SourceFailure?

    init(store: LocalStore, registry: SourceRegistry = .standard(),
         secrets: any SecretStore = KeychainSecretStore()) {
        self.store = store
        self.registry = registry
        self.secrets = secrets
        self.coordinator = SignInCoordinator(store: store)
    }

    /// Whether this build can sign in to this server at all. No client, no button.
    func canSignIn(to server: Server) -> Bool {
        registry.authClient(for: server.socialProtocol) != nil
    }

    func account(on server: Server) -> SignedInAccount? {
        accounts[server.endpoint]
    }

    func refresh() async {
        accounts = (try? await store.signedInByServer()) ?? [:]
    }

    func signIn(to server: Server, authenticate: @escaping @Sendable (URL, String) async throws -> URL) async {
        guard let auth = registry.authClient(for: server.socialProtocol) else { return }
        failure = nil
        do {
            accounts[server.endpoint] = try await coordinator.signIn(
                server: server, using: auth, secrets: secrets, authenticate: authenticate)
        } catch let refused as SourceFailure {
            failure = refused
        } catch let closed as ASWebAuthenticationSessionError where closed.code == .canceledLogin {
            // Closing the browser is a decision, not a failure.
        } catch {
            failure = .signInFailed(error.localizedDescription)
        }
    }

    /// Signs out every owned account on the server. One account per server is policy
    /// (decision 9), so this is the row's Sign out too — and what removing a server, or
    /// forgetting them all, calls per server (decision 8).
    func signOut(of server: Server) async {
        guard let auth = registry.authClient(for: server.socialProtocol) else { return }
        await coordinator.signOutAll(for: server.endpoint, using: auth, secrets: secrets)
        accounts[server.endpoint] = nil
    }
}
