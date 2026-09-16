import Foundation
import Testing

@testable import FediqoCore

/// Adding a forum: what the reader's button actually calls, and what it does with each answer.
///
/// **No captured page is read here any more, and that is a loss as well as a decision.** Every
/// fixture this file used to fetch was a byte-exact capture of a running forum, and what those
/// captures carried beyond their shape — "this really is what that server sends" — is gone with
/// them and cannot be restored by anything written below. What each literal here can still prove
/// is that the join makes the right decision about the shape it is given; what none of them can
/// prove any more is that the shape is the one a forum sends.
///
/// What replaces them is the rule this branch settled on: **one property, one literal, written in
/// the test that pins it.** A join that only has to succeed or fail gets the smallest page that
/// succeeds or fails; only the tests that are about an index's structure carry an index's shape.
/// The duplication between them is the intended cost of not having one author's idea of a forum
/// standing in for four installs.
///
/// Hosts are codenames for what they are rather than names of anybody's server — the table is in
/// `Sources/FediqoCore/Discuz.swift`. The measurements those installs produced are kept, because
/// they are what make the rules arguable.
@Suite("Forum join")
struct ForumJoinTests {
    private static func joiner(_ http: FixtureHTTP, _ store: ItemStore) -> SourceJoin {
        SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
    }

    /// A host that answers `/` with one page and `/forum.php` with another.
    ///
    /// Routing only — every byte of both pages comes from the test that cares about them.
    private static func discuzHTTP(front: String, forum: FixtureHTTP.Outcome) -> FixtureHTTP {
        FixtureHTTP(["/": .text(front), "/forum.php": forum])
    }

    /// A forum whose index and whose boards are all reachable, each at its own address.
    ///
    /// Routed by whole address rather than by path, because a Discuz!'s index and every one of
    /// its boards are the same path — `/forum.php` — and telling them apart is the query.
    private static func boardHTTP(
        host: String,
        front: String,
        index: FixtureHTTP.Outcome,
        boards: [Int: FixtureHTTP.Outcome] = [:]
    ) -> FixtureHTTP {
        var routes: [String: FixtureHTTP.Outcome] = [
            "/": .text(front),
            "https://\(host)/forum.php": index,
        ]
        for (fid, outcome) in boards {
            routes["https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)"] = outcome
        }
        return FixtureHTTP(routes)
    }

