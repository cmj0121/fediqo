import FediqoCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #303: under a finger one post is always the one being read.
///
/// **The rules are functions, and the functions are what is tested.** Which row is marked of
/// what the list says is on screen, what a press means, whether the list moves for a selection,
/// what a keyboard coming or going does to it: each is asked directly. The pane is then hosted
/// with the environment a phone with no keyboard has, and asked what it did with them.
///
/// What this does not reach: a finger, a scroll, or a keyboard being attached. Those are a
/// person's, on a device.
@Suite("Under a finger one post is the one being read", .serialized)
@MainActor
struct ReadingMarkTests {
    // MARK: - Which row is marked

    @Test("The marked row is the first wholly on screen; where none is whole, the one holding the top; where the list says nothing, the one it was")
    func whichRowIsMarked() {
        // The top row is cut by the header: the first whole one is the second.
        #expect(ShellReadingMark.marked(whole: ["b", "c"], visible: ["a", "b", "c"], standing: nil) == "b")
        // At rest at the top of the list, the first row is whole and is the one.
        #expect(ShellReadingMark.marked(whole: ["a", "b"], visible: ["a", "b"], standing: "z") == "a")
        // A post taller than the screen: nothing is whole, and the row holding the top is it.
        #expect(ShellReadingMark.marked(whole: [], visible: ["a"], standing: "z") == "a")
        // Its middle going by: nothing whole and nothing half on. The mark stays.
        #expect(ShellReadingMark.marked(whole: [], visible: [], standing: "a") == "a")
        #expect(ShellReadingMark.marked(whole: [], visible: [], standing: nil) == nil, "an empty list marks nothing")
        // A post kept is the one, whatever is on screen, until the person scrolls.
        #expect(ShellReadingMark.marked(whole: ["a", "b"], visible: ["a", "b"], standing: "a", kept: "z") == "z")
    }

    @Test("The mark follows what the list reports, whichever of the two reports comes first")
    func theMarkFollowsTheList() {
        let mark = ShellReadingMark()
        mark.list(["a", "b", "c", "d"])
        mark.visible(["a", "b", "c"])
        #expect(mark.id == "a", "half on is enough until the list says what is whole")
        mark.whole(["b", "c"])
        #expect(mark.id == "b")
        mark.whole(["c", "d"])
        mark.visible(["b", "c", "d"])
        #expect(mark.id == "c")
        mark.forget()
        #expect(mark.id == nil)
        mark.visible([])
        #expect(mark.id == nil, "a list forgotten leaves nothing standing")
    }

