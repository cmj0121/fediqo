import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// Unit F4: the reader's own three steps — *sign in, list the boards, select one or more to
/// subscribe* — as the shell actually drives them.
///
/// What is pinned here is the **flow**, because that is what this unit is: `begin` stopping with
/// nothing added, the sheet the reader answers it in, every way out of it leaving nothing behind,
/// and the boards they kept as a property of the source. `DiscuzBoardJoin` has its own suite for what the
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
            routes["https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)&filter=author&orderby=dateline"] = outcome
        }
        return FixtureHTTP(routes)
    }

    private static func session(_ http: FixtureHTTP) -> ShellSession {
        ShellSession(http: http, store: ItemStore())
    }

    // MARK: - The pause

    /// **Two presses now, and the first of them is the new stage.** Add looks; a Discuz! has no
    /// document about itself, so what the look asks is whether it will show a signed-out reader
    /// any board at all, and the preview says that. Subscribe is what reaches D28's pause. Both
    /// are asserted, because "adds nothing" has to hold at *both* of them.
    @Test("Adding a forum shows it first, and subscribing stops at the picker with nothing added")
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

        // Stage one, and what a Discuz! can say about itself: its index answered a signed-out
        // reader, so it reads without an account — and the index it answered with is carried, so
        // the press has nothing left to ask.
        guard case .previewing(let preview, _, _) = session.stage else {
            Issue.record("a look should open a preview")
            return
        }
        #expect(preview.host == Self.host)
        #expect(preview.profile == .stated(SourceProfile(
            host: Self.host, kind: .discuz, readsWithoutAccount: true
        )))
        #expect(preview.boards.flatMap(\.boards).map(\.fid) == [33, 41])
        #expect(session.choosing == nil, "the boards were reached before the reader agreed")
        #expect(session.sources.isEmpty)

        await session.confirm()

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

    /// **A microblog is previewed too, and that is the point rather than a cost.** The old claim
    /// this test made — that a microblog does not stop — is no longer true and should not be
    /// patched into looking true: *every* protocol stops at the preview now, because a stage that
    /// appeared only for the one protocol with nothing to show would be the frame failing at its
    /// one job. What is still true, and is what the rest of the assertions are about, is that a
    /// microblog is never asked which boards: one press to look, one to take, and no third.
    @Test("A microblog is previewed, taken in one press after that, and never asked about boards")
    func aMicroblogIsPreviewedThenTaken() async {
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

        // Stage one, and the server had something to say — so the preview is the rich one and
        // nothing has been joined yet.
        guard case .previewing(let preview, _, _) = session.stage else {
            Issue.record("a Mastodon should be looked at before it is taken")
            return
        }
        #expect(preview.host == "first.example")
        #expect(preview.profile == .stated(SourceProfile(
            host: "first.example", kind: .mastodon, title: "First"
        )))
        #expect(session.sources.isEmpty)

        await session.confirm()

        #expect(session.stage == nil, "the sheet stayed up over a server that is now joined")
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
        await session.confirm()
        #expect(session.choosing != nil)

        // **One dismissal for all three stages now.** `cancelChoosing` was the picker's own way
        // out; the sheet is one presenter, so closing it is one call whichever stage is showing.
        session.dismissStage()

        // Nothing was added, so there is nothing to take back — and nothing to apologise for.
        #expect(session.stage == nil)
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
        await session.confirm()
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
        await session.confirm()
        // The premise, pinned: without it every assertion below is satisfied by a join that
        // never happened, and the test passes with `confirm()` deleted.
        guard session.choosing != nil else {
            Issue.record("a Discuz! should have paused on the picker")
            return
        }

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
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused for the reader to choose")
            return
        }

        await session.subscribe(offer.boards.filter { [33, 41].contains($0.fid) })

        // D26: one source per host, carrying the set of boards. Never one source per board.
        #expect(session.sources.map(\.host) == [Self.host])
        #expect(session.sources.first?.boards.map(\.fid) == [33, 41])
        #expect(!session.notes.isEmpty)

        // All and Trends are the only timeline queries. Boards stay on the source.
        #expect(session.queries.map(\.id) == ["all"])
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
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })

        #expect(!session.queries.contains { $0.id == "trends" })
        // And the place is still open, which is the half that would have broken quietly: the
        // gate used to want both ids.
        #expect(session.availability.allows(.timeline))
        #expect(session.timelineID == .all)
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

    /// **All and Trends are the only two queries of the store.** A forum is offered All alone —
    /// it has no trending read — and a microblog beside it brings Trends back. Boards add
    /// nothing to this list: they choose what a source fetches, not what the rail draws.
    @Test("The queries are All, and Trends only where a source has one")
    func queriesAreAllAndTrends() {
        let session = Self.session(Self.forumHTTP(index: .fail))
        let forum = Source(
            host: "forum.example", kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "启动盘工具")]
        )
        session.sources = [forum]
        session.rebuildQueries()
        #expect(session.queries.map(\.id) == ["all"])

        session.sources = [forum, Source(host: "mastodon.example", kind: .mastodon)]
        session.rebuildQueries()
        #expect(session.queries.map(\.id) == ["all", "trends"])
    }

    /// The selection is not persisted, so the only ids that reach a query are ones this build
    /// knows — but an unknown one, such as an old board tab's, names All rather than nothing.
    /// And a selection whose query goes away falls back to All too.
    @Test("An unknown timeline id, or a query that went away, falls back to All")
    func anUnknownTimelineFallsBackToAll() {
        #expect(TimelineQuery(id: "board:forum.example:33") == .all)
        #expect(TimelineQuery(id: "trends") == .trends)

        let session = Self.session(Self.forumHTTP(index: .fail))
        session.sources = [Source(host: "mastodon.example", kind: .mastodon)]
        session.rebuildQueries()
        session.timelineID = .trends
        session.sources = [Source(host: "forum.example", kind: .discuz)]
        session.rebuildQueries()
        #expect(session.timelineID == .all)
    }

    /// Subscribing to a board fetches its threads into the store and adds no tab: they are
    /// drawn under All.
    @Test("A subscribed board's threads land under All")
    func aSubscribedBoardLandsUnderAll() async {
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
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })

        #expect(session.queries.map(\.id) == ["all"])
        #expect(session.timelineID == .all)
        #expect(!TimelineQuery.all.items(from: session.notes, latest: nil).isEmpty)
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
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { [33, 41].contains($0.fid) })

        // The one that read is subscribed; the one that did not is **not** — a board in the rail
        // whose timeline can never load is the same failure as a source that can never load.
        #expect(session.sources.first?.boards.map(\.fid) == [33])
        #expect(session.queries.map(\.id) == ["all"])

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
        await session.confirm()
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

    /// **The refusal arrives at the press, not at the look, and that is a real change.** A
    /// Discuz! publishes nothing about itself, so the look never fetches the index — which is
    /// where the notice page is. The reader is therefore shown a preview of a forum that is going
    /// to turn them away, and finds out when they press Subscribe. That is the honest ordering:
    /// this app cannot know the answer without spending the request, and spending it on a reader
    /// who has not agreed to anything is what the whole stage exists to stop.
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
        await session.confirm()

        // The forum's own notice page is a refusal — the host is fine, the spelling is fine, and
        // somebody said no on purpose. That is the one failure a sign-in can change.
        #expect(session.offerSignIn == Self.host)
        #expect(session.refuse != nil)
        #expect(session.choosing == nil)
        // **And the sheet is gone.** A refusal is reported on the page, under the field, where
        // the offer of a sign-in is — leaving the preview up over it would put the one thing the
        // reader can do about it behind a sheet.
        #expect(session.stage == nil)
        #expect(session.sources.isEmpty)
        // What they typed is still there, so the way back is one press and not a retype.
        #expect(session.hostname == Self.host)
    }

    /// Refused at the press for the reason the notice-page test above states: the index is what
    /// carries the answer and the look does not fetch it.
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
        await session.confirm()

        // An index with no board is an account question, not an address question — sending the
        // reader to check their spelling would send them after a fault of theirs that is not one.
        #expect(session.offerSignIn == Self.host)
        #expect(session.choosing == nil)
        #expect(session.stage == nil)
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

    /// **The retry skips the preview and lands on the boards.** The reader has already read what
    /// this server says about itself, already pressed Subscribe, and already gone and done the
    /// one thing that could change the answer; showing them that screen again asks a question
    /// they have answered.
    ///
    /// **It is still a fresh look, and under the index probe that matters.** A signed-in reader's
    /// forum index is a different document — it is the index that says which boards they may see
    /// — so the retry reads one rather than reusing whatever the refused look left behind.
    ///
    /// **What this test does not show, said so rather than implied:** that the second read goes
    /// through the engine the sign-in built. This session holds no real engine, so `joiner(for:)`
    /// falls back to the plain client and the two transports are indistinguishable from here.
    /// That half is pinned Core-side by `PreviewTests.aPreviewSurvivesItsJoiner`, which runs the
    /// press on a second `FixtureHTTP` and asserts the second one did the reading.
    ///
    /// Pinned so it can fail: this calls `resumeAfterSignIn()` **once** and expects the boards.
    /// Wired to `add()`, as it was, the reader is left sitting on a preview and this goes red.
    @Test("A sign-in reached, and the retry lands on the boards without asking again")
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
        #expect(session.signInFinished(reached: true, host: Self.host), "the premise: a sign-in")

        await session.resumeAfterSignIn()

        #expect(session.choosing?.offer.host == Self.host, """
            The retry left the reader on a preview they had already answered. \
            `resumeAfterSignIn` looks and takes; `add` stops.
            """)
        #expect(session.choosing?.offer.boards.map(\.fid) == [33])
        #expect(session.sources.isEmpty, "the boards stage adds nothing until they pick")
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
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return
        }
        await session.subscribe(offer.boards.filter { $0.fid == 33 })
        #expect(session.sources.first?.boards.map(\.fid) == [33])

        await session.clear(host: Self.host)

        // The server stays added and its boards stay chosen. The rail is still All.
        #expect(session.sources.first?.boards.map(\.fid) == [33])
        #expect(session.queries.map(\.id) == ["all"])
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
            // A `.one` key is English's singular, read only through `L10n.count`, which falls
            // back to the plain key where a language has no grammatical number — so a raw key
            // can never reach the screen through one, and 繁體中文 carries none.
            let missing = english.subtracting(translated).filter { !$0.hasSuffix(".one") }.sorted()
            #expect(missing.isEmpty, "\(lproj) is missing: \(missing.joined(separator: ", "))")
            let extra = translated.subtracting(english).sorted()
            #expect(extra.isEmpty, "\(lproj) has strings en does not: \(extra.joined(separator: ", "))")
        }
    }

    /// **來源 is a source; 主機 is a hostname or an address.** The user's ruling, and three keys
    /// shipped with it backwards — `shell.account.summary`, `join.browse.title` and
    /// `account.browse.label` all said 主機 about a thing that is a 來源. Their English was already
    /// right, which is exactly why nobody saw it: a reader in English reads "servers you read"
    /// and a reader in 中文 read "the hosts you read", and the two are not the same sentence.
    ///
    /// **Derived, and not the three literals this first shipped as.** A list of the keys that were
    /// wrong today is a test that describes a smaller world than the code — the branch's own first
    /// earned convention, and the comment over the literal version claimed a rule it did not
    /// implement, which is worse than the missing pin because it stops the next reader looking.
    /// So the rule is read off the development bundle: **every key whose English says "server" is
    /// a key whose 中文 must say neither 主機 nor 伺服器.** A key written the wrong way tomorrow is
    /// on no list here and is caught where it is written.
    ///
    /// **Two banned spellings and not one, because the app had three words for one concept.** 主機
    /// was the ruling's own case. 伺服器 was found in two pre-M1 sentences while this was being
    /// written — `prefs.cache.footer` and `forum.signin.save.on` — and a test banning only 主機
    /// would have shipped one third of the inconsistency with a green tick over it. The user ruled
    /// on a *rule*, so it reaches both.
    ///
    // MARK: - A row restating what it reads (decisions 24, 25, 26, 27)

    /// A four-board index, and a session with three of them already subscribed.
    ///
    /// The index is written here because these tests *are* about which boards the picker offers
    /// and which of them it opens ticked; everything else about the markup is
    /// `ForumJoinTests`' business.
    private static let fourBoards = #"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h2><a href="forum.php?gid=56">::工具区::</a></h2>
    <div id="category_56" class="bm_c">
    <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt></dl>
    <dl><dt><a href="forum.php?mod=forumdisplay&fid=40">镜像工具</a></dt></dl>
    <dl><dt><a href="forum.php?mod=forumdisplay&fid=37">虚拟机专区</a></dt></dl>
    <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">急救盘</a></dt></dl>
    </div></body></html>
    """#

    private static func oneBoard(_ fid: Int) -> String {
        #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=\#(fid)">板</a></h1>
        <table><tbody id="normalthread_9\#(fid)"><tr>
        <th class="common"><a href="forum.php?mod=viewthread&tid=9\#(fid)" class="s xst">一件事</a></th>
        <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
        </tr></tbody></table>
        """#
    }

    /// A session already reading boards 33, 40 and 37 on the forum — joined the way a reader
    /// would have, so the store holds what a restate is about to change rather than a fixture's
    /// idea of it.
    private static func reading(_ index: String = fourBoards) async -> (ShellSession, FixtureHTTP) {
        let http = forumHTTP(index: .text(index), boards: [
            33: .text(oneBoard(33)), 40: .text(oneBoard(40)), 37: .text(oneBoard(37)),
            41: .text(oneBoard(41)),
        ])
        let session = Self.session(http)
        session.hostname = host
        await session.add()
        await session.confirm()
        guard case .choosingBoards(let offer, _) = session.stage else { return (session, http) }
        await session.subscribe(offer.boards.filter { [33, 40, 37].contains($0.fid) })
        return (session, http)
    }

    /// **Decision 25, and the reason this entrance is dangerous enough to need one.** The picker
    /// opens ticked from what the reader is already subscribed to, because
    /// `ItemStore.subscribe(host:to:)` replaces the set — an empty picker plus one new tick is a
    /// silent unsubscribe from the other three.
    @Test("A row's boards control opens the picker ticked from what the reader already reads")
    func theRestatePickerOpensTicked() async {
        let (session, _) = await Self.reading()
        #expect(session.sources.first?.boards.map(\.fid) == [33, 40, 37], "the premise")

        await session.changeBoards(host: Self.host)

        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        #expect(offer.boards.map(\.fid) == [33, 40, 37, 41])
        #expect(origin.ticked == [33, 40, 37], """
            The picker opened with the reader's own subscription unticked. A press then replaces \
            their board set with whatever is ticked, which is a silent unsubscribe.
            """)
        // And it is a restate rather than a join: what is behind it is nothing, and the baseline
        // is carried so the press can keep what it already reads.
        #expect(origin.keeping.map(\.fid) == [33, 40, 37])
        #expect(JoinSheet.leading(for: session.stage) == .cancel)
        #expect(JoinSheet.detailKey(for: origin) == "board.choose.detail.change")
    }

    /// **The data-loss case, end to end through the session.** Three boards, reopen, tick a
    /// fourth, Subscribe — and the three survive, having never been asked for again.
    @Test("Adding a fourth board from a row keeps the three already read")
    func aRestateKeepsTheBoardsAlreadyRead() async {
        let (session, http) = await Self.reading()
        await session.changeBoards(host: Self.host)
        guard case .choosingBoards(let offer, _) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        // The pages of the boards already read, read when the picker opened (#161), are done
        // before the press is counted.
        await session.looking?.value
        let asked = await http.requested.count

        await session.subscribe(offer.boards.filter { [33, 40, 37, 41].contains($0.fid) })

        #expect(session.sources.first?.boards.map(\.fid) == [33, 40, 37, 41], """
            A board the reader was already subscribed to was dropped by a press that only added \
            one. The reader never touched it.
            """)
        #expect(session.unread.isEmpty)
        // One board was new, so exactly one board was read. The other three were carried.
        #expect(await http.requested.count == asked + 1, """
            The restate re-read boards the store already holds. Each one runs for seconds, and \
            each one is a chance to lose a subscription to a timeout.
            """)
        // Decision 22: the notes the reader already has stay whatever happens to the picks.
        #expect(session.notes.count >= 3)
    }

    /// Unticking, which is the other half of a restate. The board goes out of the rail and the
    /// notes it brought stay — decision 22, because unsubscribing changes what this device
    /// fetches *next* and is not a deletion of what it holds.
    @Test("Unticking a board drops it from the tabs and keeps the notes it already brought")
    func untickingDropsTheBoardAndKeepsTheNotes() async {
        let (session, _) = await Self.reading()
        let held = session.notes.count
        #expect(held >= 3, "the premise: three boards' threads are in the store")

        await session.changeBoards(host: Self.host)
        guard case .choosingBoards(let offer, _) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        await session.subscribe(offer.boards.filter { [33, 37].contains($0.fid) })

        #expect(session.sources.first?.boards.map(\.fid) == [33, 37])
        #expect(session.queries.map(\.id) == ["all"])
        #expect(session.notes.count == held, """
            Unticking a board deleted the notes it had already brought. Decision 22: this device \
            stops fetching it, it does not forget what it holds.
            """)
    }

    /// **Decision 26, revised by #161: only an untick removes a subscription.** A board the
    /// reader reads that the front page no longer lists is still listed — under the name it was
    /// subscribed by — and still ticked, and a press keeps it. Absence from one page is not
    /// evidence the board is gone: a sub-board the front page never names is absent the same
    /// way, and the old rule dropped it from a reader who never touched it. A board the forum
    /// really deleted is there to untick.
    @Test("A subscribed board the forum no longer lists is still listed, ticked, and kept")
    func aBoardTheForumNoLongerListsIsKept() async {
        let (session, _) = await Self.reading()
        // The same forum, one board later withdrawn from its index.
        session.stage = nil
        let shrunk = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt></dl>
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=37">虚拟机专区</a></dt></dl>
        </div></body></html>
        """#
        let reopened = ShellSession(http: Self.forumHTTP(index: .text(shrunk)), store: session.store)
        reopened.sources = session.sources

        await reopened.changeBoards(host: Self.host)
        await reopened.looking?.value

        guard case .choosingBoards(let offer, let origin) = reopened.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        #expect(offer.boards.map(\.fid) == [33, 37, 40], "listed, after what the forum places")
        #expect(offer.categories.last?.gid == JoinOffer.keptSection)
        #expect(origin.ticked == [33, 40, 37])
        #expect(reopened.refuse == nil)
        #expect(reopened.rowRefusal == nil)

        // And the press keeps it, having asked nothing of it again.
        await reopened.subscribe(offer.boards.filter { origin.ticked.contains($0.fid) })
        #expect(Set(reopened.sources.first?.boards.map(\.fid) ?? []) == [33, 40, 37])
    }

    /// **Decision 24, from both ends.** Core cannot express "unsubscribe from everything" — with
    /// an empty pick `DiscuzBoardJoin.subscribe` returns before it reaches `store.subscribe`, and
    /// the session's empty-pick guard reads it as a reader who changed their mind, which is true
    /// of a join and false of a restate. So the button refuses where the reader can see it, and
    /// the press behind it changes nothing if it is ever reached.
    ///
    /// **Written down so a later round does not "fix" this into a silent mass-unsubscribe.** The
    /// honest route to reading none of a forum is Remove.
    @Test("A restate cannot unsubscribe from everything, and the refusal is visible")
    func aRestateCannotUnsubscribeFromEverything() async {
        let (session, _) = await Self.reading()
        await session.changeBoards(host: Self.host)
        #expect(session.stage?.ticked.isEmpty == false, "the premise: the picker opened ticked")

        // The reader unticks every board. The Subscribe button is `.disabled(picked.isEmpty)`,
        // and this is that expression's own value.
        session.stage = session.stage?.ticking([])
        #expect(session.stage?.ticked.isEmpty == true)

        // And if the press is reached anyway, it changes nothing rather than emptying the set.
        await session.subscribe([])
        #expect(session.sources.first?.boards.map(\.fid) == [33, 40, 37], """
            An empty pick emptied the reader's subscription. Core reads that silence as a reader \
            who changed their mind; a restate must not turn it into a mass-unsubscribe.
            """)
        #expect(session.refuse == nil)
    }

    /// The forum's index could not be read. **The sheet does not open**, and the sentence is in
    /// the row the reader pressed — not under the field, which on a list of six sources is off
    /// screen when they pressed row four.
    @Test("A boards control whose index fails says so in its own row, and opens nothing")
    func aFailedIndexSpeaksInItsOwnRow() async {
        let (session, _) = await Self.reading()
        let refusing = ShellSession(
            http: Self.forumHTTP(index: .fail), store: session.store
        )
        refusing.sources = session.sources

        await refusing.changeBoards(host: Self.host)

        #expect(refusing.stage == nil, "the picker opened on an index that was never read")
        #expect(refusing.rowRefusal?.host == Self.host)
        #expect(refusing.rowRefusal?.key == "account.source.boards.unread")
        // Not the page's own refusal line: that one is drawn under the field and says a host was
        // not added. This host was added weeks ago and nothing changed.
        #expect(refusing.refuse == nil)
        // And it goes when the row does.
        await refusing.remove(host: Self.host)
        #expect(refusing.rowRefusal == nil)
    }

    /// **Risk 12's class, closed at the one place it can be.** All four controls are dimmed on
    /// this rule and the boards press refuses on this rule, so a control the reader can see and
    /// press cannot be refused three files away. The four defects risk 12 counts were each a
    /// correct rule attached where nothing could read it.
    @Test("One rule says whether a row may be acted on, and the press asks the same one")
    func oneRuleDecidesWhetherTheBoardsControlIsLive() async {
        #expect(ShellSession.rowActsLive(at: nil, checking: false))
        #expect(!ShellSession.rowActsLive(at: nil, checking: true), "something is on the wire")
        #expect(!ShellSession.rowActsLive(at: .browsing, checking: false))
        let preview = SourcePreview(
            host: Self.host, kind: .discuz, profile: .silent(host: Self.host, kind: .discuz)
        )
        #expect(!ShellSession.rowActsLive(
            at: .previewing(preview, from: .field, ticked: []), checking: false
        ), "this press replaces the stage, so it must not fire under a preview being read")

        // And the press itself refuses on exactly that, rather than on a guard of its own.
        let (session, http) = await Self.reading()
        session.stage = .browsing
        let asked = await http.requested.count
        await session.changeBoards(host: Self.host)
        #expect(session.stage == .browsing, "the press acted while the rule says it is not live")
        #expect(await http.requested.count == asked)
    }

    /// Opens only when a test lets it, so a press can be caught mid-flight. `JoinStageTests`'
    /// shape, for the same reason: the flag is set before the waiters are resumed.
    /// **One press, one progress report.** `AccountPane`'s line fired on bare `checking`, so a
    /// restate drew the row's own line *and* a second spinner under the field — and the word under
    /// the field was "Checking …", the detection vocabulary, for the one errand whose whole
    /// justification is that it detects nothing.
    ///
    /// The rule and the errand are both pinned: the predicate says which surface reports, and the
    /// press is caught in flight to prove the session actually claims the errand for the row.
    @Test("A restate reports itself in its own row, and the page's line stays down")
    func aRestateDrawsOneProgressReport() async {
        // The rule, every way round. **Three surfaces answer it now** — the page, the pressed row
        // and the inline block — and an expression in a `View` body deciding which is the shape
        // this branch has shipped four defects in. Rewritten from `(checking:rowErrand:)` with
        // the widening: a `String?` could name two owners and there are three, which is why the
        // block's own Subscribe used to draw a bare spinner 300pt from a sentence about it.
        let block = ProgressReport(owner: .block, key: "account.detect.progress")
        let drawn = JoinStage.previewing(
            SourcePreview(host: Self.host, kind: .discuz, profile: .unasked(
                host: Self.host, kind: .discuz
            )),
            from: .field, ticked: []
        )
        #expect(ShellSession.reporting(
            ProgressReport(owner: .page, key: "account.detect.progress"), drawnAs: nil
        ) == .page)
        #expect(ShellSession.reporting(nil, drawnAs: nil) != .page)
        #expect(ShellSession.reporting(block, drawnAs: drawn) != .page,
                "the page drew a line for a press made in the block, 300pt below it")
        #expect(ShellSession.reporting(
            ProgressReport(owner: .row(host: Self.host), key: "account.source.boards.progress"),
            drawnAs: nil
        ) != .page, """
            The page drew its own progress line for an errand a row had already claimed, so one \
            press produced two spinners and two sentences.
            """)

        // **The block is the one surface that can go away under its own errand**, because its
        // Cancel stays live while its Subscribe is on the wire. A sentence owned by a block that
        // has been dismissed had nowhere to appear — while `checking` was still true and the
        // field, the magnifier and Browse were all grey. The page takes it back.
        #expect(ShellSession.reporting(block, drawnAs: drawn) == .block)
        #expect(ShellSession.reporting(block, drawnAs: nil) == .page, """
            A reader who cancelled the block mid-press was left waiting on a request with every \
            control refused and nothing on screen saying why.
            """)
        // A row's errand is never taken back: a row outlives its own press.
        let row = ProgressReport(owner: .row(host: Self.host), key: "account.detect.progress")
        #expect(ShellSession.reporting(row, drawnAs: nil) == .row(host: Self.host))

        // And the reporter is a function of the origin, never of what happens to be drawn.
        //
        // **One entrance answers and one has nothing to answer with** — decision 38 leaves two
        // preview origins, and `reporter` is what `confirm()` reads to refuse a detail's Subscribe
        // structurally rather than at a guard. The `JoinEntrance` enum that used to carry this is
        // gone: its second case, the browser's, is the seam that produced this milestone's hardest
        // defect, and with one entrance left the enum was one value wrapping another.
        #expect(PreviewOrigin.field.reporter == .block)
        #expect(
            PreviewOrigin.joined(Source(host: Self.host, kind: .discuz)).reporter == nil,
            "a detail was given a surface to report a press it cannot make"
        )

        let (seeded, _) = await Self.reading()
        let http = GatedHTTP(
            ["https://\(Self.host)/forum.php": .text(Self.fourBoards)],
            holding: "https://\(Self.host)/forum.php"
        )
        let session = ShellSession(http: http, store: seeded.store)
        session.sources = seeded.sources
        let pane = AccountPane(session: session)

        let press = Task { await session.changeBoards(host: Self.host) }
        #expect(await spun { session.checking }, """
            the index read never claimed the errand, so there was nothing to ask who owned it
            """)

        #expect(session.progress?.owner == .row(host: Self.host), """
            the row did not claim its own errand
            """)
        // And it says the **index** read, which is what that key has always meant.
        #expect(session.progress?.key == "account.source.boards.progress")
        #expect(pane.pageWaiting == nil, "the page drew a second progress line for the row's press")
        #expect(
            SourceRow.waitingLine(session.progress, drawnAs: session.stage, host: Self.host) != nil,
            "the row that claimed the errand had no sentence to draw"
        )

        await http.gate.open()
        await press.value

        // And it is handed back the moment the errand ends, so no sentence outlives its press.
        #expect(session.progress == nil)
        #expect(!session.checking)
    }

    /// **The second half of the errand obeys the rule the first half wrote down.** An index
    /// failure is drawn in the pressed row, in `inkDim`, because "that colour is spent on the line
    /// that says a host was not added and why, and this host was added weeks ago". A Subscribe
    /// failure is the same errand and the same host — so it must not produce an alarm-coloured
    /// sentence under a field the reader never touched, a screen away from the row they pressed.
    ///
    /// Reachable: untick everything subscribed, tick only new boards, and have all of them fail.
    @Test("A restate whose Subscribe fails says so in its own row, not in alarm under the field")
    func aRestateSubscribeFailureSpeaksInItsOwnRow() async {
        let (seeded, _) = await Self.reading()
        // The same forum; the one board the reader is about to tick refuses outright.
        let session = ShellSession(
            http: Self.forumHTTP(index: .text(Self.fourBoards), boards: [41: .fail]),
            store: seeded.store
        )
        session.sources = seeded.sources

        await session.changeBoards(host: Self.host)
        guard case .choosingBoards(let offer, _) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        // Everything already subscribed is unticked, and only the new board is picked.
        await session.subscribe(offer.boards.filter { $0.fid == 41 })

        #expect(session.rowRefusal?.host == Self.host, """
            A restate that failed at Subscribe said nothing in the row the reader pressed.
            """)
        #expect(session.rowRefusal?.key == "account.source.boards.unread")
        #expect(session.refuse == nil, """
            A restate drew an alarm-coloured line under the field about a host that was added \
            weeks ago and is still in the reader's list. That colour is spent on a host that was \
            not added, and this one was.
            """)
        #expect(session.offerSignIn == nil, """
            A restate offered a sign-in under the field. The row already carries its own Sign in \
            control; that offer exists to give a refused join somewhere to go.
            """)
        #expect(session.unreadAll == 0)
        // And nothing was lost: a failed restate changes no subscription.
        #expect(session.sources.first?.boards.map(\.fid) == [33, 40, 37])
    }

    /// **A control that cannot be pressed must not look pressable.** `.disabled` dims a control by
    /// supplying a foreground style, which an explicit `.foregroundStyle` overrides — so a refused
    /// control went on saying press-me at full strength. That defect shipped twice on this branch,
    /// and `RowActionButton`'s own doc predicted it for these four. The tint is a function of the
    /// state now, so a colour cannot be set on a control that is not live.
    ///
    /// **The plate this used to be about is gone** (decision 30): the boards line is no longer the
    /// affordance, so `ShellChrome.well` leaves `AccountPane` entirely and what is pinned here is
    /// the rule the four glyphs are drawn from instead.
    @Test("A row's boards control stops looking pressable exactly when it stops being pressable")
    func theBoardsControlLooksRefusedWhenItIsRefused() {
        let source = Source(
            host: Self.host, kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "启动盘工具")]
        )
        // **`SourceRow.state(of:source:actsLive:)` is gone, and this reads the view's rule
        // directly — which is the stronger of the two anyway.** With decision 33 withdrawing the
        // strike, that function was a function of `actsLive` alone and no longer read `source` at
        // all: a signature that lies about what decides. The rule now lives in one place, on the
        // view, where the drawing is.
        let row = SourceRow(source: source, profile: .unasked(host: Self.host, kind: .discuz))
        func drawn(live: Bool) -> SourceRowView {
            SourceRowView(
                row: row, signedIn: false, width: 900,
                widest: SourceRow.controls(of: source),
                actsLive: live, waiting: nil, refusal: nil,
                signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
            )
        }
        #expect(drawn(live: true).state(.boards) == .live(ShellChrome.inkDim(.light)))
        #expect(drawn(live: false).state(.boards) == .dimmed, """
            The control drew live while the rule said the row was not the reader's, which is a \
            press the reader can see and cannot make.
            """)
    }

    /// **The press asks the same two questions the control is drawn on, not one of them.**
    /// `boardsLive` answers *when*; `canChangeBoards` answers *which protocol*. A press that
    /// asked only the first would reach Core, be refused `unsupportedKind`, and hand the reader
    /// "boards could not be read just now" — a sentence about a wire, about a protocol that has
    /// no picker at all.
    @Test("A protocol with no board picker cannot reach the restate, and is not told it failed")
    func aProtocolWithNoPickerCannotRestate() async {
        let http = Self.forumHTTP(index: .text("<html></html>"))
        let session = Self.session(http)
        await session.store.add(Source(
            host: Self.host, kind: .discourse,
            boards: [BoardSubscription(fid: 33, name: "somewhere")]
        ))
        session.sources = await session.store.sources()

        await session.changeBoards(host: Self.host)

        #expect(session.stage == nil)
        #expect(session.rowRefusal == nil, """
            A protocol with no picker was told its boards could not be read. Nothing was read, \
            because there was nothing to read — and that is not a failure to report.
            """)
        #expect(await http.requested.isEmpty, "a protocol with no picker went to the wire")
    }

    /// Which protocols have a board set the reader can re-state at all. **A total map**, in the
    /// shape `DummyItemTests` established: a set of the true ones would say nothing about the
    /// kinds left out, and it is the ones left out that must not grow a control that opens a
    /// sheet which cannot exist (decision 6, and unit 7's question about Lemmy).
    @Test("Only a protocol with a board picker offers to change its boards")
    func onlyAForumOffersToChangeItsBoards() {
        let expected: [ProtocolKind: Bool] = [
            .discuz: true,
            .mastodon: false, .pleroma: false, .akkoma: false, .misskey: false,
            .pixelfed: false, .lemmy: false, .peertube: false, .friendica: false,
            .gotosocial: false, .discourse: false, .unknown: false,
        ]
        #expect(Set(expected.keys) == Set(ProtocolKind.allCases), """
            A protocol was added and this map was not asked about it.
            """)
        for kind in ProtocolKind.allCases {
            #expect(SourceRow.canChangeBoards(kind) == expected[kind], "\(kind)")
        }
    }

    /// **The keys the rule does not touch are as deliberate as the ones it does.**
    /// `join.browse.none` says "Type a hostname in the field instead" and keeps 主機名稱; so do
    /// `account.add.host`, `account.refuse.network` and the rest of the address vocabulary. They
    /// are about a machine's name, which is precisely what 主機 is reserved for, and the word
    /// boundary is what keeps them out — as it keeps `observer` out.
    ///
    /// `join.browse.filter` was this comment's example until decision 38 retired it with the
    /// browser's field; the replacement is the same point made by a key that still ships.
    ///
    /// `account.sources.title` is 來源 and is the reference.
    @Test("No key whose English says server calls it 主機 or 伺服器 in 中文")
    func sourcesAreNotCalledHosts() throws {
        let english = try Self.pairs(in: "en")
        // Both bundles, not one. `L10n` falls back from `zh-TW` to `zh-Hant`, so a correction made
        // in one and missed in the other still resolves — and the reader whose system picks the
        // bundle that was missed sees the old sentence.
        for lproj in ["zh-Hant", "zh-TW"] {
            let chinese = try Self.pairs(in: lproj)
            // If the parser ever stops reading these files, every loop below runs zero times and
            // the test passes while proving nothing. These two lines refuse that.
            #expect(english.count > 200, "the strings file stopped parsing; this proves nothing")

            let aboutServers = english.filter { Self.saysServer($0.value) }
            #expect(aboutServers.count >= 15, "the English rule stopped matching; it proves nothing")

            for key in aboutServers.keys.sorted() {
                let said = chinese[key] ?? ""
                for wrong in Self.notASource {
                    #expect(!said.contains(wrong), """
                        \(lproj)/\(key) calls a source \(wrong). This app says 來源 for a source \
                        and keeps 主機 for a hostname or an address. Its English says server. \
                        中文: \(said)
                        """)
                }
            }

            // From the other side, on the keys this work corrected: they must *say* 來源 and not
            // merely avoid the wrong words, or a translation that dropped the noun entirely would
            // pass the rule above while saying less than the English.
            for key in Self.correctedToSource {
                #expect(chinese[key]?.contains("來源") == true, """
                    \(lproj)/\(key) stopped calling a source 來源: \(chinese[key] ?? "missing")
                    """)
            }
        }
    }

    /// The two words this app does **not** use for a source. 主機 is a hostname or an address;
    /// 伺服器 is a third spelling that reached two pre-M1 sentences and is now spent.
    private static let notASource = ["主機", "伺服器"]

    /// The keys whose English says server, which must therefore name a 來源 outright.
    ///
    /// **Not every key the ban covers**: `source.held.forum` and `source.held.closed` are about a
    /// *forum* and say 論壇, correctly. This list is the ones whose subject is the source itself.
    ///
    /// Listed only for the positive half — that the noun is *present*. The ban above is derived
    /// and needs no list; this cannot be, because "said nothing at all" is indistinguishable from
    /// "said it right" to a rule written as an absence.
    private static let correctedToSource = [
        // The four this round added whose English says *server*. Listed here and not left to the
        // ban alone, which is the whole argument for this list existing: a translation that
        // dropped the noun entirely passes a rule written as an absence.
        "account.source.open.hint",
        "source.held.detail",
        "source.held.microblog",
        "source.held.turnedAway",

        "account.browse.label",
        "forum.signin.save.on",
        // **`join.browse.title` is off this list and two keys are on in its place**, which is
        // decision 38 changing what that title is about rather than a rule being relaxed. It read
        // "Servers to read" and is now "Protocols Fediqo reads" — the browser's first step, whose
        // subject is a protocol and not a source, so the noun it must carry is not 來源 and the
        // derived ban above does not reach it either. The two keys below are the ones whose
        // subject *is* the source now: step two's title, and the sentence under step one saying
        // what pressing a protocol shows.
        "join.browse.protocols.detail",
        "join.browse.servers.title",
        "join.preview.closed.hint",
        "join.preview.detail",
        "join.preview.next.microblog",
        "join.preview.rules",
        "join.preview.turnedAway",
        "join.preview.unread",
        "prefs.cache.footer",
        "shell.account.summary",
    ]

    /// Whether a sentence is about a server, in the one language the rule is derived from.
    ///
    /// Word-bounded, so `observer` is not a server and a key is not swept in by a substring.
    private static func saysServer(_ english: String) -> Bool {
        english.range(
            of: #"\bservers?\b"#, options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Every key and its value from one shipped `.lproj`, read off disk for `keys(in:)`'s reason:
    /// `L10n` falls back between the two Chinese bundles and cannot see what one of them says.
    private static func pairs(in lproj: String) throws -> [String: String] {
        let text = try bundleText(lproj)
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst()
            guard let keyEnd = body.firstIndex(of: "\"") else { continue }
            let key = String(body[body.startIndex..<keyEnd])
            guard let equals = body[keyEnd...].firstIndex(of: "=") else { continue }
            var value = body[body.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.hasSuffix("\";"), value.count >= 3 else { continue }
            value.removeFirst()
            value.removeLast(2)
            found[key] = value
        }
        return found
    }

    /// The two Chinese bundles are the same file, byte for byte — `zh-TW` exists because App
    /// Store Connect wants that code, not because the wording differs. A correction applied to one
    /// and not the other is a reader seeing the old sentence depending on which bundle answered.
    @Test("The two Chinese bundles are byte-identical")
    func theChineseBundlesAreTheSameFile() throws {
        let hant = try Self.bundleText("zh-Hant")
        let tw = try Self.bundleText("zh-TW")
        #expect(hant == tw, "zh-Hant and zh-TW have drifted apart")
    }

    private static func bundleText(_ lproj: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/FediqoUI/Resources/\(lproj).lproj/Localizable.strings"
                ),
            encoding: .utf8
        )
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

    // MARK: - The longest wait in the app, said correctly

    /// **"Checking %@…" is the detection vocabulary, and it stood over the one phase in this app
    /// that detects nothing.** `subscribe(_:)` reads one page per picked board, sequentially, so a
    /// reader who picked four boards watched the word *Checking* for as long as four page fetches
    /// take, about a forum this app had already detected, previewed and read the index of.
    ///
    /// Unit C fixed the restate's half by routing it into the row. The join's half was still under
    /// the field, and this is it: **one key, both entrances**, because it is one phase.
    ///
    /// Caught in flight rather than asserted on the rule alone — the defect was never the rule, it
    /// was which sentence the running errand carried (risk 12).
    @Test("The boards a reader picked are not 'Checking': one phase, one sentence, both entrances")
    func theBoardsAReaderPickedAreNotADetection() async {
        let http = GatedHTTP(
            [
                "/": .text(#"""
                <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
                """#),
                "https://\(Self.host)/forum.php": .text(Self.fourBoards),
                "https://\(Self.host)/forum.php?mod=forumdisplay&fid=33&filter=author&orderby=dateline":
                    .text(Self.oneBoard(33)),
            ],
            holding: "https://\(Self.host)/forum.php?mod=forumdisplay&fid=33&filter=author&orderby=dateline"
        )
        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)
        session.hostname = Self.host
        await session.add()
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused for the reader to choose")
            return
        }

        let press = Task { await session.subscribe(offer.boards.filter { $0.fid == 33 }) }
        #expect(await spun { session.checking }, """
            the boards never went on the wire, so there was nothing to ask who owned it
            """)

        // A join: the boards sheet is down and the block went with the stage, so the page owns it.
        #expect(session.progress?.owner == .page)
        #expect(session.progress?.key == "account.join.boards.progress", """
            The join path still says "Checking %@…" over the boards the reader picked — the \
            detection vocabulary, over a phase that detects nothing and takes the longest.
            """)
        let said = pane.pageWaiting
        #expect(said?.contains(Self.host) == true)
        #expect(
            said != String(format: L10n.t("account.detect.progress"), Self.host),
            "the page drew the detection sentence over the board reads"
        )
        #expect(
            said == String(format: L10n.t("account.join.boards.progress"), Self.host)
        )
        // And it is not the *index* sentence either: three phases, three sentences.
        #expect(said != String(format: L10n.t("account.source.boards.progress"), Self.host))

        await http.gate.open()
        await press.value
        #expect(session.progress == nil, "a sentence outlived the press it was about")
    }

    /// The other half of the same phase: pressed in a row, it is said **in that row**, in the same
    /// words. One key and two owners, because a reader's picked boards are being read either way.
    @Test("A restate's boards read says the same sentence, in the row that asked for it")
    func aRestatesBoardReadSaysTheSameThing() async {
        let (seeded, _) = await Self.reading()
        let http = GatedHTTP(
            ["https://\(Self.host)/forum.php?mod=forumdisplay&fid=40&filter=author&orderby=dateline": .text(Self.oneBoard(40))],
            holding: "https://\(Self.host)/forum.php?mod=forumdisplay&fid=40&filter=author&orderby=dateline"
        )
        let session = ShellSession(http: http, store: seeded.store)
        session.sources = seeded.sources
        let pane = AccountPane(session: session)
        let offer = JoinOffer(
            host: Self.host, kind: .discuz,
            categories: [DiscuzCategory(
                gid: 56, name: "::工具区::",
                boards: [
                    DiscuzBoard(fid: 40, name: "镜像工具", category: "::工具区::", gid: 56),
                ]
            )]
        )
        session.stage = .choosingBoards(offer, from: .joined(subscribed: [], ticked: [40]))

        let press = Task { await session.subscribe(offer.boards) }
        #expect(await spun { session.checking }, """
            the restate never claimed the errand, so there was nothing to ask who owned it
            """)

        #expect(session.progress?.owner == .row(host: Self.host), """
            A restate reported itself under the field, a screen away from the row that asked.
            """)
        #expect(session.progress?.key == "account.join.boards.progress")
        #expect(pane.pageWaiting == nil, "the page drew a second sentence for one press")
        #expect(
            SourceRow.waitingLine(session.progress, drawnAs: session.stage, host: Self.host)
                == String(format: L10n.t("account.join.boards.progress"), Self.host)
        )
        // And not in a row that did not ask.
        #expect(SourceRow.waitingLine(
            session.progress, drawnAs: session.stage, host: "elsewhere.example"
        ) == nil)

        await http.gate.open()
        await press.value
        #expect(session.progress == nil)
    }

    // MARK: - The tick, which was not there

    /// **The one finding of this round that is arithmetic rather than taste.** The plate was filled
    /// `selectInk`, which is `phosphor`, and the checkmark was drawn in `selectFill`, which is that
    /// same phosphor at 10% (light) / 22% (dark). A translucent colour composited over itself at
    /// full strength **is** that colour, so the mark measured **1.00:1 in both schemes** — there
    /// was no tick in the checkbox, and a reader could not find a control that was not drawn.
    ///
    /// **Derived and not stated, which is what makes this the pin the suite was missing.** The
    /// ratio is computed from the tokens the view actually reads, through `Color.resolve(in:)`,
    /// compositing in the **encoded** sRGB space a renderer blends in — see `contrast(_:on:_:)`,
    /// which is where that choice is argued and where it must not be "corrected" to linear. So
    /// re-tinting either token, or handing the mark the plate's own hue again, fails here. A test
    /// that asserted *which token* was used would have passed on the shipped code, because the
    /// shipped code used a token too.
    @Test("The tick is a mark a reader can see, and the box has a boundary they can find")
    func theTickIsVisible() {
        for scheme in [ColorScheme.light, .dark] {
            guard case .on(let plate, _, let mark) = BoardPickerList.tick(true, scheme) else {
                Issue.record("a ticked box is not drawn as ticked in \(scheme)")
                continue
            }
            // 4.5:1 is the floor this app's own `inkFaint` doc sets for small type, and a
            // checkmark is the smallest thing on the row. Measured after the fix: 5.37:1 light,
            // 9.60:1 dark.
            let markOnPlate = Self.contrast(mark, on: plate, scheme)
            #expect(markOnPlate >= 4.5, """
                the checkmark measures \(markOnPlate):1 on its own plate in \(scheme). \
                It was 1.00:1 when the mark was drawn in a translucent version of the plate.
                """)

            guard case .off(_, let border) = BoardPickerList.tick(false, scheme) else {
                Issue.record("an unticked box is not drawn as unticked in \(scheme)")
                continue
            }
            // WCAG 1.4.11 wants 3:1 for a control's own boundary. `hairline`, the token this
            // replaces, measured 1.30:1 in light — a box whose edge was not findable either.
            // Measured after: 4.78:1 light, 6.69:1 dark.
            let edge = Self.contrast(border, on: ShellChrome.page(scheme), scheme)
            #expect(edge >= 3, "the unticked box's own boundary measures \(edge):1 in \(scheme)")
        }
    }

    /// **The state carries the mark, so a box with nothing in it cannot be given one.**
    ///
    /// `RowActionState`'s shape, applied to the other control this branch shipped invisible: the
    /// three colours are chosen together in one `static func` a test can drive, and the mark's ink
    /// exists only in the ticked case. The previous spelling picked all three inside a `View` body
    /// with two ternaries, which is reachable from no test at all — and that is how the defect
    /// above survived a green suite (risk 12).
    @Test("Only a ticked box has a mark, and the two states differ by a shape and not a hue")
    func onlyATickedBoxHasAMark() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(BoardPickerList.tick(false, scheme).mark == nil, "\(scheme)")
            #expect(BoardPickerList.tick(true, scheme).mark != nil, "\(scheme)")
            // The row's wash is deliberately *not* the state — it is a scanning aid down a column
            // of 33 boards and measures 1.09:1 in light. What tells a reader the box is ticked is
            // the mark being there at all, which is why its absence is the other case's whole
            // content rather than a colour set to clear.
            #expect(
                BoardPickerList.tick(true, scheme) != BoardPickerList.tick(false, scheme),
                "\(scheme)"
            )
        }
    }

    /// The WCAG 2.1 contrast ratio between two of this app's tokens, one drawn on the other.
    ///
    /// Resolved through SwiftUI rather than restated here, so the numbers come from the same values
    /// the view is handed.
    ///
    /// **The blend is done in the encoded space and not the linear one, and the difference is not
    /// academic.** `Color.Resolved` reports both; a translucent ink composited over its ground in
    /// linear space puts `inkFaint`'s boundary at 2.48:1 and in the encoded space at 4.78:1, and
    /// the encoded one is what a reader sees — Core Graphics blends in the destination's own space,
    /// which here is sRGB. Measuring in the other one would fail this control for a darkness it
    /// does not have on screen. The linearisation below is then WCAG's own, applied once, after
    /// the composite rather than before it.
    private static func contrast(_ ink: Color, on ground: Color, _ scheme: ColorScheme) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let over = ground.resolve(in: environment)
        let on = ink.resolve(in: environment)
        let alpha = Double(on.opacity)
        func blended(_ front: Float, _ back: Float) -> Double {
            Double(front) * alpha + Double(back) * (1 - alpha)
        }
        let first = Self.luminance(
            blended(on.red, over.red),
            blended(on.green, over.green),
            blended(on.blue, over.blue)
        )
        let second = Self.luminance(Double(over.red), Double(over.green), Double(over.blue))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG 2.1 relative luminance, from sRGB components as they are encoded.
    private static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
