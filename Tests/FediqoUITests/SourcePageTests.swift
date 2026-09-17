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
        await session.add(from: .field)
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
    @Test("Exactly one protocol offers a sign-in, and every protocol has an answer")
    func onlyDiscuzOffersASignIn() {
        let expected: [ProtocolKind: Bool] = [
            .mastodon: false, .pleroma: false, .akkoma: false, .misskey: false,
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
        forums.recordSignIn(host: Self.forum)
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
    /// that reading it inside a body is a read that a later `recordSignIn` wakes.
    ///
    /// Driven through `withObservationTracking`, which is the same machinery SwiftUI redraws a
    /// body from — a `@ObservationIgnored` on `reachedHosts`, or the predicate ever being
    /// answered from something untracked, would leave the row saying Sign in for the rest of the
    /// run and this is the only thing that would notice.
    @Test("Recording a sign-in wakes the read the row's toggle is drawn from")
    func recordingASignInWakesTheRow() {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let woken = Woken()

        withObservationTracking {
            _ = forums.reachedSignIn(host: Self.forum)
        } onChange: {
            woken.fired = true
        }
        #expect(!woken.fired, "nothing has happened yet")

        forums.recordSignIn(host: Self.forum)

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

    // MARK: - §3.6 — this list and Preferences' stay apart

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
            == "What each one has left on this device is on Preferences.")
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
    @Test("The field is out of the reader's hands behind a sheet, and only behind a sheet")
    func theFieldIsDisabledOnlyWhereTheReaderCannotSeePastTheStage() async {
        let session = ShellSession(http: FixtureHTTP())
        let pane = AccountPane(session: session)
        let preview = SourcePreview(
            host: Self.micro, kind: .mastodon, profile: .unasked(host: Self.micro, kind: .mastodon)
        )

        #expect(!pane.busy, "nothing is happening and the field was grey")

        session.stage = .previewing(preview, from: .directory, ticked: [])
        #expect(pane.busy, "a second look could start behind a sheet the reader cannot see past")

        session.stage = .browsing
        #expect(pane.busy, "the directory covers the page")

        session.stage = .previewing(preview, from: .field, ticked: [])
        #expect(!pane.busy)

        session.stage = nil
        session.checking = true
        #expect(pane.busy, "something on the wire still takes the top half out of the reader's hands")
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
    /// directory rather than looking a host up, and the catalogue is fetched on the press
    /// (decision 10) rather than when the page appeared.
    @Test("Browse opens the directory and nothing else")
    func browseOpensTheDirectory() async {
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
        #expect(
            L10n.t("account.sources.detail", language: .english)
                == "Everything this device reads. Removing one takes its boards and its posts with it."
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
        let gone = [
            "account.source.remove", "account.source.signin", "account.source.signout",
            "timeline.sources", "source.unsigned", "source.signedIn",
        ]
        for key in gone {
            #expect(L10n.t(key, language: .english) == key, """
                \(key) is back in the bundle. Nothing draws it: if a caption has returned, it \
                needs a surface and a reason, not a revived key.
                """)
        }
    }

    /// Decision 28's requirement, which is the whole of what makes a struck control honest: it has
    /// to say **why**. Both new sentences, in both languages, and the choice between the boards
    /// control's two of them.
    @Test("A struck control says why it is struck, in every language")
    func aStruckControlSaysWhy() {
        #expect(
            L10n.t("account.source.signin.struck", language: .english)
                == "Fediqo cannot sign in to a %@ yet"
        )
        #expect(
            L10n.t("account.source.boards.struck", language: .english)
                == "Fediqo does not pick boards on a %@"
        )
        #expect(
            L10n.t("account.source.boards.none", language: .english)
                == "%@ has no boards to pick from"
        )
        for key in [
            "account.source.signin.struck", "account.source.boards.struck",
            "account.source.boards.none", "account.standing.count",
            "account.standing.count.signedIn", "account.clear.title", "account.clear.confirm",
            "account.clear.detail", "account.clear.detail.signedout", "account.clear.detail.password",
        ] {
            #expect(L10n.t(key, language: .taiwanese) != key, "\(key) is missing from the Chinese")
        }

        // The sentence names the *protocol*, because that is what lacks the capability — decision
        // 28's whole point is that the reader can see which protocols have it at all.
        let micro = Source(host: Self.micro, kind: .mastodon)
        #expect(
            SourceRow.struckReason(.signIn, source: micro) == "Fediqo cannot sign in to a Mastodon yet"
        )
        #expect(
            SourceRow.struckReason(.boards, source: micro)
                == "Fediqo does not pick boards on a Mastodon"
        )
        // **Two keys and not one, because these are two different facts.** A protocol with no
        // picker and a source with nothing to pick are not the same sentence, and a translator
        // cannot make one carry both.
        let empty = Source(host: Self.forum, kind: .discuz)
        #expect(
            SourceRow.struckReason(.boards, source: empty) == "\(Self.forum) has no boards to pick from"
        )
        // Neither Clear nor Remove is ever struck, so neither ever has a reason to give.
        for control in [SourceRow.Control.clear, .remove] {
            #expect(SourceRow.struckReason(control, source: micro) == nil)
        }
        // And a live control's label is the act, not a reason — the two must not both appear.
        let forum = Source(
            host: Self.forum, kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "閒聊")]
        )
        #expect(SourceRow.struckReason(.boards, source: forum) == nil)
        #expect(
            SourceRow.controlLabel(.boards, source: forum, signedIn: false)
                == "Change which boards you read on \(Self.forum)"
        )
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

    // MARK: - The two arrangements, and the two constants
    //
    // **This is the part of the row a test has to carry alone.** A layout that depends on a
    // measured width is wiring no test can see, and this branch has now shipped four defects of
    // exactly that class under a fully green suite (risk 12). So the decision is a pure function
    // and it is driven here across both arrangements, the unmeasured first frame and the boundary.
    // What is *not* reachable is named in `SourceRowView`'s own doc comment: `AccountPane`'s
    // `onGeometryChange`, which is SwiftUI's own measurement.

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
        // **The structure, which is what the constants are now summed from.** Each of these is a
        // symbol the drawn row reads: `SourceRowView`'s glyph frame takes `gutterWidth`, its
        // `actions` loop iterates `Control.allCases` and lays out `gaps`. So a change to any of
        // them moves the drawn row and the constant together — and lands here as a changed value.
        #expect(SourceRow.gutterWidth == 20)
        #expect(SourceRow.touch == 44, "the 44pt floor is what 176 of the control line is")
        #expect(SourceRow.gaps == [ShellSpace.tight, ShellSpace.snug, ShellSpace.snug], """
            The gap sequence changed. `actions` lays these out and `controlLine` sums them, so \
            the row just moved — which is the point of reading this list in both places.
            """)
        #expect(SourceRow.Control.allCases.count == 4)
        #expect(SourceRow.gaps.count == SourceRow.Control.allCases.count - 1, """
            Four targets have three gaps. A control added without a gap traps at its first \
            layout, so it is caught here instead.
            """)

        #expect(SourceRow.furniture == 240)
        #expect(SourceRow.furniture == SourceRow.controlLine + SourceRow.gutterWidth
            + ShellSpace.step * 2)

        // **240 and not 184, declared rather than quietly re-expected.** Decision 30 adds a fourth
        // control; §3.1 refused one on size, the size argument was right, and it is now paid.
        #expect(SourceRow.furniture == 184 + SourceRow.touch + ShellSpace.step, """
            The fourth control's cost is one target plus the gap it brought. If this drifts, the \
            constant has stopped being the row.
            """)
    }

    /// **The mutation the previous version of these tests could not see.** Both constants used to
    /// be literals whose terms lived in a doc comment, and the test restated the same literals — so
    /// it agreed with the row by hand rather than deriving from it. QA proved it twice: the glyph
    /// gutter changed 20 → 28 and the suite passed; a drawn gap was re-tokened `tight` → `snug`,
    /// the real group became 200pt, and `controlLine == 196` stayed green while being false.
    ///
    /// Both now come out of the same two symbols the row lays out, so this test is about the
    /// *structure* rather than about the tokens underneath it: change what the row draws, and
    /// these numbers move.
    @Test("Both constants are summed from the structure the row draws, not stated beside it")
    func theConstantsAreDerivedFromTheDrawnRow() {
        #expect(SourceRow.controlLine == 196)
        #expect(SourceRow.controlLine
            == SourceRow.touch * CGFloat(SourceRow.Control.allCases.count)
                + SourceRow.gaps.reduce(0, +))

        // A control added or taken away moves the line by a target and a gap; that is the shape a
        // fifth control has to arrive in, and it cannot arrive without moving this number.
        let five = SourceRow.touch * 5 + SourceRow.gaps.reduce(0, +) + ShellSpace.snug
        #expect(five != SourceRow.controlLine)
        #expect(five == 248, "a fifth control costs a target and a gap, and both are visible here")

        // And the gutter is one symbol, not two literals that can drift apart.
        #expect(SourceRow.furniture - SourceRow.controlLine - ShellSpace.step * 2
            == SourceRow.gutterWidth)
    }

    /// **`controlLine` is invariant and that is the whole argument for the `beneath` regime.**
    /// No words, a fixed touch floor, `ShellSpace` gaps, and a glyph capped below its own target —
    /// so 196 is 196 at every rung, in all three languages, on both platforms.
    @Test("The control line is 196pt of nothing that can vary")
    func theControlLineCannotMove() {
        #expect(SourceRow.controlLine
            == SourceRow.touch * 4 + ShellSpace.tight + ShellSpace.snug * 2)
        #expect(SourceRow.controlLine == 196)
        // The two constants are the same group, counted with and without the row around it.
        #expect(SourceRow.furniture
            == SourceRow.controlLine + SourceRow.gutterWidth + ShellSpace.step * 2)

        // **The narrowest real case, restated term by term.** macOS `minWidth: 520`, less the open
        // rail's 201 and its hairline, is 318pt of page; less `ShellSpace.pad` either side, 286pt
        // of row; less the glyph gutter and the gap after it, 254pt of content column.
        let page: CGFloat = 520 - 201 - ShellSpace.hair
        let row = page - ShellSpace.pad * 2
        let column = row - SourceRow.gutterWidth - ShellSpace.step
        #expect(page == 318)
        #expect(row == 286)
        #expect(column == 254)
        #expect(SourceRow.controlLine + SourceRow.gutterWidth + ShellSpace.step
            + ShellSpace.pad * 2 <= page, """
            The four controls no longer fit the macOS minimum window with the rail open, which is \
            the one case the `beneath` arrangement exists for.
            """)
        #expect(column - SourceRow.controlLine == 58, "the spare at the default rung")

        // At the largest rung the gutter scales to about 33 and the spare narrows; it never closes.
        let grownColumn = row - 33 - ShellSpace.step
        #expect(grownColumn - SourceRow.controlLine >= 45)
    }

    /// **The ceiling is what makes both constants true rather than hopeful.** A glyph is allowed to
    /// grow with the type until it would reach the edges of the 44pt target it sits in, and then it
    /// stops — so the control group cannot widen past 176pt of targets at any Dynamic Type rung.
    @Test("A control glyph stops growing before it reaches the edges of its own target")
    func theGlyphIsCappedBelowItsTarget() {
        #expect(SourceRow.symbolPoints(24) == 24, "at the default rung nothing is capped")
        #expect(SourceRow.symbolPoints(36) == 36, "the ceiling itself is not below it")
        #expect(SourceRow.symbolPoints(60) == 36, "a large rung grew the glyph out of its target")
        #expect(SourceRow.symbolPoints(1_000) == SourceRow.touch - ShellSpace.snug)
        // Stated as the arithmetic rather than as 36, so a change to either token is caught here.
        #expect(SourceRow.touch - ShellSpace.snug == 36)
        // The property this buys: the group is the same width whatever the type does.
        for scaled in [CGFloat(16), 24, 36, 48, 96] {
            #expect(SourceRow.symbolPoints(scaled) <= SourceRow.touch, """
                A glyph reached its own target's edge, so the control group is wider than \
                `SourceRow.controlLine` says and the narrow case is no longer proved.
                """)
        }
    }

    /// **The first frame, before anything has been measured.** `onGeometryChange` has not fired, so
    /// the width is zero — and zero is not a narrow row, it is no answer at all.
    ///
    /// **The reason has changed and the answer has not.** It used to be *this layout never clips*;
    /// it is now *this layout never crowds* — 196pt of controls against 254pt of content column in
    /// the narrowest real case, so the safe choice on an unmeasured frame costs nothing at all.
    @Test("An unmeasured row is drawn beneath, and a negative one too")
    func theFirstFrameGetsTheSafeRegime() {
        #expect(SourceRow.regime(width: 0) == .beneath)
        // A layout pass that reports a negative width is not a row to draw icons in either.
        #expect(SourceRow.regime(width: -10) == .beneath)
    }

    /// **480pt, and the rule behind it is "the words get at least half the row".** Pinned from both
    /// sides and *at* the boundary, because an off-by-one here is a row that crowds in Chinese on
    /// the one width where it was most carefully argued that it would not.
    @Test("The threshold is twice the furniture, and the boundary itself is trailing")
    func theBoundaryIsTwiceTheFurniture() {
        let threshold = SourceRow.furniture * 2
        #expect(threshold == 480)
        #expect(threshold - SourceRow.furniture >= SourceRow.furniture,
                "at the boundary the words must get at least what the furniture gets")

        #expect(SourceRow.regime(width: threshold) == .trailing,
                "at the boundary the words get exactly half, which is the rule met")
        #expect(SourceRow.regime(width: threshold - 0.5) == .beneath)
        #expect(SourceRow.regime(width: threshold + 0.5) == .trailing)
    }

    /// **Where each real context lands, and every row in the table moved.** That is decision 30's
    /// stated cost, accepted by the user after being shown this arithmetic: four larger targets put
    /// the threshold at 480, so **every row is drawn beneath at the macOS minimum window**, and a
    /// phone reaches the trailing arrangement on no size Apple currently ships.
    ///
    /// Declared rather than quietly re-expected: at 184 the collapsed-rail Mac and a 430pt phone
    /// were both trailing, and they are not any more.
    @Test("Where each real context lands, including the macOS minimum window")
    func theRealContextsLandWhereTheyWereMeasured() {
        let contexts: [(String, CGFloat, SourceRow.Regime)] = [
            ("macOS, 520pt window, rail expanded", 286, .beneath),
            ("macOS, 520pt window, rail collapsed", 439, .beneath),
            ("macOS, any normal window", 568, .trailing),
            ("iPhone SE, 375pt", 343, .beneath),
            ("iPhone 390pt", 358, .beneath),
            ("iPhone 430pt", 398, .beneath),
            ("iPad, 1024pt page, rail expanded", 791, .trailing),
        ]
        for (context, row, expected) in contexts {
            #expect(
                SourceRow.regime(width: row) == expected,
                "\(context) at \(row)pt is drawn in the wrong arrangement"
            )
        }
    }

    /// **One axis, and the second gate is gone.** It existed to protect *words* in the action row,
    /// and this ruling deletes those words. The evidence it was wrong as well as redundant is the
    /// last two lines: an iPad at `.accessibility1` has 791pt of row and four glyphs that cannot
    /// exceed 36pt each, and the type gate would have restacked it.
    ///
    /// Gone with the gate: `SourceRowView.typeScales`, its `#if os(macOS)` and the row's
    /// `@Environment(\.dynamicTypeSize)` read. `regime` now takes one argument, so a type size
    /// cannot be handed to it at all — which is why this test is about the shape of the call.
    @Test("The type size decides nothing, on any platform or rung")
    func theTypeGateIsGone() {
        // A wide row is trailing and a narrow one is beneath, and nothing else is consulted.
        #expect(SourceRow.regime(width: 900) == .trailing)
        #expect(SourceRow.regime(width: 300) == .beneath)
        #expect(DummyFontSize.allCases.count == 5, "the ladder changed and nothing re-read it")

        // **Both places the deleted gate fired where width had not, and not only the flattering
        // one.** The first report of this claimed the gate was redundant "except on an iPad",
        // which was wrong as a statement of fact: at HEAD's 368 threshold it fired at
        // `.accessibility1` on every page above that, and a 430pt iPhone is 398pt of row.
        let head: CGFloat = 184 * 2
        #expect(head == 368, "HEAD's threshold, which is what the old gate fired on top of")
        for row in [CGFloat(398), 791] {
            #expect(row > head, """
                \(row)pt was trailing by width at HEAD, so the type gate restacking it at the \
                largest rung was the gate speaking where width had not.
                """)
        }
        // On the phone that was redundant; 398pt is beneath by width alone now, so the gate has
        // nothing left to say there either way.
        #expect(SourceRow.regime(width: 398) == .beneath)
        // On an iPad it was *wrong*, and this is the one case that survives the new threshold:
        // 791pt has room for 196pt of controls at every rung and no reason to restack.
        #expect(SourceRow.regime(width: 791) == .trailing, """
            An iPad page has room for the control line at every rung. A gate that restacked it \
            was firing where firing was wrong, which is why the axis is width alone.
            """)
        #expect(SourceRow.controlLine < 791 - SourceRow.gutterWidth - ShellSpace.step)
    }

    // MARK: - Decision 28, delivered to a phone

    /// **`.help()` is a no-op on iOS, so a struck control on a phone gave the strike and no
    /// reason** — a control silent about its own refusal, which is the thing decision 28 exists to
    /// forbid. The row's licence for four unlabelled glyphs is that none of them does anything
    /// irreversible on first press, and that argument covers the *pressable* ones: a struck control
    /// cannot be pressed to discover what it is.
    ///
    /// So a struck control stays tappable and its press puts the reason in the row's status line —
    /// the sibling the waiting and refusal sentences already use.
    @Test("A struck control is still pressable, and pressing it is what explains it")
    func aStruckControlCanBeAskedWhy() {
        // Dimmed refuses the press; struck does not, because struck is the one that has something
        // to say and no other way to say it.
        #expect(SourceRowView.explains(.struck))
        #expect(!SourceRowView.explains(.dimmed))
        #expect(!SourceRowView.explains(.live(ShellChrome.alarm(.light))))

        // A toggle, so there is a way back, and a readout rather than a stack.
        #expect(SourceRow.explaining(.signIn, current: nil) == .signIn)
        #expect(SourceRow.explaining(.signIn, current: .signIn) == nil, "no way back out")
        #expect(SourceRow.explaining(.boards, current: .signIn) == .boards, "a readout, not a stack")

        // And what the line then says is the sentence already written for `.help()` and for the
        // spoken label — one string, so there is nothing new to translate and the three cannot
        // come to disagree.
        let micro = Source(host: Self.micro, kind: .mastodon)
        let reason = SourceRow.struckReason(.signIn, source: micro)
        #expect(reason == "Fediqo cannot sign in to a Mastodon yet")
        #expect(SourceRow.controlLabel(.signIn, source: micro, signedIn: false) == reason)

        // The act is unreachable from a struck control by construction rather than by a guard:
        // every struck control is one `explains` answers true for.
        for control in SourceRow.Control.allCases {
            let struck = SourceRow.isStruck(control, source: micro)
            #expect(SourceRowView.explains(
                SourceRow.state(of: control, source: micro, actsLive: true) == .struck
                    ? .struck : .live(ShellChrome.inkDim(.light))
            ) == struck, "\(control)")
        }
    }

    /// **The view's own application of the rule.** `SourceRow.regime` being right proves nothing
    /// about the row unless the row asks it the right question, and a width hardcoded in
    /// `SourceRowView.regime` — or the height read where the width was meant — is precisely the
    /// wiring-unreachable defect this branch has shipped four times (risk 12).
    @Test("The row asks the rule about its own width, and a hardcoded one dies here")
    func theRowPassesItsWidthToTheRule() {
        #expect(Self.drawn(Self.microRow, at: 0).regime == .beneath,
                "the unmeasured first frame is not a wide row")
        #expect(Self.drawn(Self.microRow, at: 300).regime == .beneath)
        #expect(Self.drawn(Self.microRow, at: 400).regime == .beneath,
                "400pt of row is under the four-control threshold")
        #expect(Self.drawn(Self.microRow, at: 500).regime == .trailing)
    }

    // MARK: - Decisions 28 and 30 — four controls, three looks

    private static let microRow = SourceRow(
        source: Source(host: micro, kind: .mastodon),
        profile: .unasked(host: micro, kind: .mastodon)
    )

    static func drawn(
        _ row: SourceRow, at width: CGFloat, actsLive: Bool = true, signedIn: Bool = false
    ) -> SourceRowView {
        SourceRowView(
            row: row, signedIn: signedIn, width: width,
            actsLive: actsLive, waiting: nil, refusal: nil,
            signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
        )
    }

    /// **Two looks, two meanings** — the rail's `closedMark` doctrine, applied where decision 28
    /// reverses decision 4. Struck says *this protocol has no such thing*; dimmed says *not right
    /// now*. A single grey would have collapsed them into one, which is exactly the silence the
    /// decision was made against.
    @Test("Every control has a state on every protocol, and the two greys mean different things")
    func everyControlHasAState() {
        let micro = Source(host: Self.micro, kind: .mastodon)
        let forum = Source(
            host: Self.forum, kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "閒聊")]
        )

        // A microblog: neither capability exists, so both are struck — drawn, and saying why.
        #expect(SourceRow.state(of: .signIn, source: micro, actsLive: true) == .struck)
        #expect(SourceRow.state(of: .boards, source: micro, actsLive: true) == .struck)
        #expect(SourceRow.state(of: .clear, source: micro, actsLive: true) == .live)
        #expect(SourceRow.state(of: .remove, source: micro, actsLive: true) == .live)

        // A forum with boards: all four are the reader's.
        for control in SourceRow.Control.allCases {
            #expect(SourceRow.state(of: control, source: forum, actsLive: true) == .live, "\(control)")
        }

        // **Struck beats dimmed, because they answer different questions.** A protocol does not
        // acquire a sign-in while a sheet happens to be open.
        #expect(SourceRow.state(of: .signIn, source: micro, actsLive: false) == .struck)
        #expect(SourceRow.state(of: .clear, source: micro, actsLive: false) == .dimmed)
        for control in SourceRow.Control.allCases {
            #expect(SourceRow.state(of: control, source: forum, actsLive: false) == .dimmed, "\(control)")
        }

        // A Discourse: boards exist as a concept for no protocol but Discuz!, so Boards is struck
        // even where the source carries some — unit 7 answers this at `canChangeBoards`.
        let discourse = Source(
            host: "f.example", kind: .discourse,
            boards: [BoardSubscription(fid: 1, name: "somewhere")]
        )
        #expect(SourceRow.state(of: .boards, source: discourse, actsLive: true) == .struck)

        // And the two facts that strike the boards control are both asked, not one of them.
        #expect(SourceRow.isStruck(.boards, source: Source(host: Self.forum, kind: .discuz)), """
            A forum with no boards drew a live control over a sheet with nothing in it.
            """)
        #expect(!SourceRow.isStruck(.boards, source: forum))
        // Neither of the two that every source has is ever struck.
        for kind in ProtocolKind.allCases {
            let any = Source(host: "a.example", kind: kind)
            #expect(!SourceRow.isStruck(.clear, source: any), "\(kind)")
            #expect(!SourceRow.isStruck(.remove, source: any), "\(kind)")
        }
        #expect(SourceRow.Control.allCases.count == 4, "a control was added and has no state")
    }

    /// **The view's own mapping, read back off the view — which is the half risk 12 counts.**
    /// `SourceRow.state(of:source:actsLive:)` being right proves nothing unless the row asks it
    /// about each of its four controls and attaches the hue only where the answer is live. That
    /// mapping used to be two style modifiers inside a `View` body, where nothing could ask what
    /// they had decided — the defect the boards plate shipped with, and the one `RowActionButton`'s
    /// own doc predicted for these controls.
    ///
    /// **A colour can only arrive inside `.live`**, so a struck or dimmed control cannot be handed
    /// one, which is the trap this unit closes. That is what the `.dimmed`/`.struck` expectations
    /// below are: not "it is grey" but "there is nowhere to put a colour".
    @Test("The row maps every control to a state, and a hue reaches only a live one")
    func theRowReadsTheRuleForAllFour() {
        let forum = SourceRow(
            source: Source(
                host: Self.forum, kind: .discuz,
                boards: [BoardSubscription(fid: 33, name: "閒聊")]
            ),
            profile: .unasked(host: Self.forum, kind: .discuz)
        )
        // Outside a rendered tree `@Environment(\.colorScheme)` hands back `.light`, which is what
        // makes the hue readable as a value here at all.
        let light = ColorScheme.light

        for width in [CGFloat(286), 900] {
            let live = Self.drawn(forum, at: width, actsLive: true)
            #expect(live.state(.signIn) == .live(ShellChrome.inkDim(light)), "at \(width)")
            #expect(live.state(.boards) == .live(ShellChrome.inkDim(light)), "at \(width)")
            // Decision 29: both of these carry the alarm the user chose, in both arrangements.
            #expect(live.state(.clear) == .live(ShellChrome.alarm(light)), "at \(width)")
            #expect(live.state(.remove) == .live(ShellChrome.alarm(light)), "at \(width)")

            // State B8, closed rather than deferred: nothing on this row is live, and no hue is
            // reachable to make one of them look as though it were.
            let held = Self.drawn(forum, at: width, actsLive: false)
            for control in SourceRow.Control.allCases {
                #expect(held.state(control) == .dimmed, "\(control) at \(width)")
            }
        }

        // `filament` is what a mark turns once the reader has switched it on, and the sign-in is
        // the one control that changes hue without being pressed.
        #expect(
            Self.drawn(forum, at: 900, signedIn: true).state(.signIn)
                == .live(ShellChrome.filament(light))
        )

        // And a microblog's two absent capabilities are struck at the view, not merely at the rule.
        let micro = Self.drawn(Self.microRow, at: 900)
        #expect(micro.state(.signIn) == .struck)
        #expect(micro.state(.boards) == .struck)
        #expect(micro.state(.clear) == .live(ShellChrome.alarm(light)))
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
    @Test("A row's press is refused exactly when its controls are, and by the same rule")
    func theRowsPressObeysTheSameRuleItsControlsDo() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        let source = Source(host: Self.micro, kind: .mastodon)
        await seed(session, [source])

        session.stage = .browsing
        session.openSource(host: Self.micro)
        #expect(session.stage == .browsing, "a row pressed under a sheet replaced the sheet")

        session.stage = nil
        session.checking = true
        session.openSource(host: Self.micro)
        #expect(session.stage == nil, "a row pressed mid-errand opened a sheet over it")

        session.checking = false
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
        #expect(SourcePreviewView.framingKey(for: .field) == "join.preview.detail")
        #expect(SourcePreviewView.framingKey(for: .directory) == "join.preview.detail")
        #expect(SourcePreviewView.framingKey(for: held) == "source.held.detail")

        for caution in [SourcePreviewView.Caution.needsAccount, .turnedAway] {
            #expect(SourcePreviewView.cautionKey(caution, for: .field) == caution.key)
            #expect(SourcePreviewView.cautionKey(caution, for: .directory) == caution.key)
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
    /// `PreviewOrigin.entrance` is total with no `default:`, and `.joined` has no entrance to hand
    /// over — so `take` cannot be called, `JoinSheet` draws no primary button, and there is no
    /// `if origin == .joined` anywhere to be forgotten.
    @Test("Subscribe on a detail is not refused at a guard: there is nothing to press")
    func aDetailOffersNoSubscribe() async {
        #expect(PreviewOrigin.field.entrance == .field)
        #expect(PreviewOrigin.directory.entrance == .directory)
        #expect(PreviewOrigin.joined(Source(host: Self.micro, kind: .mastodon)).entrance == nil)
        // And back the other way, which is what `backToPreview` reconstructs a stage from.
        #expect(JoinEntrance.field.origin == .field)
        #expect(JoinEntrance.directory.origin == .directory)

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

    /// **A detail is not a preview with a directory behind it, and `backToBrowsing` had to be told
    /// so.** `guard case .previewing = stage` matched the new origin and would have thrown a
    /// reader who opened a source's own detail into the server directory. Unreachable from the
    /// sheet — `leading(for:)` gives a detail Close — which is exactly what makes it the kind of
    /// silent wrong answer `backToPreview`'s own doc bans: a `default:` wearing a different hat.
    @Test("Back to the directory declines for every stage that has no directory behind it")
    func backToBrowsingDecidesForEveryOrigin() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        await seed(session, [Source(host: Self.micro, kind: .mastodon)])

        session.openSource(host: Self.micro)
        let detail = session.stage
        session.backToBrowsing()
        #expect(session.stage == detail, """
            A reader looking at what a source says about itself was thrown into the directory.
            """)

        // A typed host's preview has the page behind it, not the directory, and is unchanged.
        let typed = JoinStage.previewing(
            SourcePreview(host: "elsewhere.example", kind: .mastodon, profile: .unasked(
                host: "elsewhere.example", kind: .mastodon
            )),
            from: .field, ticked: []
        )
        session.stage = typed
        session.backToBrowsing()
        #expect(session.stage == typed)

        // And the one origin that does have the directory behind it still steps back to it.
        session.stage = .previewing(
            SourcePreview(host: "elsewhere.example", kind: .mastodon, profile: .unasked(
                host: "elsewhere.example", kind: .mastodon
            )),
            from: .directory, ticked: []
        )
        session.backToBrowsing()
        #expect(session.stage == .browsing)
    }

    /// **Only `openSource` can build a detail, and that is now structural.** `add(from:)` is the
    /// only other producer of `.previewing`, and it takes the narrowed `JoinEntrance` — so
    /// `.joined(someSource)` cannot be handed to it, and a stage whose origin names one server
    /// while its preview names another is not a value anybody can write.
    @Test("A detail can be built by one function, and the join path cannot spell one")
    func onlyOneFunctionBuildsADetail() async {
        // The narrowing, stated: both join entrances map to a preview origin and neither of them
        // is the held one, so `add`'s parameter cannot carry a source.
        #expect(JoinEntrance.field.origin == .field)
        #expect(JoinEntrance.directory.origin == .directory)
        #expect(PreviewOrigin.field.held == nil)
        #expect(PreviewOrigin.directory.held == nil)
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
