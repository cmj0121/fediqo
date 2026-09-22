import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// A forum's Trends, as rows: **the points guard**, and a blog opened as a page.
///
/// Some boards on the reader's forum charge points just to open a thread, and D30 reads a row's
/// opening post the moment it is reached. A thread the forum's ranking lists named from a board
/// the reader never chose must therefore not be read by being scrolled past — only by being
/// opened — while a thread from a board they do read behaves exactly as it always has.
@MainActor
@Suite("A forum's Trends, and what reaching them reads")
struct RankedGuardTests {
    private static let host = "install-g.example"
    private static let source = Source(host: host, kind: .discuz)
    /// A board the reader reads.
    private static let read = BoardSubscription(fid: 37, name: "Board A")

    private static func threadAddress(_ tid: Int) -> String {
        "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
    }

    private static func opening(_ tid: Int) -> FixtureHTTP.Outcome {
        .text(#"""
        <div class="plc cl" id="pid\#(tid)1">
        <ul class="authi"><li class="mtit">1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">someone</a></li></ul>
        <div class="message">The opening words.</div>
        </div>
        """#)
    }

    /// A thread row as the store holds it: through `categories`, and nothing else of note.
    private static func thread(_ tid: Int, _ categories: Set<FediqoCore.Category>) -> Note {
        Note(
            id: "discuz:\(host):\(tid)", source: source, author: "someone",
            handle: "@someone@\(host)", body: "", title: "A thread",
            postedAt: Date(timeIntervalSince1970: 0), categories: categories,
            url: URL(string: "https://\(host)/forum.php?mod=viewthread&tid=\(tid)")
        )
    }

    private static func ref(_ note: Note) throws -> ForumThreadRef {
        try #require(ForumThreadRef(DummyItem(note)))
    }

    /// `ForumPosts` as the session keeps it: reading board 37 on this forum.
    private static func posts(_ http: FixtureHTTP = FixtureHTTP()) -> ForumPosts {
        let posts = ForumPosts(http: http)
        posts.boardsRead = [host: [read.fid]]
        return posts
    }

    // MARK: - What a row carries

    @Test("A row knows whether it was ranked and which boards it is in")
    func theRefCarriesTheFacts() throws {
        let ranked = try Self.ref(Self.thread(900, [.trends, .board(id: "99")]))
        #expect(ranked.ranked)
        #expect(ranked.boards == [99])
        let plain = try Self.ref(Self.thread(901, [.board(id: "37")]))
        #expect(!plain.ranked)
        #expect(plain.boards == [37])
        // Carried, and not what the thread is: one thread is one thread whatever a row says.
        #expect(ranked == ForumThreadRef(host: Self.host, tid: 900))
    }

    // MARK: - The guard

    @Test("A ranked thread from a board the reader does not read is not read when reached")
    func unsubscribedRankedIsNotReadWhenReached() async throws {
        let http = FixtureHTTP([Self.threadAddress(900): Self.opening(900)])
        let posts = Self.posts(http)
        let ref = try Self.ref(Self.thread(900, [.trends, .board(id: "99")]))

        #expect(!posts.readsWhenReached(ref))
        #expect(!posts.fetches(ref, opened: false), "a row in a list does not read it")
        #expect(posts.reading(ref, opened: false) == .unread, "and says why, rather than waiting")
        #expect(posts.asks(ref), "the premise: nothing is held, so D30 alone would have asked")
        #expect(await http.requested.isEmpty)
    }

    @Test("Opening that thread reads it")
    func openingReadsIt() async throws {
        let http = FixtureHTTP([Self.threadAddress(900): Self.opening(900)])
        let posts = Self.posts(http)
        let ref = try Self.ref(Self.thread(900, [.trends, .board(id: "99")]))

        // The opened thread — the pane — is the reader's choice.
        #expect(posts.fetches(ref, opened: true))
        #expect(posts.reading(ref, opened: true) == .coming)
        await posts.fetch(ref)
        #expect(await http.requested.map(\.absoluteString) == [Self.threadAddress(900)])
        #expect(posts.reading(ref, opened: true) == .words("The opening words."))
        // Once read, the row draws what was read, and asks nothing more.
        #expect(posts.reading(ref, opened: false) == .words("The opening words."))
        #expect(!posts.fetches(ref, opened: false))
    }

    @Test("A ranked thread from a board the reader reads is read when reached, as its board's rows are")
    func subscribedRankedIsReadWhenReached() throws {
        let posts = Self.posts()
        let ranked = try Self.ref(Self.thread(902, [.trends, .board(id: "37")]))
        #expect(posts.readsWhenReached(ranked))
        #expect(posts.fetches(ranked, opened: false))
        #expect(posts.reading(ranked, opened: false) == .coming)
    }

    @Test("A thread that was not ranked is read when reached, as it always was")
    func unrankedIsUntouched() throws {
        let posts = Self.posts()
        for categories: Set<FediqoCore.Category> in [[.board(id: "37")], [.board(id: "99")], []] {
            let ref = try Self.ref(Self.thread(903, categories))
            #expect(posts.readsWhenReached(ref), "\(categories)")
            #expect(posts.fetches(ref, opened: false), "\(categories)")
        }
    }

    @Test("Strict where it cannot tell: no board, or a forum read through its front page")
    func strictWhereItCannotTell() throws {
        let posts = Self.posts()
        let boardless = try Self.ref(Self.thread(904, [.trends]))
        #expect(!posts.fetches(boardless, opened: false))

        let frontPage = ForumPosts(http: FixtureHTTP())
        frontPage.boardsRead = [Self.host: []]
        let ranked = try Self.ref(Self.thread(905, [.trends, .board(id: "37")]))
        #expect(!frontPage.fetches(ranked, opened: false))
        #expect(frontPage.fetches(ranked, opened: true))
    }

    @Test("A board read again does not make an unread ranked thread read itself")
    func revisitKeepsTheGuard() throws {
        let posts = Self.posts()
        let kept = ForumOpening(words: "kept")
        var item = DummyItem(Self.thread(906, [.trends, .board(id: "99")]))
        item.opening = kept
        let ref = try #require(ForumThreadRef(item))
        posts.revisit(host: Self.host)
        #expect(posts.asks(ref), "the premise: a revisit would have D30 ask again")
        #expect(!posts.fetches(ref, opened: false))
        #expect(posts.reading(ref, opened: false) == .words("kept"), "what was read stays drawn")
    }

    @Test("The session keeps the boards read up to date, so subscribing to a board lifts the guard")
    func theSessionKeepsTheBoards() async throws {
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .discuz, boards: [Self.read]))
        let session = ShellSession(http: FixtureHTTP(), store: store, posts: ForumPosts(http: FixtureHTTP()))
        await session.reloadFromStore()
        #expect(session.posts.boardsRead == [Self.host: [37]])

        let ref = try Self.ref(Self.thread(900, [.trends, .board(id: "99")]))
        #expect(!session.posts.fetches(ref, opened: false))

        await session.store.subscribe(host: Self.host, to: [Self.read, BoardSubscription(fid: 99, name: "Board B")])
        await session.reloadFromStore()
        #expect(session.posts.boardsRead == [Self.host: [37, 99]])
        #expect(session.posts.fetches(ref, opened: false))

        await session.remove(host: Self.host)
        #expect(session.posts.boardsRead.isEmpty)
    }

    @Test("A row that waits for its opening says so in every language, and aloud")
    func theUnreadSentence() {
        #expect(ForumPostBand.spoken(.unread) == L10n.t("item.forum.unread"))
        for language in DummyLanguage.allCases {
            let text = L10n.t("item.forum.unread", language: language)
            #expect(!text.isEmpty && text != "item.forum.unread", "\(language)")
        }
    }

    // MARK: - A blog

    @Test("A ranked blog is no thread to fetch, and opening it reads its page")
    func aBlogOpensItsPage() {
        let blog = Note(
            id: DiscuzBlogRow.id(host: Self.host, blog: 500), source: Self.source, author: "writer",
            handle: "@writer@\(Self.host)", body: "The excerpt ...", title: "A blog",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.trends],
            url: URL(string: "https://\(Self.host)/home.php?mod=space&uid=21&do=blog&id=500")
        )
        let item = DummyItem(blog)
        #expect(ForumThreadRef(item) == nil, "no opening post is ever read for it")
        #expect(item.page?.absoluteString == "https://\(Self.host)/home.php?mod=space&uid=21&do=blog&id=500")
        #expect(item.body == "The excerpt ...")
        #expect(item.kind == .thread)

        #expect(DummyItem(Self.thread(900, [.trends, .board(id: "99")])).page == nil, "a thread opens its conversation")
    }
}
