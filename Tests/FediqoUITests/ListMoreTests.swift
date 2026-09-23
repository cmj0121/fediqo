import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Listing a timeline asks for more as you go (#87).
///
/// What a test can reach: which sources are asked for what, and for which stretch; what lands and
/// what does not move; a stretch not asked twice nor past its end; a failure leaving the listing as
/// it was; two asks landing one row; and the rule for when a row coming into view asks. What it
/// cannot: a real scroll reaching the end on a Mac and a phone — that lives in a lazy stack.
@MainActor
@Suite("Listing asks for more as you go")
struct ListMoreTests {
    private static let one = "one.example"
    private static let forum = "forum.example"

    init() {
        L10n.language = .english
    }

    private static func status(_ id: String, day: Int) -> String {
        """
        {"id":"\(id)","uri":"https://\(one)/users/ada/statuses/\(id)",
         "created_at":"2024-01-\(String(format: "%02d", day))T00:00:00.000Z","content":"<p>\(id)</p>",
         "visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func page(_ statuses: String...) -> FixtureHTTP.Outcome {
        .text("[" + statuses.joined(separator: ",") + "]")
    }

    private static func newest(_ host: String = one) -> String { "https://\(host)/api/v1/timelines/public?limit=40" }
    private static func older(than id: String) -> String { newest() + "&max_id=\(id)" }
    private static let trends = "https://\(one)/api/v1/trends/statuses?limit=20"
    private static let boardFirst =
        "https://\(forum)/forum.php?mod=forumdisplay&fid=34&filter=author&orderby=dateline"
    private static func board(page: Int) -> String { boardFirst + "&page=\(page)" }

    private static func board(_ threads: (tid: Int, title: String)...) -> FixtureHTTP.Outcome {
        .text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=34">工具箱讨论区</a></h1>
        <table id="threadlisttableid">
        """# + threads.map { thread in
            #"""
            <tbody id="normalthread_\#(thread.tid)"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=\#(thread.tid)" class="s xst">\#(thread.title)</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            <td class="num"><a href="forum.php?mod=viewthread&tid=\#(thread.tid)" class="xi2">7</a><em>120</em></td>
            </tr></tbody>
            """#
        }.joined() + "</table></body></html>")
    }

    /// Posts 5 and 6 held from `one.example`'s public timeline, and thread 40125 from board 34.
    private static var held: [Note] {
        let mastodon = Source(host: one, kind: .mastodon)
        let discuz = Source(host: forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "工具箱讨论区")])
        return ["5", "6"].map { id in
            Note(
                id: "https://\(one)/users/ada/statuses/\(id)", source: mastodon, author: "Ada",
                handle: "@ada", body: id, postedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id)!),
                categories: [.public], statusID: id
            )
        } + [
            Note(
                id: "discuz:\(forum):40125", source: discuz, author: "tinbox", handle: "tinbox", body: "",
                title: "工具箱一键下载安装", postedAt: Date(timeIntervalSince1970: 1_900_000_000),
                categories: [.board(id: "34")]
            ),
        ]
    }

    private func shell(_ http: any HTTPClient) async -> ShellSession {
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.add(Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "工具箱讨论区")]
        ))
        await store.ingest(Self.held)
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        return session
    }

    private func ids(_ session: ShellSession) -> [String] {
        session.timelineItems(latest: nil).map(\.noteID)
    }

    // MARK: - What is asked, and what lands

    @Test("The timeline's sources are asked for the stretch past what is held, and new posts appear below")
    func asksPastTheEnd() async throws {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(Self.status("3", day: 3), Self.status("4", day: 4)),
            Self.board(page: 2): Self.board((40100, "舊的一篇")),
        ])
        let session = await shell(http)
        let before = ids(session)
        let selected = try #require(before.first)

        await session.reload.more(.all, in: session)

        let asked = Set(await http.requested.map(\.absoluteString))
        #expect(asked == [Self.older(than: "5"), Self.board(page: 2)], "each read one stretch further, and nothing else")
        let after = ids(session)
        #expect(Array(after.prefix(before.count)) == before, "what was there is where it was")
        #expect(after.contains("https://\(Self.one)/users/ada/statuses/3"))
        #expect(after.contains("https://\(Self.one)/users/ada/statuses/4"), "a new Mastodon post appears")
        #expect(after.contains("discuz:\(Self.forum):40100"), "and a new forum post")
        #expect(after.contains(selected), "the post being read is still there to be selected")
        #expect(session.reload.landed == 0, "and the list is not re-centred: nothing jumps")
        #expect(!session.reload.running)
        #expect(session.reload.line == nil)
    }

    @Test("A post missing from what the source sent is neither dropped nor marked")
    func missingSaysNothing() async throws {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(Self.status("3", day: 3)),
            Self.board(page: 2): Self.board((40100, "舊的一篇")),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        for note in Self.held {
            let row = try #require(session.held(note.key.rowID), "\(note.id) is still held")
            #expect(row.goneSince == nil)
        }
    }

    @Test("A stretch is not asked twice, and not past its end")
    func notTwiceNorPastTheEnd() async {
        let http = FixtureHTTP([
            // Nothing older on the Mastodon; the forum's third page is its second again, as a
            // Discuz! answers past its last page.
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40100, "二")),
            Self.board(page: 3): Self.board((40100, "二")),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        #expect(await http.requested.count == 2)
        await session.reload.more(.all, in: session)
        #expect(await http.requested.map(\.absoluteString).last == Self.board(page: 3), "the Mastodon is at its end")
        let asked = await http.requested.count
        #expect(asked == 3)
        await session.reload.more(.all, in: session)
        #expect(await http.requested.count == asked, "both at their end: nothing asked again")
    }

    @Test("A page this device already holds is not the end: an earlier run's page two leads on to page three")
    func heldIsNotTheEnd() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40125, "工具箱一键下载安装")),
            Self.board(page: 3): Self.board((40090, "三")),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await http.requested.map(\.absoluteString).contains(Self.board(page: 3)))
        #expect(ids(session).contains("discuz:\(Self.forum):40090"))
    }

    @Test("Esc does not stop an ask for more: scrolling started it, not a key")
    func escLeavesIt() async {
        let gated = GatedHTTP([
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40100, "二")),
        ], holding: Self.older(than: "5"))
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let more = Task { await session.reload.more(.all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        #expect(!session.reload.stop(), "nothing pressed to stop")
        #expect(session.reload.asking == [.more])
        #expect(!session.reload.stopped)
        await gated.gate.open()
        await more.value
        #expect(ids(session).contains("discuz:\(Self.forum):40100"))
    }

    @Test("The wait does not start while an ask for more is out")
    func waitHoldsOff() async {
        let gated = GatedHTTP([Self.older(than: "5"): Self.page()], holding: Self.older(than: "5"))
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let more = Task { await session.reload.more(.all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        await session.reload.held(in: session)
        #expect(session.reload.asking == [.more], "the wait asked nothing")
        await gated.gate.open()
        await more.value
    }

    @Test("A forum page read before r started its pages over is not recorded over the restart")
    func staleRestart() async {
        let gated = GatedHTTP([
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40100, "二")),
            Self.newest(): Self.page(),
            Self.trends: Self.page(),
            Self.boardFirst: Self.board((40125, "工具箱一键下载安装")),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ], holding: Self.board(page: 2))
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let more = Task { await session.reload.more(.all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        await session.reload.timeline(.all, in: session)
        await gated.gate.open()
        await more.value
        let before = await gated.asks
        await session.reload.more(.all, in: session)
        #expect(await gated.asks == before + 1, "page two asked again, not page three")
    }

    @Test("A host the ask for more missed is not still named once r reads it whole")
    func answeredClears() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): .text("", status: 500),
            Self.board(page: 2): Self.board((40100, "二")),
            Self.newest(): Self.page(),
            Self.trends: Self.page(),
            Self.boardFirst: Self.board((40125, "工具箱一键下载安装")),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        #expect(session.reload.failed == [Self.one])
        await session.reload.held(in: session)
        #expect(session.reload.failed.isEmpty)
    }

    @Test("A forum's stretch goes on a page at a time while each brings something new")
    func pageAfterPage() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40100, "二")),
            Self.board(page: 3): Self.board((40090, "三")),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        let asked = await http.requested.map(\.absoluteString)
        #expect(asked.filter { $0.hasPrefix(Self.boardFirst) } == [Self.board(page: 2), Self.board(page: 3)])
        #expect(ids(session).contains("discuz:\(Self.forum):40090"))
    }

    @Test("A Mastodon stretch that brought older posts is asked again from the new oldest")
    func fromTheNewOldest() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(Self.status("4", day: 4)),
            Self.older(than: "4"): Self.page(),
            Self.board(page: 2): Self.board((40125, "工具箱一键下载安装")),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await http.requested.map(\.absoluteString).filter { $0.contains("max_id") }
                == [Self.older(than: "5"), Self.older(than: "4")])
    }

    // MARK: - Failing, and landing together

    @Test("An ask that fails leaves the listing as it was, and says so in the reload's words")
    func failureLeavesTheList() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): .text("", status: 500),
            Self.board(page: 2): .fail,
        ])
        let session = await shell(http)
        let before = session.timelineItems(latest: nil)
        await session.reload.more(.all, in: session)
        #expect(session.timelineItems(latest: nil) == before)
        #expect(Set(session.reload.failed) == [Self.one, Self.forum])
        #expect(session.reload.line == String(format: L10n.t("timeline.reload.failed"), session.reload.failed.joined(separator: ", ")))
        // Failed is not asked: the same stretch is asked again next time.
        await session.reload.more(.all, in: session)
        #expect(await http.requested.count == 4)
    }

    @Test("Asked while r reads: only the Mastodon's next stretch, the forum left to r; both landing leave one row")
    func landingTogether() async throws {
        let shared = Self.status("4", day: 4)
        let gated = GatedHTTP([
            Self.older(than: "5"): Self.page(shared),
            Self.board(page: 2): Self.board((40100, "二")),
            Self.newest(): Self.page(shared),
            Self.trends: Self.page(),
            Self.boardFirst: Self.board((40125, "工具箱一键下载安装")),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ], holding: Self.newest())
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)

        let reload = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        await session.reload.more(.all, in: session)
        #expect(session.reload.asking == [.timeline], "the ask for more ran beside r and finished")
        let asked = await gated.requested()
        #expect(!asked.contains(Self.board(page: 2)), "no forum asked twice at once")
        #expect(asked.contains(Self.older(than: "5")))
        #expect(TimelineToast.shown(
            running: session.reload.running, waiting: session.reload.onlyWaiting,
            line: session.reload.line, stopped: session.reload.stopped, note: nil
        )?.kind == .loading, "on its way, as every other wait says it")
        await gated.gate.open()
        await reload.value

        let key = "https://\(Self.one)/users/ada/statuses/4"
        #expect(ids(session).filter { $0 == key }.count == 1)
        #expect(await session.store.snapshot().notes.filter { $0.id == key }.count == 1)
    }

    @Test("r starts a forum's stretches over: its newest page moved every page under it along")
    func rStartsOver() async {
        let http = FixtureHTTP([
            Self.older(than: "5"): Self.page(),
            Self.board(page: 2): Self.board((40125, "工具箱一键下载安装")),
            Self.newest(): Self.page(),
            Self.trends: Self.page(),
            Self.boardFirst: Self.board((40125, "工具箱一键下载安装")),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ])
        let session = await shell(http)
        await session.reload.more(.all, in: session)
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        let pages = await http.requested.map(\.absoluteString).filter { $0 == Self.board(page: 2) }
        #expect(pages.count == 2)
        let mastodon = await http.requested.map(\.absoluteString).filter { $0 == Self.older(than: "5") }
        #expect(mastodon.count == 1, "an id says what is older than it whatever arrived since")
    }

    @Test("Signed in, Home is asked as the reader for the stretch before its oldest post")
    func homeAsTheReader() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let server = ActServer(["/api/v1/timelines/home": .json("[" + Self.status("2", day: 2) + "]")])
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.ingest([Note(
            id: "https://\(Self.one)/users/ada/statuses/7", source: Source(host: Self.one, kind: .mastodon),
            author: "Ada", handle: "@ada", body: "7", postedAt: Date(timeIntervalSince1970: 1_800_000_000),
            categories: [.home], statusID: "7"
        )])
        let session = ShellSession(
            http: FixtureHTTP([Self.older(than: "7"): Self.page()]), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()

        await session.reload.more(.all, in: session)
        let asked = await server.requests.compactMap(\.url).filter { $0.path == "/api/v1/timelines/home" }
        #expect(asked.count == 1)
        #expect(asked.first?.query?.contains("max_id=7") == true)
        #expect(ids(session).contains("https://\(Self.one)/users/ada/statuses/2"))
        #expect(session.notes.first { $0.statusID == "2" }?.categories == [.home])
    }

    @Test("A timeline asks only its own sources' own reads: Trends has no next stretch")
    func onlyItsOwn() async {
        let http = FixtureHTTP([:])
        let session = await shell(http)
        await session.reload.more(.trends, in: session)
        #expect(await http.requested.isEmpty)
        #expect(!session.reload.running)
    }

    // MARK: - When it is asked

    @Test("A row coming into view asks near the end of a timeline, and never in a search")
    func whenARowAsks() {
        let ahead = TimelinePane.moreAhead
        #expect(!TimelinePane.asksForMore(at: 0, of: 40, searching: false))
        #expect(!TimelinePane.asksForMore(at: 40 - ahead - 1, of: 40, searching: false))
        #expect(TimelinePane.asksForMore(at: 40 - ahead, of: 40, searching: false))
        #expect(TimelinePane.asksForMore(at: 39, of: 40, searching: false))
        #expect(!TimelinePane.asksForMore(at: 39, of: 40, searching: true))
    }
}

/// The addresses a next stretch is asked at (#87), each protocol's own.
@Suite("The next stretch's address")
struct StretchAddressTests {
    @Test("Discuz! and Discourse ask a page past the first, and the first is asked as it always was")
    func pages() async throws {
        let host = "f.example"
        let empty = FixtureHTTP.Outcome.text(#"{"users":[],"topic_list":{"topics":[]}}"#)
        let http = FixtureHTTP([
            "https://\(host)/latest.json?order=created&page=1": empty,
            "https://\(host)/site.json": .text("{}"),
        ])
        _ = try? await DiscourseClient(http: http, host: host)
            .latest(source: Source(host: host, kind: .discourse), page: 1)
        _ = try? await DiscuzClient(http: http, host: host).latest(source: Source(host: host, kind: .discuz), page: 3)
        _ = try? await DiscuzClient(http: http, host: host).latest(source: Source(host: host, kind: .discuz))
        let asked = Set(await http.requested.map(\.absoluteString))
        #expect(asked.contains("https://\(host)/latest.json?order=created&page=1"))
        #expect(asked.contains("https://\(host)/forum.php?mod=guide&view=newthread&page=3"))
        #expect(asked.contains("https://\(host)/forum.php?mod=guide&view=newthread"))
    }

    @Test("A Mastodon id that is not one is never put in the address")
    func maxIDChecked() async {
        let http = FixtureHTTP([:])
        _ = try? await MastodonClient(http: http, host: "m.example")
            .publicTimeline(source: Source(host: "m.example", kind: .mastodon), olderThan: "../x")
        #expect(await http.requested.isEmpty, "not the newest page in its place")
    }
}
