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
    /// Whether this sign-in was made before this app asked for something it now would — to
    /// write, or for bookmarks (`unasked(grant:bookmarks:)`). The one fact `owed` adds to
    /// `writing`, and **handed in as `writing` is and for its reason**: both are the session's.
    let unasked: Bool

    /// What the sign-in must be asked again for — what the row's one permission glyph is drawn
    /// from. Derived, so it cannot disagree with `writing`.
    var owed: Owed { Self.owed(writing: writing, unasked: unasked) }

    /// **`writing` left out is not a second derivation but the same one with nothing to carry**:
    /// `SourceWriting.of` is asked with no sign-in and no refusal, which is the honest answer for a
    /// source this device holds neither for — a forum reads only whatever anybody agreed, and a
    /// signed-out microblog reads. `unasked` left out is no sign-in, which was asked nothing.
    init(
        source: Source, profile: ProfileAnswer, signedIn: Bool = false,
        writing: SourceWriting? = nil, unasked: Bool = false
    ) {
        self.source = source
        self.shape = DummyItem.shape(of: source.kind)
        self.profile = profile
        self.canSignIn = Self.canSignIn(source.kind)
        self.signedIn = signedIn
        self.writing = writing ?? SourceWriting.of(kind: source.kind, grant: nil, refused: false)
        self.unasked = unasked
    }

    /// Whether this protocol has a sign-in for the reader to be offered.
    ///
    /// **No `default:`**, the shape `ShellSession.hasTrends` already takes and for its reason: a
    /// protocol added and not listed here would silently inherit somebody else's answer about a
    /// control it may not have.
    ///
    /// **Where this is false the key is still drawn, dim** (`look(_:source:signedIn:actsLive:)`):
    /// every row draws the same glyphs and only their colour differs. A protocol is flipped on
    /// by adding it to this switch, never by a `kind == .discuz` at a call site.
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

    /// Every sentence standing about this source now, in the order the head of the row's `…`
    /// reads them: the errand running, then a refusal of the last press on this host, then the
    /// forum's own notice. The row draws none of them — its `…` says in colour and in its name that
    /// there is something to read (`saying`) — VoiceOver hears them all, and the source's detail
    /// (`SourceStanding`) says every one whole.
    static func statusLines(waiting: String?, refusal: (host: String, key: String)?, notice: String?,
                            host: String, language: DummyLanguage? = nil) -> [String] {
        var lines: [String] = []
        if let waiting { lines.append(waiting) }
        if let refusal, refusal.host == host {
            lines.append(String(format: L10n.t(refusal.key, language: language), host))
        }
        if let notice { lines.append(notice) }
        return lines
    }

    /// What may be done on this source, in the reader's own words (#69).
    ///
    /// **Said, and not drawn.** `spoken(_:)` says it on every row — four words and no silence, so
    /// a listener never has to read a source by what is missing — and what a sighted reader is
    /// shown is the one case that asks something of them: the permission glyph (`owed`).
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
    /// what the row stopped drawing and its detail still shows — what may be done here, the
    /// figures, the evidence line and the board names **whole** — so a reader who cannot see the
    /// detail is owed nothing by the row.
    @MainActor
    static func spoken(_ row: SourceRow) -> String {
        var said = [String(
            format: L10n.t("source.spoken"),
            row.source.host,
            row.source.kind.displayName,
            DummyItem.shapeWord(row.shape)
        )]
        // Straight after the identity and before the figures: it is what decides whether a press
        // on this source can ever write, so it is not left to the end of a sentence a reader may
        // stop listening to.
        said.append(L10n.t(writingKey(row.writing)))
        said += figures(row.profile)
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
    /// saved password from the Keychain, and an Account row draws no line saying one is held —
    /// so the question is where it is said before it goes.
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
    /// What can be done to a source, in the order it is offered: least to most destructive.
    ///
    /// **An enum and not five call sites**, so that one rule answers for all of them and a sixth
    /// act cannot be added with its look decided somewhere else.
    ///
    /// **Every row offers every one of them.** What a source lacks is drawn dim with its reason
    /// (`look(_:source:signedIn:actsLive:)`), so every row of the list has one shape and a reader
    /// learns it once.
    enum Control: CaseIterable {
        case signIn
        case boards
        /// A signed-in Mastodon's lists (#25) — the boards control's counterpart.
        case lists
        case clear
        case remove
    }

    /// The one act drawn as a mark on the row itself: the sign-in, since it is the one with a
    /// state a reader looks for.
    static let onRow: [Control] = [.signIn]

    /// What the row's `…` holds, in the order it lists them (`more`). `ShellMore` puts the two
    /// that take something away under its divider whatever order they are handed in; they are
    /// last here too, so the list reads as it is drawn.
    static let inMore: [Control] = [.boards, .lists, .clear, .remove]

    /// The glyph each act is drawn with, live or dim, on or off: the act's own, and nothing else
    /// decides it.
    ///
    /// **`key` and not `person.crop.circle` for the sign-in.** Fediqo's sign-in is not an identity
    /// — it is this device holding a cookie and a Keychain password for one forum, which is what
    /// `ForumSessions.reachedSignIn`'s own doc is careful to say. A key is exactly that; a person
    /// is a claim about who you are, which this app never makes.
    ///
    /// **`eraser` and not a second `trash` for Clear.** Clear empties what this device is holding,
    /// which is not a deletion of anything the reader picked — it says "wipe this" without saying
    /// "throw this away".
    static func symbol(_ control: Control) -> String {
        switch control {
        case .signIn: "key"
        case .boards: "checklist"
        case .lists: "list.bullet"
        case .clear: "eraser"
        case .remove: "trash"
        }
    }

    /// How an act is drawn on this source right now: live, or dim with the reason.
    ///
    /// **`never` before `notNow`.** A protocol with no sign-in has none while the page is busy
    /// too, and "not right now" would promise a control that is never coming.
    ///
    /// **A function of the source and not of the protocol alone**, because Boards is refused on
    /// two different facts and one of them is per-source: a protocol with no picker at all, and a
    /// source with nothing to pick. **It adds no switch over `ProtocolKind`**: `canSignIn`,
    /// `canChangeBoards` and `canChooseLists` are the three that decide, they are already
    /// exhaustive and already pinned, and a fourth table saying the same thing is a fourth place
    /// to forget a protocol.
    ///
    /// Lists are the account's: a protocol that has them and no sign-in to read them with says
    /// not right now, since signing in is what brings them.
    static func look(
        _ control: Control, source: Source, signedIn: Bool, actsLive: Bool
    ) -> MarkLook {
        let has: Bool
        var ready = actsLive
        switch control {
        case .signIn:
            has = canSignIn(source.kind)
        case .boards:
            has = canChangeBoards(source.kind) && !source.boards.isEmpty
        case .lists:
            has = canChooseLists(source.kind)
            ready = actsLive && signedIn
        // Every source this device holds can be emptied and let go of.
        case .clear, .remove:
            has = true
        }
        guard has else { return .dim(.never) }
        return ready ? .live : .dim(.notNow)
    }

    /// One act as a mark: its glyph, its name, its look, and whether it is switched on — which
    /// only the sign-in can be. The key on the row and the items of `…` are both made from this,
    /// so one act has one glyph, one name and one look wherever it is offered.
    @MainActor
    static func mark(
        _ control: Control, source: Source, signedIn: Bool, actsLive: Bool
    ) -> ShellMark {
        ShellMark(
            symbol(control),
            controlLabel(control, source: source, signedIn: signedIn),
            look: look(control, source: source, signedIn: signedIn, actsLive: actsLive),
            on: control == .signIn && signedIn
        )
    }

    /// What a control is called out loud, and hovered over.
    ///
    /// **One string for the tooltip and the speech**, so a pointer user and a VoiceOver reader
    /// cannot be told different things about the same press. Why a dim one is dim is not said
    /// here: `ShellMark.spoken` puts the reason after the name.
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
    /// What a sign-in is owed before everything it could do is offered.
    enum Owed: Equatable {
        /// Nothing: no sign-in, one that was asked everything, one that reads by the reader's own
        /// choice, or a protocol with nothing to ask for.
        case nothing
        /// It was made before this app asked — to write, or for bookmarks.
        case asking
        /// The source turned a write away since.
        case refused
    }

    /// The one permission glyph's rule (Q5): a sign-in that must be asked again.
    ///
    /// **Three cases with one cure, so one glyph is honest**: a write the source refused, a
    /// sign-in made before writing was asked for, and one made before bookmarks were. Left out
    /// are the two with no cure or none needed — `.never`, where there is nothing to ask, and
    /// `.reads` by the reader's own choice — and a source that is signed out, whose live key
    /// already says what to do.
    ///
    /// A refusal is the loudest of the three and is asked first: it is something that happened.
    static func owed(writing: SourceWriting, unasked: Bool) -> Owed {
        if writing == .refused { return .refused }
        return unasked ? .asking : .nothing
    }

    /// Whether a sign-in was made before this app asked for something it now would: to write,
    /// or for bookmarks.
    static func unasked(grant: MastodonGrant?, bookmarks: BookmarkStanding) -> Bool {
        grant == .unasked || bookmarks == .unasked
    }

    /// The permission glyph. `key.slash` is taken by forgetting a password and
    /// `exclamationmark.triangle` by an act that failed.
    static let permissionSymbol = "exclamationmark.lock"

    /// What the permission glyph says — to the pointer, to VoiceOver, and at the head of the
    /// row's `…`, which is where a finger reads it. Nothing where nothing is owed.
    static func permissionLine(_ row: SourceRow, language: DummyLanguage? = nil) -> String? {
        guard row.owed != .nothing else { return nil }
        return String(format: L10n.t("account.source.permission", language: language), row.source.host)
    }

    /// The permission glyph as a value, or nothing where nothing is owed: its glyph, its
    /// sentence, and a mark's two looks — live, or dim for now while the row's acts are not
    /// live. **The look decides the press** (`ShellMark.press`), so a glyph that cannot be
    /// pressed is never drawn as one that can, and says "not right now" after its sentence.
    static func permission(
        _ row: SourceRow, actsLive: Bool, language: DummyLanguage? = nil
    ) -> ShellMark? {
        guard let line = permissionLine(row, language: language) else { return nil }
        return ShellMark(permissionSymbol, line, look: actsLive ? .live : .dim(.notNow))
    }

    /// The permission glyph's ink: a dim mark's while it cannot be pressed; otherwise quiet, and
    /// the alarm only where a write was turned away.
    ///
    /// **The one ink handed to a `ShellMarkButton` over its look's own** (`MarkLook`): a mark is
    /// a press that is offered, and this one also says something happened to a press.
    static func permissionInk(_ owed: Owed, look: MarkLook, _ scheme: ColorScheme) -> Color {
        if case .dim = look { return ShellChrome.markDim(scheme) }
        return owed == .refused ? ShellChrome.alarm(scheme) : ShellChrome.inkDim(scheme)
    }
}

