import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// Unit 5: `ShellPlace.account` becomes the source page — one row per server, and what it is.
///
/// **What is pinned here is every decision the row makes, driven as a value.** The row is a
/// function of a `SourceRow`, and a `SourceRow` is a function of what the session already holds, so
/// none of this needs SwiftUI stood up — which is the point: this milestone has twice shipped a
/// rule that was right and a caller that no test could reach, so the wiring is driven too.
@MainActor
@Suite("The source page")
struct SourcePageTests {
    private static let forum = "install-c.example"
    private static let micro = "first.example"

    init() {
        L10n.language = .english
    }

    private func session() -> ShellSession {
        ShellSession(http: FixtureHTTP(), store: ItemStore())
    }

    /// A session whose every request parks until the test opens the gate, so a press can be
    /// caught genuinely mid-flight.
    ///
    /// **Not `session.checking = true`.** `checking` is `progress != nil`, so busy-with-no-
    /// sentence is a state no press can produce and a test can no longer spell. Two tests here
    /// used to hand-set it, and what both of them actually wanted was this.
    private func gatedSession() -> (ShellSession, GatedHTTP) {
        let http = GatedHTTP(["/": .text("<html><body></body></html>")], holding: "/")
        return (ShellSession(http: http, store: ItemStore()), http)
    }

    /// Starts a look and returns once it is **provably** parked on the wire, with the task to
    /// await after the gate opens. `hangGuard` is the standing pattern: `.timeLimit` does not
    /// rescue a task parked on a continuation.
    private func heldLook(
        _ session: ShellSession, _ http: GatedHTTP, host: String
    ) async -> (Task<Void, Never>, Task<Void, Never>) {
        let watchdog = hangGuard(http.gate)
        session.hostname = host
        let look = Task { await session.add() }
        #expect(await spun { session.checking }, "the look never reached the wire")
        return (look, watchdog)
    }

    /// Somewhere a `@Sendable` observation callback can leave a mark. The shape `ClearTests`
    /// established, for the same reason: `withObservationTracking` cannot write to a local.
    private final class Woken: @unchecked Sendable {
        var fired = false
    }

    private func seed(_ session: ShellSession, _ sources: [Source]) async {
        for source in sources { await session.store.add(source) }
        session.sources = await session.store.sources()
    }

    // MARK: - The rows

