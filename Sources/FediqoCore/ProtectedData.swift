import Foundation

/// Whether what the app keeps can be read right now (#344), as one thing a launch and a save
/// can ask — and a test can turn by hand.
///
/// **The probe decides, and nothing else does.** The system's flag and its notices arrive on
/// the main run loop, so neither can change while the store is being opened there: a device
/// that locks ten seconds into a launch would be invisible to them. The canary is a closed
/// file of the same class in the same folder as the index, opened afresh each time it is
/// asked, and so is refused exactly when a fresh open of the index is. The flag is asked
/// beside it; the events only ever wake something that then asks the probe.
public struct ProtectedData: Sendable {
    /// What the probe found.
    public enum Canary: Sendable, Equatable {
        /// It is there, at the class, and was read.
        case reads
        /// It is there and will not be read, or cannot be made at its class: the lock's own
        /// answer.
        case refused
        /// There is none, and one could not be made for a reason that is plainly no lock — no
        /// room, no folder. Nothing can then tell a lock from damage.
        case none
        /// Written anew a moment ago and then not to be read: the lock's own signature where
        /// new files can still be made — a Mac's — and **the lock whatever else says the
        /// device is unlocked**. Only `remade` answers it.
        case closed
    }

    /// The system's own word that protected data is available.
    public var flag: @Sendable () -> Bool
    /// The probe: a fresh read of the canary, made first where there is none.
    public var canary: @Sendable () -> Canary
    /// The canary written anew, once, and probed again: what is tried where it will not read
    /// and the device is known to be unlocked.
    public var remade: @Sendable () -> Canary
    /// Whether a person is in front of an unlocked device, as far as the platform can say:
    /// on a phone, that the scene is active — which is itself proof; on a Mac, that the
    /// screen is not locked, or, where that cannot be read, that the app is active. A canary
    /// that refuses while this holds is no canary, and not a lock.
    public var unlockedForSomebody: @Sendable () -> Bool
    /// Something happened that may have changed the answer: the device unlocked, the scene
    /// became active, a Mac woke. **A wake-up and nothing more** — whoever hears it asks the
    /// probe.
    public var changes: @Sendable () -> AsyncStream<Void>

    public init(
        flag: @escaping @Sendable () -> Bool, canary: @escaping @Sendable () -> Canary,
        remade: @escaping @Sendable () -> Canary, unlockedForSomebody: @escaping @Sendable () -> Bool,
        changes: @escaping @Sendable () -> AsyncStream<Void>
    ) {
        self.flag = flag
        self.canary = canary
        self.remade = remade
        self.unlockedForSomebody = unlockedForSomebody
        self.changes = changes
    }

    /// Both: the system's flag, and the canary read.
    public func isAvailable() -> Bool { flag() && canary() == .reads }

    /// A store nothing ever closes: a test's scratch folder, a store not on disk at all.
    public static let always = ProtectedData(
        flag: { true }, canary: { .reads }, remade: { .reads }, unlockedForSomebody: { true },
        changes: { AsyncStream { $0.finish() } }
    )

    /// The canary in `folder`, asked of the disk, with the platform's signals handed in.
    public static func canary(
        in folder: URL, flag: @escaping @Sendable () -> Bool,
        unlockedForSomebody: @escaping @Sendable () -> Bool,
        changes: @escaping @Sendable () -> AsyncStream<Void>
    ) -> ProtectedData {
        ProtectedData(
            flag: flag, canary: { Guarded.probeCanary(in: folder) },
            remade: { Guarded.probeCanary(in: folder, anew: true) },
            unlockedForSomebody: unlockedForSomebody, changes: changes
        )
    }
}
