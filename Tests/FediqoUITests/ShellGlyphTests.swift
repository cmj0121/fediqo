#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import FediqoUI

/// Chosen is drawn as another glyph, not only another ink: every place on the rail and every tab
/// a page can choose has a twin the system draws, and the twin is not the glyph itself.
@Suite("A chosen glyph")
struct ShellGlyphTests {
    /// Every glyph that is drawn chosen somewhere: the rail's places, and the glyph of every tab.
    static var chosenable: [String] {
        var symbols = ShellPlace.allCases.map(\.symbolName)
        symbols += TagTab.allCases.map(\.symbol) + PersonTab.allCases.map(\.symbol)
        symbols += TrendsTab.allCases.map(\.symbol) + FoundWhich.allCases.map(\.symbol)
        symbols += AdminTab.allCases.map(\.symbol) + RisingWhich.allCases.map(\.symbol)
        symbols += EditorTab.allCases.map(\.symbol) + DummyShortcutGroup.allCases.map(\.symbol)
        symbols += PreferencesPane.Purpose.allCases.map(\.symbol)
        symbols += AccountPane.Purpose.allCases.map(\.symbol) + UsagePane.Purpose.allCases.map(\.symbol)
        symbols += [TimelineQuery.all, .trends, .written(UUID())].map(\.symbol)
        // The rule form's own pills: where a rule reads (`RuleFormFoot.scopeSymbol`) and what it does.
        symbols += ["globe", "externaldrive", "eye", "eye.slash"]
        return Array(Set(symbols.filter { !$0.isEmpty })).sorted()
    }

    @Test("Every glyph that can be chosen has a twin the system draws, and it is another glyph")
    func everyChosenGlyphHasATwin() {
        for symbol in Self.chosenable {
            let twin = ShellGlyph.drawn(symbol, chosen: true)
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            #expect(NSImage(systemSymbolName: twin, accessibilityDescription: nil) != nil, "\(symbol) → \(twin)")
            #expect(twin != symbol, "\(symbol)")
        }
    }

    @Test("Not chosen is the glyph itself, and a glyph already filled stays as it is")
    func unchosenIsItself() {
        #expect(ShellGlyph.drawn("bell", chosen: false) == "bell")
        #expect(ShellGlyph.drawn("bell", chosen: true) == "bell.fill")
        #expect(ShellGlyph.drawn("hand.tap.fill", chosen: true) == "hand.tap.fill")
        #expect(ShellGlyph.drawn("", chosen: true) == "")
    }
}
#endif
