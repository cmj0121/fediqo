import Foundation
import Testing
@testable import FediqoCore

/// Why a forum will not show a blog or a thread, told apart (#213) — every notice a real install
/// was measured to answer with, classified, and each carried to the reader of one blog or one
/// thread as the refusal it is.
@Suite("A forum's refusals, each as itself")
struct DiscuzRefusalTests {
    private static let host = "discuz.localhost"

    private static func blogAddress(uid: Int = 1, id: Int) -> String {
        "https://\(host)/home.php?mod=space&uid=\(uid)&do=blog&id=\(id)"
    }

    private static func threadAddress(_ tid: Int) -> String {
        "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
    }

    /// A captured region inside a page, as the whole page carries it.
    private static func page(_ region: String) -> String {
        "<!DOCTYPE html><html><head><title>提示信息</title></head><body>\n\(region)\n</body></html>"
    }

    // MARK: - Every captured notice, classified

    @Test("Every notice the real install answered with is classified as the refusal it is")
    func everyCapturedNotice() {
        let cases: [(String, DiscuzRefusal)] = [
            (DiscuzBlogCaptures.signInNotice, .signIn),
            (DiscuzBlogCaptures.missing, .gone),
            (DiscuzBlogCaptures.switchedOff, .blogsOff),
            (DiscuzRefusalCaptures.threadGone, .gone),
            (DiscuzRefusalCaptures.threadStanding, .standing(asked: "抱歉，本帖要求阅读权限高于 200 才能浏览")),
            (DiscuzRefusalCaptures.threadStandingDesktop, .standing(asked: "抱歉，本帖要求阅读权限高于 200 才能浏览")),
            (DiscuzRefusalCaptures.boardStanding, .standing(asked: "抱歉，您没有权限访问该版块")),
            (DiscuzRefusalCaptures.boardPoints, .points(
                asked: "您需要满足以下条件才能访问这个版块 访问条件： 金钱 > 100 您的信息： 金钱: 2"
            )),
        ]
        for (region, expected) in cases {
            let html = Self.page(region)
            #expect(DiscuzRefusalReader.isNotice(html), "\(expected)")
            #expect(DiscuzRefusalReader.refusal(inNotice: html) == expected)
        }
    }

    @Test("The password answers are notices too, and neither is read as a blog")
    func passwordAnswers() {
        for region in [DiscuzRefusalCaptures.wrongPassword, DiscuzRefusalCaptures.rightPassword] {
            #expect(DiscuzRefusalReader.isNotice(Self.page(region)))
            #expect(DiscuzBlogPage.blog(in: Self.page(region), id: 4, uid: 1, host: Self.host) == nil)
        }
    }

    @Test("Discuz!'s own sentences, in both scripts it ships, are each read as their refusal")
    func theForumsOwnSentences() {
        // `lang_message`'s, SC_UTF8 and TC_UTF8, for every refusal a blog or a thread may meet.
        let cases: [(String, DiscuzRefusal?)] = [
            ("抱歉，您需要登录后才能查看", .signIn),
            ("抱歉，您需要登錄後才能查看", .signIn),
            ("请先登录后才能继续浏览", .signIn),
            ("抱歉，您尚未登錄，沒有權限訪問該版塊", .signIn),
            ("抱歉，您要查看的资讯不存在或已被删除", .gone),
            ("抱歉，您要查看的資訊不存在或已被刪除", .gone),
            ("抱歉，指定的主題不存在或已被刪除或正在被審核", .gone),
            ("抱歉，日誌功能尚未開啓", .blogsOff),
            ("抱歉，家园功能尚未开启", .blogsOff),
            ("抱歉，本帖要求閲讀權限高於 200 才能瀏覽", .standing(asked: "抱歉，本帖要求閲讀權限高於 200 才能瀏覽")),
            ("本版塊只有特定用戶組可以訪問", .standing(asked: "本版塊只有特定用戶組可以訪問")),
            ("您需要滿足以下條件才能訪問這個版塊", .points(asked: "您需要滿足以下條件才能訪問這個版塊")),
            ("只有好友才能查看這篇日誌。", nil),
        ]
        for (said, expected) in cases {
            #expect(DiscuzRefusalReader.refusal(said: said) == expected, "\(said)")
        }
        // A notice that offers its own sign-in box is a sign-in, whatever it says.
        #expect(DiscuzRefusalReader.refusal(said: "抱歉", offersSignIn: true) == .signIn)
    }

    // MARK: - Blogs

    @Test("A signed-in reader is refused a private blog, and shown a password blog's form, each as itself")
    func blogPages() async {
        for (region, id, expected) in [
            (DiscuzRefusalCaptures.privacy, 3, DiscuzRefusal.privateToAuthor),
            (DiscuzRefusalCaptures.password, 4, .password),
        ] {
            let address = Self.blogAddress(id: id)
            let client = DiscuzClient(http: FixtureHTTP([address: .text(Self.page(region))]), host: Self.host)
            await #expect(throws: DiscuzRequestError.refusal(expected)) { try await client.blog(uid: 1, id: id) }
        }
    }

    @Test("The privacy page is the author's: another author's friend list is not it")
    func privacyIsTheAuthors() {
        let html = Self.page(DiscuzRefusalCaptures.privacy)
        #expect(DiscuzRefusalReader.blog(in: html, uid: 1) == .privateToAuthor)
        #expect(DiscuzRefusalReader.blog(in: html, uid: 11) == nil)
        // The blog page's own header links the reader's friend list, naming nobody.
        #expect(DiscuzRefusalReader.blog(in: DiscuzBlogCaptures.blog, uid: 1) == nil)
    }

