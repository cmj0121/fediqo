import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #307: pulling a timeline down reads it again, and a read can be stopped.
///
/// What the mark is, when a pull is offered and what one does are functions and are asked
/// directly. A pull and a press are then each made on a session of their own, against the same
/// answers, and what each asked for is compared: the pull is the press, so they are the same.
/// The pull itself — a finger on a list — is not reached from here.
@Suite("Pulling a timeline down reads it again, and a read can be stopped", .serialized, .watched)
@MainActor
struct ReloadPullTests {
    @Test("The mark is absent where a reload is not offered, Stop while one the reader pressed for runs, and the reload mark otherwise")
    func whatTheMarkIs() {
        #expect(ReloadMark.shown(canReload: false, stoppable: false) == nil)
        #expect(ReloadMark.shown(canReload: false, stoppable: true) == nil, "not offered is not offered, running or not")
        #expect(ReloadMark.shown(canReload: true, stoppable: false) == .reload)
        #expect(ReloadMark.shown(canReload: true, stoppable: true) == .stop)
    }

    @Test("A pull is offered exactly where the mark is, and never over a search's results")
    func whenAPullIsOffered() {
        #expect(ReloadMark.pulls(canReload: true, searching: false))
        #expect(!ReloadMark.pulls(canReload: false, searching: false))
        #expect(!ReloadMark.pulls(canReload: true, searching: true))
    }

    @Test("What a reader pressed for can be stopped; what the app asks by itself — the wait, more, a tag, a search, a renewal — cannot be, and is no reason to draw Stop")
    func whatCanBeStopped() {
        #expect(ShellReload.stoppable([.timeline]) == [.timeline])
        #expect(ShellReload.stoppable([.thread, .held]) == [.thread])
        #expect(ShellReload.stoppable([.held, .search, .tag, .more, .renew]).isEmpty)
        #expect(ShellReload.stoppable([]).isEmpty)
    }

    @Test("A pull is the press and then the wait, every time — the press itself takes a second one of the same read and does nothing; where no reload is offered a pull does neither")
    func whatAPullDoes() async {
        var pressed = 0, waited = 0
        // What the pull gives its press before it waits is kept, and not slept.
        var leads: [Duration] = []
        await PullsToReload.pull(offered: true, reload: { pressed += 1 }, settled: { waited += 1 }) { leads.append($0) }
        #expect(pressed == 1 && waited == 1 && leads == [PullsToReload.lead])
        await PullsToReload.pull(offered: false, reload: { pressed += 1 }, settled: { waited += 1 }) { leads.append($0) }
        #expect(pressed == 1 && waited == 1, "not offered, a pull's spinner comes and goes")
        #expect(leads.count == 1, "and it waits for nothing")
        // A second pull while the first read runs presses again, and the press starts nothing.
        let http = FixtureHTTP(Self.routes)
        let session = session(http)
        session.reload.press(thread: nil, timeline: .all, in: session)
        session.reload.press(thread: nil, timeline: .all, in: session)
        // No `by:` in this suite's waits on a press: its read is a task of the press's own
        // making, which nothing out here can name.
        await met("the reload pressed for twice has ended") { Self.ended(session) }
        await session.reload.settled(.timeline)
        let once = FixtureHTTP(Self.routes)
        let single = self.session(once)
        single.reload.press(thread: nil, timeline: .all, in: single)
        await met("the reload pressed for once has ended") { Self.ended(single) }
        await single.reload.settled(.timeline)
        let twice = await http.paths, one = await once.paths
        #expect(!one.isEmpty && twice == one, "two presses asked \(twice), one asks \(one)")
    }

