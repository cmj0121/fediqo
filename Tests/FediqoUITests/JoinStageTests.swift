import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// Unit 4: adding a source in two presses, and the one sheet all three of its stages happen in.
///
/// **What is pinned here is the flow's own guarantees rather than any one screen.** `checking`
/// stopped covering this errand the moment adding split in two — the sheet is up while nothing is
/// on the wire — so the things that can now go wrong are a second look overwriting the stage under
/// the reader, and a press they abandoned springing the sheet back open behind them. Both are
/// below, and both were unreachable before this unit.
@MainActor
@Suite("Two-stage subscribe")
struct JoinStageTests {
    private static let forum = "install-c.example"

    init() {
        L10n.language = .english
    }

    /// Opens only when a test lets it, so a press can be caught mid-flight.
    ///
    /// `ClearTests.Gate`'s shape, and the same reason for it: the flag is set before the waiters
    /// are resumed, so a caller arriving after the gate is open does not park on a continuation
    /// nobody will resume.
    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    /// A fixture that holds one address until the test says otherwise.
    private actor GatedHTTP: HTTPClient {
        private let inner: FixtureHTTP
        private let held: String
        let gate = Gate()

        init(_ routes: [String: FixtureHTTP.Outcome], holding held: String) {
            self.inner = FixtureHTTP(routes)
            self.held = held
        }

        /// Matched on the path as well as the whole address, because a Mastodon's timeline
        /// carries a query this test has no business knowing the value of.
        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            if url.absoluteString == held || url.path == held { await gate.wait() }
            return try await inner.data(from: url)
        }
    }

    /// Waits for a condition, and **gives up rather than spinning for ever**. A bare
    /// `while !x { await Task.yield() }` survives `.timeLimit` — yielding does not throw on
    /// cancellation — so a press that stopped setting `checking` would hang the suite instead of
    /// failing it.
    private static func spun(until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private static let discuzFront = #"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
    """#

    private static let discuzIndex = #"""
    <h2><a href="forum.php?gid=56">::工具区::</a></h2>
    <div id="category_56" class="bm_c">
    <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
    <dd><em>主题: 4207</em></dd></dl>
    </div>
    """#

    /// One board's thread list. Shared by the two tests that drive a subscribe through the gate,
    /// because neither is about the markup and a second copy is a second thing to get wrong.
    private static let oneBoard = #"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
    <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
    <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
    <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
    </tr></tbody></table></body></html>
    """#

    private static func forumRoutes() -> [String: FixtureHTTP.Outcome] {
        [
            "/": .text(discuzFront),
            "https://\(forum)/forum.php": .text(discuzIndex),
        ]
    }

    private static func forumSession() -> (ShellSession, FixtureHTTP) {
        let http = FixtureHTTP(forumRoutes())
        return (ShellSession(http: http, store: ItemStore()), http)
    }

    // MARK: - PLAN risk 8: what `checking` stopped covering

    /// **The sheet being up is the errand being in progress.** `checking` goes false the instant
    /// the look returns, so the field and the Add button are live again behind an open preview —
    /// and a second press would replace the stage under a reader who is still reading the first
    /// one. The stage is what says so, and `add` is guarded on it.
    @Test("A second Add behind an open preview changes nothing")
    func aSecondAddIsRefusedWhileTheSheetIsUp() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add()
        let opened = session.stage
        #expect(opened != nil, "the premise did not hold: no preview was opened")
        let asked = await http.paths.count

        session.hostname = "somewhere.else.example"
        await session.add()

        #expect(session.stage == opened, "a second look replaced the stage behind the reader")
        #expect(await http.paths.count == asked, "a second look was spent on a refused press")
    }

    /// The same guard from the other side: a press cannot start while one is on the wire.
    @Test("Subscribe does nothing while a press is already in flight")
    func confirmIsRefusedWhileChecking() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add()
        let asked = await http.paths.count

        session.checking = true
        await session.confirm()

        #expect(await http.paths.count == asked, "a second press reached the forum")
        #expect(session.choosing == nil)
    }

    /// **The hazard this unit had to be built against.** The reader presses Subscribe on a forum,
    /// swipes the sheet away while the index is still on the wire, and the answer comes back
    /// carrying boards. Without a token compared before the write, that answer springs the sheet
    /// open again — over a reader who left, at a stage they never asked for.
    ///
    /// **The preview is seeded rather than looked up, so only the press touches the wire.** Since
    /// the index probe landed, a look and a press both want `/forum.php`, and a gate on it would
    /// stop the look this test is not about. A preview carrying no boards is what a forum that
    /// turned the reader away leaves behind, and it is exactly the preview whose press reads.
    @Test(
        "A sheet swiped away mid-press does not spring back when the boards arrive",
        .timeLimit(.minutes(1))
    )
    func anAbandonedPressDoesNotReopenTheSheet() async {
        let http = GatedHTTP(Self.forumRoutes(), holding: "https://\(Self.forum)/forum.php")
        let session = ShellSession(http: http, store: ItemStore())
        // **Armed before anything can await, which is the half that is easy to get wrong.**
        // Nothing but this test releases the gate, so any call that comes to want this address
        // parks for ever — and `.timeLimit` does not rescue a task held on a `CheckedContinuation`
        // (`ClearTests` records that), so the watchdog is the load-bearing half. Placed here
        // rather than beside the press because a watchdog created *after* the hang site never
        // runs: verified by re-creating the deadlock, which hung for 200 seconds with the
        // watchdog sitting below it. On the passing path it is cancelled without ever waiting.
        //
        // Not hypothetical: the index probe made `look` want the forum's index, and the first cut
        // of it deadlocked exactly this way.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        session.hostname = Self.forum
        session.stage = .previewing(SourcePreview(
            host: Self.forum,
            kind: .discuz,
            profile: .stated(SourceProfile(
                host: Self.forum, kind: .discuz, readsWithoutAccount: false
            ))
        ))

        let press = Task { await session.confirm() }
        // The press is parked on the index. The reader leaves.
        #expect(await Self.spun { session.checking }, "the press never reached the wire")
        session.dismissStage()
        await http.gate.open()
        await press.value

        #expect(session.stage == nil, "the boards reopened a sheet the reader had left")
        #expect(session.choosing == nil)
        #expect(session.sources.isEmpty, "nothing is added by a press nobody is waiting for")
    }

    /// **The other side of the token, and the one it must not be applied to.** A microblog press
    /// writes the source to the store *before* it returns, so a reader who dismissed the sheet
    /// while it was in flight has joined that server whether or not they are still looking at the
    /// sheet. Refusing the whole answer would leave it added and invisible — the list disagreeing
    /// with the store until something else happened to refresh it.
    @Test(
        "A join that finished behind a dismissed sheet still reaches the list",
        .timeLimit(.minutes(1))
    )
    func anAbandonedJoinIsStillAdopted() async {
        let http = GatedHTTP([
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
        ], holding: "/api/v1/timelines/public")
        let session = ShellSession(http: http, store: ItemStore())
        // **Armed before anything can await, which is the half that is easy to get wrong.**
        // Nothing but this test releases the gate, so any call that comes to want this address
        // parks for ever — and `.timeLimit` does not rescue a task held on a `CheckedContinuation`
        // (`ClearTests` records that), so the watchdog is the load-bearing half. Placed here
        // rather than beside the press because a watchdog created *after* the hang site never
        // runs: verified by re-creating the deadlock, which hung for 200 seconds with the
        // watchdog sitting below it. On the passing path it is cancelled without ever waiting.
        //
        // Not hypothetical: the index probe made `look` want the forum's index, and the first cut
        // of it deadlocked exactly this way.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        session.hostname = "first.example"
        await session.add()

        let press = Task { await session.confirm() }
        #expect(await Self.spun { session.checking }, "the press never reached the wire")
        session.dismissStage()
        await http.gate.open()
        await press.value

        #expect(session.stage == nil)
        #expect(session.sources.map(\.host) == ["first.example"], """
            The join wrote the source to the store and the list never heard about it. The \
            generation token belongs on the stage write, not on `adopt`.
            """)
        #expect(!session.notes.isEmpty)
    }

    /// **A reader who walked away is not a server that is still being checked.** `progressHost`
    /// is what the progress line names, and a cancellation that left it set would leave a server's
    /// name under a field with nothing happening to it.
    @Test("Cancellation clears the host the errand was about, at both presses")
    func cancellationClearsTheProgressHost() async {
        let looking = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .cancelled,
        ]), store: ItemStore())
        looking.hostname = "first.example"
        await looking.add()
        #expect(looking.stage == nil)
        #expect(looking.refuse == nil, "a reader's leaving was reported as the server's fault")
        #expect(looking.progressHost == "")

        let pressing = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .cancelled,
            "/api/v1/trends/statuses": .text("[]"),
        ]), store: ItemStore())
        pressing.hostname = "first.example"
        await pressing.add()
        #expect(pressing.progressHost == "first.example", "the premise: the press names the host")
        await pressing.confirm()
        #expect(pressing.refuse == nil)
        #expect(pressing.progressHost == "")
        #expect(pressing.sources.isEmpty)
    }

    // MARK: - Decision 12: Back, without a second request

    /// **The reader-visible gain of merging three sheets into one.** The preview travels inside
    /// the boards stage, so stepping back is a value being read rather than a forum being asked
    /// for its index a second time.
    @Test("Back from the boards returns to the same preview and asks the forum nothing")
    func backFromTheBoardsCostsNothing() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add()
        guard case .previewing(let looked) = session.stage else {
            Issue.record("a look should open a preview")
            return
        }
        await session.confirm()
        #expect(session.choosing != nil, "the premise did not hold: the boards were not reached")
        let asked = await http.paths

        session.backToPreview()

        #expect(session.stage == .previewing(looked), "Back landed somewhere else")
        #expect(await http.paths == asked, "Back asked the forum for its index again")
        #expect(session.sources.isEmpty)
    }

    @Test("Back does nothing from a stage there is nothing behind")
    func backFromElsewhereDoesNothing() async {
        let (session, _) = Self.forumSession()
        session.browse()
        session.backToPreview()
        #expect(session.stage == .browsing)
    }

    // MARK: - Decision 10: the catalog waits for Browse

    /// **Nothing is contacted on launch any more.** The catalog used to load from
    /// `AccountPane`'s `.task`, so a reader who opened the app and added nothing had still had a
    /// third party told about them. It loads when they ask for it and not before.
    @Test("The directory is not contacted until Browse is pressed")
    func theCatalogWaitsForBrowse() async {
        let http = FixtureHTTP(["/servers": .text("[]")])
        let session = ShellSession(http: http, store: ItemStore())
        #expect(await http.paths.isEmpty, "the directory was contacted before anybody asked")

        session.browse()
        #expect(session.stage == .browsing)
        // `browse` starts the load rather than awaiting it, so the sheet is up at once.
        while await http.paths.isEmpty { await Task.yield() }
        #expect(await http.paths == ["/servers"])
    }

    /// The page's Browse button, which is a different press from the sheet's Back: a reader
    /// reading a preview did not ask for it to be replaced by a list.
    @Test("Browse is refused behind an open sheet, like every other way in from the page")
    func browseIsRefusedWhileTheSheetIsUp() async {
        let (session, _) = Self.forumSession()
        session.hostname = Self.forum
        await session.add()
        let opened = session.stage
        session.browse()
        #expect(session.stage == opened, "Browse replaced a preview the reader was reading")
    }

    /// **The directory is where a look is started from, so a row in it must be pressable.** The
    /// guard that stops a second look cannot be "any stage is up": browsing *is* a stage, and a
    /// row pressed in it is the very call being guarded. Without this the whole list is dead to
    /// the touch the moment Browse becomes a sheet — every row does nothing, silently.
    @Test("A row pressed in the directory opens its preview")
    func aRowInTheDirectoryOpensAPreview() async {
        let session = ShellSession(http: FixtureHTTP([
            "/servers": .text(#"""
            [{"domain": "install-c.example", "description": "A forum", "language": "en",
              "region": "europe", "category": "general", "total_users": 10,
              "last_week_users": 2, "approval_required": false, "proxied_thumbnail": null}]
            """#),
            "/": .text(Self.discuzFront),
            "https://\(Self.forum)/forum.php": .text(Self.discuzIndex),
        ]), store: ItemStore())

        session.browse()
        await session.loadCatalog()
        guard case .ready(let servers) = session.catalog, let row = servers.first else {
            Issue.record("the premise did not hold: catalog \(session.catalog)")
            return
        }

        await session.pick(row)

        #expect(session.stage?.host == Self.forum, "a row in the directory did nothing")
        #expect(session.choosing == nil)
        #expect(session.sources.isEmpty, "a row in the directory joined instead of looking")
    }

    /// **The sheet's own Back, which `browse()` cannot be.** A reader who picked a row off the
    /// directory and wants the directory again is at a preview by definition — so the guard that
    /// makes the page's Browse safe is exactly the guard this press must not have.
    @Test("Back from a preview reached through the directory returns to the directory")
    func backFromAPreviewReturnsToBrowsing() async {
        let (session, _) = Self.forumSession()
        session.hostname = Self.forum
        await session.add()
        #expect(session.stage != nil, "the premise did not hold: no preview was opened")

        session.backToBrowsing()

        #expect(session.stage == .browsing, "Back from a preview went nowhere")
        #expect(session.sources.isEmpty)

        // And it is a step back, not a dismissal: there is nothing behind the directory.
        session.backToBrowsing()
        #expect(session.stage == .browsing)
    }

    // MARK: - Ticks belong to one forum

    /// **The bug this rule exists for.** The tick set was hoisted out of a picker that was built
    /// fresh per presentation into a sheet that outlives the stage, so its name went on meaning
    /// "the boards ticked" while it had quietly become "the boards ticked at some point during
    /// this presentation". Reachable with the sheet's own buttons — boards(A) → Back → Back →
    /// row B → Subscribe — and Discuz! `fid`s are small integers that collide across forums as a
    /// matter of course, so the reader subscribes to boards of B they never ticked.
    @Test("Ticks made on one forum do not survive a move to another")
    func ticksDoNotCrossForums() {
        let held = JoinSheet.Ticks(picked: [33, 41], host: "a.example")
        #expect(JoinSheet.ticks(held, movingTo: Self.boards("b.example")).picked == [], """
            One forum's ticks were carried onto another's board list. Discuz! fids collide, so \
            this subscribes the reader to boards they never ticked.
            """)
        #expect(JoinSheet.ticks(held, movingTo: nil).picked == [])
        #expect(JoinSheet.ticks(held, movingTo: .browsing).picked == [])
        #expect(JoinSheet.ticks(JoinSheet.Ticks(), movingTo: Self.boards("a.example")).picked == [])
    }

    /// The other half, and why this is a rule rather than "clear it on every change": stepping
    /// back to the preview and forward to the boards again is one forum and one decision, so the
    /// reader does not lose eight ticks out of forty for looking at the description again.
    @Test("Ticks survive a step back to the preview and forward again")
    func ticksSurviveABackAndForth() {
        let held = JoinSheet.Ticks(picked: [33, 41], host: "a.example")
        #expect(JoinSheet.ticks(held, movingTo: Self.preview("a.example")).picked == [33, 41])
        #expect(JoinSheet.ticks(held, movingTo: Self.boards("a.example")).picked == [33, 41])
    }

    /// **The route to the bug, walked press by press.** The rule being right is not what was
    /// wrong last time — the bug this unit shipped green was a correct method called from the
    /// wrong place. So this threads the sheet's own state through the exact sequence the reader
    /// can perform with the sheet's own buttons, the way `.onChange` does, and asks what Subscribe
    /// would send at the end of it.
    @Test("Ticks on forum A never reach forum B's Subscribe, by the route that reaches it")
    func ticksSurviveTheAttackSequence() {
        let a = "a.example"
        let b = "b.example"
        // browsing → preview(A) → Subscribe → boards(A)
        var held = JoinSheet.Ticks()
        for stage in [JoinStage.browsing, Self.preview(a), Self.boards(a)] {
            held = JoinSheet.ticks(held, movingTo: stage)
        }
        // The reader ticks two boards on A.
        held.picked = [33, 41]
        // Back → preview(A) → Back → browsing → row B → preview(B) → Subscribe → boards(B)
        for stage in [Self.preview(a), JoinStage.browsing, Self.preview(b), Self.boards(b)] {
            held = JoinSheet.ticks(held, movingTo: stage)
        }

        #expect(held.picked.isEmpty, """
            A's ticks reached B's board list. `offer.boards.filter { picked.contains($0.fid) }` \
            then subscribes the reader to boards of B they never ticked, wherever fids collide.
            """)
        #expect(held.host == b)
    }

    private static func preview(_ host: String) -> JoinStage {
        .previewing(SourcePreview(host: host, kind: .discuz, profile: .stated(SourceProfile(
            host: host, kind: .discuz, readsWithoutAccount: true
        ))))
    }

    private static func boards(_ host: String) -> JoinStage {
        .choosingBoards(
            JoinOffer(host: host, kind: .discuz, categories: []),
            from: SourcePreview(host: host, kind: .discuz, profile: .stated(SourceProfile(
                host: host, kind: .discuz, readsWithoutAccount: true
            )))
        )
    }

    // MARK: - Which button calls which method

    /// **The one bug this control has already had was a button calling the wrong method**, and it
    /// was invisible: Back from a preview called `browse()`, which refuses while a sheet is up,
    /// so the button did nothing and all 405 tests stayed green. The rule and the press are both
    /// pinned here; only the `Button` label itself is out of a test's reach.
    @Test("Each stage offers the button that matches what is behind the reader")
    func eachStageOffersItsOwnLeadingButton() {
        let preview = SourcePreview(
            host: Self.forum, kind: .discuz, profile: .silent(host: Self.forum, kind: .discuz)
        )
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        #expect(JoinSheet.leading(for: nil, cameFromBrowsing: false) == nil)
        #expect(JoinSheet.leading(for: .browsing, cameFromBrowsing: false) == .close)
        // A preview reached from the field has the field behind it; one reached from a row has
        // the directory. Same stage, different answer — §2.2's rule by shape, not by history.
        #expect(JoinSheet.leading(for: .previewing(preview), cameFromBrowsing: false) == .cancel)
        #expect(
            JoinSheet.leading(for: .previewing(preview), cameFromBrowsing: true) == .backToBrowsing
        )
        #expect(
            JoinSheet.leading(for: .choosingBoards(offer, from: preview), cameFromBrowsing: false)
                == .backToPreview
        )

        // And every one of them is a word, in every language.
        for button in [JoinSheet.Leading.close, .backToBrowsing, .backToPreview, .cancel] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(button.key, language: language) != button.key)
            }
        }
    }

    /// And what each one actually does when it is pressed — the switch the shipped bug lived in.
    @Test("Pressing each leading button lands the reader where its word promises")
    func pressingALeadingButtonDoesWhatItSays() async {
        let (browsing, _) = Self.forumSession()
        browsing.browse()
        JoinSheet.press(.close, on: browsing)
        #expect(browsing.stage == nil)

        let (cancelling, _) = Self.forumSession()
        cancelling.hostname = Self.forum
        await cancelling.add()
        JoinSheet.press(.cancel, on: cancelling)
        #expect(cancelling.stage == nil)

        let (back, _) = Self.forumSession()
        back.hostname = Self.forum
        await back.add()
        JoinSheet.press(.backToBrowsing, on: back)
        #expect(back.stage == .browsing, "Back to the directory went nowhere")

        let (boards, _) = Self.forumSession()
        boards.hostname = Self.forum
        await boards.add()
        await boards.confirm()
        #expect(boards.choosing != nil, "the premise: the boards were reached")
        JoinSheet.press(.backToPreview, on: boards)
        #expect(boards.stage?.host == Self.forum)
        #expect(boards.choosing == nil, "Back from the boards stayed on the boards")
    }

    // MARK: - Leaving

    /// **A picture pulled for a server the reader did not take is a byte nobody can account for.**
    /// `ShellPictures` tags an entry by host and Preferences lists the hosts in `sources`, so a
    /// thumbnail fetched for a host that was only looked at would be held for the run and appear
    /// in no inventory. `forget(host:)` bumps the generation unconditionally, which is what makes
    /// the press visible here at all.
    @Test("Backing out of a preview forgets what was fetched for it; taking it does not")
    func leavingAPreviewForgetsItsPictures() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let leaving = ShellSession(http: FixtureHTTP(Self.forumRoutes()), pictures: pictures)
        leaving.hostname = Self.forum
        await leaving.add()
        let before = pictures.generation

        leaving.dismissStage()
        #expect(pictures.generation > before, "a host only looked at kept its pictures")

        // And a host that *is* a source keeps them, because the reader is still reading it.
        let kept = ShellPictures(http: FixtureHTTP())
        let staying = ShellSession(http: FixtureHTTP(Self.forumRoutes()), pictures: kept)
        staying.sources = [Source(host: Self.forum, kind: .discuz)]
        staying.stage = .previewing(SourcePreview(
            host: Self.forum, kind: .discuz, profile: .silent(host: Self.forum, kind: .discuz)
        ))
        let held = kept.generation
        staying.dismissStage()
        #expect(kept.generation == held, "a joined server's pictures were dropped on a dismissal")
    }

    @Test("A stage names the server it is about, and browsing names none")
    func aStageNamesItsServer() {
        let preview = SourcePreview(
            host: Self.forum, kind: .discuz, profile: .silent(host: Self.forum, kind: .discuz)
        )
        #expect(JoinStage.browsing.host == nil)
        #expect(JoinStage.previewing(preview).host == Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])
        #expect(JoinStage.choosingBoards(offer, from: preview).host == Self.forum)
    }

    // MARK: - What the preview says

    /// **Every protocol has an outcome sentence, and none of them is a key echoed back.** The
    /// switch has no `default:`, so units 6–8 break the build here; this is the other half —
    /// every case it names has a string behind it in the language the reader is in.
    @Test("Every protocol's outcome line is a sentence in all three languages")
    func everyOutcomeLineIsASentence() {
        // `allCases`, not a list written out here: a thirteenth protocol must be covered the day
        // it is added, not the day somebody remembers this test exists.
        for kind in ProtocolKind.allCases {
            let key = JoinSheet.outcomeKey(kind)
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(kind) has no sentence")
            }
        }
        // A forum's two answers are its own, and neither is the microblog sentence.
        #expect(JoinSheet.outcomeKey(.discuz) == "join.preview.next.boards")
        #expect(JoinSheet.outcomeKey(.discourse) == "join.preview.next.forum")
        #expect(JoinSheet.outcomeKey(.mastodon) == "join.preview.next.microblog")
    }

    @Test("Every way a profile could not be read has a sentence of its own")
    func everyUnreadProfileHasASentence() {
        let reasons: [ProfileError] = [.unreachable, .refused(403), .unreadable]
        var said: Set<String> = []
        for reason in reasons {
            let sentence = JoinSheet.unreadMessage(reason)
            #expect(!sentence.hasPrefix("join.preview.unread."), "\(reason) has no sentence")
            said.insert(sentence)
        }
        #expect(said.count == 3, "two reasons were told to the reader as the same sentence")
        #expect(JoinSheet.unreadMessage(.refused(429)).contains("429"))
    }

    @Test("Every registration state has a sentence of its own")
    func everyRegistrationStateHasASentence() {
        let states: [SourceProfile.Registration] = [.open, .byApproval, .closed]
        var said: Set<String> = []
        for state in states {
            let key = JoinSheet.registrationKey(state)
            #expect(L10n.t(key, language: .english) != key, "\(state) has no sentence")
            said.insert(key)
        }
        #expect(said.count == 3)
    }

    /// **`nil` is not a warning.** A Mastodon has no `login_required` idea at all, so the field is
    /// nothing there — and a preview that drew "reading this needs an account" over every Mastodon
    /// would be the strongest sentence on the screen, said about nothing.
    @Test("Only a server that said so is warned about")
    func onlyAStatedRefusalWarns() {
        func preview(_ reads: Bool?) -> SourcePreview {
            SourcePreview(host: "a.example", kind: .discourse, profile: .stated(SourceProfile(
                host: "a.example", kind: .discourse, readsWithoutAccount: reads
            )))
        }
        #expect(JoinSheet.warns(preview(false)))
        #expect(!JoinSheet.warns(preview(true)))
        #expect(!JoinSheet.warns(preview(nil)), "a field the protocol has no idea of was a warning")
        #expect(!JoinSheet.warns(SourcePreview(
            host: "a.example", kind: .discuz, profile: .silent(host: "a.example", kind: .discuz)
        )))
    }

    /// **The warning has to reach the protocol it was designed for.** `warns` answers false for
    /// anything but a `.stated` profile, and a Discuz! preview used to be `.silent` — so the one
    /// affordance built for "reading this needs an account" was structurally unreachable for
    /// exactly the protocol where login walls are the norm. The index probe is what closes that:
    /// a forum that turns a signed-out reader away now states so, and the lock fires.
    @Test("A forum that turns a stranger away is a forum the preview warns about")
    func aClosedForumWarns() async {
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://\(Self.forum)/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div id="ct"><div id="messagetext" class="alert_info">
            <p>抱歉，您的权限不足，无法访问本版块。</p>
            </div></div></body></html>
            """#),
        ]), store: ItemStore())
        session.hostname = Self.forum
        await session.add()

        guard case .previewing(let preview) = session.stage else {
            Issue.record("a forum that refuses should still be previewed, not refused outright")
            return
        }
        #expect(JoinSheet.warns(preview), """
            The lock warning cannot fire for a Discuz!, which is the protocol it was designed \
            for. A preview that cannot say "this needs an account" is the affordance missing.
            """)
        #expect(session.refuse == nil, "a prediction was reported as a refusal")
        #expect(session.sources.isEmpty)
    }

    /// **The warning widens rather than disappearing.** The ruling that stopped a doorman being
    /// recorded as the forum's policy must not cost the reader the warning the user asked for —
    /// it has to say something different, because it *is* something different: one is the
    /// forum's own rule, the other is a filter, and a sign-in is the remedy for both.
    @Test("A forum behind a filter is warned about, in different words from a forum that is shut")
    func aTurnedAwayForumWarnsDifferently() async {
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://\(Self.forum)/forum.php": .text(#"""
            <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head>
            <body><p>Enable JavaScript and cookies to continue</p></body></html>
            """#),
        ]), store: ItemStore())
        session.hostname = Self.forum
        await session.add()

        guard case .previewing(let preview) = session.stage else {
            Issue.record("a forum behind a filter should still be previewed, not refused outright")
            return
        }
        #expect(JoinSheet.caution(preview) == .turnedAway, """
            A forum behind a filter is warned about with the wrong sentence, or not at all. \
            The ruling that split it from the forum's own policy must not cost the warning.
            """)
        // The press is still theirs, and is still the thing that fails — a prediction, not a
        // refusal that has happened.
        #expect(session.refuse == nil)
        #expect(JoinSheet.warns(preview), "Return was left on a press the screen warned about")

        // And the two cautions do not say the same thing in any language.
        for language in [DummyLanguage.english, .taiwanese] {
            let shut = L10n.t(JoinSheet.Caution.needsAccount.key, language: language)
            let filtered = L10n.t(JoinSheet.Caution.turnedAway.key, language: language)
            #expect(shut != filtered, "two different facts were given one sentence")
            #expect(filtered != JoinSheet.Caution.turnedAway.key, "no sentence in \(language)")
        }
    }

    /// The rest of the read failures are **not** cautions. "We could not read its description"
    /// says nothing about whether this server can be joined — an old Mastodon serves no profile
    /// at all and reads perfectly — so warning about it would talk the reader out of a server
    /// that works, which is the whole reason `.unread` does not throw.
    @Test("Only a refusal among the read failures predicts the press")
    func onlyARefusalAmongReadFailuresWarns() {
        func preview(_ error: ProfileError) -> SourcePreview {
            SourcePreview(host: "a.example", kind: .mastodon, profile: .unread(
                host: "a.example", kind: .mastodon, error
            ))
        }
        #expect(JoinSheet.caution(preview(.refused(403))) == .turnedAway)
        #expect(JoinSheet.caution(preview(.unreadable)) == nil)
        #expect(JoinSheet.caution(preview(.unreachable)) == nil)
        #expect(JoinSheet.caution(SourcePreview(
            host: "a.example", kind: .discuz, profile: .unasked(host: "a.example", kind: .discuz)
        )) == nil)
    }

    /// One word per shape, and the same one the source row will use — §1.1. `.board` is
    /// unreachable from `shape(of:)` and still has an answer, because a case with no answer is a
    /// key echoed back on somebody's screen.
    ///
    /// **Asked rather than assigned.** This test used to set `L10n.language` in its own loop.
    /// `L10n.language` is a `nonisolated(unsafe) static var` that nine suite `init`s write, and
    /// suites run in parallel — so between this test's two lines another suite's test could read a
    /// language this one had just set for itself, and fail for a reason nowhere near it. Nothing
    /// here was ever wrong about shapes; it was a flake waiting on scheduling, and the parameter
    /// on `shapeWord` is what lets it go away.
    @Test("Every shape has one word, in every language")
    func everyShapeHasAWord() {
        for shape in [DummySourceKind.microblog, .forum, .board, .video] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(!DummyItem.shapeWord(shape, language: language).hasPrefix("source.shape."))
            }
        }
        #expect(DummyItem.shapeWord(.forum, language: .english)
            == DummyItem.shapeWord(.board, language: .english))
        #expect(DummyItem.shapeWord(.microblog, language: .english) == "microblog")
        #expect(DummyItem.shapeWord(.video, language: .english) == "video")
    }

    /// **A server the reader removed mid-subscribe does not come back** — the finding QA left on
    /// unit 3, reachable from the moment a row draws a Remove button.
    ///
    /// The shape is risk 9's exactly: `DiscuzBoardJoin.subscribe` reads one board per request and
    /// writes `add`, `subscribe` and `ingest` at the *end* of all of them, so a pick of several
    /// boards keeps the wire busy for seconds — ample time to press Remove — and then puts the
    /// source and every board pick back behind the reader.
    ///
    /// Driven through the gate rather than by arranging the calls to interleave by luck: the press
    /// is parked inside Core with the store not yet written, which is the one moment the bug
    /// exists in.
    @Test("A server removed while its boards are still being read does not come back")
    func aRemovedSourceIsNotResurrectedByAnInFlightSubscribe() async {
        let board = "https://\(Self.forum)/forum.php?mod=forumdisplay&fid=33"
        var routes = Self.forumRoutes()
        routes[board] = .text(Self.oneBoard)
        let http = GatedHTTP(routes, holding: board)
        let session = ShellSession(http: http, store: ItemStore())
        // Armed before anything awaits, for the reason the two tests above give: nothing else
        // releases this gate, and `.timeLimit` does not rescue a task held on a continuation.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        session.hostname = Self.forum
        await session.add()
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused for the reader to choose")
            return
        }

        let press = Task { await session.subscribe(offer.boards.filter { $0.fid == 33 }) }
        #expect(await Self.spun { session.checking }, "the pick never reached the wire")

        // The reader presses Remove while the boards are being read one at a time.
        await session.remove(host: Self.forum)
        await http.gate.open()
        await press.value

        #expect(session.sources.isEmpty, """
            The subscribe wrote the source back after the reader removed it. A press cannot \
            resurrect a server, and the generation token is what says so.
            """)
        #expect(session.notes.isEmpty, "its threads came back with it")
        #expect(session.queries.isEmpty, "and its board tabs came back with them")
        #expect(await session.store.sources().isEmpty, """
            The list agrees and the store does not, which is the worse half: the source is added \
            and invisible until something else happens to refresh the list.
            """)
        #expect(session.unread.isEmpty, "a sentence was left about a server that is gone")
    }

    /// The other side of the same token: **a Remove of a *different* server must not abandon this
    /// one's subscribe.** `remove` bumps `errand` only where `progressHost` names the host going
    /// away, and that narrowing is what this pins.
    ///
    /// **Driven in flight, which the first version of this test was not.** It called `remove`
    /// *before* `subscribe`, and `subscribe` bumps the token at entry and reads `mine` after — so
    /// `mine == errand` held whatever the earlier Remove had done, and QA showed that making the
    /// bump unconditional, which is exactly the narrowing this test exists to protect, left the
    /// whole suite green. The Remove has to land while the boards are on the wire, so the gate is
    /// the only way to write it.
    @Test("Removing one server does not abandon a subscribe to a different one")
    func removingOneServerLeavesAnotherSubscribeAlone() async {
        let board = "https://\(Self.forum)/forum.php?mod=forumdisplay&fid=33"
        var routes = Self.forumRoutes()
        routes[board] = .text(Self.oneBoard)
        let http = GatedHTTP(routes, holding: board)
        let session = ShellSession(http: http, store: ItemStore())
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        await session.store.add(Source(host: "elsewhere.example", kind: .mastodon))
        session.sources = await session.store.sources()

        session.hostname = Self.forum
        await session.add()
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused for the reader to choose")
            return
        }

        let press = Task { await session.subscribe(offer.boards.filter { $0.fid == 33 }) }
        #expect(await Self.spun { session.checking }, "the pick never reached the wire")

        // Somebody else's server goes, while this errand is about the forum and parked on a board.
        await session.remove(host: "elsewhere.example")
        await http.gate.open()
        await press.value

        #expect(session.sources.map(\.host) == [Self.forum], """
            The pick was thrown away by a Remove that had nothing to do with it. The token is \
            bumped only where the errand is about the host that went.
            """)
        #expect(session.sources.first?.boards.map(\.fid) == [33])
        #expect(!session.notes.isEmpty, "its threads went with the pick")
    }

    /// The header's spoken line, which the source row reuses from the same key so that the same
    /// server is described the same way before and after the press.
    @Test("A preview says its host, its protocol and its shape out loud")
    func aPreviewSpeaksItself() {
        let spoken = JoinSheet.spoken(SourcePreview(
            host: Self.forum, kind: .discuz, profile: .silent(host: Self.forum, kind: .discuz)
        ))
        #expect(spoken.contains(Self.forum))
        #expect(spoken.contains("Discuz!"))
        #expect(spoken.contains("forum"))
    }

    /// **Unit 5 reads this map, and it costs no request.** The look the reader already waited for
    /// is what fills it, keyed by the parsed host rather than by what they typed.
    @Test("The look records what the server said, under the host it was parsed to")
    func theLookRecordsWhatWasSaid() async {
        let (session, _) = Self.forumSession()
        session.hostname = "  HTTPS://\(Self.forum)/forum.php  "
        await session.add()
        #expect(session.profiles[Self.forum] == .stated(SourceProfile(
            host: Self.forum, kind: .discuz, readsWithoutAccount: true
        )))
        #expect(session.profiles.count == 1, "one server left two rows in the map")
    }
}