    /// **Zero extra requests, which is the whole design of the list.** `profiles` is filled by the
    /// look the reader already waited for — `theLookRecordsWhatWasSaid` pins that end — and a row is
    /// assembled out of it and `sources` and nothing else.
    ///
    /// Measured rather than asserted: the wire is counted before the list is read and after, so a
    /// row that ever went and asked a server anything would fail this whatever it asked for.
    @Test("A row is built from what the session already holds, and asks no server anything")
    func rowsComeFromTheSessionAndCostNothing() async {
        let http = FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"""
            {"domain": "first.example", "title": "First",
             "usage": {"users": {"active_month": 1200000}}}
            """#),
            "/api/v1/timelines/public": .text("[]"),
            "/api/v1/trends/statuses": .text("[]"),
        ])
        let session = ShellSession(http: http, store: ItemStore())
        session.hostname = Self.micro
        await session.add()
        await session.confirm()
        // Joined second, and never looked at, so it has no entry in `profiles` at all.
        await session.store.add(Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "启动盘工具")]
        ))
        session.sources = await session.store.sources()
        let asked = await http.paths.count

        let rows = session.rows

        #expect(rows.map(\.id) == [Self.micro, Self.forum], "join order is the list's order")
        #expect(rows.map(\.shape) == [.microblog, .forum])
        #expect(SourceRow.figures(rows[0].profile).count == 1,
                "the look the reader already waited for is not what the row draws")
        #expect(SourceRow.figures(rows[0].profile)[0].hasSuffix(" active this month"))
        #expect(rows[1].profile == .unasked(host: Self.forum, kind: .discuz))
        #expect(await http.paths.count == asked, "drawing the list asked a server something")
    }

    /// **A source nobody looked at reads `.unasked`, and the row is honest rather than empty.**
    /// Not `Optional<ProfileAnswer>`: in this package a nil would mean "this source has no such
    /// idea", which is `.silent`, and the two must not be one spelling.
    @Test("A source that arrived another way is unasked, not silent and not a hole")
    func aSourceNobodyLookedAtIsUnasked() async {
        let session = session()
        await seed(session, [Source(host: Self.forum, kind: .discuz)])

        let row = try! #require(session.rows.first)
        #expect(row.profile == .unasked(host: Self.forum, kind: .discuz))
        #expect(SourceRow.figures(row.profile).isEmpty)
        #expect(SourceRow.evidenceKey(row.profile) == nil)
        // What it can still say, it says: the host, and what shape of thing it is.
        #expect(SourceRow.spoken(row).contains(Self.forum))
        #expect(SourceRow.spoken(row).contains("Discuz!"))
        #expect(SourceRow.spoken(row).contains("forum"))
    }

    /// The shape comes from `DummyItem.shape(of:)` and cannot be handed in, so a row and the
    /// timeline cannot disagree about what a server is. Unit 2's globe-over-every-forum, closed at
    /// the type rather than at a call site.
    @Test("A row's shape is the timeline's shape, for every protocol")
    func aRowsShapeIsTheTimelinesShape() {
        for kind in ProtocolKind.allCases {
            let row = SourceRow(
                source: Source(host: "a.example", kind: kind),
                profile: .unasked(host: "a.example", kind: kind)
            )
            #expect(row.shape == DummyItem.shape(of: kind), "\(kind) is drawn as two different things")
        }
    }

    // MARK: - Decision 4 — the sign-in control

    /// **A total map, not a set**, the shape unit 2's rewrite established: every protocol is named
    /// and the answer is written down twice by the same person, which is the only guard a `switch`
    /// with no `default:` can be given beyond the compiler's.
    @Test("Discuz! and Mastodon offer a sign-in, and every protocol has an answer")
    func onlyDiscuzAndMastodonOfferASignIn() {
        let expected: [ProtocolKind: Bool] = [
            .mastodon: true, .pleroma: false, .akkoma: false, .misskey: false,
            .pixelfed: false, .lemmy: false, .peertube: false, .friendica: false,
            .gotosocial: false, .discourse: false, .discuz: true, .unknown: false,
        ]
        #expect(Set(expected.keys) == Set(ProtocolKind.allCases), "a protocol has no stated answer")
        for kind in ProtocolKind.allCases {
            #expect(SourceRow.canSignIn(kind) == expected[kind], "\(kind) answers the wrong thing")
        }
        // And the flag is what the row reads, so M4 turns a protocol on here and edits no view.
        let discuz = SourceRow(
            source: Source(host: Self.forum, kind: .discuz),
            profile: .unasked(host: Self.forum, kind: .discuz)
        )
        let discourse = SourceRow(
            source: Source(host: "f.example", kind: .discourse),
            profile: .unasked(host: "f.example", kind: .discourse)
        )
        #expect(discuz.canSignIn)
        #expect(!discourse.canSignIn, "absent, never disabled — a grey control for nine in ten")
    }

    /// Decision 13, at the row. The toggle's two states and their two labels, and Sign in reusing
    /// the key the refusal's offer already uses so one act cannot be two translations.
    ///
    /// **`signInTitleKey` is gone and that is declared rather than quietly dropped.** It returned
    /// the control's *word*, and after decision 30's ruling there is no word: both arrangements
    /// draw the same four glyphs, so `account.source.signin` and `account.source.signout` lost
    /// their last reader and left the bundles with the function. The relationship the toggle
    /// expresses survives whole in the label keys below, which are what a pointer and a VoiceOver
    /// reader both get.
    @Test("The sign-in toggle says what this device last saw, both ways round")
    func theToggleFollowsWhatWasLastSeen() {
        #expect(SourceRow.signInLabelKey(reached: false) == "account.refuse.signin.label")
        #expect(SourceRow.signInLabelKey(reached: true) == "account.source.signout.label")
        let forum = Source(host: Self.forum, kind: .discuz)
        #expect(
            SourceRow.controlLabel(.signIn, source: forum, signedIn: false)
                == "Open \(Self.forum)'s own sign-in page"
        )
        #expect(
            SourceRow.controlLabel(.signIn, source: forum, signedIn: true)
                == "Sign out of \(Self.forum) and forget what it left here"
        )
    }

    /// **The wiring, not only the rule.** A predicate that is right and a press that never consults
    /// it is this milestone's recurring failure, so the press itself is driven here: it must sign
    /// in when this device has seen nothing, and sign out when it has.
    @Test("Pressing the toggle signs in or out according to that same predicate")
    func pressingTheToggleGoesTheRightWay() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), forums: forums)
        await seed(session, [Source(host: Self.forum, kind: .discuz)])
        let pane = AccountPane(session: session)
        let row = try! #require(session.rows.first)

        // Nothing seen: the press asks for the forum's own page.
        await pane.press(row)
        #expect(session.signingIn?.host == Self.forum, "the press did not offer a sign-in")

        // Seen: the press ends it, and the predicate goes back to no.
        session.signingIn = nil
        await forums.plantSession(host: Self.forum)
        #expect(forums.reachedSignIn(host: Self.forum), "the premise did not hold")
        await pane.press(row)
        #expect(!forums.reachedSignIn(host: Self.forum), "the press did not sign the reader out")
        #expect(session.signingIn == nil, "signing out opened a sign-in sheet")
        #expect(session.sources.map(\.host) == [Self.forum], "signing out removed the source")
    }

    /// **The two errands that end at the same callback, told apart.** Unit 4 wrote
    /// `resumeAfterSignIn` for one of them — a stranger turned this app away, the reader went and
    /// signed in, and the join runs again — and this unit then drew a Sign in toggle on rows for
    /// servers that are *already* joined. Both end in the same two lines at `FediqoRootView:120`
    /// and `:140`, and nothing there told the two apart: a reader who pressed Sign in on a joined
    /// Discuz! row and signed in on the forum's own page was answered with "You are already
    /// reading this server", which is `look`'s duplicate guard reporting an errand nobody started.
    ///
    /// The suite was green because this pair was only ever driven from the typed-host path. So
    /// this drives the row's press and then the sheet's answer **in the shape the two call sites
    /// have them in, the `if` included** — the `if` is where the answer is acted on, and a test
    /// that called `resumeAfterSignIn` unconditionally would be pinning something the app does
    /// not do.
    @Test("A sign-in pressed on a row already joined ends there, and refuses nobody")
    func aRowsSignInIsAnErrandOfItsOwn() async {
        let http = FixtureHTTP()
        let forums = ForumSessions(credentials: MemoryCredentials())
        let session = ShellSession(http: http, store: ItemStore(), forums: forums)
        await seed(session, [Source(host: Self.forum, kind: .discuz)])
        let pane = AccountPane(session: session)
        let row = try! #require(session.rows.first)
        // They were part-way through typing a second server when they pressed the row's button.
        session.hostname = "half.typed.example"

        await pane.press(row)
        #expect(session.signingIn?.host == Self.forum, "the premise: the row offered a sign-in")

        // What the forum's own page does when the reader gets there.
        await forums.plantSession(host: Self.forum)
        if session.signInFinished(reached: true, host: Self.forum) {
            await session.resumeAfterSignIn()
        }

        #expect(session.refuse == nil, """
            The reader signed in and was told they are already reading this server. Nothing was \
            being added: the sign-in was the whole errand.
            """)
        // What they *can* see instead, and the reason nothing is said: the toggle is drawn from
        // this, and `ForumSessions` is observed, so the row reads Sign out by itself.
        #expect(forums.reachedSignIn(host: Self.forum), "the sign-in went unrecorded")
        #expect(session.hostname == "half.typed.example", """
            The row's host was written over what the reader was typing. They pressed a button on \
            a row; the field was not what that press was about.
            """)
        #expect(await http.paths.isEmpty, "a joined server was looked up again")
        #expect(session.stage == nil, "a sheet was opened over a server that is already a source")
        #expect(session.sources.map(\.host) == [Self.forum])
    }

    /// **The whole of what the reader gets told, so it is measured and not assumed.** The test
    /// above says nothing is said under the field, and that is only defensible if the row itself
    /// moves: otherwise a reader presses Sign in, signs in to the forum, and watches the app do
    /// nothing at all. The row draws its toggle from `reachedSignIn`, so what has to be true is
    /// that reading it inside a body is a read that a later read of the store wakes.
    ///
    /// Driven through `withObservationTracking`, which is the same machinery SwiftUI redraws a
    /// body from — a `@ObservationIgnored` on `reachedHosts`, or the predicate ever being
    /// answered from something untracked, would leave the row saying Sign in for the rest of the
    /// run and this is the only thing that would notice.
    @Test("A sign-in read off the store wakes the read the row's toggle is drawn from")
    func recordingASignInWakesTheRow() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        forums.watch(forums: [Self.forum])
        let woken = Woken()

        withObservationTracking {
            _ = forums.reachedSignIn(host: Self.forum)
        } onChange: {
            woken.fired = true
        }
        #expect(!woken.fired, "nothing has happened yet")

        await forums.plantSession(host: Self.forum)

        #expect(woken.fired, """
            The row's toggle would still read Sign in after a sign-in that was reached, and the \
            reader would have been told nothing anywhere.
            """)
    }

    // MARK: - What each answer draws

    /// The table in `DESIGN.md` §3.3, one case at a time.
    @Test("Figures are drawn only where a server stated some, and never as a zero")
    func figuresAreOnlyWhatWasStated() {
        let stated = ProfileAnswer.stated(SourceProfile(
            host: "f.example", kind: .discourse, people: 4200, posts: 91000
        ))
        // Asserted by which figures, in which order, and not by how the number came out:
        // `compact` formats through the system locale, so "4.2K" on one machine is "4200" on
        // another and an assertion on the digits would be a test about where it ran.
        #expect(SourceRow.figures(stated).count == 2, "a figure the server did not state was drawn")
        #expect(SourceRow.figures(stated)[0].hasSuffix(" people"))
        #expect(SourceRow.figures(stated)[1].hasSuffix(" posts"))

        // A server that stated none of the three gets no line at all, rather than three zeros.
        let quiet = ProfileAnswer.stated(SourceProfile(host: "f.example", kind: .discourse))
        #expect(SourceRow.figures(quiet).isEmpty)

        #expect(SourceRow.figures(.silent(host: Self.forum, kind: .discuz)).isEmpty)
        #expect(SourceRow.figures(.unread(host: Self.forum, kind: .discuz, .unreachable)).isEmpty)
        #expect(SourceRow.figures(.unasked(host: Self.forum, kind: .discuz)).isEmpty)
    }

    /// **`.silent` gets no evidence line and `.unread` does**, which is the one asymmetry on the
    /// row. Nothing is expected of a Discuz!, so nothing is missing; something was expected of an
    /// unread server and did not arrive, and a reader would otherwise wonder why that row is
    /// thinner than the one above it.
    @Test("Only a server that was asked and could not be read says so")
    func onlyAnUnreadServerSaysSo() {
        #expect(SourceRow.evidenceKey(.unread(host: Self.forum, kind: .discuz, .unreadable))
            == "account.source.unread")
        #expect(SourceRow.evidenceKey(.silent(host: Self.forum, kind: .discuz)) == nil)
        #expect(SourceRow.evidenceKey(.unasked(host: Self.forum, kind: .discuz)) == nil)
        #expect(SourceRow.evidenceKey(.stated(SourceProfile(host: "f.example", kind: .discourse))) == nil)
    }

    /// **Decision 17, at the row, and it cost a round upstream to get right.** A Discuz! behind a
    /// bot filter is `.unread(.refused)` — a doorman answered and the forum said nothing — and the
    /// row must draw that as *we could not read it*, never as *this needs an account*. A forum
    /// that answered about its own policy is the other case, and it is `.stated`.
    @Test("A forum behind a filter reads as unread, never as needing an account")
    func aFilteredForumIsNotAForumThatNeedsAnAccount() {
        let filtered = ProfileAnswer.unread(host: Self.forum, kind: .discuz, .refused(403))
        let key = try! #require(SourceRow.evidenceKey(filtered))
        #expect(key == "account.source.unread")
        #expect(L10n.t(key) == "Its description could not be read.")
        // The sentence about needing an account belongs to the preview's warning and to a forum
        // that stated its own policy. Nothing on this row may say it.
        #expect(!L10n.t(key).contains("account"))
        #expect(L10n.t(key) != L10n.t("join.preview.closed"))

        // And a forum that did answer about its policy is a different case entirely.
        let policy = ProfileAnswer.stated(SourceProfile(
            host: Self.forum, kind: .discuz, readsWithoutAccount: false
        ))
        #expect(SourceRow.evidenceKey(policy) == nil, "a stated policy was drawn as a failed read")
    }

    /// The count leads so it survives truncation — the visible line is clipped at two lines and
    /// "3 boards" is the half a reader needs whole.
    @Test("The boards line counts first and names them after, and is absent where there are none")
    func theBoardsLineCountsFirst() {
        let forum = Source(host: Self.forum, kind: .discuz, boards: [
            BoardSubscription(fid: 33, name: "启动盘工具"),
            BoardSubscription(fid: 41, name: "虚拟机专区"),
        ])
        #expect(SourceRow.boardsLine(forum) == "2 boards: 启动盘工具 · 虚拟机专区")
        #expect(SourceRow.boardsLine(Source(host: Self.micro, kind: .mastodon)) == nil)
    }

    // MARK: - What the row says out loud

    /// §5. One sentence, the same identity key the preview's header uses, then everything the row
    /// actually draws — **with the board names whole**, because the visible line is clipped at two
    /// and a reader who cannot see it is owed the rest.
    @Test("A row says its identity, its figures and all of its boards out loud")
    func aRowSpeaksEverythingItDraws() {
        let row = SourceRow(
            source: Source(host: Self.forum, kind: .discuz, boards: [
                BoardSubscription(fid: 33, name: "启动盘工具"),
                BoardSubscription(fid: 41, name: "虚拟机专区"),
            ]),
            profile: .unread(host: Self.forum, kind: .discuz, .refused(403))
        )
        let spoken = SourceRow.spoken(row)
        #expect(spoken.hasPrefix(JoinSheet.spoken(SourcePreview(
            host: Self.forum, kind: .discuz, profile: .unasked(host: Self.forum, kind: .discuz)
        ))), "the row and the preview describe the same server differently")
        #expect(spoken.contains("Its description could not be read."))
        #expect(spoken.contains("启动盘工具"))
        #expect(spoken.contains("虚拟机专区"), "a board name was clipped out of the spoken sentence")
    }

    // MARK: - §3.6 — this list and Usage's stay apart

    /// **No byte figure and no date on an Account row, ever** — and pinned as the row's *complete*
    /// vocabulary rather than as a property of one helper.
    ///
    /// The first version of this asserted the return of `SourceRow.figures(_:)`, which QA showed
    /// is bypassable: `SourceRowView.said` draws five things and only one of them comes through
    /// that function, so a byte figure added straight to the view — and to `spoken` — left all 770
    /// tests green. `hasPrefix` and `contains` elsewhere could not catch it either.
    ///
    /// So the assertion is **equality on the whole spoken sentence**. §5 already requires spoken to
    /// say what is drawn, so an equality on it makes it the row's complete vocabulary: anything
    /// added to the row must appear here, and anything appearing here must be one of the six parts
    /// below. That closes the drawn side and the spoken side with one line.
    @Test("An Account row says exactly its identity, its stated figures and its boards — and nothing else")
    func anAccountRowsVocabularyIsComplete() {
        let profile = SourceProfile(
            host: "f.example", kind: .discourse,
            title: "A forum", summary: "words", activeMonth: 900, people: 4200, posts: 91_000,
            registration: .open, readsWithoutAccount: true, rules: ["one", "two"]
        )
        let row = SourceRow(
            source: Source(host: "f.example", kind: .discourse, boards: [
                BoardSubscription(fid: 1, name: "General"),
            ]),
            profile: .stated(profile)
        )

        // Built from the parts the row is allowed to have, in the order §3.3 draws them. Not a
        // literal, because the figures' digits follow the shell's language — see
        // `aNumberFollowsTheShellsLanguage`.
        let identity = String(
            format: L10n.t("source.spoken"), "f.example", "Discourse", DummyItem.shapeWord(.forum)
        )
        let expected = ([identity] + SourcePreviewView.figurePieces(profile)
            + ["1 boards: General"]).joined(separator: ", ")

        #expect(SourceRow.spoken(row) == expected, """
            The row says something that is not its identity, a figure the server stated, or its \
            boards. Everything a row draws is in this sentence, so anything new has to be here.
            """)

        // The two vocabularies that must never cross into it, stated as the readings they would be.
        #expect(!SourceRow.spoken(row).contains("MB"))
        #expect(!SourceRow.spoken(row).contains("held"))
        // And what the server stated that is evidence for the preview rather than identity here.
        #expect(!SourceRow.spoken(row).contains("A forum"))
        #expect(!SourceRow.spoken(row).contains("words"))
        #expect(!SourceRow.spoken(row).contains(L10n.t("join.preview.reg.open")))

        // The footnote that names the other list, which is what kills the duplicate reading.
        #expect(L10n.t("account.sources.held", language: .english)
            == "What each one has left on this device is on Usage.")
    }

    // MARK: - Every control on this page, driven

    /// **The regression this suite existed alongside and could not see.** The field's Return and
    /// the magnifier both called `ShellSession.search()`, which trimmed the text and cleared the
    /// error and looked nothing up — and with the Add button gone into the sheet there was no way
    /// left to add a source by typing its hostname at all. 436 UI tests were green because every
    /// one of them called `session.add()` directly.
    ///
    /// So this drives the pane's own method, which is what both controls call, and asserts the
    /// server was actually asked.
    @Test("Typing a hostname and asking for it looks the server up")
    func typingAHostnameLooksItUp() async {
        let http = FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text("[]"),
            "/api/v1/trends/statuses": .text("[]"),
        ])
        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)
        session.hostname = "  first.example  "

        await pane.typedHost()

        #expect(await http.paths.contains("/api/v2/instance"), """
            The field's control asked the server nothing. A reader who types a hostname and \
            presses Return has no other way to add it — Browse opens a directory, not their host.
            """)
        guard case .previewing(let preview, _, _)? = session.stage else {
            Issue.record("typing a hostname did not open its preview")
            return
        }
        #expect(preview.host == Self.micro)
        // Looked, and **nothing added** — the reader still presses Subscribe.
        #expect(session.sources.isEmpty)
        // And the field it was typed into is live beside the block it opened. It used to be
        // disabled by any stage at all, which was one term answering two questions: *is something
        // on the wire* and *is the reader looking at something else*. A block in the page is
        // neither over the field nor instead of it.
        #expect(!pane.busy, "the field was greyed out under a preview drawn beside it")
    }

    /// The other side of the same term, and the reason it still exists. A preview in the sheet
    /// covers the page, so a second look started behind it would replace a stage the reader cannot
    /// see — PLAN risk 8, which this split must not undo.
    @Test(
        "The field is out of the reader's hands behind a sheet, and only behind a sheet",
        .timeLimit(.minutes(1))
    )
    func theFieldIsDisabledOnlyWhereTheReaderCannotSeePastTheStage() async {
        let (session, http) = gatedSession()
        let pane = AccountPane(session: session)
        let preview = SourcePreview(
            host: Self.micro, kind: .mastodon, profile: .unasked(host: Self.micro, kind: .mastodon)
        )

        #expect(!pane.busy, "nothing is happening and the field was grey")

        session.stage = .previewing(
            preview, from: .joined(Source(host: Self.micro, kind: .mastodon)), ticked: []
        )
        #expect(pane.busy, "a second look could start behind a sheet the reader cannot see past")

        session.stage = .browsing
        #expect(pane.busy, "the browser covers the page")

        session.stage = .browsingServers(.mastodon)
        #expect(pane.busy, "the browser's server list covers the page")

        session.stage = .previewing(preview, from: .field, ticked: [])
        #expect(!pane.busy)

        session.stage = nil
        let (look, watchdog) = await heldLook(session, http, host: Self.micro)
        #expect(pane.busy, "something on the wire still takes the top half out of the reader's hands")

        await http.gate.open()
        await look.value
        watchdog.cancel()
    }

    /// The same control, refusing the same way `add` refuses, so nothing had to be re-guarded when
    /// the field started looking: a host already in the list is still a duplicate.
    @Test("Asking for a host that is already a source is refused, not looked up again")
    func typingADuplicateIsRefused() async {
        let http = FixtureHTTP()
        let session = ShellSession(http: http, store: ItemStore())
        let pane = AccountPane(session: session)
        await seed(session, [Source(host: Self.micro, kind: .mastodon)])
        session.hostname = Self.micro

        await pane.typedHost()

        #expect(session.refuse == L10n.t("account.refuse.duplicate"))
        #expect(await http.paths.isEmpty, "a duplicate was spent on the wire")
        #expect(session.stage == nil)
    }

    /// Browse, and the one thing that distinguishes it from the field beside it: it opens the
    /// browser rather than looking a host up. **And it fetches nothing** — decision 38 puts the
    /// directory a press further in than decision 10 did, so the step this opens names no server
    /// and reaches no third party.
    @Test("Browse opens the browser and nothing else")
    func browseOpensTheBrowser() async {
        let session = session()
        let pane = AccountPane(session: session)
        pane.browse()
        #expect(session.stage == .browsing)
        #expect(session.sources.isEmpty)
    }

    /// The button a refusal offers. It is the only control on the top half that names a host other
    /// than the one in the field, so it is driven with one.
    @Test("The sign-in a refusal offers opens that forum's own page")
    func theOfferedSignInOpensThatForum() async {
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(),
            forums: ForumSessions(credentials: MemoryCredentials())
        )
        let pane = AccountPane(session: session)
        session.offerSignIn = Self.forum

        await pane.offeredSignIn(Self.forum)

        #expect(session.signingIn?.host == Self.forum)
    }

    /// A row's Clear and a row's Remove, driven through the pane rather than asserted about the
    /// session. **Both now destroy nothing**: each raises its own question, and only a dialog's
    /// confirm reaches `clear(host:)` or `remove(host:)`.
    ///
    /// Clear's half of that is decision 29 and is a declared change: it used to empty on the press.
    @Test("A row's Clear and its Remove both only ask")
    func aRowsClearAndRemoveReachTheRightThings() async {
        let session = session()
        let pane = AccountPane(session: session)
        await seed(session, [
            Source(host: Self.micro, kind: .mastodon),
            Source(host: Self.forum, kind: .discuz),
        ])
        let rows = session.rows

        pane.askClear(rows[0])
        #expect(session.clearing == Self.micro)
        #expect(session.cleared == 0, "Clear emptied a server before the question was answered")

        pane.askRemove(rows[1])
        #expect(session.removing == Self.forum)
        #expect(session.sources.count == 2, "the question destroyed something before it was answered")
        #expect(await session.store.sources().count == 2)

        // And the confirms, which are where the two acts actually differ.
        await session.clear(host: Self.micro)
        #expect(session.cleared == 1)
        #expect(session.sources.count == 2, "Clear removed a source; it empties, it does not remove")
    }

    /// The row's fourth control, driven through the pane like the other three.
    ///
    /// **`AccountPane.changeBoards(_:)` is the wiring, and the wiring is what this branch keeps
    /// shipping wrong** — four times, each a correct rule reached by nothing (risk 12). The rule
    /// and the press are both pinned in `BoardChoiceTests`; this is the one line between a button
    /// in a `View` body and either of them.
    @Test("A row's boards control reaches the restate, and changes nothing by reaching it")
    func aRowsBoardsControlReachesTheRestate() async {
        let index = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
        <h2><a href="forum.php?gid=56">::工具区::</a></h2>
        <div id="category_56" class="bm_c">
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt></dl>
        <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt></dl>
        </div></body></html>
        """#
        let session = ShellSession(
            http: FixtureHTTP(["https://\(Self.forum)/forum.php": .text(index)]),
            store: ItemStore()
        )
        let pane = AccountPane(session: session)
        await seed(session, [Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "启动盘工具")]
        )])
        let row = try! #require(session.rows.first)

        await pane.changeBoards(row)

        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the row's boards control reached nothing")
            return
        }
        #expect(offer.boards.map(\.fid) == [33, 41])
        #expect(origin.ticked == [33], "the picker did not open on what this row already reads")
        // Nothing has changed: this press reads an index and opens a sheet.
        #expect(session.sources.first?.boards.map(\.fid) == [33])
    }

    // MARK: - The strings

    @Test("Every string this page draws is in all three bundles and says what it should")
    func theCopyIsRight() {
        #expect(L10n.t("account.sources.title", language: .english) == "Sources")
        // **Rewritten, declared rather than quietly re-expected.** Decision 34 takes four lines
        // off every row, and two facts that are about *the list* rather than about any one server
        // come to the page in words: that a row opens, and what the marks mean. The final clause
        // is the shipped sentence verbatim, so the warning that stands before a reader meets a
        // Remove button is untouched and the translator edited rather than rewrote.
        #expect(
            L10n.t("account.sources.detail", language: .english) == """
                Everything this device reads. Press a row for what that server says about itself \
                — its name, its size, its boards. Removing one takes its boards and its posts \
                with it.
                """
        )
        // The legend, and its first clause is the load-bearing one: decision 33 makes *absence*
        // meaningful, so a reader looking at a two-mark row above a four-mark one has no other way
        // to learn that the short row is short on purpose.
        #expect(
            L10n.t("account.sources.marks", language: .english) == """
                A row carries only the marks its own server has: sign in, change boards or \
                lists, clear what it left here, and remove it.
                """
        )
        #expect(L10n.t("account.source.boards", language: .english) == "%1$d boards: %2$@")
        #expect(L10n.t("account.source.unread", language: .english) == "Its description could not be read.")
        #expect(
            L10n.t("account.source.remove.label", language: .english)
                == "Remove %@ and everything it left here"
        )
        #expect(
            L10n.t("account.source.signout.label", language: .english)
                == "Sign out of %@ and forget what it left here"
        )
        // **The copy change unit 4 left behind, because it belongs with the list it describes.**
        // "This timeline's source" was singular and now stands over a list of servers.
        #expect(L10n.t("shell.account.summary", language: .english) == "The servers you read")

        let keys = [
            "account.sources.title", "account.sources.detail", "account.sources.held",
            "account.sources.marks",
            "account.source.boards", "account.source.unread",
            "account.source.remove.label", "account.source.signout.label", "shell.account.summary",
        ]
        for key in keys {
            #expect(L10n.t(key, language: .taiwanese) != key, "\(key) is missing from the Chinese")
        }

        // **Six keys left the bundles with the words that read them, and that is declared.**
        //
        // `account.source.remove`, `.signin` and `.signout` were the stacked regime's button
        // captions; decision 30's ruling draws four glyphs in both arrangements, so no surface
        // says those words any more. `timeline.sources` and `source.unsigned` were the old
        // masthead mark's plate label and its "Not signed in" line, both of which the glance drops
        // by design — the row three lines below says both, with the act attached.
        // `source.signedIn` had already had no reader for longer than that.
        //
        // A string nothing reads is a translation cost in three bundles and a reader of this file
        // inferring a control that is not there.
        //
        // **Three more left with decision 33, and that is this unit's own deletion.** Decision 28
        // made a control a protocol lacks *struck and saying why*; decision 33 withdraws it and
        // restores decision 4, so such a control is absent. Nothing is struck, nothing has a
        // reason to give, and three sentences about why a control is refused describe a control
        // that is not drawn.
        let gone = [
            "account.source.remove", "account.source.signin", "account.source.signout",
            "timeline.sources", "source.unsigned", "source.signedIn",
            "account.source.signin.struck", "account.source.boards.struck",
            "account.source.boards.none",
        ]
        for key in gone {
            #expect(L10n.t(key, language: .english) == key, """
                \(key) is back in the bundle. Nothing draws it: if a caption has returned, it \
                needs a surface and a reason, not a revived key.
                """)
        }
    }

    // MARK: - Decision 29 — Clear asks, and says what actually goes

    /// **Three whole messages, and the one that names the password is the reason this exists.**
    /// Clear reaches `ForumSessions.forget(host:)`, which deletes the saved Keychain password and
    /// signs the reader out — and the Account row, by `DESIGN.md` §3.6's own rule, draws no
    /// inventory line that could have said so before the press.
    @Test("Clear picks its sentence from what this device is actually holding")
    func clearSaysWhatGoes() {
        #expect(
            SourceRow.clearDetailKey(hasPassword: false, reachedSignIn: false)
                == "account.clear.detail"
        )
        #expect(
            SourceRow.clearDetailKey(hasPassword: false, reachedSignIn: true)
                == "account.clear.detail.signedout"
        )
        #expect(
            SourceRow.clearDetailKey(hasPassword: true, reachedSignIn: true)
                == "account.clear.detail.password"
        )
        // A password held with no sign-in reached on this run is still a password that goes.
        #expect(
            SourceRow.clearDetailKey(hasPassword: true, reachedSignIn: false)
                == "account.clear.detail.password"
        )

        // **The overstatement the user was told not to repeat, checked from both sides.** Clear is
        // not reversible — the password does not come back — and it is not a removal either. Every
        // message says the source stays; only the one about a password says something does not
        // come back.
        for key in [
            "account.clear.detail", "account.clear.detail.signedout", "account.clear.detail.password",
        ] {
            // Case-insensitive on the first letter alone: the password message opens a new
            // sentence with it, the other two carry it as a clause.
            #expect(
                L10n.t(key, language: .english).lowercased().contains("stays in your sources"),
                "\(key) stopped saying the source stays, which is the whole difference from Remove"
            )
        }
        #expect(
            L10n.t("account.clear.detail.password", language: .english)
                .contains("does not come back"),
            "the one message about a deleted password stopped saying it is not coming back"
        )
        for key in ["account.clear.detail", "account.clear.detail.signedout"] {
            #expect(!L10n.t(key, language: .english).contains("password"), """
                \(key) mentions a password. "the password saved for it is deleted" must never \
                appear for a source that has none.
                """)
        }
        // And Remove keeps the sentence only it has, so the two dialogs stay mirror sentences.
        #expect(
            L10n.t("account.remove.detail.boards", language: .english)
                .contains("The boards do not come back")
        )
        #expect(L10n.t("account.clear.title", language: .english) == "Clear what %@ left here?")
    }

    /// **The wiring, which is the half risk 12 counts.** Both entrances set the same piece of
    /// session state and neither empties anything by itself; only the dialog's confirm reaches
    /// `clear(host:)`, and that call clears the question behind it.
    @Test("Both Clears ask the same question, and neither empties anything by asking")
    func bothClearsAsk() async throws {
        let session = self.session()
        await seed(session, [Source(host: Self.forum, kind: .discuz)])
        let pane = AccountPane(session: session)
        let row = try #require(session.rows.first)

        pane.askClear(row)
        #expect(session.clearing == Self.forum, "the row's Clear did not raise the question")
        #expect(session.cleared == 0, "the row's Clear emptied something before it was answered")

        // The confirm, and the question going with it.
        await session.clear(host: Self.forum)
        #expect(session.cleared == 1)
        #expect(session.clearing == nil, "the question outlived the decision it was asking about")

        // **Remove answers a pending Clear too**, or a dialog would be left standing over a row
        // that has gone: `remove` reaches `clear` on its way out.
        session.clearing = Self.forum
        await session.remove(host: Self.forum)
        #expect(session.clearing == nil)
    }

    // MARK: - A number is in the shell's language, not the device's

    /// **The defect this unit widened and therefore closes.** `.formatted` with no locale follows
    /// the *system*, and this app lets the reader choose a language the device is not set to — so
    /// on a `zh-TW` machine with the shell in English the preview drew "9.1萬 posts", one sentence
    /// in two languages, against `DESIGN.md` §0 rule 3. Unit 5 made it worse by drawing the same
    /// figures on a second surface; all three surfaces share `L10n.compact`, so there is one
    /// fix and this is its pin.
    ///
    /// **Asserted without encoding this machine's locale**, which is the whole difficulty. The two
    /// languages are driven through *the same number* with nothing else varying, so what is proved
    /// is that the language decides the digits — not that any particular rendering came out. The
    /// nouns are deliberately kept out of it: comparing whole figure lines would pass on
    /// "posts" ≠ "篇文章" while the number stayed wrong in both.
    @Test("The same number in two shell languages is two numbers, and each is in one language")
    func aNumberFollowsTheShellsLanguage() {
        let english = L10n.compact(91_000, language: .english)
        let chinese = L10n.compact(91_000, language: .taiwanese)

        #expect(english != chinese, """
            The language did not reach the formatter, so every reader gets whatever language the \
            device is set to.
            """)
        // Stated as the bug rather than as a rendering: whatever English compacts 91,000 to, it is
        // not a Chinese numeral. Pinning the literal "91K" would hand this test to ICU's data.
        let englishIsASCII = english.allSatisfy { $0.isASCII }
        let chineseIsASCII = chinese.allSatisfy { $0.isASCII }
        #expect(englishIsASCII, "an English figure carried a Chinese numeral")
        #expect(chineseIsASCII == false, "a Chinese figure came out in the device's language")

        // And the mapping the resolution goes through, so nobody can quietly swap in `.current`.
        #expect(L10n.locale(.english) == DummyLanguage.english.locale)
        #expect(L10n.locale(.taiwanese) == DummyLanguage.taiwanese.locale)
    }

    /// The end of the same thread: the figures a surface actually draws, in one language throughout.
    ///
    /// The sentence and the number inside it are resolved separately — `L10n.t` and `compact` — and
    /// before this they resolved against different things. So the assertion is that an English
    /// figure line contains **no** Chinese at all, which is exactly what a reader saw fail.
    @Test("A figure line is in one language, sentence and number together")
    func aFigureLineIsAllOneLanguage() {
        let profile = SourceProfile(
            host: "f.example", kind: .discourse, activeMonth: 900, people: 4200, posts: 91_000
        )
        let english = SourceRow.figures(.stated(profile), language: .english)
        let chinese = SourceRow.figures(.stated(profile), language: .taiwanese)

        #expect(english.count == 3 && chinese.count == 3)
        let allASCII = english.allSatisfy { piece in piece.allSatisfy { $0.isASCII } }
        #expect(allASCII, "an English figure line came back half in Chinese")
        #expect(zip(english, chinese).allSatisfy { $0 != $1 })

        // **The shell's language and not the device's, asked through the default argument** — the
        // path every real call site takes. This suite's `init` sets the shell to English, so on a
        // machine whose system locale is not English this line is the regression itself; on an
        // English machine it is true either way and the two assertions above carry the weight.
        #expect(SourceRow.figures(.stated(profile)) == english)
    }

    // MARK: - The glyph

    /// §1.3: the glyph is driven by the shape, out of `SourceMark`'s one table, and is never
    /// hard-coded. A total map for the same reason `canSignIn`'s is one.
    @Test("Every shape has its own glyph, and the row and the mark read one table")
    func everyShapeHasItsOwnGlyph() {
        let expected: [DummySourceKind: String] = [
            .microblog: "globe", .forum: "text.bubble", .board: "list.bullet", .video: "film",
        ]
        for (shape, symbol) in expected {
            #expect(SourceMark.symbol(shape) == symbol, "\(shape) is drawn with the wrong glyph")
        }
        #expect(expected.count == 4, "a shape was added and has no glyph")
        // The bug unit 2 closed, asked from this side: a joined forum is not drawn with a globe.
        #expect(SourceMark.symbol(DummyItem.shape(of: .discuz)) != SourceMark.symbol(.microblog))
        #expect(SourceMark.symbol(DummyItem.shape(of: .discourse)) == "text.bubble")
    }

    // MARK: - The two arrangements, and the numbers that are no longer constants
    //
    // **This is the part of the row a test has to carry alone.** A layout that depends on a
    // measured width is wiring no test can see, and this branch has now shipped four defects of
    // exactly that class under a fully green suite (risk 12). So the decision is a pure function
    // and it is driven here across both arrangements, the unmeasured first frame and the boundary.
    // What is *not* reachable is named in `SourceRowView`'s own doc comment: `AccountPane`'s
    // `onGeometryChange`, which is SwiftUI's own measurement.
    //
    // **They stopped being `static let`s, and the test is stronger for it.** Decision 33 made the
    // control count per-protocol, so `furniture` and `controlLine` are functions of a stated
    // control set — which means every expectation below now states *which row* it is about, where
    // before it could only state a sum.

    /// The four controls a Discuz! carries, and the two a microblog does. Named once so every
    /// expectation below says which row it is about.
    private static let discuzControls: [SourceRow.Control] = [.signIn, .boards, .clear, .remove]
    private static let microControls: [SourceRow.Control] = [.clear, .remove]
    /// What a Mastodon carries since it can be signed in to (#24).
    private static let mastodonControls: [SourceRow.Control] = [.signIn, .clear, .remove]

    /// **Every term of the row as it is drawn, restated rather than trusted.** The threshold's
    /// whole claim is that the number is arithmetic and not taste, so if somebody moves
    /// `ShellSpace.step`, `ShellSpace.tight`, `ShellSpace.snug` or the touch floor, the row moved
    /// with them and this is where that is noticed.
    ///
    /// **Four targets have three gaps, and leaving them out is how this shipped wrong once.** Unit
    /// B computed 176 from three targets and no gaps between them, and the test recited the same
    /// omission — so the constant described a row nobody drew and stayed green while the drawn row
    /// moved. Every gap is named here, including which token spaces which pair.
    @Test("The furniture is every gap and target in the row as it is actually drawn")
    func furnitureIsArithmeticAndNotATasteNumber() {
        // **The structure, which is what the numbers are summed from.** Each of these is a symbol
        // the drawn row reads: `SourceRowView` frames its leading mark at `markBase`, and its
        // `actions` loop iterates `controls(of:)` and pads by each control's own `lead`.
        #expect(SourceRow.markBase == 24)
        #expect(SourceRow.touch == 44, "the 44pt floor is what 176 of a four-control line is")
        #expect(SourceRow.hostFloor == 132)
        #expect(SourceRow.hostFloor == SourceRow.touch * 3, """
            The hostname's floor stopped being derived from the touch target. It is a recognition \
            floor, and `touch` is the only fixed metric in this row that already carries a \
            what-a-human-needs argument.
            """)
        #expect(SourceRow.Control.allCases.count == 5)

        // **The gap is a property of the control now, not an index into a list.** `gaps[index - 1]`
        // was correct only while every row drew all four: a Mastodon drawing [clear, remove] would
        // have read `gaps[0]` — `tight` — for a pair the design deliberately separates.
        let leads: [SourceRow.Control: CGFloat] = [
            .signIn: ShellSpace.snug, .boards: ShellSpace.tight, .lists: ShellSpace.tight,
            .clear: ShellSpace.snug, .remove: ShellSpace.snug,
        ]
        #expect(Set(leads.keys) == Set(SourceRow.Control.allCases), """
            A control was added and this table was not asked about it. There is no `gaps.count` \
            check left to trap it at its first layout, so it has to be caught here.
            """)
        for control in SourceRow.Control.allCases {
            #expect(control.lead == leads[control], "\(control)")
        }
        // The one grouping the gaps say: Sign in and Boards are the two acts that change what this
        // device reads, and Remove is deliberately not tight against Clear.
        #expect(SourceRow.Control.boards.lead < SourceRow.Control.remove.lead)

        // **244, and nothing regresses**: a Discuz! row's control line is identical to the 196 that
        // shipped. What moved is the leading mark, 20 → 24, and the threshold's second term.
        #expect(SourceRow.furniture(Self.discuzControls, mark: 24) == 244)
        #expect(SourceRow.furniture(Self.discuzControls, mark: 24)
            == SourceRow.controlLine(Self.discuzControls) + SourceRow.markBase + ShellSpace.step * 2)
        #expect(SourceRow.furniture(Self.microControls, mark: 24) == 144)
    }

    /// **The mutation the previous version of these tests could not see.** Both numbers used to be
    /// literals whose terms lived in a doc comment, and the test restated the same literals — so it
    /// agreed with the row by hand rather than deriving from it. QA proved it twice: the leading
    /// glyph's width changed 20 → 28 and the suite passed; a drawn gap was re-tokened `tight` →
    /// `snug`, the real group became 200pt, and `controlLine == 196` stayed green while being false.
    @Test("Both sums are computed from the structure the row draws, not stated beside it")
    func theConstantsAreDerivedFromTheDrawnRow() {
        // **196, identical to what shipped** — the four-control line did not move.
        #expect(SourceRow.controlLine(Self.discuzControls) == 196)
        #expect(SourceRow.controlLine(Self.discuzControls)
            == SourceRow.touch * 4 + ShellSpace.tight + ShellSpace.snug * 2)
        // And the two-control line, which nothing computed before decision 33 and which is the one
        // that ships the ragged trailing edge. A test that pinned only the four-control case would
        // leave this path unpinned entirely — §10's named hazard.
        #expect(SourceRow.controlLine(Self.microControls) == 96)
        #expect(SourceRow.controlLine(Self.microControls)
            == SourceRow.touch * 2 + SourceRow.Control.remove.lead)

        // **The first control's `lead` is dropped, whichever control turns out to be first.** A
        // Lemmy with communities and no sign-in draws [boards, clear, remove], and boards' `tight`
        // must not appear: 132 + 8 + 8, not 132 + 4 + 8 + 8.
        #expect(SourceRow.controlLine([.boards, .clear, .remove]) == 148)

        // A control added or taken away moves the line by a target and a gap, visibly.
        #expect(SourceRow.controlLine(Self.discuzControls)
            - SourceRow.controlLine([.boards, .clear, .remove]) == SourceRow.touch + ShellSpace.tight)

        // An empty set is no targets and no gaps, not a negative sum from `dropFirst`.
        #expect(SourceRow.controlLine([]) == 0)
    }

    /// Which controls a source actually carries — decision 33, which withdraws decision 28 and
    /// restores decision 4. **A total map over the protocols**, in the shape `DummyItemTests`
    /// established: a set of the true ones would say nothing about the kinds left out.
    @Test("A row carries only the controls its own source has, and every protocol has an answer")
    func aRowCarriesOnlyItsOwnControls() {
        for kind in ProtocolKind.allCases {
            let bare = Source(host: "a.example", kind: kind)
            let expected: [SourceRow.Control] =
                SourceRow.canSignIn(kind) ? [.signIn, .clear, .remove] : [.clear, .remove]
            #expect(SourceRow.controls(of: bare) == expected, "\(kind)")
            // Clear and Remove are on every row of every protocol: every source this device holds
            // can be emptied and let go of.
            #expect(SourceRow.controls(of: bare).suffix(2) == [.clear, .remove], "\(kind)")
        }

        // **Boards is refused on two different facts and both are asked.** A protocol with no
        // picker at all, and a source with nothing to pick.
        let bareForum = Source(host: Self.forum, kind: .discuz)
        #expect(SourceRow.controls(of: bareForum) == [.signIn, .clear, .remove], """
            A forum with no boards drew a control that opens a sheet with nothing in it.
            """)
        let forum = Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "閒聊")]
        )
        #expect(SourceRow.controls(of: forum) == Self.discuzControls)
        // A Discourse carrying boards still has no picker — unit 7 answers this at
        // `canChangeBoards`, not here.
        let discourse = Source(
            host: "f.example", kind: .discourse, boards: [BoardSubscription(fid: 1, name: "x")]
        )
        #expect(SourceRow.controls(of: discourse) == [.clear, .remove])

        // **The declared order is the drawn order and the suffix property falls out of it.** A
        // later hand reordering the enum to put Remove first would destroy the property that Clear
        // and Remove stand in the same two columns on every row, silently.
        #expect(SourceRow.Control.allCases == [.signIn, .boards, .lists, .clear, .remove])
    }

    /// **One threshold for the whole list, computed from the widest row in it** — decision 33's
    /// rule, and the cost the user accepted with it.
    @Test("The threshold is the widest row in this list, and every row is drawn to it")
    func oneThresholdForTheWholeList() {
        let micro = SourceRow(
            source: Source(host: Self.micro, kind: .mastodon),
            profile: .unasked(host: Self.micro, kind: .mastodon)
        )
        let forum = SourceRow(
            source: Source(
                host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "閒聊")]
            ),
            profile: .unasked(host: Self.forum, kind: .discuz)
        )
        #expect(SourceRow.widest([micro, micro, micro]) == Self.mastodonControls)
        #expect(SourceRow.widest([micro, forum, micro]) == Self.discuzControls, """
            One forum in a list of microblogs did not widen the list. Every row must restack \
            together or the list reads as broken.
            """)
        // No rows is no widest row, and no block is drawn either.
        #expect(SourceRow.widest([]).isEmpty)

        // **The stated cost, pinned so it is a decision and not a surprise.** Three Mastodons on a
        // 393pt phone are one-line rows; adding a Discuz! restacks all four.
        let phone: CGFloat = 393 - ShellSpace.pad * 2
        let before = SourceRow.threshold(SourceRow.widest([micro, micro, micro]), mark: 24, host: 132)
        let after = SourceRow.threshold(SourceRow.widest([micro, micro, micro, forum]), mark: 24, host: 132)
        #expect(before == 328 && after == 376)
        #expect(SourceRow.regime(width: phone, threshold: before) == .trailing)
        #expect(SourceRow.regime(width: phone, threshold: after) == .beneath)
    }

    /// **The ceiling is what makes every sum above true rather than hopeful.** A mark is allowed to
    /// grow with the type until it would reach the edges of the 44pt target it sits in, and then it
    /// stops — so a control group cannot widen past its own targets at any Dynamic Type rung.
    @Test("A mark stops growing before it reaches the edges of its own target")
    func theGlyphIsCappedBelowItsTarget() {
        #expect(SourceRow.symbolPoints(24) == 24, "at the default rung nothing is capped")
        #expect(SourceRow.symbolPoints(36) == 36, "the ceiling itself is not below it")
        #expect(SourceRow.symbolPoints(60) == 36, "a large rung grew the mark out of its target")
        #expect(SourceRow.symbolPoints(1_000) == SourceRow.touch - ShellSpace.snug)
        // Stated as the arithmetic rather than as 36, so a change to either token is caught here.
        #expect(SourceRow.touch - ShellSpace.snug == 36)
        for scaled in [CGFloat(16), 24, 36, 48, 96] {
            #expect(SourceRow.symbolPoints(scaled) <= SourceRow.touch, """
                A mark reached its own target's edge, so the control group is wider than \
                `SourceRow.controlLine` says and the narrow case is no longer proved.
                """)
        }
    }

    /// **The first frame, before anything has been measured.** `onGeometryChange` has not fired, so
    /// the width is zero — and zero is not a narrow row, it is no answer at all.
    @Test("An unmeasured row is drawn beneath, and a negative one too")
    func theFirstFrameGetsTheSafeRegime() {
        for threshold in [CGFloat(276), 376] {
            #expect(SourceRow.regime(width: 0, threshold: threshold) == .beneath)
            // A layout pass that reports a negative width is not a row to draw marks in either.
            #expect(SourceRow.regime(width: -10, threshold: threshold) == .beneath)
        }
    }

    /// **376 and 276, and the rule behind them is no longer "the words get at least half the row".**
    /// That rule was argued for a content column holding four lines of prose; decision 34 deletes
    /// all four but the hostname, and a hostname is one unbreakable token that truncates from the
    /// tail. What it needs is a floor, and `hostFloor` is it.
    ///
    /// Pinned from both sides and *at* the boundary, because an off-by-one here is a row that
    /// crowds on the one width where it was most carefully argued that it would not.
    @Test("The threshold is the furniture plus the hostname's floor, and the boundary is trailing")
    func theBoundaryIsFurniturePlusTheFloor() {
        let forum = SourceRow.threshold(Self.discuzControls, mark: 24, host: 132)
        let micro = SourceRow.threshold(Self.microControls, mark: 24, host: 132)
        #expect(forum == 376)
        #expect(micro == 276)
        #expect(SourceRow.threshold([.boards, .clear, .remove], mark: 24, host: 132) == 328)

        // **The property this buys, and it is the reason the rule was replaced rather than
        // re-measured:** at the boundary the hostname has exactly its floor, and above it more.
        // So the hostname never truncates below `hostFloor` in the trailing regime, at any width.
        // Paired rather than recovered by comparing two `CGFloat`s: if the two thresholds ever
        // coincided, an equality branch would silently test the same row twice.
        for (threshold, controls) in [(forum, Self.discuzControls), (micro, Self.microControls)] {
            #expect(threshold - SourceRow.furniture(controls, mark: 24) == SourceRow.hostFloor)
            #expect(SourceRow.regime(width: threshold, threshold: threshold) == .trailing,
                    "at the boundary the hostname gets exactly its floor, which is the rule met")
            #expect(SourceRow.regime(width: threshold - 0.5, threshold: threshold) == .beneath)
            #expect(SourceRow.regime(width: threshold + 0.5, threshold: threshold) == .trailing)
        }
    }

    /// **Where each real context lands, and every row in the table moved.** Revision 2's arithmetic
    /// was 714pt of macOS window for a forum and "no iPhone in portrait ever draws them"; this is
    /// 610pt, below the minimum entirely with the rail collapsed, and **every phone draws the
    /// one-line row for a list without a forum**. That last is decision 33's dividend rather than
    /// decision 34's, and it is the real gain.
    ///
    /// The macOS page is window − rail − hairline; the row is the page less `ShellSpace.pad` either
    /// side. Both are restated here rather than quoted, so a rail metric that moves lands here.
    @Test("Where each real context lands, including the macOS minimum window")
    func theRealContextsLandWhereTheyWereMeasured() {
        let forum = SourceRow.threshold(Self.discuzControls, mark: 24, host: 132)
        let micro = SourceRow.threshold(Self.microControls, mark: 24, host: 132)

        let openRail = RailView.Metrics.expandedWidth + ShellSpace.hair
        let shutRail = RailView.Metrics.collapsedWidth + ShellSpace.hair
        func row(page: CGFloat) -> CGFloat { page - ShellSpace.pad * 2 }

        // **Rounded, and the rounding is the fact worth recording.** `Metrics.pad` is `rem * 0.3`
        // = 4.8, so the expanded rail is **200.8** and not the 201 that `PLAN.md`, `DESIGN-R2.md`
        // and `DESIGN-TAIL.md` all quote — which makes the macOS minimum page 318.2 and the row
        // 286.2. The fifth of a point changes no regime anywhere and every document is right to
        // the point; pinning the exact value would pin a float sum instead, and pinning nothing
        // would let a real rail change through.
        #expect(shutRail == 49, "the collapsed rail moved; every figure below is stale")
        #expect(openRail.rounded() == 202, "the expanded rail moved; every figure below is stale")
        #expect(row(page: 520 - openRail).rounded() == 286,
                "the macOS minimum window with the rail open")

        let contexts: [(String, CGFloat, SourceRow.Regime, SourceRow.Regime)] = [
            // context, row width, with a forum in the list, without one
            ("macOS 520pt minimum, rail open", row(page: 520 - openRail), .beneath, .trailing),
            ("macOS 520pt minimum, rail collapsed", row(page: 520 - shutRail), .trailing, .trailing),
            ("macOS 700pt, rail open", row(page: 700 - openRail), .trailing, .trailing),
            ("macOS 610pt, rail open — a forum's own boundary", row(page: 610 - openRail), .trailing, .trailing),
            ("iPhone SE, 375pt", row(page: 375), .beneath, .trailing),
            ("iPhone 15/16, 393pt", row(page: 393), .beneath, .trailing),
            ("iPhone 15 Pro Max, 430pt", row(page: 430), .trailing, .trailing),
            ("iPhone landscape, 852pt", row(page: 852), .trailing, .trailing),
            ("iPad 11in portrait, rail open", row(page: 834 - openRail), .trailing, .trailing),
            ("iPad half-width Split View, rail open", row(page: 507 - openRail), .beneath, .beneath),
        ]
        for (context, width, withForum, withoutOne) in contexts {
            #expect(SourceRow.regime(width: width, threshold: forum) == withForum,
                    "\(context) at \(width)pt of row is drawn in the wrong arrangement with a forum")
            #expect(SourceRow.regime(width: width, threshold: micro) == withoutOne,
                    "\(context) at \(width)pt of row is wrong for a list of microblogs")

            // **The property the rule guarantees, at the default rung.** Trailing, the hostname
            // has at least its floor *by construction*, at every rung — the threshold is the
            // furniture plus the floor. Beneath, it has the whole row less the mark and one gap,
            // which is a different kind of claim: it is arithmetic about a real width, and
            // `theStackedFloorHoldsToTheTopOfTheLadder` below is where it is taken up the ladder.
            let beneathRoom = width - SourceRow.markBase - ShellSpace.step
            #expect(beneathRoom >= SourceRow.hostFloor, """
                \(context): the hostname is below its recognition floor even stacked, which is the \
                one thing neither arrangement is allowed to do.
                """)
        }

        // Collapsing the rail is enough at every window size a Mac can be, which is the one lever
        // a reader has: 457pt of window is below `minWidth: 520`.
        #expect(457 - shutRail - ShellSpace.pad * 2 == forum)
    }

    /// **The threshold scales with the type, and that is a reversal made deliberately.** The
    /// shipped `Regime` deleted the Dynamic Type gate on the grounds that "both arrangements draw
    /// the same four glyphs, and a glyph has no string length and no type size". That was true of
    /// the *controls*, and QA was right that the gate restacked a 791pt iPad wrongly.
    ///
    /// The new term points the other way: the content column now holds **nothing but text**, so at
    /// `.accessibility1` a fixed 132pt floor would show four characters of hostname. The fix is not
    /// a second gate — it is that `markBase` and `hostFloor` are read through `@ScaledMetric` and
    /// passed in. **One axis, one scaling term, no `#if os(macOS)`, and nothing asks what platform
    /// it is on.**
    @Test("The type size reaches the threshold through one scaling term, and nothing else")
    func theThresholdScalesWithTheType() {
        let forum = Self.discuzControls
        // Roughly `.accessibility1`: about 1.6× a callout.
        let large = SourceRow.threshold(forum, mark: SourceRow.symbolPoints(24 * 1.6), host: 132 * 1.6)
        let base = SourceRow.threshold(forum, mark: 24, host: 132)
        #expect(large > base, "the hostname's floor stopped scaling, so large type shows four letters")

        // **Both parameters, because only one of them was pinned.** Substituting `hostFloor` for
        // `host` fails the line above; substituting `markBase` for `mark` left the whole suite
        // green, so a comment was the only thing standing over the mark term — which is what this
        // branch has already shipped once as a constant agreeing with the row by hand.
        #expect(SourceRow.threshold(forum, mark: 36, host: 132)
            == SourceRow.threshold(forum, mark: 24, host: 132) + 12)
        #expect(SourceRow.threshold(forum, mark: 24, host: 200)
            == SourceRow.threshold(forum, mark: 24, host: 132) + 68)

        // **The iPad case the deleted gate got wrong, and it stays right.** 791pt of row has room
        // for the control line at every rung and no reason to restack.
        #expect(SourceRow.regime(width: 791, threshold: large) == .trailing, """
            An iPad page has room for the control line at every rung. A gate that restacked it was \
            firing where firing was wrong, which is why there is one axis and it is width.
            """)
        // On a phone it rises past the row, which is right: the hostname needs the width.
        #expect(SourceRow.regime(width: 361, threshold: large) == .beneath)

        // The mark scales too, and is capped, so a large rung cannot widen the row's own furniture
        // without limit — which is what keeps the threshold a number and not a runaway.
        #expect(SourceRow.symbolPoints(24 * 1.6) == 36)
        #expect(DummyFontSize.allCases.count == 5, "the ladder changed and nothing re-read it")
    }

    /// **The one assertion the old suite took at a scaled rung, restored — and it turns out to be
    /// the assertion that bounds the claim.** `theControlLineCannotMove`'s last two lines ran the
    /// narrow case at a grown gutter; nothing carried that over, so "the hostname never truncates
    /// below the floor, at any width, in either regime" was proved at the default rung alone.
    ///
    /// **Trailing is fine at every rung by construction** — the threshold *is* the furniture plus
    /// the floor, so the floor is met by definition whatever the two terms scale to. **Beneath is
    /// arithmetic**, and it is the half that can fail: the stacked hostname gets the whole row less
    /// the mark and one gap, and that does not grow with the type while the floor does.
    ///
    /// So the claim is now stated as what is true: it holds to the top of **this app's own
    /// ladder**, and the margin is named rather than assumed. `DummyPrefs` sets
    /// `dynamicTypeSize` on the whole tree from its own preference, and `DummyFontSize.largest` is
    /// `.accessibility1` — about 1.63x a `.callout` metric against the `.large` base
    /// `@ScaledMetric` scales from. Past that it stops holding, and this test says where.
    @Test("The stacked hostname keeps its floor to the top of this app's type ladder")
    func theStackedFloorHoldsToTheTopOfTheLadder() {
        // The narrowest row a reader can actually be in: the macOS minimum window, rail open.
        let narrowest: CGFloat = 286

        func stackedRoom(at rung: CGFloat) -> CGFloat {
            narrowest - SourceRow.symbolPoints(SourceRow.markBase * rung) - ShellSpace.step
        }
        func floor(at rung: CGFloat) -> CGFloat { SourceRow.hostFloor * rung }

        // `DummyFontSize.largest` is `.accessibility1`; five rungs, one above the system default.
        #expect(DummyFontSize.allCases.count == 5, "the ladder changed and nothing re-read it")
        #expect(DummyFontSize.largest.dynamicType == .accessibility1, """
            The top of the ladder moved. The margin below is measured against it, so it is now \
            measuring something else.
            """)
        let topRung: CGFloat = 1.63

        for rung in [CGFloat(1), 1.2, 1.4, topRung] {
            #expect(stackedRoom(at: rung) >= floor(at: rung), """
                At \(rung)x the stacked hostname is below its recognition floor on the narrowest \
                row a reader can be in. `SourceRowView.said` and DESIGN-R4 §1.5 both claim it \
                never is.
                """)
        }
        // The margin at the top rung, named so a change that eats it is visible rather than silent.
        #expect(stackedRoom(at: topRung) - floor(at: topRung) >= 20, """
            The headroom at the top of the ladder has gone under 20pt. It is not a cliff far away: \
            the claim stops holding just past this rung.
            """)
        // And where it stops, stated rather than left to be discovered. This is *outside* what
        // this app can produce — but not by much, which is the honest shape of the claim.
        #expect(stackedRoom(at: 1.9) < floor(at: 1.9), """
            The stacked floor now holds past 1.9x. That is better than it was, and this test has \
            stopped describing the boundary — restate where it actually falls.
            """)
        // The mark's cap is what keeps the stacked room from shrinking without limit, so it is
        // part of this proof rather than a neighbouring fact.
        #expect(SourceRow.symbolPoints(SourceRow.markBase * topRung) == 36)
    }

    /// **Decision 37's *absence*, pinned.** The Account page contacts nobody on appearing because
    /// there is no picture tier above `kindMark` — and "no tier" fails no test by itself, so
    /// reintroducing one would have been caught by nothing. What is asserted instead is the
    /// property a picture tier would break: the leading mark is a function of the **protocol** and
    /// the rendered pixel count, and is independent of everything the server published.
    ///
    /// That is the user's own ruling and it exists to protect a privacy claim — `.account` is
    /// `ShellPlace.launch`, and decision 10 moved the catalogue off `.task` so that "a reader who
    /// never browses contacts nobody". A row that drew `profile.thumbnail` would put N requests to
    /// N servers back on the launch screen.
    @Test("A row's leading mark is its protocol's, never anything the server published")
    func theRowsMarkIgnoresWhatTheServerPublished() {
        let host = Self.micro
        let source = Source(host: host, kind: .mastodon)
        // One server that published a picture, and the same server never asked. If a picture tier
        // ever returns above `kindMark`, these two stop drawing the same thing.
        let published = SourceRow(source: source, profile: .stated(SourceProfile(
            host: host, kind: .mastodon,
            thumbnail: URL(string: "https://\(host)/hero.png"), activeMonth: 1_200_000
        )))
        let unasked = SourceRow(source: source, profile: .unasked(host: host, kind: .mastodon))

        // The profiles really do differ, or everything below is vacuous.
        #expect(!SourceRow.figures(published.profile).isEmpty)
        #expect(SourceRow.figures(unasked.profile).isEmpty)

        for width in [CGFloat(286), 900] {
            let withPicture = Self.drawn(published, at: width)
            let without = Self.drawn(unasked, at: width)
            #expect(withPicture.markName == without.markName, """
                The leading mark changed with what the server published, which is a picture tier \
                reintroduced above the protocol mark — and with it N requests to N servers on the \
                app's launch screen.
                """)
            #expect(withPicture.markName == "KindMastodon" || withPicture.markName == "KindMastodonSmall")
            #expect(withPicture.hasKindMark == without.hasKindMark)
            #expect(withPicture.markInk == without.markInk)
        }
    }

    // MARK: - The leading mark

    /// **The mark is the protocol's, always — decision 37, which amends decision 35.** The server's
    /// own published picture is gone from the row and stays in the detail sheet, for two costs with
    /// one answer between them: `.account` is `ShellPlace.launch`, so a picture per row meant N
    /// requests to N servers before the reader pressed anything; and `SourceProfile.thumbnail` is a
    /// banner, not an avatar, so cropped square to 24pt it is a legible fragment of the wrong thing.
    ///
    /// **A total map**, in the shape `canSignIn`'s is: a protocol added without an answer falls to
    /// the shape glyph, and that must be a chosen fallback rather than a gap.
    @Test("Every protocol answers for its own mark, and the pixel count picks the drawing")
    func everyProtocolAnswersForItsMark() {
        // **A second place the same person writes the same thought, and no `default:` in it.**
        // The map is stated here rather than derived from `kindMark`, because a derived expectation
        // agrees with the code by construction (risk 10). And it is a `switch` with every case
        // written out rather than a dictionary, so a protocol added without an answer breaks *this
        // build* — an `Issue.record` in a `default:` would demote the house rule from a compiler
        // stop to a runtime failure, at the one place that decides.
        for kind in ProtocolKind.allCases {
            let fine = SourceMark.kindMark(kind, pixels: 48)
            let small = SourceMark.kindMark(kind, pixels: 24)
            switch kind {
            case .mastodon, .pleroma, .akkoma, .gotosocial, .pixelfed, .friendica, .misskey:
                #expect(fine == "KindMastodon", "\(kind)")
                #expect(small == "KindMastodonSmall", "\(kind)")
            case .discuz:
                #expect(fine == "KindDiscuz")
                #expect(small == "KindDiscuzSmall")
            // Drawn, joinable, and deliberately nil: this repo has no Discourse drawing, and the
            // shape glyph answering is a decision rather than an omission.
            case .discourse, .lemmy, .peertube, .unknown:
                #expect(fine == nil, "\(kind)")
                #expect(small == nil, "\(kind)")
            }
        }

        // **The gate is 32 rendered pixels and it is the artwork's own rule** — the `-small` pair
        // is snapped to the 64-unit grid because anything narrower lands mid-pixel. At 24pt the row
        // draws 24px at 1× and 48px at 2×, which straddles it.
        #expect(SourceMark.kindMark(.mastodon, pixels: 32) == "KindMastodonSmall", "the gate is >, not >=")
        #expect(SourceMark.kindMark(.mastodon, pixels: 32.5) == "KindMastodon")
        #expect(SourceMark.kindMark(.discuz, pixels: 24 * 1) == "KindDiscuzSmall")
        #expect(SourceMark.kindMark(.discuz, pixels: 24 * 2) == "KindDiscuz")
        #expect(SourceMark.kindMark(.discuz, pixels: 24 * 3) == "KindDiscuz")
    }

    /// Whether a name resolves to a drawing in this bundle, **by whichever of the two shapes the
    /// bundle actually has**.
    ///
    /// **SwiftPM does not always compile an asset catalogue, and that is why this is not one
    /// line.** Swift 6.4's build compiles `Media.xcassets` with `actool` and leaves an
    /// `Assets.car`, which is what `Bundle.image(forResource:)` reads. Swift 6.1.2 -- what CI
    /// runs -- says `Copying Media.xcassets` and puts the directory in the bundle verbatim, so
    /// that accessor returns nil for every name and a test asking it alone fails the whole suite
    /// on a machine where nothing is wrong.
    ///
    /// **What the app ships is unaffected**, because the app is built by `xcodebuild`, which
    /// always compiles the catalogue -- the CI job that builds both apps was green on the run
    /// this test failed. So the copied case is a real, correct bundle and has to be read as one.
    private static func drawingExists(_ name: String) -> Bool {
        if Bundle.module.image(forResource: name) != nil { return true }

        return Self.copiedCatalogue(Bundle.module.resourceURL, draws: name)
    }

    /// The copied catalogue, read off the directory instead of off `Assets.car`: the imageset has
    /// to be there, its `Contents.json` has to parse, and every file it names has to exist beside
    /// it. That is each failure the compiled lookup would have caught -- a mis-spelt imageset, a
    /// missing `Contents.json`, an SVG that never made it in.
    ///
    /// **Takes the directory rather than reading `Bundle.module`, so that it can be pinned
    /// here.** This branch only ever runs where SwiftPM copied the catalogue, which is CI and not
    /// this machine -- so written against the bundle it would have been a fix nobody could try
    /// before pushing it, which is the shape this branch has already paid for more than once.
    /// `theCopiedCatalogueIsReadAsCarefullyAsTheCompiledOne` builds the shape and drives it.
    static func copiedCatalogue(_ resources: URL?, draws name: String) -> Bool {
        guard let resources else { return false }
        let imageset = resources
            .appendingPathComponent("Media.xcassets")
            .appendingPathComponent("\(name).imageset")
        guard let data = try? Data(contentsOf: imageset.appendingPathComponent("Contents.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]]
        else { return false }

        let named = images.compactMap { $0["filename"] as? String }
        return !named.isEmpty && named.allSatisfy {
            FileManager.default.fileExists(atPath: imageset.appendingPathComponent($0).path)
        }
    }

    /// **The branch that only runs on the machine this was not written on.** Swift 6.1.2 copies
    /// `Media.xcassets` into the bundle and Swift 6.4 compiles it, so the fallback above is dead
    /// code here and the only code there. Built by hand, and asked the four questions that matter.
    @Test("The copied catalogue is read as carefully as the compiled one")
    func theCopiedCatalogueIsReadAsCarefullyAsTheCompiledOne() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copied-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("Media.xcassets")
        defer { try? FileManager.default.removeItem(at: root) }

        func imageset(_ name: String, contents: String?, files: [String]) throws {
            let folder = assets.appendingPathComponent("\(name).imageset")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
            if let contents {
                try contents.write(
                    to: folder.appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8
                )
            }
            for file in files {
                try Data().write(to: folder.appendingPathComponent(file))
            }
        }

        let good = #"{"images":[{"filename":"a.svg","idiom":"universal"}]}"#

        try imageset("Whole", contents: good, files: ["a.svg"])
        try imageset("NoContents", contents: nil, files: ["a.svg"])
        try imageset("NoDrawing", contents: good, files: [])
        try imageset("Unparseable", contents: "{ not json", files: ["a.svg"])
        try imageset("NamesNothing", contents: #"{"images":[]}"#, files: ["a.svg"])

        #expect(Self.copiedCatalogue(root, draws: "Whole"))
        #expect(!Self.copiedCatalogue(root, draws: "NoContents"),
                "an imageset with no Contents.json was read as a drawing")
        #expect(!Self.copiedCatalogue(root, draws: "NoDrawing"), """
            The SVG never made it into the catalogue and the lookup said it had -- which is the \
            failure this whole test exists to catch, arriving through the other shape.
            """)
        #expect(!Self.copiedCatalogue(root, draws: "Unparseable"))
        #expect(!Self.copiedCatalogue(root, draws: "NamesNothing"),
                "an imageset naming no file at all is not a drawing")
        #expect(!Self.copiedCatalogue(root, draws: "NotThere"))
        #expect(!Self.copiedCatalogue(nil, draws: "Whole"), "a bundle with no resources at all")
    }

    /// **The one way this feature can ship invisible.** `Image(_:bundle:)` on a name that is not in
    /// the catalogue draws nothing at all, silently — so a mis-spelt imageset, a missing
    /// `Contents.json` or an SVG that never made it into `Media.xcassets` is a row with a blank
    /// leading edge and a green suite. This is the cheap test that closes it.
    @Test("Every drawing the row can ask for is actually in the bundle")
    func everyMarkIsInTheBundle() {
        var asked: Set<String> = []
        for kind in ProtocolKind.allCases {
            for pixels in [CGFloat(24), 48] {
                if let name = SourceMark.kindMark(kind, pixels: pixels) { asked.insert(name) }
            }
        }
        #expect(asked == ["KindMastodon", "KindMastodonSmall", "KindDiscuz", "KindDiscuzSmall"])
        for name in asked.sorted() {
            #expect(Self.drawingExists(name), """
                \(name) is not in Media.xcassets. `Image(_:bundle:)` draws nothing for a name it \
                cannot find and says nothing about it, so this is the only place it can be caught.
                """)
        }
        // And the lookup says no when it should, or every line above proves nothing. Both shapes
        // have to refuse it: a compiled catalogue has no such image, and a copied one has no such
        // directory.
        #expect(!Self.drawingExists("KindMastodonn"))
        // The mascot has been in this catalogue since before the marks and is loaded the same
        // way, so it is the control that says this lookup works at all on whichever build system
        // is running -- a green suite where every name resolved by accident would otherwise look
        // exactly like this one.
        #expect(Self.drawingExists("Mascot"))
    }

    // MARK: - Decision 33 — the controls a source has, and two looks

    private static let microRow = SourceRow(
        source: Source(host: micro, kind: .mastodon),
        profile: .unasked(host: micro, kind: .mastodon)
    )

    private static let forumRow = SourceRow(
        source: Source(
            host: forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "閒聊")]
        ),
        profile: .unasked(host: forum, kind: .discuz)
    )

    static func drawn(
        _ row: SourceRow, at width: CGFloat,
        widest: [SourceRow.Control]? = nil, actsLive: Bool = true, signedIn: Bool = false
    ) -> SourceRowView {
        SourceRowView(
            row: row, signedIn: signedIn, width: width,
            // The default is this row's own set, which is the single-row list. A test about the
            // list's threshold states it instead.
            widest: widest ?? SourceRow.controls(of: row.source),
            actsLive: actsLive, waiting: nil, refusal: nil,
            signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
        )
    }

    /// **The view's own application of the rule.** `SourceRow.regime` being right proves nothing
    /// about the row unless the row asks it the right question, and a width hardcoded in
    /// `SourceRowView.regime` — or the height read where the width was meant — is precisely the
    /// wiring-unreachable defect this branch has shipped four times (risk 12).
    ///
    /// **And now a second question, which is risk 14's fourth shape.** The threshold depends on the
    /// widest row in the *list*, and a row deriving it from its own source would give each row a
    /// different one under a green suite. So the row is *told*, and the last two expectations are
    /// that being told is what decides.
    @Test("The row asks the rule about its own width and the list's own widest row")
    func theRowPassesItsWidthToTheRule() {
        #expect(Self.drawn(Self.microRow, at: 0).regime == .beneath,
                "the unmeasured first frame is not a wide row")
        #expect(Self.drawn(Self.microRow, at: 270).regime == .beneath)
        #expect(Self.drawn(Self.microRow, at: 322).regime == .beneath)
        #expect(Self.drawn(Self.microRow, at: 328).regime == .trailing,
                "a list of Mastodons reaches the one-line row at 328pt")
        #expect(Self.drawn(Self.forumRow, at: 300).regime == .beneath)
        #expect(Self.drawn(Self.forumRow, at: 376).regime == .trailing)

        // **The threshold is the list's and not the row's.** A Mastodon in a list containing a
        // Discuz! stacks with it at 300pt; the same Mastodon alone does not.
        #expect(Self.drawn(Self.microRow, at: 300, widest: Self.discuzControls).regime == .beneath, """
            A microblog row computed its own threshold, so it stayed trailing while the forum \
            below it stacked — which is the one arrangement decision 33 forbids.
            """)
        #expect(Self.drawn(Self.microRow, at: 300, widest: Self.microControls).regime == .trailing)

        // And both scaling terms reach the sum, through the row's own metrics.
        let row = Self.drawn(Self.forumRow, at: 376)
        #expect(row.mark == SourceRow.markBase, "the leading mark is not the size the sum counts")
        #expect(row.threshold == 376)
        #expect(row.controls == Self.discuzControls)
    }

    /// **The pane's half of the one-threshold rule, which is the half risk 12 counts.**
    /// `SourceRow.widest` being right proves nothing unless the pane asks it about the list it
    /// actually draws and hands the answer to every row. That value used to not exist at all, and
    /// a value computed inside a `View` body is reachable from nothing — which is how all four of
    /// the defects risk 12 lists survived a green suite.
    @Test("The pane computes one threshold from the list it draws, and every row gets that one")
    func thePaneHandsOneWidestToEveryRow() async {
        let session = self.session()
        await seed(session, [
            Source(host: Self.micro, kind: .mastodon),
            Source(
                host: Self.forum, kind: .discuz,
                boards: [BoardSubscription(fid: 33, name: "閒聊")]
            ),
        ])
        let pane = AccountPane(session: session)
        #expect(pane.widest(session.rows) == Self.discuzControls, """
            The pane did not read the forum in its own list, so the Mastodon row above it would \
            have been drawn trailing while the forum below it stacked.
            """)
        // **From `session.rows` and not `session.sources`**, so the list the threshold is computed
        // from is the list that is drawn.
        #expect(pane.widest(session.rows) == SourceRow.widest(session.rows))

        // A list with no forum in it is narrower, and that is the whole gain: every phone draws
        // the one-line row for a list of microblogs.
        let micro = self.session()
        await seed(micro, [Source(host: Self.micro, kind: .mastodon)])
        #expect(AccountPane(session: micro).widest(micro.rows) == Self.mastodonControls)
    }

    /// **Two looks, two meanings, and the third is gone.** Decision 33 withdraws decision 28: a
    /// control for a protocol that has no such thing is **absent**, not struck. So there is no
    /// third state to draw, no reason for one to give, and `state(of:source:actsLive:)` is deleted
    /// rather than reduced — with `.struck` withdrawn it was a function of `actsLive` alone and no
    /// longer read `source` at all, which is a signature that lies about what decides.
    ///
    /// **A colour can only arrive inside `.live`**, so a dimmed control cannot be handed one. That
    /// is what the `.dimmed` expectations below are: not "it is grey" but "there is nowhere to put
    /// a colour".
    @Test("The row maps every control it draws to a state, and a hue reaches only a live one")
    func theRowReadsTheRuleForEveryControlItDraws() {
        // Outside a rendered tree `@Environment(\.colorScheme)` hands back `.light`, which is what
        // makes the hue readable as a value here at all.
        let light = ColorScheme.light

        for width in [CGFloat(286), 900] {
            let live = Self.drawn(Self.forumRow, at: width, actsLive: true)
            #expect(live.controls == Self.discuzControls, "at \(width)")
            #expect(live.state(.signIn) == .live(ShellChrome.inkDim(light)), "at \(width)")
            #expect(live.state(.boards) == .live(ShellChrome.inkDim(light)), "at \(width)")
            // Decision 29: both of these carry the alarm the user chose, in both arrangements.
            #expect(live.state(.clear) == .live(ShellChrome.alarm(light)), "at \(width)")
            #expect(live.state(.remove) == .live(ShellChrome.alarm(light)), "at \(width)")

            // Nothing on this row is live, and no hue is reachable to make one look as though it
            // were.
            let held = Self.drawn(Self.forumRow, at: width, actsLive: false)
            for control in held.controls {
                #expect(held.state(control) == .dimmed, "\(control) at \(width)")
            }
        }

        // `filament` is what a mark turns once the reader has switched it on, and the sign-in is
        // the one control that changes hue without being pressed.
        #expect(
            Self.drawn(Self.forumRow, at: 900, signedIn: true).state(.signIn)
                == .live(ShellChrome.filament(light))
        )

        // **A microblog draws two marks and not four**, which is the whole of decision 33 at the
        // view: what it lacks is absent rather than struck, and there is no state left that a
        // control not drawn could be in.
        let micro = Self.drawn(Self.microRow, at: 900)
        #expect(micro.controls == Self.mastodonControls)
        #expect(micro.state(.clear) == .live(ShellChrome.alarm(light)))
        #expect(micro.state(.remove) == .live(ShellChrome.alarm(light)))
    }

    /// **The label is the act and nothing else now.** With nothing struck there is no reason branch
    /// left, so a control's `.help()` and its spoken label are its own verb — the four the footer
    /// legend names, which is what keeps an act's name the same across the whole surface.
    @Test("A control says its own act, in the same words the legend uses")
    func aControlSaysItsOwnAct() {
        let forum = Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "閒聊")]
        )
        #expect(
            SourceRow.controlLabel(.boards, source: forum, signedIn: false)
                == "Change which boards you read on \(Self.forum)"
        )
        #expect(
            SourceRow.controlLabel(.signIn, source: forum, signedIn: false)
                == "Open \(Self.forum)'s own sign-in page"
        )
        #expect(
            SourceRow.controlLabel(.signIn, source: forum, signedIn: true)
                == "Sign out of \(Self.forum) and forget what it left here"
        )
        #expect(
            SourceRow.controlLabel(.clear, source: forum, signedIn: false)
                == "Clear what this device holds from \(Self.forum)"
        )
        #expect(
            SourceRow.controlLabel(.remove, source: forum, signedIn: false)
                == "Remove \(Self.forum) and everything it left here"
        )
    }

    // MARK: - Decision 31 — pressing a row opens that source's detail

    /// **It costs no request, and that is the whole shape of the feature.** The profile is already
    /// in `profiles`, put there by the look the reader waited for when they added the source, so
    /// the wire is counted before the press and after it and must not have moved.
    ///
    /// **And it does not route through `look()`**, which refuses an added host by design: a press
    /// that went that way would answer the reader with "You are already reading this server",
    /// which is `signInFinished`'s recorded incident arriving by a new door.
    @Test("Pressing a row opens what that source says about itself, asking no server anything")
    func pressingARowOpensItsDetail() async {
        let http = FixtureHTTP()
        let session = ShellSession(http: http, store: ItemStore())
        let source = Source(
            host: Self.forum, kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "启动盘工具")]
        )
        await seed(session, [source])
        let before = await http.paths.count

        AccountPane(session: session).openSource(session.rows[0])

        guard case .previewing(let preview, let origin, let ticked) = session.stage else {
            Issue.record("the row's press opened nothing")
            return
        }
        #expect(await http.paths.count == before, "the detail asked a server something")
        #expect(preview.host == Self.forum)
        #expect(preview.kind == .discuz)
        #expect(origin == .joined(source), "the sheet does not know which source it is about")
        #expect(ticked.isEmpty, "a detail has no picker and so nothing to tick")
        #expect(session.refuse == nil, "the press was reported as a refusal")
        // `SourcePreview.boards` means *the forum's index*, and nothing read one. The boards the
        // reader subscribed to travel in the origin, where they are what they say they are.
        #expect(preview.boards.isEmpty)
    }

    /// **One rule, and now four ends** (`DESIGN-R2` §10.1). Opening a detail replaces `stage`, so a
    /// row pressed while an inline preview is open would delete a screen the reader is part-way
    /// through — which is exactly the boards control's argument, and it must be the same predicate
    /// rather than a second one.
    @Test(
        "A row's press is refused exactly when its controls are, and by the same rule",
        .timeLimit(.minutes(1))
    )
    func theRowsPressObeysTheSameRuleItsControlsDo() async {
        let (session, http) = gatedSession()
        let source = Source(host: Self.micro, kind: .mastodon)
        await seed(session, [source])

        session.stage = .browsing
        session.openSource(host: Self.micro)
        #expect(session.stage == .browsing, "a row pressed under a sheet replaced the sheet")

        session.stage = .browsingServers(.mastodon)
        session.openSource(host: Self.micro)
        #expect(session.stage == .browsingServers(.mastodon))

        session.stage = nil
        // A host the list does not already hold, so the look actually starts: `add` refuses a
        // duplicate, and a refused press puts nothing on the wire to be caught mid-flight.
        let (look, watchdog) = await heldLook(session, http, host: "elsewhere.example")
        session.openSource(host: Self.micro)
        #expect(session.stage == nil, "a row pressed mid-errand opened a sheet over it")

        await http.gate.open()
        await look.value
        watchdog.cancel()
        // The look's own outcome is not what this test is about — only that the errand has ended.
        session.stage = nil
        session.refuse = nil

        session.openSource(host: "not.a.source.example")
        #expect(session.stage == nil, "a host that is not a source opened a detail of nothing")

        session.openSource(host: Self.micro.uppercased())
        #expect(session.stage?.host == Self.micro, "the press did not fold the host it was given")
    }

    /// **The wash is the whole of what says this row is pressable**, so a row whose press is
    /// refused must not draw it. `.buttonStyle(.plain)` supplies no dimming of its own and there is
    /// no glyph, plate or tint on the row's body to dim — so the S1 pattern is closed the way
    /// `RowActionState` closes it, by making the colour unreachable rather than by remembering.
    @Test("A refused row cannot be given the wash that says it is pressable")
    func aRefusedRowHasNoWash() {
        let light = ColorScheme.light
        #expect(
            SourceRow.press(hovering: true, actsLive: true, scheme: light)
                == .live(ShellChrome.hoverFill(light))
        )
        // A pointer that has left does not make the row unpressable — same case, no wash.
        #expect(SourceRow.press(hovering: false, actsLive: true, scheme: light) == .live(nil))
        #expect(SourceRow.press(hovering: true, actsLive: false, scheme: light) == .inert, """
            A row refused by `rowActsLive` still lit under the pointer, which is a press the \
            reader can see and cannot make.
            """)
        #expect(SourceRow.press(hovering: true, actsLive: false, scheme: light).wash == nil)

        // And the row asks the rule rather than the rule being right where nothing reads it.
        #expect(Self.drawn(Self.microRow, at: 900, actsLive: true).pressed == .live(nil))
        #expect(Self.drawn(Self.microRow, at: 900, actsLive: false).pressed == .inert)
    }

    /// **The evidence is identical and three sentences are not.** What the server said does not
    /// depend on whether the reader has taken it; what is false for a source already subscribed is
    /// the framing ("Nothing is added until you subscribe"), the outcome ("Subscribing adds…") and
    /// the caution ("…subscribing will most likely be refused").
    @Test("A detail says three things a preview does not, and every entrance answers for itself")
    func aDetailSaysWhatAPreviewCannot() {
        let held = PreviewOrigin.joined(Source(host: Self.micro, kind: .mastodon))
        // **Two origins now, and the switches over them stay split rather than collapsing.**
        // Decision 38 removed the third; what is left is exactly the distinction these sentences
        // are about — something the reader might take, and something they have.
        #expect(SourcePreviewView.framingKey(for: .field) == "join.preview.detail")
        #expect(SourcePreviewView.framingKey(for: held) == "source.held.detail")

        for caution in [SourcePreviewView.Caution.needsAccount, .turnedAway] {
            #expect(SourcePreviewView.cautionKey(caution, for: .field) == caution.key)
            #expect(SourcePreviewView.cautionKey(caution, for: held) == caution.heldKey)
            // The two are different facts — a policy and a doorman — on both entrances.
            #expect(caution.key != caution.heldKey)
        }
        #expect(
            SourcePreviewView.cautionKey(.needsAccount, for: held)
                != SourcePreviewView.cautionKey(.turnedAway, for: held)
        )

        // The outcome line's replacement, as a total map over the protocols — `DummyItemTests`'
        // shape, because a set of the interesting ones says nothing about the kinds left out.
        let expected: [ProtocolKind: String] = [
            .discourse: "source.held.forum",
            .mastodon: "source.held.microblog", .pleroma: "source.held.microblog",
            .akkoma: "source.held.microblog", .misskey: "source.held.microblog",
            .pixelfed: "source.held.microblog", .lemmy: "source.held.microblog",
            .peertube: "source.held.microblog", .friendica: "source.held.microblog",
            .gotosocial: "source.held.microblog", .unknown: "source.held.microblog",
        ]
        for (kind, key) in expected {
            #expect(
                SourcePreviewView.heldLine(Source(host: Self.micro, kind: kind))
                    == L10n.t(key, language: .english),
                "\(kind)"
            )
            // And it is the present tense of something happening, not a prediction about a press.
            #expect(
                SourcePreviewView.heldLine(Source(host: Self.micro, kind: kind))
                    != L10n.t(SourcePreviewView.outcomeKey(kind), language: .english)
            )
        }
        #expect(
            Set(expected.keys).union([.discuz]) == Set(ProtocolKind.allCases),
            "A protocol was added and this map was not asked what a reader of it is reading."
        )
    }

    /// **This is the one surface in the app where the whole board list is readable**, which is why
    /// the sheet earns its existence beyond "the profile again": the row clips it at two lines, and
    /// `spoken(_:)` gave a VoiceOver reader the untruncated list while a sighted reader had no
    /// equivalent at all. The same key as the row's line, so the two cannot drift.
    @Test("A held forum's line is its whole board list, untruncated and in the row's own words")
    func aHeldForumNamesEveryBoardItReads() {
        let forum = Source(
            host: Self.forum, kind: .discuz,
            boards: [
                BoardSubscription(fid: 33, name: "启动盘工具"),
                BoardSubscription(fid: 34, name: "閒聊"),
                BoardSubscription(fid: 35, name: "公告"),
            ]
        )
        let line = SourcePreviewView.heldLine(forum)
        #expect(line == SourceRow.boardsLine(forum), "the sheet and the row said it differently")
        for board in forum.boards {
            #expect(line.contains(board.name), "\(board.name) was left out of the whole list")
        }
        #expect(line.contains("3"), "the count leads, so it survives truncation")

        // Unreachable — a joined forum always carries at least one board — and total anyway, so a
        // guarantee two files away is not what this screen depends on.
        #expect(
            SourcePreviewView.heldLine(Source(host: Self.forum, kind: .discuz))
                == L10n.t("source.held.forum", language: .english)
        )
    }

    /// **A detail has nothing to subscribe to, and the refusal is structural rather than a guard.**
    /// `PreviewOrigin.reporter` is total with no `default:`, and `.joined` has no owner to hand
    /// over — so `take` cannot be called, `JoinSheet` draws no primary button, and there is no
    /// `if origin == .joined` anywhere to be forgotten.
    ///
    /// **It is the reporter that carries it now, and that is a deletion rather than a swap.** The
    /// door used to be `entrance: JoinEntrance?`, and what a `JoinEntrance` ever held was the
    /// answer to *which surface reports a press made here*. With decision 38 leaving one entrance,
    /// the enum was one value wrapping another; asking for the surface is asking for the door.
    @Test("Subscribe on a detail is not refused at a guard: there is nothing to press")
    func aDetailOffersNoSubscribe() async {
        #expect(PreviewOrigin.field.reporter == .block)
        #expect(PreviewOrigin.joined(Source(host: Self.micro, kind: .mastodon)).reporter == nil)

        let http = FixtureHTTP()
        let session = ShellSession(http: http, store: ItemStore())
        await seed(session, [Source(host: Self.micro, kind: .mastodon)])
        session.openSource(host: Self.micro)
        let opened = session.stage
        let before = await http.paths.count

        await session.confirm()

        #expect(await http.paths.count == before, "a detail's Subscribe reached a server")
        #expect(session.stage == opened, "a detail's Subscribe moved the reader somewhere")
        #expect(session.refuse == nil, """
            The press was answered with a refusal sentence, which is the incident this closes: \
            `look`'s duplicate guard reporting an errand nobody started.
            """)
    }

    /// Every answer the third entrance gives, one at a time. **Each is a one-line addition to a
    /// switch with no `default:`**, which is what stops a fourth entrance inheriting this one's.
    @Test("A detail draws in the sheet, covers the field, and has nothing behind it")
    func everySwitchAnswersForTheDetail() {
        let source = Source(host: Self.micro, kind: .mastodon)
        let stage = JoinStage.previewing(
            SourcePreview(host: Self.micro, kind: .mastodon, profile: .unasked(
                host: Self.micro, kind: .mastodon
            )),
            from: .joined(source),
            ticked: []
        )
        #expect(stage.surface == .sheet, "the page has no slot for it that is not above the list")
        #expect(stage.inlinePreview == nil, "the page drew a block for a sheet's stage")
        #expect(!stage.admitsASecondLook, "a detail covers the field it would be typed into")
        #expect(JoinSheet.leading(for: stage) == .close, """
            A detail is not a step in a flow and has nothing behind it, so the word is Close.
            """)
        #expect(stage.host == Self.micro)
        #expect(stage.ticked.isEmpty)
    }

    /// The detail's own sentences, present and non-empty in every bundle.
    ///
    /// **It does not check the terminology and must not claim to.** Two of these are about a
    /// *forum* and say 論壇 — `source.held.forum` and `source.held.closed` — so a blanket "says
    /// 來源" here would be false. The word is checked where it is derived, by
    /// `BoardChoiceTests.sourcesAreNotCalledHosts`: the ban over every key whose English says
    /// *server*, and the positive half over the four of these whose subject is the source itself.
    @Test("The detail's sentences are present and non-empty in every bundle")
    func theDetailSpeaksEveryLanguage() {
        #expect(
            L10n.t("source.held.detail", language: .english)
                == "What this server says about itself. You are already reading it."
        )
        #expect(
            L10n.t("source.held.microblog", language: .english)
                == "You are reading this server's public timeline."
        )
        #expect(L10n.t("account.source.open", language: .english) == "What %@ says about itself")

        let keys = [
            "account.source.open", "account.source.open.hint",
            "source.held.detail", "source.held.microblog", "source.held.forum",
            "source.held.closed", "source.held.turnedAway",
            "account.join.boards.progress",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = L10n.t(key, language: language)
                // `L10n.t` echoes the key back where a bundle has no entry, which is the one
                // failure that looks like a working screen in English and a broken one in 中文.
                #expect(said != key, "\(key) is missing in \(language)")
                #expect(!said.isEmpty)
            }
        }
    }

    // MARK: - Where a third case meets code written when there were two

    /// **`backToBrowsing` is gone, and what pins its absence is that its premise cannot be
    /// written.** It stepped back from a preview into the server directory, and it had to be told
    /// that a *detail* is not such a preview — a `guard case .previewing = stage` matched the
    /// third origin and would have thrown a reader who opened a source's own account of itself
    /// into the directory. That is this repo's `default:`-wearing-a-different-hat, found the hard
    /// way.
    ///
    /// Decision 38 removes the case the press existed for: no preview has a browser behind it, so
    /// `PreviewOrigin` has two cases and neither of them means "reached from the browser". The
    /// switch below is exhaustive over both, so a third origin added tomorrow has to answer here
    /// rather than inheriting an answer — which is the guarantee the deleted press needed and
    /// never had.
    ///
    /// `ShellSession.backToProtocols()` is not this press renamed: it steps between the browser's
    /// own two steps, and `JoinStageTests.backToProtocolsDecidesForEveryStage` drives it.
    @Test("No preview has a browser behind it, and both origins say so")
    func noPreviewStepsBackIntoTheBrowser() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        await seed(session, [Source(host: Self.micro, kind: .mastodon)])

        session.openSource(host: Self.micro)
        guard case .previewing(_, let held, _) = session.stage else {
            Issue.record("the detail was not built")
            return
        }
        let typed = PreviewOrigin.field

        // Total over `PreviewOrigin`: what each origin has behind it, said by the button it is
        // offered, and neither answer is a step into the browser.
        for origin in [typed, held] {
            let stage = JoinStage.previewing(
                SourcePreview(host: "elsewhere.example", kind: .mastodon, profile: .unasked(
                    host: "elsewhere.example", kind: .mastodon
                )),
                from: origin, ticked: []
            )
            let button = JoinSheet.leading(for: stage)
            #expect(button == .cancel || button == .close, """
                A preview offered a step back into a browser that is not behind it.
                """)
            #expect(button != .backToProtocols)
            session.stage = stage
            session.backToProtocols()
            #expect(session.stage == stage, "a preview was thrown into the browser")
        }
    }

    /// **Only `openSource` can build a detail, and it is more structural than it was.** `add()` is
    /// the only other producer of `.previewing`, and it used to take a narrowed `JoinEntrance` so
    /// that `.joined(someSource)` could not be handed to it. Decision 38 leaves one entrance, so
    /// the origin is written inside `add()` rather than passed in: there is no parameter left to
    /// hand the wrong value to, and a stage whose origin names one server while its preview names
    /// another is not a value anybody can write.
    @Test("A detail can be built by one function, and the join path cannot spell one")
    func onlyOneFunctionBuildsADetail() async {
        // The narrowing, stated: the join entrance carries no source at all, so nothing on that
        // path can be a detail.
        #expect(PreviewOrigin.field.held == nil)
        let source = Source(host: Self.micro, kind: .mastodon)
        #expect(PreviewOrigin.joined(source).held == source)

        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        await seed(session, [source])
        session.openSource(host: Self.micro)
        #expect(session.stage?.surface == .sheet)
        // The detail names one server in both halves, which is the thing the narrowing protects.
        guard case .previewing(let preview, .joined(let held), _) = session.stage else {
            Issue.record("the detail was not built")
            return
        }
        #expect(preview.host == held.host)
    }
}
