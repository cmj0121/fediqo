import FediqoCore
import Foundation

/// What keeps the app running after a phone has put it in the background, until it is given
/// back. The app's is the system's background task; a check's is one that records.
@MainActor
public protocol BackgroundGranting: AnyObject {
    /// Gives the grant back. Asked more than once — by the leaving, and by the system running
    /// out of patience — it is given back once.
    func end()
}

/// What a phone does as the app is left (#344), in the one order in which what was just done
/// is on disk before the device locks.
///
/// **The bound is not the grant.** The system gives a backgrounded app some tens of seconds,
/// but where the phone is locked at once the files close about ten seconds after — and from
/// then on nothing is written, grant or no grant. So the write comes first, ahead of
/// everything else leaving does, and is waited for to its real end:
///
/// 1. **The grant is held already** — taken by the app the moment it is told, before this is
///    asked — and is held through every step here.
/// 2. **What decides what is saved** (`decide`): a step in memory, with no request and no
///    file. First, because the save writes what it leaves.
/// 3. **The save, to its end** (`StoreSaver.finished`): the words waiting to be sent, then
///    the notices, then the items, each a transaction of its own — so the small parts are on
///    disk even where the items are cut off. Not `flush`, which answers at its deadline and
///    leaves the write running with nobody holding the grant for it. A save that fails here
///    is logged and owed (`StoreSaver.owedNow`); it is not tried another way.
/// 4. **Whatever else leaving does** (`then`) — the forum browser's cache dropped — **only
///    where the app is still left, and there is still a device to do it on**: skipped where
///    the person has come back meanwhile (the save can take long enough for that, and a cache
///    is not dropped under somebody reading), where the canary refuses, or where the ten
///    seconds are spent. The next launch's sweep does it instead.
/// 5. **The grant given back**, last. A save the follower begins after step 3 is still under
///    it through step 4.
///
/// **A write cut off all the same** — the grant ending, the files closing mid-transaction —
/// **is a journal and not damage.** SQLite's rollback journal holds each page as it was, and
/// the next open of the index (`StoreFile.init(at:)`, its first read) rolls the write back
/// before anything is read. And a launch made while the device is still locked reads nothing
/// as damage either: that is the canary's rule (`StoreFile.open`).
///
/// **A phone's alone.** A Mac is given no moment before its screen locks and needs none: its
/// app is not suspended, and a save on the connection it holds goes through the lock.
public enum Leaving {
    /// How long after the app is left the device's files may close.
    public static let bound: Duration = .seconds(10)

    /// `clock` is asked when leaving begins and again before step 4; a check hands in its own.
    /// `stillLeft` is asked before step 4, first and for nothing: whether the app is still in
    /// the background.
    /// The canary is asked once, before step 4, and at no other point here: on a phone each
    /// asking makes and unlinks a file.
    @MainActor
    public static func leave(
        holding grant: any BackgroundGranting, decide: @MainActor () async -> Void, saver: StoreSaver,
        protected: ProtectedData, bound: Duration = Leaving.bound,
        clock: @MainActor () -> ContinuousClock.Instant = { .now },
        stillLeft: @MainActor () -> Bool = { true },
        then: @MainActor () async -> Void
    ) async {
        let began = clock()
        await decide()
        await saver.finished()
        if stillLeft(), clock() - began < bound, protected.canary() != .refused { await then() }
        grant.end()
    }
}
