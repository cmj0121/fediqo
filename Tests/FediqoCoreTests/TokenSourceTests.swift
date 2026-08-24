import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// An in-memory secret store that says how many times it was opened. The Keychain is the
/// slow, blocking thing behind the real one, so "how often did we ask it" is the whole
/// point of caching and is what these tests assert on.
private final class CountingSecretStore: SecretStore {
    private let kept = InMemorySecretStore()
    private let reads = Mutex<Int>(0)

    var readCount: Int { reads.withLock { $0 } }

    func secret(for account: String) throws -> Data? {
        reads.withLock { $0 += 1 }
        return try kept.secret(for: account)
    }

    func setSecret(_ secret: Data, for account: String) throws {
        try kept.setSecret(secret, for: account)
    }

    func removeSecret(for account: String) throws {
        try kept.removeSecret(for: account)
    }
}

/// The same, but the first read holds the door open until the test says to let go.
///
/// A look-up suspends inside the actor while it waits on the Keychain, and an actor is only
/// exclusive between suspension points — so this is how a test gets to be the thing that
/// happens in the middle, rather than hoping a race falls the right way.
private final class GatedSecretStore: SecretStore {
    private let kept = InMemorySecretStore()
    private let reads = Mutex<Int>(0)
    /// Only the first read is held. The rest go straight through, so a test can ask again
    /// afterwards without arranging a second handover.
    private let unclaimed = Mutex<Bool>(true)
    /// The held read blocks a thread, and it has to: `SecretStore.secret(for:)` is a
    /// synchronous protocol method, so there is no suspension point to park on and a
    /// continuation latch has nowhere to go. One pool thread is parked, briefly, by one
    /// test at a time — and `letGo()` always runs, including down the failure path.
    private let release = DispatchSemaphore(value: 0)

    var readCount: Int { reads.withLock { $0 } }

    /// Whether the first read began and is now being held. Polled rather than waited on: a
    /// semaphore may not be waited on from an async context. Bounded, so a look-up that
    /// never reaches the Keychain fails the test that expected it instead of hanging the
    /// suite — the caller reports, this only answers.
    func waitUntilHolding() async -> Bool {
        for _ in 0..<10_000 {
            if readCount > 0 { return true }
            await Task.yield()
        }
        return false
    }

    /// Let the held read finish.
    func letGo() {
        release.signal()
    }

    func secret(for account: String) throws -> Data? {
        let hold = unclaimed.withLock { unclaimed -> Bool in
            defer { unclaimed = false }
            return unclaimed
        }
        reads.withLock { $0 += 1 }
        if hold { release.wait() }
        return try kept.secret(for: account)
    }

    func setSecret(_ secret: Data, for account: String) throws {
        try kept.setSecret(secret, for: account)
    }

    func removeSecret(for account: String) throws {
        try kept.removeSecret(for: account)
    }
}

/// Who is signed in changes when somebody signs in or out and at no other moment, so a page
/// refreshing itself every thirty seconds has no business opening the Keychain every thirty
/// seconds — nor sending a credential a server has already refused.
@Suite("One answer to who we are, kept until it stops being true")
struct TokenSourceTests {
    private let publicTimeline = "/api/v1/timelines/public"

