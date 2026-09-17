import FediqoCore
import SwiftUI

/// One server this device reads, and everything the source page says about it.
///
/// **A value the screen is a function of, rather than a view that goes and asks.** Every line the
/// row draws and every word it says out loud is derived by a `static func` on this type, so the
/// decisions are reachable from a test without standing SwiftUI up — which is the failure this
/// milestone has already made twice: a rule that is pure and tested while the wiring that calls it
/// is reachable from nothing.
struct SourceRow: Identifiable, Hashable {
    var id: String { source.host }
    let source: Source
    /// How this protocol is drawn, **through `DummyItem.shape(of:)` and nowhere else**. Derived in
    /// `init` rather than taken as an argument so that no caller can hand a source one shape while
    /// the timeline draws it as another.
    let shape: DummySourceKind
    /// What the host said about itself when it was looked at.
    ///
    /// **Not `Optional`, because `.unasked` is a real answer and nil would be a second spelling of
    /// it.** A source that arrived by some route the reader never previewed — and there will be
    /// such routes — reads `.unasked`, and the row draws the host and its shape, honestly, rather
    /// than a gap where a fact would be.
    let profile: ProfileAnswer
    let canSignIn: Bool

    init(source: Source, profile: ProfileAnswer) {
        self.source = source
        self.shape = DummyItem.shape(of: source.kind)
        self.profile = profile
        self.canSignIn = Self.canSignIn(source.kind)
    }

    /// Whether this protocol has a sign-in for the reader to be offered.
    ///
    /// **No `default:`**, the shape `ShellSession.hasTrends` already takes and for its reason: a
    /// protocol added and not listed here would silently inherit somebody else's answer about a
    /// control it may not have.
    ///
    /// **Absent is not disabled** — decision 4. A control that is permanently grey for nine
    /// sources in ten is worse than a row that does not offer it, so where this is false the row
    /// draws nothing at all. M4 flips a protocol on by adding it to this switch, not by editing a
    /// view: the check belongs to the kind and never to a `kind == .discuz` at a call site.
    static func canSignIn(_ kind: ProtocolKind) -> Bool {
        switch kind {
        // The one protocol this app signs in to. A Discuz! behind a login wall is the case the
        // whole sign-in path was built for, and F2's engine is the only transport that reaches it.
        case .discuz: true
        // Every other protocol this app reads is read signed-out. `HTTPClient` is GET-only until
        // M4, so there is nothing to offer here that would not be a button that cannot work.
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            false
        }
    }

    /// What the server stated about its size, or nothing.
    ///
    /// **Only `.stated` has figures, and the three silences are named rather than swept together.**
    /// `SourcePreviewView.figurePieces` is the one place they are worded, so the preview and the
    /// row say the same numbers in the same words about the same server.
    @MainActor
    static func figures(_ answer: ProfileAnswer, language: DummyLanguage? = nil) -> [String] {
        switch answer {
        case .stated(let profile): SourcePreviewView.figurePieces(profile, language: language)
        case .silent, .unread, .unasked: []
        }
    }

    /// The line that says something was expected and did not arrive, or nothing.
    ///
    /// **`.silent` gets no line here although the preview gives it a paragraph, and that is not an
    /// omission.** The picker's rule — a board that stated nothing at all says so in words — exists
    /// so a row can be *judged* against its neighbours. This row is not for judging, it is for
    /// managing, and it is already judgeable from its host, its protocol, its shape and its boards.
    /// Nothing is expected of a Discuz!, so nothing is missing, and printing "publishes nothing
    /// about itself" on every forum row for ever is noise.
    ///
    /// `.unread` does get one, because there something *was* expected and did not arrive, and a
    /// reader would otherwise wonder why this row is thinner than the one above it.
    ///
    /// **A forum behind a bot filter reads as *we could not read it*, never as *this needs an
    /// account*** — decision 17. That distinction is carried by the answer rather than by this
    /// function: `.challenged` is `.unread(.refused)` because a doorman answered and the forum said
    /// nothing, and a row that turned that into a sentence about the forum's policy would assert
    /// something about a server that may well read fine to a signed-out human.
    static func evidenceKey(_ answer: ProfileAnswer) -> String? {
        switch answer {
        case .unread: "account.source.unread"
        case .stated, .silent, .unasked: nil
        }
    }

    /// The boards the reader picked, counted first so the count survives truncation.
    ///
    /// No plural form: this repo ships no `.stringsdict` and `board.choose.threads` = "%d threads"
    /// sets the precedent. A stated limitation rather than an oversight.
    @MainActor
    static func boardsLine(_ source: Source) -> String? {
        guard !source.boards.isEmpty else { return nil }
        return String(
            format: L10n.t("account.source.boards"),
            source.boards.count,
            source.boards.map(\.name).joined(separator: " · ")
        )
    }

    /// What the whole row says out loud, in one sentence.
    ///
    /// The identity comes from `source.spoken` — **the same key `JoinSheet.spoken` uses**, so the
    /// server a reader previewed and the server in their list are described identically. Then
    /// everything the row actually draws, in the order it draws it, with the board names **whole**:
    /// the visible line is clipped at two lines and a reader who cannot see it is owed the rest.
    @MainActor
    static func spoken(_ row: SourceRow) -> String {
        var said = [String(
            format: L10n.t("source.spoken"),
            row.source.host,
            row.source.kind.displayName,
            DummyItem.shapeWord(row.shape)
        )]
        said += figures(row.profile)
        // Said as well as drawn. §5's list stops at the boards, which would leave the one row that
        // has an evidence line the only row whose spoken sentence is shorter than what is on it.
        if let evidence = evidenceKey(row.profile) { said.append(L10n.t(evidence)) }
        if let boards = boardsLine(row.source) { said.append(boards) }
        return said.joined(separator: ", ")
    }

    /// Whether this protocol's board set is something the reader can re-state.
    ///
    /// **A predicate and not a `kind == .discuz`**, and **no `default:`** — `canSignIn`'s shape and
    /// for its reason. `!source.boards.isEmpty` is sufficient today and is not sufficient for long:
    /// decision 6 leaves open whether Lemmy needs a board picker at all, and a Lemmy with
    /// communities and no picker would draw a control that opens a sheet that cannot exist. Unit 7
    /// answers this here, at the place that decides, rather than inheriting Discuz!'s answer about
    /// a picker Lemmy may not have.
    static func canChangeBoards(_ kind: ProtocolKind) -> Bool {
        switch kind {
        // The one protocol whose boards this app picks between. `SourceJoin.boards(of:)` answers
        // for exactly this case and throws for the rest, so the two switches say one thing.
        case .discuz: true
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            false
        }
    }

