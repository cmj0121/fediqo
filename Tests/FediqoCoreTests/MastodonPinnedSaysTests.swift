import Foundation
import Testing
@testable import FediqoCore

/// One answer of a local server, whole: its status, its headers, and its body as JSON where it
/// is JSON.
private struct PinnedAnswer {
    let status: Int
    let response: HTTPURLResponse
    let body: Data

    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    var list: [[String: Any]] { (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [] }
    var ids: [String] { list.compactMap { $0["id"] as? String } }
    var link: String? { response.value(forHTTPHeaderField: "Link") }
    /// What each address the answer names for more says for the word.
    var word: [String?] { MastodonLink.said(MastodonPerson.pinnedWord, in: link) }
    /// What each post says of being pinned: nothing where it carries no such word.
    var marks: [Bool?] { list.map { $0["pinned"] as? Bool } }
}

/// A local server asked plainly, with no sign-in unless a token is handed in.
private func asked(_ host: String, _ path: String, as token: String? = nil, _ method: String = "GET") async throws -> PinnedAnswer {
    guard let url = URL(string: "https://\(host)\(path)") else { throw LocalHTTPError.invalidURL }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("en", forHTTPHeaderField: "Accept-Language")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (body, response) = try await LocalHTTP.client().send(request)
    return PinnedAnswer(status: response.statusCode, response: response, body: body)
}

private func reader(_ host: String, as accessToken: String, keptIn tokens: MemoryMastodonTokens = MemoryMastodonTokens()) throws -> MastodonPerson {
    let token = MastodonToken(host: host, accessToken: accessToken, clientID: "x", clientSecret: "x")
    try tokens.save(token)
    return MastodonPerson(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
}

/// Runs `body` with `posts` pinned at `host` in that order by `token`'s account, and unpins
/// them again whatever became of it — and before it, should a run that died have left one.
private func pinning(_ posts: [String], at host: String, as token: String, _ body: () async throws -> Void) async throws {
    func unpinAll() async {
        for post in posts { _ = try? await asked(host, "/api/v1/statuses/\(post)/unpin", as: token, "POST") }
    }
    await unpinAll()
    let thrown: (any Error)?
    do {
        for post in posts {
            let pinned = try await asked(host, "/api/v1/statuses/\(post)/pin", as: token, "POST")
            #expect(pinned.status == 200, "pinning \(post): \(pinned.status)")
        }
        try await body()
        thrown = nil
    } catch {
        thrown = error
    }
    await unpinAll()
    if let thrown { throw thrown }
}

/// #310: what Fediqo believes a Mastodon says of the posts somebody pinned, held against the
/// real one this checkout brings up (`make servers`, Mastodon 4.6.6) — every line of the table
/// in `MastodonPinnedCaptures`. Each check goes through this app's own reader,
/// `MastodonPerson.pinned`, and beside it asks the server plainly for the part of the answer
/// the reader rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Nobody in the seed has pinned anything**, so the second check pins three of the writer's
/// spare posts through the server's own API, as them, **and unpins them however it ends**
/// (`pinning`). Nothing else is written.
///
/// **Asked gently.** A run makes some fifty requests and no registration.
@Suite("What a Mastodon says of the posts somebody pinned", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPinnedSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func seeded() throws -> (all: LocalServers.Seeded, people: LocalServers.Seeded.People, spare: [String]) {
        let all = try LocalServers.seeded()
        let stale: Comment = "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again"
        let spare = try #require(all.notices?.spare, stale)
        try #require(spare.count >= 3, stale)
        return (all, try #require(all.people, stale), spare)
    }

    private func ask(_ path: String, as token: String? = nil, _ method: String = "GET") async throws -> PinnedAnswer {
        try await asked(Self.host, path, as: token, method)
    }

    private func unsigned() throws -> MastodonPerson {
        MastodonPerson(http: try LocalHTTP.client(), host: Self.host)
    }

    private static func statuses(_ id: String) -> String { "/api/v1/accounts/\(id)/statuses" }

    @Test("Somebody who pinned nothing is answered with an empty list and no address for more — to nobody as to somebody signed in, and for a suspended account, somebody who blocks the reader, somebody of another server and an account with nothing alike — which read through this app is a stretch with nothing in it; an id nobody has is somebody the source has not heard of")
    func nonePinned() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let mine = try reader(Self.host, as: seeded.all.writer)
        let people = seeded.people
        for id in [people.person.id, people.gone.id, people.blocker.id, people.far.id, people.robot.id] {
            for token in [nil, seeded.all.writer] {
                let plain = try await ask("\(Self.statuses(id))?pinned=true", as: token)
                #expect(plain.status == 200 && plain.body == Data("[]".utf8) && plain.link == nil, "\(id)")
            }
            #expect(try await unsigned().pinned(of: id, source: Self.source) == PostStretch(posts: [], next: nil), "\(id)")
            #expect(try await mine.pinned(of: id, source: Self.source) == PostStretch(posts: [], next: nil), "\(id)")
        }
        let nobody = try await ask("\(Self.statuses("1"))?pinned=true")
        #expect(nobody.status == 404 && String(decoding: nobody.body, as: UTF8.self) == MastodonPeopleCaptures.missing)
        for reader in [try unsigned(), mine] {
            await #expect(throws: PersonReadError.unheardOf) { _ = try await reader.pinned(of: "1", source: Self.source) }
        }
    }

    @Test("What somebody pinned is given to anyone, the one pinned last first; only its author is told a post is pinned; every address the answer names repeats the word, and none does where the word is one the server does not know — which answers their ordinary posts; cut short, its next names the last listed post's id in a list that is not in id order, and the stretch after repeats; and neither a boost nor somebody else's post can be pinned")
    func whatIsPinned() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let writer = seeded.all.writer, other = seeded.all.other
        let id = try #require(try await ask("/api/v1/accounts/verify_credentials", as: writer).object["id"] as? String)
        let path = "\(Self.statuses(id))?pinned=true"
        // Oldest first as the seed made them; pinned second, third, then first.
        let (a, b, c) = (seeded.spare[0], seeded.spare[1], seeded.spare[2])
        try #require(a < b && b < c, "the seed's spare posts are not listed oldest first")
        let listed = [a, c, b]

        try await pinning([b, c, a], at: Self.host, as: writer) {
            // Given to anyone, in the order of pinning, and through this app the same notes.
            let tokens = MemoryMastodonTokens()
            let readers = [try unsigned(), try reader(Self.host, as: writer), try reader(Self.host, as: other), try reader(Self.host, as: "not-a-token", keptIn: tokens)]
            for reader in readers {
                let stretch = try #require(try await reader.pinned(of: id, source: Self.source))
                #expect(stretch.posts.map(\.statusID) == listed && stretch.next == nil && stretch.carried.isEmpty)
            }
            #expect(try tokens.token(host: Self.host) != nil, "a token that is none is answered as nobody is, and nobody is signed out")
            let mine = try #require(try await readers[1].pinned(of: id, source: Self.source))
            #expect(mine.posts.allSatisfy { $0.favourited != nil && $0.boosted == false })

            // Who is told a post is pinned: its author, and nobody else.
            let toNobody = try await ask(path), toAuthor = try await ask(path, as: writer), toAnother = try await ask(path, as: other)
            #expect(toNobody.ids == listed && toAuthor.ids == listed && toAnother.ids == listed)
            #expect(toNobody.marks == [nil, nil, nil] && toAnother.marks == [nil, nil, nil] && toAuthor.marks == [true, true, true])
            let ordinary = try await ask("\(Self.statuses(id))?limit=40", as: writer)
            #expect(Set(ordinary.list.filter { $0["pinned"] as? Bool == true }.compactMap { $0["id"] as? String }) == Set(listed))
            // Every post of theirs says so one way or the other; a boost they made says nothing.
            #expect(ordinary.list.allSatisfy { ($0["pinned"] is Bool) != ($0["reblog"] is [String: Any]) } && ordinary.word == [nil, nil])
            let alone = try await ask("/api/v1/statuses/\(c)"), aloneToAuthor = try await ask("/api/v1/statuses/\(c)", as: writer)
            #expect(alone.object["id"] as? String == c && alone.object["pinned"] == nil && aloneToAuthor.object["pinned"] as? Bool == true)

            // The addresses the answer names: the word, as it was sent.
            #expect(toNobody.word == ["true"] && toNobody.link?.contains(#"rel="next""#) == false)
            for yes in ["1", "yes"] {
                let answer = try await ask("\(Self.statuses(id))?pinned=\(yes)")
                #expect(answer.ids == listed && answer.word == [yes], "pinned=\(yes)")
            }
            // A word it does not know, the word with no value, and the word as a no: their ordinary posts.
            for (query, word) in [("fediqo_pinned=true", [String?]([nil, nil])), ("pinned", [nil, nil]), ("pinned=false", ["false", "false"])] {
                let answer = try await ask("\(Self.statuses(id))?\(query)&limit=4")
                #expect(answer.ids.count == 4 && answer.ids != listed && answer.word == word, "\(query)")
                #expect(answer.ids == answer.ids.sorted(by: >), "\(query): newest first, as their posts are")
            }

            // Cut short: a next that names the last listed post, and a stretch after it that repeats.
            let first = try await ask("\(path)&limit=2")
            #expect(first.ids == [a, c] && first.word == ["true", "true"])
            #expect(try MastodonLink.next(in: first.link) == c)
            let second = try await ask("\(path)&limit=2&max_id=\(c)")
            #expect(second.ids == [a, b], "every pinned post with a smaller id, the one given already among them")
            let onward = try #require(try await unsigned().pinned(of: id, source: Self.source, after: c))
            #expect(onward.posts.map(\.statusID) == [a, b] && onward.next == nil)
            let read = try PostsRead().readingOn(PostStretch(posts: mine.posts.prefix(2).map { $0 }, next: c)).readingOn(onward)
            #expect(read.posts.map(\.statusID) == listed && read.ended, "held once each, in the order they first came")

            // What can be pinned at all.
            let boost = try await ask("/api/v1/statuses/\(seeded.all.seeded.reblog)/pin", as: other, "POST")
            #expect(boost.status == 422 && String(decoding: boost.body, as: UTF8.self).contains("A boost cannot be pinned"))
            let theirs = try await ask("/api/v1/statuses/\(seeded.spare[2])/pin", as: other, "POST")
            #expect(theirs.status == 422 && String(decoding: theirs.body, as: UTF8.self).contains("Someone else's post cannot be pinned"))
        }
        #expect(try await ask(path).body == Data("[]".utf8), "left as it was found")
    }
}

/// The same asked of a server that speaks Mastodon's way of asking and is not one — a GoToSocial
/// 0.22.2, brought up only by `FEDIQO_SERVERS_GOTOSOCIAL=1 make servers` — where what tells a
/// pinned answer from an ordinary one is not what tells it on a Mastodon
/// (`servers/gotosocial/FINDINGS.md`). It makes no such server a supported source.
///
/// **Passed over unless asked for**, and failing where it was asked for and the server is not up.
/// What it pins — two posts of the seed's second person, as them — it unpins however it ends.
@Suite("What a GoToSocial says of the posts somebody pinned", .enabled(if: LocalServers.gotosocialRequested), .serialized)
struct GoToSocialPinnedSaysTests {
    private static let host = LocalServers.gotosocial
    private static let source = Source(host: host, kind: .mastodon)

