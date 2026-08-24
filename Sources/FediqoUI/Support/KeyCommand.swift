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
enum KeyCommand: Equatable {
    case refreshNow
    case cycleRefreshInterval
    case compose
    case dismiss
    case nextTab, previousTab
    case nextPage, previousPage

    /// The command a press means, or nothing when the key is not one of ours.
    ///
    /// `typing` is the whole of why single keys are safe. SwiftUI has no global "a text
    /// field has the keyboard", so the app derives one and every letter asks it here, in one
    /// place, rather than each shortcut remembering to.
    ///
    /// Only the letters ask it. `Escape` and `Tab` are not characters a draft has any use
    /// for — one is how you leave the field, the other is a move — so they are decided
    /// before the gate rather than behind it. For `Tab` that is not a nicety: a `Tab` we say
    /// nothing about is a `Tab` handed back to AppKit, which spends it on window tabs this
    /// app does not have, folding the window into a tab set where the reader cannot find it.
    /// A key we recognise is answered whatever else is going on.
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
        // it is not asked for, and the guard above has already turned it away.
        if character == KeyEquivalent.tab.character {
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
        default: return nil
        }
    }

    /// The keys worth listening for at all. Naming them keeps every other keystroke — the
    /// ones a text field, a menu or the focus system owns — out of our handler entirely.
    static let listened: Set<KeyEquivalent> = [.tab, .escape, "r", "R", "c"]
}
