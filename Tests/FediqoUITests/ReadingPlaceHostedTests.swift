#if os(macOS)
import AppKit
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #273: the lamp the place names, asked of the real pane with the root's own modifier on it.
///
/// **Hosted, and wired the way the root wires it**, as `TimelinePlacesHostedTests` is and for its
/// reasons: the pane off-screen in an `NSHostingView`, a lamp in `@State`, the root's search, and
/// `KeepsReadingPlace` handed what `ReadingPlace.standing` makes of them. What is asked is the
/// one thing only the two together answer — that the lamp the pane lights on a switch is the lamp
/// written down under the timeline arrived at.
///
/// **Never which row is on top.** Which row an off-screen list calls its top is the layout's to
/// say; that row's writing is asked of the session, in `ReadingPlaceKeptTests`. The one test here
/// that reads a top, `openWithNothingTyped`, asks only that one was told and that it is a row of
/// the timeline in front.
@Suite("Where reading stands is written down, hosted", .serialized)
@MainActor
struct ReadingPlaceHostedTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)

    init() {
        L10n.language = .english
    }

    /// The lamp, written the way a key writes it and read back after the pane has answered.
    @Observable
    @MainActor
    final class Lamp {
        var wanted: String?
        var tick = 0
        @ObservationIgnored var seen: String?
        /// Whether the timeline place is the one in front: off, the pane is not drawn at all,
        /// which is what the root does with it on another tab.
        var onTimeline = true
    }

    /// The root's share of the pane: a lamp in `@State`, a search that is always there, and the
    /// place told to the session.
    private struct Host: View {
        let session: ShellSession
        let lamp: Lamp
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
            lamp.seen = selected
            return place
                .environment(prefs)
                .onChange(of: lamp.tick) { _, _ in selected = lamp.wanted }
                .modifier(KeepsReadingPlace(session: session, standing: standing, now: { standing }))
        }

        @ViewBuilder
        private var place: some View {
            if lamp.onTimeline {
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
        let session: ShellSession
        let defaults: CountingDefaults
        let lamp: Lamp
        let search: ShellSearch
        let view: NSView

        /// The rows a timeline holds, worked out from the session rather than drawn.
        func rows(of query: TimelineQuery) -> [String] {
            query.items(from: session.notes, among: session.written, index: session.textIndex, latest: nil).map(\.id)
        }

        /// What is kept, read the way a relaunch reads it.
        var kept: ReadingPlace? { ReadingPlaceStore(defaults: defaults).load() }

        /// Every place written so far, oldest first: what a quit at any moment would have left.
        var everKept: [ReadingPlace] {
            defaults.sets.filter { $0.key == "fediqo.place" }.compactMap { written in
                let one = CountingDefaults()
                one.set(written.value, forKey: "fediqo.place")
                return ReadingPlaceStore(defaults: one).load()
            }
        }

        func stand(on id: String?) async {
            lamp.wanted = id
            lamp.tick += 1
            await settle()
            #expect(lamp.seen == id)
        }

        func press(_ query: TimelineQuery) async {
            session.timelineID = query
            await settle()
        }

        /// One change answered: the pane's `onChange`, the lamp it wrote, and the place told a
        /// tick after. Three passes, each a layout and a brief turn of the run loop, and the main actor
        /// handed back after each.
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

    private func note(_ id: String, _ author: String, _ categories: Set<FediqoCore.Category>, at t: Double) -> Note {
        Note(id: id, source: microblog, author: author, handle: "@\(author.lowercased())@m.example", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    /// All holds `p1`–`p3`, Trends `t1`–`t3`, and a timeline written for Ada her posts from both.
    /// `searching` opens the root's search, with nothing typed, before the pane is first drawn.
    private func harness(searching: Bool = false) async throws -> Harness {
        let defaults = CountingDefaults()
        let session = ShellSession(
            http: FixtureHTTP([:]),
            timelines: WrittenTimelineStore(defaults: defaults),
            place: ReadingPlaceStore(defaults: defaults)
        )
        session.sources = [microblog]
        session.rebuildQueries()
        session.notes = [
            note("p1", "Ada", [.public], at: 9),
            note("p2", "Bob", [.public], at: 8),
            note("p3", "Ada", [.public], at: 7),
            note("t1", "Cy", [.trends], at: 6),
            note("t2", "Dee", [.trends], at: 5),
            note("t3", "Ada", [.trends], at: 4),
        ]
        var draft = TimelineDraft(new: 1)
        draft.name = "Ada"
        draft.rules = [try #require(Rule.author("@ada@m.example", in: .every, sources: []))]
        session.commit(draft)
        session.timelineID = .all
        let lamp = Lamp()
        let search = ShellSearch()
        if searching {
            search.open(from: nil, over: session.notes)
            await search.indexed()
            // Written from the first row the list says is in view, which is what is asked.
            session.keepPlaceFromHere()
        }
        let view = NSHostingView(rootView: Host(session: session, lamp: lamp, search: search))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let harness = Harness(session: session, defaults: defaults, lamp: lamp, search: search, view: view)
        await harness.settle()
        session.keepPlaceFromHere()
        return harness
    }

    private func rowID(_ id: String, in session: ShellSession) throws -> String {
        try #require(session.notes.first { $0.id == id }.map { DummyItem($0).id })
    }

    @Test("The lamp moved is written, and a timeline pressed is written with the lamp the pane lights there")
    func theLampOfTheTimelineInFront() async throws {
        let h = try await harness()
        let p2 = try rowID("p2", in: h.session)
        let t2 = try rowID("t2", in: h.session)
        await h.stand(on: p2)
        #expect(h.kept?.timeline == .all)
        #expect(h.kept?.lamp == p2)

        // Trends for the first time this run: nothing lit, and All's lamp is not carried there.
        await h.press(.trends)
        #expect(h.lamp.seen == nil)
        #expect(h.kept?.timeline == .trends)
        #expect(h.kept?.lamp == nil)
        await h.stand(on: t2)
        #expect(h.kept?.lamp == t2)

        // Back: the pane gives All its post again, and that is what is written under All.
        await h.press(.all)
        #expect(h.lamp.seen == p2)
        #expect(h.kept?.timeline == .all)
        #expect(h.kept?.lamp == p2)
        #expect(h.kept?.thread == nil)

        // At no moment on the way was one timeline's post written under the other's name — as
        // its lamp, or as its top row, which the list says of the rows it held before the switch
        // before it says it of its own. Which of its own rows is on top is not asked.
        let all = Set(h.session.notes.filter { $0.categories.contains(.public) }.map { DummyItem($0).id })
        for place in h.everKept {
            for row in [place.lamp, place.top].compactMap({ $0 }) {
                #expect(all.contains(row) == (place.timeline == .all), "\(place)")
            }
        }
    }

    /// The lamp reads the same before and after the switch, so nothing about the lamp changed for
    /// the modifier to see — and the session forgot it as the timeline changed.
    @Test("A post two timelines were both left on is written under each as it comes in front")
    func thePostBothHold() async throws {
        let h = try await harness()
        let mine = TimelineQuery.written(try #require(h.session.written.first).id)
        let p3 = try rowID("p3", in: h.session)
        await h.stand(on: p3)
        await h.press(mine)
        await h.stand(on: p3)
        #expect(h.kept?.timeline == mine)
        #expect(h.kept?.lamp == p3)

        await h.press(.all)
        #expect(h.lamp.seen == p3)
        #expect(h.kept?.timeline == .all)
        #expect(h.kept?.lamp == p3)

        await h.press(mine)
        #expect(h.lamp.seen == p3)
        #expect(h.kept?.timeline == mine)
        #expect(h.kept?.lamp == p3)
    }

    /// The field open and nothing typed: the pane still draws the timeline, so the row its list
    /// says is at the top is the timeline's, and is written as the place's. Which row is not
    /// asked — only that it is one of All's, and that it went to the place and not aside.
    @Test("A search open with nothing typed in it: the top row the list reports is the timeline's, and is written")
    func openWithNothingTyped() async throws {
        let h = try await harness(searching: true)
        #expect(h.search.isOpen)
        #expect(h.session.searched(h.search, latest: nil) == nil)

        let top = try #require(h.session.scrolledTop)
        #expect(h.rows(of: .all).contains(top))
        #expect(h.kept == ReadingPlace(timeline: .all, top: top))
    }

    // MARK: Acceptance: a change of tab alone writes nothing

    /// The pane is taken away and put back, as the root does it when the rail goes to another
    /// place and returns: the list goes with everything it reports, and comes back drawn afresh.
    /// Which row it then calls its top is not asked — only that nothing was written on the way.
    @Test("The timeline place left for another and come back to writes nothing")
    func aTabChange() async throws {
        let h = try await harness()
        let p2 = try rowID("p2", in: h.session)
        await h.stand(on: p2)
        #expect(h.kept?.lamp == p2)
        let kept = h.kept
        let writes = h.defaults.writes

        h.lamp.onTimeline = false
        await h.settle()
        #expect(h.defaults.writes == writes)

        h.lamp.onTimeline = true
        await h.settle()
        #expect(h.lamp.seen == p2)
        #expect(h.defaults.writes == writes)
        #expect(h.kept == kept)
    }

    @Test("Under a search the lamp written stays the post it parked, through opening and closing")
    func underASearch() async throws {
        let h = try await harness()
        let p2 = try rowID("p2", in: h.session)
        let p3 = try rowID("p3", in: h.session)
        await h.stand(on: p2)

        // `/`, as the root opens it: the lamp parked in the search and put out, then on a result.
        h.search.open(from: h.lamp.seen, over: h.session.notes)
        await h.stand(on: nil)
        await h.stand(on: p3)
        #expect(h.kept?.lamp == p2)

        // Closed, as the root closes it: the parked post back on the lamp.
        await h.stand(on: h.search.close())
        #expect(h.kept?.lamp == p2)
    }
}
#endif