    @Test("A notice is judged without the blog's own words, which may say anything")
    func wordsAreNotANotice() async throws {
        let quoting = DiscuzBlogCaptures.blog.replacingOccurrences(
            of: "First line.", with: #"<div class="jump_c"><div>抱歉，您需要登录后才能查看</div></div>"#
        )
        let address = Self.blogAddress(id: 1)
        let client = DiscuzClient(http: FixtureHTTP([address: .text(quoting)]), host: Self.host)
        let blog = try await client.blog(uid: 1, id: 1)
        #expect(blog.body.contains("抱歉，您需要登录后才能查看"))
    }

    // MARK: - Threads

    @Test("A thread refused for standing, points, or being gone is refused as itself")
    func threadNotices() async {
        let cases: [(String, Int, DiscuzRefusal)] = [
            (DiscuzRefusalCaptures.threadStanding, 200, .standing(asked: "抱歉，本帖要求阅读权限高于 200 才能浏览")),
            (DiscuzRefusalCaptures.boardStanding, 200, .standing(asked: "抱歉，您没有权限访问该版块")),
            (DiscuzRefusalCaptures.boardPoints, 200, .points(
                asked: "您需要满足以下条件才能访问这个版块 访问条件： 金钱 > 100 您的信息： 金钱: 2"
            )),
            (DiscuzRefusalCaptures.threadGone, 404, .gone),
        ]
        for (region, status, expected) in cases {
            let http = FixtureHTTP([Self.threadAddress(7): .text(Self.page(region), status: status)])
            let client = DiscuzClient(http: http, host: Self.host)
            await #expect(throws: DiscuzRequestError.refusal(expected)) { try await client.post(tid: 7) }
            await #expect(throws: DiscuzRequestError.refusal(expected)) { try await client.replies(tid: 7) }
        }
    }

    @Test("A thread answered with the sign-in page is a sign-in refusal")
    func threadSignIn() async {
        let client = DiscuzClient(http: SignInRedirect(host: Self.host), host: Self.host)
        await #expect(throws: DiscuzRequestError.refusal(.signIn)) { try await client.post(tid: 2) }
    }

    /// What the real install did with a signed-out reader's thread that asks standing: a 302 to
    /// the sign-in page, which answers 200 with a login form.
    private struct SignInRedirect: HTTPClient {
        let host: String

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            let login = URL(string: "https://\(host)/member.php?mod=logging&action=login&mobile=2") ?? url
            let response = HTTPURLResponse(url: login, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            return (Data("<html><body><form></form></body></html>".utf8), try #require(response))
        }
    }

    @Test("A thread its author sells says its price, and its replies still read")
    func pricedThread() async throws {
        let html = Self.page(DiscuzRefusalCaptures.pricedThread)
        #expect(DiscuzRefusalReader.price(in: html, tid: 3) == .price(asked: "本主题需向作者支付 5 金钱 才能浏览"))
        #expect(DiscuzRefusalReader.price(in: html, tid: 33) == nil, "another thread's price is not this one's")
        let client = DiscuzClient(http: FixtureHTTP([Self.threadAddress(3): .text(html)]), host: Self.host)
        await #expect(throws: DiscuzRequestError.refusal(.price(asked: "本主题需向作者支付 5 金钱 才能浏览"))) {
            try await client.post(tid: 3)
        }
        #expect(try await client.replies(tid: 3).isEmpty)
    }

    @Test("A board or a join is not asked which refusal a notice is")
    func joinStaysRestricted() async {
        let address = "https://\(Self.host)/forum.php?mod=forumdisplay&fid=2&filter=author&orderby=dateline"
        let http = FixtureHTTP([address: .text(Self.page(DiscuzRefusalCaptures.boardStanding.replacingOccurrences(
            of: #"class="jump_c""#, with: #"id="messagetext""#
        )))])
        let client = DiscuzClient(http: http, host: Self.host)
        await #expect(throws: DiscuzRequestError.restricted) {
            try await client.board(2, source: Source(host: Self.host, kind: .discuz))
        }
    }

    // MARK: - The password

    @Test("The password goes in as a bound argument, to the page's own origin, following no redirect")
    func thePasswordScript() {
        let script = DiscuzBlogPasswordScript.send
        #expect(script.contains("body.set('viewpwd', password)"))
        #expect(script.contains("redirect: 'error'"))
        #expect(script.contains("credentials: 'same-origin'"))
        #expect(script.contains("action.origin !== location.origin"))
        #expect(script.contains("location.protocol !== 'https:'"))
        #expect(DiscuzBlogPasswordScript.isUnlock(cookie: "eA11_2132_view_pwd_blog_4", blog: 4))
        #expect(!DiscuzBlogPasswordScript.isUnlock(cookie: "eA11_2132_view_pwd_blog_14", blog: 4))
        #expect(!DiscuzBlogPasswordScript.isUnlock(cookie: "eA11_2132_view_pwd_blog_4", blog: 14))
        #expect(!DiscuzBlogPasswordScript.isUnlock(cookie: "eA11_2132_auth", blog: 4))
    }

    @Test("Only what a sign-in could change is asked again after one")
    func signInMayChange() {
        #expect(DiscuzRefusal.signIn.signInMayChange)
        #expect(DiscuzRefusal.password.signInMayChange)
        #expect(DiscuzRefusal.standing(asked: "").signInMayChange)
        #expect(!DiscuzRefusal.gone.signInMayChange)
        #expect(!DiscuzRefusal.blogsOff.signInMayChange)
    }
}
