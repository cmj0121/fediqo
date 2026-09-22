import SwiftUI

/// Which of the app's two arrangements a width gets: the rail beside the page, or the page with
/// the places as tabs (#57).
///
/// **The width on screen, and not the kind of device.** The macOS build drew the rail at every
/// width it could be dragged to and simply refused to be dragged narrower than the rail needed;
/// the phone build asked the system for a size class, which is a guess about the device handed
/// down as a fact about the space. A window dragged across the line has to read as the
/// arrangement for the width it has now, while the edge is still moving (#110), and the only
/// thing that knows that width is the view that was given it.
///
/// **One line, crossed the same way in both directions.** There is no band where the answer
/// depends on which way the reader was dragging: a window at a width reads one way whether it
/// arrived there growing or shrinking, which is what "dragging back swaps them back, at the same
/// width" asks for. A little flicker exactly at the line is the price of that, and it is the
/// right price — a layout that remembered where it came from would be two answers for one width.
public enum ShellLayout: Hashable, Sendable, CaseIterable {
    /// The page alone, the places as tabs, and compose as a button over the page. The rows keep
    /// their narrow arrangement, where the picture goes under the words rather than beside them.
    case narrow
    /// The rail on the left, the page beside it.
    case wide

    /// Where the rail begins. **Not a new number:** it is the floor the rail beside the page has
    /// always kept on a Mac, `RailView.Metrics.expandedWidth` plus the hairline plus the 318
    /// points every threshold in a source row is measured against. Below it the rail open leaves
    /// the page narrower than anything in it was built for, so below it the rail is not drawn.
    public static let breakpoint: CGFloat = 520

    /// The narrowest the app is ever drawn: the narrowest phone, and an iPad in Slide Over. A Mac
    /// window may be dragged this far and no further, because below it the narrow arrangement
    /// has nothing left to fold.
    public static let floor: CGFloat = 320

    /// The arrangement for a width. Pure, so both sides of the line can be asserted without a
    /// window to drag.
    ///
    /// **Nothing measured yet is wide**, which is what every launch drew before this rule
    /// existed, for one pass, until the first measurement lands.
    public static func answering(width: CGFloat?) -> ShellLayout {
        guard let width else { return .wide }
        return width < breakpoint ? .narrow : .wide
    }

    /// The arrangement on a platform that may still have its own say (#111).
    ///
    /// **An iPad answers the width it has, the way a Mac window does.** It used to answer the
    /// system's size class, which is right at the extremes and wrong exactly where a tablet is
    /// most often used beside something else: an 11-inch iPad at half the screen is some 590
    /// points wide and compact, so it drew the phone's tabs with room for the rail to spare.
    /// Turning the device is then the same change as dragging a window — a new width, answered —
    /// and every size the system offers beside another app is answered by what it is.
    ///
    /// **A phone keeps its size class**, and that is the one place a device is still asked about.
    /// #110 names the phone as its own task, and on its side a phone is wide enough for the rail
    /// and not tall enough to stand it in; answering the phone's width here would be deciding that
    /// task inside this one. `phoneIsCompact` is `nil` on everything that is not a phone.
    public static func answering(width: CGFloat?, phoneIsCompact: Bool?) -> ShellLayout {
        if let phoneIsCompact { return phoneIsCompact ? .narrow : .wide }
        return answering(width: width)
    }
}

/// The width a window gives, measured, and the arrangement for it handed to what is drawn (#110).
///
/// **A view of its own so that the thing a drag exercises can be exercised without a drag.** The
/// root asks this for its arrangement and a test hosts it off-screen and resizes the host, which
/// is the same sequence of widths a window's edge produces — nothing about it is the root's.
///
/// **The measurement sits outside whatever the content switches between**, so it is of the space
/// and not of the arrangement, and it outlives the swap it causes rather than starting again with
/// each arrangement's first frame.
struct ShellArranged<Content: View>: View {
    /// Which arrangement a width gets. The width rule unless a platform says otherwise.
    var answer: (CGFloat?) -> ShellLayout = { ShellLayout.answering(width: $0) }
    @ViewBuilder var content: (ShellLayout) -> Content

    /// The width last given, where one has been measured.
    @State private var width: CGFloat?

    var body: some View {
        let layout = answer(width)
        content(layout)
            .environment(\.shellLayout, layout)
            // **The window's floor is the narrow arrangement's, not the rail's.** It used to be a
            // `minWidth` of 520 on the rail's own arrangement, which is what stopped a Mac window
            // from ever reaching a width that could draw anything else. Both bounds on one frame,
            // so the width is the window's whatever arrangement is inside; `LayoutHostedTests`
            // asks it how narrow it can be over content that wants more, and it says the floor.
            #if os(macOS)
            .frame(
                minWidth: ShellLayout.floor, maxWidth: .infinity,
                minHeight: 360, maxHeight: .infinity
            )
            #else
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension EnvironmentValues {
    /// The arrangement the shell is drawn in, for the views inside it that arrange themselves too
    /// — a row, most of all. Handed down from the one place that measured, so a row does not
    /// guess from the device while the shell answers the width.
    @Entry var shellLayout: ShellLayout = .wide
}
