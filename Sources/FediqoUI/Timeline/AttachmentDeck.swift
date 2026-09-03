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
    /// What the top card is drawn at, which is the whole of it where there is nothing under it.
    ///
    /// The deck used to frame itself `side + overhang` across while every caller reserved `side`
    /// — the reserved column is exactly that wide, and the stacked arrangement measures a box at
    /// exactly the card's ratio. So the fan and the counter under it were drawn outside the room
    /// anybody had given them, and on a phone the reader saw neither: three attachments, and the
    /// screen said nothing about two of them (#95).
    private var faceSide: CGFloat { side - overhang }
    static func faceSide(under count: Int, on side: CGFloat) -> CGFloat {
        side - overhang(under: count, on: side)
    }
    private var faceHeight: CGFloat { faceSide * Self.ratio }
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
    /// **A share of the card rather than a number of points** (#95). It was three points, fixed,
    /// when the card was 200 wide; #79 doubled the card to 400 and left it there, so the stack
    /// halved in visibility on the day the picture grew — three points of paper under four
    /// hundred points of photograph is nothing at all, and a reader was left learning there were
    /// more only from the counter.
    ///
    /// Proportional, so this cannot happen again to whoever next changes `side`. And still
    /// calmer than the version that was rejected: a full four points on a 200-point card drew
    /// three bordered slabs that competed with the picture, and this is a smaller share of a
    /// bigger card than that was.
    private var leaf: CGFloat { Self.leaf(on: side) }
    static func leaf(on side: CGFloat) -> CGFloat { side * leafShare }
    private static let leafShare: CGFloat = 0.022

    /// How strongly a sheet draws its own edge.
    ///
    /// A whole hairline, where it was half of one. The sheets are filled with the same colour
    /// the card behind them is — that is what makes them read as paper rather than as objects —
    /// so the edge is the only thing distinguishing one from the next, and at half strength it
    /// was distinguishing nothing. What made the four-point version too loud was three bordered
    /// slabs the size of the picture, not the borders; at this share of this card they are the
    /// edges of a stack.
    private static let edge: Double = 1

    /// How far the fan reaches from the top card's corner — what the sheets underneath cost the
    /// card they are under.
    private var overhang: CGFloat { Self.overhang(under: attachments.count, on: side) }

    /// How far the fan reaches, for a given number of attachments on a card of a given width.
    ///
    /// Pure and static so the one rule that matters can be asserted without drawing anything:
    /// **the fan comes out of the card, never out of the room around it.** Every caller reserves
    /// `side` — the wide arrangement's column is exactly that, and the stacked one measures a box
    /// at exactly the card's ratio — so a deck that drew wider than `side` drew where nobody had
    /// left it room, which is what #95 turned out to be.
    static func overhang(under count: Int, on side: CGFloat) -> CGFloat {
        CGFloat(min(max(count - 1, 0), shown)) * leaf(on: side)
    }

    private var showing: Attachment? {
        attachments.isEmpty ? nil : attachments[top % attachments.count]
    }

    private var hidden: Bool { covered }

    var body: some View {
        deck
            .frame(width: side, alignment: .leading)
            .onChange(of: turns) { _, _ in turn() }
            // `p` on the row this deck belongs to plays what is on top of it, or stops it.
            .onChange(of: plays) { _, _ in
                guard let showing, showing.isPlayable else { return }
                play(showing)
            }
            // A deck that goes off the screen — the reader scrolled, or closed the post they
            // had opened — takes its sound with it. Nothing here plays out of sight.
            .onDisappear { if playing(showing) { app.playback.stop() } }
    }

    /// Which one of how many, on the card rather than under it.
    ///
    /// It was a line below the deck, in a `VStack` — which the reserved column and the measured
    /// box both sized to the card alone, so it was drawn outside the room it had and a reader
    /// on a phone never saw it. On the card it needs no room of its own, and it is where a
    /// count of photographs is looked for anyway.
    @ViewBuilder
    private var howMany: some View {
        if attachments.count > 1 {
            Text(verbatim: "\(top % attachments.count + 1) / \(attachments.count)")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.hair)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(Space.step)
                .accessibilityHidden(true)
        }
    }

    private var deck: some View {
        ZStack(alignment: .topLeading) {
            // The ones underneath, stepping out from the top card so the stack has a
            // thickness. They are drawn as plain cards rather than as their own pictures:
            // what is under the top one is not something the reader can see anyway, and
            // loading three more images to show a few points of each is a request nobody
            // asked for.
            //
            // **Paper under a photograph, not cards of their own** (#79). They used to step
            // out four points each with a hairline around every one, which drew three
            // bordered slabs beside the picture — a shape that competed with the picture for
            // the eye. What replaced it said nothing at all, which is #95: three fixed points
            // under a card that had doubled to four hundred. Now the step is a share of the
            // card, each sheet fainter than the one above it, and the edge is a whole hairline
            // because on cards of the same colour it is the only thing there is to see. What a
            // reader sees is the photograph; what the edges tell them is that there are more.
            ForEach(0..<min(attachments.count - 1, Self.shown), id: \.self) { depth in
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Palette.raised(colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.hairline(colorScheme).opacity(Self.edge)))
                    .opacity(1 - Double(depth) * 0.25)
                    .frame(width: faceSide, height: faceHeight)
                    .offset(x: CGFloat(depth + 1) * leaf, y: CGFloat(depth + 1) * leaf)
            }
            top(showing)
        }
        // The card's own footprint and no more. What the sheets take, they take out of the
        // photograph rather than out of the row.
        .frame(width: side, height: height, alignment: .topLeading)
    }

    @ViewBuilder
    private func top(_ attachment: Attachment?) -> some View {
        if let attachment {
            ZStack(alignment: .bottomLeading) {
                if let player = app.playback.player, playing(attachment) {
                    AttachmentPlayer(player: player, audio: attachment.kind == .audio,
                                     width: faceSide, height: faceHeight)
                } else {
                    still(attachment)
                }
            }
            .frame(width: faceSide, height: faceHeight)
            .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Palette.hairline(colorScheme)))
            .overlay(alignment: .topTrailing) { howMany }
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
                        width: faceSide, height: faceHeight,
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
