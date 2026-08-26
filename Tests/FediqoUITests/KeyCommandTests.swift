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

    @Test("Tab moves between the tabs inside a page; holding Control rotates the pages")
    func tabAndControlTab() {
        #expect(KeyCommand.from(tab, modifiers: [], typing: false) == .nextTab)
        #expect(KeyCommand.from(tab, modifiers: [.shift], typing: false) == .previousTab)
        #expect(KeyCommand.from(tab, modifiers: [.control], typing: false) == .nextPage)
        #expect(KeyCommand.from(tab, modifiers: [.control, .shift], typing: false) == .previousPage)
    }

    /// Both spellings of the same four moves: the letters for a reader who has met vi, the
    /// arrows for everybody else.
    @Test("Moving through the posts, in letters and in arrows", arguments: [
        (Character("j"), KeyCommand.nextPost), (down, .nextPost),
        (Character("k"), .previousPost), (up, .previousPost),
        (Character("g"), .backToTop), (enter, .expandPost),
    ] as [(Character, KeyCommand)])
    func postKeys(character: Character, command: KeyCommand) {
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == command)
    }

    /// ⇧↓ selects text and `J` is a letter this app has no use for: neither is the small
    /// step the bare key asks for, so neither is answered.
    /// `Space` asks for the same thing `Return` does, and it is the one key here that used to
    /// belong to the scroll view. It is taken knowingly: a page is not a unit in a list of
    /// cards of different heights, and `j`/`k` already step by post — which is the finer move.
    /// Inside the opened post there is no ring and `Space` scrolls again.
    @Test("Space shows the whole post, the same as Return")
    func spaceExpands() {
        #expect(KeyCommand.from(" ", modifiers: [], typing: false) == .expandPost)
        // And in a draft it is a space, like every other letter.
        #expect(KeyCommand.from(" ", modifiers: [], typing: true) == nil)
    }

    @Test("Held with Shift, none of the post keys are ours",
          arguments: ["j", "k", "g", enter, up, down] as [Character])
    func shiftedPostKeys(character: Character) {
        #expect(KeyCommand.from(character, modifiers: [.shift], typing: false) == nil)
    }

    @Test("A key that is not one of ours means nothing", arguments: ["x", "1", "C", ";"] as [Character])
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

    /// Moving somebody off what they are writing in the middle of a sentence is not what a
    /// press of Tab can have meant, so mid-draft it means nothing — in either form.
    @Test("While text is being typed, Tab is not a move either",
          arguments: [EventModifiers(), .shift, .control, [.control, .shift]])
    func tabIsDeadWhileTyping(modifiers: EventModifiers) {
        #expect(KeyCommand.from(tab, modifiers: modifiers, typing: true) == nil)
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

    /// Every key that is answered has to be a key that is heard: on iOS nothing reaches the
    /// app at all unless it is named in `listened`, and on macOS the monitor turns away
    /// anything that is not. A letter added to one and forgotten in the other is a shortcut
    /// that is silently dead, which is why this asks rather than trusting two lists to agree.
    @Test("Every key the app answers for is a key it listens for")
    func everyAnsweredKeyIsListenedFor() {
        let printable = (UInt8(32)...UInt8(126)).map { Character(UnicodeScalar($0)) }
        let held: [EventModifiers] = [[], .shift, .control, [.control, .shift]]
        for character in printable + [escape, tab, enter, up, down] {
            for modifiers in held where KeyCommand.from(character, modifiers: modifiers, typing: false) != nil {
                #expect(KeyCommand.listenedCharacters.contains(character),
                        "\(character) is answered but not listened for")
            }
        }
    }
}

/// Whether a press is ours to keep, which is decided from the key and from whether there was
/// anything to do with it — never from what the app happens to be showing. So the app is
/// stood in for here by the only thing this asks of it: what it did.
@Suite("Whether a press is ours")
struct KeyOwnershipTests {
    private func pressing(_ character: Character, modifiers: EventModifiers = [],
                          typing: Bool = false, did: Bool) -> Bool {
        KeyCommand.handles(character, modifiers: modifiers, typing: typing) { _ in did }
    }

