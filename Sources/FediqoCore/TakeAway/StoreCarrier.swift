import Foundation

/// What the shell drives to take a store away and read one back (#247), the way it drives
/// `MediaCopies`: a protocol here, so `FediqoUI` never learns where a store lives on disk, and
/// `FediqoPersistence.StorePackager` is the real one.
///
/// Every call here reaches nowhere off this device. The shell records each as an act under
/// "this device" in the run's list, which is how the person sees that nothing left.
public protocol StoreCarrier: Sendable {
    /// What a package would weigh, with and without the picture copies, and what this device
    /// has room for — asked before the person chooses.
    func weigh() async throws -> PackageWeight
    /// Writes the whole of what this device holds to `url`, locked by `key`, with the picture
    /// copies where `pictures` says so. `progress` is told as it goes.
    func takeAway(
        to url: URL, key: PackageKey, pictures: Bool, progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws
    /// What the package at `url` says it holds, once `key` opens it: #252's question, and nothing
    /// on this device changes.
    func preview(_ url: URL, key: PackageKey) async throws -> PackageSummary
    /// Reads the package at `url` back onto this device, whole or not at all. `replacing` is the
    /// person's answer to what becomes of a store already held: without it, a held store refuses
    /// (`PackageFault.alreadyHeld`).
    func readBack(
        _ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws
}

/// What taking away would come to.
public struct PackageWeight: Sendable, Equatable {
    public let withoutPictures: Int
    public let withPictures: Int
    /// What the volume the store lives on has free, for the staging a read back needs.
    public let free: Int
    /// Whether this device holds a store now — a source, at least — which a read back must ask
    /// about before replacing.
    public let holdsStore: Bool

    public init(withoutPictures: Int, withPictures: Int, free: Int, holdsStore: Bool) {
        self.withoutPictures = withoutPictures
        self.withPictures = withPictures
        self.free = free
        self.holdsStore = holdsStore
    }
}

/// How far a take-away or a read back has come, in bytes of what the entries hold.
public struct PackageProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Between 0 and 1, and 1 where there was nothing to do.
    public var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 1
    }
}