    /// What `servers/gotosocial/seed.sh` wrote: a sign-in of each of its two people, and what
    /// the second of them posted.
    private struct Seeded: Decodable {
        struct Posts: Decodable {
            let plain: String
            let edited: String
            let reblog: String
        }
        let writer: String
        let other: String
        let otherID: String
        let seeded: Posts

        private enum CodingKeys: String, CodingKey {
            case writer, other, seeded
            case otherID = "other_id"
        }
    }

    private static func seeded() throws -> Seeded {
        let url = LocalServers.repoRoot.appending(path: "servers/.run/gotosocial-tokens.json")
        return try JSONDecoder().decode(Seeded.self, from: Data(contentsOf: url))
    }

    @Test("Nothing is read there with no sign-in; signed in, none pinned is an empty list, as an id nobody has is; what is pinned comes the one pinned first first, with no address named and every post saying the reader did not pin it unless they are its author; and the ordinary posts, which a made-up word brings, name addresses that say the word as a no and list a boost")
    func whatIsPinned() async throws {
        try await LocalServers.requireGoToSocial()
        let seeded = try Self.seeded()
        let path = "/api/v1/accounts/\(seeded.otherID)/statuses"
        let mine = try reader(Self.host, as: seeded.writer)
        let open = MastodonPerson(http: try LocalHTTP.client(), host: Self.host)

        #expect(try await asked(Self.host, "\(path)?pinned=true").status == 401)
        await #expect(throws: MastodonRequestError.http(401)) { _ = try await open.pinned(of: seeded.otherID, source: Self.source) }
        #expect(try await mine.pinned(of: seeded.otherID, source: Self.source) == PostStretch(posts: [], next: nil))
        let nobody = try await asked(Self.host, "/api/v1/accounts/01M4SMY2P3W13ETQGFFP4R91ZZ/statuses?pinned=true", as: seeded.writer)
        #expect(nobody.status == 200 && nobody.body == Data("[]".utf8))

        let listed = [seeded.seeded.edited, seeded.seeded.plain]
        try await pinning(listed, at: Self.host, as: seeded.other) {
            let stretch = try #require(try await mine.pinned(of: seeded.otherID, source: Self.source))
            #expect(stretch.posts.map(\.statusID) == listed && stretch.next == nil)

            let toAnother = try await asked(Self.host, "\(path)?pinned=true", as: seeded.writer)
            let toAuthor = try await asked(Self.host, "\(path)?pinned=true", as: seeded.other)
            #expect(toAnother.ids == listed && toAnother.link == nil && toAnother.marks == [false, false])
            #expect(toAuthor.ids == listed && toAuthor.link == nil && toAuthor.marks == [true, true])
            // A length and a place to go on from are passed over: the whole answer again.
            #expect(try await asked(Self.host, "\(path)?pinned=true&limit=1&max_id=\(listed[1])", as: seeded.writer).ids == listed)

            for query in ["", "?fediqo_pinned=true", "?pinned=false"] {
                let ordinary = try await asked(Self.host, "\(path)\(query)", as: seeded.writer)
                #expect(ordinary.ids.first == seeded.seeded.reblog && ordinary.list.first?["reblog"] is [String: Any], "\(query)")
                #expect(ordinary.word == ["false", "false"], "\(query)")
            }
            #expect(try await asked(Self.host, "\(path)?pinned=yes", as: seeded.writer).status == 400)

            let boost = try await asked(Self.host, "/api/v1/statuses/\(seeded.seeded.reblog)/pin", as: seeded.other, "POST")
            let theirs = try await asked(Self.host, "/api/v1/statuses/\(seeded.seeded.plain)/pin", as: seeded.writer, "POST")
            #expect(boost.status == 422 && theirs.status == 422)
        }
        #expect(try await asked(Self.host, "\(path)?pinned=true", as: seeded.writer).body == Data("[]".utf8), "left as it was found")
    }
}
