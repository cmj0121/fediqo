import Foundation
import Testing
@testable import FediqoCore

/// #310, in the half of it Core holds: the posts somebody pinned read as their posts are, none
/// pinned told from a source that has no such thing, and their ordinary posts never taken for
/// pinned ones. Read from what a real 4.6.6 and a real GoToSocial answered
/// (`MastodonPinnedCaptures`).
@Suite("The posts somebody pinned")
struct MastodonPinnedTests {
    private typealias Captures = MastodonPinnedCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let other = Source(host: Captures.otherHost, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let statuses = "/api/v1/accounts/\(Captures.writerID)/statuses"
    private static let pinned = "\(statuses)?pinned=true"
    private static let otherPinned = "/api/v1/accounts/\(Captures.otherID)/statuses?pinned=true"

    private func unsigned(
        _ routes: [String: PeopleServer.Answer], host: String = Captures.host
    ) -> (MastodonPerson, PeopleServer) {
        let server = PeopleServer(routes)
        return (MastodonPerson(http: server, host: host), server)
    }

    private func signedIn(
        _ routes: [String: PeopleServer.Answer]
    ) throws -> (MastodonPerson, PeopleServer, MemoryMastodonTokens) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonPerson(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server, tokens)
    }

    private static func answer(_ stretch: Captures.Stretch) -> PeopleServer.Answer {
        .json(stretch.body, link: stretch.link)
    }

    /// What tells one note from another to whoever draws or holds it, without the moment it
    /// was read at.
    private static func told(_ notes: [Note]) -> [[String]] {
        notes.map { [$0.id, $0.statusID ?? "", $0.handle, $0.body, String(describing: $0.audience), "\($0.postedAt)", "\($0.counts)"] }
    }

    // MARK: - Read as their posts are

    @Test("What somebody pinned is read with no sign-in, by the one word more at the address their posts are at, into the same notes their posts are — and in the source's order, the one pinned last first, which is no order of ids or of time")
    func readAsPostsAre() async throws {
        let (reader, server) = unsigned([Self.pinned: Self.answer(Captures.pinned), Self.statuses: Self.answer(Captures.pinned)])
        let stretch = try #require(try await reader.pinned(of: Captures.writerID, source: Self.source))
        #expect(stretch.posts.map(\.statusID) == Captures.pinnedIDs && stretch.carried.isEmpty && stretch.next == nil)
        #expect(Captures.pinnedIDs != Captures.pinnedIDs.sorted() && Captures.pinnedIDs != Captures.pinnedIDs.sorted(by: >))
        let asPosts = try await reader.posts(of: Captures.writerID, source: Self.source)
        #expect(Self.told(stretch.posts) == Self.told(asPosts.posts), "the same notes, by the same reader")
        #expect(stretch.posts.allSatisfy { $0.source == Self.source && $0.categories.isEmpty && $0.handle == "@fediqo@mastodon.localhost" })
        #expect(stretch.posts.allSatisfy { $0.favourited == nil && $0.boosted == nil && $0.bookmarked == nil })
        #expect(try PostsRead().readingOn(stretch).posts.map(\.statusID) == Captures.pinnedIDs, "and held in that order")
        #expect(await server.asked == [Self.pinned, Self.statuses], "no length asked for")
        #expect(await server.hosts == [Captures.host])
        #expect(await server.bearers.isEmpty)
    }

    @Test("Signed in, the same is read through the one signed-in door, the reader's token to the source's own host, and a post says what the reader did to it; a next the source names is handed back")
    func signedInAsTheReader() async throws {
        let (reader, server, tokens) = try signedIn([Self.pinned: Self.answer(Captures.pinnedToTheirAuthor)])
        let stretch = try #require(try await reader.pinned(of: Captures.writerID, source: Self.source))
        #expect(stretch.posts.map(\.statusID) == [Captures.pinnedIDs[0]] && stretch.next == Captures.pinnedIDs[0])
        #expect(stretch.posts.allSatisfy { $0.favourited == false && $0.boosted == false && $0.bookmarked == false })
        #expect(await server.bearers == ["Bearer tok-123"])
        #expect(await server.hosts == [Captures.host])
        #expect(try tokens.token(host: Captures.host) != nil)
    }

    // MARK: - None, and no such thing

    @Test("Somebody who pinned nothing is a stretch with nothing in it and no next — not an error, and not a source that has no such thing")
    func nonePinned() async throws {
        let (reader, _) = unsigned([Self.pinned: .json(Captures.nonePinned)])
        let stretch = try await reader.pinned(of: Captures.writerID, source: Self.source)
        #expect(stretch == PostStretch(posts: [], next: nil))
        #expect(stretch != nil)
    }

