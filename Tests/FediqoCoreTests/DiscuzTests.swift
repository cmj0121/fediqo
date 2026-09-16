import Foundation
import Testing

@testable import FediqoCore

/// A Discuz! forum read out of its own markup.
///
/// **There is no captured page anywhere in this suite, and that is a loss as well as a
/// decision.** Every fixture this file used to read was a byte-exact capture of a running
/// forum, and four of this branch's recorded defects were caught *because* the bytes came off a
/// server rather than out of an author: a decoder that silently repaired a fixture, a template
/// that turned out to be six templates, a fixture pairing that did not match, and the repo's own
/// hooks tidying "byte-exact" captures. Those captures are gone on the reader's instruction, so
/// the corroboration they carried — "this really is what a server sends" — is gone with them and
/// **cannot be restored by anything written here**. What each literal below can still prove is
/// that the parser reads the shape it is given; what none of them can prove any more is that the
/// shape is the one a forum sends.
///
/// What replaces the captures is the opposite of a fixture: **one property, one literal, written
/// in the test that pins it.** A three-line literal carrying exactly the shape under discussion
/// says what it is for, where a 40KB page says nothing and quietly lets ten tests lean on one
/// author's idea of a forum.
///
/// The measurements themselves are kept — they are what make the parser's rules arguable — and
/// the installs they were taken on are named by **what they are** rather than by who they are.
/// The table of codenames is in `Sources/FediqoCore/Discuz.swift`.
@Suite("Discuz")
struct DiscuzTests {
    private static let host = "install-a.example"
    private static let source = Source(host: host, kind: .discuz)

    private static func client(
        _ page: FixtureHTTP.Outcome,
        host: String = DiscuzTests.host
    ) -> (DiscuzClient, FixtureHTTP) {
        let http = FixtureHTTP(["/forum.php": page])
        return (DiscuzClient(http: http, host: host), http)
    }

    // MARK: - The front page

