import Foundation
import Testing
@testable import FediqoCore

/// #309: what Fediqo believes a Mastodon source says of a person and of the lists of people it
/// keeps, held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) —
/// as `MastodonSaysTests` holds what it says of posts. Each check reads the server through this
/// app's own reader, `MastodonPeople`, and beside it asks the server plainly for the part of
/// the answer the reader rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`), and nothing here writes: a
/// suspended account, one that moved and somebody of another server are made only from inside
/// the server. What the same server answered once is kept word for word in
/// `MastodonPeopleCaptures`, which the checks that need no server read.
///
/// **Asked gently.** A run makes some thirty requests and no registration.
@Suite("What a Mastodon says of people", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPeopleSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func seeded() throws -> LocalServers.Seeded.People {
        try #require(
            try LocalServers.seeded().people,
            "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again"
        )
    }

    /// One answer, whole: its status, its headers, and its body as JSON where it is JSON.
    private struct Answer {
        let status: Int
        let response: HTTPURLResponse
        let body: Data

        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        var object: [String: Any] { json as? [String: Any] ?? [:] }
        var list: [[String: Any]] { json as? [[String: Any]] ?? [] }
        var ids: [String] { list.compactMap { $0["id"] as? String } }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    /// The server asked plainly, with no sign-in unless a token is handed in.
    private func ask(_ path: String, as token: String? = nil) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    private func unsigned() throws -> MastodonPeople {
        MastodonPeople(http: try LocalHTTP.client(), host: Self.host)
    }

    private func signedIn(_ accessToken: String) throws -> MastodonPeople {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonPeople(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    /// One account's answer, asked plainly, and the person this app makes of it.
    private func read(_ id: String) async throws -> (raw: Answer, person: Person) {
        let raw = try await ask("/api/v1/accounts/\(id)")
        #expect(raw.status == 200, "account \(id): \(raw.status)")
        return (raw, try MastodonPeople.person(from: raw.body, source: Self.source))
    }

    /// Every stretch of a list, read on through this app's reader until the source names no
    /// next — each folded into a `PeopleRead`, which a source going round or on for ever fails.
    private func everything(_ people: MastodonPeople, _ list: MastodonPeople.List, limit: Int?) async throws -> [PeopleStretch] {
        var stretches = [try await people.stretch(list, source: Self.source, limit: limit)]
        var read = try PeopleRead().readingOn(stretches[0])
        while let next = read.next {
            let stretch = try await people.stretch(list, source: Self.source, after: next, limit: limit)
            read = try read.readingOn(stretch)
            stretches.append(stretch)
        }
        #expect(read.ended && read.people.count == stretches.map(\.people.count).reduce(0, +))
        return stretches
    }

    // MARK: - 1. A person

    @Test("An account is given to anyone, the same by its id and by its handle, and this app makes a person of it: the name and its picture, the words without their markup, the fields and the one checked, and the counts — with nothing said of hiding by an account that never hid")
    func aPerson() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let (raw, person) = try await read(seeded.person.id)
        let byHandle = try await ask("/api/v1/accounts/lookup?acct=\(seeded.person.acct)")
        #expect(byHandle.status == 200 && byHandle.object["id"] as? String == seeded.person.id)
        #expect(raw.object["hide_collections"] is NSNull, "said as nothing, not as no")

        #expect(person.accountID == seeded.person.id && person.handle == "@\(seeded.person.acct)@\(Self.host)")
        #expect(person.name == "Per :fediqo_mark: Son" && person.emojis.map(\.shortcode) == ["fediqo_mark"])
        #expect(person.words == "Reads #fediqo309 beside @fediqo_other :fediqo_mark:\nhttps://example.com/about")
        #expect(person.fields.map(\.name) == ["Site", "Pronouns :fediqo_mark:"])
        #expect(person.fields.map(\.value) == ["https://example.com/per", "they/them"])
        #expect(person.fields.first?.verifiedAt != nil && person.fields.last?.verifiedAt == nil)
        #expect(person.tally.followers == 8 && person.tally.following == 4)
        #expect(person.tally.posts == raw.object["statuses_count"] as? Int)
        #expect(person.livesHere && !person.hidesLists && !person.locked && person.sort == .person)
        #expect(person.avatarURL != nil && person.headerURL != nil)

        let nobody = try await ask("/api/v1/accounts/lookup?acct=fediqo_nobody_here")
        #expect(nobody.status == 404 && nobody.object["error"] as? String == "Record not found")
    }

    @Test("A locked account, an automated one, one that moved and one suspended each say so in the account, and somebody of another server is named with that server and carries its counts")
    func whatElseAnAccountSays() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        #expect(try await read(seeded.locked.id).person.locked)
        let robot = try await read(seeded.robot.id).person
        #expect(robot.sort == .automated && robot.tally == Person.Tally(posts: 0, following: 0, followers: 0))
        let moved = try await read(seeded.moved.id).person
        #expect(moved.moved?.accountID == seeded.person.id && moved.moved?.handle == "@\(seeded.person.acct)@\(Self.host)")
        let gone = try await read(seeded.gone.id)
        #expect(gone.raw.object["suspended"] as? Bool == true && gone.person.suspended && gone.person.words.isEmpty)

        let far = try await read(seeded.far.id)
        #expect(far.raw.object["acct"] as? String == seeded.far.acct && seeded.far.acct.hasSuffix("@elsewhere.example"))
        #expect(!far.person.livesHere && far.person.home == "elsewhere.example" && far.person.handle == "@\(seeded.far.acct)")
        #expect(far.person.tally.followers == 2811 && far.person.fields.map(\.value) == ["elsewhere.example/far"])
    }

    // MARK: - 2. A list, read on

    @Test("Who follows somebody is read on by the source's own next — the id of a follow, which no account in the stretch names — to a stretch with nobody and no next, every follower once; signed in, the people the reader blocks and mutes are left out")
    func readingOn() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let followers = MastodonPeople.List.followers(of: seeded.person.id)
        let path = "/api/v1/accounts/\(seeded.person.id)/followers"

        let whole = try await ask(path)
        #expect(whole.status == 200 && whole.ids.count == 8)
        #expect(whole.header("Link")?.contains(#"rel="next""#) == false, "one stretch, and nothing after it")
        let first = try await ask("\(path)?limit=2")
        let link = first.header("Link") ?? ""

        let stretches = try await everything(try unsigned(), followers, limit: 2)
        #expect(stretches.map(\.people.count) == [2, 2, 2, 2, 0])
        let next = try #require(stretches.first?.next)
        #expect(link.contains("max_id=\(next)>; rel=\"next\""), "the source's own way on: \(link)")
        #expect(!first.ids.contains(next), "and not the id of anybody listed")
        #expect(stretches.last?.next == nil)
        let all = stretches.dropFirst().reduce(stretches[0].people) { $0.readingOn($1.people) }
        #expect(all.map(\.accountID) == whole.ids && Set(all.map(\.id)).count == 8)
        #expect(all.prefix(2).allSatisfy { !$0.livesHere } && all.dropFirst(2).allSatisfy(\.livesHere))

        // With no length asked for, the one stretch is the whole list and names no next.
        let once = try await unsigned().stretch(followers, source: Self.source)
        #expect(once.people.map(\.accountID) == whole.ids && once.next == nil)

        // As the writer, who blocks one of them and mutes another.
        let mine = try await everything(try signedIn(try LocalServers.seeded().writer), followers, limit: 2).flatMap(\.people)
        #expect(mine.map(\.accountID) == whole.ids.filter { ![seeded.muted.id, seeded.blocked.id].contains($0) })

        let following = try await unsigned().stretch(.following(of: seeded.person.id), source: Self.source)
        #expect(following.people.count == 4 && following.next == nil)
    }

    // MARK: - 3. Hidden, empty, and known in part

    @Test("A list its owner hides is answered exactly as an empty one — 200, nobody, no next — and only the account says which: the one who hides says so and counts two followers, the one with nobody says nothing and counts none; the owner, signed in, is given the list")
    func hiddenOrEmpty() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let empty = PeopleStretch(people: [], next: nil)

        let hidden = try await read(seeded.hidden.id)
        #expect(hidden.raw.object["hide_collections"] as? Bool == true && hidden.person.hidesLists)
        #expect(hidden.person.tally.followers == 2)
        let raw = try await ask("/api/v1/accounts/\(seeded.hidden.id)/followers")
        #expect(raw.status == 200 && raw.list.isEmpty && raw.header("Link") == nil)
        for list in [MastodonPeople.List.followers(of: seeded.hidden.id), .following(of: seeded.hidden.id)] {
            #expect(try await unsigned().stretch(list, source: Self.source) == empty)
            #expect(try await signedIn(try LocalServers.seeded().writer).stretch(list, source: Self.source) == empty)
        }
        let own = try await signedIn(seeded.hidden.token).stretch(.followers(of: seeded.hidden.id), source: Self.source)
        #expect(own.people.count == 2)

        let robot = try await read(seeded.robot.id).person
        #expect(!robot.hidesLists && robot.tally.followers == 0)
        #expect(try await unsigned().stretch(.followers(of: seeded.robot.id), source: Self.source) == empty)

        // A suspended account's lists are as empty, and nothing on a list says why.
        #expect(try await unsigned().stretch(.followers(of: seeded.gone.id), source: Self.source) == empty)
    }

    @Test("Of somebody who lives on another server the source lists only who has reached it beside the count their own server gave, and where it holds their lists to be hidden it says so as it does of its own")
    func knownInPart() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let far = try await read(seeded.far.id).person
        let listed = try await unsigned().stretch(.followers(of: seeded.far.id), source: Self.source)
        #expect(far.tally.followers == 2811 && listed.people.count == 2 && listed.next == nil)
        #expect(!far.hidesLists && listed.people.allSatisfy(\.livesHere))

        let farHidden = try await read(seeded.farHidden.id).person
        #expect(farHidden.hidesLists && !farHidden.livesHere && farHidden.tally.followers == 77)
        #expect(try await unsigned().stretch(.followers(of: seeded.farHidden.id), source: Self.source).people.isEmpty)
    }

    // MARK: - 4. What nothing on the list says

    @Test("Somebody who blocks the reader answers the reader with nobody on either list and no posts, 200 each, while anyone else is given them — and the account itself says nothing of it to the one blocked")
    func blockedByThem() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let writer = try LocalServers.seeded().writer
        let base = "/api/v1/accounts/\(seeded.blocker.id)"

        let account = try await ask(base, as: writer)
        #expect(account.status == 200 && account.object["acct"] as? String == seeded.blocker.acct)
        #expect(account.object["followers_count"] as? Int == 1 && account.object["statuses_count"] as? Int == 1)
        #expect(account.object["suspended"] == nil && account.object["hide_collections"] is NSNull)
        for part in ["followers", "following", "statuses"] {
            let mine = try await ask("\(base)/\(part)", as: writer)
            #expect(mine.status == 200 && mine.list.isEmpty && mine.header("Link") == nil, "\(part): \(mine.status)")
        }
        #expect(try await ask("\(base)/followers").list.count == 1)
        #expect(try await ask("\(base)/statuses").list.count == 1)

        let empty = PeopleStretch(people: [], next: nil)
        #expect(try await signedIn(writer).stretch(.followers(of: seeded.blocker.id), source: Self.source) == empty)
        #expect(try await unsigned().stretch(.followers(of: seeded.blocker.id), source: Self.source).people.count == 1)
        // Only how the reader stands to them says so, and that is another ask.
        let standing = try await ask("/api/v1/accounts/relationships?id[]=\(seeded.blocker.id)", as: writer)
        #expect(standing.list.first?["blocked_by"] as? Bool == true)
    }

    @Test("A token that is no token is answered as nobody is — 200, an account and a list alike — so a sign-in the source no longer honours reads these as anyone does and is told nothing")
    func aTokenThatIsNone() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let none = "not-a-token"
        let account = try await ask("/api/v1/accounts/\(seeded.person.id)", as: none)
        #expect(account.status == 200 && account.object["id"] as? String == seeded.person.id)
        let listed = try await ask("/api/v1/accounts/\(seeded.person.id)/followers", as: none)
        let toAnyone = try await ask("/api/v1/accounts/\(seeded.person.id)/followers")
        #expect(listed.status == 200 && listed.ids == toAnyone.ids && listed.ids.count == 8)
        // The owner's own hidden list, asked with it, is the empty one anybody is given.
        let hidden = try await ask("/api/v1/accounts/\(seeded.hidden.id)/followers", as: none)
        #expect(hidden.status == 200 && hidden.list.isEmpty)
        #expect(try await ask("/api/v1/accounts/relationships?id[]=\(seeded.person.id)", as: none).status == 401, "where a sign-in is needed, it is refused")

        // Through this app's door the same: read, and not signed out.
        let people = try signedIn(none)
        #expect(try await people.stretch(.followers(of: seeded.person.id), source: Self.source).people.count == 8)
    }

    @Test("Somebody of another server is found by their handle only where this source has heard of them: the one it holds is given, and a handle it never met is 404 — it asks the other server nothing")
    func foundOnlyWhereHeardOf() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let known = try await ask("/api/v1/accounts/lookup?acct=\(seeded.far.acct)")
        #expect(known.status == 200 && known.object["id"] as? String == seeded.far.id)
        for who in [nil, try LocalServers.seeded().writer] as [String?] {
            let unknown = try await ask("/api/v1/accounts/lookup?acct=nobody@elsewhere.example", as: who)
            #expect(unknown.status == 404 && unknown.object["error"] as? String == "Record not found")
        }
        let limited = try await read(seeded.limited.id)
        #expect(limited.raw.object["limited"] as? Bool == true && !limited.person.suspended)
    }

    // MARK: - 5. Nobody there

    @Test("A list of an account nobody has is refused with 404, unsigned and signed in, and the sign-in is not taken for it")
    func nobodyThere() async throws {
        try await LocalServers.requireHealthy()
        await #expect(throws: MastodonRequestError.http(404)) {
            _ = try await unsigned().stretch(.followers(of: "1"), source: Self.source)
        }
        let writer = try LocalServers.seeded().writer
        await #expect(throws: MastodonAuthError.http(404)) {
            _ = try await signedIn(writer).stretch(.followers(of: "1"), source: Self.source)
        }
        #expect(try await ask("/api/v1/accounts/verify_credentials", as: writer).status == 200)
    }
}
