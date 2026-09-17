import FediqoCore
import SwiftUI

/// What a server says about itself, drawn the same way wherever the reader is standing.
///
/// **One view, two surfaces, because two previews drift.** This body used to live inside
/// `JoinSheet`; once a typed host's preview is drawn in the page and a browsed one stays in the
/// sheet, keeping it there would mean copying two hundred lines and maintaining both. `dotted(_:)`
/// already names that cost from the other side — "two places that can come to disagree about what
/// separates two readings" — and it is the same argument one level up.
///
/// **Built silent-first.** The spine — who this is, what the server claims, what pressing will do
/// — is drawable from `host` and `kind` alone, so a Discuz! with nothing to publish gets a
/// finished screen with less evidence rather than a rich screen with holes in it. Blocks collapse;
/// nothing greys out; a hairline is drawn only *between* blocks that exist, so the emptiest
/// preview has no internal hairline and cannot read as a form with its rows deleted.
///
/// **It does not scroll and it draws no buttons.** The sheet wraps it in a `ScrollView` and the
/// page is already one; nesting a second scroller inside `AccountPane` is the exact thing that
/// pane's own comment records squeezing its list to nothing at 320pt. Cancel and Subscribe belong
/// to the surface, because the sheet's footer also carries the boards count and the leading button
/// and the page has no analogue for either.
struct SourcePreviewView: View {
    let preview: SourcePreview
    /// Decision 20's derived value, passed in. It decides exactly two things — the title's role
    /// and the horizontal inset — and nothing else on this screen differs between the two.
    let surface: JoinSurface
    /// Where the reader reached this screen from — **decision 31, and it decides three sentences
    /// and nothing else**. The evidence is identical: the hero, the identity, the title, the
    /// summary, the figures, the registration and the rules are what the server said, and what
    /// the server said does not depend on whether the reader has taken it. What *is* false for a
    /// source already subscribed is the framing, the outcome and the caution, and those three go
    /// through `framingKey`, `heldLine` and `cautionKey`, each exhaustive and none of them here
    /// in a `View` body.
    let origin: PreviewOrigin

    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        /// A server's own banner, at the one size a sheet this wide can afford.
        static let hero: CGFloat = 120
    }

    /// The title's role, which is the **only** visual difference between the two surfaces.
    ///
    /// `ShellType.pane` is documented as a pane's own title, one per page, and `AccountPane`'s is
    /// "Account" — so a second `pane`-weight title inside that page would be two page titles. In a
    /// sheet there is no competing title, so the host keeps `pane` there. A `static func` rather
    /// than a branch inside a `body`, so one test pins it without standing a view up.
    static func titleFont(for surface: JoinSurface) -> Font {
        switch surface {
        case .sheet: ShellType.pane
        case .pane: ShellType.name
        }
    }

    /// How far a block is inset from the leading edge.
    ///
    /// **Zero in the page, and that is not a tidier number.** `AccountPane` already pads its whole
    /// `VStack` by `ShellSpace.pad`; a shared view carrying its own horizontal padding would inset
    /// the inline block 32pt against the sheet's 16pt, and the block's hairlines would then fail to
    /// line up with the page's own hairline above the sources list. Vertical padding is identical
    /// on both surfaces and stays in this view.
    static func inset(for surface: JoinSurface) -> CGFloat {
        switch surface {
        case .sheet: ShellSpace.pad
        case .pane: 0
        }
    }

    private var inset: CGFloat { Self.inset(for: surface) }

    /// The host, and the sentence that frames everything under it as *the server's claim* rather
    /// than this app's verdict.
    ///
    /// **Its own view, because the two surfaces place it differently and neither may re-spell it.**
    /// The sheet pins it above its own hairline where it does not scroll; the page scrolls it with
    /// the rest of the block. A nested `View` and not a computed property on the parent: an
    /// `@Environment` value is injected when a view is *rendered*, so a property read off a
    /// hand-built struct would draw the light-mode ink in a dark window.
    struct Header: View {
        let preview: SourcePreview
        let surface: JoinSurface
        let origin: PreviewOrigin

        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(preview.host)
                    .font(SourcePreviewView.titleFont(for: surface))
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t(SourcePreviewView.framingKey(for: origin)))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(JoinSheet.spoken(preview))
        }
    }

    var body: some View {
        switch preview.profile {
        case .stated(let profile):
            stated(profile)
        case .silent:
            spine {
                Text(String(format: L10n.t("join.preview.silent"), preview.host))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .unread(_, _, let error):
            spine {
                VStack(alignment: .leading, spacing: ShellSpace.snug) {
                    Text(String(format: L10n.t("join.preview.unread"), preview.host))
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.unreadMessage(error))
                        .font(ShellType.mark)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        // **The contract says this cannot arrive here, and the house bans `default:`**, so it is
        // drawn rather than asserted on: the spine with no evidence is still a finished screen,
        // and it costs one string to make a contract change upstream unable to produce a blank
        // sheet.
        case .unasked:
            spine {
                Text(String(format: L10n.t("join.preview.unasked"), preview.host))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }

    /// Identity, whatever evidence there is, and what the press will do — one block, no internal
    /// hairlines, because there is not enough here to separate.
    private func spine<Evidence: View>(@ViewBuilder _ evidence: () -> Evidence) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            identityLine(preview.kind)
            evidence()
            outcome()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ShellSpace.pad)
        .padding(.horizontal, inset)
    }

    /// The rich case, which is the variation and not the design.
    private func stated(_ profile: SourceProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                if let thumbnail = profile.thumbnail { hero(thumbnail, host: preview.host) }
                VStack(alignment: .leading, spacing: ShellSpace.snug) {
                    identityLine(preview.kind)
                    if let title = profile.title {
                        Text(title)
                            .font(ShellType.name)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = profile.summary {
                        Text(summary)
                            .font(ShellType.body)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                figures(profile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ShellSpace.pad)
            .padding(.horizontal, inset)

            if !profile.rules.isEmpty {
                hairline
                rules(profile.rules)
            }
            hairline
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                outcome()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ShellSpace.pad)
            .padding(.horizontal, inset)
        }
    }

    /// The server's own picture of itself.
    ///
    /// **The hairline overlay is a light-mode requirement, not trim.** `ShellChrome.page` in light
    /// is very nearly white, and a banner with a pale edge bleeds into the page without it.
    private func hero(_ url: URL, host: String) -> some View {
        RemoteImage(
            url: url,
            tier: .deck,
            host: host,
            alt: String(format: L10n.t("join.preview.thumbnail"), host),
            radius: ShellSpace.tight
        )
        .aspectRatio(16 / 9, contentMode: .fill)
        .frame(maxWidth: .infinity, maxHeight: Metrics.hero)
        .clipShape(RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
        }
    }

    private func identityLine(_ kind: ProtocolKind) -> some View {
        Text(kind.displayName)
            + Text(verbatim: " · ")
            + Text(DummyItem.shapeWord(DummyItem.shape(of: kind)))
    }

    /// What the server stated about its size and its door, and **only** what it stated.
    ///
    /// Concatenated `Text` rather than an `HStack`, which is `BoardPickerSheet.stated(_:)`'s
    /// technique and the house's answer to this exact problem: the numbers follow the shell's
    /// language, and the line wraps instead of clipping at a 460pt sheet in Chinese.
    @ViewBuilder
    private func figures(_ profile: SourceProfile) -> some View {
        let stated = Self.figureLine(profile)
        if stated != nil || profile.registration != nil {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                if let stated {
                    stated
                        .font(ShellType.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // **Kept apart from the outcome line on purpose.** Whether a stranger may sign up
                // is a fact about the server's character; whether *this reader* may read it is a
                // fact about their press. Drawn adjacently, a reader reads "sign-ups are closed"
                // as "I cannot read this", which is false for most servers.
                if let registration = profile.registration {
                    Text(L10n.t(Self.registrationKey(registration)))
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func figureLine(_ profile: SourceProfile) -> Text? {
        dotted(figurePieces(profile))
    }

    /// Readings joined by `" · "`, as **concatenated `Text` and never as a formatted `String`** —
    /// `BoardPickerSheet.stated(_:)`'s technique and the house's answer to this exact problem: the
    /// line wraps instead of clipping at a 460pt sheet in Chinese.
    ///
    /// Shared with the source page's rows, which draw the same figures about the same server. Two
    /// copies of a five-line loop is not the cost; two places that can come to disagree about what
    /// separates two readings is.
    static func dotted(_ pieces: [String]) -> Text? {
        var line: Text?
        for piece in pieces {
            line = line.map { $0 + Text(verbatim: " · ") + Text(piece) } ?? Text(piece)
        }
        return line
    }

    /// The figures a server stated, each already a sentence, in the order they are read.
    ///
    /// **Split out from `figureLine` because the source page needs the same facts twice over.** It
    /// draws them as a concatenated `Text`, like this sheet, *and* has to put them into one spoken
    /// label for a row collapsed to a single accessibility element — and a `Text` cannot be read
    /// back out. Two spellings of "what this server stated about its size" is two things to drift,
    /// which is the whole argument `shapeWord` already won for the shape.
    ///
    /// Nothing where the server stated nothing: a fact it did not state is drawn as nothing and
    /// never as a zero, which is this house's second rule.
    /// `language` is threaded to **both** halves of every piece — the sentence and the number in
    /// it — so the two cannot come back in different languages. That is the failure this parameter
    /// exists for: `L10n.t` was already resolving the shell's language while `compact` quietly
    /// resolved the device's.
    static func figurePieces(_ profile: SourceProfile, language: DummyLanguage? = nil) -> [String] {
        var pieces: [String] = []
        if let active = profile.activeMonth {
            pieces.append(String(
                format: L10n.t("join.preview.activeMonth", language: language),
                L10n.compact(active, language: language)
            ))
        }
        if let people = profile.people {
            pieces.append(String(
                format: L10n.t("account.catalog.people", language: language),
                L10n.compact(people, language: language)
            ))
        }
        if let posts = profile.posts {
            pieces.append(String(
                format: L10n.t("join.preview.posts", language: language),
                L10n.compact(posts, language: language)
            ))
        }
        return pieces
    }

    /// **No `default:`.** A registration state swept into somebody else's sentence is a reader
    /// told the wrong thing about whether they can join a server.
    static func registrationKey(_ registration: SourceProfile.Registration) -> String {
        switch registration {
        case .open: "join.preview.reg.open"
        case .byApproval: "join.preview.reg.approval"
        case .closed: "join.preview.reg.closed"
        }
    }

    /// **The numbers are information, not styling.** Every server's own about page numbers its
    /// rules, and a reader comparing "rule 3" with what a moderator quoted at them needs it.
    /// Monospaced so a column of 1–9 does not wobble.
    private func rules(_ rules: [String]) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("join.preview.rules"))
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    Text(verbatim: "\(index + 1)")
                        .font(ShellType.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .accessibilityHidden(true)
                    Text(rule)
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                // The number is on screen for a sighted reader and would simply be gone
                // otherwise — `BoardPickerSheet.spoken(_:)`'s doctrine applied to a list.
                .accessibilityLabel(String(
                    format: L10n.t("join.preview.rules.spoken"),
                    index + 1, rules.count, rule
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ShellSpace.pad)
        .padding(.horizontal, inset)
        .accessibilityLabel(L10n.t("join.preview.rules"))
    }

    /// The sentence under the host, which frames everything below it.
    ///
    /// "Nothing is added until you subscribe" is a promise about a decision, and a reader looking
    /// at a source they already have is not taking one. **No `default:`.**
    static func framingKey(for origin: PreviewOrigin) -> String {
        switch origin {
        case .field: "join.preview.detail"
        case .joined: "source.held.detail"
        }
    }

    /// What is true of a source the reader **has**, in the present tense — `DESIGN-R2` §4.3.
    ///
    /// **No `default:`**, so units 6–8 answer here as they answer at `outcomeKey`.
    ///
    /// **Discuz! is why this sheet earns its existence beyond "the profile again".** It is the one
    /// surface in the app where the whole board list is readable: the row clips it at two lines,
    /// and `SourceRow.spoken(_:)` gives a VoiceOver reader the untruncated list while a sighted
    /// reader had no equivalent at all. The same key as the row's line, so the count leads and the
    /// names follow in the same words.
    ///
    /// The fallback names the forum rather than asserting boards it has none of. It is
    /// unreachable: `DiscuzBoardJoin.subscribe` returns before `store.subscribe` where nothing
    /// read, so a joined forum carries at least one board — and a total function is what stops
    /// that guarantee, which lives two files away, being the thing this screen depends on.
    @MainActor
    static func heldLine(_ source: Source) -> String {
        switch source.kind {
        case .discuz:
            SourceRow.boardsLine(source) ?? L10n.t("source.held.forum")
        case .discourse:
            L10n.t("source.held.forum")
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
             .gotosocial, .unknown:
            L10n.t("source.held.microblog")
        }
    }

    /// What pressing Subscribe will do — or, where the server has said a signed-out reader may
    /// not read it, what it will most likely do instead. On a detail, what **is** happening.
    @ViewBuilder
    private func outcome() -> some View {
        if let caution = Self.caution(preview) {
            // **It replaces the outcome line rather than sitting beside it, because it *is* the
            // outcome.** Full `ink` at medium weight and one literal glyph: the only full-ink
            // body text and the only glyph in the preview, so it reads as the significant line
            // without borrowing `alarm`, which is spent on refusals that have actually happened.
            //
            // **One glyph for both cautions, and the sentence carries the difference.** A second
            // symbol would be a second statement, and this house spends glyphs one at a time —
            // what the reader needs told apart is the cause and the remedy, which are words.
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Image(systemName: "lock")
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityHidden(true)
                Text(L10n.t(Self.cautionKey(caution, for: origin)))
                    .font(ShellType.meta.weight(.medium))
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let held = origin.held {
            // The outcome line is a prediction about a press, and on a detail there is no press.
            // What replaces it is the present tense of the same fact: what the reader is reading.
            Text(SourcePreviewView.heldLine(held))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L10n.t(Self.outcomeKey(preview.kind)))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the reader is likely to meet if they press, where the look already found out.
    ///
    /// **Two of them, because they are two different facts and the reader can act on them
    /// differently.** One is the server's own policy and the other is a doorman in front of it;
    /// folding them would assert "reading this needs an account" about a forum that may read
    /// perfectly well to a signed-out human, which is a claim this app would have invented.
    enum Caution: Equatable {
        /// **The server said so about itself.** A signed-out reader may not read it.
        case needsAccount
        /// **Something in front of the server said so, and the server said nothing.** A filter
        /// decided this app was a robot. Usually a sign-in clears it.
        case turnedAway

        var key: String {
            switch self {
            case .needsAccount: "join.preview.closed"
            case .turnedAway: "join.preview.turnedAway"
            }
        }

        /// The same two facts, said to a reader who already has this server.
        ///
        /// **No `default:`.**
        var heldKey: String {
            switch self {
            case .needsAccount: "source.held.closed"
            case .turnedAway: "source.held.turnedAway"
            }
        }
    }

    /// Which wording the caution takes, which is a function of the entrance and not of the fact.
    ///
    /// **Reworded rather than dropped, and that was a decision.** Its job is to warn before a
    /// press and on a detail there is no press — but it is the only sentence in this app that
    /// explains **why a forum you read is empty**, and the remedy it names is one the reader has:
    /// the Sign in on that server's own row. Both sentences end "…will most likely be refused",
    /// which is a prediction about a subscription that has already happened, so both are false
    /// here and both are replaced. The glyph, the full `ink` and the weight are unchanged; the
    /// withdrawn Return is moot, because a detail has no default button to withdraw.
    ///
    /// **No `default:`.**
    static func cautionKey(_ caution: Caution, for origin: PreviewOrigin) -> String {
        switch origin {
        case .field: caution.key
        case .joined: caution.heldKey
        }
    }

    /// **A prediction, never a refusal**, in either shape. `nil` on `readsWithoutAccount` is
    /// "this protocol has no such idea" and is not a warning; only a stated `false` is.
    ///
    /// **No `default:`** on the answer: which case carries the caution is a decision, and a new
    /// one swept in here is a screen that warns about the wrong thing or stays silent about the
    /// right one.
    static func caution(_ preview: SourcePreview) -> Caution? {
        switch preview.profile {
        case .stated(let profile):
            profile.readsWithoutAccount == false ? .needsAccount : nil
        // A refusal is the one read failure that predicts the press, and the only one a reader
        // can do something about. The rest say nothing about whether this server can be joined.
        case .unread(_, _, let error):
            if case .refused = error { .turnedAway } else { nil }
        case .silent, .unasked:
            nil
        }
    }

    /// Whether the press has been warned about at all — what withdraws the Return key and adds
    /// the spoken hint, which both cautions earn equally.
    ///
    /// Read by both surfaces' Subscribe buttons, so the sheet's footer and the page's action row
    /// cannot come to disagree about which press this screen warned about.
    static func warns(_ preview: SourcePreview) -> Bool {
        caution(preview) != nil
    }

    /// **No `default:`**, so units 6–8 break the build at the place that has to decide what a
    /// press on their protocol actually does.
    static func outcomeKey(_ kind: ProtocolKind) -> String {
        switch kind {
        case .discuz: "join.preview.next.boards"
        case .discourse: "join.preview.next.forum"
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
             .gotosocial, .unknown:
            "join.preview.next.microblog"
        }
    }

    /// Why a profile could not be read, as a sentence. `ShellSession.unreadMessage(_:)`'s shape,
    /// one layer up and about a document rather than a board.
    ///
    /// **No `default:`.** A reason swept into somebody else's sentence tells the reader the wrong
    /// thing about a server they can very probably still have.
    static func unreadMessage(_ error: ProfileError) -> String {
        switch error {
        case .unreachable: L10n.t("join.preview.unread.network")
        case .refused(let status): String(format: L10n.t("join.preview.unread.refused"), status)
        case .unreadable: L10n.t("join.preview.unread.unreadable")
        }
    }
}
