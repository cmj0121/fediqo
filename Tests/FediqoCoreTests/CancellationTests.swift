import Foundation
import Testing
@testable import FediqoCore

/// Every place a reader walking away could be written down as a fact about somebody's server.
///
/// **One suite for one bug class, on purpose.** These sites live in four files and share nothing
/// but the mistake: `catch is CancellationError` beside a swallow, which against a real
/// `URLSession` never fires, because a cancelled transfer arrives as `URLError(.cancelled)`. The
/// tests are gathered here rather than filed under each client so that the class can be read in
/// one sitting, and so that deleting a fix has an obvious place to show up.
///
/// Nothing here could be written before `FixtureHTTP.Outcome.cancelled` existed. That is why the
/// class stayed latent through fourteen sites and 298 green tests: there was no way to produce
/// the error that the product produces.
@Suite("The reader who walked away")
struct CancellationTests {
    // MARK: - Fixtures

    private static let mastodonFront = #"""
    <html><head><meta name="application-name" content="Mastodon"></head>
    <body><div id="mastodon"></div></body></html>
    """#

    private static let instance = #"""
    {"domain": "first.example", "title": "First", "version": "4.3.0"}
    """#

    private static let statuses = #"""
    [{"id": "100", "uri": "https://first.example/users/ada/statuses/1",
      "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Hello</p>",
      "visibility": "public",
      "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
    """#

    private static let discourseFront = #"""
    <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
    """#

    private static let latest = #"""
    {"users": [{"id": 1, "username": "ada", "name": "Ada"}],
     "topic_list": {"topics": [
       {"id": 7, "title": "A thread", "slug": "a-thread", "posts_count": 2, "reply_count": 1,
        "category_id": 3, "created_at": "2024-01-01T00:00:00.000Z",
        "last_posted_at": "2024-01-02T00:00:00.000Z", "posters": [{"user_id": 1}]}
     ]}}
    """#

    private static let site = #"""
    {"categories": [{"id": 3, "name": "General"}]}
    """#

    private static let discuzFront = #"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
    """#

    /// Three boards, in the order a pick iterates them: one that reads, one that is walked away
    /// from, and one that must never be asked for.
    private static let discuzIndex = #"""
    <h2><a href="forum.php?gid=56">Tools and software</a></h2>
    <div id="category_56">
    <table class="fl_tb"><tr>
    <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
    <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=40">Imaging tools</a></dt></dl></td>
    <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=41">Virtual machines</a></dt></dl></td>
    </tr></table>
    </div>
    """#

    private static func boardPage(_ fid: Int) -> String {
        #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=\#(fid)">A board</a></h1>
        <table>
        <tbody id="normalthread_45103\#(fid)">
        <tr>
        <th class="new"><a href="thread-45103\#(fid)-1-1.html" class="s xst">A thread on \#(fid)</a></th>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 08:12">7&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-45103\#(fid)-1-1.html" class="xi2">29</a><em>3480</em></td>
        </tr>
        </tbody>
        </table>
        """#
    }

    private static func discuzHTTP(boards: [Int: FixtureHTTP.Outcome]) -> FixtureHTTP {
        var routes: [String: FixtureHTTP.Outcome] = [
            "/": .text(discuzFront),
            "https://install-a.example/forum.php": .text(discuzIndex),
        ]
        for (fid, outcome) in boards {
            routes["https://install-a.example/forum.php?mod=forumdisplay&fid=\(fid)&filter=author&orderby=dateline"] = outcome
        }
        return FixtureHTTP(routes)
    }

    private static func joiner(_ http: FixtureHTTP, _ store: ItemStore) -> SourceJoin {
        SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
    }

    // MARK: - Detection

    @Test("Walking away during the front page is not a host that speaks something else")
    func cancelledFrontPage() async {
        // Without the fix the front page's failure is swallowed as "no answer yet", the probe is
        // spent on a reader who is gone, and the detector answers `.mastodon` — a fact about a
        // server, recorded from a reader's leaving.
        let http = FixtureHTTP(["/": .cancelled, "/api/v2/instance": .text(Self.instance)])
        await #expect(throws: CancellationError.self) {
            try await Detector(http: http).detect("first.example")
        }
    }

