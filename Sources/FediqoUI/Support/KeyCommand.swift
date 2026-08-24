import SwiftUI

/// The item `steps` along a list from the one you are on, wrapping at both ends.
///
/// One rule for every rotation in the app: the pages in the rail, the tabs inside a page,
/// how often the clock ticks — and, when #3 lands, the posts inside a tab. Wrapping is not
/// a nicety here: a reader holding `Tab` should come back round to where they started
/// rather than stop against the end of a list they cannot see.
///
/// `nil` when the list is empty or does not contain `current`, because a rotation with no
/// starting point has no answer — the caller says what to do about that.
func rotated<T: Equatable>(_ items: [T], from current: T, by steps: Int) -> T? {
    guard let index = items.firstIndex(of: current) else { return nil }
    let count = items.count
    return items[((index + steps) % count + count) % count]
}

/// What a key press means. Written in plain values rather than SwiftUI's `KeyPress`, which
/// has no initialiser: the decision of what a key means is the part worth testing, so it is
/// the part kept away from the event type.
enum KeyCommand: Hashable, CaseIterable {
    case refreshNow
    case cycleRefreshInterval
    case compose
    case dismiss
    case nextTab, previousTab
    case nextPage, previousPage
    case nextPost, previousPost
    case openPost
    case backToTop
    case showShortcuts

    /// The command a press means, or nothing when the key is not one of ours.
    ///
    /// `typing` is the whole of why single keys are safe. SwiftUI has no global "a text
    /// field has the keyboard", so the app derives one and every letter asks it here, in one
    /// place, rather than each shortcut remembering to.
    ///
    /// `Escape` is the one key decided before the gate. It is not a character a draft has any
    /// use for — it is how you leave the field — so it has to answer from inside one.
    ///
    /// `Tab` is not a character a draft wants either, but it is not a way out: it is a move,
    /// and turning the page out from under somebody mid-sentence is not what a press of it
    /// can have meant. So while a draft has the keyboard `Tab` means nothing here. It is
    /// still never handed back — `swallowed(_:typing:)` is where that is said and why — it
    /// simply does not navigate.
    static func from(_ character: Character, modifiers: EventModifiers, typing: Bool) -> KeyCommand? {
        // The ⌘ forms belong to the menu bar, which is where a Mac user reads them. Claiming
        // them here as well would mean two owners for one key.
        guard !modifiers.contains(.command) else { return nil }

        // Escape held down with nothing, and only that. ⌘Escape and ⌃Escape are the system's
        // own presses and a different ask entirely; a panel is closed by the bare key.
        if character == KeyEquivalent.escape.character {
            return modifiers.isEmpty ? .dismiss : nil
        }

        let shift = modifiers.contains(.shift)
        // Tab rotates the pages, ⌃Tab the tabs inside one — the bare key for the bigger
        // move. ⌘Tab is the app switcher and belongs to the system on both platforms, so
        // it is not asked for, and the guard above has already turned it away. A draft has
        // the moves off it entirely, in either form.
        if character == KeyEquivalent.tab.character {
            guard !typing else { return nil }
            return modifiers.contains(.control)
                ? (shift ? .previousTab : .nextTab)
                : (shift ? .previousPage : .nextPage)
        }

        // What is left is letters, and letters are what the gate is for: while a draft has
        // the keyboard they are the draft's.
        guard !typing else { return nil }
        switch character {
        // Shift arrives spelled two ways depending on the platform's keyboard layer — as the
        // capital, or as the small letter with the flag. Both mean the same key.
        case "r": return shift ? .cycleRefreshInterval : .refreshNow
        case "R": return .cycleRefreshInterval
        case "c": return shift ? nil : .compose
        // Moving through the posts, in both spellings: the letters a reader who has met vi
        // reaches for, and the arrows everybody else does. `Return` opens the one you are on
        // and `g` goes back to the top — all of them behind the gate, because in a draft an
        // arrow moves the caret, `Return` starts a paragraph and `j` is a letter.
        case "j", KeyEquivalent.downArrow.character: return shift ? nil : .nextPost
        case "k", KeyEquivalent.upArrow.character: return shift ? nil : .previousPost
        case "g": return shift ? nil : .backToTop
        case KeyEquivalent.return.character: return shift ? nil : .openPost
        // `?` is shift-slash, and which of the two the keyboard layer hands over depends on
        // the layer: AppKit's `charactersIgnoringModifiers` keeps Shift and types the
        // question mark, SwiftUI's `KeyPress` can arrive as the unshifted slash with the flag
        // still on. Both spellings are the same key, the same way `R` and `⇧r` are.
        case "?": return .showShortcuts
        case "/": return shift ? .showShortcuts : nil
        default: return nil
        }
    }

