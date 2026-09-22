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
/// that draws them, and the fold rule is checked against it at the line and the points either
/// side of it, in both languages, for every set of places a reader can have. The folded pop-up is
/// AppKit's `NSPopUpButton`, and its items are read off it as well.
///
/// **What it does not reach.** No window is made and nothing is shown. How the strip and the
/// pop-up look in light and dark, and what VoiceOver says out loud, are for the user to check on a
/// running app.
///
/// **Few layouts, one at a time, and no language set.** A hosted layout runs on the main actor,
/// and a suite that asks for many of them in parallel with everything else starves the tests
/// that wait on the main actor for their own answers. So the widths asked are the ones that decide
/// the rule — the floor, the line itself and a point either side, the rail's line — rather than
/// every point between, and the suite runs serially. Each language is named, not set: a suite
/// that wrote `L10n.language` would change the words under every suite running beside it.
@Suite("The narrowest window's fold names what it opens, hosted", .serialized)
@MainActor
struct FoldHostedTests {
    /// A view that can be found in the hosted tree, standing in for a page.
    private final class Mark: NSView {}

    private struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> Mark { Mark() }
        func updateNSView(_ nsView: Mark, context: Context) {}
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// A new frame, laid out, and the one redraw the width's measurement asks for, laid out again.
    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        view.layoutSubtreeIfNeeded()
    }

    private static func host(_ root: some View, width: CGFloat, height: CGFloat = 500) -> NSHostingView<some View> {
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        settle(view)
        return view
    }

    private static func titles(_ places: [ShellPlace], _ language: DummyLanguage) -> [String] {
        places.map { $0.title(language: language) }
    }

    /// The narrow arrangement's tabs, as `FediqoRootView.tabbed` writes them.
    private static func tabs(_ places: [ShellPlace], _ language: DummyLanguage) -> some View {
        TabView {
            ForEach(places) { item in
                Marker()
                    .tabItem { Label(item.title(language: language), systemImage: item.symbolName) }
                    .tag(item)
            }
        }
    }

    /// The narrow arrangement's switch, as `FediqoRootView.narrow` writes it, under the real
    /// measurement.
    private static func narrow(_ places: [ShellPlace], _ language: DummyLanguage = .english) -> some View {
        ShellArranged { _ in
            ShellNarrow(titles: titles(places, language)) {
                tabs(places, language)
            } folded: {
                FoldedPlaces(place: .constant(places[0]), places: places, language: language) { Marker() }
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

    /// The widths that decide the rule for a strip that needs `needed`: the floor, the line and a
    /// point either side of it, and the last point before the rail. Only those inside the narrow
    /// arrangement's range.
    private static func deciding(_ needed: CGFloat) -> [CGFloat] {
        let range = ShellLayout.floor ... ShellLayout.breakpoint - 1
        let widths = [ShellLayout.floor, needed - 1, needed, needed + 1, ShellLayout.breakpoint - 1]
        return Array(Set(widths.filter(range.contains))).sorted()
    }

    // MARK: - Where the strip stops fitting

    /// **The measurement is the control's.** The width the rule asks AppKit for is the width the
    /// hosted strip says it wants, for every set of names, in both languages.
    @Test("The strip's width the rule measures is the width the hosted strip wants")
    func theMeasuredWidthIsTheStrips() throws {
        for language in Self.languages {
            for places in Self.offered {
                let view = Self.host(Self.tabs(places, language), width: ShellLayout.breakpoint - 1)
                let strip = try #require(Self.all(NSSegmentedControl.self, in: view).first)
                #expect(strip.segmentCount == places.count)
                #expect(
                    strip.intrinsicContentSize.width == ShellFold.stripWidth(Self.titles(places, language)),
                    "\(language) \(places)"
                )
            }
        }
    }

    /// **"At every wider width nothing changes."** At the line and a point either side of it, at
    /// the floor and at the rail's line, the rule folds exactly where the hosted strip is squeezed
    /// narrower than its names need, and nowhere else. Every other width is on one side of the
    /// line or the other, and the rule is one comparison with no memory.
    @Test("The rule folds exactly where the hosted strip is squeezed, at every width that decides it")
    func theRuleFoldsWhereTheStripIsSqueezed() throws {
        var asked = 0
        for language in Self.languages {
            for places in Self.offered {
                let titles = Self.titles(places, language)
                let needed = ShellFold.stripWidth(titles)
                let view = Self.host(Self.tabs(places, language), width: ShellLayout.breakpoint - 1)
                for width in Self.deciding(needed) {
                    view.frame.size.width = width
                    view.layoutSubtreeIfNeeded()
                    let strip = try #require(Self.all(NSSegmentedControl.self, in: view).first)
                    #expect(
                        ShellFold.folds(width: width, titles: titles) == (strip.frame.width < needed),
                        "\(language) \(places.count) places at \(width): strip \(strip.frame.width)"
                    )
                    asked += 1
                }
            }
        }
        // Not vacuous: the English window at the floor with every place really does fold, the
        // Chinese one really does not, and the line was crossed in at least one set.
        #expect(ShellFold.folds(width: ShellLayout.floor, titles: Self.titles(ShellPlace.allCases, .english)))
        #expect(!ShellFold.folds(width: ShellLayout.floor, titles: Self.titles(ShellPlace.allCases, .taiwanese)))
        #expect(asked > Self.languages.count * Self.offered.count * 2)
    }

    // MARK: - What is drawn either side of it

    /// At the widths that decide it, the switch draws the strip where the rule says it fits and
    /// the named pop-up where it does not. Never both, and never neither.
    @Test("The narrow arrangement draws the tabs or the pop-up, as the rule says")
    func eitherTheTabsOrThePopUp() {
        let places = ShellPlace.allCases
        let titles = Self.titles(places, .english)
        let view = Self.host(Self.narrow(places), width: ShellLayout.breakpoint - 1)
        for width in Self.deciding(ShellFold.stripWidth(titles)).reversed() {
            view.frame.size.width = width
            Self.settle(view)
            let folds = ShellFold.folds(width: width, titles: titles)
            #expect(Self.all(NSTabView.self, in: view).count == (folds ? 0 : 1), "\(width)")
            #expect(Self.all(NSPopUpButton.self, in: view).count == (folds ? 1 : 0), "\(width)")
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
            guard ShellFold.folds(width: ShellLayout.floor, titles: Self.titles(places, .english)) else {
                // Four English names fit at the floor, and three do, so there is nothing folded
                // to reach.
                #expect(Self.all(NSPopUpButton.self, in: view).isEmpty, "\(places)")
                continue
            }
            folded += 1
            let popUp = try #require(Self.all(NSPopUpButton.self, in: view).first, "\(places)")
            #expect(popUp.itemTitles == Self.titles(places, .english))
            #expect(popUp.titleOfSelectedItem == places[0].title(language: .english))
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
        let tabbed = Self.host(Self.tabs(places, .english), width: width)
        let folded = Self.host(
            FoldedPlaces(place: .constant(.timeline), places: places, language: .english) { Marker() },
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
