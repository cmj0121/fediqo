#if os(macOS)
import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// What the engine says about where an answer came from.
@Suite("Forum engine response")
@MainActor
struct ForumEngineResponseTests {
    // A caller reads the response's address to tell "here is your thread" from "here is the
    // sign-in page instead". A synthesised response that echoed the *requested* address would
    // make every redirect invisible to that check — and invisible only on the path that matters
    // most, since a forum read through the engine is one the reader signed in to, which is exactly
    // where a lapsed session sends them.
    @Test("A synthesised response carries where the view ended up, not where it was sent")
    func theSynthesisedResponseFollowsTheView() async {
        let engine = ForumWebEngine(host: "bbs.example", dataStore: .nonPersistent())
        let asked = URL(string: "https://bbs.example/forum.php?mod=viewthread&tid=1")!

        // Nothing loaded: there is nowhere else it could have ended up, so the request stands.
        #expect(engine.response(for: asked).url == asked)

        // And the rule the address is read by is the one that matters here.
        #expect(!DiscuzPage.isSignInPage(asked))
        #expect(DiscuzPage.isSignInPage(
            URL(string: "https://bbs.example/member.php?mod=logging&action=login")
        ))
    }
}
#endif
