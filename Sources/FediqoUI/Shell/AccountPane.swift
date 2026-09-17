import FediqoCore
import SwiftUI

/// The sources this device reads. Empty, it is the first thing anyone sees, so it says
/// what the app is for before it asks for anything. Joined, it gets out of the way.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @FocusState private var searchFocused: Bool
    /// `JoinSheet`'s `headerFocused` doctrine applied to the page: without it a VoiceOver reader
    /// who pressed Return in the field is left with focus on a field while a screenful of new
    /// content has appeared below it.
    @AccessibilityFocusState private var previewFocused: Bool
    /// What the source list measured itself to be. **Zero until the first measurement lands**, and
    /// `SourceRow.regime(width:threshold:)` reads that zero as "not measured yet" rather than as a
    /// narrow row.
    @State private var rowWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        /// The mark, at the size the mark is drawn rather than the size of an icon.
        static let mark: CGFloat = 72
        /// A field the width of a hostname. A pane is wider than anything typed into it.
        static let field: CGFloat = 520
        /// The promise is a sentence, not a row: it wraps where a sentence should.
        static let saying: CGFloat = 560
        static let fieldRadius: CGFloat = 6
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
                masthead
                adding
                // A hostname the reader typed, previewed where they typed it. From the directory
                // it stays in the sheet the directory is in, which is `inlinePreview`'s answer
                // rather than this view's.
                if let preview = session.stage?.inlinePreview {
                    inlinePreview(preview)
                        .id(Self.previewAnchor)
                }
                // **Nothing at all where nothing is joined** — not a hairline, not a header,
                // not an empty state. The hero above already says what the app is for and names
                // the next act, and Browse is beside the field; a second invitation under a rule
                // would be two of them on one screen, with the mascot arguing against the other.
                // `PreferencesPane` draws its empty state and is right to, because it has no
                // hero to be contradicted by.
                if !session.sources.isEmpty {
                    hairline
                    sources
                }
                }
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .onDisappear { session.searchFocused = false }
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
            hairline
            // **`.field` and not the stage's own origin, because the block is drawn for exactly
            // one of them.** `JoinStage.inlinePreview` answers non-nil only where the origin is
            // the field — including under the boards sheet, where the origin has not changed —
            // and that switch is exhaustive and pinned. Reading it back out of the stage here
            // would be a second derivation of a fact one function already decides.
            SourcePreviewView.Header(preview: preview, surface: .pane, origin: .field)
                .padding(.vertical, ShellSpace.pad)
                .accessibilityFocused($previewFocused)
            hairline
            SourcePreviewView(preview: preview, surface: .pane, origin: .field)
            hairline
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

    /// Nothing has been joined yet. The octopus, the promise, and what it costs — and
    /// then the one control that does anything about it.
    private var hero: some View {
        HStack(alignment: .top, spacing: ShellSpace.pad) {
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.mark, height: Metrics.mark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(L10n.t("account.hero.promise"))
                    .font(ShellType.display)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("account.hero.detail"))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
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
                .font(ShellType.pane)
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
            Self.mark($0, signedIn: session.forums.reachedSignIn(host: $0.source.host))
        }
    }

    private var adding: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if !session.sources.isEmpty {
                Text(L10n.t("account.add.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            fieldRow
            if statusVisible { status }
        }
    }

    /// The field, and the way in for a reader who does not have a hostname to type.
    ///
    /// **`layoutPriority` on the field, and the button allowed to wrap.** At 320pt with a long
    /// translation the right failure is a Browse that takes two lines, not a field that collapses.
    private var fieldRow: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            searchField
                .layoutPriority(1)
            Button(L10n.t("account.browse")) { browse() }
                .font(ShellType.body)
                .disabled(busy)
                .help(L10n.t("account.browse.label"))
                .accessibilityLabel(L10n.t("account.browse.label"))
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
    var busy: Bool {
        session.checking || session.stage?.surface == .sheet
    }

    /// The magnifier's ink, and **the whole of what `.disabled` is visible as on this control**.
    ///
    /// `.buttonStyle(.plain)` supplies no dimming of its own and an explicit `.foregroundStyle`
    /// overrides the one `.disabled` would supply — so this button was refused behind a sheet and
    /// looked exactly as pressable as before. **The fourth instance of that defect on this
    /// branch**, and the one on the page whose other controls this unit had just fixed: the row's
    /// four glyphs went through `RowActionState`, `ShellChrome.well` left this pane with the
    /// boards plate, and this control went on saying press-me.
    ///
    /// **Internal rather than private so a test can read it**, on the same grounds as `busy` and
    /// `pageWaiting`: a style decided inside a `View` body is reachable from nothing, which is
    /// precisely how the first three instances survived a green suite.
    var searchInk: Color {
        busy ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme)
    }

    private var searchField: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField(L10n.t("account.search.placeholder"), text: $session.hostname)
                .font(ShellType.body)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(busy)
                .onSubmit { Task { await typedHost() } }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.t("account.search.placeholder"))
            Button {
                Task { await typedHost() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(ShellType.body.weight(.semibold))
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .foregroundStyle(searchInk)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(L10n.t("account.search"))
            .help(L10n.t("account.search"))
        }
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
    /// **Through `ShellSession.pageProgress` and never through `checking` alone.** A restate is
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
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                // Where *every* board failed there is no list to draw — Core threw the first
                // board's reason and kept none — so what can still be said is how much the
                // sentence above is about.
                if session.unreadAll > 0 {
                    Text(String(format: L10n.t("board.unread.all"), session.unreadAll))
                        .font(ShellType.mark)
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
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(session.unread, id: \.board.fid) { entry in
                Text(ShellSession.unreadMessage(entry))
                    .font(ShellType.mark)
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
            Button(String(format: L10n.t("account.refuse.signin"), host)) {
                Task { await offeredSignIn(host) }
            }
            .font(ShellType.meta)
            .accessibilityLabel(Text(String(format: L10n.t("account.refuse.signin.label"), host)))
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }

    /// The sources this device reads, one row each.
    ///
    /// **This list and `PreferencesPane`'s answer different questions and are kept visibly apart.**
    /// This one is *what am I reading* — a mark, a hostname, and what can be done about it. That
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
    /// words: the header paragraph says that a row opens, and the footer legend says what the
    /// marks mean. A per-server fact cannot go in a header — a section header cannot say
    /// "mastodon.social has 1.2M active people" — which is the line that decides what moved where.
    ///
    /// **Named cost, for the record:** a server's size was readable while scanning six rows and is
    /// now one press per server, with no way to compare two without two presses. That is the
    /// largest single loss and it is not recoverable inside decision 34.
    private var sources: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            // `name` and not `pane`: `pane` is documented as a page's own title, one per page, and
            // this page's is "Account".
            Text(L10n.t("account.sources.title"))
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            // The sentence that says which question this list answers and what Remove costs,
            // before the reader meets a Remove button.
            Text(L10n.t("account.sources.detail"))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            // **A plain stack, because the page is the thing that scrolls.** A `ScrollView` here
            // would be the inner one the page comment above is about.
            // Row-independent — `stage == nil && !checking` names no host — so it is asked once
            // for the list rather than once per row.
            let actsLive = ShellSession.rowActsLive(at: session.stage, checking: session.checking)
            // **Read once for the list, beside `actsLive` and for its reason.** `session.rows` is
            // a computed property that allocates a fresh `[SourceRow]`, and `widest` folds the
            // whole of it — so referenced from inside the `ForEach` they are O(n²) on the app's
            // launch screen, and the sentence below would have read as though it were true while
            // being false.
            let rows = session.rows
            // **The property, not a second call to the same function.** They agreed by being the
            // same expression, so changing the body alone would have left
            // `thePaneHandsOneWidestToEveryRow` green while every row was drawn to a threshold
            // nothing had pinned — the risk-12 shape with the test on the wrong side of it.
            let widest = widest
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SourceRowView(
                        row: row,
                        signedIn: session.forums.reachedSignIn(host: row.source.host),
                        width: rowWidth,
                        // **Handed down, never derived per row.** Decision 33 made the control
                        // count per-protocol, so the widest row is a property of the list; a row
                        // asking `controls(of:)` about itself would give a Mastodon one threshold
                        // and the Discuz! beside it another, and a list where one row is trailing
                        // and the row above it is beneath at the same width reads as broken.
                        // Risk 14's generalised fix: the caller states the answer, the callee
                        // never looks around for it.
                        widest: widest,
                        actsLive: actsLive,
                        // **The comparison moved to a named function and the fold went with
                        // it.** It used to be written here, folding case on both sides against a
                        // guarantee three files away that nothing at this site stated — the shape
                        // `ShellSession.remove` names as how a bug class reaches fourteen places.
                        // `ProgressOwner.row` carries the host already folded by whoever set it.
                        waiting: SourceRow.waitingLine(
                            session.progress, drawnAs: session.stage, host: row.source.host
                        ),
                        refusal: session.boardsRefusal,
                        signIn: { Task { await press(row) } },
                        clear: { askClear(row) },
                        remove: { askRemove(row) },
                        changeBoards: { Task { await changeBoards(row) } },
                        open: { openSource(row) }
                    )
                    // **Between rows and not after every one.** A rule under the last row is a
                    // list that looks cut off rather than finished, with the footnote below it
                    // hanging off the end of a table.
                    if row.id != rows.last?.id { hairline }
                }
            }
            // **One reader for the whole list, not one per row.** Every row in it is the same
            // width, and `SourceRow.regime` is a function of that width and of the list's own
            // widest control set, so measuring it once and
            // handing it down keeps each row a function of its inputs — which is what the row's
            // own doc comment demands and what makes the decision drivable from a test.
            //
            // **This line is not reachable from a test, and it is now one of exactly two such
            // seams left on this page** (risk 12). Nothing verifies that the number arriving in
            // `rowWidth` is the row's width, and nothing can without a UI test target. The other
            // is `FediqoRootView`'s `message:` closure, which feeds `SourceRow.clearDetailKey`.
            // Every other decision on this page is a named value a test reads.
            // On DESIGN-TAIL §6.3 and §6.4: whether it fires before first paint, and whether it
            // fires when the macOS rail is expanded or collapsed — which moves the page by about
            // 150pt and should flip the regime.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            // **What the marks mean, said once for the list rather than four times per row.**
            // Decision 34 deleted the words from the row and decision 33 makes *absence*
            // meaningful, so a reader looking at a two-mark Mastodon above a four-mark Discuz! has
            // no other way to learn that the short row is short on purpose. `.help()` is a no-op
            // on iOS, so without this line a phone reader has nothing anywhere naming these marks.
            //
            // **Its verbs are the controls' own verbs** — sign in, change boards, clear, remove —
            // matching `account.refuse.signin.label`, `account.source.boards.change`,
            // `prefs.cache.clear.label` and `account.source.remove.label`, so an act keeps its
            // name through the whole surface.
            Text(L10n.t("account.sources.marks"))
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("account.sources.held"))
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The control set of the widest row in this list — decision 33's one-threshold rule.
    ///
    /// **Internal rather than private so a test can read it**, on the same grounds as `busy` and
    /// `searchInk`: this value decides the arrangement of *every* row on the page, and a value
    /// computed inside a `View` body is reachable from nothing — which is precisely how the four
    /// defects risk 12 counts all survived a green suite.
    ///
    /// **From `session.rows` and not `session.sources`**, so the list the threshold is computed
    /// from is the list that is drawn.
    var widest: [SourceRow.Control] {
        SourceRow.widest(session.rows)
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
    func typedHost() async {
        await session.add(from: .field)
    }

    /// Browse pressed. The catalogue is fetched here and not on the page appearing (decision 10).
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
    func press(_ row: SourceRow) async {
        if session.forums.reachedSignIn(host: row.source.host) {
            await session.signOut(host: row.source.host)
        } else {
            await session.signIn(host: row.source.host)
        }
    }

    /// A row's Clear. **Empties nothing** — it raises the question, and only the dialog's confirm
    /// reaches `clear(host:)`. Decision 29, and `askRemove`'s shape for its reason.
    ///
    /// The same act, and the same key, as the one on Preferences — which now asks the same
    /// question through the same presenter, or one word would do two things two panes apart.
    func askClear(_ row: SourceRow) {
        session.clearing = row.source.host
    }

    /// A row's boards control. **Changes nothing by itself** — it reads the forum's index and
    /// opens the picker pre-ticked; the reader still has to press Subscribe, and Cancel loses
    /// nothing.
    func changeBoards(_ row: SourceRow) async {
        await session.changeBoards(host: row.source.host)
    }

    /// A row's Remove. **Destroys nothing** — it raises the question, and only the dialog's
    /// confirm reaches `remove(host:)`.
    func askRemove(_ row: SourceRow) {
        session.removing = row.source.host
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