    @Test("The second load reads what the first resolved, without opening the Keychain again")
    func theSecondLoadCostsNoKeychain() async throws {
        let host = "cached.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let secrets = CountingSecretStore()
        try await signInRows("t0ken", to: server, store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets)

        _ = await loader.load(servers: [server], mode: .timeline)
        let afterFirst = secrets.readCount
        _ = await loader.load(servers: [server], mode: .timeline)

        #expect(afterFirst == 1)
        #expect(secrets.readCount == 1)
        // Both reads still went out as the account, so nothing was saved by forgetting.
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == ["Bearer t0ken", "Bearer t0ken"])
    }

    @Test("A server nobody has been asked about yet is looked up — and only that one")
    func onlyTheUnseenServerIsResolved() async throws {
        let first = makeServer("first-seen.test")
        let second = makeServer("second-seen.test")
        for server in [first, second] {
            stubRoutes.on(server.host, publicTimeline, status: 200, body: oneStatusJSON)
        }
        let store = try LocalStore.inMemory()
        let secrets = CountingSecretStore()
        try await signInRows("one", to: first, store: store, secrets: secrets)
        try await signInRows("two", to: second, store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets)

        _ = await loader.load(servers: [first], mode: .timeline)
        #expect(secrets.readCount == 1)

        _ = await loader.load(servers: [first, second], mode: .timeline)

        // The second server cost one look-up, not two: what was known about the first was
        // kept rather than thrown away and walked again.
        #expect(secrets.readCount == 2)
        #expect(stubRoutes.requests(for: second.host, publicTimeline).map(\.authorization) == ["Bearer two"])

        // And a shorter list afterwards does not forget the longer one — two callers asking
        // about different servers must not undo each other's work.
        _ = await loader.load(servers: [first], mode: .timeline)
        _ = await loader.load(servers: [first, second], mode: .timeline)
        #expect(secrets.readCount == 2)
    }

    @Test("Signing out is told, so the next read is not sent as somebody who has left")
    func invalidationForcesAFreshLook() async throws {
        let server = makeServer("invalidated.test")
        let store = try LocalStore.inMemory()
        let secrets = CountingSecretStore()
        try await signInRows("t0ken", to: server, store: store, secrets: secrets)
        let tokens = TokenSource(store: store, secrets: secrets)

        #expect(await tokens.tokens(for: [server]).keys.sorted() == [server.endpoint])
        #expect(secrets.readCount == 1)
        _ = await tokens.tokens(for: [server])
        #expect(secrets.readCount == 1)

        await tokens.invalidate()
        _ = await tokens.tokens(for: [server])

        #expect(secrets.readCount == 2)
    }

    @Test("A credential a server has already refused is not handed out again")
    func aRejectedEndpointGetsNoToken() async throws {
        let server = makeServer("already-refused.test")
        let store = try LocalStore.inMemory()
        let secrets = CountingSecretStore()
        try await signInRows("expired", to: server, store: store, secrets: secrets)
        let tokens = TokenSource(store: store, secrets: secrets)

        await tokens.markRejected(server.endpoint)

        #expect(await tokens.tokens(for: [server]).isEmpty)
        // Signing in again is the one thing that gives a server another chance.
        await tokens.invalidate()
        #expect(await tokens.tokens(for: [server]).keys.sorted() == [server.endpoint])
    }

    @Test("The launch check marks what it found, so the first refresh does not ask to be refused again")
    func theLaunchCheckSuppressesWhatItFound() async throws {
        let server = makeServer("launch-checked.test")
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        let tokens = TokenSource(store: store, secrets: secrets)
        try await signInRows("expired", to: server, store: store, secrets: secrets)
        let auth = ScriptedAuthClient(account: SignedInAccount(authorId: "\(server.endpoint)/@ada", handle: "@ada",
                                                              displayName: "Ada", avatarURL: nil))
        auth.refusesVerify(with: SourceFailure.tokenRejected(server.host))
        let coordinator = SignInCoordinator(store: store, secrets: secrets, tokens: tokens)

        let rejected = await coordinator.rejectedEndpoints(among: [server]) { _ in auth }

        #expect(rejected == [server.endpoint])
        #expect(await tokens.tokens(for: [server]).isEmpty)
    }

    @Test("Signing in reaches the feed, because the loader and the sign-in share one resolver")
    func signingInReachesTheFeed() async throws {
        let host = "shared-seam.test"
        let server = makeServer(host)
        stubRoutes.on(host, publicTimeline, status: 200, body: oneStatusJSON)
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        // The one thing this test is about: both sides are handed the same actor. Give them
        // one each and everything below still compiles, still runs, and is wrong.
        let tokens = TokenSource(store: store, secrets: secrets)
        let loader = stubbedLoader(store: store, secrets: secrets, tokens: tokens)
        let auth = ScriptedAuthClient(account: SignedInAccount(authorId: "\(server.endpoint)/@ada", handle: "@ada",
                                                              displayName: "Ada", avatarURL: nil))
        let coordinator = SignInCoordinator(store: store, secrets: secrets, tokens: tokens)

        // A read before anybody signs in, which is what caches "there is no token here".
        _ = await loader.load(servers: [server], mode: .timeline)
        _ = try await coordinator.signIn(server: server, using: auth, authenticate: approving)
        _ = await loader.load(servers: [server], mode: .timeline)

        // The second read carries the credential the first could not have known about.
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization) == [nil, "Bearer token-1"])

        await coordinator.signOut(authorId: "\(server.endpoint)/@ada", using: auth)
        _ = await loader.load(servers: [server], mode: .timeline)

        // And the mirror: a read after signing out goes out as nobody again.
        #expect(stubRoutes.requests(for: host, publicTimeline).map(\.authorization).last == .some(nil))
    }

    @Test("A refusal that lands mid-look-up is the newer answer, and the look-up does not undo it")
    func aRefusalDuringALookUpStands() async throws {
        let server = makeServer("refused-mid-flight.test")
        let store = try LocalStore.inMemory()
        let secrets = GatedSecretStore()
        try await signInRows("expired", to: server, store: store, secrets: secrets)
        let tokens = TokenSource(store: store, secrets: secrets)

        async let resolving = tokens.tokens(for: [server])
        let held = await secrets.waitUntilHolding()
        // The actor is suspended on the Keychain, so this gets in the middle — which is the
        // whole of the hazard: a load in flight must not put a spent credential back.
        if held { await tokens.markRejected(server.endpoint) }
        // Always, so a look-up that never started fails this test rather than hanging on a
        // read nobody will ever release.
        secrets.letGo()
        _ = await resolving

        try #require(held, "the look-up never reached the Keychain, so nothing was interleaved with it")
        #expect(await tokens.tokens(for: [server]).isEmpty)
    }

    @Test("Signing out during a look-up disowns it: what it read is not put back")
    func signingOutDuringALookUpDiscardsIt() async throws {
        let server = makeServer("left-mid-flight.test")
        let store = try LocalStore.inMemory()
        let secrets = GatedSecretStore()
        try await signInRows("t0ken", to: server, store: store, secrets: secrets)
        let tokens = TokenSource(store: store, secrets: secrets)

        async let resolving = tokens.tokens(for: [server])
        let held = await secrets.waitUntilHolding()
        if held { await tokens.invalidate() }
        secrets.letGo()
        _ = await resolving

        try #require(held, "the look-up never reached the Keychain, so nothing was interleaved with it")
        // Nothing was kept, so the next question is a fresh walk rather than an answer about
        // somebody who has since left.
        #expect(secrets.readCount == 1)
        _ = await tokens.tokens(for: [server])
        #expect(secrets.readCount == 2)
    }
}
