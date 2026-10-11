import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by method, path and query, with a `Link` header where it is given
/// one, and remembers each request as it went out: how, to which address as the wire spells
/// it, and as whom.
actor TagServer: HTTPSender {
    enum Answer: Sendable {
        case json(String, link: String? = nil, status: Int = 200)
        case fail
    }

    struct Asked: Equatable, Sendable {
        let method: String
        /// The whole address, percent-encoded as it was sent.
        let address: String
        let bearer: String?
    }

    private let routes: [String: Answer]
    private(set) var asked: [Asked] = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    var lines: [String] { asked.map { "\($0.method) \($0.address)" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let method = request.httpMethod ?? "GET"
        asked.append(Asked(method: method, address: url.absoluteString, bearer: request.value(forHTTPHeaderField: "Authorization")))
        switch routes["\(method) \(url.path)" + (url.query.map { "?\($0)" } ?? "")] {
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

/// #318, in the half of it Core holds: whether the reader follows a hashtag, following one and
/// stopping, and the followed ones read a stretch at a time — read from what a real 4.6.6
/// answered (`MastodonTagFollowCaptures`).
@Suite("A hashtag followed at a Mastodon, and the followed ones read on")
struct MastodonTagFollowsTests {
    private typealias Captures = MastodonTagFollowCaptures

    private static let origin = "https://\(Captures.host)"
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let check = "GET /api/v1/accounts/verify_credentials"

    private func signedIn(_ routes: [String: TagServer.Answer]) throws -> (MastodonTagFollows, TagServer, MemoryMastodonTokens) {
        let server = TagServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonTagFollows(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server, tokens)
    }

    private func tag(_ name: String) throws -> PostTag {
        try #require(PostTag("#" + name))
    }

    @Test("Whether the reader follows a hashtag is what a real server said of it: asked once, at the hashtag's own address on the host the sign-in is of, as the person — followed, and not")
    func whetherItIsFollowed() async throws {
        let (not, server, _) = try signedIn(["GET /api/v1/tags/fediqo318a": .json(Captures.notFollowed)])
        #expect(try await not.isFollowed(try tag("fediqo318a")) == false)
        #expect(await server.asked == [.init(method: "GET", address: "\(Self.origin)/api/v1/tags/fediqo318a", bearer: "Bearer tok-123")])

        let (yes, _, _) = try signedIn(["GET /api/v1/tags/fediqo318a": .json(Captures.followed)])
        #expect(try await yes.isFollowed(try tag("fediqo318a")) == true)
    }

    @Test("An answer that does not say whether the reader follows it is not one to go by, and is never read as not followed: the answer a source gives nobody, a following of another shape, a body that is no hashtag")
    func anAnswerThatDoesNotSay() throws {
        #expect(try MastodonTagFollows.followed(in: Data(Captures.followed.utf8)) == true)
        #expect(try MastodonTagFollows.followed(in: Data(Captures.notFollowed.utf8)) == false)
        // Only `following` is read: the name the source calls it is its own, and may differ.
        #expect(try MastodonTagFollows.followed(in: Data(Captures.accent.utf8)) == true)
        #expect(try MastodonTagFollows.followed(in: Data(#"{"following":true,"name":7,"history":"x"}"#.utf8)) == true)
        let silent = [
            Captures.unsigned, #"{"following":"true"}"#, #"{"following":1}"#, #"{"following":null}"#, "{}", "[]", "",
            "null", "<html>", #"[{"following":true}]"#, Captures.followed + "x",
        ]
        for body in silent {
            #expect(throws: MastodonTagFollowError.unreadable, "\(body.prefix(40))") {
                _ = try MastodonTagFollows.followed(in: Data(body.utf8))
            }
        }
    }

    @Test("Following a hashtag and stopping are each one POST with nothing in it, to the hashtag's own address and the word for the act after it, as the person; what comes back is the source's word afterwards, and asking twice is answered the same")
    func followingAndStopping() async throws {
        let (follows, server, _) = try signedIn([
            "POST /api/v1/tags/fediqo318a/follow": .json(Captures.followed),
            "POST /api/v1/tags/fediqo318a/unfollow": .json(Captures.notFollowed),
        ])
        let name = try tag("fediqo318a")
        #expect(try await follows.follow(name) == true)
        #expect(try await follows.follow(name) == true)
        #expect(try await follows.follow(name, false) == false)
        #expect(try await follows.follow(name, false) == false)
        let asked = await server.asked
        #expect(asked.map(\.method) == ["POST", "POST", "POST", "POST"])
        #expect(asked.map(\.address) == [
            "\(Self.origin)/api/v1/tags/fediqo318a/follow", "\(Self.origin)/api/v1/tags/fediqo318a/follow",
            "\(Self.origin)/api/v1/tags/fediqo318a/unfollow", "\(Self.origin)/api/v1/tags/fediqo318a/unfollow",
        ])
        #expect(asked.allSatisfy { $0.bearer == "Bearer tok-123" })
    }

    @Test("A name goes out as one segment of the path, percent-encoded where it is not ASCII and in the case it was written in, never with its mark")
    func aNameAsOneSegment() async throws {
        #expect(try MastodonTagFollows.path(of: try tag("FediQo318Case"), host: Captures.host) == "/api/v1/tags/FediQo318Case")
        #expect(try MastodonTagFollows.path(of: try tag("標籤318"), .follow, host: Captures.host) == "/api/v1/tags/標籤318/follow")
        #expect(try MastodonTagFollows.path(of: try tag("a_b"), .unfollow, host: Captures.host) == "/api/v1/tags/a_b/unfollow")

        let (follows, server, _) = try signedIn([
            "GET /api/v1/tags/標籤318": .json(Captures.chinese), "POST /api/v1/tags/café318/follow": .json(Captures.accent),
        ])
        #expect(try await follows.isFollowed(try tag("標籤318")) == true)
        #expect(try await follows.follow(try tag("café318")) == true)
        #expect(await server.lines == [
            "GET \(Self.origin)/api/v1/tags/%E6%A8%99%E7%B1%A4318", "POST \(Self.origin)/api/v1/tags/caf%C3%A9318/follow",
        ])
    }

    @Test("A name that would add a segment, climb one, end the path early or run on without end is refused before anything is asked — whatever let it be made")
    func aNameThatIsNoSegment() async throws {
        // What `PostTag` itself turns away never gets as far as a path.
        for written in ["#a/b", "#a?b", "#a#b", "#..", "#.", "#a%2Fb", "#a b", "#", "#a\\b", "#a\nb", "#a.b"] {
            #expect(PostTag(written) == nil, "\(written)")
        }
        let long = try tag(String(repeating: "f", count: MastodonTagFollows.nameLength + 1))
        let longest = try tag(String(repeating: "f", count: MastodonTagFollows.nameLength))
        #expect(throws: MastodonRequestError.invalidURL) { _ = try MastodonTagFollows.path(of: long, host: Captures.host) }
        #expect(throws: MastodonRequestError.invalidURL) { _ = try MastodonTagFollows.path(of: long, .follow, host: Captures.host) }
        #expect(try MastodonTagFollows.path(of: longest, host: Captures.host).count == 13 + MastodonTagFollows.nameLength)
        // A host that is none builds no address.
        #expect(throws: MastodonRequestError.invalidURL) { _ = try MastodonTagFollows.path(of: longest, host: "a b/c") }

        let (follows, server, _) = try signedIn([:])
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.isFollowed(long) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.follow(long) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.follow(long, false) }
        #expect(await server.asked.isEmpty)
    }

    @Test("The followed ones are read a stretch at a time by the source's own word for what is next and no other, the one followed last first, to the end — which is a stretch that names no next")
    func theFollowedOnesReadOn() async throws {
        let (follows, server, _) = try signedIn([
            "GET /api/v1/followed_tags?limit=2": .json(Captures.stretches[0].body, link: Captures.stretches[0].link),
            "GET /api/v1/followed_tags?limit=2&max_id=12": .json(Captures.stretches[1].body, link: Captures.stretches[1].link),
            "GET /api/v1/followed_tags?limit=2&max_id=10": .json(Captures.stretches[2].body, link: Captures.stretches[2].link),
        ])
        var read = FollowedTagsRead()
        #expect(read.next == nil)
        #expect(!read.ended)
        read = try read.readingOn(try await follows.followed(limit: 2))
        #expect(read.tags.map(\.name) == ["fediqo318p5", "fediqo318p4"])
        #expect(read.next == "12")
        #expect(!read.ended)
        read = try read.readingOn(try await follows.followed(after: read.next, limit: 2))
        #expect(read.next == "10")
        #expect(!read.ended)
        read = try read.readingOn(try await follows.followed(after: read.next, limit: 2))
        #expect(read.tags.map(\.name) == Captures.names)
        #expect(read.next == nil)
        #expect(read.ended)
        let asked = await server.asked
        #expect(asked.map(\.address) == [
            "\(Self.origin)/api/v1/followed_tags?limit=2", "\(Self.origin)/api/v1/followed_tags?limit=2&max_id=12",
            "\(Self.origin)/api/v1/followed_tags?limit=2&max_id=10",
        ])
        #expect(asked.map(\.method) == ["GET", "GET", "GET"])
        #expect(asked.allSatisfy { $0.bearer == "Bearer tok-123" })
    }

    @Test("A stretch is never asked for a length of none, and never by a place that could not stand in a query as an id; left alone it asks for a hundred")
    func theLengthAndThePlace() async throws {
        let (follows, server, _) = try signedIn([
            "GET /api/v1/followed_tags?limit=1": .json("[]"), "GET /api/v1/followed_tags?limit=100": .json("[]"),
        ])
        #expect(try await follows.followed(limit: 0) == FollowedTagsStretch(tags: [], next: nil))
        #expect(try await follows.followed(limit: -7).tags.isEmpty)
        #expect(try await follows.followed().tags.isEmpty)
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.followed(after: "12&limit=9") }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.followed(after: "../x") }
        #expect(await server.lines == [
            "GET \(Self.origin)/api/v1/followed_tags?limit=1", "GET \(Self.origin)/api/v1/followed_tags?limit=1",
            "GET \(Self.origin)/api/v1/followed_tags?limit=100",
        ])
    }

    @Test("A listed name is a stranger's word: entry by entry, one that is no hashtag, runs over a line, hides a mark that turns the line round or is too long is that one not listed; a hashtag given twice, however written, is listed once; and no more is read than was asked for")
    func aListedNameIsAStrangersWord() async throws {
        let long = String(repeating: "f", count: MastodonTagFollows.nameLength + 1)
        let fits = String(repeating: "g", count: MastodonTagFollows.nameLength)
        let hostile = """
        [{"name":"swift"},{"name":"Swift"},{"name":"ｓｗｉｆｔ"},{"name":"two words"},{"name":"line\\nbreak"},
         {"name":"turn\\u202Eround"},{"name":"#marked"},{"name":"a/b"},{"name":"../up"},{"name":""},{"name":7},
         {"id":"1"},"swift",null,[],{"name":"\(long)"},{"name":"\(fits)"},{"name":"標籤318"},{"name":"café318"}]
        """
        let (follows, _, _) = try signedIn(["GET /api/v1/followed_tags?limit=100": .json(hostile)])
        let listed = try await follows.followed().tags
        #expect(listed.map(\.name) == ["swift", fits, "標籤318", "café318"])
        for tag in listed {
            #expect(tag.name.unicodeScalars.count <= MastodonTagFollows.nameLength)
            #expect(tag.text.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.properties.generalCategory != .format })
        }

        let many = "[" + (1...50).map { #"{"name":"t\#($0)"}"# }.joined(separator: ",") + "]"
        let (few, _, _) = try signedIn(["GET /api/v1/followed_tags?limit=3": .json(many)])
        #expect(try await few.followed(limit: 3).tags.map(\.name) == ["t1", "t2", "t3"])
    }

    @Test("An answer that is no list is unreadable; a next that cannot be read is not the end; and a source that names again the place it was just asked by, sends the reader round, or goes on with nothing new is stopped")
    func whatIsNotAListAndWhatDoesNotPage() async throws {
        for body in ["{}", "", "null", "<html>", Captures.followed, Captures.notGiven] {
            let (follows, _, _) = try signedIn(["GET /api/v1/followed_tags?limit=100": .json(body)])
            await #expect(throws: MastodonTagFollowError.unreadable, "\(body.prefix(30))") { _ = try await follows.followed() }
        }
        let noPlace = #"<https://mastodon.localhost/api/v1/followed_tags?limit=2>; rel="next""#
        let (unreadable, _, _) = try signedIn(["GET /api/v1/followed_tags?limit=100": .json("[]", link: noPlace)])
        await #expect(throws: MastodonPeopleError.unreadable) { _ = try await unreadable.followed() }

        let same = #"<https://mastodon.localhost/api/v1/followed_tags?max_id=12>; rel="next""#
        let (ring, _, _) = try signedIn(["GET /api/v1/followed_tags?limit=100&max_id=12": .json("[]", link: same)])
        await #expect(throws: PagingError.notPaging) { _ = try await ring.followed(after: "12") }

        let swift = try tag("swift")
        var read = try FollowedTagsRead().readingOn(FollowedTagsStretch(tags: [swift], next: "9"))
        read = try read.readingOn(FollowedTagsStretch(tags: [try tag("SWIFT")], next: "8"))
        #expect(read.tags == [swift], "one hashtag, however it is written")
        #expect(throws: PagingError.notPaging) { _ = try read.readingOn(FollowedTagsStretch(tags: [], next: "9")) }
        var barren = FollowedTagsRead()
        for place in 1..<PeopleRead.barren { barren = try barren.readingOn(FollowedTagsStretch(tags: [], next: "\(place)")) }
        #expect(throws: PagingError.notPaging) { _ = try barren.readingOn(FollowedTagsStretch(tags: [], next: "x")) }
        #expect(barren.next == "\(PeopleRead.barren - 1)", "a stretch refused changes nothing")
    }

    @Test("A sign-in that was not given the word is refused, and the refusal is what the door throws — not the end of the sign-in; a name the source has no hashtag for is its not-found; with no sign-in honoured the door asks the source's own check before it says the sign-in is over; a failure is a failure of that ask")
    func refusedAndFailed() async throws {
        let name = try tag("fediqo318a")
        let (refused, server, tokens) = try signedIn([
            "POST /api/v1/tags/fediqo318a/follow": .json(Captures.notGiven, status: 403),
            "POST /api/v1/tags/fediqo318a/unfollow": .json(Captures.notGiven, status: 403),
            "GET /api/v1/followed_tags?limit=100": .json(Captures.notGiven, status: 403),
            "GET /api/v1/tags/fediqo318a": .json(Captures.notFound, status: 404),
        ])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.follow(name) }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.follow(name, false) }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.followed() }
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await refused.isFollowed(name) }
        let stillHeld = try tokens.token(host: Captures.host)
        #expect(stillHeld != nil)
        #expect(await server.asked.count == 4, "no refusal is asked about twice, and none asks the account check")

        let (over, gone, forgotten) = try signedIn([
            "POST /api/v1/tags/fediqo318a/follow": .json(Captures.noSignIn, status: 401),
            Self.check: .json(Captures.noSignIn, status: 401),
        ])
        await #expect(throws: MastodonAuthError.signedOut) { _ = try await over.follow(name) }
        let after = try forgotten.token(host: Captures.host)
        #expect(after == nil)
        #expect(await gone.asked.map(\.method) == ["POST", "GET"])

        let (down, _, kept) = try signedIn([
            "GET /api/v1/tags/fediqo318a": .fail, "POST /api/v1/tags/fediqo318a/follow": .json("oops", status: 500),
            "GET /api/v1/followed_tags?limit=100": .json("<html>", status: 500),
        ])
        await #expect(throws: URLError.self) { _ = try await down.isFollowed(name) }
        await #expect(throws: MastodonAuthError.http(500)) { _ = try await down.follow(name) }
        await #expect(throws: MastodonAuthError.http(500)) { _ = try await down.followed() }
        let held = try kept.token(host: Captures.host)
        #expect(held != nil)
    }
}
