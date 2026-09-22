import SwiftUI
import Testing
@testable import FediqoUI

@Suite("The attachment keys")
struct AttachmentKeysTests {
    private static let keys: [(Character, DummyCommand)] = [
        ("v", .viewAttachment),
        ("a", .playAttachment),
        ("m", .nextAttachment),
        ("s", .reveal),
    ]

    @Test("v, a, m and s each name one command")
    func fourLettersNameFourCommands() {
        for (character, command) in Self.keys {
            #expect(DummyCommand.from(character) == command)
        }
        #expect(Set(Self.keys.map(\.1)).count == Self.keys.count)
    }

    @Test("The four letters belong to the draft while composing")
    func fourLettersYieldWhileTyping() {
        for (character, _) in Self.keys {
            #expect(DummyCommand.from(character, typing: true) == nil)
        }
    }

    @Test("A focused field owns the four letters")
    func fourLettersYieldToAFocusedField() {
        for (character, _) in Self.keys {
            #expect(DummyCommand.from(character, fieldFocused: true) == nil)
        }
    }

    @Test("The four letters are ours whether or not they moved anything")
    func fourLettersAreConsumed() {
        for (character, _) in Self.keys {
            #expect(DummyCommand.consumes(character, did: false))
        }
    }

    @Test("The keys that worked before still work")
    func theOlderKeysAreUntouched() {
        #expect(DummyCommand.from("\t") == .nextTab)
        #expect(DummyCommand.from("\t", shift: true) == .previousTab)
        #expect(DummyCommand.from("\t", control: true) == .nextPage)
        #expect(DummyCommand.from("\t", shift: true, control: true) == .previousPage)
        #expect(DummyCommand.from("j") == .nextPost)
        #expect(DummyCommand.from("k") == .previousPost)
        #expect(DummyCommand.from(KeyEquivalent.downArrow.character) == .nextPost)
        #expect(DummyCommand.from(KeyEquivalent.upArrow.character) == .previousPost)
        #expect(DummyCommand.from("g") == .goTop)
        #expect(DummyCommand.from("\r") == .expandPost)
        #expect(DummyCommand.from(" ") == .expandPost)
        #expect(DummyCommand.from("c") == .compose)
        #expect(DummyCommand.from("q") == .back)
        #expect(DummyCommand.from("\u{1B}") == .dismiss)
        #expect(DummyCommand.from("?") == .showShortcuts)
        #expect(DummyCommand.from("?", shift: true) == .showShortcuts)
        #expect(DummyCommand.from("r") == .reload)
        #expect(DummyCommand.from("r", command: true) == .replayLanding)
    }

    @Test("The guide names a key cap and a translated line for each of the four")
    func theGuideCarriesTheFourLines() {
        for (character, command) in Self.keys {
            let line = DummyShortcut.all.first { $0.commands == [command] }
            #expect(line?.keys == [String(character)])
            #expect(line?.group == .read)
        }
    }

    @Test("Every guide line names commands that exist, in every language")
    func theGuideCannotLie() {
        #expect(DummyShortcut.all.flatMap(\.commands).count == DummyCommand.allCases.count)
        for language in [DummyLanguage.english, .taiwanese] {
            for line in DummyShortcut.all {
                let key = "shortcut.\(line.name)"
                #expect(L10n.t(key, language: language) != key)
            }
        }
    }
}
