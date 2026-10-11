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

    private func object(_ body: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    @Test("The host's own list holds every word of every part, the ones a sign-in asks today first among them and in today's order; a registration for all of them is echoed whole, so nothing of it is written down as less than was asked")
    func everyPartIsKnownAndEchoed() throws {
        let everything = MastodonOAuth.scopes(writing: true, notices: true)
        #expect(Captures.everyPart.hasPrefix("\(everything) "), "a registration for every part can carry every page of today")
        let every: [String] = Captures.everyPart.split(separator: " ").map(String.init)
        #expect(every.count == 24)
        #expect(Set(every).count == every.count)

        let listed = try #require(try object(Captures.wordList)["scopes_supported"] as? [String])
        #expect(listed.count == 47)
        #expect(Set(listed).isSuperset(of: every))

        let echoed = try #require(try object(Captures.widestRegistration)["scopes"] as? [String])
        #expect(echoed == every)
        #expect(MastodonOAuth.granted(echoed.joined(separator: " "), of: Captures.everyPart) == Captures.everyPart)
    }

    @Test("Beside its list the host names where to authorise, trade, revoke and register, and each is the path on the host this app's own sign-in already goes to")
    func theHostNamesNoOtherAddress() throws {
        let said = try object(Captures.wordList)
        let signer = MastodonOAuth(host: "mastodon.localhost", sender: Unsent())
        let page = try #require(signer.authorizeURL(clientID: "c", challenge: "x", state: "s"))
        let authorises: String? = said["authorization_endpoint"] as? String
        #expect(authorises == "https://mastodon.localhost\(page.path)")
        for (name, path) in Captures.namedPaths {
            let named: String? = said[name] as? String
            #expect(named == "https://mastodon.localhost\(path)", "\(name)")
        }
    }

    /// Nothing here is sent.
    private struct Unsent: HTTPSender {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    @Test("The source's own account of a token names its words as a list, and the person by a number of the server's own that is no account id; one made for the whole of reading and writing is said in those two words, neither of which is a word this app asks for")
    func theSourcesOwnAccountOfAToken() throws {
        let said = try object(Captures.wholeInfo)
        #expect(Set(said.keys) == Captures.infoNames)
        let words = try #require(said["scope"] as? [String])
        let person: Int? = said["resource_owner_id"] as? Int
        #expect(words == ["read", "write"])
        #expect(person == 1)
        let asked = Set(Captures.everyPart.split(separator: " ").map(String.init))
        #expect(asked.isDisjoint(with: words))
        // And the narrow one's, asked a day before: the words as a list, in the order asked.
        let narrow: [String]? = try object(Captures.narrowInfo)["scope"] as? [String]
        #expect(narrow == Captures.narrow.split(separator: " ").map(String.init))
    }
}