extension SourceRow {
    /// Whether the row says something went wrong, as against only that it is waiting.
    static func warns(waiting: Bool, said: [String]) -> Bool {
        !said.isEmpty && !(waiting && said.count == 1)
    }

    /// What the row's `…` says besides that it is there: nothing at rest, that it waits while
    /// the errand running is all the row has to say, and a warning otherwise. **The one signal a
    /// sighted reader has that the menu has something at its head**, since no line is held open
    /// under the hostname for it — and it is colour and words, never a second glyph.
    static func saying(waiting: Bool, said: [String]) -> ShellMoreSaying {
        guard !said.isEmpty else { return .nothing }
        return warns(waiting: waiting, said: said) ? .warns : .waits
    }

    /// What stands at the head of the row's `…` before any dim mark's reason: every standing
    /// sentence, then what the permission glyph says.
    static func head(_ row: SourceRow, said: [String], language: DummyLanguage? = nil) -> [String] {
        said + [permissionLine(row, language: language)].compactMap { $0 }
    }

    /// What a listener is told of the row: what it is, and then whatever it has to say.
    static func heard(row: String, said: [String]) -> String {
        ([row] + said).joined(separator: " ")
    }

    /// What each press of a row does, handed in by the page: the row acts on nothing itself.
    struct Presses {
        var signIn: () -> Void = {}
        /// Puts the question a sign-in is owed; the permission glyph's press.
        var askAgain: () -> Void = {}
        var changeBoards: () -> Void = {}
        var chooseLists: () -> Void = {}
        /// What the yes to Clear's question does. Reached only through that yes.
        var clear: () -> Void = {}
        /// What the yes to Remove's question does. Reached only through that yes.
        var remove: () -> Void = {}
        /// The row's own press: it opens what this server says about itself.
        var open: () -> Void = {}
    }

