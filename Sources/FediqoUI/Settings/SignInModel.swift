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
    private let coordinator: SignInCoordinator

    /// Who is signed in, keyed by `Server.endpoint` — one account per server (decision 9).
    private(set) var accounts: [String: SignedInAccount] = [:]

    /// Why the last sign-in gave nothing. Cleared when it is retried.
    private(set) var failure: SourceFailure?

    init(store: LocalStore, registry: SourceRegistry = .standard(),
         secrets: any SecretStore = KeychainSecretStore()) {
        self.store = store
        self.registry = registry
        self.coordinator = SignInCoordinator(store: store, secrets: secrets)
    }

    /// Whether this build can sign in to this server at all. No client, no button.
    /// Counts the reads, so a slow one cannot overwrite a newer one. See `refresh()`.
    private var generation = 0

    func canSignIn(to server: Server) -> Bool {
        registry.authClient(for: server.socialProtocol) != nil
    }

    func account(on server: Server) -> SignedInAccount? {
        accounts[server.endpoint]
    }

    /// Re-reads who is signed in. Two of these can be in flight at once — forgetting every
    /// server signs each out concurrently — and the one that started last has read the
    /// truest answer, so an older read that comes back afterwards is dropped rather than
    /// allowed to reinstate an account that has since gone.
    func refresh() async {
        generation += 1
        let mine = generation
        let latest = (try? await store.signedInByServer()) ?? [:]
        guard mine == generation else { return }
        if latest != accounts { accounts = latest }
    }

    func signIn(to server: Server, authenticate: @escaping @Sendable (URL, String) async throws -> URL) async {
        guard let auth = registry.authClient(for: server.socialProtocol) else { return }
        failure = nil
        do {
            _ = try await coordinator.signIn(server: server, using: auth, authenticate: authenticate)
            // What is shown is always what the store remembers, re-read rather than patched.
            await refresh()
        } catch let refused as SourceFailure {
            failure = refused
        } catch is CancellationError {
            // Closing the browser is a decision, not a failure.
        } catch {
            failure = .signInFailed(error.localizedDescription)
        }
    }

    /// Signs out every owned account on the server. One account per server is policy
    /// (decision 9), so this is the row's Sign out too — and what removing a server, or
    /// forgetting them all, calls per server (decision 8). The row empties at once; the
    /// revoke keeps its background, best-effort manner.
    func signOut(of server: Server) async {
        guard let auth = registry.authClient(for: server.socialProtocol) else { return }
        accounts[server.endpoint] = nil
        await coordinator.signOutAll(for: server.endpoint, using: auth)
        await refresh()
    }
}
