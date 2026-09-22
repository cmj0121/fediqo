import FediqoCore
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

    /// A wait and a miss are the toast; the stream is held or empty. Search never becomes
    /// a network failure: it reads the store and asks no source. Pictures still use this
    /// place — that is not this task.
    @Test("A wait and a miss leave the stream empty or held")
    func aWaitAndAMissLeaveTheStream() {
        // The stream is its rows, or the empty notice where it has none — a reload's running and
        // its misses are not inputs to that choice. What a running or missed reload leaves in an
        // empty stream is the notice for "not everybody was asked", never the wait or the miss.
        let empty = EmptyNotice.timeline(
            searching: false, indexed: true, query: .all, notes: [], written: [],
            sources: [Source(host: "one.example", kind: .mastodon)], index: TextIndex([]),
            latest: nil, asked: false, language: .english
        )
        #expect(empty.kind == .held)
        #expect(empty.spoken != ShellWaiting.spoken)
        #expect(empty.title != ShellFailure.spoken(["one.example"]))
        #expect(ShellFailure.spoken(["one.example"]) == String(
            format: L10n.t("shell.failed"), "one.example"
        ))
    }

    /// An open thread's miss is the toast; the thread stays the thread, or the
    /// empty-thread notice. A wait still on the wire is still the replies wait.
    @Test("A thread reload miss is not a pane-sized failure")
    func threadReloadMissIsNotAFailurePlace() {
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: nil
        )?.kind == .thread)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: ForumRepliesStanding.none
        )?.kind == .thread)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: .coming
        ) == nil)
    }

    /// `r` stays the reload key. The failure place does not remap it.
    @Test("r is still the reload key")
    func rRemainsReload() {
        #expect(DummyCommand.from("r") == .reload)
    }
}