    /// The row's `…`, as a value.
    ///
    /// The head is what the row has to say, then why each of the row's marks that is dim is dim
    /// — the lock where one is drawn, and the key — the only place a finger reads either. Then
    /// Boards and Lists, dim with their reason in their own title where the source has none or
    /// cannot just now; then, under the divider, Clear and Remove (`inMore`'s order).
    ///
    /// **Clear and Remove are built here and nowhere else, and only as `danger`**: the menu puts
    /// each one's question, and only its yes reaches the act. The questions are the session's
    /// (`ShellSession.clearQuestion`, `.removeQuestion`) and are built when an item is chosen,
    /// not once a row each time the list is drawn.
    @MainActor
    static func more(
        _ row: SourceRow, actsLive: Bool, said: [String],
        clearAsks: @escaping () -> ShellConfirmation,
        removeAsks: @escaping () -> ShellConfirmation, presses: Presses
    ) -> ShellMore {
        func mark(_ control: Control) -> ShellMark {
            Self.mark(control, source: row.source, signedIn: row.signedIn, actsLive: actsLive)
        }
        let drawn = [permission(row, actsLive: actsLive)].compactMap { $0 } + onRow.map(mark)
        return ShellMore(
            head: head(row, said: said) + ShellMore.reasons(of: drawn),
            items: [
                .plain(mark(.boards), act: presses.changeBoards),
                .plain(mark(.lists), act: presses.chooseLists),
                .danger(mark(.clear), asks: clearAsks(), act: presses.clear),
                .danger(mark(.remove), asks: removeAsks(), act: presses.remove),
            ]
        )
    }
}

