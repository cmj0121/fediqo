import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by path and query, with a `Link` header where it is given one, and
/// remembers what it was asked, of which host, and as whom.
private actor PeopleServer: HTTPClient, HTTPSender {
    enum Answer: Sendable {
        case json(String, link: String? = nil, status: Int = 200)
        case fail
    }

    private let routes: [String: Answer]
    private(set) var asked: [String] = []
    private(set) var hosts: Set<String> = []
    private(set) var bearers: Set<String> = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let ask = url.path + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        hosts.insert(url.host ?? "")
        if let bearer = request.value(forHTTPHeaderField: "Authorization") { bearers.insert(bearer) }
        switch routes[ask] {
        case .json(let body, let link, let status):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: link.map { ["Link": $0] }
            )!
            return (Data(body.utf8), response)
        case .fail:
            throw URLError(.notConnectedToInternet)
        case nil:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// #310 and #311, in the half of them Core holds: somebody as a source says them, and a list of
/// people read a stretch at a time by the source's own word for what is next. Read from what a
/// real 4.6.6 answered (`MastodonPeopleCaptures`).
@Suite("Somebody as a source says them, and a stretch of people read on")
struct MastodonPeopleTests {
    private typealias Captures = MastodonPeopleCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let followersPath = "/api/v1/accounts/\(Captures.personID)/followers"
    private static let followingPath = "/api/v1/accounts/\(Captures.personID)/following"
    private static let followers = MastodonPeople.List.followers(of: Captures.personID)

    private func said(_ body: String) throws -> Person {
        try MastodonPeople.person(from: Data(body.utf8), source: Self.source)
    }

    private func unsigned(_ routes: [String: PeopleServer.Answer]) -> (MastodonPeople, PeopleServer) {
        let server = PeopleServer(routes)
        return (MastodonPeople(http: server, host: Captures.host), server)
    }

    private func signedIn(
        _ routes: [String: PeopleServer.Answer]
    ) throws -> (MastodonPeople, PeopleServer, MemoryMastodonTokens) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonPeople(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server, tokens)
    }

    /// The captured followers as the server would serve them: the first stretch at the list's
    /// own path, and each later one where the stretch before said it is.
    private static func served(_ stretches: [Captures.Stretch], at path: String) throws -> [String: PeopleServer.Answer] {
        var routes: [String: PeopleServer.Answer] = [:]
        var ask = path
        for stretch in stretches {
            routes[ask] = .json(stretch.body, link: stretch.link)
            guard let next = try MastodonLink.next(in: stretch.link) else { break }
            ask = "\(path)?max_id=\(next)"
        }
        return routes
    }

    /// Every stretch of a list, read on until the source names no next.
    private func everything(_ people: MastodonPeople, _ list: MastodonPeople.List) async throws -> [PeopleStretch] {
        var stretches = [try await people.stretch(list, source: Self.source)]
        while let next = stretches.last?.next {
            try #require(stretches.count < 12, "reading on never came to an end")
            stretches.append(try await people.stretch(list, source: Self.source, after: next))
        }
        return stretches
    }

    // MARK: - One person

    @Test("An account's answer is one person: who they are at the source, the name and the pictures it is written in, their own words without the markup, the fields they filled in and which one the source checked, what it counts of them, and that they live there")
    func aPerson() throws {
        let person = try said(Captures.person)
        #expect(person.source == Self.source && person.accountID == Captures.personID)
        #expect(person.id == "mastodon.localhost\u{1e}person\u{1e}\(Captures.personID)")
        #expect(person.handle == "@fediqo_person@mastodon.localhost" && person.lineHandle == person.handle)
        #expect(person.name == "Per :fediqo_mark: Son" && person.lineName == person.name)
        #expect(person.emojis.map(\.shortcode) == ["fediqo_mark"])
        #expect(person.emojis.first?.url.host() == Captures.host && person.emojis.first?.staticURL != nil)
        #expect(person.avatarURL?.absoluteString == "https://mastodon.localhost/avatars/original/missing.png")
        #expect(person.headerURL?.absoluteString == "https://mastodon.localhost/headers/original/missing.png")
        #expect(person.words == "Reads #fediqo309 beside @fediqo_other :fediqo_mark:\nhttps://example.com/about")
        #expect(person.fields == [
            Person.Field(name: "Site", value: "https://example.com/per", verifiedAt: MastodonJSON.date(from: "2026-10-01T00:00:00.000+00:00")),
            Person.Field(name: "Pronouns :fediqo_mark:", value: "they/them"),
        ])
        #expect(person.tally == Person.Tally(posts: 9, following: 4, followers: 8))
        #expect(person.livesHere && person.home == Captures.host)
        #expect(!person.hidesLists && !person.locked && person.sort == .person && person.moved == nil && !person.suspended)
    }

    @Test("Somebody who lives on another server is named with that server, lives there and not here, and carries the counts their own server gave — a field sent as a link is the link's words")
    func aPersonLivingElsewhere() throws {
        let far = try said(Captures.far)
        #expect(far.handle == "@far@elsewhere.example" && far.home == "elsewhere.example" && !far.livesHere)
        #expect(far.name == "Far :far_mark: Away" && far.emojis.map(\.shortcode) == ["far_mark"])
        #expect(far.words == "Lives elsewhere :far_mark:")
        #expect(far.fields == [Person.Field(name: "Home", value: "elsewhere.example/far")])
        #expect(far.tally == Person.Tally(posts: 1204, following: 310, followers: 2811))
        #expect(far.avatarURL?.host() == Captures.host, "the source's own copy of their picture")
        #expect(!far.hidesLists, "the source said nothing either way")
    }

    @Test("Whether they hide their lists is the source's yes and nothing else; a locked account, an automated one, one that moved and one suspended each say so, and one with nothing counts nothing rather than leaving its counts unsaid")
    func whatElseAnAccountSays() throws {
        #expect(try said(Captures.hidden).hidesLists)
        let farHidden = try said(Captures.farHidden)
        #expect(farHidden.hidesLists && !farHidden.livesHere && farHidden.tally.followers == 77)
        for plain in [Captures.person, Captures.locked, Captures.robot, Captures.moved, Captures.gone, Captures.limited] {
            #expect(try !said(plain).hidesLists)
        }

        #expect(try said(Captures.locked).locked)
        let robot = try said(Captures.robot)
        #expect(robot.sort == .automated && robot.tally == Person.Tally(posts: 0, following: 0, followers: 0))
        #expect(robot.name == "fediqo_robot", "no name of their own: the one they sign in by")

        let moved = try said(Captures.moved)
        #expect(moved.moved == Person.Moved(accountID: Captures.personID, handle: "@fediqo_person@mastodon.localhost"))
        #expect(moved.moved?.lineHandle == "@fediqo_person@mastodon.localhost")

        let gone = try said(Captures.gone)
        #expect(gone.suspended && gone.words.isEmpty && gone.fields.isEmpty && gone.handle == "@fediqo_gone@mastodon.localhost")
        #expect(try !said(Captures.limited).suspended)
    }

    @Test("What a stranger's server sent is made fit where it enters: a name that would turn a line round or run on is one bounded line, their words and their fields are bounded, a picture this device will not fetch is none, and a count that is not a count is one the source did not say")
    func cleanedAndBounded() throws {
        let fields = (1...40).map { #"{"name":"n\#($0)\nx","value":"<p>\#(String(repeating: "v", count: 600))</p>","verified_at":"not a date"}"# }
        let hostile = try said(#"""
        {
          "id": "42", "username": "u", "acct": "u@far.example",
          "display_name": "Al‮ice\nof \#(String(repeating: "a", count: 200))",
          "note": "<p>\#(String(repeating: "w", count: 9000))</p>",
          "avatar": "javascript:alert(1)", "header": "file:///etc/passwd",
          "locked": "yes", "bot": 1, "group": true, "suspended": null, "hide_collections": "true",
          "followers_count": -1, "following_count": "12", "statuses_count": 7,
          "emojis": [{"shortcode": "ok", "url": "https://far.example/ok.png"}, {"shortcode": "bad", "url": "data:x"}, 7],
          "fields": [\#(fields.joined(separator: ",")), "not a field"],
          "moved": {"id": "../7", "acct": "x"}
        }
        """#)
        #expect(!hostile.lineName.unicodeScalars.contains("\u{202E}") && !hostile.lineName.contains("\n"))
        #expect(hostile.lineName.count == LineText.nameLength + 1 && hostile.lineName.hasPrefix("Alice of a"))
        #expect(hostile.words.count == Person.wordsLength + 1 && hostile.words.hasSuffix("…"))
        #expect(hostile.fields.count == Person.fieldCount)
        #expect(hostile.fields.allSatisfy { $0.value.count == Person.fieldLength + 1 && $0.verifiedAt == nil })
        #expect(hostile.fields.first?.name == "n1 x")
        #expect(hostile.avatarURL == nil && hostile.headerURL == nil)
        #expect(hostile.emojis.map(\.shortcode) == ["ok"])
        #expect(hostile.tally == Person.Tally(posts: 7, following: nil, followers: nil))
        #expect(!hostile.locked && !hostile.hidesLists && !hostile.suspended, "a word of another shape is no word")
        #expect(hostile.sort == .group && hostile.moved == nil)

        // Who they are is the one thing that cannot be done without, and an id is trusted with
        // a path only where it could stand in one.
        for unreadable in [#"{"acct":"u"}"#, #"{"id":"42"}"#, #"{"id":"4/2","acct":"u"}"#, #"{"id":"42","acct":""}"#, "[]", "not json"] {
            #expect(throws: MastodonPeopleError.unreadable) { _ = try said(unreadable) }
        }
        let bare = try said(#"{"id":"42","acct":"u"}"#)
        #expect(bare.name == "u" && bare.handle == "@u@mastodon.localhost" && bare.tally == Person.Tally() && bare.words.isEmpty)
        #expect(try said(#"{"id":"42","acct":"u","moved":{"id":"42","acct":"u"}}"#).moved == nil, "moved to themself is moved nowhere")

        // An id is as long as a name is, wherever it is taken from.
        let long = String(repeating: "7", count: ListSubscription.idLength + 1)
        #expect(throws: MastodonPeopleError.unreadable) { _ = try said(#"{"id":"\#(long)","acct":"u"}"#) }
        #expect(try said(#"{"id":"\#(long.dropLast())","acct":"u","moved":{"id":"\#(long)","acct":"v"}}"#).moved == nil)
        #expect(MastodonPeople.List.followers(of: long).path == nil && MastodonPeople.List.following(of: String(long.dropLast())).path != nil)
        #expect(throws: MastodonPeopleError.unreadable) { _ = try MastodonLink.next(in: #"<https://h/p?max_id=\#(long)>; rel="next""#) }
    }

    @Test("The server somebody lives on is a host or nothing: the last part of their handle, in lower case and the one spelling a name has — and a part that would turn a sentence round, break it, run on, or name a path is no home, so nothing says they live there and nothing offers to ask it")
    func aHomeIsAHostOrNothing() throws {
        #expect(Person.host(named: "@a@Example.ORG") == "example.org")
        #expect(Person.host(named: "a@example.org") == "example.org")
        #expect(Person.host(named: "@a@bücher.example") == "xn--bcher-kva.example")
        for noHost in [
            "@a@\u{202E}moc.elgoog", "@a@x y", "@a@x\nz", "@a@", "@a", "a", "", "@a@ex/ample", "@a@ex?x", "@a@ex#x",
            "@a@https://example.org", "@a@-x.example", "@a@.example", "@a@ex_ample.org", "@a@ex*ample.org", "@a@ex%2eample", "@a@ex\u{200B}ample.org", "@a@[::1]", "@a@x:8443",
            "@a@" + String(repeating: "a", count: 100_000), "@a@" + String(repeating: "a.", count: 130),
        ] {
            #expect(Person.host(named: noHost) == nil, "\(noHost.prefix(40).debugDescription)")
        }

        let turned = try said(#"{"id":"42","acct":"a@\u202Emoc.elgoog"}"#)
        #expect(turned.home == nil && !turned.livesHere && turned.handle == "@a@\u{202E}moc.elgoog")
        #expect(!turned.lineHandle.unicodeScalars.contains("\u{202E}"), "and the handle a line says is cleaned as a name is")
        let long = try said(#"{"id":"42","acct":"a@\#(String(repeating: "a", count: 100_000))"}"#)
        #expect(long.home == nil && long.lineHandle.count <= LineText.nameLength + 1)
        #expect(try said(#"{"id":"42","acct":"a@Far.Example"}"#).home == "far.example")
    }

    @Test("What is kept is cut before it is worked on: their words and a field's value are bounded before the markup is taken out, by scalars and not by characters, and the fields and the pictures are bounded by how many")
    func boundedBeforeItIsRead() throws {
        // Markup past the bound is never reached, so what lies behind it is not read at all.
        let buried = String(repeating: "<i>", count: AccountDTO.noteLength) + "tail"
        let entities = String(repeating: "&#65;", count: 50_000)
        let emojis = (1...400).map { #"{"shortcode":"e\#($0)","url":"https://far.example/\#($0).png"}"# }.joined(separator: ",")
        let person = try said(#"""
        {"id": "42", "acct": "u", "note": "\#(entities)", "emojis": [\#(emojis)],
         "fields": [{"name": "a", "value": "\#(buried)"}, {"name": "b", "value": "\#(String(repeating: "<i>", count: 20))tail"}]}
        """#)
        #expect(person.words == String(repeating: "A", count: AccountDTO.noteLength / 5))
        #expect(person.fields.map(\.value) == ["", "tail"])
        #expect(person.emojis.count == Person.emojiCount && person.emojis.first?.shortcode == "e1")

        // One letter under thousands of marks is one character, and is still cut.
        let stacked = "a" + String(repeating: "\u{0301}", count: Person.wordsLength * 2)
        let made = Person(
            source: Self.source, accountID: "1", handle: "@a@b.example", name: "a", words: stacked,
            fields: (1...40).map { Person.Field(name: "n\($0)", value: "v") },
            emojis: (1...400).compactMap { URL(string: "https://b.example/\($0)").map { CustomEmoji(shortcode: "e", url: $0) } }
        )
        #expect(made.words.unicodeScalars.count == Person.wordsLength + 1 && made.words.hasSuffix("…"))
        #expect(made.fields.count == Person.fieldCount && made.emojis.count == Person.emojiCount)
    }

    // MARK: - A stretch of people, read on

    @Test("A list of people is read a stretch at a time by the source's own word for what is next, until it names none: every follower once, in the source's order, and nothing asked but the list's own path and the id each stretch handed on")
    func readOnToTheEnd() async throws {
        let (people, server) = unsigned(try Self.served(Captures.followers, at: Self.followersPath))
        let stretches = try await everything(people, Self.followers)
        #expect(stretches.map(\.people.count) == [2, 2, 2, 2, 0], "the stretch after a full last one is empty")
        #expect(stretches.map(\.next) == ["19", "7", "5", "3", nil], "the id of a follow, which no person in the stretch names")
        let all = stretches.dropFirst().reduce(stretches[0].people) { $0.readingOn($1.people) }
        #expect(all.map(\.accountID) == Captures.followerIDs && Set(all.map(\.id)).count == 8)
        #expect(all.map(\.livesHere) == [false, false, true, true, true, true, true, true])
        #expect(all.allSatisfy { $0.source == Self.source })
        #expect(await server.asked == [
            Self.followersPath, "\(Self.followersPath)?max_id=19", "\(Self.followersPath)?max_id=7",
            "\(Self.followersPath)?max_id=5", "\(Self.followersPath)?max_id=3",
        ], "no length asked for, and the address in the header never followed as sent")
        #expect(await server.bearers.isEmpty)
    }

    @Test("Signed in, the same list is read through the one signed-in door — the reader's token to the source's own host — and read on by the same word")
    func readOnSignedIn() async throws {
        let (people, server, _) = try signedIn(try Self.served(Captures.followersSignedIn, at: Self.followersPath))
        let first = try await people.stretch(Self.followers, source: Self.source)
        #expect(first.people.map(\.accountID) == Array(Captures.followerIDs.prefix(2)) && first.next == "19")
        let second = try await people.stretch(Self.followers, source: Self.source, after: first.next)
        #expect(second.people.count == 2 && second.next == "5", "two long, without the people the reader blocks or mutes")
        #expect(await server.bearers == ["Bearer tok-123"])
        #expect(await server.hosts == [Captures.host])
    }

    @Test("A stretch is as long as the source makes it unless a length is asked for, and a length asked for is asked again with what is next")
    func aLengthAskedFor() async throws {
        let (people, server) = unsigned([
            "\(Self.followersPath)?limit=2": .json(Captures.followers[0].body, link: Captures.followers[0].link),
            "\(Self.followersPath)?limit=2&max_id=19": .json(Captures.followers[1].body, link: Captures.followers[1].link),
        ])
        let first = try await people.stretch(Self.followers, source: Self.source, limit: 2)
        let second = try await people.stretch(Self.followers, source: Self.source, after: first.next, limit: 2)
        #expect(first.next == "19" && second.next == "7" && second.people.count == 2)
        #expect(await server.asked == ["\(Self.followersPath)?limit=2", "\(Self.followersPath)?limit=2&max_id=19"])

        // A length of none is answered with a failure of the server's own: one is asked for.
        let (least, asked) = unsigned(["\(Self.followersPath)?limit=1": .json(Captures.nobodyListed)])
        for none in [0, -3] {
            #expect(try await least.stretch(Self.followers, source: Self.source, limit: none).people.isEmpty)
        }
        #expect(await asked.asked == ["\(Self.followersPath)?limit=1", "\(Self.followersPath)?limit=1"])
    }

    @Test("A list that fits one stretch names no next, and whom they follow is asked at its own path")
    func aListInOneStretch() async throws {
        let (people, server) = unsigned([Self.followingPath: .json(Captures.following.body, link: Captures.following.link)])
        let stretch = try await people.stretch(.following(of: Captures.personID), source: Self.source)
        #expect(stretch.people.count == 4 && stretch.next == nil, "a header that names only what is newer is the end")
        #expect(stretch.people.map(\.handle).last == "@fediqo_fan_1@mastodon.localhost")
        #expect(await server.asked == [Self.followingPath])
    }

    @Test("A list its owner hides arrives as an empty one with no word of why — the stretch has nobody and no next, and it is the person who says the list is hidden")
    func aHiddenList() async throws {
        let hidden = try said(Captures.hidden)
        let path = "/api/v1/accounts/\(hidden.accountID)/followers"
        let (people, _) = unsigned([path: .json(Captures.nobodyListed)])
        let stretch = try await people.stretch(.followers(of: hidden.accountID), source: Self.source)
        #expect(stretch == PeopleStretch(people: [], next: nil))
        #expect(hidden.hidesLists && hidden.tally.followers == 2, "hidden, and not empty")
        #expect(try !said(Captures.robot).hidesLists && said(Captures.robot).tally.followers == 0, "empty, and not hidden")
    }

    @Test("Reading on lands nobody twice: somebody a stretch brings again stands where they stood")
    func nobodyTwice() throws {
        let stretches = try Captures.followers.map {
            try MastodonJSON.decoder.decode([AccountDTO].self, from: Data($0.body.utf8)).compactMap { $0.asPerson(source: Self.source) }
        }
        // The list gained somebody between two asks, so the second stretch begins one early.
        let read = stretches[0].readingOn([stretches[0][1]] + stretches[1]).readingOn(stretches[1])
        #expect(read.map(\.accountID) == Array(Captures.followerIDs.prefix(4)))
        // The same name at another source is somebody else.
        let elsewhere = Person(source: Source(host: "other.example", kind: .mastodon), accountID: read[0].accountID, handle: "@a@b", name: "a")
        #expect(read.readingOn([elsewhere]).count == 5)
    }

    // MARK: - The source's word for what is next

    @Test("Only the id is taken from the source's way on: an address that names another host, another path or more to ask is never followed, and the next ask goes where this one went")
    func theWayOnIsNeverFollowedAsSent() async throws {
        let astray = #"<https://evil.example/steal?max_id=19&limit=80&token=1>; rel="next""#
        let (people, server, _) = try signedIn([
            Self.followersPath: .json(Captures.followers[0].body, link: astray),
            "\(Self.followersPath)?max_id=19": .json(Captures.followers[1].body),
        ])
        let first = try await people.stretch(Self.followers, source: Self.source)
        #expect(first.next == "19")
        let second = try await people.stretch(Self.followers, source: Self.source, after: first.next)
        #expect(second.people.count == 2 && second.next == nil)
        #expect(await server.hosts == [Captures.host])
        #expect(await server.asked == [Self.followersPath, "\(Self.followersPath)?max_id=19"])
    }

    @Test("A header is read for its next and nothing else: none, or one naming only what is newer, is the end; the mark may be written any way a server writes it; and a next that names no place to go on from is not taken for the end")
    func theLinkHeader() throws {
        #expect(try MastodonLink.next(in: nil) == nil)
        #expect(try MastodonLink.next(in: "") == nil)
        #expect(try MastodonLink.next(in: Captures.following.link) == nil)
        #expect(try MastodonLink.next(in: Captures.followers[0].link) == "19")
        #expect(try MastodonLink.next(in: Captures.posts[0].link) == "117417151807144931")
        #expect(try MastodonLink.next(in: Captures.posts[2].link) == nil)
        for written in [
            #"<https://h/p?since_id=21>; rel="prev", <https://h/p?max_id=19>; rel="next""#,
            "<https://h/p?max_id=19>;rel=next",
            #"<https://h/p?max_id=19>; REL = "Next""#,
            #"<https://h/p?tags=a,b&max_id=19>; rel="next"; title="more, and more""#,
            #"<https://h/p?max_id=19>; rel="prev next""#, #"<https://h/p?max_id=19>; title="x"; rel="next last""#,
        ] {
            #expect(try MastodonLink.next(in: written) == "19", "\(written)")
        }
        #expect(try MastodonLink.next(in: #"<https://h/p?max_id=19>; rel="nextish"; title="rel=next""#) == nil)
        for unreadable in [
            #"<https://h/p?limit=2>; rel="next""#, #"<https://h/p?max_id=>; rel="next""#,
            #"<https://h/p?max_id=1/../2>; rel="next""#, #"<>; rel="next""#, #"<https://h/p?since_id=21>; rel="next""#,
        ] {
            #expect(throws: MastodonPeopleError.unreadable, "\(unreadable)") { _ = try MastodonLink.next(in: unreadable) }
        }
    }

    @Test("A source whose way on is the place it was asked from is not paging, and is not read on for ever; one whose way on cannot be read fails the stretch rather than end the list short")
    func aServerNotPaging() async throws {
        let (people, _) = unsigned([
            "\(Self.followersPath)?max_id=19": .json(Captures.followers[1].body, link: Captures.followers[0].link),
            Self.followersPath: .json(Captures.followers[0].body, link: #"<https://mastodon.localhost/x?page=2>; rel="next""#),
        ])
        await #expect(throws: MastodonPeopleError.notPaging) {
            _ = try await people.stretch(Self.followers, source: Self.source, after: "19")
        }
        await #expect(throws: MastodonPeopleError.unreadable) { _ = try await people.stretch(Self.followers, source: Self.source) }
    }

    @Test("A list read on remembers every place the source sent it: one that names a place it named before — a ring of two as of one — is not paging; one that brings nobody new stretch after stretch and still names a next is stopped at a bound; and a single stretch of nobody with a next, which a signed-in read may be, ends nothing")
    func aListReadOnIsNotReadForEver() throws {
        let people = try Captures.followers.map {
            try MastodonJSON.decoder.decode([AccountDTO].self, from: Data($0.body.utf8)).compactMap { $0.asPerson(source: Self.source) }
        }
        var read = PeopleRead()
        #expect(read.people.isEmpty && read.next == nil && !read.ended)

        // As the real list went: four stretches, and a fifth with nobody that ends it.
        for (stretch, next) in zip(people, ["19", "7", "5", "3", nil]) {
            read = try read.readingOn(PeopleStretch(people: stretch, next: next))
            #expect(read.next == next && read.ended == (next == nil))
        }
        #expect(read.people.map(\.accountID) == Captures.followerIDs)

        // A ring of two: A, B, and A again.
        var ring = try PeopleRead().readingOn(PeopleStretch(people: people[0], next: "19"))
        ring = try ring.readingOn(PeopleStretch(people: people[1], next: "7"))
        #expect(throws: MastodonPeopleError.notPaging) { _ = try ring.readingOn(PeopleStretch(people: people[2], next: "19")) }
        #expect(ring.people.count == 4 && ring.next == "7", "and what was read stands as it stood")

        // Nobody new, a fresh place every time.
        var barren = try PeopleRead().readingOn(PeopleStretch(people: people[0], next: "100"))
        barren = try barren.readingOn(PeopleStretch(people: [], next: "99"))
        #expect(barren.next == "99" && !barren.ended, "one stretch of nobody ends nothing")
        barren = try barren.readingOn(PeopleStretch(people: people[1], next: "98"))
        for step in 1..<PeopleRead.barren {
            barren = try barren.readingOn(PeopleStretch(people: step.isMultiple(of: 2) ? people[0] : [], next: String(98 - step)))
        }
        #expect(throws: MastodonPeopleError.notPaging) { _ = try barren.readingOn(PeopleStretch(people: [], next: "1")) }
        #expect(barren.people.count == 4)
        // Somebody new starts the count again.
        barren = try barren.readingOn(PeopleStretch(people: people[2], next: "2"))
        #expect(barren.people.count == 6 && barren.next == "2")
    }

    @Test("A list is read only of the source this reads: asked to stamp the people of another source, it asks nobody")
    func onlyOfItsOwnSource() async throws {
        let (people, server) = unsigned([Self.followersPath: .json(Captures.followers[0].body)])
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await people.stretch(Self.followers, source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await server.asked.isEmpty)
    }

    // MARK: - Refused, failed, unreadable

    @Test("A source that refuses or fails says so and nothing else: unsigned, its status; signed in, what the door threw, with the sign-in still held; a body that is not a list of people is unreadable; and an account in it this build cannot read is that one person not listed")
    func refusedOrFailed() async throws {
        let (missing, _) = unsigned([Self.followersPath: .json(Captures.missing, status: 404)])
        await #expect(throws: MastodonRequestError.http(404)) { _ = try await missing.stretch(Self.followers, source: Self.source) }

        let (refused, _, tokens) = try signedIn([Self.followersPath: .json(Captures.standingRefused, status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.stretch(Self.followers, source: Self.source) }
        #expect(try tokens.token(host: Captures.host) != nil)

        let (dark, _) = unsigned([Self.followersPath: .fail])
        await #expect(throws: URLError.self) { _ = try await dark.stretch(Self.followers, source: Self.source) }

        for body in [Captures.person, #"{"error":"x"}"#, "<html>"] {
            let (odd, _) = unsigned([Self.followersPath: .json(body)])
            await #expect(throws: MastodonPeopleError.unreadable) { _ = try await odd.stretch(Self.followers, source: Self.source) }
        }

        let mixed = #"[{"id":"1","acct":"a"}, {"acct":"no id"}, 7, {"id":"2","acct":"b@far.example"}]"#
        let (some, _) = unsigned([Self.followersPath: .json(mixed, link: Captures.followers[0].link)])
        let stretch = try await some.stretch(Self.followers, source: Self.source)
        #expect(stretch.people.map(\.handle) == ["@a@mastodon.localhost", "@b@far.example"] && stretch.next == "19")
    }

    @Test("A list of an account whose id could not stand in a path, and a stretch asked after a word that is no id, ask the source nothing")
    func nothingAskedByAnIdThatIsNone() async throws {
        let (people, server, _) = try signedIn([:])
        for list in [MastodonPeople.List.followers(of: "1/../../oauth/revoke"), .following(of: ""), .followers(of: "1?x=1")] {
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await people.stretch(list, source: Self.source) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await people.stretch(Self.followers, source: Self.source, after: "19&limit=80")
        }
        #expect(await server.asked.isEmpty)
    }

    @Test("The signed-in door hands a list's way on back beside its body, and keeps its one rule: a 401 the account check confirms forgets the sign-in")
    func theDoorHandsTheWayOnBack() async throws {
        let (_, server, tokens) = try signedIn([
            Self.followersPath: .json(Captures.followers[0].body, link: Captures.followers[0].link),
            Self.followingPath: .json("[]"),
            "/api/v1/lists": .json(Captures.standingUnsigned, status: 401),
            MastodonAuthorized.accountCheck: .json(Captures.standingUnsigned, status: 401),
        ])
        let door = MastodonAuthorized(token: Self.token, sender: server, store: tokens)
        let linked = try await door.getLinked(path: Self.followersPath)
        #expect(linked.link == Captures.followers[0].link && linked.body == Data(Captures.followers[0].body.utf8))
        #expect(try await door.getLinked(path: Self.followingPath).link == nil)
        await #expect(throws: MastodonAuthError.signedOut) { _ = try await door.getLinked(path: "/api/v1/lists") }
        #expect(try tokens.token(host: Captures.host) == nil)
    }
}