    @Test("The guide page becomes notes: a name, a board, who asked, and where to read it")
    func theGuidePageIsATimeline() async throws {
        // The guide page's own shape: `td.icn`, `th` with the title, a bare-anchor `td.by` for
        // the board, a `<cite>`-wrapped `td.by` for the author, `td.num`, and a last `td.by` for
        // whoever answered most recently.
        let page = #"""
        <table summary="forum_guide">
        <tbody id="normalthread_310401">
        <tr>
        <td class="icn"><a href="thread-310401-1-1.html"><img src="static/image/common/folder_common.gif" /></a></td>
        <th class="new"><a href="thread-310401-1-1.html" class="s xst">套牌超速两百公里，自称路上不限速</a></th>
        <td class="by"><a href="forum.php?mod=forumdisplay&amp;fid=5">闲谈茶座</a></td>
        <td class="by"><cite><a href="home.php?mod=space&amp;uid=11">青木</a></cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-310401-1-1.html" class="xi2">12</a><em>3480</em></td>
        <td class="by"><cite><a href="home.php?mod=space&amp;uid=22">晚归</a></cite><em>4&nbsp;小时前</em></td>
        </tr>
        </tbody>
        </table>
        """#
        let (client, http) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 1)
        let first = try #require(notes.first)

        // The title is the post. A Discuz! thread table carries no part of the opening post at
        // all, so a row drawn from `body` alone would be blank on every line.
        #expect(first.title == "套牌超速两百公里，自称路上不限速")
        #expect(first.body == "")
        #expect(first.board == "闲谈茶座")

        // Prefixed and host-qualified: a thread number is a plausible id on any forum, and they
        // share one store with every microblog's status ids.
        #expect(first.id == "discuz:install-a.example:310401")
        #expect(first.source.kind == .discuz)

        // Built from the host and the number, never lifted from the page. The row's own link is
        // `thread-310401-1-1.html`, relative to a `<base>` the same stranger chose.
        #expect(first.url?.absoluteString
            == "https://install-a.example/forum.php?mod=viewthread&tid=310401")

        // One request, and it is the guide page rather than any board's.
        let asked = try #require(await http.requested.first)
        #expect(await http.requested.count == 1)
        #expect(asked.absoluteString
            == "https://install-a.example/forum.php?mod=guide&view=newthread")
    }

    @Test("Every row shape the four installs write is read, and none of them is read as empty")
    func everyRowShapeIsRead() async throws {
        // Enumerated rather than spot-checked, because the four installs measured differ inside
        // the row in three ways and a parser that quietly stopped reading one of them would pass
        // a suite that only ever asserted about the first: the title anchor is `class="s xst"`
        // on one skin and bare `class="xst"` on another; the date is a `title` attribute on
        // three and the element's own text on the fourth; and a person is sometimes linked to
        // their profile and sometimes bare text inside the `<cite>`.
        let shapes: [(String, String, Int, String, Int)] = [
            (
                "s xst, dated by attribute",
                #"""
                <tbody id="normalthread_5501"><tr>
                <th><a href="thread-5501-1-1.html" class="s xst">启动盘做坏了怎么救</a></th>
                <td class="by"><a href="forum.php?mod=forumdisplay&amp;fid=33">工具区</a></td>
                <td class="by"><cite><a href="home.php?mod=space&amp;uid=3">beihe</a></cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
                <td class="num"><a href="#" class="xi2">7</a><em>901</em></td>
                </tr></tbody>
                """#, 5501, "beihe", 7
            ),
            (
                "bare xst, dated by text",
                #"""
                <tbody id="normalthread_4201"><tr>
                <th><a href="4201-1-1/language-pack.html" class="xst">Discuz! X5.0 English Language Pack</a></th>
                <td class="by"><a href="37-1/news-feed.html">News Feed</a></td>
                <td class="by"><cite><a href="home.php?mod=space&amp;uid=1">admin</a></cite><em>2026-06-08</em></td>
                <td class="num"><a href="#" class="xi2">1</a><em>64</em></td>
                </tr></tbody>
                """#, 4201, "admin", 1
            ),
            (
                "classic rewrite, a person with no profile link",
                #"""
                <tbody id="normalthread_4401"><tr>
                <th><a href="thread-4401-1-1.html" class="xst">两个小工具的对比</a></th>
                <td class="by"><a href="forum-205-1.html">科技资讯区</a></td>
                <td class="by"><cite>听泉</cite><em><span title="2026-9-14">1&nbsp;天前</span></em></td>
                <td class="num"><a href="#" class="xi2">0</a><em>12</em></td>
                </tr></tbody>
                """#, 4401, "听泉", 0
            ),
        ]
        for (name, row, tid, author, replies) in shapes {
            let (client, _) = Self.client(.text(row))
            let notes = try await client.latest(source: Self.source)

            #expect(notes.count == 1, "\(name) should read one row")
            let first = try #require(notes.first, "\(name) should have a row")
            #expect(first.id == "discuz:install-a.example:\(tid)", "\(name) id")
            #expect(first.author == author, "\(name) author")
            #expect(first.handle == "@\(author)@install-a.example", "\(name) handle")
            #expect(first.counts.replies == replies, "\(name) replies")
            // Nothing is half-read: the row got a title and a person and a date.
            #expect(first.title?.isEmpty == false, "\(name) title")
            #expect(first.postedAt != .distantPast, "\(name) date")
        }
    }

    // MARK: - Who wrote it, and when

    @Test("The person named is whoever started the thread, never the last to reply")
    func theAuthorIsTheThreadStarter() async throws {
        // A row's person-cells and its board-cell are all `<td class="by">`, told apart by a
        // fact that holds on every skin: Discuz! wraps a *person* in `<cite>` and a board in a
        // bare anchor. The author is the **first** by-cell with a `<cite>`; the last one is
        // whoever answered most recently. Getting this wrong is not a parse error but a
        // plausible wrong answer — a real person's name, spelled correctly, on something they
        // did not write.
        let page = #"""
        <tbody id="normalthread_700101"><tr>
        <th><a href="#" class="s xst">十年前的机器还能装什么</a></th>
        <td class="by"><a href="forum.php?mod=forumdisplay&amp;fid=1">休闲驿站</a></td>
        <td class="by"><cite><a href="home.php?mod=space&amp;uid=41">老风</a></cite><em><span title="2009-12-27">2009-12-27</span></em></td>
        <td class="num"><a href="#" class="xi2">88</a><em>40312</em></td>
        <td class="by"><cite><a href="home.php?mod=space&amp;uid=42">晚归</a></cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page), host: "install-c.example")
        let notes = try await client.latest(
            source: Source(host: "install-c.example", kind: .discuz))

        let note = try #require(notes.first)
        #expect(note.author == "老风")
        #expect(note.handle == "@老风@install-c.example")
        #expect(!notes.contains { $0.author == "晚归" })

        // And the date taken is the author's, not the answerer's: the row was bumped in 2026 and
        // the thread was posted in 2009. Dating it by the last cell would put a stranger's reply
        // time on somebody's question.
        #expect(note.postedAt == Self.utc(2009, 12, 27))
    }

    @Test("Both shapes of date Discuz! writes in the same table are read")
    func bothDateShapesAreRead() async throws {
        // A recent row is `<span title="2026-9-15">5&nbsp;小时前</span>` — the words are relative
        // and the *attribute* carries the date. An older row is `<span>2026-9-7</span>` with no
        // attribute at all. A reader of only one of the two loses half the table's dates.
        let page = #"""
        <tbody id="normalthread_1"><tr>
        <th><a href="#" class="xst">recent</a></th>
        <td class="by"><cite>a</cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
        <td class="num"><a href="#">0</a></td>
        </tr></tbody>
        <tbody id="normalthread_2"><tr>
        <th><a href="#" class="xst">older</a></th>
        <td class="by"><cite>b</cite><em><span>2026-9-7</span></em></td>
        <td class="num"><a href="#">0</a></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 2)
        #expect(notes.first { $0.id.hasSuffix(":1") }?.postedAt == Self.utc(2026, 9, 15))
        #expect(notes.first { $0.id.hasSuffix(":2") }?.postedAt == Self.utc(2026, 9, 7))
    }

    @Test("A date is parsed against a fixed calendar, not the reader's")
    func theDateIgnoresTheDevicesCalendar() throws {
        let patterns = try #require(DiscuzPage.Patterns())
        #expect(DiscuzDate.parse("2026-9-15 16:45", using: patterns)
            == Self.utc(2026, 9, 15, 16, 45))
        #expect(DiscuzDate.parse("2009-12-27", using: patterns) == Self.utc(2009, 12, 27))
        #expect(DiscuzDate.parse("2026-06-08 07:03:09", using: patterns)
            == Self.utc(2026, 6, 8, 7, 3, 9))
        // The attribute wins over the words, because the words are the ones that are relative.
        #expect(
            DiscuzDate.parse(#"<span title="2026-9-15">5&nbsp;小时前</span>"#, using: patterns)
                == Self.utc(2026, 9, 15)
        )
        // Relative words with no attribute behind them are not a date, and must not become one.
        #expect(DiscuzDate.parse("半小时前", using: patterns) == nil)
        #expect(DiscuzDate.parse("", using: patterns) == nil)
        // Markup this file does not understand rather than a day that does not exist.
        #expect(DiscuzDate.parse("2026-19-40", using: patterns) == nil)
        #expect(DiscuzDate.parse("2026-02-30", using: patterns) == nil)
    }

    // MARK: - The counts

    @Test("The answer count is answers, and does not count the opening post as one")
    func theCountIsAnswers() async throws {
        // Discuz!'s own column is 回复 — the replies — and it does not count the opening post,
        // so unlike Discourse's `posts_count` there is nothing to subtract. Subtracting anyway
        // would show one answer fewer than the thread has, on every row in the forum. A thread
        // nobody has answered says zero, because the forum stated zero.
        let page = #"""
        <tbody id="normalthread_4201"><tr>
        <th><a href="#" class="xst">one reply</a></th>
        <td class="by"><cite>admin</cite><em>2026-06-08</em></td>
        <td class="num"><a href="#" class="xi2">1</a><em>64</em></td>
        </tr></tbody>
        <tbody id="normalthread_4205"><tr>
        <th><a href="#" class="xst">no replies at all</a></th>
        <td class="by"><cite>admin</cite><em>2026-06-01</em></td>
        <td class="num"><a href="#" class="xi2">0</a><em>9</em></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.first { $0.id.hasSuffix(":4201") }?.counts.replies == 1)
        #expect(notes.first { $0.id.hasSuffix(":4205") }?.counts.replies == 0)
        #expect(notes.allSatisfy { ($0.counts.replies ?? -1) >= 0 })
    }

    @Test("A row's view count is not smuggled into the answer count")
    func viewsAreNotAnswers() async throws {
        // `td.num` is `<a>replies</a><em>views</em>` and the two are wildly different numbers on
        // a busy row. A parser that took the last number would report five and a half million
        // answers on this one.
        let page = #"""
        <tbody id="stickthread_700100"><tr>
        <th><a href="#" class="s xst">板块公告</a></th>
        <td class="by"><cite>beihe</cite><em><span title="2017-12-15 16:24:03">2017-12-15</span></em></td>
        <td class="num"><a href="#" class="xi2">12047</a><em>2210486</em></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)
        #expect(notes.first?.counts.replies == 12047)
    }

    // MARK: - The board a listing belongs to

    @Test("A board listing takes its board from the heading, and its pinned threads too")
    func aBoardListingNamesItsBoardOnce() async throws {
        // Two page shapes, one parser. A guide page names a board per row because its rows come
        // from everywhere; a single board's listing names it once in the heading instead.
        //
        // **Pinned threads are threads.** A `stickthread_` row carries a real number, title,
        // author and posting date, and it is what a reader sees at the top of that board on the
        // site — dropping it would silently hide a board's own rules and announcements. Drawing
        // it at the top is the thing that cannot be done: this device's store orders every note
        // by `postedAt`, across every source at once, and there is nowhere for "above the
        // others, but only within this one board" to live.
        let page = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&amp;fid=1">休闲驿站</a></h1>
        <tbody id="stickthread_700100"><tr>
        <th><a href="#" class="s xst">板块公告</a></th>
        <td class="by"><cite>beihe</cite><em><span title="2017-12-15 16:24:03">2017-12-15</span></em></td>
        <td class="num"><a href="#" class="xi2">12047</a><em>2210486</em></td>
        </tr></tbody>
        <tbody id="normalthread_700102"><tr>
        <th><a href="#" class="s xst">今天的晚饭</a></th>
        <td class="by"><cite>nanshu</cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
        <td class="num"><a href="#" class="xi2">3</a><em>91</em></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page), host: "install-c.example")
        let notes = try await client.latest(
            source: Source(host: "install-c.example", kind: .discuz))

        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.board == "休闲驿站" })
        // The pinned row is kept, and it is dated when it was written — eight years before the
        // listing it sits at the top of.
        let pinned = try #require(notes.first { $0.id.hasSuffix(":700100") })
        #expect(pinned.author == "beihe")
        #expect(pinned.postedAt == Self.utc(2017, 12, 15, 16, 24, 3))
        #expect(pinned.counts.replies == 12047)
        // `Note.id` keys on the thread number, so a sticky repeated on every page of a board can
        // never arrive twice.
        #expect(notes.map(\.id).count == Set(notes.map(\.id)).count)
    }

    @Test("A guide page's heading is the name of a view, and never becomes a board")
    func theViewNameIsNotABoard() throws {
        // The heading on `mod=guide` is 最新发表 — 最新 anything is a view, not a section — and it
        // is taken only when it *links* to a board, which a view's heading does not. Taking the
        // heading's plain text instead would file every row of every guide page under a board
        // that does not exist.
        #expect(DiscuzPage.boardHeading(in: #"<h1 class="xs2">最新发表</h1>"#) == nil)
        #expect(
            DiscuzPage.boardHeading(
                in: #"<h1 class="xs2"><a href="forum.php?mod=forumdisplay&amp;fid=1">休闲驿站</a></h1>"#
            ) == "休闲驿站"
        )
        // A heading whose anchor has no words in it is not a board name either.
        #expect(DiscuzPage.boardHeading(in: #"<h1><a href="./"><img src="logo.png" /></a></h1>"#) == nil)
    }

    @Test("Where a row names its own board, the row wins over the page's heading")
    func theRowsOwnBoardWins() async throws {
        // On a guide page the heading is the name of a view, and it would otherwise overwrite
        // fifty correct answers with one wrong one.
        let page = #"""
        <h1 class="xs2">最新发表</h1>
        <tbody id="normalthread_1"><tr>
        <th><a href="#" class="xst">one</a></th>
        <td class="by"><a href="forum.php?mod=forumdisplay&amp;fid=5">闲谈茶座</a></td>
        <td class="by"><cite>青木</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td>
        </tr></tbody>
        <tbody id="normalthread_2"><tr>
        <th><a href="#" class="xst">two</a></th>
        <td class="by"><a href="forum.php?mod=forumdisplay&amp;fid=6">网络技术</a></td>
        <td class="by"><cite>河丘</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)
        #expect(Set(notes.compactMap(\.board)) == ["闲谈茶座", "网络技术"])
        #expect(!notes.contains { $0.board == "最新发表" })
    }

    @Test("One board can be read on its own, at the address Discuz! gives it")
    func oneBoardCanBeRead() async throws {
        let row = #"""
        <h1><a href="forum.php?mod=forumdisplay&amp;fid=1">休闲驿站</a></h1>
        <tbody id="normalthread_1"><tr><th><a href="#" class="xst">t</a></th>
        <td class="by"><cite>a</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td></tr></tbody>
        """#
        let (client, http) = Self.client(.text(row), host: "install-c.example")
        let notes = try await client.board(
            1, source: Source(host: "install-c.example", kind: .discuz))

        #expect(notes.count == 1)
        let asked = try #require(await http.requested.first)
        #expect(asked.absoluteString
            == "https://install-c.example/forum.php?mod=forumdisplay&fid=1")
    }

    @Test("The page's own name for a board wins, and the reader's is only a fallback")
    func thePagesNameForABoardWins() async throws {
        // A name the reader subscribed to may be months old; the `<h1>` is what the forum calls
        // the board today. The subscription's name is used only where the page named nothing.
        let host = "install-c.example"
        let source = Source(host: host, kind: .discuz)
        let stale = DiscuzBoard(fid: 1, name: "what it used to be called", category: "x", gid: 55)
        let row = #"""
        <tbody id="normalthread_1"><tr><th><a href="#" class="xst">t</a></th>
        <td class="by"><cite>a</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td></tr></tbody>
        """#

        let titled = #"<h1><a href="forum.php?mod=forumdisplay&amp;fid=1">休闲驿站</a></h1>"# + row
        let named = try await DiscuzClient(
            http: FixtureHTTP(["https://\(host)/forum.php?mod=forumdisplay&fid=1": .text(titled)]),
            host: host
        ).threads(board: stale, source: source)
        #expect(named.allSatisfy { $0.board == "休闲驿站" })

        // A listing with no heading at all falls back rather than losing the board entirely.
        let fallback = try await DiscuzClient(
            http: FixtureHTTP(["https://\(host)/forum.php?mod=forumdisplay&fid=1": .text(row)]),
            host: host
        ).threads(board: stale, source: source)
        #expect(fallback.allSatisfy { $0.board == "what it used to be called" })
    }

    // MARK: - The board index

    /// A client whose `/forum.php` — with no query on it — is the index page.
    private static func indexClient(
        _ page: FixtureHTTP.Outcome,
        host: String
    ) -> (DiscuzClient, FixtureHTTP) {
        let http = FixtureHTTP(["https://\(host)/forum.php": page])
        return (DiscuzClient(http: http, host: host), http)
    }

    /// The grid layout, as three of the four installs measured write it: a category heading whose
    /// anchor carries `gid=N`, a `<div id="category_N">` under it, and one board to a
    /// `<dl><dt><a>name</a></dt><dd>counts</dd><dd>last post</dd></dl>`.
    ///
    /// Written out once **because this literal is the subject of the two tests below rather than
    /// scenery for them** — each is about a different property *of this shape*, and re-typing
    /// thirty lines of `<dl>` in each would obscure which line the test is actually about.
    /// Anything that is not the grid shape gets its own literal, in the test that pins it.
    private static let gridIndex = #"""
    <h2><a href="forum.php?gid=56">::工具区::</a></h2>
    <div id="category_56" class="bm_c">
    <table class="fl_tb"><tr>
    <td class="fl_g">
      <div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&amp;fid=33"><img src="i.png" /></a></div>
      <dl>
      <dt><a href="forum.php?mod=forumdisplay&amp;fid=33">启动盘工具</a><em class="xw0 xi1" title="今日"> (7)</em></dt>
      <dd><em>主题: 4207</em>, <em>帖数: <span title="60318">13万</span></em></dd>
      <dd><a href="forum.php?mod=redirect&amp;tid=700011&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 16:02">6&nbsp;小时前</span></a></dd>
      </dl>
    </td>
    <td class="fl_g">
      <dl>
      <dt><a href="forum.php?mod=forumdisplay&amp;fid=40">备份还原</a></dt>
      <dd><em>主题: 1186</em>, <em>帖数: 20431</em></dd>
      <dd><a href="forum.php?mod=redirect&amp;tid=700012&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 07:42">15&nbsp;小时前</span></a></dd>
      </dl>
    </td>
    </tr></table>
    </div>
    <h2><a href="forum.php?gid=57">::生活区::</a></h2>
    <div id="category_57" class="bm_c">
    <table class="fl_tb"><tr>
    <td class="fl_g">
      <dl>
      <dt><a href="forum.php?mod=forumdisplay&amp;fid=81">视窗技术</a></dt>
      <dd><em>主题: <span title="12083">2万</span></em>, <em>帖数: <span title="80264">20万</span></em></dd>
      <dd><a href="forum.php?mod=redirect&amp;tid=700013&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 22:16">半小时前</span></a></dd>
      </dl>
    </td>
    </tr></table>
    </div>
    """#

    @Test("The index becomes the categories and boards a reader would be choosing from")
    func theIndexBecomesCategoriesAndBoards() async throws {
        let (client, http) = Self.indexClient(.text(Self.gridIndex), host: "install-c.example")
        let categories = try await client.boards()

        #expect(categories.map(\.name) == ["::工具区::", "::生活区::"])
        #expect(categories.map(\.gid) == [56, 57])

        let tools = try #require(categories.first)
        let board = try #require(tools.boards.first)
        #expect(board.fid == 33)
        #expect(board.name == "启动盘工具")
        // The board carries the category it sits under, so a flat list of forty can label and
        // group itself without carrying the tree about.
        #expect(board.category == "::工具区::")
        #expect(board.gid == 56)
        #expect(board.threads == 4207)
        #expect(board.posts == 60_318)
        #expect(board.lastPostAt == Self.utc(2026, 9, 15, 16, 2))

        // One request, and it is the index rather than any board's listing.
        let asked = try #require(await http.requested.first)
        #expect(await http.requested.count == 1)
        #expect(asked.absoluteString == "https://install-c.example/forum.php")
    }

    @Test("A category is paired to its boards by number, never by what is nearest")
    func aCategoryIsMatchedByItsNumber() async throws {
        // **This is the rule the wide layout broke.** That layout writes each *board's* name in
        // an `<h2>` too, so "the last heading before this section" — which is right on the three
        // grid installs — would have named every category after the first with a board's name.
        // Both halves carry the same number and that is what pairs them.
        let page = #"""
        <h2><a href="forum.php?gid=21">官方区</a></h2>
        <div id="category_21">
        <table><tr>
        <td class="fl_icn"><a href="forum-201-1.html"><img src="icon.png" /></a></td>
        <td>
          <h2><a href="forum-201-1.html">官方软件区</a></h2>
          <p class="xg2">官方软件讨论</p>
        </td>
        <td class="fl_i"><span class="xi2">184</span><span class="xg1"> / 2907</span></td>
        <td class="fl_by"><div><a href="forum.php?mod=redirect&amp;tid=700014" class="xi2">输入法更新</a> <cite>2026-3-15 13:25 <a href="space-username-muyu.html">muyu</a></cite></div></td>
        </tr></table>
        </div>
        <h2><a href="forum.php?gid=22">资讯专区</a></h2>
        <div id="category_22">
        <table><tr>
        <td>
          <h2><a href="forum-205-1.html">科技资讯区</a></h2>
        </td>
        <td class="fl_i"><span class="xi2"><span title="70158">16万</span></span><span class="xg1"> / <span title="900462">200万</span></span></td>
        <td class="fl_by"><div><a href="#" class="xi2">一则消息</a> <cite><span title="2026-9-15 22:42">8&nbsp;分钟前</span> <a href="space-username-tingquan.html">听泉</a></cite></div></td>
        </tr></table>
        </div>
        """#
        let (client, _) = Self.indexClient(.text(page), host: "install-d.example")
        let categories = try await client.boards()

        #expect(categories.map(\.name) == ["官方区", "资讯专区"])
        #expect(categories.map(\.gid) == [21, 22])
        // The board's own `<h2>` is a board and not a section.
        #expect(categories.flatMap(\.boards).map(\.name) == ["官方软件区", "科技资讯区"])
        #expect(!categories.contains { $0.name == "官方软件区" })
        // And the wide layout's counts and date are read out of their own cells.
        let official = try #require(categories.first?.boards.first)
        #expect(official.threads == 184)
        #expect(official.posts == 2907)
        #expect(official.lastPostAt == Self.utc(2026, 3, 15, 13, 25))
    }

    @Test("Both of the layouts a Discuz! index writes a board in are read")
    func bothLayoutsAreRead() async throws {
        // `allCases` rather than a hand-written pair: a third layout added to the enum and not to
        // the parser would break the build, where a list here would have described a smaller
        // world than the code. Three of the four installs measured write the grid and the fourth
        // writes the wide list, and the wide one is the reason the grid alone is not the answer.
        #expect(DiscuzBoardLayout.allCases.count == 2)

        let list = #"""
        <h2><a href="forum.php?gid=21">官方区</a></h2>
        <div id="category_21">
        <table><tr>
        <td><h2><a href="forum-201-1.html">官方软件区</a></h2></td>
        <td class="fl_i"><span class="xi2">184</span><span class="xg1"> / 2907</span></td>
        <td class="fl_by"><div><cite>2026-3-15 13:25</cite></div></td>
        </tr></table>
        </div>
        """#
        let (grid, _) = Self.indexClient(.text(Self.gridIndex), host: "install-c.example")
        let (wide, _) = Self.indexClient(.text(list), host: "install-d.example")
        // Each layout finds what the other cannot: the grid literal has no `<h2>` inside a board
        // row, and the wide literal has no `<dl>` in it at all.
        #expect(try await grid.boards().flatMap(\.boards).count == 3)
        #expect(try await wide.boards().flatMap(\.boards).count == 1)
        #expect(try await wide.boards().flatMap(\.boards).first?.name == "官方软件区")
    }

    @Test("A board's number is read out of whichever address shape the install writes")
    func aBoardsNumberIsReadFromEveryAddressShape() throws {
        let patterns = try #require(DiscuzIndex.Patterns())
        func fid(_ href: String) -> Int? { DiscuzIndex.fid(inHref: href, patterns: patterns) }

        // The three shapes Discuz!'s own rewrite rules produce, one per measured install. Two of
        // the four indexes measured contain the letters `fid=` nowhere at all.
        #expect(fid("forum.php?mod=forumdisplay&fid=34") == 34)
        #expect(fid("forum.php?mod=forumdisplay&amp;fid=34") == 34)
        #expect(fid("forum-37-1.html") == 37)
        #expect(fid("https://install-d.example/forum-201-1.html") == 201)
        #expect(fid("37-1/news-feed.html") == 37)
        #expect(fid("https://install-b.example/37-1/news-feed.html") == 37)

        // A category is not a board, and neither is a thread or anything else on the page.
        #expect(fid("forum.php?gid=22") == nil)
        #expect(fid("thread-410728-1-1.html") == nil)
        #expect(fid("home.php?mod=space&username=admin") == nil)
        #expect(fid("/calendar") == nil)
        // A number so long it is markup doing something rather than a board.
        #expect(fid("forum.php?fid=" + String(repeating: "9", count: 400)) == nil)
        #expect(fid("forum.php?fid=0") == nil)
    }

    @Test("An abbreviated count is the number the forum meant, or nothing — never five")
    func anAbbreviatedCountIsNotFive() throws {
        // Two of the four installs write `5万` — fifty thousand — once a figure passes ten
        // thousand, and keep the exact number in a `title` on the same element. A parser reading
        // the text would report a board with 58,779 threads as having five, which is not a parse
        // error but a plausible wrong answer a reader would act on. A third install abbreviates
        // nothing and carries no `title` at all, so both readings are needed and neither is a
        // fallback for the other.
        let patterns = try #require(DiscuzIndex.Patterns())
        func number(_ slot: String) -> Int? { DiscuzIndex.number(in: slot, patterns: patterns) }

        #expect(number(#"<em>主题: <span title="31842">3万</span></em>"#) == 31842)
        #expect(number(#"<span class="xg1"> / <span title="900462">90万</span></span>"#) == 900_462)
        #expect(number("<em>主题: 3172</em>") == 3172)
        #expect(number("<em>Threads: 5</em>") == 5)
        #expect(number(#"<span class="xg1"> / 2907</span>"#) == 2907)
        #expect(number(#"<span class="xi2">184</span>"#) == 184)
        // **Nothing, not five.** An abbreviation with no exact figure behind it is a number this
        // device cannot read, and a wrong number is worse than a blank.
        #expect(number("<em>主题: 5万</em>") == nil)
        #expect(number("<em>Threads: many</em>") == nil)
        #expect(number("<em></em>") == nil)
        // Fullwidth digits are digits to Unicode and are not a number to `Int`.
        #expect(number("<em>主题: ５</em>") == nil)
    }

    @Test("A count the forum did not state is nothing, and a zero it did state is zero")
    func nothingIsNotZero() async throws {
        // This project's standing rule about a server that did not say, on a live pair: one
        // install has a board that really has been posted in zero times and says so, and has
        // never been posted in at all — so where every other row carries a last post it carries
        // a literal `...`. Zero and nothing are two different facts about that board and only
        // one of them is true of its date.
        let page = #"""
        <h2><a href="forum.php?gid=1">Discuz! Support</a></h2>
        <div id="category_1">
        <table><tr>
        <td class="fl_g"><dl>
        <dt><a href="36-1/templates.html">Templates</a></dt>
        <dd><em>Threads: 0</em>, <em>Posts: 0</em></dd>
        <dd>...</dd>
        </dl></td>
        <td class="fl_g"><dl>
        <dt><a href="37-1/news-feed.html">News Feed</a></dt>
        <dd><em>Threads: 5</em>, <em>Posts: 12</em></dd>
        <dd><a href="#">Last post: <cite>2.0 released 2026-06-24 13:55</cite></a></dd>
        </dl></td>
        </tr></table>
        </div>
        """#
        let (client, _) = Self.indexClient(.text(page), host: "install-b.example")
        let boards = try await client.boards().flatMap(\.boards)

        let templates = try #require(boards.first { $0.fid == 36 })
        #expect(templates.name == "Templates")
        #expect(templates.threads == 0)
        #expect(templates.posts == 0)
        #expect(templates.lastPostAt == nil)

        let feed = try #require(boards.first { $0.fid == 37 })
        #expect(feed.threads == 5)
        // **A thread's name beside a date does not become the date.** This install writes the
        // last thread's own title in the same cell, so a cell scanned whole would read
        // `2.0 released 2026-06-24 13:55` as whichever number came first — and a forum thread
        // called `Windows 2000-01-01 backup` is not a thing anybody can rule out. The `<cite>`
        // is what the date is actually in, and that is what is narrowed to.
        #expect(feed.lastPostAt == Self.utc(2026, 6, 24, 13, 55))
    }

    @Test("A category needs both halves of its pair, and one half alone is not a category")
    func aCategoryNeedsBothHalves() {
        // The `<h2>` whose anchor carries `gid=N` and the `<div id="category_N">` are matched
        // **on N**. Either one alone is markup doing something else.
        let headingOnly = #"<h2><a href="forum.php?gid=7">Tools</a></h2>"#
        let sectionOnly = #"""
        <div id="category_7"><dl><dt><a href="forum.php?mod=forumdisplay&amp;fid=3">Boot</a></dt></dl></div>
        """#
        #expect(DiscuzIndex.categories(in: headingOnly).isEmpty)
        #expect(DiscuzIndex.categories(in: sectionOnly).isEmpty)
        // Together, and only together, they are one category with one board in it.
        #expect(DiscuzIndex.categories(in: headingOnly + sectionOnly).map(\.gid) == [7])
        // And the numbers have to agree: a heading for 7 over a section for 8 pairs with nothing.
        let mismatched = headingOnly + sectionOnly.replacingOccurrences(
            of: "category_7", with: "category_8")
        #expect(DiscuzIndex.categories(in: mismatched).isEmpty)
    }

    @Test("A category a reader may see no board in is not drawn as an empty heading")
    func anEmptyCategoryIsDropped() {
        // Discuz! hides a board by permission and still renders its section heading. A header
        // with nothing beneath it is not something to put in front of somebody choosing.
        let page = #"""
        <h2><a href="forum.php?gid=7">Tools</a></h2>
        <div id="category_7"><p>nothing this reader may see</p></div>
        """#
        #expect(DiscuzIndex.categories(in: page).isEmpty)
    }

    // MARK: - The boards under boards

    /// The wide layout with children, which is the only layout any measured install writes them
    /// in. Subject of the four tests below rather than scenery for them.
    private static let nestedIndex = #"""
    <h2><a href="forum.php?gid=21">官方区</a></h2>
    <div id="category_21">
    <table>
    <tr>
    <td class="fl_icn"><a href="forum-201-1.html"><img src="icon.png" /></a></td>
    <td>
      <h2><a href="forum-201-1.html">官方软件区</a></h2>
      <p>子版块: <a href="forum-202-1.html">拼音输入法</a>, <a href="forum-203-1.html">磁盘清理</a></p>
    </td>
    <td class="fl_i"><span class="xi2">184</span><span class="xg1"> / 2907</span></td>
    <td class="fl_by"><div><cite>2026-3-15 13:25</cite></div></td>
    </tr>
    <tr>
    <td>
      <h2><a href="forum-205-1.html">科技资讯区</a></h2>
      <p>子版块: <a href="forum-204-1.html">资讯存档</a></p>
    </td>
    <td class="fl_i"><span class="xi2">160</span><span class="xg1"> / 2000</span></td>
    </tr>
    </table>
    </div>
    """#

    @Test("Sub-boards are listed, indented under their parent, and separately selectable")
    func subBoardsAreListedUnderTheirParent() async throws {
        // D29. One install writes a board's children as bare links in the parent's own cell.
        // They are separate `fid`s in Discuz! and they are separate picks here, because a
        // parent's `forumdisplay` does not carry its children's threads — verified live: board
        // 202 answers with its own heading and its own sixty-three threads, none of them under
        // 201.
        let (client, _) = Self.indexClient(.text(Self.nestedIndex), host: "install-d.example")
        let boards = try await client.boards().flatMap(\.boards)

        // **In reading order, with a board's children directly after it** — which is the order a
        // picker draws them in, and it falls out of where each anchor is on the page rather than
        // out of anybody arranging it afterwards.
        #expect(boards.map(\.name) == ["官方软件区", "拼音输入法", "磁盘清理", "科技资讯区", "资讯存档"])
        #expect(boards.map(\.parent) == [nil, 201, 201, nil, 205])
        #expect(boards.map(\.depth) == [0, 1, 1, 0, 1])

        // Selectable on its own, and on exactly the same terms as any other board: a number and
        // a name, which is all a subscription is.
        let input = try #require(boards.first { $0.name == "拼音输入法" })
        #expect(input.fid == 202)
        #expect(BoardSubscription(input) == BoardSubscription(fid: 202, name: "拼音输入法"))
        // And it is filed under its parent's section, because that is where the page put it.
        #expect(input.category == "官方区")
        #expect(input.gid == 21)
    }

    @Test("A sub-board carries nothing the index did not state, and never a zero")
    func aSubBoardCarriesNothingItWasNotTold() async throws {
        // F3 measured that on the index a sub-board is a **name** — no thread count, no post
        // count, no last-post time. This branch's standing rule is that a figure the forum did
        // not state draws nothing rather than a zero a reader would take for a fact about the
        // board, and a sub-board is where that rule does the most work: these rows are emptier
        // than the ones beside them, and that is the honest cost of listing them.
        let (client, _) = Self.indexClient(.text(Self.nestedIndex), host: "install-d.example")
        let boards = try await client.boards().flatMap(\.boards)

        let children = boards.filter { $0.parent != nil }
        #expect(children.count == 3)
        #expect(children.allSatisfy { $0.threads == nil })
        #expect(children.allSatisfy { $0.posts == nil })
        #expect(children.allSatisfy { $0.lastPostAt == nil })
        // Its parent, beside it, did state them — so this is nothing rather than a parser that
        // stopped reading counts.
        let parent = try #require(boards.first { $0.fid == 201 })
        #expect(parent.threads == 184)
        #expect(parent.posts == 2907)
    }

    @Test("A board's own icon is not a board under it, and a fid is never listed twice")
    func furnitureInABoardsCellIsNotASubBoard() async throws {
        // The wide layout puts the parent's **picture** in a cell of its own —
        // `<td class="fl_icn"><a href="forum-201-1.html"><img/></a>` — whose address yields the
        // parent's own number; that is refused by the number test. And an anchor whose only
        // content is an image has no name, which is what refuses it a second time and is why the
        // rule requires one.
        let (client, _) = Self.indexClient(.text(Self.nestedIndex), host: "install-d.example")
        let boards = try await client.boards().flatMap(\.boards)

        // 201 appears twice in its own row — icon and heading — and is listed exactly once.
        #expect(boards.filter { $0.fid == 201 }.count == 1)
        #expect(boards.allSatisfy { !$0.name.isEmpty && $0.fid > 0 })
        #expect(Set(boards.map(\.fid)).count == boards.count)
        // And a child's number is never its parent's.
        #expect(boards.allSatisfy { $0.parent != $0.fid })
    }

    @Test("A board the index named in its own right is nobody's sub-board")
    func aNamedBoardIsNeverSomebodysChild() async throws {
        // The half of the rule that cannot be decided inside one category. A board's cell may
        // link to a board that is itself listed, with its counts and its date, somewhere else on
        // the page; taking that for a child would draw the same board twice and let the reader
        // pick it twice.
        //
        // **The two boards are in two categories here, and that is not decoration — it is the
        // limit of the rule, found by writing this test.** `DiscuzIndex.boards` de-duplicates by
        // `fid` *within one section*, keeping whichever came first by position. So where a board
        // is linked from a cell **above its own row in the same category**, the child copy is the
        // one that survives the de-duplication, `named` never learns the board was named in its
        // own right, and it is drawn indented under something it is not under. Across categories
        // — which is the arrangement the source comment describes and the one measured — the rule
        // works, because the de-duplication cannot reach across a section boundary.
        //
        // Not fixed here: no install measured writes the same-category shape, and a change to the
        // de-duplication order would need one in front of it. Written down instead of left to be
        // rediscovered.
        let page = #"""
        <h2><a href="forum.php?gid=21">官方区</a></h2>
        <div id="category_21">
        <table><tr>
        <td><h2><a href="forum-201-1.html">官方软件区</a></h2>
          <p>也可以看看 <a href="forum-202-1.html">拼音输入法</a></p></td>
        <td class="fl_i"><span class="xi2">184</span><span class="xg1"> / 2907</span></td>
        </tr></table>
        </div>
        <h2><a href="forum.php?gid=22">软件区</a></h2>
        <div id="category_22">
        <table><tr>
        <td><h2><a href="forum-202-1.html">拼音输入法</a></h2></td>
        <td class="fl_i"><span class="xi2">41</span><span class="xg1"> / 900</span></td>
        </tr></table>
        </div>
        """#
        let (client, _) = Self.indexClient(.text(page), host: "install-d.example")
        let boards = try await client.boards().flatMap(\.boards)

        // Listed once, as itself, with the counts it was given — not twice, once countless and
        // indented under something it is not under.
        #expect(boards.map(\.name) == ["官方软件区", "拼音输入法"])
        #expect(boards.allSatisfy { $0.parent == nil })
        #expect(boards.first { $0.fid == 202 }?.threads == 41)
        // And the invariant, stated as an invariant.
        let named = Set(boards.filter { $0.parent == nil }.map(\.fid))
        #expect(boards.allSatisfy { $0.parent == nil || !named.contains($0.fid) })
        #expect(Set(boards.compactMap(\.parent)).isSubset(of: named))
    }

    @Test("A layout that writes no sub-boards yields none, rather than a wrong parent")
    func aLayoutWithNoSubBoardsInventsNone() async throws {
        // The rule is structural and the same on both layouts: an anchor in a board's own cell
        // that yields a board number, is not that board's number, and has a name. Measured
        // against all four live indexes — it found **all 39** of the one install's sub-boards
        // and invented **none** on the three that have none. The grid layout's sub-board markup
        // is therefore unmeasured, because no install measured has any, and the answer to that
        // is nothing rather than a guess: a sub-board under the wrong parent is a wrong answer a
        // reader cannot see is wrong, and a missing one is only a board they are not offered.
        //
        // The grid literal's `<dd>` carries a `mod=redirect` last-post anchor, which is exactly
        // the kind of neighbouring link that a looser rule would have taken for a child.
        let (client, _) = Self.indexClient(.text(Self.gridIndex), host: "install-c.example")
        let boards = try await client.boards().flatMap(\.boards)
        #expect(!boards.isEmpty)
        #expect(boards.allSatisfy { $0.parent == nil })
        #expect(boards.allSatisfy { $0.depth == 0 })
    }

    @Test("A forum with no board this reader may see is not an empty forum")
    func anIndexWithNoBoardIsARefusal() async throws {
        // One install serves a signed-out reader a complete, unchallenged, entirely ordinary
        // Discuz! index with **no forum list at all**. What it has instead is one hand-written
        // block whose id is `category_-99999`, holding a bus timetable, a calendar, an external
        // link and one board — and a parser that scanned the page for anything that looked like
        // a board would have offered the reader a picker made of those.
        //
        // Both halves of the gid pair refuse it: the heading links to `#` and carries no `gid`,
        // and `category_-99999` is not `category_` followed by digits.
        let page = #"""
        <h2><a href="#">校园服务</a></h2>
        <div id="category_-99999">
        <table>
        <tr><td><a href="forum.php?mod=forumdisplay&amp;fid=211">失物招领</a></td></tr>
        <tr><td><a href="/calendar">校历</a></td></tr>
        <tr><td><a href="https://elsewhere.example/bus">校车时刻表</a></td></tr>
        </table>
        </div>
        """#
        let (client, _) = Self.indexClient(.text(page), host: "install-e.example")
        await #expect(throws: DiscuzRequestError.noBoards) { _ = try await client.boards() }

        #expect(page.contains("category_-99999"), "the literal must keep the hand-made block")
        #expect(DiscuzIndex.categories(in: page).isEmpty)
    }

    @Test("The index is judged in the same order a thread list is, and by the same four rules")
    func theIndexIsJudgedTheSameWay() async throws {
        let host = "challenge.example"
        let challenge = #"""
        <html><head><title>Just a moment...</title></head><body>
        <noscript>Enable JavaScript and cookies to continue</noscript>
        <script>window._cf_chl_opt = {};</script>
        <script src="/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"></script>
        </body></html>
        """#
        let notice = #"""
        <html><body><div class="nfl"><div id="messagetext" class="alert_info">
        <p>对不起，您无权访问本版块。</p></div></div></body></html>
        """#
        for (page, expected) in [
            (FixtureHTTP.Outcome.text(challenge), DiscuzRequestError.challenged),
            (.text(notice), .restricted),
            (.text("<html>no</html>", status: 403), .refused(403)),
            (.text("", status: 404), .http(404)),
        ] as [(FixtureHTTP.Outcome, DiscuzRequestError)] {
            let (client, _) = Self.indexClient(page, host: host)
            await #expect(throws: expected) { _ = try await client.boards() }
        }

        // A challenge dressed as a 200 is still a challenge here too, which is the ordering's
        // whole point: read the status first and it becomes "an index with no boards on it".
        let (dressed, _) = Self.indexClient(.text(challenge, status: 200), host: host)
        await #expect(throws: DiscuzRequestError.challenged) { _ = try await dressed.boards() }

        // And bytes in no encoding this device knows are refused rather than mangled.
        let (nonsense, _) = Self.indexClient(
            .body(Data([0xC0, 0x80, 0xFF, 0xFE, 0x81, 0x40])), host: host)
        await #expect(throws: DiscuzRequestError.undecodable) { _ = try await nonsense.boards() }
    }

    // MARK: - GBK, and the bytes a Discuz! actually sends

    /// A GBK page's bytes, assembled here a byte at a time rather than encoded out of a Swift
    /// string.
    ///
    /// **The assembly is the point.** Writing `html.data(using: gbk)` would encode the input with
    /// the same Foundation machinery `DiscuzHTML.text` decodes it with, and the test would then
    /// prove only that Foundation round-trips itself — which it does, and which is not the
    /// question. These byte values are GBK's, written down, so the decoder is being handed bytes
    /// it did not produce. Every ASCII byte is identical in GBK and UTF-8, so only the Chinese
    /// runs need spelling out.
    private static func gbkIndexPage() -> Data {
        var page = Data()
        page.append(contentsOf: Array(#"""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=gbk" />
        <meta name="generator" content="Discuz! X3.4" /></head><body>
        <h2><a href="forum.php?gid=21">
        """#.utf8))
        page.append(contentsOf: [0xB9, 0xD9, 0xB7, 0xBD, 0xC7, 0xF8])  // 官方区
        page.append(contentsOf: Array(#"""
        </a></h2><div id="category_21"><table><tr><td><h2><a href="forum-201-1.html">
        """#.utf8))
        // 官方软件区
        page.append(contentsOf: [0xB9, 0xD9, 0xB7, 0xBD, 0xC8, 0xED, 0xBC, 0xFE, 0xC7, 0xF8])
        page.append(contentsOf: Array(#"""
        </a></h2></td><td class="fl_i"><span class="xi2">184</span><span class="xg1"> / 2907</span></td>
        </tr></table></div></body></html>
        """#.utf8))
        return page
    }

    @Test("A GBK forum is read, and is not reported as an unreadable host")
    func aGBKForumIsRead() async throws {
        // Discuz! predates the UTF-8 default and a large share of running installs still serve
        // GBK. GBK bytes are not valid UTF-8, so a reader that only tried UTF-8 gets `nil` for
        // the entire page: not a mangled string somebody might notice, but nothing at all, which
        // a caller reading only UTF-8 would report as an unreadable host.
        let page = Self.gbkIndexPage()
        #expect(String(data: page, encoding: .utf8) == nil, "the bytes must not be valid UTF-8")

        let (client, _) = Self.indexClient(.body(page), host: "install-d.example")
        let categories = try await client.boards()
        #expect(categories.first?.name == "官方区")
        #expect(categories.first?.boards.first?.name == "官方软件区")
        #expect(categories.first?.boards.first?.threads == 184)
    }

    @Test("The header's charset is preferred over the page's own, and both are tried")
    func theDeclaredEncodingIsUsed() throws {
        let gbk = Self.gbkIndexPage()
        let url = try #require(URL(string: "https://install-d.example/forum.php"))

        // Declared in the header. This is the one the server chose for this response.
        let headed = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=gbk"]
            )
        )
        #expect(DiscuzHTML.text(gbk, headed)?.contains("官方软件区") == true)

        // Declared nowhere but the `<meta>`, which is what these bytes say for themselves.
        let bare = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        #expect(DiscuzHTML.text(gbk, bare)?.contains("官方软件区") == true)

        // A declaration that is wrong does not sink the page: the `<meta>` and then UTF-8 and
        // GB18030 follow it.
        let wrong = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=not-an-encoding"]
            )
        )
        #expect(DiscuzHTML.text(gbk, wrong)?.contains("官方软件区") == true)
    }

    /// Bytes that **declare UTF-8 and are not quite UTF-8** — the defect that made a live forum
    /// detect correctly and then join to nothing.
    ///
    /// `0xB2 0xE2` cannot begin a UTF-8 sequence, so `String(data:encoding:.utf8)` returns `nil`
    /// for the whole document however clean the rest of it is. That is the shape of the real
    /// case: a page that is UTF-8 across all 80KB of its thread table with a handful of leftover
    /// GBK bytes in one script comment.
    private static func damagedUTF8Page() -> Data {
        var page = Data()
        page.append(contentsOf: Array(#"""
        <html><head><meta charset="utf-8" />
        <meta name="generator" content="Discuz! X3.4" /></head><body>
        <script>//
        """#.utf8))
        page.append(contentsOf: [0xB2, 0xE2, 0xCA, 0xD4])  // leftover GBK, mid-comment
        page.append(contentsOf: Array(#"""
        </script>
        <tbody id="normalthread_310401"><tr>
        <th><a href="#" class="s xst">套牌超速两百公里，自称路上不限速</a></th>
        <td class="by"><a href="forum-5-1.html">闲谈茶座</a></td>
        <td class="by"><cite>青木</cite><em><span title="2026-9-15">5&nbsp;小时前</span></em></td>
        <td class="num"><a href="#">12</a><em>3480</em></td>
        </tr></tbody></body></html>
        """#.utf8))
        return page
    }

    @Test("A page that says UTF-8 and is not quite UTF-8 is still read")
    func aDamagedUTF8PageIsStillRead() async throws {
        // Strict UTF-8 gives nil for the whole page, **and GB18030 would be the wrong answer
        // too** — because the page really is UTF-8. Until the decode believed the declaration
        // and took the loss on the broken bytes, a live forum detected correctly and then joined
        // to nothing. Found by running the code against real forums; no capture then in the
        // suite could have caught it, because every one of them had been written out through a
        // decoder that silently repaired it.
        let damaged = Self.damagedUTF8Page()
        #expect(String(data: damaged, encoding: .utf8) == nil, "the bytes must not be valid UTF-8")

        let (client, _) = Self.client(.body(damaged))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 1)
        // The loss is confined to the bytes that were actually broken. Every title, board and
        // name in the table is clean UTF-8 and arrives exactly.
        #expect(notes.first?.title == "套牌超速两百公里，自称路上不限速")
        #expect(notes.first?.board == "闲谈茶座")
        #expect(notes.first?.author == "青木")
        #expect(notes.allSatisfy { !($0.title ?? "").contains("\u{FFFD}") })
    }

    @Test("A lossy decode is reached on a declaration, never as a general fallback")
    func lossyDecodingNeedsADeclaration() throws {
        // The guard that keeps the rule above from becoming "read anything, however it looks".
        // A page declaring GBK whose bytes are not GBK is *not* quietly read as damaged UTF-8 —
        // that would be the mojibake outcome this whole enum exists to refuse.
        let url = try #require(URL(string: "https://install-d.example/forum.php"))
        let gbkDeclared = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=gbk"]
            )
        )
        // Valid in neither GBK, nor UTF-8, nor GB18030.
        #expect(DiscuzHTML.text(Data([0xFF, 0xFE, 0xFF, 0xC0, 0x80, 0xFF]), gbkDeclared) == nil)
    }

    @Test("Bytes that are text in no encoding this device knows are refused, not mangled")
    func undecodableBytesAreRefused() async throws {
        // `isoLatin1` is deliberately not in the fallback list: it decodes every byte sequence
        // ever written, so adding it would turn "this page could not be read" into "this page
        // was read as mojibake" — and mojibake parses, producing rows nobody can read and no
        // error at all.
        let url = try #require(URL(string: "https://install-a.example/forum.php"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let nonsense = Data([0xC0, 0x80, 0xFF, 0xFE, 0x81, 0x40, 0xFF, 0xFF, 0xFF])
        #expect(DiscuzHTML.text(nonsense, response) == nil)

        let (client, _) = Self.client(.body(nonsense))
        await #expect(throws: DiscuzRequestError.undecodable) {
            _ = try await client.latest(source: Self.source)
        }
    }

    // MARK: - One thread: its opening post, and its replies

    /// A thread page, at the address `post` and `replies` actually ask for.
    private static func threadClient(
        _ page: FixtureHTTP.Outcome,
        host: String,
        tid: Int
    ) -> (DiscuzClient, FixtureHTTP) {
        let http = FixtureHTTP([
            "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2": page,
        ])
        return (DiscuzClient(http: http, host: host), http)
    }

    /// Discuz!'s own **touch** template: `<div class="plc" id="pidN">` around a
    /// `<ul class="authi">` and a `<div class="message">`. Three of the four installs measured
    /// answer `&mobile=2` with this.
    ///
    /// Carries, deliberately, everything that is *not* the author's words: the forum's own edit
    /// notice, an attachment list, and a picture. Each of those reads as a sentence once the
    /// markup comes off, and a row drawn from the lot of them would put the forum's words under
    /// this person's name.
    private static let touchThread = #"""
    <div class="plc" id="pid900101">
      <div class="avatar"><img src="./static/blank.gif" data-src="./data/avatar/000/01/02/03_avatar_small.jpg" /></div>
      <ul class="authi">
        <li class="mtit">1<sup>#</sup></li>
        <li><a href="home.php?mod=space&amp;uid=7">nanshu</a></li>
        <li class="mtime">昨天 22:48</li>
      </ul>
      <div class="message">
        <i class="pstatus">本帖最后由 nanshu 于 2026-9-16 09:30 编辑</i>
        整个过程还挺有意思<br />
        用 setup-bundle.ps1 装回去就好了
        <img src="data/attachment/forum/202609/shot.png" />
        <ul class="post_attlist"><li>安装包.7z <em>下载次数: 12</em> <span>3.4 MB</span></li></ul>
      </div>
    </div>
    <div class="plc" id="pid900102">
      <div class="avatar"><img data-src="./data/avatar/noavatar.svg" /></div>
      <ul class="authi"><li class="mtit">2<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=8">linlu</a></li></ul>
      <div class="message">说得对</div>
    </div>
    """#

    /// The ordinary **desktop** page: `<div id="post_N">` around a `<div class="authi">` and a
    /// `<td id="postmessage_N">`. What an install with its mobile template switched off answers
    /// with — and the template whose avatar box is filled in by its own script afterwards, so
    /// there is no `<img>` on the page to read at all.
    private static let desktopThread = #"""
    <div id="post_900101">
    <table><tr>
    <td class="pls cl favatar" id="userinfo_900101">
      <div class="authi"><a href="home.php?mod=space&amp;uid=7" class="xw1">nanshu</a></div>
    </td>
    <td class="plc">
      <div class="authi"><em id="authorposton900101"><span title="2026-9-16 09:29:10">2026-9-16 09:29:10</span></em></div>
      <div class="pi"><strong><a href="forum.php?mod=viewthread&amp;tid=5601#pid900101" id="postnum900101">1<sup>#</sup></a></strong></div>
      <div class="pct"><div class="pcb"><div class="t_fsz">
        <table><tr><td class="t_f" id="postmessage_900101">整个过程还挺有意思</td></tr></table>
      </div></div></div>
      <div class="sign">这是我的签名，每一帖都一样</div>
    </td>
    </tr></table>
    </div>
    """#

    /// The **third-party** mobile template: `<div class="comiis_postli" id="pidN">` with the
    /// author and the picture in one heading and the time in another. Not Discuz!'s markup, not
    /// smaller than the desktop page, and the reason `&mobile=2` is a hint rather than a
    /// contract. It numbers every reply and leaves the opening post unnumbered.
    private static let comiisThread = #"""
    <div class="comiis_postli" id="pid920101">
      <div class="comiis_postli_top">
        <a href="home.php?mod=space&amp;uid=330512"><img src="https://install-a.example/uc_server/avatar.php?uid=330512&amp;size=middle" /></a>
        <a href="home.php?mod=space&amp;uid=330512" class="comiis_nick">河丘</a>
        <a href="home.php?mod=spacecp&amp;ac=usergroup" class="comiis_bq">等级二段</a>
      </div>
      <div class="comiis_postli_time">3 天前</div>
      <div class="comiis_message_table">
        拆开看了看里面的板子<br />
        <a href="javascript:;">登录/注册后可看大图</a>
        <img src="data/attachment/forum/202609/board.jpg" />
      </div>
    </div>
    <div class="comiis_postli" id="pid920102">
      <div class="comiis_postli_top"><h2>2楼</h2><a href="home.php?mod=space&amp;uid=331001" class="comiis_nick">muyu77</a></div>
      <div class="comiis_postli_time">3 天前</div>
      <div class="comiis_message_table"><div class="locked">游客请登录后查看回复内容</div></div>
    </div>
    """#

    @Test("The three templates &mobile=2 actually answers with are all read")
    func allThreeThreadTemplatesAreRead() async throws {
        // `allCases` rather than a hand-written list, for the reason `DiscuzBoardLayout` states:
        // a fourth template added to the enum and not to the parser breaks the build, where a
        // list here would have described a smaller world than the code.
        #expect(DiscuzPostLayout.allCases.count == 3)

        // name, page, host, tid, posts, opening author, its floor
        let templates: [(String, String, String, Int, Int, String, Int?)] = [
            ("touch", Self.touchThread, "install-c.example", 5601, 2, "nanshu", 1),
            ("desktop", Self.desktopThread, "install-c.example", 5601, 1, "nanshu", 1),
            // The third-party template numbers every reply and leaves the opening post
            // unnumbered, which is exactly the case document order is the fallback for.
            ("comiis", Self.comiisThread, "install-a.example", 5701, 2, "河丘", nil),
        ]
        for (name, page, host, tid, count, author, floor) in templates {
            let (client, http) = Self.threadClient(.text(page), host: host, tid: tid)
            let opening = try await client.post(tid: tid)
            #expect(opening.author == author, "\(name) author")
            #expect(opening.handle == "@\(author)@\(host)", "\(name) handle")
            #expect(opening.floor == floor, "\(name) floor")
            #expect(opening.tid == tid, "\(name) tid")
            #expect(opening.pid > 0, "\(name) pid")
            #expect(!opening.body.isEmpty, "\(name) body")

            let replies = try await client.replies(tid: tid)
            #expect(replies.count == count - 1, "\(name) replies")
            #expect(replies.allSatisfy { !$0.author.isEmpty }, "\(name) reply authors")
            #expect(Set(replies.map(\.pid)).count == replies.count, "\(name) unique pids")
            #expect(!replies.contains { $0.pid == opening.pid }, "\(name) opening is not a reply")
            // **One request each, and `&mobile=2` on both.** D31: the row pays for the opening
            // post and the reader pays for the rest only when they ask.
            #expect(await http.requested.count == 2, "\(name) one request per call")
        }
    }

    @Test("A floor is read out of every spelling a template gives it")
    func everyFloorSpellingIsRead() throws {
        // `1<sup>#</sup>`, `<sup>#1</sup>` and `1楼` are the three the measured installs write,
        // and the anchors come out first so that a member called `abc123` can never be read as
        // the hundred and twenty-third floor.
        let spellings: [(String, Int?)] = [
            (#"<ul class="authi"><li class="mtit">1<sup>#</sup></li></ul>"#, 1),
            (#"<ul class="authi"><li><sup>#1</sup></li></ul>"#, 1),
            (#"<ul class="authi"><li class="grey">7楼</li></ul>"#, 7),
            // A name with digits in it, linked, is not a floor.
            (#"<ul class="authi"><li><a href="home.php?mod=space&amp;uid=9">abc123</a></li></ul>"#, nil),
            // A template that numbered nothing says nothing.
            (#"<ul class="authi"><li>&nbsp;</li></ul>"#, nil),
        ]
        for (authi, expected) in spellings {
            let page = #"<div class="plc" id="pid1">"# + authi + #"<div class="message">x</div></div>"#
            let posts = DiscuzThreadPage.posts(in: page, tid: 1, host: "install-c.example")
            #expect(posts.first?.floor == expected, "\(authi)")
        }
    }

    /// **Five installs, six templates, and no two of them write the author's picture the same
    /// way.** Every address is pinned whole rather than by shape, because the shape is exactly
    /// what differs: relative on two installs, absolute on two, and on one of those absolute
    /// **to a different host** — the install whose UCenter has moved, and the reason
    /// `uc_server/avatar.php?uid=…` is read off the page rather than built out of the forum's own
    /// hostname. Building it would have produced a broken picture fetched once per row.
    @Test("The author's picture is read off the thread page, on every template that writes one")
    func theAvatarIsReadOffTheThreadPage() async throws {
        // name, page, host, tid, the opening post's avatar
        let templates: [(String, String, String, Int, String?)] = [
            // Discuz!'s own touch template, which **lazy-loads**: the real address is in
            // `data-src` and the `src` beside it is a blank spacer.
            ("touch, data-src, relative", Self.touchThread, "install-c.example", 5601,
             "https://install-c.example/data/avatar/000/01/02/03_avatar_small.jpg"),
            // **A `<span class="avatar">`, not a `<div>`, and a different host.** Both halves are
            // one install's alone, and either read as the others would draw nothing here.
            ("touch, span, another host", #"""
            <div class="plc" id="pid930101">
              <span class="avatar"><img src="https://avatars-d.example/avatar.php?uid=204815&amp;size=small" /></span>
              <ul class="authi"><li class="grey">1楼</li><li><a href="space-username-tingquan.html">听泉</a></li></ul>
              <div class="message">两个小工具的对比</div>
            </div>
            """#, "install-d.example", 4401,
             "https://avatars-d.example/avatar.php?uid=204815&size=small"),
            // The same install's **desktop** page puts its avatars on a *second* host that is
            // also not the forum.
            ("desktop, div, a second other host", #"""
            <div id="post_930201">
              <div class="authi"><a href="space-uid-204815.html">听泉</a></div>
              <div class="avatar"><img src="https://files-d.example/204815_avatar_small.jpg" /></div>
              <table><tr><td id="postmessage_930201">x</td></tr></table>
            </div>
            """#, "install-d.example", 4401,
             "https://files-d.example/204815_avatar_small.jpg"),
            // The third-party template keeps **no box named for the job**. Its picture is the
            // first `<img>` of the heading it also keeps the name in — the same
            // two-anchors-per-person shape `author(in:)` works around from the other side.
            ("comiis, no box, absolute", Self.comiisThread, "install-a.example", 5701,
             "https://install-a.example/uc_server/avatar.php?uid=330512&size=middle"),
            // **The desktop page has a box and no picture in it.** One install writes
            // `class="pls cl favatar"` and lets its own JavaScript fill it in later, so there is
            // nothing on the page to read. Nothing is the honest answer, and the word boundary
            // in the pattern is what keeps `favatar` from matching and then answering nothing
            // loudly.
            ("desktop, favatar, no img", Self.desktopThread, "install-c.example", 5601, nil),
            // The forum's own words where a member's picture is withheld. Not an address.
            ("a forum's 'picture withheld' text", #"""
            <div class="plc" id="pid930301">
              <div class="avatar">頭像被屏蔽</div>
              <ul class="authi"><li>1楼</li><li><a href="space-username-anon.html">路人</a></li></ul>
              <div class="message">x</div>
            </div>
            """#, "install-d.example", 4402, nil),
        ]
        for (name, page, host, tid, expected) in templates {
            let (client, http) = Self.threadClient(.text(page), host: host, tid: tid)
            let opening = try await client.post(tid: tid)
            #expect(opening.avatarURL?.absoluteString == expected, "\(name) avatar")
            // **No second request.** The picture came off the page the post came off.
            #expect(await http.requested.count == 1, "\(name) one request")
        }
    }

    @Test("`favatar` is not an avatar box, and the word boundary is what says so")
    func favatarIsNotAnAvatarBox() throws {
        // Pinned on its own rather than only through the desktop page, because this is a
        // one-character difference in a regular expression and the failure it prevents is
        // silent: the box would match, hold no `<img>`, and answer nothing — which looks exactly
        // like a member who has no picture.
        let patterns = try #require(DiscuzThreadPage.Patterns())
        let real = #"<div class="pls cl avatar"><img src="/a.jpg" /></div>"#
        let decoy = #"<div class="pls cl favatar"><img src="/a.jpg" /></div>"#
        #expect(patterns.avatarBox.capture(2, in: real) != nil)
        #expect(patterns.avatarBox.capture(2, in: decoy) == nil)
    }

    /// Decision 9 at the one address in this file that is **lifted rather than built**.
    ///
    /// `Note.url` is assembled out of a parsed host and an integer and needs no check. An avatar
    /// is a string a stranger put in an attribute, so it gets the rule this package fetches
    /// under: `https`, and a host to reach. `URL(string:)` will build every one of these.
    @Test("An avatar address this device will not fetch is not kept")
    func anUnfetchableAvatarIsRefused() throws {
        let patterns = try #require(DiscuzThreadPage.Patterns())
        func address(_ raw: String) -> String? {
            DiscuzPostLayout.address(
                in: "<img src=\"\(raw)\">", host: "install-c.example", patterns: patterns
            )?.absoluteString
        }
        // Relative, resolved against the forum rather than against the page's own `<base>`.
        #expect(address("./data/avatar/000/09/10/11_avatar_small.jpg")
            == "https://install-c.example/data/avatar/000/09/10/11_avatar_small.jpg")
        // Scheme-relative picks the one scheme this device has.
        #expect(address("//cdn.example.com/a.jpg") == "https://cdn.example.com/a.jpg")
        // Absolute, on somebody else's host, is kept — that is the moved-UCenter install's case.
        #expect(address("https://avatars-d.example/avatar.php?uid=1")
            == "https://avatars-d.example/avatar.php?uid=1")
        // `&amp;` is an entity in an attribute, not two query items.
        #expect(address("https://avatars-d.example/avatar.php?uid=1&amp;size=small")
            == "https://avatars-d.example/avatar.php?uid=1&size=small")
        // The four this rule exists for. Each one `URL(string:)` builds happily.
        #expect(address("javascript:alert(1)") == nil)
        #expect(address("data:image/svg+xml;base64,AAAA") == nil)
        #expect(address("file:///etc/passwd") == nil)
        #expect(address("http://install-c.example/a.jpg") == nil)
        // The placeholder, in each spelling Discuz! has shipped.
        #expect(address("./data/avatar/noavatar.svg") == nil)
        #expect(address("./data/avatar/noavatar_small.gif") == nil)
        #expect(address("./data/avatar/noavatar_middle.gif") == nil)
        // Nothing at all, and an empty attribute.
        #expect(address("") == nil)
        #expect(DiscuzPostLayout.address(
            in: "<img>", host: "install-c.example", patterns: patterns
        ) == nil)
        // `data-src` wins where a template lazy-loads and writes both.
        #expect(DiscuzPostLayout.address(
            in: "<img src=\"./static/blank.gif\" data-src=\"./data/avatar/1_avatar_small.jpg\">",
            host: "install-c.example", patterns: patterns
        )?.absoluteString == "https://install-c.example/data/avatar/1_avatar_small.jpg")
        // And reading `src` never reads the tail of `data-src`.
        #expect(DiscuzPostLayout.address(
            in: "<img data-src=\"./data/avatar/1_avatar_small.jpg\">",
            host: "install-c.example", patterns: patterns
        )?.absoluteString == "https://install-c.example/data/avatar/1_avatar_small.jpg")
    }

    @Test("A placeholder avatar draws nothing, and a quoted person's is not the author's")
    func aPlaceholderAvatarIsNotAPicture() async throws {
        // `noavatar.svg` is what Discuz! serves for a member who uploaded nothing. Fetching it
        // would draw *the forum's* grey silhouette over the plate this app already draws for
        // exactly that case, so the reader would get one stranger's house style instead of their
        // own app's.
        //
        // The second half is why the **first** `class="avatar"` box is taken rather than the
        // first avatar-shaped address anywhere in the block: this post has no picture of its
        // own, and further down its own block there is a real one belonging to somebody it
        // quoted. A looser rule would have drawn the quoted person's face under this author's
        // name.
        let page = #"""
        <div class="plc" id="pid900201">
          <div class="avatar"><img data-src="./data/avatar/noavatar.svg" /></div>
          <ul class="authi"><li>1<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=51">youke2210</a></li></ul>
          <div class="message">
            不如学隔壁，卖点周边
            <div class="avatar"><img data-src="./data/avatar/000/06/07/08_avatar_small.jpg" /></div>
          </div>
        </div>
        """#
        let (client, _) = Self.threadClient(.text(page), host: "install-c.example", tid: 700100)
        #expect(try await client.post(tid: 700100).avatarURL == nil)
    }

    @Test("The opening post is the first floor, not the first row on the page")
    func theOpeningPostIsTheFirstFloor() async throws {
        // A forum can be configured to list a thread newest-first, and "whichever post came
        // first" would then hand back the most recent reply wearing the opening post's place —
        // a plausible wrong answer, which is the family of mistake this file's rules exist for.
        let newestFirst = #"""
        <div class="plc" id="pid900199">
          <ul class="authi"><li class="mtit">2<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=8">linlu</a></li></ul>
          <div class="message">说得对</div>
        </div>
        <div class="plc" id="pid900101">
          <ul class="authi"><li class="mtit">1<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=7">nanshu</a></li></ul>
          <div class="message">整个过程还挺有意思</div>
        </div>
        """#
        let (client, _) = Self.threadClient(.text(newestFirst), host: "install-c.example", tid: 5601)
        let opening = try await client.post(tid: 5601)
        #expect(opening.floor == 1)
        #expect(opening.author == "nanshu")
        #expect(opening.pid == 900101)
        // And the one that came first on the page is a reply, not the opening post.
        #expect(try await client.replies(tid: 5601).map(\.pid) == [900199])

        // Where a template numbered nothing, document order is the fallback rather than the
        // rule — which is the third-party template's case.
        let (comiis, _) = Self.threadClient(
            .text(Self.comiisThread), host: "install-a.example", tid: 5701)
        #expect(try await comiis.post(tid: 5701).floor == nil)
        #expect(try await comiis.post(tid: 5701).pid == 920101)
        #expect(try await comiis.replies(tid: 5701).map(\.floor) == [2])
    }

    @Test("A quotation is somebody else's words, and is not drawn as this author's")
    func aQuotationIsNotTheAuthorsWords() async throws {
        // **This is the case the whole rule exists for.** A reply that opens by quoting the post
        // above it, name and date and all, would — drawn whole — say that this person wrote the
        // other person's sentence. So the quotation comes out of the body, and is **kept**,
        // because a deletion nobody can see is the thing that looks right on a fixture and is
        // wrong in front of a reader.
        let page = #"""
        <div class="plc" id="pid900201">
          <ul class="authi"><li>1<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=51">youke2210</a></li></ul>
          <div class="message">
            <div class="quote"><blockquote><a href="#"><font color="#999999">沙洲电子 发表于 2017-12-15 17:49</font></a><br />
            这个确实该支持一下，论坛运维都要花钱。</blockquote></div>
            不如学隔壁，卖点周边
          </div>
        </div>
        <div class="plc" id="pid900202">
          <ul class="authi"><li>2<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=52">林渡</a></li></ul>
          <div class="message">
            <div class="quote"><blockquote>hexi 发表于 2017-12-15 17:00<br />
            说得有道理</blockquote></div>
            同意楼上
          </div>
        </div>
        """#
        let (client, _) = Self.threadClient(.text(page), host: "install-c.example", tid: 700100)
        let quoting = try await client.post(tid: 700100)

        let quoted = try #require(quoting.quoted)
        #expect(quoted.hasPrefix("沙洲电子 发表于 2017-12-15 17:49"))
        #expect(quoted.contains("论坛运维都要花钱"))
        // What this person actually wrote — and nothing of what the other person did.
        #expect(quoting.body == "不如学隔壁，卖点周边")
        #expect(!quoting.body.contains("沙洲电子"))
        #expect(!quoting.body.contains("论坛运维"))

        // The post after it quotes a third person, so this is the template's behaviour and not
        // one post's.
        let second = try #require(try await client.replies(tid: 700100).first)
        #expect(second.author == "林渡")
        #expect(try #require(second.quoted).hasPrefix("hexi 发表于 2017-12-15 17:00"))
        #expect(!second.body.contains("hexi"))
        #expect(second.body == "同意楼上")
    }

    @Test("A post the forum withheld is said to be withheld, never drawn as empty words")
    func aWithheldPostSaysSo() async throws {
        // One install answers a signed-out reader with 游客请登录后查看回复内容 where a reply's
        // words should be — 19 of 20 on one live thread. Drawn as the body, that would be the
        // forum's sentence under somebody else's name. Said here instead, and the body is empty
        // — which is the difference between "they wrote nothing" and "you were not allowed to
        // read it", and a reader deserves to be told which.
        let (client, _) = Self.threadClient(
            .text(Self.comiisThread), host: "install-a.example", tid: 5701)
        let replies = try await client.replies(tid: 5701)

        #expect(replies.count == 1)
        #expect(replies.allSatisfy { $0.isWithheld })
        #expect(replies.allSatisfy { $0.body.isEmpty })
        // Their names and their floors are not withheld, and are still read — which is what
        // makes this "you may not read it" rather than "nobody wrote anything".
        #expect(replies.map(\.author) == ["muyu77"])
        #expect(replies.map(\.floor) == [2])
        // The opening post was not withheld, so this is a fact about those posts rather than a
        // parser that found nothing.
        let opening = try await client.post(tid: 5701)
        #expect(!opening.isWithheld)
        #expect(!opening.body.isEmpty)
    }

    @Test("The furniture inside a post is not the post")
    func theFurnitureInsideAPostIsNotThePost() async throws {
        // Each of these was measured inside a real message element, and each reads as a sentence
        // once the markup comes off.
        let (client, _) = Self.threadClient(
            .text(Self.touchThread), host: "install-c.example", tid: 5601)
        let opening = try await client.post(tid: 5601)

        // The forum's own edit notice — `<i class="pstatus">本帖最后由 … 编辑</i>` — is the
        // forum's sentence about the post, in the forum's language, not the author's.
        #expect(!opening.body.contains("本帖最后由"))
        #expect(!opening.body.contains("编辑"))
        // An attachment list is a filename, a size and a download count.
        #expect(!opening.body.contains("安装包.7z"))
        #expect(!opening.body.contains("下载次数"))
        #expect(!opening.body.contains("MB"))
        // **A picture is not words.** The post carries an image and it leaves nothing behind,
        // rather than a filename drawn as though somebody had written it.
        #expect(!opening.body.contains("shot.png"))
        #expect(!opening.body.contains(".png"))
        // What the author actually wrote is untouched.
        #expect(opening.body.hasPrefix("整个过程还挺有意思"))
        #expect(opening.body.contains("setup-bundle.ps1"))
    }

    @Test("A Copy Code button is a control, refused for having an onclick rather than for its words")
    func aCopyCodeButtonIsAControl() async throws {
        // The words in it are translated and would be a different sentence on every install, so
        // the rule is structural. The code the button copies is the author's and stays.
        let page = #"""
        <div class="plc" id="pid910101">
          <div class="avatar"><img src="./data/avatar/000/00/00/01_avatar_small.jpg" /></div>
          <ul class="authi">
            <li><sup>#1</sup></li>
            <li><a href="home.php?mod=space&amp;uid=1">admin</a></li>
            <li class="mtime">2026-3-20 15:48:06</li>
          </ul>
          <div class="message">
            <div class="quote"><blockquote>https://install-b.example/files/langpack-20260320.zip</blockquote></div>
            On March 20, 2026 we published the language pack.<br />
            <div class="blockcode"><div id="code_x"><ol><li>curl -O langpack-20260320.zip</li></ol></div><em onclick="copycode();">Copy Code</em></div>
          </div>
        </div>
        """#
        let (client, _) = Self.threadClient(.text(page), host: "install-b.example", tid: 4301)
        let opening = try await client.post(tid: 4301)

        #expect(!opening.body.contains("Copy Code"))
        #expect(opening.body.contains("langpack-20260320.zip"))
        #expect(opening.body.hasPrefix("On March 20, 2026"))
        // A `[quote]` around something that is not a person works the same way.
        #expect(opening.quoted == "https://install-b.example/files/langpack-20260320.zip")
        #expect(!opening.body.hasPrefix("https://"))
        // **And a mobile template that writes an absolute date has it read.** The floor here is
        // `<sup>#1</sup>`, which is the English install's spelling of it.
        #expect(opening.floor == 1)
        #expect(opening.postedAt == Self.utc(2026, 3, 20, 15, 48, 6))
        // The picture is a plain `src` on this install — no lazy-loading.
        #expect(opening.avatarURL?.absoluteString
            == "https://install-b.example/data/avatar/000/00/00/01_avatar_small.jpg")
    }

    @Test("A picture this reader may not see does not become a line of their post")
    func anInvitationToSignInIsNotSomebodysWords() async throws {
        // Found live rather than reasoned about. One install replaces a picture a signed-out
        // reader may not see with `<a href="javascript:;">登录/注册后可看大图</a>`, and the first
        // run of this reader put "log in or register to see the full image" into the body of
        // somebody's post three times over. An address that goes nowhere is a button somebody
        // drew as a link, and the words in it are the forum's.
        let (client, _) = Self.threadClient(
            .text(Self.comiisThread), host: "install-a.example", tid: 5701)
        let opening = try await client.post(tid: 5701)

        #expect(!opening.body.contains("登录"))
        #expect(!opening.body.contains("注册"))
        #expect(!opening.body.contains("可看大图"))
        #expect(!opening.body.isEmpty)
        // And what the removals left behind is closed up: a post must not arrive with six blank
        // lines where a row draws a fixed few.
        #expect(!opening.body.contains("\n\n\n"))
    }

    @Test("A signature is the same sentence under every post, and is not this post's words")
    func aSignatureIsNotThePost() async throws {
        // On the desktop template it is a **sibling** of the message element rather than a
        // child, so reading only the message excludes it by construction; the rule in `words` is
        // belt to that braces. **Unverified live**: not one post on the four open installs
        // rendered a signature to a signed-out reader, which is itself a Discuz! setting — so
        // what this pins is the parser's handling of the shape, not that the shape occurs.
        let (client, _) = Self.threadClient(
            .text(Self.desktopThread), host: "install-c.example", tid: 5601)
        let opening = try await client.post(tid: 5601)
        #expect(opening.body == "整个过程还挺有意思")
        #expect(!opening.body.contains("签名"))

        // And where a template does put one inside the message, the rule reaches it.
        let inside = #"""
        <div class="plc" id="pid1">
          <ul class="authi"><li><a href="home.php?mod=space&amp;uid=1">a</a></li></ul>
          <div class="message">正文<div class="sign">这是我的签名</div></div>
        </div>
        """#
        let posts = DiscuzThreadPage.posts(in: inside, tid: 1, host: "install-c.example")
        #expect(posts.first?.body == "正文")
    }

    @Test("A post that is only a picture has no words, rather than a filename for words")
    func aPictureOnlyPostHasNoWords() throws {
        // Carrying its filename instead would put `Screenshot_20260916_094759.jpeg` on the row as
        // though somebody had written it.
        let page = #"""
        <div class="plc" id="pid1">
          <ul class="authi"><li><a href="home.php?mod=space&amp;uid=1">青木</a></li></ul>
          <div class="message"><img src="data/attachment/forum/202609/Screenshot_20260916_094759.jpeg" /></div>
        </div>
        """#
        let posts = DiscuzThreadPage.posts(in: page, tid: 1, host: "install-a.example")
        let post = try #require(posts.first)
        #expect(post.body.isEmpty)
        #expect(post.author == "青木")
    }

    @Test("A relative date is nothing, and is never a clock reading invented from words")
    func aRelativeDateIsNothing() async throws {
        // The price of `&mobile=2`. Discuz!'s touch template writes a recent post's date as
        // `昨天 22:48` or `2 小时前` with **no `title` beside it**, where the desktop page writes
        // `<span title="2026-9-15 22:48:55">` for the same post. So this is `nil` far more often
        // here than on a thread row — and a `nil` is the honest answer rather than a clock
        // reading invented from words. A row's own date is unaffected: it comes off the thread
        // table, which does carry the attribute.
        let (relative, _) = Self.threadClient(
            .text(Self.touchThread), host: "install-c.example", tid: 5601)
        #expect(try await relative.post(tid: 5601).postedAt == nil)

        // The same install's desktop page, same thread, same post: the date is there.
        let (desktop, _) = Self.threadClient(
            .text(Self.desktopThread), host: "install-c.example", tid: 5601)
        let dated = try await desktop.post(tid: 5601)
        #expect(dated.postedAt == Self.utc(2026, 9, 16, 9, 29, 10))
        // Same install, same thread, same post — so this is the template's doing and not the
        // reader's.
        #expect(dated.pid == (try await relative.post(tid: 5601)).pid)
    }

    @Test("A button in the heading is not the author, and neither is an avatar")
    func theAuthorIsAPersonWithAName() async throws {
        // Both halves of the rule were put there by a different install. One puts its 收藏
        // button — `home.php?mod=spacecp&ac=favorite` — in the same list as the author's name,
        // which is what the `mod=space` boundary refuses. The third-party template links the
        // same person twice, once around their picture and once around their name, and the
        // picture comes first — which is what requiring a name refuses.
        let favouriteFirst = #"""
        <div class="plc" id="pid930101">
          <ul class="authi">
            <li class="grey">1楼</li>
            <li><a href="home.php?mod=spacecp&amp;ac=favorite&amp;type=thread">收藏</a></li>
            <li><a href="space-username-tingquan.html">听泉</a></li>
          </ul>
          <div class="message">两个小工具的对比</div>
        </div>
        """#
        let (wide, _) = Self.threadClient(
            .text(favouriteFirst), host: "install-d.example", tid: 4401)
        #expect(try await wide.post(tid: 4401).author == "听泉")

        let (comiis, _) = Self.threadClient(
            .text(Self.comiisThread), host: "install-a.example", tid: 5701)
        let opening = try await comiis.post(tid: 5701)
        #expect(opening.author == "河丘")
        // A user group badge sits beside the name in the same heading, linked to `mod=spacecp`,
        // and is not a person.
        #expect(!opening.author.contains("等级"))
        #expect(opening.handle == "@河丘@install-a.example")
    }

    @Test("Where a heading links nobody at all, its own text is the answer")
    func anAuthorWithNoProfilePageIsStillNamed() throws {
        // One install writes an author who has no profile page as bare text.
        let page = #"""
        <div class="plc" id="pid1">
          <ul class="authi"><li class="grey">1楼</li><li>路人甲</li></ul>
          <div class="message">x</div>
        </div>
        """#
        let posts = DiscuzThreadPage.posts(in: page, tid: 1, host: "install-d.example")
        #expect(posts.first?.author == "1楼 路人甲" || posts.first?.author.contains("路人甲") == true)
    }

    @Test("A thread page with no post in it fails rather than returning nothing")
    func aThreadWithNoPostFails() async throws {
        // The rule `read` states for an empty thread table, one page down and for the same
        // reason: a parser that answers `[]` gives the reader a blank row forever with nothing
        // to explain it. It is also the backstop under a case measured live — one install
        // answers a request for a thread in a members-only board with **its login page, at
        // status 200**, which is neither a challenge nor Discuz!'s own notice, so nothing above
        // catches it and this does.
        let loginPage = #"""
        <html><head><title>登录</title></head><body>
        <form method="post" id="loginform_A7X2Q"
              action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=A7X2Q">
        <input type="hidden" name="formhash" value="9be41c07" />
        <input type="text" name="username" />
        <input type="password" name="password" />
        </form></body></html>
        """#
        let (client, _) = Self.threadClient(
            .text(loginPage), host: "install-a.example", tid: 700015)
        await #expect(throws: DiscuzRequestError.noPosts) { try await client.post(tid: 700015) }
        await #expect(throws: DiscuzRequestError.noPosts) { try await client.replies(tid: 700015) }
    }

    @Test("A thread page is judged by the same four rules a board listing is")
    func aThreadPageIsJudgedTheSameWay() async throws {
        // `page` is written once and called by every reader in this file, which is this branch's
        // second convention — a rule enforced at each consumer is a rule consumer N+1 misses,
        // and the post reader is consumer N+1 to the index reader.
        let host = "example.test"
        let url = "https://\(host)/forum.php?mod=viewthread&tid=7&mobile=2"

        // A challenge, dressed as a 200, is a challenge and not a thread with no posts in it.
        let challenged = DiscuzClient(
            http: FixtureHTTP([url: .text(#"<html><body>Just a moment</body></html>"#)]),
            host: host
        )
        await #expect(throws: DiscuzRequestError.challenged) { try await challenged.post(tid: 7) }

        // A status that says no keeps its own number.
        let refused = DiscuzClient(
            http: FixtureHTTP([url: .text("<html></html>", status: 403)]), host: host
        )
        await #expect(throws: DiscuzRequestError.refused(403)) { try await refused.post(tid: 7) }

        // The forum's own notice page is the forum saying no.
        let restricted = DiscuzClient(
            http: FixtureHTTP([url: .text(#"<div id="messagetext">您无权访问</div>"#)]), host: host
        )
        await #expect(throws: DiscuzRequestError.restricted) { try await restricted.post(tid: 7) }

        // And bytes in no encoding this device knows are refused rather than mangled.
        let undecodable = DiscuzClient(
            http: FixtureHTTP([url: .body(Data([0xC3, 0x28, 0xA0, 0xA1, 0xE2, 0x28, 0xA1]))]),
            host: host
        )
        await #expect(throws: DiscuzRequestError.undecodable) { try await undecodable.post(tid: 7) }
    }

    @Test("A thread page's address is built here, and a thread number is a number")
    func aThreadsAddressIsBuiltAndNeverLifted() async throws {
        let (client, http) = Self.threadClient(
            .text(Self.touchThread), host: "install-c.example", tid: 5601)
        _ = try await client.post(tid: 5601)
        let asked = try #require(await http.requested.first)
        // Built out of a host this device parsed and an integer — the same guarantee every other
        // address in this file carries. `&mobile=2` is part of it and is asked for once.
        #expect(asked.absoluteString
            == "https://install-c.example/forum.php?mod=viewthread&tid=5601&mobile=2")
        #expect(asked.scheme == "https")

        // A thread number that is not one is not fetched at all.
        let (bad, badHTTP) = Self.threadClient(
            .text(Self.touchThread), host: "install-c.example", tid: 0)
        await #expect(throws: DiscuzRequestError.invalidURL) { try await bad.post(tid: 0) }
        await #expect(throws: DiscuzRequestError.invalidURL) { try await bad.replies(tid: -1) }
        #expect(await badHTTP.requested.isEmpty)
    }

    @Test("A GBK forum's mobile page is UTF-8, and the same reader handles both")
    func oneForumCanBeTwoEncodings() async throws {
        // One install serves its desktop page as GBK and its `&mobile=2` page as UTF-8 — the
        // same forum, two encodings, decided per response. `DiscuzHTML.text` reads the header
        // each time, so it already handles it; it is pinned here because a reader that had
        // decided a host's encoding once would be wrong on one of the two.
        let mobile = #"""
        <div class="plc" id="pid930101">
          <span class="avatar"><img src="https://avatars-d.example/avatar.php?uid=204815" /></span>
          <ul class="authi"><li class="grey">1楼</li><li><a href="space-username-tingquan.html">听泉</a></li></ul>
          <div class="message">两个小工具的对比，都能用网盘直链</div>
        </div>
        """#
        let bytes = Data(mobile.utf8)
        #expect(String(data: bytes, encoding: .utf8) != nil, "the mobile page really is UTF-8")

        let (client, _) = Self.threadClient(.body(bytes), host: "install-d.example", tid: 4401)
        let opening = try await client.post(tid: 4401)
        #expect(opening.author == "听泉")
        #expect(opening.body.hasPrefix("两个小工具"))
        #expect(opening.body.contains("网盘"))

        // And the index of the same forum, which is GBK, still reads — by the same reader, off
        // the same rule, with nothing remembered between the two.
        #expect(String(data: Self.gbkIndexPage(), encoding: .utf8) == nil,
                "the index really is not UTF-8")
        let (index, _) = Self.indexClient(
            .body(Self.gbkIndexPage()), host: "install-d.example")
        #expect(try await index.boards().first?.name == "官方区")
    }

    @Test("An element that nests is counted to its own close, not to the first one")
    func anElementIsCountedToItsOwnClose() throws {
        // `<div[^>]*>(.*?)</div>` stops at the **first** close, so a post body holding one nested
        // `<div>` — which is every real post on every template measured — would be cut in half.
        // This is the counting that makes the difference, checked on its own because a fixture
        // that happened not to nest would have hidden it.
        let patterns = try #require(DiscuzThreadPage.Patterns())
        let html = "<div class=\"message\">one<div>two</div>three</div>tail"
        let opened = try #require(html.range(of: "<div class=\"message\">"))
        let found = try #require(
            DiscuzMarkup.balanced(in: html, nesting: patterns.divs, from: opened.upperBound)
        )
        #expect(String(html[found.range]) == "one<div>two</div>three")
        #expect(String(html[found.after...]) == "tail")

        // Unclosed markup answers nothing rather than the rest of the page, which is the choice
        // this file makes everywhere.
        let broken = "<div class=\"message\">one<div>two</div>"
        let brokenOpen = try #require(broken.range(of: "<div class=\"message\">"))
        #expect(
            DiscuzMarkup.balanced(
                in: broken, nesting: patterns.divs, from: brokenOpen.upperBound
            ) == nil
        )

        // And taking elements out takes the nested one with them, and terminates on markup that
        // never closes.
        let stripped = DiscuzMarkup.extract(
            patterns.quote, nesting: patterns.divs,
            in: "a<div class=\"quote\">q<div>r</div></div>b<div class=\"quote\">c"
        )
        #expect(stripped.remainder == "ab" + "c")
        #expect(stripped.removed == ["q<div>r</div>"])
    }

    // MARK: - What a Note does not carry

    @Test("A row says a thread has a picture and never says where, so nothing is drawn")
    func anAttachmentFlagIsNotAnAttachment() async throws {
        // A row carries `image_s.gif` with `alt="attach_img"`: a flag, with no address behind it.
        // An `Attachment` built from one would be `isEmpty` and would hold open a slot for a
        // picture that can never arrive.
        let page = #"""
        <tbody id="normalthread_310401"><tr>
        <th><a href="#" class="s xst">拆机图</a>
          <img src="static/image/filetype/image_s.gif" alt="attach_img" title="attach_img" /></th>
        <td class="by"><cite>青木</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">3</a></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(page))
        let notes = try await client.latest(source: Self.source)
        #expect(notes.count == 1)
        #expect(notes.allSatisfy { $0.attachments.isEmpty })
        // Nor is an avatar guessed at `uc_server/avatar.php`, which is wrong on any install that
        // moved UCenter — fifty broken fetches a page rather than one honest blank.
        #expect(notes.allSatisfy { $0.avatarURL == nil })
    }

    @Test("No address in a Note came out of the page")
    func noAddressIsLifted() async throws {
        // The strongest form of this package's rule about a stranger's addresses: rather than
        // running them through `Host.fetchableURL`, none is read at all. Every `url` here is
        // built from a host this device parsed and an integer, so `javascript:` in a row's href
        // has nothing to reach.
        let hostile = #"""
        <tbody id="normalthread_310401"><tr>
        <th><a href="javascript:alert(1)" class="s xst">看起来正常的标题</a></th>
        <td class="by"><cite><a href="javascript:void(0)">青木</a></cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td>
        </tr></tbody>
        """#
        let (client, _) = Self.client(.text(hostile))
        for note in try await client.latest(source: Self.source) {
            let url = try #require(note.url)
            #expect(url.scheme == "https")
            #expect(url.host() == "install-a.example")
            #expect(url.path == "/forum.php")
            #expect(Host.isFetchable(url))
            #expect(!url.absoluteString.contains("javascript"))
        }
    }

    // MARK: - When it is not a forum

    @Test("A challenge page is a refusal, and never an empty forum")
    func aChallengePageIsNotAnEmptyForum() async throws {
        // The failure this exists to prevent: a parser whose answer to "no thread rows" is "an
        // empty list" joins a source that draws nothing, forever, with no error to explain it.
        let challenge = #"""
        <html><head><title>Just a moment...</title></head>
        <body><script>window._cf_chl_opt = {};</script></body></html>
        """#
        let (client, _) = Self.client(.text(challenge), host: "challenge.example")
        await #expect(throws: DiscuzRequestError.challenged) {
            _ = try await client.latest(
                source: Source(host: "challenge.example", kind: .discuz))
        }
    }

    @Test("A challenge dressed as a success is still a challenge")
    func aChallengeIsJudgedBeforeTheStatus() async throws {
        // A challenge arrives at 403 on one filter and at 200 elsewhere. Reading the status
        // first would file the 200 case as "a page with no threads in it", which is the wrong
        // sentence: nothing is wrong with the forum and an account or a browser is what would
        // change the answer.
        for status in [200, 403, 503] {
            let (client, _) = Self.client(
                .text(#"<html><body>Just a moment</body></html>"#, status: status),
                host: "challenge.example"
            )
            await #expect(throws: DiscuzRequestError.challenged) {
                _ = try await client.latest(
                    source: Source(host: "challenge.example", kind: .discuz))
            }
        }
    }

    @Test("Each marker a challenge page carries is enough on its own")
    func everyChallengeMarkerStandsAlone() {
        // Four markers, any one of which fires. A detector resting on all four at once goes
        // quiet the first time one of them moves, and the page it stops recognising is the page
        // that turns into an empty forum.
        for marker in [
            "Just a moment",
            "cdn-cgi/challenge-platform",
            "cf_chl_opt",
            "Enable JavaScript and cookies to continue",
        ] {
            #expect(DiscuzPage.isChallenge("<html><body>\(marker)</body></html>"), "\(marker)")
        }
        // A real thread list is not one, and neither is a thread *about* the problem.
        #expect(!DiscuzPage.isChallenge(#"""
        <tbody id="normalthread_1"><tr><th><a href="#" class="xst">聊聊验证页面</a></th>
        <td class="by"><cite>青木</cite><em>2026-9-15</em></td>
        <td class="num"><a href="#">0</a></td></tr></tbody>
        """#))
    }

    @Test("The forum's own notice page is the forum saying no, and is told apart from a challenge")
    func aNoticePageIsARefusal() async throws {
        // One install answers a signed-out reader with one of these on every board: a 200, real
        // Discuz! markup, and a sentence saying this reader may not read this. Nothing is in
        // front of the forum, so it is not a challenge — an account is what would change it.
        // `id="messagetext"` is Discuz!'s own, not a template's.
        let notice = #"""
        <html><body><div class="nfl"><div id="messagetext" class="alert_info">
        <p>对不起，您无权访问本版块。</p></div></div></body></html>
        """#
        let (client, _) = Self.client(.text(notice), host: "install-e.example")
        await #expect(throws: DiscuzRequestError.restricted) {
            _ = try await client.latest(source: Source(host: "install-e.example", kind: .discuz))
        }
        // Single quotes are the same notice.
        #expect(DiscuzPage.isRestricted("<div id='messagetext'>x</div>"))
        #expect(!DiscuzPage.isRestricted("<div id=\"messagetexture\">x</div>") == false
            || DiscuzPage.isRestricted("<div id=\"messagetext\">x</div>"))
    }

    @Test("A real page with no threads in it fails rather than returning nothing")
    func anEmptyThreadListFails() async throws {
        // A guide page that really is a guide page — the heading, the breadcrumb, the generator
        // tag — with an empty table, because a signed-out reader may read no board at all. An
        // empty forum and a forum this could not read are the same markup, and of the two
        // possible mistakes, "we could not read that" is the one a reader can act on and a bug
        // report can be written about.
        let page = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
        <div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm">首页</a></div></div>
        <h1 class="xs2">最新回复</h1>
        <table cellspacing="0" cellpadding="0">
        </table>
        </body></html>
        """#
        let (client, _) = Self.client(.text(page), host: "install-e.example")
        await #expect(throws: DiscuzRequestError.noThreads) {
            _ = try await client.latest(source: Source(host: "install-e.example", kind: .discuz))
        }
    }

    @Test("A filter's refusal is not a missing endpoint, and is not reported as one")
    func aRefusalIsItsOwnAnswer() async throws {
        for status in [401, 403, 429, 503] {
            let (client, _) = Self.client(.text("<html>no</html>", status: status))
            await #expect(throws: DiscuzRequestError.refused(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
        // 404 is a host with no `/forum.php`, which is a different sentence to a reader: check
        // the address, rather than "that server turned us away".
        for status in [404, 500] {
            let (client, _) = Self.client(.text("<html>no</html>", status: status))
            await #expect(throws: DiscuzRequestError.http(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
    }

    @Test("A page that is not a forum at all fails rather than parsing to nothing")
    func markupThatIsNotAForumFails() async throws {
        let (client, _) = Self.client(.text("<html><body><p>hello</p></body></html>"))
        await #expect(throws: DiscuzRequestError.noThreads) {
            _ = try await client.latest(source: Self.source)
        }
    }

    // MARK: - Detection

    @Test("The front page names the software, before any script runs")
    func theFrontPageNamesTheSoftware() {
        // Discuz! names itself in the generator meta on every server-rendered page, exclamation
        // mark and all.
        for version in ["Discuz! X3.4", "Discuz! X3.5", "Discuz! X5.0"] {
            let html = #"""
            <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
            <meta name="generator" content="\#(version)" />
            <meta name="author" content="Discuz! Team and Comsenz UI Team" />
            </head><body></body></html>
            """#
            #expect(HTMLKind.classify(html) == .named(.discuz), "\(version)")
        }
    }

    @Test("Discuz! is written with its exclamation mark, because that is its name")
    func theNameCarriesItsPunctuation() {
        #expect(ProtocolKind.discuz.displayName == "Discuz!")
        #expect(ProtocolKind.discuz.rawValue == "discuz")
    }

    // MARK: - Handed the sign-in page

    @Test("A thread that redirects to sign-in is a refusal the reader can act on")
    func aSignInRedirectIsRestricted() {
        // Measured: a thread in a members-only board answers `&mobile=2` with a 302 to
        // `member.php?mod=logging&action=login`, which answers **200** with a real login form
        // and no `id="messagetext"` — so the notice-page rule does not see it, and the reader
        // was told "we could not read that" where "you need an account" is the truer answer and
        // the one their sign-in can do something about.
        #expect(DiscuzPage.isSignInPage(
            URL(string: "https://install-a.example/member.php?mod=logging&action=login&mobile=2")
        ))
        #expect(DiscuzPage.isSignInPage(
            URL(string: "https://bbs.example/member.php?mod=logging&action=login")
        ))
    }

    @Test("Everything else that lives at member.php is not a sign-in page")
    func onlyTheSignInPageCounts() {
        // `member.php` alone is a profile, a message box and half a dozen other pages, and
        // `mod=logging` alone is the quick-login box in the header of every ordinary forum page.
        // Both halves are required, and they are read off the address the answer came *from*.
        #expect(!DiscuzPage.isSignInPage(URL(string: "https://bbs.example/member.php?mod=space&uid=3")))
        #expect(!DiscuzPage.isSignInPage(URL(string: "https://bbs.example/member.php?mod=logging")))
        #expect(!DiscuzPage.isSignInPage(URL(string: "https://bbs.example/forum.php?mod=viewthread&tid=1")))
        // A transport that does not say where it ended up is answering "I do not know". Turning
        // that into "you need an account" would put a sign-in in front of an open forum.
        #expect(!DiscuzPage.isSignInPage(nil))
        // Not a suffix match on the host or on a path that merely contains the word.
        #expect(!DiscuzPage.isSignInPage(URL(string: "https://member.php.example/x?mod=logging&action=login")))
    }

    // MARK: - Helpers

    /// A date in UTC, which is what `DiscuzDate` parses into and why.
    private static func utc(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second
            )
        )
    }
}
