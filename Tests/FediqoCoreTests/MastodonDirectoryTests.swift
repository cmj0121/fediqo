import Foundation
import Testing
@testable import FediqoCore

/// #315, the reading: a Mastodon's directory of people, read out of what a real server sent
/// (`MastodonDirectoryCaptures`) — through the reader an account has everywhere, a stretch at a
/// time, on by how many were passed over, and absent only where the host's own address says so.
@Suite("A Mastodon's directory of people")
struct MastodonDirectoryTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let path = MastodonDirectory.path

    private static func reader(_ outcome: FixtureHTTP.Outcome) -> (MastodonDirectory, FixtureHTTP) {
        let http = FixtureHTTP([path: outcome])
        return (MastodonDirectory(http: http, host: host), http)
    }

    private static func accounts(_ ids: Range<Int>) -> String {
        "[" + ids.map { #"{"id":"\#($0)","acct":"p\#($0)"}"# }.joined(separator: ",") + "]"
    }

    @Test("What a real server sent is read as people, through the reader every account has: who they are, where they live, their counts, whether they hide their lists, their words out of their markup — and the stretch names as its next how many it has passed over")
    func whatARealServerSent() async throws {
        let (reader, http) = Self.reader(.text(MastodonDirectoryCaptures.newestTwo))
        let stretch = try await reader.stretch(source: Self.source, order: .new, limit: 2)
        #expect(stretch.people.map(\.handle) == ["@far_hidden@elsewhere.example", "@far@elsewhere.example"])
        #expect(stretch.people.map(\.name) == ["Far Hidden", "Far :far_mark: Away"])
        #expect(stretch.people.map(\.hidesLists) == [true, false] && stretch.people.allSatisfy { !$0.livesHere })
        #expect(stretch.people[1].tally == Person.Tally(posts: 1204, following: 310, followers: 2811))
        #expect(stretch.people[1].words == "Lives elsewhere :far_mark:" && stretch.people[1].emojis.count == 1)
        #expect(stretch.people.allSatisfy { $0.source == Self.source && $0.avatarURL?.scheme == "https" && $0.headerURL == nil })
        #expect(stretch.next == "2")
        // The same account, read as the one account's answer is read.
        let one = try #require(try JSONSerialization.jsonObject(with: Data(MastodonDirectoryCaptures.newestTwo.utf8)) as? [Any]).last
        let alone = try MastodonPeople.person(from: JSONSerialization.data(withJSONObject: try #require(one)), source: Self.source)
        #expect(alone == stretch.people[1])

        let after = try await Self.reader(.text(MastodonDirectoryCaptures.afterTwo)).0
            .stretch(source: Self.source, order: .new, after: 2, limit: 2)
        #expect(after.people.map(\.handle) == ["@fediqo_blocker@m.example", "@fediqo_hidden@m.example"] && after.next == "4")
        #expect(after.people.allSatisfy { $0.livesHere })
        #expect(await http.requested.count == 1)
    }

    @Test("It is asked at its own address, of that host and no other, by the two words the server takes for an order and no third, for eighty people at most and never for none; only the people who live there where that is wanted, and from how many were passed over where that is not none")
    func whatIsAsked() async throws {
        func asked(order: DirectoryOrder = .active, localOnly: Bool = false, after: Int = 0, limit: Int = 80) async throws -> String {
            let (reader, http) = Self.reader(.text("[]"))
            _ = try await reader.stretch(source: Self.source, order: order, localOnly: localOnly, after: after, limit: limit)
            let url = try #require(await http.requested.first)
            #expect(url.scheme == "https" && url.host() == Self.host && url.path == "/api/v1/directory")
            return url.query ?? ""
        }
        #expect(try await asked() == "order=active&limit=80")
        #expect(try await asked(order: .new, localOnly: true, after: 160) == "order=new&limit=80&local=true&offset=160")
        #expect(try await asked(limit: 200) == "order=active&limit=80")
        #expect(try await asked(limit: 0) == "order=active&limit=1")
        #expect(try await asked(limit: -5) == "order=active&limit=1")
        #expect(Set(DirectoryOrder.allCases.map(\.rawValue)) == ["active", "new"])
        // Another source's people are not asked for here, and a place that is no count asks nothing.
        let (reader, http) = Self.reader(.text("[]"))
        for passed in [-1, MastodonDirectory.furthest + 1] {
            await #expect(throws: MastodonRequestError.invalidURL) { try await reader.stretch(source: Self.source, after: passed) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await reader.stretch(source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await http.requested.isEmpty)
        // A host written in capitals is the host a source names in small letters.
        let folded = MastodonDirectory(http: FixtureHTTP([Self.path: .text("[]")]), host: "M.Example")
        #expect(try await folded.stretch(source: Self.source).people.isEmpty)
    }

    @Test("Its next is how many people it has passed, and an empty stretch is the end: a short one names a next all the same, since a host holds a stretch to a length of its own; an account that cannot be read is nobody listed and still one passed; more than was asked for is held to what was asked; and past the furthest a directory is read, there is no next")
    func itsNextIsACount() async throws {
        func stretch(_ body: String, after: Int = 0, limit: Int = 80) async throws -> PeopleStretch {
            try await Self.reader(.text(body)).0.stretch(source: Self.source, after: after, limit: limit)
        }
        #expect(try await stretch("[]").next == nil)
        #expect(try await stretch("[]", after: 80).next == nil)
        #expect(try await stretch(Self.accounts(0..<3)).next == "3")
        #expect(try await stretch(Self.accounts(0..<3), after: 80).next == "83")
        let holed = try await stretch(#"[{"id":"1","acct":"a"},{"id":"../2","acct":"b"},7,{"acct":"c"},{"id":"5","acct":"e"}]"#)
        #expect(holed.people.map(\.accountID) == ["1", "5"] && holed.next == "5")
        let flood = try await stretch(Self.accounts(0..<500), limit: 80)
        #expect(flood.people.count == 80 && flood.people.last?.accountID == "79" && flood.next == "80")
        #expect(try await stretch(Self.accounts(0..<2), after: MastodonDirectory.furthest - 1).next == nil)
        #expect(try await stretch(Self.accounts(0..<1), after: MastodonDirectory.furthest - 1).next == nil, "the furthest is where reading stops")
        #expect(try await stretch(Self.accounts(0..<1), after: MastodonDirectory.furthest - 2).next == String(MastodonDirectory.furthest - 1))
        #expect(MastodonDirectory.furthest == 4_000)

        #expect(MastodonDirectory.passed("80") == 80 && MastodonDirectory.passed("3999") == 3999)
        for none in ["", "0", "-1", "+3", " 3", "3 ", "1e3", "٣", "abc", "1000000", "100001", "4001", "04000", "3&local=true", "117418762800029218"] {
            #expect(MastodonDirectory.passed(none) == nil, "\(none)")
        }
    }

    @Test("What a stranger's server sent is bounded and cleaned where it enters: a name and a handle are fit for a line, words are cut and taken out of their markup, and a picture is fetched only over a safe scheme")
    func aStrangersWord() async throws {
        let long = String(repeating: "word ", count: 5_000)
        let body = #"""
        [{"id":"1","acct":"a‮b","display_name":"Na‮me\nTwo","note":"<p>\#(long)</p><script>x</script>",
          "avatar":"javascript:alert(1)","header":"file:///etc/passwd","followers_count":-4,"statuses_count":"many"}]
        """#
        let person = try #require(try await Self.reader(.text(body)).0.stretch(source: Self.source).people.first)
        #expect(person.lineName == "Name Two" && person.lineHandle == "@ab@m.example")
        #expect(person.words.unicodeScalars.count <= Person.wordsLength + 1 && !person.words.contains("<"))
        #expect(person.avatarURL == nil && person.headerURL == nil)
        #expect(person.tally.followers == nil && person.tally.posts == nil)
    }

    @Test("A directory is absent only where the host says its address is not there — switched off, a page of its own, no body at all; a record that is not there, the failure the server answers a word it does not take, a refusal and nothing answering are each a failure of that ask, and an answer that is no list is unreadable")
    func absentByItsOwnAddress() async throws {
        func ask(_ body: String, status: Int) async throws -> PeopleStretch {
            try await Self.reader(.text(body, status: status)).0.stretch(source: Self.source)
        }
        for body in [MastodonDirectoryCaptures.switchedOff, MastodonHostCaptures.noSuchAddress, ""] {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await ask(body, status: 404) }
        }
        #expect(MastodonDirectoryCaptures.switchedOff == MastodonHostCaptures.noMeansForIt)
        await #expect(throws: MastodonRequestError.http(404)) { try await ask(MastodonHostCaptures.noSuchRecord, status: 404) }
        for status in [401, 403, 422, 429, 500, 503] {
            await #expect(throws: MastodonRequestError.http(status)) { try await ask(MastodonDirectoryCaptures.switchedOff, status: status) }
        }
        for body in [#"{"error":"Not Found"}"#, "", "<html>", #"{"accounts":[]}"#] {
            await #expect(throws: MastodonPeopleError.unreadable) { try await ask(body, status: 200) }
        }
        await #expect(throws: FixtureHTTPError.unreachable) { try await Self.reader(.fail).0.stretch(source: Self.source) }
        await #expect(throws: URLError.self) { try await Self.reader(.cancelled).0.stretch(source: Self.source) }
        // Nobody listed is a directory, with nobody in it.
        #expect(try await ask(MastodonDirectoryCaptures.nobody, status: 200) == PeopleStretch(people: [], next: nil))
    }

    @Test("Asked as the reader it goes through the signed-in door, to the host the sign-in is of, with the same words; a not-found of the address is told there too, and is no word about the sign-in; a record not found and a refusal are that door's failures")
    func asTheReader() async throws {
        func reader(_ outcome: FixtureSender.Outcome) throws -> (MastodonDirectory, FixtureSender, MemoryMastodonTokens) {
            let tokens = MemoryMastodonTokens()
            try tokens.save(MastodonFixture.token)
            let server = FixtureSender([Self.path: outcome])
            return (MastodonDirectory(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)), server, tokens)
        }
        let home = Source(host: MastodonFixture.host, kind: .mastodon)
        let (signed, server, _) = try reader(.json(MastodonDirectoryCaptures.afterTwo))
        let stretch = try await signed.stretch(source: home, order: .new, localOnly: true, after: 2)
        #expect(stretch.people.count == 2 && stretch.next == "4")
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://\(MastodonFixture.host)/api/v1/directory?order=new&limit=80&local=true&offset=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)")
        await #expect(throws: MastodonRequestError.invalidURL) { try await signed.stretch(source: Self.source) }

        let (off, _, tokens) = try reader(.json(MastodonDirectoryCaptures.switchedOff, status: 404))
        await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await off.stretch(source: home) }
        let held = try tokens.token(host: MastodonFixture.host)
        #expect(held != nil)
        let (missing, _, _) = try reader(.json(MastodonHostCaptures.noSuchRecord, status: 404))
        await #expect(throws: MastodonAuthError.http(404)) { try await missing.stretch(source: home) }
        let (refused, _, _) = try reader(.json("", status: 500))
        await #expect(throws: MastodonAuthError.http(500)) { try await refused.stretch(source: home) }
    }

    @Test("Read on through a list of people as it has been read, nobody is listed twice where somebody joined between two asks, and a directory that goes on with nobody new is stopped")
    func readOnNobodyTwice() async throws {
        var read = try PeopleRead().readingOn(
            try await Self.reader(.text(Self.accounts(0..<3))).0.stretch(source: Self.source)
        )
        // Somebody joined at the head: the stretch after three begins with the third again.
        read = try read.readingOn(try await Self.reader(.text(Self.accounts(2..<5))).0.stretch(source: Self.source, after: 3))
        #expect(read.people.map(\.accountID) == ["0", "1", "2", "3", "4"] && read.next == "6")
        var barren = read
        #expect(throws: PagingError.notPaging) {
            for round in 0..<PeopleRead.barren {
                barren = try barren.readingOn(PeopleStretch(people: read.people, next: String(100 + round)))
            }
        }
    }
}
