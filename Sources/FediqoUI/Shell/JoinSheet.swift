import FediqoCore
import SwiftUI

/// Which of the two surfaces draws a stage.
///
/// **Derived from the stage and never stored beside it** — decision 20. Two presenters read it:
/// `FediqoRootView` puts the sheet up at `.sheet`, `AccountPane` draws the block in the page at
/// `.pane`. They cannot both fire, because a function cannot disagree with its own input.
enum JoinSurface: Equatable {
    /// Over everything, dismissable by a swipe or Escape.
    case sheet
    /// Drawn into `AccountPane` between the field and the sources list, beside the field rather
    /// than over it.
    case pane
}

/// Where a *join* was started. The two entrances that end in something being added.
///
/// **A second enum rather than three cases in one, and it is unit A's own argument honoured
/// rather than departed from.** `PreviewOrigin` gained `.joined` — a source the reader already
/// has, looked at again — and a detail has no Subscribe, so it can never reach a board list.
/// Carried in `BoardsOrigin.preview` and in `ShellSession.take`, `PreviewOrigin` would have made
/// `.preview(_, from: .joined, _)` a value somebody can write: an unreachable combination in a
/// type, which unit A recorded as *a case somebody later writes a branch for*. Narrowed here, the
/// combination cannot be constructed, so no switch in this app ever answers for it — and
/// `confirm()`'s refusal is structural rather than a guard that can be forgotten.
enum JoinEntrance: Equatable {
    /// The reader typed a hostname on `AccountPane` and pressed Return or the magnifier.
    case field
    /// The reader pressed a row in the directory.
    case directory

    /// The same entrance, said as the preview origin it produces. Total, because both of these
    /// *are* previews of something the reader might take.
    var origin: PreviewOrigin {
        switch self {
        case .field: .field
        case .directory: .directory
        }
    }

    /// Which surface reports a press made at this entrance.
    ///
    /// **A function of the entrance and never of what happens to be drawn.** Derived from the
    /// stage it read *whatever block was on screen*, and a reader can have host A's block open
    /// while being turned away typing host B — so B's sentence appeared inside A's block, under
    /// A's Subscribe, with nothing at all under the field where they actually pressed. The
    /// entrance is the press, and the sentence is about the press.
    ///
    /// **No `default:`.**
    var reporter: ProgressOwner {
        // The field's preview is drawn as a block in the page and its Subscribe is in that block,
        // 300pt from the field's own line.
        switch self {
        case .field: .block
        // A browsed preview is in the sheet, which has no line of its own, so the page keeps it —
        // and the directory row the reader pressed draws its own from `progressHost`.
        case .directory: .page
        }
    }
}

/// Where a preview was reached from.
///
/// **Per-case rather than a field on the stage, so an illegal pairing cannot be written.** There
/// is no such thing as browsing-from-the-field, and a single origin beside the stage would let
/// somebody spell it.
enum PreviewOrigin: Equatable {
    /// The reader typed a hostname on `AccountPane` and pressed Return or the magnifier. Drawn in
    /// the page, beside the field they typed into.
    case field
    /// The reader pressed a row in the directory. The directory is behind them, so this stays in
    /// the sheet the directory is in.
    case directory
    /// A source the reader already has, whose own account of itself they asked to see —
    /// **decision 31**.
    ///
    /// **Not a preview of something they might take: a detail of something they have.** The
    /// sentences that frame this screen as a decision are all false here, so three of them change
    /// (`SourcePreviewView.framingKey`, `.heldLine`, `.cautionKey`) and the evidence does not.
    ///
    /// **`look()` refuses an added host by design, so this must not route through it.** The
    /// answer is already in `ShellSession.profiles`, put there by the look the reader waited for
    /// when they added it, and this costs **no request**. `ShellSession.openSource(host:)` is the
    /// entrance.
    ///
    /// **It carries the source, and that is not the copy `removing` refuses to hold.** The whole
    /// board list is the one thing this screen has that the row does not — the row clips at two
    /// lines — and it is not in `SourcePreview`, whose `boards` is the forum's *index*. A copy
    /// held here cannot go stale while it is held: this is a stage, and `rowActsLive` refuses
    /// every control on every row while a stage is up, so the reader cannot change their boards
    /// underneath it. `removing` is a dialog, which leaves the rows live, and that is the
    /// difference.
    case joined(Source)

