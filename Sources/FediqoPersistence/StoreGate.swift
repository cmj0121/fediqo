import FediqoCore
import Foundation

/// What stands between a launch and its store (#344): the store is opened once, with what it
/// holds readable, and **nothing of the run exists until it has been** — no session, no saver,
/// no window but the launch ground.
///
/// **Why a launch waits rather than starting without its store.** A save replaces everything
/// the index holds with what the run holds. A run that began while the device was locked,
/// holding nothing, and was handed the store a moment later would write that nothing over it.
/// So there is no later open: `opened` is set once, never cleared and never replaced, and the
/// run is built from it.
///
/// **The canary decides whether to open, and events only wake the asking** (`ProtectedData`):
///
/// - **It reads** — every ordinary launch: the store is opened here and now, before the first
///   frame. Should the device lock while it is being opened the answer is `.locked`, nothing
///   is set, and the gate waits like any other.
/// - **It refuses** — the lock's own answer: the gate waits, on a Mac as on a phone, for
///   something to happen, and then asks again. **Unless a person is in front of an unlocked
///   device** (`unlockedForSomebody`): then it is no lock. The canary is written anew, once;
///   if it still will not read the store is opened as one with no canary — but where it was
///   written and then would not be read, that pair is the lock's own signature and the gate
///   waits whatever the platform says of the person.
/// - **There is none, and none can be made** — no room, no folder: nothing to wait for. The
///   store is opened at once as one with no canary, with no event needed, and says what it
///   says today ("no room"). A launch never sits on the launch ground for want of an event.
///
/// With no canary nothing in that launch is classed as damage, put aside or swept
/// (`StoreFile.open`).
@MainActor
public final class StoreGate {
    private let protected: ProtectedData
    private let waits: Bool
    private let unlockedForSomebody: @MainActor () -> Bool
    private let open: @MainActor (_ unlocked: Bool) -> StoreFile.Opened

    /// What the launch found. Set once.
    public private(set) var opened: StoreFile.Opened?

    /// `open` opens the store; handed `unlocked` where a canary that refuses is to be taken
    /// for no canary. `waits` is false only in the simulator, where nothing is ever closed and
    /// a canary that refuses is never a lock. `unlockedForSomebody` is the level **read on the
    /// main actor at the moment it is asked** — the application's own state, not a copy kept
    /// from the last notice; left out, it is `protected`'s. The first asking is here.
    public init(
        protected: ProtectedData, waits: Bool = true,
        unlockedForSomebody: (@MainActor () -> Bool)? = nil,
        open: @escaping @MainActor (_ unlocked: Bool) -> StoreFile.Opened
    ) {
        self.protected = protected
        self.waits = waits
        self.unlockedForSomebody = unlockedForSomebody ?? { protected.unlockedForSomebody() }
        self.open = open
        ask()
    }

    /// Returns once `opened` is set — or, where nothing can any longer wake it, without.
    ///
    /// **The level is read after subscribing, and not only the edge listened for**: a scene
    /// that was already active when this was asked sends no event to say so, and a Mac seldom
    /// sends one at all.
    public func wait() async {
        guard opened == nil else { return }
        let events = protected.changes()
        ask()
        guard opened == nil else { return }
        for await _ in events {
            ask()
            if opened != nil { return }
        }
    }

    private func ask() {
        guard opened == nil else { return }
        var unlocked = false
        if protected.canary() == .refused {
            guard !waits || unlockedForSomebody() else { return }
            let again = protected.remade()
            // Written and then not to be read: the lock itself, whoever is said to be there.
            if waits, again == .closed { return }
            unlocked = again != .reads
        }
        let found = open(unlocked)
        // It locked while the store was being opened: nothing was moved, and nothing is set.
        if found.trouble == .unreachable(.locked) { return }
        opened = found
    }
}
