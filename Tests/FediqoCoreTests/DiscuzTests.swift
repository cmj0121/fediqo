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
