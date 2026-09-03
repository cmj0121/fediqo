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
    /// Open the whole post, and the conversation around it, over the timeline.
    case expandPost
    /// Hand the post to the server it came from — the browser, which is what `Return` used
    /// to do before opening the post here became a thing this app could do.
    case openInBrowser
    /// Open what is attached to the post the reader is on, over the app.
    case openMedia
    /// Give the opened picture the whole screen, where the platform has one to give.
    case fullScreen
    /// Turn the deck of attachments on the post the reader is on.
    case rotateMedia
    /// Play what is on top of that deck, or stop whatever is playing.
    case playMedia
    /// Lift what the author covered on the post the reader is on, or put it back. One key for
    /// the words behind their line and the media behind its blur, because they are one act.
    case toggleCover
    /// The four things that can be done *to* the post the reader is on, rather than with it.
    ///
    /// Three of them are a server's answer and one of them is this device's, and the keys do
    /// not say which is which — the row already does, by drawing the first three in a group
    /// that carries other people's counts and the last two in one that carries nobody's. What
    /// a key is for is the reader who is going down a timeline with one hand and does not want
    /// to reach for a pointer to keep a post they liked.
    ///
    /// Each is a switch and not a command: pressed again, it takes the mark back off.
    case favouritePost
    case boostPost
    case bookmarkPost
    case keepPost
    /// Open the page of whoever wrote the post the reader is on.
    ///
    /// The name in a row can be pressed and there was no key for it, so a reader working from
    /// the keyboard had to reach for the pointer to do the one thing this app is otherwise
    /// built to do without one (#96).
    ///
    /// On a boost it opens whoever wrote the post, not whoever boosted it. The boost line
    /// already names the one and the post names the other, and the key belongs to the post.
    case openAuthor
    /// Take the handle the composer is offering (#98).
    ///
    /// The one thing a key means while a draft has the keyboard, besides leaving. `Tab` is the
    /// completion key everywhere a completion exists, it is not a character a draft wants, and
    /// mid-draft it was already being kept and spent on nothing.
    case completeMention
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
    /// and moving somebody off what they are writing mid-sentence is not what a press of it
    /// can have meant. So while a draft has the keyboard `Tab` means nothing here. Mid-draft
    /// it is still never handed back — `handles(_:modifiers:typing:perform:)` is where that
    /// is said and why — it simply does not navigate. With no draft open it is an ordinary
    /// key of the shared kind, kept where it moved something and given back where it did not.
    static func from(_ character: Character, modifiers: EventModifiers, typing: Bool,
                     offering: Bool = false) -> KeyCommand? {
        // The ⌘ forms belong to the menu bar, which is where a Mac user reads them. Claiming
        // them here as well would mean two owners for one key.
        guard !modifiers.contains(.command) else { return nil }

        // Escape held down with nothing, and only that. ⌘Escape and ⌃Escape are the system's
        // own presses and a different ask entirely; a panel is closed by the bare key.
        if character == KeyEquivalent.escape.character {
            return modifiers.isEmpty ? .dismiss : nil
        }

        let shift = modifiers.contains(.shift)
        // Tab moves between the tabs inside a page, ⌃Tab rotates the pages — the bare key
        // for the smaller move, which is what leaves it free to go back to the focus system
        // on the three pages that have no tabs. ⌘Tab is the app switcher and belongs to the
        // system on both platforms, so it is not asked for, and the guard above has already
        // turned it away. A draft has the moves off it entirely, in either form.
        if character == KeyEquivalent.tab.character {
            // The one exception to the gate below, and it is not a move: with a handle being
            // offered, `Tab` finishes the word somebody is in the middle of. It is what the key
            // does in every field that completes anything, and mid-draft it was being swallowed
            // and spent on nothing anyway.
            if typing { return offering ? .completeMention : nil }
            return modifiers.contains(.control)
                ? (shift ? .previousPage : .nextPage)
                : (shift ? .previousTab : .nextTab)
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
        // `Return`, `Space` and a click are one ask: show me the post the ring is on. `Space`
        // no longer pages the list, and that is deliberate — a page is not a unit here, cards
        // are different heights and `j`/`k` already step by post, which is the finer move.
        // Inside an opened conversation the ring is the conversation's, so the same press
        // opens the reply it is on, over the thread being read: one meaning, wherever the
        // reader is.
        case KeyEquivalent.return.character, " ": return .expandPost
        case "o": return .openInBrowser
        // `v` for the look at it, `f` for the screen it takes. `f` means nothing until
        // something is open — it is the second press, not a first one.
        case "v": return .openMedia
        case "f": return .fullScreen
        case "m": return .rotateMedia
        case "p": return .playMedia
        case "s": return .toggleCover
        // What is done to the post itself. `f` would have been favourite's letter in any
        // other app and it is already the screen a picture takes, so the mark takes the
        // letter of what pressing it means — `l` for liking it. `b` is boost where a reader
        // coming from Mastodon's own web client already expects it, which leaves bookmark
        // `d`. And `a` is the archive box's own letter, on the one of the four that tells
        // nobody: keeping a post is this device's business and no server's.
        case "l": return .favouritePost
        case "b": return .boostPost
        case "d": return .bookmarkPost
        case "a": return .keepPost
        // `u` for the person, `p` having gone to the media long ago. Every other letter near
        // the meaning was taken: `a` keeps a post and `p` plays one.
        case "u": return .openAuthor
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
    /// `Tab` is here for the plainest version of the same reason: it is the focus key in
    /// every other app, and on three of the four pages this one has nothing to spend it on.
    /// Only the Timeline has tabs, so only there does a press of it move anything; on Kept,
    /// Statistics and Settings it goes back to AppKit, and the pickers and buttons in
    /// Settings stay reachable by somebody not using a pointer.
    ///
    /// Handing one back is safe, which it was not under the other assignment. `⌃Tab` is the
    /// press AppKit spends on window tabs, and `⌃Tab` now rotates the pages — there are
    /// always four, so it always moved something and is always kept; AppKit never sees it.
    /// And `ShellKeys` sets `NSWindow.allowsAutomaticWindowTabbing = false` when the shell
    /// appears, so there is no tab set for any press to fold this window into anyway.
    static let sharedWithControls: Set<Character> = [
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.return.character,
        KeyEquivalent.escape.character,
        KeyEquivalent.tab.character,
    ]

    /// The keys worth listening for at all. Naming them keeps every other keystroke — the
    /// ones a text field, a menu or the focus system owns — out of our handler entirely.
    static let listened: Set<KeyEquivalent> = [
        .tab, .escape, .return, .upArrow, .downArrow, .space,
        "r", "R", "c", "j", "k", "g", "m", "o", "p", "s", "v", "f", "?", "/",
        "l", "b", "d", "a", "u",
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
                        offering: Bool = false, perform: (KeyCommand) -> Bool) -> Bool {
        guard let command = from(character, modifiers: modifiers, typing: typing,
                                 offering: offering) else {
            return typing && character == KeyEquivalent.tab.character
        }
        return consumes(spelledWith: character, did: perform(command))
    }

    /// Whether a press we understood is ours to keep, given whether it had anything to do.
    ///
    /// A key that is ours alone is ours whether or not it did anything. Handing one back
    /// because it changed nothing is worse than swallowing it: AppKit would find nobody who
    /// wanted a bare `r` and beep, on a page where the app itself says the key does nothing.
    ///
    /// The exception is a key the platform might also want, which goes back when there was
    /// nothing here to do with it: `↑`, `↓` and `Return` are how every screen in the app is
    /// steered by somebody not using a pointer, and swallowing them on a page with no
    /// timeline would leave the pickers in Settings unmovable and its buttons unpressable.
    /// `Escape` with nothing in front of you was never ours at all, and `Tab` on a page with
    /// no tabs to move between is simply the focus key, doing what it does everywhere else.
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

    /// Every key this app answers, written down once. The `?` overlay draws this — there
    /// is one list, and it is the same list the commands above are decided from.
    static let shortcuts: [Shortcut] = [
        Shortcut(group: .moving, keys: ["⌃Tab", "⌃⇧Tab"], name: "pages",
                 commands: [.nextPage, .previousPage]),
        Shortcut(group: .moving, keys: ["Tab", "⇧Tab"], name: "tabs",
                 commands: [.nextTab, .previousTab]),
        Shortcut(group: .moving, keys: ["j", "k", "↓", "↑"], name: "posts",
                 commands: [.nextPost, .previousPost]),
        Shortcut(group: .moving, keys: ["g"], name: "top", commands: [.backToTop]),
        // Among the moves rather than the doings: it takes the reader somewhere, and what
        // they do when they get there is that page's business.
        Shortcut(group: .moving, keys: ["u"], name: "author", commands: [.openAuthor]),
        Shortcut(group: .doing, keys: ["r"], name: "readAgain", commands: [.refreshNow]),
        Shortcut(group: .doing, keys: ["R"], name: "interval", commands: [.cycleRefreshInterval]),
        Shortcut(group: .doing, keys: ["c"], name: "compose", commands: [.compose]),
        Shortcut(group: .doing, keys: ["Tab"], name: "complete", commands: [.completeMention]),
        Shortcut(group: .doing, keys: ["Return", "Space"], name: "expand", commands: [.expandPost]),
        Shortcut(group: .doing, keys: ["o"], name: "browser", commands: [.openInBrowser]),
        Shortcut(group: .doing, keys: ["l"], name: "favourite", commands: [.favouritePost]),
        Shortcut(group: .doing, keys: ["b"], name: "boost", commands: [.boostPost]),
        Shortcut(group: .doing, keys: ["d"], name: "bookmark", commands: [.bookmarkPost]),
        Shortcut(group: .doing, keys: ["a"], name: "keep", commands: [.keepPost]),
        Shortcut(group: .doing, keys: ["v"], name: "viewMedia", commands: [.openMedia]),
        Shortcut(group: .doing, keys: ["f"], name: "fullScreen", commands: [.fullScreen]),
        Shortcut(group: .doing, keys: ["m"], name: "media", commands: [.rotateMedia]),
        Shortcut(group: .doing, keys: ["p"], name: "play", commands: [.playMedia]),
        Shortcut(group: .doing, keys: ["s"], name: "cover", commands: [.toggleCover]),
        Shortcut(group: .doing, keys: ["?"], name: "list", commands: [.showShortcuts]),
        Shortcut(group: .leaving, keys: ["Escape"], name: "dismiss", commands: [.dismiss]),
    ]

    /// The same lines, filed under the question they answer. Worked out once rather than by
    /// walking the table again for each of the three headings, every time the list is drawn.
    static let byGroup = Dictionary(grouping: shortcuts, by: \.group)
}