extension SourceRow {
    /// The smallest the hostname's press is allowed to be. **Fixed, not `@ScaledMetric`** — a
    /// finger does not grow with the type size.
    static let touch: CGFloat = 44

    /// The leading mark's size at the default rung.
    ///
    /// **24, and it is the same 24 other surfaces already want**: `RailView.Metrics.iconSize` is
    /// `well - snug`, which is also 24, and `JoinSheet` reads this constant for its own marks.
    /// **Named rather than written twice** — it was once a bare `20` in two places, and changing
    /// one moved the drawn row and left the other behind.
    static let markBase: CGFloat = 24

    /// The leading mark's drawn size, with its ceiling.
    ///
    /// **36pt, and it is `touch - snug` rather than a literal**: the mark is allowed to grow with
    /// the type until it would reach the edges of the 44pt line it sits in, and then it stops,
    /// leaving `ShellSpace.snug` around it — so a large type size makes the row's words bigger
    /// and never the row taller for its mark.
    static func symbolPoints(_ scaled: CGFloat) -> CGFloat {
        min(scaled, touch - ShellSpace.snug)
    }

}

extension SourceRow {
    /// How the row's **own body** is drawn: the pointer's wash, or nothing at all.
    ///
    /// **A colour that can only arrive inside `.live`, which is the only shape that closes this.** The row's body has
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
    /// **The same `actsLive` the row's marks read** — `ShellSession.rowActsLive(at:checking:)`,
    /// one rule for every end (`DESIGN-R2` §10.1). Opening a detail replaces `session.stage`,
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

/// One row of the source list, the same at every width and for every source: the protocol's
/// mark, the hostname, the sign-in key, and `…`.
///
/// **One layout.** Every source draws the same glyphs in the same places and only their colour
/// differs: what a source lacks is dim, and says why.
///
/// **What is drawn.** The mark and the hostname, which is the row's press and opens what the
/// server says about itself (decision 31). One glyph when the sign-in must be asked again
/// (`SourceRow.owed`), and only then. The key: quiet when signed out, filled and warm when signed
/// in, dim where the protocol has no sign-in or the page is busy. And `…`, always that glyph and
/// red where the row warns, which holds what the row has to say, Boards, Lists, and — under its
/// divider, each asking first — Clear and Remove.
///
/// **What a sighted reader loses and a VoiceOver reader does not.** `SourceRow.spoken(_:)`
/// composes from the *source*, never from these views, so the figures, the boards and what may be
/// done on the source are still said. That asymmetry is a property of this design rather than an
/// oversight.
///
/// **Nothing that takes something away is a mark here.** Clear and Remove are destructive items
/// of `…` and cannot be built any other way (`SourceRow.more`); on a phone, where `.help()` is a
/// no-op and a glyph has no word until it is pressed, that is what makes an unlabelled row safe.
/// The list's (?) (`account.sources.marks`) names the marks once for the list.
///
/// **No chevron, though the hostname is a way in** (U2's finding 15, the exception written down):
/// the trailing edge is the key and `…`, and a third glyph there would read as a third control.
///
/// **Every rule is a `static func` on `SourceRow` or an internal value here, and `SourcePageTests`
/// drives them.** What no test reaches is what SwiftUI delivers — a hover, a menu opening — and
/// this project has no UI test target (risk 12).
struct SourceRowView: View {
    let row: SourceRow
    /// Whether this row's acts may be pressed at all right now — one rule, read from
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
    /// Builds the question Clear asks. Handed in: what it says depends on a saved password and a
    /// sign-in, which are the session's to know — and called only when Clear is chosen.
    let clearAsks: () -> ShellConfirmation
    /// Builds the question Remove asks, called only when Remove is chosen.
    let removeAsks: () -> ShellConfirmation
    let presses: SourceRow.Presses

