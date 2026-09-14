import SwiftUI

/// A dummy key press. Only the keys that actually work are named here, so the guide cannot lie.
public enum DummyCommand: String, Hashable, Sendable, CaseIterable {
    case compose
    case showShortcuts
    case dismiss

    /// What a press means. Letters are the draft's while composing, except Escape.
    public static func from(_ character: Character, shift: Bool = false, typing: Bool = false)
        -> DummyCommand?
    {
        if character == KeyEquivalent.escape.character {
            return .dismiss
        }
        guard !typing else { return nil }
        if shift, character == "?" || character == "/" { return .showShortcuts }
        switch character {
        case "?": return .showShortcuts
        case "c": return .compose
        default: return nil
        }
    }
}

/// One line of the written-down list. Caps are not translated: a keyboard is labelled as it is.
public struct DummyShortcut: Identifiable, Hashable, Sendable {
    public let keys: [String]
    public let name: String
    public let command: DummyCommand

    public var id: String { name }
    public var detail: String { L10n.t("shortcut.\(name)") }

    public static let all: [DummyShortcut] = [
        DummyShortcut(keys: ["c"], name: "compose", command: .compose),
        DummyShortcut(keys: ["?"], name: "list", command: .showShortcuts),
        DummyShortcut(keys: ["Escape"], name: "dismiss", command: .dismiss),
    ]
}
