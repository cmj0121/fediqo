import Foundation

/// Saving, asked for and not waited for.
///
/// **Nothing the person does waits for the store to be written.** A save writes every note down
/// again, and the screen is drawn from the store in memory, which has the change already; so the
/// act that made it goes on, and the write follows. What is this device's alone — a keep mark, a
/// post marked gone, a sign-in's marks let go — is asked for here at once all the same, because
/// no source can say it again; the rest the saver would have followed by itself.
///
/// **Two kinds of caller do wait.** Whoever reads the file next: `saveForCarry()` before a
/// take-away or a move nearby, the room's check before it weighs the index, and the app as it is
/// left or quit, which flushes the saver itself. And an act whose whole point is that something
/// leaves this device (`saveNow`): letting go by dates, by time or by what is marked gone, a
/// post taken back, a signed-out reader's marks — none says it is done while the file still
/// holds what it let go (#292).
extension ShellSession {
    /// Asks for a save now and does not wait. Each ask runs after the one before it.
    /// `then` runs after that save has returned — measuring or compacting the file it wrote.
    ///
    /// On the main actor up to `persist`, which is the app's and hops to the saver's own actor
    /// for the write. The task holds the session until it ends: a save asked for is made.
    func saveSoon(then tail: (@MainActor () async -> Void)? = nil) {
        let before = saving
        saving = Task {
            await before?.value
            await persist?()
            await tail?()
        }
    }

    /// Writes the store now and **waits for it**, for the one kind of act that must: the person
    /// asked for something to be gone from this device, and is not told it is until the write
    /// that takes it off the disk has returned (#292). `then` is not waited for — measuring or
    /// compacting the file is nothing the answer depends on — and runs after every ask before it.
    func saveNow(then tail: (@MainActor () async -> Void)? = nil) async {
        await persist?()
        guard let tail else { return }
        let before = saving
        saving = Task {
            await before?.value
            await tail()
        }
    }

    /// Every save asked for before this call, and its tail, has returned. Not the ones asked for
    /// while it waits: a caller in the middle of steady landings would otherwise never be let go.
    /// What a test awaits before it looks at the file or counts the saves.
    func saved() async {
        await saving?.value
    }
}
