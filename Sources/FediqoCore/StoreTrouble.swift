import Foundation

/// What went wrong with this device's store at launch, where something did (#295) — said to the
/// person at the first thing they see, and never left to a log line.
///
/// **The causes are not treated alike, because they are not alike.** A store that is damaged
/// will be damaged at every later launch, so it is put aside and an empty one takes its place.
/// A store that is only out of reach for now — another copy of the app is writing it, there is
/// no room left, the folder would not answer — is as good as it was, and a launch that put it
/// aside would turn one bad moment into everything the person had, gone: it is left exactly
/// where it is, nothing replaces it, and the run has no store at all.
public enum StoreTrouble: Equatable, Sendable {
    /// Why a store that may be perfectly good could not be opened this time.
    public enum Unreachable: Equatable, Sendable {
        /// Another connection holds it: another copy of the app, mid-save.
        case inUse
        /// There is no room left to open it in.
        case noRoom
        /// Anything else about the moment and not about the store: the folder or the file would
        /// not be read or written.
        case outOfReach
        /// A read back was interrupted, and the store it had moved out of the way could not be
        /// moved back (`StorePackager.settleHalfCommits`).
        case readBackInterrupted
        /// The store was damaged and has been put aside, and no new one could be made in its
        /// place this time. Something on disk did change: the damaged store moved.
        case putAsideOnly
        /// Of two stores, the one the person chose proved damaged and has been put aside; the
        /// other, kept until the chosen one had opened and saved, is put back at the next launch.
        case otherComesBack
    }

    /// What took a damaged store's place.
    public enum Replacement: Equatable, Sendable {
        /// An empty store.
        case empty
        /// The other of two stores (`Unreachable.otherComesBack`): nothing empty took its place.
        case otherStore
    }

    /// The store could not be opened. This run reads nothing and saves nothing, and what is
    /// done in it is not kept; the next launch tries again. Nothing on disk was changed, but
    /// for the two reasons that say a damaged store was put aside.
    case unreachable(Unreachable)
    /// A store that could not be read was put aside, by this launch or by one before it that
    /// never got to say so, and something took its place. What was put aside is deleted once
    /// the person has been told — by their own press on the notice, and nothing else — and what
    /// took its place has been saved (`StoreFile.told(in:)`, in the persistence layer).
    case damaged(replacedBy: Replacement)
    /// A read back was interrupted, and the device holds two stores it cannot choose between:
    /// one where the store belongs, and the one the read back had moved out of the way. This
    /// run has no store until the person chooses (`StorePackager.choose(_:in:)`).
    case twoStores(inPlace: StoreGlance, setAside: StoreGlance)
}

/// What can be said of a store without opening it to write: when its file was last written, and
/// how many posts it holds — or nothing of either, where it would not say.
public struct StoreGlance: Equatable, Sendable {
    public let written: Date?
    public let posts: Int?

    public init(written: Date?, posts: Int?) {
        self.written = written
        self.posts = posts
    }
}

/// What the person answered to a store's trouble.
public enum StoreTroubleAnswer: Equatable, Sendable {
    /// They pressed the notice's own button: they have been told. Never the notice merely
    /// going away — a sheet is taken down for many reasons, and what waits on this is a deletion.
    case told
    /// Of two stores: the one where the store belongs is the store.
    case keepInPlace
    /// Of two stores: the one a read back moved out of the way is put back.
    case putBack
}
