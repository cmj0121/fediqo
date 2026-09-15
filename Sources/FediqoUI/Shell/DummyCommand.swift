import SwiftUI

/// A dummy key press. Only the keys that actually work are named here, so the guide cannot lie.
public enum DummyCommand: String, Hashable, Sendable, CaseIterable {
    case nextTab
    case previousTab
    case nextPage
    case previousPage
    case nextPost
    case previousPost
    case goTop
    case expandPost
    case viewAttachment
    case playAttachment
    case nextAttachment
    case liftCover
    case back
    case compose
    case showShortcuts
    case dismiss

    /// What a press means. Letters are the draft's while composing, except Escape.
    /// A focused text field owns every key, including Escape.
    public static func from(
        _ character: Character,
        shift: Bool = false,
        control: Bool = false,
        typing: Bool = false,
        fieldFocused: Bool = false
    ) -> DummyCommand? {
        if fieldFocused { return nil }
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
        case "j", KeyEquivalent.downArrow.character: return .nextPost
        case "k", KeyEquivalent.upArrow.character: return .previousPost
        case "g": return .goTop
        case "v": return .viewAttachment
        case "a": return .playAttachment
        case "m": return .nextAttachment
        case "s": return .liftCover
        case KeyEquivalent.return.character, " ": return .expandPost
        case "q": return .back
        default: return nil
        }
    }

    /// Keys the platform may still want. Letters are ours whether or not they moved anything.
    public static let sharedWithControls: Set<Character> = [
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.return.character,
        KeyEquivalent.escape.character,
        KeyEquivalent.tab.character,
        " ",
    ]

    public static func consumes(_ character: Character, did: Bool) -> Bool {
        sharedWithControls.contains(character) ? did : true
    }

    /// Step through a ring. Used by Tab and ⌃Tab so the two rotates cannot drift apart.
    public static func advanced<T: Equatable>(_ items: [T], from current: T, by step: Int) -> T {
        guard let index = items.firstIndex(of: current), !items.isEmpty else { return current }
        let count = items.count
        let offset = ((step % count) + count) % count
        return items[(index + offset) % count]
    }

    /// Step through a list without wrapping. Nil current picks the first (down) or last (up).
    public static func stepped<T: Equatable>(_ items: [T], from current: T?, by step: Int) -> T? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(of: current) else {
            return step >= 0 ? items.first : items.last
        }
        let next = index + step
        guard items.indices.contains(next) else { return current }
        return items[next]
    }
}

/// The three questions the list answers: where am I going, what am I doing, how do I leave.
public enum DummyShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case moving
    case doing
    case leaving

    public var id: String { rawValue }
    var titleKey: String { "shortcut.group.\(rawValue)" }
}

/// One line of the written-down list. Caps are not translated: a keyboard is labelled as it is.
public struct DummyShortcut: Identifiable, Hashable, Sendable {
    public let group: DummyShortcutGroup
    public let keys: [String]
    public let name: String
    public let commands: [DummyCommand]

    public var id: String { name }
    public var detail: String { L10n.t("shortcut.\(name)") }

    public static let all: [DummyShortcut] = [
        DummyShortcut(group: .moving, keys: ["Tab", "⇧Tab"], name: "tabs",
                      commands: [.nextTab, .previousTab]),
        DummyShortcut(group: .moving, keys: ["⌃Tab", "⌃⇧Tab"], name: "pages",
                      commands: [.nextPage, .previousPage]),
        DummyShortcut(group: .moving, keys: ["j", "k", "↓", "↑"], name: "posts",
                      commands: [.nextPost, .previousPost]),
        DummyShortcut(group: .moving, keys: ["g"], name: "top", commands: [.goTop]),
        DummyShortcut(group: .doing, keys: ["Return", "Space"], name: "expand",
                      commands: [.expandPost]),
        DummyShortcut(group: .doing, keys: ["v"], name: "view", commands: [.viewAttachment]),
        DummyShortcut(group: .doing, keys: ["a"], name: "play", commands: [.playAttachment]),
        DummyShortcut(group: .doing, keys: ["m"], name: "turn", commands: [.nextAttachment]),
        DummyShortcut(group: .doing, keys: ["s"], name: "cover", commands: [.liftCover]),
        DummyShortcut(group: .doing, keys: ["c"], name: "compose", commands: [.compose]),
        DummyShortcut(group: .doing, keys: ["?"], name: "list", commands: [.showShortcuts]),
        DummyShortcut(group: .leaving, keys: ["q"], name: "back", commands: [.back]),
        DummyShortcut(group: .leaving, keys: ["Escape"], name: "dismiss", commands: [.dismiss]),
    ]
}
