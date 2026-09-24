import FediqoCore
import SwiftUI

/// What a post draws of the post it quotes (#214), in two places.
///
/// **In the row's decorator, as a boost is** (`QuoteMark`): `❝ quoting @x`, in the band a boost's
/// `boosted by` line stands in, the same ink and the same one line — so a quoting row is exactly as
/// tall as a boosted one whatever the quoted post wrote, and a boost of a quote is one line still.
/// A quote that cannot be shown says its state there in a few words.
///
/// **Whole in the pane** (`QuoteCard`), under the words: the post the reader opened in order to
/// read it, where the quoted post's author, words and what it carries are worth their height.
///
/// **Nothing of the quoted post where the quote may not be shown.** Core keeps nothing of it in
/// that case (`Quote.post`); the decorator names the state and the pane draws no card.
struct QuoteBand: View {
    let quote: Quote
    /// The source the quoting post came through, which every picture here is read through: the
    /// only host the reader's Clear button can name (`ShellPictures`, I10).
    let host: String
    /// Whether the reader lifted the quoted post's cover. Its cover is its own row's, so lifting
    /// it here lifts it where it is opened too, and the other way round.
    var lifted: Bool = false
    /// Opening the quoted post as a post of its own. Nothing where there is nothing to open.
    var onOpen: (() -> Void)?
    var onToggleCover: () -> Void = {}

    var body: some View {
        if let post = quote.post {
            QuoteCard(post: post, host: host, lifted: lifted, onOpen: onOpen, onToggleCover: onToggleCover)
        }
    }

    // MARK: - What it says, where a test can ask

    /// What a quote says where the quoted post is not drawn: which state, and nothing of it.
    /// **No `default:`**, so a state added to Core has to be given its sentence here.
    static func sentence(_ quote: Quote, language: DummyLanguage? = nil) -> String {
        let key: String
        switch quote.state {
        // Accepted, and not here in full: a quote a level down, which came as an id alone.
        case .accepted: key = "quote.state.shallow"
        case .pending: key = "quote.state.pending"
        case .rejected: key = "quote.state.rejected"
        case .revoked: key = "quote.state.revoked"
        case .deleted: key = "quote.state.deleted"
        case .unauthorized: key = "quote.state.unauthorized"
        case .blockedAccount: key = "quote.state.blockedAccount"
        case .blockedDomain: key = "quote.state.blockedDomain"
        case .mutedAccount: key = "quote.state.mutedAccount"
        case .unknown: key = "quote.state.unknown"
        }
        return L10n.t(key, language: language)
    }

    /// What the quoted post's own quote is, one level down: that there is one, and nothing of it.
    static func nested(_ quote: NestedQuote, language: DummyLanguage? = nil) -> String {
        L10n.t(quote.state == .accepted ? "quote.nested" : "quote.nested.hidden", language: language)
    }

    /// The quoted post's words as a line may carry them: on one line, or the cover in their place.
    static func shownWords(_ post: QuotedPost, lifted: Bool, language: DummyLanguage? = nil) -> String {
        guard !post.covered || lifted else {
            let warning = post.spoiler ?? ""
            return warning.isEmpty
                ? L10n.t("quote.covered", language: language)
                : String(format: L10n.t("quote.covered.warning", language: language), warning)
        }
        return post.body.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// What the decorator says: who is quoted, or in a few words why the quote cannot be shown.
    /// **No `default:`**, for `sentence`'s reason.
    static func decorator(_ quote: Quote, language: DummyLanguage? = nil) -> String {
        if let post = quote.post {
            return String(format: L10n.t("quote.decorator", language: language), post.handle)
        }
        let key: String
        switch quote.state {
        case .accepted: key = "quote.short.shallow"
        case .pending: key = "quote.short.pending"
        case .rejected: key = "quote.short.rejected"
        case .revoked: key = "quote.short.revoked"
        case .deleted: key = "quote.short.deleted"
        case .unauthorized: key = "quote.short.unauthorized"
        case .blockedAccount: key = "quote.short.blockedAccount"
        case .blockedDomain: key = "quote.short.blockedDomain"
        case .mutedAccount: key = "quote.short.mutedAccount"
        case .unknown: key = "quote.short.unknown"
        }
        return L10n.t(key, language: language)
    }

    /// What a listener hears of the decorator: the quoted post as `spoken` says it, or the state's
    /// whole sentence where it cannot be shown — and **while the quoting post is covered, only who
    /// it quotes**, as the drawn decorator says: the quoted words are under the same cover.
    static func spokenMark(
        _ quote: Quote, lifted: Bool, covered: Bool = false, language: DummyLanguage? = nil
    ) -> String {
        if covered { return decorator(quote, language: language) }
        return quote.post.map { spoken($0, lifted: lifted, language: language) } ?? sentence(quote, language: language)
    }

    /// What a listener hears of the quote: `Quoting <author>: <words>`, the cover in the words'
    /// place while it is on, and the quoted post's own quote after.
    static func spoken(_ post: QuotedPost, lifted: Bool, language: DummyLanguage? = nil) -> String {
        let quoting = String(
            format: L10n.t("quote.spoken", language: language),
            post.author, shownWords(post, lifted: lifted, language: language)
        )
        guard let inner = post.quoting else { return quoting }
        return quoting + ". " + nested(inner, language: language)
    }
}

/// The quote in the row's decorator, beside `boosted by` and in its shape: a glyph and a few
/// words, one line, the decorator's ink. Pressed — or `o`, or its action — it opens the quoted post.
struct QuoteMark: View {
    let quote: Quote
    var lifted: Bool = false
    /// Whether the quoting post is covered, which covers what it quotes too.
    var covered: Bool = false
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "quote.opening")
            Text(QuoteBand.decorator(quote))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuoteBand.spokenMark(quote, lifted: lifted, covered: covered))
        .modifier(QuotePress(onOpen: onOpen))
    }
}

