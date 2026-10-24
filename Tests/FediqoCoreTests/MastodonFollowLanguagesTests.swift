import Foundation
import Testing
@testable import FediqoCore

/// #378, in what Core holds: which languages of somebody followed reach Home, read with how the
/// reader stands, said again with a follow, and the languages a source knows.
@Suite("The languages of somebody followed, and the languages a source knows")
struct MastodonFollowLanguagesTests {
    private typealias Captures = MastodonStandingCaptures

    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let stands = "GET /api/v1/accounts/relationships?id%5B%5D="
    private static let follow = "POST /api/v1/accounts/\(Captures.followable)/follow"

    private func signedIn(_ routes: [String: TagServer.Answer]) throws -> (MastodonStanding, TagServer) {
        let server = TagServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonStanding(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    private static func followed(in languages: String) -> String {
        Captures.followed.replacingOccurrences(of: "\"languages\":null", with: "\"languages\":\(languages)")
    }

    @Test("What is chosen is read with how the reader stands: the codes as the source keeps them; none and an empty list are every language, one spelling; and of somebody not followed, nothing")
    func readBack() async throws {
        let (stands, _) = try signedIn([
            Self.stands + Captures.followable: .json("[" + Self.followed(in: #"["en","ja"]"#) + "]"),
            Self.stands + Captures.far: .json(Captures.farAsked.replacingOccurrences(of: "\"languages\":null", with: #""languages":["en"]"#)),
        ])
        #expect(try await stands.standing(to: Captures.followable)?.languages == ["en", "ja"])
        #expect(try await stands.standing(to: Captures.far)?.languages == nil, "only asked: nothing taken yet")
        let (every, _) = try signedIn([Self.stands + Captures.followable: .json("[" + Self.followed(in: "[]") + "]")])
        #expect(try await every.standing(to: Captures.followable)?.languages == nil)
        #expect(PersonStanding(accountID: "1", following: true, languages: []) == PersonStanding(accountID: "1", following: true))
    }

    @Test("A choice is said again with a follow, and what is kept is the source's answer; a language it will not take is refused in its own words; and nothing at all is refused before anything is asked")
    func narrowed() async throws {
        let (stands, server) = try signedIn([Self.follow: .json(Self.followed(in: #"["de"]"#))])
        let answer = try await stands.narrow(Captures.followable, languages: ["de"])
        #expect(answer.following && answer.languages == ["de"])
        #expect(await server.lines == ["POST https://\(Captures.host)/api/v1/accounts/\(Captures.followable)/follow"])
        let (refusing, _) = try signedIn([Self.follow: .json(#"{"error":"Validation failed: Languages is invalid"}"#, status: 422)])
        await #expect(throws: AccountPartError.refused(sentence: "Validation failed: Languages is invalid")) {
            _ = try await refusing.narrow(Captures.followable, languages: ["zz"])
        }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.narrow(Captures.followable) }
    }

    @Test("The languages a source knows are its codes and names in its order; an entry with no code is none, and a body that is no list is unreadable")
    func whatASourceKnows() async throws {
        let path = "GET /api/v1/instance/languages"
        let (stands, _) = try signedIn([path: .json(#"[{"code":"aa","name":"Afar"},{"code":"","name":"x"},{"name":"y"},{"code":"en","name":"English"}]"#)])
        #expect(try await stands.languages() == [FollowLanguage(code: "aa", name: "Afar"), FollowLanguage(code: "en", name: "English")])
        let (odd, _) = try signedIn([path: .json(#"{"error":"no"}"#)])
        await #expect(throws: MastodonStandingError.unreadable) { _ = try await odd.languages() }
    }
}
