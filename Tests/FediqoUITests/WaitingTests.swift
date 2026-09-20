import Foundation
import Testing
@testable import FediqoUI

/// #64 — the one way this app says something is on its way.
///
/// What is assertable without a screen is what `ShellWaiting` was deliberately split into: a pure
/// `clock(reduceMotion:)` and a pure `wave(_:of:at:)`. Between them they carry both claims the
/// view makes — that a reader who asked for less movement gets no second frame, and that the run
/// stays inside its ends at every instant — which is the shape `EmojiText` and `ForumWaiting`
/// already established here.
@Suite("One way of saying something is on its way")
struct WaitingTests {
    /// **Nothing moves, and it still reads as waiting.** `nil` is not a slow clock; it is the
    /// branch of `body` with no `TimelineView` in it, so there is nothing left that could tick.
    /// The still frame is `wave(0, of: 1, at: 0)`, and it is the plate at full rather than at
    /// some in-between the reader would read as a half-drawn thing.
    @Test("Reduce motion takes the clock away, and the still frame is the plate at full")
    func reduceMotionStopsTheWaitingPlate() {
        #expect(ShellWaiting.clock(reduceMotion: true) == nil)
        #expect(ShellWaiting.clock(reduceMotion: false) == ShellWaiting.tick)
        #expect(ShellWaiting.wave(0, of: 1, at: 0) == 1)
        #expect(ShellWaiting.glow(at: 0) == ShellWaiting.lit)
    }

    /// Fast enough to read as motion, and no faster than this app's own ceiling on how often
    /// anything may ask for a redraw.
    @Test("The clock is under this app's redraw ceiling and slow enough not to read as an alarm")
    func theClockIsWithinTheAppsOwnLimits() {
        #expect(try! #require(ShellWaiting.clock(reduceMotion: false)) >= EmojiClock.fastestTick)
        #expect(ShellWaiting.period > ShellWaiting.tick)
    }

    /// Bounded from **both** sides. A plate that empties is a place that flickers, which is the
    /// whole reason these ends are shallower than the ones a sentence's trailing plates use.
    @Test("The plate stays between banked and lit at every instant, and never empties")
    func theWaitingPlateIsBoundedAndNeverEmpties() {
        #expect(ShellWaiting.banked > 0.5, "a place that nearly empties reads as a flicker")
        #expect(ShellWaiting.lit == 1)
        for step in 0..<400 {
            let instant = Double(step) * 0.017
            let glow = ShellWaiting.glow(at: instant)
            #expect(glow >= ShellWaiting.banked - 1e-9, "at \(instant) the plate went dark")
            #expect(glow <= ShellWaiting.lit + 1e-9, "at \(instant) the plate overran")
            #expect(glow.isFinite)
        }
    }

    /// It is a loop rather than a ramp, and it does move — a wave that drew one frame forever
    /// would pass every bound above.
    @Test("The pass repeats on the period, and something changes inside one")
    func theWaitingPassIsPeriodicAndMoves() {
        #expect(abs(ShellWaiting.wave(0, of: 1, at: 3.5)
            - ShellWaiting.wave(0, of: 1, at: 3.5 + ShellWaiting.period)) < 1e-9)
        #expect(ShellWaiting.wave(0, of: 1, at: 0)
            != ShellWaiting.wave(0, of: 1, at: ShellWaiting.period / 3))
    }

    /// **One rhythm, not two.** `ForumWaiting` is the sentence-carrying sibling and reads its
    /// clock and its wave from here; if either grows a second copy, this is what notices.
    @Test("The sentence's plates and the bare plate move to the same clock and the same wave")
    func oneRhythmForBothWaitingStates() {
        #expect(ForumWaiting.tick == ShellWaiting.tick)
        #expect(ForumWaiting.period == ShellWaiting.period)
        #expect(ForumWaiting.clock(reduceMotion: true) == nil)
        #expect(ForumWaiting.glow(0, at: 0) == ForumWaiting.lit)
        for step in 0..<50 {
            let instant = Double(step) * 0.031
            let ends = ForumWaiting.lit - ForumWaiting.banked
            for plate in 0..<ForumWaiting.plates {
                let wave = ShellWaiting.wave(plate, of: ForumWaiting.plates, at: instant)
                #expect(abs(ForumWaiting.glow(plate, at: instant)
                    - (ForumWaiting.banked + ends * wave)) < 1e-9)
            }
        }
    }

    /// **One waiting place, one sentence — whatever it is built out of.** A plate standing alone
    /// is the place and says so. A plate that is one shape inside a place its surface speaks for
    /// says nothing at all, so a row of them is one utterance rather than one per plate, and that
    /// is the switch rather than a doc comment asking the next surface to be careful. `nil` and
    /// not an empty sentence: silence is a plate a reader never lands on.
    @Test("A plate speaks for itself by default, and is silent where the surface speaks")
    func aPlateSpeaksOnlyWhenItIsTheWaitingPlace() {
        #expect(ShellWaiting.voice(speaks: true) == ShellWaiting.spoken)
        #expect(ShellWaiting.voice(speaks: false) == nil)
        #expect(ShellWaiting().speaks, "a plate standing alone is its own waiting place")
        #expect(ShellWaiting(speaks: false).speaks == false)
    }

    /// **The plate says it; the sentence is only ever heard.** A screen reader gets one line in
    /// whichever language the shell is in, and it is a translation rather than the key falling
    /// through — the key on screen is exactly the failure this app's `value:` fallback hides.
    @Test("The waiting state's one sentence is spoken, translated, in every shipped language")
    func theWaitingSentenceIsSpokenAndTranslated() {
        for language in [DummyLanguage.english, .taiwanese] {
            let spoken = L10n.t("shell.waiting", language: language)
            #expect(spoken != "shell.waiting", "\(language.rawValue) falls through to the key")
            #expect(!spoken.isEmpty)
        }
        #expect(L10n.t("shell.waiting", language: .english)
            != L10n.t("shell.waiting", language: .taiwanese))
    }
}
