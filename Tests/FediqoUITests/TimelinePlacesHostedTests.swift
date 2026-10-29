#if os(macOS)
import AppKit
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #144: the place each timeline keeps, asked of the real pane rather than of `TimelinePlaces`.
///
/// **Hosted, and wired the way the root wires it.** `TimelinePane` is drawn off-screen in an
/// `NSHostingView`, handed a lamp held in `@State` exactly as `FediqoRootView` holds
/// `selectedItemID`, and handed the root's `ShellSearch` — an object that is always there and is
/// merely closed while no search is open. A lamp moved is `j` landing on a row; a timeline
/// switched is Tab (`rotateTab`) or a press on its pill (`timelineID`), the two ways the reader
/// changes timeline. Nothing here stands in for the pane's own `onChange`, which is the code
/// under test.
///
/// What it does not reach: a window, a hand on the trackpad, or iOS. Those are the user's.
///
/// **It gives the main actor back between passes.** Every test in this process that waits on the
/// main actor — the reload, join and subscribe suites behind `FixtureHTTP`'s gates — waits behind
/// whatever holds it, and a nested `RunLoop.main.run` does not drain the main queue: an earlier
/// version turned it four times per switch and, on a loaded runner, held the main actor for most of
/// a minute, until the guards those suites then had, which went by a clock, fired. Each settle
/// here is one layout, one brief pass of the run loop and a `Task.yield()`, and the rows a test
/// stands on are worked out from the session without drawing anything.
@Suite("Where each timeline was left, hosted", .serialized, .watched)
@MainActor
struct TimelinePlacesHostedTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)

    init() {
        L10n.language = .english
    }

    /// The lamp, written the way a key writes it and read back after the pane has answered.
    @Observable
    @MainActor
    final class Lamp {
        /// What the next pass should light — `j` landing on a row — and a tick to say so.
        var wanted: String?
        var tick = 0
        /// What the lamp is on, as the pane last saw it.
        @ObservationIgnored var seen: String?
    }

    /// The root's share of the pane: a lamp in `@State`, a search that is always there.
    private struct Host: View {
        let session: ShellSession
        let lamp: Lamp
        let search: ShellSearch
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: HostedDefaults())

        var body: some View {
            lamp.seen = selected
            return TimelinePane(
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
                search: search, serverFilters: true
            )
            .environment(prefs)
            .onChange(of: lamp.tick) { _, _ in selected = lamp.wanted }
        }
    }

    @MainActor
    private struct Harness {
        let session: ShellSession
        let lamp: Lamp
        let search: ShellSearch
        let view: NSView

        /// The rows a timeline holds, worked out from the session rather than drawn — asking it
        /// by switching would be a switch, and one the pane would answer.
        func rows(of query: TimelineQuery) -> [String] {
            query.items(from: session.notes, among: session.written, index: session.textIndex, latest: nil).map(\.id)
        }

        /// `j` until the lamp is on this row.
        func stand(on id: String?) async {
            lamp.wanted = id
            lamp.tick += 1
            await settle()
            // No `by:`: the run loop is turned here, by the check.
            await met("the lamp is on the row the key landed on") {
                turn()
                return lamp.seen == id
            }
        }

        func press(_ query: TimelineQuery) async {
            session.timelineID = query
            await settle()
        }

        /// Tab until this timeline is in front: each press its own switch, as the reader's are.
        func tab(to query: TimelineQuery) async {
            while session.currentTimeline != query {
                session.rotateTab(by: 1)
                await settle()
            }
        }

        /// The lamp is on `id`: what a switch gave back, waited for with the run loop turned.
        /// No `by:`: the run loop is turned here, by the check.
        func gives(
            _ id: String, _ what: String = "the timeline gives back the post it was left on",
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            await met(what, sourceLocation: sourceLocation) {
                turn()
                return lamp.seen == id
            }
        }

        /// One change answered: the pane's `onChange`, then the lamp it wrote. Two passes, each
        /// a layout and a brief turn of the run loop, and the main actor handed back after each.
        /// Counted passes, and room only: a check that then wants a post lit waits for it
        /// (`gives`, `stand`); only one that wants the lamp out looks straight after them.
        func settle() async {
            for _ in 0 ..< 2 {
                turn()
                await Task.yield()
            }
        }

        /// One layout and a brief turn of the run loop, which is where the hosting view answers
        /// what changed. Synchronous, because the run loop cannot be turned from an async body.
        private func turn() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
    }

    private func note(_ id: String, _ author: String, _ categories: Set<FediqoCore.Category>, at t: Double) -> Note {
        Note(id: id, source: microblog, author: author, handle: "@\(author.lowercased())@m.example", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    private func harness() async throws -> Harness {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: HostedDefaults()))
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
        // The timeline beside All that holds what is trending, now Trends is a place of its own.
        var others = TimelineDraft(new: 2)
        others.name = "Cy and Dee"
        others.position = 1
        others.rules = [
            try #require(Rule.author("@cy@m.example", in: .every, sources: [])),
            try #require(Rule.author("@dee@m.example", in: .every, sources: [])),
        ]
        session.commit(others)
        session.timelineID = .all
        let lamp = Lamp()
        let search = ShellSearch()
        let view = NSHostingView(rootView: Host(session: session, lamp: lamp, search: search))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let harness = Harness(session: session, lamp: lamp, search: search, view: view)
        await harness.settle()
        return harness
    }

    private func written(_ session: ShellSession) throws -> TimelineQuery {
        .written(try #require(session.written.first).id)
    }

    /// The written timeline of what is trending: Cy's and Dee's posts.
    private func second(_ session: ShellSession) throws -> TimelineQuery {
        .written(try #require(session.written.first { $0.name == "Cy and Dee" }).id)
    }

    /// The rows of one timeline that no other timeline in this pairing holds, so a lamp that
    /// merely survived a switch cannot pass for a place that was kept.
    private func own(_ query: TimelineQuery, against other: TimelineQuery, in harness: Harness) -> [String] {
        let theirs = Set(harness.rows(of: other))
        return harness.rows(of: query).filter { !theirs.contains($0) }
    }

    // MARK: Acceptance: the four steps

    @Test("On X on post 1, to Y on post 2, back to X, back to Y: post 2 is lit")
    func theFourSteps() async throws {
        let h = try await harness()
        let x = TimelineQuery.all
        let y = try second(h.session)
        await h.press(x)
        let post1 = try #require(own(x, against: y, in: h).last)
        await h.stand(on: post1)

        await h.press(y)
        let post2 = try #require(own(y, against: x, in: h).last ?? h.rows(of: y).last)
        await h.stand(on: post2)

        await h.press(x)
        await h.gives(post1, "step 3: X gives back post 1")

        await h.press(y)
        await h.gives(post2, "step 4: Y gives back post 2")
    }

    // MARK: Acceptance: any number of trips, any pairing

    /// The posts to stand on in each timeline: one from the middle of the list, so neither the
    /// top row nor a lamp that merely survived the switch can pass for it — and, where the other
    /// timeline holds rows this one does not, one of those.
    private func post(in query: TimelineQuery, against other: TimelineQuery, in h: Harness) throws -> String {
        let own = own(query, against: other, in: h)
        if let post = own.dropFirst().first ?? own.first { return post }
        return try #require(h.rows(of: query).dropFirst().first)
    }

    /// X → Y → X → Y → X → Y, every arrival checked, for each pairing of All and two written
    /// timelines, by both ways of switching. One order per pairing: the trips go both
    /// ways already, so the reversed order would ask each switch a second time.
    @Test("Going back and forth lands, every time, on the post each was left on", arguments: [false, true])
    func backAndForth(byTab: Bool) async throws {
        // `nil` is the reader's first timeline, and `.trends` stands for the second.
        let pairings: [(TimelineQuery?, TimelineQuery?)] = [(.all, .trends), (.all, nil), (nil, .trends)]
        for (a, b) in pairings {
            let h = try await harness()
            func resolved(_ query: TimelineQuery?) throws -> TimelineQuery {
                switch query {
                case nil: try written(h.session)
                case .trends?: try second(h.session)
                case let query?: query
                }
            }
            let x = try resolved(a)
            let y = try resolved(b)
            func go(_ query: TimelineQuery) async {
                if byTab { await h.tab(to: query) } else { await h.press(query) }
            }
            let xPost = try post(in: x, against: y, in: h)
            let yPost = try post(in: y, against: x, in: h)
            await go(x)
            await h.stand(on: xPost)
            await go(y)
            await h.stand(on: yPost)
            for trip in 1 ... 2 {
                await go(x)
                await h.gives(xPost, "\(x) → back on trip \(trip)")
                await go(y)
                await h.gives(yPost, "\(y) → back on trip \(trip)")
            }
        }
    }

    /// Arriving at one timeline is not a write to another's: a third timeline passed through
    /// on the way, standing on something else, leaves X's and Y's where they were.
    @Test("Passing through a third timeline changes neither of the other two")
    func aThirdChangesNeither() async throws {
        let h = try await harness()
        let others = try second(h.session)
        let mine = try written(h.session)
        let allPost = try post(in: .all, against: others, in: h)
        let trendPost = try post(in: others, against: mine, in: h)
        await h.press(.all)
        await h.stand(on: allPost)
        await h.press(others)
        await h.stand(on: trendPost)
        await h.press(mine)
        await h.stand(on: try #require(h.rows(of: mine).last))
        await h.press(.all)
        await h.gives(allPost)
        await h.press(mine)
        await h.press(others)
        await h.gives(trendPost)
    }

    /// A post that has left the timeline since is not pretended to be there, however many trips
    /// it took — and the other timeline's place is not disturbed by finding it gone.
    @Test("A post that has since left its timeline is not lit, on the second trip or the third")
    func aPostThatLeftIsNotLit() async throws {
        let h = try await harness()
        let others = try second(h.session)
        let allPost = try post(in: .all, against: others, in: h)
        let trendPost = try post(in: others, against: .all, in: h)
        await h.press(.all)
        await h.stand(on: allPost)
        await h.press(others)
        await h.stand(on: trendPost)
        await h.press(.all)
        await h.gives(allPost)
        // A reload lands without the trending post the reader was on.
        h.session.notes = h.session.notes.filter { $0.id != String(trendPost.split(separator: "\u{1E}").last ?? "") }
        await h.settle()
        await h.press(others)
        #expect(h.lamp.seen == nil)
        await h.press(.all)
        await h.gives(allPost)
        await h.press(others)
        #expect(h.lamp.seen == nil)
    }

    /// #100's parking, still: with the search open nothing is written into a timeline's place,
    /// and closing it gives back the post the timeline was on.
    @Test("With the search open a switch writes no place, and closing gives the parked post back")
    func theSearchStillParks() async throws {
        let h = try await harness()
        let others = try second(h.session)
        let allPost = try post(in: .all, against: others, in: h)
        let trendPost = try post(in: others, against: .all, in: h)
        await h.press(others)
        await h.stand(on: trendPost)
        await h.press(.all)
        await h.stand(on: allPost)
        // `/`, as the root opens it: the lamp parked in the search and put out.
        h.search.open(from: h.lamp.seen, over: h.session.notes)
        await h.stand(on: nil)
        await h.press(others)
        await h.press(.all)
        // Closed, as the root closes it: the parked post back on the lamp.
        await h.stand(on: h.search.close())
        await h.gives(allPost)
        await h.press(others)
        await h.gives(trendPost)
    }

    /// #145 on top of #100 and #144: a timeline switched under an open search is searched with
    /// the pattern kept, and closing the search gives back the post of the timeline the reader
    /// is now in — each timeline's place still its own.
    @Test("Switched with the search open, closing gives back the place of the timeline arrived at")
    func switchedUnderTheSearch() async throws {
        let h = try await harness()
        let others = try second(h.session)
        let mine = try written(h.session)
        let allPost = try post(in: .all, against: others, in: h)
        let trendPost = try post(in: others, against: .all, in: h)
        await h.press(others)
        await h.stand(on: trendPost)
        await h.press(.all)
        await h.stand(on: allPost)
        h.search.open(from: h.lamp.seen, over: h.session.notes)
        await h.stand(on: nil)
        await h.search.indexed()
        h.search.text = "*"
        h.search.settle("*")
        await h.settle()
        // A result lit on All, then the other in front: the pattern is kept and it is searched.
        let result = try #require(h.session.searched(h.search, latest: nil)?.first?.id)
        await h.stand(on: result)
        await h.press(others)
        #expect(h.search.text == "*")
        let found = try #require(h.session.searched(h.search, latest: nil)).map(\.id)
        #expect(found == h.rows(of: others))
        if let lit = h.lamp.seen { #expect(found.contains(lit)) }
        // Through a written timeline and back to the other, still searching.
        await h.press(mine)
        await h.press(others)
        await h.stand(on: h.search.close())
        await h.gives(trendPost, "its own place, not All's")
        await h.press(.all)
        await h.gives(allPost, "All's place was written down, not the result")
        await h.press(others)
        await h.gives(trendPost)
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class HostedDefaults: UserDefaults, @unchecked Sendable {
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
#endif
