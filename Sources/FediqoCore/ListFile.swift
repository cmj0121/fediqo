import Foundation
import os

/// One of the person's own lists on disk (#344): one file beside the index, in Application
/// Support, written through `Guarded` as the limits' account is. Here and not beside that
/// account's own code, because the lists' owners are the interface's and the packager both.
///
/// **Beside the index and not in the preferences.** What may be reached beyond a source, and
/// the timelines a person wrote, name the sources they read and the words they filter. The
/// preferences are the system's file, at the system's class; this one is made at the store's,
/// and cannot be read while the device is locked. One small file each rather than a table,
/// because nothing queries them: each is read whole and written whole, at the act.
///
/// **Earlier builds kept each under a preference key, and it is moved once** (`held`): read
/// between two good canary reads, written here, read back, and only then is the key removed.
///
/// - **Where there is a file, the file is the list**, and a key found beside it is removed: a
///   move cut short between the two, or a build from before this one having run since — whose
///   key is never moved over the file.
/// - **Where there is none, the key is read** — and an absent key is "none" only between two
///   good canary reads: preferences that read empty behind a lock are not an empty list.
/// - **A file that is there and will not be read is neither**, and is never written over.
/// - **No file is made from nothing.** Where the key is truly absent the list is none, no file
///   is written, and the next launch asks the key again — until a first real write.
///
/// The bytes are the owner's: this neither reads nor judges them, so a shape a later build
/// wrote is moved as it is.
public struct ListFile: @unchecked Sendable {
    /// What is kept.
    public enum Read: Equatable, Sendable {
        /// Nothing is kept: no file, and no key an earlier build left.
        case none
        case data(Data)
        /// A file is there and will not be read. Never "none", and nothing is written while
        /// it lasts.
        case unread
        /// No file, and preferences holding no key on a device not known to be unlocked — a
        /// run with no canary: whether anything is kept is not known, and a first file is
        /// not made of that. Never "none".
        case notKnown
    }

    /// Thrown where there is no file and the preferences hold no key, on a device not known to
    /// be unlocked: whether anything is kept is not known.
    package struct NotKnown: Error {}

    /// The preference key earlier builds kept this list under, and the name it still rides in
    /// a package by.
    public let key: String
    package let url: URL
    private let defaults: UserDefaults
    private let protected: ProtectedData
    private let device: Guarded.Device
    /// Whether something under the key that is not what any build wrote is read as nothing
    /// kept, as the list's owner always read it — and so replaced by the first write.
    private let otherIsNone: Bool

    /// What comes between a list's name and the rest of the name it is moved aside under
    /// while a read back replaces it (`putAside`).
    package static let asideInfix = ".replaced-"

    package static let allowancesName = "allowances.json"
    package static let timelinesName = "timelines.json"

    package init(
        directory: URL, name: String, key: String, defaults: UserDefaults, protected: ProtectedData,
        device: Guarded.Device = .this, otherIsNone: Bool = false
    ) {
        self.otherIsNone = otherIsNone
        url = directory.appendingPathComponent(name)
        self.key = key
        self.defaults = defaults
        self.protected = protected
        self.device = device
    }

    /// What is kept, moved from its key where it is still there.
    public func read() -> Read {
        do {
            return try held().map(Read.data) ?? .none
        } catch is NotKnown {
            return .notKnown
        } catch {
            return .unread
        }
    }

    /// Writes the list down, and says whether it was. **Not over what cannot be read**, and
    /// not as a first file where what the key holds is not known (`ListFile`).
    @discardableResult
    public func write(_ data: Data) -> Bool {
        do {
            _ = try Data(contentsOf: url)
        } catch where Self.isAbsent(error) {
            // A key that is there is known; one that is not, only between two canary reads.
            guard defaults.object(forKey: key) != nil || keyIsAbsent() else { return false }
        } catch {
            return false
        }
        guard (try? lay(data)) != nil else {
            NetLog.protection.error("One of the person's own lists could not be written beside the index")
            return false
        }
        return true
    }

