import Foundation

/// Holds process termination until the quit-write finishes.
///
/// On a Mac, Cmd+Q often never delivers `scenePhase == .background`. A fire-and-forget
/// `Task { await save() }` dies with the process. The app delays its quit reply until
/// `save` returns.
@MainActor
public enum PersistOnQuit {
    public static func holdUntilSaved(
        save: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        Task {
            await save()
            reply()
        }
    }
}
