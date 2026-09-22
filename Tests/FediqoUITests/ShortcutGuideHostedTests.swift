#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FediqoUI

/// #152, measured: the written-down keys fit their plate at the standard type size, so no tab
/// scrolls where the window leaves the plate its full width.
///
/// **What this reaches, and what it does not.** The plate is laid out off-screen by SwiftUI's own
/// layout, the one a window runs, and asked what size it takes for a proposal — no window is
/// made and nothing is shown. It measures the letters this Mac draws with; a different machine's
/// system font may land a point or two either way, which is why the budget is asserted and not a
/// height. It does not see a phone, VoiceOver, or dark mode.
///
/// Kept to two tests and serialized: the hosted suites share the main actor with every
/// other suite, and one that settles many layouts starves them.
@Suite("The keys guide fits its plate, hosted", .serialized)
@MainActor
struct ShortcutGuideHostedTests {
    /// The size a view takes when offered `width` and all the height it could want.
    private func size(of view: some View, offered width: CGFloat) -> CGSize {
        let host = NSHostingController(rootView: view.dynamicTypeSize(.large))
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    /// Every tab at once: the plate lays every tab out and keeps the tallest one's height, so the
    /// plate's own height is the tallest tab's plus the heading. Then each tab alone, so a tab that
    /// grows past the budget is named.
    @Test("At full width every tab fits the plate's height without scrolling")
    func everyTabFitsThePlate() {
        let plate = ShortcutGuide.Metrics.plate
        let whole = size(
            of: ShortcutGuide.Plate(tab: .constant(.move), onClose: {}),
            offered: plate.width + 2 * ShellSpace.room
        )
        #expect(whole.width == plate.width)
        #expect(whole.height <= plate.height, "the plate is \(whole.height) tall")

        let inner = plate.width - 2 * ShellSpace.pad
        let pages = DummyShortcutGroup.allCases.map { group in
            (group, size(of: ShortcutGuide.Page(group: group), offered: inner).height)
        }
        let tallest = pages.map(\.1).max() ?? 0
        // What is above the page: the title, the note, the pills, and the plate's own padding.
        let heading = whole.height - tallest
        #expect(heading > 0)
        for (group, height) in pages {
            #expect(heading + height <= plate.height, "\(group) is \(height) under \(heading)")
        }
    }

    /// At the floor the plate gives up width rather than its edges.
    ///
    /// **Not quite all the room, and older than #152.** A line's caps do not wrap, and the
    /// text beside them wraps only between words, so a tab is never narrower than its widest
    /// caps plus its longest word. On this Mac that is Read's `Return` `Space` beside
    /// "attachment": 14 points more than the floor leaves, so there the plate takes 7 points of
    /// the room on each side. Those lines sat together on the old Timeline tab too, which was
    /// at least as wide. Asserted as a bound so it cannot grow unnoticed.
    @Test("At the floor the plate narrows, and keeps its edges inside the window")
    func thePlateNarrowsAtTheFloor() {
        let offered = ShellLayout.floor - 2 * ShellSpace.room
        let narrow = size(of: ShortcutGuide.Plate(tab: .constant(.read), onClose: {}), offered: offered)
        #expect(narrow.width < ShortcutGuide.Metrics.plate.width)
        #expect(narrow.width <= ShellLayout.floor - ShellSpace.room, "the plate is \(narrow.width) wide")
    }
}
#endif
