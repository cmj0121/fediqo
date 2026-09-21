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

/// Where a preview was reached from.
///
/// **Per-case rather than a field on the stage, so an illegal pairing cannot be written.** There
/// is no such thing as browsing-from-the-field, and a single origin beside the stage would let
/// somebody spell it.
///
/// **Two cases, and the third one's going is decision 38.** There was a `.directory` — a preview
/// reached by pressing a row in the browser, drawn in the sheet the browser was in. The browser is
/// a picker now: choosing a server closes it, fills the field and runs the errand a typed host
/// runs, so every preview of a server the reader might take arrives through the field and is drawn
/// beside it. **What went with that case is this milestone's hardest defect** — `.directory`'s
/// press reported itself on the page while its stage was surfaced in the sheet, so the progress
/// sentence drew under a field the sheet was standing on. No `.directory`, no contradiction, and
/// no rescue needed for one; see `ShellSession.reporting(_:drawnAs:)`.
enum PreviewOrigin: Equatable {
    /// The reader typed a hostname on `AccountPane` and pressed Return or the magnifier — or
    /// picked a server in the browser, which fills that same field and presses it for them. Drawn
    /// in the page, beside the field.
    case field
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

    /// Which surface reports a Subscribe pressed here — and **nothing where there is no Subscribe
    /// to press.**
    ///
    /// **A total function and the only door to `ShellSession.take`**, which is what makes a
    /// detail's Subscribe unrepresentable rather than guarded against: `.joined` has no owner to
    /// hand over, so there is nothing for `take` to be called with, and `JoinSheet` reads the same
    /// `nil` to draw no primary button at all. It carried a `JoinEntrance` until decision 38 left
    /// that enum with one case; what the entrance was ever *for* was this answer, so the answer is
    /// what stayed.
    ///
    /// **`.block` and not `.page`, because a join's preview is a block in the page and its
    /// Subscribe is in that block**, 300pt from the field's own line. That is now true of every
    /// Subscribe there is, which is the contradiction decision 38 deleted.
    ///
    /// **No `default:`** — a third origin says whether a press means anything on it rather than
    /// inheriting `.field`'s yes.
    var reporter: ProgressOwner? {
        switch self {
        case .field: .block
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
        case .field: nil
        case .joined(let source): source
        }
    }
}

/// What the reader was doing when they arrived at a forum's board list.
///
/// The two are different errands and the sheet has to tell them apart: one is a join with a
/// preview behind it, the other is a reader restating what they already read.
enum BoardsOrigin: Equatable {
    /// A join in progress. Carries the preview — decision 12 — so Back costs no second request.
    ///
    /// **It carried the preview's own origin too, and decision 38 is what retired that.**
    /// `backToPreview()` does not restore a stage, it **reconstructs** one — and while a preview
    /// could be reached from two places, a guess about which would throw the reader onto the wrong
    /// surface. Every join preview is now the field's, so the reconstruction has one answer and
    /// nothing to carry it in.
    ///
    /// **`ticked` is what the picker opens ticked here** — decision 27. The preview is drawn in
    /// the page, so the sheet comes down on Back and would take a tick set stored in the view with
    /// it. Carried in the stage, a swipe and a Back behave identically because neither surface is
    /// holding anything.
    case preview(SourcePreview, ticked: Set<Int>)
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
        case .preview(_, let ticked): ticked
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
        case .preview(let preview, _): .preview(preview, ticked: picked)
        case .joined(let subscribed, _): .joined(subscribed: subscribed, ticked: picked)
        }
    }
}