    /// The sign-in control's spoken label, by what this device last saw.
    ///
    /// **A toggle and not two controls**, because the reader has one relationship with a forum and
    /// it is either on or off. What "on" means is `ForumSessions.reachedSignIn`'s business, and its
    /// doc comment is where the honesty about an expiring cookie lives.
    ///
    /// Sign in reuses `account.refuse.signin.label` — one key for one act, so the offer under a
    /// refusal and the control on the row cannot drift in translation.
    static func signInLabelKey(reached: Bool) -> String {
        reached ? "account.source.signout.label" : "account.refuse.signin.label"
    }

    /// What this row is waiting on, in words, or nothing where the errand is not this row's.
    ///
    /// **One value decides both which surface speaks and what it says.** A row draws a sentence
    /// exactly when `ProgressOwner` names it, so the page's line and this one cannot both fire and
    /// cannot both stay silent — and the key travels with the owner, so the index read and the
    /// boards the reader picked are two sentences rather than one used twice. The second of those
    /// is the longest wait in the app.
    ///
    /// **Pure and named rather than an expression in the pane's `ForEach`**, which is where the
    /// host comparison used to live: it folded case on both sides against a guarantee three files
    /// away, and a comparison written at a call site is a comparison a fifth call site spells
    /// differently. `ProgressOwner.row` carries the host already folded by the session that set it.
    ///
    /// **Through `ShellSession.reporting` and not through `progress.owner`**, so a row covered by
    /// a sheet draws nothing: ownership and visibility are two questions, and this file has to ask
    /// the same one every other surface asks or the guarantee that exactly one of them speaks is
    /// only true of the three that remembered.
    @MainActor
    static func waitingLine(
        _ progress: ProgressReport?, drawnAs stage: JoinStage?, host: String
    ) -> String? {
        guard let progress,
              ShellSession.reporting(progress, drawnAs: stage) == .row(host: host)
        else { return nil }
        return String(format: L10n.t(progress.key), host)
    }

    /// Which of the three messages Clear asks its question with.
    ///
    /// **Three whole messages and not a stem with clauses glued on**, for `DESIGN.md` §4's stated
    /// reason: a translator cannot reorder a clause appended with `+`, and "the password saved for
    /// it is deleted" must never appear for a Mastodon.
    ///
    /// **The reader is told the password goes, and that is what this function is for.** Clear
    /// reaches `ForumSessions.forget(host:)`, which drops the forum's cookies *and* deletes the
    /// saved password from the Keychain. `PreferencesPane` draws `passwordLine` before its Clear,
    /// so that pane meets `forget`'s own fairness condition — "the row says a password is held
    /// before the button is pressed". An Account row draws no inventory line at all by `DESIGN.md`
    /// §3.6's rule, so until decision 29 this device deleted a Keychain password with nothing on
    /// screen having said one was held. The dialog is that repair, and not ceremony.
    ///
    /// **A `static func` and not an expression in a dialog's `message:` closure**, so the choice
    /// between three sentences is something a test can drive (risk 12).
    static func clearDetailKey(hasPassword: Bool, reachedSignIn: Bool) -> String {
        if hasPassword { return "account.clear.detail.password" }
        if reachedSignIn { return "account.clear.detail.signedout" }
        return "account.clear.detail"
    }
}

extension SourceRow {
    /// The four controls a row carries, in the order it draws them: least to most destructive.
    ///
    /// **An enum and not four call sites**, so that one rule answers for all four and a fifth
    /// control cannot be added with its state decided somewhere else.
    enum Control: String, CaseIterable, Identifiable {
        case signIn
        case boards
        case clear
        case remove

        var id: String { rawValue }
    }

    /// What a control is right now. **Three looks, three meanings**, borrowed from the rail's
    /// `closedMark` doctrine.
    ///
    /// - `struck` — *this protocol has no such thing*. Decision 28, reversing decision 4: a
    ///   reader should be able to see whether a protocol has the capability at all, and the
    ///   control therefore has to say **why** it is refused rather than merely look grey.
    /// - `dimmed` — *not right now*. A stage is up, or something is on the wire.
    /// - `live` — theirs to press.
    ///
    /// Carries no colour, so the decision is drivable from a test with no colour scheme in hand;
    /// the hue is `SourceRowView`'s and is a function of this.
    enum ControlState: Equatable {
        case live
        case dimmed
        case struck
    }

    /// Why a control is struck, unresolved — the key and the one thing it names — or nothing where
    /// it is not struck.
    ///
    /// **Struck-ness and its reason are one fact, and this is the one place either is decided.**
    /// Writing the predicate twice — once to draw the strike and once to pick the sentence — is
    /// how a control comes to be struck with nothing to say, or to hand back a reason while
    /// drawing live. `isStruck` and `struckReason` are both readings of this.
    ///
    /// **No `default:`**, the rule this branch states everywhere it switches over a closed set.
    /// **Pure**, with no localisation in it, so the state a control is drawn in is decidable from
    /// a test with no bundle loaded and costs no lookup per redraw.
    ///
    /// Boards is struck on two different facts and both are real: a protocol with no picker at
    /// all (`canChangeBoards`), and a source with nothing to pick. The second cannot occur today —
    /// `DiscuzBoardJoin.subscribe` returns before `store.subscribe` where nothing read, so a
    /// joined forum always has at least one board — and it is answered here rather than left to
    /// produce a live control over an empty sheet the day some other protocol can. Two keys and
    /// not one, for `DESIGN.md` §4's reason: a translator cannot make one sentence carry both.
    static func struckKey(_ control: Control, source: Source) -> (key: String, names: String)? {
        switch control {
        case .signIn:
            guard !canSignIn(source.kind) else { return nil }
            return ("account.source.signin.struck", source.kind.displayName)
        case .boards:
            if !canChangeBoards(source.kind) {
                return ("account.source.boards.struck", source.kind.displayName)
            }
            if source.boards.isEmpty { return ("account.source.boards.none", source.host) }
            return nil
        // Neither is ever struck: every source this device holds can be emptied and let go of.
        case .clear, .remove:
            return nil
        }
    }

