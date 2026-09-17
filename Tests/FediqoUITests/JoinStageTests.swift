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
    /// A second forum, for the tests about a look replacing a look.
    private static let other = "install-d.example"

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

        /// Whether the held address has actually been asked for.
        ///
        /// **`checking` is not a discriminator between two phases of one press.** A look and the
        /// take after it both set it, so a test that spins on `checking` alone asserts against
        /// whichever phase it happened to catch — and a resumed sign-in runs both, back to back,
        /// with no await between the look returning and the take claiming the errand. This says
        /// *the take is parked on the wire*, which is the state those tests are about.
        private(set) var reached = false

        /// Matched on the path as well as the whole address, because a Mastodon's timeline
        /// carries a query this test has no business knowing the value of.
        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            if url.absoluteString == held || url.path == held {
                reached = true
                await gate.wait()
            }
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
    ///
    /// **Driven from the directory, which is where this stays true.** A preview reached from a
    /// catalogue row is drawn over the page in the sheet, so the reader cannot see what a second
    /// look would replace. One reached by typing is drawn beside the field, and that case is the
    /// test below.
    @Test("A second Add behind a preview the reader cannot see past changes nothing")
    func aSecondAddIsRefusedWhileTheSheetIsUp() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add(from: .directory)
        let opened = session.stage
        #expect(opened != nil, "the premise did not hold: no preview was opened")
        #expect(opened?.surface == .sheet, "the premise did not hold: this preview is in the page")
        let asked = await http.paths.count

        session.hostname = "somewhere.else.example"
        await session.add(from: .field)

        #expect(session.stage == opened, "a second look replaced the stage behind the reader")
        #expect(await http.paths.count == asked, "a second look was spent on a refused press")
    }

    /// **The other half of splitting `busy`, and the half that makes the first half honest.**
    /// `AccountPane` re-enables the field beside an inline preview, because the block is beside it
    /// and not over it. If `look`'s guard had stayed `stage?.host == nil`, Return and the
    /// magnifier would both be live and both refused three files away — a control that does
    /// nothing, which is unit 5b's defect and risk 12's whole class.
    @Test("A second hostname typed beside an inline preview replaces it")
    func aSecondAddIsTakenBesideAnInlinePreview() async {
        var routes = Self.forumRoutes()
        routes["https://\(Self.other)/forum.php"] = .text(Self.discuzIndex)
        let session = ShellSession(http: FixtureHTTP(routes), store: ItemStore())

        session.hostname = Self.forum
        await session.add(from: .field)
        #expect(session.stage?.inlinePreview?.host == Self.forum, "the premise: a block in the page")

        session.hostname = Self.other
        await session.add(from: .field)

        #expect(session.stage?.inlinePreview?.host == Self.other, """
            The field was live beside the block and its Return did nothing — the shape this \
            branch has now shipped four times.
            """)
    }

    /// The same guard from the other side: a press cannot start while one is on the wire.
    @Test("Subscribe does nothing while a press is already in flight")
    func confirmIsRefusedWhileChecking() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add(from: .field)
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
        ), from: .field, ticked: [])

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
        await session.add(from: .field)

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
        await looking.add(from: .field)
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
        await pressing.add(from: .field)
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
        await session.add(from: .field)
        guard case .previewing(let looked, _, _) = session.stage else {
            Issue.record("a look should open a preview")
            return
        }
        await session.confirm()
        #expect(session.choosing != nil, "the premise did not hold: the boards were not reached")
        let asked = await http.paths

        session.backToPreview()

        #expect(session.stage == .previewing(looked, from: .field, ticked: []), "Back landed somewhere else")
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

    /// **The sheet also goes away when the stage stops being a sheet, and that is not a
    /// dismissal.** On the inline route Back flips the surface to `.pane` while the sheet is up,
    /// so SwiftUI takes the sheet down and can re-enter the presentation binding's setter —
    /// arriving at `sheetDismissed()` with the stage already at `.previewing(_, .field)`. Read as
    /// a dismissal it answers `dismissStage()`, which deletes the preview the reader has just
    /// stepped back onto and the ticks with it.
    ///
    /// Pre-existing, and it is what makes decision 27's ticks worth protecting rather than merely
    /// stored. Neither the binding nor the swipe is reachable from a test; the method both land on
    /// is, which is why it is a method.
    @Test("A sheet going away because the stage moved to the page is not a dismissal")
    func aSheetLeavingForThePageIsNotADismissal() async {
        let (session, _) = Self.forumSession()
        session.hostname = Self.forum
        await session.add(from: .field)
        await session.confirm()
        #expect(session.stage?.surface == .sheet, "the premise: the boards opened in the sheet")
        session.stage = session.stage?.ticking([33, 41])

        session.backToPreview()
        let landed = session.stage
        #expect(landed?.surface == .pane, "the premise: Back put the reader on the page")

        // SwiftUI now tears the sheet down, and the binding's setter calls this.
        session.sheetDismissed()

        #expect(session.stage == landed, """
            A sheet taken down because the stage moved to the page was read as the reader \
            dismissing it, and the preview they had just stepped back onto was deleted.
            """)
        #expect(session.stage?.ticked == [33, 41], "the reader's ticks went with the sheet")

        // And a real dismissal of a sheet-surfaced stage still does what it always did.
        session.stage = .browsing
        session.sheetDismissed()
        #expect(session.stage == nil)
    }

    /// **The guard that used to be a dead button, and is now a refusal nothing can reach.**
    /// `backToPreview()` returns silently for a restate because there is no preview behind one —
    /// which was unreachable while nothing constructed `.joined`, and is now unreachable because
    /// `leading(for:)` offers that stage Cancel instead. Both halves are pinned, so a later round
    /// that changes one has to change the other.
    @Test("A restate has no Back: the button is Cancel, and Back refuses if it is reached anyway")
    func aRestateHasNoBack() async {
        let (session, _) = Self.forumSession()
        let restate = JoinStage.choosingBoards(
            JoinOffer(host: Self.forum, kind: .discuz, categories: []),
            from: .joined(subscribed: [], ticked: [])
        )
        session.stage = restate

        session.backToPreview()
        #expect(session.stage == restate, "a restate stepped back to a preview it never had")

        // And the button the reader is actually given takes the whole thing down, changing
        // nothing — which is what Cancel promises and what `sheetDismissed` already agreed.
        JoinSheet.press(.cancel, on: session)
        #expect(session.stage == nil)
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
    ///
    /// **From the directory, where the reader cannot see past the sheet.** The typed-host case is
    /// the test below, and it goes the other way for the same reason `look`'s does.
    @Test("Browse is refused behind a preview the reader cannot see past")
    func browseIsRefusedWhileTheSheetIsUp() async {
        let (session, _) = Self.forumSession()
        session.hostname = Self.forum
        await session.add(from: .directory)
        let opened = session.stage
        session.browse()
        #expect(session.stage == opened, "Browse replaced a preview the reader was reading")
    }

    /// Browse sits beside the field, and an inline preview covers neither. A Browse refused under
    /// a button the reader can see and press is the dead control this branch has shipped four
    /// times — and the replaced preview still has to forget the picture it pulled, or a host that
    /// was never joined holds bytes that appear in no inventory.
    @Test("Browse beside an inline preview opens the directory, and forgets what it replaced")
    func browseIsTakenBesideAnInlinePreview() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        var routes = Self.forumRoutes()
        routes["/servers"] = .text("[]")
        let session = ShellSession(
            http: FixtureHTTP(routes), store: ItemStore(), pictures: pictures
        )
        session.hostname = Self.forum
        await session.add(from: .field)
        #expect(session.stage?.inlinePreview != nil, "the premise: a block in the page")
        let before = pictures.generation

        session.browse()

        #expect(session.stage == .browsing, "Browse did nothing beside a block it does not sit under")
        #expect(pictures.generation > before, """
            A preview replaced by Browse kept the picture it pulled for a host nobody joined.
            """)
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
        // Through the directory, which is what this test is named for. `backToBrowsing()` is
        // origin-blind, so a typed host passed here too — and the test then proved nothing about
        // the entrance its own sentence is about.
        await session.add(from: .directory)
        #expect(session.stage?.surface == .sheet, "the premise: a preview with a directory behind it")

        session.backToBrowsing()

        #expect(session.stage == .browsing, "Back from a preview went nowhere")
        #expect(session.sources.isEmpty)

        // And it is a step back, not a dismissal: there is nothing behind the directory.
        session.backToBrowsing()
        #expect(session.stage == .browsing)
    }

    // MARK: - Ticks belong to one forum

    /// **The bug this used to be a rule about, and is now a shape.** The tick set lived in
    /// `JoinSheet` as a `@State` set plus the host it was made on, so "the boards ticked" had
    /// quietly become "the boards ticked at some point during this presentation" — reachable with
    /// the sheet's own buttons, boards(A) → Back → Back → row B → Subscribe, and Discuz! `fid`s
    /// are small integers that collide across forums as a matter of course.
    ///
    /// **The ticks now live in the stage** (decision 27), and a stage names exactly one forum. So
    /// there is no rule left to remember on a stage change: B's stage simply has B's ticks in it,
    /// whatever A's had. This pins that the shape does the work.
    @Test("Ticks made on one forum are not in another forum's stage")
    func ticksDoNotCrossForums() {
        let onA = Self.boards("a.example").ticking([33, 41])
        #expect(onA.ticked == [33, 41])
        #expect(Self.boards("b.example").ticked == [], """
            One forum's ticks were carried onto another's board list. Discuz! fids collide, so \
            this subscribes the reader to boards they never ticked.
            """)
        #expect(JoinStage.browsing.ticked == [], "the directory names no forum to tick boards on")
        #expect(JoinStage.browsing.ticking([33, 41]).ticked == [])
        #expect(Self.preview("a.example").ticked == [], "a fresh look opens nothing ticked")
    }

    /// The other half: stepping back to the preview and forward to the boards again is one forum
    /// and one decision, so the reader does not lose eight ticks out of forty for looking at the
    /// description again — **on either surface**, which is what decision 27 bought. It used to be
    /// true from the directory only, by the accident that the sheet stayed mounted there.
    @Test("Ticks survive a step back to the preview and forward again, from either entrance")
    func ticksSurviveABackAndForth() async {
        for origin in [JoinEntrance.field, .directory] {
            let (session, _) = Self.forumSession()
            session.hostname = Self.forum
            await session.add(from: origin)
            await session.confirm()
            #expect(session.choosing != nil, "the premise: the boards were reached")

            session.stage = session.stage?.ticking([33, 41])
            session.backToPreview()
            #expect(session.stage?.ticked == [33, 41], """
                Stepping back to the preview dropped the reader's ticks. From the field the sheet \
                unmounts on Back, and before decision 27 it took them with it.
                """)

            await session.confirm()
            #expect(session.stage?.ticked == [33, 41], "the picker did not reopen ticked")
        }
    }

    /// **The route to the bug, walked press by press.** The rule being right was never what was
    /// wrong — the bug this branch shipped green was a correct method called from the wrong place.
    /// So this walks the exact sequence the reader can perform with the sheet's own buttons and
    /// asks what Subscribe would send at the end of it.
    @Test("Ticks on forum A never reach forum B's Subscribe, by the route that reaches it")
    func ticksSurviveTheAttackSequence() async {
        var routes = Self.forumRoutes()
        routes["https://\(Self.other)/forum.php"] = .text(Self.discuzIndex)
        let session = ShellSession(http: FixtureHTTP(routes), store: ItemStore())
        // browsing → row A → preview(A) → Subscribe → boards(A)
        session.browse()
        session.hostname = Self.forum
        await session.add(from: .directory)
        await session.confirm()
        // The reader ticks two boards on A.
        session.stage = session.stage?.ticking([33, 41])
        // Back → preview(A) → Back → browsing → row B → preview(B) → Subscribe → boards(B)
        session.backToPreview()
        session.backToBrowsing()
        session.hostname = Self.other
        await session.add(from: .directory)
        await session.confirm()

        #expect(session.stage?.host == Self.other, "the premise: the reader reached B")
        #expect(session.stage?.ticked.isEmpty == true, """
            A's ticks reached B's board list. `offer.boards.filter { picked.contains($0.fid) }` \
            then subscribes the reader to boards of B they never ticked, wherever fids collide.
            """)
    }

    private static func preview(_ host: String) -> JoinStage {
        .previewing(previewOf(host), from: .directory, ticked: [])
    }

    private static func boards(_ host: String) -> JoinStage {
        .choosingBoards(
            JoinOffer(host: host, kind: .discuz, categories: []),
            from: .preview(previewOf(host), from: .directory, ticked: [])
        )
    }

    private static func previewOf(_ host: String) -> SourcePreview {
        SourcePreview(host: host, kind: .discuz, profile: .stated(SourceProfile(
            host: host, kind: .discuz, readsWithoutAccount: true
        )))
    }

    // MARK: - Decision 20: the entrance travels in the stage

    /// **The two presenters cannot both fire, because they read one function of one value.**
    /// `FediqoRootView` puts the sheet up at `.sheet` and `AccountPane` draws the block at
    /// `.pane`; before this, the sheet's getter was `stage != nil` and would have put an empty
    /// sheet over a preview drawn in the page.
    @Test("Every stage says which surface draws it, and only one of them is the page")
    func everyStageNamesItsSurface() {
        let preview = Self.previewOf(Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        #expect(JoinStage.browsing.surface == .sheet)
        #expect(JoinStage.previewing(preview, from: .field, ticked: []).surface == .pane)
        #expect(JoinStage.previewing(preview, from: .directory, ticked: []).surface == .sheet)
        #expect(JoinStage.choosingBoards(offer, from: .preview(preview, from: .field, ticked: [])).surface
            == .sheet, "decision 21: a typed host's boards open the sheet, not the page")
        #expect(JoinStage.choosingBoards(offer, from: .joined(subscribed: [], ticked: [])).surface == .sheet)
    }

    /// **The page keeps drawing its block while the boards sheet stands on it** — §1.5(b). A pane
    /// that asked `if case .previewing` would blank the block the moment Subscribe opened the
    /// picker and rebuild it on Back, which is the page throwing the reader somewhere and then
    /// throwing them back.
    @Test("The page knows which preview it is drawing, including under an open sheet")
    func thePageKnowsWhatItIsDrawing() {
        let preview = Self.previewOf(Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        #expect(JoinStage.browsing.inlinePreview == nil)
        #expect(JoinStage.previewing(preview, from: .field, ticked: []).inlinePreview?.host == Self.forum)
        #expect(JoinStage.previewing(preview, from: .directory, ticked: []).inlinePreview == nil)
        #expect(
            JoinStage.choosingBoards(offer, from: .preview(preview, from: .field, ticked: []))
                .inlinePreview?.host == Self.forum,
            "the block went down the moment the boards sheet opened over it"
        )
        #expect(JoinStage.choosingBoards(offer, from: .preview(preview, from: .directory, ticked: []))
            .inlinePreview == nil, "the page drew a block for a preview that lives in the sheet")
        #expect(JoinStage.choosingBoards(offer, from: .joined(subscribed: [], ticked: [])).inlinePreview == nil)
    }

    /// The rule the field and Browse are both gated on. Pinned as a value, because the two
    /// controls that read it are in a `View` body and a session guard respectively, and those two
    /// disagreeing is how a live control gets refused three files away.
    @Test("Only a stage the reader can see past admits a second look")
    func onlyAVisibleStageAdmitsASecondLook() {
        let preview = Self.previewOf(Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        #expect(JoinStage.browsing.admitsASecondLook, "the directory's own rows are looks")
        #expect(JoinStage.previewing(preview, from: .field, ticked: []).admitsASecondLook)
        #expect(!JoinStage.previewing(preview, from: .directory, ticked: []).admitsASecondLook)
        #expect(!JoinStage.choosingBoards(offer, from: .preview(preview, from: .field, ticked: []))
            .admitsASecondLook)
        #expect(!JoinStage.choosingBoards(offer, from: .joined(subscribed: [], ticked: [])).admitsASecondLook)
    }

    /// **A swipe on the boards sheet is Back and not Cancel** — §1.5(d). The setter this replaces
    /// called `dismissStage()`, which would cancel the whole errand and take an inline block the
    /// reader can see down with it. Neither the binding nor the swipe is reachable from a test;
    /// the method both of them land on is, which is why it is a method.
    @Test("A swipe on the boards sheet steps back rather than cancelling the errand")
    func aSwipeOnTheBoardsStepsBack() {
        let preview = Self.previewOf(Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        let fromPage = ShellSession(http: FixtureHTTP())
        fromPage.stage = .choosingBoards(offer, from: .preview(preview, from: .field, ticked: []))
        fromPage.sheetDismissed()
        #expect(fromPage.stage == .previewing(preview, from: .field, ticked: []), """
            A swipe on the boards sheet cancelled the errand and took the page's block with it.
            """)

        let fromSheet = ShellSession(http: FixtureHTTP())
        fromSheet.stage = .choosingBoards(offer, from: .preview(preview, from: .directory, ticked: []))
        fromSheet.sheetDismissed()
        #expect(fromSheet.stage == .previewing(preview, from: .directory, ticked: []))

        // Every other stage is a complete cancel, as it was.
        for stage in [JoinStage.browsing, .previewing(preview, from: .directory, ticked: [])] {
            let leaving = ShellSession(http: FixtureHTTP())
            leaving.stage = stage
            leaving.sheetDismissed()
            #expect(leaving.stage == nil)
        }
    }

    /// **The same leak as Browse's, down the other route, and it had no test.** A reader who types
    /// a second hostname over an inline preview has left the first server — and `dismissStage`,
    /// which is what forgets a looked-at host's pictures, is never reached on this path because
    /// the stage is overwritten rather than cleared. The route only exists because the field is
    /// live beside the block, so it arrived with this unit.
    @Test("A second hostname typed over a block forgets the picture the first one pulled")
    func replacingAnInlinePreviewForgetsItsPicture() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        var routes = Self.forumRoutes()
        routes["https://\(Self.other)/forum.php"] = .text(Self.discuzIndex)
        let session = ShellSession(
            http: FixtureHTTP(routes), store: ItemStore(), pictures: pictures
        )

        session.hostname = Self.forum
        await session.add(from: .field)
        #expect(session.stage?.inlinePreview?.host == Self.forum, "the premise: a block in the page")
        let before = pictures.generation

        session.hostname = Self.other
        await session.add(from: .field)

        #expect(session.stage?.inlinePreview?.host == Self.other, "the premise: the block was replaced")
        #expect(pictures.generation > before, """
            A preview replaced by a second typed hostname kept the picture it pulled. The host was \
            never joined, so `PreferencesPane` lists no such server and those bytes are held for \
            the run in an inventory nobody can see.
            """)
    }

    /// And the two guards on it, because a forget that fires too eagerly is its own defect: a host
    /// the reader did join keeps its pictures, and a re-look of the same host does not drop the one
    /// it is about to draw.
    @Test("Replacing a block forgets nothing it should keep")
    func replacingAnInlinePreviewKeepsWhatItShould() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let session = ShellSession(
            http: FixtureHTTP(Self.forumRoutes()), store: ItemStore(), pictures: pictures
        )

        session.hostname = Self.forum
        await session.add(from: .field)
        let before = pictures.generation

        // The same host looked at again: the picture being dropped is the one about to be drawn.
        session.hostname = Self.forum
        await session.add(from: .field)
        #expect(pictures.generation == before, "a re-look dropped the picture it was re-drawing")
    }

    /// **The block's own Subscribe stops being the live one the moment the boards sheet opens over
    /// it.** Two live Subscribe buttons on two surfaces at once is the two-presenters failure in a
    /// new shape — and the gate saying so lived inside a `View` body, where nothing could read it.
    @Test("The block's actions are live only while the preview is the stage")
    func theBlocksActionsAreLiveOnlyAtThePreview() {
        let preview = Self.previewOf(Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])

        #expect(AccountPane.actionsLive(at: .previewing(preview, from: .field, ticked: [])))
        let overIt = JoinStage.choosingBoards(offer, from: .preview(preview, from: .field, ticked: []))
        #expect(!AccountPane.actionsLive(at: overIt), """
            The block kept a live Subscribe under the boards sheet standing on it.
            """)
        #expect(!AccountPane.actionsLive(at: .browsing))
        #expect(!AccountPane.actionsLive(at: nil))
        // The block is drawn for exactly these stages, and it is disabled in all but the first.
        for stage in [JoinStage.previewing(preview, from: .field, ticked: []),
                      .choosingBoards(offer, from: .preview(preview, from: .field, ticked: []))] {
            #expect(stage.inlinePreview != nil, "the premise: the block is drawn at this stage")
        }
    }

    /// Decision 21, end to end: a typed host's Subscribe on a Discuz! opens the **sheet** at the
    /// boards, the page keeps its block underneath, and Back returns to that same preview without
    /// asking the forum for its index a second time.
    @Test("A typed host's boards open over the page, and Back lands on the block still drawn")
    func aTypedHostsBoardsOpenOverThePage() async {
        let (session, http) = Self.forumSession()
        session.hostname = Self.forum
        await session.add(from: .field)
        guard case .previewing(let looked, .field, _) = session.stage else {
            Issue.record("a typed host should preview in the page")
            return
        }

        await session.confirm()
        #expect(session.choosing != nil, "the premise: the boards were reached")
        #expect(session.stage?.surface == .sheet, "the boards were drawn in the page")
        #expect(session.stage?.inlinePreview?.host == Self.forum, """
            The page stopped drawing its block the moment the sheet opened over it.
            """)
        let asked = await http.paths

        session.backToPreview()

        #expect(session.stage == .previewing(looked, from: .field, ticked: []), "Back landed somewhere else")
        #expect(await http.paths == asked, "Back asked the forum for its index again")
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

        #expect(JoinSheet.leading(for: nil) == nil)
        #expect(JoinSheet.leading(for: .browsing) == .close)
        // A preview reached from the field has the field behind it; one reached from a row has
        // the directory. Same stage, different answer — §2.2's rule by shape, not by history.
        //
        // **And the answer is now a function of one value.** It used to take the entrance as a
        // second argument, fed from a `@State` inside `JoinSheet` that nothing here could set —
        // so this test proved the rule while the thing deciding which way to call it was
        // reachable from no test at all.
        #expect(JoinSheet.leading(for: .previewing(preview, from: .field, ticked: [])) == .cancel)
        #expect(JoinSheet.leading(for: .previewing(preview, from: .directory, ticked: [])) == .backToBrowsing)
        #expect(
            JoinSheet.leading(for: .choosingBoards(offer, from: .preview(preview, from: .field, ticked: [])))
                == .backToPreview
        )
        // **Built, and it is Cancel.** A restate has nothing behind it: the reader pressed a
        // boards control on a row they already have, so there is no preview to step back to and
        // the press changes nothing. This expectation was `.backToPreview` with a message naming
        // this unit as the one that would turn it over.
        #expect(
            JoinSheet.leading(for: .choosingBoards(offer, from: .joined(subscribed: [], ticked: [])))
                == .cancel,
            "a restate offered Back to a preview that was never there"
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
        await cancelling.add(from: .field)
        JoinSheet.press(.cancel, on: cancelling)
        #expect(cancelling.stage == nil)

        let (back, _) = Self.forumSession()
        back.hostname = Self.forum
        // **The directory, and it has to be.** `leading(for:)` offers `.backToBrowsing` only to a
        // preview reached through the directory; a typed host is offered Cancel. Pressing it on a
        // `.field` stage pairs a button with a stage that can never present it, and passes only
        // because `press` switches on the button — in the test whose whole purpose is to catch a
        // button calling the wrong method.
        await back.add(from: .directory)
        #expect(JoinSheet.leading(for: back.stage) == .backToBrowsing, """
            The premise: this is the stage that actually offers this button.
            """)
        JoinSheet.press(.backToBrowsing, on: back)
        #expect(back.stage == .browsing, "Back to the directory went nowhere")

        let (boards, _) = Self.forumSession()
        boards.hostname = Self.forum
        await boards.add(from: .field)
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
        await leaving.add(from: .field)
        let before = pictures.generation

        leaving.dismissStage()
        #expect(pictures.generation > before, "a host only looked at kept its pictures")

        // And a host that *is* a source keeps them, because the reader is still reading it.
        let kept = ShellPictures(http: FixtureHTTP())
        let staying = ShellSession(http: FixtureHTTP(Self.forumRoutes()), pictures: kept)
        staying.sources = [Source(host: Self.forum, kind: .discuz)]
        staying.stage = .previewing(SourcePreview(
            host: Self.forum, kind: .discuz, profile: .silent(host: Self.forum, kind: .discuz)
        ), from: .field, ticked: [])
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
        #expect(JoinStage.previewing(preview, from: .field, ticked: []).host == Self.forum)
        let offer = JoinOffer(host: Self.forum, kind: .discuz, categories: [])
        #expect(JoinStage.choosingBoards(offer, from: .preview(preview, from: .field, ticked: [])).host
            == Self.forum)
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
            let key = SourcePreviewView.outcomeKey(kind)
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(kind) has no sentence")
            }
        }
        // A forum's two answers are its own, and neither is the microblog sentence.
        #expect(SourcePreviewView.outcomeKey(.discuz) == "join.preview.next.boards")
        #expect(SourcePreviewView.outcomeKey(.discourse) == "join.preview.next.forum")
        #expect(SourcePreviewView.outcomeKey(.mastodon) == "join.preview.next.microblog")
    }

    @Test("Every way a profile could not be read has a sentence of its own")
    func everyUnreadProfileHasASentence() {
        let reasons: [ProfileError] = [.unreachable, .refused(403), .unreadable]
        var said: Set<String> = []
        for reason in reasons {
            let sentence = SourcePreviewView.unreadMessage(reason)
            #expect(!sentence.hasPrefix("join.preview.unread."), "\(reason) has no sentence")
            said.insert(sentence)
        }
        #expect(said.count == 3, "two reasons were told to the reader as the same sentence")
        #expect(SourcePreviewView.unreadMessage(.refused(429)).contains("429"))
    }

    @Test("Every registration state has a sentence of its own")
    func everyRegistrationStateHasASentence() {
        let states: [SourceProfile.Registration] = [.open, .byApproval, .closed]
        var said: Set<String> = []
        for state in states {
            let key = SourcePreviewView.registrationKey(state)
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
        #expect(SourcePreviewView.warns(preview(false)))
        #expect(!SourcePreviewView.warns(preview(true)))
        #expect(
            !SourcePreviewView.warns(preview(nil)),
            "a field the protocol has no idea of was a warning"
        )
        #expect(!SourcePreviewView.warns(SourcePreview(
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
        await session.add(from: .field)

        guard case .previewing(let preview, _, _) = session.stage else {
            Issue.record("a forum that refuses should still be previewed, not refused outright")
            return
        }
        #expect(SourcePreviewView.warns(preview), """
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
        await session.add(from: .field)

        guard case .previewing(let preview, _, _) = session.stage else {
            Issue.record("a forum behind a filter should still be previewed, not refused outright")
            return
        }
        #expect(SourcePreviewView.caution(preview) == .turnedAway, """
            A forum behind a filter is warned about with the wrong sentence, or not at all. \
            The ruling that split it from the forum's own policy must not cost the warning.
            """)
        // The press is still theirs, and is still the thing that fails — a prediction, not a
        // refusal that has happened.
        #expect(session.refuse == nil)
        #expect(SourcePreviewView.warns(preview), "Return was left on a press the screen warned about")

        // And the two cautions do not say the same thing in any language.
        for language in [DummyLanguage.english, .taiwanese] {
            let shut = L10n.t(SourcePreviewView.Caution.needsAccount.key, language: language)
            let filtered = L10n.t(SourcePreviewView.Caution.turnedAway.key, language: language)
            #expect(shut != filtered, "two different facts were given one sentence")
            #expect(filtered != SourcePreviewView.Caution.turnedAway.key, "no sentence in \(language)")
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
        #expect(SourcePreviewView.caution(preview(.refused(403))) == .turnedAway)
        #expect(SourcePreviewView.caution(preview(.unreadable)) == nil)
        #expect(SourcePreviewView.caution(preview(.unreachable)) == nil)
        #expect(SourcePreviewView.caution(SourcePreview(
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
        await session.add(from: .field)
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
        await session.add(from: .field)
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
        await session.add(from: .field)
        #expect(session.profiles[Self.forum] == .stated(SourceProfile(
            host: Self.forum, kind: .discuz, readsWithoutAccount: true
        )))
        #expect(session.profiles.count == 1, "one server left two rows in the map")
    }

    // MARK: - Where the sentence goes when the press was not made where the block is

    /// **A reader can be looking at A's block while being turned away typing B, and B's errand is
    /// not A's block's.** The owner used to be derived from whatever block happened to be drawn,
    /// so the resumed join's "Checking B…" rendered inside A's `previewActions`, directly under
    /// A's Subscribe — and nothing at all appeared under the field, where the reader pressed.
    ///
    /// Reachable only by this exact sequence, which is why it is walked press by press: a typed
    /// preview leaves the field live (`admitsASecondLook`), a refused second look leaves the first
    /// block standing, and the sign-in offered under the field resumes from there.
    @Test("A join resumed after a sign-in reports under the field, not inside another server's block")
    func aResumedJoinReportsWhereThePressWas() async {
        let first = "first.example"
        let second = "second.example"
        let http = GatedHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "https://\(first)/api/v2/instance": .text(#"{"domain": "first.example"}"#),
            "https://\(second)/api/v2/instance": .text(#"{"domain": "second.example"}"#),
            "/api/v1/timelines/public": .text("[]"),
            "/api/v1/trends/statuses": .text("[]"),
        ], holding: "/api/v1/timelines/public")
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)

        // A's block is open in the page, and the field beside it is live.
        session.hostname = first
        await session.add(from: .field)
        #expect(session.stage?.inlinePreview?.host == first, "the premise: A's block is drawn")

        // The reader types B and resumes it the way a refusal's sign-in offer does.
        session.hostname = second
        let press = Task { await session.resumeAfterSignIn() }
        // **Parked on the *take*, not merely `checking`.** The resumed press is a look and then a
        // take with no await between them, and both set `checking` — so spinning on that alone
        // would assert against the look, where the owner is `.page` for an unrelated reason.
        var landed = false
        for _ in 0..<100_000 {
            if await http.reached { landed = true; break }
            await Task.yield()
        }
        #expect(landed, "the resumed press never reached the timeline")

        #expect(session.progressHost == second)
        #expect(session.progress?.owner == .page, """
            The resumed errand was attributed to whatever block happened to be on screen, which \
            is a different server's.
            """)
        #expect(pane.pageWaiting?.contains(second) == true, """
            Nothing appeared under the field, where the reader pressed.
            """)
        #expect(pane.blockWaiting == nil, """
            B's sentence was drawn inside A's block, under A's Subscribe.
            """)

        await http.gate.open()
        await press.value
    }

    /// **The block's Cancel stays live while its own Subscribe is on the wire — deliberately, a
    /// reader may leave — and leaving takes the block away.** A sentence owned by a surface that
    /// has gone left the reader waiting on a request with the field, the magnifier and Browse all
    /// grey and nothing on screen saying why. The page takes an orphaned errand back.
    @Test("Cancelling the block mid-press does not leave the reader waiting in silence")
    func aCancelledBlockHandsItsSentenceBack() async {
        let http = GatedHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example"}"#),
            "/api/v1/timelines/public": .text("[]"),
            "/api/v1/trends/statuses": .text("[]"),
        ], holding: "/api/v1/timelines/public")
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)
        session.hostname = "first.example"
        await session.add(from: .field)

        let press = Task { await session.confirm() }
        #expect(await Self.spun { session.checking }, "the press never reached the wire")
        // The block owns it while the block is there.
        #expect(pane.blockWaiting != nil)
        #expect(pane.pageWaiting == nil)

        // The reader presses Cancel, which is live throughout — `previewActions` withdraws only
        // Subscribe on `checking`.
        session.dismissStage()

        #expect(session.checking, "the premise: the request is still on the wire")
        #expect(pane.blockWaiting == nil, "a sentence was owned by a block that is not drawn")
        #expect(pane.pageWaiting != nil, """
            The reader was left waiting on a request with every control on the page refused and \
            nothing anywhere saying why.
            """)

        await http.gate.open()
        await press.value
        #expect(session.progress == nil)
    }

    /// **Ownership was fixed; visibility was never made a function of anything.** `.directory`'s
    /// reporter is `.page`, a browsed preview's surface *is* `.sheet`, and `take` holds the stage
    /// for the whole of `begin(preview)` — unlike `subscribe`, which nils it first, which is the
    /// only reason the boards phase was ever visible. So browsing a server and pressing Subscribe
    /// drew the sentence under the field, **behind the sheet**: a reader waiting on a request,
    /// told nothing, with every visible control refused.
    ///
    /// The suite could not see it because every `pageProgress` assertion passed `drawnAs: nil`.
    /// This one passes a sheet stage and follows the answer through to where the sentence lands.
    @Test("A browsed Subscribe says so in the sheet the reader is looking at, not behind it")
    func aSheetDoesNotHideTheSentenceAboutItsOwnPress() async {
        let http = GatedHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example"}"#),
            "/api/v1/timelines/public": .text("[]"),
            "/api/v1/trends/statuses": .text("[]"),
        ], holding: "/api/v1/timelines/public")
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await http.gate.open()
        }
        defer { watchdog.cancel() }

        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)
        let sheet = JoinSheet(session: session)
        session.hostname = "first.example"
        await session.add(from: .directory)
        #expect(session.stage?.surface == .sheet, "the premise: the preview is in the sheet")

        let press = Task { await session.confirm() }
        #expect(await Self.spun { session.checking }, "the press never reached the wire")

        // The press belonged to the page — the field is where a browsed join is reported from —
        // and the page is not what the reader can see.
        #expect(session.progress?.owner == .page)
        #expect(
            ShellSession.reporting(session.progress, drawnAs: session.stage) == .sheet,
            "the errand was attributed to a surface the sheet is standing over"
        )
        #expect(pane.pageWaiting == nil, "the sentence was drawn under a field nobody can see")
        #expect(sheet.sheetWaiting?.contains("first.example") == true, """
            Nothing in the sheet said anything, while its Subscribe was grey and its Cancel was \
            the only live control on screen.
            """)

        await http.gate.open()
        await press.value
        #expect(session.progress == nil)
    }

    /// The sheet has two places for one sentence — a directory row, and the footer — and they must
    /// not both fire. A row the catalogue lists draws its own; a preview being taken has no row,
    /// and neither does a host the directory does not list, so those go to the footer.
    @Test("One sentence, one place in the sheet, whichever stage the reader is on")
    func theSheetPutsItsSentenceInExactlyOnePlace() {
        let listed = ["first.example"]
        #expect(JoinSheet.drawnByARow(.browsing, host: "first.example", listed: listed))
        // `extraRow` — a host the reader typed that the directory does not carry. It has no row
        // foot at all, so the footer is the only site it can have.
        #expect(!JoinSheet.drawnByARow(.browsing, host: "other.example", listed: listed))
        // A preview being taken: the catalogue is not even on screen.
        let previewing = JoinStage.previewing(
            SourcePreview(host: "first.example", kind: .mastodon, profile: .unasked(
                host: "first.example", kind: .mastodon
            )),
            from: .directory, ticked: []
        )
        #expect(!JoinSheet.drawnByARow(previewing, host: "first.example", listed: listed))
        #expect(!JoinSheet.drawnByARow(nil, host: "first.example", listed: listed))
    }
}
