import Foundation
import Testing
@testable import FediqoCore

/// #310: what Fediqo believes a Mastodon source says of somebody it knows and of their posts,
/// held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read
/// through this app's own reader, `MastodonPerson`, and beside it asked plainly for the part of
/// the answer the reader rests on. What it says of the lists of people is
/// `MastodonPeopleSaysTests`'.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`), and nothing here writes.
///
/// **Asked gently.** A run makes some forty requests and no registration.
@Suite("What a Mastodon says of somebody and their posts", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPersonSaysTests {
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

    private func unsigned() throws -> MastodonPerson {
        MastodonPerson(http: try LocalHTTP.client(), host: Self.host)
    }

    private func signedIn(_ accessToken: String, keptIn tokens: MemoryMastodonTokens = MemoryMastodonTokens()) throws -> MastodonPerson {
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonPerson(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    /// Somebody's posts read on through this app's reader until the source names no next.
    private func everything(_ reader: MastodonPerson, of id: String, limit: Int?) async throws -> (stretches: [PostStretch], read: PostsRead) {
        var stretches = [try await reader.posts(of: id, source: Self.source, limit: limit)]
        var read = try PostsRead().readingOn(stretches[0])
        while let next = read.next {
            let stretch = try await reader.posts(of: id, source: Self.source, after: next, limit: limit)
            read = try read.readingOn(stretch)
            stretches.append(stretch)
        }
        #expect(read.posts.count == stretches.map(\.posts.count).reduce(0, +), "no post came twice")
        return (stretches, read)
    }

    // MARK: - 1. Somebody the source knows

    @Test("Somebody is found by the id the source gives them and by their handle, the same person either way, unsigned as signed in; somebody of another server by their whole handle where the source has heard of them; and a handle or an id it knows nobody by is one it has not heard of — with the sign-in held")
    func knownAndUnheardOf() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let tokens = MemoryMastodonTokens()
        let mine = try signedIn(try LocalServers.seeded().writer, keptIn: tokens)

        let byID = try await unsigned().person(id: seeded.person.id, source: Self.source)
        #expect(byID.handle == "@\(seeded.person.acct)@\(Self.host)" && byID.tally.followers == 8 && byID.livesHere)
        for handle in [byID.handle, "@\(seeded.person.acct)", seeded.person.acct.uppercased()] {
            #expect(try await unsigned().person(handle: handle, source: Self.source) == byID, "\(handle)")
        }
        #expect(try await mine.person(id: seeded.person.id, source: Self.source) == byID)
        #expect(try await mine.person(handle: byID.handle, source: Self.source) == byID)

        let far = try await unsigned().person(handle: "@\(seeded.far.acct)", source: Self.source)
        #expect(far.accountID == seeded.far.id && !far.livesHere && far.home == "elsewhere.example")

        for reader in [try unsigned(), mine] {
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.person(handle: "@nobody@elsewhere.example", source: Self.source) }
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.person(handle: "@fediqo_nobody_here", source: Self.source) }
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.person(id: "1", source: Self.source) }
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.posts(of: "1", source: Self.source) }
        }
        #expect(try tokens.token(host: Self.host) != nil)
    }

    @Test("A suspended account is read as who it was and says it is suspended, with no posts and no next; one that moved names where; and both are found by their handles")
    func goneAndMoved() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let gone = try await unsigned().person(handle: "@\(seeded.gone.acct)", source: Self.source)
        #expect(gone.accountID == seeded.gone.id && gone.suspended && gone.tally.posts == 1)
        #expect(try await unsigned().posts(of: gone.accountID, source: Self.source) == PostStretch(posts: [], next: nil))
        let moved = try await unsigned().person(handle: "@\(seeded.moved.acct)", source: Self.source)
        #expect(moved.moved?.accountID == seeded.person.id && !moved.suspended)
        #expect(try await unsigned().person(id: try #require(moved.moved?.accountID), source: Self.source).accountID == seeded.person.id)
    }

    // MARK: - 2. Their posts, read on

    @Test("Their posts are read on by the source's own next to a last stretch shorter than was asked, every post once and newest first, a boost listed under its own id with the post it boosts beside it; the way on names the last post's id, the boost's own where the boost is last")
    func postsReadOn() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let path = "/api/v1/accounts/\(seeded.person.id)/statuses"

        let (stretches, read) = try await everything(try unsigned(), of: seeded.person.id, limit: 3)
        #expect(stretches.map(\.posts.count) == [3, 3, 2])
        #expect(read.posts.map(\.statusID) == seeded.posts.reversed() && Set(read.posts.map(\.id)).count == 8)
        let first = try await ask("\(path)?limit=3")
        #expect(first.ids == Array(seeded.posts.reversed().prefix(3)))
        #expect(first.header("Link")?.contains("max_id=\(first.ids[2])>; rel=\"next\"") == true)
        #expect(stretches[0].next == first.ids[2])
        #expect(try await ask("\(path)?limit=3&max_id=\(try #require(stretches[1].next))").header("Link")?.contains(#"rel="next""#) == false)

        let boost = try #require(read.posts.first), boosted = try #require(read.carried.first)
        #expect(boost.isReblog && boost.statusID == seeded.posts.last && boost.handle == "@\(seeded.person.acct)@\(Self.host)")
        #expect(read.carried.count == 1 && boost.reblogKey == NoteKey(host: Self.host, id: boosted.id))
        #expect(boosted.handle == "@fediqo_other@\(Self.host)" && !read.posts.contains { $0.id == boosted.id })
        let one = try await unsigned().posts(of: seeded.person.id, source: Self.source, limit: 1)
        #expect(one.posts.count == 1 && one.next == boost.statusID, "the boost's own id is where the next stretch begins")
        #expect(read.posts.dropFirst().allSatisfy { !$0.isReblog })

        // Somebody of another server: the posts that reached this source, and no more.
        let far = try await everything(try unsigned(), of: seeded.far.id, limit: 2)
        #expect(far.read.posts.map(\.statusID) == seeded.farPosts.reversed() && far.stretches.map(\.posts.count) == [2, 1])
        #expect(far.read.posts.allSatisfy { $0.handle == "@\(seeded.far.acct)" })
    }

    @Test("A stretch of posts is twenty where no length is asked and forty at most, and a place to go on from that is no id of the source's is answered with nothing and no failure — so read through this app it is an end, and one that could not stand in a query is never asked")
    func howLongAStretchIs() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let writer = try LocalServers.seeded().writer
        let me = try #require(try await ask("/api/v1/accounts/verify_credentials", as: writer).object["id"] as? String)

        let byDefault = try await unsigned().posts(of: me, source: Self.source)
        #expect(byDefault.posts.count == 20 && byDefault.next == byDefault.posts.last?.statusID)
        let most = try await unsigned().posts(of: me, source: Self.source, limit: 100)
        #expect(most.posts.count == 40 && most.next != nil)
        #expect(try await unsigned().posts(of: me, source: Self.source, after: most.next, limit: 100).posts.first?.statusID != most.posts.last?.statusID)

        let noID = try await ask("/api/v1/accounts/\(seeded.person.id)/statuses?max_id=abc")
        #expect(noID.status == 200 && noID.list.isEmpty && noID.header("Link") == nil)
        #expect(try await unsigned().posts(of: seeded.person.id, source: Self.source, after: "abc") == PostStretch(posts: [], next: nil))
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await unsigned().posts(of: seeded.person.id, source: Self.source, after: "abc&limit=1")
        }
    }

    // MARK: - 3. Who is given what

    @Test("Posts for their followers and for the people they named are not given to a reader who may not see them, and nothing says any were left out: nobody and somebody who does not follow them are given the same eight and a follower a ninth, while the account counts more than anybody was given")
    func whoIsGivenWhat() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let open = seeded.posts.reversed()
        let toNobody = try await everything(try unsigned(), of: seeded.person.id, limit: nil).read.posts.map(\.statusID)
        let toWriter = try await everything(try signedIn(try LocalServers.seeded().writer), of: seeded.person.id, limit: nil).read.posts.map(\.statusID)
        #expect(toNobody == Array(open) && toWriter == Array(open))
        #expect(!toNobody.contains(seeded.kept.private) && !toNobody.contains(seeded.kept.direct))

        // The one who hides their lists follows them.
        let toFollower = try await everything(try signedIn(seeded.hidden.token), of: seeded.person.id, limit: nil).read.posts.map(\.statusID)
        #expect(toFollower.count == 9 && toFollower.contains(seeded.kept.private) && !toFollower.contains(seeded.kept.direct))
        let counted = try #require(try await unsigned().person(id: seeded.person.id, source: Self.source).tally.posts)
        #expect(counted > toNobody.count, "the count is of more than was given: \(counted)")
    }

    @Test("Signed in, a post says what the reader did to it; with no sign-in, and with a token that is none, it says nothing of that — the token that is none is answered as nobody is, 200, and this app concludes no sign-out from it")
    func whatAPostSaysOfTheReader() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let mine = try await signedIn(try LocalServers.seeded().writer).posts(of: seeded.person.id, source: Self.source)
        #expect(mine.posts.dropFirst().allSatisfy { $0.favourited == false && $0.boosted == false })

        let open = try await unsigned().posts(of: seeded.person.id, source: Self.source)
        #expect(open.posts.allSatisfy { $0.favourited == nil && $0.boosted == nil && $0.bookmarked == nil })

        let tokens = MemoryMastodonTokens()
        let dead = try signedIn("not-a-token", keptIn: tokens)
        let read = try await dead.posts(of: seeded.person.id, source: Self.source)
        #expect(read.posts.map(\.statusID) == open.posts.map(\.statusID))
        #expect(read.posts.allSatisfy { $0.favourited == nil && $0.boosted == nil })
        #expect(try await dead.person(id: seeded.person.id, source: Self.source).accountID == seeded.person.id)
        #expect(try tokens.token(host: Self.host) != nil, "not signed out by it")
    }
}
