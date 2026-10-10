import Foundation
import Testing
@testable import FediqoCore

/// What this app makes today of the answers a real 4.6.6 gave through its own sign-in pages
/// (`MastodonSignInCaptures`) — read by the readers a sign-in already goes through, with
/// nothing new built for them.
@Suite("What a Mastodon's own sign-in pages answered, as this app reads it")
struct MastodonSignInSaidTests {
    private typealias Captures = MastodonSignInCaptures

    private struct Issued: Decodable {
        let scope: String
    }

    private func scope(_ body: String) throws -> String {
        try JSONDecoder().decode(Issued.self, from: Data(body.utf8)).scope
    }

    @Test("What a page was granted is written down from the token's own word: a page asking for less than its registration as what it asked, word for word and in the order asked, a wider one of the same registration as what it asked — and neither as holding a word the other was granted")
    func whatAPageWasGranted() throws {
        #expect(MastodonOAuth.granted(try scope(Captures.narrowToken), of: Captures.narrow) == Captures.narrow)
        #expect(MastodonOAuth.granted(try scope(Captures.wideToken), of: Captures.wide) == Captures.wide)
        #expect(MastodonOAuth.granted(try scope(Captures.wideToken), of: Captures.narrow) == Captures.narrow, "never more than was asked")
        #expect(MastodonOAuth.granted(try scope(Captures.narrowToken), of: Captures.wide) == Captures.narrow, "and never more than was given")
        #expect(MastodonOAuth.reading == Captures.narrow, "the narrow sign-in is this app's reading one")
    }

    @Test("The page approved sends a code back with the state it was sent, and the page refused sends a refusal with it — which is a sign-in declined, and is nobody's answer under any other state")
    func whereThePageSendsThePerson() throws {
        let approved = try #require(URL(string: Captures.approvedCallback))
        #expect(try MastodonOAuth.code(from: approved, state: "s1") == "<code>")

        let refused = try #require(URL(string: Captures.refusedCallback))
        #expect(throws: MastodonSignInError.denied) { _ = try MastodonOAuth.code(from: refused, state: "s5") }
        #expect(throws: MastodonSignInError.stateMismatch) { _ = try MastodonOAuth.code(from: refused, state: "s1") }
    }
}
