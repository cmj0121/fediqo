import Foundation
import SwiftUI

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
/// post taken back, a notice dismissed, a source removed or cleared, a signed-out reader's
/// marks — none says it is done while the file still holds what it let go (#292).
///
/// **And where that write did not land, the person is told** (`Said.Unwritten`): once, on the
/// strip of every page, that what they let go could not be taken off this device yet and will
/// be tried again. It is: the saver tries a write that failed again by itself
/// (`StoreSaver.follow`), and the line goes at its `×` or with the next save this session
/// makes that lands.
extension ShellSession {
    /// Writes the store and says whether the write happened — true in a session nobody gave
    /// a disk, which has no file for anything to be left in. A write that lands takes down
    /// what was said of one that had not, and the line of a text whose words it took out. On the main actor up to `persist`, which is the
    /// app's and hops to the saver's own actor for the write.
    @discardableResult
    func write() async -> Bool {
        guard let persist else { return true }
        let written = await persist()
        if written { landed() }
        return written
    }

    /// A save of the whole store landed — this session's, another window's, or the saver's own
    /// retry: what was said not to be off this device yet now is, and the line of a text whose
    /// words it took out goes. On the main actor, with no wait inside.
    func landed() {
        said.written()
        outbox.written()
    }

    /// The saver, followed: each save that writes every part after a write had failed
    /// (`StoreSaver.landings`) is `landed()` here, so a line this session said is taken down
    /// by a save it never asked for. Until the task running it is cancelled — a modifier's
    /// own (`FollowingSaves`), so a window closed stops listening. Nothing in a session
    /// nobody gave a saver. Each landing is heard on the saver's actor and acted on here, on
    /// the main actor.
    func followSaves() async {
        guard let landings = await savesLanded?() else { return }
        for await _ in landings { landed() }
    }

    /// Asks for a save now and does not wait. Each ask runs after the one before it.
    /// `then` runs after that save has returned — measuring or compacting the file it wrote.
    ///
    /// On the main actor up to `persist`, which is the app's and hops to the saver's own actor
    /// for the write. The task holds the session until it ends: a save asked for is made.
    func saveSoon(then tail: (@MainActor () async -> Void)? = nil) {
        let before = saving
        saving = Task {
            await before?.value
            await self.write()
            await tail?()
        }
    }

    /// Writes the store now and **waits for it**, for the one kind of act that must: the person
    /// asked for something to be gone from this device, and is not told it is until the write
    /// that takes it off the disk has returned (#292). `then` is not waited for — measuring or
    /// compacting the file is nothing the answer depends on — and runs after every ask before it.
    ///
    /// **Says whether the write happened, and where it did not, says so to the person**: one
    /// line on the strip naming `gone` — what they asked to be gone — as not off this device
    /// yet (`Said.Unwritten`). Said once: a line already standing for the same thing is left as
    /// it is, neither moved nor said aloud again.
    @discardableResult
    func saveNow(_ gone: Said.Unwritten, then tail: (@MainActor () async -> Void)? = nil) async -> Bool {
        let written = await write()
        if !written {
            let line = Said(.unwritten(gone), .unreachable, host: "")
            if !said.lines.contains(where: { $0.id == line.id }) { said.say(line) }
        }
        guard let tail else { return written }
        let before = saving
        saving = Task {
            await before?.value
            await tail()
        }
        return written
    }

    /// Every save asked for before this call, and its tail, has returned. Not the ones asked for
    /// while it waits: a caller in the middle of steady landings would otherwise never be let go.
    /// What a test awaits before it looks at the file or counts the saves.
    func saved() async {
        await saving?.value
    }
}

/// Listens for saves that landed after one had failed (`ShellSession.followSaves`) for as long
/// as the root is up — a modifier, so the root's chain gains one plain call and no closure.
struct FollowingSaves: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.task { await session.followSaves() }
    }
}
