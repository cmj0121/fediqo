import Foundation
import Testing
@testable import FediqoCore

/// #315: what Fediqo believes a Mastodon says of the people it suggests, held against the real
/// one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through this app's own
/// reader, `MastodonSuggestions`, and beside it asked plainly for the part of each answer the
/// reader rests on (`MastodonSuggestionsCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`): whoever runs the server
/// named nine people to suggest — the seven its directory lists, one suspended and one
/// limited — and the writer, who blocks one of them and mutes another, is suggested five.
///
/// **Nobody is told not to be suggested.** No sign-in the seed holds for this app's words may
/// tell the server that, and that refusal is what is checked; the asks that are let through
/// name an account nobody has, which dismisses nobody. What a dismissal does to the next read
/// was asked by hand in a window of its own and is in the captures' table: a dismissal cannot
/// be taken back through any address, so no check here makes one.
///
/// **Whoever a check follows it unfollows, however it ends**: one person, by the writer's
/// sign-in for everything, whatever became of the check.
///
/// **No order is pinned**: the server draws one by lot for each reader.
///
/// **Asked gently.** A run makes some forty requests and no registration.
@Suite("What a Mastodon says of the people it suggests", .enabled(if: LocalServers.requested), .serialized)
struct MastodonSuggestionsSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)
    private static let older = "/api/v1/suggestions"
    private static let dismissal = older + "/"

    private static func seeded() throws -> LocalServers.Seeded {
        let seeded = try LocalServers.seeded()
        _ = try #require(seeded.people, "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again")
        return seeded
    }

    private func plain(
        _ path: String, as token: String? = nil, method: String = "GET"
    ) async throws -> (status: Int, body: Data, response: HTTPURLResponse) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body, response)
    }

    private func accts(_ body: Data) throws -> [String] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
            .compactMap { ($0["account"] as? [String: Any])?["acct"] as? String }
    }

    private func reader(as token: String) throws -> MastodonSuggestions {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(host: Self.host, accessToken: token, clientID: "x", clientSecret: "x")
        try tokens.save(held)
        return MastodonSuggestions(door: MastodonAuthorized(token: held, sender: try LocalHTTP.client(), store: tokens))
    }

    @Test("Nobody is suggested anything unsigned, and a sign-in is by one word of reading every sign-in of this app holds: with this app's reading sign-in, its acting one and the two of follows the writer is given the same people, each an account beside why it is suggested; a sign-in for reading posts alone is refused in the server's words for a missing word")
    func whoMayRead() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let people = try #require(seeded.people), notices = try #require(seeded.notices)
        // The words of a 401 are in the asker's language, so only what it is is checked.
        let unsigned = try await plain(MastodonSuggestions.path)
        #expect(unsigned.status == 401 && !MastodonHostNotFound.isOfTheAddress(status: unsigned.status, body: unsigned.body))
        let bad = try await plain(MastodonSuggestions.path, as: "not-a-token")
        #expect(bad.status == 401)

        let expected = Set(([people.person, people.far] + people.fans.prefix(3)).map(\.acct))
        let following = try #require(people.following?.token), standing = try #require(people.standing?.token)
        for (name, token) in [("reading", notices.reading.token), ("acting", notices.acting.token), ("standing", standing), ("following", following)] {
            let said = try await plain(MastodonSuggestions.path, as: token)
            let given = try accts(said.body)
            #expect(said.status == 200, "\(name)")
            #expect(Set(given) == expected, "\(name)")
            #expect(given.count == expected.count, "\(name)")
            #expect(said.response.value(forHTTPHeaderField: "Link") == nil, "it names no next")
        }
        let entries = try #require(try JSONSerialization.jsonObject(with: try await plain(MastodonSuggestions.path, as: notices.reading.token).body) as? [[String: Any]])
        #expect(entries.allSatisfy { Set($0.keys) == ["source", "sources", "account"] })
        #expect(entries.allSatisfy { ($0["source"] as? String) == "staff" && ($0["sources"] as? [String]) == ["featured"] })

        let narrow = try await plain(MastodonSuggestions.path, as: try #require(people.narrow?.token))
        #expect(narrow.status == 403 && narrow.body == Data(MastodonSuggestionsCaptures.dismissalRefused.utf8))
        #expect(narrow.response.value(forHTTPHeaderField: "WWW-Authenticate") == MastodonSuggestionsCaptures.readingWants)
    }

    @Test("Asked as the reader it leaves out whoever they block or mute, and for everybody whoever it suspended or limited, though each was named and chose to be found: through this app's reader the writer is given five people, none marked suspended, limited or moved — and another person is given the two the writer blocks and mutes")
    func whoIsLeftOut() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let people = try #require(seeded.people), notices = try #require(seeded.notices)
        let said = try await reader(as: notices.reading.token).stretch(source: Self.source)
        let expected = Set(([people.person, people.far] + people.fans.prefix(3)).map(\.id))
        #expect(Set(said.people.map(\.accountID)) == expected && said.people.count == expected.count)
        #expect(said.next == nil, "shorter than was asked for: the end")
        #expect(said.people.allSatisfy { !$0.suspended && !$0.limited && $0.moved == nil })
        let far = try #require(said.people.first { $0.accountID == people.far.id })
        #expect(!far.livesHere && far.home == "elsewhere.example")

        let other = try accts(try await plain(MastodonSuggestions.path, as: people.hidden.token).body)
        #expect(other.contains(people.blocked.acct) && other.contains(people.muted.acct))
        #expect(!other.contains(people.gone.acct) && !other.contains(people.limited.acct))
    }

    @Test("It is read on by how many were passed over and by nothing else, and an ask past how many it has is answered with a failure of the server's own: stretches of two are five people with nobody twice, the third — of one — is the end and nothing is asked after it; a length of none is answered with nobody though people are suggested")
    func readOnByACount() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let token = try #require(seeded.notices).reading.token
        let suggestions = try reader(as: token)
        var read = PeopleRead(), next: String?, asks = 0
        repeat {
            let passed = try next.map { try #require(MastodonSuggestions.passed($0)) } ?? 0
            let stretch = try await suggestions.stretch(source: Self.source, after: passed, limit: 2)
            #expect(stretch.people.count <= 2)
            read = try read.readingOn(stretch)
            next = read.next
            asks += 1
        } while next != nil && asks < 8
        #expect(asks == 3)
        #expect(read.ended)
        #expect(read.people.count == 5)
        #expect(Set(read.people.map(\.accountID)).count == 5)

        let atTheEnd = try await plain(MastodonSuggestions.path + "?limit=2&offset=5", as: token)
        #expect(atTheEnd.status == 200 && atTheEnd.body == Data(MastodonSuggestionsCaptures.nobody.utf8))
        let past = try await plain(MastodonSuggestions.path + "?limit=2&offset=1000", as: token)
        #expect(past.status == 500)
        let none = try await plain(MastodonSuggestions.path + "?limit=0", as: token)
        #expect(none.status == 200 && none.body == Data(MastodonSuggestionsCaptures.nobody.utf8))
        let all = try await plain(MastodonSuggestions.path + "?limit=200", as: token)
        let ignored = try await plain(MastodonSuggestions.path + "?limit=200&max_id=1", as: token)
        let whole: [String] = try accts(all.body), again: [String] = try accts(ignored.body)
        #expect(whole == again && whole.count == 5, "max_id is not how it goes on, and the order is kept between two asks")
    }

    @Test("A length or a place it does not know is not refused: asked for eighty, for more than eighty or for two hundred it gives what there is; a length below none is one person and a length that is no number is nobody; a place before the first is the last person; and a place that is no number, and a page, are not heard at all")
    func lengthsAndPlacesItDoesNotKnow() async throws {
        try await LocalServers.requireHealthy()
        let token = try #require(try Self.seeded().notices).reading.token
        func given(_ query: String) async throws -> [String] {
            let said = try await plain(MastodonSuggestions.path + query, as: token)
            #expect(said.status == 200, "\(query)")
            return try accts(said.body)
        }
        let whole = try await given("")
        #expect(whole.count == 5)
        for query in ["?limit=80", "?limit=81", "?limit=200", "?offset=abc", "?page=2"] {
            #expect(try await given(query) == whole, "\(query)")
        }
        #expect(try await given("?limit=-1") == Array(whole.prefix(1)))
        #expect(try await given("?limit=abc").isEmpty)
        #expect(try await given("?offset=-1") == Array(whole.suffix(1)))
    }

    @Test("The older address still answers, by the same words: the same people in the same order, each the bare account with no reason beside it; unsigned, and with a sign-in for reading posts alone, it is refused as the newer one is")
    func theOlderAddress() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let people = try #require(seeded.people), token = try #require(seeded.notices).reading.token
        let newer = try accts(try await plain(MastodonSuggestions.path, as: token).body)
        let older = try await plain(Self.older, as: token)
        let bare = try #require(try JSONSerialization.jsonObject(with: older.body) as? [[String: Any]])
        #expect(older.status == 200)
        #expect(bare.compactMap { $0["acct"] as? String } == newer)
        #expect(bare.allSatisfy { $0["account"] == nil && $0["source"] == nil })
        #expect(try await plain(Self.older).status == 401)
        let narrow = try await plain(Self.older, as: try #require(people.narrow?.token))
        #expect(narrow.status == 403)
        #expect(narrow.response.value(forHTTPHeaderField: "WWW-Authenticate") == MastodonSuggestionsCaptures.readingWants)
    }

    @Test("Somebody the reader follows is gone from the very next read, and is suggested again once unfollowed")
    func followingTakesSomebodyOut() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let people = try #require(seeded.people), token = try #require(seeded.notices).reading.token
        let fan = try #require(people.fans.dropFirst(2).first), account = "/api/v1/accounts/\(fan.id)/"
        #expect(try accts(try await plain(MastodonSuggestions.path, as: token).body).contains(fan.acct))
        let thrown: (any Error)?
        do {
            let followed = try await plain(account + "follow", as: try #require(people.following?.token), method: "POST")
            #expect(followed.status == 200)
            let left = try accts(try await plain(MastodonSuggestions.path, as: token).body)
            #expect(!left.contains(fan.acct))
            #expect(left.count == 4)
            thrown = nil
        } catch {
            thrown = error
        }
        // Unfollowed whatever became of that, by the sign-in for everything.
        let undone = try? await plain(account + "unfollow", as: seeded.writer, method: "POST")
        #expect(undone?.status == 200, "left followed on the server: \(fan.acct)")
        if let thrown { throw thrown }
        let back = try accts(try await plain(MastodonSuggestions.path, as: token).body)
        #expect(back.contains(fan.acct))
        #expect(back.count == 5)
    }

    @Test("Telling it not to suggest somebody is refused to every sign-in this app makes — its reading one, its acting one, the two of follows — in the server's words for a missing word, which name the word that changes the reader's own account; a sign-in that may do everything is let through, even for an account nobody has; and the newer address takes no dismissal at all")
    func dismissingNeedsAWordNoSignInHolds() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let people = try #require(seeded.people), notices = try #require(seeded.notices)
        let somebody = Self.dismissal + people.person.id
        let following = try #require(people.following?.token), standing = try #require(people.standing?.token)
        for (name, token) in [("reading", notices.reading.token), ("acting", notices.acting.token), ("standing", standing), ("following", following)] {
            let refused = try await plain(somebody, as: token, method: "DELETE")
            #expect(refused.status == 403 && refused.body == Data(MastodonSuggestionsCaptures.dismissalRefused.utf8), "\(name)")
            #expect(refused.response.value(forHTTPHeaderField: "WWW-Authenticate") == MastodonSuggestionsCaptures.dismissalWants, "\(name)")
        }
        #expect(try await plain(somebody, method: "DELETE").status == 401)
        // An id nobody has, and one that is no number: the server answers as it does a
        // dismissal, and dismisses nobody.
        for id in ["1", "abc"] {
            let nobody = try await plain(Self.dismissal + id, as: seeded.writer, method: "DELETE")
            #expect(nobody.status == 200, "\(id)")
            #expect(nobody.body == Data(MastodonSuggestionsCaptures.dismissed.utf8), "\(id)")
        }
        let newer = try await plain(MastodonSuggestions.path + "/1", as: seeded.writer, method: "DELETE")
        #expect(MastodonHostNotFound.isOfTheAddress(status: newer.status, body: newer.body))
        // Nobody was dismissed by any of that.
        let still = try accts(try await plain(MastodonSuggestions.path, as: notices.reading.token).body)
        #expect(still.contains(people.person.acct) && still.count == 5)
    }
}
