import SwiftUI

/// A dummy key press. Only the keys that actually work are named here, so the guide cannot lie.
public enum DummyCommand: String, Hashable, Sendable, CaseIterable {
    case nextTab
    case previousTab
    case nextPage
    case previousPage
    case compose
    case showShortcuts
    case dismiss

    /// What a press means. Letters are the draft's while composing, except Escape.
    public static func from(
        _ character: Character,
        shift: Bool = false,
        control: Bool = false,
        typing: Bool = false
    ) -> DummyCommand? {
        if character == KeyEquivalent.escape.character {
            return .dismiss
        }
        if character == KeyEquivalent.tab.character {
            if typing { return nil }
            if control { return shift ? .previousPage : .nextPage }
            return shift ? .previousTab : .nextTab
        }
        guard !typing else { return nil }
        if shift, character == "?" || character == "/" { return .showShortcuts }
        switch character {
        case "?": return .showShortcuts
        case "c": return .compose
        default: return nil
        }
    }

    /// Step through a ring. Used by Tab and ⌃Tab so the two rotates cannot drift apart.
    public static func advanced<T: Equatable>(_ items: [T], from current: T, by step: Int) -> T {
        guard let index = items.firstIndex(of: current), !items.isEmpty else { return current }
        let count = items.count
        let offset = ((step % count) + count) % count
        return items[(index + offset) % count]
    }
}

/// One line of the written-down list. Caps are not translated: a keyboard is labelled as it is.
public struct DummyShortcut: Identifiable, Hashable, Sendable {
    public let keys: [String]
    public let name: String
    public let commands: [DummyCommand]

    public var id: String { name }
    public var detail: String { L10n.t("shortcut.\(name)") }

    public static let all: [DummyShortcut] = [
        DummyShortcut(keys: ["Tab", "⇧Tab"], name: "tabs", commands: [.nextTab, .previousTab]),
        DummyShortcut(keys: ["⌃Tab", "⌃⇧Tab"], name: "pages", commands: [.nextPage, .previousPage]),
        DummyShortcut(keys: ["c"], name: "compose", commands: [.compose]),
        DummyShortcut(keys: ["?"], name: "list", commands: [.showShortcuts]),
        DummyShortcut(keys: ["Escape"], name: "dismiss", commands: [.dismiss]),
    ]
}