    @Test("A source that passes the word over answers with their ordinary newest posts, and those are never handed back as pinned: told by an address for more that does not repeat the word, or says it as a no, and by a boost, which is never pinned — nothing is handed back at all, which is a source that has no such thing and no failure")
    func ordinaryPostsAreNotPinned() async throws {
        // A Mastodon given a word it does not know: no boost among them, and no word in its addresses.
        let (unknowing, _) = unsigned([Self.pinned: Self.answer(Captures.wordPassedOver)])
        #expect(try await unknowing.pinned(of: Captures.writerID, source: Self.source) == nil)
        #expect(try await unknowing.pinned(of: Captures.writerID, source: Self.source, after: nil) == nil)

        // The other server's ordinary answer: a boost, and `pinned=false` in each address.
        let passedOver = Captures.otherWordPassedOver
        let (saysNo, _) = unsigned([Self.otherPinned: Self.answer(passedOver)], host: Captures.otherHost)
        #expect(try await saysNo.pinned(of: Captures.otherID, source: Self.other) == nil)
        // Either alone tells it: the boost with no address named, and the no with no boost listed.
        let (boost, _) = unsigned([Self.otherPinned: .json(passedOver.body)], host: Captures.otherHost)
        #expect(try await boost.pinned(of: Captures.otherID, source: Self.other) == nil)
        let (no, _) = unsigned([Self.otherPinned: .json(Captures.otherPinned.body, link: passedOver.link)], host: Captures.otherHost)
        #expect(try await no.pinned(of: Captures.otherID, source: Self.other) == nil)

        // One address of two without the word is an answer to another question; the word as
        // either yes a real server took is the answer to this one.
        let base = "https://mastodon.localhost\(Self.statuses)"
        for (link, isPinned) in [
            (#"<\#(base)?max_id=7&pinned=true>; rel="next", <\#(base)?min_id=9>; rel="prev""#, false),
            (#"<\#(base)?min_id=9&pinned=0>; rel="prev""#, false),
            (#"<\#(base)?min_id=9&pinned>; rel="prev""#, false),
            (#"<\#(base)?min_id=9&pinned=1>; rel="prev""#, true),
            (#"<\#(base)?min_id=9&pinned=TRUE>; rel="prev""#, true),
        ] {
            let (reader, _) = unsigned([Self.pinned: .json(Captures.pinned.body, link: link)])
            #expect((try await reader.pinned(of: Captures.writerID, source: Self.source) != nil) == isPinned, "\(link)")
        }
    }

    @Test("Another server's pinned posts are read though each says the reader did not pin it and no address is named: nothing on a post is read for whether it is pinned — and so a source that passes the word over, names no address and lists no boost cannot be told, and is believed")
    func noPostsOwnWordIsRead() async throws {
        let (reader, _) = unsigned([Self.otherPinned: Self.answer(Captures.otherPinned)], host: Captures.otherHost)
        let stretch = try #require(try await reader.pinned(of: Captures.otherID, source: Self.other))
        #expect(stretch.posts.map(\.statusID) == ["01M4SMY2QYQRN9YFG42KPN5K1C", "01M4SMY2Q30H6CXRBCAGQ42734"] && stretch.next == nil)
        #expect(Captures.otherPinned.body.contains(#""pinned": false"#) && !Captures.otherPinned.body.contains(#""pinned": true"#))

        let (untold, _) = unsigned([Self.pinned: .json(Captures.wordPassedOver.body)])
        #expect(try await untold.pinned(of: Captures.writerID, source: Self.source)?.posts.count == 3, "the limit of what a source lets be told")
    }

    // MARK: - Read on

    @Test("Where the source names a next it is followed by its id alone, with the word sent again and no length; a Mastodon cut short repeats what it gave, and whoever holds them lists each once, in the order they first came, to the stretch that names no next")
    func readOnByTheSourcesNext() async throws {
        let cut = Captures.pinnedByLength
        let (reader, server) = unsigned([
            Self.pinned: Self.answer(cut[0]),
            "\(Self.pinned)&max_id=\(Captures.pinnedIDs[1])": Self.answer(cut[1]),
            "\(Self.pinned)&max_id=\(Captures.pinnedIDs[2])": Self.answer(cut[2]),
        ])
        var read = PostsRead()
        var counts: [Int] = []
        var next: String?
        repeat {
            let stretch = try #require(try await reader.pinned(of: Captures.writerID, source: Self.source, after: next))
            counts.append(stretch.posts.count)
            read = try read.readingOn(stretch)
            next = read.next
        } while next != nil
        #expect(counts == [2, 2, 1] && read.ended && read.posts.map(\.statusID) == Captures.pinnedIDs)
        #expect(await server.asked == [
            Self.pinned, "\(Self.pinned)&max_id=\(Captures.pinnedIDs[1])", "\(Self.pinned)&max_id=\(Captures.pinnedIDs[2])",
        ], "the address in the header never followed as sent")
        #expect(await server.hosts == [Captures.host])
    }

    @Test("Reading on is held to the rules their posts are: only the id is taken from the way on, a way on that is the place asked from or names none fails the stretch, and a place to go on from that could not stand in a query is never asked")
    func theWayOn() async throws {
        let base = "https://mastodon.localhost\(Self.statuses)"
        let astray = #"<https://evil.example/x?max_id=\#(Captures.pinnedIDs[1])&pinned=true&token=1>; rel="next""#
        let (reader, server, _) = try signedIn([
            Self.pinned: .json(Captures.pinnedByLength[0].body, link: astray),
            "\(Self.pinned)&max_id=\(Captures.pinnedIDs[1])": Self.answer(Captures.pinnedByLength[0]),
            "\(Self.pinned)&max_id=7": .json(Captures.pinned.body, link: #"<\#(base)?page=2&pinned=true>; rel="next""#),
        ])
        #expect(try await reader.pinned(of: Captures.writerID, source: Self.source)?.next == Captures.pinnedIDs[1])
        await #expect(throws: PagingError.notPaging) {
            _ = try await reader.pinned(of: Captures.writerID, source: Self.source, after: Captures.pinnedIDs[1])
        }
        await #expect(throws: PersonReadError.unreadable) { _ = try await reader.pinned(of: Captures.writerID, source: Self.source, after: "7") }
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await reader.pinned(of: Captures.writerID, source: Self.source, after: "abc&limit=80")
        }
        #expect(await server.hosts == [Captures.host])
        #expect(await server.asked.count == 3)
    }

    // MARK: - Refused, failed, and what is never asked

    @Test("A source that refuses or fails says so as it does for their posts and changes nothing: somebody it has not heard of is that, a refusal — the one a server that reads nothing unsigned gives — is a refusal, a body that is no list is unreadable, a post this build cannot read is that one post not listed, and the sign-in is held")
    func refusedOrFailed() async throws {
        let missing = MastodonPeopleCaptures.missing
        let (unknown, _) = unsigned([Self.pinned: .json(missing, status: 404)])
        await #expect(throws: PersonReadError.unheardOf) { _ = try await unknown.pinned(of: Captures.writerID, source: Self.source) }

        let (refused, _, tokens) = try signedIn([Self.pinned: .json("{}", status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.pinned(of: Captures.writerID, source: Self.source) }
        #expect(try tokens.token(host: Captures.host) != nil)

        let unsupplied = #"{"error":"Unauthorized: token not supplied"}"#
        let (kept, _) = unsigned([Self.otherPinned: .json(unsupplied, status: 401)], host: Captures.otherHost)
        await #expect(throws: MastodonRequestError.http(401)) { _ = try await kept.pinned(of: Captures.otherID, source: Self.other) }

        let (dark, _) = unsigned([Self.pinned: .fail])
        await #expect(throws: URLError.self) { _ = try await dark.pinned(of: Captures.writerID, source: Self.source) }
        let (odd, _) = unsigned([Self.pinned: .json(missing)])
        await #expect(throws: PersonReadError.unreadable) { _ = try await odd.pinned(of: Captures.writerID, source: Self.source) }

        let whole = try #require(try JSONSerialization.jsonObject(with: Data(Captures.pinned.body.utf8)) as? [Any])
        let mixed = try JSONSerialization.data(withJSONObject: [whole[0], ["id": "no words"], 7, whole[2]])
        let (some, _) = unsigned([Self.pinned: .json(String(decoding: mixed, as: UTF8.self), link: Captures.pinned.link)])
        let stretch = try await some.pinned(of: Captures.writerID, source: Self.source)
        #expect(stretch?.posts.map(\.statusID) == [Captures.pinnedIDs[0], Captures.pinnedIDs[2]])
    }

    @Test("Nothing is asked by an id that is none, or of another source than the one this reads")
    func nothingAskedByWhatIsNoID() async throws {
        let (reader, server, _) = try signedIn([:])
        for id in ["", "1/../2", "1?x", "1&pinned=false", String(repeating: "7", count: ListSubscription.idLength + 1)] {
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.pinned(of: id, source: Self.source) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await reader.pinned(of: "1", source: Self.other) }
        #expect(await server.asked.isEmpty)
    }

    @Test("What each address of a header says for a word is read whatever the address is marked as: the word's value, nothing where the address does not say it, and no entry where there is no address")
    func whatAnAddressSays() {
        #expect(MastodonLink.said("pinned", in: nil).isEmpty && MastodonLink.said("pinned", in: "").isEmpty)
        #expect(MastodonLink.said("pinned", in: Captures.pinned.link) == ["true"])
        #expect(MastodonLink.said("pinned", in: Captures.pinnedByLength[0].link) == ["true", "true"])
        #expect(MastodonLink.said("pinned", in: Captures.wordPassedOver.link) == [nil, nil])
        #expect(MastodonLink.said("pinned", in: Captures.otherWordPassedOver.link) == ["false", "false"])
        #expect(MastodonLink.said("pinned", in: #"<https://a.example/x?unpinned=true>; rel="prev", <not closed"#) == [nil])
    }
}