    /// The join this entrance is part of, or nothing where it is not part of one.
    ///
    /// **A total function and the only door to `ShellSession.take`**, which is what makes a
    /// detail's Subscribe unrepresentable rather than guarded against: `.joined` has no
    /// `JoinEntrance` to hand over, so there is nothing for `take` to be called with, and
    /// `JoinSheet` reads the same `nil` to draw no primary button at all.
    ///
    /// **No `default:`** — a fourth entrance says whether a press means anything on it rather
    /// than inheriting `.field`'s yes.
    var entrance: JoinEntrance? {
        switch self {
        case .field: .field
        case .directory: .directory
        case .joined: nil
        }
    }

    /// The source this screen is a detail *of*, where it is a detail at all.
    ///
    /// Read by the one line that differs per protocol — `SourcePreviewView.heldLine(_:)` — so the
    /// boards the reader actually subscribed to travel with the origin rather than being fetched
    /// back out of the session by a view.
    var held: Source? {
        switch self {
        case .field, .directory: nil
        case .joined(let source): source
        }
    }
}

/// What the reader was doing when they arrived at a forum's board list.
///
/// The two are different errands and the sheet has to tell them apart: one is a join with a
/// preview behind it, the other is a reader restating what they already read.
enum BoardsOrigin: Equatable {
    /// A join in progress. Carries the preview — decision 12 — so Back costs no second request,
    /// and the origin of *that* preview.
    ///
    /// **The origin is load-bearing and not a note about where the reader came from.**
    /// `backToPreview()` does not restore a stage, it **reconstructs** one:
    /// `.previewing(preview, from: origin)`. Drop the origin here and there is nothing to
    /// reconstruct it from, so Back would have to guess — and either guess is a reader thrown onto
    /// the wrong surface. Guess `.field` and a preview picked off the directory comes back as a
    /// block in the page, for somebody who never typed anything and whose sheet has just vanished.
    /// Guess `.directory` and a typed host's Back opens a sheet over the page that is still
    /// drawing that same preview underneath it.
    ///
    /// It is also what `JoinStage.inlinePreview` reads to keep the page's block drawn while this
    /// sheet stands over it, which is the more visible of the two but the weaker reason.
    ///
    /// **`ticked` is what the picker opens ticked here** — decision 27. From the directory both
    /// stages are this sheet, so the sheet stayed mounted and its ticks survived Back by accident
    /// of where they were stored; from the field the preview is `.pane`, the sheet comes down on
    /// Back and took them with it. Carried in the stage, the two entrances answer the same
    /// question from the same place, and no surface keeps state another cannot.
    ///
    /// **`JoinEntrance` and not `PreviewOrigin`**, because only a join reaches a board list: see
    /// `JoinEntrance` for why the narrower type is unit A's argument kept rather than broken.
    case preview(SourcePreview, from: JoinEntrance, ticked: Set<Int>)
    /// A source the reader already has, whose boards they are changing.
    ///
    /// **`subscribed` is the baseline and `ticked` is the reader's hand on it**, and they are two
    /// facts rather than one. The baseline is what `subscribe(host:to:keeping:)` is told to keep,
    /// so a board that is still picked is carried through rather than fetched again; the ticks are
    /// what the reader has done since the sheet opened.
    ///
    /// **The picker opens ticked from the baseline, or the feature is a data-loss bug** —
    /// decision 25. `ItemStore.subscribe(host:to:)` **replaces** the board set, so a picker that
    /// opened empty and a reader who ticked one new board would silently unsubscribe the eight
    /// they had.
    case joined(subscribed: [BoardSubscription], ticked: Set<Int>)

    /// What the picker opens ticked. **One concept, two sources** — the reader's own ticks on a
    /// join, and their existing subscription on a restate.
    ///
    /// **No `default:`.** A third entrance has to say what it opens ticked rather than inherit an
    /// answer, and either wrong answer here is silent: an empty one unsubscribes, and a full one
    /// re-subscribes to boards the reader unticked.
    var ticked: Set<Int> {
        switch self {
        case .preview(_, _, let ticked): ticked
        case .joined(_, let ticked): ticked
        }
    }

    /// The boards this host is subscribed to **now**, which is what a restate is told to keep.
    ///
    /// Empty for a join, because a join has nothing to keep — and it says so rather than
    /// defaulting, which is `subscribe(host:to:keeping:)`'s own rule about its `keeping:`.
    var keeping: [BoardSubscription] {
        switch self {
        case .preview: []
        case .joined(let subscribed, _): subscribed
        }
    }

