import XCTest

/// The app, launched and driven from outside itself.
///
/// Everything the package tests is tested with the app not running: `swift test` reaches Core
/// and the models above it and stops where SwiftUI begins, because nothing in a package can
/// execute a view body. This is the other side of that line — a second process that starts the
/// real app and presses things in it.
///
/// What it reads is `Fixture`'s invented world, asked for with `FEDIQO_FIXTURE`. Three servers
/// whose names all end in `.example`, which no resolver will ever answer, so a run here asks
/// nobody's machine anything and says the same thing on a laptop as on a runner.
///
/// Nothing here asserts on an English sentence. The app follows the reader's own language and
/// no launch variable overrides it — inventing one so a test could read the screen would be a
/// door in the product that exists for the test alone. What is asserted on instead is what
/// survives translation: whether an element is there, whether the ring is on it, and whether a
/// message names the host it is about.
enum DrivenApp {
    /// A running app, on the page named, reading the invented world.
    ///
    /// The launch variables are the ones the app already understands — the screenshot workflow
    /// opens it the same way. Nothing here is a door built for testing: a test that needs its
    /// own way in is a test of something no reader can reach.
    @MainActor
    static func launched(on rail: String = "timeline") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FEDIQO_FIXTURE"] = "1"
        app.launchEnvironment["FEDIQO_ROUTE"] = "shell"
        app.launchEnvironment["FEDIQO_RAIL"] = rail
        // Nothing restored from the last run. macOS brings a window back where it was left,
        // and a suite that launches the app eight times would be asking each of those eight
        // questions of a window somebody else placed — which is a suite that passes alone and
        // fails in company, and did.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Frontmost, and not merely running. An element behind another window is an element
        // that exists, is drawn, and cannot be pressed — which is precisely the difference
        // this suite reads "is it on the screen" out of.
        //
        // Nothing is torn down, here or in a `tearDown`, and the reason is worth writing down
        // because it was tried twice. `XCTestCase`'s synchronous `tearDown` is isolated to
        // nothing, `XCUIApplication` is isolated to the main actor, and under Swift 6 the two
        // do not meet — which the compiler on this laptop is lenient about and the one on the
        // runner is not. Nothing is lost by leaving it out: `launch()` terminates an instance
        // already running before it starts one, so no test ever meets the window another left
        // behind. The last app stays up until somebody quits it, which is one window on the
        // second display.
        app.activate()
        return app
    }

    /// How long anything here waits for the app to catch up.
    ///
    /// A press is answered in a frame and a launch takes a second or two; ten is not a guess at
    /// either, it is the point past which something is wrong rather than slow. A test that
    /// fails after ten seconds fails for a reason, and one that passes never waits that long.
    static let patience: TimeInterval = 10
}

/// The waiting and the finding, all of it on the main actor.
///
/// Not a preference: `XCUIApplication` and `XCUIElement` are main-actor isolated, and under
/// Swift 6 a nonisolated test method touching either is an error rather than a warning. The
/// compiler on this laptop is lenient about it and the one on the runner is not, which is a
/// difference worth spelling out rather than discovering twice.
@MainActor
extension XCUIElement {
    /// This element, once it is actually there. Fails the test where it never arrives.
    @discardableResult
    func waitForIt(_ file: StaticString = #filePath, _ line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: DrivenApp.patience),
                      "\(self) never appeared", file: file, line: line)
        return self
    }

    /// Whether this element comes to be on the screen and pressable, waiting for it rather
    /// than asking once.
    ///
    /// Asking once is what a flaky test is made of. Existing and being on the screen are two
    /// different moments here: a screen the reader has just come back to is built, laid out and
    /// only then scrolled to where they were, and a question asked between the second and the
    /// third gets the honest answer that the post is above the top of the list. Waiting is not
    /// a workaround for that — it is the same thing a reader does, which is look at the screen
    /// a moment after arriving at it.
    func waitUntilOnScreen(timeout: TimeInterval = DrivenApp.patience) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                 object: self)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }
}

@MainActor
extension XCUIApplication {
    /// Every post row on screen, by the identifier `PostRow` puts on itself.
    var postRows: XCUIElementQuery {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post.'"))
    }

    /// The row the ring is on — the one drawn with the focus ring, which says as much to a
    /// screen reader and therefore to this.
    var ringedRow: XCUIElement? {
        let rows = postRows
        for index in 0..<rows.count where rows.element(boundBy: index).isSelected {
            return rows.element(boundBy: index)
        }
        return nil
    }

    /// The ring, waited for. A press is answered in a frame and a screen coming back is built
    /// before it is scrolled, so "which row is ringed" asked the instant after either is a
    /// question asked too early.
    func ringedRow(waiting: TimeInterval = DrivenApp.patience) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(waiting)
        while Date() < deadline {
            if let row = ringedRow { return row }
        }
        return nil
    }

    /// Back once no row is ringed, or false where one still is when the waiting is over.
    ///
    /// The other half of `ringedRow(waiting:)`, and needed for the same reason: `g` lets the
    /// ring go and the app answers a frame later, so a test that walks away the instant after
    /// pressing it walks away from a screen that has not answered yet — and comes back to find
    /// the ring it thought it had dropped.
    func waitForNoRing(_ waiting: TimeInterval = DrivenApp.patience) -> Bool {
        let deadline = Date().addingTimeInterval(waiting)
        while Date() < deadline {
            if ringedRow == nil { return true }
        }
        return false
    }

    /// The page `steps` along the rail, asked for the way a reader asks: ⌃Tab, which rotates
    /// the four and wraps.
    func rotatePage(by steps: Int = 1) {
        for _ in 0..<steps { typeKey(XCUIKeyboardKey.tab, modifierFlags: .control) }
    }

    /// Off the timeline, and back once its rows are gone.
    func leaveTheTimeline() -> Bool {
        rotatePage()
        return postRows.firstMatch.waitForNonExistence(timeout: DrivenApp.patience)
    }

    /// Round the rail until the timeline is in front of the reader again.
    ///
    /// Counted presses were what this used to be — three of them, because there are four pages
    /// — and counting is what made it fragile: a single press that the app never saw leaves the
    /// reader on Settings, and the test that follows waits ten seconds for rows that were never
    /// going to be there. Pressing until the destination arrives asks the question the test
    /// actually has, which is whether the timeline came back and not how many keys it took.
    func returnToTheTimeline(within presses: Int = 6) -> Bool {
        for _ in 0..<presses {
            rotatePage()
            if postRows.firstMatch.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// What the app is saying about the last thing it was asked to do, or nothing.
    var notice: XCUIElement {
        descendants(matching: .any)["action.notice"]
    }
}
