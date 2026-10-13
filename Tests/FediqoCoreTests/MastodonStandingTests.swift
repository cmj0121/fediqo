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
        #expect(try await stands.follow(Captures.followable) == PersonStanding(accountID: Captures.followable, following: true))
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