    /// Whether this protocol has no such thing, which is a different fact from *not right now*.
    static func isStruck(_ control: Control, source: Source) -> Bool {
        struckKey(control, source: source) != nil
    }

    /// The one rule that decides how all four controls are drawn.
    ///
    /// **Struck beats dimmed**, because they answer different questions. *Not right now* is about
    /// this moment; *no such thing* is about the protocol, and a protocol does not acquire a
    /// sign-in while a sheet happens to be open.
    ///
    /// **Named rather than written inside a `View` body** — risk 12. Three units have now been
    /// sent back for a rule pinned while the wiring that calls it was reachable from nothing, and
    /// a control's *appearance* is exactly the kind of decision that hides in a modifier.
    static func state(of control: Control, source: Source, actsLive: Bool) -> ControlState {
        if isStruck(control, source: source) { return .struck }
        return actsLive ? .live : .dimmed
    }

    /// Why a struck control is struck, in words, or nothing where it is not.
    ///
    /// **Decision 28 requires this and the tooltip is not enough on its own.** A control that is
    /// silent about its own refusal is the thing this branch has spent four incidents on, so the
    /// sentence is the control's `.help()` *and* its spoken label — one string, so a pointer user
    /// and a VoiceOver reader are told the same thing.
    @MainActor
    static func struckReason(_ control: Control, source: Source) -> String? {
        guard let struck = struckKey(control, source: source) else { return nil }
        return String(format: L10n.t(struck.key), struck.names)
    }

    /// Which control's reason the status line carries after a struck one is pressed.
    ///
    /// **A toggle, so there is a way back.** Pressing a struck control shows its reason; pressing
    /// the same one again takes it away. Pressing a different struck control replaces it, because
    /// the line is a readout and not a stack.
    ///
    /// Pure and named, so the rule is drivable — what a test cannot reach is the `@State` write
    /// itself, which only a rendered tree performs (risk 12).
    static func explaining(
        _ pressed: Control, current: Control?
    ) -> Control? {
        current == pressed ? nil : pressed
    }

    /// What a control is called out loud, and hovered over.
    ///
    /// **The struck sentence replaces the act's own label rather than following it.** "Open
    /// mastodon.social's own sign-in page" is a promise this app cannot keep for a Mastodon, and a
    /// label that made it and then added a reason would be two sentences disagreeing. The struck
    /// sentences name the act themselves — *sign in*, *pick boards* — so nothing is lost.
    @MainActor
    static func controlLabel(_ control: Control, source: Source, signedIn: Bool) -> String {
        if let reason = struckReason(control, source: source) { return reason }
        switch control {
        case .signIn:
            return String(format: L10n.t(signInLabelKey(reached: signedIn)), source.host)
        case .boards:
            return String(format: L10n.t("account.source.boards.change"), source.host)
        // One key, one word, one call — the same Clear as Preferences', because it is one act
        // reached from two questions and not a duplicate of anything.
        case .clear:
            return String(format: L10n.t("prefs.cache.clear.label"), source.host)
        case .remove:
            return String(format: L10n.t("account.source.remove.label"), source.host)
        }
    }
}

extension SourceRow {
    /// Where a row's four controls go.
    ///
    /// **`beneath` and not `stacked`, which is a rename and not a new case.** The old name
    /// described a block of *words* on its own line, and those words are gone: both arrangements
    /// now draw the same four glyphs at the same size, and only their position differs. A name
    /// describing deleted work is how a later reader reconstructs the wrong intent.
    enum Regime: Equatable {
        /// Icons at the trailing edge, on the host line. Only where the words still get half the
        /// row.
        case trailing
        /// The same four icons, on their own line inside the content column, leading-aligned.
        case beneath
    }

    /// Which of the two a row is drawn in.
    ///
    /// **One axis, and the second gate is gone.** It existed to protect *words* in the action row,
    /// and decision 30's ruling deletes those words: both arrangements draw the same four glyphs,
    /// and a glyph has no string length and no type size — `symbolPoints(_:)` caps it below the
    /// 44pt target at every rung. Decision 23 was amended once to say the axis is width; this
    /// finishes that amendment rather than reversing it.
    ///
    /// **Where the gate actually fired, stated in full rather than in the flattering half.** At
    /// HEAD's 368 threshold it fired at `.accessibility1` on *every* page wider than that — a
    /// 430pt iPhone is 398pt of row, which width called trailing and the gate restacked — not
    /// only on an iPad. On the phone that was merely redundant work; on an **iPad** it was
    /// *wrong*, because a 791pt row has room for 196pt of controls at any rung and no reason to
    /// restack. Under the 480 threshold the phone case is `beneath` by width anyway, so the iPad
    /// is the only place the gate would still have spoken — and it would have spoken wrongly.
    ///
    /// Gone with it: `SourceRowView.typeScales`, its `#if os(macOS)`, and the row's
    /// `@Environment(\.dynamicTypeSize)` read. `EmojiText`'s measurement — that macOS scales no
    /// semantic `Font` with `dynamicTypeSize` while the environment still reads `.accessibility1`
    /// — is why that gate had to be told which platform it was on, and nothing now asks.
    static func regime(width: CGFloat) -> Regime {
        // Not measured yet — the first frame, before the list has reported its width.
        //
        // **Behaviourally dead and kept deliberately, and its reason has changed.** It used to say
        // *this layout never clips*. It now says *this layout never crowds*: at 196pt of controls
        // against 254pt of content column in the narrowest real case there is nothing to clip
        // either way, so the safe choice on an unmeasured frame costs nothing at all. Anything at
        // or below zero already fails the comparison below, so this changes no answer; it is here
        // to name the state rather than leave a reader inferring it from an arithmetic accident.
        guard width > 0 else { return .beneath }
        return width < furniture * 2 ? .beneath : .trailing
    }

    /// The smallest a press is allowed to be. **Fixed, not `@ScaledMetric`** — a finger does not
    /// grow with the type size. Scaled from `.callout` it would be 41pt at `.medium`, under the
    /// floor, and 60pt at `.xxxLarge`, which would blow the 176pt both constants are computed
    /// from and make `furniture` and `controlLine` lies.
    static let touch: CGFloat = 44