/// Where the reader is in adding a source: looking for a protocol, looking through its servers,
/// looking *at* one, or picking what of it to read.
///
/// **Four stages, one piece of state, and the stage says which surface draws it.** Three sheets
/// driven by three optionals is what this replaces, and on iOS two `.sheet` modifiers that can
/// both be active means the second is silently ignored.
///
/// **The browser is two steps and has no field of its own** — decisions 19 and 38. `.browsing` is
/// the protocols this app can read; `.browsingServers` is one protocol's suggested servers.
/// Choosing a server does not open a preview *here*: it closes the sheet, fills the hostname
/// field and runs the same errand typing would, which is why no browsing stage leads anywhere
/// inside this sheet.
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
    /// Step one of the browser: the protocols this app can read. **Names no server and reaches no
    /// wire** — the directory is not asked for until a protocol that has one is chosen, which is
    /// decision 10 moved one press later than it was.
    case browsing
    /// Step two: the servers suggested for one protocol, or the sentence saying there are none
    /// suggested for it yet. **Nothing is typed here and nothing is filtered** — the user's
    /// ruling, decision 38: the browser is a picker and the field is on the page.
    case browsingServers(ProtocolKind)
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
    /// A signed-in Mastodon's lists, and which of them this device reads (#25). Always about a
    /// source the reader already has, so it is the boards restate's shape: Cancel, never Back.
    /// Its ticks are list ids and live in the choice, not in `ticked`, which is a board's `fid`.
    case choosingLists(ListChoice)

    /// Whether this stage goes away when the reader leaves the window.
    ///
    /// **The selectors do; nothing else does — the user's ruling, stated with its cost.** A
    /// picker is a question the reader came to answer, and one they walked away from is a
    /// question they stopped answering. What it costs is named here rather than argued away:
    /// **`.choosingBoards` is holding their ticks**, and on a Mac `scenePhase` goes `.inactive`
    /// whenever the window stops being the key one — so a reader who switches to a browser to
    /// copy a hostname comes back to an unticked picker. That was put to the user and this is
    /// the answer; `ShellSession.windowLeft(_:)` is where the platforms are told apart, and it is
    /// deliberately *not* `.inactive` on iOS for the same reason.
    ///
    /// **The editor and a new post are excluded and are not here to exclude.** Compose and
    /// sign-in are their own sheets on `FediqoRootView`, not stages, so this property cannot
    /// reach them and no future case can accidentally give them this behaviour.
    ///
    /// **No `default:`.** A fifth stage answers, or it does not build.
    var closesWhenTheWindowLeaves: Bool {
        switch self {
        case .browsing, .browsingServers: true
        // Drawn in the page beside the field, not over it — decision 38. There is no window to
        // leave that would make a block in a page a thing to take away.
        case .previewing(_, .field, _): false
        // The detail of a source already held is a thing to read, not a question to answer.
        case .previewing(_, .joined, _): false
        case .choosingBoards, .choosingLists: true
        }
    }

    var id: String {
        switch self {
        case .browsing: "browsing"
        case .browsingServers(let kind): "browsingServers:\(kind.rawValue)"
        case .previewing(let preview, _, _): "previewing:\(preview.host)"
        case .choosingBoards(let offer, _): "choosingBoards:\(offer.host)"
        case .choosingLists(let choice): "choosingLists:\(choice.host)"
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
        case .browsing, .browsingServers: []
        case .previewing(_, _, let ticked): ticked
        case .choosingBoards(_, let origin): origin.ticked
        // Lists are ticked by id, in the choice itself; there is no board here to tick.
        case .choosingLists: []
        }
    }

    /// The same stage with the reader's hand moved. **Pure and total**, so the picker's binding is
    /// a call to this and the press-by-press route a test walks is the same one.
    ///
    /// Neither browsing step names a forum, so there is nothing on either to tick and both answer
    /// themselves unchanged rather than inventing a set — which is the same fact `host` reports as
    /// `nil`.
    func ticking(_ picked: Set<Int>) -> JoinStage {
        switch self {
        // Neither browsing step holds ticks, so both hand themselves back rather than rebuilding
        // a value equal to the one matched. Still exhaustive: a fifth stage breaks the build here
        // exactly as it did before.
        case .browsing, .browsingServers, .choosingLists: self
        case .previewing(let preview, let origin, _):
            .previewing(preview, from: origin, ticked: picked)
        case .choosingBoards(let offer, let origin):
            .choosingBoards(offer, from: origin.ticking(picked))
        }
    }

    /// The server this stage is about, where it is about one.
    ///
    /// **Neither browsing step is about one, and that is a fact rather than a gap.** A reader with
    /// the browser open has not named a host yet — not even at the server list, where the press
    /// that names one also closes the sheet — so a caller asking "is this stage about the server
    /// that just went away" gets the true answer of no.
    var host: String? {
        switch self {
        case .browsing, .browsingServers: nil
        case .previewing(let preview, _, _): preview.host
        case .choosingBoards(let offer, _): offer.host
        case .choosingLists(let choice): choice.host
        }
    }

    /// Which surface draws this stage. **Derived, never stored** — decision 20.
    ///
    /// **Every preview of a server the reader might take is drawn in the page** — decision 38. It
    /// belongs beside the field they typed into, and since the browser fills that field rather than
    /// previewing anything itself, there is no longer a second answer. The detail of a source they
    /// already have is the exception and says why at its own case.
    ///
    /// **No `default:`**, and the `.previewing` cases are split rather than folded: a third origin
    /// has to say where it draws rather than inherit somebody else's answer.
    var surface: JoinSurface {
        switch self {
        case .browsing, .browsingServers: .sheet
        case .previewing(_, .field, _): .pane
        // **The page has no slot for a detail that is not above the list.** `AccountPane` draws
        // its block between the field and the sources, so opening row four's detail inline would
        // push a screenful in above the list and scroll the reader away from the row they
        // pressed. Decision 31, and `DESIGN-R2` §4.1.
        case .previewing(_, .joined, _): .sheet
        case .choosingBoards, .choosingLists: .sheet
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
        case .browsing, .browsingServers: nil
        case .previewing(let preview, .field, _): preview
        // A detail is drawn in the sheet, so the page draws nothing for it.
        case .previewing(_, .joined, _): nil
        case .choosingBoards(_, .preview(let preview, _)): preview
        case .choosingBoards(_, .joined): nil
        case .choosingLists: nil
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
    /// **Neither browsing step admits one, and that is decision 38 turning an answer over.**
    /// `.browsing` used to, because the browser's own rows *were* looks started from inside it.
    /// They are not: a picked server closes the sheet before anything is looked up, so by the time
    /// `look` asks this question there is no stage left to ask about. Answering yes would leave a
    /// second look startable behind a sheet the reader cannot see past — PLAN risk 8 exactly, and
    /// the browser is the only stage that ever needed the exception.
    ///
    /// **No `default:`**, in the house style of `hasTrends` and `canSignIn`.
    var admitsASecondLook: Bool {
        switch self {
        case .browsing, .browsingServers: false
        case .previewing(_, .field, _): true
        // A detail covers the field: the reader cannot see what a second look would replace.
        case .previewing(_, .joined, _): false
        case .choosingBoards, .choosingLists: false
        }
    }
}

/// The one sheet adding a source is done in, at whichever of its four stages the reader is on.
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
    /// How many pixels a point is, so a mark can ask for the drawing made for the size it will
    /// actually be rendered at — `SourceMark.kindMark`'s own rule, and the gate is the pixel
    /// count and never the platform.
    @Environment(\.displayScale) private var displayScale

    @AccessibilityFocusState private var headerFocused: Bool

    private enum Metrics {
        /// A protocol's mark, at **the source row's own constant** rather than a second 24 written
        /// here. `SourceRow.markBase`'s doc records a bare literal being changed to 28 with the
        /// suite still green; this is the same picture of the same kind of thing, so it takes the
        /// same number from the same place.
        static let mark: CGFloat = SourceRow.markBase
    }

    /// The protocols this app can read, in the order the reader meets them.
    ///
    /// **Derived from `SourceJoin.reads` and never written out here** — decision 19, and risk 12's
    /// mitigation applied to a list rather than to a rule. A hand-written list is a second answer
    /// to a question Core already owns: it would go on offering a protocol the day Core stopped
    /// reading one, and the reader would meet `unsupportedKind` after the press instead of a
    /// browser that never offered it. M2 unlocks five forks by moving them across that switch, and
    /// they appear here the same day with nothing edited.
    ///
    /// `ProtocolKind.allCases` order, which puts the Mastodon family first and the two forums
    /// after it. `.unknown` is not read, so it is not offered.
    /// `static let`, because it is a compile-time constant: `reads` is a pure switch over a closed
    /// set and `allCases` does not change at runtime.
    static let protocols: [ProtocolKind] = ProtocolKind.allCases.filter(SourceJoin.reads)

    var body: some View {
        VStack(spacing: 0) {
            header
            ShellRule()
            body(for: session.stage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ShellRule()
            footer
        }
        .background(ShellChrome.page(colorScheme))
        // **Nothing is added at any stage this sheet draws, so a swipe is always a complete
        // cancel.** It used to be held shut on `session.checking`, against a press stranded
        // mid-flight — and no press can be in flight here any more: see
        // `ShellSession.reporting(_:drawnAs:)` for the invariant and the entrances that hold it,
        // and `catalogRow` for the same term dropped for the same reason. Armour that cannot fire
        // is a reader of this file inferring a state the app does not have.
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

    // MARK: - The frame

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            switch session.stage {
            case .browsing:
                titled(L10n.t("join.browse.title"), L10n.t("join.browse.protocols.detail"))
            case .browsingServers(let kind):
                titled(
                    String(format: L10n.t("join.browse.servers.title"), kind.displayName),
                    L10n.t("join.browse.detail")
                )
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
            case .choosingLists(let choice):
                titled(
                    String(format: L10n.t("list.choose.title"), choice.host),
                    L10n.t("list.choose.detail")
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
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($headerFocused)
            Text(detail)
                .shellFont(.meta)
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
            protocolList
        case .browsingServers(let kind):
            servers(of: kind)
        case .previewing(let preview, let origin, _):
            // **The `ScrollView` is the sheet's and not the shared view's.** `AccountPane` is
            // already one scroller and nesting a second inside it is the failure that pane's own
            // comment records: the list squeezed to a sliver at 320pt with nothing to scroll.
            ScrollView { SourcePreviewView(preview: preview, surface: .sheet, origin: origin) }
        case .choosingBoards(let offer, _):
            BoardPickerList(offer: offer, picked: picked)
        case .choosingLists(let choice):
            ListPickerList(offered: choice.offered, picked: pickedLists)
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

    /// The lists ticked, by id — read and written straight through to the stage, as `picked` is.
    private var pickedLists: Binding<Set<String>> {
        Binding(
            get: {
                guard case .choosingLists(let choice) = session.stage else { return [] }
                return choice.ticked
            },
            set: { ticked in
                guard case .choosingLists(var choice) = session.stage else { return }
                choice.ticked = ticked
                session.stage = .choosingLists(choice)
            }
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

    /// The footer's count, where the stage has one.
    ///
    /// **This slot also held the sheet's own progress sentence, and decision 38 took the need for
    /// it away.** A browsed preview's Subscribe used to run with this sheet standing over the
    /// field its errand was reported under, so the sheet needed a waiting site of its own and a
    /// rule (`drawnByARow`) keeping it from firing twice. The browser presses nothing now — it
    /// fills the field and closes — so no errand is ever on the wire while this sheet is up, and a
    /// waiting line here would be a site nothing can reach. See `ShellSession.reporting(_:drawnAs:)`
    /// for where that invariant is stated and what enforces it.
    @ViewBuilder
    private var reading: some View {
        if case .choosingBoards(let offer, _) = session.stage {
            Text(String(
                format: L10n.t("board.choose.count"),
                picked.wrappedValue.count,
                offer.boards.count
            ))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
        } else if case .choosingLists(let choice) = session.stage {
            Text(String(
                format: L10n.t("board.choose.count"), choice.ticked.count, choice.offered.count
            ))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
        }
    }

    /// **By rule rather than by history** — §2.2. What is behind the reader decides the word:
    /// nothing at the protocols, the protocols at a server list, and always the preview at the
    /// boards.
    ///
    /// **Named as a value rather than written straight into the button**, because the one bug
    /// this control has already had was a button calling the wrong method — Back from a preview
    /// called `browse()`, which refuses while a sheet is up, so the button did nothing at all and
    /// every test stayed green. A `View` body is the one place a test cannot reach; the rule and
    /// the press are both reachable here, and both are pinned.
    enum Leading: Equatable {
        case close
        /// Step two of the browser back to step one. **Not the `.backToBrowsing` this replaces**:
        /// that one stepped back from a *preview* into the server list, and decision 38 leaves no
        /// preview with a browser behind it. This one is inside the browser, between its two
        /// steps, and the stage it is offered at is one the old case could never be offered at.
        case backToProtocols
        case backToPreview
        case cancel

        /// The word printed on it.
        var key: String {
            switch self {
            case .close: "join.close"
            case .backToProtocols, .backToPreview: "join.back"
            // Reused rather than duplicated, so the two stages cannot drift in translation.
            case .cancel: "board.choose.cancel"
            }
        }
    }

    /// Which button the reader is looking at. **No `default:`** — a fifth stage has to decide
    /// what is behind it rather than inherit somebody else's answer.
    ///
    /// **A pure function of one value, and that is the whole of what changed here.** The
    /// directory-or-field distinction used to arrive as a second argument fed from a view-local
    /// `@State`, so the rule was pinned and the thing that set it was reachable from no test. The
    /// entrance now travels in the stage, so the stage-shapes give the answers and every one of
    /// them is driven from a test.
    ///
    /// `.previewing(_, .field)` is drawn in the page and has no footer to put a button in; it
    /// still answers, because the rule is about what is behind the reader and not about who is
    /// asking.
    static func leading(for stage: JoinStage?) -> Leading? {
        switch stage {
        case .browsing: .close
        case .browsingServers: .backToProtocols
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
        // A choice about a source already held, so nothing is behind it: Cancel, as a restate.
        case .choosingLists: .cancel
        case nil: nil
        }
    }

    /// What pressing it does. **No `default:`**, and pinned one case at a time: this switch is
    /// the wiring the shipped bug lived in.
    static func press(_ leading: Leading, on session: ShellSession) {
        switch leading {
        case .close, .cancel: session.dismissStage()
        case .backToProtocols: session.backToProtocols()
        case .backToPreview: session.backToPreview()
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let leading = Self.leading(for: session.stage) {
            Button(L10n.t(leading.key)) { Self.press(leading, on: session) }
        }
    }

    /// **No preview draws a Subscribe in this sheet any more, and both origins say so by name.**
    ///
    /// This arm used to carry one — it was the browsed preview's, the only takeable preview this
    /// sheet ever presented. Decision 38 retires it: a chosen server closes the sheet and previews
    /// beside the field, so the only `.previewing` that is still sheet-surfaced is the detail of a
    /// source the reader already has, which has nothing to subscribe to. The button left behind was
    /// a byte-for-byte copy of `AccountPane.previewActions` with no stage left to present it, and
    /// it read as a second live Subscribe on a second surface — the two-presenters failure this
    /// file's docs warn about, sitting in the file that warns about it.
    ///
    /// **Two named arms rather than a `where` clause**, so a third origin has to decide what it
    /// draws here rather than falling into whichever arm it happens to match.
    @ViewBuilder
    private var primary: some View {
        switch session.stage {
        // Drawn in the page, where the block owns Cancel and Subscribe — `AccountPane`. This sheet
        // is not presented for a `.pane` stage at all; the arm exists so the switch is total.
        case .previewing(_, .field, _):
            EmptyView()
        // **A detail has nothing to subscribe to** — the same fact `ShellSession.confirm()` refuses
        // on, where `PreviewOrigin.reporter` is `nil`. Close alone: Remove, Clear and Boards stay
        // on the row, because a second entrance to Remove is the two-presenters failure in a new
        // shape.
        case .previewing(_, .joined, _):
            EmptyView()
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
        // **Not disabled on an empty pick**, unlike boards: reading none of your lists is a real
        // choice — Home is still read — and not a mass unsubscribe from the source.
        case .choosingLists(let choice):
            Button(L10n.t("list.choose.done")) {
                Task { await session.chooseLists(choice.picks) }
            }
            .keyboardShortcut(.defaultAction)
        case .browsing, .browsingServers, nil:
            EmptyView()
        }
    }

    // MARK: - Step one: what this app can read

    private var protocolList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.protocols, id: \.self) { kind in
                    protocolRow(kind)
                    ShellRule()
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// One protocol: its mark and its name, and nothing else.
    ///
    /// **Deliberately the terse row, which is the opposite of the server row below it.** There is
    /// one fact here and the reader already knows it or does not; a figure about a protocol is not
    /// a thing this app can state. Whether a protocol has servers to suggest is *not* drawn either
    /// — pressing it says so in a whole sentence, and a badge saying "none" beside a name is a
    /// refusal in the one place a reader cannot press to find out why.
    private func protocolRow(_ kind: ProtocolKind) -> some View {
        Button {
            session.chooseProtocol(kind)
        } label: {
            HStack(spacing: ShellSpace.step) {
                mark(kind)
                    .frame(width: Metrics.mark, height: Metrics.mark)
                    .foregroundStyle(markInk(kind))
                Text(kind.displayName)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
    }

    /// A protocol's picture: its own mark, or the shape glyph where this repo draws none.
    ///
    /// **`SourceMark.drawing` and not a third copy of it.** Writing the two tiers out here is what
    /// the source row's own comment predicted — and the copy had already dropped
    /// `.symbolVariant`, so this surface would have stopped filling a signed-in glyph while the
    /// other two went on filling it.
    ///
    /// **`signedIn: false`, and it is a statement rather than a default.** A protocol is not a
    /// server: there is nothing here to be signed in to, and `filament` on this row would claim a
    /// relationship with a whole protocol that this app cannot have.
    private func mark(_ kind: ProtocolKind) -> some View {
        SourceMark.drawing(
            kind, shape: DummyItem.shape(of: kind), points: Metrics.mark, scale: displayScale,
            signedIn: false
        )
    }

    /// The mark's ink, **through `SourceMark.ink` and in the row's own two tiers**.
    ///
    /// A drawing is a mark at the head of a pressable row and takes `inkDim`; a shape glyph is
    /// fainter. `SourceRow.markInk` draws exactly this distinction, and a flat `inkDim` here would
    /// have put Discourse's fallback glyph a shade darker in the picker than in the list beside it.
    private func markInk(_ kind: ProtocolKind) -> Color {
        SourceMark.ink(
            signedIn: false,
            quiet: SourceMark.kindMark(kind, pixels: Metrics.mark * displayScale) != nil
                ? ShellChrome.inkDim(colorScheme)
                : ShellChrome.inkFaint(colorScheme),
            scheme: colorScheme
        )
    }

    // MARK: - Step two: that protocol's servers

    @ViewBuilder
    private func servers(of kind: ProtocolKind) -> some View {
        if ServerDirectory.covers(kind) {
            switch session.catalog {
            case .loading:
                // One way of waiting, `ShellType.body` dropped to `meta` with it: a sentence about
                // an errand is read second, whatever surface it is on.
                note { ForumWaiting(line: L10n.t("account.catalog.loading")) }
            case .failed:
                note { Text(L10n.t("account.catalog.failed")) }
            case .empty:
                note { Text(L10n.t("account.catalog.empty")) }
            case .ready(let servers):
                // **Folded once for the list, not once per row.** `session.isAdded` lowercases and
                // scans `sources` linearly, so asked inside the `ForEach` it is O(rows x sources)
                // on every redraw — and this list is the directory whole now that the sheet has no
                // filter, where it used to be a narrowed subset. `AccountPane`'s own comment about
                // hoisting `rows` and `widest` out of its `ForEach` is the precedent.
                let added = Set(session.sources.map(\.host))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(servers) { server in
                            catalogRow(server, added: added.contains(server.domain.lowercased()))
                            ShellRule()
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        } else {
            note { Text(String(format: L10n.t("join.browse.none"), kind.displayName)) }
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .shellFont(.body)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One suggested server: hostname, description, and the three figures — **decision 39**.
    ///
    /// **This is deliberately not the source row, and it must not be "unified" with it later.**
    /// The compact row on the source page is terse because the reader already chose those servers
    /// and can press one for the rest; this row exists to help them *decide which to choose*, and
    /// the description, the language and the two figures are the deciding evidence. They cost no
    /// request — `CatalogServer` carries all of them — and a reader comparing two servers here has
    /// no other way to see the difference. Two rows about the same kind of thing, for two
    /// different errands.
    ///
    /// **Pressing it closes the sheet and fills the field** — decision 38 — so this row draws no
    /// waiting line of its own. It carried one, for the one row of forty the reader had pressed,
    /// because the press used to preview inside this sheet; the press goes to the page now and
    /// answers there.
    private func catalogRow(_ server: CatalogServer, added: Bool) -> some View {
        // **Built once and handed to both readers.** `rowFoot` draws these three and the spoken
        // value says the same three, and each one costs a locale lookup, two bundle lookups and
        // two compact-number formats — so asking twice doubled that for every visible row on every
        // redraw. `AccountPane`'s `let widest = widest` hoist is the same move for the same reason.
        let readings = readings(server)
        return Button {
            Task { await session.pick(server) }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(server.domain)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : server.summary)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
                if !added { rowFoot(readings) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **`added` alone, and `checking` is gone rather than kept as armour.** Nothing is ever on
        // the wire while this sheet is up, so that term could not fire — and a refusal that cannot
        // fire is a reader of this file inferring a state the app does not have. A row that *is*
        // refused says why in its own second line, which is the one thing a refused control here
        // has always had to do.
        .disabled(added)
        .accessibilityLabel(server.domain)
        .accessibilityValue(
            added
                ? L10n.t("account.catalog.added")
                : "\(server.summary), \(readings.joined(separator: ", "))"
        )
    }

    /// The row's own readings.
    ///
    /// Three readings, each one a labelled sentence about the server. They used to be a single
    /// string joined with middle dots, where one of the numbers was labelled with an initialism
    /// and the other was not labelled at all — which is the objection this separation answers, and
    /// the reason a dot-joined line is not the tidier version of it. (`metaLine` *does* dot-join,
    /// and may: it is spoken, where both halves say what they are.)
    private func rowFoot(_ readings: [String]) -> some View {
        HStack(spacing: ShellSpace.pad) {
            ForEach(readings, id: \.self) { reading in
                Text(reading)
            }
        }
        .shellFont(.mark)
        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        .lineLimit(1)
    }

    private func readings(_ server: CatalogServer) -> [String] {
        [
            languageName(server.language),
            String(format: L10n.t("account.catalog.weekly"), L10n.compact(server.weekUsers)),
            String(format: L10n.t("account.catalog.people"), L10n.compact(server.users)),
        ]
    }

    private func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.t("account.catalog.langUnknown") }
        return locale.localizedString(forLanguageCode: trimmed) ?? trimmed
    }

}
