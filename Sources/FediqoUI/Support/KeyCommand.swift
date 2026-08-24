import SwiftUI

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
    /// still never handed back — `handles(_:modifiers:typing:perform:)` is where that is said
    /// and why — it simply does not navigate.
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

        // The two keys held with Shift, and nothing else is: `⇧j` is not the small step `j`
        // asks for, `⇧↓` selects text, and `⇧c` is a letter this app has no use for. Asked
        // first so that the table below has no branch in it at all.
        //
        // Both arrive spelled two ways, depending on which keyboard layer handed the press
        // over: as the shifted character, or as the unshifted one with the flag still on.
        // AppKit's `charactersIgnoringModifiers` types the capital and the question mark;
        // SwiftUI's `KeyPress` can give the small letter and the slash.
        if shift {
            switch character {
            case "r", "R": return .cycleRefreshInterval
            case "/", "?": return .showShortcuts
            default: return nil
            }
        }

        switch character {
        case "r": return .refreshNow
        case "R": return .cycleRefreshInterval
        case "c": return .compose
        // Moving through the posts, in both spellings: the letters a reader who has met vi
        // reaches for, and the arrows everybody else does. `Return` opens the one you are on
        // and `g` goes back to the top — all of them behind the gate, because in a draft an
        // arrow moves the caret, `Return` starts a paragraph and `j` is a letter.
        case "j", KeyEquivalent.downArrow.character: return .nextPost
        case "k", KeyEquivalent.upArrow.character: return .previousPost
        case "g": return .backToTop
        case KeyEquivalent.return.character: return .openPost
        case "?": return .showShortcuts
        // A slash on its own asks for nothing. It is here only as the other half of `?`.
        default: return nil
        }
    }

    /// The keys the platform may still want.
    ///
    /// A picker is moved with the arrows and a button is pressed with `Return`, so a press of
    /// one of them that this app had nothing to do with is handed back to the focus system it
    /// belongs to. `Escape` is here for the same reason and a plainer one: a press that
    /// dismissed nothing was never a dismissal, and the platform has its own uses for the key.
    ///
    /// The letters are shared with nobody: no control anywhere wants a bare `j`, so a letter
    /// is kept whether or not it moved anything — which is what makes holding `j` at the
    /// bottom of a list, or pressing `g` on a page with no posts, silent rather than a row of
    /// beeps.
    ///
    /// `Tab` is deliberately not here. It is the focus key in every other app, and this one
    /// takes it anyway: the screens it moves between have no traversal order worth keeping,
    /// and a rotation that worked on some pages and moved the focus ring on others would be
    /// two keys wearing one cap.
    static let sharedWithControls: Set<Character> = [
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.return.character,
        KeyEquivalent.escape.character,
    ]

    /// The keys worth listening for at all. Naming them keeps every other keystroke — the
    /// ones a text field, a menu or the focus system owns — out of our handler entirely.
    static let listened: Set<KeyEquivalent> = [
        .tab, .escape, .return, .upArrow, .downArrow, "r", "R", "c", "j", "k", "g", "?", "/",
    ]

    /// The same list, in the spelling a press arrives in, so that a key nobody listens for
    /// can be turned away by the character it typed.
    static let listenedCharacters = Set(listened.map(\.character))

    /// The whole of what a key press does: what it means, what it did, and whether the app
    /// keeps it. Both listeners — SwiftUI's on iOS, AppKit's on macOS — ask this and nothing
    /// else, so the two cannot come to answer the same press differently.
    ///
    /// `perform` is what the app does about it, which is the app's business and not this
    /// file's: everything decided here is decided from the press alone.
    ///
    /// One press means nothing and is kept anyway: `Tab` while a draft has the keyboard.
    /// There is nothing to traverse to — the composer is a single field — so handing it back
    /// would buy the writer no move; what it would buy is AppKit's focus loop taking the
    /// keyboard off the field they are typing into.
    static func handles(_ character: Character, modifiers: EventModifiers, typing: Bool,
                        perform: (KeyCommand) -> Bool) -> Bool {
        guard let command = from(character, modifiers: modifiers, typing: typing) else {
            return typing && character == KeyEquivalent.tab.character
        }
        return consumes(spelledWith: character, did: perform(command))
    }

    /// Whether a press we understood is ours to keep, given whether it had anything to do.
    ///
    /// A key we understand is ours whether or not it did anything. Handing one back because
    /// it changed nothing is worse than swallowing it: `⌃Tab` on a page with no tabs would go
    /// on to the focus system, which has its own use for the key and would move the ring
    /// somewhere the reader did not ask to be — a press that meant one thing on the Timeline
    /// meaning another on Settings.
    ///
    /// The exception is a key the platform might also want, which goes back when there was
    /// nothing here to do with it: `↑`, `↓` and `Return` are how every screen in the app is
    /// steered by somebody not using a pointer, and swallowing them on a page with no
    /// timeline would leave the pickers in Settings unmovable and its buttons unpressable —
    /// and `Escape` with nothing in front of you was never ours at all.
    ///
    /// Which key was pressed is the whole of what decides it, never which command it meant —
    /// `j` and `↓` ask for the same move and are not the same key, which is why no command is
    /// named here. A letter is ours alone, so it is kept whatever it did; handing it back
    /// would have AppKit find nothing that wanted it and beep, once for every press of `j`
    /// held at the bottom of a list.
    static func consumes(spelledWith key: Character, did: Bool) -> Bool {
        sharedWithControls.contains(key) ? did : true
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

    /// The same lines, filed under the question they answer. Worked out once rather than by
    /// walking the table again for each of the three headings, every time the list is drawn.
    static let byGroup = Dictionary(grouping: shortcuts, by: \.group)
}
