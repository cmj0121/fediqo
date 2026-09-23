import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// A forum's ranked blog, read in the app rather than as its page (#209).
///
/// What this holds without a screen: that opening the blog reads its page once and draws its
/// title, author, date and words from the row the read landed on; that the row then reads with
/// the network off; that a blog the forum refuses says why and still offers its page; that leaving
/// gives the row back; and that a blog is never read by being reached. How the pane looks, in
/// light and dark, on each platform and through VoiceOver, is for a running app.
///
/// `@MainActor` on the suite, for the reason `LinkTests` gives at length.
@MainActor
@Suite("A forum's ranked blog, read in the app")
struct BlogReadTests {
    private static let host = "install-g.example"
    private static let source = Source(host: host, kind: .discuz)
    private static let address = "https://\(host)/home.php?mod=space&uid=21&do=blog&id=500"

    /// A blog page as Discuz! X3.x draws it, trimmed to what is read: the breadcrumb naming the
    /// author, the heading and its date line, the words, and the author's card.
    private static let page = #"""
    <html><body>
    <div id="pt" class="bm cl"><div class="z"><a href="./">論壇</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21">某人</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21&amp;do=blog&amp;view=me">日誌</a></div></div>
    <div class="vw mbm"><div class="h pbm">
    <h1 class="ph">一篇日誌</h1>
    <p class="xg2"><span class="xg1">2026-9-10 21:30</span></p>
    </div>
    <div id="blog_article" class="d cl">整篇日誌的字，比排行榜上的摘要長得多。</div>
    </div>
    <div id="pcd" class="bm cl"><p><a href="home.php?mod=space&amp;uid=21" class="avtm"><img src="https://install-g.example/uc_server/avatar.php?uid=21&amp;size=middle" /></a></p></div>
    </body></html>
    """#

    /// The blog's row as the forum's ranking list wrote it: an excerpt, a day, no picture.
    private static let ranked = Note(
        id: DiscuzBlogRow.id(host: host, blog: 500), source: source, author: "某人",
        handle: "@某人@\(host)", body: "整篇日誌的字……", title: "一篇日誌",
        postedAt: date(2026, 9, 10, 0, 0), categories: [.trends], url: URL(string: address)
    )

    private static var rowID: String { ranked.key.rowID }

    /// A session holding the ranked blog, whose blogs are read through `http`.
    private static func session(_ http: FixtureHTTP, store: ItemStore? = nil) async -> ShellSession {
        let store = store ?? ItemStore()
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

    // MARK: - Opened

    @Test("Opening a ranked blog reads it, and draws its title, author, date and words")
    func openingReadsIt() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page)])
        let session = await Self.session(http)
        let row = try #require(session.held(Self.rowID))
        #expect(ForumThreadRef(row) == nil, "no thread is asked for it")
        #expect(session.blogs.reading(of: row) == .coming)

        await session.reload.opened(row, in: session)
        #expect(await http.requested.map(\.absoluteString) == [Self.address])

        let read = try #require(session.held(Self.rowID))
        #expect(read.title == "一篇日誌")
        #expect(read.author == "某人")
        #expect(read.postedAt == Self.date(2026, 9, 10, 21, 30), "the page's own minute over the list's day")
        #expect(read.body == "整篇日誌的字，比排行榜上的摘要長得多。")
        #expect(read.avatarURL?.absoluteString == "https://install-g.example/uc_server/avatar.php?uid=21&size=middle")
        #expect(session.blogs.reading(of: read) == .read)
        #expect(DummyThreadPane.sentence(forBlog: .refused, host: Self.host).contains(Self.host))
    }

    @Test("A blog read once reads with the network off, and asks for nothing")
    func offlineAfterRead() async throws {
        let store = ItemStore()
        let online = await Self.session(FixtureHTTP([Self.address: .text(Self.page)]), store: store)
        await online.reload.opened(try #require(online.held(Self.rowID)), in: online)

        // Another run on the same store, with nothing answering.
        let dark = FixtureHTTP()
        let offline = await Self.session(dark, store: store)
        let row = try #require(offline.held(Self.rowID))
        #expect(row.body == "整篇日誌的字，比排行榜上的摘要長得多。")
        #expect(offline.blogs.reading(of: row) == .read)
        await offline.reload.opened(row, in: offline)
        #expect(await dark.requested.isEmpty, "kept words are drawn, not asked for again")
        #expect(offline.blogs.reading(of: try #require(offline.held(Self.rowID))) == .read)
    }

    @Test("A read of the store begun before the blog landed does not leave the pane waiting")
    func aStaleReadOfTheStore() async throws {
        let session = await Self.session(FixtureHTTP([Self.address: .text(Self.page)]))
        let stale = session.notes
        let drawn = await session.store.drawn
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        // The keep is a change to what is drawn, so whatever read of the store was on its way is
        // followed by one that has it. A thread's opening post, kept as rows are reached, is not.
        #expect(await session.store.drawn > drawn)

        // The read that was on its way lands after the keep, with the row as it was.
        session.notes = stale
        let drawnStale = try #require(session.held(Self.rowID))
        #expect(drawnStale.opening == nil)
        #expect(session.blogs.reading(of: drawnStale) == .read, "not reading, with nothing on the wire")
        // And the next read of the store draws it with its words.
        await session.reloadFromStore()
        #expect(session.held(Self.rowID)?.body == "整篇日誌的字，比排行榜上的摘要長得多。")

        // #154's keep, as rows are reached, draws nothing new: that is its default.
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest([Self.ranked])
        let before = await store.drawn
        await store.keep([Self.ranked.key: ForumOpening(words: "kept")])
        #expect(await store.drawn == before)
    }

    @Test("A blog read with no words on it keeps the list's excerpt, and says it had none")
    func aSilentBlog() async throws {
        let empty = Self.page.replacingOccurrences(of: "整篇日誌的字，比排行榜上的摘要長得多。", with: "")
        let session = await Self.session(FixtureHTTP([Self.address: .text(empty)]))
        await session.reload.opened(try #require(session.held(Self.rowID)), in: session)
        let row = try #require(session.held(Self.rowID))
        #expect(row.opening?.words == "")
        #expect(row.body == Self.ranked.body)
        #expect(session.blogs.reading(of: row) == .silent)
    }

    // MARK: - Refused

    @Test("A blog the forum refuses says why where its words would be, and still offers its page")
    func refusedSaysWhy() async throws {
        let notice = #"<html><body><div id="messagetext"><p>只有好友才能查看。</p></div></body></html>"#
        for (outcome, absence) in [
            (FixtureHTTP.Outcome.text(notice), ForumPosts.Absence.refused),
            (.text("<html><body><form><input type=\"password\"></form></body></html>"), .unreadable),
            (.fail, .unreachable),
        ] {
            let session = await Self.session(FixtureHTTP([Self.address: outcome]))
            let row = try #require(session.held(Self.rowID))
            await session.reload.opened(row, in: session)
            let after = try #require(session.held(Self.rowID))
            let reading = session.blogs.reading(of: after)
            #expect(reading == .absent(absence), "\(absence)")
            #expect(reading?.offersPage == true)
            #expect(after.page?.absoluteString == Self.address, "its page, as today")
            #expect(after.body == Self.ranked.body, "what the list said stays; nothing is claimed")
        }
    }

    @Test("A blog that did not arrive is asked again, and reads")
    func askedAgain() async throws {
        let session = await Self.session(FixtureHTTP([Self.address: .fail]))
        let row = try #require(session.held(Self.rowID))
        await session.reload.opened(row, in: session)
        #expect(session.blogs.reading(of: row) == .absent(.unreachable))

        let blogs = ForumBlogs(http: FixtureHTTP([Self.address: .text(Self.page)]))
        blogs.work = SourceWork()
        blogs.landing = { key, blog in await session.keep(blog, for: key) }
        #expect(await blogs.again(row))
        #expect(session.held(Self.rowID)?.body == "整篇日誌的字，比排行榜上的摘要長得多。")
    }

    // MARK: - The walk, and the guard

    @Test("Leaving a blog gives back the row it was opened from")
    func leavingReturnsToTheRow() throws {
        var walk = ShellWalk()
        let walked = walk.walk(to: .thread(Self.rowID), from: Self.rowID)
        #expect(walked)
        #expect(walk.openedThread == Self.rowID)
        let back = walk.back()
        let left = try #require(back)
        #expect(left.lamp == Self.rowID)
        #expect(walk.isEmpty)
    }

    @Test("A blog is not read by being reached, nor on the wait while it is open")
    func notReadWhenReached() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page)])
        let session = await Self.session(http)
        let row = try #require(session.held(Self.rowID))
        // In a list: a blog's row has no band that reads, and the wait asks nothing of it.
        #expect(ForumThreadRef(row) == nil)
        session.reload.inFront = row
        #expect(await session.reload.renew(in: session) == nil)
        #expect(await http.requested.isEmpty)
        #expect(session.held(Self.rowID)?.body == Self.ranked.body)
    }

    @Test("What a blog's pane says is said in every language")
    func theSentences() {
        for language in DummyLanguage.allCases {
            for key in [
                "blog.title", "blog.reading", "blog.refused", "blog.unreadable", "blog.unreachable",
                "blog.again", "blog.page", "blog.page.hint",
            ] {
                let text = L10n.t(key, language: language)
                #expect(!text.isEmpty && text != key, "\(key) \(language)")
            }
        }
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )) ?? .distantPast
    }
}
