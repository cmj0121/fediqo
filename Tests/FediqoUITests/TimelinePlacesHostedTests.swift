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
@Suite("Where each timeline was left, hosted")
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
                search: search
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

        /// The rows the timeline in front holds, as the pane draws them.
        var rows: [String] { session.timelineItems(latest: nil).map(\.id) }

        /// `j` until the lamp is on this row.
        func stand(on id: String) {
            lamp.wanted = id
            lamp.tick += 1
            settle()
            #expect(lamp.seen == id)
        }

        func press(_ query: TimelineQuery) {
            session.timelineID = query
            settle()
        }

        func settle() {
            for _ in 0 ..< 4 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
    }

    private func note(_ id: String, _ author: String, _ categories: Set<FediqoCore.Category>, at t: Double) -> Note {
        Note(id: id, source: microblog, author: author, handle: "@\(author.lowercased())@m.example", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    private func harness() throws -> Harness {
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
        session.timelineID = .all
        let lamp = Lamp()
        let search = ShellSearch()
        let view = NSHostingView(rootView: Host(session: session, lamp: lamp, search: search))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let harness = Harness(session: session, lamp: lamp, search: search, view: view)
        harness.settle()
        return harness
    }

    private func written(_ session: ShellSession) throws -> TimelineQuery {
        .written(try #require(session.written.first).id)
    }

    /// The rows of one timeline that no other timeline in this pairing holds, so a lamp that
    /// merely survived a switch cannot pass for a place that was kept.
    private func own(_ query: TimelineQuery, against other: TimelineQuery, in harness: Harness) -> [String] {
        let session = harness.session
        let before = session.timelineID
        session.timelineID = other
        let theirs = Set(session.timelineItems(latest: nil).map(\.id))
        session.timelineID = query
        let mine = session.timelineItems(latest: nil).map(\.id)
        session.timelineID = before
        harness.settle()
        return mine.filter { !theirs.contains($0) }
    }

    // MARK: Acceptance: the four steps

    @Test("On X on post 1, to Y on post 2, back to X, back to Y: post 2 is lit")
    func theFourSteps() throws {
        let h = try harness()
        let x = TimelineQuery.all
        let y = TimelineQuery.trends
        h.press(x)
        let post1 = try #require(own(x, against: y, in: h).last)
        h.stand(on: post1)

        h.press(y)
        let post2 = try #require(own(y, against: x, in: h).last ?? h.rows.last)
        h.stand(on: post2)

        h.press(x)
        #expect(h.lamp.seen == post1, "step 3: X gives back post 1")

        h.press(y)
        #expect(h.lamp.seen == post2, "step 4: Y gives back post 2")
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
