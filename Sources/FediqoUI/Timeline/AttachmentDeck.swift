import SwiftUI
import FediqoCore

/// What came attached, drawn as a deck.
///
/// Several attachments are not a row of thumbnails here: they are a stack with one on top, and
/// clicking it turns the stack over. There is no lightbox and no gallery — nothing that has to
/// be got out of again — which is why the deck can live in a column 200 points wide beside the
/// words rather than pushing them out of the way.
///
/// What can be played, plays here too, in the same rectangle the still was in: the mark on a
/// film or a clip is a button. Nothing starts by itself, and turning the stack over stops
/// whatever was playing — sound from a card the reader has just turned away from is a fault.
///
/// One attachment is one picture. A deck of one would be a stack that cannot be turned, which
/// is a control lying about what it can do.
struct AttachmentDeck: View {
    let attachments: [Attachment]
    /// Whether the deck arrives covered. The cover is the reader's to lift, and lifting it
    /// lasts as long as this run of the app and is never written down.
    var covered = false
    /// Bumped by the app when `m` is pressed on the row this deck belongs to. A count rather
    /// than a position: which one is on top belongs to the deck, and pressing the key twice
    /// means it twice.
    var turns = 0
    /// Bumped by the app when `p` is pressed on the row this deck belongs to.
    var plays = 0
    /// Asked when the reader lifts the cover from here. The answer belongs to the row: the
    /// words and the media are covered together and uncovered together, so a deck keeping its
    /// own idea of it would be a second answer to one question.
    var uncover: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var app
    /// Which attachment is on top. It belongs to the row, so a refresh that replaces the list
    /// leaves a reader who turned to the third one looking at the third one.
    @State private var top = 0

    /// The column's width, and the height of the card in it. Shared, because the words beside
    /// it are held to the same height: a list where every row is the same height is a list a
    /// reader can move through without the next post jumping to a different place each time.
    static let side: CGFloat = 200
    static var height: CGFloat { side * 0.68 }
    /// How many of the ones underneath are drawn behind the top card. Three is enough to say
    /// "there are more"; past that the edges stop being distinguishable anyway.
    private static let shown = 3

    private var showing: Attachment? {
        attachments.isEmpty ? nil : attachments[top % attachments.count]
    }

    private var hidden: Bool { covered }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            deck
            if attachments.count > 1 {
                Text(verbatim: "\(top % attachments.count + 1) / \(attachments.count)")
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .onChange(of: turns) { _, _ in turn() }
        // `p` on the row this deck belongs to plays what is on top of it, or stops it.
        .onChange(of: plays) { _, _ in
            guard let showing, showing.isPlayable else { return }
            play(showing)
        }
        // A deck that goes off the screen — the reader scrolled, or closed the post they had
        // opened — takes its sound with it. Nothing here is allowed to play out of sight.
        .onDisappear { if playing(showing) { app.playback.stop() } }
    }

    private var deck: some View {
        ZStack(alignment: .topLeading) {
            // The ones underneath, offset by a few points each so the stack has a thickness.
            // They are drawn as plain cards rather than as their own pictures: what is under
            // the top one is not something the reader can see anyway, and loading three more
            // images to show six points of each is a request nobody asked for.
            ForEach(0..<min(attachments.count - 1, Self.shown), id: \.self) { depth in
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Palette.raised(colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.hairline(colorScheme)))
                    .frame(width: Self.side, height: Self.height)
                    .offset(x: CGFloat(depth + 1) * Space.tight, y: CGFloat(depth + 1) * Space.tight)
            }
            top(showing)
        }
        .frame(width: Self.side + CGFloat(min(attachments.count - 1, Self.shown)) * Space.tight,
               height: Self.height + CGFloat(min(attachments.count - 1, Self.shown)) * Space.tight,
               alignment: .topLeading)
    }

    @ViewBuilder
    private func top(_ attachment: Attachment?) -> some View {
        if let attachment {
            ZStack(alignment: .bottomLeading) {
                if let player = app.playback.player, playing(attachment) {
                    AttachmentPlayer(player: player, audio: attachment.kind == .audio,
                                     width: Self.side, height: Self.height)
                } else {
                    still(attachment)
                }
            }
            .frame(width: Self.side, height: Self.height)
            .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Palette.hairline(colorScheme)))
            .accessibilityElement()
            .accessibilityLabel(Text(label(for: attachment)))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// What is drawn when nothing is playing: the still the server sent, the cover over it
    /// where the author asked for one, and the mark that says what is behind it.
    private func still(_ attachment: Attachment) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: hidden ? nil : attachment.displayURL,
                        width: Self.side, height: Self.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .blur(radius: hidden ? 18 : 0)
            if hidden {
                cover
            } else if let mark = symbol(for: attachment.kind) {
                // The mark is a button where the file is here to be played, and a label where
                // it is not: an attachment stored before 005 is a still with nothing behind
                // it, and a play button over one would promise something we cannot do.
                if attachment.isPlayable {
                    Button { play(attachment) } label: { badge(mark) }
                        .buttonStyle(.plain)
                        .help(t("post.media.play"))
                        .accessibilityLabel(Text(t("post.media.play")))
                } else {
                    badge(mark)
                }
            }
        }
        // The deck owns this click and does not pass it on: the row opens the post, and a
        // reader turning the stack over has not asked to leave the timeline. The play mark
        // sits above it and takes its own clicks first.
        .contentShape(Rectangle())
        .onTapGesture { hidden ? uncover() : turn() }
        .help(attachment.alt.isEmpty ? t("post.media.turn") : attachment.alt)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .fediqoSymbol(Glyph.badge)
            .padding(Space.snug)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(Space.snug)
    }

    private var cover: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: "eye.slash").fediqoSymbol(Glyph.badge)
            Text(t("post.covered.show")).fediqoFont(TypeScale.caption, weight: .medium)
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.snug)
        .background(.black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white)
        .padding(Space.step)
    }

    /// The one mark on a picture, and only where there is something to say. An image gets
    /// none — it is a picture and looks like one — and `unknown` gets none either, because a
    /// question mark over somebody's photograph claims something we do not know.
    private func symbol(for kind: Attachment.Kind) -> String? {
        switch kind {
        case .video: "play.fill"
        case .audio: "waveform"
        case .image, .unknown: nil
        }
    }

    /// Said out loud: which one this is, what kind of thing it is, and what its author wrote
    /// for it. A deck that will not say "two of three" is a deck nobody can navigate blind.
    private func label(for attachment: Attachment) -> String {
        let described = attachment.alt.isEmpty ? t("post.media.\(attachment.kind.rawValue)") : attachment.alt
        guard attachments.count > 1 else { return described }
        return t("post.media.position", top % attachments.count + 1, attachments.count) + " " + described
    }

    private func turn() {
        guard attachments.count > 1 else { return }
        // Turning away from something that is playing stops it. What is on top is what the
        // reader is looking at, and a film that goes on playing behind the card in front of
        // it is a sound coming from nowhere.
        if playing(showing) { app.playback.stop() }
        withAnimation(Motion.appearing) { top = (top + 1) % attachments.count }
    }

    private func play(_ attachment: Attachment) {
        guard let url = attachment.url else { return }
        app.playback.toggle(url)
    }

    private func playing(_ attachment: Attachment?) -> Bool {
        app.playback.isPlaying(attachment?.url)
    }
}