    /// No control anywhere wants a bare `j`, so a letter is kept whether or not it moved
    /// anything — which is what makes holding `j` at the bottom of a list silent rather than
    /// a row of beeps.
    @Test("A key of ours alone is kept whatever it did",
          arguments: ["r", "R", "c", "j", "k", "g", "?"] as [Character])
    func ourOwnKeysAreAlwaysKept(character: Character) {
        #expect(pressing(character, did: false))
        #expect(pressing(character, did: true))
    }

    /// A picker is moved with the arrows and a button is pressed with `Return`; `Escape` is
    /// how you leave what you are in; and `Tab` is the focus key in every other app. All five
    /// are the platform's before they are ours, so a press that did nothing here goes back
    /// to it.
    @Test("A key the platform may want goes back where there was nothing to do",
          arguments: [up, down, enter, escape, tab] as [Character])
    func sharedKeysFollowWhatHappened(character: Character) {
        #expect(pressing(character, did: false) == false)
        #expect(pressing(character, did: true))
    }

    @Test("A key that is nobody's is handed back, draft or no draft",
          arguments: ["x", "1", ";"] as [Character])
    func unknownKeysAreNobodys(character: Character) {
        #expect(pressing(character, did: true) == false)
        #expect(pressing(character, typing: true, did: true) == false)
    }

    /// Meaning nothing is not the same as belonging to somebody else. The composer is a
    /// single field, so a Tab handed back would find nothing to traverse to and take the
    /// keyboard off the draft on its way past.
    @Test("A Tab meaning nothing is still not handed back",
          arguments: [tab, escape, "j", "?"] as [Character])
    func onlyTabIsSwallowedWhileTyping(character: Character) {
        #expect(pressing(character, typing: true, did: false) == (character == tab))
    }
}

/// The commands themselves, done to a real app.
@Suite("Steering the app from the keyboard")
@MainActor
struct CommandTests {
    @Test("⌃Tab goes round the four pages and comes back to where it started")
    func pagesRotateForwards() {
        let app = freshApp("pages-forwards")
        app.railItem = .timeline
        for page in [RailItem.kept, .statistics, .settings, .timeline] {
            #expect(app.perform(.nextPage))
            #expect(app.railItem == page)
        }
    }

    @Test("⌃⇧Tab goes the other way, and wraps at the beginning")
    func pagesRotateBackwards() {
        let app = freshApp("pages-backwards")
        app.railItem = .timeline
        for page in [RailItem.settings, .statistics, .kept, .timeline] {
            #expect(app.perform(.previousPage))
            #expect(app.railItem == page)
        }
    }

    @Test("Tab goes round the tabs of the Timeline page, both ways, wrapping at both ends")
    func tabsRotate() {
        let app = freshApp("tabs-rotate")
        app.railItem = .timeline
        app.currentTimeline = "public"
        #expect(app.perform(.nextTab))
        #expect(app.currentTimeline == "trend")
        #expect(app.perform(.nextTab))
        #expect(app.currentTimeline == "public")
        #expect(app.perform(.previousTab))
        #expect(app.currentTimeline == "trend")
        #expect(app.perform(.previousTab))
        #expect(app.currentTimeline == "public")
    }

    /// The one place the answer matters: a `false` here is the shell letting the press
    /// through rather than swallowing a key that did nothing.
    @Test("On a page with no tabs, Tab does nothing and says so", arguments: pagesWithoutTabs)
    func tabDoesNothingWithoutTabs(page: RailItem) {
        let app = freshApp("tab-without-tabs")
        app.railItem = page
        let feed = app.currentTimeline
        let statistics = app.statisticsTab
        let settings = app.settingsTab
        #expect(app.perform(.nextTab) == false)
        #expect(app.perform(.previousTab) == false)
        // Not one of the other pages' tabs moved either. A rotation that answered `false`
        // and still wrote somewhere would be the worst of both.
        #expect(app.currentTimeline == feed)
        #expect(app.statisticsTab == statistics)
        #expect(app.settingsTab == settings)
    }

