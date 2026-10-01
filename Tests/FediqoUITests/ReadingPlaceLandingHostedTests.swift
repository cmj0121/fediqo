#if os(macOS)
import AppKit
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #273: a launch comes back to the timeline and the lamp kept, asked of the real pane with the
/// root's share of the launch around it.
///
/// **Hosted, and launched in the root's order**, as `ReadingPlaceHostedTests` is wired the root's
/// way: the view is up before the store has said anything, the store is adopted, and then — in
/// one turn, as the root's `.task` does it — the timeline place comes in front, the session lands
/// on the place kept, the lamp is set from what it hands back, and the writing starts. With the
/// pane and `KeepsReadingPlace` both answering, what is asked is that the lamp and the timeline
/// in front are the ones kept, and that nothing written on the way says otherwise.
///
/// **Never which row is on top**, and no conversation: where an off-screen list is scrolled to is
/// the layout's to say, and a conversation drawn would ask its source. Both are asked as logic,
/// in `ReadingPlaceLandingTests` and `ReadingPlaceLaunchTests`.
@Suite("A launch comes back to where reading stopped, hosted", .serialized)
@MainActor
struct ReadingPlaceLandingHostedTests {
    init() {
        L10n.language = .english
    }

    /// What the test presses, and what the view was last drawn with.
    @Observable
    @MainActor
    final class Launch {
        /// Bumped where the store has been adopted: the rest of the root's launch, in one turn.
        var lands = 0
        /// Whether the timeline place is the one in front.
        var onTimeline: Bool
        @ObservationIgnored var seen: String?

        init(onTimeline: Bool) {
            self.onTimeline = onTimeline
        }
    }

    /// The root's share: a lamp in `@State`, the place told to the session, and the launch.
    private struct Host: View {
        let session: ShellSession
        let launch: Launch
        let search: ShellSearch
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = Host.englishPrefs()

        /// English said first: preferences read set the shell's language, which every suite shares.
        private static func englishPrefs() -> DummyPrefs {
            let defaults = CountingDefaults()
            defaults.set("en", forKey: "fediqo.dummy.language")
            return DummyPrefs(defaults: defaults)
        }

        var body: some View {
            launch.seen = selected
            return place
                .environment(prefs)
                .onChange(of: launch.lands) { _, _ in land() }
                .modifier(KeepsReadingPlace(session: session, standing: standing, now: { standing }))
        }

        /// The root's `.task` from `launch.settle` on, less the conversation.
        private func land() {
            launch.onTimeline = true
            session.landAtKeptPlace(latest: prefs.latestDate)
            if let stopped = session.takeLanding() {
                selected = stopped.lamp
            }
            session.keepPlaceFromHere()
        }

        @ViewBuilder
        private var place: some View {
            if launch.onTimeline {
                pane
            } else {
                Text(verbatim: "another place")
            }
        }

        private var pane: some View {
            TimelinePane(
                session: session,
                selectedID: $selected,
                standing: nil,
                onOpenPerson: { _ in },
                decks: $decks,
                playback: playback,
                onPlayRow: { _ in },
                onViewRow: { _ in },
                onTurnRow: { _ in },
                onOpenThread: { _ in },
                jumpToTop: 0,
                onBack: {},
                ways: TimelineWays(canSearch: true, onSearch: {}, canReload: false, onReload: {}),
                search: search
            )
        }

        private var standing: ReadingPlace.Standing {
            ReadingPlace.standing(
                lamp: selected, walk: ShellWalk(), searching: search.isOpen, parked: search.selectionBefore
            )
        }
    }

    @MainActor
    private struct Harness {
        let device: KeptDevice
        let session: ShellSession
        let launch: Launch
        let view: NSView
        /// How many values the defaults had been set before the launch.
        let before: Int

        /// Every place written since the launch began, oldest first: what a quit at any moment
        /// of it would have left.
        var written: [ReadingPlace] {
            device.defaults.sets.dropFirst(before).filter { $0.key == "fediqo.place" }.compactMap { set in
                let one = CountingDefaults()
                one.set(set.value, forKey: "fediqo.place")
                return ReadingPlaceStore(defaults: one).load()
            }
        }

        /// Three passes, each a layout and a brief turn of the run loop, and the main actor
        /// handed back after each: a change, what answered it, and what was told a tick after.
        func settle() async {
            for _ in 0 ..< 3 {
                turn()
                await Task.yield()
            }
        }

        /// Synchronous, because the run loop cannot be turned from an async body.
        private func turn() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
    }

