import SwiftUI
import Testing
import FediqoCore
@testable import FediqoUI

/// What a key press means, decided before anything is done about it.
@Suite("What a key means")
struct KeyCommandMeaningTests {
    @Test("The single keys, with nothing held down", arguments: [
        (Character("r"), KeyCommand.refreshNow), (Character("c"), .compose),
    ] as [(Character, KeyCommand)])
    func plainKeys(character: Character, command: KeyCommand) {
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == command)
    }

    @Test("Shift and `r` cycles the interval, however the platform spells it")
    func shiftedR() {
        #expect(KeyCommand.from("R", modifiers: [.shift], typing: false) == .cycleRefreshInterval)
        #expect(KeyCommand.from("r", modifiers: [.shift], typing: false) == .cycleRefreshInterval)
        #expect(KeyCommand.from("R", modifiers: [], typing: false) == .cycleRefreshInterval)
    }

    @Test("Tab moves between pages; holding Control moves between the tabs inside one")
    func tabAndControlTab() {
        #expect(KeyCommand.from(tab, modifiers: [], typing: false) == .nextPage)
        #expect(KeyCommand.from(tab, modifiers: [.shift], typing: false) == .previousPage)
        #expect(KeyCommand.from(tab, modifiers: [.control], typing: false) == .nextTab)
        #expect(KeyCommand.from(tab, modifiers: [.control, .shift], typing: false) == .previousTab)
    }

    /// Both spellings of the same four moves: the letters for a reader who has met vi, the
    /// arrows for everybody else.
    @Test("Moving through the posts, in letters and in arrows", arguments: [
        (Character("j"), KeyCommand.nextPost), (down, .nextPost),
        (Character("k"), .previousPost), (up, .previousPost),
        (Character("g"), .backToTop), (enter, .openPost),
    ] as [(Character, KeyCommand)])
    func postKeys(character: Character, command: KeyCommand) {
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == command)
    }

    /// ⇧↓ selects text and `J` is a letter this app has no use for: neither is the small
    /// step the bare key asks for, so neither is answered.
    @Test("Held with Shift, none of the post keys are ours",
          arguments: ["j", "k", "g", enter, up, down] as [Character])
    func shiftedPostKeys(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [.shift], typing: false) == nil)
    }

    @Test("A key that is not one of ours means nothing", arguments: ["x", "1", "C", " "] as [Character])
    func unknownKeys(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == nil)
    }

    @Test("The ⌘ forms belong to the menu bar, so nothing here claims them",
          arguments: ["r", "n", "1"] as [Character])
    func commandFormsAreLeftAlone(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [.command], typing: false) == nil)
    }

    // MARK: - The typing signal

    /// The arrows and `Return` are in here for a plainer reason than the letters: in a draft
    /// an arrow moves the caret and `Return` starts a paragraph. A composer that jumped down
    /// the timeline every time somebody finished a line would be unusable.
    @Test("While text is being typed, every single key is dead",
          arguments: ["r", "R", "c", "j", "k", "g", enter, up, down] as [Character])
    func singleKeysAreDeadWhileTyping(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [], typing: true) == nil)
    }

    /// A Tab we decline is a Tab AppKit takes instead, and AppKit spends it on window tabs
    /// this app does not have — the window is folded into a tab set and the reader has lost
    /// it. Nothing in a draft wants a Tab, so nothing is given up by answering it.
    @Test("Tab is still a move while typing — it is not a letter the draft is waiting for")
    func tabSurvivesTyping() {
        #expect(KeyCommand.from(tab, modifiers: [], typing: true) == .nextPage)
        #expect(KeyCommand.from(tab, modifiers: [.shift], typing: true) == .previousPage)
        #expect(KeyCommand.from(tab, modifiers: [.control], typing: true) == .nextTab)
        #expect(KeyCommand.from(tab, modifiers: [.control, .shift], typing: true) == .previousTab)
    }

    @Test("Escape is the one key that survives typing: it is how you leave what you are in")
    func escapeSurvivesTyping() {
        #expect(KeyCommand.from(escape, modifiers: [], typing: true) == .dismiss)
        #expect(KeyCommand.from(escape, modifiers: [], typing: false) == .dismiss)
    }

    /// ⌘Escape and ⌃Escape are the system's presses, not ours. A panel is closed by the bare
    /// key, and anything held with it makes a different ask that we hand straight back.
    @Test("Escape held with anything is somebody else's press",
          arguments: [EventModifiers.command, .control, .shift, [.control, .shift]])
    func escapeWithModifiers(modifiers: EventModifiers) {
        #expect(KeyCommand.from(escape, modifiers: modifiers, typing: false) == nil)
        #expect(KeyCommand.from(escape, modifiers: modifiers, typing: true) == nil)
    }
}

