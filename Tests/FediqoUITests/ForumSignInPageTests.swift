#if os(macOS)
import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// The forum's own sign-in page, driven the way a reader drives it — #153.
@MainActor
@Suite("A sign-in on the forum's own page", .serialized)
struct ForumSignInPageTests {
    static let signedIn = #"""
    <p>Welcome back</p><a href="member.php?mod=logging&amp;action=logout&amp;formhash=ab12cd34">Log out</a>
    """#

    static let login = #"""
    <html><body>
    <form id="loginform_Ab1Cd" method="post"
          action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=Ab1Cd"
          onsubmit="document.body.innerHTML = window.landed; return false;">
      <input type="hidden" name="formhash" value="ab12cd34">
      <input type="text" name="username" value="">
      <input type="password" name="password" value="">
      <input type="checkbox" name="cookietime" value="2592000">
      <button type="submit" name="loginsubmit" value="true">Log in</button>
    </form>
    </body></html>
    """#

    /// Loads `html` as though `bbs.example` had served it, and waits for it to settle.
    static func load(_ html: String, in engine: ForumWebEngine) async throws {
        engine.view.loadHTMLString(html, baseURL: URL(string: "https://bbs.example/member.php"))
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(10))
            if !engine.view.isLoading,
               (try? await engine.view.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return
            }
        }
        Issue.record("the page never settled")
    }

    /// What the reader does: types into the two fields and presses the forum's button. The page's
    /// own handler moves it on to the signed-in page, as Discuz! does after its answer arrives.
    static func typeAndPress(in engine: ForumWebEngine) async throws {
        _ = try await engine.view.callAsyncJavaScript(
            """
            window.landed = landed;
            document.querySelector('input[name="username"]').value = 'reader';
            document.querySelector('input[name="password"]').value = 'p@ss"word';
            document.querySelector('button[type="submit"]').click();
            """,
            arguments: ["landed": signedIn], contentWorld: .page
        )
    }

    /// **The cause, shown.** What the old keep did — read the form at the moment Done is
    /// pressed — finds nothing, because the page has moved on by the time the sign-in can be
    /// confirmed. Kept as a test so the reason the watcher exists cannot be argued away.
    @Test("Read when Done is pressed, the form has already gone")
    func theFormIsGoneByDone() async throws {
        let engine = ForumWebEngine(host: "bbs.example", dataStore: .nonPersistent())
        try await Self.load(Self.login, in: engine)
        try await Self.typeAndPress(in: engine)
        #expect(await engine.isSignedIn(), "the premise: the page shows a signed-in member")
        #expect(await engine.typedCredential() == nil)
    }

    @Test("With the switch on, what was submitted is held across the page moving on, and kept")
    func typedSurvivesTheRedirect() async throws {
        let credentials = MemoryCredentials()
        let forums = ForumSessions(credentials: credentials)
        let engine = forums.engine(host: "bbs.example")
        try await Self.load(Self.login, in: engine)
        // The reader turns the switch on with the form already in front of them.
        forums.watchTyped(host: "bbs.example", on: true)
        try await Self.typeAndPress(in: engine)
        #expect(await spun { forums.holdsTyped(host: "bbs.example") }, "nothing was handed over")
        #expect(await engine.isSignedIn())

        #expect(await forums.saveTyped(host: "bbs.example") == .kept)
        #expect(try credentials.credential(host: "bbs.example")
                == ForumCredential(host: "bbs.example", username: "reader", password: "p@ss\"word"))
    }

    /// D23: before the switch, nothing in this app reads the field.
    @Test("With the switch off, nothing typed is handed to this app")
    func nothingIsReadWithTheSwitchOff() async throws {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let engine = forums.engine(host: "bbs.example")
        forums.watchTyped(host: "bbs.example", on: true)
        forums.watchTyped(host: "bbs.example", on: false)
        try await Self.load(Self.login, in: engine)
        try await Self.typeAndPress(in: engine)
        #expect(await engine.isSignedIn())
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!forums.holdsTyped(host: "bbs.example"), "the field was read with the switch off")
    }

    /// #153's first cause, on a page: the reader's own sign-in asks the forum to remember it.
    @Test("The forum's own remember-me is ticked on its login page")
    func rememberIsTicked() async throws {
        let engine = ForumWebEngine(host: "bbs.example", dataStore: .nonPersistent())
        try await Self.load(Self.login, in: engine)
        let checked = try await engine.view.evaluateJavaScript(
            "document.querySelector('input[name=\"cookietime\"]').checked"
        ) as? Bool
        #expect(checked == true)
    }
}
#endif