    /// The glyph gutter at the default rung, and **`furniture`'s first term**.
    ///
    /// **Named rather than written twice**, which is the whole of the fix. It was a bare `20` in
    /// `SourceRowView`'s `@ScaledMetric` and a bare `20` in this constant's comment, so changing
    /// one moved the drawn row and left the threshold behind — QA changed it to 28 and the suite
    /// passed. The row's frame and the constant now read this one symbol.
    static let gutterWidth: CGFloat = 20

    /// The gap before each control after the first, in the order they are drawn.
    ///
    /// **`tight`, then `snug`, then `snug`, and the first gap is the grouping.** Sign in and
    /// Boards are the two acts that change what this device *reads*; Clear and Remove are the two
    /// that take something away. Binding the first pair tighter than the rest says that with a
    /// gap rather than with a rule or a plate.
    ///
    /// **A sequence and not three literals in an `HStack`, because the row and the constant have
    /// to move together.** `SourceRowView.actions` lays these out and `controlLine` sums them, so
    /// a gap re-tokened changes both — which is what the two hand-written `HStack` spacings did
    /// not do. `gaps.count` is one less than `Control.allCases.count`, and the test pins that
    /// rather than leaving a fifth control to trap at its first press.
    static let gaps: [CGFloat] = [ShellSpace.tight, ShellSpace.snug, ShellSpace.snug]

    /// A control glyph's size, with the ceiling that makes the two constants proofs.
    ///
    /// **36pt, and it is `touch - snug` rather than a literal**: a glyph is allowed to grow with
    /// the type until it would reach the edges of the 44pt target it sits in, and then it stops,
    /// leaving `ShellSpace.snug` of the target around it. Without this cap a large-type row would
    /// widen its own control group past 176pt, and `controlLine`'s claim — 196 at every rung, in
    /// every language, on both platforms — would be false exactly where the narrow case lives.
    ///
    /// A `static func` and not an expression in a `View` body, so the ceiling is pinned rather
    /// than trusted (risk 12).
    static func symbolPoints(_ scaled: CGFloat) -> CGFloat {
        min(scaled, touch - ShellSpace.snug)
    }

    /// Everything in a **trailing** row that is not the words: the glyph gutter, the two gaps
    /// either side of the content column, and the control line. 20 + 12 + 12 + 196 = 240.
    /// Threshold = 480.
    ///
    /// **The threshold is twice this, and the rule behind it is "the words get at least half the
    /// row".** Below 480pt the content column would take less of the row than its own furniture
    /// does, and at that point a hostname, an identity line, a figures line and a two-line Chinese
    /// boards list are being asked to live in a gutter.
    ///
    /// **Computed from the row rather than agreed with by hand, which is the correction.** Every
    /// term is now a symbol the drawn row itself reads: `SourceRow.gutterWidth` sets the
    /// glyph's frame, `ShellSpace.step` is the `HStack`'s own spacing, and `controlLine` is
    /// summed from the gaps `SourceRowView.actions` iterates. The previous version was a literal
    /// 240 whose terms lived only in this comment, and two of them were unguarded: the gutter was
    /// a bare `20` written twice, and the drawn gaps were tokens the test happened to name. QA
    /// changed the gutter to 28 and re-tokened a drawn gap, and the suite stayed green both
    /// times. A constant that agrees with the row by hand is unit B's failure one term over.
    ///
    /// **240 and not 184, because decision 30 added a fourth control.** §3.1 refused a fourth icon
    /// on size and the size argument was right; it is now simply paid. **Every row stacks at the
    /// macOS minimum window** — 286pt of row against a 480pt threshold — and the user was shown
    /// that arithmetic and accepted it.
    ///
    /// **It does not vary by control count, and that is the point rather than an approximation.**
    /// Every row draws all four now — decision 28 shows a control this protocol lacks rather than
    /// hiding it — so the count no longer varies at all, and the one threshold that made every row
    /// restack together is now also the only one there could be.
    static let furniture: CGFloat =
        gutterWidth + ShellSpace.step * 2 + controlLine

    /// The control line: every target, and every gap between them. 176 + 4 + 8 + 8 = 196.
    ///
    /// **Summed from the structure the row draws, not stated beside it.** The count is
    /// `Control.allCases`, which `SourceRowView.actions` iterates, and the gaps are
    /// `SourceRow.gaps`, which the same loop lays out — so a control added, a control removed
    /// or a gap re-tokened moves this number and the drawn row together. It cannot be made to
    /// disagree with the row by hand any more; it can only be made to disagree with **196**, which
    /// is what the test pins.
    ///
    /// **This constant is invariant, and that is the whole argument for the `beneath` regime.**
    /// There are no words in it, `SourceRow.touch` is fixed because a finger does not grow
    /// with the type size, the gaps are `ShellSpace` constants, and
    /// `SourceRowView.symbolPoints(_:)` caps the glyph below the target it sits in. So 196 is 196
    /// at every Dynamic Type rung, in all three languages, on both platforms.
    ///
    /// **The narrowest real case, measured rather than estimated.** The macOS minimum window with
    /// the rail open is `520 − 201 − 1 = 318`pt of page; less `ShellSpace.pad` either side that is
    /// 286pt of row; less the glyph gutter and the gap after it, 254pt of content column. **196 ≤
    /// 254, 58pt spare.** At the largest rung the gutter scales to about 33 and leaves 241, so the
    /// spare narrows to 45 and never closes.
    static let controlLine: CGFloat =
        touch * CGFloat(Control.allCases.count) + gaps.reduce(0, +)
}

extension SourceRow {
    /// How the row's **own body** is drawn: the pointer's wash, or nothing at all.
    ///
    /// **`RowActionState`'s shape, and it is the only shape that closes this.** The row's body has
    /// no glyph, no plate and no tint, so the hover wash is the whole of what says *this row is
    /// pressable* — and a `.disabled` on a `.buttonStyle(.plain)` supplies no dimming of its own,
    /// which is the S1 pattern this branch has shipped four times. There is nothing here to
    /// remember to dim; there is a colour that must be unreachable when the press is refused, and
    /// it is reachable only from `.live`.
    enum RowPress: Equatable {
        /// Theirs to press. Carries the wash where the pointer is on it, and nothing where it is
        /// not — the same case, because a pointer leaving a row does not make it unpressable.
        case live(Color?)
        /// **Not right now.** A stage is up, or something is on the wire. No wash exists here to
        /// be given.
        case inert

