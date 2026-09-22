import Foundation
import Testing
@testable import FediqoCore

/// A Discuz! forum's ranking lists, read as its Trends.
///
/// **The shape is `install-g.example`'s, trimmed and with every name replaced.** The forum's
/// thread ranking (`type=thread&view=replies`) is a table whose first three ranks are pictures
/// and the rest numbers, one row per thread with its board beside it; its blog ranking
/// (`type=blog&view=heats`) is a run of `dl.bbda` entries with a share link, a title, a byline, an
/// excerpt and a figure. Nothing below was copied from the forum: titles, boards, people,
/// excerpts and numbers are placeholders, and only the markup's structure is the forum's.
@Suite("A forum's ranking lists")
struct DiscuzRanklistTests {
    private static let host = "install-g.example"
    private static let source = Source(host: host, kind: .discuz)

    private static let threadAddress =
        "https://\(host)/misc.php?mod=ranklist&type=thread&view=replies&orderby=thisweek"
    private static let blogAddress =
        "https://\(host)/misc.php?mod=ranklist&type=blog&view=heats&orderby=thisweek"

    /// The thread ranking: the heading row, two ranks as pictures, one as a number, one of them
    /// posted anonymously, and a navigation link to a thread elsewhere on the page that is not a
    /// ranked row.
    private static let threadPage = #"""
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body>
    <ul id="nav"><li><a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=100">常見問題</a></li></ul>
    <table><tbody><tr><td><a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=101">廣告</a></td></tr></tbody></table>
    <div class="tl">
    <table cellspacing="0" cellpadding="0">
    <tbody>
    <tr class="th">
    <td class="icn">&nbsp;</td>
    <th>標題</th>
    <td class="frm">版塊</td>
    <td class="by">作者</td>
    <td width="60">
    回復</td>
    </tr>
    </tbody><tbody><tr>
    <td class="icn"><img src="./thread_files/rank_1.gif" alt="1"></td>
    <th><a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=900" target="_blank">第一個主題 (01.02)</a></th>
    <td class="frm"><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=37" class="xg1" target="_blank">版塊甲</a></td>
    <td class="by">
    <cite><a href="https://install-g.example/home.php?mod=space&amp;uid=11" target="_blank">A&amp;B</a></cite>
    <em>2026-9-16 17:50</em>
    </td>
    <td>
    <a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=900" class="xi2" target="_blank">150</a></td>
    </tr>
    <tr>
    <td class="icn"><img src="./thread_files/rank_2.gif" alt="2"></td>
    <th><a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=901" target="_blank">第二個主題</a></th>
    <td class="frm"><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=38" class="xg1" target="_blank">版塊乙</a></td>
    <td class="by">
    <cite><a href="https://install-g.example/home.php?mod=space&amp;uid=12" target="_blank"></a></cite>
    <em>2026-9-17 11:14</em>
    </td>
    <td>
    <a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=901" class="xi2" target="_blank">142</a></td>
    </tr>
    <tr>
    <td class="icn">4</td>
    <th><a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=902" target="_blank">第三個主題</a></th>
    <td class="frm"><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=37" class="xg1" target="_blank">版塊甲</a></td>
    <td class="by">
    <cite><a href="https://install-g.example/home.php?mod=space&amp;uid=13" target="_blank">someone</a></cite>
    <em>2026-9-18 01:01</em>
    </td>
    <td>
    <a href="https://install-g.example/forum.php?mod=viewthread&amp;tid=902" class="xi2" target="_blank">117</a></td>
    </tr>
    </tbody></table>
    </div>
    </body></html>
    """#

    /// The blog ranking: a rank as a picture and one as a number, an excerpt the forum cut with
    /// its editor's markup still in it and then escaped, and one with no excerpt at all.
    private static let blogPage = #"""
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body>
    <div class="xld xlda hasrank"><dl class="bbda">
    <dd class="ranknum"><img src="./ranklist_files/rank_1.gif" alt="1"></dd>
    <dd class="m">
    <div class="avt">
    <a href="https://install-g.example/home.php?mod=space&amp;uid=21" target="_blank"><img src="./ranklist_files/avatar.jpg"></a>
    </div>
    </dd>
    <dt class="xs2">
    <a href="https://install-g.example/home.php?mod=spacecp&amp;ac=share&amp;type=blog&amp;id=500&amp;handlekey=lsbloghk_500" id="a_share_500" onclick="showWindow(this.id, this.href, 'get', 0);" class="oshr xs1 xw0">分享</a>
    <a href="https://install-g.example/home.php?mod=space&amp;uid=21&amp;do=blog&amp;id=500" target="_blank">一篇日誌</a>
    </dt>
    <dd>
    <a href="https://install-g.example/home.php?mod=space&amp;uid=21" target="_blank">writer</a> <span class="xg1">2026-9-16 05:10</span>
    </dd>
    <dd class="cl">
    日誌開頭的幾句話 ...</dd>
    <dd class="xg1">
    人氣: 60</dd>
    </dl>
    <dl class="bbda">
    <dd class="ranknum">4</dd>
    <dd class="m"><div class="avt"><a href="https://install-g.example/home.php?mod=space&amp;uid=22"><img src="a.jpg"></a></div></dd>
    <dt class="xs2">
    <a href="https://install-g.example/home.php?mod=spacecp&amp;ac=share&amp;type=blog&amp;id=900" class="oshr xs1 xw0">分享</a>
    <a href="https://install-g.example/home.php?mod=space&amp;uid=22&amp;do=blog&amp;id=900" target="_blank">另一篇</a>
    </dt>
    <dd>
    <a href="https://install-g.example/home.php?mod=space&amp;uid=22" target="_blank">other</a> <span class="xg1">2026-9-17 15:15</span>
    </dd>
    <dd class="cl">
    &lt;font size="4" color="#333"&gt;有格式的字&lt;/font&gt;&lt;span style="font-size: 16px ...</dd>
    <dd class="xg1">
    人氣: 51</dd>
    </dl>
    <dl class="bbda">
    <dd class="ranknum">5</dd>
    <dt class="xs2">
    <a href="https://install-g.example/home.php?mod=space&amp;uid=23&amp;do=blog&amp;id=901" target="_blank">沒有摘要</a>
    </dt>
    <dd>
    <a href="https://install-g.example/home.php?mod=space&amp;uid=23" target="_blank">third</a> <span class="xg1">2026-9-18 02:53</span>
    </dd>
    <dd class="cl">
    </dd>
    <dd class="xg1">
    人氣: 43</dd>
    </dl>
    </div>
    <div class="appl"><h2 class="mt bbda">排行榜</h2></div>
    </body></html>
    """#

    /// A thread ranking and a blog ranking in GBK — assembled a byte at a time for
    /// `DiscuzTests.gbkIndexPage`'s reason: bytes the decoder did not produce itself.
    private static func gbk(_ page: (inout Data) -> Void) -> Data {
        var data = Data()
        page(&data)
        return data
    }

    private static func ascii(_ text: String, into data: inout Data) {
        data.append(contentsOf: Array(text.utf8))
    }

    private static let gbkBoardB: [UInt8] = [0xB0, 0xE6, 0xBF, 0xE9, 0xD2, 0xD2]  // 版块乙
    private static let gbkBoardC: [UInt8] = [0xB0, 0xE6, 0xBF, 0xE9, 0xB1, 0xFB]  // 版块丙
    // 链接到外部地址
    private static let gbkExcerpt: [UInt8] = [
        0xC1, 0xB4, 0xBD, 0xD3, 0xB5, 0xBD, 0xCD, 0xE2, 0xB2, 0xBF, 0xB5, 0xD8, 0xD6, 0xB7,
    ]

    private static let gbkThreadPage = gbk { data in
        ascii(#"""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=gbk" /></head><body>
        <div class="tl"><table><tbody><tr>
        <td class="icn"><img src="rank_1.gif" alt="1" /></td>
        <th><a href="forum.php?mod=viewthread&amp;tid=77">
        """#, into: &data)
        data.append(contentsOf: gbkBoardC)
        ascii(#"""
        </a></th>
        <td class="frm"><a href="forum.php?mod=forumdisplay&amp;fid=434" class="xg1">
        """#, into: &data)
        data.append(contentsOf: gbkBoardB)
        ascii(#"""
        </a></td>
        <td class="by"><cite><a href="home.php?mod=space&amp;uid=8">someone</a></cite> <em>2026-9-15</em></td>
        <td><a href="forum.php?mod=viewthread&amp;tid=77" class="xi2">3</a></td></tr>
        </tbody></table></div></body></html>
        """#, into: &data)
    }

    private static let gbkBlogPage = gbk { data in
        ascii(#"""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=gbk" /></head><body>
        <div class="xld xlda hasrank"><dl class="bbda">
        <dd class="ranknum"><img src="rank_1.gif" alt="1" /></dd>
        <dt class="xs2"><a href="home.php?mod=space&amp;uid=8&amp;do=blog&amp;id=66">
        """#, into: &data)
        data.append(contentsOf: gbkBoardC)
        ascii(#"""
        </a></dt>
        <dd><a href="home.php?mod=space&amp;uid=8">someone</a> <span class="xg1">2026-9-15 08:00</span></dd>
        <dd class="cl">
        """#, into: &data)
        data.append(contentsOf: gbkExcerpt)
        ascii(#"""
        </dd><dd class="xg1">h: 1</dd></dl></div></body></html>
        """#, into: &data)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))
    }

    // MARK: - The thread ranking

    @Test("The thread ranking is read in its order, ranks as pictures and as numbers alike")
    func threadsInOrder() throws {
        let ranked = DiscuzRanklist.threads(in: Self.threadPage)
        #expect(ranked.map(\.thread.tid) == [900, 901, 902], "the heading row and the other links are not threads")
        #expect(ranked.map(\.rank) == [1, 2, 4])

        let first = try #require(ranked.first)
        #expect(first.thread.title == "第一個主題 (01.02)")
        #expect(first.thread.board == "版塊甲")
        #expect(first.fid == 37)
        #expect(first.thread.author == "A&B")
        #expect(first.thread.postedAt == Self.date(2026, 9, 16, 17, 50))
        #expect(first.thread.replies == 150)
    }

    @Test("An anonymous thread's author is nobody, and never somebody else's name")
    func anonymousAuthor() throws {
        let ranked = DiscuzRanklist.threads(in: Self.threadPage)
        let anonymous = try #require(ranked.first { $0.thread.tid == 901 })
        #expect(anonymous.thread.author == "")
        let note = anonymous.asNote(source: Self.source, host: Self.host)
        #expect(note.author == "")
        #expect(note.handle == "", "never a bare @@host")
    }

    @Test("A ranked thread is the row its board makes: the same id and address, with Trends and its board")
    func aRankedThreadIsItsBoardsRow() throws {
        let ranked = try #require(DiscuzRanklist.threads(in: Self.threadPage).first)
        let note = ranked.asNote(source: Self.source, host: Self.host)
        let boardRow = ranked.thread.asNote(source: Self.source, host: Self.host, board: nil, boardID: "37")
        #expect(note.id == "discuz:\(Self.host):900")
        #expect(note.id == boardRow.id)
        #expect(note.url == boardRow.url)
        #expect(note.url?.absoluteString == "https://\(Self.host)/forum.php?mod=viewthread&tid=900")
        #expect(note.categories == [.board(id: "37"), .trends])
        #expect(note.body == "", "its words are its opening post's, read as any thread's are")
        #expect(note.board == "版塊甲")
        #expect(note.counts.replies == 150)
    }

    @Test("A rewritten thread address still gives its number")
    func rewrittenAddresses() {
        let page = #"""
        <table><tr><td class="icn">7</td>
        <th><a href="thread-321-1-1.html">改寫的位址</a></th>
        <td class="frm"><a href="forum-9-1.html" class="xg1">版塊</a></td>
        <td class="by"><cite><a href="space-uid-1.html">x</a></cite><em>2026-9-1</em></td>
        <td><a href="thread-321-1-1.html">2</a></td></tr></table>
        """#
        let ranked = DiscuzRanklist.threads(in: page)
        #expect(ranked.map(\.thread.tid) == [321])
        #expect(ranked.first?.fid == 9)
        #expect(ranked.first?.rank == 7)
    }

    // MARK: - The blog ranking

    @Test("The blog ranking is read in its order; the title is the link to the blog, not the share button")
    func blogsInOrder() throws {
        let ranked = DiscuzRanklist.blogs(in: Self.blogPage)
        #expect(ranked.map(\.id) == [500, 900, 901], "the side panel's heading is not an entry")
        #expect(ranked.map(\.rank) == [1, 4, 5])
        let first = try #require(ranked.first)
        #expect(first.title == "一篇日誌")
        #expect(first.uid == 21)
        #expect(first.author == "writer")
        #expect(first.postedAt == Self.date(2026, 9, 16, 5, 10))
        #expect(first.excerpt == "日誌開頭的幾句話 ...")
        #expect(ranked.last?.excerpt == "", "a blog with no excerpt says nothing, not the figure below it")
    }

    @Test("An excerpt cut with its markup still in it reads as words")
    func escapedExcerpt() throws {
        let ranked = DiscuzRanklist.blogs(in: Self.blogPage)
        let marked = try #require(ranked.first { $0.id == 900 })
        #expect(marked.excerpt == "有格式的字")
    }

    @Test("A blog is a row of its own: its own id, Trends only, the excerpt as its words, its page as its address")
    func aBlogIsItsOwnRow() throws {
        let ranked = DiscuzRanklist.blogs(in: Self.blogPage)
        let note = try #require(ranked.first).asNote(source: Self.source, host: Self.host)
        #expect(note.id == "discuz:\(Self.host):blog:500")
        #expect(note.categories == [.trends])
        #expect(note.board == nil)
        #expect(note.title == "一篇日誌")
        #expect(note.author == "writer")
        #expect(note.handle == "@writer@\(Self.host)")
        #expect(note.body == "日誌開頭的幾句話 ...")
        #expect(note.url?.absoluteString == "https://\(Self.host)/home.php?mod=space&uid=21&do=blog&id=500")
        #expect(note.opening == nil)
        #expect(DiscuzBlogRow.isBlog(note.id))

        // A blog and a thread that share a number are two rows.
        let blog900 = try #require(ranked.first { $0.id == 900 }).asNote(source: Self.source, host: Self.host)
        let thread900 = try #require(DiscuzRanklist.threads(in: Self.threadPage).first)
            .asNote(source: Self.source, host: Self.host)
        #expect(blog900.id != thread900.id)
        #expect(!DiscuzBlogRow.isBlog(thread900.id))
    }

    @Test("Only a blog's four-part id is a blog's")
    func blogIDs() {
        #expect(DiscuzBlogRow.isBlog("discuz:install-g.example:blog:5"))
        #expect(!DiscuzBlogRow.isBlog("discuz:install-g.example:5"))
        #expect(!DiscuzBlogRow.isBlog("discuz::blog:5"))
        #expect(!DiscuzBlogRow.isBlog("discuz:install-g.example:blog:x"))
        #expect(!DiscuzBlogRow.isBlog("discuz:install-g.example:blog:0"))
        #expect(!DiscuzBlogRow.isBlog("discourse:install-f.example:blog:5"))
    }

    // MARK: - Neither

    @Test("A page with no ranking on it is nothing, on both readers")
    func noRanking() {
        let page = #"""
        <html><body><div class="tl"><table><tr class="th"><th>標題</th><td class="frm">版塊</td></tr></table></div>
        <ul><li><a href="forum.php?mod=viewthread&amp;tid=5">x</a></li></ul>
        <p class="emp">沒有排行</p></body></html>
        """#
        #expect(DiscuzRanklist.threads(in: page).isEmpty)
        #expect(DiscuzRanklist.blogs(in: page).isEmpty)
        #expect(DiscuzRanklist.threads(in: Self.blogPage).isEmpty, "a blog ranking has no ranked thread")
        #expect(DiscuzRanklist.blogs(in: Self.threadPage).isEmpty, "a thread ranking has no ranked blog")
    }

    // MARK: - Through the client

    @Test("Each ranking is one page, asked for this week, and read into rows")
    func throughTheClient() async throws {
        let http = FixtureHTTP([
            Self.threadAddress: .text(Self.threadPage),
            Self.blogAddress: .text(Self.blogPage),
        ])
        let client = DiscuzClient(http: http, host: Self.host)
        let threads = try await client.rankedThreads(source: Self.source)
        let blogs = try await client.rankedBlogs(source: Self.source)
        #expect(threads.count == 3)
        #expect(blogs.count == 3)
        #expect(await http.requested.map(\.absoluteString) == [Self.threadAddress, Self.blogAddress])
    }

    @Test("A GBK forum's rankings are read, in its own encoding")
    func gbkRankings() async throws {
        let http = FixtureHTTP([
            Self.threadAddress: .body(Self.gbkThreadPage),
            Self.blogAddress: .body(Self.gbkBlogPage),
        ])
        let client = DiscuzClient(http: http, host: Self.host)
        let thread = try #require(try await client.rankedThreads(source: Self.source).first)
        #expect(thread.title == "版块丙")
        #expect(thread.board == "版块乙")
        #expect(thread.categories == [.board(id: "434"), .trends])
        let blog = try #require(try await client.rankedBlogs(source: Self.source).first)
        #expect(blog.title == "版块丙")
        #expect(blog.body == "链接到外部地址")
        #expect(blog.id == "discuz:\(Self.host):blog:66")
    }

    @Test("An empty ranking is no rows, not a failure; a notice or a challenge is still said")
    func emptyAndRefused() async {
        let empty = DiscuzClient(
            http: FixtureHTTP([Self.threadAddress: .text("<html><body></body></html>")]), host: Self.host
        )
        let rows = try? await empty.rankedThreads(source: Self.source)
        #expect(rows == [])

        let notice = DiscuzClient(http: FixtureHTTP([
            Self.blogAddress: .text(#"<html><body><div id="messagetext"><p>x</p></div></body></html>"#),
        ]), host: Self.host)
        await #expect(throws: DiscuzRequestError.restricted) {
            try await notice.rankedBlogs(source: Self.source)
        }

        let challenged = DiscuzClient(http: FixtureHTTP([
            Self.threadAddress: .text("<html><title>Just a moment...</title></html>", status: 403),
        ]), host: Self.host)
        await #expect(throws: DiscuzRequestError.challenged) {
            try await challenged.rankedThreads(source: Self.source)
        }
    }

    // MARK: - In the store

    @Test("A ranked thread and its board's row are one row, whichever lands first, and it gains Trends")
    func oneRowPerThread() async throws {
        let ranked = try #require(DiscuzRanklist.threads(in: Self.threadPage).first)
        let rankedNote = ranked.asNote(source: Self.source, host: Self.host)
        let boardNote = ranked.thread.asNote(source: Self.source, host: Self.host, board: "版塊甲", boardID: "37")

        for order in [[boardNote, rankedNote], [rankedNote, boardNote]] {
            let store = ItemStore()
            await store.add(Source(host: Self.host, kind: .discuz, boards: [BoardSubscription(fid: 37, name: "版塊甲")]))
            for note in order { await store.ingest([note], ifSourceHere: Self.host) }
            let all = await store.all()
            #expect(all.count == 1)
            #expect(all.first?.categories == [.board(id: "37"), .trends])
            #expect(await store.trends().map(\.id) == [boardNote.id])
        }
    }

    @Test("Blogs are rows of their own, and a Remove takes them with the forum's other rows")
    func blogsInTheStore() async throws {
        let store = ItemStore()
        await store.add(Self.source)
        let threads = DiscuzRanklist.threads(in: Self.threadPage).map { $0.asNote(source: Self.source, host: Self.host) }
        let blogs = DiscuzRanklist.blogs(in: Self.blogPage).map { $0.asNote(source: Self.source, host: Self.host) }
        await store.ingest(threads + blogs, ifSourceHere: Self.host)
        #expect(await store.all().count == 6, "thread 900 and blog 900 are two rows")
        await store.remove(host: Self.host)
        #expect(await store.all().isEmpty)
    }
}
