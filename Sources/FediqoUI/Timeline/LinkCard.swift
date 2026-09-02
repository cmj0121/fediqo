import SwiftUI
import FediqoCore

/// What a link says it is, drawn where the pictures go.
///
/// **In the attachment column, and only where there are no attachments.** The column is already
/// there on every row, already the row's height, and already the place a reader's eye goes for
/// "what is in this post besides words" — so a card needs no space of its own and cannot make a
/// row taller than its neighbour, which S6 would not have. And a post that has both its own
/// pictures and a link shows the pictures: the media is the author's, the card is somebody
/// else's page, and the author's own comes first.
///
/// **Every byte of it comes from the server that handed the post over.** The title, the words
/// and the picture were fetched by that server, from the site, on its own account; the picture
/// is served from its media storage rather than from the site. Nothing here asks the linked host
/// anything, and nothing here may — a request to it would tell that host this device read this
/// post at this time, which `docs/privacy.md` says never happens. See `Card`.
struct LinkCard: View {
    let card: Card
    /// Covered with the rest of the post's media: the words behind a warning and the pictures
    /// behind a blur are one act to a reader, and a link's picture is a picture.
    var covered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    /// The deck's own size, taken from it rather than agreed with it: a row with a card and a
    /// row with pictures have to be the same row, and two numbers that must match are one
    /// number written once.
    private var side: CGFloat { AttachmentDeck.side }
    private var height: CGFloat { AttachmentDeck.height }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            picture
            // Only under the words, and only where there are words. A scrim over a card that
            // says nothing is a shadow with nothing to make legible.
            if saysSomething { scrim }
            if saysSomething { said }
        }
        .frame(width: side, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
            .strokeBorder(Palette.hairline(colorScheme)))
        .contentShape(Rectangle())
        .onTapGesture { if !covered { openURL(card.url) } }
        .help(card.url.absoluteString)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isLink)
    }

    private var saysSomething: Bool { !card.title.isEmpty || !card.provider.isEmpty }

    /// The picture the server fetched, or the card's own ground where it sent none. Never a
    /// placeholder that looks like a broken image: a link without a picture is an ordinary
    /// link, not a failure.
    private var picture: some View {
        RemoteImage(url: covered ? nil : card.imageURL, width: side, height: height,
                    radius: Radius.inner, standing: covered ? .covered : .picture)
            .blur(radius: covered ? 18 : 0)
    }

    /// Dark under the words and clear above them, so a title over a bright photograph is still
    /// a title. Drawn rather than a flat wash over the whole card, which would dim the picture
    /// everywhere to make legible the third of it that needed it.
    private var scrim: some View {
        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.72)],
                       startPoint: .center, endPoint: .bottom)
    }

    /// What the site calls itself, then what it called this page. That order, because the site
    /// is what a reader decides on — the title is somebody else's headline, and the host is the
    /// only part of a link that says who is being trusted.
    private var said: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            if !card.provider.isEmpty {
                Text(card.provider)
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            if !card.title.isEmpty {
                Text(card.title)
                    .fediqoFont(TypeScale.small, weight: .medium)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a reader who cannot see it is told, and nothing that was invented on the way.
    ///
    /// The picture's own alt text is the server's, where it sent one. Where it did not, this
    /// says nothing about the picture rather than describing it — nobody here has looked at it.
    private var label: String {
        [card.provider, card.title, card.imageAlt, card.url.absoluteString]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
