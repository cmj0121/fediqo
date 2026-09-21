import Foundation
import Testing
@testable import FediqoUI

/// #82 — what is on its way, and what went wrong, is said in the bottom toast.
///
/// What is assertable without a screen is the kind the capsule decides from, and
/// that a wait is a spinner or an hourglass, not the launch mascot. The suite is
/// `@MainActor` for the reason `WaitingTests` is: `TimelinePane` belongs to a `View`.
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

    @Test("A wait is a spinner, or an hourglass when motion is asked to stop")
    func aWaitIsASpinnerOrAnHourglass() {
        #expect(TimelineToast.waitMark(reduceMotion: false) == .spinner)
        #expect(TimelineToast.waitMark(reduceMotion: false).symbol == nil)
        #expect(TimelineToast.waitMark(reduceMotion: true) == .hourglass)
        #expect(TimelineToast.waitMark(reduceMotion: true).symbol == "hourglass")
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
