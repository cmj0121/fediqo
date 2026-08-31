import XCTest

/// Clicking a post, which until now nothing here did.
///
/// Every other driven test presses keys, and that is a real gap rather than a stylistic one: a
/// click goes through gestures, hit testing and view layering, none of which a key touches and
/// none of which a package test can reach. A closure wired to the wrong parameter, or a press
/// swallowed by the selectable words on top of it, compiles and passes everything else.
@MainActor
final class ClickingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A click says which post the reader means, and it says it from wherever in the row they
    /// clicked.
    ///
    /// The middle of a row is its words, and the words are selectable — so the press never
    /// reaches the row behind them, and for a long time clicking what you were reading did
    /// nothing at all. What is asserted is the ring, because the ring is what every key that
    /// acts on "this post" goes on to read.
    func testClickingTheWordsOfAPostPutsTheRingOnIt() {
        let app = DrivenApp.launched()
        app.postRows.firstMatch.waitForIt()
        XCTAssertNil(app.ringedRow, "something was already ringed before anything was clicked")

        let second = app.postRows.element(boundBy: 1)
        XCTAssertTrue(second.waitUntilOnScreen(), "the second post never came on screen")
        let wanted = second.identifier
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press()

        let ringed = app.ringedRow(waiting: DrivenApp.patience)
        XCTAssertEqual(ringed?.identifier, wanted,
                       "clicking a post left the ring on \(ringed?.identifier ?? "nothing")")
    }

    /// And clicking the words does not open the post.
    ///
    /// The row opens from behind itself, so that the words stay selectable and the marks stay
    /// pressable — a click on the words is the reader saying which post they mean and nothing
    /// more. What says the page did not open is the list still being a list: a conversation
    /// here is one post, and the timeline is several.
    func testClickingTheWordsDoesNotOpenThePost() {
        let app = DrivenApp.launched()
        app.postRows.firstMatch.waitForIt()
        let before = app.postRows.count
        XCTAssertGreaterThan(before, 1, "the invented world handed over one post, so this asks nothing")

        let second = app.postRows.element(boundBy: 1)
        XCTAssertTrue(second.waitUntilOnScreen(), "the second post never came on screen")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press()
        XCTAssertNotNil(app.ringedRow(waiting: DrivenApp.patience))

        XCTAssertEqual(app.postRows.count, before,
                       "clicking the words of a post opened it instead of pointing at it")
    }
}