    /// Whether reading `lamp` is told of a change while `change` runs.
    private func told(_ lamp: ShellReadingMark.Lamp, while change: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var set = false }
        let flag = Flag()
        withObservationTracking { _ = lamp.lit } onChange: { flag.set = true }
        change()
        return flag.set
    }

    @Test("A mark that moves tells the row that lost it and the row that gained it, and no other row")
    func onlyTwoRowsAreToldOfAMove() {
        let mark = ShellReadingMark()
        mark.list(["a", "b", "c"])
        let a = mark.lamp(for: "a"), b = mark.lamp(for: "b"), c = mark.lamp(for: "c")
        mark.mark("a")
        #expect(a.lit && !b.lit && !c.lit)
        #expect(told(a) { mark.mark("b") } == true, "the row that lost it")
        mark.mark("a")
        #expect(told(b) { mark.mark("b") } == true, "the row that gained it")
        mark.mark("a")
        #expect(told(c) { mark.mark("b") } == false, "a row the mark never touched is not drawn again")
        #expect(!a.lit && b.lit && !c.lit)
        // The same mark said again is no change at all.
        #expect(told(b) { mark.mark("b") } == false)
        #expect(told(b) { mark.visible(["b"]); mark.whole(["b"]) } == false, "scrolling within one row redraws nothing")
    }

    @Test("A row built after the mark came to rest on it is lit from its first drawing")
    func aLateRowIsLit() {
        let mark = ShellReadingMark()
        mark.mark("late")
        #expect(mark.lamp(for: "late").lit)
        #expect(!mark.lamp(for: "other").lit)
        #expect(mark.lamp(for: "late") === mark.lamp(for: "late"), "one lamp a row")
    }

    // MARK: - What is drawn, what a press means, what moves the list

    @Test("Under a finger a row is lit by the mark and never by the selection; with a keyboard by the selection and never by the mark")
    func whatLightsARow() {
        #expect(ShellReadingMark.lit(selected: false, marked: true, touch: true))
        #expect(!ShellReadingMark.lit(selected: true, marked: false, touch: true), "a selection left by a press is not a second lit row")
        #expect(ShellReadingMark.lit(selected: true, marked: false, touch: false))
        #expect(!ShellReadingMark.lit(selected: false, marked: true, touch: false))
    }

    @Test("Under a finger one press opens a row, whatever is selected; with a keyboard or a pointer the first press selects and the second opens, as it did")
    func onePressOpens() {
        for selected in [nil, "a", "b"] as [String?] {
            #expect(DummyCommand.tapped("a", selected: selected, touch: true) == .open)
        }
        #expect(DummyCommand.tapped("a", selected: nil, touch: false) == .select)
        #expect(DummyCommand.tapped("a", selected: "b", touch: false) == .select)
        #expect(DummyCommand.tapped("a", selected: "a", touch: false) == .open)
        #expect(DummyCommand.tapped("a", selected: "b") == .select, "nobody saying is a keyboard or a pointer")
    }

    @Test("The list moves to a newly selected row with a keyboard or a pointer; never under a finger, and never for the row a keyboard was just handed")
    func whatMovesTheList() {
        #expect(ShellReadingMark.centres(onSelecting: "a", touch: false, handed: nil))
        #expect(ShellReadingMark.centres(onSelecting: "a", touch: false, handed: "b"))
        #expect(!ShellReadingMark.centres(onSelecting: "a", touch: true, handed: nil))
        #expect(!ShellReadingMark.centres(onSelecting: "a", touch: false, handed: "a"), "the row handed over is where the reader left it")
        #expect(!ShellReadingMark.centres(onSelecting: nil, touch: false, handed: nil))
    }

    @Test("A lamp a row already holds is the one lit after a timeline is switched: lamps are put out, never replaced")
    func lampsOutliveASwitch() {
        let mark = ShellReadingMark()
        mark.list(["a", "b"])
        let held = mark.lamp(for: "a")
        mark.mark("a")
        mark.forget()
        #expect(!held.lit && mark.id == nil, "the lamp is put out")
        mark.mark("a")
        #expect(held.lit, "and the row that held it is lit again, not a lamp nobody reads")
        #expect(mark.lamp(for: "a") === held)
        // The same through a list that still has the row.
        mark.list(["a", "c"])
        #expect(mark.lamp(for: "a") === held && held.lit)
    }

    @Test("Only the rows of the list in front have lamps: a row that has gone gives its lamp up, so the lamps do not grow for the session")
    func lampsAreBounded() {
        let mark = ShellReadingMark()
        mark.list(["a", "b", "c"])
        let a = mark.lamp(for: "a")
        _ = mark.lamp(for: "b")
        mark.mark("a")
        mark.list(["b", "x"])
        #expect(mark.id == nil, "a row no longer in the list is not what is being read")
        #expect(mark.rows == ["b", "x"])
        #expect(mark.lamp(for: "a") !== a, "the lamp of a row that went is let go")
        // And what the list is told of rows that are not its own is not heard.
        mark.whole(["gone", "b"])
        #expect(mark.id == "b")
        mark.visible(["gone"])
        #expect(mark.id == "b")
    }

    @Test("A post a timeline was returned to is the one being read whatever the list reports, until the person scrolls; then the first whole row is")
    func aKeptPostStaysMarked() {
        let mark = ShellReadingMark()
        mark.list(["a", "b", "c", "last"])
        mark.keep("last")
        #expect(mark.id == "last" && mark.kept == "last" && mark.returning == "last")
        // Near the end of its list it cannot reach the top: an earlier row is the first whole one.
        mark.visible(["b", "c", "last"])
        mark.whole(["c", "last"])
        #expect(mark.id == "last", "the place does not creep up the list")
        mark.scrolledByHand()
        #expect(mark.kept == nil && mark.id == "c", "the person's own scroll gives the mark back to the list")
        // Another timeline lets go of it too.
        mark.keep("last")
        mark.forget()
        #expect(mark.kept == nil && mark.id == nil)
        mark.keep(nil)
        #expect(mark.kept == nil && mark.returning == nil)
    }

    @Test("The post a timeline was left at is known whichever comes first, the list saying its rows changed or the switch asking; and it is asked once")
    func thePostLeftAt() {
        // The switch asks first.
        let first = ShellReadingMark()
        first.list(["a", "b"])
        first.mark("b")
        #expect(first.left() == "b")
        // The list's rows are replaced first, which puts the mark out.
        let second = ShellReadingMark()
        second.list(["a", "b"])
        second.mark("b")
        second.list(["x", "y"])
        #expect(second.id == nil)
        #expect(second.left() == "b", "the post left at is still known")
        #expect(second.left() == nil, "once")
        // A mark made since is the answer, not the one that went.
        second.list(["a", "b"])
        second.mark("a")
        second.list(["x"])
        second.mark("x")
        #expect(second.left() == "x")
    }

    @Test("The list being put somewhere is not the person scrolling it: only a hand on the list, and the glide after it, count")
    func whatScrollingByHandIs() {
        #expect(ShellReadingMark.byHand(.interacting) && ShellReadingMark.byHand(.decelerating))
        #expect(!ShellReadingMark.byHand(.idle) && !ShellReadingMark.byHand(.animating) && !ShellReadingMark.byHand(.tracking))
    }

    @Test("A keyboard attached after the list was moved by hand makes the marked row the selected one; one that was there from the start selects nothing; a keyboard removed leaves nothing selected")
    func aKeyboardComesAndGoes() {
        #expect(ShellReadingMark.handover(touchNow: false, marked: "a", used: true, selected: nil) == "a")
        #expect(ShellReadingMark.handover(touchNow: false, marked: "a", used: false, selected: nil) == nil, "a launch with a keyboard selects nothing")
        #expect(ShellReadingMark.handover(touchNow: false, marked: "a", used: false, selected: "s") == "s", "and leaves a selection there is alone")
        #expect(ShellReadingMark.handover(touchNow: false, marked: nil, used: true, selected: "s") == nil)
        #expect(ShellReadingMark.handover(touchNow: true, marked: "a", used: true, selected: "s") == nil)
        let mark = ShellReadingMark()
        #expect(!mark.used)
        mark.scrolledByHand()
        #expect(mark.used)
        mark.becameTouch()
        #expect(!mark.used, "each time there is nothing but a finger starts untouched")
        #expect(ShellHands.touch(keyboard: true) == false)
        #expect(ShellHands.touch(keyboard: false) == true)
        #if os(macOS)
        #expect(ShellKeyboard.present && !ShellHands.shared.touch, "a Mac is never touch")
        #endif
    }

    @Test("When newer posts land above, the list holds the post being read at its top under a finger, and the row that was at the top with a keyboard")
    func whatALandingHolds() {
        #expect(ShellReadingMark.heldAtTop(top: "cut", marked: "read", touch: true) == "read")
        #expect(ShellReadingMark.heldAtTop(top: "cut", marked: nil, touch: true) == "cut")
        #expect(ShellReadingMark.heldAtTop(top: "cut", marked: "read", touch: false) == "cut")
        #expect(ShellReadingMark.heldAtTop(top: nil, marked: "read", touch: false) == nil)
    }

    @Test("A list drawn afresh under a finger goes back to the place scrolled to and centres nothing; with a keyboard it centres the selection as it did")
    func landingUnderAFinger() {
        #expect(TimelinePane.landing(selected: "lamp", top: "top", touch: true) == .top("top"))
        #expect(TimelinePane.landing(selected: "lamp", top: nil, touch: true) == nil)
        #expect(TimelinePane.landing(selected: "lamp", top: "top", touch: false) == .centred("lamp"))
        #expect(TimelinePane.landing(selected: "lamp", top: "top") == .centred("lamp"))
        #expect(TimelinePane.landing(selected: nil, top: "top", touch: false) == .top("top"))
        // Back from an opened post the list returns to the post being read, not to the row cut
        // by the top above it; and with a keyboard the mark is nothing to it.
        #expect(TimelinePane.landing(selected: "lamp", top: "cut", touch: true, marked: "read") == .top("read"))
        #expect(TimelinePane.landing(selected: nil, top: nil, touch: true, marked: "read") == .top("read"))
        #expect(TimelinePane.landing(selected: nil, top: "cut", touch: false, marked: "read") == .top("cut"))
    }

    @Test("A timeline returned to puts the post it was left at at the top and marks it under a finger; with a keyboard it is selected and centred")
    func returningToATimeline() {
        #expect(TimelinePane.arrival(selected: nil, returning: "kept", touch: true) == .top("kept"))
        #expect(TimelinePane.arrival(selected: "stale", returning: nil, touch: true) == nil)
        #expect(TimelinePane.arrival(selected: "kept", returning: nil, touch: false) == .centred("kept"))
        #expect(TimelinePane.arrival(selected: nil, returning: "kept", touch: false) == nil)
        let finger = TimelinePane.restored("kept", touch: true)
        #expect(finger.selected == nil && finger.marked == "kept")
        let keys = TimelinePane.restored("kept", touch: false)
        #expect(keys.selected == "kept" && keys.marked == nil)
    }

    #if os(macOS)
    // MARK: - The pane, hosted as a phone with no keyboard has it

    private let microblog = Source(host: "m.example", kind: .mastodon)

    @Observable
    @MainActor
    final class Seen {
        @ObservationIgnored var selected: String?
        @ObservationIgnored var opened: [String] = []
        var wanted: String?
        var tick = 0
        var touch = true
    }

    private struct Host: View {
        let session: ShellSession
        let seen: Seen
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: MarkDefaults())

        var body: some View {
            seen.selected = selected
            return TimelinePane(
                session: session, selectedID: $selected, standing: nil, onOpenPerson: { _ in },
                decks: $decks, playback: playback, onPlayRow: { _ in }, onViewRow: { _ in },
                onTurnRow: { _ in }, onOpenThread: { seen.opened.append($0) }, jumpToTop: 0, onBack: {},
                ways: TimelineWays(canSearch: true, onSearch: {}, canReload: false, onReload: {}),
                search: ShellSearch()
            )
            .environment(prefs)
            .environment(\.shellTouch, seen.touch)
            .onChange(of: seen.tick) { _, _ in selected = seen.wanted }
        }
    }

    private func note(_ id: String, _ categories: Set<FediqoCore.Category>, at t: Double) -> Note {
        Note(id: id, source: microblog, author: "Ada", handle: "@ada@m.example", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    @MainActor
    private struct Hosted {
        let session: ShellSession
        let seen: Seen
        let view: NSView

        func settle(_ passes: Int = 3) async {
            for _ in 0 ..< passes {
                turn()
                await Task.yield()
            }
        }

        /// One layout and a brief turn of the run loop, which cannot be turned from an async body.
        private func turn() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }

        func rows(of query: TimelineQuery) -> [String] {
            query.items(from: session.notes, among: session.written, index: session.textIndex, latest: nil).map(\.id)
        }

        func select(_ id: String?) async {
            seen.wanted = id
            seen.tick += 1
            await settle()
        }

        func press(_ query: TimelineQuery) async {
            session.timelineID = query
            await settle()
        }

        func keyboard(_ attached: Bool) async {
            seen.touch = !attached
            await settle()
        }
    }

    private func hosted(touch: Bool, rising: Bool = true) async -> Hosted {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: MarkDefaults()))
        session.sources = [microblog]
        session.rebuildQueries()
        // Enough posts that the list is several screens long, so a row can be scrolled to its top.
        let posts = (1 ... 24).map { note("p\($0)", [.public], at: Double(1000 - $0)) }
        let risen = rising ? (1 ... 3).map { note("t\($0)", [.trends], at: Double(100 - $0)) } : []
        session.notes = posts + risen
        session.timelineID = .all
        let seen = Seen()
        seen.touch = touch
        let view = NSHostingView(rootView: Host(session: session, seen: seen))
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 700)
        let hosted = Hosted(session: session, seen: seen, view: view)
        await hosted.settle()
        return hosted
    }

    @Test("Under a finger a timeline returned to has the post it was left at marked, at the top of the list, lit on the lamp its row holds, and selects nothing; with a keyboard it selects it, as it did")
    func aTimelineReturnedTo() async throws {
        let finger = await hosted(touch: true)
        let all = finger.rows(of: TimelineQuery.all), trends = finger.rows(of: TimelineQuery.trends)
        let left = all[8]
        #expect(!trends.contains(left))
        finger.session.readingMark.mark(left)
        await finger.press(.trends)
        let marked = try #require(finger.session.readingMark.id, "a timeline with posts has one marked")
        #expect(trends.contains(marked), "\(marked) is marked on a timeline of \(trends)")
        #expect(finger.seen.selected == nil)
        #expect(finger.session.timelinePlaces.arriving(at: .all, among: all) == left, "the place written down is the post being read, not a selection there is none of")
        await finger.press(.all)
        let mark = finger.session.readingMark
        #expect(mark.id == left && mark.kept == left, "the post it was left at is marked, and kept so")
        #expect(mark.lamp(for: left).lit, "and its row's lamp is the one lit")
        #expect(finger.seen.selected == nil, "and nothing is selected")

        let keys = await hosted(touch: false)
        await keys.select(left)
        await keys.press(.trends)
        await keys.press(.all)
        #expect(keys.seen.selected == left, "with a keyboard the post is the selection again")
        #expect(keys.session.readingMark.kept == nil, "and nothing is kept as a mark")
    }

    /// **That the list is then scrolled to it is not shown here**: a list hosted off screen
    /// does not scroll. It is shown on a simulator, in the `returned` and `emptied` pictures.
    @Test("Through a timeline with no posts the place is not lost: the post left at is marked again, and asked for at the top once")
    func returnedThroughAnEmptyTimeline() async throws {
        let finger = await hosted(touch: true, rising: false)
        let all = finger.rows(of: TimelineQuery.all)
        #expect(finger.rows(of: TimelineQuery.trends).isEmpty)
        let left = all[8]
        finger.session.readingMark.mark(left)
        await finger.press(.trends)
        #expect(finger.session.readingMark.id == nil, "a timeline with no posts marks nothing")
        await finger.press(.all)
        let mark = finger.session.readingMark
        #expect(mark.id == left, "the post it was left at is marked")
        #expect(mark.returning == nil, "once, and not again at the next drawing")
    }

    @Test("Both of the list's reports arrive: the row at its top is written down as it always was, and the rows wholly on screen are too")
    func bothReportsArrive() async throws {
        let finger = await hosted(touch: true)
        let first = try #require(finger.rows(of: TimelineQuery.all).first)
        #expect(finger.session.scrolledTop == first, "the report `HoldsPlace` and the owing rows are read from")
        #expect(finger.session.readingMark.visible.first == first)
        #expect(finger.session.readingMark.whole.first == first, "the report of rows wholly on screen")
        #expect(finger.session.readingMark.whole.count > 1, "more than one row is whole on a screen 700 tall")
        // And with a keyboard the first is unchanged by the second being there.
        let keys = await hosted(touch: false)
        #expect(keys.session.scrolledTop == first)
    }

    @Test("Under a finger a timeline with posts has one marked with nothing pressed: the first row, which is whole on screen, and nothing is selected")
    func markedOnArrival() async throws {
        let finger = await hosted(touch: true)
        let first = try #require(finger.rows(of: TimelineQuery.all).first)
        #expect(finger.session.readingMark.id == first)
        #expect(finger.session.readingMark.lamp(for: first).lit)
        #expect(finger.seen.selected == nil)
        #expect(finger.session.readingMark.rows == Set(finger.rows(of: TimelineQuery.all)), "the mark knows the rows of the list in front")
    }

    @Test("Under a finger a selection a press left behind lights nothing and is put out by a switch")
    func noSelectionUnderAFinger() async throws {
        let finger = await hosted(touch: true)
        let rows = finger.rows(of: TimelineQuery.all)
        let first = try #require(rows.first), pressed = rows[2]
        await finger.select(pressed)
        #expect(finger.seen.selected == pressed)
        #expect(finger.session.readingMark.id == first, "the mark is where the list is, not where the press was")
        #expect(!finger.session.readingMark.lamp(for: pressed).lit, "and the selected row's lamp is not lit")
        #expect(finger.session.scrolledTop == first, "nor did the list move to it")
        await finger.press(.trends)
        #expect(finger.seen.selected == nil, "a switch under a finger selects nothing")
    }

    @Test("A keyboard that was there from the start selects nothing; attached after the list was moved by hand it takes the marked row as the selection, and the list does not move")
    func theHandover() async throws {
        let early = await hosted(touch: true)
        let first = try #require(early.rows(of: TimelineQuery.all).first)
        #expect(early.session.readingMark.id == first)
        await early.keyboard(true)
        #expect(early.seen.selected == nil, "a keyboard reported a moment after launch selects nothing")

        let later = await hosted(touch: true)
        later.session.readingMark.scrolledByHand()
        await later.keyboard(true)
        #expect(later.seen.selected == first, "the marked row is the selection")
        #expect(later.session.scrolledTop == first, "and the list is where it was")
        await later.keyboard(false)
        #expect(later.seen.selected == nil, "taken away again, nothing is selected")
        #expect(!later.session.readingMark.used)
    }

    @Test("An act pressed on a row is done to that row, whichever row is marked and whichever is selected")
    func anActIsItsOwnRows() async throws {
        let finger = await hosted(touch: true)
        let rows = finger.rows(of: TimelineQuery.all)
        let pressed = try #require(rows.last), marked = try #require(rows.first)
        #expect(pressed != marked)
        finger.session.readingMark.mark(marked)
        var opened: [String] = []
        var selected: String? = marked
        let pane = TimelinePane(
            session: finger.session, selectedID: Binding(get: { selected }, set: { selected = $0 }), standing: nil,
            onOpenPerson: { _ in }, decks: .constant(ShellDecks()), playback: ShellPlayback(),
            onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { opened.append($0) },
            jumpToTop: 0, onBack: {}, ways: TimelineWays(canSearch: true, onSearch: {}, canReload: false, onReload: {})
        )
        let item = try #require(finger.session.held(pressed))
        // Answering is the one act whose press is seen from outside without a server: it opens
        // the post it was pressed on.
        pane.acting(item).perform?(.answer)
        #expect(opened == [pressed], "the answer went to \(opened), with \(marked) marked and selected")
        #expect(selected == marked && finger.session.readingMark.id == marked, "and neither the mark nor the selection moved")
    }
    #endif
}

/// Preferences that are nobody's: a hosted pane must not read or write the person's own.
private final class MarkDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