    /// Whether the pointer is on this row. **`RailButton`'s own `@State hovering`**, and like it a
    /// seam no test reaches — `.onHover` is delivered by a rendered tree. What a test does reach
    /// is `SourceRow.press(hovering:actsLive:scheme:)`, which this only feeds.
    @State private var hovering = false

    @Environment(\.colorScheme) private var colorScheme
    /// How many pixels a point is, so the leading mark can ask for the drawing made for the size it
    /// will actually be rendered at. **The rendered pixel count and never the platform** — a 1×
    /// external display hung off a Mac wants the same drawing an old phone does.
    @Environment(\.displayScale) private var displayScale
    /// The leading mark's drawn size, before the ceiling. Scaled so the mark grows with the
    /// hostname beside it; capped by `symbolPoints(_:)`.
    @ShellMetric(relativeTo: .callout) private var markScaled: CGFloat = SourceRow.markBase
    /// The box each trailing mark is drawn in — `ShellGlyphBox`'s own metric, read here so the
    /// gap between two of them is computed from the box they actually have at this type size.
    @ShellMetric(relativeTo: .caption) private var box: CGFloat = ShellGlyphBox.box

    /// The leading mark's size as it is actually drawn.
    var mark: CGFloat { SourceRow.symbolPoints(markScaled) }

    /// Every sentence standing about this source now. **Internal and pinned**: it is the head of
    /// `…`, the glyph `…` wears and what a listener hears after the row's own sentence.
    var said: [String] {
        SourceRow.statusLines(waiting: waiting, refusal: refusal, notice: notice, host: row.source.host)
    }

    /// The sign-in, as the mark the row draws. **Internal and pinned** — a look decided inside a
    /// `View` body is reachable from nothing.
    var key: ShellMark {
        SourceRow.mark(.signIn, source: row.source, signedIn: row.signedIn, actsLive: actsLive)
    }

    /// The row's `…`. **Internal and pinned**: what it holds, in what order, and that the two
    /// acts that take something away are destructive items of it.
    var more: ShellMore {
        SourceRow.more(
            row, actsLive: actsLive, said: said, clearAsks: clearAsks, removeAsks: removeAsks,
            presses: presses
        )
    }

    /// `more`, as the builder `…` calls when it is opened.
    private func menu() -> ShellMore { more }

    /// What `…` says beyond that it is there. Internal for `more`'s reason.
    var saying: ShellMoreSaying {
        SourceRow.saying(waiting: waiting != nil, said: said)
    }

    /// The permission glyph, where one is owed. Internal for `key`'s reason.
    var permission: ShellMark? {
        SourceRow.permission(row, actsLive: actsLive)
    }

