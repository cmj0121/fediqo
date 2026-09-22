import Foundation
import Testing
@testable import FediqoUI

/// #110 — a window dragged narrow or wide swaps layout while it is being dragged.
///
/// What a test can reach: which arrangement a width gets, that the answer has one line and no
/// memory of the direction it was crossed in, that the line and the floor are the numbers the
/// rail and the phone already stand on, and where a list rebuilt by the swap puts the reader.
/// What it cannot: that the swap happens during the drag, which is a window being resized under
/// a hand — named in the report rather than claimed here.
@Suite("The width decides the arrangement")
struct LayoutTests {
    // MARK: One line

    @Test("Below the line is narrow, and the line itself and above are wide")
    func eachSideOfTheLine() {
        let line = ShellLayout.breakpoint
        #expect(ShellLayout.answering(width: ShellLayout.floor) == .narrow)
        #expect(ShellLayout.answering(width: line - 0.5) == .narrow)
        #expect(ShellLayout.answering(width: line) == .wide)
        #expect(ShellLayout.answering(width: line + 0.5) == .wide)
        #expect(ShellLayout.answering(width: 1440) == .wide)
    }

    /// **Dragging back swaps them back, at the same width.** A drag is a run of widths, and
    /// the arrangement at each is asked for as the edge passes it. Swept narrow-to-wide and back
    /// again, every width reads the same both ways, and each sweep changes arrangement exactly
    /// once and at the line.
    @Test("A drag either way changes arrangement once, at the same width")
    func aDragEitherWaySwapsAtTheSameWidth() {
        let widths = Array(stride(from: ShellLayout.floor, through: 1400, by: 0.5))
        let growing = widths.map { ShellLayout.answering(width: $0) }
        let shrinking = widths.reversed().map { ShellLayout.answering(width: $0) }
        #expect(growing == Array(shrinking.reversed()))

        func swaps(_ sweep: [ShellLayout], over widths: [CGFloat]) -> [CGFloat] {
            zip(sweep, sweep.dropFirst()).enumerated().compactMap { index, pair in
                pair.0 == pair.1 ? nil : widths[index + 1]
            }
        }
        #expect(swaps(growing, over: widths) == [ShellLayout.breakpoint])
        #expect(swaps(shrinking, over: widths.reversed()) == [ShellLayout.breakpoint - 0.5])
    }

    /// Before the first measurement there is no width to answer, and the answer is the one every
    /// launch gave before the rule existed.
    @Test("Nothing measured yet is wide")
    func nothingMeasuredIsWide() {
        #expect(ShellLayout.answering(width: nil) == .wide)
    }

    // MARK: Where the line is

    /// **Not a new number.** The line is the floor the rail beside the page always kept: the
    /// rail open, its hairline, and the page every threshold in a source row is measured against.
    /// A rail that grows moves this test before it moves the line quietly.
    @Test("The line is the rail open, its hairline, and the page a source row is measured at")
    func theLineIsTheRailsOldFloor() {
        let page = ShellLayout.breakpoint - RailView.Metrics.expandedWidth - ShellSpace.hair
        #expect(page.rounded() == 318)
        #expect(ShellLayout.floor < ShellLayout.breakpoint)
    }

    /// The floor is the narrowest phone, and a sheet drawn over the page at that width keeps its
    /// edges: the guide gives up width, not its margins.
    @Test("The keys list fits the floor by narrowing, and is its full width where the rail is")
    func theGuideFitsEveryWidth() {
        #expect(ShortcutGuide.Metrics.plate + 2 * ShellSpace.room <= ShellLayout.breakpoint)
        #expect(ShellLayout.floor - 2 * ShellSpace.room > 0)
    }

    // MARK: Nothing lost across the swap

    /// The lamp wins, as it always did coming back from a thread: its row, in the middle.
    @Test("A list rebuilt by the swap centres the lamp where there is one")
    func theLampIsCentred() {
        #expect(TimelinePane.landing(selected: "a", top: "z") == .centred("a"))
        #expect(TimelinePane.landing(selected: "a", top: nil) == .centred("a"))
    }

    /// **The place scrolled to is still in view.** Without a lamp the list used to come back at
    /// the top, which is exactly the place scrolled to lost.
    @Test("With no lamp, a list rebuilt by the swap keeps the row that was at the top")
    func thePlaceScrolledToIsKept() {
        #expect(TimelinePane.landing(selected: nil, top: "z") == .top("z"))
        #expect(TimelinePane.landing(selected: nil, top: nil) == nil)
    }
}
