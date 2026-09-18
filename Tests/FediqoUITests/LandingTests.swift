import Testing
@testable import FediqoUI

@Suite("The launch mascot")
struct LandingTests {
    /// **A reader who asked for less movement never sees a flip.** The same claim, in the
    /// same shape, as `ForumWaiting.clock(reduceMotion:)`: the skip is the starting value,
    /// not a zero-speed animation the view might still tick.
    @Test("Reduce motion starts dismissed, with the mascot unturned")
    func reduceMotionStartsDismissed() {
        let still = Landing.start(reduceMotion: true)
        #expect(!still.showing)
        #expect(still.pitch == 0)
        #expect(still.yaw == 0)
    }

    @Test("A launch starts showing the mascot, unturned")
    func aLaunchStartsShowingTheMascotUnturned() {
        let launch = Landing.start(reduceMotion: false)
        #expect(launch.showing)
        #expect(launch.pitch == 0)
        #expect(launch.yaw == 0)
    }

    /// Up-down is X, left-right is Y, and each is a full turn so the mascot lands the
    /// right way up. The order is the user's own: up-down, then left-right.
    @Test("Up-down is a full turn about X, then left-right is a full turn about Y")
    func flipsAreVerticalThenHorizontalFullTurns() {
        var launch = Landing.start(reduceMotion: false)
        launch.flipVertical()
        #expect(launch.pitch == Landing.flip)
        #expect(launch.yaw == 0)
        #expect(launch.showing)
        launch.flipHorizontal()
        #expect(launch.pitch == Landing.flip)
        #expect(launch.yaw == Landing.flip)
        #expect(launch.showing)
        launch.dismiss()
        #expect(!launch.showing)
        #expect(launch.pitch == Landing.flip)
        #expect(launch.yaw == Landing.flip)
    }

    @Test("A flip is 360 degrees, and the mascot is larger than an icon")
    func flipIsAFullTurnAndTheMarkIsTheSubject() {
        #expect(Landing.flip == 360)
        #expect(Landing.mark > 72)
        #expect(Landing.duration > 0)
        #expect(Landing.hold > 0)
    }
}
