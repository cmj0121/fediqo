import SwiftUI
import Testing
import FediqoCore
@testable import FediqoUI

private let escape = KeyEquivalent.escape.character
private let tab = KeyEquivalent.tab.character

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

    @Test("While text is being typed, every single key is dead",
          arguments: ["r", "R", "c"] as [Character])
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
        #expect(app.consumes(.nextTab))
        #expect(app.consumes(.refreshNow))
    }

    @Test("Escape is the exception: with nothing in front of you it was never ours")
    func escapeIsHandedBack() {
        let app = freshApp("escape-handed-back")
        #expect(app.consumes(.dismiss) == false)
        app.setComposing(true)
        #expect(app.consumes(.dismiss))
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