    /// Whether this errand belongs to a row rather than to the page.
    ///
    /// **It decides which surface reports it**, both while it runs and when it fails: a restate
    /// was started by a control inside one row and is answered there, while a join was started at
    /// the field and is answered under it. Read by `ShellSession.progress`, whose `ProgressOwner`
    /// is what both the progress line and the refusal are routed on — one concept, so the two
    /// cannot come to disagree about whose press this was.
    ///
    /// **No `default:`.**
    var isRestate: Bool {
        switch self {
        case .preview: false
        case .joined: true
        }
    }

    /// The same errand, with the reader's hand moved. **Pure**, so the picker writing a tick and
    /// a test writing one are the same call.
    func ticking(_ picked: Set<Int>) -> BoardsOrigin {
        switch self {
        case .preview(let preview, let origin, _): .preview(preview, from: origin, ticked: picked)
        case .joined(let subscribed, _): .joined(subscribed: subscribed, ticked: picked)
        }
    }
}

/// Where the reader is in adding a source: looking for one, looking *at* one, or picking what of
/// it to read.
///
/// **Three stages, one piece of state, and the stage says which surface draws it.** Three sheets
/// driven by three optionals is what this replaces, and on iOS two `.sheet` modifiers that can
/// both be active means the second is silently ignored.
///
/// **The entrance travels in the case** — decision 20. It used to be a `@State` inside `JoinSheet`
/// called `cameFromBrowsing`: a view-local flag no test could reach, which is the shape this
/// branch has shipped a defect in twice. Carried here, `surface`, `inlinePreview`,
/// `admitsASecondLook` and `leading(for:)` are all pure functions of one value, and every one of
/// them is driven by a test.
///
/// **`.choosingBoards` carries the preview it came from** — decision 12. It is what lets the
/// boards stage draw a Back button at all, and Back without a second request is the reader-visible
/// gain of merging the three sheets.
enum JoinStage: Identifiable, Equatable {
    /// A list of servers to look at. Nothing has been typed and nothing detected.
    case browsing
    /// One server, and what it says about itself. **Nothing added.**
    ///
    /// **`ticked` is the boards stage's ticks, in transit** — decision 27, and the one part of it
    /// `BoardsOrigin` cannot hold on its own. The inline round trip is boards → Back → Subscribe,
    /// and Back lands *here*: a stage with nowhere to put them is where the reader's ticks were
    /// being dropped. Empty for every fresh look, and for every protocol that has no boards.
    ///
    /// **Recorded: `ShellSession.resumeAfterSignIn` passes `[]`**, so a reader who had ticked
    /// boards, stepped back, was turned away and went and signed in returns to an unticked
    /// picker. Narrow — it needs a refusal between the Back and the press — and the explicit `[]`
    /// is a correct no-default rather than an oversight: what that path resumes is a *join* that
    /// was refused, and the index it lands on is the signed-in one, which is a different document
    /// from the one those ticks were made against.
    case previewing(SourcePreview, from: PreviewOrigin, ticked: Set<Int>)
    /// D28's pause: the forum's boards, and what the reader was doing when they got here.
    case choosingBoards(JoinOffer, from: BoardsOrigin)

    var id: String {
        switch self {
        case .browsing: "browsing"
        case .previewing(let preview, _, _): "previewing:\(preview.host)"
        case .choosingBoards(let offer, _): "choosingBoards:\(offer.host)"
        }
    }

    /// What the picker opens ticked, wherever the reader is standing.
    ///
    /// **The ticks live here and nowhere else** — decision 27. `JoinSheet` holds no `@State` for
    /// them at all, so a tick made with the mouse, a tick restored after Back and a tick written
    /// by a test are one value in one place, and the sheet coming down cannot take them anywhere.
    ///
    /// **No `default:`.**
    var ticked: Set<Int> {
        switch self {
        case .browsing: []
        case .previewing(_, _, let ticked): ticked
        case .choosingBoards(_, let origin): origin.ticked
        }
    }

    /// The same stage with the reader's hand moved. **Pure and total**, so the picker's binding is
    /// a call to this and the press-by-press route a test walks is the same one.
    ///
    /// `.browsing` names no forum, so there is nothing on it to tick and it answers itself
    /// unchanged rather than inventing a set — which is the same fact `host` reports as `nil`.
    func ticking(_ picked: Set<Int>) -> JoinStage {
        switch self {
        case .browsing: .browsing
        case .previewing(let preview, let origin, _):
            .previewing(preview, from: origin, ticked: picked)
        case .choosingBoards(let offer, let origin):
            .choosingBoards(offer, from: origin.ticking(picked))
        }
    }

