import Foundation
import Testing
@testable import FediqoCore

/// #310, in the half of it Core holds: somebody a source knows read by their id or their handle,
/// and their posts read a stretch at a time by the source's own word for what is next. Read from
/// what a real 4.6.6 answered (`MastodonPeopleCaptures`).
@Suite("Somebody a source knows, and their posts read on")
struct MastodonPersonTests {
    private typealias Captures = MastodonPeopleCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let account = "/api/v1/accounts/\(Captures.personID)"
    private static let statuses = "\(account)/statuses"
    private static let lookup = MastodonPerson.lookupPath
    /// The seed's person's posts as the three captured stretches list them, newest first: a
    /// boost, an answer, one in public, and five more.
    private static let listed = [
        "117417151809415268", "117417151808635667", "117417151807144931", "117417151806675949",
        "117417151806152424", "117417151805516092", "117417151804850707", "117417151804136795",
    ]

    private func unsigned(_ routes: [String: PeopleServer.Answer]) -> (MastodonPerson, PeopleServer) {
        let server = PeopleServer(routes)
        return (MastodonPerson(http: server, host: Captures.host), server)
    }

    private func signedIn(
        _ routes: [String: PeopleServer.Answer]
    ) throws -> (MastodonPerson, PeopleServer, MemoryMastodonTokens) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonPerson(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server, tokens)
    }

    /// The captured posts as the server would serve them: each stretch where the one before
    /// said it is.
    private static func served() throws -> [String: PeopleServer.Answer] {
        var routes: [String: PeopleServer.Answer] = [:]
        var ask = statuses
        for stretch in Captures.posts {
            routes[ask] = .json(stretch.body, link: stretch.link)
            guard let next = try MastodonLink.next(in: stretch.link) else { break }
            ask = "\(statuses)?max_id=\(next)"
        }
        return routes
    }

    private func captured() throws -> [PostStretch] {
        try Captures.posts.map { capture in
            let sent = ReadMoment.now()
            let arrived = try MastodonJSON.decoder.decode([StatusDTO].self, from: Data(capture.body.utf8))
                .map { $0.arrival(source: Self.source, categories: [], sent: sent) }
            return PostStretch(
                posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged), next: try MastodonLink.next(in: capture.link)
            )
        }
    }

    // MARK: - Somebody the source knows

    @Test("Somebody is read by the id the source gives them and by their handle — asked as the source names its own where the handle names the source, and as it names a stranger otherwise — and is the same person either way")
    func byIdAndByHandle() async throws {
        let (reader, server) = unsigned([
            Self.account: .json(Captures.person),
            "\(Self.lookup)?acct=fediqo_person": .json(Captures.person),
            "\(Self.lookup)?acct=far@elsewhere.example": .json(Captures.far),
        ])
        let byID = try await reader.person(id: Captures.personID, source: Self.source)
        #expect(byID.accountID == Captures.personID && byID.handle == "@fediqo_person@mastodon.localhost" && byID.tally.followers == 8)
        for handle in ["@fediqo_person@mastodon.localhost", "fediqo_person@Mastodon.Localhost", "@fediqo_person", "fediqo_person"] {
            #expect(try await reader.person(handle: handle, source: Self.source) == byID, "\(handle)")
        }
        let far = try await reader.person(handle: "@far@elsewhere.example", source: Self.source)
        #expect(far.handle == "@far@elsewhere.example" && !far.livesHere && far.tally.followers == 2811)
        #expect(await server.asked == [Self.account] + Array(repeating: "\(Self.lookup)?acct=fediqo_person", count: 4)
            + ["\(Self.lookup)?acct=far@elsewhere.example"])
        #expect(await server.hosts == [Captures.host])
        #expect(await server.bearers.isEmpty)
    }

    @Test("A suspended account and one that moved are read as the people they are, and say so")
    func goneAndMoved() async throws {
        let gone = try MastodonPeople.person(from: Data(Captures.gone.utf8), source: Self.source)
        let (reader, _) = unsigned([
            "\(Self.lookup)?acct=fediqo_gone": .json(Captures.gone), "\(Self.lookup)?acct=fediqo_moved": .json(Captures.moved),
            "/api/v1/accounts/\(gone.accountID)/statuses": .json(Captures.nobodyListed),
        ])
        #expect(try await reader.person(handle: "@fediqo_gone", source: Self.source).suspended)
        #expect(try await reader.person(handle: "@fediqo_moved", source: Self.source).moved?.accountID == Captures.personID)
        // Their posts are answered as somebody's who wrote nothing: none, and no next.
        #expect(try await reader.posts(of: gone.accountID, source: Self.source) == PostStretch(posts: [], next: nil))
    }

    @Test("Somebody the source knows nobody as — by name or by number, unsigned or signed in — is one it has not heard of, and that is the whole answer: nothing else is asked, and the sign-in is held")
    func unheardOf() async throws {
        let missing: [String: PeopleServer.Answer] = [
            "\(Self.lookup)?acct=nobody@elsewhere.example": .json(Captures.missing, status: 404),
            "/api/v1/accounts/1": .json(Captures.missing, status: 404),
            "/api/v1/accounts/1/statuses": .json(Captures.missing, status: 404),
        ]
        let (open, asked) = unsigned(missing)
        let (mine, _, tokens) = try signedIn(missing)
        for reader in [open, mine] {
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.person(handle: "@nobody@elsewhere.example", source: Self.source) }
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.person(id: "1", source: Self.source) }
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.posts(of: "1", source: Self.source) }
        }
        #expect(await asked.asked == ["\(Self.lookup)?acct=nobody@elsewhere.example", "/api/v1/accounts/1", "/api/v1/accounts/1/statuses"])
        #expect(await asked.hosts == [Captures.host], "and nobody else was asked")
        #expect(try tokens.token(host: Captures.host) != nil)
    }

    @Test("A source that refuses or fails says so as it did and changes nothing: a refusal is not somebody unheard of, a body that is no account or no list of posts is unreadable, and a post this build cannot read is that one post not listed")
    func refusedOrFailed() async throws {
        let (refused, _, tokens) = try signedIn([
            Self.account: .json(Captures.standingRefused, status: 403), Self.statuses: .json("{}", status: 500),
        ])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.person(id: Captures.personID, source: Self.source) }
        await #expect(throws: MastodonAuthError.http(500)) { _ = try await refused.posts(of: Captures.personID, source: Self.source) }
        #expect(try tokens.token(host: Captures.host) != nil)

        let (dark, _) = unsigned([Self.account: .fail, Self.statuses: .json(Captures.standingRefused, status: 429)])
        await #expect(throws: URLError.self) { _ = try await dark.person(id: Captures.personID, source: Self.source) }
        await #expect(throws: MastodonRequestError.http(429)) { _ = try await dark.posts(of: Captures.personID, source: Self.source) }

        let (odd, _) = unsigned([Self.account: .json("[]"), Self.statuses: .json(Captures.person)])
        await #expect(throws: PersonReadError.unreadable) { _ = try await odd.person(id: Captures.personID, source: Self.source) }
        await #expect(throws: PersonReadError.unreadable) { _ = try await odd.posts(of: Captures.personID, source: Self.source) }

        // Asked for by number, somebody else's answer is no answer; by handle the source's word stands.
        let (other, _) = unsigned([Self.account: .json(Captures.far), "\(Self.lookup)?acct=fediqo_person": .json(Captures.far)])
        await #expect(throws: PersonReadError.unreadable) { _ = try await other.person(id: Captures.personID, source: Self.source) }
        #expect(try await other.person(handle: "@fediqo_person", source: Self.source).handle == "@far@elsewhere.example")

        let whole = try #require(try JSONSerialization.jsonObject(with: Data(Captures.posts[2].body.utf8)) as? [Any])
        let mixed = try JSONSerialization.data(withJSONObject: [whole[0], ["id": "no words"], 7, whole[1]])
        let (some, _) = unsigned([Self.statuses: .json(String(decoding: mixed, as: UTF8.self), link: Captures.posts[0].link)])
        let stretch = try await some.posts(of: Captures.personID, source: Self.source)
        #expect(stretch.posts.map(\.statusID) == Array(Self.listed.suffix(2)) && stretch.next == "117417151807144931")
    }

    @Test("Nothing is asked by a handle that is no handle, an id that is none, a place to go on from that is none, or of another source than the one this reads")
    func nothingAskedByWhatIsNoName() async throws {
        #expect(MastodonPerson.acct(of: "@a@Mastodon.Localhost", at: Captures.host) == "a")
        #expect(MastodonPerson.acct(of: "a@b.example", at: Captures.host) == "a@b.example")
        #expect(MastodonPerson.acct(of: "@a", at: Captures.host) == "a")
        let long = "a@" + String(repeating: "b", count: MastodonPerson.handleLength)
        let (reader, server, _) = try signedIn([:])
        for handle in ["", "@", "@@a", "a@", "@a@b@c", "a b@c", "a\n@c", "a@\u{202E}c", "a\u{200B}@c", long] {
            #expect(MastodonPerson.acct(of: handle, at: Captures.host) == nil, "\(handle.prefix(20).debugDescription)")
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.person(handle: handle, source: Self.source) }
        }
        for id in ["", "1/../2", "1?x", String(repeating: "7", count: ListSubscription.idLength + 1)] {
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.person(id: id, source: Self.source) }
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.posts(of: id, source: Self.source) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await reader.posts(of: Captures.personID, source: Self.source, after: "abc&limit=80")
        }
        let other = Source(host: "other.example", kind: .mastodon)
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.person(id: "1", source: other) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.person(handle: "@a", source: other) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.posts(of: "1", source: other) }
        #expect(await server.asked.isEmpty)
    }

    // MARK: - Their posts, read on

    @Test("Their posts are read a stretch at a time by the source's own word for what is next until it names none: every post once, newest first — a boost as the boost, under its own id at the time they boosted, with the post it boosts beside it and not in its place — through no category, and saying nothing of a reader nobody was")
    func postsReadOnToTheEnd() async throws {
        let (reader, server) = unsigned(try Self.served())
        var read = PostsRead()
        var stretches = [try await reader.posts(of: Captures.personID, source: Self.source)]
        read = try read.readingOn(stretches[0])
        while let next = read.next {
            stretches.append(try await reader.posts(of: Captures.personID, source: Self.source, after: next))
            read = try read.readingOn(try #require(stretches.last))
        }
        #expect(stretches.map(\.posts.count) == [3, 3, 2], "the last, shorter than was asked, names no next")
        #expect(stretches.map(\.next) == ["117417151807144931", "117417151805516092", nil])
        #expect(read.ended && read.posts.map(\.statusID) == Self.listed && Set(read.posts.map(\.id)).count == 8)
        #expect(await server.asked == [
            Self.statuses, "\(Self.statuses)?max_id=117417151807144931", "\(Self.statuses)?max_id=117417151805516092",
        ], "no length asked for, and the address in the header never followed as sent")

        let boost = try #require(read.posts.first)
        #expect(boost.isReblog && boost.body.isEmpty && boost.handle == "@fediqo_person@mastodon.localhost")
        #expect(boost.id.hasSuffix("/117417151809415268/activity"))
        let boosted = try #require(read.carried.first)
        #expect(read.carried.count == 1 && boosted.handle == "@fediqo_other@mastodon.localhost" && boosted.body == "fediqo298seed plain")
        #expect(boost.reblogKey == NoteKey(host: Captures.host, id: boosted.id) && boost.postedAt > boosted.postedAt)
        #expect(!read.posts.contains { $0.id == boosted.id }, "what a boost boosts is not listed as theirs")

        #expect(read.posts[1].reply != nil && read.posts[2].audience == .everyone)
        #expect(read.posts.dropFirst().allSatisfy { !$0.isReblog && $0.handle == boost.handle })
        #expect((read.posts + read.carried).allSatisfy { $0.categories.isEmpty && $0.source == Self.source })
        #expect((read.posts + read.carried).allSatisfy { $0.favourited == nil && $0.boosted == nil && $0.bookmarked == nil })
        #expect(read.posts[2].emojis.map(\.shortcode) == ["fediqo_mark"])
    }

    @Test("Signed in, the same posts are read through the one signed-in door, the reader's token to the source's own host; a length asked for is asked again with what is next, and is never less than one")
    func postsSignedInAndByLength() async throws {
        let (reader, server, _) = try signedIn([
            "\(Self.statuses)?limit=3": .json(Captures.posts[0].body, link: Captures.posts[0].link),
            "\(Self.statuses)?limit=3&max_id=117417151807144931": .json(Captures.posts[1].body, link: Captures.posts[1].link),
            "\(Self.statuses)?limit=1": .json("[]"),
        ])
        let first = try await reader.posts(of: Captures.personID, source: Self.source, limit: 3)
        let second = try await reader.posts(of: Captures.personID, source: Self.source, after: first.next, limit: 3)
        #expect(first.posts.count == 3 && second.posts.map(\.statusID) == Array(Self.listed[3..<6]))
        #expect(try await reader.posts(of: Captures.personID, source: Self.source, limit: 0).posts.isEmpty)
        #expect(await server.bearers == ["Bearer tok-123"])
        #expect(await server.hosts == [Captures.host])
        #expect(await server.asked.last == "\(Self.statuses)?limit=1")
    }

    @Test("Only the id is taken from the source's way on, and a way on that is the place asked from, or names none, fails the stretch rather than read for ever or end the posts short")
    func theWayOn() async throws {
        let astray = #"<https://evil.example/x?max_id=117417151807144931&token=1>; rel="next""#
        let (reader, server, _) = try signedIn([
            Self.statuses: .json(Captures.posts[0].body, link: astray),
            "\(Self.statuses)?max_id=117417151807144931": .json(Captures.posts[1].body, link: Captures.posts[0].link),
            "\(Self.statuses)?max_id=7": .json(Captures.posts[1].body, link: #"<https://mastodon.localhost/x?page=2>; rel="next""#),
        ])
        #expect(try await reader.posts(of: Captures.personID, source: Self.source).next == "117417151807144931")
        await #expect(throws: PagingError.notPaging) {
            _ = try await reader.posts(of: Captures.personID, source: Self.source, after: "117417151807144931")
        }
        await #expect(throws: PersonReadError.unreadable) { _ = try await reader.posts(of: Captures.personID, source: Self.source, after: "7") }
        #expect(await server.hosts == [Captures.host])
    }

    @Test("A 401 the account check does not confirm signs nobody out, and an answer given to a token is no proof the token lives: the read is refused or read, and the sign-in stands either way")
    func noSignOutConcluded() async throws {
        let (reader, _, tokens) = try signedIn([
            Self.account: .json(Captures.standingUnsigned, status: 401),
            MastodonAuthorized.accountCheck: .json(Captures.person),
            Self.statuses: .json(Captures.posts[2].body, link: Captures.posts[2].link),
        ])
        await #expect(throws: MastodonAuthError.http(401)) { _ = try await reader.person(id: Captures.personID, source: Self.source) }
        #expect(try await reader.posts(of: Captures.personID, source: Self.source).posts.count == 2)
        #expect(try tokens.token(host: Captures.host) != nil)
    }

    // MARK: - What a page of their posts holds

    @Test("Posts read on remember every place the source sent them: a place named before is a source not paging, as is one that goes on with nothing new past a bound — and what was read stands")
    func postsAreNotReadForEver() throws {
        let stretches = try captured()
        var ring = try PostsRead().readingOn(stretches[0])
        ring = try ring.readingOn(stretches[1])
        #expect(throws: PagingError.notPaging) { _ = try ring.readingOn(PostStretch(posts: stretches[2].posts, next: "117417151807144931")) }
        #expect(ring.posts.count == 6 && ring.next == "117417151805516092" && !ring.ended)

        var barren = try PostsRead().readingOn(stretches[0])
        for step in 1..<PostsRead.barren {
            barren = try barren.readingOn(PostStretch(posts: step.isMultiple(of: 2) ? stretches[0].posts : [], next: String(100 - step)))
        }
        #expect(throws: PagingError.notPaging) { _ = try barren.readingOn(PostStretch(posts: [], next: "1")) }
        barren = try barren.readingOn(stretches[1])
        #expect(barren.posts.count == 6 && barren.carried.count == 1, "something new starts the count again, and nothing lands twice")
        #expect(try barren.readingOn(stretches[2]).posts.map(\.statusID) == Self.listed)
    }
}