        /// What the row's background takes. `nil` is no wash rather than a clear one, so the
        /// caller draws nothing rather than drawing an invisible thing.
        ///
        /// **Do not collapse this type into a plain `Color?`.** The `Optional` would then mean two
        /// things — *no pointer on a live row* and *this row cannot be pressed* — and the second
        /// is the one that must not be spellable alongside a colour. That collapse is the S1
        /// pattern being reintroduced in the file that was written to close it.
        var wash: Color? {
            switch self {
            case .live(let wash): wash
            case .inert: nil
            }
        }
    }

    /// Whether the row's own press is live, and what the pointer does about it.
    ///
    /// **The same `actsLive` the four controls read** — `ShellSession.rowActsLive(at:checking:)`,
    /// one rule and now four ends (`DESIGN-R2` §10.1). Opening a detail replaces `session.stage`,
    /// so a row pressed while an inline preview is open would delete a screen the reader is
    /// part-way through reading; that is the same argument the boards control is gated on, and it
    /// must be the same predicate rather than a second one.
    static func press(hovering: Bool, actsLive: Bool, scheme: ColorScheme) -> RowPress {
        guard actsLive else { return .inert }
        // `RailButton.rowFill`'s own idiom, which is this house's existing statement of *this row
        // is pressable*. On iOS nothing hovers and this is always the no-wash case, which is
        // right: a finger has no hover state and needs none.
        return .live(hovering ? ShellChrome.hoverFill(scheme) : nil)
    }
}

/// One row of the source list, in one of two arrangements of the same four controls.
///
/// **Four glyphs at the trailing edge where the words still get half the row, the same four on
/// their own line inside the content column where they do not.** `DESIGN.md` §3.3's word row is
/// replaced outright: its measurement survives as the reason `SourceRow.furniture` exists, and
/// what it measured was *width against words* — it never argued the controls must **be** words.
/// Widening the window therefore moves four marks and regroups nothing, and a reader who never
/// widens still learns the same four marks.
///
/// **The regime is decided by `SourceRow.regime(width:)`, which is pure and is driven across both
/// arrangements, the unmeasured first frame and the boundary by `SourcePageTests`.** So is this
/// view's own `regime` — see that property. What no test reaches is `AccountPane`'s
/// `onGeometryChange`, which is SwiftUI's own measurement, and this project has no UI test target
/// (risk 12). That is the seam, named here rather than left to be discovered.
///
/// **Four unlabelled glyphs on an iPhone are only safe because none of the four does anything
/// irreversible on first press.** `.help()` is a no-op on iOS, so a sighted pointer user there has
/// no word at all for these marks until they press one — and what makes that acceptable is that
/// Remove asks first, and, since decision 29, so does Clear. Clear only became one of those
/// through that decision: before it, one unlabelled press deleted a Keychain password and signed
/// the reader out of a forum with nothing on screen having said either would happen. **Whoever is
/// later tempted to drop a confirmation to save a tap is removing the thing that makes this row's
/// icons legitimate.**
///
/// **The words are a fifth press now** — decision 31 — and it is the one press on this row that
/// cannot cost the reader anything: it opens a sheet built from what this session already holds,
/// asks no server anything, and Close puts it away. It is told apart from the four marks by
/// position and by routing rather than by a chevron: the body is text on the page's ground, the
/// marks are controls at the trailing edge or in the block, and they are siblings rather than
/// children so SwiftUI routes a press to the innermost with no ambiguity to resolve. **The cost,
/// named: five tab stops per row on macOS**, thirty for six sources. The words are first in each
/// row, so Tab-then-Space still reaches every row's detail in six presses.
struct SourceRowView: View {
    let row: SourceRow
    /// Whether this device last saw a sign-in reached here. Passed in rather than read from the
    /// session inside the body, so the row stays a function of its inputs.
    let signedIn: Bool
    /// What the list measured for a row's width. **Zero until it has been measured**, which is the
    /// first frame and is a state `regime` names rather than guesses at.
    let width: CGFloat
    /// Whether this row's controls may be pressed at all right now — one rule, read from
    /// `ShellSession.rowActsLive(at:checking:)`, so what is drawn and what the press does cannot
    /// disagree. State B8, closed rather than deferred.
    let actsLive: Bool
    /// What this row is waiting on, in words, or nothing.
    ///
    /// **The sentence and not a flag**, because the two phases a row reports are two errands: the
    /// forum's index, and the boards the reader picked one request at a time. It was one `Bool`
    /// and one hard-coded key, so both said "Reading %@'s boards…" and the longer of the two —
    /// which is not the index — said the wrong thing. Chosen by `SourceRow.waitingLine(_:host:)`,
    /// which is pure and pinned, so the row stays a function of its inputs and the choice is not
    /// made in a `View` body.
    let waiting: String?
    /// The last boards refusal this session holds, whichever row it belongs to. Compared against
    /// this row's host here rather than filtered by the caller, so the row stays a function of its
    /// inputs and the comparison is in one place.
    let refusal: (host: String, key: String)?

    /// Which struck control the reader has asked about, or nothing.
    ///
    /// **Row-local and ephemeral**, because it is an answer to a press and not a fact about the
    /// server. The rule that moves it is `SourceRow.explaining(_:current:)`, which is pure and
    /// pinned; **this write is the seam a test cannot reach**, for `onGeometryChange`'s reason —
    /// `@State` outside a rendered tree hands back its initial value and keeps it.
    @State private var explaining: SourceRow.Control?
    /// Whether the pointer is on this row. **`RailButton`'s own `@State hovering`**, and like it a
    /// seam no test reaches — `.onHover` is delivered by a rendered tree. What a test does reach
    /// is `SourceRow.press(hovering:actsLive:scheme:)`, which this only feeds.
    @State private var hovering = false
    let signIn: () -> Void
    let clear: () -> Void
    let remove: () -> Void
    let changeBoards: () -> Void
    /// The row's own press: it opens what this server says about itself — decision 31.
    let open: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The width of the glyph's gutter, so every row's text starts on the same line however big
    /// the type is. **The width only** — the symbol itself scales through its own font below,
    /// because a `@ScaledMetric` frame around a symbol that does not scale with it is a glyph that
    /// drifts off the baseline it is aligned to as the type grows.
    @ScaledMetric(relativeTo: .callout) private var gutter: CGFloat = SourceRow.gutterWidth
    /// Half a callout's cap height, scaling with it, so the trailing group's anchor holds across
    /// the rungs the trailing regime exists in. See `actionsTrailing`.
    @ScaledMetric(relativeTo: .callout) private var capHalf: CGFloat = 6
    /// A control glyph's drawn size, before the ceiling. Scaled so the marks grow with the words
    /// beside them; capped by `symbolPoints(_:)` so they can never grow out of their targets.
    @ScaledMetric(relativeTo: .callout) private var glyph: CGFloat = 24

