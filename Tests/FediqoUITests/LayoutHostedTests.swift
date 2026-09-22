#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FediqoUI

/// #110, one step closer to a window than a pure function: `ShellArranged` hosted off-screen in
/// an `NSHostingView`, its frame moved a step at a time the way a window's edge moves it.
///
/// **What this reaches, and what it does not.** It runs the measurement, the rule and the redraw
/// the root runs, with nothing standing in for any of them, so "the arrangement answers each new
/// width as it arrives, and at the same width both ways" is asserted of the real mechanism. It
/// does not reach a window a hand is resizing: no window is made, nothing is shown, and AppKit's
/// live resize — the path a real drag takes — is not the path a moved frame takes. That part is
/// named in the report as unobserved rather than claimed here.
@Suite("The width decides the arrangement, hosted")
@MainActor
struct LayoutHostedTests {
    /// What the content was last built with. A class, so the view writes and the test reads.
    private final class Seen {
        var layout: ShellLayout?
        var environment: ShellLayout?
    }

    /// Reads the environment the way a row does, so the value handed down is asserted too.
    private struct Reader: View {
        let layout: ShellLayout
        let seen: Seen
        @Environment(\.shellLayout) private var environment

        var body: some View {
            seen.layout = layout
            seen.environment = environment
            return Color.clear
        }
    }

    private func host(_ seen: Seen, width: CGFloat) -> NSHostingView<some View> {
        let view = NSHostingView(rootView: ShellArranged { layout in Reader(layout: layout, seen: seen) })
        view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        settle(view)
        return view
    }

    /// One step of the edge: the new frame, the layout it causes, the redraw the measurement
    /// asks for, and the layout after that.
    private func settle(_ view: NSView) {
        for _ in 0 ..< 3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func resize(_ view: NSView, to width: CGFloat) {
        view.frame.size.width = width
        settle(view)
    }

    @Test("Each width is answered as it arrives, and the content and the rows are told the same")
    func eachWidthIsAnsweredAsItArrives() {
        let seen = Seen()
        let view = host(seen, width: 900)
        #expect(seen.layout == .wide)
        #expect(seen.environment == .wide)

        resize(view, to: ShellLayout.breakpoint - 1)
        #expect(seen.layout == .narrow)
        #expect(seen.environment == .narrow)

        resize(view, to: ShellLayout.breakpoint)
        #expect(seen.layout == .wide)
        #expect(seen.environment == .wide)
    }

    /// **The floor is the narrow arrangement's, whatever is inside.** The rail's arrangement used
    /// to carry the window's minimum, 520 points, so the width that swaps the arrangement could
    /// never be reached by dragging. Asked for its size at no width at all — the question a
    /// window's minimum asks — the shell answers the floor even over content that wants more.
    @Test("Asked how narrow it can be, the shell answers the floor, not what its content wants")
    func theFloorIsTheShellsNotTheContents() {
        let greedy = NSHostingController(rootView: ShellArranged { _ in
            Color.clear.frame(minWidth: 800)
        })
        let least = greedy.sizeThatFits(in: CGSize(width: 0, height: 0))
        #expect(least.width == ShellLayout.floor)
    }

    /// A drag, both ways, a point at a time across the line: every width reads the same whichever
    /// way it was arrived at.
    @Test("A drag narrow and back swaps at the same width both ways")
    func aDragSwapsAtTheSameWidthBothWays() {
        let seen = Seen()
        let line = ShellLayout.breakpoint
        let steps = Array(stride(from: line + 6, through: line - 6, by: -1))
        let view = host(seen, width: steps[0])

        var shrinking: [CGFloat: ShellLayout] = [:]
        for width in steps {
            resize(view, to: width)
            shrinking[width] = seen.layout
        }
        var growing: [CGFloat: ShellLayout] = [:]
        for width in steps.reversed() {
            resize(view, to: width)
            growing[width] = seen.layout
        }
        #expect(shrinking == growing)
        for width in steps {
            #expect(shrinking[width] == ShellLayout.answering(width: width), "\(width)")
        }
    }
}
#endif