    @Test("A press on Stop within four tenths of a second of the press that began the reload is not heard; later it is; a reload begun any other way is stopped at once")
    func aQuickSecondPress() {
        let began = Date(timeIntervalSince1970: 1000)
        #expect(!ReloadMark.stops(at: began.addingTimeInterval(0.1), pressedAt: began))
        #expect(!ReloadMark.stops(at: began.addingTimeInterval(0.39), pressedAt: began))
        #expect(ReloadMark.stops(at: began.addingTimeInterval(0.41), pressedAt: began))
        #expect(ReloadMark.stops(at: began.addingTimeInterval(5), pressedAt: began))
        #expect(ReloadMark.stops(at: began, pressedAt: nil), "begun by a key or a pull")
        #expect(ReloadMark.settle == 0.4)
        // The press itself, as every mark asks it: the reload mark always begins; Stop stops, or
        // within the settle of the press that began it is not heard — to the edge, and at it.
        #expect(ReloadMark.press(.reload, at: began, pressedAt: nil) == .begins)
        #expect(ReloadMark.press(.reload, at: began, pressedAt: began) == .begins)
        #expect(ReloadMark.press(.reload, at: began.addingTimeInterval(5), pressedAt: began) == .begins)
        #expect(ReloadMark.press(.stop, at: began, pressedAt: nil) == .stops)
        #expect(ReloadMark.press(.stop, at: began, pressedAt: began) == .unheard)
        #expect(ReloadMark.press(.stop, at: began.addingTimeInterval(0.39), pressedAt: began) == .unheard)
        // At the settle exactly it is heard — counted from a moment whose sum is exact.
        let zero = Date(timeIntervalSinceReferenceDate: 0)
        #expect(ReloadMark.press(.stop, at: zero.addingTimeInterval(ReloadMark.settle), pressedAt: zero) == .stops)
        #expect(ReloadMark.press(.stop, at: began.addingTimeInterval(0.41), pressedAt: began) == .stops)
        #expect(ReloadMark.press(.stop, at: began.addingTimeInterval(-1), pressedAt: began) == .unheard)
    }

    @Test("What a pull brings is shown at the top of the list, once; every other landing holds the place")
    func whatAPullsLandingShows() {
        typealias Pull = ShellReadingMark.Pull
        #expect(!ShellReadingMark.showsNewest(.none))
        #expect(ShellReadingMark.showsNewest(.running(landed: false)) && ShellReadingMark.showsNewest(.ended))
        let mark = ShellReadingMark()
        #expect(!mark.landing(), "a landing nobody pulled for — the mark, r, the wait — holds the place")
        mark.pulled()
        #expect(mark.landing(), "the pull's own landing shows the newest")
        #expect(mark.landing(), "and so does a second while its read still runs")
        mark.pullSettled()
        #expect(mark.pull == .none && !mark.landing(), "its read over, the next landing holds")
    }

    @Test("A pull whose read ends before anything lands still shows the landing that follows — unless the person has moved the list by then")
    func aLateLanding() {
        let late = ShellReadingMark()
        late.pulled()
        late.pullSettled()
        #expect(late.pull == .ended)
        #expect(late.landing() && late.pull == .none)
        #expect(!late.landing(), "once")
        let moved = ShellReadingMark()
        moved.pulled()
        moved.pullSettled()
        moved.scrolledByHand()
        #expect(!moved.landing(), "the list was moved: what lands now holds the place")
        // Moving the list while the read still runs does not give the pull up.
        let during = ShellReadingMark()
        during.pulled()
        during.scrolledByHand()
        #expect(during.landing())
    }

    #if os(macOS)
    /// Counts how often a view inside the pulled list was made anew.
    @Observable
    @MainActor
    final class Made {
        @ObservationIgnored var times = 0
        var offered = true
    }

    private struct Probe: View {
        let made: Made
        @State private var mine = 0

        var body: some View {
            Color.clear.frame(height: 10).onAppear { made.times += 1 }
        }
    }

    private struct Pulled: View {
        let made: Made

        var body: some View {
            ScrollView { Probe(made: made) }
                .modifier(PullsToReload(offered: { made.offered }, reload: {}, settled: {}, applies: true))
                // Read here so the body is drawn again when it flips, as the pane's is.
                .opacity(made.offered ? 1 : 0.99)
        }
    }

