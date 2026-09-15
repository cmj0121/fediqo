import AVKit
import FediqoCore
import SwiftUI

/// What came attached, drawn in the square the row keeps open for it.
///
/// **Several attachments are a stack, not a row of thumbnails.** A row of thumbnails in a 96pt
/// slot is four pictures 22 points across, which is four pictures nobody can see; one on top with
/// the edges of the others behind it is a picture at nearly the full slot plus the fact that there
/// are more. `m` turns it, and which one is on top belongs to the row — see `ShellDecks`.
///
/// **One attachment is one picture.** No sheets, no counter: a deck of one that looks turnable is
/// a control lying about what it can do.
///
/// **The fan comes out of the card, never out of the row.** The slot is exactly the side it was
/// given and every row reserves exactly that much, so a deck drawing wider than `side` draws where
/// nobody left it room — which on a phone is off the edge of the screen. The sheets take their
/// step out of the photograph instead: the card is `side - overhang` and the stack as a whole is
/// `side`.
///
/// **The picture fills the slot and is cut to it.** It was fitted at first, on the grounds that
/// cutting shows the middle of somebody's photograph and calls it the photograph; the reader
/// overruled that, and the reason is the column rather than the picture — a fitted photograph
/// leaves the well colour on two sides, and a screenful of rows each with a different band of
/// empty colour reads as broken rather than as careful. Filling means the **short** edge decides
/// the scale and the long one is truncated: a tall picture keeps its full width and loses its top
/// and bottom. What that costs is real — at 96pt most of a tall photograph is off the card — and
/// `v` is what seeing it properly is for.
///
/// **No edge is drawn round any of it.** The hairline that used to separate card from sheet and
/// sheet from row went with the fitting: it was chrome standing in for a picture, and now there
/// is a picture in every one of those rectangles to do the separating itself.
struct AttachmentDeck: View {
    let attachments: [Attachment]
    /// Which one is on top, as the row remembers it. Folded by the count here as well, because
    /// the row's memory outlives any one version of the post.
    let top: Int
    /// The side of the slot, which is square. Passed in rather than measured: the row scales it
    /// with the reader's type size, and a deck that measured its own room would fan out of a slot
    /// that had already been given a width.
    let side: CGFloat

    /// Which of the reader's servers this post arrived through, for the picture cache to file the
    /// card under. Passed in because this view holds no item: an attachment address is usually a
    /// CDN and cannot be traced back to a server, so somebody who knows has to say. See
    /// `ShellPictures`, I10.
    let host: String
    var radius: CGFloat = ShellSpace.tight

    /// The app's one player, handed to this slot only while this slot's card is the thing that is
    /// playing. Nothing covers "nothing is playing", "another row is playing it" and "the viewer
    /// is playing it over this row" alike, which to a slot are one answer: draw the still.
    var player: AVPlayer?

    /// Starts or stops the card on top. The slot's own way to the key `a`, for the reader who is
    /// not holding one.
    var onPlay: () -> Void = {}

    /// That the playing rectangle has left the screen.
    var onEnded: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    private enum Card {
        /// How many of the ones underneath are drawn. Three is enough to say there are more;
        /// past that the edges stop being distinguishable from each other anyway.
        static let sheets = 3

        /// How far each sheet steps out from the one above it, as a share of the card rather
        /// than a number of points.
        ///
        /// A named number on this view rather than a token, because it is not a gap between two
        /// things: it is the thickness of a sheet of paper, and it belongs to this drawing and to
        /// nothing else. Proportional so that it cannot be left behind by a later change to the
        /// slot — the prior art's fixed three points survived the card doubling and became
        /// invisible. At this share of 96pt a sheet is about three points, which is the least
        /// that reads as an edge rather than as a rendering artefact.
        static let leafShare: CGFloat = 0.032

        /// How much fainter each sheet is than the one above it. With the hairline gone and a
        /// real picture in every sheet, this is the whole of what says which one is further down:
        /// the edge of a photograph at three quarters strength reads as under the one above it
        /// rather than beside it.
        static let fade: Double = 0.25
    }

    /// How many sheets are actually drawn. Clamped at both ends: at the top because three is all
    /// the eye can use, and at the bottom because an empty deck would otherwise ask for a
    /// backwards range, which is a crash rather than a blank square.
    private var sheetCount: Int {
        min(max(attachments.count - 1, 0), Card.sheets)
    }

    private var leaf: CGFloat { side * Card.leafShare }

    /// What the sheets cost the card they are under.
    private var overhang: CGFloat { CGFloat(sheetCount) * leaf }

    /// The top card's own side. The whole slot where there is nothing underneath.
    private var face: CGFloat { side - overhang }

    private var index: Int {
        Self.folded(top, of: attachments.count)
    }

