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
@Suite("The foot of a thread asks only when reached, hosted", .serialized)
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
        RunLoop.main.run(until: Date())
    }

    private static func settle(_ view: NSView) async {
        for _ in 0..<3 {
            pump(view)
            await Task.yield()
        }
    }

    @Test("A stop turning the foot to held asks nothing, and the foot still knows it is in view")
    func aStopDoesNotAskAgain() async {
        let foot = Foot()
        let view = NSHostingView(rootView: Harness(foot: foot))
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        await Self.settle(view)
        #expect(foot.reaches == [true], "coming into view is the one automatic ask")

        foot.said = .coming
        await Self.settle(view)
        foot.said = .held
        await Self.settle(view)
        #expect(foot.reaches == [true], "held after a stop is not the foot coming into view")
        #expect(foot.asks == 0)

        // Pressed, it reads on; a page that lands under it while it is in view asks for the next.
        foot.said = .coming
        await Self.settle(view)
        foot.said = .more
        await Self.settle(view)
        #expect(foot.reaches == [true, false], "still in view, so a landed page reads on")
    }
}
#endif
