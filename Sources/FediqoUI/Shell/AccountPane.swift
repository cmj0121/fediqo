import AuthenticationServices
import FediqoCore
import SwiftUI

/// The sources this device reads. Empty, it is the first thing anyone sees, so it says
/// what the app is for before it asks for anything. Joined, it gets out of the way.
///
/// **Two tabs once anything is joined (#235)**: the list of sources, and adding one — a list and
/// a form are two styles, and a page holds one (#231's fourth rule). Tab and ⇧Tab rotate them
/// (`ShellSession.rotateAccountTab`), as on Usage and Preferences. With nothing joined there is no
/// list to be a tab of, and the page is the hero and the field alone.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @FocusState private var searchFocused: Bool
    /// `JoinSheet`'s `headerFocused` doctrine applied to the page: without it a VoiceOver reader
    /// who pressed Return in the field is left with focus on a field while a screenful of new
    /// content has appeared below it.
    @AccessibilityFocusState private var previewFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// What Remove's question says of a source's posts — the reader's standing choice (#250).
    /// Optional, so a page hosted without the preferences still draws.
    @Environment(DummyPrefs.self) private var prefs: DummyPrefs?

    /// Whether a removed source's posts stay, as things stand when it is asked: once for
    /// Remove's question and again for its yes, so the line and the act agree.
    private var postsStay: () -> Bool {
        let prefs = prefs
        return { Self.postsStay(prefs?.removedPostsStay) }
    }

    /// The reader's choice, or — where the page was hosted without the preferences — **that the
    /// posts stay**. Not knowing falls on the side that takes less: a Remove that kept posts
    /// nobody asked to keep can be put right from Usage, and one that deleted them cannot.
    static func postsStay(_ chosen: Bool?) -> Bool {
        chosen ?? true
    }
    /// The system's sign-in sheet, which a Mastodon row's Sign in opens on the server's own page.
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    /// What this page is for, one tab each (#235).
    enum Purpose: String, CaseIterable, Identifiable, ShellTab {
        case sources
        case add

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .sources: "account.sources.title"
            case .add: "account.add.title"
            }
        }

        var symbol: String {
            switch self {
            case .sources: "square.stack.3d.up"
            case .add: "plus"
            }
        }
    }

    /// Whether the page is tabs: only where there is a list to be one of them.
    static func tabbed(sources: Int) -> Bool {
        sources > 0
    }

    private enum Metrics {
        /// The mark, at the size the mark is drawn rather than the size of an icon.
        static let mark: CGFloat = 72
        /// A field the width of a hostname. A pane is wider than anything typed into it.
        static let field: CGFloat = 520
        /// The promise is a sentence, not a row: it wraps where a sentence should.
        static let saying: CGFloat = 560
        static let fieldRadius = ShellRadius.field
        static let icon: CGFloat = 18
        /// The one orchestrated moment on this page, and it answers the reader's own press: it
        /// shows them what changed. There is no other motion here that a press did not ask for.
        static let scroll: TimeInterval = 0.2
    }

    /// **The whole page scrolls, not a list inside it.** `PreferencesPane` is a `Form` and every
    /// other pane here scrolls as one thing; this one briefly did the opposite — a fixed `VStack`
    /// with the rows in an inner `ScrollView` — and that puts the masthead, the field, Browse, the
    /// section title, its paragraph and the footnote all ahead of the list for height. At 320pt in
    /// Chinese at a large Dynamic Type size the list is squeezed to a sliver or to nothing, and
    /// there is nothing the reader can scroll to reach it. No test can see that, which is the
    /// reason it is written down here.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.room) {
                    // What the page stands under stays where it is: a swipe begins under it.
                    masthead.headOfPage()
                    page
                }
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            // A sideways swipe goes to the tab beside, where the page has tabs (#305).
            .modifier(SwipesTabs(
                slide: session.slide("account"), tabs: Self.tabbed(sources: session.sources.count) ? Array(Purpose.allCases) : [],
                selected: session.accountPurpose, select: { session.accountPurpose = $0 }
            ))
            // **The page takes the reader to the block, once, on its appearing.**
            //
            // **Gated on `nil → non-nil` and nothing else.** A reader coming back from the boards
            // sheet must find the page where they left it; a scroll fired on that transition is
            // the page throwing them somewhere they did not ask to go. `inlinePreview` stays
            // non-nil across that whole round trip, which is what makes the gate expressible.
            //
            // **Neither the scroll nor the focus is reachable from a test**, and this project has
            // no UI test target (risk 12). What a test can reach is the value both of them read —
            // `JoinStage.inlinePreview`, pinned four ways in `JoinStageTests`. Listed for a
            // running window in DESIGN-TAIL §6.5.
            .onChange(of: session.stage?.inlinePreview?.host) { old, new in
                guard old == nil, new != nil else { return }
                withAnimation(.easeOut(duration: Metrics.scroll)) {
                    proxy.scrollTo(Self.previewAnchor, anchor: .top)
                }
                previewFocused = true
            }
            .onChange(of: searchFocused) { _, on in
                session.searchFocused = on
            }
            .onChange(of: session.accountPurpose) { _, now in
                arrived(at: now)
            }
            .onDisappear { session.searchFocused = false }
            // **Reading first and the wider answer second**, which is `previewActions`' rule on
            // this page: the narrower act is never the one a reader reaches by reflex. Neither is
            // a loss; what each half buys is a sentence, behind the question's (?).
            .modifier(SignInChoiceQuestion(session: session) { ask, writing in
                Task { await chose(host: ask.host, writing: writing, noticesSaid: ask.notices) }
            })
            // The key pressed while signed in: the question, and only its yes signs out.
            .modifier(SignOutQuestion(session: session, signOut: signOutAnswered))
        }
    }

    /// Where the page scrolls to when a block appears. One anchor, on the block itself, so the
    /// header lands at the top rather than the reader guessing what moved.
    static let previewAnchor = "account.preview"

    /// The preview, drawn into the page as **the sheet's own frame unrolled**: hairline, header,
    /// hairline, evidence, hairline, actions. Nothing else on this page has that structure, so it
    /// reads as an inserted object rather than as a third permanent section — and it needs no
    /// plate, fill, border, radius or shadow to say so, which is what keeps `DESIGN.md` §0's ban
    /// on a card intact.
    ///
    /// **No hairline under the actions.** `sources`' own comment argues it from the other side: a
    /// rule under the last row is a list that looks cut off rather than finished. Where sources
    /// exist the page's own hairline closes the block; where they do not, the block simply ends.
    private func inlinePreview(_ preview: SourcePreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellRule()
            // **`.field` and not the stage's own origin, because the block is drawn for exactly
            // one of them.** `JoinStage.inlinePreview` answers non-nil only where the origin is
            // the field — including under the boards sheet, where the origin has not changed —
            // and that switch is exhaustive and pinned. Reading it back out of the stage here
            // would be a second derivation of a fact one function already decides.
            SourcePreviewView.Header(preview: preview, surface: .pane, origin: .field)
                .padding(.vertical, ShellSpace.pad)
                .accessibilityFocused($previewFocused)
            ShellRule()
            SourcePreviewView(preview: preview, surface: .pane, origin: .field)
            ShellRule()
            previewActions(preview)
                .padding(.vertical, ShellSpace.pad)
        }
    }

    /// Cancel and Subscribe, with no footer to hold them.
    ///
    /// **Leading-aligned, because this is the page and not a dialog footer** — `DESIGN.md` §0's
    /// fourth rule. **Cancel first and Subscribe second, which is the sheet's own order**: a
    /// reader who previews one server from Browse and the next from the field must not meet the
    /// two buttons the other way round. The emphasis is carried by `.defaultAction` and not by
    /// position, exactly as it is inside the sheet.
    ///
    /// **Disabled, and still drawn, while the boards sheet stands over the block** (§1.5(c)). Two
    /// live Subscribe buttons on two surfaces at once is the two-presenters failure in a new
    /// shape; removing the row instead of disabling it would change the block's height twice, once
    /// when the sheet opens and once when it closes.
    ///
    /// The gate itself is `actionsLive(at:)`, so the rule is a value rather than an expression
    /// inside a `View` body — the same argument that made `busy` internal, applied to the newer
    /// of the two rules.
    private func previewActions(_ preview: SourcePreview) -> some View {
        let warned = SourcePreviewView.warns(preview)
        return HStack(spacing: ShellSpace.step) {
            Button(L10n.t("board.choose.cancel")) { cancelPreview() }
            Button(L10n.t("board.choose.subscribe")) { Task { await subscribePreview() } }
                .disabled(session.checking)
                // Withdrawn in the one state the block has just warned about, on the same terms
                // as the sheet's footer and from the same function — so the two surfaces cannot
                // come to disagree about which press was warned about.
                .keyboardShortcut(warned ? .none : .defaultAction)
                .accessibilityHint(warned ? Text(L10n.t("join.preview.closed.hint")) : Text(""))
            // After Subscribe rather than replacing it, so the button does not move under a
            // finger mid-press.
            //
            // **The words are here now, where the press was.** This was a bare spinner with no
            // sentence at all while the page drew a sentence about the same errand 300pt above
            // it — two indicators for one press. `ProgressOwner` is what tells them apart, and
            // `blockWaiting` is this surface's half of the one answer.
            if let waiting = blockWaiting {
                ForumWaiting(line: waiting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!Self.actionsLive(at: session.stage))
    }

    /// Whether the block's own Cancel and Subscribe are the live ones.
    ///
    /// **They are live exactly while the preview *is* the stage.** Once Subscribe has opened the
    /// boards sheet over the block, the errand has moved into the sheet and two live Subscribe
    /// buttons on two surfaces at once is the two-presenters failure in a new shape.
    ///
    /// **A `static func` and not an expression in the body**, on the same grounds `busy` is
    /// internal: this is the rule that stops that happening, and a rule written inside a `View`
    /// body is reachable from nothing. `titleFont(for:)` and `inset(for:)` are already this shape.
    /// The block is drawn in exactly the cases `JoinStage.inlinePreview` answers, so this is asked
    /// only of those — and it is false for the boards stage among them, which is the whole point.
    static func actionsLive(at stage: JoinStage?) -> Bool {
        stage?.surface == .pane
    }

    @ViewBuilder
    private var masthead: some View {
        if session.sources.isEmpty { hero } else { standing }
    }

    /// **No tabs and no list where nothing is joined** — not a hairline, not a header, not an
    /// empty state. The hero already says what the app is for and names the next act; a second
    /// invitation would argue with the mascot.
    @ViewBuilder
    private var page: some View {
        if Self.tabbed(sources: session.sources.count) {
            ShellTabs(Purpose.allCases, selected: session.accountPurpose) {
                session.accountPurpose = $0
            }
            // The tabs' head leans with the page's own slide, and its list is the page's (#305).
            .environment(\.shellTabsSlide, session.slide("account"))
            .modifier(ProbedPane(part: .head))
            // What is under the tabs follows a sideways swipe; the tabs stay (#305).
            Group {
                switch session.accountPurpose {
                case .sources: sources
                case .add: addPage
                }
            }
            .modifier(ProbedPane(part: .under))
            .modifier(Slid(slide: session.slide("account")))
        } else {
            addPage
        }
    }

    /// The page moved to a tab, by a press or by Tab. **Arriving on Add puts the keyboard in the
    /// field**, which is the one thing that tab is for; leaving it takes the keyboard out, so the
    /// shell's keys are not held off by a field no longer on screen.
    ///
    /// Asked after the tab's views are in the page, since a field is focused only once it is there.
    func arrived(at purpose: Purpose) {
        guard purpose == .add else {
            searchFocused = false
            session.searchFocused = false
            return
        }
        Task { @MainActor in searchFocused = true }
    }

    /// Adding a source: the field and Browse, what the last look said, and the preview of a
    /// hostname the reader typed — previewed where they typed it. From the directory it stays in
    /// the sheet the directory is in, which is `inlinePreview`'s answer rather than this view's.
    private var addPage: some View {
        VStack(alignment: .leading, spacing: ShellSpace.room) {
            adding
            if let preview = session.stage?.inlinePreview {
                inlinePreview(preview)
                    .id(Self.previewAnchor)
            }
        }
    }

    /// Nothing has been joined yet. The octopus and the promise — and then the one control that
    /// does anything about it, whose own heading says what to do (#244).
    private var hero: some View {
        HStack(alignment: .top, spacing: ShellSpace.pad) {
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.mark, height: Metrics.mark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(L10n.t("account.hero.promise"))
                    .shellFont(.display)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Metrics.saying, alignment: .leading)
        }
    }

    /// Something is joined. The page says which, and stops selling itself.
    ///
    /// **The glance under the title is drawn only at two or more sources**, which is
    /// `SourceMarkRow.drawn(sources:)`'s rule and not this body's. At one source the pane title
    /// already says everything the glance would, and the cap disposes of the plural problem
    /// outright: this repo ships no `.stringsdict`, and "1 sources" is the one bad case, which now
    /// cannot occur.
    private var standing: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("shell.account.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            if let glance { SourceMarkRow(marks: glance) }
        }
    }

    /// What the glance is drawn from, or nothing where it is not drawn at all.
    ///
    /// **Internal, and a value rather than a view, so the wiring is pinned and not only the
    /// rules.** `drawn(sources:)`, `countKey`, `count` and `mark` were each named and driven while
    /// nothing proved this body called any of them: not that the gate is asked with the *source
    /// count*, not that the marks come from `session.rows` rather than from a second derivation.
    /// That is the shape of all four defects risk 12 counts, and the row was given exactly this
    /// treatment on purpose.
    ///
    /// **`session.rows` and not `session.sources`**, so the shape is derived once on this page:
    /// `SourceRow` says of itself that it comes "through `DummyItem.shape(of:)` and nowhere else",
    /// and the glance sitting three lines above the list must not be a second caller.
    var glance: [SourceMarkRow.Mark]? {
        guard SourceMarkRow.drawn(sources: session.sources.count) else { return nil }
        return session.rows.map {
            Self.mark($0, signedIn: session.isSignedIn(host: $0.source.host))
        }
    }

    private var adding: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            // The field's own heading, with what it is for and the rest behind its (?) (#244):
            // before any source, the first thing to do; after, how to add another.
            let keys = Self.addingKeys(tabbed: Self.tabbed(sources: session.sources.count))
            ShellSectionHead(title: "account.add.title", line: keys.line, help: keys.help)
            fieldRow
            if statusVisible { status }
        }
    }

    /// What the adding field's heading says: the first thing to do on a page with no source yet,
    /// and how to add another on the tab beside the list.
    static func addingKeys(tabbed: Bool) -> (line: String, help: String) {
        tabbed ? ("account.add.line", "account.add.detail") : ("account.hero.line", "account.hero.detail")
    }

    /// The field, and the way in for a reader who does not have a hostname to type.
    ///
    /// **`layoutPriority` on the field**, so a narrow page shortens the field and never Browse,
    /// which is one glyph that names itself (#235).
    private var fieldRow: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            searchField
                .layoutPriority(1)
            ShellIconButton("books.vertical", name: "account.browse.label") { browse() }
                .disabled(busy)
        }
    }

    /// Whether the top half is out of the reader's hands: something on the wire, or a stage the
    /// reader cannot see past.
    ///
    /// **A sheet counts, which is PLAN risk 8.** `checking` is false the whole time a preview is
    /// on screen, so a gate asking only about it would leave the field and both buttons live
    /// behind an open sheet — and a second look would overwrite the stage under a reader who is
    /// reading the first one.
    ///
    /// **An inline preview does not, and that is the correction.** This term was answering two
    /// questions at once: *is something on the wire* and *is the reader looking at something
    /// else*. A block drawn in the page is neither over the field nor instead of it — it is
    /// beside it — so disabling the field under it would grey out a control for no reason the
    /// reader can see. What stops a second look from being nonsense is
    /// `JoinStage.admitsASecondLook`, at the session, where the press lands.
    ///
    /// **Internal rather than private so a test can read it**, on the same grounds as `mark(_:)`
    /// below: this term decides whether three controls are grey, it has just been narrowed, and
    /// a view's private property is reachable from nothing. The four defects risk 12 lists were
    /// all correct rules attached where no test could see them.
    ///
    /// **It now negates the press's own rule rather than restating it.** This read
    /// `session.checking || session.stage?.surface == .sheet` — a second exhaustive switch over
    /// the same five shapes, agreeing with `look()`'s guard by coincidence and held by no test.
    /// `ShellSession.pageActsLive` is the one rule both ends ask, so a stage that changes its
    /// answer changes it for the ink and the press together.
    var busy: Bool {
        !ShellSession.pageActsLive(at: session.stage, checking: session.checking)
    }

    /// The magnifier's ink, and **the whole of what `.disabled` is visible as on this control**.
    ///
    /// `.buttonStyle(.plain)` supplies no dimming of its own and an explicit `.foregroundStyle`
    /// overrides the one `.disabled` would supply — so this button was refused behind a sheet and
    /// looked exactly as pressable as before. **The fourth instance of that defect on this
    /// branch**, and the one on the page whose other controls had just been fixed: the row's
    /// glyphs took a look that carries their ink, `ShellChrome.well` left this pane with the
    /// boards plate, and this control went on saying press-me.
    ///
    /// **Internal rather than private so a test can read it**, on the same grounds as `busy` and
    /// `pageWaiting`: a style decided inside a `View` body is reachable from nothing, which is
    /// precisely how the first three instances survived a green suite.
    var searchInk: Color {
        busy ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme)
    }

    private var searchField: some View {
        ShellHostField(
            L10n.t("account.search.placeholder"), text: $session.hostname, focus: $searchFocused,
            onSubmit: { Task { await typedHost() } }
        ) {
            Button {
                Task { await typedHost() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .shellFont(.body, weight: .semibold)
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .foregroundStyle(searchInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("account.search"))
            .help(L10n.t("account.search"))
        }
        .disabled(busy)
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .frame(maxWidth: Metrics.field, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
        }
    }

    /// Whether the pane has anything to say under the field.
    ///
    /// **A partial pick is one of the things it has to say.** A pick where some boards read and
    /// some did not sets no `refuse` — it was not a failed join, the source is in the list and
    /// its tabs are in the rail — so a gate asking only about `checking` and `refuse` would build
    /// the sentence naming the boards that failed and then never draw it. That is the exact shape
    /// this branch keeps writing down: the answer exists and nobody is asked for it.
    private var statusVisible: Bool {
        pageWaiting != nil || session.refuse != nil || !session.unread.isEmpty
    }

    /// The sentence under the field while the **page** is the one waiting, or nothing.
    ///
    /// **Through `ShellSession.reporting(_:drawnAs:)` and never through `checking` alone.** A
    /// restate is
    /// pressed inside a row and draws its own status line there; a gate asking only whether
    /// something is on the wire drew both, so one press produced two spinners and two sentences —
    /// and the one under the field said "Checking …", the detection vocabulary, about the one
    /// errand whose whole justification is that it detects nothing.
    ///
    /// **The key comes with the owner rather than being written here**, which is the other half
    /// of that fix: the page reports both a look and the boards a reader picked, and those are
    /// two errands in two sentences. See `ProgressReport.key`.
    ///
    /// **Internal rather than private so a test can read it**, on the same grounds as `busy`: this
    /// term decides whether a sentence appears and which one, and a view's private property is
    /// reachable from nothing.
    var pageWaiting: String? {
        waiting(.page)
    }

    /// The same sentence, where the **block's** own Subscribe is what is waiting.
    ///
    /// Internal for `pageWaiting`'s reason. The two cannot both answer and cannot both stay
    /// silent: they are two readings of one value through one rule.
    var blockWaiting: String? {
        waiting(.block)
    }

    /// The sentence this surface draws, or nothing where the errand is somebody else's.
    ///
    /// **Through `ShellSession.reporting` and not through `progress.owner` directly**, because the
    /// block can be dismissed out from under its own errand — its Cancel stays live while its
    /// Subscribe is on the wire — and a sentence owned by a surface that has gone is a reader
    /// waiting with every control grey and nothing on screen saying why. The page takes it back.
    private func waiting(_ owner: ProgressOwner) -> String? {
        guard ShellSession.reporting(session.progress, drawnAs: session.stage) == owner,
              let key = session.progress?.key
        else { return nil }
        return String(format: L10n.t(key), session.progressHost)
    }

    @ViewBuilder
    private var status: some View {
        if let waiting = pageWaiting {
            ForumWaiting(line: waiting)
        } else if let refuse = session.refuse {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(refuse)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                // Where *every* board failed there is no list to draw — Core threw the first
                // board's reason and kept none — so what can still be said is how much the
                // sentence above is about.
                if session.unreadAll > 0 {
                    Text(String(format: L10n.t("board.unread.all"), session.unreadAll))
                        .shellFont(.mark)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                offer
            }
        } else if !session.unread.isEmpty {
            unreadReport
        }
    }

    /// Boards the reader picked that could not be read.
    ///
    /// **A partial pick is not a silence.** They chose these off a list this app drew for them,
    /// and some of them did not answer — `install-a.example` board 37 has 114,662 threads and serves
    /// them as picture cards with no date on any, so it fails and is not subscribed to. Leaving
    /// it out of the rail with no sentence would leave the reader counting tabs to work out which
    /// of their choices went missing, and guessing why.
    ///
    /// Drawn where the refusal is drawn, because the reader pressed Add here and this is the rest
    /// of that answer. Not in alarm: the boards that worked did work, and this is the footnote to
    /// a success rather than a failure of its own.
    @ViewBuilder
    private var unreadReport: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("board.unread.some"), session.unread.count))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(session.unread, id: \.board.fid) { entry in
                Text(ShellSession.unreadMessage(entry))
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one thing a reader can do about a server that turned this app away.
    ///
    /// This branch recorded the hole and left it open — the refusal message "tells the reader
    /// what happened and offers them nothing to do about it". A reader with an account on that
    /// forum *is* somebody it can be opened for, and the honest route is the one the forum's
    /// owner controls: their own sign-in page, in a real browser engine, with them typing into
    /// it. Offered only after a refusal, never beside a typo.
    @ViewBuilder
    private var offer: some View {
        if let host = session.offerSignIn {
            ShellLinkButton(String(format: L10n.t("account.refuse.signin"), host)) {
                Task { await offeredSignIn(host) }
            }
            .accessibilityLabel(Text(String(format: L10n.t("account.refuse.signin.label"), host)))
        }
    }

    /// The sources this device reads, one row each.
    ///
    /// **This list and `UsagePane`'s answer different questions and are kept visibly apart.**
    /// This one is *what am I reading* — a mark, a hostname, its sign-in, and `…`. That
    /// one is *what is this device holding* — an inventory, every line of it with a byte count or a
    /// date. So **no byte figure and no date appears on a row here, ever**, and the footnote below
    /// names the other list and its job rather than repeating it. Clear is in both, which is one
    /// act reached from two questions and not a duplicate; Remove is only here, because removing is
    /// about what you read and not about what is held.
    ///
    /// **What a row used to say about one server is now behind its press** — decision 34 with
    /// decision 31. Protocol, shape, figures, evidence and the whole board list are drawn by
    /// `SourcePreviewView` under `PreviewOrigin.joined`, and this unit adds no drawing there. Two
    /// facts that are about **the list** rather than about any one server stay on the page in
    /// words behind the list's (?): that a row opens, and what the marks mean. A per-server fact cannot go in a header — a section header cannot say
    /// "mastodon.social has 1.2M active people" — which is the line that decides what moved where.
    ///
    /// **Named cost, for the record:** a server's size was readable while scanning six rows and is
    /// now one press per server, with no way to compare two without two presses. That is the
    /// largest single loss and it is not recoverable inside decision 34.
    private var sources: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            // The list's heading (#244): one short line, and behind its (?) which question this
            // list answers, what Remove costs, what the marks on a row mean, and where what a
            // source left is counted — the lines that stood under the list.
            ShellSectionHead(
                L10n.t("account.sources.title"), line: L10n.t("account.sources.line"), help: Self.sourcesHelp()
            )
            // **A plain stack, because the page is the thing that scrolls.** A `ScrollView` here
            // would be the inner one the page comment above is about.
            // Row-independent — `stage == nil && !checking` names no host — so it is asked once
            // for the list rather than once per row.
            let actsLive = ShellSession.rowActsLive(at: session.stage, checking: session.checking)
            // **Read once for the list, beside `actsLive` and for its reason.** `session.rows` is
            // a computed property that allocates a fresh `[SourceRow]`.
            let rows = session.rows
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SourceRowView(
                        row: row,
                        actsLive: actsLive,
                        // **The comparison is a named function and the fold went with it.**
                        // `ProgressOwner.row` carries the host already folded by whoever set it.
                        waiting: SourceRow.waitingLine(
                            session.progress, drawnAs: session.stage, host: row.source.host
                        ),
                        refusal: session.rowRefusal,
                        notice: session.forums.notice(host: row.source.host)?.sentence(),
                        clearAsks: { session.clearQuestion(host: row.source.host) },
                        removeAsks: { session.removeQuestion(host: row.source.host, postsStay: postsStay()) },
                        presses: presses(row, postsStay: postsStay)
                    )
                    // **Between rows and not after every one.** A rule under the last row is a
                    // list that looks cut off rather than finished.
                    if row.id != rows.last?.id { ShellRule() }
                }
            }
        }
    }

    /// What the sources list's (?) says: which question the list answers and what Remove costs,
    /// what the key and `…` on a row are, what the lock and its word beside them mean, and where
    /// what each source left is counted — four keys, one bubble.
    static func sourcesHelp(language: DummyLanguage? = nil) -> String {
        [
            "account.sources.detail", "account.sources.marks", "account.sources.writing", "account.sources.held",
        ]
        .map { L10n.t($0, language: language) }
        .joined(separator: "\n\n")
    }

    /// Every press of one row, each a named method of this page and nothing else — so a row's
    /// closures do nothing but call one. `postsStay` is read when Remove's yes is pressed.
    func presses(_ row: SourceRow, postsStay: @escaping () -> Bool = { AccountPane.postsStay(nil) }) -> SourceRow.Presses {
        SourceRow.Presses(
            signIn: { Task { await press(row) } },
            askAgain: { askAgain(row) },
            changeBoards: { Task { await changeBoards(row) } },
            chooseLists: { Task { await changeLists(row) } },
            clear: { Task { await clear(row) } },
            remove: { Task { await remove(row, keepingPosts: postsStay()) } },
            open: { openSource(row) }
        )
    }

    // MARK: - What every control on this page actually does
    //
    // **One named method per interactive element, and no logic in any closure.** This page shipped
    // a search field whose button called `ShellSession.search()`, which trimmed the text and
    // cleared the error and *never looked anything up* — with the Add button gone into the sheet,
    // there was no way left to add a source by typing its hostname, and 436 UI tests were green
    // because every one of them called `session.add()` directly. That is the third time on this
    // branch that a rule was pinned at the session while the thing that calls it was reachable
    // from nothing. So each control below is a method a test can call, and the closures in the
    // body do nothing but call one.

    /// The reader typed a hostname and asked for it — the field's Return, and the magnifier.
    ///
    /// **Both look, and it is the same act.** A reader who has typed `mastodon.social` and pressed
    /// Return has asked for that server; a magnifying glass beside a field is the same request
    /// made with the mouse. Neither is a catalogue filter any more — the directory's filter lives
    /// in the sheet, next to the list it filters — so a control here that only tidied the text was
    /// a control pretending to be one.
    ///
    /// Nothing is added by this. `add()` looks and opens the preview, and the reader still has to
    /// press Subscribe; every guard that press has — the duplicate check, the parse, the sheet
    /// already being up — is `look`'s and applies unchanged.
    ///
    /// **It is also what the browser's own rows reach**, through `pick(_:)` — decision 38. A
    /// chosen server fills this field and runs this errand, so there is one way in and not two
    /// that have to agree.
    func typedHost() async {
        await session.add()
    }

    /// Browse pressed. **It opens the protocols this app can read and contacts nobody** —
    /// decisions 19 and 38. The directory is fetched a press later, when a protocol that has one
    /// is chosen, which is decision 10's argument carried one step further.
    func browse() {
        session.browse()
    }

    /// The inline preview's Cancel. **Through `dismissStage` and not by clearing the stage**, so
    /// the pictures a preview pulled for a host that was never joined are still forgotten. A block
    /// in the page has no swipe and no Escape; this is its only way out.
    func cancelPreview() {
        session.dismissStage()
    }

    /// The inline preview's Subscribe — the same press as the sheet's, and the same method.
    func subscribePreview() async {
        await session.confirm()
    }

    /// The sign-in a refusal offered, taken.
    func offeredSignIn(_ host: String) async {
        await session.signIn(host: host)
    }

    /// A row's sign-in toggle, either way round.
    ///
    /// **Which way it goes is `reachedSignIn`'s answer and not this view's** — see its doc comment
    /// for why "signed in" here can only ever mean as far as this device last saw.
    ///
    /// **A sign-in that could carry writing asks first** (#69). The question is the reader's to
    /// answer before the server's page opens, so nothing is asked of the server and nothing is
    /// opened until they have; a protocol this app cannot write on has no question to put and goes
    /// straight through.
    ///
    /// **Signing out asks first too, whatever the protocol.** A sign-out hands a Mastodon's token
    /// back to its server and drops a forum's session with its saved password, so a press on a
    /// signed-in key only puts the question (`ShellSession.signOutAsk`); `signOut(_:)` is its yes.
    func press(_ row: SourceRow) async {
        if session.isSignedIn(host: row.source.host) {
            session.askSignOut(host: row.source.host)
        } else if row.asksWriting {
            session.signInChoice = row.source.host
        } else {
            await session.signIn(
                host: row.source.host, through: WebAuthBrowser(session: webAuthenticationSession)
            )
        }
    }

    /// The yes to the sign-out question: `signOut(_:)`, started from a press.
    func signOutAnswered(_ host: String) {
        Task { await signOut(host) }
    }

    /// The yes to the sign-out question: the one way a press on this page signs anybody out.
    func signOut(_ host: String) async {
        session.signOutAsk = nil
        await session.signOut(host: host)
    }

    /// The writing question, put to a reader who is **already signed in** (#69), and nobody is
    /// signed out to put it. Reached from the row's permission control (`askAgain`).
    ///
    /// The dialog and `MastodonSessions.signIn` both cope with a host that already holds a token —
    /// the new token replaces it here and the one it supersedes is revoked at the server — so a
    /// reader who cancels on the server's page still has the sign-in they had before they asked.
    ///
    /// **The row's own toggle is untouched**: it is two-state and stays two-state. This is the
    /// second surface for the question and not a third behaviour on the first.
    ///
    /// **Asked from the row and not in an alert, for as long as it is owed.** Widening what
    /// somebody already agreed to is not done quietly: the control stands on the row of the
    /// source it is about until the reader answers.
    func askWriting(_ host: String) {
        session.signInChoice = host
    }

    /// The permission control's press: the question this row's sign-in is owed, and **nobody is
    /// signed out to put it** — `askWriting`'s argument, which is why this is not the key's own
    /// press: on a signed-in row the key asks to sign out, and a sign-out revokes the token.
    ///
    /// A sign-in that only lacks bookmarks is asked for those, the one question a post's row
    /// puts; a write turned away, or a sign-in made before writing was asked for, is asked what
    /// it may do. Nothing where the row owes nothing.
    func askAgain(_ row: SourceRow) {
        let host = row.source.host
        switch row.owed {
        case .nothing: return
        case .refused: askWriting(host)
        case .asking:
            if session.mastodon.bookmarks(host: host) == .unasked {
                askBookmarks(host)
            } else {
                askWriting(host)
            }
        }
    }

    /// The bookmark question about `host` (#285), reached from the row's permission control:
    /// the one a post's row puts, and nobody is signed out to put it. Nothing where that sign-in is no
    /// longer one to ask.
    func askBookmarks(_ host: String) {
        guard session.mastodon.bookmarks(host: host) == .unasked else { return }
        session.bookmarkAsk = host.lowercased()
    }

    /// The reader answered the scope question: sign in on the server's page, asking for what they
    /// agreed to and no more.
    ///
    /// **The one seam of this choice a test cannot reach** (risk 12), and it is the seam the
    /// sign-in branch of `press(_:)` already had: a `WebAuthBrowser` built here would open a real
    /// sheet. What a test drives is `press(_:)` raising the question and
    /// `ShellSession.signIn(host:through:writing:)` answering it with a page fixture; what nothing
    /// verifies is that this method hands the reader's own answer to that call. Named here rather
    /// than left to be discovered.
    ///
    /// `noticesSaid` is what the question said of notices, handed over with its answer.
    func chose(host: String, writing: Bool, noticesSaid: Bool? = nil) async {
        session.putDownSignInChoice()
        await session.signIn(
            host: host, through: WebAuthBrowser(session: webAuthenticationSession),
            writing: writing, noticesSaid: noticesSaid
        )
    }

    /// The yes to a row's Clear (decision 29: the press itself only asks, and the row's `…` is
    /// what asks). **`ShellSession.clear(host:)` and nothing beside it** — the one call the yes
    /// to Usage's Clear makes too, so one act is one function whichever page it was asked on.
    func clear(_ row: SourceRow) async {
        await session.clear(host: row.source.host)
    }

    /// A row's boards control. **Changes nothing by itself** — it reads the forum's index and
    /// opens the picker pre-ticked; the reader still has to press Subscribe, and Cancel loses
    /// nothing.
    func changeBoards(_ row: SourceRow) async {
        await session.changeBoards(host: row.source.host)
    }

    /// A signed-in Mastodon row's lists control. **Changes nothing by itself** — it reads the
    /// account's lists and opens the picker pre-ticked; Cancel loses nothing.
    func changeLists(_ row: SourceRow) async {
        await session.changeLists(host: row.source.host)
    }

    /// The yes to a row's Remove, which the row's `…` asks first. **`ShellSession.remove(host:
    /// keepingPosts:)` and nothing beside it**, with the reader's standing choice about its
    /// posts (#250) as it stands at the yes.
    func remove(_ row: SourceRow, keepingPosts: Bool) async {
        await session.remove(host: row.source.host, keepingPosts: keepingPosts)
    }

    /// The row's own press — decision 31. **Asks nobody anything**: the profile is already in
    /// `ShellSession.profiles`, and `openSource(host:)` is the only route in, because `look()`
    /// refuses a host that is already a source by design.
    func openSource(_ row: SourceRow) {
        session.openSource(host: row.source.host)
    }

    /// The mark a joined source is drawn with in the masthead glance. Internal rather than private
    /// only so that `AccountTests` can pin it: the globe it used to draw over every forum was
    /// invisible to the suite, because a view's private helper is reachable from nothing.
    ///
    /// **`signedIn` is an argument now, and that is what kills a dead branch.** This used to build
    /// a `DummySource.unsigned(_:kind:)`, so the mark's signed-in variant was unreachable from
    /// this page — a mark that could never fill, standing over a row whose sign-in control does.
    /// The fact travels with the value instead.
    ///
    /// **`kind` travels beside `shape` so the glance draws the same picture the row does.** The
    /// glance asked only for the shape, so a Discuz! was `text.bubble` here and its own mark three
    /// lines below — one server with two pictures on one screen. Both halves are taken from the
    /// same `SourceRow`, so they cannot be handed in disagreeing.
    ///
    /// **A `SourceRow` and not a `Source`, so the shape is derived once on this page.** `SourceRow`
    /// says of itself that the shape comes "through `DummyItem.shape(of:)` and nowhere else … so
    /// that no caller can hand a source one shape while the timeline draws it as another" — and a
    /// second call to `shape(of:)` here was a second caller, three lines above the list it would
    /// disagree with. The glance now reads exactly what the row beneath it reads.
    static func mark(_ row: SourceRow, signedIn: Bool) -> SourceMarkRow.Mark {
        SourceMarkRow.Mark(
            id: row.source.host, kind: row.source.kind, shape: row.shape, signedIn: signedIn
        )
    }
}

