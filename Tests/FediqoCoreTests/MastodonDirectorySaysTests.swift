import Foundation
import Testing
@testable import FediqoCore

/// #315: what Fediqo believes a Mastodon says of its directory of people, held against the real
/// one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through this app's own
/// reader, `MastodonDirectory`, and beside it asked plainly for the part of each answer the
/// reader rests on (`MastodonDirectoryCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`): seven people who chose to
/// be listed — one whole, their five followers, one of another server — and two more who
/// chose to and are not given, one suspended and one limited. **Nothing here writes, and
/// nothing is switched**: what a directory answers switched off can be asked only from inside
/// the server; it was, and is in the captures' table.
///
/// **No figure that holds only on the day the seed ran is pinned**: who posted last decides
/// one order, so that order is checked by who is in it and who comes before those who never
/// posted, and the other — whom the server met last — by the seed's own order of making them.
///
/// **Asked gently.** A run makes some fifteen requests and no registration.
@Suite("What a Mastodon says of its directory of people", .enabled(if: LocalServers.requested), .serialized)
struct MastodonDirectorySaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func seeded() throws -> LocalServers.Seeded.People {
        try #require(
            try LocalServers.seeded().people,
            "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again"
        )
    }

    private func plain(_ path: String, as token: String? = nil) async throws -> (status: Int, body: Data, response: HTTPURLResponse) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body, response)
    }

    private func accts(_ body: Data) throws -> [String] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]]).compactMap { $0["acct"] as? String }
    }

    private func reader() throws -> MastodonDirectory {
        MastodonDirectory(http: try LocalHTTP.client(), host: Self.host)
    }

    @Test("With no sign-in it gives the people who chose to be listed, of this server and of another it has heard of, each read as a person — and not one it suspended or limited, though they chose to be")
    func whoIsListed() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let listed = Set(([seeded.person, seeded.far] + seeded.fans).map(\.id))
        let said = try await reader().stretch(source: Self.source)
        #expect(Set(said.people.map(\.accountID)) == listed && said.people.count == listed.count, "nobody twice")
        #expect(!said.people.map(\.accountID).contains(seeded.gone.id) && !said.people.map(\.accountID).contains(seeded.limited.id))
        #expect(said.next == String(listed.count), "a short stretch names a next all the same")
        let far = try #require(said.people.first { $0.accountID == seeded.far.id })
        #expect(!far.livesHere && far.home == "elsewhere.example" && far.tally.followers == 2811)
        #expect(try #require(said.people.first { $0.accountID == seeded.person.id }).livesHere)

        let nobody = try await plain(MastodonDirectory.path)
        #expect(nobody.status == 200 && nobody.response.value(forHTTPHeaderField: "Link") == nil, "it names no next")
        let given = try accts(nobody.body)
        #expect(Set(given) == Set(([seeded.person, seeded.far] + seeded.fans).map(\.acct)))
        #expect(!MastodonHostNotFound.isOfTheAddress(status: nobody.status, body: nobody.body))
    }

    @Test("It takes two orders by its own words: whoever posted most lately first — which is also what it gives unasked, with those who never posted after them — and whoever it met most lately first; any other word is answered with a failure of its own")
    func itsTwoOrders() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let posted = Set([seeded.person.id, seeded.far.id])
        let active = try await reader().stretch(source: Self.source, order: .active)
        #expect(Set(active.people.prefix(2).map(\.accountID)) == posted, "the two who posted come before the five who never did")
        let unasked = try await plain(MastodonDirectory.path), asked = try await plain(MastodonDirectory.path + "?order=active")
        let first = try accts(unasked.body).prefix(2), same = try accts(asked.body).prefix(2)
        #expect(Set(first) == Set(same) && Set(first) == Set([seeded.person.acct, seeded.far.acct]))

        let new = try await reader().stretch(source: Self.source, order: .new)
        #expect(new.people.map(\.accountID) == [seeded.far.id] + seeded.fans.reversed().map(\.id) + [seeded.person.id])
        for word in ["bogus", ""] {
            #expect(try await plain(MastodonDirectory.path + "?order=\(word)").status == 500, "\(word)")
        }
    }

    @Test("It can be held to the people who live there, and is read on by how many were passed over and by nothing else: stretches of two are four with nobody twice, the one after them is empty and is the end, and a length of none is answered with nobody though the directory has people")
    func readOnByACount() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let local = try await reader().stretch(source: Self.source, order: .new, localOnly: true)
        #expect(local.people.map(\.accountID) == seeded.fans.reversed().map(\.id) + [seeded.person.id])
        #expect(local.people.allSatisfy { $0.livesHere })

        var read = PeopleRead(), next: String?, asks = 0
        repeat {
            let passed = try next.map { try #require(MastodonDirectory.passed($0)) } ?? 0
            let stretch = try await reader().stretch(source: Self.source, order: .new, after: passed, limit: 2)
            #expect(stretch.people.count <= 2)
            read = try read.readingOn(stretch)
            next = read.next
            asks += 1
        } while next != nil && asks < 8
        #expect(asks == 5 && read.ended, "four stretches with somebody, and the empty one that is the end")
        #expect(read.people.map(\.accountID) == [seeded.far.id] + seeded.fans.reversed().map(\.id) + [seeded.person.id])

        let none = try await plain(MastodonDirectory.path + "?order=new&limit=0")
        #expect(none.status == 200 && none.body == Data(MastodonDirectoryCaptures.nobody.utf8))
        let ignored = try await plain(MastodonDirectory.path + "?order=new&limit=2&max_id=1")
        let firstTwo = try accts(ignored.body), lastFan = try #require(seeded.fans.last)
        #expect(firstTwo == [seeded.far.acct, lastFan.acct], "max_id is not how it goes on")
        #expect(try await plain(MastodonDirectory.path + "?order=new&offset=-1").status == 500)
    }

    @Test("Signed in it leaves out the people the reader blocks or mutes — read through this app's reader as the seed's writer, somebody they block and somebody they mute are not there — and a token that is none is answered as nobody is")
    func signedInItLeavesPeopleOut() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let writer = try accts(try await plain(MastodonDirectory.path, as: try LocalServers.writerToken()).body)
        #expect(!writer.contains(seeded.muted.acct) && !writer.contains(seeded.blocked.acct) && writer.contains(seeded.person.acct))
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: try LocalServers.writerToken(), clientID: "x", clientSecret: "x")
        try tokens.save(token)
        let asWriter = MastodonDirectory(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
        let given = try await asWriter.stretch(source: Self.source, order: .new).people.map(\.accountID)
        #expect(!given.contains(seeded.blocked.id) && !given.contains(seeded.muted.id) && given.contains(seeded.person.id))
        let nobody = try accts(try await plain(MastodonDirectory.path).body)
        #expect(nobody.contains(seeded.muted.acct) && nobody.contains(seeded.blocked.acct))
        let bad = try await plain(MastodonDirectory.path, as: "not-a-token")
        let unknown = try accts(bad.body)
        #expect(bad.status == 200 && Set(unknown) == Set(nobody))
    }
}
