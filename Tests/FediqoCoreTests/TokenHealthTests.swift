import Foundation
import Testing
@testable import FediqoCore

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
        let c = try Harness(answering: ada)
        try await c.signIn(to: server)
        c.auth.refusesVerify(with: SourceFailure.tokenRejected(server.host))

        #expect(await c.rejected(among: [server]) == [server.endpoint])
    }

    @Test("A server that still accepts the credential names nothing")
    func acceptedTokenIsNotReported() async throws {
        let c = try Harness(answering: ada)
        try await c.signIn(to: server)

        #expect(await c.rejected(among: [server]).isEmpty)
    }

    @Test("A server that cannot answer is not a verdict on the credential")
    func offlineServerReportsNothing() async throws {
        let c = try Harness(answering: ada)
        try await c.signIn(to: server)
        c.auth.refusesVerify(with: URLError(.notConnectedToInternet))

        #expect(await c.rejected(among: [server]).isEmpty)
    }

    @Test("Nobody signed in, nothing asked")
    func nothingOwnedAsksNothing() async throws {
        let c = try Harness(answering: ada)
        let callsBefore = c.auth.networkCalls

        #expect(await c.rejected(among: [server]).isEmpty)
        #expect(c.auth.networkCalls == callsBefore)
    }

    @Test("A server nobody owns an account on is not asked, even beside one that is")
    func onlyOwnedServersAreAsked() async throws {
        let c = try Harness(answering: ada)
        try await c.signIn(to: server)
        let callsBefore = c.auth.networkCalls
        c.auth.refusesVerify(with: SourceFailure.tokenRejected(server.host))

        #expect(await c.rejected(among: [server, makeServer("stranger.test")]) == [server.endpoint])
        #expect(c.auth.networkCalls == callsBefore + 1)
    }
}
