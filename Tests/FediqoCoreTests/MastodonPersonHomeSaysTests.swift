import Foundation
import Testing
@testable import FediqoCore

/// #310: what Fediqo believes a server says when it is asked, with no sign-in, for somebody by
/// their name — the one ask this app makes of the server a person lives on — held against the
/// real ones this checkout brings up (`make servers`, Mastodon 4.6.6 and two forums): asked
/// plainly, and through this app's own reader, `MastodonPersonHome`.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`), and nothing here writes.
/// A run makes some fifteen requests and no registration.
///
/// **Not asked here**: a Mastodon that answers only its members. The fixture is not one; what
/// its code answers with that setting on is written down in `MastodonPersonHomeCaptures`.
@Suite("What a server says when asked, unsigned, for somebody by name", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPersonHomeSaysTests {
    private static let host = LocalServers.mastodon

    private static func seeded() throws -> LocalServers.Seeded.People {
        try #require(
            try LocalServers.seeded().people,
            "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again"
        )
    }

    /// A server asked plainly for `name`, with no sign-in.
    private func ask(_ name: String, at host: String = host) async throws -> (status: Int, response: HTTPURLResponse, body: Data) {
        let query = [URLQueryItem(name: "acct", value: name)]
        guard let url = Host.httpsURL(host: host, path: MastodonPerson.lookupPath, query: query) else { throw LocalHTTPError.invalidURL }
        let (body, response) = try await LocalHTTP.client().data(from: url)
        return (response.statusCode, response, body)
    }

    private func home(_ host: String = host) throws -> MastodonPersonHome {
        MastodonPersonHome(http: try LocalHTTP.client(), host: host)
    }

    private static func address(_ name: String, at host: String = host) throws -> PersonAddress {
        try #require(PersonAddress(typed: "@\(name)@\(host)"))
    }

    @Test("Somebody who lives there is answered to anyone, 200 and named by the name alone, and read through this app is the one asked for with no picture taken; every answer says how often the server may be asked")
    func somebodyWhoLivesThere() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let plain = try await ask(seeded.person.acct)
        let account = try #require(try JSONSerialization.jsonObject(with: plain.body) as? [String: Any])
        #expect(plain.status == 200 && account["acct"] as? String == seeded.person.acct && account["id"] as? String == seeded.person.id)
        #expect(plain.response.value(forHTTPHeaderField: "x-ratelimit-limit") == "300")
        #expect(plain.response.value(forHTTPHeaderField: "x-ratelimit-remaining") != nil)
        #expect(plain.response.value(forHTTPHeaderField: "x-ratelimit-reset") != nil)

        let person = try await home().person(try Self.address(seeded.person.acct))
        #expect(person.accountID == seeded.person.id && person.handle == "@\(seeded.person.acct)@\(Self.host)")
        #expect(person.avatarURL == nil && person.headerURL == nil && person.emojis.isEmpty)
        #expect(person.tally.followers == 8 && person.tally.following == 4)
    }

    @Test("A suspended account, a limited one and one that moved are each answered 200 with the account, saying which; read through this app each says the same")
    func whatBecameOfThem() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let reader = try home()
        let gone = try await reader.person(try Self.address(seeded.gone.acct))
        #expect(try await ask(seeded.gone.acct).status == 200 && gone.suspended)
        let limited = try await reader.person(try Self.address(seeded.limited.acct))
        #expect(try await ask(seeded.limited.acct).status == 200 && limited.limited)
        let moved = try await reader.person(try Self.address(seeded.moved.acct))
        #expect(moved.moved?.handle == "@\(seeded.person.acct)@\(Self.host)")
    }

    @Test("A name nobody has is a 404 in JSON, and read through this app the server knows nobody of that name; somebody of another server is answered under that server's name, which is never what its own person is asked by")
    func nobodyOfThatName() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let missing = try await ask("fediqo_nobody_of_this_name")
        #expect(missing.status == 404 && String(decoding: missing.body, as: UTF8.self) == MastodonPersonHomeCaptures.missing)
        await #expect(throws: PersonHomeError.nobody) {
            try await home().person(try Self.address("fediqo_nobody_of_this_name"))
        }
        let far = try await ask(seeded.far.acct)
        let account = try #require(try JSONSerialization.jsonObject(with: far.body) as? [String: Any])
        #expect(far.status == 200 && (account["acct"] as? String)?.contains("@") == true)
    }

    @Test("A server that is no Mastodon gives no account at that path: a Discourse answers its own page with a 404, and a Discuz! sends the ask back to itself — read through this app, neither is anybody")
    func noMastodon() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let page = try await ask(seeded.person.acct, at: LocalServers.discourse)
        #expect(page.status == 404 && page.response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        await #expect(throws: PersonHomeError.noAccount) {
            try await home(LocalServers.discourse).person(try Self.address(seeded.person.acct, at: LocalServers.discourse))
        }
        await #expect(throws: PersonHomeError.self) {
            try await home(LocalServers.discuz).person(try Self.address(seeded.person.acct, at: LocalServers.discuz))
        }
    }
}