    /// Which card `top` names, in range whatever it holds.
    ///
    /// The two-step remainder rather than one, which is the form `DummyCommand.advanced` already
    /// uses: `%` in Swift keeps the sign of its left side, so a negative `top` gives a negative
    /// index and a subscript that traps. Nothing hands this a negative number today — the row
    /// remembers only what it counted up itself. It is one operator against a crash.
    ///
    /// `nonisolated` because a `View`'s statics are isolated to the main actor and `ShellDecks`,
    /// which asks the same question about the number it is holding, is a plain value that is not.
    nonisolated static func folded(_ top: Int, of count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((top % count) + count) % count
    }

    private var showing: Attachment? {
        attachments.isEmpty ? nil : attachments[index]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            sheets
            if let showing { card(showing) }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    /// The ones underneath, stepping down and to the right so the stack has a thickness.
    ///
    /// **They draw their own pictures.** They were plain cards at first, on the grounds that a
    /// few points of edge is not worth another request to a stranger's server. The reader
    /// overruled it, and they were right: a fan of blank cards behind a photograph reads as
    /// chrome, where what the fan is there to say is that there are more *photographs*.
    ///
    /// The cost is bounded and mostly already spent. At most three more deck-tier entries per
    /// row, and they are the same addresses `m` is about to ask for anyway — so turning the deck
    /// now draws something the cache is already holding instead of starting a fetch and showing
    /// a bare plate while it lands.
    ///
    /// No alt text, deliberately: these are edges of pictures the reader has not turned to yet,
    /// and `RemoteImage` keeps an unlabelled picture out of the accessibility tree. What is
    /// spoken is the card on top and the counter that says how many there are.
    private var sheets: some View {
        ForEach(0..<sheetCount, id: \.self) { depth in
            Group {
                if let next = beneath(depth) {
                    RemoteImage(url: next.displayURL, tier: .deck, host: host, radius: radius)
                } else {
                    ShellChrome.well(colorScheme)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .frame(width: face, height: face)
            .opacity(1 - Double(depth) * Card.fade)
            .offset(x: CGFloat(depth + 1) * leaf, y: CGFloat(depth + 1) * leaf)
        }
    }

    /// The attachment one step further down the stack than `depth` — what the sheet at that depth
    /// is an edge of, and what `m` will put on top next.
    ///
    /// Folded like everything else that indexes this list, because `top` is the row's own count of
    /// how many times it has been turned and adding to it walks straight off the end.
    private func beneath(_ depth: Int) -> Attachment? {
        guard let at = Self.beneath(top, depth: depth, of: attachments.count) else { return nil }
        return attachments[at]
    }

    /// The index `beneath(_:)` reads, as a number, so the off-by-one can be pinned without a view.
    ///
    /// The `+ 1` is the whole of it: sheet zero is the *next* one and never the one already on
    /// top. Getting it wrong draws the card's own picture behind itself, which on a deck of two
    /// looks like a stack of the same photograph and on a deck of one looks like nothing at all.
    nonisolated static func beneath(_ top: Int, depth: Int, of count: Int) -> Int? {
        guard count > 0 else { return nil }
        return folded(top + depth + 1, of: count)
    }

    /// The one on top: the picture, its edge, and which one of how many it is.
    private func card(_ attachment: Attachment) -> some View {
        Group {
            if let player {
                // In the rectangle the still was in, so starting and stopping moves nothing else
                // on the screen — and with no controls, because AVKit's are larger than this
                // square. What plays here is a moving thumbnail, not a player.
                AttachmentPlayer(player: player, controls: false, onGone: onEnded)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                RemoteImage(
                    url: attachment.displayURL,
                    // Said, not defaulted. The slot wants a thumbnail; the viewer's tier is unit
                    // 7's and has a contract of at most three addresses at once that a row in a
                    // list would break on its first screen.
                    tier: .deck,
                    host: host,
                    alt: spoken,
                    radius: radius
                )
            }
        }
        .frame(width: face, height: face)
        .overlay(alignment: .topTrailing) { counter }
        .overlay(alignment: .bottomLeading) { playMark(attachment) }
    }

    /// The mark that says this one plays, and plays it.
    ///
    /// **Unit 6 left this out on purpose and the reason has now gone.** A play mark over a still
    /// that nothing would play is a control that lies, so until `a` did something there was
    /// nothing honest to draw. What it cost in the meantime was that a video in the slot was
    /// pixel-identical to a photograph, and only a reader using a screen reader was told which.
    ///
    /// A button and not only a mark, for the reason the cover control is one: a control that can
    /// only be reached from the keyboard is no control at all on a phone, and unit 6 has just
    /// been fixed for exactly that.
    ///
    /// Gone while it plays. What is in the rectangle is moving, which is the whole of what the
    /// mark was there to promise, and `a` is still how it stops.
    @ViewBuilder
    private func playMark(_ attachment: Attachment) -> some View {
        if player == nil, let symbol = Self.playSymbol(of: attachment) {
            Button(action: onPlay) {
                Image(systemName: symbol)
                    .font(ShellType.mark.weight(.semibold))
                    .foregroundStyle(ShellChrome.overPicture)
                    .padding(ShellSpace.tight)
                    .background(Circle().fill(ShellChrome.scrim))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(ShellSpace.tight)
            .help(L10n.t("item.deck.play"))
            .accessibilityLabel(L10n.t("item.deck.play"))
        }
    }

    /// Which mark a kind of attachment gets, and which gets none.
    ///
    /// A video and an audio clip get one. **An image gets none** — it is a picture and it looks
    /// like one, and a label saying so is a label about nothing. **`unknown` gets none either**:
    /// a question mark over somebody's photograph claims to know something about it that nobody
    /// told us, and what the server actually said is that it did not say.
    ///
    /// And nothing at all where there is no file behind the still, which is `isPlayable`'s second
    /// half. A mark offering to play something this app cannot play is the lie again, arriving
    /// from the other side.
    nonisolated static func playSymbol(of attachment: Attachment) -> String? {
        guard attachment.isPlayable else { return nil }
        switch attachment.kind {
        case .video: return "play.fill"
        case .audio: return "waveform"
        case .image, .unknown: return nil
        }
    }

    /// Which one of how many, on the card rather than under it. The slot is exactly the card and
    /// no more, so a line below the deck would be drawn in somebody else's room; on the card it
    /// needs none of its own, and the corner of a photograph is where a count of photographs is
    /// looked for.
    ///
    /// Not translated, and not read out: it is a pair of numerals, and what a screen reader says
    /// instead is `spoken`, which puts the same fact into a sentence.
    ///
    /// Set close, without spaces around the slash. On the card this was drawn for first it was a
    /// lozenge a third of the card wide, competing with the photograph it was a footnote to;
    /// closed up it is a mark in the corner, which is what it is.
    @ViewBuilder
    private var counter: some View {
        if attachments.count > 1 {
            Text(verbatim: "\(index + 1)/\(attachments.count)")
                .font(ShellType.mark.weight(.medium))
                .foregroundStyle(ShellChrome.overPicture)
                .padding(.horizontal, ShellSpace.hair * 3)
                .padding(.vertical, ShellSpace.hair)
                .background(Capsule(style: .continuous).fill(ShellChrome.scrim))
                .padding(ShellSpace.tight)
                .accessibilityHidden(true)
        }
    }

    /// Said out loud: which one this is, and what it is. A deck that will not say "2 of 3" is a
    /// deck nobody can turn blind, and an attachment whose author wrote no alt text still has a
    /// kind — "a video" is little, and it is more than silence.
    private var spoken: String? {
        guard let showing else { return nil }
        let described = showing.alt.isEmpty ? Self.kind(of: showing) : showing.alt
        return Self.positioned(described, index: index, of: attachments.count)
    }

    /// The same fact with the author's words left out: what kind of thing is on top and which of
    /// how many it is, and nothing about what is in it.
    ///
    /// This is what a **covered** row says. The alt text describes the picture, so a covered row
    /// that read it out would be the cover lifted for exactly the reader who cannot lift it back
    /// — and a covered row that said nothing about it at all would leave them not knowing there
    /// was anything to uncover. Naming it without describing it is the whole of the difference.
    ///
    /// `nonisolated` for the same reason `folded(_:of:)` is: a `View`'s statics are isolated to
    /// the main actor, and this is asked as a plain question about a list of attachments by
    /// callers that are not — `DummyItemRow`'s accessibility label and the suite that pins the
    /// two spellings against each other.
    nonisolated static func named(_ attachments: [FediqoCore.Attachment], top: Int) -> String? {
        guard !attachments.isEmpty else { return nil }
        let index = folded(top, of: attachments.count)
        return positioned(kind(of: attachments[index]), index: index, of: attachments.count)
    }

    /// `nonisolated` with `named` above it, which is its only reason to be: `L10n` is a plain
    /// enum and this is a lookup, not a drawing.
    nonisolated private static func kind(of attachment: FediqoCore.Attachment) -> String {
        L10n.t("item.deck.\(attachment.kind.rawValue)")
    }

    /// One place for the counter, so the two spellings cannot drift into two forms of the same
    /// sentence. A deck of one has no position worth saying.
    nonisolated private static func positioned(
        _ described: String, index: Int, of count: Int
    ) -> String {
        guard count > 1 else { return described }
        let position = String(format: L10n.t("item.deck.position"), index + 1, count)
        return "\(position) — \(described)"
    }
}
