import Foundation
import Testing
@testable import FediqoCore

/// #315, the reading: the people a Mastodon suggests to whoever is signed in, read out of what
/// a real server sent (`MastodonSuggestionsCaptures`) — through the signed-in door and no
/// other, a stretch at a time, on by how many were passed over, to the first stretch shorter
/// than was asked for, and absent only where the host's own address says so.
@Suite("The people a Mastodon suggests")
struct MastodonSuggestionsTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)
    private static let path = MastodonSuggestions.path

    private static func reader(
        _ body: String, status: Int = 200
    ) throws -> (MastodonSuggestions, FixtureSender, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let server = FixtureSender([path: .json(body, status: status)])
        return (MastodonSuggestions(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)), server, tokens)
    }

    private static func entries(_ ids: Range<Int>) -> String {
        "[" + ids.map { #"{"source":"staff","sources":["featured"],"account":{"id":"\#($0)","acct":"p\#($0)"}}"# }.joined(separator: ",") + "]"
    }

    @Test("What a real server sent is read as people, through the reader every account has: who they are, their counts, their words out of their markup — each out of the entry that says why it is suggested — and a stretch as long as was asked for names as its next how many it has passed over")
    func whatARealServerSent() async throws {
        let (reader, server, _) = try Self.reader(MastodonSuggestionsCaptures.afterThree)
        let stretch = try await reader.stretch(source: Self.source, after: 3, limit: 2)
        #expect(stretch.people.map(\.handle) == ["@fediqo_fan_2@social.example", "@fediqo_person@social.example"])
        #expect(stretch.people.map(\.name) == ["fediqo_fan_2", "Per :fediqo_mark: Son"])
        let person = try #require(stretch.people.last)
        #expect(person.tally == Person.Tally(posts: 9, following: 4, followers: 8) && person.emojis.count == 1)
        #expect(person.words.hasPrefix("Reads #fediqo309 beside @fediqo_other") && !person.words.contains("<"))
        #expect(person.fields.map(\.name) == ["Site", "Pronouns :fediqo_mark:"] && person.fields.first?.verifiedAt != nil)
        #expect(stretch.people.allSatisfy { $0.source == Self.source && !$0.suspended && !$0.limited && $0.moved == nil })
        #expect(stretch.next == "5")
        // The same account, read as the one account's answer is read.
        let whole = try #require(try JSONSerialization.jsonObject(with: Data(MastodonSuggestionsCaptures.afterThree.utf8)) as? [[String: Any]])
        let account = try #require(whole.last?["account"])
        let alone = try MastodonPeople.person(from: JSONSerialization.data(withJSONObject: account), source: Self.source)
        #expect(alone == person)
        #expect(await server.requests.count == 1)

        let first = try await Self.reader(MastodonSuggestionsCaptures.firstOne).0.stretch(source: Self.source, limit: 1)
        #expect(first.people.map(\.handle) == ["@fediqo_fan_1@social.example"] && first.next == "1")
    }

    @Test("It is asked at its own address, as the reader, of the host the sign-in is of and no other, for eighty people at most and never for none, and from how many were passed over where that is not none")
    func whatIsAsked() async throws {
        func asked(after: Int = 0, limit: Int = 80) async throws -> String {
            let (reader, server, _) = try Self.reader("[]")
            _ = try await reader.stretch(source: Self.source, after: after, limit: limit)
            let request = try #require(await server.requests.first)
            #expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)")
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host() == Self.host)
            #expect(request.url?.path == "/api/v2/suggestions")
            return request.url?.query ?? ""
        }
        #expect(try await asked() == "limit=80")
        #expect(try await asked(after: 160) == "limit=80&offset=160")
        #expect(try await asked(limit: 200) == "limit=80")
        #expect(try await asked(limit: 0) == "limit=1")
        #expect(try await asked(limit: -5) == "limit=1")
        // Another source's people are not asked for here, and a place that is no count asks nothing.
        let (reader, server, _) = try Self.reader("[]")
        for passed in [-1, MastodonSuggestions.furthest + 1] {
            await #expect(throws: MastodonRequestError.invalidURL) { try await reader.stretch(source: Self.source, after: passed) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await reader.stretch(source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await server.requests.isEmpty)
    }

    @Test("A stretch shorter than was asked for is the end — a real server gives as many as it was asked for while it has them — and so is an empty one; one as long as was asked names as its next how many were passed; an entry that cannot be read is nobody listed and still one passed; more than was asked for is held to what was asked; and past the furthest suggestions are read, there is no next")
    func whereItEnds() async throws {
        func stretch(_ body: String, after: Int = 0, limit: Int = 80) async throws -> PeopleStretch {
            try await Self.reader(body).0.stretch(source: Self.source, after: after, limit: limit)
        }
        #expect(try await stretch(MastodonSuggestionsCaptures.nobody) == PeopleStretch(people: [], next: nil))
        let short = try await stretch(Self.entries(0..<3))
        #expect(short.people.map(\.accountID) == ["0", "1", "2"] && short.next == nil)
        let whole = try await stretch(Self.entries(0..<80))
        #expect(whole.people.count == 80 && whole.next == "80")
        let on = try await stretch(Self.entries(80..<160), after: 80)
        #expect(on.next == "160")

        let holed = #"[{"account":{"id":"1","acct":"a"}},{"account":{"id":7}},"junk",{"sources":["featured"]},{"account":null},{"account":{"id":"2","acct":"b"}}]"#
        let read = try await stretch(holed, limit: 6)
        #expect(read.people.map(\.accountID) == ["1", "2"] && read.next == "6")
        let more = try await stretch(Self.entries(0..<5), limit: 2)
        #expect(more.people.map(\.accountID) == ["0", "1"] && more.next == "2")

        let last = try await stretch(Self.entries(0..<80), after: MastodonSuggestions.furthest - 80)
        #expect(last.people.count == 80 && last.next == nil)
        #expect(MastodonSuggestions.longest == 80 && MastodonSuggestions.furthest == 400)

        #expect(MastodonSuggestions.passed("80") == 80 && MastodonSuggestions.passed("400") == 400)
        for word in ["", "0", "401", "-1", "8x", "08000", "١٢"] { #expect(MastodonSuggestions.passed(word) == nil, "\(word)") }
    }

    @Test("What a stranger's server sent is bounded and cleaned where it enters: a name and a handle are fit for a line, words are cut and taken out of their markup, and a picture is fetched only over a safe scheme")
    func aStrangersWord() async throws {
        let long = String(repeating: "word ", count: 5_000)
        let body = #"""
        [{"source":"\#(long)","sources":["\#(long)"],"account":{"id":"1","acct":"a‮b","display_name":"Na‮me\nTwo","note":"<p>\#(long)</p><script>x</script>",
          "avatar":"javascript:alert(1)","header":"file:///etc/passwd","followers_count":-4,"statuses_count":"many"}}]
        """#
        let person = try #require(try await Self.reader(body).0.stretch(source: Self.source).people.first)
        #expect(person.lineName == "Name Two" && person.lineHandle == "@ab@social.example")
        #expect(person.words.unicodeScalars.count <= Person.wordsLength + 1 && !person.words.contains("<"))
        #expect(person.avatarURL == nil && person.headerURL == nil)
        #expect(person.tally.followers == nil && person.tally.posts == nil)
    }

    @Test("Suggestions are absent only where the host says their address is not there — a page of its own, its plain not-found, no body at all — and that is no word about the sign-in; a record that is not there, a refusal for want of a word and a failure are each a failure of that ask, and an answer that is no list is unreadable")
    func absentByItsOwnAddress() async throws {
        for body in [MastodonHostCaptures.noSuchAddress, MastodonHostCaptures.noMeansForIt, ""] {
            let (reader, _, tokens) = try Self.reader(body, status: 404)
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await reader.stretch(source: Self.source) }
            let held = try tokens.token(host: Self.host)
            #expect(held != nil)
        }
        let missing = try Self.reader(MastodonHostCaptures.noSuchRecord, status: 404).0
        await #expect(throws: MastodonAuthError.http(404)) { try await missing.stretch(source: Self.source) }
        for status in [403, 422, 429, 500, 503] {
            let (refused, _, tokens) = try Self.reader(MastodonSuggestionsCaptures.dismissalRefused, status: status)
            await #expect(throws: MastodonAuthError.http(status)) { try await refused.stretch(source: Self.source) }
            let held = try tokens.token(host: Self.host)
            #expect(held != nil, "\(status)")
        }
        for body in [#"{"error":"Not Found"}"#, "", "<html>", #"{"accounts":[]}"#] {
            let reader = try Self.reader(body).0
            await #expect(throws: MastodonPeopleError.unreadable) { try await reader.stretch(source: Self.source) }
        }
    }

    @Test("Read on through a list of people as it has been read, nobody is listed twice where the server drew its order again between two asks")
    func readOnNobodyTwice() async throws {
        let first = try await Self.reader(Self.entries(0..<80)).0.stretch(source: Self.source)
        let second = try await Self.reader(Self.entries(70..<90)).0.stretch(source: Self.source, after: 80)
        let read = try PeopleRead().readingOn(first).readingOn(second)
        #expect(read.people.count == 90)
        #expect(Set(read.people.map(\.accountID)).count == 90)
        #expect(read.ended)
    }
}