    /// Which regime this row is drawn in.
    ///
    /// **Internal, not private, and pinned** — the habit `busy` and `AccountPane.actionsLive(at:)`
    /// established. A test reads this property and proves that `width` reaches the rule; a
    /// hardcoded width here dies against it. What stays genuinely unreachable is `AccountPane`'s
    /// `onGeometryChange`: nothing verifies that the number arriving in `width` is the row's
    /// width, and nothing can without a UI test target (risk 12).
    var regime: SourceRow.Regime {
        SourceRow.regime(width: width)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            Image(systemName: SourceMark.symbol(row.shape))
                // The host line's own type, so the symbol and the line it is aligned with grow
                // together and `.firstTextBaseline` keeps meaning what it says.
                .font(ShellType.name)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .frame(width: gutter)
                // A scanning aid across a list, not information. The spoken sentence names the
                // shape in words, so a reader who cannot see this loses nothing.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                // **The words are the press, and the four marks are siblings of it.** That is the
                // standard list idiom — the row opens, the accessory acts — and it needs no
                // chevron to say so: a chevron would be a fifth mark in a row that has four, and
                // the hover wash plus a pointer is the platform's answer on macOS while iOS needs
                // none. The controls are sibling `Button`s rather than children, so SwiftUI routes
                // a press to the innermost and there is no ambiguity to resolve; and the row's
                // 12pt vertical padding is outside this, so the gap between rows is dead, which is
                // right.
                Button(action: open) {
                    // The whole width of the words is the press, not the glyphs of the text —
                    // `BoardPickerList.row(_:)` states the same rule, and without it a reader
                    // aiming at the gap beside a short hostname presses nothing.
                    said.contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(pressed == .inert)
                    .help(String(format: L10n.t("account.source.open"), row.source.host))
                    .accessibilityHint(Text(L10n.t("account.source.open.hint")))
                // **Between the words and the controls, and not below the controls.** These two
                // lines are about this row's boards, and the boards line they answer is directly
                // above them; under the control line they would be a footnote to four marks.
                //
                // **A sibling of `said` and not inside it.** `said`'s spoken label is composed by
                // `SourceRow.spoken(_:)` from the source, so anything folded into that element is
                // silently dropped from what is read out. These two sentences are about an errand
                // rather than about the server, they come and go, and they are owed aloud.
                boardsStatus
                // **Inside the content column, leading-aligned, one step further down the scale.**
                // The `VStack` already spaces by `tight`, so this extra `tight` makes the gap 8 —
                // `ShellSpace.snug`, one rung up — which says *a different kind of thing* without
                // a rule or a plate. The cost, stated: a row grows about 52pt here. `AccountPane`
                // scrolls as one thing by a deliberate decision, so that is scroll and not squeeze.
                if regime == .beneath {
                    actions.padding(.top, ShellSpace.tight)
                }
            }
            // **No `Spacer` between the two, in either regime.** `said` already claims the row
            // with `maxWidth: .infinity`, so it is the one flexible element and the icons are
            // pushed to the trailing edge by it. A `Spacer(minLength: ShellSpace.step)` here would
            // put a third gap between them — 12 either side of a spacer of at least 12 — and
            // `SourceRow.furniture` counts two gaps of 12, so the threshold would be computed from
            // a row this one is not. Two flexible siblings in one `HStack` also share the slack
            // rather than giving it to the words, which is the opposite of what the threshold is
            // protecting.
            if regime == .trailing { actionsTrailing }
        }
        .padding(.vertical, ShellSpace.step)
        // **The wash is under the whole row including its controls, and that is correct**: the
        // wash says *this row*, and the four marks are in this row. Drawn behind the padding so
        // the lit area is the row and not only its words.
        .background { if let wash = pressed.wash { wash } }
        .onHover { hovering = $0 }
    }

    /// Whether this row's own press is live, and what the pointer draws.
    ///
    /// **Internal, not private, and pinned** — the habit `regime` and `state(_:)` established, and
    /// the reason risk 12 exists: a rule that is right and a view that asks it the wrong question
    /// is this branch's recurring defect, and a style decided in a `View` body is reachable from
    /// nothing.
    var pressed: SourceRow.RowPress {
        SourceRow.press(hovering: hovering, actsLive: actsLive, scheme: colorScheme)
    }

    /// Everything the row states about the server, as one accessibility element — **and, since
    /// decision 31, the label of the row's own press**.
    ///
    /// Being a button's label changes nothing here: the element is still the combined facts with
    /// `spoken(_:)` as its label, and the `Button` adds the `.isButton` trait and the hint over
    /// it. What it must not become is the *parent* of the four controls — see below.
    private var said: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(row.source.host)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            identity
            if let figures = SourcePreviewView.dotted(SourceRow.figures(row.profile)) {
                figures
                    .font(ShellType.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let evidence = SourceRow.evidenceKey(row.profile) {
                Text(L10n.t(evidence))
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // **Back inside the combined element, and plain again — no plate, no fill, no
            // radius.** Decision 30 makes the boards a trailing control, so the line stops being
            // the affordance and returns to what `DESIGN.md` §3.3 specified: the count leading so
            // it survives truncation, clipped at two lines. `ShellChrome.well` leaves this pane
            // entirely with it. The whole list is said out loud by `SourceRow.spoken(_:)`, which
            // composes from the source and so carries the names untruncated.
            if let boards = SourceRow.boardsLine(row.source) {
                Text(boards)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **Combined, and the four controls are deliberately not inside it.** A row collapsed
        // with `children: .ignore` swallows its buttons' activation and leaves a keyboard-only
        // reader with no way to act — `PreferencesPane` records shipping that defect twice. So the
        // stated facts become one element and all four controls stay siblings of it.
        //
        // **`.combine` and never `.ignore`, which matters more now that this is a button's
        // label**, not less: `.ignore` on an element that is itself pressable is the same defect
        // with a press attached.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SourceRow.spoken(row))
    }

    /// What this row's boards are doing, or why the last press about them came to nothing.
    ///
    /// **The plate is gone and these two lines had to go somewhere.** Decision 30 does not only
    /// move a control: reversing `DESIGN-TAIL` §3.1 deletes the surface the restate's progress was
    /// drawn *inside* and its refusal *under*. Both land here, in the content column, under the
    /// boards line they are about — which keeps `session.boardsRefusal`'s whole reason for
    /// existing intact. The page's own refusal sentence lives under the field, and a reader who
    /// pressed a control in row four of six is 900pt away from it.
    ///
    /// **The height changes under the press now, and that is the cost of the ruling.** The plate
    /// swapped its words in place; a sibling line appears. It is one line in a row that is already
    /// three or four, and the alternative was keeping a plate that no longer has a press in it.
    @ViewBuilder
    private var boardsStatus: some View {
        if let waiting {
            ForumWaiting(line: waiting)
        }
        // The reason a struck control could not give on a phone, asked for and answered here.
        if let explaining, let reason = SourceRow.struckReason(explaining, source: row.source) {
            Text(reason)
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let refusal, refusal.host == row.source.host {
            Text(String(format: L10n.t(refusal.key), row.source.host))
                .font(ShellType.mark)
                // **Not `alarm`.** That colour is spent on the line that says a host was not added
                // and why; this host was added. Two of this row's glyphs are alarm-coloured now,
                // which is what keeps the distinction readable: alarm on a glyph is a control,
                // alarm on words is a report.
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `protocol · shape`, two self-describing halves, so the middle dot is safe here.
    private var identity: some View {
        (Text(row.source.kind.displayName)
            + Text(verbatim: " · ")
            + Text(DummyItem.shapeWord(row.shape)))
            .font(ShellType.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The four controls, at the trailing edge, anchored to the host line.
    ///
    /// **Anchored to the host line and not to the column's centre.** The leading shape glyph
    /// already sits on that baseline, so this gives the row one rule running its full width —
    /// glyph, host, controls — with everything the server states hanging beneath it. A centred
    /// group wobbles instead: a Mastodon row is three lines, a Discuz! four, and a Chinese boards
    /// line that wraps makes it five, so the icons would sit at a different height on every row of
    /// a list that is scanned down its trailing edge.
    ///
    /// **The guide is the correction, and it is the one thing here nobody has rendered.** A
    /// `frame(minHeight: 44)` around a symbol may report its first text baseline from the frame
    /// rather than from the symbol, which would hoist the group about 19pt above the row's top.
    /// Mapping the group's own centre onto the host line's optical centre says what is meant
    /// whichever it does. Listed in DESIGN-TAIL §6.1 — if it is wrong the icons sit visibly off
    /// the hostname, and no test in this repository can see that.
    private var actionsTrailing: some View {
        // Read out before the closure: `alignmentGuide`'s is `@Sendable` and a `@ScaledMetric` is
        // main-actor isolated, so the number crosses rather than the property.
        let anchor = capHalf
        return actions
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + anchor }
    }

    /// The four marks themselves, in one order and with one set of gaps, so that widening the
    /// window moves them and regroups nothing.
    ///
    /// **Iterated from `SourceRow.Control.allCases` and `gaps`, which is what makes
    /// `SourceRow.controlLine` a proof rather than a claim.** Written as nested `HStack`s with
    /// literal spacings, the drawn group and the constant agreed only by hand: QA re-tokened one
    /// gap, the real group became 200pt, and `controlLine == 196` became a lie under a green
    /// suite. Laid out from the same two symbols the constant sums, a control added or removed
    /// and a gap changed all move both at once.
    ///
    /// The gap is leading padding on every control after the first rather than `HStack` spacing,
    /// because spacing is a number the constant cannot see and padding is one it can.
    private var actions: some View {
        HStack(spacing: 0) {
            ForEach(Array(SourceRow.Control.allCases.enumerated()), id: \.element) { index, control in
                icon(control)
                    .padding(.leading, index > 0 ? SourceRow.gaps[index - 1] : 0)
            }
        }
    }

    /// Whether pressing this control explains it instead of performing it.
    ///
    /// **A struck control stays tappable, and that is decision 28 delivered rather than claimed.**
    /// `.help()` is a no-op on iOS, so on a phone the strike was the whole message and the reason
    /// was reachable only by VoiceOver — a control silent about its own refusal, which is the
    /// thing decision 28 exists to forbid. **The tap exists because a strike cannot explain itself
    /// without a pointer.** It puts the reason in the row's status line, the sibling the waiting
    /// and refusal sentences already use, so it borrows a vocabulary the row has and invents no
    /// toast, no popover and no layout.
    ///
    /// The act itself is unreachable from a struck control by construction: `icon(_:)` hands the
    /// button the explaining closure instead of the acting one, so there is no guard to forget.
    static func explains(_ state: RowActionState) -> Bool { state == .struck }

    /// One control, drawn from the one rule that decides all four.
    ///
    /// Order is least to most destructive, and **every one of them is drawn on every row** —
    /// decision 28, reversing decision 4: a reader should be able to see whether a protocol has
    /// the capability at all, so what a protocol lacks is struck rather than absent.
    private func icon(_ control: SourceRow.Control) -> some View {
        // **One symbol and a variant, not two controls** — the reader has one relationship with a
        // forum and it is either on or off. `SourceMarkRow` spells that same relationship the same
        // way, so the masthead and the row agree rather than collide. Sign in is the only control
        // that has an *on*, and the fill and the `.isSelected` trait are the same fact twice: one
        // for a reader who can see it and one for a reader who cannot.
        let on = control == .signIn && signedIn
        let drawn = state(control)
        return RowActionButton(
            symbol: Self.symbol(control),
            variant: on ? .fill : .none,
            state: drawn,
            points: SourceRow.symbolPoints(glyph),
            label: SourceRow.controlLabel(control, source: row.source, signedIn: signedIn),
            selected: on,
            action: Self.explains(drawn)
                ? { explaining = SourceRow.explaining(control, current: explaining) }
                : press(control)
        )
    }

    /// The glyph each act is drawn with.
    ///
    /// **`eraser` and not a second `trash` for Clear.** Clear empties what this device is holding,
    /// which is not a deletion of anything the reader picked — it says "wipe this" without saying
    /// "throw this away", and the two cannot be confused at this size even though both now carry
    /// the same hue.
    private static func symbol(_ control: SourceRow.Control) -> String {
        switch control {
        case .signIn: "person.crop.circle"
        case .boards: "checklist"
        case .clear: "eraser"
        case .remove: "trash"
        }
    }

    /// What this control looks like right now: `SourceRow.state(of:source:actsLive:)`'s answer,
    /// with the hue a live one carries attached.
    ///
    /// **`alarm` on Clear as well as Remove is decision 29 and it is a deliberate overstatement.**
    /// Clear is the one act of the four that is not a removal, and the user has chosen to draw it
    /// as one because of what it actually reaches — the forum's cookies and a saved Keychain
    /// password. The dialog is where that is said exactly; the row says only *this takes something
    /// away*.
    ///
    /// **`filament` on a signed-in sign-in** is the token's own doc: what a mark turns once the
    /// reader has switched it on. The one stateful control on the row, and so the only one that
    /// changes hue without being pressed.
    ///
    /// **Internal rather than private so a test can read it** — the habit `regime` and
    /// `AccountPane.actionsLive(at:)` established, and the reason risk 12 exists. A rule that is
    /// right and a view that asks it the wrong question is this branch's recurring defect, and a
    /// mapping written in a `View` body is reachable from nothing.
    func state(_ control: SourceRow.Control) -> RowActionState {
        switch SourceRow.state(of: control, source: row.source, actsLive: actsLive) {
        case .struck: return .struck
        case .dimmed: return .dimmed
        case .live:
            switch control {
            case .signIn:
                return .live(
                    signedIn
                        ? ShellChrome.filament(colorScheme)
                        : ShellChrome.inkDim(colorScheme)
                )
            case .boards: return .live(ShellChrome.inkDim(colorScheme))
            case .clear, .remove: return .live(ShellChrome.alarm(colorScheme))
            }
        }
    }

    private func press(_ control: SourceRow.Control) -> () -> Void {
        switch control {
        case .signIn: signIn
        case .boards: changeBoards
        case .clear: clear
        case .remove: remove
        }
    }
}

/// How one of the row's four controls is drawn. **The tint and the strike are both functions of
/// this**, which is what closes the trap the previous version of this type predicted about itself.
///
/// That trap was real and this branch shipped it twice: `.buttonStyle(.plain)` supplies no dimming
/// of its own, and an explicit `.foregroundStyle` overrides the one `.disabled` would supply — so
/// a refused control looked exactly as pressable as a live one. A colour that can only arrive
/// inside `.live` is a colour that cannot be set on a control that is not.
enum RowActionState: Equatable {
    /// Theirs to press, in the hue this act carries.
    case live(Color)
    /// **Not right now.** A stage is up, or something is on the wire.
    case dimmed
    /// **This protocol has no such thing.** Decision 28.
    case struck
}

/// One of the row's four controls.
///
/// **`DummyMarkButton`'s shape, because this house already draws bare control glyphs on every
/// timeline row.** `DESIGN.md` §0's "glyphs are rare" is about glyphs that *state* something — a
/// shape mark, the preview's lock — and a control glyph is a different category with its own
/// precedent here.
///
/// **`.help()` is not optional on any of them**, and where the control is struck the help text and
/// the spoken label are both the *reason* — decision 28's requirement that a refused control say
/// why, rather than being silent about its own refusal.
///
/// `minWidth`/`minHeight` rather than a fixed frame, so the target is a floor and not a cage.
private struct RowActionButton: View {
    let symbol: String
    let variant: SymbolVariants
    let state: RowActionState
    /// Capped by `SourceRowView.symbolPoints(_:)` before it arrives, which is what keeps the
    /// control group 196pt wide at every Dynamic Type rung.
    let points: CGFloat
    /// Already host-bearing or reason-bearing, and used for both the tooltip and the spoken
    /// label — one string, so the two cannot come to say different things about the same press.
    let label: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: points))
                .symbolVariant(variant)
                .symbolRenderingMode(.hierarchical)
                .overlay { strike }
                .frame(minWidth: SourceRow.touch, minHeight: SourceRow.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .disabled(refusesPress)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// **Dimmed alone refuses the press, and struck deliberately does not.** A dimmed control is
    /// *not right now* and there is nothing to say about it that the reader cannot see. A struck
    /// one is *no such thing here*, and on a platform with no tooltip the only way it can say so
    /// is to be pressed — `SourceRowView.explains(_:)` holds that argument, and hands this button
    /// a closure that explains rather than acts, so what a struck press reaches is not the act.
    private var refusesPress: Bool { state == .dimmed }

    private var tint: Color {
        switch state {
        case .live(let hue): hue
        // **Two looks, two meanings, and both of them are `inkFaint`.** The strike is what tells
        // them apart, which is the rail's `closedMark` doctrine: a line through a mark says *there
        // is no such thing here*, and quiet ink alone says *not now*.
        case .dimmed, .struck: ShellChrome.inkFaint(colorScheme)
        }
    }

    /// `RailButton.closedMark`'s two capsules, with the under-capsule recoloured.
    ///
    /// The rail draws its lower capsule in `ShellChrome.rail` because that is the ground a rail
    /// button sits on; a source row sits on `page`. The capsule is a gap cut through the glyph so
    /// the strike reads as one line rather than as a mark laid over a mark, and a gap is only a
    /// gap if it is the colour of what is behind it.
    @ViewBuilder
    private var strike: some View {
        if state == .struck {
            ZStack {
                capsule(ShellChrome.page(colorScheme), thickness: ShellSpace.tight)
                capsule(ShellChrome.inkFaint(colorScheme), thickness: ShellSpace.hair * 1.5)
            }
            .rotationEffect(.degrees(-45))
            .accessibilityHidden(true)
        }
    }

    private func capsule(_ color: Color, thickness: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: points * 1.2, height: thickness)
    }
}