    /// The server this stage is about, where it is about one.
    ///
    /// **`.browsing` is about none, and that is a fact rather than a gap.** A reader with the
    /// directory open has not named a host yet, so a caller asking "is this stage about the
    /// server that just went away" gets the true answer of no.
    var host: String? {
        switch self {
        case .browsing: nil
        case .previewing(let preview, _, _): preview.host
        case .choosingBoards(let offer, _): offer.host
        }
    }

    /// Which surface draws this stage. **Derived, never stored** — decision 20.
    ///
    /// A typed hostname's preview belongs beside the field the reader typed into; one reached from
    /// the directory belongs in the sheet the directory is in, because the directory is what is
    /// behind it. Everything else is the sheet.
    ///
    /// **No `default:`**, and the `.previewing` cases are split rather than folded: a fourth
    /// entrance has to say where it draws rather than inherit somebody else's answer.
    var surface: JoinSurface {
        switch self {
        case .browsing: .sheet
        case .previewing(_, .field, _): .pane
        case .previewing(_, .directory, _): .sheet
        // **The page has no slot for a detail that is not above the list.** `AccountPane` draws
        // its block between the field and the sources, so opening row four's detail inline would
        // push a screenful in above the list and scroll the reader away from the row they
        // pressed. Decision 31, and `DESIGN-R2` §4.1.
        case .previewing(_, .joined, _): .sheet
        case .choosingBoards: .sheet
        }
    }

    /// Which preview the *page* is showing, if any.
    ///
    /// True at `.previewing` whose origin is the field, **and also** while the boards sheet stands
    /// over it: the page is what the reader steps back onto, so it does not stop being drawn while
    /// something is drawn on top of it. A pane that asked `if case .previewing` would blank the
    /// block the moment the sheet opened and rebuild it on Back — which is the page throwing the
    /// reader somewhere and then throwing them back.
    ///
    /// **No `default:`**, so the boards origins each answer for themselves.
    var inlinePreview: SourcePreview? {
        switch self {
        case .browsing: nil
        case .previewing(let preview, .field, _): preview
        case .previewing(_, .directory, _): nil
        // A detail is drawn in the sheet, so the page draws nothing for it.
        case .previewing(_, .joined, _): nil
        case .choosingBoards(_, .preview(let preview, .field, _)): preview
        case .choosingBoards(_, .preview(_, .directory, _)): nil
        case .choosingBoards(_, .joined): nil
        }
    }

    /// Whether the reader may start a second look — type another hostname, or press Browse —
    /// while this stage is up.
    ///
    /// **This is the other half of splitting `busy`, and leaving it out makes the first half a
    /// lie.** An inline preview does not cover the field, so the field is re-enabled beside it;
    /// a field that is live and whose Return is refused by a guard three files away is a control
    /// that does nothing, which is exactly the defect unit 5b closed and risk 12 names.
    ///
    /// `.browsing` admits one because the directory's own rows *are* looks. A preview in the sheet
    /// and a board list do not, because the reader cannot see past them to know they replaced
    /// something.
    ///
    /// **No `default:`**, in the house style of `hasTrends` and `canSignIn`.
    var admitsASecondLook: Bool {
        switch self {
        case .browsing: true
        case .previewing(_, .field, _): true
        case .previewing(_, .directory, _): false
        // A detail covers the field, like a browsed preview and for its reason: the reader cannot
        // see what a second look would replace.
        case .previewing(_, .joined, _): false
        case .choosingBoards: false
        }
    }
}

/// The one sheet adding a source is done in, at whichever of its three stages the reader is on.
///
/// **Presented over `.sheet(isPresented:)`, and the `id` is exactly why.** A stable identity is
/// what stops SwiftUI re-presenting a sheet, so `.sheet(item:)` would leave whether the content
/// builder re-runs for a same-id change to version-dependent behaviour rather than to contract —
/// and the likely outcome on a device is the preview still on screen while the session says
/// boards. `isPresented` plus the switch below has neither problem: `ShellSession` is
/// `@Observable`, this body reads `session.stage`, and a change of stage is a redraw.
///
/// The frame is `BoardPickerSheet`'s, which is this house's reference sheet: header, hairline,
/// scrolling body, hairline, footer. The sizing modifiers live here and **only** here, so the
/// window does not resize as the reader moves between stages.
struct JoinSheet: View {
    @Bindable var session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    @AccessibilityFocusState private var headerFocused: Bool