    @Test("A forum is detected, read, and added with its topics in the store")
    func aForumJoins() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
        """#
        // `/latest.json`'s shape, and only its shape: the topics, the handful of people who
        // wrote in them, and each topic's section by number.
        let latest = #"""
        {
          "users": [
            { "id": 11, "username": "ada", "name": "Ada Nolan",
              "avatar_template": "/user_avatar/install-f.example/ada/{size}/11_2.png" },
            { "id": 12, "username": "bram", "name": "Bram Ohlsen",
              "avatar_template": "/user_avatar/install-f.example/bram/{size}/12_2.png" }
          ],
          "topic_list": {
            "topics": [
              { "id": 101, "title": "A sentinel nobody can document", "slug": "a-sentinel",
                "created_at": "2026-09-14T09:00:00.000Z",
                "bumped_at": "2026-09-15T11:00:00.000Z",
                "posts_count": 3, "reply_count": 2, "like_count": 4, "category_id": 6,
                "posters": [ { "user_id": 11, "description": "Original Poster" },
                             { "user_id": 12, "description": "Most Recent Poster" } ] },
              { "id": 102, "title": "Why does this import take four seconds", "slug": "slow-import",
                "created_at": "2026-09-13T08:30:00.000Z",
                "bumped_at": "2026-09-15T09:00:00.000Z",
                "posts_count": 5, "reply_count": 4, "like_count": 1, "category_id": 7,
                "posters": [ { "user_id": 12, "description": "Original Poster" } ] },
              { "id": 103, "title": "Reading a file in a loop", "slug": "reading-a-file",
                "created_at": "2026-09-12T12:00:00.000Z",
                "bumped_at": "2026-09-14T12:00:00.000Z",
                "posts_count": 1, "reply_count": 0, "like_count": 0, "category_id": 7,
                "posters": [ { "user_id": 11, "description": "Original Poster" } ] }
            ]
          }
        }
        """#
        let site = #"""
        { "categories": [ { "id": 6, "name": "Ideas" }, { "id": 7, "name": "Help" } ] }
        """#
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(front),
            "/latest.json": .text(latest),
            "/site.json": .text(site),
        ])
        try await Self.joiner(http, store).join(host: "install-f.example")

        let sources = await store.sources()
        #expect(sources.map(\.host) == ["install-f.example"])
        // The source carries what the host actually speaks, because that is what decides the
        // shape of the row — a forum is drawn as a thread, a microblog as a note.
        #expect(sources.first?.kind == .discourse)

        let notes = await store.all()
        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
        // A topic names its section by number; `/site.json` is what turns that into a word.
        #expect(notes.contains { $0.board == "Ideas" })
    }

    @Test("The host is asked what it speaks once, not once per protocol")
    func theHostIsAskedOnce() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
        """#
        let latest = #"""
        {
          "users": [ { "id": 11, "username": "ada", "name": "Ada Nolan" } ],
          "topic_list": {
            "topics": [
              { "id": 101, "title": "One topic is enough to count requests by",
                "slug": "one-topic", "created_at": "2026-09-14T09:00:00.000Z",
                "posts_count": 1, "reply_count": 0, "category_id": 6,
                "posters": [ { "user_id": 11, "description": "Original Poster" } ] }
            ]
          }
        }
        """#
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(front),
            "/latest.json": .text(latest),
            "/site.json": .text(#"{ "categories": [ { "id": 6, "name": "Ideas" } ] }"#),
        ])
        try await Self.joiner(http, store).join(host: "install-f.example")

        // The front page is read once for the detector and never again. A dispatcher that let
        // each protocol re-detect would double this against every server, for nothing.
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
        #expect(await Set(http.paths) == ["/", "/latest.json", "/site.json"])
    }

    @Test("A forum that answers the detector and then refuses is not left behind as a source")
    func aRefusedForumIsNotAdded() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
        """#
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(front),
            "/latest.json": .text("<html>checking your browser</html>", status: 403),
            "/site.json": .text(#"{ "categories": [] }"#),
        ])

        await #expect(throws: JoinError.refused(403)) {
            try await Self.joiner(http, store).join(host: "install-f.example")
        }

        // Nothing added. A source in the list whose timeline can never load is worse than a
        // failed join: the reader has to work out for themselves why one of their servers is
        // permanently blank.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("A refusal is its own message, never confused with a host that is not a forum")
    func aRefusalIsToldApart() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
        """#
        for status in [401, 403, 429, 503] {
            let store = ItemStore()
            let http = FixtureHTTP([
                "/": .text(front),
                "/latest.json": .text("", status: status),
                "/site.json": .text(#"{ "categories": [] }"#),
            ])
            await #expect(throws: JoinError.refused(status)) {
                try await Self.joiner(http, store).join(host: "install-f.example")
            }
        }

        // 404 is a host that does not serve a front page, which is a different sentence to a
        // reader: check the address, rather than "that server turned us away".
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(front),
            "/latest.json": .text("", status: 404),
            "/site.json": .text(#"{ "categories": [] }"#),
        ])
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await Self.joiner(http, store).join(host: "install-f.example")
        }
    }

    // MARK: - The other forum

    @Test("A Discuz! forum is detected, read, and added with its threads in the store")
    func aDiscuzForumJoins() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        // The guide page's own shape — a cross-board listing, so each row names its own board in
        // a `td.by` with no `<cite>` in it.
        let guide = #"""
        <h1 class="xs2">最新发表</h1>
        <table cellspacing="0" cellpadding="0">
        <tbody id="normalthread_310401">
        <tr>
        <td class="icn"><a href="thread-310401-1-1.html"><img src="static/image/common/folder_common.gif" /></a></td>
        <th class="common"><a href="thread-310401-1-1.html" class="xst">A kettle that outlived three kitchens</a></th>
        <td class="by"><a href="forum-80-1.html">闲谈区</a></td>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 19:48">1&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-310401-1-1.html" class="xi2">1</a><em>3</em></td>
        <td class="by"><cite><a href="space-uid-2.html">林向北</a></cite><em><span title="2026-9-15 20:48">半小时前</span></em></td>
        </tr>
        </tbody>
        <tbody id="normalthread_620793">
        <tr>
        <td class="icn"><a href="thread-620793-1-1.html"><img src="static/image/common/folder_common.gif" /></a></td>
        <th class="common"><a href="thread-620793-1-1.html" class="xst">A one-cent extension lead, posted free</a></th>
        <td class="by"><a href="forum-81-1.html">器材区</a></td>
        <td class="by"><cite><a href="space-uid-2.html">林向北</a></cite><em><span title="2026-9-15 18:10">3&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-620793-1-1.html" class="xi2">7</a><em>512</em></td>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 20:02">1&nbsp;小时前</span></em></td>
        </tr>
        </tbody>
        </table>
        """#
        let store = ItemStore()
        let http = Self.discuzHTTP(front: front, forum: .text(guide))
        try await Self.joiner(http, store).join(host: "install-a.example")

        let sources = await store.sources()
        #expect(sources.map(\.host) == ["install-a.example"])
        // The source carries what the host actually speaks. A Discuz! and a Discourse are both
        // forums and are not the same program; the row is drawn from the kind.
        #expect(sources.first?.kind == .discuz)

        let notes = await store.all()
        // Every row on the page became a note, and none of them arrived without a name.
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
        #expect(notes.contains { $0.board == "闲谈区" })

        // The front page is read once for the detector, and the guide page once for the threads.
        #expect(await Set(http.paths) == ["/", "/forum.php"])
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
    }

    @Test("A challenge page is a refusal, and leaves no source behind that draws nothing")
    func aChallengedForumIsNotAdded() async throws {
        // The whole reason the page is read *before* the source is added. A forum that detects
        // perfectly and then hands back a filter's challenge would otherwise sit in the reader's
        // list forever, permanently blank, with nothing anywhere saying why.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        // A filter's interstitial, carrying the four markers `DiscuzPage.isChallenge` looks for
        // and nothing else: no token, no ray id, no zone, and nothing naming anybody's server.
        let challenge = #"""
        <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
        <meta http-equiv="content-security-policy" content="frame-src https://challenges.cloudflare.com">
        </head><body>
        <noscript><div class="h2"><span id="challenge-error-text">Enable JavaScript and cookies to continue</span></div></noscript>
        <script>window._cf_chl_opt = {};var a = document.createElement('script');
        a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1';
        document.getElementsByTagName('head')[0].appendChild(a);</script>
        </body></html>
        """#
        for status in [200, 403] {
            let store = ItemStore()
            let http = Self.discuzHTTP(front: front, forum: .text(challenge, status: status))

            // 403 whatever status it arrived with: a challenge dressed as a 200 reported as a
            // 200 would tell the reader that it worked.
            await #expect(throws: JoinError.refused(403)) {
                try await Self.joiner(http, store).join(host: "challenge.example")
            }
            #expect(await store.sources().isEmpty)
            #expect(await store.all().isEmpty)
        }
    }

    @Test("The forum's own notice page is a refusal too, and is not a spelling mistake")
    func aRestrictedForumIsNotAdded() async throws {
        // `install-e.example` answers a signed-out reader with one of these on every board. The
        // host is fine and so is the address; an account is what would change the answer, which
        // is exactly what `refused` means and `publicTimelineFailed` does not.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        // Discuz!'s own notice page: a 200, real forum markup, no thread table, and the one
        // container every version puts its one-line answer in.
        let notice = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /><title>提示信息</title></head>
        <body><div id="ct" class="ct1 wp cl"><div class="mn"><div class="nfl">
        <div id="messagetext" class="alert_info">
        <p>You do not have permission to read this board.</p>
        </div>
        </div></div></div></body></html>
        """#
        let store = ItemStore()
        let http = Self.discuzHTTP(front: front, forum: .text(notice))
        await #expect(throws: JoinError.refused(403)) {
            try await Self.joiner(http, store).join(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A forum that shows this reader no threads is a failed join, not an empty one")
    func anEmptyForumIsNotAdded() async throws {
        // Measured on `install-e.example`: a real, complete guide page whose thread table is
        // empty, because a signed-out reader may read no board there at all.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        let guide = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /><title>导读-最新回复</title></head>
        <body>
        <div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm">A forum</a></div></div>
        <h1 class="xs2">最新回复</h1>
        <table cellspacing="0" cellpadding="0">
        </table>
        </body></html>
        """#
        let store = ItemStore()
        let http = Self.discuzHTTP(front: front, forum: .text(guide))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await Self.joiner(http, store).join(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("A Discuz! refusal keeps its own number, and a 404 stays a 404")
    func aDiscuzRefusalIsToldApart() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        for status in [401, 403, 429, 503] {
            let store = ItemStore()
            let http = Self.discuzHTTP(front: front, forum: .text("<html>no</html>", status: status))
            await #expect(throws: JoinError.refused(status)) {
                try await Self.joiner(http, store).join(host: "install-a.example")
            }
            #expect(await store.sources().isEmpty)
        }

        let store = ItemStore()
        let http = Self.discuzHTTP(front: front, forum: .text("", status: 404))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await Self.joiner(http, store).join(host: "install-a.example")
        }
    }

    @Test("A forum that cannot be reached at all is not reported as a refusal")
    func anUnreachableDiscuzIsUnreachable() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        let store = ItemStore()
        let http = Self.discuzHTTP(front: front, forum: .fail)
        await #expect(throws: JoinError.unreachable) {
            try await Self.joiner(http, store).join(host: "install-a.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - A join that pauses so the reader can choose

    @Test("A forum join pauses with the boards in hand, and nothing added")
    func aForumJoinPauses() async throws {
        // D28: `join(host:)` means "returns when the source is added and its timeline is in the
        // store", and a forum cannot honour that — the reader has to choose before there is a
        // timeline to fetch at all. So this stops, hands back the index, and adds nothing.
        //
        // The grid index three of the four measured installs write: a category is an `<h2>`
        // carrying `gid=N` and a `<div id="category_N">`, and each board is a `<dl>` inside it.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56" class="bm_c">
        <table cellspacing="0" cellpadding="0" class="fl_tb">
        <tr>
        <td class="fl_g">
        <div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&fid=33" title="Boot disks"><img src="icon.png" /></a></div>
        <dl>
        <dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt>
        <dd><em>主题: 4207</em>, <em>帖数: <span title="60318">6万</span></em></dd>
        <dd><a href="forum.php?mod=redirect&amp;tid=421714&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 16:02">6&nbsp;小时前</span></a></dd>
        </dl>
        </td>
        <td class="fl_g">
        <div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&fid=40" title="Imaging tools"><img src="icon.png" /></a></div>
        <dl>
        <dt><a href="forum.php?mod=forumdisplay&fid=40">Imaging tools</a></dt>
        <dd><em>主题: 2227</em>, <em>帖数: 42372</em></dd>
        <dd><a href="forum.php?mod=redirect&amp;tid=421800&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 07:42">15&nbsp;小时前</span></a></dd>
        </dl>
        </td>
        </tr>
        </table>
        </div>
        <h2><a href="forum.php?gid=57">Everyday systems</a></h2>
        <div id="category_57" class="bm_c">
        <table cellspacing="0" cellpadding="0" class="fl_tb">
        <tr>
        <td class="fl_g">
        <dl>
        <dt><a href="forum.php?mod=forumdisplay&fid=41">Linux</a></dt>
        <dd><em>主题: 1624</em>, <em>帖数: <span title="35336">3万</span></em></dd>
        <dd><a href="forum.php?mod=redirect&amp;tid=453470&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 22:01">半小时前</span></a></dd>
        </dl>
        </td>
        <td class="fl_g">
        <dl>
        <dt><a href="forum.php?mod=forumdisplay&fid=73">Apple systems</a></dt>
        <dd><em>主题: 202</em>, <em>帖数: 2417</em></dd>
        <dd><a href="forum.php?mod=redirect&amp;tid=451656&amp;goto=lastpost#lastpost">最后发表: <span title="2026-9-15 00:07">22&nbsp;小时前</span></a></dd>
        </dl>
        </td>
        </tr>
        </table>
        </div>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(host: "install-c.example", front: front, index: .text(index))
        let step = try await Self.joiner(http, store).begin(host: "install-c.example")

        guard case .chooseBoards(let offer) = step else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }
        #expect(offer.host == "install-c.example")
        #expect(offer.kind == .discuz)
        #expect(offer.categories.map(\.name) == ["Tools and software", "Everyday systems"])
        #expect(offer.boards.count == 4)
        #expect(offer.boards.map(\.fid) == [33, 40, 41, 73])

        // **Nothing is added until they pick** — the same rule the existing joins follow, for the
        // same reason: a source in the list whose timeline can never load is worse than a failed
        // join, and until the reader has chosen there is nothing for its timeline to be.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("The offer hands the picker sub-boards in order, with a depth to indent by")
    func theOfferCarriesSubBoardsInOrder() async throws {
        // D29, at the door the picker actually reads. `JoinOffer.boards` is the flat list a sheet
        // draws one row at a time, so the nesting has to survive the flattening: a child directly
        // after its parent, and a `depth` to indent it by. It does, because each board is placed
        // by where its own anchor is on the page rather than by which container it sat in.
        //
        // The wide `list` layout, which is where sub-boards were measured: one board to a `<tr>`,
        // its name in an `<h2>`, and its children written as bare links in its own cell. The
        // parent's icon cell links to the parent and holds a picture, which is what the rule's
        // two guards — not this board's own number, and an anchor with something to read — are
        // there to refuse. The last-post cell's two anchors are there for the other half of it:
        // a thread redirect and a person's profile are anchors in the same cell that yield no
        // board number, and neither may arrive in the picker as a board somebody can subscribe
        // to.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=296">Official</a></h2>
        <div id="category_296">
        <table cellspacing="0" cellpadding="0" class="fl_tb">
        <tr>
        <td class="fl_icn"><a href="forum-297-1.html"><img src="common_297_icon.png" alt="" /></a></td>
        <td>
        <h2><a href="forum-297-1.html">Editors and tools</a></h2>
        <p class="xg2">The software this forum writes itself</p>
        <p>子版块: <a href="forum-300-1.html">Keyboard</a>, <a href="forum-302-1.html">Cleaner</a>, <a href="forum-298-1.html">MiniBrowser</a>, <a href="forum-305-1.html">Converter</a></p>
        </td>
        <td class="fl_i"><span class="xi2">370</span><span class="xg1"> / 6414</span></td>
        <td class="fl_by"><div><a href="forum.php?mod=redirect&amp;tid=700014&amp;goto=lastpost#lastpost" class="xi2">The keyboard ate a word</a> <cite>2026-3-15 13:25 <a href="space-username-muyu.html">muyu</a></cite></div></td>
        </tr>
        </table>
        </div>
        <h2><a href="forum.php?gid=43">News</a></h2>
        <div id="category_43">
        <table cellspacing="0" cellpadding="0" class="fl_tb">
        <tr>
        <td class="fl_icn"><a href="forum-15-1.html"><img src="common_15_icon.png" alt="" /></a></td>
        <td>
        <h2><a href="forum-15-1.html">Headlines</a><em class="xw0 xi1" title="今日"> (24)</em></h2>
        <p>子版块: <a href="forum-238-1.html">Archive</a></p>
        </td>
        <td class="fl_i"><span class="xi2"><span title="70158">7万</span></span><span class="xg1"> / <span title="900462">90万</span></span></td>
        <td class="fl_by"><div><cite><span title="2026-9-15 22:42">8&nbsp;分钟前</span></cite></div></td>
        </tr>
        </table>
        </div>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(host: "install-d.example", front: front, index: .text(index))
        guard case .chooseBoards(let offer) = try await Self.joiner(http, store)
            .begin(host: "install-d.example")
        else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }

        #expect(
            offer.boards.map { String(repeating: "  ", count: $0.depth) + $0.name } == [
                "Editors and tools",
                "  Keyboard", "  Cleaner", "  MiniBrowser", "  Converter",
                "Headlines",
                "  Archive",
            ]
        )
        // And each of them is a pick in its own right, because each is its own `fid`.
        #expect(Set(offer.boards.map(\.fid)).count == offer.boards.count)
        // The nesting itself, and not merely the indent it is drawn with: a child names the
        // board it sits under, and a board the index named in its own right names nobody.
        #expect(offer.boards.map(\.depth) == [0, 1, 1, 1, 1, 0, 1])
        #expect(offer.boards.map(\.parent) == [nil, 297, 297, 297, 297, nil, 15])
        #expect(await store.sources().isEmpty)
    }

    @Test("A forum served in GBK is read, not reported as an unreadable host")
    func aGBKIndexIsRead() async throws {
        // Discuz! predates the UTF-8 default and a great many running installs still serve GBK —
        // `install-d.example` answers `Content-Type: text/html; charset=gbk` today. GBK bytes are
        // not valid UTF-8, so a client that only tried UTF-8 would call the whole forum
        // unreadable rather than pause with its boards in hand.
        //
        // **The bytes are assembled rather than encoded from a Swift string**, so what the client
        // is handed here is genuinely not UTF-8 and the decode is a real one. ASCII is the same
        // byte in GBK, so only the names need spelling out.
        func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
        let category: [UInt8] = [0xD7, 0xCA, 0xD1, 0xB6, 0xC7, 0xF8]  // 资讯区
        let board: [UInt8] = [0xB9, 0xD9, 0xB7, 0xBD, 0xC8, 0xED, 0xBC, 0xFE, 0xC7, 0xF8]  // 官方软件区

        var bytes: [UInt8] = []
        bytes += ascii(#"<html><head><meta http-equiv="Content-Type" content="text/html; charset=gbk" /></head><body>"#)
        bytes += ascii(#"<h2><a href="forum.php?gid=296">"#)
        bytes += category
        bytes += ascii("</a></h2>")
        bytes += ascii(#"<div id="category_296"><table class="fl_tb"><tr>"#)
        bytes += ascii(#"<td><h2><a href="forum-297-1.html">"#)
        bytes += board
        bytes += ascii("</a></h2></td>")
        bytes += ascii(#"<td class="fl_i"><span class="xi2">370</span><span class="xg1"> / 6414</span></td>"#)
        bytes += ascii("</tr></table></div></body></html>")

        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-d.example", front: front, index: .body(Data(bytes))
        )
        guard case .chooseBoards(let offer) = try await Self.joiner(http, store)
            .begin(host: "install-d.example")
        else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }
        #expect(offer.categories.map(\.name) == ["资讯区"])
        #expect(offer.boards.map(\.name) == ["官方软件区"])
        #expect(offer.boards.map(\.fid) == [297])
    }

    @Test("The reader picks, and one source carries every board they chose")
    func theReaderPicksAndOneSourceCarriesThem() async throws {
        // D26: one `Source` per host with a set of subscribed boards, never one source per board.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt>
        <dd><em>主题: 4207</em>, <em>帖数: 60318</em></dd></dl></td>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=41">Linux</a></dt>
        <dd><em>主题: 1624</em>, <em>帖数: 35336</em></dd></dl></td>
        </tr></table>
        </div>
        """#
        let board = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></h1>
        <table cellspacing="0" cellpadding="0">
        <tbody id="normalthread_451039">
        <tr>
        <td class="icn"><a href="thread-451039-1-1.html"><img src="folder_common.gif" /></a></td>
        <th class="new"><a href="thread-451039-1-1.html" class="s xst">A rescue stick that boots on anything</a></th>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 08:12">7&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-451039-1-1.html" class="xi2">29</a><em>3480</em></td>
        <td class="by"><cite><a href="space-uid-2.html">林向北</a></cite><em><span title="2026-9-15 20:48">半小时前</span></em></td>
        </tr>
        </tbody>
        </table>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-c.example",
            front: front,
            index: .text(index),
            boards: [33: .text(board), 41: .text(board)]
        )
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let picks = offer.boards.filter { [33, 41].contains($0.fid) }
        let outcome = try await join.subscribe(offer, to: picks)

        #expect(outcome.subscribed.map(\.fid) == [33, 41])
        #expect(outcome.unread.isEmpty)

        let sources = await store.sources()
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.host == "install-c.example")
        #expect(source.kind == .discuz)
        #expect(source.boards.map(\.fid) == [33, 41])
        #expect(source.boards.map(\.name) == ["Boot disks", "Linux"])
        #expect(source.subscribes(to: 33))
        #expect(!source.subscribes(to: 99))
        #expect(await store.all().isEmpty == false)
    }

    @Test("The host is asked what it speaks once, across both halves of the conversation")
    func theHostIsAskedOnceAcrossThePause() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt>
        <dd><em>主题: 4207</em></dd></dl></td>
        </tr></table>
        </div>
        """#
        let board = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></h1>
        <table>
        <tbody id="normalthread_451039">
        <tr>
        <th class="new"><a href="thread-451039-1-1.html" class="s xst">A rescue stick that boots on anything</a></th>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 08:12">7&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-451039-1-1.html" class="xi2">29</a><em>3480</em></td>
        </tr>
        </tbody>
        </table>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-c.example", front: front, index: .text(index),
            boards: [33: .text(board)]
        )
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })

        // The detection travelled in the offer. A second half that asked again would double
        // every join's traffic against a server that did nothing to deserve it.
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
    }

    @Test("A board that cannot be read is not subscribed to, and is named")
    func aBoardThatCannotBeReadIsNotSubscribedTo() async throws {
        // `install-a.example` board 37 is the live case: a real, busy board whose per-board
        // display style is Discuz!'s picture mode, so a signed-out reader is served an empty
        // thread table and a wall of cards with no dates on them. Subscribing to it would put a
        // permanently blank query in the rail — the same failure `refused` guards against one
        // level up.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=40">Imaging tools</a></dt></dl></td>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=37">Virtual machines</a></dt></dl></td>
        </tr></table>
        </div>
        """#
        let reads = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></h1>
        <table>
        <tbody id="normalthread_451039">
        <tr>
        <th class="new"><a href="thread-451039-1-1.html" class="s xst">A rescue stick that boots on anything</a></th>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 08:12">7&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-451039-1-1.html" class="xi2">29</a><em>3480</em></td>
        </tr>
        </tbody>
        </table>
        """#
        // A real board page whose thread table is empty: nothing to read, and no reason given.
        let nothingToRead = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=40">Imaging tools</a></h1>
        <table cellspacing="0" cellpadding="0">
        </table>
        """#
        // The forum's own notice page: somebody said no, on purpose.
        let turnedAway = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <div id="messagetext" class="alert_info"><p>You do not have permission to read this board.</p></div>
        </body></html>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-c.example",
            front: front,
            index: .text(index),
            boards: [
                33: .text(reads),
                40: .text(nothingToRead),
                37: .text(turnedAway),
            ]
        )
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let outcome = try await join.subscribe(
            offer, to: offer.boards.filter { [33, 40, 37].contains($0.fid) })

        #expect(outcome.subscribed.map(\.fid) == [33])
        #expect(outcome.unread.map(\.board.fid) == [40, 37])
        // Each carries its own reason, so what the reader is told about one is not what they are
        // told about the other: nothing to read, against being turned away.
        #expect(outcome.unread.map(\.error) == [.publicTimelineFailed, .refused(403)])
        #expect(await store.sources().first?.boards.map(\.fid) == [33])
    }

    @Test("A pick where nothing read leaves nothing behind, and says why")
    func nothingReadAddsNothing() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
        </tr></table>
        </div>
        """#
        let challenge = #"""
        <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head><body>
        <noscript><div class="h2"><span id="challenge-error-text">Enable JavaScript and cookies to continue</span></div></noscript>
        <script>window._cf_chl_opt = {};</script>
        </body></html>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-c.example", front: front, index: .text(index),
            boards: [33: .text(challenge)]
        )
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        await #expect(throws: JoinError.refused(403)) {
            try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("Picking nothing is not a failure, and is not a source either")
    func anEmptyPickIsNotAFailure() async throws {
        // A reader who opened the picker and closed it again has not failed at anything, so
        // there is no error for it. There is also no source, which is the half that matters.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
        </tr></table>
        </div>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(host: "install-c.example", front: front, index: .text(index))
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let outcome = try await join.subscribe(offer, to: [])
        #expect(outcome.subscribed.isEmpty)
        #expect(outcome.unread.isEmpty)
        #expect(await store.sources().isEmpty)
    }

    @Test("Picking again replaces the subscription rather than adding a second server")
    func pickingAgainReplacesTheSubscription() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=41">Linux</a></dt></dl></td>
        </tr></table>
        </div>
        """#
        let board = #"""
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></h1>
        <table>
        <tbody id="normalthread_451039">
        <tr>
        <th class="new"><a href="thread-451039-1-1.html" class="s xst">A rescue stick that boots on anything</a></th>
        <td class="by"><cite><a href="space-uid-1.html">程小雨</a></cite><em><span title="2026-9-15 08:12">7&nbsp;小时前</span></em></td>
        <td class="num"><a href="thread-451039-1-1.html" class="xi2">29</a><em>3480</em></td>
        </tr>
        </tbody>
        </table>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-c.example",
            front: front,
            index: .text(index),
            boards: [33: .text(board), 41: .text(board)]
        )
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })
        try await join.subscribe(offer, to: offer.boards.filter { [33, 41].contains($0.fid) })

        // One host, one source — and the newest statement of what the reader subscribed to.
        #expect(await store.sources().count == 1)
        #expect(await store.sources().first?.boards.map(\.fid) == [33, 41])
    }

    @Test("A forum whose index has no board for this reader is a refusal, not a spelling mistake")
    func anIndexWithNoBoardsIsARefusal() async throws {
        // `install-e.example` serves an unchallenged, ordinary index with no forum list on it at
        // all. The host is fine, the address is fine, and an account is what would change the
        // answer — which is what `refused` means and what `publicTimelineFailed` does not.
        //
        // The only board-ish block on it is hand-written: an `id="category_-99999"` of campus
        // links under a heading that is not a category's. Both halves of the rule fail on it —
        // the id is not a number, and the heading carries no `gid` — which is exactly why the
        // rule wants both.
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
        """#
        let index = #"""
        <html><head><meta name="generator" content="Discuz! X3.4" /></head>
        <body><div class="mn"><div class="fl bm">
        <div class="bm bmw cl">
        <div class="bm_h cl"><h2><a href="#">校园服务</a></h2></div>
        <div id="category_-99999" class="bm_c">
        <table cellspacing="0" cellpadding="0" class="fl_tb">
        <tr class="fl_row">
        <td class="fl_g"><a href="forum.php?mod=forumdisplay&amp;fid=305" target="_blank">失物招领</a></td>
        <td class="fl_g"><a href="/calendar" target="_blank">校历</a></td>
        </tr>
        </table>
        </div>
        </div>
        </div></div></body></html>
        """#
        let store = ItemStore()
        let http = Self.boardHTTP(host: "install-e.example", front: front, index: .text(index))
        await #expect(throws: JoinError.refused(403)) {
            _ = try await Self.joiner(http, store).begin(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Everything that is not a forum with boards still joins in one step")
    func everythingElseStillJoinsInOneStep() async throws {
        let store = ItemStore()
        let discourseFront = #"""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head><body></body></html>
        """#
        let latest = #"""
        {
          "users": [ { "id": 11, "username": "ada", "name": "Ada Nolan" } ],
          "topic_list": {
            "topics": [
              { "id": 101, "title": "A forum with no boards to choose between",
                "slug": "no-boards", "created_at": "2026-09-14T09:00:00.000Z",
                "posts_count": 1, "reply_count": 0, "category_id": 6,
                "posters": [ { "user_id": 11, "description": "Original Poster" } ] }
            ]
          }
        }
        """#
        let discourse = try await Self.joiner(
            FixtureHTTP([
                "/": .text(discourseFront),
                "/latest.json": .text(latest),
                "/site.json": .text(#"{ "categories": [ { "id": 6, "name": "Ideas" } ] }"#),
            ]),
            store
        ).begin(host: "install-f.example")
        #expect(discourse == .joined)
        #expect(await store.sources().map(\.kind) == [.discourse])
        // And it carries no boards, because a Discourse has no such idea.
        #expect(await store.sources().first?.boards.isEmpty == true)

        let microblog = ItemStore()
        let mastodonFront = #"""
        <html><head><meta name="application-name" content="Mastodon" /></head><body></body></html>
        """#
        let timeline = #"""
        [
          {
            "id": "1",
            "uri": "https://first.example/users/ada/statuses/1",
            "created_at": "2026-09-15T10:00:00.000Z",
            "content": "<p>A note, not a thread.</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada Nolan" }
          }
        ]
        """#
        let step = try await Self.joiner(
            FixtureHTTP([
                "/": .text(mastodonFront),
                "/api/v1/timelines/public": .text(timeline),
                "/api/v1/trends/statuses": .text("[]"),
            ]),
            microblog
        ).begin(host: "first.example")
        #expect(step == .joined)
        #expect(await microblog.sources().map(\.kind) == [.mastodon])

        // A host that speaks neither is refused by name through this door too.
        let neither = ItemStore()
        let pleroma = #"""
        <html><head><meta name="generator" content="Pleroma" /></head><body></body></html>
        """#
        let http = FixtureHTTP(["/": .text(pleroma)])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            _ = try await Self.joiner(http, neither).begin(host: "pleroma.example")
        }
    }

    @Test("Subscribing against a kind that has no boards is refused by name")
    func subscribingToSomethingWithNoBoardsIsRefused() async throws {
        // Refused from the offer alone. The routes are empty on purpose: a dispatcher that asked
        // the server anything before noticing that a Discourse has no boards would have to reach
        // one of them, and none of them is there.
        let store = ItemStore()
        let http = FixtureHTTP([:])
        let offer = JoinOffer(host: "install-f.example", kind: .discourse, categories: [])
        await #expect(throws: JoinError.unsupportedKind(.discourse)) {
            try await Self.joiner(http, store).subscribe(offer, to: [])
        }
        #expect(await store.sources().isEmpty)
        #expect(await http.paths.isEmpty)
    }

    @Test("A microblog still joins through the same door, and still gets its catalogue")
    func aMicroblogStillJoins() async throws {
        let front = #"""
        <html><head><meta name="application-name" content="Mastodon" /></head><body></body></html>
        """#
        let timeline = #"""
        [
          {
            "id": "1",
            "uri": "https://first.example/users/ada/statuses/1",
            "created_at": "2026-09-15T10:00:00.000Z",
            "content": "<p>A note, not a thread.</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada Nolan" }
          }
        ]
        """#
        let store = ItemStore()
        let catalogues = EmojiCatalogueStore()
        let http = FixtureHTTP([
            "/": .text(front),
            "/api/v1/timelines/public": .text(timeline),
            "/api/v1/trends/statuses": .text("[]"),
            "/api/v1/custom_emojis": .text("[]"),
        ])
        try await SourceJoin(http: http, store: store, catalogues: catalogues)
            .join(host: "first.example")

        #expect(await store.sources().map(\.kind) == [.mastodon])
        #expect(await store.all().isEmpty == false)
    }

    @Test("A host that speaks neither is refused by name")
    func anUnsupportedHostIsRefusedByName() async throws {
        let front = #"""
        <html><head><meta name="generator" content="Pleroma" /></head><body></body></html>
        """#
        let store = ItemStore()
        let http = FixtureHTTP(["/": .text(front)])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            try await Self.joiner(http, store).join(host: "pleroma.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - A host behind a filter

    @Test("A challenge at the front door is a refusal, not an unknown protocol")
    func aChallengedHostIsRefusedNotUnknown() async throws {
        // The live case this exists for: `challenge.example` answers a challenge page to every
        // path, including `/robots.txt`. A challenge names no software, so every marker
        // `HTMLKind.classify` looks for is absent and the detector used to fall through to
        // `.unknown` — which tells the reader to check their spelling for a host whose spelling
        // is fine, and closes the only door that opens: a sign-in is offered on a refusal and on
        // nothing else.
        let challenge = #"""
        <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
        <meta http-equiv="content-security-policy" content="frame-src https://challenges.cloudflare.com">
        </head><body>
        <noscript><div class="h2"><span id="challenge-error-text">Enable JavaScript and cookies to continue</span></div></noscript>
        <script>window._cf_chl_opt = {};var a = document.createElement('script');
        a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1';
        document.getElementsByTagName('head')[0].appendChild(a);</script>
        </body></html>
        """#
        let store = ItemStore()
        let http = FixtureHTTP(["/": .text(challenge, status: 403)])

        await #expect(throws: JoinError.refused(403)) {
            try await Self.joiner(http, store).join(host: "challenge.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A challenge dressed as a 200 is still a refusal")
    func aChallengeAt200IsStillARefusal() async throws {
        // A managed filter serves the interstitial at 403 on some paths and 200 on others.
        // Reporting the literal status would tell the reader a challenge had worked.
        let challenge = #"""
        <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head><body>
        <noscript><div class="h2"><span id="challenge-error-text">Enable JavaScript and cookies to continue</span></div></noscript>
        <script>window._cf_chl_opt = {};
        var a = document.createElement('script');
        a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1';</script>
        </body></html>
        """#
        let store = ItemStore()
        let http = FixtureHTTP(["/": .text(challenge)])
        await #expect(throws: JoinError.refused(403)) {
            try await Self.joiner(http, store).join(host: "challenge.example")
        }
    }

    @Test("A forum that names itself is named, even from behind a filter")
    func softwareMarkersWinOverTheFilter() async throws {
        // The ordering that matters: a forum merely *sitting behind* a filter still serves its
        // own front page most of the time, and naming itself is a better answer than naming its
        // filter. The challenge judgement is only reached when the page named nothing — so a
        // page carrying **both** the forum's own generator tag and a filter's markers is named
        // for the forum, and never reported as a challenge.
        let page = #"""
        <html><head>
        <meta name="generator" content="Discuz! X3.4" />
        <title>Just a moment...</title>
        </head><body>
        <noscript><span id="challenge-error-text">Enable JavaScript and cookies to continue</span></noscript>
        <script>window._cf_chl_opt = {};</script>
        </body></html>
        """#
        let http = FixtureHTTP(["/": .text(page)])
        #expect(try await Detector(http: http).detect("install-a.example") == .discuz)
    }
}
