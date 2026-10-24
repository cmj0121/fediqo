import Foundation
import Testing
@testable import FediqoCore

/// #377, in what Core holds: the reader's own note on somebody, which the source keeps on how the
/// reader stands to them, and who of the people the reader follows also follow them.
@Suite("The reader's note on somebody, and who is known in common")
struct MastodonNoteTests {
    private typealias Captures = MastodonStandingCaptures

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

    private static func noted(_ words: String) -> String {
        Captures.followed.replacingOccurrences(of: "\"note\":\"\"", with: "\"note\":\"\(words)\"")
    }

    @Test("The reader's note on somebody is read with how the reader stands, in the same one ask; an empty one is none")
    func theNoteIsReadWithTheStanding() async throws {
        let (stands, server) = try signedIn([
            Self.stands + Captures.followable: .json("[" + Self.noted("Met at the conference") + "]"),
            Self.stands + Captures.far: .json(Captures.farAsked),
        ])
        let read = try await stands.standingNoted(to: Captures.followable)
        #expect(read.standing?.following == true && read.note == "Met at the conference")
        #expect(try await stands.standingNoted(to: Captures.far).note == nil, "an empty note is none")
        #expect(await server.asked.count == 2, "one ask each, the note with the standing")
        #expect(try await stands.standing(to: Captures.followable)?.following == true, "the standing alone reads as it did")
    }

    @Test("A note is written to the source as its comment, and what is kept is the source's answer; an empty one clears it")
    func aNoteIsWritten() async throws {
        let path = "POST /api/v1/accounts/\(Captures.followable)/note"
        let (stands, server) = try signedIn([path: .json(Self.noted("Owes me a book"))])
        let written = try await stands.note("Owes me a book", on: Captures.followable)
        #expect(written.note == "Owes me a book" && written.standing.following)
        #expect(await server.asked.map(\.method) == ["POST"])
        let (clearing, _) = try signedIn([path: .json(Captures.followed)])
        #expect(try await clearing.note("", on: Captures.followable).note == nil)
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.note("x", on: "1/follow") }
    }

    @Test("Who in common is read by their id, as people of the source; nobody in common is nobody, and an entry about somebody else is not theirs")
    func familiarFollowers() async throws {
        let path = "GET /api/v1/accounts/familiar_followers?id%5B%5D=" + Captures.followable
        let ada = "{\"id\":\"7\",\"username\":\"ada\",\"acct\":\"ada\",\"display_name\":\"Ada\",\"note\":\"\"}"
        let bo = "{\"id\":\"8\",\"username\":\"bo\",\"acct\":\"bo@far.example\",\"display_name\":\"Bo\",\"note\":\"\"}"
        let cy = "{\"id\":\"10\",\"username\":\"cy\",\"acct\":\"cy\",\"display_name\":\"Cy\"}"
        let body = "[{\"id\":\"\(Captures.followable)\",\"accounts\":[\(ada),\(bo)]},{\"id\":\"9\",\"accounts\":[\(cy)]}]"
        let (stands, _) = try signedIn([path: .json(body)])
        let source = Source(host: Captures.host, kind: .mastodon)
        let common = try await stands.familiarFollowers(of: Captures.followable, at: source)
        #expect(common.map(\.accountID) == ["7", "8"])
        let (nobody, _) = try signedIn([path: .json("[{\"id\":\"\(Captures.followable)\",\"accounts\":[]}]")])
        #expect(try await nobody.familiarFollowers(of: Captures.followable, at: source).isEmpty)
    }
}
