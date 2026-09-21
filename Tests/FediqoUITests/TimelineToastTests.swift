import Foundation
import Testing
@testable import FediqoUI

/// #82 — what is on its way, and what went wrong, is said in the bottom toast.
///
/// What is assertable without a screen is the kind the capsule decides from, that
/// loading reuses the launch flip's numbers, and that Reduce Motion takes the clock
/// away. The suite is `@MainActor` for the reason `WaitingTests` is: `TimelinePane`
/// and `LandingMascot` belong to a `View`.
@Suite("The bottom toast carries wait and miss")
@MainActor
struct TimelineToastTests {
    init() {
        L10n.language = .english
    }

    @Test("Running is loading, and it stays")
    func runningIsLoadingAndStays() {
        let toast = TimelineToast.shown(
            running: true,
            line: L10n.t("timeline.reload.progress"),
            stopped: false,
            note: nil
        )
        #expect(toast?.kind == .loading)
        #expect(toast?.text == L10n.t("timeline.reload.progress"))
        #expect(toast?.stays == true)
        #expect(toast?.text == "Reloading…")
    }

    @Test("A failed line is an error, and it stays")
    func failedLineIsAnError() {
        let line = String(format: L10n.t("timeline.reload.failed"), "one.example")
        let toast = TimelineToast.shown(
            running: false, line: line, stopped: false, note: nil
        )
        #expect(toast?.kind == .error)
        #expect(toast?.text == line)
        #expect(toast?.stays == true)
        #expect(toast?.text.contains("one.example") == true)
    }

    @Test("A stopped reload is a warning, and it stays")
    func stoppedIsAWarning() {
        let line = L10n.t("timeline.reload.stopped")
        let toast = TimelineToast.shown(
            running: false, line: line, stopped: true, note: nil
        )
        #expect(toast?.kind == .warning)
        #expect(toast?.text == line)
        #expect(toast?.stays == true)
        #expect(toast?.text == "Reload stopped.")
    }

    @Test("An unfindable post is an error")
    func unfindableIsAnError() {
        let line = ShellReload.Unfindable.signedOut(host: "one.example").sentence
        let toast = TimelineToast.shown(
            running: false, line: line, stopped: false, note: nil
        )
        #expect(toast?.kind == .error)
        #expect(toast?.text == line)
        #expect(toast?.stays == true)
    }

    @Test("A note is a note, and it does not stay")
    func aNoteIsANote() {
        let toast = TimelineToast.shown(
            running: false, line: nil, stopped: false, note: L10n.t("timeline.edit.fixed")
        )
        #expect(toast?.kind == .note)
        #expect(toast?.text == L10n.t("timeline.edit.fixed"))
        #expect(toast?.stays == false)
    }

    @Test("Running wins over a leftover line and over a note")
    func runningWins() {
        let toast = TimelineToast.shown(
            running: true,
            line: L10n.t("timeline.reload.progress"),
            stopped: false,
            note: L10n.t("timeline.edit.fixed")
        )
        #expect(toast?.kind == .loading)
        let leftover = TimelineToast.shown(
            running: true,
            line: String(format: L10n.t("timeline.reload.failed"), "one.example"),
            stopped: false,
            note: nil
        )
        #expect(leftover?.kind == .loading)
    }

    @Test("A later note replaces a leftover line")
    func aLaterNoteReplacesALeftoverLine() {
        let line = String(format: L10n.t("timeline.reload.failed"), "one.example")
        let toast = TimelineToast.shown(
            running: false, line: line, stopped: false, note: L10n.t("timeline.edit.fixed")
        )
        #expect(toast?.kind == .note)
        #expect(toast?.text == L10n.t("timeline.edit.fixed"))
        let after = TimelineToast.shown(
            running: false, line: line, stopped: false, note: nil
        )
        #expect(after?.kind == .error)
        #expect(after?.text == line)
    }

    @Test("Nothing to say is no toast")
    func nothingIsNoToast() {
        #expect(TimelineToast.shown(
            running: false, line: nil, stopped: false, note: nil
        ) == nil)
    }

    @Test("Loading uses the launch flip, duration, and hold")
    func loadingUsesTheLaunchFlip() {
        #expect(Landing.toastMark < Landing.mark)
        #expect(Landing.toastMark > 0)
        #expect(Landing.flip == 360)
        #expect(Landing.duration == 0.45)
        #expect(Landing.hold == 0.2)
        #expect(Landing.pass == Landing.hold + Landing.duration * 2)

        let rest = Landing.orientation(at: 0, looping: true)
        #expect(rest.pitch == 0)
        #expect(rest.yaw == 0)
        let held = Landing.orientation(at: Landing.hold, looping: true)
        #expect(held.pitch == 0)
        #expect(held.yaw == 0)

        let midPitch = Landing.orientation(
            at: Landing.hold + Landing.duration / 2, looping: true
        )
        #expect(abs(midPitch.pitch - Landing.flip / 2) < 1e-9)
        #expect(midPitch.yaw == 0)

        let afterPitch = Landing.orientation(
            at: Landing.hold + Landing.duration, looping: true
        )
        #expect(abs(afterPitch.pitch - Landing.flip) < 1e-9)
        #expect(afterPitch.yaw == 0)

        let done = Landing.orientation(at: Landing.pass, looping: true)
        #expect(abs(done.pitch - Landing.flip) < 1e-9)
        #expect(abs(done.yaw - Landing.flip) < 1e-9)

        let again = Landing.orientation(at: Landing.pass * 2, looping: true)
        #expect(abs(again.pitch - Landing.flip * 2) < 1e-9)
        #expect(abs(again.yaw - Landing.flip * 2) < 1e-9)
    }

    @Test("Reduce Motion shows the mascot still, with no clock")
    func reduceMotionShowsTheMascotStill() {
        let still = Landing.loading(reduceMotion: true)
        #expect(still.showing)
        #expect(still.pitch == 0)
        #expect(still.yaw == 0)
        #expect(Landing.clock(reduceMotion: true) == nil)
        #expect(Landing.clock(reduceMotion: false) == EmojiClock.fastestTick)
        let turned = Landing.orientation(at: 5, looping: true, reduceMotion: true)
        #expect(turned.pitch == 0)
        #expect(turned.yaw == 0)
    }

    @Test("The toast sentences exist in both languages")
    func toastSentencesAreTranslated() {
        for key in [
            "timeline.reload.progress", "timeline.reload.failed", "timeline.reload.stopped",
            "thread.reload.unfindable", "thread.reload.notfound", "thread.reload.scope",
        ] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
        #expect(
            L10n.t("timeline.reload.progress", language: .english)
                != L10n.t("timeline.reload.progress", language: .taiwanese)
        )
    }
}
