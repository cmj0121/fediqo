import Foundation
import Testing
@testable import FediqoCore

/// #337, in the half of it Core holds: a list is made, renamed and removed, and who is on it
/// is changed — read from what a real 4.6.6 answered (`MastodonListCaptures`).
@Suite("Lists a Mastodon keeps")
struct MastodonListsTests {
    private typealias Captures = MastodonListCaptures

    private static let origin = "https://\(Captures.host)"
    private static let reading = "read:statuses read:lists read:accounts"
    private static let writing = reading + " write:lists"

    private func door(
        _ routes: [String: FormServer.Answer], scopes: String? = MastodonListsTests.writing
    ) throws -> (MastodonLists, FormServer) {
        let server = FormServer(routes)
        let token = MastodonToken(
            host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: scopes
        )
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return (MastodonLists(door: MastodonAuthorized(token: token, sender: server, store: tokens)), server)
    }

    private func asked(_ server: FormServer) async -> [String] {
        await server.asked.map { "\($0.method) \($0.address) [\($0.form)]" }
    }

    @Test("Lists are a part of their own: the one word, standing without acting, asked of no question by itself, and the last part is still tending")
    func thePart() {
        #expect(MastodonPart.lists.words == ["write:lists"])
        #expect(!MastodonPart.lists.rider && !MastodonPart.lists.needsActing && MastodonPart.lists.wordsBesideActing.isEmpty)
        #expect(MastodonPart.allCases.last == .tending)
        #expect(MastodonParts.holds(.lists, in: Self.writing))
        #expect(!MastodonParts.holds(.lists, in: Self.reading))
        #expect(!MastodonParts.holds(.lists, in: nil))
    }

