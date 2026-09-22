#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FediqoUI

/// #141 — what the narrowest window folds away says what it opens, asked of the real controls
/// hosted off-screen.
///
/// **What this reaches.** The `TabView` the narrow arrangement draws, hosted in an
/// `NSHostingView` the way `LayoutHostedTests` hosts the switch, is AppKit's own `NSTabView` and
/// its own segmented strip. So "where the strip stops fitting its names" is read off the control
/// that draws them, a point at a time from the floor to the rail's line, in both languages, and the
/// fold rule is checked against it. The folded pop-up is AppKit's `NSPopUpButton`, and its items,
/// its help and its accessibility label are read off it as well.
///
/// **What it does not reach.** No window is made and nothing is shown. How the strip and the
/// pop-up look in light and dark, and what VoiceOver says out loud, are for the user to check on a
/// running app.
@Suite("The narrowest window's fold names what it opens, hosted")
@MainActor
struct FoldHostedTests {
    init() {
        L10n.language = .english
    }

    /// A view that can be found in the hosted tree, standing in for a page.
    private final class Mark: NSView {}

    private struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> Mark { Mark() }
        func updateNSView(_ nsView: Mark, context: Context) {}
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// A new frame, laid out, and the redraw a measurement asks for, laid out again.
    private static func settle(_ view: NSView) {
        for _ in 0 ..< 3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// A new frame, laid out, where nothing is measured: AppKit places its strip in the layout
    /// pass itself, so there is no redraw to wait for.
    private static func lay(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
    }

    private static func host(_ root: some View, width: CGFloat, height: CGFloat = 500) -> NSHostingView<some View> {
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        settle(view)
        return view
    }

    /// The narrow arrangement's tabs, as `FediqoRootView.tabbed` writes them.
    private static func tabs(_ places: [ShellPlace]) -> some View {
        TabView {
            ForEach(places) { item in
                Marker()
                    .tabItem { Label(item.title, systemImage: item.symbolName) }
                    .tag(item)
            }
        }
    }

    /// The narrow arrangement's switch, as `FediqoRootView.narrow` writes it, under the real
    /// measurement.
    private static func narrow(_ places: [ShellPlace]) -> some View {
        ShellArranged { _ in
            ShellNarrow(titles: places.map(\.title)) {
                tabs(places)
            } folded: {
                FoldedPlaces(place: .constant(places[0]), places: places) { Marker() }
            }
        }
    }

    /// The sets of places a reader can have: everything; no sign-in, so no Notices; and no
    /// source at all, so no Timeline and no Notices.
    private static let offered: [[ShellPlace]] = [
        ShellPlace.allCases,
        ShellPlace.allCases.filter { $0 != .notices },
        [.account, .usage, .preferences],
    ]

    private static let languages: [DummyLanguage] = [.english, .taiwanese]

    // MARK: - Where the strip stops fitting

    /// **The measurement is the control's.** The width the rule asks AppKit for is the width the
    /// hosted strip says it wants, for every set of names, in both languages.
    @Test("The strip's width the rule measures is the width the hosted strip wants")
    func theMeasuredWidthIsTheStrips() throws {
        for language in Self.languages {
            L10n.language = language
            for places in Self.offered {
                let view = Self.host(Self.tabs(places), width: 900)
                let strip = try #require(Self.all(NSSegmentedControl.self, in: view).first)
                #expect(strip.segmentCount == places.count)
                #expect(
                    strip.intrinsicContentSize.width == ShellFold.stripWidth(places.map(\.title)),
                    "\(language) \(places)"
                )
            }
        }
        L10n.language = .english
    }

