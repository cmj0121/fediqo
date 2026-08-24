import Foundation

/// The one place a read finds out who it is.
///
/// `LocalStore.tokens(using:for:)` is still the walk — the rows say who is signed in where,
/// the Keychain says what proves it. This is what stands in front of it, and it does two
/// things that walk cannot do for itself:
///
/// - It keeps what it found. Who is signed in changes when somebody signs in or out and at
///   no other moment, so a page refreshing itself every thirty seconds has no business
///   opening the Keychain every thirty seconds. `invalidate()` is how it is told.
/// - It stops sending a credential that has already been turned down. A server that said no
///   will say no again; `markRejected(_:)` takes that endpoint's token out of every answer
///   until someone signs in again, and the read goes out as a stranger instead.
///
/// One of these is shared by everything that needs to know: the loader that reads timelines
/// and the launch check that asks every signed-in server whether its credential still works.
public actor TokenSource {
    private let store: LocalStore
    private let secrets: any SecretStore

    /// What is known about each endpoint asked about so far: a token to read it as, or nil
    /// where there is none to be had — nobody is signed in there, or the credential they
    /// signed in with has since been refused. A key that is absent has not been looked up;
    /// a key holding nil has, and the answer was no. Both read as "no token", so a caller
    /// cannot tell them apart, and only this actor has to.
    private var known: [String: OAuthToken?] = [:]

    /// Bumped by every `invalidate()`. A look-up carries the number it started under, and
    /// writes nothing if that number has moved — an actor is only exclusive between
    /// suspension points, and the walk below has one in the middle of it.
    private var generation = 0

    public init(store: LocalStore, secrets: any SecretStore) {
        self.store = store
        self.secrets = secrets
    }

    /// The token each of `servers` is read as. Only endpoints never looked up are looked up,
    /// so a page refreshing itself stops asking the Keychain about a server it already has an
    /// answer for — and an endpoint whose credential has already been refused is answered
    /// from here without asking anybody, so the read goes out as a stranger instead.
    ///
    /// Two loads starting at once can both find the same endpoint unknown and both walk for
    /// it. That costs a second look-up and nothing else: whichever finishes first is kept,
    /// and the loser writes nothing, so they cannot disagree.
    public func tokens(for servers: [Server]) async -> [String: OAuthToken] {
        let unknown = servers.filter { known.index(forKey: $0.endpoint) == nil }
        if !unknown.isEmpty {
            let startedUnder = generation
            let found = await store.tokens(using: secrets, for: unknown)
            // Back from the suspension, and the world may have moved: somebody signed out
            // while we were away, and what we just read is about a person who has left.
            if startedUnder == generation {
                // Only what is *still* unknown is filled in. A `markRejected` that landed
                // mid-walk is an answer newer than this one, and it stands.
                for server in unknown where known.index(forKey: server.endpoint) == nil {
                    known[server.endpoint] = .some(found[server.endpoint])
                }
            }
        }
        return servers.reduce(into: [:]) { tokens, server in
            tokens[server.endpoint] = known[server.endpoint] ?? nil
        }
    }

    /// Somebody signed in or out, so nothing known here is known any more. The refusals go
    /// with it: a server is given the chance to accept a credential again, and one that
    /// still refuses says so once and is marked again. A look-up already in flight is
    /// disowned rather than allowed to put the old answer back.
    public func invalidate() {
        known = [:]
        generation += 1
    }

    /// A server turned this endpoint's credential down. It is not sent again until somebody
    /// signs in; saying so twice changes nothing.
    public func markRejected(_ endpoint: String) {
        known[endpoint] = .some(nil)
    }
}
