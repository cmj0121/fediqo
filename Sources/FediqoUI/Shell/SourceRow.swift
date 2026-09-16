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
    /// `JoinSheet.figurePieces` is the one place they are worded, so the preview and the row say
    /// the same numbers in the same words about the same server.
    @MainActor
    static func figures(_ answer: ProfileAnswer, language: DummyLanguage? = nil) -> [String] {
        switch answer {
        case .stated(let profile): JoinSheet.figurePieces(profile, language: language)
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

    /// The sign-in control's word, by what this device last saw.
    ///
    /// **A toggle and not two controls**, because the reader has one relationship with a forum and
    /// it is either on or off. What "on" means is `ForumSessions.reachedSignIn`'s business, and its
    /// doc comment is where the honesty about an expiring cookie lives.
    static func signInTitleKey(reached: Bool) -> String {
        reached ? "account.source.signout" : "account.source.signin"
    }

    /// Its spoken label. Sign in reuses `account.refuse.signin.label` — one key for one act, so
    /// the offer under a refusal and the control on the row cannot drift in translation.
    static func signInLabelKey(reached: Bool) -> String {
        reached ? "account.source.signout.label" : "account.refuse.signin.label"
    }
}

/// One row of the source list.
///
/// **Actions on their own line, leading-aligned**, not trailing like `PreferencesPane`'s single
/// Clear. Three controls, three languages and a 320pt phone: trailing placement either clips or
/// forces the content column to a width that breaks Chinese. Their own line also gives a finger a
/// stable target. Ordered least to most destructive.
struct SourceRowView: View {
    let row: SourceRow
    /// Whether this device last saw a sign-in reached here. Passed in rather than read from the
    /// session inside the body, so the row stays a function of its inputs.
    let signedIn: Bool
    let signIn: () -> Void
    let clear: () -> Void
    let remove: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The width of the glyph's gutter, so every row's text starts on the same line however big
    /// the type is. **The width only** — the symbol itself scales through its own font below,
    /// because a `@ScaledMetric` frame around a symbol that does not scale with it is a glyph that
    /// drifts off the baseline it is aligned to as the type grows.
    @ScaledMetric(relativeTo: .callout) private var gutter: CGFloat = 20

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
                said
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ShellSpace.step)
    }

    /// Everything the row states about the server, as one accessibility element.
    private var said: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(row.source.host)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            identity
            if let figures = JoinSheet.dotted(SourceRow.figures(row.profile)) {
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
            if let boards = SourceRow.boardsLine(row.source) {
                Text(boards)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **Combined, and the buttons are deliberately not inside it.** A row collapsed with
        // `children: .ignore` swallows its buttons' activation and leaves a keyboard-only reader
        // with no way to act — `PreferencesPane` records shipping that defect twice. So the stated
        // facts become one element and the three controls stay siblings of it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SourceRow.spoken(row))
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

    private var actions: some View {
        HStack(spacing: ShellSpace.step) {
            // Drawn only where the protocol has one. Absent, never disabled — decision 4.
            if row.canSignIn {
                Button(L10n.t(SourceRow.signInTitleKey(reached: signedIn)), action: signIn)
                    .font(ShellType.meta)
                    .accessibilityLabel(Text(String(
                        format: L10n.t(SourceRow.signInLabelKey(reached: signedIn)),
                        row.source.host
                    )))
            }
            // One key, one word, one call — the same Clear as Preferences', because it is one act
            // reached from two questions and not a duplicate of anything.
            Button(L10n.t("prefs.cache.clear"), action: clear)
                .font(ShellType.meta)
                .accessibilityLabel(Text(String(
                    format: L10n.t("prefs.cache.clear.label"), row.source.host
                )))
            // A plain button, styled like Clear. **Not `alarm`** — that colour is spent on the one
            // line that says a host was not added and why. Remove's weight is carried by the
            // question it raises, where the system colours the destructive button and where the
            // press actually does something.
            Button(L10n.t("account.source.remove"), action: remove)
                .font(ShellType.meta)
                .accessibilityLabel(Text(String(
                    format: L10n.t("account.source.remove.label"), row.source.host
                )))
        }
    }
}
