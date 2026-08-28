import XCTest

/// Reading a timeline: that there is one, and that leaving it and coming back puts the reader
/// back on the post they were on.
final class ReadingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The one test that proves the pipeline itself. Everything else here is worthless if the
    /// app does not start and draw a timeline.
    func testTheTimelineHasPostsInIt() {
        let app = DrivenApp.launched(by: self)
        XCTAssertTrue(app.postRows.firstMatch.waitForExistence(timeout: DrivenApp.patience),
                      "the timeline drew no rows")
        XCTAssertGreaterThan(app.postRows.count, 1, "a timeline of one row is not a timeline")
    }

    /// `j` twice, and the ring is on the second post rather than nowhere.
    func testTheRingFollowsTheKeys() {
        let app = DrivenApp.launched(by: self)
        app.postRows.firstMatch.waitForIt()
        XCTAssertNil(app.ringedRow, "something was ringed before anybody pressed anything")

        app.typeKey("j", modifierFlags: [])
        let first = app.ringedRow(waiting: DrivenApp.patience)?.identifier
        XCTAssertNotNil(first, "j put the ring nowhere")

        app.typeKey("j", modifierFlags: [])
        let second = app.ringedRow(waiting: DrivenApp.patience)?.identifier
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first, "the second j moved nothing")
    }

    /// The thing `swift test` cannot ask, and the reason this target exists.
    ///
    /// The ring is remembered by the feed, and the package already proves that. The *place* is
    /// the screen's, and the screen is built again from nothing every time the reader comes
    /// back to it — so whether they are looking at the post they were on is a question about a
    /// scroll, and nothing inside the package can perform one.
    func testComingBackLandsOnThePostYouWereOn() {
        let app = DrivenApp.launched(by: self)
        app.postRows.firstMatch.waitForIt()
        for _ in 0..<4 { app.typeKey("j", modifierFlags: []) }
        let left = app.ringedRow(waiting: DrivenApp.patience)?.identifier
        XCTAssertNotNil(left, "no ring to come back to")

        // Away, and round the other three pages back to this one.
        app.rotatePage()
        XCTAssertTrue(app.postRows.firstMatch.waitForNonExistence(timeout: DrivenApp.patience),
                      "the timeline is still on screen, so nothing was left")
        app.rotatePage(by: 3)
        app.postRows.firstMatch.waitForIt()

        // Two things, and the second is the one only this target can ask. The ring is on the
        // same post — which the package already knows. And the post is *on the screen*: a list
        // built afresh at its top would have this row below the fold, with the reader looking
        // at posts they had already read.
        let back = app.ringedRow(waiting: DrivenApp.patience)
        XCTAssertEqual(back?.identifier, left, "the ring moved while the reader was away")
        XCTAssertTrue(back?.waitUntilOnScreen() == true,
                      "the reader came back to a post that is not on the screen")
    }

    /// The other half of the rule, and the reason the screen watches the post rather than the
    /// key alone: with no ring there is nothing to come back to, and the list starts where
    /// every list starts rather than wherever the reader last happened to be.
    func testWithNoRingTheListComesBackToItsTop() {
        let app = DrivenApp.launched(by: self)
        app.postRows.firstMatch.waitForIt()
        let top = app.postRows.firstMatch.identifier
        for _ in 0..<4 { app.typeKey("j", modifierFlags: []) }
        XCTAssertNotNil(app.ringedRow(waiting: DrivenApp.patience))
        // `g` lets the ring go, which is what being taken to the top means here.
        app.typeKey("g", modifierFlags: [])

        app.rotatePage()
        XCTAssertTrue(app.postRows.firstMatch.waitForNonExistence(timeout: DrivenApp.patience))
        app.rotatePage(by: 3)
        app.postRows.firstMatch.waitForIt()

        XCTAssertNil(app.ringedRow, "a ring appeared while the reader was away")
        XCTAssertTrue(app.descendants(matching: .any)[top].waitUntilOnScreen(),
                      "the top of the list is not what came back")
    }
}
