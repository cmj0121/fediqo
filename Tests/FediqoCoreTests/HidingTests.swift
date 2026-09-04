import Foundation
import Testing
@testable import FediqoCore

/// What a server says it is hiding for the reader, and stopping it (#114).
@Suite("What your servers are hiding")
struct HidingTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/me", token: "t")
    }

    /// **The assertion this suite exists for.** These were declared only as protocol-extension
    /// defaults, which are dispatched where they are written rather than where they are called —
    /// so every client's own answer was walked straight past and every one of these lists was
    /// empty on a server that was hiding things. Nothing failed and nothing warned.
    @Test("A client's own answer is the one that is reached")
    func theclientsAnswerIsReached() async throws {
        let asked = Answering()
        // Through the existential, which is how the app holds a client and where the bug lived.
        let anyClient: any SourceClient = asked
        #expect(try await anyClient.hidden(.muted, as: account("a.example")).count == 1)
        #expect(try await anyClient.people(.favourited, of: makePost(uri: "https://a.example/1", at: 1),
                                           host: "a.example", limit: 1, token: nil).count == 1)
    }

    @Test("Each list is asked for by its own name", arguments: Hiding.allCases)
    func eachAtItsOwnAddress(which: Hiding) async throws {
        let host = "\(which.rawValue).hiding.test"
        let body = which.isAboutPeople
            ? #"[{"id": "1", "acct": "a@\#(host)", "username": "a", "display_name": "A", "url": "https://\#(host)/@a"}]"#
            : #"["shouting.example"]"#
        stubRoutes.on(host, "/api/v1/\(which.path)", status: 200, body: body)

        let found = try await client.hidden(which, as: account(host))
        #expect(found.count == 1)
        #expect(stubRoutes.paths(for: host) == ["/api/v1/\(which.path)"])
    }

    /// Three different acts with three different reaches, and the row differs by which.
    @Test("A list of servers is not a list of people")
    func serversAreNotPeople() {
        #expect(Hiding.allCases.filter(\.isAboutPeople) == [.muted, .blocked])
        #expect(Hiding.blockedServers.isAboutPeople == false)
    }

    /// A person on the list of servers is a pairing this app cannot make, and refusing it out
    /// loud beats sending a request shaped from a guess about which the caller meant.
    @Test("A subject that does not match its list is refused rather than guessed at")
    func mismatched() async throws {
        await #expect(throws: (any Error).self) {
            try await client.stopHiding(.blockedServers,
                                        .person(Profile(id: "1", authorId: "1", name: "A",
                                                        handle: "@a@a.example")),
                                        as: account("mismatch.hiding.test"))
        }
    }

    @Test("A server block is taken down by naming the domain")
    func adomainBlock() async throws {
        let host = "undo.hiding.test"
        stubRoutes.on(host, "/api/v1/domain_blocks", status: 200, body: "{}")
        try await client.stopHiding(.blockedServers, .server("shouting.example"),
                                    as: account(host))
        let sent = try #require(stubRoutes.requests(for: host, "/api/v1/domain_blocks").first)
        #expect(sent.method == "DELETE")
        #expect(sent.query["domain"] == "shouting.example")
    }

    /// Answers one of each, so that a default quietly standing in its place is a count of zero.
    private struct Answering: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }

        func hidden(_ which: Hiding, as account: ActingAccount) async throws -> [Hidden.Subject] {
            [.server("somewhere.example")]
        }

        func people(_ which: People.AboutAPost, of post: Post, host: String,
                    limit: Int, token: String?) async throws -> [Profile] {
            [Profile(id: "1", authorId: "1", name: "A", handle: "@a@a.example")]
        }
    }
}
