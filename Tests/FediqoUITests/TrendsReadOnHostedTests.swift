#if os(macOS)
import AppKit
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #288: reading on through what is rising, asked of the real pane rather than of `ShellReload`.
///
/// **What this reaches.** `TimelinePane` drawn off-screen in an `NSHostingView` on the Trends
/// timeline, holding a list shorter than the pane — so every row is one of the last few, and
/// every row coming into view asks for more. The asks counted are the ones SwiftUI's own
/// `onAppear` made: nothing here calls `more` itself. Each test lets the pane settle, then turns
/// it many more times with no row added and no key pressed, and counts again: an ask that
/// changed nothing must not make another.
///
/// **What it does not reach.** No window is made and nothing is shown: the line at the foot in
/// light and dark, a finger on a phone and what VoiceOver says are for the user to check on a
/// running app.
///
/// **It gives the main actor back between passes**, for `TimelinePlacesHostedTests`' reasons, and
/// sets no language.
@Suite("What is rising read on from the pane asks a bounded number of times, hosted", .serialized)
@MainActor
struct TrendsReadOnHostedTests {
    nonisolated private static let one = "one.example"

    /// A source's trending list, answering every ask one way and counting them.
    private actor Rising: HTTPClient {
        enum Way: Sendable {
            /// Every ask fails.
            case fails
            /// Every ask, however far in, is answered with the same full stretch.
            case repeatsItsTop
            /// The top is all there is: fewer than a stretch.
            case ends
        }

        private let way: Way
        /// How far in each ask of the trending list was, in order.
        private(set) var offsets: [Int] = []
        /// Every other address asked for.
        private(set) var others: [URL] = []

        init(_ way: Way) { self.way = way }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            guard url.path == "/api/v1/trends/statuses" else {
                others.append(url)
                throw FixtureHTTPError.unmapped
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            offsets.append(items.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0)
            let ids: [Int]
            switch way {
            case .fails: throw FixtureHTTPError.unreachable
            case .repeatsItsTop: ids = Array(1...MastodonClient.trendsStretch)
            case .ends: ids = Array(1...TrendsReadOnHostedTests.held)
            }
            let body = "[" + ids.map(TrendsReadOnHostedTests.status).joined(separator: ",") + "]"
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    /// How many posts the device holds before the pane is drawn: fewer than `moreAhead`, so every
    /// one of them asks as it comes into view.
    nonisolated fileprivate static let held = 3

    nonisolated private static func key(_ id: Int) -> String { "https://\(one)/users/ada/statuses/\(id)" }

    nonisolated fileprivate static func status(_ id: Int) -> String {
        let stamp = String(format: "2024-01-01T%02d:%02d:00.000Z", id / 60, id % 60)
        return """
        {"id":"\(id)","uri":"\(key(id))",
         "created_at":"\(stamp)","content":"<p>\(id)</p>",
         "visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// The root's share of the pane, with nothing lit and no search open.
    private struct Host: View {
        let session: ShellSession
        let search: ShellSearch
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: PaneDefaults())

        var body: some View {
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
            .environment(prefs)
        }
    }

    /// The pane on Trends over a store holding `held` rising posts of one source, and the list
    /// answering as `way` says. The pane is far taller than anything these tests draw, so the
    /// whole list is in view and its end with it.
    private func pane(_ way: Rising.Way) async -> (ShellSession, Rising, NSView) {
        let source = Source(host: Self.one, kind: .mastodon)
        let store = ItemStore()
        await store.add(source)
        await store.ingest((1...Self.held).map { id in
            Note(
                id: Self.key(id), source: source, author: "Ada", handle: "@ada", body: "\(id)",
                postedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60), categories: [.trends],
                statusID: "\(id)"
            )
        })
        let http = Rising(way)
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])),
            timelines: WrittenTimelineStore(defaults: PaneDefaults())
        )
        await session.reloadFromStore()
        session.timelineID = .trends
        let view = NSHostingView(rootView: Host(session: session, search: ShellSearch()))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 6000)
        return (session, http, view)
    }

    /// One layout and a brief turn of the run loop — where the hosting view answers what changed
    /// and a row's `onAppear` runs — and the main actor handed back for the ask it started.
    private func settle(_ view: NSView) async {
        turn(view)
        for _ in 0 ..< 4 { await Task.yield() }
    }

    /// Synchronous, because the run loop cannot be turned from an async body.
    private func turn(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    /// The pane turned until it has asked at least once and nothing is out, then turned `more`
    /// times again with no row added and no key pressed. The asks made by then.
    private func asks(_ session: ShellSession, _ http: Rising, _ view: NSView, thenTurned more: Int = 40) async -> [Int] {
        let asked = await spun(5_000) {
            await settle(view)
            return await !http.offsets.isEmpty && session.reload.asking.isEmpty
        }
        #expect(asked, "the premise: a row coming into view asked for more")
        for _ in 0 ..< more { await settle(view) }
        #expect(session.reload.asking.isEmpty, "nothing is still out")
        return await http.offsets
    }

    /// Drawing the rows may ask the source for its custom emoji, which is the rows' business and
    /// not reading on's; that it is asked at most once, and nothing else at all, is what shows no
    /// other ask went round either.
    private func nothingElseLooped(_ http: Rising) async {
        let others = await http.others.map(\.absoluteString)
        #expect(others.count <= 1, "an address asked over and over: \(others)")
        #expect(others.allSatisfy { $0 == "https://\(Self.one)/api/v1/custom_emojis" }, "asked besides: \(others)")
    }

    private func rows(_ session: ShellSession) -> Int { session.timelineItems(latest: nil).count }

    @Test("A source failing every ask is asked once for the rows that came into view, and not again while nothing changes")
    func aSourceThatFails() async throws {
        let (session, http, view) = await pane(.fails)
        let first = await asks(session, http, view)
        #expect(first == [0], "one ask, of the top: the rows that came into view together asked together")
        #expect(rows(session) == Self.held, "nothing landed")
        #expect(session.reload.trendsEnded(of: .trends, in: session).isEmpty, "a failure is not the source's end")

        for _ in 0 ..< 60 { await settle(view) }
        #expect(await http.offsets == first, "failing, it did not ask again with no new row and no press")
        await nothingElseLooped(http)
    }

    @Test("A source answering every ask with its top again is asked twice — the top, and once further in — and then no more")
    func aSourceThatRepeatsItsTop() async throws {
        let (session, http, view) = await pane(.repeatsItsTop)
        let done = await spun(5_000) {
            await settle(view)
            return !session.reload.trendsEnded(of: .trends, in: session).isEmpty && session.reload.asking.isEmpty
        }
        #expect(done, "the same stretch come twice is the source having no more")
        let first = await http.offsets
        #expect(first == [0, MastodonClient.trendsStretch], "the rows that landed came into view and asked once more")
        #expect(rows(session) == MastodonClient.trendsStretch, "the stretch landed once")

        for _ in 0 ..< 60 { await settle(view) }
        #expect(await http.offsets == first, "ended, it is not asked again — the foot coming into view asks nothing")
        #expect(rows(session) == MastodonClient.trendsStretch)
        await nothingElseLooped(http)
    }

    @Test("A source whose top is all there is is asked once, says so at the foot, and is not asked again")
    func aSourceThatEnds() async throws {
        let (session, http, view) = await pane(.ends)
        let first = await asks(session, http, view)
        #expect(first == [0], "one ask, of the top")
        #expect(session.reload.trendsEnded(of: .trends, in: session) == [Self.one], "a short stretch is the end")
        #expect(rows(session) == Self.held, "what was held is what there is")

        for _ in 0 ..< 60 { await settle(view) }
        #expect(await http.offsets == first, "the foot drawn, and the redraw it caused, asked nothing")
        await nothingElseLooped(http)
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class PaneDefaults: UserDefaults, @unchecked Sendable {
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
