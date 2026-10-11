import Foundation
import Testing
@testable import FediqoCore

/// #319, the reading: what a Mastodon's search found, read out of what a real server sent
/// (`MastodonSearchCaptures`) — posts, people and hashtags in one ask, the people read on by a
/// count, and one address looked up, which is the one ask that says `resolve=true`.
@Suite("A Mastodon's search: people, hashtags and an address looked up")
struct MastodonSearchTests {
    private static let home = Source(host: MastodonFixture.host, kind: .mastodon)
    private static let path = "/api/v2/search"

    private static func search(
        _ body: String, status: Int = 200
    ) throws -> (MastodonSearch, FixtureSender, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let server = FixtureSender([path: .json(body, status: status)])
        return (MastodonSearch(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)), server, tokens)
    }

    private static func query(_ server: FixtureSender) async throws -> String {
        let request = try #require(await server.requests.first)
        #expect(request.url?.host() == MastodonFixture.host && request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)")
        return request.url?.query(percentEncoded: true) ?? ""
    }

    private static func accounts(_ ids: Range<Int>) -> String {
        #"{"accounts":["# + ids.map { #"{"id":"\#($0)","acct":"p\#($0)"}"# }.joined(separator: ",") + #"],"statuses":[],"hashtags":[]}"#
    }

    @Test("One ask with no kind named brings what a real server sent together: the people through the reader every account has, the hashtags through the reader a list of rising hashtags has, and no post where there was none — asked unresolved, for forty of each")
    func everythingInOneAsk() async throws {
        let (search, server, _) = try Self.search(MastodonSearchCaptures.together)
        let finds = try await search.everything(matching: "fediqo", source: Self.home)
        #expect(finds.people.map(\.handle) == ["@fediqo_other@\(MastodonFixture.host)", "@fediqo_third@\(MastodonFixture.host)"])
        #expect(finds.people.allSatisfy { $0.source == Self.home && $0.livesHere })
        let first = try #require(finds.people.first)
        #expect(first.tally == Person.Tally(posts: 8, following: 0, followers: 2))
        let tag = try #require(finds.tags.first)
        #expect(finds.tags.count == 1 && tag.tag.text == "#FediqoRising" && tag.use == RisingUse(posts: 15, people: 15, days: 2))
        #expect(finds.posts.isEmpty)
        #expect(try await Self.query(server) == "q=fediqo&resolve=false&limit=40")
        // The same account, read as the one account's answer is read.
        let whole = try #require(try JSONSerialization.jsonObject(with: Data(MastodonSearchCaptures.together.utf8)) as? [String: Any])
        let one = try #require((whole["accounts"] as? [Any])?.first)
        #expect(try MastodonPeople.person(from: JSONSerialization.data(withJSONObject: one), source: Self.home) == first)

        let limited = try await Self.search(MastodonSearchCaptures.limited).0.everything(matching: "x", source: Self.home)
        #expect(limited.people.map(\.limited) == [true], "somebody limited is found, and said to be")
        let nothing = try await Self.search(MastodonSearchCaptures.nothing).0.everything(matching: "x", source: Self.home)
        #expect(nothing.people.isEmpty && nothing.tags.isEmpty && nothing.posts.isEmpty)
    }

    @Test("Each kind is read entry by entry and kind by kind: an account or a hashtag that cannot be read is that one not listed, a kind in a shape that cannot be read is that kind found empty, a hashtag or a person given twice is listed once, and no kind is longer than was asked for however many a server sends; a body that is no answer at all, and a refusal, throw")
    func aStrangersWordIsBounded() async throws {
        let mixed = #"""
        {"accounts":[{"id":"1","acct":"a"},{"id":"../2","acct":"b"},17,{"id":"1","acct":"a"},{"acct":"c"}],
         "statuses":"none",
         "hashtags":[{"name":"Swift"},{"name":"swift"},{"name":"not a tag"},{"name":"ＳＷＩＦＴ"},{"nome":"x"},{"name":"birds","history":"never"}]}
        """#
        let finds = try await Self.search(mixed).0.everything(matching: "x", source: Self.home)
        #expect(finds.people.map(\.accountID) == ["1"] && finds.posts.isEmpty)
        #expect(finds.tags.map(\.tag.text) == ["#Swift", "#birds"] && finds.tags.allSatisfy { $0.use == .unsaid })

        let many = try await Self.search(Self.accounts(0..<90)).0.everything(matching: "x", source: Self.home)
        #expect(many.people.count == MastodonSearch.longest)
        let names = (0..<90).map { #"{"name":"t\#($0)"}"# }.joined(separator: ",")
        let tags = try await Self.search(#"{"hashtags":["# + names + "]}").0.everything(matching: "x", source: Self.home)
        #expect(tags.tags.count == MastodonSearch.longest && tags.people.isEmpty)

        for body in ["[]", "", "<html>", #"{"error":"Not Found"}"#] {
            await #expect(throws: (any Error).self) { try await Self.search(body).0.everything(matching: "x", source: Self.home) }
        }
        let (refused, _, tokens) = try Self.search(MastodonSearchCaptures.outsideScopes, status: 403)
        await #expect(throws: MastodonScopeError.outside) { try await refused.everything(matching: "x", source: Self.home) }
        let held = try tokens.token(host: MastodonFixture.host)
        #expect(held != nil, "refused, and not signed out")
        let (elsewhere, unasked, _) = try Self.search(MastodonSearchCaptures.together)
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await elsewhere.everything(matching: "x", source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await unasked.requests.isEmpty, "a source that is not the sign-in's is asked nothing")
    }

    @Test("A refusal for want of a scope is told from every other 403 by what the server said — the header a real one sent, or its own sentence — and only that is the refusal a search throws: a 403 that says anything else, or nothing, is the failure any other ask has, and no other status is a refusal whatever it says")
    func aRefusalForWantOfAScope() async throws {
        let sentence = Data(MastodonSearchCaptures.outsideScopes.utf8), header = MastodonPeopleCaptures.standingRefusedHeader
        #expect(MastodonScopeRefusal.isOne(status: 403, body: sentence, authenticate: nil))
        #expect(MastodonScopeRefusal.isOne(status: 403, body: Data(), authenticate: header))
        #expect(MastodonScopeRefusal.isOne(status: 403, body: Data(#"{"error":"此操作超出授權範圍"}"#.utf8), authenticate: header))
        let suspended = #"{"error":"Your login is currently disabled"}"#
        for body in [suspended, "", "<html>Forbidden</html>", #"{"error":7}"#, "[]"] {
            #expect(!MastodonScopeRefusal.isOne(status: 403, body: Data(body.utf8), authenticate: nil), "\(body)")
        }
        let revoked = MastodonSignInCaptures.afterRevokeHeader
        #expect(!MastodonScopeRefusal.isOne(status: 403, body: Data(suspended.utf8), authenticate: revoked))
        #expect(!MastodonScopeRefusal.isOne(status: 401, body: sentence, authenticate: header))
        #expect(!MastodonScopeRefusal.isOne(status: 200, body: sentence, authenticate: header))

        let far = try #require(PersonAddress(typed: "@far@elsewhere.example"))
        let (other, _, tokens) = try Self.search(suspended, status: 403)
        await #expect(throws: MastodonAuthError.http(403)) { try await other.everything(matching: "x", source: Self.home) }
        await #expect(throws: MastodonAuthError.http(403)) { try await other.people(matching: "x", source: Self.home) }
        await #expect(throws: MastodonAuthError.http(403)) { try await other.resolved(far, source: Self.home) }
        let held = try tokens.token(host: MastodonFixture.host)
        #expect(held != nil)
        let refused = try Self.search(MastodonSearchCaptures.outsideScopes, status: 403).0
        await #expect(throws: MastodonScopeError.outside) { try await refused.people(matching: "x", source: Self.home) }
    }

    @Test("What was typed goes into the ask as a value and nothing else — encoded by the address builder, cut to a length — so no letter of it can add a word to the ask or change the address asked")
    func whatWasTypedIsAValue() async throws {
        let typed = "a&resolve=true&type=statuses#x /../y?z=1 %26"
        let (search, server, _) = try Self.search(MastodonSearchCaptures.nothing)
        _ = try await search.everything(matching: typed, source: Self.home)
        let request = try #require(await server.requests.first)
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let expected = [
            URLQueryItem(name: "q", value: typed), URLQueryItem(name: "resolve", value: "false"), URLQueryItem(name: "limit", value: "40"),
        ]
        #expect(items == expected)
        #expect(url.path == Self.path && url.fragment == nil && url.host() == MastodonFixture.host)

        let long = String(repeating: "é", count: 5_000)
        let (cut, heard, _) = try Self.search(MastodonSearchCaptures.nothing)
        _ = try await cut.everything(matching: long, source: Self.home)
        let sent = try #require(await heard.requests.first?.url)
        let words = URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(words?.unicodeScalars.count == MastodonSearch.wordsLength)
    }

    @Test("The people found are read on by how many were passed over, with their kind named, forty at most and never none: a stretch names as its next how many it has passed, an empty one is the end, the furthest a search is read names none, and a next that is no such count is not one")
    func peopleReadOnByACount() async throws {
        let (search, server, _) = try Self.search(MastodonSearchCaptures.peopleAfterTwo)
        let stretch = try await search.people(matching: "fediqo", source: Self.home, after: 2, limit: 2)
        #expect(stretch.people.map(\.handle) == ["@fediqo_person@\(MastodonFixture.host)", "@fediqo_hidden@\(MastodonFixture.host)"])
        #expect(stretch.next == "4" && stretch.people.map(\.hidesLists) == [false, true])
        #expect(try await Self.query(server) == "q=fediqo&resolve=false&type=accounts&limit=2&offset=2")

        let (first, heard, _) = try Self.search(Self.accounts(0..<90))
        let whole = try await first.people(matching: "x", source: Self.home, limit: 500)
        #expect(whole.people.count == 40 && whole.next == "40")
        #expect(try await Self.query(heard) == "q=x&resolve=false&type=accounts&limit=40")
        let (none, asked, _) = try Self.search(MastodonSearchCaptures.nothing)
        #expect(try await none.people(matching: "x", source: Self.home, after: 40, limit: 0) == PeopleStretch(people: [], next: nil))
        #expect(try await Self.query(asked) == "q=x&resolve=false&type=accounts&limit=1&offset=40")
        let last = try await Self.search(Self.accounts(0..<40)).0.people(matching: "x", source: Self.home, after: MastodonSearch.furthest - 40)
        #expect(last.people.count == 40 && last.next == nil, "read as far as a search is read")

        await #expect(throws: MastodonRequestError.invalidURL) {
            try await Self.search(Self.accounts(0..<2)).0.people(matching: "x", source: Self.home, after: MastodonSearch.furthest + 1)
        }
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await Self.search(Self.accounts(0..<2)).0.people(matching: "x", source: Source(host: "other.example", kind: .mastodon))
        }
        await #expect(throws: MastodonPeopleError.unreadable) {
            try await Self.search(#"{"statuses":[]}"#).0.people(matching: "x", source: Self.home)
        }
        #expect(MastodonSearch.passed("40") == 40 && MastodonSearch.passed("400") == 400)
        for word in ["", "0", "401", "4000", "-4", "4a", " 4", "４"] { #expect(MastodonSearch.passed(word) == nil, "\(word)") }
    }

    @Test("An address of a person is a name at a server, or the address of the page a server keeps for them, and nothing else: not a name alone, not a post's address or a hashtag's, not an address over anything but https or with somebody's credentials in it, and nothing with a space or a mark nobody sees in it")
    func whatIsAnAddressOfAPerson() throws {
        #expect(PersonAddress(typed: "@far@Elsewhere.Example") == .handle("far@elsewhere.example"))
        #expect(PersonAddress(typed: "  far@elsewhere.example\n") == .handle("far@elsewhere.example"))
        #expect(PersonAddress(typed: "@far@elsewhere.example")?.asked == "@far@elsewhere.example")
        #expect(PersonAddress(typed: "@far@elsewhere.example")?.host == "elsewhere.example")
        let page = try #require(PersonAddress(typed: "https://Elsewhere.example/@far"))
        #expect(page.asked == "https://Elsewhere.example/@far" && page.host == "elsewhere.example" && page.name == "far")
        #expect(PersonAddress(typed: "https://elsewhere.example/users/far")?.name == "far")
        #expect(PersonAddress(typed: "https://m.example/@far@elsewhere.example")?.name == "far")

        let none = [
            "", "   ", "far", "@far", "far@", "@@elsewhere.example", "@far@elsewhere.example@x", "@fa r@elsewhere.example",
            "@far@else where.example", "@far@elsewhere.example/x", "@far@elsewhere.example:8443", "@f\u{200B}ar@elsewhere.example",
            "#tag", "two words", "far@elsewhere.example and more",
            "https://elsewhere.example/@far/1", "https://elsewhere.example/users/far/statuses/1", "https://elsewhere.example/tags/far",
            "https://elsewhere.example/", "https://elsewhere.example", "https://elsewhere.example/@", "https://elsewhere.example/far",
            "https://elsewhere.example/@far?x=1", "https://elsewhere.example/@far#x",
            "http://elsewhere.example/@far", "https://someone@elsewhere.example/@far", "javascript:alert(1)", "file:///etc/passwd",
            "@" + String(repeating: "a", count: 2_000) + "@elsewhere.example",
        ]
        for typed in none { #expect(PersonAddress(typed: typed) == nil, "\(typed)") }
    }

    @Test("Looking an address up is the one ask that says resolve, of people alone: who a real server found is believed where the address names them, whatever case it was typed in; an answer about anybody else is not believed, nobody found is that the source has not heard of them, and a refusal for want of search is that refusal and no sign-out")
    func lookingAnAddressUp() async throws {
        let far = try #require(PersonAddress(typed: "https://elsewhere.example/users/far"))
        let (search, server, _) = try Self.search(MastodonSearchCaptures.farByItsAddress)
        let person = try await search.resolved(far, source: Self.home).person
        #expect(person.handle == "@far@elsewhere.example" && !person.livesHere && person.home == "elsewhere.example")
        let asked = try #require(await server.requests.first?.url)
        let items = try #require(URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems)
        let expected = [
            URLQueryItem(name: "q", value: "https://elsewhere.example/users/far"), URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "type", value: "accounts"), URLQueryItem(name: "limit", value: "5"),
        ]
        #expect(items == expected && asked.host() == MastodonFixture.host)

        let typed = try #require(PersonAddress(typed: "@FAR@ELSEWHERE.EXAMPLE"))
        #expect(try await Self.search(MastodonSearchCaptures.farByItsAddress).0.resolved(typed, source: Self.home).person == person)
        let local = try #require(PersonAddress(typed: "https://\(MastodonFixture.host)/@fediqo_person"))
        #expect(try await Self.search(MastodonSearchCaptures.localByPage).0.resolved(local, source: Self.home).person.livesHere)

        let other = try #require(PersonAddress(typed: "@near@elsewhere.example"))
        await #expect(throws: PersonReadError.unheardOf) {
            try await Self.search(MastodonSearchCaptures.farByItsAddress).0.resolved(other, source: Self.home)
        }
        await #expect(throws: PersonReadError.unheardOf) {
            try await Self.search(MastodonSearchCaptures.nothing).0.resolved(far, source: Self.home)
        }
        await #expect(throws: PersonReadError.unreadable) { try await Self.search("[]").0.resolved(far, source: Self.home) }
        let (refused, _, tokens) = try Self.search(MastodonSearchCaptures.outsideScopes, status: 403)
        await #expect(throws: MastodonScopeError.outside) { try await refused.resolved(far, source: Self.home) }
        let held = try tokens.token(host: MastodonFixture.host)
        #expect(held != nil)
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await Self.search(MastodonSearchCaptures.nothing).0.resolved(far, source: Source(host: "other.example", kind: .mastodon))
        }
    }

    @Test("A handle looked up is whoever is at that very handle, wherever the answer lists them: somebody of the same name at another server listed first is passed over for the one the handle names, whatever case it was typed in. Only where nobody is at that handle is the same name at another server believed — and then by the handle the source gave, handed back as not at the address typed")
    func aHandleIsTheNameAndTheServer() async throws {
        func answer(_ accts: [String]) -> String {
            let accounts = accts.enumerated().map { #"{"id":"\#($0.offset + 1)","acct":"\#($0.element)"}"# }
            return #"{"accounts":["# + accounts.joined(separator: ",") + #"],"statuses":[],"hashtags":[]}"#
        }
        let typed = try #require(PersonAddress(typed: "@Bob@FAR.example"))
        let both = try await Self.search(answer(["bob@evil.example", "bob@far.example"])).0.resolved(typed, source: Self.home).person
        #expect(both.handle == "@bob@far.example" && both.accountID == "2")
        let cased = try await Self.search(answer(["bob@evil.example", "BOB@Far.Example"])).0.resolved(typed, source: Self.home).person
        #expect(cased.handle == "@BOB@Far.Example")
        let filed = try await Self.search(answer(["bob@evil.example"])).0.resolved(typed, source: Self.home).person
        #expect(filed.handle == "@bob@evil.example" && filed.home == "evil.example")
        await #expect(throws: PersonReadError.unheardOf) {
            try await Self.search(answer(["bobby@far.example"])).0.resolved(typed, source: Self.home)
        }
        // Somebody who lives at the source is at the handle that names it.
        let here = try #require(PersonAddress(typed: "@bob@\(MastodonFixture.host)"))
        let local = try await Self.search(answer(["bob@evil.example", "bob"])).0.resolved(here, source: Self.home).person
        #expect(local.livesHere && local.accountID == "2")
        #expect(typed.exactly(both) && !typed.exactly(filed) && typed.names(filed))
        let exact = try await Self.search(answer(["bob@evil.example", "bob@far.example"])).0.resolved(typed, source: Self.home)
        let byName = try await Self.search(answer(["bob@evil.example"])).0.resolved(typed, source: Self.home)
        #expect(exact.asTyped && !byName.asTyped)
    }

    @Test("The address of a page looked up is whoever's own server gives that very address as their page — the same server whatever case it is written in, the very path, nothing after it — wherever the answer lists them; then whoever of that name is at the server that keeps the page; and only then the first of the name alone, handed back as not at the address typed")
    func aPageIsItsAddressThenItsServer() async throws {
        func answer(_ accounts: [(acct: String, url: String?)]) -> String {
            let said = accounts.enumerated().map { place, account in
                let url = account.url.map { #","url":"\#($0)""# } ?? ""
                return #"{"id":"\#(place + 1)","acct":"\#(account.acct)"\#(url)}"#
            }
            return #"{"accounts":["# + said.joined(separator: ",") + #"],"statuses":[],"hashtags":[]}"#
        }
        func found(_ accounts: [(acct: String, url: String?)], by typed: String = "https://Web.Far.example/@bob") async throws -> PersonLookedUp {
            let page = try #require(PersonAddress(typed: typed))
            return try await Self.search(answer(accounts)).0.resolved(page, source: Self.home)
        }
        // The page's own address: their handle is at another server's name than their page is.
        let byAddress = try await found([
            ("bob@web.far.example", nil), ("bob@evil.example", "https://evil.example/@bob"), ("bob@far.example", "https://web.far.example/@bob"),
        ])
        #expect(byAddress.person.accountID == "3" && byAddress.asTyped)
        // An address that is nearly it is not it.
        let near = ["https://web.far.example/@bob?x=1", "https://web.far.example/@bob#x", "https://web.far.example/@Bob", "https://web.far.example/@bob/1", "http://web.far.example/@bob", "not an address"]
        for url in near {
            let other = try await found([("bob@evil.example", url), ("bob@web.far.example", nil)])
            #expect(other.person.accountID == "2" && other.asTyped, "\(url)")
        }
        // No such address given: the one at the server that keeps the page, wherever listed.
        let byServer = try await found([("bob@evil.example", nil), ("BOB@web.far.example", nil)])
        #expect(byServer.person.accountID == "2" && byServer.asTyped)
        // Nobody there either: the first of the name, and said not to be at the address typed.
        let byName = try await found([("bobby@web.far.example", nil), ("bob@evil.example", nil), ("bob@worse.example", nil)])
        #expect(byName.person.accountID == "2" && !byName.asTyped)
        await #expect(throws: PersonReadError.unheardOf) { _ = try await found([("bobby@web.far.example", nil)]) }
        // What a real server sent: found by the address it files them under, at their own server.
        let filed = try #require(PersonAddress(typed: "https://elsewhere.example/users/far"))
        let far = try await Self.search(MastodonSearchCaptures.farByItsAddress).0.resolved(filed, source: Self.home)
        #expect(far.asTyped && far.person.handle == "@far@elsewhere.example")
    }

    @Test("No other ask of a search says resolve, and a sign-in is known to search by its own words: the word for search, or the whole of reading")
    func nothingElseResolves() async throws {
        let (search, server, _) = try Self.search(MastodonSearchCaptures.nothing)
        _ = try await search.everything(matching: "@far@elsewhere.example", source: Self.home)
        _ = try await search.people(matching: "https://elsewhere.example/@far", source: Self.home)
        let queries = await server.requests.compactMap { $0.url?.query(percentEncoded: true) }
        #expect(queries.count == 2 && queries.allSatisfy { $0.contains("resolve=false") && !$0.contains("resolve=true") })

        #expect(MastodonOAuth.searches(MastodonOAuth.reading) && MastodonOAuth.searches("read write"))
        #expect(MastodonOAuth.searches(MastodonOAuth.scopes(writing: true, notices: true)))
        #expect(!MastodonOAuth.searches(MastodonOAuth.readingWithoutSearch) && !MastodonOAuth.searches("read:statuses"))
        #expect(!MastodonOAuth.searches(nil) && !MastodonOAuth.searches("") && !MastodonOAuth.searches("read:searching"))
        for rung in MastodonOAuth.ladder(writing: true) + MastodonOAuth.ladder(writing: false) {
            #expect(MastodonOAuth.searches(rung) == rung.contains("read:search"), "\(rung)")
        }
    }
}
