import SwiftUI
import FediqoCore

/// One row, in bands. Each is the whole width and each answers one question:
///
/// ```text
/// what happened to this post before it got here   (only when something did)
/// who wrote it, where it reached us, and when
/// what it says              │ what came attached
/// what can be done about it
/// what it was written with                        (right, and often empty)
/// ```
///
/// **The two columns are only the middle band**, and only where there is room for them: the
/// words on the left, the attachments on the right, in a column that stays there whether or
/// not anything is in it. That empty column is the point — it is what keeps every row's text
/// starting and ending in the same place down a long list. Below `fediqoWideRows` there is
/// nothing to spend on it and the attachments go back under the words.
///
extension Post {
    /// Whether the author covered anything here: a line in front of the words, media behind a
    /// blur, or both. What the key asks before it does anything, and the row asks before it
    /// draws a control for it.
    var hidesSomething: Bool { sensitive == true || !(spoiler ?? "").isEmpty }
}

/// Every row is the same height, set by the attachment card: a short post is padded up to it
/// and a long one stops at it with an ellipsis. What the ellipsis is hiding is what opening
/// the post is for.
struct PostRow: View {
    let post: Post
    /// Whether this is the row the reader is on. The row is told rather than asking: which
    /// post the ring is on belongs to the feed, and a row knows nothing but itself.
    var selected = false
    /// Bumped when `m` is pressed while this row is the one the reader is on — the deck turns
    /// itself over, and which one is on top stays the deck's own business.
    var turns = 0
    /// Bumped when `p` is pressed on this row: what is on top of the deck plays, or stops.
    var plays = 0
    /// Bumped when `s` is pressed on this row: what the author covered is lifted, or put back.
    /// The key and the button beside the warning are one control reached two ways, so they
    /// end in the same line and cannot come to disagree about which way the row is going.
    var covers = 0
    /// Whether what this post covered arrives uncovered. The reader's standing answer; a row
    /// can still be opened by hand without changing it.
    var revealed = false
    /// Whether this is a row in a list rather than the post itself, opened.
    ///
    /// In a list it is held to the same height as every other row and its words stop with an
    /// ellipsis — which is the row saying there is more, and `Return` is how to get it. The
    /// opened post is where the whole of it lives, so nothing is clamped there.
    var condensed = true
    /// What a click on the row asks for. `nil` in a preview and in the detail page itself,
    /// where opening what you are already looking at means nothing.
    var open: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.fediqoWideRows) private var wide
    /// The reader's text size, because how many lines fit in a card depends on it.
    @Environment(\.fediqoTextScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    /// What this reader decided about this post, or nothing where they have not decided.
    ///
    /// `nil` follows the standing preference; a press of the button is an answer of its own and
    /// wins over it **in both directions** — a reader who turned everything on can still put
    /// one post back behind its warning. It lasts as long as the app is open and is never
    /// written down: which posts somebody chose to read is a reading record, and this app
    /// keeps none.
    @State private var reveal: Bool?

    /// How much of a post a row shows before it stops — worked out from the height it has to
    /// fit in rather than fixed at a number of lines.
    ///
    /// The reader's text size moves what a line is, and this app's own default is the largest
    /// of them: a count that fits at 13 points overflows the card at 21. So the count follows
    /// the size, and every row still stops at the same place as every other row, which is what
    /// keeps the list level. 1.35 is the line height a `Text` gives itself around its point
    /// size; three lines is the floor, because a row that shows one line of a paragraph is not
    /// showing a post at all.
    private var lines: Int {
        max(3, Int(AttachmentDeck.height / (TypeScale.body * scale * 1.35)))
    }

    private var spoiler: String { post.spoiler ?? "" }
    /// One answer for both halves, the way the preference is one switch for both: the words
    /// behind their line and the media behind its blur are the same act to a reader.
    private var shown: Bool { reveal ?? revealed }
    private var wordsAreCovered: Bool { !spoiler.isEmpty && !shown }
    private var mediaIsCovered: Bool { post.sensitive == true && !shown }

    /// What `covers` stood at when the ring arrived here, or nothing while it is elsewhere.
    ///
    /// Without it the count alone would lie. Every row but the selected one is handed a zero,
    /// so a ring moving onto a post takes its `covers` from 0 to however many times the key
    /// has been pressed anywhere — which reads as a press and would lift the cover off a post
    /// the reader has only just arrived at. That is the one thing a cover must never do, so
    /// the row remembers where the count was when it became the reader's and acts only on
    /// what happens after.
    @State private var coversOnArrival: Int?

    var body: some View {
        content
            .onChange(of: selected, initial: true) { _, now in
                coversOnArrival = now ? covers : nil
            }
            .onChange(of: covers) { _, now in
                guard selected, let arrival = coversOnArrival, now > arrival else { return }
                coversOnArrival = now
                withAnimation(Motion.appearing) { reveal = !shown }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            decorator
            metadata
            if wide {
                HStack(alignment: .top, spacing: Space.gap) {
                    words
                    attachmentColumn
                }
                // Every row the same height, whatever is in it: the attachment card sets it,
                // a post of two words is padded up to it, and a long one is cut off at it with
                // an ellipsis saying there is more. The words are clamped to whatever number
                // of lines fits in that height at the reader's own text size, so nothing is
                // ever cut mid-line — the ellipsis is the row's, not the frame's.
                .frame(height: AttachmentDeck.height, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: Space.step) {
                    words
                    if !post.attachments.isEmpty { deck }
                }
            }
            InteractionBar(post: post, open: open)
            footer
        }
        .padding(Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
        .fediqoFocusRing(selected)
        // A tap on the row opens the post. Not a `Button`: the words are selectable, the deck
        // turns itself over and the interaction bar has buttons of its own, and wrapping the
        // lot in one would take every one of those clicks away from them.
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .contextMenu {
            if open != nil { Button(t("post.open")) { open?() } }
            if let url = post.webURL {
                Button(t("timeline.open")) { openURL(url) }
            }
        }
    }

    /// The band above everything: what happened to this post before it reached the reader.
    ///
    /// Today that is one thing — somebody boosted it — because a boost is the only such fact
    /// a timeline read hands over. Favourites and the rest arrive with notifications (#9), and
    /// when they do this is the line they are said on, rather than a second design for the
    /// same idea. Nothing at all is drawn when there is nothing to say.
    @ViewBuilder
    private var decorator: some View {
        if let boostedBy = post.boostedBy {
            Label(t("timeline.boostedBy", boostedBy), systemImage: "arrow.2.squarepath")
                .fediqoFont(TypeScale.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Who wrote it, where it reached us, and when. The whole width, above both columns: it
    /// is about the post rather than about its words, and an avatar in a gutter beside the
    /// text would make the text column start in a different place from the row above it.
    private var metadata: some View {
        HStack(spacing: Space.step) {
            RemoteImage(url: post.authorAvatarURL, width: Size.avatar, height: Size.avatar)
            Text(post.authorName).fediqoFont(TypeScale.body, weight: .semibold).lineLimit(1)
            Text(post.authorHandle).fediqoFont(TypeScale.minor).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: Space.snug)
            sources
            Text(post.createdAt, format: .relative(presentation: .numeric))
                .fediqoFont(TypeScale.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// The left column: what they said, and the line in front of it where there is one.
    private var words: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            if !spoiler.isEmpty { warning }
            if !post.text.isEmpty, !wordsAreCovered {
                Text(post.text)
                    .fediqoFont(TypeScale.body)
                    .textSelection(.enabled)
                    .lineLimit(condensed ? lines : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !condensed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line the author put in front of their words, and the way past it.
    ///
    /// A band rather than a line of small print: it is the one thing on a row that says "what
    /// is under here is not what you were expecting", and it has to be read before the words
    /// are, not after. The warning stays up whether or not the words behind it are showing —
    /// taking it away once somebody has read past it would remove the only thing saying what
    /// they are looking at — and the button beside it works both ways, so a reader who has
    /// everything turned on can still put one post back.
    private var warning: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.step) {
            Image(systemName: "exclamationmark.triangle.fill")
                .fediqoSymbol(Glyph.inline)
                .foregroundStyle(.orange)
            Text(spoiler)
                .fediqoFont(TypeScale.small, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.step)
            toggle
        }
        .padding(.horizontal, Space.gap)
        .padding(.vertical, Space.step)
        .background(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Show, or hide again. One control, both ways, and it says which way it is about to go.
    private var toggle: some View {
        Button {
            withAnimation(Motion.appearing) { reveal = !shown }
        } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: shown ? "eye.slash" : "eye")
                    .fediqoSymbol(Glyph.badge)
                Text(t(shown ? "post.covered.hide" : "post.covered.show"))
                    .fediqoFont(TypeScale.caption, weight: .semibold)
            }
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.tight)
            .background(Capsule().fill(Color.orange.opacity(colorScheme == .dark ? 0.28 : 0.20)))
            .foregroundStyle(.orange)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(t(shown ? "post.covered.hide" : "post.covered.show"))
    }

    /// The right column. It is there whether or not anything is in it — that is what keeps the
    /// words the same width down the whole list — and when it is empty it is nothing at all:
    /// no frame, no dashes, no "no attachments". A visible empty box on every second post
    /// reads as something broken.
    @ViewBuilder
    private var attachmentColumn: some View {
        if post.attachments.isEmpty {
            Color.clear.frame(width: AttachmentDeck.side, height: 0)
        } else {
            deck
        }
    }

    private var deck: some View {
        AttachmentDeck(attachments: post.attachments, covered: mediaIsCovered,
                       turns: turns, plays: plays) {
            withAnimation(Motion.appearing) { reveal = true }
        }
    }

    /// The foot of the row: what the post was written with.
    ///
    /// Under everything, and quietly, because it is the least of what a row says — it is about
    /// neither the person nor the words. It is absent far more often than not: a server tells
    /// you what its own writers used and says nothing about a post that reached it from
    /// somewhere else. Nothing is drawn then. "Unknown app" would be a claim nobody made.
    @ViewBuilder
    private var footer: some View {
        if post.application == nil {
            // Held open, because most posts have nothing to say here and a list where every
            // other row is nine points shorter is a list that never sits still.
            if condensed { Color.clear.frame(height: TypeScale.minor * scale) }
        } else if let application = post.application {
            // At the right, alone. It is the only line in the row that is about none of the
            // three — not the person, not the words, not what can be done — and the far end is
            // where a reader's eye goes last.
            HStack(spacing: Space.tight) {
                Spacer(minLength: 0)
                Text(t("post.writtenWith")).fediqoFont(TypeScale.micro).foregroundStyle(.tertiary)
                if let website = application.website {
                    Link(application.name, destination: website)
                        .fediqoFont(TypeScale.micro)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(application.name).fediqoFont(TypeScale.micro).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Which server handed it over — and when two did, it says both. It sits in the metadata
    /// band beside who wrote it and when, because it is the same kind of fact: where this post
    /// reached us from, rather than anything about what it says.
    private var sources: some View {
        HStack(spacing: Space.snug) {
            Text(t("timeline.via")).fediqoFont(TypeScale.caption).foregroundStyle(.tertiary)
            ForEach(post.sources, id: \.self) { host in
                Text(host).fediqoFont(TypeScale.caption).fediqoPill()
            }
        }
    }
}

/// An avatar or a thumbnail: the same fetch, placeholder and clip wherever a picture comes
/// off a server rather than out of the bundle.
struct RemoteImage: View {
    @Environment(\.colorScheme) private var colorScheme
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = Radius.thumbnail

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Palette.hairline(colorScheme))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