    private enum Metrics {
        static let fieldRadius: CGFloat = 6
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            body(for: session.stage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            hairline
            footer
        }
        .background(ShellChrome.page(colorScheme))
        // Nothing is added until the reader says so, so a swipe is a complete cancel — except
        // while something is actually on the wire, where leaving would strand the press.
        .interactiveDismissDisabled(session.checking)
        // **`id` and not the stage itself.** The ticks now live *in* the stage, so every tick is a
        // change of it — and focus moved on every change would throw a VoiceOver reader back to
        // the header each time they ticked a board. `id` names the stage and the forum and nothing
        // else, so it moves exactly when the reader has arrived somewhere new.
        .onChange(of: session.stage?.id) { _, _ in headerFocused = true }
        // **And on the way in, because `.onChange` does not fire on a first presentation.** Every
        // entrance that mounts this sheet already at its stage would otherwise never move focus:
        // the restate opens straight into `.choosingBoards` from no stage at all, and a typed
        // host's Subscribe opens it from a preview drawn in the page. Only the transitions *inside*
        // the sheet were covered.
        .onAppear { headerFocused = true }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }

    // MARK: - The frame

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            switch session.stage {
            case .browsing:
                titled(L10n.t("join.browse.title"), L10n.t("join.browse.detail"))
                filterField
            // **The one block this sheet shares with the page, in the sheet's own header slot.**
            // It stays pinned above the hairline here and scrolls with the block there, which is
            // why it is placed by each surface rather than carried inside the shared body.
            case .previewing(let preview, let origin, _):
                SourcePreviewView.Header(preview: preview, surface: .sheet, origin: origin)
                    .accessibilityFocused($headerFocused)
            case .choosingBoards(let offer, let origin):
                titled(
                    String(format: L10n.t("board.choose.title"), offer.host),
                    L10n.t(Self.detailKey(for: origin))
                )
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(title)
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($headerFocused)
            Text(detail)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sentence under the boards title, which is not the same sentence on both entrances.
    ///
    /// `board.choose.detail` ends "Nothing is added until you do", which is true of a join and
    /// **false of a restate** — the source was added weeks ago, and what the reader needs to know
    /// before they press is the thing `ItemStore.subscribe(host:to:)` actually does: what they
    /// pick replaces what they read now. Two sentences, two keys, because a translator cannot
    /// reorder a clause glued on with `+`.
    ///
    /// **No `default:`**, so a third entrance says which of the two facts is true of it.
    static func detailKey(for origin: BoardsOrigin) -> String {
        switch origin {
        case .preview: "board.choose.detail"
        case .joined: "board.choose.detail.change"
        }
    }

    /// What a preview's header says out loud: the host, the protocol, and the shape — the same
    /// sentence the source row says about the same server, from the same key.
    static func spoken(_ preview: SourcePreview) -> String {
        String(
            format: L10n.t("source.spoken"),
            preview.host,
            preview.kind.displayName,
            DummyItem.shapeWord(DummyItem.shape(of: preview.kind))
        )
    }

    @ViewBuilder
    private func body(for stage: JoinStage?) -> some View {
        switch stage {
        case .browsing:
            browsing
        case .previewing(let preview, let origin, _):
            // **The `ScrollView` is the sheet's and not the shared view's.** `AccountPane` is
            // already one scroller and nesting a second inside it is the failure that pane's own
            // comment records: the list squeezed to a sliver at 320pt with nothing to scroll.
            ScrollView { SourcePreviewView(preview: preview, surface: .sheet, origin: origin) }
        case .choosingBoards(let offer, _):
            BoardPickerList(offer: offer, picked: picked)
        case nil:
            EmptyView()
        }
    }

    /// The boards this reader has ticked, by `fid` — **read and written straight through to the
    /// stage**, which is the whole of decision 27.
    ///
    /// **There is no `@State` here any more, and that is a deletion rather than a move.** The
    /// ticks used to be a set and a host held by this view, so "which boards are ticked" meant
    /// "the boards ticked at some point during this presentation" — which was one forum's only by
    /// a rule (`ticks(_:movingTo:)`) that had to be remembered on every stage change, and which
    /// the sheet coming down took with it anyway. Discuz! `fid`s are small integers and collide
    /// across forums as a matter of course, so that was a reader subscribing to boards of B they
    /// ticked on A, one bug away at all times.
    ///
    /// Held in the stage, none of that is a rule: a stage names exactly one forum, so the ticks
    /// cannot belong to another one, and a sheet that unmounts on Back leaves them where they
    /// were. A swipe, Escape, the leading button and a remount all behave identically because
    /// none of them is holding anything.
    private var picked: Binding<Set<Int>> {
        Binding(
            get: { session.stage?.ticked ?? [] },
            set: { session.stage = session.stage?.ticking($0) }
        )
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: ShellSpace.step) {
            reading
            Spacer(minLength: ShellSpace.snug)
            leading
            primary
        }
        .padding(ShellSpace.pad)
    }

