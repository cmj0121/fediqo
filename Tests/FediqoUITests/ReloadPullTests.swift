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
@Suite("Pulling a timeline down reads it again, and a read can be stopped", .serialized)
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
        await PullsToReload.pull(offered: true, reload: { pressed += 1 }, settled: { waited += 1 })
        #expect(pressed == 1 && waited == 1)
        await PullsToReload.pull(offered: false, reload: { pressed += 1 }, settled: { waited += 1 })
        #expect(pressed == 1 && waited == 1, "not offered, a pull's spinner comes and goes")
        // A second pull while the first read runs presses again, and the press starts nothing.
        let http = FixtureHTTP(Self.routes)
        let session = session(http)
        session.reload.press(thread: nil, timeline: .all, in: session)
        session.reload.press(thread: nil, timeline: .all, in: session)
        await session.reload.settled(.timeline)
        _ = await spun { session.reload.landed > 0 || !session.reload.failed.isEmpty }
        await session.reload.settled(.timeline)
        let once = FixtureHTTP(Self.routes)
        let single = self.session(once)
        single.reload.press(thread: nil, timeline: .all, in: single)
        _ = await spun { single.reload.landed > 0 || !single.reload.failed.isEmpty }
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

    @Test("A pull and a press on the reload mark ask the same things of the same source, in the same order")
    func aPullIsThePress() async throws {
        let pressedHTTP = FixtureHTTP(Self.routes)
        let pressed = session(pressedHTTP)
        pressed.reload.press(thread: nil, timeline: .all, in: pressed)
        #expect(await spun { pressed.reload.landed > 0 || !pressed.reload.failed.isEmpty })
        await pressed.reload.settled(.timeline)

        let pulledHTTP = FixtureHTTP(Self.routes)
        let pulled = session(pulledHTTP)
        await PullsToReload.pull(
            offered: true,
            reload: { pulled.reload.press(thread: nil, timeline: .all, in: pulled) },
            settled: { await pulled.reload.settled(.timeline) }
        )
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
        #expect(await spun { held.reload.stoppable })
        let waiting = Task { await held.reload.settled(.timeline) }
        #expect(held.reload.stop(), "there was something to stop")
        await waiting.value
        #expect(!held.reload.stoppable && held.reload.stopped)
        #expect(ReloadMark.shown(canReload: true, stoppable: held.reload.stoppable) == .reload, "and the mark is the reload mark again")
    }

    @Test("A wait whose list has gone ends with it, though the reload runs on")
    func theWaitIsCancelled() async {
        let reload = ShellReload()
        let asked = Task { await reload.run(.timeline) { try? await Task.sleep(for: .seconds(30)) } }
        #expect(await spun { reload.stoppable })
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        let waiting = Task {
            await reload.settled(.timeline)
            flag.done = true
        }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(!flag.done, "while the reload runs, the wait is still waiting")
        waiting.cancel()
        await waiting.value
        #expect(reload.stoppable, "the reload itself was not stopped by it")
        // And a wait for another read than the one running is over at once.
        let other = Flag()
        let waitingForThread = Task {
            await reload.settled(.thread)
            other.done = true
        }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(other.done, "a conversation's pull does not wait for a timeline's read")
        waitingForThread.cancel()
        _ = reload.stop()
        asked.cancel()
    }

    @Test("The keys' table says the two new ways under a finger: the list pulled for r, and Stop for the part of Escape that stops a reload; neither line's first answer changed")
    func theTable() throws {
        let reload = try #require(DummyShortcut.all.first { $0.name == "reload" })
        #expect(reload.touch == .press && reload.also == .pull)
        let dismiss = try #require(DummyShortcut.all.first { $0.name == "dismiss" })
        #expect(dismiss.touch == .partly && dismiss.also == .press)
        #expect(DummyShortcut.all.filter { $0.also != nil }.map(\.name) == ["expand", "reload", "edit", "dismiss"])
    }

    @Test("Stop is named in each language the app ships")
    func theWord() {
        #expect(L10n.t("timeline.reload.stop", language: .english) == "Stop reloading")
        #expect(L10n.t("timeline.reload.stop", language: .taiwanese) == "停止重新載入")
    }
}
