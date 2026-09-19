import AVKit
import FediqoCore
import SwiftUI

/// What the reader opened with `v`, over the whole app.
///
/// The slot is 96 points and a photograph is not, so the deck said all along that `v` was the
/// answer to its own size. This is that answer, and it is deliberately small: there is nothing
/// here to get lost in. One press opens it, `Escape` leaves it, and what it leaves is the row it
/// was opened from with the lamp where the reader left it.
///
/// **The outermost layer.** `Escape` and `q` close this before they close anything under it —
/// the rule is `DummyCommand.outermost`, so the order is one list in one place rather than a
/// sequence of `if`s that can be reordered by accident.
///
/// **It reads the row's own state and keeps none of its own.** Which card is on top and whether
/// the cover is lifted both live in `ShellDecks`, keyed by the post, which is what makes `m` and
/// `s` mean here exactly what they mean in the row: the same key, on the same post, against the
/// same value. A viewer with a private copy of either would drift from the row behind it the
/// first time one of them was pressed.
struct AttachmentViewer: View {
    let attachments: [Attachment]
    /// Which one is on top, as the row remembers it.
    let top: Int
    /// Whether the author's cover is still on. The notice is drawn either way — see `notice`.
    let covered: Bool
    /// Whether the post carries a cover at all, lifted or not.
    let hasCover: Bool
    /// The author's warning, or nothing where they wrote none — the mark alone says covered.
    let coverLine: String?
    /// The custom emoji the post arrived with, for the caption to draw the ones its alt text
    /// names. The post's own list and nothing else is asked for here — `EmojiText` reaches the
    /// server's catalogue behind it for a shortcode the post did not carry a picture for.
    let emojis: [CustomEmoji]
    /// Which source this picture is being read through — `RemoteImage` has no default for it and
    /// this view holds no item, so the post's host is threaded in from where the post is.
    let host: String
    /// The app's one player, handed here only while this viewer's card is the thing that is
    /// playing. Something playing in a row underneath is nothing to this view.
    let player: AVPlayer?
    var onToggleCover: () -> Void
    var onPlay: () -> Void
    /// That the playing rectangle has left the screen.
    var onGone: () -> Void = {}
    var onClose: () -> Void

    @Environment(\.displayScale) private var displayScale

    /// How far the reader has magnified the picture, and what a pinch in progress is adding.
    ///
    /// **Held here and nowhere else.** Magnification is about this looking, not about the post:
    /// a reader who zoomed in on one picture and pressed `m` is asking to see the next one, not
    /// to see it enlarged. `@State` on a view that is created when the viewer opens resets on
    /// both counts for free, and `top` resets it in between.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private enum Box {
        static let corner: CGFloat = 8
        /// How far a covered picture is smeared. Larger than the row's, because what is being
        /// covered here is larger: a radius that hides a 96pt square leaves a window-sized
        /// picture perfectly readable, and a cover that can be read through is not a cover.
        static let smear: CGFloat = 40
        /// The widest a line of somebody's alt text is set. Prose, not a caption band stretched
        /// to whatever the window happens to be.
        static let prose: CGFloat = 520

        /// The most a reader may magnify. Past this a photograph is pixels with edges and there
        /// is nothing further to see.
        static let mostZoom: CGFloat = 6

        /// How near the honest size a pinch has to land to snap to it.
        ///
        /// **The honest size is a detent** because it is the only size in the range that is the
        /// photograph rather than an interpretation of it. A reader who wants it back should find
        /// it by feel, not by aiming.
        static let detent: CGFloat = 0.08

