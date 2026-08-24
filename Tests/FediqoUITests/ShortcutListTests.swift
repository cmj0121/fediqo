import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// The written-down list, against the keys it claims to describe.
///
/// This is the whole reason the list is a table on `KeyCommand` rather than words in a view:
/// a key added later and left undescribed has to fail here, not go quietly unmentioned.
@Suite("The keys, written down")
struct ShortcutListTests {
    @Test("Every key the app answers is written down, and none of them twice")
    func everyCommandIsDescribed() {
        let described = KeyCommand.shortcuts.flatMap(\.commands)
        #expect(Set(described) == Set(KeyCommand.allCases))
        #expect(described.count == KeyCommand.allCases.count)
    }

    @Test("Every line belongs to one of the three groups, and no group is left empty")
    func everyGroupHasLines() {
        for group in KeyCommand.ShortcutGroup.allCases {
            #expect(KeyCommand.shortcuts.contains { $0.group == group })
        }
    }

    @Test("Every line has caps to press and a name of its own")
    func everyLineIsWhole() {
        #expect(KeyCommand.shortcuts.allSatisfy { !$0.keys.isEmpty && !$0.commands.isEmpty })
        #expect(Set(KeyCommand.shortcuts.map(\.name)).count == KeyCommand.shortcuts.count)
    }

    // MARK: - The strings behind it

    /// A label whose key is missing from the catalogue draws the key itself — `shortcut.top`
    /// where the reader expected a sentence. There is one line per key here and it is easy
    /// to add one and forget the other, so both languages are checked against the catalogue
    /// rather than against the built bundle: SwiftPM copies `.xcstrings` across untouched
    /// and only the app build compiles it, so the file is the thing to ask.
    ///
    /// Everything the two views draw, not only the rows: the heading, the note above them
    /// and the button that closes the card are text on the screen the same as a description
    /// is, and a set derived from the table alone would leave them uncovered.
    @Test("Every label the list draws is written in both languages",
          arguments: ["en", "zh-TW"])
    func everyLabelIsTranslated(language: String) throws {
        let catalogue = try stringCatalogue()
        var keys = ["shortcut.title", "shortcut.note", "common.close"]
        keys += KeyCommand.ShortcutGroup.allCases.map(\.titleKey)
        keys += KeyCommand.shortcuts.map(\.detailKey)
        for key in keys {
            let value = catalogue[key]?[language]
            #expect(value?.isEmpty == false, "\(key) says nothing in \(language)")
        }
    }

    /// The catalogue as `key → language → text`, read from the source of truth itself.
    private func stringCatalogue() throws -> [String: [String: String]] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FediqoUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package
            .appending(path: "Sources/FediqoUI/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        let strings = try #require((json as? [String: Any])?["strings"] as? [String: Any])
        return strings.compactMapValues { entry in
            guard let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] else { return nil }
            return localizations.compactMapValues { unit in
                ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
    }
}

/// The key that puts the list up, and the key that takes it down again.
@Suite("Asking for the list")
struct ShortcutKeyTests {
    /// `?` is shift-slash, and the two keyboard layers disagree about which of the two they
    /// hand over. Both spellings are the same press.
    @Test("? asks for the list, however the keyboard spells it")
    func questionMarkIsRead() {
        #expect(KeyCommand.from("?", modifiers: [], typing: false) == .showShortcuts)
        #expect(KeyCommand.from("?", modifiers: [.shift], typing: false) == .showShortcuts)
        #expect(KeyCommand.from("/", modifiers: [.shift], typing: false) == .showShortcuts)
    }

    @Test("A slash on its own is not an ask for anything")
    func plainSlashIsNotOurs() {
        #expect(KeyCommand.from("/", modifiers: [], typing: false) == nil)
    }

    @Test("While text is being typed, ? is a character the draft is owed",
          arguments: ["?", "/"] as [Character])
    func questionMarkIsDeadWhileTyping(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [.shift], typing: true) == nil)
    }

    /// On iOS nothing is heard at all unless the key is named here, so both spellings have
    /// to be listened for as well as understood.
    @Test("Both spellings are listened for")
    func bothSpellingsAreListenedFor() {
        #expect(KeyCommand.listened.contains("?"))
        #expect(KeyCommand.listened.contains("/"))
    }
}

/// The list as the app holds it: what opens it, and what closes it.
@Suite("Putting the list up and taking it down")
@MainActor
struct ShortcutStateTests {
    @Test("? puts the list up, and Escape takes it down")
    func openAndDismiss() {
        let app = freshApp("shortcuts-open-dismiss")
        #expect(app.showingShortcuts == false)
        #expect(app.perform(.showShortcuts))
        #expect(app.showingShortcuts)
        #expect(app.perform(.dismiss))
        #expect(app.showingShortcuts == false)
    }

    /// One press dismisses one thing, and it dismisses the one in front — the list is drawn
    /// over the composer, so a draft opened before it is still there afterwards.
    @Test("With the list over a draft, Escape closes the list and leaves the draft alone")
    func listIsDismissedBeforeTheComposer() {
        let app = freshApp("shortcuts-before-composer")
        app.setComposing(true)
        app.setShowingShortcuts(true)
        #expect(app.perform(.dismiss))
        #expect(app.showingShortcuts == false)
        #expect(app.composing)
        #expect(app.perform(.dismiss))
        #expect(app.composing == false)
    }

    /// `?` is a letter as far as the focus system is concerned: no control anywhere wants
    /// one, so the press is ours whatever it did.
    @Test("The press is kept rather than handed back")
    func theKeyIsKept() {
        let app = freshApp("shortcuts-key-kept")
        #expect(app.consumes(.showShortcuts, spelledWith: "?"))
    }
}