    @Test("Walking away during the probe is not an unknown protocol")
    func cancelledProbe() async {
        // The one QA verified: the front page said nothing, the probe is cancelled, and the
        // guard beneath it never fires — so detection falls through to `.unknown`, which
        // `SourceJoin` turns into `unsupportedKind` and the reader is told to check an address
        // that is perfectly fine. The comment ten lines above that fall-through names that
        // sentence as the thing to avoid.
        let http = FixtureHTTP([
            "/": .text("<html><head></head><body>Nothing that names itself</body></html>"),
            "/api/v2/instance": .cancelled,
        ])
        await #expect(throws: CancellationError.self) {
            try await Detector(http: http).detect("first.example")
        }
    }

    @Test("Walking away during detection adds nothing and blames nobody")
    func cancelledDetectionAddsNothing() async {
        let http = FixtureHTTP(["/": .cancelled, "/api/v2/instance": .text(Self.instance)])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await Self.joiner(http, store).begin(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("The one-shot door reports a leaving as a leaving too")
    func cancelledDetectionOnTheOneShotDoor() async {
        let http = FixtureHTTP(["/": .cancelled, "/api/v2/instance": .text(Self.instance)])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - Mastodon

    @Test("Walking away during the public timeline is not a host that could not be reached")
    func cancelledPublicTimeline() async {
        let http = FixtureHTTP([
            "/": .text(Self.mastodonFront),
            "/api/v2/instance": .text(Self.instance),
            "/api/v1/timelines/public": .cancelled,
            "/api/v1/trends/statuses": .text("[]"),
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Walking away during trends does not join the server behind the reader's back")
    func cancelledTrending() async {
        // **The site QA's list did not name, and it is `Discourse.profile`'s bug exactly.**
        // Trends are allowed to fail, so every way they can fail is swallowed to `[]` — and a
        // cancelled transfer is one of those ways. Without the fix the join carries on to
        // `store.add` and `store.ingest` for a reader who is no longer there, and the server is
        // in their list the next time they open the app.
        let http = FixtureHTTP([
            "/": .text(Self.mastodonFront),
            "/api/v2/instance": .text(Self.instance),
            "/api/v1/timelines/public": .text(Self.statuses),
            "/api/v1/trends/statuses": .cancelled,
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await MastodonJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    // MARK: - Discourse

    @Test("Walking away during a forum's front page leaves no source behind")
    func cancelledDiscourseLatest() async {
        let http = FixtureHTTP([
            "/": .text(Self.discourseFront),
            "/latest.json": .cancelled,
            "/site.json": .text(Self.site),
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await Self.joiner(http, store).join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Walking away during the category names does not join the forum anyway")
    func cancelledDiscourseCategories() async {
        // `/site.json` is allowed to fail — a forum that will not answer it still has a readable
        // front page — so the swallow beside it is correct and the cancellation clause beside
        // *that* was the dead one. `DiscourseClient.profile` already carries this fix and its
        // comment names `latest` as the twin that does not; this is that twin.
        let http = FixtureHTTP([
            "/": .text(Self.discourseFront),
            "/latest.json": .text(Self.latest),
            "/site.json": .cancelled,
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await Self.joiner(http, store).join(host: "first.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    // MARK: - Discuz!

    @Test("Walking away during a Discuz! guide page leaves no source behind")
    func cancelledDiscuzLatest() async {
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "/forum.php": .cancelled,
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await DiscuzJoin(http: http, store: store).ingest(host: "install-a.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Walking away during the index is not a forum that could not be reached")
    func cancelledDiscuzIndex() async {
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "/forum.php": .cancelled,
        ])
        let store = ItemStore()
        await #expect(throws: CancellationError.self) {
            try await Self.joiner(http, store).begin(host: "install-a.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - The pick, which is the one with consequences

    @Test("Walking away mid-pick stops the loop, spends nothing more, and adds nothing")
    func cancelledMidPickStopsAndAddsNothing() async throws {
        // **The worst of the fourteen.** Board 33 reads. Board 40 is the reader closing the app.
        // Without the fix that leaving becomes `UnreadBoard(.unreachable)` — a permanent record
        // that somebody's real board is broken — the loop carries on and spends a request on
        // board 41 for nobody, and because board 33 succeeded the whole of `store.add`,
        // `store.subscribe` and `store.ingest` then runs behind a reader who has gone.
        let http = Self.discuzHTTP(boards: [
            33: .text(Self.boardPage(33)),
            40: .cancelled,
            41: .text(Self.boardPage(41)),
        ])
        let store = ItemStore()
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-a.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        await #expect(throws: CancellationError.self) {
            try await join.subscribe(offer, to: offer.boards, keeping: [])
        }
        // Nothing written, though one board read perfectly well before the reader left.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
        // And the loop stopped: board 41 was never asked for. A reader who walks away does not
        // go on spending a stranger's bandwidth one request per remaining pick.
        let asked = await http.requested.map(\.absoluteString)
        #expect(asked.contains { $0.contains("fid=40") })
        #expect(!asked.contains { $0.contains("fid=41") })
    }

    @Test("Walking away on the first board is the same nothing")
    func cancelledFirstPick() async throws {
        let http = Self.discuzHTTP(boards: [
            33: .cancelled,
            40: .text(Self.boardPage(40)),
            41: .text(Self.boardPage(41)),
        ])
        let store = ItemStore()
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-a.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        await #expect(throws: CancellationError.self) {
            try await join.subscribe(offer, to: offer.boards, keeping: [])
        }
        #expect(await store.sources().isEmpty)
        let asked = await http.requested.map(\.absoluteString)
        #expect(!asked.contains { $0.contains("fid=40") })
        #expect(!asked.contains { $0.contains("fid=41") })
    }
}