    @Test("The lists a real server listed are read as they came, and which lists a person is on are those, not the ones they own")
    func reading() async throws {
        let (lists, server) = try door([
            "GET /api/v1/lists": .init(body: Captures.lists),
            "GET /api/v1/accounts/\(Captures.person)/lists": .init(body: Captures.ofPerson),
        ], scopes: Self.reading)
        let all = try await lists.all()
        #expect(all == [ServerList(id: Captures.seeded, title: "fediqo-298", replies: .list, exclusive: false)])
        #expect(all[0].alsoOnHome)
        let on = try await lists.lists(ofAccount: Captures.person)
        #expect(on == all)
        #expect(await asked(server) == [
            "GET \(Self.origin)/api/v1/lists []",
            "GET \(Self.origin)/api/v1/accounts/\(Captures.person)/lists []",
        ])
    }

    @Test("Making a list posts the title alone and reads back what the server named; a blank name is refused before anything is asked; a long one is sent whole")
    func making() async throws {
        let (lists, server) = try door([
            "POST /api/v1/lists": .init(body: Captures.created),
        ])
        for blank in ["", " ", "\n", " \t "] {
            await #expect(throws: MastodonListError.invalid) { _ = try await lists.make(title: blank) }
        }
        #expect(await server.asked.isEmpty)
        let made = try await lists.make(title: "  fediqo-337-probe  ")
        #expect(made == ServerList(id: "2", title: "fediqo-337-probe", replies: .list, exclusive: false))
        #expect(await asked(server) == [
            "POST \(Self.origin)/api/v1/lists [title=fediqo-337-probe]",
        ])
        #expect(await server.asked[0].bearer == "Bearer tok-123")

        let (longer, longServer) = try door(["POST /api/v1/lists": .init(body: Captures.longTitle)])
        let title = String(repeating: "a", count: 200)
        let took = try await longer.make(title: title)
        #expect(took.id == "3" && took.title == title && took.replies == .list && !took.exclusive)
        #expect(await longServer.asked[0].form == "title=\(title)")
    }

    @Test("Renaming sends the title, whose replies and whether it is kept off Home, in that order, and a policy the server has not is its own sentence")
    func changing() async throws {
        let (lists, server) = try door([
            "PUT /api/v1/lists/2": .init(body: Captures.renamedFollowed),
        ])
        let renamed = try await lists.change("2", title: "fediqo-337-renamed", replies: .followed, exclusive: true)
        #expect(renamed == ServerList(id: "2", title: "fediqo-337-renamed", replies: .followed, exclusive: true))
        #expect(!renamed.alsoOnHome)
        #expect(await asked(server) == [
            "PUT \(Self.origin)/api/v1/lists/2 [title=fediqo-337-renamed&replies_policy=followed&exclusive=true]",
        ])

        let (none, noneServer) = try door(["PUT /api/v1/lists/2": .init(body: Captures.renamedNone)])
        let quiet = try await none.change("2", title: "fediqo-337-renamed", replies: .none, exclusive: false)
        #expect(quiet.replies == .none && quiet.alsoOnHome)
        #expect(await noneServer.asked[0].form == "title=fediqo-337-renamed&replies_policy=none&exclusive=false")

        let (refused, refusedServer) = try door([
            "PUT /api/v1/lists/2": .init(body: Captures.badPolicy, status: 422),
        ])
        await #expect(throws: MastodonListError.refused(sentence: "Validation failed: Replies policy is not included in the list")) {
            _ = try await refused.change("2", title: "fediqo-337-renamed", replies: .list, exclusive: false)
        }
        #expect(await refusedServer.asked.count == 1)
    }

    @Test("Removing a list is one delete the server answers with nothing; an id it has not is gone; an id that is no path is refused before anything is asked")
    func removing() async throws {
        let (lists, server) = try door([
            "DELETE /api/v1/lists/2": .init(body: Captures.removed),
            "DELETE /api/v1/lists/9": .init(body: Captures.removedAgain, status: 404),
            "PUT /api/v1/lists/9": .init(body: Captures.putMissing, status: 404),
        ])
        for id in ["", "1/follow", "../1", "a b"] {
            await #expect(throws: MastodonListError.invalid) { try await lists.remove(id) }
            await #expect(throws: MastodonListError.invalid) {
                _ = try await lists.change(id, title: "x", replies: .list, exclusive: false)
            }
        }
        #expect(await server.asked.isEmpty)
        try await lists.remove("2")
        await #expect(throws: MastodonListError.gone) { try await lists.remove("9") }
        await #expect(throws: MastodonListError.gone) {
            _ = try await lists.change("9", title: "x", replies: .list, exclusive: false)
        }
        #expect(await asked(server) == [
            "DELETE \(Self.origin)/api/v1/lists/2 []",
            "DELETE \(Self.origin)/api/v1/lists/9 []",
            "PUT \(Self.origin)/api/v1/lists/9 [title=x&replies_policy=list&exclusive=false]",
        ])
    }

    @Test("Who is on a list is read in the server's order, an empty name uses the username, and the next page is followed until it names no next")
    func members() async throws {
        let accounts = "/api/v1/lists/\(Captures.seeded)/accounts"
        let (lists, server) = try door([
            "GET \(accounts)": .init(body: Captures.nobody),
        ])
        #expect(try await lists.members(of: Captures.seeded).isEmpty)

        let (one, oneServer) = try door([
            "GET \(accounts)": .init(body: Captures.onePerson, link: Captures.personLink),
            "GET \(accounts)?max_id=\(Captures.person)": .init(body: Captures.nobody),
        ])
        let people = try await one.members(of: Captures.seeded)
        #expect(people == [ListPerson(id: Captures.person, acct: "fediqo_other", name: "fediqo_other")])
        #expect(await asked(oneServer) == [
            "GET \(Self.origin)\(accounts) []",
            "GET \(Self.origin)\(accounts)?max_id=\(Captures.person) []",
        ])
    }

    @Test("A next page that repeats, or a list that still names a next after fifty pages, is not read as the whole list")
    func membersThatDoNotEnd() async throws {
        let accounts = "/api/v1/lists/\(Captures.seeded)/accounts"
        let (again, againServer) = try door([
            "GET \(accounts)": .init(body: Captures.onePerson, link: Captures.personLink),
            "GET \(accounts)?max_id=\(Captures.person)": .init(body: Captures.onePerson, link: Captures.personLink),
        ])
        await #expect(throws: MastodonListError.unreadable) { _ = try await again.members(of: Captures.seeded) }
        #expect(await againServer.asked.count == 2)

        var routes: [String: FormServer.Answer] = [:]
        let body = #"[{"id":"1","username":"a","display_name":"A"}]"#
        for page in 1...50 {
            let next = String(page + 1)
            let link = "<https://\(Captures.host)\(accounts)?max_id=\(next)>; rel=\"next\""
            let key = page == 1 ? "GET \(accounts)" : "GET \(accounts)?max_id=\(page)"
            routes[key] = .init(body: body, link: link)
        }
        let (capped, cappedServer) = try door(routes)
        await #expect(throws: MastodonListError.unreadable) { _ = try await capped.members(of: Captures.seeded) }
        #expect(await cappedServer.asked.count == 50)
    }

    @Test("Putting somebody on a list and taking them off answer with nothing; somebody the server will not list is its own sentence; an id it has not is gone")
    func membership() async throws {
        let accounts = "/api/v1/lists/\(Captures.seeded)/accounts"
        let (lists, server) = try door([
            "POST \(accounts)": .init(body: Captures.added),
            "DELETE \(accounts)": .init(body: Captures.dropped),
        ])
        try await lists.add(Captures.person, to: Captures.seeded)
        try await lists.drop(Captures.person, from: Captures.seeded)
        #expect(await asked(server) == [
            "POST \(Self.origin)\(accounts) [account_ids%5B%5D=\(Captures.person)]",
            "DELETE \(Self.origin)\(accounts) [account_ids%5B%5D=\(Captures.person)]",
        ])

        let (refused, refusedServer) = try door([
            "POST \(accounts)": .init(body: Captures.mustFollow, status: 422),
            "POST /api/v1/lists/\(Captures.seeded)/accounts-missing": .init(body: Captures.missingAccount, status: 404),
        ])
        await #expect(throws: MastodonListError.refused(sentence: "Validation failed: Account must be a followed account")) {
            try await refused.add("9", to: Captures.seeded)
        }
        let (missing, _) = try door([
            "POST \(accounts)": .init(body: Captures.missingAccount, status: 404),
        ])
        await #expect(throws: MastodonListError.gone) { try await missing.add("9", to: Captures.seeded) }
        #expect(await refusedServer.asked.count == 1)
        for id in ["", "a/b"] {
            await #expect(throws: MastodonListError.invalid) { try await lists.add(id, to: Captures.seeded) }
            await #expect(throws: MastodonListError.invalid) { try await lists.add(Captures.person, to: id) }
        }
    }

    @Test("A sign-in without the word sends nothing and is locked; one that holds it and is still refused is forbidden, after the request")
    func theWord() async throws {
        let (locked, lockedServer) = try door([
            "POST /api/v1/lists": .init(body: Captures.outside, status: 403, authenticate: Captures.outsideAuthenticate),
        ], scopes: Self.reading)
        await #expect(throws: MastodonListError.locked) { _ = try await locked.make(title: "x") }
        await #expect(throws: MastodonListError.locked) { try await locked.remove("2") }
        await #expect(throws: MastodonListError.locked) { try await locked.add(Captures.person, to: "2") }
        #expect(await lockedServer.asked.isEmpty)

        let (forbidden, forbiddenServer) = try door([
            "POST /api/v1/lists": .init(body: Captures.outside, status: 403, authenticate: Captures.outsideAuthenticate),
            "DELETE /api/v1/lists/2": .init(body: Captures.outside, status: 403, authenticate: Captures.outsideAuthenticate),
        ])
        await #expect(throws: MastodonListError.forbidden) { _ = try await forbidden.make(title: "x") }
        await #expect(throws: MastodonListError.forbidden) { try await forbidden.remove("2") }
        #expect(await forbiddenServer.asked.count == 2)
    }

    @Test("An answer that is not a list is not a list: nothing is handed back as one")
    func unreadable() async throws {
        let (lists, _) = try door([
            "POST /api/v1/lists": .init(body: #"{"id":"2","title":"x","replies_policy":"everyone","exclusive":false}"#),
            "GET /api/v1/lists": .init(body: #"{"id":"1"}"#),
        ])
        await #expect(throws: MastodonListError.unreadable) { _ = try await lists.make(title: "x") }
        await #expect(throws: MastodonListError.unreadable) { _ = try await lists.all() }
    }
}
