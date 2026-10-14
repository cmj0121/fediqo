#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
@testable import FediqoUI

/// #177 — the foot of a thread asks by itself only as it comes into view, or as a page lands under
/// it while it is in view, **never as it changes what it says**: asked of the real view, hosted
/// off-screen, because what decides it is SwiftUI's lifecycle and not any function of ours.
///
/// **What this reaches.** Whether a foot turning from "coming" to "held" after a stop runs an
/// appearance — which asked again, and made every Esc stop an ask the foot had just started — and
/// whether it still knows it is in view afterwards. **What it does not reach**: scrolling, how the
/// foot looks, and VoiceOver, which are for a running app.
///
/// **A guard, not a reproduction.** Hosted here, the `Group` the foot used to be did not fire an
/// appearance on the turn either — the lifecycle that did it was seen by review, not by this — so
/// what this pins is that the single container the foot is now keeps the rule, however SwiftUI
/// flattens a lazy stack's children on a running app.
///
/// Few layouts, one at a time: `FoldHostedTests`' reason.
@Suite("The foot of a thread asks only when reached, hosted", .serialized, .watched)
@MainActor
struct ThreadFootHostedTests {
    @Observable
    @MainActor
    final class Foot {
        var said: ThreadFoot.Said = .more
        var reaches: [Bool] = []
        var asks = 0
    }

    private struct Harness: View {
        let foot: Foot

        /// Where the pane puts it: the last thing in a lazy stack in a scroll view.
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    Text(verbatim: "the last reply")
                    ThreadFoot(
                        said: foot.said,
                        ask: { foot.asks += 1 },
                        reach: { appeared in foot.reaches.append(appeared) }
                    )
                }
            }
        }
    }

    /// A layout and one turn of the run loop that does not wait — a synchronous hop, since the run
    /// loop may not be turned from an async context.
    private static func pump(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    /// How many looks in a row must find the foot as the look before left it.
    private static let looks = 20

    /// Turns the run loop until what the foot was told is the same for `looks` looks in a row.
    /// No `by:`: the run loop is turned here, by the check. Counted looks, because what a hosted
    /// view does when its words change is nothing a check can name — so where a check then says
    /// the foot was told something, it has waited for that first, by name.
    private static func settle(_ view: NSView, _ foot: Foot) async {
        var last: [Bool]?
        var asks = 0
        var same = 0
        await met("the foot is drawn, and \(looks) turns more tell it nothing") {
            pump(view)
            same = foot.reaches == last && foot.asks == asks ? same + 1 : 0
            last = foot.reaches
            asks = foot.asks
            return same >= looks
        }
    }

    @Test("A stop turning the foot to held asks nothing, and the foot still knows it is in view")
    func aStopDoesNotAskAgain() async {
        let foot = Foot()
        let view = NSHostingView(rootView: Harness(foot: foot))
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        await met("the foot has come into view") {
            Self.pump(view)
            return !foot.reaches.isEmpty
        }
        await Self.settle(view, foot)
        #expect(foot.reaches == [true], "coming into view is the one automatic ask")

        foot.said = .coming
        await Self.settle(view, foot)
        foot.said = .held
        await Self.settle(view, foot)
        #expect(foot.reaches == [true], "held after a stop is not the foot coming into view")
        #expect(foot.asks == 0)

        // Pressed, it reads on; a page that lands under it while it is in view asks for the next.
        foot.said = .coming
        await Self.settle(view, foot)
        foot.said = .more
        await met("the foot says a page landed under it") {
            Self.pump(view)
            return foot.reaches.count > 1
        }
        await Self.settle(view, foot)
        #expect(foot.reaches == [true, false], "still in view, so a landed page reads on")
    }
}
#endif
