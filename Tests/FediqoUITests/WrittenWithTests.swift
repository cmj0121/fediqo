import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// What a post was written with, and where that is (#102).
///
/// The row's own drawing is not asserted here. What is asserted is the two facts underneath it:
/// that a website is only ever the server's, and that the words for saying where the link goes
/// exist in both languages — a label a screen reader is given that came back as its own key
/// would be the one thing a reader who cannot see the underline has instead of it.
@Suite("What a post was written with")
struct WrittenWithTests {
    /// **A link nobody sent is a link this app invented** (S5). The name is kept and the site is
    /// not guessed from it — not from the name, not from a host that looks like one.
    @Test("A client with no website has none, and none is made up for it")
    func nowebsiteIsNoWebsite() {
        let named = Application(name: "Some Client")
        #expect(named.website == nil)
        #expect(named.name == "Some Client")
    }

    @Test("A client with a website keeps the one it was sent")
    func awebsiteIsKept() throws {
        let site = try #require(URL(string: "https://fediqo.example/about"))
        #expect(Application(name: "Fediqo", website: site).website == site)
    }

    /// The words for where it goes, in both languages. The underline is what a reader sees; this
    /// is what somebody who cannot see it is told instead, and it names the host rather than the
    /// client — the name of a client is not the name of a host.
    @Test("Where it goes is said in both languages")
    func whereItGoesIsSaid() {
        let url = URL(string: "https://fediqo.example/about")
        #expect(url?.host() == "fediqo.example")
        #expect(TemplateWordsTests.written("post.writtenWith.opens"))
        #expect(TemplateWordsTests.written("post.writtenWith"))
    }
}
