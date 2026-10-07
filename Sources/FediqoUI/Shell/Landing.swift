import SwiftUI

/// The one launch motion: the octopus alone gathers itself, pushes off, coasts back to rest and
/// fades, then the shell is the page. A jet, which is how this animal moves.
///
/// **Not a `DummyLayer`.** A layer is something the reader opened and a press to leave takes
/// away. This is the first frame of a process, and it takes itself away. Putting it on that
/// list would make `q` and `Escape` a skip they were not asked for, and would rewrite the
/// order `ViewerTests` pins.
///
/// **Reduce motion skips it outright**, the same structural skip as `ForumWaiting.clock`:
/// `start(reduceMotion: true)` is already dismissed, so nothing is asked to tick. A
/// zero-speed jet would still be a jet.
///
/// The steps themselves are a value a test can drive. SwiftUI interpolates `squeeze`, `lift`
/// and `opacity`; the suite never has to stand a view up to know that gathering is wider,
/// shorter and lower, and that pushing off is narrower, taller and higher.
struct Landing: Equatable, Sendable {
    /// The scale on each axis. 1 × 1 is the drawing as it is.
    var squeeze: CGSize
    /// Points above rest; a negative lift is below it.
    var lift: CGFloat
    var opacity: Double
    var showing: Bool

    /// Larger than the Account hero's 72, because this is the whole window for a moment — and
    /// larger than a tile would need, because without one the animal fills 82% of its box.
    static let mark: CGFloat = 200
    static let rest = CGSize(width: 1, height: 1)
    /// Wider, shorter and a little lower: the mantle fills.
    static let gathered = CGSize(width: 1.07, height: 0.90)
    static let sink: CGFloat = -7
    /// Narrower, taller and well above rest: the water is out.
    static let pushed = CGSize(width: 0.97, height: 1.05)
    static let rise: CGFloat = 28

    /// A beat at rest so the octopus is seen before it moves.
    static let hold: TimeInterval = 0.20
    static let gatherTime: TimeInterval = 0.16
    static let pushOffTime: TimeInterval = 0.26
    /// The spring's response as well as the wait: the coast is one settle, not a bounce.
    static let coastTime: TimeInterval = 0.34
    static let coastDamping: Double = 0.8
    /// A control's 0.18: by now the octopus is at rest and only has to go.
    static let leaveTime: TimeInterval = 0.18

    static func start(reduceMotion: Bool) -> Landing {
        Landing(squeeze: rest, lift: 0, opacity: 1, showing: !reduceMotion)
    }

    mutating func gather() {
        squeeze = Self.gathered
        lift = Self.sink
    }

    mutating func pushOff() {
        squeeze = Self.pushed
        lift = Self.rise
    }

    mutating func coast() {
        squeeze = Self.rest
        lift = 0
    }

    mutating func leave() {
        opacity = 0
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
            // A template, so one drawing is the ink of whichever ground it is on: the tile's
            // navy body vanished on a dark page and its pale rim on a light one.
            Image("Octopus", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(width: Landing.mark, height: Landing.mark)
                .scaleEffect(landing.squeeze)
                .offset(y: -landing.lift)
                .opacity(landing.opacity)
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
            withAnimation(.easeIn(duration: Landing.gatherTime)) {
                landing.gather()
            }
            try await Task.sleep(for: .seconds(Landing.gatherTime))
            withAnimation(.easeOut(duration: Landing.pushOffTime)) {
                landing.pushOff()
            }
            try await Task.sleep(for: .seconds(Landing.pushOffTime))
            withAnimation(.spring(response: Landing.coastTime, dampingFraction: Landing.coastDamping)) {
                landing.coast()
            }
            try await Task.sleep(for: .seconds(Landing.coastTime))
            withAnimation(.easeIn(duration: Landing.leaveTime)) {
                landing.leave()
            }
            try await Task.sleep(for: .seconds(Landing.leaveTime))
            landing.dismiss()
            onFinished()
        } catch {
            onFinished()
        }
    }
}
