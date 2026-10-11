import Foundation
import Testing
@testable import FediqoCore

/// #319: what Fediqo believes a Mastodon's search says, held against the real one this checkout
/// brings up (`make servers`, Mastodon 4.6.6) — read through this app's own reader,
/// `MastodonSearch`, and beside it asked plainly for the part of each answer the reader rests
/// on (`MastodonSearchCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`): the people a person's page
/// is checked against, two of another server, and the one hashtag the seed makes rise.
/// **Nothing here writes.** This server has no full-text index, so what a search of posts'
/// words finds is not checked here; that a post is found by its address is, in `MastodonSaysTests`.
///
/// **No figure that holds only on the day or the machine the seed ran is pinned.** Who is found
/// is checked by who is in the answer and who is not, never by an order the server chose. That
/// a look-up of somebody of another server comes to nobody rests on that server's name being
/// one that names no server anywhere (`.example`), which no machine reaches.
///
/// **Asked gently.** A run makes some forty requests and no registration.
@Suite("What a Mastodon's search says of people, hashtags and addresses", .enabled(if: LocalServers.requested), .serialized)
struct MastodonSearchSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)
    private static let path = "/api/v2/search"

    private struct Said {
        let status: Int
        let body: Data
        let response: HTTPURLResponse
        var accts: [String] { Self.names(body, "accounts", "acct") }
        var tags: [String] { Self.names(body, "hashtags", "name") }
        var posts: Int { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { $0["statuses"] as? [Any] }?.count ?? -1 }

        private static func names(_ body: Data, _ kind: String, _ key: String) -> [String] {
            let whole = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return (whole?[kind] as? [[String: Any]] ?? []).compactMap { $0[key] as? String }
        }
    }

    private static func seeded() throws -> (all: LocalServers.Seeded, people: LocalServers.Seeded.People, reading: String, narrow: String) {
        let all = try LocalServers.seeded()
        let people = try #require(all.people, "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again")
        let reading = try #require(all.notices?.reading.token)
        let narrow = try #require(people.narrow?.token)
        return (all, people, reading, narrow)
    }

    private func plain(_ words: [(String, String)], as token: String? = nil) async throws -> Said {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = Self.host
        parts.path = Self.path
        parts.queryItems = words.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Said(status: response.statusCode, body: body, response: response)
    }

    private func reader(_ accessToken: String) throws -> (MastodonSearch, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return (MastodonSearch(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)), tokens)
    }

    @Test("One ask with no kind named brings people and hashtags together, read through this app's reader as people and as hashtags; a kind named brings that kind alone, a kind it does not know brings nothing, and a length holds every kind at once — none at a length of none, which is not finding nothing")
    func everythingTogether() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let finds = try await reader(seeded.reading).0.everything(matching: "fediqo", source: Self.source)
        let found = Set(finds.people.map(\.accountID))
        let expected: [String] = [seeded.people.person.id, seeded.people.limited.id] + seeded.people.fans.map(\.id)
        #expect(found.isSuperset(of: expected))
        #expect(finds.people.count <= MastodonSearch.longest && Set(finds.people.map(\.id)).count == finds.people.count)
        #expect(finds.people.allSatisfy { $0.source == Self.source && $0.livesHere })
        #expect(finds.tags.map(\.tag.text) == ["#FediqoRising"])
        let whole = try #require(finds.people.first { $0.accountID == seeded.people.person.id })
        #expect(whole.tally.followers == 8 && whole.fields.count == 2 && !whole.words.contains("<"))

        let together = try await plain([("q", "fediqo")], as: seeded.reading)
        #expect(together.status == 200 && !together.accts.isEmpty && together.tags == ["FediqoRising"] && together.posts == 0)
        #expect(together.response.value(forHTTPHeaderField: "Link") == nil, "it names no next")
        #expect(together.response.value(forHTTPHeaderField: "x-ratelimit-limit") == "300")
        let people = try await plain([("q", "fediqo"), ("type", "accounts")], as: seeded.reading)
        #expect(!people.accts.isEmpty && people.tags.isEmpty)
        let tags = try await plain([("q", "fediqo"), ("type", "hashtags")], as: seeded.reading)
        #expect(tags.accts.isEmpty && tags.tags == ["FediqoRising"])
        for word in ["fediqorising", "#FediqoRising"] {
            #expect(try await plain([("q", word), ("type", "hashtags")], as: seeded.reading).tags == ["FediqoRising"], "\(word)")
        }
        let bogus = try await plain([("q", "fediqo"), ("type", "bogus")], as: seeded.reading)
        #expect(bogus.status == 200 && bogus.body == Data(MastodonSearchCaptures.nothing.utf8))
        let two = try await plain([("q", "fediqo"), ("limit", "2")], as: seeded.reading)
        #expect(two.accts.count == 2 && two.tags.count == 1)
        for length in ["0", "abc"] {
            let none = try await plain([("q", "fediqo"), ("limit", length)], as: seeded.reading)
            #expect(none.status == 200 && none.body == Data(MastodonSearchCaptures.nothing.utf8), "\(length)")
        }
        for words in [[("q", "")], [("q", "   ")], [("type", "accounts")]] {
            let refused = try await plain(words, as: seeded.reading)
            #expect(refused.status == 400 && refused.body == Data(MastodonSearchCaptures.noWords.utf8))
        }
    }

    @Test("The people found are read on by how many were passed over and by nothing else, and only with their kind named: stretches of two through this app's reader list nobody twice, an offset past the end is nobody, with no kind named the offset is ignored, max_id is ignored, and an offset of less than none is refused")
    func readOnByACount() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let search = try reader(seeded.reading).0
        var read = PeopleRead()
        var next: String?
        for _ in 0..<3 {
            let passed = try next.map { try #require(MastodonSearch.passed($0)) } ?? 0
            let stretch = try await search.people(matching: "fediqo", source: Self.source, after: passed, limit: 2)
            #expect(stretch.people.count == 2)
            read = try read.readingOn(stretch)
            next = read.next
        }
        #expect(read.people.count == 6 && Set(read.people.map(\.id)).count == 6 && next == "6")
        let past = try await search.people(matching: "fediqo", source: Self.source, after: 400)
        #expect(past == PeopleStretch(people: [], next: nil))

        let first = try await plain([("q", "fediqo"), ("limit", "2")], as: seeded.reading)
        let ignored = try await plain([("q", "fediqo"), ("limit", "2"), ("offset", "2")], as: seeded.reading)
        #expect(first.accts == ignored.accts && first.accts.count == 2, "with no kind named, an offset moves nothing")
        let typed = try await plain([("q", "fediqo"), ("type", "accounts"), ("limit", "2"), ("offset", "2")], as: seeded.reading)
        #expect(Set(typed.accts).isDisjoint(with: first.accts) && typed.accts.count == 2)
        let byID = try await plain([("q", "fediqo"), ("type", "accounts"), ("limit", "2"), ("max_id", "1")], as: seeded.reading)
        #expect(byID.accts == first.accts, "max_id is not how it goes on")
        #expect(try await plain([("q", "fediqo"), ("type", "accounts"), ("offset", "-1")], as: seeded.reading).status == 400)
    }

    @Test("With no sign-in people and hashtags are given, and neither a look-up nor a stretch further in: each is refused as needing a sign-in, to nobody and to a token that is none. A sign-in without the word for search is refused everything with a 403 that names what is missing — through this app's reader too — and goes on being honoured for what it holds")
    func whoMayAsk() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let nobody = try await plain([("q", "fediqo")])
        #expect(nobody.status == 200 && nobody.accts.contains(seeded.people.person.acct) && nobody.tags == ["FediqoRising"])
        for token in [nil, "not-a-token"] {
            let resolve = try await plain([("q", "fediqo"), ("type", "accounts"), ("resolve", "true")], as: token)
            #expect(resolve.status == 401 && resolve.body == Data(MastodonSearchCaptures.resolveUnsigned.utf8))
            let unresolved = try await plain([("q", "fediqo"), ("type", "accounts"), ("resolve", "false")], as: token)
            #expect(unresolved.status == 200 && !unresolved.accts.isEmpty)
        }
        let further = try await plain([("q", "fediqo"), ("type", "accounts"), ("limit", "2"), ("offset", "2")])
        #expect(further.status == 401 && further.body == Data(MastodonSearchCaptures.pagingUnsigned.utf8))

        for words in [[("q", "fediqo")], [("q", "fediqo"), ("type", "hashtags")], [("q", "@far@elsewhere.example"), ("type", "accounts"), ("resolve", "true")]] {
            let refused = try await plain(words, as: seeded.narrow)
            #expect(refused.status == 403 && refused.body == Data(MastodonSearchCaptures.outsideScopes.utf8))
            let header = refused.response.value(forHTTPHeaderField: "WWW-Authenticate")
            #expect(header?.contains("read:search") == true)
            #expect(MastodonScopeRefusal.isOne(status: refused.status, body: Data(), authenticate: header), "told by the header alone")
        }
        let (narrow, tokens) = try reader(seeded.narrow)
        await #expect(throws: MastodonScopeError.outside) { try await narrow.everything(matching: "fediqo", source: Self.source) }
        let address = try #require(PersonAddress(typed: "@far@elsewhere.example"))
        await #expect(throws: MastodonScopeError.outside) { try await narrow.resolved(address, source: Self.source) }
        let held = try tokens.token(host: Self.host)
        #expect(held != nil, "refused, and not signed out")
    }

    @Test("Somebody suspended and somebody who moved are not found at all; somebody limited is found and said to be; and signed in, somebody the reader blocks, somebody they mute and somebody who blocks them are each found as anyone is given them — a search leaves nobody out for the reader")
    func whoIsFound() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let writer = try reader(try LocalServers.writerToken()).0
        func name(_ who: LocalServers.Seeded.People.Named) -> String { who.acct }
        for who in [seeded.people.gone, seeded.people.moved] {
            #expect(try await writer.everything(matching: name(who), source: Self.source).people.isEmpty, "\(who.acct)")
            #expect(try await plain([("q", name(who)), ("type", "accounts")]).accts.isEmpty, "\(who.acct)")
        }
        let limited = try await writer.everything(matching: name(seeded.people.limited), source: Self.source).people
        #expect(limited.map(\.accountID) == [seeded.people.limited.id] && limited.map(\.limited) == [true])
        for who in [seeded.people.blocked, seeded.people.muted, seeded.people.blocker] {
            let found = try await writer.everything(matching: name(who), source: Self.source).people
            #expect(found.map(\.accountID) == [who.id], "\(who.acct)")
        }
    }

    @Test("An address of somebody who lives there is found with and without a look-up, and the address of their page only with one; somebody of another server it has heard of is found unresolved, and looked up — their server being one nothing reaches — comes to nobody, with no word of why, as an address it never heard of does; found all the same by the address this server files them under. A post's address looked up as a person brings nothing")
    func addresses() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let search = try reader(seeded.reading).0
        let person = seeded.people.person, far = seeded.people.far

        let local = try #require(PersonAddress(typed: "@\(person.acct)@\(Self.host)"))
        #expect(try await search.resolved(local, source: Self.source).person.accountID == person.id)
        #expect(try await plain([("q", local.asked), ("type", "accounts"), ("resolve", "false")]).accts == [person.acct])
        let page = try #require(PersonAddress(typed: "https://\(Self.host)/@\(person.acct)"))
        #expect(try await plain([("q", page.asked), ("type", "accounts"), ("resolve", "false")], as: seeded.reading).accts.isEmpty)
        #expect(try await search.resolved(page, source: Self.source).person.accountID == person.id)

        let farHandle: String = "@\(far.acct)"
        let known = try #require(PersonAddress(typed: farHandle))
        #expect(try await plain([("q", known.asked), ("type", "accounts"), ("resolve", "false")], as: seeded.reading).accts == [far.acct])
        let unreached = try await plain([("q", known.asked), ("type", "accounts"), ("resolve", "true")], as: seeded.reading)
        #expect(unreached.status == 200 && unreached.body == Data(MastodonSearchCaptures.nothing.utf8))
        await #expect(throws: PersonReadError.unheardOf) { try await search.resolved(known, source: Self.source) }
        let filed = try #require(PersonAddress(typed: "https://elsewhere.example/users/far"))
        let found = try await search.resolved(filed, source: Self.source).person
        #expect(found.accountID == far.id && !found.livesHere && found.home == "elsewhere.example")

        let unheard = try #require(PersonAddress(typed: "@nobody@nowhere.example"))
        await #expect(throws: PersonReadError.unheardOf) { try await search.resolved(unheard, source: Self.source) }
        let never = try await plain([("q", unheard.asked), ("type", "accounts"), ("resolve", "false")], as: seeded.reading)
        #expect(never.status == 200 && never.body == Data(MastodonSearchCaptures.nothing.utf8))

        let post = "https://\(Self.host)/@\(person.acct)/\(try #require(seeded.people.posts.first))"
        #expect(PersonAddress(typed: post) == nil, "a post's address is no person's, and is never sent to be looked up")
        let asPerson = try await plain([("q", post), ("type", "accounts"), ("resolve", "true")], as: seeded.reading)
        #expect(asPerson.status == 200 && asPerson.body == Data(MastodonSearchCaptures.nothing.utf8))
    }
}
