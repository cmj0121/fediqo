import Foundation
import Testing

@testable import FediqoCore

/// A Discuz! forum read out of its own markup, against what three real ones actually send.
///
/// The fixtures are trimmed captures taken on 2026-09-15, and the three of them are three
/// **different programs' worth of difference** rather than one page copied about:
///
/// | fixture | host | version | how it addresses a thread |
/// | --- | --- | --- | --- |
/// | `discuz-x34-guide` | `install-a.example` | X3.4 | `thread-620795-1-1.html` |
/// | `discuz-x35-guide` | `install-b.example` | X3.5, English | an SEO slug, `…-82-1-1.html` |
/// | `discuz-x50-guide` | `install-c.example` | X5.0 | `forum.php?mod=viewthread&tid=…` |
///
/// That spread is the point. A parser pinned to one skin passes a suite built from one skin, and
/// this one is written against the structure all three share because all three were in front of
/// it while it was written.
///
/// **The index fixtures are four installs, not three**, captured on 2026-09-15 for the same
/// reason and with a fourth added because three turned out to agree about something the fourth
/// does not:
///
/// | fixture | host | version | how a board is written, and addressed |
/// | --- | --- | --- | --- |
/// | `discuz-x50-index` | `install-c.example` | X5.0 | `<dl><dt>` grid, `forum.php?mod=forumdisplay&fid=34` |
/// | `discuz-x35-index` | `install-b.example` | X3.5, English | `<dl><dt>` grid, `37-1/news-feed.html` |
/// | `discuz-x34-index` | `install-a.example` | X3.4 | `<dl><dt>` grid, `forum-37-1.html` |
/// | `discuz-gbk-index` | `install-d.example` | X3.4, GBK | `<td><h2>` wide list, `forum-297-1.html` |
/// | `discuz-empty-index` | `install-e.example` | X3.4 | an ordinary index with no forum list on it |
///
/// Two of them contain the letters `fid=` nowhere at all, one of them writes a **board's** name
/// in an `<h2>`, and two of them are not valid UTF-8. All five are byte-exact: this branch's own
/// lesson is that a fixture written out through a decoder describes a cleaner world than the code
/// meets, and the X3.4 index is precisely that case — a live forum that declares UTF-8 and is not
/// quite UTF-8.
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

    private static func fixture(_ name: String) -> FixtureHTTP.Outcome {
        .body(Fixtures.html(name))
    }

    // MARK: - The front page

    @Test("The guide page becomes notes: a name, a board, who asked, and where to read it")
    func theGuidePageIsATimeline() async throws {
        let (client, http) = Self.client(Self.fixture("discuz-x34-guide"))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 5)
        let first = try #require(notes.first)

        // The title is the post. A Discuz! thread table carries no part of the opening post at
        // all, so a row drawn from `body` alone would be blank on every line.
        #expect(first.title == "套假牌，超速200+，自称德国不限速。难度2星")
        #expect(first.body == "")
        #expect(first.board == "缘聚茶楼")

        // Prefixed and host-qualified: `620795` is a plausible id on any forum, and they share
        // one store with every microblog's status ids.
        #expect(first.id == "discuz:install-a.example:620795")
        #expect(first.source.kind == .discuz)

        // Built from the host and the number, never lifted from the page. This install writes
        // its own links as `thread-620795-1-1.html`, which is relative to a `<base>` the same
        // stranger chose.
        #expect(first.url?.absoluteString == "https://install-a.example/forum.php?mod=viewthread&tid=620795")

        // One request, and it is the guide page rather than any board's.
        let asked = try #require(await http.requested.first)
        #expect(await http.requested.count == 1)
        #expect(asked.absoluteString == "https://install-a.example/forum.php?mod=guide&view=newthread")
    }

    @Test("Every one of the three skins is read, and none of them is read as empty")
    func allThreeSkinsParse() async throws {
        // Enumerated rather than spot-checked: a parser that quietly stopped reading one of the
        // three would otherwise pass a suite that only ever asserted about the first.
        let skins = [
            ("discuz-x34-guide", "install-a.example", 620795, "缘聚茶楼", "猪小呆"),
            ("discuz-x35-guide", "install-b.example", 82, "News Feed", "admin"),
            ("discuz-x50-guide", "install-c.example", 453471, "杂谈区", "beihe"),
        ]
        for (name, host, tid, board, author) in skins {
            let source = Source(host: host, kind: .discuz)
            let (client, _) = Self.client(Self.fixture(name), host: host)
            let notes = try await client.latest(source: source)

            #expect(notes.count == 5, "\(name) should read five rows")
            let first = try #require(notes.first, "\(name) should have a first row")
            #expect(first.id == "discuz:\(host):\(tid)", "\(name) id")
            #expect(first.board == board, "\(name) board")
            #expect(first.author == author, "\(name) author")
            #expect(first.handle == "@\(author)@\(host)", "\(name) handle")
            #expect(
                first.url?.absoluteString
                    == "https://\(host)/forum.php?mod=viewthread&tid=\(tid)",
                "\(name) url"
            )
            // Nothing is half-read: every row on every skin got a title and a person.
            #expect(notes.allSatisfy { $0.title?.isEmpty == false }, "\(name) titles")
            #expect(notes.allSatisfy { !$0.author.isEmpty }, "\(name) authors")
            #expect(notes.allSatisfy { $0.counts.replies != nil }, "\(name) reply counts")
        }
    }

    // MARK: - Who wrote it, and when

    @Test("The person named is whoever started the thread, never the last to reply")
    func theAuthorIsTheThreadStarter() async throws {
        // `install-c.example` thread 158222, checked against the thread itself: post #1 is by
        // 老风 on 2009-12-27, and the row's last cell names `wanggui`, who answered in 2026.
        // Getting this wrong is not a parse error but a plausible wrong answer — a real person's
        // name, spelled correctly, on something they did not write.
        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.latest(source: source)

        let vote = try #require(notes.first { $0.id.hasSuffix(":158222") })
        #expect(vote.author == "老风")
        #expect(vote.handle == "@老风@install-c.example")
        #expect(!notes.contains { $0.author == "wanggui" })
    }

    @Test("A thread is dated when it was posted, not when a stranger last answered")
    func theDateIsTheAuthors() async throws {
        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.latest(source: source)

        // The row's own last-reply cell says 2026-09-15; the thread was posted in 2009.
        let vote = try #require(notes.first { $0.id.hasSuffix(":158222") })
        #expect(vote.postedAt == Self.utc(2009, 12, 27))
    }

    @Test("Both shapes of date Discuz! writes in the same table are read")
    func bothDateShapesAreRead() async throws {
        // A recent row is `<span title="2026-9-15">5&nbsp;小时前</span>` — the words are relative
        // and the *attribute* carries the date. An older row is `<span>2026-9-7</span>` with no
        // attribute at all. A reader of only one of the two loses half the table's dates.
        let (client, _) = Self.client(Self.fixture("discuz-x34-guide"))
        let fromAttribute = try await client.latest(source: Self.source)
        #expect(fromAttribute.allSatisfy { $0.postedAt == Self.utc(2026, 9, 15) })

        let store = Source(host: "install-b.example", kind: .discuz)
        let (english, _) = Self.client(Self.fixture("discuz-x35-guide"), host: "install-b.example")
        let fromText = try await english.latest(source: store)
        // Zero-padded, and from the element's text rather than a title attribute. Checked
        // against the thread itself: post #1 of 82 is dated 2026-06-08.
        #expect(fromText.first?.postedAt == Self.utc(2026, 6, 8))
    }

    @Test("A date is parsed against a fixed calendar, not the reader's")
    func theDateIgnoresTheDevicesCalendar() throws {
        let patterns = try #require(DiscuzPage.Patterns())
        #expect(DiscuzDate.parse("2026-9-15 16:45", using: patterns) == Self.utc(2026, 9, 15, 16, 45))
        #expect(DiscuzDate.parse("2009-12-27", using: patterns) == Self.utc(2009, 12, 27))
        #expect(DiscuzDate.parse("2026-06-08 07:03:09", using: patterns) == Self.utc(2026, 6, 8, 7, 3, 9))
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
        // Checked against the thread itself: `install-b.example` thread 82 has two posts — the
        // opening one and one reply — and its row says 1. Discuz!'s column is already answers,
        // so unlike Discourse's `posts_count` there is nothing to subtract; subtracting anyway
        // would show one answer fewer than the thread has, on every row in the forum.
        let store = Source(host: "install-b.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x35-guide"), host: "install-b.example")
        let notes = try await client.latest(source: store)

        #expect(notes.first?.counts.replies == 1)
        // A thread nobody has answered says nothing rather than one.
        #expect(notes.first { $0.id.hasSuffix(":78") }?.counts.replies == 0)
        #expect(notes.allSatisfy { ($0.counts.replies ?? -1) >= 0 })
    }

    @Test("A row's view count is not smuggled into the answer count")
    func viewsAreNotAnswers() async throws {
        // `td.num` is `<a>replies</a><em>views</em>` and the two are wildly different numbers.
        // A parser that took the last number would report 5,944,472 answers on one row.
        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.latest(source: source)
        #expect(notes.first { $0.id.hasSuffix(":403684") }?.counts.replies == 33954)
    }

    // MARK: - The board

    @Test("A board listing takes its board from the heading, and its pinned threads too")
    func aBoardListingNamesItsBoardOnce() async throws {
        // Two page shapes, one parser. A guide page names a board per row because its rows come
        // from everywhere; a single board's listing names it once in the heading instead.
        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.latest(source: source)

        #expect(notes.count == 6)
        #expect(notes.allSatisfy { $0.board == "休闲娱乐" })
        // Pinned threads are threads. Six of the thirty-three rows on this live board were
        // `stickthread_`, and a parser reading only `normalthread_` would silently drop them.
        #expect(notes.contains { $0.id.hasSuffix(":403684") })
    }

    @Test("A guide page's heading is the name of a view, and never becomes a board")
    func theViewNameIsNotABoard() async throws {
        // The heading on `mod=guide` is 最新发表 — 最新 anything is a view, not a section — and it
        // is taken only when it *links* to a board, which a view's heading does not.
        let html = String(decoding: Fixtures.html("discuz-x34-guide"), as: UTF8.self)
        #expect(DiscuzPage.boardHeading(in: html) == nil)

        let board = String(decoding: Fixtures.html("discuz-x50-board"), as: UTF8.self)
        #expect(DiscuzPage.boardHeading(in: board) == "休闲娱乐")

        // And where both exist the row's own answer wins, on all fifty rows rather than one.
        let (client, _) = Self.client(Self.fixture("discuz-x34-guide"))
        let notes = try await client.latest(source: Self.source)
        #expect(Set(notes.compactMap(\.board)).count > 1)
        #expect(!notes.contains { $0.board == "最新发表" })
    }

    @Test("One board can be read on its own, at the address Discuz! gives it")
    func oneBoardCanBeRead() async throws {
        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, http) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.board(1, source: source)

        #expect(notes.count == 6)
        let asked = try #require(await http.requested.first)
        #expect(asked.absoluteString == "https://install-c.example/forum.php?mod=forumdisplay&fid=1")
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

    @Test("The index becomes the categories and boards a reader would be choosing from")
    func theIndexBecomesCategoriesAndBoards() async throws {
        let (client, http) = Self.indexClient(
            Self.fixture("discuz-x50-index"), host: "install-c.example")
        let categories = try await client.boards()

        #expect(categories.map(\.name) == ["::工具软件::", "::数码生活::"])
        #expect(categories.map(\.gid) == [56, 57])

        let tools = try #require(categories.first)
        let board = try #require(tools.boards.first)
        #expect(board.fid == 33)
        #expect(board.name == "启动盘工具")
        // The board carries the category it sits under, so a flat list of forty can label and
        // group itself without carrying the tree about.
        #expect(board.category == "::工具软件::")
        #expect(board.gid == 56)
        #expect(board.threads == 9501)
        #expect(board.posts == 135_487)
        #expect(board.lastPostAt == Self.utc(2026, 9, 15, 16, 2))

        // One request, and it is the index rather than any board's listing.
        let asked = try #require(await http.requested.first)
        #expect(await http.requested.count == 1)
        #expect(asked.absoluteString == "https://install-c.example/forum.php")
    }

    @Test("Every index skin is read, and the brief's markup is on exactly one of them")
    func allFourIndexSkinsAreRead() async throws {
        // Enumerated rather than spot-checked. `forum.php?mod=forumdisplay&fid=N` inside a `<dt>`
        // is what `install-c.example` writes and what **no other install here writes at all**: two of
        // the four do not contain the letters `fid=` anywhere on their index, and the fourth does
        // not use a `<dt>` for a board. A suite built from one capture would have passed a parser
        // that reads one forum.
        let skins: [(String, String, Int, String, String, Int)] = [
            // fixture, host, first category gid, category name, first board name, its fid
            ("discuz-x50-index", "install-c.example", 56, "::工具软件::", "启动盘工具", 33),
            ("discuz-x35-index", "install-b.example", 1, "Discuz! Support", "News Feed", 37),
            ("discuz-x34-index", "install-a.example", 1, "产品交易区", "数码好物", 37),
            ("discuz-gbk-index", "install-d.example", 296, "官方区", "官方软件区", 297),
        ]
        for (name, host, gid, category, board, fid) in skins {
            let (client, _) = Self.indexClient(Self.fixture(name), host: host)
            let categories = try await client.boards()

            let first = try #require(categories.first, "\(name) should have a category")
            #expect(first.gid == gid, "\(name) gid")
            #expect(first.name == category, "\(name) category")
            let one = try #require(first.boards.first, "\(name) should have a board")
            #expect(one.name == board, "\(name) board")
            #expect(one.fid == fid, "\(name) fid")
            // Nothing is half-read on any skin: every board got a number and a name.
            let all = categories.flatMap(\.boards)
            #expect(!all.isEmpty, "\(name) boards")
            #expect(all.allSatisfy { $0.fid > 0 }, "\(name) fids")
            #expect(all.allSatisfy { !$0.name.isEmpty }, "\(name) names")
            #expect(all.allSatisfy { !$0.category.isEmpty }, "\(name) categories")
            // And a fid is a fid: no board is listed twice under one number.
            #expect(Set(all.map(\.fid)).count == all.count, "\(name) unique fids")
        }
    }

    @Test("Both of the layouts a Discuz! index writes a board in are read")
    func bothLayoutsAreRead() async throws {
        // `allCases` rather than a hand-written pair: a third layout added to the enum and not to
        // the parser would break the build, where a list here would have described a smaller
        // world than the code. Three installs write the grid and the fourth writes the wide list,
        // and the wide one is the reason the grid alone is not the answer.
        #expect(DiscuzBoardLayout.allCases.count == 2)

        let (grid, _) = Self.indexClient(Self.fixture("discuz-x50-index"), host: "install-c.example")
        let (list, _) = Self.indexClient(Self.fixture("discuz-gbk-index"), host: "install-d.example")
        #expect(try await grid.boards().flatMap(\.boards).count == 9)
        #expect(try await list.boards().flatMap(\.boards).count == 2)
    }

    @Test("A board's number is read out of whichever address shape the install writes")
    func aBoardsNumberIsReadFromEveryAddressShape() throws {
        let patterns = try #require(DiscuzIndex.Patterns())
        func fid(_ href: String) -> Int? { DiscuzIndex.fid(inHref: href, patterns: patterns) }

        // The three shapes Discuz!'s own rewrite rules produce, one per measured install.
        #expect(fid("forum.php?mod=forumdisplay&fid=34") == 34)
        #expect(fid("forum.php?mod=forumdisplay&amp;fid=34") == 34)
        #expect(fid("forum-37-1.html") == 37)
        #expect(fid("https://install-d.example/forum-297-1.html") == 297)
        #expect(fid("37-1/news-feed.html") == 37)
        #expect(fid("https://install-b.example/37-1/news-feed.html") == 37)

        // A category is not a board, and neither is a thread or anything else on the page.
        #expect(fid("forum.php?gid=43") == nil)
        #expect(fid("thread-620795-1-1.html") == nil)
        #expect(fid("home.php?mod=space&username=admin") == nil)
        #expect(fid("/calendar") == nil)
        // A number so long it is markup doing something rather than a board.
        #expect(fid("forum.php?fid=" + String(repeating: "9", count: 400)) == nil)
        #expect(fid("forum.php?fid=0") == nil)
    }

    @Test("An abbreviated count is the number the forum meant, or nothing — never five")
    func anAbbreviatedCountIsNotFive() throws {
        // `install-c.example` and `install-d.example` both write `5万` — fifty thousand — once a figure
        // passes ten thousand, and keep the exact number in a `title` on the same element. A
        // parser reading the text would report a board with 58,779 threads as having five, which
        // is not a parse error but a plausible wrong answer a reader would act on.
        let patterns = try #require(DiscuzIndex.Patterns())
        func number(_ slot: String) -> Int? { DiscuzIndex.number(in: slot, patterns: patterns) }

        #expect(number(#"<em>主题: <span title="58779">5万</span></em>"#) == 58779)
        #expect(number(#"<span class="xg1"> / <span title="2006367">200万</span></span>"#) == 2_006_367)
        #expect(number("<em>主题: 5106</em>") == 5106)
        #expect(number("<em>Threads: 5</em>") == 5)
        #expect(number(#"<span class="xg1"> / 6414</span>"#) == 6414)
        #expect(number(#"<span class="xi2">370</span>"#) == 370)
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
        // This project's standing rule about a server that did not say, on a live pair: on
        // `install-b.example`, `Templates` really has been posted in zero times and says so, and
        // has never been posted in at all — so where every other row carries a last post it
        // carries a literal `...`. Zero and nothing are two different facts about that board and
        // only one of them is true of its date.
        let (client, _) = Self.indexClient(
            Self.fixture("discuz-x35-index"), host: "install-b.example")
        let boards = try await client.boards().flatMap(\.boards)

        let templates = try #require(boards.first { $0.fid == 36 })
        #expect(templates.name == "Templates")
        #expect(templates.threads == 0)
        #expect(templates.posts == 0)
        #expect(templates.lastPostAt == nil)

        let feed = try #require(boards.first { $0.fid == 37 })
        #expect(feed.threads == 5)
        #expect(feed.lastPostAt != nil)
    }

    @Test("A thread's name beside a date does not become the date")
    func aThreadTitleIsNotADate() async throws {
        // `install-b.example` writes the last thread's own title in the same cell as the date it
        // was posted, so a cell scanned whole would read whichever number came first — and a
        // forum thread called `Windows 2000-01-01 backup` is not a thing anybody can rule out.
        // The `<cite>` is what the date is actually in, and that is what is read.
        let (client, _) = Self.indexClient(
            Self.fixture("discuz-x35-index"), host: "install-b.example")
        let boards = try await client.boards().flatMap(\.boards)
        #expect(boards.first { $0.fid == 37 }?.lastPostAt == Self.utc(2026, 6, 24, 13, 55))
        // And the other shape, from the other three installs: the date is in a `title` and the
        // words beside it are relative and untranslatable.
        let (installC, _) = Self.indexClient(
            Self.fixture("discuz-x50-index"), host: "install-c.example")
        let tools = try await installC.boards().flatMap(\.boards)
        #expect(tools.first { $0.fid == 33 }?.lastPostAt == Self.utc(2026, 9, 15, 16, 2))
    }

    @Test("A category is matched to its boards by number, never by what is nearest")
    func aCategoryIsMatchedByItsNumber() async throws {
        // `install-d.example` writes each **board's** name in an `<h2>` as well, so "the last heading
        // before this category" — which is right on the other three installs — would have named
        // every category after the first with a board's name. Both halves carry the same number
        // and that is what pairs them.
        let (client, _) = Self.indexClient(Self.fixture("discuz-gbk-index"), host: "install-d.example")
        let categories = try await client.boards()

        #expect(categories.map(\.name) == ["官方区", "资讯专区"])
        #expect(categories.map(\.gid) == [296, 43])
        // The board's own `<h2>` is a board and not a section.
        #expect(categories.flatMap(\.boards).map(\.name) == ["官方软件区", "科技资讯区"])
        #expect(!categories.contains { $0.name == "官方软件区" })
    }

    @Test("A forum with no board this reader may see is not an empty forum")
    func anIndexWithNoBoardIsARefusal() async throws {
        // Captured from `install-e.example`: a complete, unchallenged, entirely ordinary Discuz!
        // index that shows a signed-out reader **no forum list at all**. What it has instead is
        // one hand-written block with `id="category_-99999"` holding a bus timetable, a calendar,
        // an external link and one board — and a parser that scanned the page for anything that
        // looked like a board would have offered the reader a picker made of those.
        let (client, _) = Self.indexClient(
            Self.fixture("discuz-empty-index"), host: "install-e.example")
        await #expect(throws: DiscuzRequestError.noBoards) {
            _ = try await client.boards()
        }

        let html = String(decoding: Fixtures.html("discuz-empty-index"), as: UTF8.self)
        #expect(html.contains("category_-99999"), "the fixture must keep the hand-made block")
        #expect(DiscuzIndex.categories(in: html).isEmpty)
    }

    @Test("The index is judged in the same order a thread list is, and by the same four rules")
    func theIndexIsJudgedTheSameWay() async throws {
        let host = "closed.example"
        for (page, expected) in [
            (Self.fixture("challenge"), DiscuzRequestError.challenged),
            (Self.fixture("discuz-restricted"), .restricted),
            (.text("<html>no</html>", status: 403), .refused(403)),
            (.text("", status: 404), .http(404)),
        ] as [(FixtureHTTP.Outcome, DiscuzRequestError)] {
            let (client, _) = Self.indexClient(page, host: host)
            await #expect(throws: expected) { _ = try await client.boards() }
        }

        // A challenge dressed as a 200 is still a challenge here too, which is the ordering's
        // whole point: read the status first and it becomes "an index with no boards on it".
        let (dressed, _) = Self.indexClient(
            .body(Fixtures.html("challenge"), status: 200), host: host)
        await #expect(throws: DiscuzRequestError.challenged) { _ = try await dressed.boards() }

        // And bytes in no encoding this device knows are refused rather than mangled.
        let (nonsense, _) = Self.indexClient(
            .body(Data([0xC0, 0x80, 0xFF, 0xFE, 0x81, 0x40])), host: host)
        await #expect(throws: DiscuzRequestError.undecodable) { _ = try await nonsense.boards() }
    }

    @Test("An index that declares UTF-8 and is not quite UTF-8 is still read, and a GBK one too")
    func theIndexIsDecodedTheWayEveryDiscuzPageIs() async throws {
        // Byte for byte from the live installs, and both of these would be `nil` to a reader that
        // only tried UTF-8. `install-a.example` declares UTF-8 and carries ten leftover GBK bytes in
        // one script comment; `install-d.example` is GBK outright. The branch's own lesson is that a
        // fixture written out through a decoder describes a cleaner world than the code meets, so
        // neither of these was.
        for name in ["discuz-x34-index", "discuz-gbk-index"] {
            #expect(
                String(data: Fixtures.html(name), encoding: .utf8) == nil,
                "\(name) must not be valid UTF-8"
            )
        }

        let (damaged, _) = Self.indexClient(
            Self.fixture("discuz-x34-index"), host: "install-a.example")
        let boards = try await damaged.boards().flatMap(\.boards)
        #expect(boards.first?.name == "数码好物")
        #expect(boards.allSatisfy { !$0.name.contains("\u{FFFD}") })

        let (gbk, _) = Self.indexClient(Self.fixture("discuz-gbk-index"), host: "install-d.example")
        #expect(try await gbk.boards().first?.name == "官方区")
    }

    // MARK: - One board the reader chose

    @Test("A subscribed board is read at the address Discuz! serves whatever it writes")
    func aSubscribedBoardIsRead() async throws {
        // Three of the four installs never write this address on their own index — they write
        // `forum-37-1.html` or an SEO slug — and all four **answer** it, because rewriting is a
        // rule about the links a Discuz! writes and not about what it serves. Verified live
        // against all three rewriting installs.
        let host = "install-c.example"
        let board = DiscuzBoard(fid: 1, name: "休闲娱乐", category: "::谈天说地::", gid: 55)
        let http = FixtureHTTP([
            "https://\(host)/forum.php?mod=forumdisplay&fid=1": Self.fixture("discuz-x50-board")
        ])
        let client = DiscuzClient(http: http, host: host)
        let notes = try await client.threads(
            board: board, source: Source(host: host, kind: .discuz))

        #expect(notes.count == 6)
        #expect(notes.allSatisfy { $0.board == "休闲娱乐" })
        let asked = try #require(await http.requested.first)
        #expect(asked.absoluteString == "https://install-c.example/forum.php?mod=forumdisplay&fid=1")
    }

    @Test("A pinned thread is a thread, and stays where its own date puts it")
    func aPinnedThreadIsAThread() async throws {
        // Seven of the nineteen rows on this live board are `stickthread_`, and they are kept:
        // they carry a real number, title, author and posting date, they are what a reader sees
        // on the site, and this app has no pinned slot for them to go in — the store orders every
        // note in it by `postedAt`, across every source at once. Dropping them would silently
        // hide a board's own rules and announcements; drawing them at the top would mean
        // inventing an order the store does not have. So they sort by when they were written,
        // like everything else, and `Note.id` keys on the thread number, so a sticky that repeats
        // on every page of a board can never arrive twice.
        let board = String(decoding: Fixtures.html("discuz-x50-board"), as: UTF8.self)
        #expect(board.contains("stickthread_"), "the fixture must carry pinned rows")

        let source = Source(host: "install-c.example", kind: .discuz)
        let (client, _) = Self.client(Self.fixture("discuz-x50-board"), host: "install-c.example")
        let notes = try await client.board(1, source: source)

        // 403684 is one of the pinned ones. Checked against the thread itself rather than against
        // its row: post #1 is by `installC` on 2017-12-15 16:24:03, and the thread's own counter
        // says 33,955 answers against 5,944,972 views. It is dated when it was written, which is
        // eight years before the listing it sits at the top of.
        let pinned = try #require(notes.first { $0.id.hasSuffix(":403684") })
        #expect(pinned.author == "installC")
        #expect(pinned.postedAt == Self.utc(2017, 12, 15))
        #expect(pinned.counts.replies == 33954)
        #expect(pinned.postedAt < Self.utc(2026, 1, 1) ?? .distantFuture)
        #expect(notes.map(\.id).count == Set(notes.map(\.id)).count)
    }

    @Test("A board listing is read on more than one install")
    func aBoardListingIsReadAcrossInstalls() async throws {
        let host = "install-b.example"
        let (client, _) = Self.client(Self.fixture("discuz-x35-board"), host: host)
        let notes = try await client.board(37, source: Source(host: host, kind: .discuz))

        #expect(notes.count == 5)
        #expect(notes.allSatisfy { $0.board == "News Feed" })
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
    }

    @Test("The page's own name for a board wins, and the reader's is only a fallback")
    func thePagesNameForABoardWins() async throws {
        // A name the reader subscribed to may be months old; the `<h1>` is what the forum calls
        // the board today. The subscription's name is used only where the page named nothing.
        let host = "install-c.example"
        let stale = DiscuzBoard(fid: 1, name: "what it used to be called", category: "x", gid: 55)
        let http = FixtureHTTP([
            "https://\(host)/forum.php?mod=forumdisplay&fid=1": Self.fixture("discuz-x50-board")
        ])
        let named = try await DiscuzClient(http: http, host: host)
            .threads(board: stale, source: Source(host: host, kind: .discuz))
        #expect(named.allSatisfy { $0.board == "休闲娱乐" })

        // A listing with no heading at all falls back rather than losing the board entirely.
        let headless = FixtureHTTP([
            "https://\(host)/forum.php?mod=forumdisplay&fid=1": Self.fixture("discuz-x34-guide")
        ])
        let fallback = try await DiscuzClient(http: headless, host: host)
            .threads(board: stale, source: Source(host: host, kind: .discuz))
        // The guide fixture's rows name their own boards, which still wins over either heading.
        #expect(fallback.allSatisfy { $0.board != nil })
    }

    // MARK: - What a Note does not carry

    @Test("A row says a thread has a picture and never says where, so nothing is drawn")
    func anAttachmentFlagIsNotAnAttachment() async throws {
        // The X3.4 capture's first row carries `image_s.gif` with `alt="attach_img"`: a flag,
        // with no address behind it. An `Attachment` built from one would be `isEmpty` and would
        // hold open a slot for a picture that can never arrive.
        let (client, _) = Self.client(Self.fixture("discuz-x34-guide"))
        let notes = try await client.latest(source: Self.source)
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
        for (name, host) in [
            ("discuz-x34-guide", "install-a.example"),
            ("discuz-x35-guide", "install-b.example"),
            ("discuz-x50-guide", "install-c.example"),
        ] {
            let source = Source(host: host, kind: .discuz)
            let (client, _) = Self.client(Self.fixture(name), host: host)
            for note in try await client.latest(source: source) {
                let url = try #require(note.url)
                #expect(url.scheme == "https", "\(name)")
                #expect(url.host() == host, "\(name)")
                #expect(url.path == "/forum.php", "\(name)")
                #expect(Host.isFetchable(url), "\(name)")
            }
        }
    }

    // MARK: - When it is not a forum

    @Test("A challenge page is a refusal, and never an empty forum")
    func aChallengePageIsNotAnEmptyForum() async throws {
        // The failure this exists to prevent: a parser whose answer to "no thread rows" is "an
        // empty list" joins a source that draws nothing, forever, with no error to explain it.
        let (client, _) = Self.client(Self.fixture("challenge"), host: "closed.example")
        await #expect(throws: DiscuzRequestError.challenged) {
            _ = try await client.latest(source: Source(host: "closed.example", kind: .discuz))
        }
    }

    @Test("A challenge dressed as a success is still a challenge")
    func aChallengeIsJudgedBeforeTheStatus() async throws {
        // Cloudflare serves this at 403 and elsewhere at 200. Reading the status first would file
        // the 200 case as "a page with no threads in it", which is the wrong sentence: nothing is
        // wrong with the forum and an account or a browser is what would change the answer.
        for status in [200, 403, 503] {
            let page = Fixtures.html("challenge")
            let (client, _) = Self.client(.body(page, status: status), host: "closed.example")
            await #expect(throws: DiscuzRequestError.challenged) {
                _ = try await client.latest(source: Source(host: "closed.example", kind: .discuz))
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
        // And the live capture carries them, so the markers are not a shape invented here.
        let captured = String(decoding: Fixtures.html("challenge"), as: UTF8.self)
        #expect(DiscuzPage.isChallenge(captured))
        // A real thread list is not one, on any of the three skins.
        for name in ["discuz-x34-guide", "discuz-x35-guide", "discuz-x50-guide", "discuz-x50-board"] {
            #expect(
                !DiscuzPage.isChallenge(String(decoding: Fixtures.html(name), as: UTF8.self)),
                "\(name)"
            )
        }
    }

    @Test("The forum's own notice page is the forum saying no, and is told apart from a challenge")
    func aNoticePageIsARefusal() async throws {
        // `install-e.example` answers a signed-out reader with one of these on every board: a 200,
        // real Discuz! markup, and a sentence saying this reader may not read this. Nothing is in
        // front of the forum, so it is not a challenge — an account is what would change it.
        let (client, _) = Self.client(Self.fixture("discuz-restricted"), host: "install-e.example")
        await #expect(throws: DiscuzRequestError.restricted) {
            _ = try await client.latest(source: Source(host: "install-e.example", kind: .discuz))
        }
    }

    @Test("A real page with no threads in it fails rather than returning nothing")
    func anEmptyThreadListFails() async throws {
        // Also captured from `install-e.example`: its guide page really is a guide page — the
        // heading, the breadcrumb, the generator tag — with an empty table, because a signed-out
        // reader may read no board at all. An empty forum and a forum this could not read are
        // the same markup, and of the two possible mistakes, "we could not read that" is the one
        // a reader can act on and a bug report can be written about.
        let (client, _) = Self.client(Self.fixture("discuz-empty-guide"), host: "install-e.example")
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

    // MARK: - GBK, and the bytes a Discuz! actually sends

    @Test("A GBK forum is read, and is not reported as an unreadable host")
    func aGBKForumIsRead() async throws {
        // Discuz! predates the UTF-8 default and a large share of running installs still serve
        // GBK — `install-d.example` answers `charset=gbk` today. GBK bytes are not valid UTF-8, so a
        // reader that only tried UTF-8 gets `nil` for the entire page: not a mangled string
        // somebody might notice, but nothing at all.
        let gbk = Fixtures.html("discuz-gbk-guide")
        #expect(String(data: gbk, encoding: .utf8) == nil, "the fixture must not be valid UTF-8")

        let (client, _) = Self.client(.body(gbk))
        let notes = try await client.latest(source: Self.source)

        // The same five rows the UTF-8 capture of the same page gives, character for character.
        let (utf8Client, _) = Self.client(Self.fixture("discuz-x34-guide"))
        let expected = try await utf8Client.latest(source: Self.source)
        #expect(notes.map(\.title) == expected.map(\.title))
        #expect(notes.map(\.author) == expected.map(\.author))
        #expect(notes.map(\.board) == expected.map(\.board))
        #expect(notes.first?.title == "套假牌，超速200+，自称德国不限速。难度2星")
    }

    @Test("The header's charset is preferred over the page's own, and both are tried")
    func theDeclaredEncodingIsUsed() throws {
        let gbk = Fixtures.html("discuz-gbk-guide")
        let url = try #require(URL(string: "https://install-a.example/forum.php"))

        // Declared in the header. This is the one the server chose for this response.
        let headed = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=gbk"]
            )
        )
        #expect(DiscuzHTML.text(gbk, headed)?.contains("套假牌") == true)

        // Declared nowhere but the `<meta>`, which is what this fixture's own bytes say.
        let bare = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        #expect(DiscuzHTML.text(gbk, bare)?.contains("套假牌") == true)

        // A declaration that is wrong does not sink the page: UTF-8 and then GB18030 follow it.
        let wrong = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=not-an-encoding"]
            )
        )
        #expect(DiscuzHTML.text(gbk, wrong)?.contains("套假牌") == true)
        #expect(DiscuzHTML.text(Fixtures.html("discuz-x34-guide"), wrong)?.contains("套假牌") == true)
    }

    @Test("A page that says UTF-8 and is not quite UTF-8 is still read")
    func aDamagedUTF8PageIsStillRead() async throws {
        // Captured byte for byte from `install-a.example`: declares UTF-8, is UTF-8 across the whole
        // thread table, and carries leftover GBK bytes in one script comment. Strict UTF-8 gives
        // nil for the whole page, **and GB18030 fails on it too** — because the page really is
        // UTF-8. Until the decode believed the declaration and took the loss on the broken bytes,
        // this live forum detected correctly and then joined to nothing.
        //
        // Found by running the code against real forums. No fixture could have caught it: every
        // other capture here was written out through a decoder, which silently repaired it.
        let damaged = Fixtures.html("discuz-damaged-guide")
        #expect(String(data: damaged, encoding: .utf8) == nil, "the fixture must not be valid UTF-8")

        let (client, _) = Self.client(.body(damaged))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 3)
        // The loss is confined to the bytes that were actually broken. Every title, board and
        // name in the table is clean UTF-8 and arrives exactly.
        #expect(notes.first?.title == "套假牌，超速200+，自称德国不限速。难度2星")
        #expect(notes.first?.board == "缘聚茶楼")
        #expect(notes.first?.author == "猪小呆")
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
        let broken = Data([0xFF, 0xFE, 0xFF, 0xC0, 0x80, 0xFF])
        #expect(DiscuzHTML.text(broken, gbkDeclared) == nil)
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

    // MARK: - Detection

    @Test("The front page names the software, before any script runs")
    func theFrontPageNamesTheSoftware() {
        let html = String(decoding: Fixtures.html("discuz"), as: UTF8.self)
        #expect(HTMLKind.classify(html) == .named(.discuz))
        // Every captured thread list says so too, so a detection is not resting on one page.
        for name in ["discuz-x34-guide", "discuz-x35-guide", "discuz-x50-guide", "discuz-x50-board"] {
            #expect(
                HTMLKind.classify(String(decoding: Fixtures.html(name), as: UTF8.self))
                    == .named(.discuz),
                "\(name)"
            )
        }
    }

    @Test("Discuz! is written with its exclamation mark, because that is its name")
    func theNameCarriesItsPunctuation() {
        #expect(ProtocolKind.discuz.displayName == "Discuz!")
        #expect(ProtocolKind.discuz.rawValue == "discuz")
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
