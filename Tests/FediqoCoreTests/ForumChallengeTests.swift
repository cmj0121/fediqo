import Foundation
import Testing

@testable import FediqoCore

/// A challenge must come back as a challenge, and a forum must not.
///
/// Both halves matter and the second is the one that is easy to lose. A detector tuned only on
/// challenge pages passes every test it has and then reads a forum thread *about* Cloudflare as a
/// wall — which is a reader shown a sign-in sheet for a page they were already allowed to see,
/// forever, with nothing in any log to say why.
@Suite("A wall in front of a forum")
struct ForumChallengeTests {
    /// The real thing: `https://www.challenge.example/forum.php`, captured with this app's own agent.
    private var live: String { String(data: Fixtures.html("cloudflare-challenge"), encoding: .utf8)! }

    @Test("The live challenge page from the reader's own forum is read as a wall")
    func liveChallengeIsAWall() {
        let page = ForumWallReader.read(html: live, status: 403, mitigated: "challenge")
        #expect(page == .wall(ForumWall(sort: .challenge, status: 403)), "the reader's forum read as content")
    }

    @Test("The same page is read as a wall from its body alone, with no header to help")
    func liveChallengeFromBodyAlone() {
        // A filter that does not send `cf-mitigated` must not be a filter this app walks into.
        let page = ForumWallReader.read(html: live)
        guard case .wall(let wall) = page else {
            Issue.record("the body markers did not carry it on their own")
            return
        }
        #expect(wall.sort == .challenge)
        #expect(wall.status == nil, "a status was invented where none was given")
    }

    @Test("The header is believed even when the body says nothing")
    func headerIsAuthoritative() {
        let page = ForumWallReader.read(html: "<html><body>ok</body></html>", status: 403,
                                        mitigated: "challenge")
        #expect(page == .wall(ForumWall(sort: .challenge, status: 403)))
    }

    @Test("Each mitigation Cloudflare names becomes its own sort")
    func everyKnownMitigation() {
        let cases: [(String, ForumWall.Sort)] = [
            ("challenge", .challenge),
            ("block", .blocked),
            ("rateLimit", .rateLimited),
            ("rate_limit", .rateLimited),
            // Case and whitespace are a header's business, not a meaning.
            ("  CHALLENGE ", .challenge),
        ]
        for (header, expected) in cases {
            let page = ForumWallReader.read(html: "<html/>", mitigated: header)
            #expect(page == .wall(ForumWall(sort: expected, status: nil)),
                    "\(header) was not read as \(expected)")
        }
    }

    @Test("A mitigation this build has never heard of is not guessed at")
    func unknownMitigationIsNotAWall() {
        // Reading an unknown token as a challenge would send the reader to a web view with
        // nothing in it to pass, every time, for as long as the token existed.
        let page = ForumWallReader.read(html: "<html><body>the forum</body></html>",
                                        status: 200, mitigated: "somethingNew")
        #expect(page == .content("<html><body>the forum</body></html>"))
    }

    @Test("Every structural marker carries a page on its own")
    func eachStructuralMarker() {
        for marker in ForumWallReader.structural {
            let page = ForumWallReader.read(html: "<html><script>\(marker)</script></html>")
            guard case .wall(let wall) = page else {
                Issue.record("\(marker) did not carry a page")
                return
            }
            #expect(wall.sort == .challenge)
        }
    }

    /// The reason the phrase list is not the primary evidence.
    @Test("A forum thread about Cloudflare is still a forum")
    func prosePhrasesAreNotEnough() {
        let thread = """
        <html><head><title>walled</title></head><body>
        <h1>Why does it say Just a moment</h1>
        <p>Enable JavaScript and cookies to continue is what Cloudflare shows. Checking your
        browser is the old wording. Ours says cType: 'managed'.</p>
        </body></html>
        """
        #expect(ForumWallReader.read(html: thread) == .content(thread),
                "a thread about the problem was read as the problem")
    }

    @Test("A phrase counts once Cloudflare's own widget host is on the page with it")
    func phrasePlusWidgetHost() {
        let html = """
        <html><body><div>Just a moment</div>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>
        </body></html>
        """
        guard case .wall(let wall) = ForumWallReader.read(html: html) else {
            Issue.record("the pairing did not carry it")
            return
        }
        #expect(wall.sort == .challenge)
    }

    @Test("A 403 a forum sent about one of its own boards is the forum talking")
    func forumOwn403IsNotAWall() {
        // A board the reader may not read answers 403 and is not a wall. Treating status alone
        // as evidence would put a sign-in sheet in front of a permission the reader simply does
        // not have, which no amount of signing in would change.
        let refused = "<html><body><h1>You do not have permission to read this board.</h1></body></html>"
        #expect(ForumWallReader.read(html: refused, status: 403) == .content(refused))
    }

    @Test("429 is a wall on its own, because it has something true to tell the reader")
    func rateLimitedWithoutMarkers() {
        #expect(ForumWallReader.read(html: "slow down", status: 429)
            == .wall(ForumWall(sort: .rateLimited, status: 429)))
    }

    @Test("Cloudflare's own block codes are told apart from a challenge")
    func blockedCodes() {
        for code in ForumWallReader.blockedCodes {
            guard case .wall(let wall) = ForumWallReader.read(html: "<html>\(code)</html>") else {
                Issue.record("\(code) was not read as a wall")
                return
            }
            #expect(wall.sort == .blocked, "\(code) was read as something to pass")
        }
    }

    @Test("An ordinary forum page comes back untouched")
    func contentIsHandedBackWhole() {
        let html = String(data: Fixtures.html("discourse"), encoding: .utf8)!
        #expect(ForumWallReader.read(html: html, status: 200) == .content(html))
    }

    /// Decision 9's rule reaches this module's new boundary too.
    @Test("The public host rules forward to the one definition")
    func hostRulesAreTheSameRules() {
        #expect(Host.allowsFetch(URL(string: "https://bbs.example.org/forum.php")!))
        #expect(!Host.allowsFetch(URL(string: "http://bbs.example.org/forum.php")!))
        #expect(!Host.allowsFetch(URL(string: "file:///etc/passwd")!))
        #expect(!Host.allowsFetch(URL(string: "https:///nohost")!))
        #expect(Host.https(host: "bbs.example.org", path: "/member.php",
                           query: [URLQueryItem(name: "mod", value: "logging")])?.absoluteString
            == "https://bbs.example.org/member.php?mod=logging")
    }
}
