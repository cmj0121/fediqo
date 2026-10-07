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
        #expect(!discourse.canSignIn)
        // **Drawn dim where it is false, and no longer absent** — decision 4 was withdrawn on
        // 2026-10-07: the same key on every row, only its colour different.
        #expect(Self.drawn(discourse).key.look == .dim(.never))
        #expect(Self.drawn(discuz).key.look == .live)
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
                == "Sign out of \(Self.forum). It asks first."
        )
    }

    /// **The wiring, not only the rule.** A predicate that is right and a press that never consults
    /// it is this milestone's recurring failure, so the press itself is driven here: it must sign
    /// in when this device has seen nothing, and — once it has — ask before it signs out, with
    /// only the question's yes ending the sign-in.
    @Test("Pressing the toggle signs in, or asks to sign out, according to that same predicate")
    func pressingTheToggleGoesTheRightWay() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), forums: forums)
        await seed(session, [Source(host: Self.forum, kind: .discuz)])
        let pane = AccountPane(session: session)
        let row = try! #require(session.rows.first)

        // Nothing seen: the press asks for the forum's own page.
        await pane.press(row)
        #expect(session.signingIn?.host == Self.forum, "the press did not offer a sign-in")

        // Seen: the press asks, and signs nobody out by asking.
        session.signingIn = nil
        await forums.plantSession(host: Self.forum)
        #expect(forums.reachedSignIn(host: Self.forum), "the premise did not hold")
        #expect(session.signOutAsk == nil)
        await pane.press(row)
        #expect(session.signOutAsk?.host == Self.forum, "the press did not put the question")
        #expect(forums.reachedSignIn(host: Self.forum), "the press signed the reader out before they answered")

        // Putting the question down changes nothing.
        session.signOutAsk = nil
        #expect(forums.reachedSignIn(host: Self.forum))

        // Its yes ends the sign-in, and the predicate goes back to no.
        await pane.press(row)
        await pane.signOut(Self.forum)
        #expect(session.signOutAsk == nil, "the question outlived its answer")
        #expect(!forums.reachedSignIn(host: Self.forum), "the yes did not sign the reader out")
        #expect(session.signingIn == nil, "signing out opened a sign-in sheet")
        #expect(session.sources.map(\.host) == [Self.forum], "signing out removed the source")
    }

    /// A sign-out question waits in the session, and the page that draws it can go while it
    /// waits. Whatever makes its words stale puts it down, so it cannot come back later.
    @Test("A sign-out still being asked is put down by a Clear or a Remove of that source, and by the page leaving; one about another source is left alone")
    func aWaitingSignOutIsPutDown() async {
        let other = "other.example"
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), forums: ForumSessions(credentials: MemoryCredentials()))
        await seed(session, [Source(host: Self.forum, kind: .discuz), Source(host: other, kind: .discuz)])

        // Only the one about that source, whatever its case.
        session.askSignOut(host: Self.forum)
        session.dropSignOutAsk(host: other)
        #expect(session.signOutAsk?.host == Self.forum, "a question about another source was put down")
        session.dropSignOutAsk(host: Self.forum.uppercased())
        #expect(session.signOutAsk == nil)

        // The page leaving puts down whichever there is.
        session.askSignOut(host: Self.forum)
        session.dropSignOutAsk()
        #expect(session.signOutAsk == nil)
        session.dropSignOutAsk()
        #expect(session.signOutAsk == nil, "putting down nothing is nothing")

        // A Clear of another source leaves it; a Clear of its own takes it.
        session.askSignOut(host: Self.forum)
        await session.clear(host: other)
        #expect(session.signOutAsk?.host == Self.forum)
        await session.clear(host: Self.forum)
        #expect(session.signOutAsk == nil, "the question outlived a Clear of its source")

        // And so does a Remove.
        session.askSignOut(host: Self.forum)
        await session.remove(host: other)
        #expect(session.signOutAsk?.host == Self.forum)
        await session.remove(host: Self.forum, keepingPosts: true)
        #expect(session.signOutAsk == nil, "the question outlived a Remove of its source")

        // The page puts it down as it leaves, in the question's own modifier.
        let pane = try! String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell/AccountPane.swift"),
            encoding: .utf8
        )
        #expect(pane.contains(".onDisappear { session.dropSignOutAsk() }"))
    }

    /// Remove's question and its yes read one value, and where the page has no preferences to
    /// read that value is the one that takes less.
    @Test("Without the preferences a removed source's posts stay; with them it is the reader's choice")
    func absentPreferencesKeepThePosts() throws {
        #expect(AccountPane.postsStay(nil), "not knowing fell on the side that deletes")
        #expect(!AccountPane.postsStay(false))
        #expect(AccountPane.postsStay(true))
        // The question and its yes read that one closure, and a press with none handed in
        // falls the same way.
        let pane = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell/AccountPane.swift"),
            encoding: .utf8
        )
        #expect(pane.contains("return { Self.postsStay(prefs?.removedPostsStay) }"))
        #expect(pane.contains("removeAsks: { session.removeQuestion(host: row.source.host, postsStay: postsStay()) }"))
        #expect(pane.contains("presses: presses(row, postsStay: postsStay)"))
        #expect(pane.contains("postsStay: @escaping () -> Bool = { AccountPane.postsStay(nil) }"))
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
        // **The writing word is the second part** (#69). The row stopped drawing it on
        // 2026-10-07 and the sentence still says it. A Discourse reads only, and for a reason
        // that is about the protocol: this app cannot write to a forum at all.
        let writing = L10n.t(SourceRow.writingKey(.never))
        let expected = ([identity, writing] + SourcePreviewView.figurePieces(profile)
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
    ///
    /// **Asked from the row's `…` since 2026-10-07**, where they are destructive items: choosing
    /// one hands over its question and nothing else, and the pane's `clear(_:)` and
    /// `remove(_:keepingPosts:)` are what its yes does.
    @Test("A row's Clear and its Remove both only ask")
    func aRowsClearAndRemoveReachTheRightThings() async {
        let session = session()
        let pane = AccountPane(session: session)
        await seed(session, [
            Source(host: Self.micro, kind: .mastodon),
            Source(host: Self.forum, kind: .discuz),
        ])
        let rows = session.rows
        func menu(_ row: SourceRow) -> ShellMore {
            SourceRowView(
                row: row, actsLive: true, waiting: nil, refusal: nil,
                clearAsks: { session.clearQuestion(host: row.source.host) }, removeAsks: { session.removeQuestion(host: row.source.host, postsStay: false) },
                presses: pane.presses(row)
            ).more
        }
        var asked: [ShellMoreAsk] = []

        menu(rows[0]).dangers[0].press { asked.append($0) }
        #expect(asked.last?.question == session.clearQuestion(host: Self.micro))
        #expect(session.cleared == 0, "Clear emptied a server before the question was answered")

        menu(rows[1]).dangers[1].press { asked.append($0) }
        #expect(asked.last?.question == session.removeQuestion(host: Self.forum, postsStay: false))
        #expect(asked.count == 2)
        #expect(session.sources.count == 2, "the question destroyed something before it was answered")
        #expect(await session.store.sources().count == 2)
        // One question an act: the menu's own. Nothing on the root asks beside it.
        // Any answer but the yes changes nothing.
        asked[1].answered("not the yes")
        await Task.yield()
        #expect(session.sources.count == 2)

        // And the confirms, which are where the two acts actually differ.
        await pane.clear(rows[0])
        #expect(session.cleared == 1)
        #expect(session.sources.count == 2, "Clear removed a source; it empties, it does not remove")
        await pane.remove(rows[1], keepingPosts: false)
        #expect(session.sources.map(\.host) == [Self.micro])
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
        // The legend, and its first clause is the load-bearing one: every row draws the same
        // marks (decision 33's absence was withdrawn on 2026-10-07), so what a reader has to be
        // told is what grey means and where the rest went.
        #expect(
            L10n.t("account.sources.marks", language: .english) == """
                Every row carries the same marks. The key is the sign-in: filled once you are \
                signed in, grey where that source has none. Pressed while filled, it asks before \
                it signs you out. ⋯ holds the rest: what the row has to say, changing boards or lists, clearing what the source left here, and \
                removing it. What a source does not have is grey there too, and says why. A red ⋯ \
                has something to say.
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
                == "Sign out of %@. It asks first."
        )
        // **The copy change unit 4 left behind, because it belongs with the list it describes.**
        // "This timeline's source" was singular and now stands over a list of servers.
        #expect(L10n.t("shell.account.summary", language: .english) == "The servers you read")

        let keys = [
            "account.sources.title", "account.sources.detail", "account.sources.held",
            "account.sources.marks", "account.source.permission",
            "account.source.boards", "account.source.unread",
            "account.source.remove.label", "account.source.signout.label", "shell.account.summary",
            "source.said.asOf",
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
        //
        // **They stay gone though decision 33 is itself withdrawn** (2026-10-07): a control a
        // source lacks is drawn again, dim, and its reason is the shared `mark.dim.*`, one
        // sentence for every row and every post rather than three of this page's own.
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

    /// **The wiring, which is the half risk 12 counts.** Both entrances are a destructive item
    /// of a `…` carrying one question, and neither empties anything by itself; only the
    /// question's yes reaches `clear(host:)`.
    @Test("Both Clears ask the same question, and neither empties anything by asking")
    func bothClearsAsk() async throws {
        let session = self.session()
        await seed(session, [Source(host: Self.forum, kind: .discuz)])
        let pane = AccountPane(session: session)
        let row = try #require(session.rows.first)

        // Usage's entrance is its detail's `…`; the row's `…` asks the same question itself
        // (`aRowsClearAndRemoveReachTheRightThings`). One function builds it for both.
        var put: [ShellMoreAsk] = []
        let usage = UsageSourceDetail.more(row.source, in: session).items[0]
        #expect(usage.isDanger)
        usage.press { put.append($0) }
        #expect(put.first?.question == session.clearQuestion(host: row.source.host))
        #expect(session.cleared == 0, "asking emptied something before it was answered")

        // The confirm — the same call from either page.
        await pane.clear(row)
        #expect(session.cleared == 1)

        // **Remove clears on its way out**: `remove` reaches `clear`.
        await session.remove(host: Self.forum)
        #expect(session.cleared == 2)
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

    // MARK: - The row's metrics
    //
    // The two arrangements, their threshold and the arithmetic that chose between them were
    // withdrawn on 2026-10-07: a row is one layout at every width (`SourceLineTests` hosts it).
    // What is left of the numbers is the leading mark's size and its ceiling.

    /// The leading mark is allowed to grow with the type until it would reach the edges of the
    /// 44pt line it sits in, and then it stops — so a large type size never makes a row taller
    /// for its mark.
    @Test("A mark stops growing before it reaches the edges of its own target")
    func theGlyphIsCappedBelowItsTarget() {
        #expect(SourceRow.markBase == 24)
        #expect(SourceRow.touch == 44)
        #expect(SourceRow.symbolPoints(24) == 24, "at the default rung nothing is capped")
        #expect(SourceRow.symbolPoints(36) == 36, "the ceiling itself is not below it")
        #expect(SourceRow.symbolPoints(60) == 36, "a large rung grew the mark out of its target")
        #expect(SourceRow.symbolPoints(1_000) == SourceRow.touch - ShellSpace.snug)
        // Stated as the arithmetic rather than as 36, so a change to either token is caught here.
        #expect(SourceRow.touch - ShellSpace.snug == 36)
        for scaled in [CGFloat(16), 24, 36, 48, 96] {
            #expect(SourceRow.symbolPoints(scaled) <= SourceRow.touch, """
                A mark reached the edge of the line it sits in, so a row grew taller for it.
                """)
        }
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

        let withPicture = Self.drawn(published)
        let without = Self.drawn(unasked)
        #expect(withPicture.markName == without.markName, """
            The leading mark changed with what the server published, which is a picture tier \
            reintroduced above the protocol mark — and with it N requests to N servers on the \
            app's launch screen.
            """)
        #expect(withPicture.markName == "KindMastodon" || withPicture.markName == "KindMastodonSmall")
        #expect(withPicture.hasKindMark == without.hasKindMark)
        #expect(withPicture.markInk == without.markInk)
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

    // MARK: - The row as it is drawn

    private static let microRow = SourceRow(
        source: Source(host: micro, kind: .mastodon),
        profile: .unasked(host: micro, kind: .mastodon)
    )

    /// A row as the page draws it, with presses that go nowhere. What it asks before Clear and
    /// Remove is the page's to hand in, and any question does for a test that is not about it.
    static func drawn(_ row: SourceRow, actsLive: Bool = true) -> SourceRowView {
        SourceRowView(
            row: row, actsLive: actsLive, waiting: nil, refusal: nil,
            clearAsks: { ShellQuestion.clear(host: row.source.host, detailKey: "account.clear.detail") },
            removeAsks: { ShellQuestion.remove(host: row.source.host, boards: row.source.boards.count) },
            presses: SourceRow.Presses()
        )
    }

    /// **The label is the act and nothing else.** Why a dim one is dim is `ShellMark.spoken`'s to
    /// add after it, so a control's name is its own verb wherever it is offered — on the row or
    /// in its `…`.
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
                == "Sign out of \(Self.forum). It asks first."
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
    /// no glyph, plate or tint on the row's body to dim — so the S1 pattern is closed by making
    /// the colour unreachable rather than by remembering.
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
        #expect(Self.drawn(Self.microRow, actsLive: true).pressed == .live(nil))
        #expect(Self.drawn(Self.microRow, actsLive: false).pressed == .inert)
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
