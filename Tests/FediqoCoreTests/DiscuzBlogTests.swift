import Foundation
import Testing
@testable import FediqoCore

/// A ranked blog, read off its own page (#209).
///
/// **Two kinds of page.** `DiscuzBlogCaptures` is a real install's, fetched off the local Discuz!
/// X5.0 in `servers/`. `page` below is written by hand in the X3.x template's shape, as a
/// signed-in reader on a busy forum is served it — the reader's own name in the header, a
/// visitor's and a commenter's around the words — which a fresh local install has none of, so
/// that none of their faces can be taken for the author's.
@Suite("A forum's blog, read")
struct DiscuzBlogTests {
    private static let host = "install-g.example"
    private static let source = Source(host: host, kind: .discuz)
    private static let address = "https://\(host)/home.php?mod=space&uid=21&do=blog&id=500"

    /// A blog page as X3.x draws it: the reader's own space in the header, the breadcrumb naming
    /// the author, the heading and its date line, the words — with a quotation, a picture and a
    /// line break in them — the author's card in the sidebar, a visitor and a comment.
    static let page = #"""
    <!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <title>一篇日誌 - 某人的日誌 - Powered by Discuz!</title></head><body>
    <div id="toptb" class="cl"><div class="y">
    <strong class="vwmy"><a href="home.php?mod=space&amp;uid=99" target="_blank" title="訪問我的空間">讀者</a></strong>
    <a href="home.php?mod=spacecp">設置</a>
    <a href="member.php?mod=logging&amp;action=logout&amp;formhash=abc">退出</a>
    </div></div>
    <div id="hd"><div class="wp"><div class="hdc cl"><h2><a href="./" title="論壇"><img src="static/image/common/logo.png" alt="論壇" border="0" /></a></h2></div></div></div>
    <div id="wp" class="wp">
    <div id="pt" class="bm cl"><div class="z">
    <a href="./" class="nvhm" title="首頁">論壇</a> <em>&rsaquo;</em>
    <a href="home.php">家園</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21">某人</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21&amp;do=blog&amp;view=me">日誌</a> <em>&rsaquo;</em>
    一篇日誌
    </div></div>
    <div id="ct" class="ct2 wp cl"><div class="mn"><div class="bm bw0"><div class="bm_c">
    <div class="vw mbm">
    <div class="h pbm">
    <h1 class="ph">一篇日誌 &amp; 其他</h1>
    <p class="xg2">
    <span class="xg1">2026-9-10 21:30</span>
    <span class="pipe">|</span><a href="home.php?mod=space&amp;uid=21&amp;do=blog&amp;id=500" class="xg1">1234 次閱讀</a>
    <span class="pipe">|</span><span class="xg1">個人分類：<a href="home.php?mod=space&amp;uid=21&amp;do=blog&amp;classid=3&amp;view=me">雜記</a></span>
    </p>
    </div>
    <div id="blog_article" class="d cl">
    <div class="quote"><blockquote>別人說過的話。</blockquote></div>
    第一行字。<br />
    <img src="data/attachment/album/202609/10/photo.jpg" class="zoom" /><br />
    <div style="text-align:center"><font size="4">第二行字。</font></div>
    </div>
    <div class="o cl"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;type=blog&amp;id=500" onclick="showWindow(this.id, this.href);">收藏</a></div>
    </div>
    <div id="comment" class="bm">
    <dl class="bbda cl"><dd class="m avt"><a href="home.php?mod=space&amp;uid=33"><img src="uc_server/avatar.php?uid=33&amp;size=small" /></a></dd>
    <dt><a href="home.php?mod=space&amp;uid=33">留言者</a> <span class="xg1">2026-9-11 08:00</span></dt>
    <dd>說得好。</dd></dl>
    </div>
    </div></div></div></div>
    <div class="sd">
    <div id="pcd" class="bm cl"><div class="bm_c"><div class="hm">
    <p><a href="home.php?mod=space&amp;uid=21" class="avtm"><img src="https://install-g.example/uc_server/avatar.php?uid=21&amp;size=middle" /></a></p>
    <h2 class="xs2"><a href="home.php?mod=space&amp;uid=21">某人</a></h2>
    </div></div></div>
    <div class="bm"><div class="bm_h"><h3>最近訪客</h3></div><div class="bm_c"><ul class="ml mls cl">
    <li><a href="home.php?mod=space&amp;uid=44" class="avt"><img src="uc_server/avatar.php?uid=44&amp;size=small" /></a><p><a href="home.php?mod=space&amp;uid=44">訪客</a></p></li>
    </ul></div></div>
    </div>
    </div>
    </body></html>
    """#

    // MARK: - A real install's page

    @Test("A real X5.0 blog page gives its date and words")
    func readsARealPage() throws {
        let blog = try #require(DiscuzBlogPage.blog(
            in: DiscuzBlogCaptures.blog, id: 1, uid: 1, host: "discuz.localhost"
        ))
        // The date comes after the read count on the same line, in the forum's own time zone.
        #expect(blog.postedAt == Self.date(2026, 9, 11, 5, 30))
        #expect(blog.body == "First line.\n\nSecond line.")
        #expect(blog.quoted == [DiscuzQuotation(words: "Somebody else said this.")])
        #expect(!blog.body.contains("路过"), "the click buttons are under the words, not in them")
        // The author uploaded no picture: the template's lazy `noavatar` placeholder is none.
        #expect(blog.avatarURL == nil)
    }

    @Test("A real page's lazy-loaded avatar is read where the author has one")
    func readsARealAvatar() throws {
        let page = DiscuzBlogCaptures.blog.replacingOccurrences(
            of: "./data/avatar/noavatar.svg", with: "./data/avatar/000/00/00/01_avatar_small.jpg"
        )
        let blog = try #require(DiscuzBlogPage.blog(in: page, id: 1, uid: 1, host: "discuz.localhost"))
        #expect(blog.avatarURL?.absoluteString == "https://discuz.localhost/data/avatar/000/00/00/01_avatar_small.jpg")
    }

    @Test("A real install's refusals — sign in, no such blog, blogs switched off — are refused, each as itself")
    func realRefusals() async {
        for (page, refusal) in [
            (DiscuzBlogCaptures.signInNotice, DiscuzRefusal.signIn),
            (DiscuzBlogCaptures.missing, .gone),
            (DiscuzBlogCaptures.switchedOff, .blogsOff),
        ] {
            let client = DiscuzClient(http: FixtureHTTP([Self.address: .text(page)]), host: Self.host)
            await #expect(throws: DiscuzRequestError.refusal(refusal)) { try await client.blog(uid: 21, id: 500) }
            #expect(DiscuzBlogPage.blog(in: page, id: 500, uid: 21, host: Self.host) == nil)
        }
    }

    // MARK: - The page, as X3.x's template promises it

    @Test("A blog's page gives when it was written, its words and its author's picture")
    func readsTheBlog() throws {
        let blog = try #require(DiscuzBlogPage.blog(in: Self.page, id: 500, uid: 21, host: Self.host))
        #expect(blog.id == 500 && blog.uid == 21)
        #expect(blog.postedAt == Self.date(2026, 9, 10, 21, 30))
        // The words, and nobody else's: the quotation kept apart, the picture leaving nothing.
        #expect(blog.body.contains("第一行字。"))
        #expect(blog.body.contains("第二行字。"))
        #expect(!blog.body.contains("別人說過的話"))
        #expect(!blog.body.contains("photo.jpg"))
        #expect(!blog.body.contains("說得好"), "a comment is under the words, not in them")
        #expect(!blog.body.contains("收藏"))
        #expect(blog.quoted == [DiscuzQuotation(words: "別人說過的話。")])
        // The author's card, not a commenter's or a visitor's face.
        #expect(blog.avatarURL?.absoluteString == "https://install-g.example/uc_server/avatar.php?uid=21&size=middle")
        // What is kept with its row, as a thread's opening post is.
        #expect(blog.opening == ForumOpening(
            words: blog.body, quoted: blog.quoted, avatarURL: blog.avatarURL, postedAt: blog.postedAt
        ))
    }

    @Test("A recent blog's date is read out of the title the forum wrote behind its words")
    func aRecentDate() throws {
        let page = Self.page.replacingOccurrences(
            of: #"<span class="xg1">2026-9-10 21:30</span>"#,
            with: #"<span class="xg1"><span title="2026-9-22 09:05">3&nbsp;小時前</span></span>"#
        )
        let blog = try #require(DiscuzBlogPage.blog(in: page, id: 500, uid: 21, host: Self.host))
        #expect(blog.postedAt == Self.date(2026, 9, 22, 9, 5))
    }

    @Test("Only the words are required: a page with no date or picture still reads")
    func onlyTheWordsAreRequired() throws {
        let page = #"<html><body><div id="blog_article" class="d cl">只有字。</div></body></html>"#
        let blog = try #require(DiscuzBlogPage.blog(in: page, id: 500, uid: 21, host: Self.host))
        #expect(blog.body == "只有字。")
        #expect(blog.postedAt == nil && blog.avatarURL == nil)
    }

    @Test("A face is never taken from under the words, even the author's own in a comment")
    func noFaceFromTheComments() throws {
        // No author card: the only picture linked to the author's space is in a comment they
        // left under their own blog, and one in the words themselves.
        let page = Self.page
            .replacingOccurrences(of: #"<div id="pcd""#, with: #"<div id="elsewhere""#)
            .replacingOccurrences(
                of: #"<dl class="bbda cl"><dd class="m avt"><a href="home.php?mod=space&amp;uid=33">"#,
                with: #"<dl class="bbda cl"><dd class="m avt"><a href="home.php?mod=space&amp;uid=21">"#
            )
            .replacingOccurrences(
                of: "第一行字。<br />",
                with: #"第一行字。<a href="home.php?mod=space&amp;uid=21"><img src="data/attachment/me.jpg" /></a><br />"#
            )
        let blog = try #require(DiscuzBlogPage.blog(in: page, id: 500, uid: 21, host: Self.host))
        #expect(blog.avatarURL == nil)
    }

    @Test("A blog whose words look like a refusal is still read")
    func wordsThatLookLikeARefusal() async throws {
        let page = Self.page.replacingOccurrences(
            of: "第一行字。<br />",
            with: #"第一行字：Just a moment… <code>&lt;div id="messagetext"&gt;</code> <span id="messagetext">x</span><br />"#
        )
        let http = FixtureHTTP([Self.address: .text(page)])
        let blog = try await DiscuzClient(http: http, host: Self.host).blog(uid: 21, id: 500)
        #expect(blog.body.contains("Just a moment"))
    }

    @Test("A page with no blog on it is no blog")
    func noBlogIsNothing() {
        #expect(DiscuzBlogPage.blog(in: Self.passwordPage, id: 500, uid: 21, host: Self.host) == nil)
        #expect(DiscuzBlogPage.blog(in: "<html><body></body></html>", id: 500, uid: 21, host: Self.host) == nil)
    }

    // MARK: - The client

    @Test("The client reads the page the row names, by its two numbers")
    func theClientReadsIt() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page)])
        let blog = try await DiscuzClient(http: http, host: Self.host).blog(uid: 21, id: 500)
        #expect(await http.requested.map(\.absoluteString) == [Self.address])
        #expect(blog.body.contains("第一行字。"))
    }

    @Test("A blog the forum refuses is refused as a thread is, and one it cannot show is unreadable")
    func refusals() async {
        let notice = #"""
        <html><body><div id="messagetext" class="alert_error"><p>只有好友才能查看這篇日誌。</p></div></body></html>
        """#
        let cases: [(FixtureHTTP.Outcome, DiscuzRequestError)] = [
            (.text(notice), .restricted),
            (.text("<html><title>Just a moment...</title></html>", status: 403), .challenged),
            (.text("", status: 403), .refused(403)),
            (.text(Self.passwordPage), .noPosts),
        ]
        for (outcome, expected) in cases {
            let client = DiscuzClient(http: FixtureHTTP([Self.address: outcome]), host: Self.host)
            await #expect(throws: expected) { try await client.blog(uid: 21, id: 500) }
        }
        let client = DiscuzClient(http: FixtureHTTP(), host: Self.host)
        await #expect(throws: DiscuzRequestError.invalidURL) { try await client.blog(uid: 0, id: 500) }
    }

    // MARK: - The row

    @Test("A blog's row gives back the two numbers its page is read by")
    func theRowNamesItsBlog() throws {
        let ranked = DiscuzRankedBlog(
            rank: 1, id: 500, uid: 21, title: "一篇日誌", author: "某人", postedAt: nil, excerpt: "…"
        )
        let note = ranked.asNote(source: Self.source, host: Self.host)
        #expect(note.url?.absoluteString == Self.address)
        let address = try #require(DiscuzBlogRow.address(noteID: note.id, url: note.url))
        #expect(address.uid == 21 && address.id == 500)
        // Not a blog, or an address that names another one: nothing.
        #expect(DiscuzBlogRow.address(noteID: "discuz:\(Self.host):500", url: note.url) == nil)
        #expect(DiscuzBlogRow.address(noteID: DiscuzBlogRow.id(host: Self.host, blog: 501), url: note.url) == nil)
        #expect(DiscuzBlogRow.address(noteID: note.id, url: nil) == nil)
    }

    // MARK: - Helpers

    /// A blog behind its author's password: the forum answers with a form, and no words.
    private static let passwordPage = #"""
    <html><body><div id="ct" class="wp cl"><div class="mn"><div class="bm bw0"><div class="bm_c">
    <form method="post" autocomplete="off" action="home.php?mod=space&amp;uid=21&amp;do=blog&amp;id=500">
    <p>這篇日誌需要密碼</p><input type="password" name="viewpwd" class="px" /><button type="submit" class="pn">提交</button>
    </form></div></div></div></div></body></html>
    """#

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }
}
