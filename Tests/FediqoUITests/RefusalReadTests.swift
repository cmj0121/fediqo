import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// A forum blog or thread that will not show itself says why in its own way, and a password opens
/// it in the app (#213).
///
/// What this holds without a screen: that each reason the real install gave reaches the pane as
/// itself, with its own mark and sentence and only the actions that could help; that a password
/// blog read signed in offers the password, opens with the right one, says so for a wrong one and
/// can be tried again, and leaves nothing of the password on this device; that one read signed out
/// offers signing in and reads again once signed in; and that a thread refused for these reasons
/// is drawn with the same view. How the view looks, in light and dark, on each platform and
/// through VoiceOver, is for a running app.
///
/// The notices below are the real install's (`DiscuzRefusalCaptures`, in Core's tests), cut to
/// the container that says why.
@MainActor
@Suite("A forum's refusals, read in the app")
struct RefusalReadTests {
    private static let host = "discuz.localhost"
    private static let source = Source(host: host, kind: .discuz)
    private static let address = "https://\(host)/home.php?mod=space&uid=1&do=blog&id=4"
    private static let password = "open-sesame-7Q"

    private static let signInNotice = #"""
    <html><body><div id="messagetext" class="alert_info">
    <p>抱歉，您需要登录后才能查看</p>
    </div>
    <div id="messagelogin"></div></body></html>
    """#

    private static let passwordForm = #"""
    <html><body><div id="ct" class="ct2_a wp cl"><div class="mn"><div class="bm bw0">
    <h1 class="mt">密码验证</h1>
    <form method="post" autocomplete="off"  id="invalueform" name="invalueform" action="home.php?mod=misc&amp;ac=inputpwd" >
    <input type="hidden" name="blogid" value="4" />
    <input type="hidden" name="formhash" value="00000000" />
    <input type="password" name="viewpwd" value="" class="px mtn" />
    </form></div></div></div></body></html>
    """#

    private static let privacyPage = #"""
    <html><body><div id="ct" class="wp cl"><div class="nfl">
    <h2 class="xs2">抱歉！由于 admin 的隐私设置，您不能访问当前内容</h2>
    <p class="mtm mbm"><a href="home.php?mod=space&amp;uid=1&amp;do=friend">查看好友列表</a></p>
    </div></div></body></html>
    """#

    private static let gone = #"""
    <html><body><div id="messagetext" class="alert_error"><p>抱歉，您要查看的信息不存在或已被删除</p></div></body></html>
    """#

    private static let blogsOff = #"""
    <html><body><div id="messagetext" class="alert_error"><p>抱歉，日志功能尚未开启</p></div></body></html>
    """#

    private static let blogPage = #"""
    <html><body><div class="vw mbm"><div class="h pbm">
    <h1 class="ph">Behind a password</h1>
    <p class="xg2"><span class="xg1">已有 1 次阅读</span><span class="xg1">2026-9-24 07:20</span></p>
    </div>
    <div id="blog_article" class="d cl">The locked words.</div>
    </div></body></html>
    """#

    /// The blog's row as the ranking list wrote it.
    private static let ranked = Note(
        id: DiscuzBlogRow.id(host: host, blog: 4), source: source, author: "admin",
        handle: "@admin@\(host)", body: "The locked…", title: "Behind a password",
        postedAt: Date(timeIntervalSince1970: 1_790_000_300), categories: [.trends], url: URL(string: address)
    )

    private static var rowID: String { ranked.key.rowID }

    /// A session holding the blog's row, whose blogs are read through `http`.
    private static func session(_ http: any HTTPClient, store: ItemStore = ItemStore()) async -> ShellSession {
        await store.add(source)
        await store.ingest([ranked])
        let blogs = ForumBlogs(http: http)
        blogs.work = SourceWork()
        let session = ShellSession(
            http: FixtureHTTP(), store: store, posts: ForumPosts(http: FixtureHTTP()), blogs: blogs
        )
        await session.reloadFromStore()
        return session
    }

    // MARK: - Each reason, as itself

    @Test("Each refusal a blog meets reaches the pane as itself, with only the help it allows")
    func eachBlogRefusal() async throws {
        let cases: [(String, ForumBlogReading, Set<ForumRefusalAction>)] = [
            (Self.signInNotice, .absent(.refusal(.signIn)), [.signIn]),
            (Self.privacyPage, .absent(.refusal(.privateToAuthor)), [.page]),
            (Self.gone, .absent(.refusal(.gone)), []),
            (Self.blogsOff, .absent(.refusal(.blogsOff)), []),
            (Self.passwordForm, .locked(.asking), [.password]),
            ("<html><body><p>nothing here</p></body></html>", .absent(.unreadable), [.again, .page]),
        ]
        for (page, expected, actions) in cases {
            let session = await Self.session(FixtureHTTP([Self.address: .text(page)]))
            await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
            let reading = session.blogs.reading(of: try #require(session.held(Self.rowID)))
            #expect(reading == expected)
            let absence: ForumPosts.Absence = switch reading {
            case .absent(let absence): absence
            default: .refusal(.password)
            }
            #expect(ForumRefusalView.actions(for: absence) == actions, "\(expected)")
            #expect(reading?.offersPage == (actions.contains(.page) && !actions.contains(.password)))
        }
    }

    @Test("Trying again is offered only where the next read could come back different")
    func tryingAgainOnlyWhereItHelps() {
        let every: [ForumPosts.Absence] = [
            .refused, .unreadable, .unreachable, .crowded,
            .refusal(.signIn), .refusal(.password), .refusal(.privateToAuthor), .refusal(.gone),
            .refusal(.blogsOff), .refusal(.standing(asked: "x")), .refusal(.points(asked: "x")),
            .refusal(.price(asked: "x")),
        ]
        let again = every.filter { ForumRefusalView.actions(for: $0).contains(.again) }
        #expect(again == [.unreadable, .unreachable])
        // Signing in only where signing in is the answer; the password only for a password.
        #expect(every.filter { ForumRefusalView.actions(for: $0).contains(.signIn) } == [.refusal(.signIn)])
        #expect(every.filter { ForumRefusalView.actions(for: $0).contains(.password) } == [.refusal(.password)])
        // Gone, and blogs switched off, offer nothing at all.
        #expect(ForumRefusalView.actions(for: .refusal(.gone)).isEmpty)
        #expect(ForumRefusalView.actions(for: .refusal(.blogsOff)).isEmpty)
    }

    @Test("Each refusal has its own mark and its own sentence, in every language")
    func marksAndSentences() {
        let refusals: [DiscuzRefusal] = [
            .signIn, .password, .privateToAuthor, .gone, .blogsOff,
            .standing(asked: ""), .points(asked: ""), .price(asked: ""),
        ]
        let glyphs = refusals.map { ForumRefusalView.glyph(for: .refusal($0)) }
        #expect(Set(glyphs).count == refusals.count, "a mark each")
        #expect(ForumRefusalView.glyph(for: .refusal(.gone)) == "xmark.bin", "gone wears the deleted-at-source mark (#179)")
        for language in DummyLanguage.allCases {
            let said = refusals.map { ForumRefusalView.sentence(for: $0, language: language) }
            #expect(Set(said).count == refusals.count, "a sentence each, \(language)")
            for key in [
                "refusal.signIn.action", "refusal.password.field", "refusal.password.open",
                "refusal.password.trying", "refusal.password.wrong", "refusal.password.note",
                "refusal.asked", "refusal.again", "refusal.page.hint",
            ] {
                let text = L10n.t(key, language: language)
                #expect(!text.isEmpty && text != key, "\(key) \(language)")
            }
        }
        // What the forum asked is said, and read out after the sentence.
        let price = ForumPosts.Absence.refusal(.price(asked: "本主题需向作者支付 5 金钱 才能浏览"))
        #expect(ForumRefusalView.asked(in: price) == "本主题需向作者支付 5 金钱 才能浏览")
        #expect(ForumRefusalView.spoken(price, sentence: "S").hasPrefix("S "))
        #expect(ForumRefusalView.spoken(price, sentence: "S").contains("5 金钱"))
        #expect(ForumRefusalView.asked(in: .refusal(.gone)) == nil)
    }

    // MARK: - The password

    @Test("The right password reads the blog, kept as any read blog is, and its cookie is let go of")
    func theRightPassword() async throws {
        let http = LockedBlog(form: Self.passwordForm, blog: Self.blogPage)
        let session = await Self.session(http)
        let sent = Sent()
        session.blogs.unlocking = { host, page, password in
            await sent.note(host: host, page: page, password: password)
            if password == Self.password { await http.open() }
        }
        session.blogs.forgetting = { host, blog in await sent.forgot(host: host, blog: blog) }

        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        #expect(session.blogs.reading(of: try #require(session.held(Self.rowID))) == .locked(.asking))

        #expect(await session.blogs.unlock(try #require(session.held(Self.rowID)), password: Self.password))
        await session.reloadFromStore()
        let read = try #require(session.held(Self.rowID))
        #expect(read.body == "The locked words.")
        #expect(session.blogs.reading(of: read) == .read)

        // Sent once, to that forum's own blog page, over https, and the cookie let go of.
        let asked = await sent.asked
        #expect(asked.count == 1)
        #expect(asked.first?.host == Self.host)
        #expect(asked.first?.page.absoluteString == Self.address)
        #expect(asked.first?.page.scheme == "https")
        #expect(await sent.forgotten == [Self.host + "#4"])
    }

    @Test("A wrong password says so in place, and the right one after it opens the blog")
    func aWrongPasswordThenTheRightOne() async throws {
        let http = LockedBlog(form: Self.passwordForm, blog: Self.blogPage)
        let session = await Self.session(http)
        session.blogs.unlocking = { _, _, password in
            if password == Self.password { await http.open() }
        }
        session.blogs.forgetting = { _, _ in }
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)

        #expect(!(await session.blogs.unlock(try #require(session.held(Self.rowID)), password: "not-it")))
        #expect(session.blogs.reading(of: try #require(session.held(Self.rowID))) == .locked(.wrong))
        #expect(ForumRefusalView.actions(for: .refusal(.password)) == [.password], "typed again, not tried again")

        #expect(await session.blogs.unlock(try #require(session.held(Self.rowID)), password: Self.password))
        await session.reloadFromStore()
        #expect(session.blogs.reading(of: try #require(session.held(Self.rowID))) == .read)
    }

    @Test("While a password is on its way the form says so, and a second press sends nothing")
    func tryingTheOne() async throws {
        let http = LockedBlog(form: Self.passwordForm, blog: Self.blogPage)
        let session = await Self.session(http)
        let gate = Gate()
        let sent = Sent()
        session.blogs.unlocking = { host, page, password in
            await sent.note(host: host, page: page, password: password)
            await gate.wait()
        }
        session.blogs.forgetting = { _, _ in }
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        let row = try #require(session.held(Self.rowID))

        let first = Task { await session.blogs.unlock(row, password: Self.password) }
        #expect(await spun { session.blogs.reading(of: row) == .locked(.trying) })
        #expect(!(await session.blogs.unlock(row, password: Self.password)))
        await gate.open()
        _ = await first.value
        #expect(await sent.asked.count == 1)
    }

    @Test("Nothing of the password is left on this device: not in the store, a save, the settings or the blogs")
    func nothingOfThePasswordRemains() async throws {
        let http = LockedBlog(form: Self.passwordForm, blog: Self.blogPage)
        let store = ItemStore()
        let session = await Self.session(http, store: store)
        session.blogs.unlocking = { _, _, password in
            if password == Self.password { await http.open() }
        }
        session.blogs.forgetting = { _, _ in }
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        _ = await session.blogs.unlock(try #require(session.held(Self.rowID)), password: "a-wrong-one-3F")
        #expect(await session.blogs.unlock(try #require(session.held(Self.rowID)), password: Self.password))

        // What a save writes.
        let dir = FileManager.default.temporaryDirectory.appending(path: "refusal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)
        for secret in [Self.password, "a-wrong-one-3F"] {
            let bytes = Data(secret.utf8)
            let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path())
            #expect(!files.isEmpty, "a save was written")
            for file in files {
                let data = (try? Data(contentsOf: dir.appending(path: file))) ?? Data()
                #expect(data.range(of: bytes) == nil, "\(file)")
            }
            // What the rows hold, the settings, and what the blogs hold this run.
            #expect(!String(describing: snapshot.notes).contains(secret))
            #expect(!String(describing: UserDefaults.standard.dictionaryRepresentation()).contains(secret))
            #expect(!String(describing: Mirror(reflecting: session.blogs).children.map(\.value)).contains(secret))
            #expect(!String(describing: session.blogs.reading(of: try #require(session.held(Self.rowID)))).contains(secret))
        }
    }

    // MARK: - Signed out

    @Test("Signed out, a blog offers signing in, and reads once a sign-in lands")
    func signedOutOffersSigningIn() async throws {
        let http = LockedBlog(form: Self.signInNotice, blog: Self.blogPage)
        let session = await Self.session(http)
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        let row = try #require(session.held(Self.rowID))
        #expect(session.blogs.reading(of: row) == .absent(.refusal(.signIn)))
        #expect(ForumRefusalView.actions(for: .refusal(.signIn)) == [.signIn])

        // With no sign-in to send it through, a password is never sent: signing in is offered.
        session.blogs.unlocking = nil
        #expect(!(await session.blogs.unlock(row, password: Self.password)))
        #expect(session.blogs.reading(of: row) == .absent(.refusal(.signIn)))

        // The sign-in lands; the blog is read again as the member the reader now is.
        await http.open()
        session.blogs.signedIn(host: Self.host)
        #expect(await spun { session.blogs.reading(of: row) == .read })
        await session.reloadFromStore()
        #expect(session.held(Self.rowID)?.body == "The locked words.")
    }

    @Test("A sign-in does not read again what no sign-in could change")
    func goneIsNotAskedAgain() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.gone)])
        let session = await Self.session(http)
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        session.blogs.signedIn(host: Self.host)
        for _ in 0..<50 { await Task.yield() }
        #expect(await http.requested.count == 1)
        #expect(session.blogs.reading(of: try #require(session.held(Self.rowID))) == .absent(.refusal(.gone)))
    }

    // MARK: - Threads, the same way

    @Test("A thread refused for standing, points, a price, a sign-in or being gone is drawn as a blog's refusal is")
    func threadsReadTheSameWay() async throws {
        let tid = 3
        let address = "https://\(Self.host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
        let standing = #"<html><body><div class="jump_c"><div>抱歉，本帖要求阅读权限高于 200 才能浏览</div></div></body></html>"#
        let priced = #"""
        <html><body><div class="viewthread"><div class="plc cl" id="pid3">
        <div class="display pi pione"><ul class="authi"><li class="mtit"><span class="z">
        <a href="home.php?mod=space&amp;uid=1&amp;mobile=2">admin</a></span></li></ul>
        <div class="message"><div class="locked">
        <a href="forum.php?mod=misc&amp;action=pay&amp;tid=3&amp;pid=3&amp;mobile=2" class="y viewpay dialog">购买主题</a>
        本主题需向作者支付 <strong>5 金钱</strong> 才能浏览</div></div>
        </div></div></div></body></html>
        """#
        let cases: [(String, Int, DiscuzRefusal)] = [
            (standing, 200, .standing(asked: "抱歉，本帖要求阅读权限高于 200 才能浏览")),
            (Self.gone.replacingOccurrences(of: "信息", with: "主题"), 404, .gone),
            (priced, 200, .price(asked: "本主题需向作者支付 5 金钱 才能浏览")),
        ]
        for (page, status, expected) in cases {
            let posts = ForumPosts(http: FixtureHTTP([address: .text(page, status: status)]))
            posts.work = SourceWork()
            let ref = ForumThreadRef(host: Self.host, tid: tid)
            await posts.fetch(ref)
            await posts.fetchReplies(ref)
            let opening = posts.reading(ref, opened: true)
            #expect(opening == .absent(.refusal(expected)))
            // The pane says it once, with the view a blog's refusal is drawn with.
            #expect(DummyThreadPane.refusal(opening: opening, replies: posts.standing(of: ref)) == expected)
            #expect(ForumPostBand.sentence(for: .refusal(expected)) == ForumRefusalView.sentence(for: expected))
            #expect(ForumPostBand.spoken(opening) == ForumRefusalView.sentence(for: expected))
            #expect(!ForumRefusalView.actions(for: .refusal(expected)).contains(.again))
        }
        // A thread that asks a sign-in offers signing in, as a blog does.
        #expect(DummyThreadPane.refusal(opening: .absent(.refusal(.signIn)), replies: .unasked) == .signIn)
        #expect(DummyThreadPane.refusal(opening: .coming, replies: .absent(.refusal(.gone))) == .gone)
        #expect(DummyThreadPane.refusal(opening: .withheld, replies: .none) == nil)
    }

    @Test("A refusal a sign-in could change is asked again after one; one it could not is not")
    func threadRefusalsAfterASignIn() {
        #expect(ForumPosts.Absence.refusal(.signIn).signInMayChange)
        #expect(ForumPosts.Absence.refusal(.standing(asked: "")).signInMayChange)
        #expect(!ForumPosts.Absence.refusal(.gone).signInMayChange)
        #expect(!ForumPosts.Absence.unreachable.signInMayChange)
        #expect(ForumPosts.Absence.refused.signInMayChange)
    }
}

/// A blog page that answers with one page until it is opened, and with the blog after — the
/// forum as a right password, or a sign-in, leaves it.
private actor LockedBlog: HTTPClient {
    private let form: String
    private let blog: String
    private var opened = false

    init(form: String, blog: String) {
        self.form = form
        self.blog = blog
    }

    func open() { opened = true }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        return (Data((opened ? blog : form).utf8), try #require(response))
    }
}

/// What was sent where, and what was let go of — never kept past the test.
private actor Sent {
    private(set) var asked: [(host: String, page: URL)] = []
    private(set) var forgotten: [String] = []

    func note(host: String, page: URL, password: String) {
        asked.append((host, page))
    }

    func forgot(host: String, blog: Int) {
        forgotten.append("\(host)#\(blog)")
    }
}