/// The rule every rotation in the app shares.
@Suite("Going round a list")
struct RotationTests {
    @Test("Forwards from the last is the first, backwards from the first is the last")
    func wrapsBothWays() {
        let items = ["a", "b", "c"]
        #expect(rotated(items, from: "a", by: 1) == "b")
        #expect(rotated(items, from: "c", by: 1) == "a")
        #expect(rotated(items, from: "a", by: -1) == "c")
        #expect(rotated(items, from: "c", by: -1) == "b")
    }

    @Test("A list with nowhere to start has no answer")
    func nowhereToStart() {
        #expect(rotated(["a", "b"], from: "z", by: 1) == nil)
        #expect(rotated([String](), from: "a", by: 1) == nil)
    }
}

/// The commands themselves, done to a real app.
@Suite("Steering the app from the keyboard")
@MainActor
struct CommandTests {
    @Test("Tab goes round the four pages and comes back to where it started")
    func pagesRotateForwards() {
        let app = freshApp("pages-forwards")
        app.railItem = .timeline
        for page in [RailItem.kept, .statistics, .settings, .timeline] {
            #expect(app.perform(.nextPage))
            #expect(app.railItem == page)
        }
    }

    @Test("⇧Tab goes the other way, and wraps at the beginning")
    func pagesRotateBackwards() {
        let app = freshApp("pages-backwards")
        app.railItem = .timeline
        for page in [RailItem.settings, .statistics, .kept, .timeline] {
            #expect(app.perform(.previousPage))
            #expect(app.railItem == page)
        }
    }

    @Test("⌃Tab goes round the tabs of the Timeline page, both ways, wrapping at both ends")
    func tabsRotate() {
        let app = freshApp("tabs-rotate")
        app.railItem = .timeline
        app.feedTab = .timeline
        #expect(app.perform(.nextTab))
        #expect(app.feedTab == .trending)
        #expect(app.perform(.nextTab))
        #expect(app.feedTab == .timeline)
        #expect(app.perform(.previousTab))
        #expect(app.feedTab == .trending)
        #expect(app.perform(.previousTab))
        #expect(app.feedTab == .timeline)
    }

    /// The one place the answer matters: a `false` here is the shell letting the press
    /// through rather than swallowing a key that did nothing.
    @Test("On a page with no tabs, ⌃Tab does nothing and says so",
          arguments: [RailItem.kept, .statistics, .settings])
    func tabDoesNothingWithoutTabs(page: RailItem) {
        let app = freshApp("tab-without-tabs")
        app.railItem = page
        let was = app.feedTab
        #expect(app.perform(.nextTab) == false)
        #expect(app.perform(.previousTab) == false)
        #expect(app.feedTab == was)
    }

    @Test("R cycles Off → 15s → 30s → 60s → 5min → Off")
    func refreshIntervalCycles() {
        let app = freshApp("interval-cycle")
        app.preferences.refreshInterval = .off
        for interval in [RefreshInterval.seconds15, .seconds30, .seconds60, .seconds300, .off] {
            #expect(app.perform(.cycleRefreshInterval))
            #expect(app.preferences.refreshInterval == interval)
        }
    }

    @Test("c opens the composer and Escape closes it, one press for one dismissal")
    func composeAndDismiss() {
        let app = freshApp("compose-dismiss")
        #expect(app.composing == false)
        #expect(app.perform(.compose))
        #expect(app.composing)
        #expect(app.perform(.dismiss))
        #expect(app.composing == false)
    }

    @Test("With nothing in front of you, Escape does nothing at all — it never navigates")
    func escapeWithNothingInFront() {
        let app = freshApp("escape-nothing")
        app.railItem = .statistics
        #expect(app.perform(.dismiss) == false)
        #expect(app.railItem == .statistics)
    }

    @Test("Reading again asks for nothing on a page that has no feed",
          arguments: [RailItem.kept, .statistics, .settings])
    func refreshNeedsAFeed(page: RailItem) {
        let app = freshApp("refresh-needs-a-feed")
        app.railItem = page
        #expect(app.perform(.refreshNow) == false)
    }

    /// Handing a key we understand back to the platform is worse than swallowing it: AppKit
    /// spends ⌃Tab on window tabs this app does not have.
    @Test("A key we understand is ours even when it had nothing to do",
          arguments: [RailItem.kept, .statistics, .settings])
    func recognisedKeysAreKept(page: RailItem) {
        let app = freshApp("recognised-keys-kept")
        app.railItem = page
        #expect(app.perform(.nextTab) == false)
        #expect(app.consumes(.nextTab, spelledWith: tab))
        #expect(app.consumes(.refreshNow, spelledWith: "r"))
    }

