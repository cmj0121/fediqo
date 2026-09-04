import Foundation
import Testing
@testable import FediqoCore

/// Putting a search to the reader's own servers (#106).
///
/// The one read in this app that is a question about the reader rather than about a timeline:
/// what is sent is what they typed, and who learns it is whoever runs the servers they added.
@Suite("Asking a server what it has")
struct ServerSearchTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    // MARK: - nothing leaves without an answer

    /// The default, and the one that sends nothing: a search reads what this device holds and
    /// has no readings at all, so there is nothing for the loader to fan out.
    @Test("Unasked, a search never leaves this device")
    func unaskedNothingLeaves() {
        var timeline = Timeline(name: "", source: .search, words: "libraries", template: "search")
        timeline.asksServers = false
        #expect(timeline.query.readings.isEmpty)
    }

    @Test("Agreed to, a search is one reading and it is the search")
    func agreedItIsOneReading() {
        var timeline = Timeline(name: "", source: .search, words: "libraries", template: "search")
        timeline.asksServers = true
        #expect(timeline.query.readings == [.base(.search)])
    }

    /// Nothing is sent for nothing. A reader who opened the field and typed nothing has asked
    /// no question, and a request carrying an empty one still tells somebody they are searching.
    @Test("No words send no request, however the answer stands")
    func nowordsSendNothing() {
        var timeline = Timeline(name: "", source: .search, words: "  ", template: "search")
        timeline.asksServers = true
        #expect(timeline.query.readings.isEmpty)
    }

    /// A reading that is not a search cannot be one, so it cannot carry the answer to a question
    /// about searching either.
    @Test("Only a search can be put to a server as one")
    func onlyAsearch() {
        for source in BaseSource.allCases where source != .search {
            var timeline = Timeline(name: "", source: source, words: "x", template: "t")
            timeline.asksServers = true
            #expect(!timeline.query.asksServers)
        }
    }

    // MARK: - what is actually sent

    /// **The assertion this suite exists for.** `resolve=true` would ask the server to go and
    /// fetch whatever the words look like they name — turning a search into this app making the
    /// reader's server touch a third party, which `docs/privacy.md` says never happens. The
    /// reader agreed to their own servers seeing what they typed, and to nothing else.
    @Test("It never asks the server to go and fetch anything")
    func neverResolves() async throws {
        let host = "search.test"
        stubRoutes.on(host, "/api/v2/search", status: 200, body: #"{"statuses": []}"#)

        _ = try await client.search("libraries", host: host, limit: 20, token: nil)

        let sent = try #require(stubRoutes.requests(for: host, "/api/v2/search").first)
        #expect(sent.query["resolve"] == "false")
        #expect(sent.query["q"] == "libraries")
        // Statuses, not accounts and not hashtags: the other two are answers to questions this
        // app did not ask here, and each of them asks for its own type.
        #expect(sent.query["type"] == "statuses")
    }

    @Test("Only the statuses are read out of the answer")
    func onlyTheStatuses() async throws {
        let host = "results.test"
        stubRoutes.on(host, "/api/v2/search", status: 200, body: """
        {"accounts": [{"id": "1", "acct": "someone", "username": "someone"}],
         "hashtags": [{"name": "libraries"}],
         "statuses": [{"id": "9", "uri": "https://results.test/users/a/statuses/9",
                       "url": "https://results.test/@a/9", "created_at": "2026-01-01T00:00:00.000Z",
                       "content": "<p>about libraries</p>", "media_attachments": [],
                       "account": {"id": "1", "acct": "a@results.test", "username": "a",
                                   "display_name": "A", "url": "https://results.test/@a"}}]}
        """)

        let found = try await client.search("libraries", host: host, limit: 20, token: nil)
        #expect(found.map(\.text) == ["about libraries"])
    }

    /// Nothing typed is nothing asked, and the request is not made at all rather than made
    /// empty — a request with an empty query still tells the server somebody is searching.
    @Test("Nothing typed asks nobody anything")
    func nothingTypedAsksNobody() async throws {
        let host = "quiet.test"
        #expect(try await client.search("   ", host: host, limit: 20, token: nil).isEmpty)
        #expect(stubRoutes.paths(for: host).isEmpty)
    }

    /// A server too old for v2 answers 404, and that is what a reader is told — not an empty
    /// result, which is what "nobody wrote that" looks like.
    @Test("A server that cannot answer says so, rather than looking empty")
    func aserverThatCannotAnswer() async throws {
        let host = "old.test"
        stubRoutes.on(host, "/api/v2/search", status: 404, body: "{}")
        await #expect(throws: (any Error).self) {
            try await client.search("libraries", host: host, limit: 20, token: nil)
        }
    }

    /// And a protocol with no search at all refuses rather than answering nothing.
    @Test("A client that cannot search refuses")
    func aclientThatCannotSearch() async throws {
        await #expect(throws: SourceFailure.cannotSearch("nowhere.example")) {
            try await Unsearchable().search("libraries", host: "nowhere.example", limit: 20,
                                            token: nil)
        }
    }

    /// Answers the public timeline and knows nothing else — the defaults in `SourceClient` are
    /// left in place on purpose, since they are what is under test.
    private struct Unsearchable: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