        /// How many lines of it are drawn.
        ///
        /// **Server text never decides how much room the picture gets.** An alt text is up to
        /// fifteen hundred characters an instance chooses, and this caption is the one block on
        /// this screen with nothing holding it open — no avatar, no slot — so without a limit a
        /// long description takes the room the photograph was opened to be seen in. It is the
        /// row's spoiler rule one layer up, and for the same reason rather than for tidiness.
        ///
        /// The limit is a fact about this block's height and about nothing else: the whole of the
        /// alt text goes to a screen reader either way, as the picture's own label.
        static let captionLines = 6
    }

    private var showing: Attachment? {
        guard !attachments.isEmpty else { return nil }
        return attachments[AttachmentDeck.folded(top, of: attachments.count)]
    }

    var body: some View {
        ZStack {
            ground
            if let showing {
                VStack(spacing: ShellSpace.pad) {
                    stage(showing)
                    caption(showing)
                }
                .padding(ShellSpace.room)
            }
        }
        .overlay(alignment: .topTrailing) { closeMark }
        // Said as well as arranged. The layer order puts this in front and
        // `FediqoRootView` takes what is under it out of the accessibility tree; this is the
        // half that tells a screen reader *why* there is nothing behind it.
        .accessibilityAddTraits(.isModal)
        // A new card is a new picture at its own size, not the old one's magnification.
        .onChange(of: top) { _, _ in zoom = 1 }
        .transition(.opacity)
    }

    /// The sheet of nothing behind it, which is also the way out: a press anywhere that is not
    /// the picture closes it, the way it does behind the shortcut guide.
    ///
    /// **Through `ShellGround` rather than spelled here.** It *was* spelled here, and identically
    /// in `ShortcutGuide`, with this comment pointing at the other copy as its authority — which
    /// is an agreement by convention between two `View` bodies that nothing could check.
    private var ground: some View {
        ShellGround(popUp: .attachmentViewer, dismiss: onClose)
    }

    /// The picture, or the film playing in the rectangle the still was in.
    @ViewBuilder
    private func stage(_ attachment: Attachment) -> some View {
        Group {
            if let player {
                AttachmentPlayer(
                    player: player,
                    controls: true,
                    mark: attachment.kind == .audio ? "waveform" : nil,
                    onGone: onGone
                )
            } else {
                picture(attachment)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Box.corner, style: .continuous))
        // **The stage is fixed and the magnification happens inside it.** A `scaleEffect` takes
        // no room, so a reader pinching a picture larger cannot squeeze the caption off the
        // bottom of the screen — which a frame that grew with the gesture would.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// The picture at the size it is, and no larger.
    ///
    /// **A picture is opened, not enlarged.** What the reader asked to see is the photograph; a
    /// small one blown up to fill a 27-inch display is not the photograph but four large blurred
    /// squares where four pixels were. So its own size is the ceiling and the window is only the
    /// other one.
    ///
    /// Where the server said nothing about the shape there is nothing to hold it to, and it takes
    /// the room: guessing at somebody else's picture is worse than drawing it large.
    @ViewBuilder
    private func picture(_ attachment: Attachment) -> some View {
        let ceiling = Self.ceiling(for: attachment, tier: .viewer, scale: displayScale)
        RemoteImage(
            url: attachment.displayURL,
            // The viewer's own tier, and the whole of unit 7's claim on it: exactly one address
            // at a time, because exactly one card is open. The contract allows three and the
            // margin at three is zero, so nothing here reads ahead to a neighbour.
            tier: .viewer,
            host: host,
            contentMode: .fit,
            alt: covered ? nil : spoken(attachment),
            radius: Box.corner
        )
        .aspectRatio(attachment.aspect.map { 1 / $0 }, contentMode: .fit)
        .frame(maxWidth: ceiling?.width ?? .infinity, maxHeight: ceiling?.height ?? .infinity)
        .scaleEffect(covered ? 1 : zoom * pinch)
        .blur(radius: covered ? Box.smear : 0)
        .clipped()
        // **Never enlarged unasked; the reader may enlarge it.** An amendment to decision 1
        // rather than a reading of it — decision 1 ruled on how a picture is *sized* and was
        // silent about gesture. What it ruled still holds: the size this opens at is the
        // picture's own and nothing here fills the window on its own.
        //
        // No new decode tier and no change to the budget. A magnification only has more to show
        // than the viewer tier already holds when the source is larger than 2048 on its long
        // edge; the case this was asked for — a small photograph that reads small — is *smaller*
        // than the decode, so its viewer-tier entry already is the source and zoom there is
        // exact. Past 2048 it is honest interpolation, which is a documented limit rather than a
        // defect.
        // A press on the picture itself does nothing. Closing is the ground behind it, the mark
        // in the corner, `Escape` and `q` — four ways out already, and a fifth that is also
        // where the reader's pointer rests while they look is a viewer that closes itself.
        //
        // **Before the overlays, and that is the whole of it.** Below the mark, this shape is the
        // picture's own and swallows the press. Above it — which is where this line used to be —
        // it becomes the shape of the picture *and everything drawn over it*, and the only
        // pressable thing in that subtree is the play mark, so the mark's region grew to the
        // whole stage and a click anywhere on the photograph started the film. Measured on a real
        // build: one click in the middle of a still and AVKit's controls were on screen. The
        // instinct it punished is the commonest one there is — press the picture to put it away.
        .contentShape(Rectangle())
        .gesture(magnify, isEnabled: !covered)
        .overlay { if covered { notice } }
        .overlay(alignment: .bottomTrailing) { playMark(attachment) }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom = Self.settled(zoom * value.magnification) }
    }

    /// Where a pinch comes to rest.
    ///
    /// The floor is the size the viewer chose, which is the honest one, and it is a detent: a
    /// reader who lands near it lands on it. There is no floor below it because there is nothing
    /// down there — the viewer already draws the picture no larger than it is, and shrinking it
    /// further is not a thing anybody opened it to do.
    nonisolated static func settled(_ scale: CGFloat) -> CGFloat {
        let held = min(max(scale, 1), Box.mostZoom)
        return abs(held - 1) < Box.detent ? 1 : held
    }

    /// The largest this may be drawn, in points, or nothing where the server did not say what
    /// shape it sent.
    ///
    /// Held to the decode as well as to the original. Past the tier's `maxPixels` on the long
    /// edge there is no more picture in hand however large the file was, so drawing it larger is
    /// the same enlargement by another route.
    ///
    /// Points rather than pixels, because the decode is handed to `Image(decorative:scale:)` at
    /// the screen's own scale: one pixel is worth one over that on the screen, and on a 2×
    /// display "its own size" means half as many points as it has pixels.
    nonisolated static func ceiling(
        for attachment: Attachment,
        tier: ShellPictures.Tier,
        scale: CGFloat
    ) -> CGSize? {
        guard let width = attachment.width, let height = attachment.height, scale > 0 else {
            return nil
        }
        let longest = max(width, height)
        let held = longest > tier.maxPixels ? CGFloat(tier.maxPixels) / CGFloat(longest) : 1
        return CGSize(
            width: CGFloat(width) * held / scale,
            height: CGFloat(height) * held / scale
        )
    }

    /// Where in the deck this is, and what its author wrote for somebody who cannot see it.
    ///
    /// **The alt text is drawn with `EmojiText`, like every other line a stranger wrote.** An
    /// earlier version of this made it the one exception — the argument being that a description
    /// of a photograph is not prose and a `:blobcat:` in one is a typing accident more often than
    /// a picture somebody meant. That argument was answered by the ask it was weighed against:
    /// shortcodes are drawn wherever a stranger's words are, and the reader does not keep a
    /// separate rule in their head for the block under the picture. Two spellings of one line in
    /// two places on one screen is the drift, not the tidiness.
    ///
    /// The `host` is the source the post was read through, not the address's own, because that is
    /// what the Clear button can name. Nothing is lost for a shortcode nobody sent a picture for:
    /// `EmojiText` leaves it standing exactly as the author typed it, and hands a screen reader
    /// the author's own text either way.
    ///
    /// **It is the one block on this screen with nothing holding it open, and an emoji makes its
    /// lines taller** — SwiftUI reserves a text attachment's whole height as the line's ascent and
    /// then adds the baseline offset to the descent, measured at `.body` 16 → 21 points. So the
    /// six-line limit is now up to about 126 points rather than about 96. That is a fact about
    /// this block and stops there: the stage above it is `maxHeight: .infinity`, so the picture
    /// gives up the difference, and a viewer is one screen rather than a column of rows — the
    /// thing the row's fixed bands exist to protect is not on this screen at all. The limit is
    /// still what keeps fifteen hundred characters an instance chose from taking the room the
    /// photograph was opened to be seen in.
    @ViewBuilder
    private func caption(_ attachment: Attachment) -> some View {
        VStack(spacing: ShellSpace.snug) {
            if attachments.count > 1 {
                Text(position)
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.overPicture.opacity(0.65))
            }
            if !covered, !attachment.alt.isEmpty {
                EmojiText(attachment.alt, emojis: emojis, host: host, role: .body)
                    .foregroundStyle(ShellChrome.overPicture.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .lineLimit(Box.captionLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: Box.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var position: String {
        String(
            format: L10n.t("item.deck.position"),
            AttachmentDeck.folded(top, of: attachments.count) + 1,
            attachments.count
        )
    }

    /// The cover mark, the author's warning where they wrote one, and the control that takes the
    /// cover off — **drawn here for the same reason it is drawn in the row.** Putting the cover
    /// back is still `s`; this notice does not say so.
    ///
    /// A viewer that can only be uncovered with `s` reproduces one layer up the defect unit 6 was
    /// just fixed for, where a reader using VoiceOver or a pointer could not uncover a post at
    /// all. The control is a real button with a real action, and it is only there while the cover
    /// is still on.
    ///
    /// **`s` blurs in place and never navigates.** The blur at this size is what confirms the
    /// press took; another `s` lifts it again; `Escape` still means leave. Two intents, two keys.
    @ViewBuilder
    private var notice: some View {
        if hasCover {
            VStack(spacing: ShellSpace.step) {
                CoverChip(lifted: !covered, onPicture: true)
                if let coverLine {
                    Text(coverLine)
                        .font(ShellType.body.weight(.medium))
                        .foregroundStyle(ShellChrome.overPicture)
                        .multilineTextAlignment(.center)
                        .lineLimit(Box.captionLines)
                        .frame(maxWidth: Box.prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Self.spokenWarning(coverLine, covered: covered))
                }
                if covered { coverButton }
            }
            .padding(ShellSpace.room)
            .background(
                RoundedRectangle(cornerRadius: Box.corner, style: .continuous)
                    .fill(ShellChrome.scrim)
            )
            .padding(ShellSpace.pad)
        }
    }

    private var coverButton: some View {
        Button(action: onToggleCover) {
            HStack(spacing: ShellSpace.snug) {
                Text(verbatim: "s")
                    .font(ShellType.keycap)
                    .padding(.horizontal, ShellSpace.snug)
                    .padding(.vertical, ShellSpace.hair * 2)
                    .background(Capsule(style: .continuous).fill(ShellChrome.scrim))
                Text(L10n.t("item.covered.show"))
                    .font(ShellType.meta)
            }
            .foregroundStyle(ShellChrome.overPicture)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Ignored and then said properly, so the key cap is not read out as the letter "s" in the
        // middle of a sentence — and the action put back on, because ignoring the children throws
        // the real button's activation away with them.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenButton(warned: coverLine != nil))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onToggleCover)
    }

    /// The chip is hidden and the old sentence is gone, so the state has to be said: once, and
    /// first — on the warning where the author wrote one, on the button where they did not.
    static func spokenWarning(_ line: String, covered: Bool) -> String {
        [mark(covered: covered), String(format: L10n.t("item.covered.warning"), line)]
            .joined(separator: ". ")
    }

    static func spokenButton(warned: Bool) -> String {
        let how = L10n.t("item.covered.label")
        return warned ? how : [mark(covered: true), how].joined(separator: ". ")
    }

    private static func mark(covered: Bool) -> String {
        L10n.t(covered ? "item.covered.mark" : "item.lifted.mark")
    }

    /// The mark that starts it, where there is something to start and it is not started.
    ///
    /// A button and not only a mark: `a` is the key and this is the way to the same thing for a
    /// reader who is not holding one. Gone while it plays, because AVKit's own controls are right
    /// there and two stop buttons on one film is one too many.
    @ViewBuilder
    private func playMark(_ attachment: Attachment) -> some View {
        if !covered, let symbol = AttachmentDeck.playSymbol(of: attachment) {
            Button(action: onPlay) {
                Image(systemName: symbol)
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.overPicture)
                    .padding(ShellSpace.pad)
                    .background(Circle().fill(ShellChrome.scrim))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(ShellSpace.room)
            .help(L10n.t("item.deck.play"))
            .accessibilityLabel(L10n.t("item.deck.play"))
        }
    }

    private func spoken(_ attachment: Attachment) -> String? {
        attachment.alt.isEmpty ? nil : attachment.alt
    }

    private var closeMark: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.overPicture)
                .padding(ShellSpace.step)
                .background(Circle().fill(ShellChrome.scrim))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(ShellSpace.pad)
        .help(L10n.t("shortcut.close"))
        .accessibilityLabel(L10n.t("shortcut.close"))
    }
}