/// The quoted post, whole, inside the post that quotes it — the pane's drawing of `QuoteBand`.
///
/// **Set apart more firmly than a forum's quotation** (`ForumQuotation`, a hairline): a plate of
/// its own (`ShellChrome.raised`) with a soft shadow under it, and a border of the lamp's width in
/// the faint ink, all the way round — because a quoted post is somebody else's whole post, an
/// author and a date of its own, and must never read as more of this one. Under Increase Contrast
/// the shadow goes and the border takes the full ink.
///
/// **Its cover is kept.** Covered, the words and what it carries are not drawn at all — not
/// blurred, not in the accessibility tree — and the cover is the way in, as on a row.
struct QuoteCard: View {
    let post: QuotedPost
    let host: String
    let lifted: Bool
    var onOpen: (() -> Void)?
    var onToggleCover: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ShellMetric(relativeTo: .body) private var face: CGFloat = 20
    @ShellMetric(relativeTo: .body) private var thumb: CGFloat = 56
    @ShellMetric(relativeTo: .body) private var coverBox: CGFloat = 36

    private var covered: Bool { post.covered && !lifted }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            header
            if post.covered { notice }
            if covered {
                coverPlate
            } else {
                words
                attachments
            }
            if let nested = post.quoting {
                Text(QuoteBand.nested(nested))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
        }
        .padding(ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { plate }
        .overlay {
            RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous)
                .strokeBorder(border, lineWidth: DummyItemRow.Box.lamp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuoteBand.spoken(post, lifted: lifted))
        .accessibilityActions { coverAction }
        .modifier(QuotePress(onOpen: onOpen))
    }

    private var increased: Bool { contrast == .increased }

    private var border: Color {
        increased ? ShellChrome.ink(colorScheme) : ShellChrome.inkFaint(colorScheme)
    }

