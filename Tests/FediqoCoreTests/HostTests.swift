import Testing
@testable import FediqoCore

@Suite("Host")
struct HostTests {
    @Test("A host or https URL is the lowercase host, path stripped")
    func parseHostAndHTTPSURL() throws {
        #expect(try Host.parse("first.example") == "first.example")
        #expect(try Host.parse("  first.example  ") == "first.example")
        #expect(try Host.parse("https://first.example/about?foo=1#bar") == "first.example")
        #expect(try Host.parse("HTTPS://first.example/") == "first.example")
        #expect(try Host.parse("https://[::1]/about") == "[::1]")
        #expect(try Host.parse("https://[2001:DB8::1]/") == "[2001:db8::1]")
        #expect(try Host.parse("[::1]") == "[::1]")
        #expect(try Host.parse("::1") == "[::1]")
    }

    @Test("http:// and @user@host are not hosts")
    func rejectHTTPAndAcct() {
        #expect(throws: HostError.invalidHost) {
            try Host.parse("http://first.example")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("@a@b")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("   ")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("first.example/about")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("ftp://first.example")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("https://")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("{")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("%")
        }
        #expect(throws: HostError.invalidHost) {
            try Host.parse("ex\u{0001}ample.com")
        }
    }

    @Test("Every kind has a human name; unknown says so")
    func displayNames() {
        #expect(ProtocolKind.mastodon.displayName == "Mastodon")
        #expect(ProtocolKind.pleroma.displayName == "Pleroma")
        #expect(ProtocolKind.akkoma.displayName == "Akkoma")
        #expect(ProtocolKind.misskey.displayName == "Misskey")
        #expect(ProtocolKind.pixelfed.displayName == "Pixelfed")
        #expect(ProtocolKind.lemmy.displayName == "Lemmy")
        #expect(ProtocolKind.peertube.displayName == "PeerTube")
        #expect(ProtocolKind.friendica.displayName == "Friendica")
        #expect(ProtocolKind.gotosocial.displayName == "GoToSocial")
        #expect(ProtocolKind.unknown.displayName == "unknown protocol")
        #expect(ProtocolKind.allCases.count == 10)
    }
}
