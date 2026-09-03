import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// Who somebody follows, and who follows them (#90).
///
/// The assertion worth having here is not that a list of people comes back — it is that **an empty
/// one is not one fact**. Somebody who has asked their server not to publish their network is
/// answered exactly as somebody who follows nobody: an empty array and a 200. Drawing "nobody"
/// over the first would be this app inventing something about a person, which is what S5 exists
/// to stop.
@Suite("Who they follow, and who follows them")
struct PeopleListTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    /// Somebody local to whoever is being asked — a bare `acct`, which is how a server spells
    /// one of its own. What it becomes is `@name@thatServer`, by the same rule every handle in
    /// this app follows, and the test says the host it asked rather than one it made up.
    private func someone(_ id: String, _ acct: String, on host: String) -> String {
        """
        { "id": "\(id)", "url": "https://\(host)/@\(acct)", "username": "\(acct)",
          "acct": "\(acct)", "display_name": "\(acct.capitalized)", "avatar": null }
        """
    }

    private func profile(followers: Int? = nil, following: Int? = nil) -> Profile {
        Profile(id: "10", authorId: "https://cedar.example/@tove", name: "Tove",
                handle: "@tove@cedar.example", followers: followers, following: following)
    }

    // MARK: - asking

    @Test("Each list is asked for by its own name, of the server the profile came from")
    func eachListHasItsOwnAddress() async throws {
        let host = "people-list.test"
        stubRoutes.on(host, "/api/v1/accounts/10/following", status: 200,
                      body: "[\(someone("1", "ines", on: host))]")
        stubRoutes.on(host, "/api/v1/accounts/10/followers", status: 200,
                      body: "[\(someone("2", "wren", on: host))]")

        let follows = try await client.people(.following, of: "10", host: host, limit: 20,
                                              before: nil, token: nil)
        let followers = try await client.people(.followers, of: "10", host: host, limit: 20,
                                                before: nil, token: nil)

        #expect(follows.map(\.handle) == ["@ines@\(host)"])
        #expect(followers.map(\.handle) == ["@wren@\(host)"])
    }

    /// A long list is paged rather than asked for whole, by the same cursor rule every page in
    /// this app follows: the last row of the page before, by that server's own number.
    @Test("A page after the first is asked for by the foot of the one before")
    func pagedByTheFootOfTheLast() async throws {
        let host = "people-page.test"
        stubRoutes.on(host, "/api/v1/accounts/10/followers", status: 200, body: "[]")
        let last = Profile(id: "77", authorId: "a", name: "A", handle: "@a@b")

        _ = try await client.people(.followers, of: "10", host: host, limit: 20,
                                    before: last, token: nil)

        let asked = try #require(stubRoutes.requests(for: host, "/api/v1/accounts/10/followers").first)
        #expect(asked.query["max_id"] == "77")
        #expect(asked.query["limit"] == "20")
    }

    @Test("The first page invents no cursor")
    func firstPageHasNoCursor() async throws {
        let host = "people-first.test"
        stubRoutes.on(host, "/api/v1/accounts/10/following", status: 200, body: "[]")

        _ = try await client.people(.following, of: "10", host: host, limit: 20,
                                    before: nil, token: nil)

        #expect(stubRoutes.requests(for: host, "/api/v1/accounts/10/following").first?
            .query["max_id"] == nil)
    }

    // MARK: - why a list is empty

    /// The one this issue is really about. A server that publishes *89 followers* and then hands
    /// over none of them has been told not to.
    @Test("A count above zero beside an empty list is a list somebody withheld")
    func withheldRatherThanEmpty() {
        #expect(People.reason(forEmpty: .followers, on: profile(followers: 89)) == .withheld)
        #expect(People.reason(forEmpty: .following, on: profile(following: 130)) == .withheld)
    }

    @Test("A count of zero beside an empty list is a list that is empty")
    func emptyIsEmpty() {
        #expect(People.reason(forEmpty: .followers, on: profile(followers: 0)) == .none)
        #expect(People.reason(forEmpty: .following, on: profile(following: 0)) == .none)
    }

    /// S5, exactly: a count nobody sent is not a zero, so why the list is empty is not something
    /// this device knows — and it says so rather than picking whichever reading looks tidier.
    @Test("A count nobody sent leaves the reason unknown")
    func silenceIsNotAReason() {
        #expect(People.reason(forEmpty: .followers, on: profile()) == .unknown)
        #expect(People.reason(forEmpty: .followers, on: nil) == .unknown)
    }

    // MARK: - people met somewhere that is not a post

    /// The last of #90's list, and the genuinely new thing about these screens. Everybody in
    /// `accounts` until now got there by writing something this device read; a follower list is
    /// full of people who have written nothing anybody here has seen.
    @Test("Somebody met in a list is written down like anybody else")
    func metInAListIsStillSomebody() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: "seen.example", socialProtocol: .mastodon)
        let met = Profile(id: "1", authorId: "https://seen.example/@ines", name: "Ines Okafor",
                          handle: "@ines@seen.example")

        try await store.saw([met], on: server)

        let rows = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT handle FROM accounts WHERE author_id = ?",
                                arguments: [met.authorId])
        }
        #expect(rows == ["@ines@seen.example"])
    }

    /// The rule every sighting follows: a later one fills in what an earlier left blank, and a
    /// blank never erases what a fuller one wrote.
    @Test("A blanker sighting does not erase a fuller one")
    func afullerSightingStands() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: "seen2.example", socialProtocol: .mastodon)
        let full = Profile(id: "1", authorId: "https://seen2.example/@wren", name: "Wren Ashby",
                           handle: "@wren@seen2.example")
        let blank = Profile(id: "1", authorId: "https://seen2.example/@wren", name: "",
                            handle: "@wren@seen2.example")

        try await store.saw([full], on: server)
        try await store.saw([blank], on: server)

        let name = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT display_name FROM accounts WHERE author_id = ?",
                                arguments: [full.authorId])
        }
        #expect(name == "Wren Ashby")
    }

    /// Each list is read against its own count. Somebody may publish one and withhold the other,
    /// and a screen reading the wrong number would call a withheld list empty.
    @Test("Each list is judged by its own count and not the other's")
    func eachListHasItsOwnCount() {
        let onlyFollowers = profile(followers: 89, following: 0)
        #expect(People.reason(forEmpty: .followers, on: onlyFollowers) == .withheld)
        #expect(People.reason(forEmpty: .following, on: onlyFollowers) == .none)
    }
}
