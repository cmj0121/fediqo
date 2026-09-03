import Foundation
import Testing
import GRDB
import FediqoCore
@testable import FediqoUI

/// A fixture run that is signed in (#100).
///
/// Half of this app exists because somebody is signed in — the composer, what a reader is to
/// somebody, who a part-typed handle could be — and none of it could be photographed at all,
/// because a fixture run signed in nowhere. What is asserted here is that it does, and that being
/// signed in without a server to be signed in to reaches nothing it should not.
@Suite("A fixture that is signed in")
@MainActor
struct SignedInFixtureTests {
    // MARK: - the way in

    @Test("One launch variable, and it means nothing on its own")
    func theLaunchVariable() {
        #expect(LaunchOptions.fromEnvironment(["FEDIQO_SIGNED_IN": "1"]).signedIn)
        #expect(LaunchOptions.fromEnvironment(["FEDIQO_SIGNED_IN": "yes"]).signedIn == false)
        #expect(LaunchOptions.fromEnvironment([:]).signedIn == false)
    }

    /// A draft is seeded so that the offer of who a part-typed handle could be — a screen that
    /// exists only while somebody is typing — can be photographed on a run where nothing types.
    @Test("A draft can be handed in, and only to a fixture")
    func theSeededDraft() {
        #expect(LaunchOptions.fromEnvironment(["FEDIQO_DRAFT": "@to"]).draft == "@to")

        let seeded = AppState(launch: LaunchOptions.fromEnvironment(["FEDIQO_FIXTURE": "1",
                                                                    "FEDIQO_DRAFT": "@to"]))
        #expect(seeded.launchedDraft == "@to")
        // Seeding a reader's own composer would be this app writing in their draft.
        let readers = AppState(launch: LaunchOptions.fromEnvironment(["FEDIQO_DRAFT": "@to"]))
        #expect(readers.launchedDraft == nil)
    }

    // MARK: - what being signed in writes

    /// The local half of signing in and nothing else: the same three rows the real one writes,
    /// in the same transaction, plus the token.
    @Test("It writes the account, the server and the ownership, and keeps the credential")
    func itWritesWhatSigningInWrites() async throws {
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        let session = SignInCoordinator(store: store, secrets: secrets)

        try await session.signInWithoutAsking(Fixture.reader, on: Fixture.readerServer,
                                              token: Fixture.readerToken)

        let owned = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts")
        }
        #expect(owned == [Fixture.reader.authorId])
        #expect(try secrets.token(for: Fixture.reader.authorId)?.accessToken == "fixture")
    }

    /// Which is what makes every screen behind a sign-in reachable: the app asks this and gets
    /// an account back rather than nobody.
    @Test("The app can act as them afterwards")
    func theAppCanActAsThem() async throws {
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        try await SignInCoordinator(store: store, secrets: secrets)
            .signInWithoutAsking(Fixture.reader, on: Fixture.readerServer,
                                 token: Fixture.readerToken)

        let signedIn = try await store.signedInByServer()
        #expect(signedIn[Fixture.readerServer.endpoint]?.authorId == Fixture.reader.authorId)
    }

    /// Nothing it names can be reached. RFC 2606 reserves `.example` and no resolver will ever
    /// answer one, so a request that escaped would fail rather than reach a stranger's machine.
    @Test("Nobody it names is a server anybody could reach")
    func nothingItNamesIsReachable() {
        #expect(Fixture.readerServer.host.hasSuffix(".example"))
        #expect(Fixture.reader.handle.hasSuffix(".example"))
        #expect(Fixture.reader.authorId.contains(".example"))
    }

    // MARK: - what the invented server now answers

    /// **A server knows the accounts it has seen and no others.** Both states stay
    /// photographable: the relationship, and the honest "this server has never heard of them",
    /// which is what #88 is careful about.
    @Test("It answers about people its own timeline has, and not about anybody else")
    func itAnswersAboutWhoItHasSeen() async throws {
        let source = FixtureSource()
        let acting = ActingAccount(host: "cedar.example",
                                   authorId: Fixture.reader.authorId, token: "t")
        let known = try #require(Fixture.timeline(of: "cedar.example").first?.authorHandle)

        #expect(try await source.relationship(with: known, as: acting) != nil)
        #expect(try await source.relationship(with: "@nobody@elsewhere.example", as: acting) == nil)
    }

    @Test("It offers who a part-typed handle could be, out of the people it has seen")
    func itOffersWhoAHandleCouldBe() async throws {
        let source = FixtureSource()
        let acting = ActingAccount(host: "cedar.example",
                                   authorId: Fixture.reader.authorId, token: "t")

        let found = try await source.searchPeople(matching: "to", limit: 5, as: acting)

        #expect(found.allSatisfy { $0.handle.lowercased().contains("to")
                                   || $0.name.lowercased().contains("to") })
        #expect(found.count <= 5)
        #expect(try await source.searchPeople(matching: "zzzz", limit: 5, as: acting).isEmpty)
    }

    /// Nobody is offered twice, however many posts of theirs the timeline carries.
    @Test("Each person is offered once")
    func eachPersonOnce() async throws {
        let source = FixtureSource()
        let acting = ActingAccount(host: "cedar.example",
                                   authorId: Fixture.reader.authorId, token: "t")

        let found = try await source.searchPeople(matching: "e", limit: 20, as: acting)

        #expect(Set(found.map(\.authorId)).count == found.count)
    }
}
