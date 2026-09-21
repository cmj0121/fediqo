import SwiftUI

/// The one launch motion: the mascot flips up-down, then left-right, then the shell is the page.
///
/// **Not a `DummyLayer`.** A layer is something the reader opened and a press to leave takes
/// away. This is the first frame of a process, and it takes itself away. Putting it on that
/// list would make `q` and `Escape` a skip they were not asked for, and would rewrite the
/// order `ViewerTests` pins.
///
/// **Reduce motion skips it outright**, the same structural skip as `ForumWaiting.clock`:
/// `start(reduceMotion: true)` is already dismissed, so nothing is asked to tick. A
/// zero-speed flip would still be a flip.
///
/// The turns themselves are a value a test can drive. SwiftUI interpolates `pitch` and `yaw`;
/// the suite never has to stand a view up to know that up-down is X and left-right is Y.
struct Landing: Equatable, Sendable {
    /// Degrees about X. 360 is one up-down flip, landing the right way up.
    var pitch: Double
    /// Degrees about Y. 360 is one left-right flip, landing the right way up.
    var yaw: Double
    var showing: Bool

    /// Larger than the Account hero's 72, because this is the whole window for a moment.
    static let mark: CGFloat = 144
    /// Toast-sized: a capsule is not the window, and `mark` would overflow it.
    static let toastMark: CGFloat = 20
    static let flip: Double = 360
    /// Slower than a control's 0.18 so the mascot is readable mid-turn.
    static let duration: TimeInterval = 0.45
    /// A beat at rest so the mascot is seen before it moves.
    static let hold: TimeInterval = 0.2
    /// Hold, then the two flips. The toast loops this; launch does it once.
    static var pass: TimeInterval { hold + duration * 2 }

    static func start(reduceMotion: Bool) -> Landing {
        Landing(pitch: 0, yaw: 0, showing: !reduceMotion)
    }

    /// The loading toast's mascot: always shown, still when reduce motion is on.
    /// Launch uses `start`, which hides the overlay outright for that preference.
    static func loading(reduceMotion _: Bool) -> Landing {
        Landing(pitch: 0, yaw: 0, showing: true)
    }

    /// Cosine ease-in-out in `0...1`, the same curve the launch flips use.
    /// One function so the toast does not grow a second interpolation.
    static func ease(_ t: Double) -> Double {
        0.5 - 0.5 * cos(.pi * min(max(t, 0), 1))
    }

    /// A clock only where one is wanted — nothing for a reader who asked for less movement,
    /// the same structural skip as `ShellWaiting.clock`.
    static func clock(reduceMotion: Bool) -> TimeInterval? {
        reduceMotion ? nil : EmojiClock.fastestTick
    }

    /// Pitch and yaw at `elapsed` into the two-flip motion. Looping keeps adding 360.
    static func orientation(
        at elapsed: TimeInterval,
        looping: Bool,
        reduceMotion: Bool = false
    ) -> (pitch: Double, yaw: Double) {
        if reduceMotion { return (0, 0) }
        let span = pass
        let t: TimeInterval
        let base: Double
        if looping {
            let cycles = (elapsed / span).rounded(.towardZero)
            t = elapsed - cycles * span
            base = cycles * flip
        } else if elapsed >= span {
            return (flip, flip)
        } else {
            t = max(elapsed, 0)
            base = 0
        }
        if t < hold {
            return (base, base)
        }
        let afterHold = t - hold
        if afterHold < duration {
            return (base + flip * ease(afterHold / duration), base)
        }
        return (base + flip, base + flip * ease((afterHold - duration) / duration))
    }

    mutating func flipVertical() {
        pitch += Self.flip
    }

    mutating func flipHorizontal() {
        yaw += Self.flip
    }

    mutating func dismiss() {
        showing = false
    }
}

struct LandingView: View {
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landing = Landing.start(reduceMotion: false)

    var body: some View {
        ZStack {
            ShellChrome.page(colorScheme)
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: Landing.mark, height: Landing.mark)
                .landingTurns(pitch: landing.pitch, yaw: landing.yaw)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            onFinished()
            return
        }
        do {
            try await Task.sleep(for: .seconds(Landing.hold))
            withAnimation(.easeInOut(duration: Landing.duration)) {
                landing.flipVertical()
            }
            try await Task.sleep(for: .seconds(Landing.duration))
            withAnimation(.easeInOut(duration: Landing.duration)) {
                landing.flipHorizontal()
            }
            try await Task.sleep(for: .seconds(Landing.duration))
            landing.dismiss()
            onFinished()
        } catch {
            onFinished()
        }
    }
}

extension View {
    /// Up-down about X, then left-right about Y — one pair so launch and the toast
    /// cannot disagree about which axis is which.
    func landingTurns(pitch: Double, yaw: Double) -> some View {
        self
            .rotation3DEffect(
                .degrees(pitch),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.55
            )
            .rotation3DEffect(
                .degrees(yaw),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
    }
}

/// The launch mascot at a given size, turning with `Landing.orientation`.
/// Reduce Motion is a still mascot: no clock, so no second frame.
struct LandingMascot: View {
    var size: CGFloat
    var looping: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date()

    var body: some View {
        Group {
            if let tick = Landing.clock(reduceMotion: reduceMotion) {
                TimelineView(.periodic(from: origin, by: tick)) { context in
                    mascot(
                        Landing.orientation(
                            at: context.date.timeIntervalSince(origin),
                            looping: looping
                        )
                    )
                }
            } else {
                mascot(Landing.orientation(at: 0, looping: looping, reduceMotion: true))
            }
        }
        .accessibilityHidden(true)
    }

    private func mascot(_ turn: (pitch: Double, yaw: Double)) -> some View {
        Image("Mascot", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .landingTurns(pitch: turn.pitch, yaw: turn.yaw)
    }
}