/// Signing out, asked of a source whose key was pressed while signed in — a modifier, for
/// `SignInChoiceQuestion`'s reason. **The question is the one read at the press and held with
/// its host** (`SignOutAsk`), not read again while the card is up: a yes on a forum deletes its
/// saved password, and a card re-read as it slid away would turn from the one that said so into
/// the one that does not. Putting it down any other way than its yes signs nobody out.
private struct SignOutQuestion: ViewModifier {
    let session: ShellSession
    let signOut: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: \.question) { ask, _ in
            signOut(ask.host)
        }
        // The question is drawn nowhere but on this page: leaving puts it down, so it cannot
        // come back on a later visit asking about a sign-in as it stood then.
        .onDisappear { session.dropSignOutAsk() }
    }

    private var asked: Binding<SignOutAsk?> {
        Binding(get: { session.signOutAsk }, set: { if $0 == nil { session.signOutAsk = nil } })
    }
}

/// Reading, or reading and writing, asked of a source being signed in to — a modifier, so the
/// page's chain gains one plain call and no presenter closure of its own.
private struct SignInChoiceQuestion: ViewModifier {
    let session: ShellSession
    let chose: @MainActor (SignInAsked, Bool) -> Void

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: question) { ask, id in
            chose(ask, id == ShellQuestion.signInWrite)
        }
    }

    private func question(_ ask: SignInAsked) -> ShellConfirmation {
        session.signInQuestion(host: ask.host)
    }

    private var asked: Binding<SignInAsked?> {
        Binding(get: { session.signInChoice.map(session.signInAsked) }, set: { if $0 == nil { session.putDownSignInChoice() } })
    }
}
