import Testing
@testable import FediqoCore

@Suite("Whatever the user types becomes a bare host")
struct ServerTests {
    @Test("Scheme, path, case and trailing dots are stripped", arguments: [
        ("https://Mastodon.Social/", "mastodon.social"),
        ("HTTP://g0v.social/public", "g0v.social"),
        ("  mstdn.jp  ", "mstdn.jp"),
        ("@fosstodon.org", "fosstodon.org"),
        ("hachyderm.io.", "hachyderm.io"),
    ])
    func normalise(input: String, expected: String) {
        #expect(Server.normalise(input) == expected)
    }

    @Test("Obvious non-hosts are refused before any request is made", arguments: [
        "", "localhost", "not a host.com", "http://", ".social", "mastodon social",
    ])
    func rejects(input: String) {
        #expect(Server.looksLikeHost(input) == false)
    }

    @Test("A plausible host is accepted")
    func accepts() {
        #expect(Server.looksLikeHost("mastodon.social"))
        #expect(Server.looksLikeHost("https://g0v.social/"))
    }

    @Test("Identity is protocol plus host, so the same host twice is one server")
    func identity() {
        #expect(Server(host: "https://mastodon.social/", socialProtocol: .mastodon).id == Server(host: "MASTODON.social", socialProtocol: .mastodon).id)
    }
}
