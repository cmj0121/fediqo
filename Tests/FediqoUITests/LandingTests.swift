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
        #expect(Landing.toastMark < Landing.mark)
        #expect(Landing.duration > 0)
        #expect(Landing.hold > 0)
        #expect(Landing.pass == Landing.hold + Landing.duration * 2)
    }

    @Test("The cosine eases from rest to a full turn")
    func theCosineEasesFromRestToAFullTurn() {
        #expect(abs(Landing.ease(0)) < 1e-9)
        #expect(abs(Landing.ease(0.5) - 0.5) < 1e-9)
        #expect(abs(Landing.ease(1) - 1) < 1e-9)
        #expect(abs(Landing.ease(-1)) < 1e-9)
        #expect(abs(Landing.ease(2) - 1) < 1e-9)
    }

    @Test("Looping the two flips keeps adding 360")
    func loopingKeepsAddingAFullTurn() {
        let first = Landing.orientation(at: Landing.pass, looping: true)
        #expect(abs(first.pitch - Landing.flip) < 1e-9)
        #expect(abs(first.yaw - Landing.flip) < 1e-9)
        let second = Landing.orientation(at: Landing.pass * 2, looping: true)
        #expect(abs(second.pitch - Landing.flip * 2) < 1e-9)
        #expect(abs(second.yaw - Landing.flip * 2) < 1e-9)
        let once = Landing.orientation(at: Landing.pass * 2, looping: false)
        #expect(once.pitch == Landing.flip)
        #expect(once.yaw == Landing.flip)
    }

    @Test("Reduce motion takes the clock away, and the loading mascot stays unturned")
    func reduceMotionTakesTheClockAway() {
        #expect(Landing.clock(reduceMotion: true) == nil)
        #expect(Landing.clock(reduceMotion: false) == EmojiClock.fastestTick)
        let loading = Landing.loading(reduceMotion: true)
        #expect(loading.showing)
        #expect(loading.pitch == 0)
        #expect(loading.yaw == 0)
        let launch = Landing.start(reduceMotion: true)
        #expect(!launch.showing)
    }

    /// `r` remounts this value from rest. A flip already spent must not be the next first frame.
    @Test("A dismissed launch can be shown again, unturned")
    func aDismissedLaunchCanBeShownAgain() {
        var launch = Landing.start(reduceMotion: false)
        launch.flipVertical()
        launch.flipHorizontal()
        launch.dismiss()
        let again = Landing.start(reduceMotion: false)
        #expect(again.showing)
        #expect(again.pitch == 0)
        #expect(again.yaw == 0)
    }
}