    /// The two things about a launch that no test may leave to chance, since nothing in the
    /// product fixes either.
    struct Order: Sendable, CustomTestStringConvertible {
        /// The pane drawn from the start, as an arrangement that keeps every place alive draws
        /// it; otherwise it is first drawn as the launch settles on the timeline.
        let paneAlive: Bool
        /// A pass drawn between the store adopted and the place landed on, so the timeline coming
        /// in front is answered before the lamp is set; otherwise both are answered at once.
        let drawnBetween: Bool

        var testDescription: String {
            "\(paneAlive ? "pane alive" : "pane drawn at landing"), \(drawnBetween ? "a pass between" : "one pass")"
        }

        static let all: [Order] = [
            Order(paneAlive: false, drawnBetween: true),
            Order(paneAlive: false, drawnBetween: false),
            Order(paneAlive: true, drawnBetween: true),
            Order(paneAlive: true, drawnBetween: false),
        ]
    }

    /// A device, launched: the view first, the store adopted under it, then the rest of the
    /// launch.
    private func launched(_ device: KeptDevice, _ order: Order) async -> Harness {
        let session = device.session()
        let launch = Launch(onTimeline: order.paneAlive)
        let view = NSHostingView(rootView: Host(session: session, launch: launch, search: ShellSearch()))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let harness = Harness(
            device: device, session: session, launch: launch, view: view, before: device.defaults.writes
        )
        await harness.settle()
        await session.reloadFromStore()
        if order.drawnBetween { await harness.settle() }
        launch.lands += 1
        await harness.settle()
        return harness
    }

    private func row(_ id: String) -> String { KeptDevice.row(id) }

    @Test(
        "A place kept on a written timeline with a lamp: that timeline is in front and that post is lit",
        arguments: Order.all
    )
    func timelineAndLamp(_ order: Order) async throws {
        let device = KeptDevice()
        await device.hold()
        let mine = try device.writeTimeline()
        // No top row kept, so the first one the list reports is a move, and is written.
        device.keep(ReadingPlace(timeline: mine, lamp: row("p3")))

        let h = await launched(device, order)
        #expect(h.session.timelineID == mine)
        #expect(h.launch.seen == row("p3"))
        #expect(h.session.readingPlace?.lamp == row("p3"))
        #expect(device.kept?.timeline == mine)
        #expect(device.kept?.lamp == row("p3"))

        // At no moment of it was the place written without its lamp, under another timeline, or
        // with a top row that is not one of that timeline's. Which of its rows is not asked.
        let rows = h.session.rows(of: mine, latest: nil)
        for place in h.written {
            #expect(place.timeline == mine, "\(place)")
            #expect(place.lamp == row("p3"), "\(place)")
            #expect(place.thread == nil, "\(place)")
            if let top = place.top { #expect(rows.contains(top), "\(place)") }
        }
    }

    @Test("A place whose written timeline was deleted: All is in front, and the post is lit there", arguments: Order.all)
    func deletedTimeline(_ order: Order) async throws {
        let device = KeptDevice()
        await device.hold()
        let deleted = try device.writeTimeline(removed: true)
        device.keep(ReadingPlace(timeline: deleted, lamp: row("p3")))

        let h = await launched(device, order)
        #expect(h.session.timelineID == .all)
        #expect(h.launch.seen == row("p3"))
        for place in h.written {
            #expect(place.timeline == .all, "\(place)")
            #expect(place.lamp == row("p3"), "\(place)")
        }
    }

    @Test("A place whose lamp was let go: its timeline is in front, and nothing is lit", arguments: Order.all)
    func lampLetGo(_ order: Order) async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .trends, lamp: row("t9"), top: row("t2")))

        let h = await launched(device, order)
        #expect(h.session.timelineID == .trends)
        #expect(h.launch.seen == nil)
        // The list has landed, whichever way it came to be drawn, and says so: the top row is
        // the list's to report again.
        #expect(!h.session.topIsOwed)
        let rows = h.session.rows(of: .trends, latest: nil)
        #expect(h.session.scrolledTop.map(rows.contains) == true)
        for place in h.written {
            #expect(place.timeline == .trends, "\(place)")
            #expect(place.lamp == nil, "\(place)")
            if let top = place.top { #expect(rows.contains(top), "\(place)") }
        }
    }

    @Test("Nothing kept: All is in front with nothing lit, as before there was a place to keep")
    func nothingKept() async throws {
        let device = KeptDevice()
        await device.hold()

        let h = await launched(device, Order(paneAlive: false, drawnBetween: true))
        #expect(h.session.timelineID == .all)
        #expect(h.launch.seen == nil)
        #expect(h.session.landings == 0)
    }
}
#endif
