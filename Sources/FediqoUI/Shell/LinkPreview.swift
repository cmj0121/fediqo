import FediqoCore
import SwiftUI

// The preview of the page a post links to, under the post (#335).
//
// **Not a second post.** A quote is a post and is drawn on a raised plate with its author's face;
// a preview is a page somewhere else, so it is drawn flat on the chassis, framed by one hairline,
// and the one thing it says in full ink is what the page is called. Where it leads is said in the
// words this app says every destination in — the host, in ASCII (`SourceWork.fold`) — beside the
// link glyph, and **never the provider's name**: that is the page's own word about itself, and a
// stranger's page may call itself anything.
//
// **One height, wherever it is drawn** (#245):
// - in a list, one line among the words, in the line it took from them (`DummyItemRow.bodyLines`),
//   and its picture in the slot a post with no media of its own keeps open — the slot's size, so
//   the row is the height of every row;
// - in the post opened to be read, a band under the words whose height is its lines' (each line
//   held to one), and a picture drawn into a frame that waits for it. **The card itself does not
//   come with the post on a Mastodon**: its worker attaches it a second or two later (asked of a
//   real one, `MastodonCardCaptures`), so a post opened before then gains the band when the
//   card lands, and what is drawn under the post — its answers — moves down by the band. In a
//   list nothing moves: the line was the words' already.
//
// **Drawn only where the person lets it, and the post has nothing of its own to show**: the
// preference on, no media on the post, no cover still on it. Its picture only where the gate lets
// it through (`SourceWork.admits`) as a picture the post's own source pointed to — and it is then
// asked as one (`RemoteImage`, under that source), and listed under that source in the run's
// record. With the preference off, or the picture not let through, nothing is asked, and the row
// is whole without it.

/// What a row draws of its post's preview: the card, where it leads, and its picture where that
/// may be asked.
struct LinkPreview: Equatable {
    let card: PostCard
    /// The source the post came through: what the picture is read under.
    let host: String
    /// Where a press goes, as the host a destination is named by — nothing where the card leads
    /// nowhere this app follows.
    let leadsTo: String?
    /// The picture, only where the gate lets it through for this source.
    let picture: URL?

    /// The preview of `item`, where it has one to draw: previews on, a card, no media of its own.
    /// `admits` is the gate's word on the picture's host for the post's source.
    static func of(_ item: DummyItem, shown: Bool, admits: (_ reached: String, _ source: String) -> Bool) -> LinkPreview? {
        guard shown, let card = item.card, item.attachments.isEmpty else { return nil }
        let host = item.source.host
        // The gate compares hosts in its own one spelling (`SourceWork.fold`), and is asked in it.
        let picture = card.image.flatMap { url in url.host().map { admits(SourceWork.fold($0), host) } == true ? url : nil }
        return LinkPreview(card: card, host: host, leadsTo: card.url?.host().map(SourceWork.fold), picture: picture)
    }

    /// Whether the card is called by the host it leads to — one whose page gave it no title
    /// (`PostCard`): the host is then said once, as its name, and not again as where it leads.
    var namedByHost: Bool {
        leadsTo != nil && SourceWork.fold(card.title) == leadsTo
    }

    /// What the card is called, as drawn: the host it leads to where that is its name.
    var title: String { namedByHost ? leadsTo ?? card.title : card.title }

    /// The line under the title: where a press goes, or that it goes nowhere this app opens.
    /// Nothing where the title is that host already.
    func whereItLeads(language: DummyLanguage? = nil) -> String? {
        if namedByHost { return nil }
        return leadsTo ?? L10n.t("card.nowhere", language: language)
    }

    /// What a listener is told: that this is the page the post links to, what it is called, and
    /// where a press goes — and, in the opened post (`described`), what the page says it is about.
    func spoken(described: Bool = false, language: DummyLanguage? = nil) -> String {
        let said: String
        if let leadsTo {
            said = namedByHost
                ? String(format: L10n.t("card.spoken.host", language: language), leadsTo)
                : String(format: L10n.t("card.spoken", language: language), card.title, leadsTo)
        } else {
            said = String(format: L10n.t("card.spoken.nowhere", language: language), card.title)
        }
        guard described, let description = card.description else { return said }
        return String(format: L10n.t("card.spoken.about", language: language), said, description)
    }
}

/// The preview on a row in a list: one line among the words — the link glyph, the title, and
/// where it leads — pressed to open the link.
struct LinkLine: View {
    let preview: LinkPreview
    let open: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let url = preview.card.url {
            Button { open(url) } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel(preview.spoken())
                .accessibilityAddTraits(.isLink)
                .help(url.absoluteString)
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(preview.spoken())
        }
    }

    private var face: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "link")
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityHidden(true)
            Text(preview.title)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .layoutPriority(1)
            if let whereItLeads = preview.whereItLeads() {
                Text(whereItLeads)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
        .shellFont(.meta)
        .lineLimit(1)
    }
}

/// The preview under the post opened to be read: what the page is called, what it says it is
/// about, and where it leads, in a frame of one hairline — its picture beside them on a narrow
/// page, where the post has no slot beside its words to draw it in.
struct LinkBand: View {
    let preview: LinkPreview
    /// Whether the picture is drawn here: a narrow page, which keeps no slot beside the words.
    let picture: Bool
    let open: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ShellMetric(relativeTo: .body) private var side: CGFloat = 56

    var body: some View {
        if let url = preview.card.url {
            Button { open(url) } label: { face }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(preview.spoken(described: true))
                .accessibilityAddTraits(.isLink)
                .help(url.absoluteString)
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(preview.spoken(described: true))
        }
    }

    private var face: some View {
        HStack(alignment: .top, spacing: ShellSpace.snug) {
            if picture, let url = preview.picture {
                RemoteImage(url: url, tier: .deck, host: preview.host, alt: nil, speaks: false, radius: ShellSpace.tight)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous))
            }
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(preview.title)
                    .shellFont(.body, weight: .semibold)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                if let description = preview.card.description {
                    Text(description)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                }
                // Where it leads, once: a card named by its host says it in its title.
                if let whereItLeads = preview.whereItLeads() {
                    HStack(spacing: ShellSpace.tight) {
                        Image(systemName: "link")
                        Text(whereItLeads)
                    }
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous)
                .strokeBorder(contrast == .increased ? ShellChrome.ink(colorScheme) : ShellChrome.hairline(colorScheme), lineWidth: 1)
        }
    }
}

/// The preview's picture in the slot a post with no media of its own keeps open: the slot's
/// square, pressed to open the link as the line under the words does.
struct LinkPicture: View {
    let preview: LinkPreview
    let url: URL
    let side: CGFloat
    let open: (URL) -> Void

    var body: some View {
        let picture = RemoteImage(url: url, tier: .deck, host: preview.host, alt: nil, speaks: false, radius: DummyItemRow.Box.plate)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous))
            // The line among the words names the same page: one press read out, not two.
            .accessibilityHidden(true)
        if let link = preview.card.url {
            Button { open(link) } label: { picture }
                .buttonStyle(.plain)
        } else {
            picture
        }
    }
}