    /// The sentence about the errand **this sheet** is the visible surface for, or nothing.
    ///
    /// **The sheet had no waiting site at all before this**, which is how a browsed preview's
    /// Subscribe came to draw its sentence under a field the sheet was covering. See
    /// `ShellSession.reporting(_:drawnAs:)`: ownership was right and visibility was never asked.
    ///
    /// Read from `session.progress` rather than spelled here, so the sheet says what the errand
    /// says — `SourceRow.waitingLine`'s rule, which exists to abolish exactly the fifth call site
    /// that spells it differently.
    var sheetWaiting: String? {
        guard ShellSession.reporting(session.progress, drawnAs: session.stage) == .sheet,
              let key = session.progress?.key
        else { return nil }
        return String(format: L10n.t(key), session.progressHost)
    }

    /// Whether a directory row is drawing this errand itself.
    ///
    /// **The sheet has two places to put one sentence and they must not both fire.** A catalogue
    /// row draws its own — which of forty rows they pressed is the thing they cannot otherwise
    /// see — and everything else goes in the footer: a preview being taken, which has no row, and
    /// a host the directory does not list, which is `extraRow` and had no site before either.
    ///
    /// A `static func` over the hosts rather than a term in a `View` body, so the rule that keeps
    /// them apart is drivable (risk 12).
    static func drawnByARow(_ stage: JoinStage?, host: String, listed: [String]) -> Bool {
        guard case .browsing = stage else { return false }
        return listed.contains(host)
    }