    /// **"At every wider width nothing changes", a point at a time.** From the floor to the rail's
    /// line, the rule folds exactly where the hosted strip is squeezed narrower than its names
    /// need, and nowhere else. In English with every place that is the bottom of the range. In
    /// 中文 it is nowhere: the names fit at the floor, so a Chinese window keeps its tabs.
    @Test("The rule folds exactly where the hosted strip is squeezed, from the floor to the line")
    func theRuleFoldsWhereTheStripIsSqueezed() throws {
        for language in Self.languages {
            L10n.language = language
            for places in Self.offered {
                let titles = places.map(\.title)
                let needed = ShellFold.stripWidth(titles)
                let view = Self.host(Self.tabs(places), width: ShellLayout.breakpoint)
                for width in stride(from: ShellLayout.breakpoint - 1, through: ShellLayout.floor, by: -1) {
                    view.frame.size.width = width
                    Self.lay(view)
                    let strip = try #require(Self.all(NSSegmentedControl.self, in: view).first)
                    let squeezed = strip.frame.width < needed
                    #expect(
                        ShellFold.folds(width: width, titles: titles) == squeezed,
                        "\(language) \(places.count) places at \(width): strip \(strip.frame.width)"
                    )
                }
            }
        }
        L10n.language = .english
        // Not vacuous: the English window at the floor with every place really does fold, and
        // the Chinese one really does not.
        #expect(ShellFold.folds(width: ShellLayout.floor, titles: ShellPlace.allCases.map(\.title)))
        L10n.language = .taiwanese
        #expect(!ShellFold.folds(width: ShellLayout.floor, titles: ShellPlace.allCases.map(\.title)))
        L10n.language = .english
    }

    // MARK: - What is drawn either side of it

    /// Across the whole narrow range, the switch draws the strip where the rule says it fits and
    /// the named pop-up where it does not. Never both, and never neither.
    @Test("The narrow arrangement draws the tabs or the pop-up, as the rule says, at every width")
    func eitherTheTabsOrThePopUp() {
        let places = ShellPlace.allCases
        let titles = places.map(\.title)
        let view = Self.host(Self.narrow(places), width: ShellLayout.breakpoint - 1)
        for width in stride(from: ShellLayout.breakpoint - 1, through: ShellLayout.floor, by: -1) {
            view.frame.size.width = width
            Self.settle(view)
            let folds = ShellFold.folds(width: width, titles: titles)
            let tabs = Self.all(NSTabView.self, in: view).count
            let popUps = Self.all(NSPopUpButton.self, in: view).count
            #expect(tabs == (folds ? 0 : 1), "\(width)")
            #expect(popUps == (folds ? 1 : 0), "\(width)")
        }
    }

    /// **Every place is still reachable through it**, by name, in the order the tabs drew them.
    /// A pop-up is pressed with a pointer or a finger and worked with the arrow keys and Return,
    /// and ⌃Tab reads the place rather than the strip, so it walks the same places it did.
    @Test("The pop-up holds every place, by name, in the tabs' order")
    func thePopUpHoldsEveryPlace() throws {
        var folded = 0
        for places in Self.offered {
            let view = Self.host(Self.narrow(places), width: ShellLayout.floor)
            guard ShellFold.folds(width: ShellLayout.floor, titles: places.map(\.title)) else {
                // Four English names fit at the floor, and three do, so there is nothing folded
                // to reach.
                #expect(Self.all(NSPopUpButton.self, in: view).isEmpty, "\(places)")
                continue
            }
            folded += 1
            let popUp = try #require(Self.all(NSPopUpButton.self, in: view).first, "\(places)")
            #expect(popUp.itemTitles == places.map(\.title))
            #expect(popUp.titleOfSelectedItem == places[0].title)
        }
        // Not vacuous: the reader with every place is the one whose names do not fit.
        #expect(folded == 1)
    }

    /// **The word for the places is written beside the pop-up**, not only in its help: the
    /// pop-up does not stand at the middle of the bar, because its label stands before it. What
    /// the label says is `shell.places.fold`; that it is drawn is read off where the pop-up is.
    @Test("Something is written before the pop-up, where the strip's middle was")
    func theLabelIsWrittenBeforeThePopUp() throws {
        let view = Self.host(Self.narrow(ShellPlace.allCases), width: ShellLayout.floor)
        let popUp = try #require(Self.all(NSPopUpButton.self, in: view).first)
        let frame = popUp.convert(popUp.bounds, to: view)
        // Centred as a pair, so the pop-up is pushed past the middle by what stands before it.
        #expect(frame.midX > view.bounds.midX + 8, "pop-up at \(frame)")
        #expect(frame.maxX <= view.bounds.maxX)
    }

    /// **Nothing that was not folded moves.** The page is where the strip's page was, to the
    /// point, and the pop-up takes the strip's height and no more. Read off both hosted trees
    /// through a marker drawn as the page.
    @Test("The folded page stands exactly where the tabs' page stood")
    func thePageDoesNotMove() throws {
        let places = ShellPlace.allCases
        let width = ShellLayout.floor
        let tabbed = Self.host(Self.tabs(places), width: width)
        let folded = Self.host(
            FoldedPlaces(place: .constant(.timeline), places: places) { Marker() },
            width: width
        )
        let before = try #require(Self.all(Mark.self, in: tabbed).first)
        let after = try #require(Self.all(Mark.self, in: folded).first)
        let was = before.convert(before.bounds, to: tabbed)
        let now = after.convert(after.bounds, to: folded)
        #expect(was == now, "tabs \(was), folded \(now)")
        let insets = ShellFold.pageInsets
        #expect(was.minX == insets.leading)
        #expect(was.minY == insets.top)
        #expect(tabbed.frame.width - was.maxX == insets.trailing)
        #expect(tabbed.frame.height - was.maxY == insets.bottom)
    }
}
#endif