    @Test("Whether a reload is offered coming and going does not make the list another list: what is in it is made once")
    func theListIsOneList() async {
        let made = Made()
        let hosted = NSHostingView(rootView: Pulled(made: made))
        hosted.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        func turn() {
            hosted.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
        turn()
        await Task.yield()
        turn()
        let first = made.times
        #expect(first >= 1)
        for offered in [false, true, false] {
            made.offered = offered
            turn()
            await Task.yield()
            turn()
        }
        #expect(made.times == first, "the list's content was made \(made.times) times")
    }

    /// **That the header does not shift as the mark flips rests on the button's fixed frame**
    /// (`ShellIconButton`), which no glyph changes; what is asked here is that it is one button
    /// under two names, each its own.
    @Test("The reload mark and Stop are one size: the header does not shift as it flips")
    func oneSizeEitherWay() {
        let reload = NSHostingView(rootView: ShellIconButton(ReloadMark.reload.symbol, name: ReloadMark.reload.name, action: {})).fittingSize
        let stop = NSHostingView(rootView: ShellIconButton(ReloadMark.stop.symbol, name: ReloadMark.stop.name, action: {})).fittingSize
        #expect(reload == stop, "the reload mark is \(reload), Stop \(stop)")
    }

    @Test("The reload mark and Stop are the one button under two glyphs and two names")
    func oneButtonTwoNames() {
        #expect(ReloadMark.reload.symbol != ReloadMark.stop.symbol)
        #expect(ReloadMark.reload.name == "shortcut.reload" && ReloadMark.stop.name == "timeline.reload.stop")
    }
    #endif

    private func session(_ http: FixtureHTTP) -> ShellSession {
        let session = ShellSession(http: http, timelines: nil)
        session.sources = [Source(host: "m.example", kind: .mastodon)]
        session.rebuildQueries()
        session.timelineID = .all
        return session
    }

    private static let routes: [String: FixtureHTTP.Outcome] = ["/api/v1/timelines/public": .text("[]")]

    /// Whether a timeline's reload has come to its end here, read or not.
    private static func ended(_ session: ShellSession) -> Bool {
        session.reload.landed > 0 || !session.reload.failed.isEmpty
    }

    @Test("A pull and a press on the reload mark ask the same things of the same source, in the same order")
    func aPullIsThePress() async throws {
        let pressedHTTP = FixtureHTTP(Self.routes)
        let pressed = session(pressedHTTP)
        pressed.reload.press(thread: nil, timeline: .all, in: pressed)
        await met("the pressed reload has ended") { Self.ended(pressed) }
        await pressed.reload.settled(.timeline)

        let pulledHTTP = FixtureHTTP(Self.routes)
        let pulled = session(pulledHTTP)
        // What the pull gives its press, turned here once the press has begun its read: the
        // pull then waits for a read that is there to wait for, on any machine.
        let lead = TurnedClock()
        let pulling = Task {
            await PullsToReload.pull(
                offered: true,
                reload: { pulled.reload.press(thread: nil, timeline: .all, in: pulled) },
                settled: { await pulled.reload.settled(.timeline) { _ in await Task.yield() } },
                sleep: lead.sleep
            )
        }
        await met("the pull has pressed, and its press has begun its read", by: pulling) {
            lead.sleeping == 1 && (pulled.reload.stoppable || Self.ended(pulled))
        }
        #expect(lead.asked == [PullsToReload.lead])
        lead.turn()
        await pulling.value
        #expect(!pulled.reload.stoppable, "the pull returned when its reload had ended")
        let asked = await pressedHTTP.paths, askedByPull = await pulledHTTP.paths
        #expect(!asked.isEmpty, "the press asked for something")
        #expect(askedByPull == asked, "the pull asked \(askedByPull), the press \(asked)")
        #expect(pulled.reload.line == pressed.reload.line && pulled.reload.failed == pressed.reload.failed, "and they say the same of it")
    }

    @Test("The wait a pull's spinner stands for ends when the reload is stopped, and at once where nothing is running; stopped, the reload says what Escape leaves it saying")
    func theSpinnerEnds() async throws {
        let idle = session(FixtureHTTP(Self.routes))
        await idle.reload.settled(.timeline)
        #expect(!idle.reload.stoppable)

        let held = session(FixtureHTTP(Self.routes))
        held.reload.press(thread: nil, timeline: .all, in: held)
        await met("the pressed reload is running") { held.reload.stoppable }
        let waiting = Task { await held.reload.settled(.timeline) }
        #expect(held.reload.stop(), "there was something to stop")
        await waiting.value
        #expect(!held.reload.stoppable && held.reload.stopped)
        #expect(ReloadMark.shown(canReload: true, stoppable: held.reload.stoppable) == .reload, "and the mark is the reload mark again")
    }

    @Test("Escape and Stop on a page opened over the stream are that page's: a reload of the stream running under it runs on, and its toast is not the page's; with the stream in front they are the stream's")
    func theStopInFrontIsThePages() async throws {
        let held = session(FixtureHTTP(Self.routes))
        held.reload.press(thread: nil, timeline: .all, in: held)
        await met("the pressed reload is running") { held.reload.stoppable }
        let pages = ShellPersonPages()
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: "m.example"))
        let front = try #require(TimelinePane.askInFront(.person(ada), rising: nil, of: pages, in: held))
        #expect(!TimelinePane.stop(front, of: pages, in: held), "the page has nothing on the wire")
        #expect(held.reload.stoppable, "and the stream's reload under it runs on")
        #expect(TimelinePane.banner(TimelinePane.ask(front, of: pages, in: held), note: nil, in: held) == nil, "nor is it the page's toast")
        #expect(TimelinePane.askInFront(nil, rising: nil, of: pages, in: held) == nil, "the stream in front: its own")
        #expect(TimelinePane.banner(nil, note: nil, in: held)?.kind == .loading)
        #expect(held.reload.stop())
    }

    @Test("A wait whose list has gone ends with it, though the reload runs on")
    func theWaitIsCancelled() async {
        let reload = ShellReload()
        let running = Gate()
        let guardTask = watching(running, "the reload that is to run on")
        defer { guardTask.cancel() }
        let asked = Task { await reload.run(.timeline) { await running.wait() } }
        await met("the reload is running", by: asked) { reload.stoppable }
        // The wait's own clock, turned here: asleep on it is a look that was made and found the
        // read running, and turned, it looks again — so "still waiting" is two looks that both
        // found it so, and not a stretch of time in which nothing was seen to happen.
        let clock = TurnedClock()
        let waiting = Task { await reload.settled(.timeline, sleep: clock.sleep) }
        await met("the wait has looked, and found the reload running", by: waiting) { clock.sleeping == 1 }
        clock.turn()
        await met("the wait has looked again, and found it running still", by: waiting) {
            clock.asked.count == 2 && clock.sleeping == 1
        }
        #expect(clock.asked == [ShellReload.look, ShellReload.look])
        waiting.cancel()
        await waiting.value
        #expect(reload.stoppable, "the reload itself was not stopped by it")
        // And a wait for another read than the one running is over at once: over without ever
        // having slept. One that did wait would be asleep on its clock, and is told apart.
        final class Flag: @unchecked Sendable { var done = false }
        let over = Flag()
        let other = TurnedClock()
        let waitingForThread = Task {
            await reload.settled(.thread, sleep: other.sleep)
            over.done = true
        }
        await met("a conversation's wait is over, or asleep", by: waitingForThread) { over.done || other.sleeping == 1 }
        #expect(over.done && other.asked.isEmpty, "a conversation's pull does not wait for a timeline's read")
        waitingForThread.cancel()
        _ = reload.stop()
        await running.open()
        asked.cancel()
    }

    @Test("The keys' table says the two new ways under a finger: the list pulled for r, and Stop for the part of Escape that stops a reload; neither line's first answer changed")
    func theTable() throws {
        let reload = try #require(DummyShortcut.all.first { $0.name == "reload" })
        #expect(reload.touch == .press && reload.also == .pull)
        let dismiss = try #require(DummyShortcut.all.first { $0.name == "dismiss" })
        #expect(dismiss.touch == .partly && dismiss.also == .press)
        #expect(DummyShortcut.all.filter { $0.also != nil }.map(\.name) == ["expand", "reload", "withdraw", "edit", "dismiss"])
    }

    @Test("Stop is named in each language the app ships")
    func theWord() {
        #expect(L10n.t("timeline.reload.stop", language: .english) == "Stop reloading")
        #expect(L10n.t("timeline.reload.stop", language: .taiwanese) == "停止重新載入")
    }
}
