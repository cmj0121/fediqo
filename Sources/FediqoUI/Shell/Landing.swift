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
    static let flip: Double = 360
    /// Slower than a control's 0.18 so the mascot is readable mid-turn.
    static let duration: TimeInterval = 0.45
    /// A beat at rest so the mascot is seen before it moves.
    static let hold: TimeInterval = 0.2

    static func start(reduceMotion: Bool) -> Landing {
        Landing(pitch: 0, yaw: 0, showing: !reduceMotion)
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
                .rotation3DEffect(
                    .degrees(landing.pitch),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.55
                )
                .rotation3DEffect(
                    .degrees(landing.yaw),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )
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
