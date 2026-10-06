import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    /// their narrow arrangement: no empty slot beside the words, a picture beside them held to
    /// the standard size's slot, and the marks on one line that gives way rather than breaking
    /// (#245).
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
            // The width itself, for the one question the arrangement cannot answer: whether the
            // narrow arrangement's strip still fits its names (#141). See `ShellNarrow`.
            .environment(\.shellWidth, width)
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

    /// The width `ShellArranged` last measured, where it has measured one. Read by `ShellNarrow`
    /// alone, to ask whether the places' strip still fits its names (#141). A row asks
    /// `shellLayout` and not this: which arrangement it is in is the row's business, and how
    /// wide the window is exactly is not.
    @Entry var shellWidth: CGFloat? = nil

    /// The corner of the page something is drawn over, where something is: how far it reaches in
    /// from the trailing edge, and how far up from the bottom (#112). Nothing, everywhere else.
    ///
    /// **The narrow arrangement's compose button, and only that.** It floats over every page, so
    /// the last row of a list stood under it with its marks unreachable by a finger, and the
    /// search bar's end sat beneath it — acts the wide arrangement never hid. The button stays
    /// where it is; what is under it is told how much room to leave, and leaves it.
    @Entry var shellFloatingCorner: CGSize = .zero

    /// Whether a sideways swipe moves anything here: on an iPhone or iPad. A test hosting a
    /// page on a Mac says yes, to see what of the page a slide moves and what it leaves.
    @Entry var shellSlides: Bool = ShellSheetFloor.sizedByContent == false

    /// The slide of the page a row of tabs heads, where the page hands one down rather than
    /// passing it: what the tabs' head leans with, and where its list is kept open.
    @Entry var shellTabsSlide: PageSlide? = nil

    /// Where a hosted pane laid its head and what is under it, for a test that asks.
    @Entry var shellPaneProbe: PaneProbe? = nil

    /// Whether something is drawn over the whole shell — a picture opened, the keys' guide, the
    /// landing — so what is under it must not answer a gesture made across it (#305).
    @Entry var shellCovered: Bool = false
}

/// Leaves the floating corner clear at the end of a list, so its last row can be scrolled out
/// from under whatever floats there. See `EnvironmentValues.shellFloatingCorner`.
///
/// **A margin on the scrolled content and not padding on the view**, so the rows still pass
/// under the button while the reader scrolls — the button is over the page, not beside it — and
/// only the end of the list stops short of it.
struct ClearsFloatingCorner: ViewModifier {
    @Environment(\.shellFloatingCorner) private var corner

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, corner.height, for: .scrollContent)
    }
}

extension View {
    /// See `ClearsFloatingCorner`.
    func clearsFloatingCorner() -> some View { modifier(ClearsFloatingCorner()) }
}

/// The least a sheet's content asks to be, where asking decides anything (#302).
///
/// **On a Mac a sheet is as large as what is in it**, so a floor is what stops one opening as a
/// sliver. **On an iPhone and an iPad the system sizes the sheet** and the content is laid out
/// in what it is given: a floor there changes nothing where it is met and, where the screen is
/// narrower than it, lays the content out wider than the sheet with both edges cut off.
enum ShellSheetFloor {
    /// Whether a sheet here is sized by what is in it.
    static var sizedByContent: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The floor to hold, or nothing where the sheet is not the content's to size.
    static func held(_ floor: CGSize, sizedByContent: Bool = ShellSheetFloor.sizedByContent) -> CGSize? {
        sizedByContent ? floor : nil
    }
}

extension View {
    /// Holds a sheet's content to no less than this, on a Mac. See `ShellSheetFloor`.
    func shellSheetFloor(width: CGFloat, height: CGFloat) -> some View {
        let held = ShellSheetFloor.held(CGSize(width: width, height: height))
        return frame(minWidth: held?.width, minHeight: held?.height)
    }
}

extension View {
    /// Keeps what stands at the foot of a page to the leading side of the corner the compose
    /// button floats in, where it floats (#302). `already` is the room the view keeps at its
    /// own sides anyway.
    func standsBesideFloatingCorner(by already: CGFloat = 0) -> some View {
        modifier(StandsBesideFloatingCorner(already: already))
    }
}

/// What stands at the foot of a page stands **beside** the compose button, and not over it.
///
/// It was lifted over the button, which on a phone put a notice some way up the page, across
/// the post being read. Now it stays at the foot, just over the places, and is kept clear of
/// the button sideways: it has the room to the leading side of the button's corner, and is in
/// the middle of that. Nothing where no button floats — a wide page, a reader who may not
/// write — and there it is in the middle of the page's foot, as it always was.
struct StandsBesideFloatingCorner: ViewModifier {
    let already: CGFloat
    @Environment(\.shellFloatingCorner) private var corner

    /// How much of the page's trailing side is left to the button: its corner's width — the
    /// button, the room it keeps from the edge and a gap beside it — less the room the view
    /// keeps at its own side anyway, so that room is not kept twice on a page with none to spare.
    static func kept(corner: CGSize, already: CGFloat) -> CGFloat {
        max(0, corner.width - already)
    }

    func body(content: Content) -> some View {
        content.padding(.trailing, Self.kept(corner: corner, already: already))
    }
}

/// Where a pane's head and what is under it were laid out, on screen. See `Probed`.
@MainActor
final class PaneProbe {
    var head = CGRect.zero
    var under = CGRect.zero
}

/// Reports where a part of a pane was laid out to a probe, where one is handed down; draws
/// nothing and changes nothing.
struct ProbedPane: ViewModifier {
    enum Part { case head, under }
    let part: Part

    @Environment(\.shellPaneProbe) private var probe

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { place in
                let _ = part == .head ? (probe.head = place.frame(in: .global)) : (probe.under = place.frame(in: .global))
                Color.clear
            })
        } else {
            content
        }
    }
}

/// Tells what is in a sheet which arrangement it is drawn in (#305).
///
/// **A sheet is raised from the root, outside the arrangement**, so it is handed none and would
/// take the wide one everywhere. On a phone it is as narrow as the page under it, and says so
/// by the same rule the page goes by (`ShellLayout.answering(width:phoneIsCompact:)`). On an
/// iPad and a Mac a sheet has a width of its own that no page's arrangement speaks for, and it
/// is left as it was.
struct ShellSheetArranged: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.shellLayout) private var handed

    /// The arrangement a sheet takes: a phone's own, and anywhere else the one it was handed.
    static func layout(phoneIsCompact: Bool?, handed: ShellLayout) -> ShellLayout {
        phoneIsCompact.map { ShellLayout.answering(width: nil, phoneIsCompact: $0) } ?? handed
    }

    private var phoneIsCompact: Bool? {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? sizeClass == .compact : nil
        #else
        nil
        #endif
    }

    func body(content: Content) -> some View {
        content.environment(\.shellLayout, Self.layout(phoneIsCompact: phoneIsCompact, handed: handed))
    }
}
