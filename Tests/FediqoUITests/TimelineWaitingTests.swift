import Foundation
import Testing
@testable import FediqoUI

/// #65 — a timeline that is still arriving shows rows where its rows will be.
///
/// What is assertable without a screen is the standing the pane decides from, the height a
/// waiting place takes from `DummyItemRow`'s fittings, and that VoiceOver is owed one sentence
/// for the group rather than one per plate. The suite is `@MainActor` for the reason
/// `WaitingTests` is: everything it reads belongs to a `View`.
@Suite("A timeline still arriving")
@MainActor
struct TimelineWaitingTests {

    /// Empty and on the wire is arriving: a blank page would read as empty, which is a
    /// different fact.
    @Test("Empty and running is arriving")
    func emptyAndRunningIsArriving() {
        #expect(TimelinePane.standing(
            running: true, hasItems: false, searching: false, hasSources: true
        ) == .arriving)
    }

    /// What is already held is read at once. A skeleton on top of real posts would hide them
    /// and then jump when it left.
    @Test("Held items and running draws the items, not skeletons")
    func heldItemsAreNotSkeletons() {
        #expect(TimelinePane.standing(
            running: true, hasItems: true, searching: false, hasSources: true
        ) == .held)
    }

    /// Nothing on the wire and nothing in the list is empty, not a wait that never ends.
    @Test("Empty and not running is not arriving")
    func emptyAndNotRunningIsEmpty() {
        #expect(TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true
        ) == .empty)
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
    }

    /// One waiting place, one sentence. The plates in a row are silent, and so is the header
    /// plate while the stream is arriving — that sentence is already the group's.
    @Test("VoiceOver is owed the waiting sentence once, not once per plate")
    func voiceOverSpeaksOnce() {
        #expect(TimelineWaiting.plateSpeaks == false)
        #expect(ShellWaiting.voice(speaks: TimelineWaiting.plateSpeaks) == nil)
        #expect(TimelineWaiting.spoken == ShellWaiting.spoken)
        #expect(TimelineWaiting.spoken == L10n.t("shell.waiting"))
        #expect(TimelinePane.headerWaitingSpeaks(standing: .arriving) == false)
        #expect(ShellWaiting.voice(speaks: TimelinePane.headerWaitingSpeaks(standing: .arriving)) == nil)
        #expect(TimelinePane.headerWaitingSpeaks(standing: .held))
        #expect(TimelinePane.headerWaitingSpeaks(standing: .empty))
    }

    /// The place is DummyItemRow's height, wide and compact: the same fittings, and compact
    /// drops the thumb column the way the row does. `rowHeight` is what the view frames to —
    /// a sum that is not that function would leave this green while the list jumped.
    @Test("A waiting row's height is DummyItemRow's fittings")
    func waitingRowHeightIsTheRows() {
        let wide = TimelineWaiting.rowHeight(narrow: false)
        #expect(wide == DummyItemRow.Box.avatar
            + DummyItemRow.Box.thumb
            + TimelineWaiting.marks
            + ShellSpace.snug * 2
            + ShellSpace.step * 2)
        #expect(TimelineWaiting.wordsHeight(narrow: false) == DummyItemRow.Box.thumb)

        let compact = TimelineWaiting.rowHeight(narrow: true)
        #expect(compact == DummyItemRow.Box.avatar
            + TimelineWaiting.compactWords
            + TimelineWaiting.marks
            + ShellSpace.snug * 2
            + ShellSpace.step * 2)
        #expect(TimelineWaiting.compactWords
            == ShellSpace.snug * 3 + ShellSpace.tight * 2)
        #expect(TimelineWaiting.wordsHeight(narrow: true) == TimelineWaiting.compactWords)
        #expect(TimelineWaiting.wordsHeight(narrow: true) != DummyItemRow.Box.thumb)
        #expect(compact == wide - DummyItemRow.Box.thumb + TimelineWaiting.compactWords)
        #expect(compact < wide)

        #expect(TimelineWaiting.places > 0)
        #expect(TimelineWaiting.places < 40)
    }

    /// Reduce Motion is the shell's clock, not a second one. A waiting row that kept its own
    /// tick would keep moving after the rest of the app had stopped.
    @Test("Reduce Motion still uses ShellWaiting's clock")
    func reduceMotionUsesTheShellClock() {
        #expect(TimelineWaiting.clock(reduceMotion: true)
            == ShellWaiting.clock(reduceMotion: true))
        #expect(TimelineWaiting.clock(reduceMotion: false)
            == ShellWaiting.clock(reduceMotion: false))
        #expect(TimelineWaiting.clock(reduceMotion: true) == nil)
    }
}