    @Test("Escape is the exception: with nothing in front of you it was never ours")
    func escapeIsHandedBack() {
        let app = freshApp("escape-handed-back")
        #expect(app.consumes(.dismiss, spelledWith: escape) == false)
        app.setComposing(true)
        #expect(app.consumes(.dismiss, spelledWith: escape))
        #expect(app.composing == false)
    }

    // MARK: - The typing signal

    @Test("The editor says when it has the keyboard, and the app remembers")
    func typingIsRemembered() {
        let app = freshApp("typing-remembered")
        #expect(app.isTyping == false)
        app.setTyping(true)
        #expect(app.isTyping)
        app.setTyping(false)
        #expect(app.isTyping == false)
    }

    /// The editor cannot report losing a keyboard it is no longer there to hold, so closing
    /// the panel is what clears the signal. Without this every single key stays dead.
    @Test("Closing the composer puts the keyboard back, however it was closed")
    func closingTheComposerClearsTheSignal() {
        let app = freshApp("typing-cleared")
        app.setComposing(true)
        app.setTyping(true)
        app.setComposing(false)
        #expect(app.isTyping == false)
    }
}

#if os(macOS)
import AppKit

/// Which key AppKit says was pressed, read the way the commands are written.
@Suite("Which key was pressed")
struct KeyCodeTests {
    /// Read by number rather than by what they typed. The character handed in here is the
    /// one the numeric pad's Enter really types — a control character no command is written
    /// in — so a table that fell through to it would be visible as a wrong answer.
    @Test("The keys AppKit numbers are read as the key, not as what they typed", arguments: [
        (UInt16(48), KeyEquivalent.tab.character),
        (UInt16(53), KeyEquivalent.escape.character),
        (UInt16(126), KeyEquivalent.upArrow.character),
        (UInt16(125), KeyEquivalent.downArrow.character),
        (UInt16(76), KeyEquivalent.return.character),
    ] as [(UInt16, Character)])
    func readByNumber(keyCode: UInt16, expected: Character) {
        #expect(shellKey(keyCode: keyCode, typed: "\u{3}") == expected)
    }

    /// Every other key is what it typed, and a key that typed nothing at all — a bare
    /// modifier — is nothing to answer.
    @Test("Everything else is read as what it typed")
    func readByWhatItTyped() {
        #expect(shellKey(keyCode: 38, typed: "j") == "j")
        #expect(shellKey(keyCode: 56, typed: nil) == nil)
    }

    /// The whole reason the pad's Enter is in the table. It types U+0003 where the Return
    /// above it types U+000D: one key to the reader, and read by what it typed it would be a
    /// key that opened nothing.
    @Test("The numeric pad's Enter opens a post, the same as the Return above it")
    func keypadEnterOpensAPost() throws {
        let character = try #require(shellKey(keyCode: 76, typed: "\u{3}"))
        #expect(character == enter)
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == .openPost)
    }
}

/// The one place AppKit's spelling of a held key meets SwiftUI's. Everything above is
/// written in `EventModifiers`, and on a Mac every press arrives in the other spelling, so
/// this crossing is on the path of every single key in the app.
@Suite("Which keys are being held")
struct ModifierFlagTests {
    @Test("The three the app steers by cross over, alone and together", arguments: [
        (NSEvent.ModifierFlags(), EventModifiers()),
        (NSEvent.ModifierFlags.shift, EventModifiers.shift),
        (NSEvent.ModifierFlags.control, EventModifiers.control),
        (NSEvent.ModifierFlags.command, EventModifiers.command),
        (NSEvent.ModifierFlags([.control, .shift]), EventModifiers([.control, .shift])),
        (NSEvent.ModifierFlags([.command, .control, .shift]),
         EventModifiers([.command, .control, .shift])),
    ] as [(NSEvent.ModifierFlags, EventModifiers)])
    func crossesOver(flags: NSEvent.ModifierFlags, expected: EventModifiers) {
        #expect(flags.eventModifiers == expected)
    }

    /// Option, caps lock, the function key, the numeric pad: AppKit tracks them all and no
    /// command in this app is written in any of them. One held alongside a key we do read
    /// must not stop it being read.
    @Test("Everything else AppKit tracks is dropped, and drops nothing with it", arguments: [
        NSEvent.ModifierFlags.option, .capsLock, .function, .numericPad, .help,
    ])
    func dropsTheRest(flag: NSEvent.ModifierFlags) {
        #expect(flag.eventModifiers.isEmpty)
        #expect(NSEvent.ModifierFlags([flag, .control]).eventModifiers == .control)
    }
}
#endif
