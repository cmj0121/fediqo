import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// `r` (#29): what is in front is asked for again, from exactly its own sources, and nothing else.
@MainActor
@Suite("r reloads what you are looking at")
struct ReloadTests {
    private static let one = "one.example"
    private static let two = "two.example"
    private static let forum = "forum.example"
    private static let tid = 40125

    init() {
        L10n.language = .english
    }

    private static func timeline(_ host: String, _ ids: String...) -> FixtureHTTP.Outcome {
        .text("[" + ids.map { id in
            """
            {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
             "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }.joined(separator: ",") + "]")
    }

    private static func publicAddress(_ host: String) -> String {
        "https://\(host)/api/v1/timelines/public?limit=40"
    }

    private static func trendsAddress(_ host: String) -> String {
        "https://\(host)/api/v1/trends/statuses?limit=20"
    }

    /// What a Mastodon is asked before it is spoken to (#86). One per host, whatever the
    /// timeline in front asks of it, and unsigned — the document is public.
    private static func flavourAddress(_ host: String) -> String { MastodonInstance.address(host) }

    private static let boardAddress = "https://\(forum)/forum.php?mod=forumdisplay&fid=34&filter=author&orderby=dateline"
    private static let threadAddress = "https://\(forum)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"

    private static let board = FixtureHTTP.Outcome.text(#"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=34">工具箱讨论区</a></h1>
    <table id="threadlisttableid">
    <tbody id="normalthread_40125"><tr>
    <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">工具箱一键下载安装</a></th>
    <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
    <td class="num"><a href="forum.php?mod=viewthread&tid=40125" class="xi2">7</a><em>120</em></td>
    </tr></tbody>
    </table></body></html>
    """#)

    private static let thread = FixtureHTTP.Outcome.text(#"""
    <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
    <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
    <div class="message">工具箱一键下载安装。</div></div>
    <div class="plc" id="pid9102"><ul class="authi"><li>2<sup>#</sup></li>
    <li><a href="home.php?mod=space&uid=9">greenpine</a></li></ul>
    <div class="message">学到了。</div></div>
    """#)

    /// Every route a reload of any of the three sources could take, answering.
    private static var everything: [String: FixtureHTTP.Outcome] {
        [
            publicAddress(one): timeline(one, "1"),
            trendsAddress(one): timeline(one, "2"),
            publicAddress(two): timeline(two, "3"),
            trendsAddress(two): timeline(two, "4"),
            boardAddress: board,
            threadAddress: thread,
            flavourAddress(one): MastodonInstance.mastodon(one),
            flavourAddress(two): MastodonInstance.mastodon(two),
        ]
    }

    /// Two Mastodons and a Discuz! reading board 34, and one HTTP for all of them.
    private func shell(
        _ routes: [String: FixtureHTTP.Outcome] = everything,
        http: (any HTTPClient)? = nil,
        mastodon: MastodonSessions = MastodonSessions(tokens: MemoryMastodonTokens(), sender: Refuse())
    ) async -> (ShellSession, FixtureHTTP) {
        let fixture = FixtureHTTP(routes)
        let wire = http ?? fixture
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.add(Source(host: Self.two, kind: .mastodon))
        await store.add(Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "工具箱讨论区")]
        ))
        let session = ShellSession(
            http: wire, store: store, mastodon: mastodon, posts: ForumPosts(http: wire)
        )
        await session.reloadFromStore()
        return (session, fixture)
    }

    private func asked(_ http: FixtureHTTP) async -> Set<String> {
        Set(await http.requested.map(\.absoluteString))
    }

    // MARK: - Which sources a timeline asks

    @Test("All asks every source for its usual reads")
    func allAsksEverySource() async {
        let (session, http) = await shell()
        await session.reload.timeline(.all, in: session)
        #expect(await asked(http) == [
            Self.publicAddress(Self.one), Self.trendsAddress(Self.one),
            Self.publicAddress(Self.two), Self.trendsAddress(Self.two),
            Self.boardAddress,
            Self.flavourAddress(Self.one), Self.flavourAddress(Self.two),
        ])
        #expect(session.notes.count == 5)
        #expect(session.reload.failed.isEmpty)
        #expect(!session.reload.running)
    }

    /// #154: a board read again means its rows' kept words may be old, so each row asks again when
    /// it is reached — and only where the forum answered, so a dark reload leaves them standing.
    @Test("A forum's board read again makes its rows read their opening posts again; one unread does not")
    func aBoardReadAgainRevisitsItsRows() async {
        let (session, _) = await shell()
        await session.reload.timeline(.all, in: session)
        #expect(session.posts.due.contains(Self.forum), "the board was read and its rows kept their words")

        var dark = Self.everything
        dark[Self.boardAddress] = nil
        let (unread, _) = await shell(dark)
        await unread.reload.timeline(.all, in: unread)
        #expect(unread.reload.failed.contains(Self.forum), "the premise: the board did not answer")
        #expect(!unread.posts.due.contains(Self.forum), "a reload that did not get through let the words go")
    }

    @Test("Trends asks only the sources that have trends, and only for their trends")
    func trendsAsksTrends() async {
        let (session, http) = await shell()
        await session.reload.timeline(.trends, in: session)
        #expect(await asked(http) == [
            Self.trendsAddress(Self.one), Self.trendsAddress(Self.two),
            Self.flavourAddress(Self.one), Self.flavourAddress(Self.two),
        ])
        #expect(await !http.requested.contains { $0.host == Self.forum }, "a forum has no trends")
    }

    @Test("A timeline you wrote asks the sources and categories its rules name, and no other")
    func writtenAsksItsRules() async throws {
        let (session, http) = await shell()
        let publicOfOne = TimelineDefinition(name: "One", rules: [
            try #require(Rule.category(.public, in: .source(host: Self.one), sources: session.sources)),
        ])
        session.written = [publicOfOne]
        await session.reload.timeline(.written(publicOfOne.id), in: session)
        #expect(await asked(http) == [Self.publicAddress(Self.one), Self.flavourAddress(Self.one)])

        let (other, otherHTTP) = await shell()
        let two = TimelineDefinition(name: "Two", rules: [try #require(Rule.source(Self.two))])
        other.written = [two]
        await other.reload.timeline(.written(two.id), in: other)
        #expect(await asked(otherHTTP) == [
            Self.publicAddress(Self.two), Self.trendsAddress(Self.two), Self.flavourAddress(Self.two),
        ])
    }

    @Test("A rule for every source asks every source; a board rule asks that board alone")
    func everyAndBoard() async throws {
        let (session, http) = await shell()
        let everyPublic = TimelineDefinition(name: "Public", rules: [
            try #require(Rule.category(.public, in: .every, sources: session.sources)),
        ])
        session.written = [everyPublic]
        await session.reload.timeline(.written(everyPublic.id), in: session)
        #expect(await asked(http) == [
            Self.publicAddress(Self.one), Self.publicAddress(Self.two),
            Self.flavourAddress(Self.one), Self.flavourAddress(Self.two),
        ])

        let (other, otherHTTP) = await shell()
        let board = TimelineDefinition(name: "Board", rules: [
            try #require(Rule.category(.board(id: "34"), in: .source(host: Self.forum), sources: other.sources)),
        ])
        other.written = [board]
        await other.reload.timeline(.written(board.id), in: other)
        #expect(await asked(otherHTTP) == [Self.boardAddress])
    }

    @Test("A rule naming a list no longer chosen asks nothing, and nobody else is asked instead")
    func goneListAsksNothing() async throws {
        let (session, http) = await shell()
        let list = TimelineDefinition(name: "Friends", rules: [
            try #require(Rule.category(.list(id: "42"), in: .source(host: Self.one), sources: session.sources)),
        ])
        session.written = [list]
        await session.reload.timeline(.written(list.id), in: session)
        #expect(await http.requested.isEmpty)
    }

    @Test("Home and a chosen list are read as you, through the signed-in door")
    func homeAndListAsYou() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Recorder(Self.timeline(Self.one, "5"))
        let (session, http) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        await session.store.subscribe(host: Self.one, toLists: [ListSubscription(id: "42", name: "Friends")])
        await session.reloadFromStore()
        let mine = TimelineDefinition(name: "Mine", rules: [
            try #require(Rule.category(.home, in: .source(host: Self.one), sources: session.sources)),
            try #require(Rule.category(.list(id: "42"), in: .source(host: Self.one), sources: session.sources)),
        ])
        session.written = [mine]
        await session.reload.timeline(.written(mine.id), in: session)
        #expect(await signedIn.paths == ["/api/v1/timelines/home", "/api/v1/timelines/list/42"])
        #expect(await asked(http) == [Self.flavourAddress(Self.one)],
                "nothing public was named; the one unsigned ask is what the server says it is")
        #expect(session.notes.first?.categories == [.home, .list(id: "42")])
    }

    @Test("r on a written tab in front asks that timeline's sources: a keyword on every source asks them all")
    func writtenTabInFront() async throws {
        let (session, http) = await shell()
        let words = TimelineDefinition(name: "Tools", rules: [try #require(Rule.keyword("工具", in: .every))])
        session.written = [words]
        session.rebuildQueries()
        session.timelineID = .written(words.id)
        await session.reload.timeline(session.currentTimeline, in: session)
        #expect(await asked(http) == [
            Self.publicAddress(Self.one), Self.trendsAddress(Self.one),
            Self.publicAddress(Self.two), Self.trendsAddress(Self.two),
            Self.boardAddress,
            Self.flavourAddress(Self.one), Self.flavourAddress(Self.two),
        ])
    }

    @Test("r on a written tab with one list rule asks only that list, as you, and nothing public")
    func writtenListTab() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Recorder(Self.timeline(Self.one, "5"))
        let (session, http) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        await session.store.subscribe(host: Self.one, toLists: [ListSubscription(id: "42", name: "Friends")])
        await session.reloadFromStore()
        let friends = TimelineDefinition(name: "Friends", rules: [
            try #require(Rule.category(.list(id: "42"), in: .source(host: Self.one), sources: session.sources)),
        ])
        session.written = [friends]
        session.rebuildQueries()
        session.timelineID = .written(friends.id)
        await session.reload.timeline(session.currentTimeline, in: session)
        #expect(await signedIn.paths == ["/api/v1/timelines/list/42"])
        #expect(await asked(http) == [Self.flavourAddress(Self.one)], "the flavour ask, and nothing else")
        #expect(session.notes.first?.categories == [.list(id: "42")])
    }

    @Test("While the timeline editor is up, r reloads nothing: the editor owns the keys")
    func editorOwnsTheKeys() async {
        let (session, http) = await shell()
        session.editing = TimelineDraft(new: 1)
        #expect(DummyCommand.from("r") == .reload)
        await session.reload.timeline(session.currentTimeline, in: session)
        await session.reload.thread(DummyItem(Self.forumNote()), in: session)
        #expect(await http.requested.isEmpty)
        #expect(session.reload.landed == 0)
        #expect(!session.reload.running)

        session.editing = nil
        await session.reload.timeline(session.currentTimeline, in: session)
        #expect(await !http.requested.isEmpty, "with the editor gone, r reloads again")
    }

    @Test("Opening the timeline editor stops a running reload, which Esc could no longer reach")
    func editorStopsTheReload() async {
        let gated = GatedHTTP(Self.everything, holding: "/api/v1/trends/statuses")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(http: gated)
        let running = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await gated.asks == 2 })
        session.newTimeline()
        #expect(session.editing != nil)
        #expect(!session.reload.running)
        #expect(session.reload.stopped)
        await running.value
        await gated.gate.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.all().isEmpty, "what it had not landed did not land")
    }

    @Test("A server that ends the sign-in on a reload signs the row out and says the source failed")
    func signedOutOnReload() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let (session, _) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: Refuse(status: 401)))
        let home = TimelineDefinition(name: "Home", rules: [
            try #require(Rule.category(.home, in: .source(host: Self.one), sources: session.sources)),
        ])
        session.written = [home]
        await session.reload.timeline(.written(home.id), in: session)
        #expect(session.mastodon.ended == [Self.one])
        #expect(!session.isSignedIn(host: Self.one))
        #expect(session.reload.failed == [Self.one])
    }

    // MARK: - Failure, one at a time, and where you were

    @Test("A source that fails says so, and the others still land")
    func oneFailsOthersLand() async {
        var routes = Self.everything
        routes[Self.publicAddress(Self.one)] = .fail
        routes[Self.trendsAddress(Self.one)] = .body(Data(), status: 503)
        let (session, _) = await shell(routes)
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed == [Self.one])
        #expect(Set(session.notes.map(\.source.host)) == [Self.two, Self.forum])
        #expect(session.reload.line == "Could not reload one.example.")
    }

    @Test("A Mastodon with no trends still reloads its timeline without a word")
    func noTrendsIsNoFailure() async {
        var routes = Self.everything
        routes[Self.trendsAddress(Self.one)] = .body(Data(), status: 404)
        let (session, _) = await shell(routes)
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed.isEmpty)
        #expect(session.reload.line == nil)
    }

    @Test("Signing out while a reload reads Home as you: nothing it read lands, and the token is not used again")
    func signOutStopsTheReadAsYou() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Paths(
            ["/api/v1/timelines/home": "[" + Self.status("5", "home") + "]"],
            holding: ["/api/v1/timelines/home"]
        )
        let guardTask = hangGuard(signedIn.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        let running = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await signedIn.paths.contains("/api/v1/timelines/home") })
        await session.signOut(host: Self.one)
        await signedIn.gate.open()
        await running.value
        #expect(!session.notes.contains { $0.categories.contains(.home) }, "Home read before the sign-out did not land")
        #expect(await signedIn.paths.filter { $0.hasPrefix("/api/v1/timelines") } == ["/api/v1/timelines/home"])
        #expect(session.notes.contains { $0.source.host == Self.two }, "the other sources still landed")
    }

    @Test("A busy thread: the post lands even when its context is past the signed-in ceiling")
    func busyThreadKeepsThePost() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Paths(
            ["/api/v1/statuses/9": Self.status("9", "edited words")],
            oversize: ["/api/v1/statuses/9/context"]
        )
        let (session, _) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        let item = await holding(Self.mastodonNote(statusID: "9"), in: session)
        await session.reload.thread(item, in: session)
        #expect(await signedIn.paths == ["/api/v1/statuses/9", "/api/v1/statuses/9/context"])
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "edited words")
        #expect(session.reload.failed.isEmpty)
        #expect(session.reload.line == nil)
    }

    @Test("A request that trickles past its deadline fails that source, and the others land")
    func deadline() async {
        let slow = Slow(Self.one, then: FixtureHTTP(Self.everything))
        let (session, _) = await shell(http: slow)
        session.reload.deadline = .milliseconds(50)
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed == [Self.one])
        #expect(Set(session.notes.map(\.source.host)) == [Self.two, Self.forum])
    }

    @Test("Stopping a running reload: it ends at once, says so, and what it had not landed does not land")
    func stopTheReload() async {
        let gated = GatedHTTP(Self.everything, holding: "/api/v1/trends/statuses")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(http: gated)
        let first = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await gated.asks == 2 })
        #expect(session.reload.stop())
        await first.value
        #expect(!session.reload.running)
        #expect(session.reload.line == "Reload stopped.")
        #expect(!session.reload.stop(), "nothing left to stop")
        await gated.gate.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.all().isEmpty)
    }

    @Test("Pressing r again while a reload runs starts no second one")
    func noDoubleReload() async {
        let gated = GatedHTTP(Self.everything, holding: "/api/v1/trends/statuses")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(http: gated)
        let first = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await gated.asks == 2 })
        #expect(session.reload.running)
        #expect(session.reload.line == "Reloading…")
        await session.reload.timeline(.trends, in: session)
        await session.reload.thread(DummyItem(session.notes.first ?? Self.forumNote()), in: session)
        #expect(await gated.asks == 2, "a second press put nothing on the wire")
        await gated.gate.open()
        await first.value
        #expect(!session.reload.running)
        #expect(session.reload.landed == 1)
    }

    @Test("r, Esc, r: the stopped run ending late does not end the new one")
    func stoppedRunDoesNotEndTheNext() async throws {
        var routes = Self.everything
        routes["https://\(Self.one)/api/v1/statuses/9"] = .text(Self.status("9", "edited words"))
        routes["https://\(Self.one)/api/v1/statuses/9/context"] = .text(Self.context)
        let held = Held(routes, holding: ["/api/v1/trends/statuses", "/api/v1/statuses/9"])
        let guards = [hangGuard(held.first), hangGuard(held.second)]
        defer { for guardTask in guards { guardTask.cancel() } }
        let (session, _) = await shell(http: held)
        let item = await holding(Self.mastodonNote(statusID: "9"), in: session)

        let first = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await held.asks("/api/v1/trends/statuses") == 2 })
        #expect(session.reload.stop())
        await first.value
        let second = Task { await session.reload.thread(item, in: session) }
        #expect(await spun { await held.asks("/api/v1/statuses/9") == 1 })

        await held.first.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(session.reload.running, "the first run's late end left the second running")
        #expect(session.reload.line == "Reloading…")
        await session.reload.timeline(.trends, in: session)
        #expect(await held.asks("/api/v1/trends/statuses") == 2, "a further r started nothing")
        #expect(session.reload.stop(), "the second run can still be stopped")
        await second.value
        #expect(!session.reload.running)
        await held.second.open()
    }

    @Test("A second r while a reload runs does nothing: it neither stops it nor starts another")
    func secondPressDoesNothing() async {
        let gated = GatedHTTP(Self.everything, holding: "/api/v1/trends/statuses")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(http: gated)
        session.reload.press(thread: nil, timeline: .trends, in: session)
        #expect(await spun { await gated.asks == 2 })
        session.reload.press(thread: nil, timeline: .trends, in: session)
        for _ in 0..<200 { await Task.yield() }
        #expect(session.reload.running)
        #expect(!session.reload.stopped)
        #expect(await gated.asks == 2)
        await gated.gate.open()
        #expect(await spun { !session.reload.running })
        #expect(session.reload.landed == 1)
    }

    @Test("The selected post is still there to be selected after a reload")
    func selectionStays() async {
        let (session, _) = await shell()
        await session.reload.timeline(.all, in: session)
        let before = TimelineQuery.all.items(from: session.notes, latest: nil)
        let selected = before[2].id
        var routes = Self.everything
        routes[Self.publicAddress(Self.two)] = Self.timeline(Self.two, "3", "6")
        let fixture = FixtureHTTP(routes)
        let again = ShellSession(
            http: fixture, store: session.store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Refuse())
        )
        await again.reloadFromStore()
        await again.reload.timeline(.all, in: again)
        let after = TimelineQuery.all.items(from: again.notes, latest: nil)
        #expect(after.count == before.count + 1)
        #expect(DummyCommand.focused(in: after, selected: selected) == .post(before[2]))
        #expect(again.reload.landed == 1)
    }

    // MARK: - An open thread

    private static func forumNote() -> Note {
        Note(
            id: "discuz:\(forum):\(tid)", source: Source(host: forum, kind: .discuz),
            author: "tinbox", handle: "@tinbox@\(forum)", body: "", title: "工具箱一键下载安装",
            postedAt: .distantPast, categories: [.board(id: "34")]
        )
    }

    @Test("With a thread open, r reloads that post and its thread, and not the timeline")
    func threadOnly() async {
        let (session, http) = await shell()
        let item = DummyItem(Self.forumNote())
        let ref = ForumThreadRef(host: Self.forum, tid: Self.tid)
        await session.posts.fetchReplies(ref)
        let fetched = await http.requested.count

        await session.reload.thread(item, in: session)
        let after = await http.requested.dropFirst(fetched).map(\.absoluteString)
        #expect(after == [Self.threadAddress, Self.threadAddress], "the opening post, and the replies")
        #expect(session.notes.isEmpty, "the timeline under it was not fetched")
        #expect(session.reload.failed.isEmpty)
        #expect(session.posts.reading(ref) == .words("工具箱一键下载安装。"))
    }

    @Test("A thread that cannot be reloaded says so, and keeps what it held")
    func threadFails() async {
        let flaky = Flaky(Self.threadAddress, Self.thread)
        let (session, _) = await shell(http: flaky)
        let ref = ForumThreadRef(host: Self.forum, tid: Self.tid)
        await session.posts.fetch(ref)
        await flaky.fail()
        await session.reload.thread(DummyItem(Self.forumNote()), in: session)
        #expect(session.reload.failed == [Self.forum])
        #expect(session.posts.reading(ref) == .words("工具箱一键下载安装。"))
    }

    @Test("Esc on a Discuz! thread reload: its page does not land, and what was noted stays")
    func stopTheThreadReload() async {
        let http = Switching(Self.threadAddress)
        let guardTask = hangGuard(http.gate)
        defer { guardTask.cancel() }
        let (session, _) = await shell(http: http)
        let ref = ForumThreadRef(host: Self.forum, tid: Self.tid)
        await session.posts.fetch(ref)
        #expect(session.posts.reading(ref) == .absent(.refused))

        await http.answer(Self.thread)
        let running = Task { await session.reload.thread(DummyItem(Self.forumNote()), in: session) }
        #expect(await spun { await http.held })
        #expect(session.reload.stop())
        await running.value
        #expect(session.posts.reading(ref) == .absent(.refused), "the mark stays while stopped")
        await http.gate.open()
        #expect(await spun { session.posts.inFlight.isEmpty })
        #expect(session.posts.reading(ref) == .absent(.refused), "the stopped page did not land")
        #expect(session.reload.failed.isEmpty)
    }

    @Test("A Discuz! thread that trickles past the deadline fails the reload")
    func threadDeadline() async {
        let slow = Slow(Self.forum, then: FixtureHTTP(Self.everything))
        let (session, _) = await shell(http: slow)
        session.reload.deadline = .milliseconds(50)
        await session.reload.thread(DummyItem(Self.forumNote()), in: session)
        #expect(session.reload.failed == [Self.forum])
        #expect(session.posts.reading(ForumThreadRef(host: Self.forum, tid: Self.tid)) == .absent(.unreachable))
    }

    private static func status(_ id: String, _ text: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(one)/users/ada/statuses/\(id)",
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>\(text)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static let context = #"{"ancestors":[],"descendants":["#
        + status("11", "a reply") + "," + status("12", "an edited reply") + "]}"

    /// A Mastodon post held on `one.example` with `statusID`, first as "first words".
    private static func mastodonNote(statusID: String?) -> Note {
        Note(
            id: "https://\(one)/users/ada/statuses/9", source: Source(host: one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(one)", body: "first words",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public], statusID: statusID
        )
    }

    private func holding(_ note: Note, in session: ShellSession) async -> DummyItem {
        await session.store.ingest([note])
        await session.reloadFromStore()
        return DummyItem(note)
    }

    @Test("r on an open Mastodon post asks that post and its context, unsigned, and the edit lands")
    func mastodonThreadWithID() async throws {
        var routes = Self.everything
        routes["https://\(Self.one)/api/v1/statuses/9"] = .text(Self.status("9", "edited words"))
        routes["https://\(Self.one)/api/v1/statuses/9/context"] = .text(Self.context)
        let (session, http) = await shell(routes)
        let heldReply = Note(
            id: "https://\(Self.one)/users/ada/statuses/12", source: Source(host: Self.one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(Self.one)", body: "a reply", postedAt: Date(timeIntervalSince1970: 0),
            categories: [.home]
        )
        await session.store.ingest([heldReply])
        let item = await holding(Self.mastodonNote(statusID: "9"), in: session)

        await session.reload.thread(item, in: session)
        #expect(await http.requested.map(\.absoluteString) == [
            "https://\(Self.one)/api/v1/statuses/9",
            "https://\(Self.one)/api/v1/statuses/9/context",
        ], "the post and its thread, and not the timeline under it")
        let row = try #require(session.notes.first { $0.key.rowID == item.id })
        #expect(row.body == "edited words")
        #expect(row.categories == [.public])
        #expect(session.notes.first { $0.key == heldReply.key }?.body == "an edited reply",
                "a reply already held is updated")
        #expect(!session.notes.contains { $0.id.hasSuffix("/11") }, "a reply never held is dropped")
        #expect(session.notes.count == 2)
        // Where you were stays: the same row, under the same id, still in the stream.
        let stream = session.timelineItems(latest: nil)
        #expect(DummyCommand.focused(in: stream, selected: item.id) == .post(DummyItem(row)))
        #expect(session.reload.failed.isEmpty)
        #expect(session.reload.line == nil)
    }

    @Test("r on an open Mastodon post with no id held, signed in, finds it through search as you")
    func mastodonThreadSearch() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Paths([
            "/api/v2/search": #"{"statuses":["# + Self.status("9", "x") + "]}",
            "/api/v1/statuses/9": Self.status("9", "edited words"),
            "/api/v1/statuses/9/context": Self.context,
        ])
        let (session, http) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        let item = await holding(Self.mastodonNote(statusID: nil), in: session)

        await session.reload.thread(item, in: session)
        #expect(await signedIn.paths == ["/api/v2/search", "/api/v1/statuses/9", "/api/v1/statuses/9/context"])
        #expect(await signedIn.queries.first?.contains(URLQueryItem(
            name: "q", value: "https://\(Self.one)/users/ada/statuses/9"
        )) == true)
        #expect(await http.requested.isEmpty, "nothing unsigned, and no timeline")
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "edited words")
        #expect(session.notes.first { $0.key.rowID == item.id }?.statusID == "9", "found once, kept")
    }

    @Test("r on an open Mastodon post with no id held, signed out, asks nobody and says so")
    func mastodonThreadUnfindable() async {
        let (session, http) = await shell()
        let item = await holding(Self.mastodonNote(statusID: nil), in: session)
        await session.reload.thread(item, in: session)
        #expect(await http.requested.isEmpty)
        #expect(session.reload.unfindable == .signedOut(host: Self.one))
        #expect(session.reload.line == "This post can't be reloaded: sign in to one.example to find it there.")
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "first words")
    }

    @Test("Signed in with a token that cannot search: nothing more is asked, and the line says sign in again")
    func mastodonThreadScope() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Paths(["/api/v2/search": "{}"], status: ["/api/v2/search": 403])
        let (session, http) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        let item = await holding(Self.mastodonNote(statusID: nil), in: session)
        await session.reload.thread(item, in: session)
        #expect(await signedIn.paths == ["/api/v2/search"])
        #expect(await http.requested.isEmpty)
        #expect(session.reload.unfindable == .cannotSearch(host: Self.one))
        #expect(session.reload.line == "This post can't be reloaded: sign in to one.example again to let Fediqo find it.")
        #expect(session.isSignedIn(host: Self.one), "a 403 is not a sign-out")
    }

    @Test("Signed out just as the search answers: the post is not asked for on the forgotten token")
    func signOutBetweenThreadSteps() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = SignsOut([
            "/api/v2/search": #"{"statuses":["# + Self.status("9", "x") + "]}",
            "/api/v1/statuses/9": Self.status("9", "edited words"),
            "/api/v1/statuses/9/context": Self.context,
        ])
        let (session, _) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        await signedIn.after("/api/v2/search") { await session.signOut(host: Self.one) }
        let item = await holding(Self.mastodonNote(statusID: nil), in: session)
        await session.reload.thread(item, in: session)
        #expect(await spun { !session.isSignedIn(host: Self.one) })
        let sent = await signedIn.paths.filter { $0.hasPrefix("/api") }
        #expect(sent == ["/api/v2/search"], "nothing after the sign-out went out")
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "first words")
    }

    @Test("Search finding some other post is not believed: nothing more is asked, and the line says so")
    func mastodonThreadSearchMismatch() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let signedIn = Paths(["/api/v2/search": #"{"statuses":["# + Self.status("12", "other") + "]}"])
        let (session, _) = await shell(mastodon: MastodonSessions(tokens: tokens, sender: signedIn))
        let item = await holding(Self.mastodonNote(statusID: nil), in: session)
        await session.reload.thread(item, in: session)
        #expect(await signedIn.paths == ["/api/v2/search"])
        #expect(session.reload.unfindable == .notFound(host: Self.one))
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "first words")
    }

    @Test("r on an open Mastodon post that fails says so and keeps what it held")
    func mastodonThreadFails() async {
        var routes = Self.everything
        routes["https://\(Self.one)/api/v1/statuses/9"] = .body(Data(), status: 500)
        let (session, _) = await shell(routes)
        let item = await holding(Self.mastodonNote(statusID: "9"), in: session)
        await session.reload.thread(item, in: session)
        #expect(session.reload.failed == [Self.one])
        #expect(session.notes.first { $0.key.rowID == item.id }?.body == "first words")
    }

    @Test("r on an open Discourse topic asks its own page, and nothing else")
    func discourseThread() async throws {
        let talk = "talk.example"
        let http = FixtureHTTP([
            "https://\(talk)/t/17.json": .text("""
                {"id":17,"title":"Tools","slug":"tools","created_at":"2024-01-01T00:00:00.000Z",
                 "reply_count":3,"post_stream":{"posts":[
                   {"post_number":1,"username":"ada","name":"Ada","cooked":"<p>edited opening</p>"}]}}
                """),
        ])
        let (session, _) = await shell(http: http)
        await session.store.add(Source(host: talk, kind: .discourse))
        let topic = Note(
            id: "discourse:\(talk):17", source: Source(host: talk, kind: .discourse), author: "Ada",
            handle: "@ada@\(talk)", body: "", title: "Tools", board: "Help",
            postedAt: Date(timeIntervalSince1970: 0), categories: []
        )
        let item = await holding(topic, in: session)
        await session.reload.thread(item, in: session)
        #expect(await http.requested.map(\.absoluteString) == ["https://\(talk)/t/17.json"])
        let row = try #require(session.notes.first { $0.key.rowID == item.id })
        #expect(row.body == "edited opening")
        #expect(row.board == "Help")
        #expect(row.counts.replies == 3)
    }

    // MARK: - The key

    @Test("r is the reload key, on the keys list under Timeline, in both languages")
    func theKey() {
        #expect(DummyCommand.from("r") == .reload)
        #expect(DummyCommand.from("r", typing: true) == nil)
        #expect(DummyCommand.from("r", fieldFocused: true) == nil)
        #expect(DummyCommand.from("r", command: true) == .replayLanding)
        let line = DummyShortcut.all.first { $0.commands == [.reload] }
        #expect(line?.keys == ["r"])
        #expect(line?.group == .read)
        for key in ["shortcut.reload", "timeline.reload.progress", "timeline.reload.failed"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }
}

/// A signed-in door that answers every request with one status.
private struct Refuse: HTTPSender {
    var status = 500

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// A signed-in door answering every timeline with `body`, remembering the paths asked.
private actor Recorder: HTTPSender {
    private let body: FixtureHTTP.Outcome
    private(set) var paths: [String] = []

    init(_ body: FixtureHTTP.Outcome) {
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        guard case .text(let text, _) = body else { throw FixtureHTTPError.unmapped }
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A signed-in door answering by path, remembering each path and query asked.
private actor Paths: HTTPSender {
    private let bodies: [String: String]
    private let status: [String: Int]
    /// Paths answered past the signed-in ceiling, as `CappedBody` refuses them.
    private let oversize: Set<String>
    /// Paths held until the test opens the gate.
    private let held: Set<String>
    let gate = Gate()
    private(set) var paths: [String] = []
    private(set) var queries: [[URLQueryItem]] = []

    init(
        _ bodies: [String: String], status: [String: Int] = [:], oversize: Set<String> = [],
        holding held: Set<String> = []
    ) {
        self.bodies = bodies
        self.status = status
        self.oversize = oversize
        self.held = held
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        queries.append(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        if held.contains(url.path) { await gate.wait() }
        if oversize.contains(url.path) { throw URLError(.dataLengthExceedsMaximum) }
        guard let body = bodies[url.path] else { throw FixtureHTTPError.unmapped }
        let code = status[url.path] ?? 200
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

/// One host that answers nothing for a minute, and everything else as `inner` does.
private struct Slow: HTTPClient {
    let host: String
    let inner: any HTTPClient

    init(_ host: String, then inner: any HTTPClient) {
        self.host = host
        self.inner = inner
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if url.host == host { try await Task.sleep(for: .seconds(60)) }
        return try await inner.data(from: url)
    }
}

/// One address that answers until told to fail.
private actor Flaky: HTTPClient {
    private let address: String
    private let answer: FixtureHTTP.Outcome
    private var failing = false

    init(_ address: String, _ answer: FixtureHTTP.Outcome) {
        self.address = address
        self.answer = answer
    }

    func fail() {
        failing = true
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard url.absoluteString == address, !failing, case .text(let text, _) = answer else {
            throw FixtureHTTPError.unreachable
        }
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Holds two paths, each on its own gate, and counts the asks for every path.
private actor Held: HTTPClient {
    private let inner: FixtureHTTP
    private let paths: [String]
    let first = Gate()
    let second = Gate()
    private var counted: [String: Int] = [:]

    init(_ routes: [String: FixtureHTTP.Outcome], holding paths: [String]) {
        inner = FixtureHTTP(routes)
        self.paths = paths
    }

    func asks(_ path: String) -> Int {
        counted[path] ?? 0
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        counted[url.path, default: 0] += 1
        if url.path == paths[0] { await first.wait() }
        if url.path == paths[1] { await second.wait() }
        return try await inner.data(from: url)
    }
}

/// One address refused with a 403 until given an answer, which it then holds on a gate.
private actor Switching: HTTPClient {
    private let address: String
    private var answer: FixtureHTTP.Outcome?
    let gate = Gate()
    private(set) var held = false

    init(_ address: String) {
        self.address = address
    }

    func answer(_ outcome: FixtureHTTP.Outcome) {
        answer = outcome
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard url.absoluteString == address else { throw FixtureHTTPError.unmapped }
        guard case .text(let text, _) = answer else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        held = true
        await gate.wait()
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A signed-in door answering by path that, as it answers one path, starts `then` on the main
/// actor — so it runs before the answer is back with whoever asked.
private actor SignsOut: HTTPSender {
    private let bodies: [String: String]
    private var trigger: (path: String, then: @MainActor @Sendable () async -> Void)?
    private(set) var paths: [String] = []

    init(_ bodies: [String: String]) {
        self.bodies = bodies
    }

    func after(_ path: String, then: @escaping @MainActor @Sendable () async -> Void) {
        trigger = (path, then)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        if let trigger, trigger.path == url.path {
            Task { @MainActor in await trigger.then() }
        }
        let body = bodies[url.path] ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
