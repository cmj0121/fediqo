import Foundation
import Testing

@testable import FediqoCore

/// A challenge must come back as a challenge, and a forum must not.
///
/// Both halves matter and the second is the one that is easy to lose. A detector tuned only on
/// challenge pages passes every test it has and then reads a forum thread *about* Cloudflare as a
/// wall — which is a reader shown a sign-in sheet for a page they were already allowed to see,
/// forever, with nothing in any log to say why.
///
/// **Where the challenge markup below comes from.** It used to be a capture of a live managed
/// challenge, taken with this app's own agent. That page carried a session token, a ray id, a
/// nonce and the name of the zone it was protecting, so it is gone and none of it is reproduced
/// here. What is written out instead carries **only the markers the reader looks for and no
/// values at all** — the arrangement is kept (the two structural markers a managed challenge
/// actually emits, the widget host named in the content-security-policy meta rather than in a
/// script src, the noscript sentence, the `Just a moment` title) but the page is no longer
/// evidence of what Cloudflare serves today.
@Suite("A wall in front of a forum")
struct ForumChallengeTests {
    /// A managed challenge with every token, ray id, nonce and zone name taken out.
    private var challengePage: String {
        #"""
        <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <meta name="robots" content="noindex,nofollow">
        <meta http-equiv="content-security-policy" content="default-src 'none'; script-src 'unsafe-eval' https://challenges.cloudflare.com; img-src 'self' https://challenges.cloudflare.com; frame-src 'self' https://challenges.cloudflare.com blob:; worker-src blob:; base-uri 'self'">
        <meta http-equiv="refresh" content="360"></head>
        <body><div class="main-wrapper" role="main"><div class="main-content"><noscript><div class="h2">
        <span id="challenge-error-text">Enable JavaScript and cookies to continue</span>
        </div></noscript></div></div>
        <script>(function(){window._cf_chl_opt = {cType: 'managed'};
        var a = document.createElement('script');
        a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1';
        document.getElementsByTagName('head')[0].appendChild(a);}());</script>
        </body></html>
        """#
    }

    @Test("A managed challenge page is read as a wall")
    func challengePageIsAWall() {
        let page = ForumWallReader.read(html: challengePage, status: 403, mitigated: "challenge")
        #expect(page == .wall(ForumWall(sort: .challenge, status: 403)), "a challenge read as content")
    }

    @Test("The same page is read as a wall from its body alone, with no header to help")
    func challengeFromBodyAlone() {
        // A filter that does not send `cf-mitigated` must not be a filter this app walks into.
        let page = ForumWallReader.read(html: challengePage)
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
        <html><head><title>A forum</title></head><body>
        <h1>Why does it say Just a moment</h1>
        <p>Enable JavaScript and cookies to continue is what Cloudflare shows. Checking your
        browser is the old wording. Ours says cType: 'managed'.</p>
        </body></html>
        """
        #expect(ForumWallReader.read(html: thread) == .content(thread),
                "a thread about the problem was read as the problem")
    }

    @Test("Every phrase counts once Cloudflare's own widget host is on the page with it")
    func everyPhrasePlusWidgetHost() {
        // Enumerated for the same reason the structural markers are: the list is the promise,
        // and a phrase quietly dropped from it is a wall this app walks into and reports as an
        // empty forum. Each phrase is tried alone with the widget host beside it, which is the
        // pairing that makes a phrase evidence rather than a coincidence.
        for phrase in ForumWallReader.phrases {
            let html = """
            <html><body><div>\(phrase)</div>
            <script src="https://\(ForumWallReader.widgetHost)/turnstile/v0/api.js"></script>
            </body></html>
            """
            guard case .wall(let wall) = ForumWallReader.read(html: html) else {
                Issue.record("\(phrase) did not carry a page beside the widget host")
                continue
            }
            #expect(wall.sort == .challenge, "\(phrase) was read as something other than a check")
        }
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
        // A forum's own front page, carrying none of the markers — and, deliberately, carrying
        // the word Cloudflare nowhere at all, so that what this pins is the ordinary case.
        let html = #"""
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>A forum</title>
            <meta name="generator" content="Discourse 2026.9.0-latest">
          </head>
          <body class="crawler">
            <div id="main-outlet"><h1>Latest topics</h1>
              <a href="/t/give-retry-after-a-documented-default/41207">Give retry_after a documented default</a>
            </div>
          </body>
        </html>
        """#
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
