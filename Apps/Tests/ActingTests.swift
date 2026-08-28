import XCTest

/// Doing something to a post, and being told what came of it.
///
/// Nothing here is signed in anywhere — the invented world has servers and posts in it and no
/// account on any of them — so every one of these presses is refused. That is the case worth
/// driving: it is the commonest one a reader meets, and until recently it was the one that
/// looked exactly like a button that does nothing.
final class ActingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Every key that acts on a post, and the same answer from each: there is nobody to act as,
    /// and the app says so instead of putting the mark quietly back.
    func testAKeyThatCannotActSaysWhy() {
        for key in ["l", "b", "d"] {
            let app = DrivenApp.launched(by: self)
            app.postRows.firstMatch.waitForIt()
            app.typeKey("j", modifierFlags: [])
            XCTAssertNotNil(app.ringedRow(waiting: DrivenApp.patience),
                            "\(key) had no post under the ring to act on")

            app.typeKey(key, modifierFlags: [])
            let notice = app.notice.waitForIt()
            // Not an English sentence: the app speaks the reader's language and this must pass
            // in every one of them. What every translation of it carries is the host it is
            // about, and `Fixture` builds a world where every host ends in `.example`.
            XCTAssertTrue(notice.label.contains(".example"),
                          "\(key) said \"\(notice.label)\", which names no server")
            app.terminate()
        }
    }

    /// Keeping a post is this device's own business: no server is asked and none can refuse, so
    /// there is nothing to report and nothing is reported.
    func testKeepingAPostTellsNobodyAndSaysNothing() {
        let app = DrivenApp.launched(by: self)
        app.postRows.firstMatch.waitForIt()
        app.typeKey("j", modifierFlags: [])
        app.typeKey("a", modifierFlags: [])
        XCTAssertFalse(app.notice.waitForExistence(timeout: 2),
                       "keeping a post complained about something: \(app.notice.label)")
    }

    /// A press with no post under the ring is silent rather than a beep, and it is silent here
    /// too: nothing is acted on and nothing is said about it.
    func testAKeyWithNoRingDoesNothingAtAll() {
        let app = DrivenApp.launched(by: self)
        app.postRows.firstMatch.waitForIt()
        XCTAssertNil(app.ringedRow)
        app.typeKey("l", modifierFlags: [])
        XCTAssertFalse(app.notice.waitForExistence(timeout: 2),
                       "a press with nothing under the ring still said something")
    }
}
