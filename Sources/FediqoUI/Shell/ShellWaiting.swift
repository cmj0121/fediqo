import SwiftUI

/// **On its way, said once for the whole app** — the plate a surface puts where a real thing
/// will be, and the rhythm every waiting thing here moves to.
///
/// ## Why this is a plate and not a spinner
///
/// The argument is `ForumWaiting`'s and is not restated: a reader who has scrolled one timeline
/// has already learned that a quiet plate is what "asked for, not here yet" looks like here, and
/// a platform spinner would be a second vocabulary for the same fact. What was missing was a
/// *place* for that plate to be written down. `ForumPostBand` drew one shape, `RemoteImage` drew
/// another, and `ForumWaiting` drew a third with its own copy of the clock — three surfaces, one
/// idea, and nothing stopping a fourth from inventing a fifth.
///
/// ## What it is
///
/// **A shape and no words.** Nothing here is text, so there is nothing to translate, nothing to
/// truncate, and nothing this app puts in an author's mouth while their post is still coming.
/// The sentence exists — `spoken` — but only a screen reader ever meets it.
///
/// **It takes the place it is given.** A `Shape` has no size of its own: whatever frame the
/// surface hands it is the frame it fills, so an avatar-sized hole, a row-sized hole and a
/// picture-sized hole are the same view under three frames rather than three views. The surface
/// says how big; it does not say what waiting looks like. A round place — an avatar — clips it.
///
/// **It has a floor, and the floor scales.** Given no height at all it is still a plate a reader
/// can see, and at the largest type size it grows with the type it stands among, so a one-line
/// plate beside 30-point words does not read as a hairline.
///
/// ## The reader who asked for less movement
///
/// `accessibilityReduceMotion` takes the clock away rather than slowing it: there is no
/// `TimelineView` in that branch at all, so no second frame is ever drawn. What is left is
/// `wave(0, of: 1, at: 0)` — the plate at full — which is exactly the still plate this shell
/// already used for waiting before any of it moved. Nothing moves, and it still reads as a held
/// place.
///
/// ## What a screen reader hears
///
/// One element, one sentence, once. `children: .ignore` closes the same trap `EmojiText`
/// documents: without it a reader is free to walk into the `TimelineView` and read whatever a
/// container happens to name. A surface that stands **several** of these in one place — a row of
/// plates standing for a row of words — wraps the group the same way and labels it with `spoken`,
/// so the sentence is said for the place and not once per plate.
struct ShellWaiting: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The smallest a plate may be, scaled to the type it stands among.
    @ScaledMetric(relativeTo: .body) private var floor: CGFloat = ShellSpace.snug

    // MARK: - The one rhythm

    /// How long one pass takes. Slow enough not to read as an alarm, quick enough that a reader
    /// who glances at it sees it move.
    static let period: TimeInterval = 1.2

    /// How often the clock ticks. `EmojiClock.fastestTick` is the ceiling this app already set
    /// for how often anything may ask for a redraw, and a fading plate needs nothing near it.
    static let tick: TimeInterval = 1.0 / 20

    /// The two ends of this plate's own pulse.
    ///
    /// **Shallower than `ForumWaiting`'s, and that is a statement rather than a drift.** Those
    /// plates trail a sentence that already carries the fact, so one of them may go nearly out
    /// without anything being lost. This one *is* the fact — it is standing in for the thing the
    /// reader is waiting for — and a place that empties every 1.2 seconds is a place that
    /// flickers. The rhythm is shared; how deep the breath goes belongs to what is breathing.
    static let banked: Double = 0.55
    static let lit: Double = 1.0

    /// A clock only where one is wanted — nothing for a reader who asked for less movement.
    ///
    /// The same shape and the same answer as `EmojiText.clock(for:reduceMotion:)`: a `nil` is
    /// what makes the still branch structural rather than an animation running at zero speed.
    static func clock(reduceMotion: Bool) -> TimeInterval? {
        reduceMotion ? nil : tick
    }

    /// Where one shape of `count` is in the pass at one instant, in `0...1` — 1 is lit.
    ///
    /// A cosine rather than a step, so a run of shapes never all sit at one brightness and never
    /// reads as a stutter. `instant` is a wall clock, so it is taken modulo the period and the
    /// result is finite for every input a `TimelineView` can hand it. Shape 0 at instant 0 is
    /// full, which is what makes the still frame a real frame.
    static func wave(_ index: Int, of count: Int, at instant: TimeInterval) -> Double {
        let phase = (instant / period - Double(index) / Double(count))
            .truncatingRemainder(dividingBy: 1)
        return (1 + cos(2 * .pi * phase)) / 2
    }

    /// How present the plate is at one instant, in `banked...lit`. What `body` actually draws,
    /// named so that the claim can be made without a screen.
    static func glow(at instant: TimeInterval) -> Double {
        banked + (lit - banked) * wave(0, of: 1, at: instant)
    }

    /// What a screen reader is told, and the sentence a surface holding several plates labels the
    /// group with. Nowhere on screen: a plate says this by being a plate.
    static var spoken: String { L10n.t("shell.waiting") }

    var body: some View {
        Group {
            if let tick = Self.clock(reduceMotion: reduceMotion) {
                TimelineView(.periodic(from: .now, by: tick)) { instant in
                    plate(at: instant.date.timeIntervalSinceReferenceDate)
                }
            } else {
                plate(at: 0)
            }
        }
        .frame(minWidth: floor, minHeight: floor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The milled recess, which is the token for a container rather than for ink: what is drawn
    /// here is the hole a thing will fill, not a thing.
    private func plate(at instant: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
            .fill(ShellChrome.well(colorScheme))
            .opacity(Self.glow(at: instant))
    }
}

/// The one view under four frames and nothing else — what a surface hands it is the only thing
/// that differs. Switch the preview between light and dark, and its type size between the two
/// ends of the scale, to read the two claims a test cannot make.
#Preview("On its way, at four sizes") {
    @Previewable @Environment(\.colorScheme) var scheme
    VStack(alignment: .leading, spacing: ShellSpace.step) {
        ShellWaiting()
        ShellWaiting().frame(width: 160)
        ShellWaiting().frame(width: 44, height: 44)
        ShellWaiting().frame(height: 120)
    }
    .padding(ShellSpace.pad)
    .frame(width: 360, alignment: .leading)
    .background(ShellChrome.page(scheme))
}