    /// What is kept, or nil where nothing is; throws where it cannot be said.
    package func held() throws -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch where Self.isAbsent(error) {
            return try fromKey()
        }
        // The file is the list. A key still there is a move cut short before its last step,
        // or an earlier build's since: removed, and never moved over the file.
        if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        return data
    }

    /// The list made `data`, or none: the file written and read back — or removed — and the
    /// key gone. For a read back and its undo, which have read what was there first.
    package func lay(_ data: Data?) throws {
        guard let data else {
            // The key first: cut short, what is left is the list as it was, not a key that a
            // launch would move back in.
            defaults.removeObject(forKey: key)
            do { try FileManager.default.removeItem(at: url) } catch where Self.isAbsent(error) {}
            return
        }
        try Guarded.write(data, to: url, atomic: true, on: device)
        // Read back before the key goes: the key is the only other copy there is.
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteUnknown) }
        defaults.removeObject(forKey: key)
    }

    // MARK: - While a read back replaces it

    /// Moves the file aside under a name of its own, and answers where — nil where there is
    /// no file. **A rename, so that putting it back is one too**: a device that locks midway
    /// refuses a new file, and does not refuse a rename (seen on a Mac; on a phone not yet,
    /// which is why an undo that is refused all the same stays owed).
    package func putAside() throws -> URL? {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + Self.asideInfix + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch where Self.isAbsent(error) {
            return nil
        }
        return aside
    }

    /// The list as it was before a read back: the file moved aside put back in place of
    /// whatever is there — or, where none was moved aside, `held` laid down again. Done
    /// twice it is done once: an aside already put back is not looked for again.
    package func putBack(_ aside: URL?, held: Data?) throws {
        guard let aside else { return try lay(held) }
        guard FileManager.default.fileExists(atPath: aside.path) else { return }
        defaults.removeObject(forKey: key)
        do { try FileManager.default.removeItem(at: url) } catch where Self.isAbsent(error) {}
        try FileManager.default.moveItem(at: aside, to: url)
    }

    /// **What a read back that never finished left aside**, asked at launch where the canary
    /// reads (`StorePackager.sweepLeftovers`): each list moved aside and neither put back nor
    /// let go. Where its list has no file, it is the person's own and is put back; where the
    /// package's landed, it goes — **unless that read back is known to have failed**
    /// (`failed`: its undo of the settings was owed and never done), and then it is the
    /// person's own list and the only copy, and is put back over what landed.
    package static func settleAsides(in directory: URL, failed: Bool) {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        for name in [allowancesName, timelinesName] {
            for stray in names where stray.hasPrefix(name + asideInfix) {
                let aside = directory.appendingPathComponent(stray)
                let list = directory.appendingPathComponent(name)
                if failed { try? manager.removeItem(at: list) }
                if manager.fileExists(atPath: list.path) {
                    try? manager.removeItem(at: aside)
                } else {
                    try? manager.moveItem(at: aside, to: list)
                }
            }
        }
    }

    private func fromKey() throws -> Data? {
        let before = protected.canary() == .reads
        let value = defaults.object(forKey: key)
        let between = before && protected.canary() == .reads
        guard let value else {
            // Empty preferences are "no key" only on a device known to be unlocked.
            guard between else { throw NotKnown() }
            return nil
        }
        // Something of another type under the key is nothing this can move or speak for —
        // or, where its owner always read such a thing as nothing kept, nothing: the key
        // stands, and the first write replaces it.
        guard let data = value as? Data else {
            guard otherIsNone, between else { throw CocoaError(.fileReadCorruptFile) }
            return nil
        }
        // The move, once. Refused, the key stands and the next launch tries again.
        if between { try? lay(data) }
        return data
    }

    private func keyIsAbsent() -> Bool {
        guard protected.canary() == .reads, defaults.object(forKey: key) == nil else { return false }
        return protected.canary() == .reads
    }

    private static func isAbsent(_ error: any Error) -> Bool {
        let said = error as NSError
        if said.domain == NSCocoaErrorDomain {
            return [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(said.code)
        }
        return said.domain == NSPOSIXErrorDomain && said.code == Int(ENOENT)
    }
}

/// The person's own lists beside one store (#344).
public struct ListFiles: Sendable {
    /// What may be reached beyond a source (#226).
    public let allowances: ListFile
    /// The timelines the person wrote (#27).
    public let timelines: ListFile

    public init(directory: URL, defaults: UserDefaults, protected: ProtectedData) {
        self.init(directory: directory, defaults: defaults, protected: protected, device: .this)
    }

    package init(directory: URL, defaults: UserDefaults, protected: ProtectedData, device: Guarded.Device) {
        allowances = ListFile(
            directory: directory, name: ListFile.allowancesName, key: "fediqo.allowances",
            defaults: defaults, protected: protected, device: device, otherIsNone: true
        )
        timelines = ListFile(
            directory: directory, name: ListFile.timelinesName, key: "fediqo.timelines",
            defaults: defaults, protected: protected, device: device
        )
    }

    package var all: [ListFile] { [allowances, timelines] }
}
