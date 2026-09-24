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
    /// Whether this device holds a sign-in for this source — what decides whether it offers lists.
    let signedIn: Bool
    /// What may be done on this source (#69): read, read and write, read only because the protocol
    /// has no writing at all, or a write the source has turned away.
    ///
    /// **Handed in rather than looked up**, because two of the three facts that decide it are the
    /// session's — what the sign-in bought, and what the source has refused since — and a row that
    /// went and asked for them would be a second derivation of an answer
    /// `MastodonSessions.writing(host:kind:)` already gives.
    let writing: SourceWriting

    /// **`writing` left out is not a second derivation but the same one with nothing to carry**:
    /// `SourceWriting.of` is asked with no sign-in and no refusal, which is the honest answer for a
    /// source this device holds neither for — a forum reads only whatever anybody agreed, and a
    /// signed-out microblog reads.
    init(
        source: Source, profile: ProfileAnswer, signedIn: Bool = false,
        writing: SourceWriting? = nil
    ) {
        self.source = source
        self.shape = DummyItem.shape(of: source.kind)
        self.profile = profile
        self.canSignIn = Self.canSignIn(source.kind)
        self.signedIn = signedIn
        self.writing = writing ?? SourceWriting.of(kind: source.kind, grant: nil, refused: false)
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
        // A Discuz! behind a login wall is the case the forum sign-in path was built for, and
        // F2's engine is the only transport that reaches it.
        case .discuz: true
        // Signed in on the server's own page (#24), for reading and — where the reader said so
        // (#69) — for writing. Accepted on Mastodon alone.
        case .mastodon: true
        // Every other protocol this app reads is read signed-out. Pleroma, Akkoma and GoToSocial
        // speak Mastodon's API but are not accepted for its sign-in yet.
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
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

    /// What may be done on this source, in the reader's own words (#69).
    ///
    /// **A word on every row and not a word on the interesting rows.** A statement that appears
    /// only where something is unusual is a statement a reader has to know the absence of, and the
    /// row is the only surface that names a source one at a time. There are four words and no
    /// silence, so no row has to be read by what is missing from it.
    ///
    /// **`never` says only "read only" and the footer legend says why.** The reason is about the
    /// protocol and is the same reason on every forum row for ever; said per row it is the noise
    /// `evidenceKey` refuses for `.silent`, and said once for the list it is a fact a reader reads
    /// when they first wonder.
    ///
    /// **No `default:`**, this file's rule everywhere it switches over a closed set.
    static func writingKey(_ writing: SourceWriting) -> String {
        switch writing {
        case .never: "account.source.writing.never"
        case .reads: "account.source.writing.read"
        case .writes: "account.source.writing.write"
        case .refused: "account.source.writing.refused"
        }
    }

    /// Whether a sign-in here has a writing question to put to the reader first (#69).
    ///
    /// **Read off the row's own `writing` and not from the protocol a second time**: `.never` is
    /// exactly "this protocol cannot write", the row is already holding that answer, and a
    /// `canWrite(source.kind)` at the press site would be the `kind == .discuz` at a call site
    /// `canSignIn`'s own doc forbids.
    var asksWriting: Bool { writing != .never }

    /// Whether the writing word is the one a reader is meant to notice.
    ///
    /// **Only a refusal.** The other three are standing facts about a source and are drawn as
    /// quietly as the footer legend that explains them; a row that has just had a write turned
    /// away is reporting something that happened, and it is drawn one ink louder. Not `alarm` —
    /// that is spent on a host that was not added, and `rowStatus` already declines it for the
    /// same reason.
    static func marksWriting(_ writing: SourceWriting) -> Bool { writing == .refused }

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
        // Straight after the identity and before the figures: it is the second thing the row draws
        // and it is what decides whether a press on this source can ever write, so it is not left
        // to the end of a sentence a reader may stop listening to.
        said.append(L10n.t(writingKey(row.writing)))
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

    /// Whether this protocol has lists a signed-in reader chooses between (#25). **No `default:`**,
    /// `canChangeBoards`' shape: `MastodonAccount` reads Mastodon's lists and nothing else's.
    static func canChooseLists(_ kind: ProtocolKind) -> Bool {
        switch kind {
        case .mastodon: true
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .discourse, .discuz, .unknown:
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
    /// saved password from the Keychain. `UsagePane` draws `passwordLine` before its Clear,
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
    /// The controls a row can carry, in the order it draws them: least to most destructive.
    ///
    /// **An enum and not four call sites**, so that one rule answers for all of them and a fifth
    /// control cannot be added with its state decided somewhere else.
    ///
    /// **The declared order is load-bearing and is not alphabetical.** Which controls a row draws
    /// varies by protocol now (decision 33), and `controls(of:)` filters this list rather than
    /// building its own — so `[clear, remove]` is always the *suffix*, and a reader scanning the
    /// trailing edge of the list finds Clear and Remove in the same two columns on every row
    /// however many marks the row above has. Reordering this enum to put Remove first would
    /// destroy that silently, which is why it is written down here rather than left to be noticed.
    enum Control: String, CaseIterable, Identifiable {
        case signIn
        case boards
        /// A signed-in Mastodon's lists (#25) — the boards control's counterpart, never beside it.
        case lists
        case clear
        case remove

        var id: String { rawValue }

        /// The gap drawn before this control when it follows another. The first drawn control has
        /// none, whichever control that turns out to be.
        ///
        /// **A property and not a sequence, because decision 33 made the set variable.** The old
        /// `SourceRow.gaps` was positional and correct only while every row drew all four: a
        /// Mastodon drawing `[clear, remove]` would have read `gaps[0]` — `tight` — for a pair the
        /// design deliberately separates. An index into a filtered list is risk 14's shape with no
        /// switch in it for the compiler to find.
        ///
        /// **`tight` binds Boards to Sign in**: those are the two acts that change what this
        /// device *reads*, and binding them closer than the rest says so with a gap rather than
        /// with a rule or a plate. Remove is deliberately **not** tight against Clear — two red
        /// acts one mis-tap apart is the arrangement that ruling exists to avoid.
        ///
        /// **No `default:`.** A fifth control answers here or it does not compile — which is what
        /// `gaps.count == allCases.count - 1` used to catch and can no longer.
        var lead: CGFloat {
            switch self {
            // Never the follower today, since it is first whenever it is drawn at all; `snug` is
            // the neutral answer for the day a control is added before it.
            case .signIn: ShellSpace.snug
            case .boards: ShellSpace.tight
            // Bound to Sign in as Boards is, and for its reason: it changes what this device reads.
            case .lists: ShellSpace.tight
            case .clear: ShellSpace.snug
            case .remove: ShellSpace.snug
            }
        }
    }

    /// Which controls this source actually carries — decision 33, which withdraws decision 28 and
    /// restores decision 4: a control for a protocol that has none is **absent**, not struck.
    ///
    /// **A function of the source and not of the protocol alone**, because `.boards` is refused on
    /// two different facts and one of them is per-source: a protocol with no picker at all, and a
    /// source with nothing to pick. The second cannot occur today — `DiscuzBoardJoin.subscribe`
    /// returns before `store.subscribe` where nothing read — and it is answered here rather than
    /// left to produce a live control over an empty sheet the day some other protocol can.
    ///
    /// **Adds no switch over `ProtocolKind`**, and that is deliberate: `canSignIn` and
    /// `canChangeBoards` are the two that decide, they are already exhaustive and already pinned,
    /// and a third table saying the same thing is a third place to forget a protocol.
    ///
    /// The result is a filter of `Control.allCases`, so it keeps the declared order and with it the
    /// suffix property `Control` documents.
    static func controls(of source: Source, signedIn: Bool = false) -> [Control] {
        Control.allCases.filter { control in
            switch control {
            case .signIn: canSignIn(source.kind)
            case .boards: canChangeBoards(source.kind) && !source.boards.isEmpty
            // Only as you: the lists are the account's, and a signed-out source has none to read.
            case .lists: canChooseLists(source.kind) && signedIn
            // Every source this device holds can be emptied and let go of.
            case .clear, .remove: true
            }
        }
    }

    /// What a control is called out loud, and hovered over.
    ///
    /// **One string for the tooltip and the speech**, so a pointer user and a VoiceOver reader
    /// cannot be told different things about the same press.
    ///
    /// There is no longer a reason branch: decision 33 draws no control a protocol lacks, so the
    /// only thing a control here has to say is its own act.
    @MainActor
    static func controlLabel(_ control: Control, source: Source, signedIn: Bool) -> String {
        switch control {
        case .signIn:
            return String(format: L10n.t(signInLabelKey(reached: signedIn)), source.host)
        case .boards:
            return String(format: L10n.t("account.source.boards.change"), source.host)
        case .lists:
            return String(format: L10n.t("account.source.lists.change"), source.host)
        // One key, one word, one call — the same Clear as Usage's, because it is one act
        // reached from two questions and not a duplicate of anything.
        case .clear:
            return String(format: L10n.t("prefs.cache.clear.label"), source.host)
        case .remove:
            return String(format: L10n.t("account.source.remove.label"), source.host)
        }
    }
}

extension SourceRow {
    /// Where a row's controls go.
    ///
    /// **`beneath` and not `stacked`, which is a rename and not a new case.** The old name
    /// described a block of *words* on its own line, and those words are gone: both arrangements
    /// draw the same marks at the same size, and only their position differs.
    enum Regime: Equatable {
        /// The mark, the hostname and the controls on one line, controls at the trailing edge.
        /// Only where the hostname still gets `hostFloor`.
        case trailing
        /// Mark and hostname on one line; the same controls on a second, inside the content
        /// column, leading-aligned.
        case beneath
    }

    /// Which of the two a row is drawn in.
    ///
    /// **The threshold is handed in and never derived here, and that is decision 33's whole
    /// mechanism.** The control count is per-protocol now, so the widest row is a property of *the
    /// list* and not of any row in it. A row computing its own threshold would give a Mastodon one
    /// answer and the Discuz! beside it another, and a list where one row is trailing and the row
    /// above it is beneath at the same width reads as broken. `AccountPane.widest` computes it
    /// once and hands it down — the caller states the answer, the callee never looks around for
    /// it, which is risk 14's generalised fix.
    static func regime(width: CGFloat, threshold: CGFloat) -> Regime {
        // Not measured yet — the first frame, before the list has reported its width. Anything at
        // or below zero already fails the comparison below, so this changes no answer; it is here
        // to name the state rather than leave a reader inferring it from an arithmetic accident.
        guard width > 0 else { return .beneath }
        return width < threshold ? .beneath : .trailing
    }

    /// The smallest a press is allowed to be. **Fixed, not `@ScaledMetric`** — a finger does not
    /// grow with the type size. Scaled from `.callout` it would be 41pt at `.medium`, under the
    /// floor, and 60pt at `.xxxLarge`, which would blow every control line computed from it.
    static let touch: CGFloat = 44

    /// The leading mark's size at the default rung, and **`furniture`'s first term**.
    ///
    /// **24, and it is the same 24 three surfaces already want.** `SourceRowView.glyph` is
    /// `@ScaledMetric(.callout) = 24` for the control marks, and `RailView.Metrics.iconSize` is
    /// now `well - snug`, which is also 24. Every mark in this app is 24pt at the default rung.
    /// The shipped row drew a 20pt leading glyph beside 24pt control glyphs — a 4pt mismatch
    /// nobody chose — and 24 is also what the leading position needs now that it is a *drawing*
    /// rather than a scanning glyph.
    ///
    /// **Named rather than written twice.** It was a bare `20` in `SourceRowView`'s `@ScaledMetric`
    /// and a bare `20` in the threshold's comment, so changing one moved the drawn row and left the
    /// threshold behind — QA changed it to 28 and the suite passed.
    static let markBase: CGFloat = 24

    /// How much room the hostname is owed in the trailing regime, at the default rung.
    ///
    /// **`touch * 3` = 132, derived and not invented.** It is about sixteen characters of
    /// `ShellType.name` at the default rung — `mastodon.social` whole, `social.vivaldi.net` as
    /// `social.vivaldi…`. It is a *recognition* floor, and `touch` is the only fixed metric in this
    /// row that already carries a "what a human needs" argument, so the floor is expressed in it.
    ///
    /// **This is what replaces "the words get at least half the row", and the replacement is the
    /// point rather than a re-measurement.** Half-the-row was argued for a content column holding a
    /// hostname, an identity line, a figures line and a two-line Chinese boards list. Decision 34
    /// deletes all four but the hostname, and a hostname is one unbreakable token that truncates
    /// from the tail and keeps its head — so what it needs is a floor, not a half.
    static let hostFloor: CGFloat = touch * 3

    /// A mark's drawn size, with the ceiling that keeps every sum above honest.
    ///
    /// **36pt, and it is `touch - snug` rather than a literal**: a mark is allowed to grow with the
    /// type until it would reach the edges of the 44pt target it sits in, and then it stops,
    /// leaving `ShellSpace.snug` of the target around it. Without this cap a large-type row would
    /// widen its own control group past the line `controlLine` claims.
    ///
    /// **The leading mark reads it too**, which is new: it is no longer a `Font`-sized glyph but a
    /// square drawing in a frame, and a drawing that outgrew 36pt would put the threshold and the
    /// row it is computed from back into disagreement.
    static func symbolPoints(_ scaled: CGFloat) -> CGFloat {
        min(scaled, touch - ShellSpace.snug)
    }

    /// Every target in this row's control set, and every gap between them.
    ///
    /// **Summed from the structure the row draws, not stated beside it.** `SourceRowView.actions`
    /// lays out exactly this list and pads each control after the first by its own `lead`, so a
    /// control added, a control removed or a gap re-tokened moves this number and the drawn row
    /// together. It cannot be made to disagree with the row by hand.
    ///
    /// **It is a function now and was a constant, and that is decision 33 arriving.** The old
    /// `controlLine` said "196 at every rung, in every language, on both platforms", and the
    /// invariance was real — but it was invariant because *every row drew all four*. A Discuz!
    /// still comes to 196; a Mastodon comes to 96.
    static func controlLine(_ controls: [Control]) -> CGFloat {
        touch * CGFloat(controls.count) + controls.dropFirst().reduce(0) { $0 + $1.lead }
    }

    /// Everything in a **trailing** row that is not the hostname: the leading mark, the two gaps
    /// either side of the content column, and the control line.
    ///
    /// Every term is a symbol the drawn row itself reads — `SourceRowView` frames the mark at
    /// `mark`, `ShellSpace.step` is the `HStack`'s own spacing, and `controlLine` is summed from
    /// the same list `actions` iterates. A constant that agrees with the row by hand is unit B's
    /// failure one term over, and this is written to make that unspellable.
    static func furniture(_ controls: [Control], mark: CGFloat) -> CGFloat {
        mark + ShellSpace.step * 2 + controlLine(controls)
    }

    /// The width at which a row stops stacking: its furniture, plus the room the hostname is owed.
    ///
    /// **`mark` and `host` are passed in because they scale and `SourceRow` cannot read the type
    /// size.** `SourceRowView` holds both as `@ShellMetric(relativeTo: .callout)` and hands them
    /// here. That is a reversal of the shipped `Regime`'s deletion of the type gate, and it is
    /// deliberate: the deleted gate was about the *controls*, which are glyphs with no string
    /// length, and QA was right that it restacked a 791pt iPad wrongly. The content column now
    /// holds nothing but text, so at `.accessibility1` a fixed 132pt floor would show four
    /// characters of hostname. One axis, one scaling term, and nothing asks what platform it is on.
    ///
    /// **Do not replace these two parameters with `markBase` and `hostFloor`.** They are equal to
    /// the constants at the default rung and only there, so the substitution looks like removing
    /// two arguments that are always the same and is in fact deleting the Dynamic Type term — a
    /// large-type reader back to a 132pt floor showing four characters, with every test still green
    /// because every test states the default rung. The constants are the *base* values the view
    /// scales; this function must be told what they scaled to.
    ///
    /// **#69's writing word adds no term here, and that is a decision rather than an omission.**
    /// The headroom between this threshold and a 393pt phone is 33 points — so *any* element given
    /// a floor of its own on the host line, a word or a glyph, takes the one-line row off every
    /// phone, which is the dividend decision 33 was argued for. So the word is drawn in the room
    /// the content column has spare, behind the hostname's own `layoutPriority`: what gives way
    /// under a squeeze is the end of the word and never the head of the hostname, and the
    /// guarantee stated below — trailing means the hostname has at least its floor — is untouched.
    /// The cost is that at a boundary width with a long hostname the word can truncate; it is said
    /// whole in `spoken(_:)` at every width, and no test can see a truncation (risk 12).
    static func threshold(_ controls: [Control], mark: CGFloat, host: CGFloat) -> CGFloat {
        furniture(controls, mark: mark) + host
    }

    /// The widest row in *this* list — decision 33's one-threshold rule, read from the rows
    /// actually drawn rather than from the widest row that could exist.
    ///
    /// **The cost, named and accepted:** a reader with three Mastodons on a phone sees one-line
    /// rows, adds a Discuz!, and all four restack together. One regime for the whole list is
    /// satisfied at every instant. The alternative — a fixed maximum — means a Mastodon-only phone
    /// never sees a one-line row at any width, which is the reader this rule is for.
    ///
    /// An empty list has no widest row and no rows to draw, so `[]` is the honest answer rather
    /// than a fallback: `AccountPane` draws the whole block only where sources exist.
    static func widest(_ rows: [SourceRow]) -> [Control] {
        // **By `controlLine` and not by `count`.** The number that decides the regime weights every
        // control by a target *and* by its own `lead`, so a count is only a proxy for it — and the
        // two agree today only because the leads are within 4pt of each other. A control added with
        // a larger gap would make a three-control row wider than a four-control one, and the list
        // would pick the narrower row's threshold and stack nothing. `lazy`, so the intermediate
        // array of control sets is never materialised on the launch screen.
        rows.lazy.map { controls(of: $0.source, signedIn: $0.signedIn) }
            .max { controlLine($0) < controlLine($1) } ?? []
    }
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

/// One row of the source list: a mark, a hostname, and the controls that source actually has.
///
/// **One line at rest — decision 34.** The identity line, the figures line, the evidence line and
/// the boards line have all left. They are not lost: decision 31 put them behind the row's press,
/// so the list says *which servers* and pressing one says *everything about it*, and every one of
/// those lines is already drawn by `SourcePreviewView` under `PreviewOrigin.joined`. This unit adds
/// no drawing there. For the boards list it is a strict improvement — the row clipped it at two
/// lines and the sheet gives the whole of it.
///
/// **What a sighted reader loses and a VoiceOver reader does not.** `SourceRow.spoken(_:)` composes
/// from the *source*, never from these views, so everything the row stops drawing is still said.
/// That asymmetry is unusual and is a property of this design rather than an oversight.
///
/// **The controls vary by protocol — decision 33.** A Mastodon draws two, a Discuz! four, and what
/// a protocol has no such thing of is **absent** rather than struck. The trailing edge is therefore
/// ragged by two controls and the *regime* is not: `SourceRow.widest` computes one threshold for
/// the whole list, because a list where one row is trailing and the row above it is beneath at the
/// same width reads as broken.
///
/// **Unlabelled marks on an iPhone are only safe because none of them does anything irreversible on
/// first press.** `.help()` is a no-op on iOS, so a sighted pointer user there has no word for
/// these marks until they press one — and what makes that acceptable is that Remove asks first,
/// and, since decision 29, so does Clear. **Whoever is later tempted to drop a confirmation to save
/// a tap is removing the thing that makes this row's icons legitimate.** What now also answers it
/// is the list's (?) (`account.sources.marks`, #235), which names all four acts in the reader's own
/// words, once for the list — including that a short row is short *on purpose*.
///
/// **The regime is decided by `SourceRow.regime(width:threshold:)`, which is pure and is driven
/// across both arrangements, the unmeasured first frame and the boundary by `SourcePageTests`.** So
/// is this view's own `regime` — see that property. What no test reaches is `AccountPane`'s
/// `onGeometryChange`, which is SwiftUI's own measurement, and this project has no UI test target
/// (risk 12). That is the seam, named here rather than left to be discovered.
struct SourceRowView: View {
    let row: SourceRow
    /// Whether this device last saw a sign-in reached here. Passed in rather than read from the
    /// session inside the body, so the row stays a function of its inputs.
    let signedIn: Bool
    /// What the list measured for a row's width. **Zero until it has been measured**, which is the
    /// first frame and is a state `regime` names rather than guesses at.
    let width: CGFloat
    /// The control set of the widest row **in this list** — decision 33's one-threshold rule.
    ///
    /// **Handed in and never derived here**, which is risk 14's generalised fix: the caller states
    /// the answer and the callee never looks around for it. A row reading `controls(of: row.source)`
    /// for its threshold would give every row a different one, under a green suite.
    let widest: [SourceRow.Control]
    /// Whether this row's controls may be pressed at all right now — one rule, read from
    /// `ShellSession.rowActsLive(at:checking:)`, so what is drawn and what the press does cannot
    /// disagree.
    let actsLive: Bool
    /// What this row is waiting on, in words, or nothing.
    ///
    /// **The sentence and not a flag**, because the two phases a row reports are two errands: the
    /// forum's index, and the boards the reader picked one request at a time. Chosen by
    /// `SourceRow.waitingLine(_:drawnAs:host:)`, which is pure and pinned, so the row stays a
    /// function of its inputs and the choice is not made in a `View` body.
    let waiting: String?
    /// The last boards refusal this session holds, whichever row it belongs to. Compared against
    /// this row's host here rather than filtered by the caller, so the row stays a function of its
    /// inputs and the comparison is in one place.
    let refusal: (host: String, key: String)?
    /// What this forum's row owes the reader about its sign-in (#153) — that a launch did not sign
    /// it in again and why, or that a password was not kept or not deleted — already a sentence.
    /// The caller asks `ForumSessions.notice(host:)` for this row's host; nothing here looks.
    var notice: String? = nil

    /// Whether the pointer is on this row. **`RailButton`'s own `@State hovering`**, and like it a
    /// seam no test reaches — `.onHover` is delivered by a rendered tree. What a test does reach
    /// is `SourceRow.press(hovering:actsLive:scheme:)`, which this only feeds.
    @State private var hovering = false
    let signIn: () -> Void
    let clear: () -> Void
    let remove: () -> Void
    let changeBoards: () -> Void
    /// A signed-in Mastodon's lists control. Defaulted, because only a row that draws it needs it.
    var chooseLists: () -> Void = {}
    /// The row's own press: it opens what this server says about itself — decision 31.
    let open: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// How many pixels a point is, so the leading mark can ask for the drawing made for the size it
    /// will actually be rendered at. **The rendered pixel count and never the platform** — a 1×
    /// external display hung off a Mac wants the same drawing an old phone does.
    @Environment(\.displayScale) private var displayScale
    /// The leading mark's drawn size, before the ceiling. Scaled so the mark grows with the
    /// hostname beside it; capped by `symbolPoints(_:)`, which the control glyphs already read.
    @ShellMetric(relativeTo: .callout) private var markScaled: CGFloat = SourceRow.markBase
    /// The room the hostname is owed, scaled. **This is the term that brings the type size back
    /// into the threshold**, and it is a different term from the gate QA deleted: that one was
    /// about the controls, which are glyphs with no string length. The content column now holds
    /// nothing but text.
    @ShellMetric(relativeTo: .callout) private var hostFloorScaled: CGFloat = SourceRow.hostFloor
    /// Half a callout's cap height, scaling with it, so both ends' anchors hold across the rungs
    /// the trailing regime exists in. See `actionsTrailing`.
    @ShellMetric(relativeTo: .callout) private var capHalf: CGFloat = 6
    /// A control glyph's drawn size, before the ceiling. Scaled so the marks grow with the words
    /// beside them; capped by `symbolPoints(_:)` so they can never grow out of their targets.
    ///
    /// **`SourceRow.markBase` and not a bare 24**, which is the whole of this unit's own lesson
    /// applied to the constant beside it: the leading mark, this glyph and `RailView`'s are one
    /// number on three surfaces, and a bare literal here is exactly how the 20pt gutter came to be
    /// written twice and changed once. The rail reads it through `well - snug` and a test pins the
    /// two equal.
    @ShellMetric(relativeTo: .callout) private var glyph: CGFloat = SourceRow.markBase

    /// The leading mark's size as it is actually drawn, which is also the term `threshold` reads.
    /// **One symbol for both**, so the frame and the arithmetic cannot drift apart — the mistake
    /// the 20pt gutter shipped once.
    var mark: CGFloat { SourceRow.symbolPoints(markScaled) }

    /// The width at which this list stops stacking. **Internal and pinned**, because it is where
    /// the list's control set and this row's scaling terms meet, and a rule that is right while
    /// nothing asks it is risk 12's recurring defect.
    var threshold: CGFloat {
        SourceRow.threshold(widest, mark: mark, host: hostFloorScaled)
    }

    /// Which regime this row is drawn in.
    ///
    /// **Internal, not private, and pinned** — the habit `busy` and `AccountPane.actionsLive(at:)`
    /// established. A test reads this property and proves that `width`, the list's widest control
    /// set and both scaling terms all reach the rule; a hardcoded width here dies against it.
    var regime: SourceRow.Regime {
        SourceRow.regime(width: width, threshold: threshold)
    }

    /// The controls this row draws — decision 33, and the same list `controlLine` sums.
    var controls: [SourceRow.Control] { SourceRow.controls(of: row.source, signedIn: signedIn) }

    var body: some View {
        // **Read once.** `regime` is asked twice below and each read runs the whole chain —
        // `symbolPoints` → `threshold` → `furniture` → `controlLine` → a fold over the control
        // set — and `controls` allocates a fresh `Control.allCases` plus its filtered result on
        // every access. This is the app's launch screen with one of these per source.
        let controls = controls
        let regime = regime
        return HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            leadingMark
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                // **The hostname is the press, and the marks are siblings of it.** That is the
                // standard list idiom — the row opens, the accessory acts — and it needs no
                // chevron to say so. The controls are sibling `Button`s rather than children, so
                // SwiftUI routes a press to the innermost and there is no ambiguity to resolve;
                // and the row's vertical padding is outside this, so the gap between rows is dead.
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
                rowStatus
                // **Inside the content column, leading-aligned, one step further down the scale.**
                // The `VStack` already spaces by `tight`, so this extra `tight` makes the gap 8 —
                // `ShellSpace.snug`, one rung up — which says *a different kind of thing* without
                // a rule or a plate.
                if regime == .beneath {
                    actions(controls).padding(.top, ShellSpace.tight)
                }
            }
            // **No `Spacer` between the two, in either regime.** `said` already claims the row
            // with `maxWidth: .infinity`, so it is the one flexible element and the marks are
            // pushed to the trailing edge by it. A `Spacer(minLength: ShellSpace.step)` here would
            // put a third gap between them, and `SourceRow.furniture` counts two — so the
            // threshold would be computed from a row this one is not.
            if regime == .trailing { actionsTrailing(controls) }
        }
        .padding(.vertical, ShellSpace.step)
        // **The wash is under the whole row including its controls, and that is correct**: the
        // wash says *this row*, and the marks are in this row. Drawn behind the padding so the lit
        // area is the row and not only its words.
        .background { if let wash = pressed.wash { wash } }
        .onHover { hovering = $0 }
    }

    /// The protocol's own mark, or the shape glyph where this repo draws none — decision 37.
    ///
    /// **Two tiers and not three, and the third is deliberately gone.** Decision 35 put the
    /// server's own published picture here and decision 37 amends it away, on two costs that have
    /// one answer between them: `.account` is `ShellPlace.launch`, so a picture per row meant *N
    /// sources, N requests before the reader pressed anything* — a smaller version of exactly what
    /// decision 10 moved off `.task`; and `SourceProfile.thumbnail` is a **banner, not an avatar**,
    /// so cropped square to 24pt a Mastodon becomes its centre strip and a Discourse wordmark
    /// becomes two or three letters from the middle of the forum's name, which is a legible
    /// fragment of the wrong thing. **The Account page contacts nobody on appearing.** The server's
    /// own picture keeps its home in the detail sheet, where it is drawn whole.
    ///
    /// **The accepted cost, recorded:** two Mastodons look identical here and are told apart by
    /// their hostnames.
    ///
    /// `filament` where signed in is decision 36, and **both tiers honour it through
    /// `SourceMark.ink`**. The row's shape glyph used to hardcode `inkFaint` with no variant while
    /// the masthead glance's honoured `signedIn` — unreachable today only because Discuz! is the
    /// one protocol with a sign-in *and* the one with a drawing, so the row never reaches tier 3
    /// for it. The first protocol with a sign-in and no drawing would have had the two surfaces
    /// saying different things about one server.
    ///
    /// **The expiry to expect, stated correctly: M4, not unit 7.** `HTTPClient` is GET-only until
    /// then — `canSignIn`'s own doc in this file says so — and `PLAN.md`'s unit 7 commits only to
    /// Lemmy's feed and to the board-picker question, not to a sign-in. When M4 gives a second
    /// protocol a sign-in, a mark tinted `filament` will say "signed in" for a protocol this repo
    /// has drawn and stay quiet for one it has not, and the answer then is to let `key.fill` +
    /// `filament` carry it alone.
    private var leadingMark: some View {
        onHostLine(markDrawing.frame(width: mark, height: mark).foregroundStyle(markInk))
            // A scanning aid across a list, not information. `spoken(_:)` names the protocol in
            // words, so a reader who cannot see this loses nothing.
            .accessibilityHidden(true)
    }

    /// **Through `SourceMark.drawing` rather than written here**, so the row, the masthead glance
    /// and the browser's protocol row draw one kind of thing one way. The `Group` is what gives the
    /// two branches one type for `leadingMark`'s modifiers to land on, and the helper's
    /// `@ViewBuilder` does that job now.
    private var markDrawing: some View {
        SourceMark.drawing(
            row.source.kind, shape: row.shape, points: mark, scale: displayScale,
            signedIn: signedIn
        )
    }

    /// Put something on the hostname's own line, by its optical centre.
    ///
    /// **One helper and not the same three lines at both ends of the row**, because the row's whole
    /// argument is that it keeps *one* rule running its full width — mark, hostname, controls — and
    /// an invariant spelt twice is one somebody re-tokens at one end. Both seams are ones no test in
    /// this repository can see (`DESIGN-TAIL` §6.1), so there is no second chance to notice.
    ///
    /// **Why a guide rather than an alignment.** A `frame(width:height:)` around an image, and a
    /// `frame(minHeight:)` around a symbol, may each report a first text baseline from the *frame*
    /// rather than from what is inside it — which would hoist the mark or the control group off the
    /// hostname. Mapping the subject's own centre onto the host line's optical centre says what is
    /// meant whichever it does.
    ///
    /// `capHalf` is read out before the closure: `alignmentGuide`'s is `@Sendable` and a
    /// `@ScaledMetric` is main-actor isolated, so the number crosses rather than the property.
    private func onHostLine(_ view: some View) -> some View {
        let anchor = capHalf
        return view.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + anchor }
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

    /// The hostname and what may be done on the source — **the whole of what the row states about
    /// the server now**, and, since decision 31, the label of the row's own press.
    ///
    /// **The writing word joined it with #69**, and it is on this line rather than under it
    /// because it is a fact about the source and not about an errand — the row is still one line
    /// at rest. It is given no floor of its own; see `SourceRow.threshold` for what that buys and
    /// what it costs.
    ///
    /// **One line, tail truncation, and no `fixedSize`.** A hostname is one unbreakable token: it
    /// truncates from the tail and keeps its head, which is what `SourceRow.hostFloor` is a floor
    /// for. `.fixedSize(horizontal: false, vertical: true)` came off with the wrapping prose — with
    /// `lineLimit(1)` it is moot, and left on it invites a later hand to read this as still
    /// wrapping.
    ///
    /// **What the floor actually guarantees, stated as two halves rather than as one sentence.**
    /// It is tempting to write "the hostname never truncates below its floor, at any width, in
    /// either regime", and that is true of one half and not the other:
    ///
    /// - **Trailing: by construction, at every rung.** The threshold *is* the furniture plus the
    ///   floor, so a row only goes trailing where the hostname has at least `hostFloor`, whatever
    ///   the two scaling terms came out as.
    /// - **Beneath: arithmetic, and it has a limit.** The stacked hostname gets the whole row less
    ///   the mark and one gap — which does **not** grow with the type while the floor does. On the
    ///   narrowest row a reader can be in (286pt, the macOS minimum window with the rail open) it
    ///   holds to the top of this app's own ladder, `DummyFontSize.largest` = `.accessibility1`,
    ///   and stops holding a little past it. `theStackedFloorHoldsToTheTopOfTheLadder` pins both
    ///   the margin and where it falls, so the boundary is a number somebody can watch rather than
    ///   a claim nobody re-checked.
    ///
    /// The element keeps `.combine` and `spoken(_:)`, so what it *says* is unchanged while what it
    /// draws is one line. What it must not become is the *parent* of the controls: a row collapsed
    /// with `children: .ignore` swallows its buttons' activation and leaves a keyboard-only reader
    /// with no way to act — `UsagePane` records shipping that defect twice, and `.ignore` on
    /// an element that is itself pressable is the same defect with a press attached.
    private var said: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(row.source.host)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                // The hostname takes its room first and the word takes what is left, so a column
                // squeezed below both loses the end of a word and never the head of a hostname.
                .layoutPriority(1)
            writingWord
            // The pair is leading-aligned inside a column that claims the whole row, so the word
            // sits beside its hostname rather than opposite it at the far edge, where it would
            // read as a fifth control.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SourceRow.spoken(row))
    }

    /// What may be done on this source, drawn (#69).
    ///
    /// **Quiet, and beside the hostname rather than under it.** It is a standing fact about the
    /// source and not an errand, so it belongs on the identity line — the row is still one line at
    /// rest (decision 34), and `rowStatus` below stays what it was: the slot for a sentence about
    /// a press.
    ///
    /// **Said and drawn from the same key.** `SourceRow.spoken(_:)` reads `writingKey` too, so a
    /// reader who cannot see this is told the same word rather than a second wording of it.
    private var writingWord: some View {
        Text(L10n.t(SourceRow.writingKey(row.writing)))
            .shellFont(.mark)
            .foregroundStyle(writingInk)
            .lineLimit(1)
            .truncationMode(.tail)
            // Said by `said`'s own label, which composes the whole row's sentence — an element
            // spoken twice is a reader hearing the same fact either side of the hostname.
            .accessibilityHidden(true)
    }

    /// The writing word's ink. **Internal and pinned**, on the same grounds as `markInk`: a colour
    /// decided inside a `View` body is reachable from nothing, and this one carries the difference
    /// between a standing fact and a source that has just turned a write away.
    var writingInk: Color {
        SourceRow.marksWriting(row.writing)
            ? ShellChrome.inkDim(colorScheme)
            : ShellChrome.inkFaint(colorScheme)
    }

    /// What this row's errand is doing, or why the last press about it came to nothing.
    ///
    /// **The one state that breaks "one line", and it is unavoidable.** `ProgressOwner.row(host:)`
    /// exists precisely so the sentence appears where the press was, and a spinner with no words is
    /// what this design removed. The row is one line **at rest** and grows a line while an errand
    /// the reader started is running.
    ///
    /// **A sibling of `said` and not inside it.** `said`'s spoken label is composed by
    /// `SourceRow.spoken(_:)` from the source, so anything folded into that element is silently
    /// dropped from what is read out. These two sentences are about an errand rather than about the
    /// server, they come and go, and they are owed aloud.
    @ViewBuilder
    private var rowStatus: some View {
        if let waiting {
            ForumWaiting(line: waiting)
        }
        if let refusal, refusal.host == row.source.host {
            Text(String(format: L10n.t(refusal.key), row.source.host))
                .shellFont(.mark)
                // **Not `alarm`.** That colour is spent on the line that says a host was not added
                // and why; this host was added. Two of this row's marks are alarm-coloured, which
                // is what keeps the distinction readable: alarm on a glyph is a control, alarm on
                // words is a report.
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let notice {
            // The same weight as a refusal and for its reason: this host was added, and nothing
            // about it is broken that a press of Sign in on this row does not answer.
            Text(notice)
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The controls, at the trailing edge, anchored to the host line.
    ///
    /// **Anchored to the host line and not to the column's centre.** The leading mark now sits on
    /// the same guide, so the row has one rule running its full width. A centred group would wobble
    /// the moment a row grew its waiting line while its neighbour did not.
    private func actionsTrailing(_ controls: [SourceRow.Control]) -> some View {
        onHostLine(actions(controls))
    }

    /// The marks themselves, in one order and with one set of gaps, so that widening the window
    /// moves them and regroups nothing.
    ///
    /// **Iterated from `SourceRow.controls(of:)` and each control's own `lead`, which is what makes
    /// `SourceRow.controlLine` a proof rather than a claim.** Written as nested `HStack`s with
    /// literal spacings, the drawn group and the constant agreed only by hand: QA re-tokened one
    /// gap, the real group became 200pt, and `controlLine == 196` became a lie under a green suite.
    /// Laid out from the same list the function sums, a control added or removed and a gap changed
    /// all move both at once.
    ///
    /// **The gap is the control's own property and not an index**, which is decision 33 arriving:
    /// `gaps[index - 1]` was correct only while every row drew all four, and against a filtered
    /// list it reads the wrong gap with no switch in it for the compiler to find.
    ///
    /// The gap is leading padding on every control after the first rather than `HStack` spacing,
    /// because spacing is a number the function cannot see and padding is one it can.
    private func actions(_ controls: [SourceRow.Control]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(controls.enumerated()), id: \.element) { index, control in
                icon(control)
                    .padding(.leading, index > 0 ? control.lead : 0)
            }
        }
    }

    /// One control, drawn from the one rule that decides all of them.
    ///
    /// Order is least to most destructive, and **a control this protocol has no such thing of is
    /// not here at all** — decision 33, which withdraws decision 28 and restores decision 4. What
    /// tells a reader that a short row is short on purpose is the list's (?), said once for the
    /// list rather than four times per row.
    private func icon(_ control: SourceRow.Control) -> some View {
        // **One symbol and a variant, not two controls** — the reader has one relationship with a
        // forum and it is either on or off. `SourceMarkRow` spells that same relationship the same
        // way, so the masthead and the row agree rather than collide. Sign in is the only control
        // that has an *on*, and the fill and the `.isSelected` trait are the same fact twice: one
        // for a reader who can see it and one for a reader who cannot.
        let on = control == .signIn && signedIn
        return RowActionButton(
            symbol: Self.symbol(control),
            variant: on ? .fill : .none,
            state: state(control),
            points: SourceRow.symbolPoints(glyph),
            label: SourceRow.controlLabel(control, source: row.source, signedIn: signedIn),
            selected: on,
            action: press(control)
        )
    }

    /// The glyph each act is drawn with.
    ///
    /// **`key` and not `person.crop.circle` for the sign-in.** Fediqo's sign-in is not an identity
    /// — it is this device holding a cookie and a Keychain password for one forum, which is what
    /// `ForumSessions.reachedSignIn`'s own doc is careful to say. A key is exactly that; a person
    /// is a claim about who you are, which this app never makes. It also fixes the register: key,
    /// checklist, eraser, trash are four handleable objects, where a portrait beside a list, a tool
    /// and a bin was three registers on one row. And `key` vs `key.fill` is a far stronger
    /// two-state signal at 24pt than two portraits differing by an interior wash.
    ///
    /// With decision 32 moving the rail's Account glyph, `person.crop.circle` leaves `FediqoUI`
    /// entirely — the third of its three meanings retired.
    ///
    /// **`eraser` and not a second `trash` for Clear.** Clear empties what this device is holding,
    /// which is not a deletion of anything the reader picked — it says "wipe this" without saying
    /// "throw this away", and the two cannot be confused at this size even though both now carry
    /// the same hue.
    private static func symbol(_ control: SourceRow.Control) -> String {
        switch control {
        case .signIn: "key"
        case .boards: "checklist"
        case .lists: "list.bullet"
        case .clear: "eraser"
        case .remove: "trash"
        }
    }

    /// What this control looks like right now: live in the hue its act carries, or dimmed.
    ///
    /// **Two states, and `state(of:source:actsLive:)` is gone rather than reduced.** With `.struck`
    /// withdrawn by decision 33 that function was a function of `actsLive` alone and no longer read
    /// `source` at all — a signature that lies about what decides. This is now the one rule, and it
    /// says the whole of it: `actsLive ? .live(hue) : .dimmed`.
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
    /// `AccountPane.actionsLive(at:)` established, and the reason risk 12 exists.
    func state(_ control: SourceRow.Control) -> RowActionState {
        guard actsLive else { return .dimmed }
        switch control {
        case .signIn: return .live(signedInInk)
        case .boards, .lists: return .live(ShellChrome.inkDim(colorScheme))
        case .clear, .remove: return .live(ShellChrome.alarm(colorScheme))
        }
    }

    /// What this device's relationship with this forum is drawn in on the **sign-in control**:
    /// `filament` once the reader has switched it on, quiet ink otherwise.
    ///
    /// **`SourceMark.ink` and not a second spelling of it**, so the control, the leading mark and
    /// the masthead glance are three readings of one rule rather than three copies of one thought.
    private var signedInInk: Color {
        SourceMark.ink(
            signedIn: signedIn, quiet: ShellChrome.inkDim(colorScheme), scheme: colorScheme
        )
    }

    /// Whether this row's protocol has a drawing of its own, or falls to the shape glyph.
    ///
    /// **Internal and pinned**, because `markInk` reads it and because it is what decision 37's
    /// absence is asserted against: it is a function of the *protocol* and the pixel count, and of
    /// nothing the server published.
    var hasKindMark: Bool {
        SourceMark.kindMark(row.source.kind, pixels: mark * displayScale) != nil
    }

    /// The leading mark's ink, whichever tier drew it.
    ///
    /// **Internal and pinned.** The two tiers differ in their quiet ink deliberately — a drawing
    /// is a leading mark on a row of controls and takes `inkDim`, a shape glyph is fainter — and
    /// they must **not** differ in whether they honour `signedIn`. That difference is what the row
    /// and the glance shipped, and it is unreachable only until a protocol has a sign-in and no
    /// drawing.
    var markInk: Color {
        SourceMark.ink(
            signedIn: signedIn,
            quiet: hasKindMark
                ? ShellChrome.inkDim(colorScheme)
                : ShellChrome.inkFaint(colorScheme),
            scheme: colorScheme
        )
    }

    /// Which drawing the leading mark uses, or nothing where the shape glyph answers.
    ///
    /// **Internal so decision 37's *absence* can be asserted.** The page contacts nobody on
    /// appearing because there is no picture tier above this — and nothing about "no tier" fails a
    /// test by itself, so what is pinned instead is that this value is a function of the protocol
    /// and the pixel count and is **independent of `row.profile`**. A picture tier reintroduced
    /// above it would make two rows with the same source and different profiles draw differently,
    /// and that is what `theRowsMarkIgnoresWhatTheServerPublished` refuses.
    var markName: String? {
        SourceMark.kindMark(row.source.kind, pixels: mark * displayScale)
    }

    private func press(_ control: SourceRow.Control) -> () -> Void {
        switch control {
        case .signIn: signIn
        case .boards: changeBoards
        case .lists: chooseLists
        case .clear: clear
        case .remove: remove
        }
    }
}

/// How one of the row's controls is drawn. **The tint is a function of this**, which is what closes
/// the trap the first version of this type predicted about itself.
///
/// That trap was real and this branch shipped it twice: `.buttonStyle(.plain)` supplies no dimming
/// of its own, and an explicit `.foregroundStyle` overrides the one `.disabled` would supply — so a
/// refused control looked exactly as pressable as a live one. A colour that can only arrive inside
/// `.live` is a colour that cannot be set on a control that is not.
///
/// **`.struck` is gone with decision 33** and nothing replaces it: a control for a protocol that
/// has no such thing is absent, so there is no third look to draw and no reason for one to give.
/// The user's "the disabled button should be gray-out only" **is** `.dimmed` — `inkFaint`, no
/// strike, no overlay.
///
/// **Do not collapse this type into a plain `Color?`.** Two cases of which one carries a colour
/// now reads like an `Optional` and is not one: the `Optional` would mean *this control has no hue
/// of its own* and *this control cannot be pressed* at the same time, and the second is precisely
/// the meaning that must not be spellable alongside a colour. That is the S1 pattern being
/// reintroduced in the type written to close it — `SourceRow.RowPress.wash` carries the same ban
/// for the same reason, and it became more tempting rather than less when the third case left.
enum RowActionState: Equatable {
    /// Theirs to press, in the hue this act carries.
    case live(Color)
    /// **Not right now.** A stage is up, or something is on the wire.
    case dimmed
}

/// One of the row's controls.
///
/// **`DummyMarkButton`'s shape, because this house already draws bare control glyphs on every
/// timeline row.** `DESIGN.md` §0's "glyphs are rare" is about glyphs that *state* something — a
/// shape mark, the preview's lock — and a control glyph is a different category with its own
/// precedent here.
///
/// **`.help()` is not optional on any of them**, and it is the same string as the spoken label, so
/// a pointer user and a VoiceOver reader cannot be told different things about one press.
///
/// `minWidth`/`minHeight` rather than a fixed frame, so the target is a floor and not a cage.
private struct RowActionButton: View {
    let symbol: String
    let variant: SymbolVariants
    let state: RowActionState
    /// Capped by `SourceRow.symbolPoints(_:)` before it arrives, which is what keeps a control
    /// group as wide as `controlLine` says at every Dynamic Type rung.
    let points: CGFloat
    /// Already host-bearing, and used for both the tooltip and the spoken label — one string, so
    /// the two cannot come to say different things about the same press.
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

    /// A dimmed control is *not right now*, and there is nothing to say about it a reader cannot
    /// see. It refuses the press, and there is no other state left that does not.
    private var refusesPress: Bool { state == .dimmed }

    private var tint: Color {
        switch state {
        case .live(let hue): hue
        case .dimmed: ShellChrome.inkFaint(colorScheme)
        }
    }
}
