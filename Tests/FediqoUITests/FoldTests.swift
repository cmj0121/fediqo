import Foundation
import Testing
@testable import FediqoUI

/// #141 — the rule and the words, without a host. `FoldHostedTests` asks the controls themselves.
///
/// What this cannot reach is what a listener hears: an off-screen host builds no accessibility tree
/// for SwiftUI to hand its label to. The pop-up is given one sentence for its help and its label,
/// asked for once (`FoldedPlaces.picker`), so the two cannot differ. What that sentence says is
/// asserted here in every language, and what VoiceOver reads out is for the user to check.
///
/// **Every language is named, never set.** Suites run side by side, and one that wrote
/// `L10n.language` would change the words under every other suite reading them.
///
/// **The suite is `@MainActor`**: `ShellFold.folds(width:titles:)` asks AppKit, which is the main
/// actor's.
@Suite("The narrowest window's fold names what it opens")
@MainActor
struct FoldTests {
    private static func titles(_ places: [ShellPlace], _ language: DummyLanguage) -> [String] {
        places.map { $0.title(language: language) }
    }

    @Test("A width folds exactly below the strip's own width, and no width yet folds nothing")
    func theLine() {
        #expect(!ShellFold.folds(width: nil, strip: 364))
        #expect(!ShellFold.folds(width: 364, strip: 364))
        #expect(ShellFold.folds(width: 363.5, strip: 364))
        #expect(ShellFold.folds(width: ShellLayout.floor, strip: 364))
        #expect(!ShellFold.folds(width: ShellLayout.floor, strip: 247))
        #expect(!ShellFold.folds(width: nil, titles: Self.titles(ShellPlace.allCases, .english)))
    }

    /// **Nothing the wide arrangement draws is touched.** The fold is asked inside the narrow
    /// arrangement only, and the narrow arrangement starts below the rail's line, so the one width
    /// the rule could fold at from there is below it. Every set of names this app has, in both
    /// languages, fits well before the line.
    @Test("Every set of names fits at the rail's line, so the wide arrangement never meets the fold")
    func nothingFoldsAtTheLine() {
        for language in [DummyLanguage.english, .taiwanese] {
            for count in 1 ... ShellPlace.allCases.count {
                let titles = Self.titles(Array(ShellPlace.allCases.prefix(count)), language)
                #expect(!ShellFold.folds(width: ShellLayout.breakpoint - 1, titles: titles), "\(language) \(titles)")
            }
        }
    }

    /// The sentence the help and the label share names every place behind the press, in the
    /// order the tabs drew them, and the word for the places before them.
    @Test("The pop-up's sentence names the places and every one of them, in every language")
    func theSentenceNamesEveryPlace() {
        for language in DummyLanguage.allCases {
            let places = ShellPlace.allCases
            let said = ShellFold.spoken(places, language: language)
            #expect(said.hasPrefix(L10n.t("shell.places.fold", language: language)), "\(language): \(said)")
            var from = said.startIndex
            for place in places {
                let found = said.range(of: place.title(language: language), range: from ..< said.endIndex)
                #expect(found != nil, "\(language): \(place) missing or out of order in \(said)")
                from = found?.upperBound ?? from
            }
            #expect(!said.contains("shell.places"), "\(language) has no line for the fold")
        }
        // A reader with fewer places is told about fewer, and never about one they cannot enter.
        let three: [ShellPlace] = [.account, .usage, .preferences]
        #expect(!ShellFold.spoken(three, language: .english).contains(ShellPlace.timeline.title(language: .english)))
    }

    /// **In both Chinese tables, and not only through the fallback.** `L10n` falls back from
    /// `zh-TW` to `zh-Hant`, so a line missing from one still resolves and hides that it is
    /// missing. Read from the files the app is built from, as `ComposeTests` and
    /// `BoardChoiceTests` read them: a built bundle's folders are not found by the same path on
    /// every toolchain.
    @Test("The fold's two lines are written in every table")
    func theLinesAreInEveryTable() throws {
        for lproj in ["en", "zh-Hant", "zh-TW"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FediqoUI/Resources/\(lproj).lproj/Localizable.strings")
            let table = try String(contentsOf: url, encoding: .utf8)
            for key in ["shell.places.fold", "shell.places.fold.help"] {
                #expect(table.contains("\"\(key)\" = \""), "\(lproj)/\(key)")
            }
        }
    }
}
