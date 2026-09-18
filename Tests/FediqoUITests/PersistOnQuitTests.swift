import Foundation
import Testing
@testable import FediqoUI

@Suite("Quit write")
@MainActor
struct PersistOnQuitTests {
    @MainActor
    private final class Log {
        var steps: [String] = []
        var outcomes: [PersistOnQuit.Outcome] = []
    }

    private struct Refused: Error {}

    /// Runs `holdUntilSaved` and returns once it has replied, then waits `settle` more so a
    /// second reply, were there one, would land in the log too.
    private func quit(
        deadline: Duration,
        settle: Duration = .milliseconds(0),
        log: Log,
        save: @escaping @Sendable () async throws -> Void
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PersistOnQuit.holdUntilSaved(deadline: deadline, save: save) { outcome in
                log.steps.append("reply")
                log.outcomes.append(outcome)
                if log.outcomes.count == 1 { cont.resume() }
            }
        }
        try? await Task.sleep(for: settle)
    }

    @Test("The quit reply waits until the write returns")
    func quitReplyWaitsForSave() async {
        let log = Log()
        await quit(deadline: .seconds(10), log: log) {
            try await Task.sleep(for: .milliseconds(20))
            await MainActor.run { log.steps.append("save") }
        }
        #expect(log.steps == ["save", "reply"])
        #expect(log.outcomes == [.saved])
    }

    @Test("A write that hangs does not hold the quit past the deadline, and it replies once")
    func quitRepliesAfterTheDeadline() async {
        let log = Log()
        let started = ContinuousClock.now
        await quit(deadline: .milliseconds(50), settle: .milliseconds(100), log: log) {
            // Never returns within the test: a write stuck on a disk that stopped answering.
            try? await Task.sleep(for: .seconds(60))
        }
        #expect(log.outcomes == [.timedOut])
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("A write that fails still lets the quit go, and says so")
    func quitRepliesWhenTheWriteFails() async {
        let log = Log()
        await quit(deadline: .seconds(10), settle: .milliseconds(20), log: log) { throw Refused() }
        #expect(log.outcomes == [.failed])
    }
}
