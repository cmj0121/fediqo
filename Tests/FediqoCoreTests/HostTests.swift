import Foundation
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

    @Test("An address this device will fetch is https with a host to reach")
    func fetchableNeedsSchemeAndHost() {
        #expect(Host.fetchableURL("https://first.example/a.jpg")
            == URL(string: "https://first.example/a.jpg"))
        #expect(Host.fetchableURL("HTTPS://first.example/a.jpg")
            == URL(string: "HTTPS://first.example/a.jpg"))
        #expect(Host.fetchableURL("https://[::1]/a.jpg") == URL(string: "https://[::1]/a.jpg"))

        // Not our scheme.
        #expect(Host.fetchableURL("http://first.example/a.jpg") == nil)
        #expect(Host.fetchableURL("file:///etc/passwd") == nil)
        #expect(Host.fetchableURL("data:image/png;base64,AAAA") == nil)
        #expect(Host.fetchableURL("javascript:alert(1)") == nil)
        #expect(Host.fetchableURL("//first.example/a.jpg") == nil)

        // Our scheme, but no host to reach. `URLSession` could only fail these, and a kept one
        // is an attachment that is not empty: it fills a slot and starts a fetch that can
        // never finish.
        #expect(Host.fetchableURL("https:") == nil)
        #expect(Host.fetchableURL("https://") == nil)
        #expect(Host.fetchableURL("https:///path") == nil)
        #expect(Host.fetchableURL("https:/host/x") == nil)
        #expect(Host.fetchableURL("https://:8443/x") == nil)

        #expect(Host.fetchableURL(nil) == nil)
        #expect(Host.fetchableURL("") == nil)
        #expect(Host.fetchableURL("not a url at all") == nil)
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
        #expect(ProtocolKind.discourse.displayName == "Discourse")
        #expect(ProtocolKind.unknown.displayName == "unknown protocol")

        // Over `allCases` rather than against a number. A count is a reminder to come back here,
        // which is exactly what a new case does not get; this says the property that actually
        // matters — every kind this app can name has a name, and no two of them share one, so a
        // case added by copy-and-paste is caught rather than counted.
        let names = ProtocolKind.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    // A template is free to delete the generator tag and plenty of administrators do, so a
    // detector resting on it alone reports a running forum as an unknown protocol — the sentence
    // that sends a reader to check a spelling that is fine, and that closes the sign-in door,
    // which is only ever offered on a refusal.
    @Test("Discuz! is recognised by its own addresses when the meta tag has been stripped")
    func discuzWithoutItsMetaTag() {
        let stripped = """
        <html><head><title>\u{4e00}\u{500b}\u{8ad6}\u{58c7}</title></head>
        <body><a href="forum.php?mod=forumdisplay&fid=2">\u{7248}\u{9762}</a></body></html>
        """
        #expect(HTMLKind.classify(stripped) == .named(.discuz))

        let footerOnly = "<html><body><div id=\"ft\">Powered by Discuz! X3.4</div></body></html>"
        #expect(HTMLKind.classify(footerOnly) == .named(.discuz))

        let thread = "<html><body><a href=\"forum.php?mod=viewthread&tid=9\">x</a></body></html>"
        #expect(HTMLKind.classify(thread) == .named(.discuz))
    }

    @Test("A page that names other software is still taken at its word")
    func theSecondLookNeverOverrules() {
        // The second look runs last, so a host that names itself is never overruled by a link
        // that happens to look like somebody else's. A forum linking to a Discuz! is not one.
        let mastodon = """
        <html><head><meta name="generator" content="Mastodon" /></head>
        <body><a href="https://elsewhere.test/forum.php?mod=forumdisplay&fid=2">a</a></body></html>
        """
        #expect(HTMLKind.classify(mastodon) == .named(.mastodon))
    }

    @Test("A page that names nothing and serves nothing of Discuz!'s is still unknown")
    func theSecondLookIsNotAGuess() {
        #expect(HTMLKind.classify("<html><body>hello</body></html>") == .unknown)
        // "forum" on its own is not Discuz!, and neither is somebody else's forum software.
        #expect(HTMLKind.classify("<html><body><a href=\"/forum/2\">board</a></body></html>") == .unknown)
    }
}
