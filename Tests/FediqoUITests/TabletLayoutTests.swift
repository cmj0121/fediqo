import Foundation
import Testing
@testable import FediqoUI

/// #111 — an iPad reads as its own size, in both orientations and beside another app.
///
/// The widths are the ones the system hands an app on each iPad this app runs on, in points,
/// full screen and at each size Split View and Slide Over offer. They are written down here
/// rather than read from a device, because nothing in this package can hold one; what the
/// device actually reports is named in the report as unobserved.
///
/// What a test can reach: which arrangement each of those widths gets, that turning the device
/// is the same answer as the width it lands on, and that a phone is untouched. What it cannot:
/// how either arrangement looks at those widths, a pointer and a finger on it, or VoiceOver.
@Suite("An iPad answers its own width")
struct TabletLayoutTests {
    /// Not a phone: the size class plays no part.
    private func tablet(_ width: CGFloat) -> ShellLayout {
        ShellLayout.answering(width: width, phoneIsCompact: nil)
    }

    // MARK: Both orientations

    /// Full screen, both ways up, on the smallest and the largest iPad: the rail, every time.
    @Test("Portrait and landscape, full screen, are the wide arrangement on every size of iPad")
    func bothOrientationsAreWide() {
        let screens: [(String, CGFloat, CGFloat)] = [
            ("iPad mini", 744, 1133),
            ("iPad 11-inch", 820, 1180),
            ("iPad Pro 11-inch", 834, 1194),
            ("iPad Pro 13-inch", 1032, 1376),
        ]
        for (name, portrait, landscape) in screens {
            #expect(tablet(portrait) == .wide, "\(name) portrait")
            #expect(tablet(landscape) == .wide, "\(name) landscape")
        }
    }

    /// **Turning the device is dragging a window.** The arrangement after a turn is whatever
    /// the new width answers, and nothing about having turned: the rule has no memory, so the
    /// same width reads the same way whether it was reached by rotating, by a divider, or by
    /// launching there.
    @Test("A turn lands on what the new width answers, whichever way it turned")
    func aTurnIsANewWidth() {
        // Half of an iPad mini: a phone's width upright, the rail's on its side, and back.
        #expect(tablet(368) == .narrow)
        #expect(tablet(561) == .wide)
        #expect(tablet(368) == .narrow)
        // Full screen stays wide both ways round.
        #expect(tablet(744) == .wide)
        #expect(tablet(1133) == .wide)
    }

    // MARK: Beside another app

    /// Every size beside another app, answered by what it is. Slide Over and a third of the
    /// screen are a phone's width and get the tabs; half and two thirds get the rail wherever it
    /// fits beside a page no narrower than the Mac's.
    @Test("Beside another app, each size the system offers answers its own width")
    func besideAnotherApp() {
        let sizes: [(String, CGFloat, ShellLayout)] = [
            ("Slide Over", 320, .narrow),
            ("a third, 13-inch landscape", 375, .narrow),
            ("half, mini portrait", 368, .narrow),
            ("half, mini landscape", 561, .wide),
            ("half, 11-inch landscape", 590, .wide),
            ("half, 13-inch landscape", 678, .wide),
            ("two thirds, 11-inch landscape", 790, .wide),
            ("two thirds, 13-inch landscape", 990, .wide),
        ]
        for (name, width, expected) in sizes {
            #expect(tablet(width) == expected, "\(name), \(width)pt")
        }
    }

    /// **The case the size class got wrong.** At half an 11-inch screen the system says compact,
    /// and the app drew the phone's tabs with room for the rail to spare — a stretched phone,
    /// which is what #111 exists to end. The width says wide, and the width is what is asked.
    @Test("Half an 11-inch iPad is wide, though the system calls it compact")
    func halfAnElevenInchIsWide() {
        #expect(tablet(590) == .wide)
        // What the size class would have said, for the record of why this changed.
        #expect(ShellLayout.answering(width: 590, phoneIsCompact: true) == .narrow)
    }

    // MARK: A phone, untouched

    /// The phone is its own task (#110), so it answers exactly as it did: its size class,
    /// whatever its width.
    @Test("A phone keeps its size class at every width")
    func aPhoneKeepsItsSizeClass() {
        for width in [CGFloat(320), 393, 440, 667, 852, 956] {
            #expect(ShellLayout.answering(width: width, phoneIsCompact: true) == .narrow, "\(width)")
            #expect(ShellLayout.answering(width: width, phoneIsCompact: false) == .wide, "\(width)")
        }
    }
}
