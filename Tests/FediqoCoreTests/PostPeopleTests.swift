import Foundation
import Testing
@testable import FediqoCore

/// Who favourited or boosted a post (#126).
@Suite("Who did it")
struct PostPeopleTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func post(on host: String) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/9",
                 originURI: "https://\(host)/users/a/statuses/9", at: 1, from: host)
    }

    /// The word in the address is the enum's own, so a screen naming the list and the request
    /// asking for it cannot come to disagree.
    @Test("Each list is asked for by its own name")
    func eachHasItsPath() {
        #expect(People.AboutAPost.favourited.path == "favourited_by")
        #expect(People.AboutAPost.boosted.path == "reblogged_by")
        #expect(People.AboutAPost.allCases.count == 2)
    }

    /// **Not a case of `People.Kind`.** Those two are asked about somebody, these about
    /// something they wrote, and one enum would have every caller carrying a subject that might
    /// be either.
    @Test("A post's lists and a person's lists are different lists")
    func differentSubjects() {
        #expect(People.Kind.allCases.map(\.rawValue) == ["following", "followers"])
        #expect(People.AboutAPost.allCases.map(\.rawValue) == ["favourited", "boosted"])
    }

    @Test("It asks the right address for each", arguments: People.AboutAPost.allCases)
    func asksTheRightAddress(which: People.AboutAPost) async throws {
        let host = "\(which.rawValue).who.test"
        stubRoutes.on(host, "/api/v1/statuses/9/\(which.path)", status: 200, body: """
        [{"id": "1", "acct": "a@\(host)", "username": "a", "display_name": "A",
          "url": "https://\(host)/@a"}]
        """)

        let people = try await client.people(which, of: post(on: host), host: host,
                                             limit: 80, token: nil)
        #expect(people.map(\.handle) == ["@a@\(host)"])
        #expect(stubRoutes.paths(for: host) == ["/api/v1/statuses/9/\(which.path)"])
    }

    /// A protocol that keeps no such list has none to hand over, and empty is the true answer —
    /// which the page tells apart from *withheld* by the count on the post disagreeing with it.
    @Test("A protocol with no such list answers none")
    func aprotocolWithout() async throws {
        #expect(try await Listless().people(.favourited, of: post(on: "nowhere.example"),
                                            host: "nowhere.example", limit: 80,
                                            token: nil).isEmpty)
    }

    private struct Listless: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