    /// The keys a control on the screen might also want.
    ///
    /// A picker is moved with the arrows and a button is pressed with `Return`, so a press of
    /// one of them that this app had nothing to do with is handed back to the focus system it
    /// belongs to. The letters are shared with nobody: no control anywhere wants a bare `j`,
    /// so a letter is kept whether or not it moved anything — which is what makes holding `j`
    /// at the bottom of a list, or pressing `g` on a page with no posts, silent rather than a
    /// row of beeps.
    ///
    /// `Tab` is deliberately not here. It is the focus key in every other app, and this one
    /// takes it anyway: the screens it moves between have no traversal order worth keeping,
    /// and a rotation that worked on some pages and moved the focus ring on others would be
    /// two keys wearing one cap.
    static let sharedWithControls: Set<Character> = [
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.return.character,
    ]

    /// The keys worth listening for at all. Naming them keeps every other keystroke — the
    /// ones a text field, a menu or the focus system owns — out of our handler entirely.
    static let listened: Set<KeyEquivalent> = [
        .tab, .escape, .return, .upArrow, .downArrow, "r", "R", "c", "j", "k", "g", "?", "/",
    ]

    /// A press we keep although it means nothing — neither a command nor anybody else's key.
    ///
    /// One key, one situation: `Tab` while a draft has the keyboard. There is nothing to
    /// traverse to — the composer is a single field — so handing the press back would buy
    /// the writer no move; what it would buy is AppKit's focus loop taking the keyboard off
    /// the field they are typing into. Swallowing it costs the draft nothing and keeps it.
    static func swallowed(_ character: Character, typing: Bool) -> Bool {
        typing && character == KeyEquivalent.tab.character
    }
}

// MARK: - The list of them

extension KeyCommand {
    /// The three questions the list answers, in the order a reader asks them: where am I
    /// going, what am I doing, and how do I get out of this.
    enum ShortcutGroup: String, CaseIterable, Identifiable {
        case moving, doing, leaving

        var id: String { rawValue }
        var titleKey: String { "shortcut.group.\(rawValue)" }
    }

    /// One line of the written-down list: the caps to press, and what pressing them does.
    ///
    /// A line can stand for more than one command, because `Tab` and `⇧Tab` are one thing to
    /// a reader and two to the app. `commands` is what keeps the list honest — every case of
    /// `KeyCommand` has to appear in exactly one line, and a test says so, so a key added
    /// later and left undescribed fails the build rather than quietly going unmentioned.
    struct Shortcut: Identifiable {
        let group: ShortcutGroup
        /// What is printed on the keys, and deliberately not translated: a keyboard is
        /// labelled in the same characters whatever language the reader speaks.
        let keys: [String]
        let name: String
        let commands: [KeyCommand]

        var id: String { name }
        var detailKey: String { "shortcut.\(name)" }
    }

    /// Every key this app answers, written down once. The `?` overlay and the card in
    /// Settings both draw this — there is one list, and it is the same list the commands
    /// above are decided from.
    static let shortcuts: [Shortcut] = [
        Shortcut(group: .moving, keys: ["Tab", "⇧Tab"], name: "pages",
                 commands: [.nextPage, .previousPage]),
        Shortcut(group: .moving, keys: ["⌃Tab", "⌃⇧Tab"], name: "tabs",
                 commands: [.nextTab, .previousTab]),
        Shortcut(group: .moving, keys: ["j", "k", "↓", "↑"], name: "posts",
                 commands: [.nextPost, .previousPost]),
        Shortcut(group: .moving, keys: ["g"], name: "top", commands: [.backToTop]),
        Shortcut(group: .doing, keys: ["r"], name: "readAgain", commands: [.refreshNow]),
        Shortcut(group: .doing, keys: ["R"], name: "interval", commands: [.cycleRefreshInterval]),
        Shortcut(group: .doing, keys: ["c"], name: "compose", commands: [.compose]),
        Shortcut(group: .doing, keys: ["Return"], name: "open", commands: [.openPost]),
        Shortcut(group: .doing, keys: ["?"], name: "list", commands: [.showShortcuts]),
        Shortcut(group: .leaving, keys: ["Escape"], name: "dismiss", commands: [.dismiss]),
    ]
}
