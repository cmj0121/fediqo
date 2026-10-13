import Foundation
import Testing
@testable import FediqoCore

/// #310, #313, in the half of it Core holds: how the reader stands to somebody, following them
/// and stopping — read from what a real 4.6.6 answered (`MastodonStandingCaptures`, and the
/// seven standings of `MastodonPeopleCaptures.standing`).
@Suite("How the reader stands to somebody at a Mastodon, and following them")
struct MastodonStandingTests {
    private typealias Captures = MastodonStandingCaptures

    private static let origin = "https://\(Captures.host)"
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let stands = "GET /api/v1/accounts/relationships?id%5B%5D="

    private func signedIn(_ routes: [String: TagServer.Answer]) throws -> (MastodonStanding, TagServer) {
        let server = TagServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonStanding(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("How the reader stands to somebody is what a real server said: asked once, by their id alone, on the host the sign-in is of, as the person — asked and not yet followed, and muted until a moment")
    func howTheReaderStands() async throws {
        let (stands, server) = try signedIn([
            Self.stands + Captures.far: .json(Captures.farAsked),
            Self.stands + Captures.muted: .json(Captures.mutedForATime),
        ])
        #expect(try await stands.standing(to: Captures.far) == PersonStanding(accountID: Captures.far, requested: true))
        #expect(await server.asked == [.init(
            method: "GET", address: "\(Self.origin)/api/v1/accounts/relationships?id%5B%5D=\(Captures.far)", bearer: "Bearer tok-123"
        )])
        let muted = try #require(try await stands.standing(to: Captures.muted))
        #expect(muted.muting)
        #expect(muted.mutedUntil == ISO8601DateFormatter().date(from: "2026-10-13T01:37:16Z"))
    }

    @Test("Each of the seven standings a real server gave at once is read as it said it — blocking, muting for good, blocked by them, asked — and whoever it left out, a suspended account and an id nobody has, has none")
    func theSevenASeverGave() throws {
        let body = Data(MastodonPeopleCaptures.standing.utf8)
        let ids = try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(ids.count == 7)
        let read = try ids.map { try #require(try MastodonStanding.standing(to: $0, in: body)) }
        #expect(read.map(\.accountID) == ids)
        #expect(read.filter(\.blocking).count == 1 && read.filter(\.blockedBy).count == 1)
        #expect(read.filter(\.muting).count == 1 && read.filter(\.requested).count == 1)
        #expect(read.allSatisfy { !$0.following && !$0.followedBy && $0.mutedUntil == nil })
        #expect(try MastodonStanding.standing(to: "1999999999", in: body) == nil)
        #expect(try MastodonStanding.standing(to: "117417151802177425", in: Data("[]".utf8)) == nil)
    }

    @Test("A stretch of people is asked about in one ask, naming each once by their id as the wire carries it, on the sign-in's host, as the person; each is read by the id their entry carries, whatever the order; whoever the server left out, whoever was not asked about and an entry that cannot be read have no standing; naming nobody asks nothing, an id that is no segment is named in no ask, and more than one ask names is refused before anything is asked")
    func aStretchInOneAsk() async throws {
        let body = MastodonPeopleCaptures.standing
        let ids = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]).compactMap { $0["id"] as? String }
        // Asked in another order than answered, with one named twice, an id nobody has, and one no segment.
        let named = Array(ids.reversed()) + [ids[0], "1999999999", "1/follow"]
        let query = (Array(ids.reversed()) + ["1999999999"]).map { "id%5B%5D=\($0)" }.joined(separator: "&")
        let (stands, server) = try signedIn(["GET /api/v1/accounts/relationships?\(query)": .json(body)])
        let said = try await stands.standings(to: named)
        #expect(await server.asked == [.init(
            method: "GET", address: "\(Self.origin)/api/v1/accounts/relationships?\(query)", bearer: "Bearer tok-123"
        )])
        #expect(Set(said.keys) == Set(ids) && said.allSatisfy { $0.key == $0.value.accountID })
        for id in ids { #expect(said[id] == (try MastodonStanding.standing(to: id, in: Data(body.utf8)))) }

        let whole = Captures.unfollowed, other = Captures.asked
        let read = try MastodonStanding.standings(
            to: [Captures.followable, "1999999999"],
            in: Data("[7,\(whole.replacingOccurrences(of: #""following":false,"#, with: "")),\(other)]".utf8)
        )
        #expect(read.isEmpty, "an entry that leaves a part out, one that is no entry, and one about somebody not asked")
        #expect(try MastodonStanding.standings(to: [Captures.followable], in: Data("[7,\(whole)]".utf8)) == [
            Captures.followable: PersonStanding(accountID: Captures.followable),
        ])
        for silent in ["", "null", "{}", "<html>", whole] {
            #expect(throws: MastodonStandingError.unreadable, "\(silent.prefix(40))") {
                _ = try MastodonStanding.standings(to: [Captures.followable], in: Data(silent.utf8))
            }
        }

        let (nobody, unasked) = try signedIn([:])
        #expect(try await nobody.standings(to: []).isEmpty)
        #expect(try await nobody.standings(to: ["", "1/follow", "../1"]).isEmpty)
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await nobody.standings(to: (0 ... MastodonStanding.most).map { "\($0)" })
        }
        #expect(await unasked.asked.isEmpty && MastodonStanding.most == 80)
    }

    @Test("An answer that does not say how the reader stands is not one to go by, and is never read as not followed: a body that is no list, an entry of theirs that leaves a part out or says it in another shape, an entry that cannot be read beside none of theirs")
    func anAnswerThatDoesNotSay() {
        let id = Captures.followable
        let whole = Captures.unfollowed
        let silent = [
            "", "null", "{}", "<html>", whole, "[\(whole)]x",
            "[\(whole.replacingOccurrences(of: #""following":false,"#, with: ""))]",
            "[\(whole.replacingOccurrences(of: #""blocked_by":false"#, with: #""blocked_by":"no""#))]",
            "[\(whole.replacingOccurrences(of: #""requested":false"#, with: #""requested":null"#))]",
            // Made up: an entry that is no standing at all may have been theirs.
            #"[7]"#, #"[{"following":true}]"#,
        ]
        for body in silent {
            #expect(throws: MastodonStandingError.unreadable, "\(body.prefix(60))") {
                _ = try MastodonStanding.standing(to: id, in: Data(body.utf8))
            }
        }
        // A moment spelled some other way is no end named, and the standing is read all the same.
        let odd = "[\(Captures.mutedForATime.dropFirst().dropLast().replacingOccurrences(of: "2026-10-13T01:37:16Z", with: "soon"))]"
        #expect(throws: Never.self) {
            let read = try MastodonStanding.standing(to: Captures.muted, in: Data(odd.utf8))
            #expect(read?.muting == true && read?.mutedUntil == nil)
        }
    }

    @Test("Following and unfollowing are one post each to the account's own address, as the person, and hand back what the server said: followed, asked where they must agree, unfollowed, a request withdrawn")
    func followingAndUnfollowing() async throws {
        let (stands, server) = try signedIn([
            "POST /api/v1/accounts/\(Captures.followable)/follow": .json(Captures.followed),
            "POST /api/v1/accounts/\(Captures.followable)/unfollow": .json(Captures.unfollowed),
            "POST /api/v1/accounts/\(Captures.locked)/follow": .json(Captures.asked),
            "POST /api/v1/accounts/\(Captures.locked)/unfollow": .json(Captures.withdrawn),
        ])
        #expect(try await stands.follow(Captures.followable) == PersonStanding(accountID: Captures.followable, following: true, showsBoosts: true, notifies: false))
        #expect(try await stands.follow(Captures.followable, false) == PersonStanding(accountID: Captures.followable))
        #expect(try await stands.follow(Captures.locked) == PersonStanding(accountID: Captures.locked, requested: true))
        #expect(try await stands.follow(Captures.locked, false) == PersonStanding(accountID: Captures.locked))
        #expect(await server.lines == [
            "POST \(Self.origin)/api/v1/accounts/\(Captures.followable)/follow",
            "POST \(Self.origin)/api/v1/accounts/\(Captures.followable)/unfollow",
            "POST \(Self.origin)/api/v1/accounts/\(Captures.locked)/follow",
            "POST \(Self.origin)/api/v1/accounts/\(Captures.locked)/unfollow",
        ])
        #expect(await server.asked.allSatisfy { $0.bearer == "Bearer tok-123" })
    }

    /// A sender that keeps what each ask carried, and answers every one the same.
    private actor Carried: HTTPSender {
        private(set) var asked: [(line: String, body: String, bearer: String?)] = []
        let answer: String

        init(_ answer: String) { self.answer = answer }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            asked.append((
                "\(request.httpMethod ?? "GET") \(url.path)", String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                request.value(forHTTPHeaderField: "Authorization")
            ))
            return (Data(answer.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    @Test("What is taken from somebody followed is a follow said again with the word that changed, and with no other: one post to the account's own address as the person, carrying `reblogs` or `notify` or both as handed in; with neither it is refused before anything is asked, since that would be a bare follow; the answer is read whole, the two things with it")
    func narrowing() async throws {
        let id = Captures.narrowedID
        let server = Carried(Captures.narrowed)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        let stands = MastodonStanding(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens))
        let said = PersonStanding(accountID: id, following: true, showsBoosts: false, notifies: true)
        #expect(try await stands.narrow(id, boosts: false) == said)
        #expect(try await stands.narrow(id, notify: true) == said)
        #expect(try await stands.narrow(id, boosts: true, notify: false) == said, "what the source answered, and never what was sent")
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.narrow(id) }
        let asked = await server.asked
        #expect(asked.map(\.line) == Array(repeating: "POST /api/v1/accounts/\(id)/follow", count: 3))
        #expect(asked.map(\.body) == ["reblogs=false", "notify=true", "reblogs=true&notify=false"], "no bare follow is sent by it")
        #expect(asked.allSatisfy { $0.bearer == "Bearer tok-123" })
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.narrow("1/follow", boosts: true) }
        await #expect(throws: MastodonStandingError.unreadable) { _ = try await stands.narrow(Captures.followable, boosts: true) }
        #expect(await server.asked.count == 4, "an id that is no segment is asked of nobody")
    }

    @Test("What is taken from them is said of a follow and of nothing else: read where the reader follows them, nothing where they do not or have only asked, and nothing where a source leaves the two out — which is still a standing")
    func whatIsTakenIsSaidOfAFollow() throws {
        func read(_ body: String, _ id: String) throws -> PersonStanding? { try MastodonStanding.standing(to: id, in: Data("[\(body)]".utf8)) }
        let followed = try #require(try read(Captures.followed, Captures.followable))
        #expect(followed.following && followed.showsBoosts == true && followed.notifies == false)
        let narrowed = try #require(try read(Captures.narrowed, Captures.narrowedID))
        #expect(narrowed.showsBoosts == false && narrowed.notifies == true)
        let unfollowed = try #require(try read(Captures.unfollowed, Captures.followable))
        #expect(!unfollowed.following && unfollowed.showsBoosts == nil && unfollowed.notifies == nil)
        // Asked and not agreed: the request carries `showing_reblogs: true`, and nothing is taken yet.
        let asked = try #require(try read(Captures.asked, Captures.locked))
        #expect(asked.requested && asked.showsBoosts == nil && asked.notifies == nil)
        let silent = #"{"id":"9","following":true,"followed_by":false,"requested":false,"muting":false,"blocking":false,"blocked_by":false}"#
        #expect(try read(silent, "9") == PersonStanding(accountID: "9", following: true), "a standing, with neither said")
    }

    @Test("A refusal is thrown as the door threw it and nothing is made of it; an answer about somebody else, or one that is no standing, is not an answer")
    func refusedAndUnreadable() async throws {
        let follow = "POST /api/v1/accounts/\(Captures.followable)/follow"
        let (refused, _) = try signedIn([follow: .json(Captures.notAllowed, status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.follow(Captures.followable) }
        let (gone, _) = try signedIn([follow: .json(Captures.notFound, status: 404)])
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await gone.follow(Captures.followable) }
        for body in [Captures.asked, "{}", "[]", #"{"id":"\#(Captures.followable)","following":true}"#] {
            let (other, _) = try signedIn([follow: .json(body)])
            await #expect(throws: MastodonStandingError.unreadable, "\(body.prefix(40))") { _ = try await other.follow(Captures.followable) }
        }
    }

    @Test("An id that would be more than one segment of an address is asked of nobody", arguments: ["", "1/follow", "../1", "1?x=1", "1#x", "a b"])
    func anIDThatIsNoSegment(id: String) async throws {
        let (stands, server) = try signedIn([:])
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.standing(to: id) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.follow(id) }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.follow(id, false) }
        #expect(await server.asked.isEmpty)
    }
}
