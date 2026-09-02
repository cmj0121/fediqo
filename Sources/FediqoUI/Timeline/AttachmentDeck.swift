import SwiftUI
import FediqoCore

/// What came attached, drawn as a deck.
///
/// Several attachments are not a row of thumbnails here: they are a stack with one on top,
/// which is why the deck can live in a column 200 points wide beside the words rather than
/// pushing them out of the way.
///
/// **This used to say there was no lightbox and no gallery, on purpose.** That was overturned
/// in #41: the one thing a reader most wants from a picture is to see it, and a column 200
/// points wide is not seeing it. A press opens it over the app — `MediaViewer` — and `m` turns
/// the deck without opening anything. What was right about the old rule survives: there is
/// still nothing to get lost in, and one press of `Escape` is the whole of getting out.
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
    /// How wide to draw, where that is not the reserved column's width.
    ///
    /// **Before `uncover`**, which is a closure a call site writes as a trailing one: a
    /// parameter declared after it takes that closure instead, which `PostRow.open` has a
    /// comment about and which this got wrong first.
    ///
    /// The column is `AttachmentDeck.side` wide and the card fills it exactly — that is what
    /// reserving it is for. Stacked under the words there is no reserved column, only the row,
    /// and the row is narrower than the card on a phone: 400 points of picture in 350 points of
    /// row is the picture drawn over both edges, which is #78's failure returning with a bigger
    /// card. So the arrangement that has no column says how much it has, and the card is that
    /// wide or `side`, whichever is less.
    var width: CGFloat?
    var uncover: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var app
    /// Which attachment is on top. It belongs to the row, so a refresh that replaces the list
    /// leaves a reader who turned to the third one looking at the third one.
    @State private var top = 0

    /// The column's width, and the height of the card in it.
    ///
    /// **Twice what it was**, which is the whole of #79's second half. At 200 a photograph was a
    /// thumbnail, and a reader deciding whether to open it was deciding from something too small
    /// to decide from.
    ///
    /// It could not be doubled while the row was this tall: S6 padded every row up to it, so a
    /// two-line post with no picture at all became four hundred points of mostly nothing and a
    /// window held two posts instead of five — measured, and the reason #79 waited for a rule to
    /// be settled rather than for a number to be picked. S6 says a row is as tall as its content
    /// now, so the card is a card and not every row's height.
    ///
    /// The words beside it are no longer held to this. `PostRow.words` keeps the height they
    /// were clamped to before, so a bigger picture is a bigger picture and not also a longer
    /// excerpt.
    static let side: CGFloat = 400

    /// What this deck is actually drawn at: the reserved column's width, or the room it was
    /// given where that is narrower. One place, so the six frames below cannot disagree.
    private var side: CGFloat { min(width ?? Self.side, Self.side) }
    private var height: CGFloat { side * Self.ratio }
    static var height: CGFloat { side * ratio }
    /// The shape of a card, kept apart from its size so that a narrower one is the same shape.
    static let ratio: CGFloat = 0.68
    /// How many of the ones underneath are drawn behind the top card. Three is enough to say
    /// "there are more"; past that the edges stop being distinguishable anyway.
    private static let shown = 3

    /// How far each one underneath steps out from the one above it, and how much of an edge
    /// it is allowed to draw.
    ///
    /// Named numbers on this view rather than tokens, because neither is a gap between two
    /// things: they are the thickness of a sheet of paper and the shadow along its edge, and
    /// they belong to this drawing and to nothing else — which is what S8 allows.
    ///
    /// Three quarters of `Space.tight` and half a hairline. The stack used to step out a full
    /// four points with a whole hairline around each sheet, which drew three bordered slabs
    /// beside the picture and competed with it; at two points and no border at all the edges
    /// then said nothing, and a reader learned there were more only from the counter
    /// underneath. This is the middle: enough paper to see, not enough to look at.
    private static let leaf: CGFloat = Space.tight * 0.75
    private static let edge: Double = 0.5

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
        .frame(width: side, alignment: .leading)
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
            // The ones underneath, offset by a couple of points each so the stack has a
            // thickness. They are drawn as plain cards rather than as their own pictures:
            // what is under the top one is not something the reader can see anyway, and
            // loading three more images to show a few points of each is a request nobody
            // asked for.
            //
            // **Paper under a photograph, not cards of their own** (#79). They used to step
            // out four points each with a hairline around every one, which drew three
            // bordered slabs beside the picture — a shape that competed with the picture for
            // the eye, on every post with more than one attachment. Now they step out two,
            // each fainter than the one above it, and none of them has a border insisting on
            // itself. What a reader sees is the photograph; what the edges tell them is only
            // that there are more.
            ForEach(0..<min(attachments.count - 1, Self.shown), id: \.self) { depth in
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Palette.raised(colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.hairline(colorScheme).opacity(Self.edge)))
                    .opacity(1 - Double(depth) * 0.25)
                    .frame(width: side, height: height)
                    .offset(x: CGFloat(depth + 1) * Self.leaf, y: CGFloat(depth + 1) * Self.leaf)
            }
            top(showing)
        }
        .frame(width: side + CGFloat(min(attachments.count - 1, Self.shown)) * Self.leaf,
               height: height + CGFloat(min(attachments.count - 1, Self.shown)) * Self.leaf,
               alignment: .topLeading)
    }

    @ViewBuilder
    private func top(_ attachment: Attachment?) -> some View {
        if let attachment {
            ZStack(alignment: .bottomLeading) {
                if let player = app.playback.player, playing(attachment) {
                    AttachmentPlayer(player: player, audio: attachment.kind == .audio,
                                     width: side, height: height)
                } else {
                    still(attachment)
                }
            }
            .frame(width: side, height: height)
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
                        width: side, height: height,
                        standing: hidden ? .covered : .picture)
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
        // reader who pressed the picture asked for the picture rather than for the words
        // beside it. The play mark sits above it and takes its own clicks first.
        .contentShape(Rectangle())
        .onTapGesture { hidden ? uncover() : open() }
        .help(attachment.alt.isEmpty ? t("post.media.open") : attachment.alt)
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

    /// Hands what is on top to the app, which draws it over everything. The deck keeps its
    /// own place in the stack: the reader comes back to the card they left.
    private func open() {
        app.show(attachments, at: top % max(attachments.count, 1), covered: covered)
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
