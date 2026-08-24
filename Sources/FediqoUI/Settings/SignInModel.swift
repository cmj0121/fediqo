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

    /// The endpoints whose token a server has turned down — the launch check's answer, and
    /// whatever a read has since run into. In memory only, never written down: whether a
    /// token works is the server's answer, and it is asked again next launch. Nothing here
    /// retries on the reader's behalf; the set empties only by signing in again or out.
    private(set) var rejected: Set<String> = []

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

    /// Whether this server has stopped accepting the account signed in to it.
    func isRejected(_ server: Server) -> Bool {
        rejected.contains(server.endpoint)
    }

    /// A server said no to the credential — from the launch check, or from a read that
    /// carried the token and was turned down. Said once; saying it again changes nothing.
    func markRejected(_ endpoint: String) {
        rejected.insert(endpoint)
    }

    /// Asks every signed-in server, once, whether its credential still works. Meant for
    /// launch: nothing waits on it, and a server that cannot answer marks nothing.
    func checkTokens(on servers: [Server]) async {
        rejected.formUnion(await coordinator.rejectedEndpoints(among: servers, using: registry))
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
            // A credential the server has just accepted is not a rejected one.
            rejected.remove(server.endpoint)
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
        rejected.remove(server.endpoint)
        await coordinator.signOutAll(for: server.endpoint, using: auth)
        await refresh()
    }
}
