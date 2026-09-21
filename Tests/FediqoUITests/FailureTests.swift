import Foundation
import Testing
@testable import FediqoUI

/// #67 — what did not arrive says so where it would have been, and can be tried again from there.
///
/// What is assertable without a screen is the sentence the place speaks, that a retry is named,
/// that a timeline and a thread and a picture all read that sentence, and that a second miss
/// replaces rather than stacks. The suite is `@MainActor` for the reason WaitingTests is:
/// everything it reads belongs to a View.
@Suite("What did not arrive says so in its place")
@MainActor
struct FailureTests {

    /// One vocabulary: the source, named, in every shipped language, and a retry a reader
    /// can activate. The key falling through is the failure `value:` hides.
    @Test("The failure place names the source and offers try-again, translated")
    func theFailureSentenceNamesTheSource() {
        let sources = ["one.example"]
        #expect(ShellFailure.spoken(sources).contains("one.example"))
        #expect(ShellFailure.spoken(["one.example", "two.example"]).contains("one.example"))
        #expect(ShellFailure.spoken(["one.example", "two.example"]).contains("two.example"))
        #expect(!ShellFailure.retryName.isEmpty)
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["shell.failed", "shell.failed.retry"] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
            let spoken = String(format: L10n.t("shell.failed", language: language), "one.example")
            #expect(spoken.contains("one.example"))
            #expect(!L10n.t("shell.failed.retry", language: language).isEmpty)
        }
        #expect(L10n.t("shell.failed", language: .english)
            != L10n.t("shell.failed", language: .taiwanese))
        #expect(L10n.t("shell.failed.retry", language: .english)
            != L10n.t("shell.failed.retry", language: .taiwanese))
    }

    /// zh-TW and zh-Hant stay byte-identical, including the new keys.
    @Test("The two Chinese string files are the same bytes")
    func chineseFilesAgree() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let tw = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(tw == hant)
    }

    /// Arriving ends in failed; failed plus a retry that lands is held. Search never becomes
    /// a network failure: it reads the store and asks no source.
    @Test("Arriving becomes failed, and a retry that lands is held")
    func arrivingBecomesFailedAndRetryLandsHeld() {
        let arriving = TimelinePane.standing(
            running: true, hasItems: false, searching: false, hasSources: true
        )
        let failed = TimelinePane.standing(
            running: false, hasItems: false, searching: false, hasSources: true,
            failed: ["one.example"]
        )
        let held = TimelinePane.standing(
            running: false, hasItems: true, searching: false, hasSources: true,
            failed: ["one.example"]
        )
        #expect(arriving == .arriving)
        #expect(failed == .failed)
        #expect(held == .held)
        #expect(ShellFailure.spoken(["one.example"]) == String(
            format: L10n.t("shell.failed"), "one.example"
        ))
    }

    /// An open thread uses the same place and the same reload. A wait still on the wire is
    /// not a failure. A second host in the list is still one place.
    @Test("A thread reload miss is one failure place, and a wait is not")
    func threadReloadMissIsOneFailurePlace() {
        #expect(DummyThreadPane.failureSources(failed: [], standing: nil) == nil)
        #expect(DummyThreadPane.failureSources(failed: ["one.example"], standing: nil)
            == ["one.example"])
        #expect(DummyThreadPane.failureSources(
            failed: ["one.example", "two.example"], standing: nil
        ) == ["one.example", "two.example"])
        #expect(DummyThreadPane.failureSources(failed: ["one.example"], standing: .coming) == nil)
        #expect(DummyThreadPane.failureSources(failed: ["one.example"], standing: .unasked)
            == ["one.example"])
        #expect(DummyThreadPane.failureSources(
            failed: ["one.example"], standing: .absent(.unreachable)
        ) == ["one.example"])
        #expect(DummyThreadPane.failureSources(failed: [], standing: .absent(.unreachable)) == nil)
    }

    /// `r` stays the reload key. The failure place does not remap it.
    @Test("r is still the reload key")
    func rRemainsReload() {
        #expect(DummyCommand.from("r") == .reload)
    }
}
