import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the narrow arrangement does with the places when a Mac window is too narrow to write
/// their names side by side (#141).
///
/// ## The fold, and why it had to say something
///
/// **The narrow arrangement draws the places as a `TabView`, and on a Mac a `TabView` is an
/// `NSTabView`**: one segmented strip across the top of a bordered page. The strip wants the width
/// its names need, and a window may be dragged to 320 points since #110. In English the five names
/// are laid out at 378 and need 364, and below that what does not fit is cut short or folded
/// behind a mark. A folded tab strip is a mark that names nothing, and a reader who has never seen
/// the wide window cannot tell that the places they are looking for are behind it. #112 accepted
/// that whatever a layout folds away has a way in that names what it opens; this was the one that
/// did not.
///
/// **Where the strip no longer fits, the places are one pop-up that says "Places" and shows where
/// the reader is**: the same list in the same order, in words, before it is pressed. Nothing else
/// changes. The page stays where the strip's page was, to the point (`pageInsets`), and the compose
/// button, the width rule and which places there are all stay as they were.
///
/// ## Where the line is, and why it is measured rather than written down
///
/// **The line is the strip's own width, asked of AppKit for the names it would draw.** A number
/// written down here would be right for one language and wrong for the other: the same five places
/// are 364 points of English and 247 of 中文, so a Chinese window at 320 has room to spare and
/// keeps its tabs. Asking an `NSSegmentedControl` with those names for its size is asking the
/// control `NSTabView` draws, and `FoldHostedTests` checks that against a hosted `TabView` a point
/// at a time. This does not change which width folds what (#110 and #112 decided that). It only
/// says what is drawn once AppKit has folded.
///
/// **A phone never folds here.** Its tab bar is the system's and fits five places at every width a
/// phone has; an iPad's narrow arrangement is the same bar. Only a Mac draws this strip.
enum ShellFold {
    /// Where the page sits inside the strip's bordered page, which is where the folded page is
    /// drawn so that nothing moves when the pop-up takes the strip's place. Read off the hosted
    /// `TabView` and checked against it in `FoldHostedTests`, so a new AppKit that moves its page
    /// fails there instead of shifting the page by a few points without anyone seeing.
    static let pageInsets = EdgeInsets(top: 27, leading: 3, bottom: 3, trailing: 3)

    /// Whether a width is too narrow for a strip that needs `strip` points. Pure, so both sides
    /// of the line can be checked without a window. **Nothing measured yet does not fold**, which
    /// is what every launch drew before this rule existed.
    ///
    /// **The strip's own size and not the room it is laid out with.** `NSTabView` gives the strip
    /// a little more than it needs where it can and takes that back first as the window narrows,
    /// so for the last few points above this line the strip is tighter and every name is still
    /// whole. That is not a fold, and nothing is done about it. The strip gets the window's whole
    /// width once it is squeezed, so the width it is squeezed below its own size is the window's.
    static func folds(width: CGFloat?, strip: CGFloat) -> Bool {
        guard let width else { return false }
        return width < strip
    }

    /// Whether the narrow arrangement at this width folds these names. False on every platform
    /// that does not draw the strip.
    @MainActor
    static func folds(width: CGFloat?, titles: [String]) -> Bool {
        #if os(macOS)
        return folds(width: width, strip: stripWidth(titles))
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// Widths already asked for, by the names asked about. A body pass asks on every change of
    /// width, and during a drag that is every point of the edge; the names change only with the
    /// language or with a place being enabled.
    @MainActor private static var measured: [[String]: CGFloat] = [:]

    /// The width the strip needs for these names: the intrinsic width of the control `NSTabView`
    /// draws, which is a plain `NSSegmentedControl` of the same names in the same system font.
    @MainActor
    static func stripWidth(_ titles: [String]) -> CGFloat {
        if let known = measured[titles] { return known }
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        let width = control.intrinsicContentSize.width
        measured[titles] = width
        return width
    }
    #endif

    /// What the pop-up is called, to a pointer's help and to VoiceOver alike: the word for the
    /// places and every place it holds, in the order the tabs drew them.
    ///
    /// **The names and not a count.** "5 places" says there is something behind the press and
    /// not what. A reader looking for Usage needs to hear Usage before pressing. The list is
    /// joined in the shell's language, so 中文 gets 、 and not an English comma.
    static func spoken(_ places: [ShellPlace]) -> String {
        let names = places.map(\.title).formatted(.list(type: .and).locale(L10n.locale()))
        return String(format: L10n.t("shell.places.fold.help"), names)
    }
}

/// The narrow arrangement, tabbed where the names fit and folded into one named pop-up where they
/// do not (#141). See `ShellFold`.
///
/// **A view of its own because the width is below the root.** `ShellArranged` measures it and
/// hands it down. The root's own properties are drawn above that and cannot read it, so the
/// question is asked here, where the width can be read, the way a row asks `\.shellLayout`.
struct ShellNarrow<Tabs: View, Folded: View>: View {
    /// The names the strip would draw, in the language it would draw them in.
    let titles: [String]
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var folded: () -> Folded

    @Environment(\.shellWidth) private var width

    var body: some View {
        if ShellFold.folds(width: width, titles: titles) {
            folded()
        } else {
            tabs()
        }
    }
}

/// The places folded into one pop-up where the strip was, and the page where the strip's page was.
///
/// **A `Picker` shown as a menu, labelled.** On a Mac that is a pop-up button with its label
/// written beside it, "Places" and then where the reader is, so the way in names what it opens
/// before it is pressed, and pressing it lists every place by name. Arrow keys and Return work it
/// like any pop-up, and ⌃Tab walks the same places as before, because ⌃Tab reads `place` and not
/// the strip.
struct FoldedPlaces<Page: View>: View {
    @Binding var place: ShellPlace
    let places: [ShellPlace]
    @ViewBuilder var page: () -> Page

    var body: some View {
        VStack(spacing: 0) {
            picker
                .frame(maxWidth: .infinity)
                .frame(height: ShellFold.pageInsets.top)
            page()
                .padding(.leading, ShellFold.pageInsets.leading)
                .padding(.trailing, ShellFold.pageInsets.trailing)
                .padding(.bottom, ShellFold.pageInsets.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var picker: some View {
        // **One sentence, asked for once and handed to both**, so a pointer's help and a
        // listener cannot come to be told different things.
        let said = ShellFold.spoken(places)
        return Picker(L10n.t("shell.places.fold"), selection: $place) {
            ForEach(places) { item in
                Label(item.title, systemImage: item.symbolName).tag(item)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(said)
        .accessibilityLabel(said)
    }
}