    var body: some View {
        // Read once a pass: each is a walk of the row's sentences or a formatted label.
        let said = said
        let saying = SourceRow.saying(waiting: waiting != nil, said: said)
        let key = key
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            // A scanning aid across a list, not information. `spoken(_:)` names the protocol in
            // words, so a reader who cannot see this loses nothing.
            markDrawing.frame(width: mark, height: mark).foregroundStyle(markInk)
                .accessibilityHidden(true)
            // **The hostname is the press, and the marks are siblings of it** — the row opens,
            // the accessories act. Sibling `Button`s rather than children, so SwiftUI routes a
            // press to the innermost and there is no ambiguity to resolve.
            Button(action: presses.open) {
                Text(row.source.host)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                    // The host is the identity: its start and its end are both kept (U2's
                    // finding 29).
                    .truncationMode(.middle)
                    // The whole width of the line is the press, not the glyphs of the text.
                    .frame(maxWidth: .infinity, minHeight: SourceRow.touch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pressed == .inert)
            .help(String(format: L10n.t("account.source.open"), row.source.host))
            // Every word of the row, and everything it has to say, though none of it is drawn.
            .accessibilityLabel(SourceRow.heard(row: SourceRow.spoken(row), said: said))
            .accessibilityHint(Text(L10n.t("account.source.open.hint")))
            // Spaced so no two presses overlap (`ShellTouchFloor.gap`), and never squeezed: under
            // a narrow page it is the hostname that gives way, by its middle.
            HStack(spacing: ShellTouchFloor.gap(drawn: box)) {
                if let permission {
                    ShellMarkButton(
                        permission,
                        ink: SourceRow.permissionInk(row.owed, look: permission.look, colorScheme),
                        act: presses.askAgain
                    )
                }
                ShellMarkButton(key, act: presses.signIn)
                // Its name is the menu's own for one that always holds four items, so the menu
                // itself is built only when it is opened.
                ShellMoreButton(label: ShellMore.label(saying: saying), saying: saying, more: menu)
            }
            .fixedSize()
            .padding(.leading, ShellTouchFloor.lead(drawn: box))
            .layoutPriority(1)
        }
        .padding(.vertical, ShellSpace.tight)
        // **The wash is under the whole row including its marks, and that is correct**: the wash
        // says *this row*, and the marks are in this row. Drawn behind the padding so the lit
        // area is the row and not only its words.
        .background { if let wash = pressed.wash { wash } }
        .onHover { hovering = $0 }
    }

    /// The protocol's own mark, or the shape glyph where this repo draws none — decision 37.
    ///
    /// **Two tiers and not three, and the third is deliberately gone.** Decision 35 put the
    /// server's own published picture here and decision 37 amends it away, on two costs that have
    /// one answer between them: `.account` is `ShellPlace.launch`, so a picture per row meant *N
    /// sources, N requests before the reader pressed anything*; and `SourceProfile.thumbnail` is a
    /// **banner, not an avatar**, so cropped square to 24pt it is a legible fragment of the wrong
    /// thing. **The Account page contacts nobody on appearing.** The server's own picture keeps
    /// its home in the detail sheet, where it is drawn whole.
    ///
    /// **The accepted cost, recorded:** two Mastodons look identical here and are told apart by
    /// their hostnames.
    ///
    /// **Through `SourceMark.drawing` rather than written here**, so the row, the masthead glance
    /// and the browser's protocol row draw one kind of thing one way. `filament` where signed in
    /// is decision 36, and both tiers honour it through `SourceMark.ink`.
    private var markDrawing: some View {
        SourceMark.drawing(
            row.source.kind, shape: row.shape, points: mark, scale: displayScale,
            signedIn: row.signedIn
        )
    }

    /// Whether this row's own press is live, and what the pointer draws.
    ///
    /// **Internal, not private, and pinned**: a rule that is right and a view that asks it the
    /// wrong question is this branch's recurring defect (risk 12), and a style decided in a
    /// `View` body is reachable from nothing.
    var pressed: SourceRow.RowPress {
        SourceRow.press(hovering: hovering, actsLive: actsLive, scheme: colorScheme)
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
    /// they must **not** differ in whether they honour the sign-in.
    var markInk: Color {
        SourceMark.ink(
            signedIn: row.signedIn,
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
}

/// Every sentence standing about a source, whole, at the head of its detail (#244): what its row
/// keeps at the head of its `…`. A line each, read in order.
struct SourceStanding: View {
    let lines: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label {
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                }
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
