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
/// **The suite is `@MainActor`**: `ShellFold.folds(width:titles:)` asks AppKit, which is the main
/// actor's.
@Suite("The narrowest window's fold names what it opens")
@MainActor
struct FoldTests {
    init() {
        L10n.language = .english
    }

    @Test("A width folds exactly below the strip's own width, and no width yet folds nothing")
    func theLine() {
        #expect(!ShellFold.folds(width: nil, strip: 364))
        #expect(!ShellFold.folds(width: 364, strip: 364))
        #expect(ShellFold.folds(width: 363.5, strip: 364))
        #expect(ShellFold.folds(width: ShellLayout.floor, strip: 364))
        #expect(!ShellFold.folds(width: ShellLayout.floor, strip: 247))
        #expect(!ShellFold.folds(width: nil, titles: ShellPlace.allCases.map(\.title)))
    }

    /// **Nothing the wide arrangement draws is touched.** The fold is asked inside the narrow
    /// arrangement only, and the narrow arrangement starts below the rail's line, so the one width
    /// the rule could fold at from there is below it. Every set of names this app has, in both
    /// languages, fits well before the line.
    @Test("Every set of names fits at the rail's line, so the wide arrangement never meets the fold")
    func nothingFoldsAtTheLine() {
        for language in [DummyLanguage.english, .taiwanese] {
            L10n.language = language
            for count in 1 ... ShellPlace.allCases.count {
                let titles = ShellPlace.allCases.prefix(count).map(\.title)
                #expect(!ShellFold.folds(width: ShellLayout.breakpoint - 1, titles: titles), "\(language) \(titles)")
            }
        }
        L10n.language = .english
    }

    /// The sentence the help and the label share names every place behind the press, in the
    /// order the tabs drew them, and the word for the places before them.
    @Test("The pop-up's sentence names the places and every one of them, in every language")
    func theSentenceNamesEveryPlace() {
        for language in DummyLanguage.allCases {
            L10n.language = language
            let places = ShellPlace.allCases
            let said = ShellFold.spoken(places)
            #expect(said.hasPrefix(L10n.t("shell.places.fold")), "\(language): \(said)")
            var from = said.startIndex
            for place in places {
                let found = said.range(of: place.title, range: from ..< said.endIndex)
                #expect(found != nil, "\(language): \(place) missing or out of order in \(said)")
                from = found?.upperBound ?? from
            }
            #expect(!said.contains("shell.places"), "\(language) has no line for the fold")
        }
        L10n.language = .english
        // A reader with fewer places is told about fewer, and never about one they cannot enter.
        let three: [ShellPlace] = [.account, .usage, .preferences]
        #expect(!ShellFold.spoken(three).contains(ShellPlace.timeline.title))
    }

    /// Both Chinese bundles, not one: `L10n` falls back from one to the other, so a line missing
    /// from one still resolves and hides that it is missing.
    @Test("The fold's two lines are in every bundle")
    func theLinesAreInEveryBundle() throws {
        for lproj in ["en", "zh-Hant", "zh-TW"] {
            let path = try #require(Bundle.module.path(forResource: lproj, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in ["shell.places.fold", "shell.places.fold.help"] {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(lproj)/\(key)")
            }
        }
    }
}
