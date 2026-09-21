import Foundation
import Testing
@testable import FediqoUI

/// #82 — a wait is the toast; the stream stays the stream.
///
/// What is assertable without a screen is the standing the pane decides from.
/// The suite is `@MainActor` for the reason `WaitingTests` is: `TimelinePane.standing`
/// belongs to a `View`.
@Suite("A wait is the toast; the stream stays the stream")
@MainActor
struct TimelineWaitingTests {

    /// Empty and on the wire is empty: waiting rows would be a wait that never ended.
    /// The wait is the toast.
    @Test("Empty and running is empty, not arriving")
    func emptyAndRunningIsEmpty() {
        #expect(TimelinePane.standing(
            running: true, hasItems: false, searching: false, hasSources: true
        ) == .empty)
        #expect(TimelinePane.standing(
            running: true, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example"]
        ) == .empty)
    }

    /// What is already held is read at once, including while a reload runs.
    @Test("Held items and running draws the items, not skeletons")
    func heldItemsAreNotSkeletons() {
        #expect(TimelinePane.standing(
            running: true, hasItems: true, searching: false, hasSources: true
        ) == .held)
    }

    /// Nothing on the wire and nothing in the list is empty, not a wait that never ends.
    @Test("Empty and not running is empty")
    func emptyAndNotRunningIsEmpty() {
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true
        ) == .empty)
    }

    /// Empty, not running, somebody was asked, and they did not answer: still empty.
    /// The miss is the toast, not a pane-sized failure.
    @Test("Empty, not running, and a source that did not answer is empty")
    func emptyAndFailedIsEmpty() {
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example"]
        ) == .empty)
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example", "two.example"]
        ) == .empty)
    }

    /// Held still wins: rows already here are read at once.
    @Test("Held items and a failed source still draw the items")
    func heldItemsAreNotAFailurePlace() {
        #expect(TimelinePane.standing(
            running: false, hasItems: true, searching: false, hasSources: true,
            failed: ["one.example"]
        ) == .held)
    }

    /// A second miss is still empty: standing reads the list it is handed, and a longer
    /// list is still one empty place. The toast names who.
    @Test("A second failed source does not make a second standing")
    func failedDoesNotStack() {
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example"]
        ) == TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example", "two.example"]
        ))
    }

    /// Search already has indexing and empty notices. Waiting rows would be a second
    /// vocabulary for a miss this device already knows is a miss.
    @Test("An empty search is not timeline waiting rows")
    func emptySearchIsNotArriving() {
        #expect(TimelinePane.standing(
            running: true, hasItems: false, searching: true, hasSources: true
        ) == .empty)
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: true, hasSources: true
        ) == .empty)
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: true, hasSources: true,
            failed: ["one.example"]
        ) == .empty)
    }

    /// Nobody to ask, so a plate standing for a row that will never come is a wait that
    /// never ends.
    @Test("No sources is empty, never waiting")
    func noSourcesIsEmptyNeverWaiting() {
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: false
        ) == .empty)
        #expect(TimelinePane.standing(
            running: true, hasItems: false, searching: false, hasSources: false
        ) == .empty)
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: false,
            failed: ["one.example"]
        ) == .empty)
    }
}