    /// The footer's count, where the stage has one — or the sheet's own sentence, where there is
    /// no row to put it on. **Mutually exclusive**: `.choosingBoards` has a count and no errand
    /// this sheet reports, and every other stage has no count.
    @ViewBuilder
    private var reading: some View {
        if let waiting = sheetWaiting,
           !Self.drawnByARow(
               session.stage,
               host: session.progressHost,
               listed: session.visibleServers.map { $0.domain.lowercased() }
           ) {
            ForumWaiting(line: waiting)
        } else if case .choosingBoards(let offer, _) = session.stage {
            Text(String(
                format: L10n.t("board.choose.count"),
                picked.wrappedValue.count,
                offer.boards.count
            ))
                .font(ShellType.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
        }
    }

    /// **By rule rather than by history** — §2.2. What is behind the reader decides the word:
    /// nothing at the directory, the directory or the field at a preview, and always the preview
    /// at the boards.
    ///
    /// **Named as a value rather than written straight into the button**, because the one bug
    /// this control has already had was a button calling the wrong method — Back from a preview
    /// called `browse()`, which refuses while a sheet is up, so the button did nothing at all and
    /// every test stayed green. A `View` body is the one place a test cannot reach; the rule and
    /// the press are both reachable here, and both are pinned.
    enum Leading: Equatable {
        case close
        case backToBrowsing
        case backToPreview
        case cancel

        /// The word printed on it.
        var key: String {
            switch self {
            case .close: "join.close"
            case .backToBrowsing, .backToPreview: "join.back"
            // Reused rather than duplicated, so the two stages cannot drift in translation.
            case .cancel: "board.choose.cancel"
            }
        }
    }

    /// Which button the reader is looking at. **No `default:`** — a fourth stage has to decide
    /// what is behind it rather than inherit somebody else's answer.
    ///
    /// **A pure function of one value, and that is the whole of what changed here.** The
    /// directory-or-field distinction used to arrive as a second argument fed from a view-local
    /// `@State`, so the rule was pinned and the thing that set it was reachable from no test. The
    /// entrance now travels in the stage, so four stage-shapes give four answers and every one of
    /// them is driven from a test.
    ///
    /// `.previewing(_, .field)` is drawn in the page and has no footer to put a button in; it
    /// still answers, because the rule is about what is behind the reader and not about who is
    /// asking.
    static func leading(for stage: JoinStage?) -> Leading? {
        switch stage {
        case .browsing: .close
        case .previewing(_, .directory, _): .backToBrowsing
        case .previewing(_, .field, _): .cancel
        // **Nothing is behind a detail and it is not a step in a flow**, so the word is Close and
        // not Cancel: there is no errand to call off. Decision 31, and `DESIGN-R2` §4.1.
        case .previewing(_, .joined, _): .close
        case .choosingBoards(_, .preview): .backToPreview
        // **A restate has nothing behind it.** The reader pressed a boards control on a row they
        // already have; there is no preview to step back to, so the word is Cancel and pressing it
        // changes nothing. Split from the case above rather than folded, because the two are
        // different errands and `sheetDismissed()` already tells them apart the same way.
        case .choosingBoards(_, .joined): .cancel
        case nil: nil
        }
    }

    /// What pressing it does. **No `default:`**, and pinned one case at a time: this switch is
    /// the wiring the shipped bug lived in.
    static func press(_ leading: Leading, on session: ShellSession) {
        switch leading {
        case .close, .cancel: session.dismissStage()
        case .backToBrowsing: session.backToBrowsing()
        case .backToPreview: session.backToPreview()
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let leading = Self.leading(for: session.stage) {
            Button(L10n.t(leading.key)) { Self.press(leading, on: session) }
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch session.stage {
        // **A detail has nothing to subscribe to, so it draws no primary at all** — and it is the
        // same `nil` `ShellSession.confirm()` refuses on, not a second reading of the same fact.
        // Close alone: Remove, Clear and Boards stay on the row, because a second entrance to
        // Remove is the two-presenters failure in a new shape.
        case .previewing(_, let origin, _) where origin.entrance == nil:
            EmptyView()
        case .previewing(let preview, _, _):
            let warned = SourcePreviewView.warns(preview)
            Button(L10n.t("board.choose.subscribe")) { Task { await session.confirm() } }
                .disabled(session.checking)
                // **Withdrawn in the one state the screen has just warned about.** The reader may
                // still press it — the warning is a prediction and not a refusal — but Return
                // must not fire the press they were told would probably fail. They have to aim.
                .keyboardShortcut(warned ? .none : .defaultAction)
                .accessibilityHint(warned ? Text(L10n.t("join.preview.closed.hint")) : Text(""))
        case .choosingBoards(let offer, _):
            Button(L10n.t("board.choose.subscribe")) {
                // **In the index's order, not the order they were tapped.** The rail reads this
                // straight through, and a forum's own ordering is a better rail than a record of
                // which board somebody happened to notice first. Filtering `offer.boards` is what
                // makes that true; iterating `picked` would give tap order, and a `Set` would
                // give neither.
                let ticked = picked.wrappedValue
                let picks = offer.boards.filter { ticked.contains($0.fid) }
                Task { await session.subscribe(picks) }
            }
            .keyboardShortcut(.defaultAction)
            // **Decision 24, and it is the refusal made visible rather than a convenience.**
            // Core cannot express "unsubscribe from everything": with an empty pick
            // `DiscuzBoardJoin.subscribe` returns before it reaches `store.subscribe`, and
            // `ShellSession.subscribe`'s empty-pick guard reads it as a reader who changed their
            // mind — true of a join and false of a restate. Rather than let one silence mean two
            // things, the button says no where the reader can see it. **Do not "fix" this into a
            // press that goes through**: that press would be a silent mass-unsubscribe, and the
            // honest route to reading none of a forum is Remove.
            .disabled(picked.wrappedValue.isEmpty)
        case .browsing, nil:
            EmptyView()
        }
    }

    // MARK: - Stage: browsing

    /// The catalog, with the sheet's header over it and a field inside it.
    ///
    /// **The field is load-bearing and not an addition.** `visibleServers` and `extraJoinHost` are
    /// both computed off `session.hostname`, so without a field in here the filter and the
    /// type-a-host-that-is-not-listed path are simply gone the moment Browse becomes a sheet.
    /// Bound to the same property, so what is typed here is still in the page's field afterwards.
    private var filterField: some View {
        TextField(L10n.t("join.browse.filter"), text: $session.hostname)
            .font(ShellType.body)
            .textFieldStyle(.plain)
            .disabled(session.checking)
            .onSubmit { Task { await look() } }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.t("join.browse.filter"))
            .padding(.horizontal, ShellSpace.step)
            .padding(.vertical, ShellSpace.snug)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
            }
    }

    /// A row was pressed here, so the preview it opens has the directory behind it.
    ///
    /// **The entrance goes to the session rather than into a flag here.** It used to set a
    /// `@State` this sheet owned, which meant the one thing deciding where a preview is drawn and
    /// what its Back button says lived in the one place a test cannot reach.
    private func look() async {
        await session.add(from: .directory)
    }

    @ViewBuilder
    private var browsing: some View {
        switch session.catalog {
        case .loading:
            // One way of waiting, `ShellType.body` dropped to `meta` with it: a sentence about an
            // errand is read second, whatever surface it is on.
            note { ForumWaiting(line: L10n.t("account.catalog.loading")) }
        case .failed:
            note { Text(L10n.t("account.catalog.failed")) }
        case .empty:
            note { Text(L10n.t("account.catalog.empty")) }
        case .ready:
            ScrollView {
                // Sections now, with the header drawn only where there is more than one — M1 has
                // exactly one and draws none, so no speculative section name ships. M3 adds rows
                // to a structure that is already here.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let host = session.extraJoinHost {
                            extraRow(host)
                            hairline
                        }
                        ForEach(session.visibleServers) { server in
                            catalogRow(server)
                            hairline
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(ShellType.body)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A host the directory does not list. **It opens a preview, like every other row** — which
    /// is why its copy no longer says Add.
    private func extraRow(_ host: String) -> some View {
        let added = session.isAdded(host)
        return Button {
            session.hostname = host
            Task { await look() }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(String(format: L10n.t("join.browse.look"), host))
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : L10n.t("join.browse.look.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.checking || added)
        .accessibilityLabel(String(format: L10n.t("join.browse.look"), host))
    }

    private func catalogRow(_ server: CatalogServer) -> some View {
        let added = session.isAdded(server.domain)
        return Button {
            Task { await session.pick(server) }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(server.domain)
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : server.summary)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
                if !added { rowFoot(server) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.checking || added)
        .accessibilityLabel(server.domain)
        .accessibilityValue(
            added ? L10n.t("account.catalog.added") : "\(server.summary), \(metaLine(server))"
        )
    }

    /// The row's own readings, or — for the one row the reader just pressed — the fact that this
    /// app is asking it. **Which of forty rows they pressed is the thing they cannot otherwise
    /// see**, and `progressHost` already records it.
    @ViewBuilder
    private func rowFoot(_ server: CatalogServer) -> some View {
        // **The sentence comes from the errand, not from here.** This site spelled both halves
        // inline — a hard-coded key and a hand-rolled host comparison — while `session.progress`
        // carried that exact key at that moment and went unread. That is the fifth call site
        // spelling it differently, which is the shape `SourceRow.waitingLine` exists to abolish;
        // a phase whose words changed would have changed everywhere but here.
        if let waiting = sheetWaiting, session.progressHost == server.domain.lowercased() {
            // `ShellType.mark` rises to `meta` with the vocabulary. It was the smallest engraving
            // in the app under the one row of forty the reader had just pressed.
            ForumWaiting(line: waiting)
        } else {
            // Three readings, each one a labelled sentence about the server. They used to be a
            // single string joined with middle dots, where one of the numbers was labelled with
            // an initialism and the other was not labelled at all — which is the objection this
            // separation answers, and the reason a dot-joined line is not the tidier version of
            // it. (`JoinSheet.figureLine` *does* dot-join, and may: there both halves say what
            // they are.)
            HStack(spacing: ShellSpace.pad) {
                ForEach(readings(server), id: \.self) { reading in
                    Text(reading)
                }
            }
            .font(ShellType.mark)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
        }
    }

    private func readings(_ server: CatalogServer) -> [String] {
        [
            languageName(server.language),
            String(format: L10n.t("account.catalog.weekly"), L10n.compact(server.weekUsers)),
            String(format: L10n.t("account.catalog.people"), L10n.compact(server.users)),
        ]
    }

    private func metaLine(_ server: CatalogServer) -> String {
        readings(server).joined(separator: ", ")
    }

    private func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.t("account.catalog.langUnknown") }
        return locale.localizedString(forLanguageCode: trimmed) ?? trimmed
    }

}