    @Test("Tab goes round the two Statistics tabs, both ways, wrapping at both ends")
    func statisticsTabsRotate() {
        let app = freshApp("statistics-tabs-rotate")
        app.railItem = .statistics
        app.statisticsTab = .storage
        #expect(app.perform(.nextTab))
        #expect(app.statisticsTab == .network)
        #expect(app.perform(.nextTab))
        #expect(app.statisticsTab == .storage)
        #expect(app.perform(.previousTab))
        #expect(app.statisticsTab == .network)
    }

    @Test("Tab goes round the three Settings tabs, both ways, wrapping at both ends")
    func settingsTabsRotate() {
        let app = freshApp("settings-tabs-rotate")
        app.railItem = .settings
        app.settingsTab = .appearance
        #expect(app.perform(.nextTab))
        #expect(app.settingsTab == .sources)
        #expect(app.perform(.nextTab))
        #expect(app.settingsTab == .keyboard)
        #expect(app.perform(.nextTab))
        #expect(app.settingsTab == .appearance)
        #expect(app.perform(.previousTab))
        #expect(app.settingsTab == .keyboard)
    }

    /// Each page keeps its own place. Rotating the tabs of one page is not a fact about any
    /// other, so leaving a page and coming back is arriving where you were.
    @Test("A page's tab is its own, and going somewhere else does not move it")
    func tabsAreKeptPerPage() {
        let app = freshApp("tabs-kept-per-page")
        app.railItem = .statistics
        #expect(app.perform(.nextTab))
        app.railItem = .settings
        #expect(app.perform(.nextTab))
        #expect(app.statisticsTab == .network)
        #expect(app.settingsTab == .sources)
        #expect(app.currentTimeline == "public")
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

    @Test("Reading again asks for nothing on a page that has no feed", arguments: pagesWithoutFeeds)
    func refreshNeedsAFeed(page: RailItem) {
        let app = freshApp("refresh-needs-a-feed")
        app.railItem = page
        #expect(app.perform(.refreshNow) == false)
    }

    /// Handing a letter back to the platform is worse than swallowing it: AppKit would find
    /// nobody who wanted a bare `r` and beep, on a page where the app itself says the key
    /// does nothing.
    @Test("A letter we understand is ours even when it had nothing to do",
          arguments: pagesWithoutFeeds)
    func recognisedKeysAreKept(page: RailItem) {
        let app = freshApp("recognised-keys-kept")
        app.railItem = page
        #expect(app.perform(.refreshNow) == false)
        #expect(app.presses("r"))
        #expect(app.railItem == page)
    }

    /// The whole point of the bare key being the smaller move. Kept is the one page with
    /// nothing to rotate, so there `Tab` goes back to AppKit — which is how a reader without a
    /// pointer still reaches whatever that page grows.
    @Test("On a page with no tabs, Tab is handed back to the focus system",
          arguments: pagesWithoutTabs)
    func tabIsHandedBackWithoutTabs(page: RailItem) {
        let app = freshApp("tab-handed-back")
        app.railItem = page
        #expect(app.presses(tab) == false)
        #expect(app.presses(tab, modifiers: .shift) == false)
        #expect(app.railItem == page)
    }

    /// There are always four pages, so ⌃Tab always has somewhere to go: it is kept on every
    /// page, and the press AppKit would spend on window tabs never reaches it.
    @Test("⌃Tab rotates the pages and is kept on every one of them",
          arguments: RailItem.allCases, [EventModifiers.control, [.control, .shift]])
    func controlTabIsAlwaysKept(page: RailItem, modifiers: EventModifiers) {
        let app = freshApp("control-tab-kept")
        app.railItem = page
        #expect(app.presses(tab, modifiers: modifiers))
        #expect(app.railItem != page)
    }

    @Test("Escape is the exception: with nothing in front of you it was never ours")
    func escapeIsHandedBack() {
        let app = freshApp("escape-handed-back")
        #expect(app.presses(escape) == false)
        app.setComposing(true)
        #expect(app.presses(escape))
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

    /// The whole of the Tab rule, through the one door both listeners use: mid-draft the
    /// press is kept and the reader stays on the page they were writing from.
    @Test("Tab mid-draft is kept and changes nothing", arguments: [
        EventModifiers(), .shift, .control, [.control, .shift],
    ] as [EventModifiers])
    func tabMidDraftDoesNothing(modifiers: EventModifiers) {
        let app = freshApp("tab-mid-draft")
        app.railItem = .timeline
        app.currentTimeline = "public"
        app.setComposing(true)
        app.setTyping(true)
        #expect(app.presses(tab, modifiers: modifiers))
        #expect(app.railItem == .timeline)
        #expect(app.currentTimeline == "public")
    }

    @Test("With no draft open, the same press moves the tab and is kept")
    func tabMovesWhenNobodyIsTyping() {
        let app = freshApp("tab-moves")
        app.railItem = .timeline
        app.currentTimeline = "public"
        #expect(app.presses(tab))
        #expect(app.currentTimeline == "trend")
        #expect(app.railItem == .timeline)
    }

    /// A key that was never ours is handed back whether or not a draft is open — the door
    /// swallows Tab, not everything that reaches it.
    @Test("A key that is nobody's is still handed back")
    func unknownKeysAreHandedBack() {
        let app = freshApp("unknown-handed-back")
        app.setTyping(true)
        #expect(app.presses("x") == false)
        #expect(app.presses("j") == false)
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
    /// key that did nothing at all.
    @Test("The numeric pad's Enter shows the whole post, the same as the Return above it")
    func keypadEnterOpensAPost() throws {
        let character = try #require(shellKey(keyCode: 76, typed: "\u{3}"))
        #expect(character == enter)
        #expect(KeyCommand.from(character, modifiers: [], typing: false) == .expandPost)
    }
}

/// The three ways a press is recognised, and the order they are asked in.
///
/// The last of them is what keeps the letters alive under an input method. With 注音 up, the
/// `j` key types ㄨ and the `k` key types ㄜ, and every letter this app listens for was dead
/// while the arrows — matched by number — went on working. The Latin layout the system keeps
/// alongside the input method is what says which key it is.
@Suite("Which of our keys a press is")
struct ListenedKeyTests {
    /// The Latin layout is never asked for the keys that are read by number: whatever it
    /// would say about them, the number has already answered.
    @Test("A numbered key is answered by its number, and nothing else is asked")
    func numberedKeysAnswerFirst() {
        var asked = false
        let key = shellListenedKey(keyCode: 125, typed: "\u{3}") { asked = true; return "j" }
        #expect(key == KeyEquivalent.downArrow.character)
        #expect(!asked)
    }

    /// The ordinary case, and the one that must not pay for the fix: a Latin keyboard types
    /// the letter, and the layout is never consulted.
    @Test("A letter that was typed is taken as typed, and the layout is left alone")
    func typedLetterAnswersSecond() {
        var asked = false
        #expect(shellListenedKey(keyCode: 38, typed: "j") { asked = true; return nil } == "j")
        #expect(!asked)
    }

    /// 注音: the key types ㄨ, which is nobody's command, and the same key is `j` on the
    /// reader's Latin layout.
    @Test("A letter typed in another script is read off the Latin layout instead")
    func latinLayoutAnswersLast() {
        #expect(shellListenedKey(keyCode: 38, typed: "ㄨ") { "j" } == "j")
        #expect(shellListenedKey(keyCode: 40, typed: "ㄜ") { "k" } == "k")
    }

    /// The Latin layout decides no more than the typed character does: a key nobody listens
    /// for is still nobody's, however it is spelled.
    @Test("A key that is nobody's stays nobody's, in either spelling")
    func unlistenedKeysAreStillNobodys() {
        #expect(shellListenedKey(keyCode: 0, typed: "ㄇ") { "a" } == nil)
        #expect(shellListenedKey(keyCode: 0, typed: nil) { nil } == nil)
    }

    /// Shift is read off the flags rather than off the character, which is why the layout is
    /// asked unshifted — and why `⇧r` under 注音 still cycles the interval.
    @Test("A held Shift survives the crossing, because the character never carried it")
    func shiftIsReadFromTheFlags() throws {
        let key = try #require(shellListenedKey(keyCode: 15, typed: "ㄐ") { "r" })
        #expect(KeyCommand.from(key, modifiers: [.shift], typing: false) == .cycleRefreshInterval)
        #expect(KeyCommand.from(key, modifiers: [], typing: false) == .refreshNow)
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
