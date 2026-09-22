import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #140 — the person behind a row, opened by key as well as by touch.
///
/// What a test can reach: which letter means it, that it is the only letter that does and that no
/// other line of the guide already had it, the line the guide writes for it in every language, and
/// the rule that says when it may open anybody. What the key *does* once the rule says yes is
/// pressed in `ViewerTests`, whose harness is the root's own switch — it is there, beside the
/// face's press, so the two can be asserted to leave the walk in the same state.
///
/// What it cannot: that the letter reaches the root on a running app. That is the key monitor on a
/// Mac and `onKeyPress` on an iPhone with a keyboard, neither of which an SPM target can drive.
///
/// **The suite is `@MainActor`** for the reason `TouchTests` states: `FediqoRootView`'s statics
/// belong to a `View`.
@Suite("Opening whoever wrote it, by key")
@MainActor
struct PersonKeyTests {
    // MARK: - The letter

    @Test("p is the key, and it is the draft's while writing and the field's while typing")
    func pIsTheKey() {
        #expect(DummyCommand.from("p") == .openAuthor)
        #expect(DummyCommand.from("p", typing: true) == nil)
        #expect(DummyCommand.from("p", fieldFocused: true) == nil)
        // ⌘P is the platform's — print, on a Mac — and stays so.
        #expect(DummyCommand.from("p", command: true) == nil)
        // A letter is ours whether or not it moved anything, so a refused `p` on somebody's own
        // page is taken quietly rather than handed on to beep.
        #expect(DummyCommand.consumes("p", did: false))
    }

    /// The only letter that means it — and, from the other side, no letter the guide already
    /// names was taken to mean it. A key written down twice is a guide that lies about one of
    /// them.
    @Test("No other key opens a person, and no line of the guide shares a key with another")
    func pIsTheOnlyKeyAndNoKeyIsShared() {
        let printable = (32 ..< 127).compactMap { UnicodeScalar($0).map(Character.init) }
        let opening = printable.filter { DummyCommand.from($0) == .openAuthor }
        #expect(opening == ["p"])
        let keys = DummyShortcut.all.flatMap(\.keys)
        #expect(Set(keys).count == keys.count, "a key is written on two lines: \(keys)")
    }

    // MARK: - Where it is written down

    @Test("The guide names it on the timeline's tab, as the face's press")
    func theGuideNamesIt() throws {
        let line = try #require(DummyShortcut.all.first { $0.commands == [.openAuthor] })
        #expect(line.group == .read)
        #expect(line.keys == ["p"])
        #expect(line.name == "person")
        #expect(line.touch == .press)
        #expect(DummyShortcut.all.filter { $0.commands.contains(.openAuthor) }.count == 1)
    }

    /// In every language the app ships, asked by language rather than by setting the shell's:
    /// suites run side by side, and a test that wrote `L10n.language` would change the words
    /// under every other test reading them.
    @Test("The guide's line reads in every language the app ships")
    func theLineReadsEverywhere() throws {
        let line = try #require(DummyShortcut.all.first { $0.commands == [.openAuthor] })
        let key = "shortcut.\(line.name)"
        for language in DummyLanguage.allCases {
            let said = L10n.t(key, language: language)
            #expect(said != key, "\(language) has no line for p")
            #expect(!said.isEmpty, "\(language)")
        }
    }

    /// **In both Chinese tables, and not only through the fallback.** `L10n` falls back from
    /// `zh-TW` to `zh-Hant`, so a line missing from one still resolves and hides that it is
    /// missing. The tables are read from the files the app is built from, as `ComposeTests` and
    /// `BoardChoiceTests` read them, because a built bundle's folders are not found by the same
    /// path on every toolchain.
    @Test("The guide's line is written in every table, not reached by falling back")
    func theLineIsInEveryTable() throws {
        for lproj in ["en", "zh-Hant", "zh-TW"] {
            let table = try String(contentsOf: Self.table(lproj), encoding: .utf8)
            #expect(table.contains("\"shortcut.person\" = \""), "\(lproj) has no line for p")
        }
    }

    /// A shipped table, read from the source tree next to this file.
    private static func table(_ lproj: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources/\(lproj).lproj/Localizable.strings")
    }

    // MARK: - When it may open anybody

    /// Over every set of open layers there is: exactly where a face may walk, less somebody's own
    /// page. Enumerated from `allCases`, so a layer added later widens this test the day it lands.
    @Test("p may open exactly where a face may, except on somebody's own page")
    func theRuleOverTheWholeWorld() {
        let layers = DummyLayer.allCases
        for bits in 0 ..< (1 << layers.count) {
            let open = Set(layers.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
            let expected = DummyCommand.canWalk(whenOpen: open) && !open.contains(.person)
            #expect(DummyCommand.canOpenAuthor(whenOpen: open) == expected, "\(open)")
        }
        #expect(DummyCommand.canOpenAuthor(whenOpen: [.selection]))
        #expect(DummyCommand.canOpenAuthor(whenOpen: [.thread, .selection]))
        #expect(DummyCommand.canOpenAuthor(whenOpen: [.search, .selection]))
        #expect(!DummyCommand.canOpenAuthor(whenOpen: [.person, .selection]))
        #expect(!DummyCommand.canOpenAuthor(whenOpen: [.viewer, .selection]))
        #expect(!DummyCommand.canOpenAuthor(whenOpen: [.shortcuts, .selection]))
    }

    /// Keys are read above either arrangement, so the width is not an input to this rule at all —
    /// which is the whole of "at every width" a test can say. The place is: somebody is a step of
    /// the timeline's walk, and Account has no rows to stand on.
    @Test("Only on the timeline, whatever the width")
    func onlyOnTheTimeline() {
        for place in ShellPlace.allCases {
            #expect(FediqoRootView.canOpenAuthor(place: place, open: [.selection]) == (place == .timeline))
        }
    }
}