    /// The card's own surface, and its shadow — on the shape alone, so the words on it cast none.
    private var plate: some View {
        RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous)
            .fill(ShellChrome.raised(colorScheme))
            .shadow(color: increased ? .clear : ShellChrome.lift(colorScheme), radius: 3, y: 1)
    }

    /// The cover, worked by a listener: only where the author put one.
    @ViewBuilder
    private var coverAction: some View {
        if post.covered {
            Button(L10n.t(covered ? "quote.lift" : "quote.cover"), action: onToggleCover)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: ShellSpace.tight) {
            Group {
                if let url = post.avatarURL {
                    RemoteImage(
                        url: url, tier: .deck, host: host, standing: .avatar, alt: nil,
                        speaks: false, radius: ShellSpace.tight
                    )
                } else {
                    ShellVacant(standing: .avatar, radius: ShellSpace.tight)
                }
            }
            .frame(width: face, height: face)
            EmojiText(post.author, emojis: post.emojis, host: host, role: .name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .layoutPriority(1)
            EmojiText(post.handle, emojis: post.emojis, host: host, role: .meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: ShellSpace.tight)
            Text(post.postedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The cover mark, and the author's warning beside it where they wrote one.
    private var notice: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            CoverChip(lifted: !covered)
            if let warning = post.spoiler, !warning.isEmpty {
                EmojiText(warning, emojis: post.emojis, host: host)
                    .fontWeight(.medium)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
    }

    /// The cover: a plate with nothing of the post under it, pressed to lift.
    private var coverPlate: some View {
        Button(action: onToggleCover) {
            Hatch()
                .stroke(ShellChrome.hatch(colorScheme), lineWidth: ShellSpace.hair)
                .frame(maxWidth: .infinity)
                .frame(height: coverBox)
                .background(ShellChrome.well(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var words: some View {
        EmojiText.words(post.body, emojis: post.emojis, host: host, covered: false)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What it carries, a small still each, in the order it was listed.
    @ViewBuilder
    private var attachments: some View {
        if !post.attachments.isEmpty {
            HStack(spacing: ShellSpace.tight) {
                ForEach(post.attachments.indices, id: \.self) { index in
                    QuoteThumb(attachment: post.attachments[index], host: host, side: thumb)
                }
            }
        }
    }
}

/// Where a press on a quote goes (#214): the root's walk, handed down once as `ShellTags` is, so
/// every row reads one object rather than a closure that differs each pass.
///
/// **Nothing, and a quote is drawn and opens nowhere** — a preview, a test drawing a row alone.
@MainActor
final class ShellQuotes {
    /// The walk's own answer to a press: whether the quoted post was opened. Set by the root.
    var opening: (@MainActor (DummyItem) -> Bool)?
    /// The row the quote leads to, where this device holds it. Set by the root.
    var target: (@MainActor (DummyItem) -> String?)?

    @discardableResult
    func open(_ item: DummyItem) -> Bool {
        opening?(item) ?? false
    }

    /// Whether this row's quote leads anywhere to open: **a post this device holds**, never the
    /// promise of one. A press, `o` and the action are offered only then.
    func leads(from item: DummyItem) -> Bool {
        guard let quote = item.quote, quote.state == .accepted else { return false }
        return target?(item) != nil
    }
}

extension EnvironmentValues {
    /// See `ShellQuotes`.
    @Entry var shellQuotes: ShellQuotes?
}

extension ShellSession {
    /// The row the post `item` quotes, where this device holds it (#214): the quoted post held
    /// aside with it, or — for a quote that came as an id alone, a level down — the post this
    /// source gave that id, where it is held at all. Nothing where the quote may not be shown.
    func quotedRow(of item: DummyItem) -> String? {
        if let id = item.quotedRowID { return heldNote(id) == nil ? nil : id }
        guard let quote = item.quote, quote.state == .accepted, let statusID = quote.statusID else {
            return nil
        }
        let host = item.source.host
        let matches = { (note: Note) in note.source.host == host && note.statusID == statusID }
        return (notes.first(where: matches) ?? aside.first(where: matches))?.key.rowID
    }
}

extension ShellDecks {
    /// Whether the reader lifted the cover of the post `item` quotes — that post's own row's
    /// cover, so a quote lifted is the post lifted where it opens, and the other way round.
    func isQuoteLifted(of item: DummyItem) -> Bool {
        item.quotedRowID.map(isLifted) ?? false
    }

    /// The cover of the post `item` quotes, lifted or put back.
    mutating func toggleQuoteCover(of item: DummyItem) {
        guard let id = item.quotedRowID else { return }
        _ = toggleCover(id)
    }
}

/// A quote as a press, where it opens anything: the finger's way and the listener's. **Where it
/// opens nothing, no press at all** — a touch falls through to the row under it, which it lights,
/// and a listener is offered no action that would be refused.
private struct QuotePress: ViewModifier {
    let onOpen: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onOpen {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(L10n.t("quote.open")), onOpen)
        } else {
            content
        }
    }
}

/// One still of what a quoted post carries.
private struct QuoteThumb: View {
    let attachment: FediqoCore.Attachment
    let host: String
    let side: CGFloat

    var body: some View {
        RemoteImage(
            url: attachment.displayURL, tier: .deck, host: host, standing: .picture,
            alt: attachment.alt.isEmpty ? nil : attachment.alt, speaks: false,
            radius: ShellSpace.tight
        )
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous))
    }
}
