import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// Unit F4: the reader's own three steps — *sign in, list the boards, select one or more to
/// subscribe* — as the shell actually drives them.
///
/// What is pinned here is the **flow**, because that is what this unit is: `begin` stopping with
/// nothing added, the sheet the reader answers it in, every way out of it leaving nothing behind,
/// and the boards they kept turning into tabs. `DiscuzBoardJoin` has its own suite for what the
/// two Core calls do; this one is about who calls them and what the reader is left holding.
@MainActor
@Suite("Choosing boards")
struct BoardChoiceTests {
    private static let host = "install-c.example"

    init() {
        L10n.language = .english
    }

    /// A Discuz! whose index and boards each answer at their own address.
    ///
    /// Routed by whole address and not by path: a Discuz!'s index and every one of its boards are
    /// the same `/forum.php`, and the query is what tells them apart — the rule `ForumJoinTests`
    /// states, at the other end of the same wire.
    ///
    /// **What is shared here is the wiring, not the page.** Every test below writes the markup
    /// it depends on into its own call: the index it is offered, and the answer each board it
    /// picks gives back. This only says which address each of those answers at, which is the one
    /// thing no test is about and every test would otherwise repeat wrongly.
    private static func forumHTTP(
        index: FixtureHTTP.Outcome,
        boards: [Int: FixtureHTTP.Outcome] = [:]
    ) -> FixtureHTTP {
        var routes: [String: FixtureHTTP.Outcome] = [
            // Enough for the detector to name it a Discuz!.
            "/": .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
            """#),
            "https://\(host)/forum.php": index,
        ]
        for (fid, outcome) in boards {
            routes["https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)"] = outcome
        }
        return FixtureHTTP(routes)
    }

    private static func session(_ http: FixtureHTTP) -> ShellSession {
        ShellSession(http: http, store: ItemStore())
    }

    // MARK: - The pause

    @Test("Adding a forum stops at the picker, and adds nothing")
    func addingAForumPauses() async {
        // A grid index with two boards under one category — enough that "the picker was offered
        // boards" is a claim with something behind it.
        let session = Self.session(Self.forumHTTP(index: .text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
        <dd><em>主题: 4207</em>, <em>帖数: 60318</em></dd></dl>
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt>
        <dd><em>主题: 1854</em>, <em>帖数: 16821</em></dd></dl>
        </div></body></html>
        """#)))
        session.hostname = Self.host
        await session.add()

        // D28: the reader has to choose before there is a timeline to fetch at all.
        #expect(session.choosing?.offer.host == Self.host)
        #expect(session.choosing?.offer.kind == .discuz)
        #expect(session.choosing?.offer.boards.isEmpty == false)

        // **Nothing added.** Not the source, not a query, not a note — a forum that stopped to
        // ask is a forum the reader has not joined yet.
        #expect(session.sources.isEmpty)
        #expect(session.queries.isEmpty)
        #expect(session.notes.isEmpty)
        #expect(session.timelineID == nil)
        #expect(!session.availability.allows(.timeline))
        #expect(session.refuse == nil)
        #expect(!session.isAdded(Self.host))
    }

    @Test("A microblog does not stop to ask, and still gets All and Trends")
    func aMicroblogDoesNotPause() async {
        let session = Self.session(FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/1",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Hello</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        session.hostname = "first.example"
        await session.add()

        #expect(session.choosing == nil)
        #expect(session.queries.map(\.id) == ["all", "trends"])
        #expect(session.availability.allows(.timeline))
    }

    // MARK: - Cancelling, at each step

    @Test("Closing the picker joins nothing, and the same host can be typed again")
    func cancellingThePickerLeavesNothing() async {
        // Nothing is ever picked here, so no board is ever read: an index is all this needs.
        let http = Self.forumHTTP(index: .text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
        <dd><em>主题: 4207</em></dd></dl>
        </div></body></html>
        """#))
        let session = Self.session(http)
        session.hostname = Self.host
        await session.add()
        #expect(session.choosing != nil)

        session.cancelChoosing()

        // Nothing was added, so there is nothing to take back — and nothing to apologise for.
        #expect(session.choosing == nil)
        #expect(session.sources.isEmpty)
        #expect(session.notes.isEmpty)
        #expect(session.queries.isEmpty)
        #expect(session.refuse == nil)
        #expect(session.unread.isEmpty)

        // **And the picker comes back.** A cancelled join left no source behind, so the duplicate
        // guard does not stand in the way, and what they typed is still in the field.
        #expect(session.hostname == Self.host)
        #expect(!session.isAdded(Self.host))
        await session.add()
        #expect(session.choosing?.offer.host == Self.host)
    }

    @Test("Subscribing to nothing is not a failure, and adds nothing")
    func anEmptyPickIsNotAFailure() async {
        // No board is picked, so no board page is asked for — and the assertion that nothing was
        // added would be worthless if there had been nothing to add.
        let session = Self.session(Self.forumHTTP(index: .text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
        <dd><em>主题: 4207</em></dd></dl>
        </div></body></html>
        """#)))
        session.hostname = Self.host
        await session.add()

        await session.subscribe([])

        // A reader who opened the picker and closed it has not failed at anything: no source, no
        // error, and no sentence telling them off for changing their mind.
        #expect(session.choosing == nil)
        #expect(session.sources.isEmpty)
        #expect(session.refuse == nil)
        #expect(session.unread.isEmpty)
        #expect(session.unreadAll == 0)
        #expect(!session.checking)
    }

    @Test("A pick with no offer in hand does nothing at all")
    func aPickWithoutAnOfferDoesNothing() async {
        // Nothing is ever fetched: `add` is never called, which is the premise.
        let session = Self.session(Self.forumHTTP(index: .text("")))
        await session.subscribe([])
        #expect(session.sources.isEmpty)
        #expect(session.refuse == nil)
    }

    // MARK: - The pick

    @Test("The boards the reader kept become the source, its notes and its tabs")
    func subscribingAddsTheBoardsAsQueries() async {
        // Two boards, and each one answers with a thread of its own — two boards that returned
        // the same thread would be one note in the store and would not show two tabs filling.
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt>
            <dd><em>主题: 1854</em></dd></dl>
            </div></body></html>
            """#),
            boards: [
                33: .text(#"""
                <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
                <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
                <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
                <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
                <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
                </tr></tbody></table></body></html>
                """#),
                41: .text(#"""
                <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
                <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></h1>
                <table id="threadlisttableid"><tbody id="normalthread_40230"><tr>
                <th class="common"><a href="forum.php?mod=viewthread&tid=40230" class="s xst">磁盘直通怎么开</a></th>
                <td class="by"><cite><a href="home.php?mod=space&uid=9">greenpine</a></cite><em>2026-9-14 08:03</em></td>
                </tr></tbody></table></body></html>
                """#),
            ]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused for the reader to choose")
            return
        }

        await session.subscribe(offer.boards.filter { [33, 41].contains($0.fid) })

        // D26: one source per host, carrying the set of boards. Never one source per board.
        #expect(session.sources.map(\.host) == [Self.host])
        #expect(session.sources.first?.boards.map(\.fid) == [33, 41])
        #expect(!session.notes.isEmpty)

        // D27: a board is a query in the rail the way `all` is for a microblog.
        let ids = session.queries.map(\.id)
        #expect(ids.first == "all")
        #expect(ids.contains("board:\(Self.host):33"))
        #expect(ids.contains("board:\(Self.host):41"))
        #expect(session.availability.allows(.timeline))
        #expect(session.choosing == nil)
        #expect(session.refuse == nil)
    }

    /// **The open item this branch recorded against itself, closed.** A join used to set the tab
    /// list to `all` and `trends` whatever it had joined, and a forum has no trending read — so
    /// that tab was permanently empty and there was no way for a reader to tell it from a quiet
    /// hour.
    @Test("A forum is offered no Trends tab")
    func aForumIsOfferedNoTrends() async {
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            </div></body></html>
            """#),
            boards: [33: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
            <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            </tr></tbody></table></body></html>
            """#)]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })

        #expect(!session.queries.contains { $0.id == "trends" })
        // And the place is still open, which is the half that would have broken quietly: the
        // gate used to want both ids.
        #expect(session.availability.allows(.timeline))
        #expect(session.timelineID == "all")
    }

    @Test("Every protocol is asked whether it has trends, and the two forums say no")
    func trendsIsDecidedPerProtocol() {
        for kind in ProtocolKind.allCases {
            switch kind {
            case .discourse, .discuz, .unknown:
                #expect(!ShellSession.hasTrends(kind), "\(kind) should be offered no trends")
            case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
                .gotosocial:
                #expect(ShellSession.hasTrends(kind), "\(kind) should be offered trends")
            }
        }
    }

    @Test("A board tab draws that board's threads and no other source's")
    func aBoardQueryDrawsItsOwnThreads() {
        let forum = Source(host: "forum.example", kind: .discuz)
        let other = Source(host: "other.example", kind: .discuz)
        let notes = [
            Self.note("a", forum, board: "启动盘工具"),
            Self.note("b", forum, board: "闲话区"),
            // Same board name, different forum. The host is half the identity for exactly this.
            Self.note("c", other, board: "启动盘工具"),
            Self.note("d", forum, board: nil),
        ]
        let query = DummyTimeline(
            board: BoardQuery(host: "forum.example", fid: 39, name: "启动盘工具")
        )
        #expect(query.items(from: notes).map(\.id) == ["a"])
        #expect(query.id == "board:forum.example:39")
        #expect(query.name == "启动盘工具")
        #expect(query.emptyKey == "timeline.empty.board")
        // All still means all of it, boards included.
        #expect(DummyTimeline(id: "all").items(from: notes).count == 4)
    }

    /// A board query rebuilt from its id alone knows it is a board and not **which** board, so
    /// the shell resolves one out of the list that holds the names. A view that reconstructed it
    /// would draw a tab matching no note — silently, and only on the tabs this unit added.
    @Test("A board query is resolved from the session, not rebuilt from its id")
    func aBoardQueryIsResolvedNotRebuilt() async {
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            </div></body></html>
            """#),
            boards: [33: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
            <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            </tr></tbody></table></body></html>
            """#)]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })

        let id = "board:\(Self.host):33"
        session.timelineID = id
        let resolved = session.timeline(for: id)
        #expect(resolved.board?.fid == 33)
        #expect(!resolved.items(from: session.notes).isEmpty)
        // The same id, rebuilt rather than resolved, is the failure this guards against.
        #expect(DummyTimeline(id: id).board == nil)
        #expect(DummyTimeline(id: id).items(from: session.notes).isEmpty)
    }

    // MARK: - Saying what did not work

    @Test("A board that could not be read is left out of the rail and named")
    func anUnreadBoardIsNamed() async {
        // `install-a.example` board 37 is the live one this is modelled on: 114,662 threads
        // served as picture cards with no date on any of them, and no query parameter turns it
        // back into a list. What reaches this app is what board 41 answers with below — a real
        // page, a real board, and an **empty** thread table.
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt>
            <dd><em>主题: 1854</em></dd></dl>
            </div></body></html>
            """#),
            boards: [
                33: .text(#"""
                <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
                <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
                <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
                <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
                <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
                </tr></tbody></table></body></html>
                """#),
                41: .text(#"""
                <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
                <h1 class="xs2">最新回复</h1>
                <table cellspacing="0" cellpadding="0"></table>
                </body></html>
                """#),
            ]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { [33, 41].contains($0.fid) })

        // The one that read is subscribed; the one that did not is **not** — a board in the rail
        // whose timeline can never load is the same failure as a source that can never load.
        #expect(session.sources.first?.boards.map(\.fid) == [33])
        #expect(!session.queries.contains { $0.id == "board:\(Self.host):41" })

        // And the reader is owed a sentence, because they picked it off a list this app drew.
        #expect(session.unread.map(\.board.fid) == [41])
        #expect(session.unreadAll == 0)
        let said = ShellSession.unreadMessage(session.unread[0])
        #expect(said.contains("no thread list"))
        #expect(said.contains(session.unread[0].board.name))
        // Not filed as a failure of the whole join: the rest of the pick worked.
        #expect(session.refuse == nil)
    }

    @Test("Where every picked board fails, nothing is added and the count is still said")
    func everyBoardFailing() async {
        let unreadable = FixtureHTTP.Outcome.text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h1 class="xs2">最新回复</h1>
        <table cellspacing="0" cellpadding="0"></table>
        </body></html>
        """#)
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt>
            <dd><em>主题: 1854</em></dd></dl>
            </div></body></html>
            """#),
            boards: [33: unreadable, 41: unreadable]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { [33, 41].contains($0.fid) })

        #expect(session.sources.isEmpty)
        #expect(session.queries.isEmpty)
        #expect(session.refuse != nil)
        // Core threw the first board's reason and kept no list, which is the right contract —
        // nothing was added. What the screen can still say is how much it was about.
        #expect(session.unreadAll == 2)
        #expect(session.unread.isEmpty)
    }

    @Test("Every reason a board can go unread has a sentence naming the board")
    func everyUnreadReasonHasASentence() {
        let board = DiscuzBoard(fid: 7, name: "启动盘工具", category: "工具软件", gid: 13)
        let reasons: [JoinError] = [
            .refused(403), .publicTimelineFailed, .unreachable, .unreachable,
            .invalidHost, .unsupportedKind(.discuz),
        ]
        for reason in reasons {
            let said = ShellSession.unreadMessage(UnreadBoard(board: board, error: reason))
            #expect(said.contains(board.name), "\(reason) should name the board")
            // A key echoed back is a missing string, which is what this catches.
            #expect(!said.hasPrefix("board.unread."), "\(reason) has no sentence")
        }
    }

    // MARK: - Refused, and the way back

    @Test("A forum that refuses offers a sign-in, and keeps what the reader typed")
    func aRefusedForumOffersSignIn() async {
        // Discuz!'s own notice page, and the one thing that identifies it: `id="messagetext"`.
        // It arrives at status 200 with real Discuz! markup, which is why nothing above the
        // parser catches it.
        let session = Self.session(FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
            """#),
            "https://\(Self.host)/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div id="ct" class="ct1 wp cl"><div class="mn"><div class="nfl">
            <div id="messagetext" class="alert_info">
            <p>抱歉，您的权限不足，无法访问本版块。</p>
            </div></div></div></div>
            </body></html>
            """#),
        ]))
        session.hostname = Self.host
        await session.add()

        // The forum's own notice page is a refusal — the host is fine, the spelling is fine, and
        // somebody said no on purpose. That is the one failure a sign-in can change.
        #expect(session.offerSignIn == Self.host)
        #expect(session.refuse != nil)
        #expect(session.choosing == nil)
        #expect(session.sources.isEmpty)
        // What they typed is still there, so the way back is one press and not a retype.
        #expect(session.hostname == Self.host)
    }

    @Test("A forum with no board this reader may see is refused, not mis-spelled")
    func aForumWithNoBoardsIsRefused() async {
        // A complete, ordinary Discuz! index with **no forum list on it** — what a signed-out
        // reader gets on `install-e.example`. What it has instead is a hand-written block whose
        // id is `category_-99999`, holding campus links rather than boards: a section with no
        // `gid` heading and nothing under it a reader could pick.
        let session = Self.session(FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
            """#),
            "https://\(Self.host)/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div class="bm bmw cl"><div class="bm_h cl"><h2><a href="#">校内服务</a></h2></div>
            <div id="category_-99999" class="bm_c">
            <table class="fl_tb"><tr class="fl_row">
            <td class="fl_g"><a href="https://\#(Self.host)/forum.php?mod=viewthread&amp;tid=1430861">班车时刻</a></td>
            <td class="fl_g"><a href="/calendar">学年日历</a></td>
            </tr></table>
            </div></div></body></html>
            """#),
        ]))
        session.hostname = Self.host
        await session.add()

        // An index with no board is an account question, not an address question — sending the
        // reader to check their spelling would send them after a fault of theirs that is not one.
        #expect(session.offerSignIn == Self.host)
        #expect(session.choosing == nil)
    }

    /// **Reaching a sign-in goes back to `begin`, and says so as a value.** The reader typed a
    /// host, was turned away, and went and signing in; the errand was always "add this forum", so
    /// the answer is a yes the caller acts on rather than an empty field.
    @Test("A sign-in that was reached asks for the join again; one that was not, does not")
    func signingInResumesTheJoin() {
        // Nothing is fetched: this is entirely about what `signInFinished` answers and leaves.
        let session = Self.session(Self.forumHTTP(index: .text("")))
        session.offerSignIn = Self.host
        session.hostname = "something else entirely"

        #expect(!session.signInFinished(reached: false, host: Self.host))
        // Not reached: the offer stays, so they can press it again without retyping.
        #expect(session.offerSignIn == Self.host)

        #expect(session.signInFinished(reached: true, host: Self.host))
        #expect(session.offerSignIn == nil)
        #expect(session.signingIn == nil)
        // And the errand belongs to the host behind the sheet, whatever the field was edited to.
        #expect(session.hostname == Self.host)
    }

    @Test("A sign-in reached, and the join runs again to the picker")
    func theJoinRunsAgainAfterASignIn() async {
        let session = Self.session(Self.forumHTTP(index: .text(#"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
        <dd><em>主题: 4207</em></dd></dl>
        </div></body></html>
        """#)))
        session.hostname = Self.host
        _ = session.signInFinished(reached: true, host: Self.host)
        await session.add()
        #expect(session.choosing?.offer.host == Self.host)
    }

    // MARK: - Clear

    /// **Clear leaves the boards alone**, and that is a decision rather than an oversight.
    ///
    /// Decision 14 is "Clear empties what this device holds of a server; it does not undo a
    /// join". The boards are not something the server left here — they are the reader's own
    /// choice, made on the screen this unit built, and the same kind of thing as the source being
    /// in the list at all. What the server contributed is the threads, and a thread is a note.
    /// D25 took the password past that rule because a secret left behind for an unread server is
    /// a hazard in itself; a list of board names is neither a secret nor a hazard, so the
    /// argument that carried D25 has nothing to carry here.
    @Test("Clearing a forum keeps the boards the reader chose")
    func clearKeepsTheSubscriptions() async {
        let session = Self.session(Self.forumHTTP(
            index: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            </div></body></html>
            """#),
            boards: [33: .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
            <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            </tr></tbody></table></body></html>
            """#)]
        ))
        session.hostname = Self.host
        await session.add()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })
        #expect(session.sources.first?.boards.map(\.fid) == [33])

        await session.clear(host: Self.host)

        // The server stays added, its boards stay chosen, and its tab stays in the rail.
        #expect(session.sources.first?.boards.map(\.fid) == [33])
        #expect(session.queries.contains { $0.id == "board:\(Self.host):33" })
        #expect(session.cleared == 1)
    }

    // MARK: - The picker's own rules

    @Test("A board the forum stated no figures for does not draw a zero")
    func nothingIsNotZero() {
        // `install-b.example` has both in one index: a board with a true, stated 0 threads, and
        // a board where the template writes `...` and there is no figure at all.
        let stated = DiscuzBoard(
            fid: 36, name: "Templates", category: "Discuz! Support", gid: 1, threads: 0, posts: 0
        )
        let unstated = DiscuzBoard(fid: 99, name: "Quiet", category: "Discuz! Support", gid: 1)
        #expect(stated.threads == 0)
        #expect(unstated.threads == nil)
        // The sentence a row with nothing stated draws instead of a fabricated zero.
        let none = L10n.t("board.choose.unstated", language: .english)
        #expect(none == "This forum stated no figures for this board")
        #expect(!none.contains("0"))
    }

    /// **Every key in every one of the three bundles, enumerated rather than listed.**
    ///
    /// This branch's first earned convention is that a test must not be free to describe a
    /// smaller world than the code, and a hand-written list of the keys this screen happens to
    /// use today is exactly that list. So the development bundle is read and *all* of it is
    /// required of the other two.
    ///
    /// **Read off disk rather than through `L10n`, because `L10n` cannot see the failure.**
    /// `bundle(for: .taiwanese)` tries `zh-TW` first and falls back to `zh-Hant`, so a key put in
    /// one and forgotten in the other still resolves and the test passes — while a reader whose
    /// system picks the bundle that is missing it sees the raw key on screen. The ship has three
    /// `.lproj` in it and this is the only way to ask about all three.
    @Test("Every shipped string exists in all three .lproj, not just the one that answers first")
    func everyStringIsInEveryBundle() throws {
        let english = try Self.keys(in: "en")
        #expect(english.contains("board.choose.title"), "the F4 strings are not in the bundle")
        for lproj in ["zh-Hant", "zh-TW"] {
            let translated = try Self.keys(in: lproj)
            let missing = english.subtracting(translated).sorted()
            #expect(missing.isEmpty, "\(lproj) is missing: \(missing.joined(separator: ", "))")
            let extra = translated.subtracting(english).sorted()
            #expect(extra.isEmpty, "\(lproj) has strings en does not: \(extra.joined(separator: ", "))")
        }
    }

    /// The keys one shipped `.lproj` declares, read from the file the app is built from.
    private static func keys(in lproj: String) throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources/\(lproj).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            let body = trimmed.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { continue }
            found.insert(String(body[body.startIndex..<end]))
        }
        return found
    }

    @Test("The picker's own sentences say something in 中文 as well as in English")
    func thePickerSpeaksChinese() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["board.choose.title", "board.choose.subscribe", "board.unread.some"] {
                let value = L10n.t(key, language: language)
                // `L10n.t` echoes the key back when a bundle has no entry, which is the one
                // failure that looks like a working screen in English and a broken one in 中文.
                #expect(value != key, "\(key) is missing in \(language)")
                #expect(!value.isEmpty)
            }
        }
    }

    private static func note(_ id: String, _ source: Source, board: String?) -> Note {
        Note(
            id: id,
            source: source,
            author: "somebody",
            handle: "@somebody",
            body: "words",
            title: "a thread",
            board: board,
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origins: [.publicTimeline]
        )
    }

    // The defect this closes, and it is the one the fixtures themselves demonstrated: the board
    // page's heading and the index's name are two hand-written strings, and matching a
    // subscription to its threads by name turned any difference between them — or an
    // administrator renaming a board between two reads — into a tab that silently drew nothing.
    @Test("A board's threads are found by its number, even when the two names disagree")
    func aBoardIsFoundByNumberNotName() {
        let source = Source(host: "forum.example", kind: .discuz)
        let onTheBoardPage = Note(
            id: "a", source: source, author: "", handle: "", body: "",
            title: "one", board: "What the board page calls itself", boardID: "39",
            postedAt: .distantPast, origins: [.publicTimeline]
        )
        // Same board, read through a cross-board listing, which names a section per row and
        // carries no number — so the name is all there is and the fallback has to hold.
        let fromAListing = Note(
            id: "b", source: source, author: "", handle: "", body: "",
            title: "two", board: "What the index calls it",
            postedAt: .distantPast, origins: [.publicTimeline]
        )
        let elsewhere = Note(
            id: "c", source: source, author: "", handle: "", body: "",
            title: "three", board: "Another board", boardID: "40",
            postedAt: .distantPast, origins: [.publicTimeline]
        )

        let query = DummyTimeline(
            board: BoardQuery(host: "forum.example", fid: 39, name: "What the index calls it")
        )
        #expect(query.items(from: [onTheBoardPage, fromAListing, elsewhere]).map(\.id) == ["a", "b"])

        // And the number is not a name: a board whose id says 40 is not this tab, whatever it is
        // called. Without this the fallback would quietly re-admit everything it was added for.
        let renamedToMatch = Note(
            id: "d", source: source, author: "", handle: "", body: "",
            title: "four", board: "What the index calls it", boardID: "40",
            postedAt: .distantPast, origins: [.publicTimeline]
        )
        #expect(query.items(from: [renamedToMatch]).isEmpty)
    }
}
