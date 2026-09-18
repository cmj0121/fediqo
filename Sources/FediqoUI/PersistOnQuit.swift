import Foundation

/// Holds process termination until the quit-write finishes, or until a deadline passes.
///
/// On a Mac, Cmd+Q often never delivers `scenePhase == .background`, and a fire-and-forget
/// `Task { await save() }` dies with the process. The app answers `.terminateLater` and replies
/// once the write returns.
///
/// **But never later than `deadline`.** A write that hangs — a locked file, a disk that stopped
/// answering — must not turn Cmd+Q into a quit that never happens; past the deadline the reply
/// goes anyway, and what the save had not written is what the last save wrote.
@MainActor
public enum PersistOnQuit {
    /// How the quit was let go.
    public enum Outcome: Equatable, Sendable {
        case saved
        case failed
        case timedOut
    }

    /// Long enough for any index this app writes; short enough that a hung write reads as a slow
    /// quit rather than a broken one.
    public static let deadline: Duration = .seconds(3)

    /// Starts `save`, and calls `reply` exactly once: when `save` returns, or when `deadline`
    /// passes first.
    public static func holdUntilSaved(
        deadline: Duration = deadline,
        save: @escaping @Sendable () async throws -> Void,
        reply: @escaping @MainActor (Outcome) -> Void
    ) {
        let once = Once(reply)
        let timer = Task {
            try await Task.sleep(for: deadline)
            once.answer(.timedOut)
        }
        Task {
            let outcome: Outcome
            do {
                try await save()
                outcome = .saved
            } catch {
                outcome = .failed
            }
            timer.cancel()
            once.answer(outcome)
        }
    }

    /// The one reply a quit gets, whichever of the save and the deadline comes first.
    @MainActor
    private final class Once {
        private var reply: (@MainActor (Outcome) -> Void)?

        init(_ reply: @escaping @MainActor (Outcome) -> Void) {
            self.reply = reply
        }

        func answer(_ outcome: Outcome) {
            guard let reply else { return }
            self.reply = nil
            reply(outcome)
        }
    }
}
