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
/// **The picture is scaled to fit and never cut.** The slot is one shape and a photograph is
/// another, so what is left over is the well colour — `RemoteImage` draws it behind every picture
/// for exactly this. Cutting it to the square instead would show the middle of somebody's
/// photograph and call it the photograph; at 96pt that is most of the picture gone. `v` is what
/// seeing it properly is for.
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

        /// How much fainter each sheet is than the one above it. The sheets are the same colour
        /// as the card behind them — that is what makes them read as paper rather than as objects
        /// of their own — so this and the hairline are the whole of what separates one from the
        /// next.
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
    /// Drawn as plain cards rather than as their own pictures. What is under the top one is a few
    /// points of edge that nobody can see anyway, and fetching three more photographs from a
    /// stranger's server to draw them would be three requests the reader did not ask for.
    private var sheets: some View {
        ForEach(0..<sheetCount, id: \.self) { depth in
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(ShellChrome.hairline(colorScheme))
                )
                .opacity(1 - Double(depth) * Card.fade)
                .frame(width: face, height: face)
                .offset(x: CGFloat(depth + 1) * leaf, y: CGFloat(depth + 1) * leaf)
        }
    }

    /// The one on top: the picture, its edge, and which one of how many it is.
    private func card(_ attachment: Attachment) -> some View {
        RemoteImage(
            url: attachment.displayURL,
            // Said, not defaulted. The slot wants a thumbnail; the viewer's tier is unit 7's and
            // has a contract of at most three addresses at once that a row in a list would break
            // on its first screen.
            tier: .deck,
            host: host,
            contentMode: .fit,
            alt: spoken,
            radius: radius
        )
        .frame(width: face, height: face)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme))
        )
        .overlay(alignment: .topTrailing) { counter }
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
