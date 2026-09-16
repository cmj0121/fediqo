import FediqoCore
import Foundation
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
    @Test("The sign-in toggle says what this device last saw, both ways round")
    func theToggleFollowsWhatWasLastSeen() {
        #expect(L10n.t(SourceRow.signInTitleKey(reached: false)) == "Sign in")
        #expect(L10n.t(SourceRow.signInTitleKey(reached: true)) == "Sign out")
        #expect(SourceRow.signInLabelKey(reached: false) == "account.refuse.signin.label")
        #expect(SourceRow.signInLabelKey(reached: true) == "account.source.signout.label")
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
        let expected = ([identity] + JoinSheet.figurePieces(profile)
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
        guard case .previewing(let preview)? = session.stage else {
            Issue.record("typing a hostname did not open its preview")
            return
        }
        #expect(preview.host == Self.micro)
        // Looked, and **nothing added** — the reader still presses Subscribe.
        #expect(session.sources.isEmpty)
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
    /// session. Remove is the one that has to destroy **nothing**: it raises the question, and only
    /// the dialog's confirm reaches `remove(host:)`.
    @Test("A row's Clear empties that server, and its Remove only asks")
    func aRowsClearAndRemoveReachTheRightThings() async {
        let session = session()
        let pane = AccountPane(session: session)
        await seed(session, [
            Source(host: Self.micro, kind: .mastodon),
            Source(host: Self.forum, kind: .discuz),
        ])
        let rows = session.rows

        await pane.clear(rows[0])
        #expect(session.cleared == 1)
        #expect(session.sources.count == 2, "Clear removed a source; it empties, it does not remove")

        pane.askRemove(rows[1])
        #expect(session.removing == Self.forum)
        #expect(session.sources.count == 2, "the question destroyed something before it was answered")
        #expect(await session.store.sources().count == 2)
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
        #expect(L10n.t("account.source.remove", language: .english) == "Remove")
        #expect(
            L10n.t("account.source.remove.label", language: .english)
                == "Remove %@ and everything it left here"
        )
        #expect(L10n.t("account.source.signin", language: .english) == "Sign in")
        #expect(L10n.t("account.source.signout", language: .english) == "Sign out")
        #expect(
            L10n.t("account.source.signout.label", language: .english)
                == "Sign out of %@ and forget what it left here"
        )
        // **The copy change unit 4 left behind, because it belongs with the list it describes.**
        // "This timeline's source" was singular and now stands over a list of servers.
        #expect(L10n.t("shell.account.summary", language: .english) == "The servers you read")

        let keys = [
            "account.sources.title", "account.sources.detail", "account.sources.held",
            "account.source.boards", "account.source.unread", "account.source.remove",
            "account.source.remove.label", "account.source.signin", "account.source.signout",
            "account.source.signout.label", "shell.account.summary",
        ]
        for key in keys {
            #expect(L10n.t(key, language: .taiwanese) != key, "\(key) is missing from the Chinese")
        }
    }

    // MARK: - A number is in the shell's language, not the device's

    /// **The defect this unit widened and therefore closes.** `.formatted` with no locale follows
    /// the *system*, and this app lets the reader choose a language the device is not set to — so
    /// on a `zh-TW` machine with the shell in English the preview drew "9.1萬 posts", one sentence
    /// in two languages, against `DESIGN.md` §0 rule 3. Unit 5 made it worse by drawing the same
    /// figures on a second surface; all three surfaces share `JoinSheet.compact`, so there is one
    /// fix and this is its pin.
    ///
    /// **Asserted without encoding this machine's locale**, which is the whole difficulty. The two
    /// languages are driven through *the same number* with nothing else varying, so what is proved
    /// is that the language decides the digits — not that any particular rendering came out. The
    /// nouns are deliberately kept out of it: comparing whole figure lines would pass on
    /// "posts" ≠ "篇文章" while the number stayed wrong in both.
    @Test("The same number in two shell languages is two numbers, and each is in one language")
    func aNumberFollowsTheShellsLanguage() {
        let english = JoinSheet.compact(91_000, language: .english)
        let chinese = JoinSheet.compact(91_000, language: .taiwanese)

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
}
