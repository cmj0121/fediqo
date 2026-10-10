import Foundation
import os

/// The one place a folder or a file of this app's is made (#344): each is made **with** the
/// platform's protection class (`platformClass`), so that what the app keeps cannot be read
/// while the device is locked.
///
/// **Made with the class, never made and then classed.** The class rides in the attributes a
/// folder is created with and in the options of a write, so no moment exists in which the file
/// is there at the system's default. What a folder is made with, everything later written into
/// it inherits: the index and the journal SQLite makes beside it, an atomic write's temporary
/// file, what WebKit keeps in a folder handed to it.
///
/// **In FediqoCore because all three targets write.** A raw `createDirectory`, `write(to:)`,
/// `createFile` or `FileHandle(forWritingTo:)` anywhere else fails a test that reads the source.
///
/// **A class that was not taken** — the file is there and does not read back as the platform's:
///
/// - **Where the volume takes the class**, which the canary having taken it says, it is a
///   failure of the write and throws (`Refused`), on a phone and a Mac alike — and what the
///   call made is removed, so nothing is left at a lesser class. Making the canary itself
///   throws whatever else is true.
/// - **Where no canary has taken it** — a volume that takes no class at all, or a launch that
///   could make none — and **in the simulator**, it is counted (`refused`) and the write
///   stands: a volume that does not take the class must not become a run with no store.
public enum Guarded {
    /// The class everything here is made at and brought to, and what "taken" is read against.
    ///
    /// - **A phone: complete.** Nothing of the app's can be read from shortly after the device
    ///   locks, by the app either; the app is suspended behind a locked screen anyway.
    /// - **A Mac: complete unless open.** A Mac closes protected files at the lock of its
    ///   screen too — seen, not read in a document — and the app goes on running behind it.
    ///   At this class a file that is open stays usable and a new one can be made, so a save
    ///   on the connection the app holds still lands; nothing that was closed can be opened
    ///   again until the screen is unlocked. At complete every save would be refused for as
    ///   long as the screen stayed locked.
    ///
    /// The iPhone build run on a Mac is on a Mac, and goes by the Mac's.
    public static let platformClass: FileProtectionType = {
        #if os(macOS)
        return .completeUnlessOpen
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac ? .completeUnlessOpen : .complete
        #endif
    }()

    /// A file or a folder was made and is not at the class.
    public struct Refused: LocalizedError, Equatable {
        public let name: String

        /// Said as the system says a file it would not let be written: where this reaches a
        /// person it is one more failure of the disk, in their language, and not a type's name.
        public var errorDescription: String? { CocoaError(.fileWriteNoPermission).localizedDescription }
    }

    // MARK: - Making

    /// Makes `url`, parents and all, at the class. One that was already there is brought to it.
    /// `excludedFromBackup` marks it as this device's alone.
    public static func makeFolder(_ url: URL, excludedFromBackup: Bool = false) throws {
        try makeFolder(url, excludedFromBackup: excludedFromBackup, on: .this)
    }

    /// Writes `data` at `url` at the class, in place of whatever was there.
    public static func write(_ data: Data, to url: URL, atomic: Bool = true) throws {
        try write(data, to: url, atomic: atomic, on: .this)
    }

    /// Makes an empty file at `url` at the class, in place of whatever was there, and opens it
    /// for writing.
    public static func makeFile(at url: URL) throws -> FileHandle {
        try makeFile(at: url, on: .this)
    }

    /// Opens for writing a file `makeFile` made, as it is: what it holds is kept.
    public static func reopen(_ url: URL) throws -> FileHandle {
        try reopen(url, on: .this)
    }

    package static func makeFolder(_ url: URL, excludedFromBackup: Bool, on device: Device) throws {
        // The folders this call is about to make, the one asked for first and its missing
        // parents after it: what goes on a refusal, each only if it is then empty.
        var mine: [URL] = []
        var above = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: above.path), above.path != "/" {
            mine.append(above)
            above = above.deletingLastPathComponent()
        }
        try made(on: device) { asked in
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: asked.map { [.protectionKey: $0] }
            )
        }
        try settle(url, mine.isEmpty ? .wasThere : .folders(mine), on: device)
        if excludedFromBackup {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var marked = url
            try marked.setResourceValues(excluded)
        }
    }

    package static func write(_ data: Data, to url: URL, atomic: Bool, on device: Device) throws {
        let was = FileManager.default.fileExists(atPath: url.path)
        // In the options and not left to the folder: an atomic write is a temporary file and a
        // rename, and the class must be the temporary file's from its first byte.
        let plain: Data.WritingOptions = atomic ? .atomic : []
        try made(on: device) { asked in
            try data.write(to: url, options: asked.map { plain.union(option(for: $0)) } ?? plain)
        }
        try settle(url, was ? .written : .file, on: device)
    }

    package static func makeFile(at url: URL, on device: Device) throws -> FileHandle {
        let was = FileManager.default.fileExists(atPath: url.path)
        // An empty write, and not `createFile(attributes:)`: that makes the file first and
        // classes it afterwards, and where the class is refused — seen on a locked Mac — it
        // answers true over a file left at the system's default.
        try made(on: device) { asked in
            try Data().write(to: url, options: asked.map(option(for:)) ?? [])
        }
        try settle(url, was ? .written : .file, on: device)
        return try FileHandle(forWritingTo: url)
    }

    package static func reopen(_ url: URL, on device: Device) throws -> FileHandle {
        let handle = try FileHandle(forWritingTo: url)
        try settle(url, .wasThere, on: device)
        return handle
    }

    // MARK: - Handing out

    /// **The one thing made here that is let out of the class**: a take-away package, sealed
    /// and finished, on its way to wherever the person puts it. What it holds is locked by its
    /// own password; the copy in their documents or a folder that syncs has to be readable by
    /// a backup and by the sync behind a locked screen, which a protected file is not. Until
    /// this is asked the package is at the class like everything else, in its staging folder.
    ///
    /// Set to `handedOutClass`, asked for by name — never left to whatever a file gets when
    /// nothing is asked, which is not this once the app asks the system for protection by
    /// default.
    public static func handOut(_ url: URL) throws {
        try handOut(url, on: .this)
    }

    package static func handOut(_ url: URL, on device: Device) throws {
        // Where the class cannot be read there is none to let it out of.
        guard device.asks != nil, let held = device.heldNow(url), held != handedOutClass else { return }
        let manager = FileManager.default
        if (try? manager.setAttributes([.protectionKey: handedOutClass], ofItemAtPath: url.path)) != nil,
           device.heldNow(url) == handedOutClass { return }
        // The system will not always change the class of a file that has one — it answers
        // that the file is busy — so what cannot be changed is written again beside itself at
        // the class it is to have, a piece at a time, and takes the first one's place.
        let copy = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).out")
        do {
            try Data().write(to: copy, options: option(for: handedOutClass))
            let from = try FileHandle(forReadingFrom: url), to = try FileHandle(forWritingTo: copy)
            defer {
                try? from.close()
                try? to.close()
            }
            while let piece = try from.read(upToCount: 1 << 20), !piece.isEmpty { try to.write(contentsOf: piece) }
            try to.synchronize()
            // Two steps and not a replacing: that keeps the first one's attributes, the class among them.
            try manager.removeItem(at: url)
            try manager.moveItem(at: copy, to: url)
        } catch {
            try? manager.removeItem(at: copy)
            throw error
        }
    }

    /// The class asked for a file handed out: readable from the first unlock after a restart,
    /// which is what a backup and a sync need of it.
    package static let handedOutClass = FileProtectionType.completeUntilFirstUserAuthentication

    // MARK: - What is already there

    /// Brings `root` and everything under it to the class: what an earlier build wrote at the
    /// system's default or at another class, and what the system wrote for the app into a
    /// folder that was not yet classed. Asked at every launch — it changes nothing where
    /// everything is at the class already, so there is no mark of having been done to lose. A
    /// link is not followed. `below` false stops at what `root` itself holds: its files and
    /// its folders, and nothing inside those. Returns how many would not take the class;
    /// nothing where `root` is not there.
    @discardableResult
    public static func bring(_ root: URL, below: Bool = true) -> Int {
        bring(root, below: below, on: .this)
    }

    package static func bring(_ root: URL, below: Bool = true, on device: Device) -> Int {
        let manager = FileManager.default
        guard device.asks != nil, manager.fileExists(atPath: root.path) else { return 0 }
        var refused = bringOne(root, on: device) ? 0 : 1
        // The class asked for with the listing, so that the walk reads each file's once and
        // from what the listing already fetched; only one at another class is touched.
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileProtectionKey]
        guard let walk = manager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: below ? [] : [.skipsSubdirectoryDescendants]
        ) else { return refused }
        for case let url as URL in walk {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if !bringOne(url, listed: true, on: device) { refused += 1 }
        }
        return refused
    }

    /// Whether `url` is at the class once asked to be; yes where no class is asked for.
    /// `listed` is a URL a listing just handed over with its class fetched: the first look is
    /// at that. Every other look is at the disk — a URL goes on answering what it once read.
    private static func bringOne(_ url: URL, listed: Bool = false, on device: Device) -> Bool {
        guard let asks = device.asks else { return true }
        if (listed ? device.held(url) : device.heldNow(url)) == asks { return true }
        try? FileManager.default.setAttributes([.protectionKey: asks], ofItemAtPath: url.path)
        return device.heldNow(url) == asks
    }

    // MARK: - The canary

    /// What the canary is called, in the store's folder.
    public static let canaryName = ".unlocked"

    /// Makes the canary in `folder` where there is none at the class: one small file of the
    /// platform's class beside the index, which a fresh open reads exactly when one of the
    /// index does. One found at any other class would read while the index is closed, so it is
    /// written anew, whole.
    ///
    /// **Throws on a class not taken, whatever else is true, and leaves no file**: a canary at
    /// a lesser class is worse than none, on a Mac as on a phone — it would say the store can
    /// be read when it cannot. Only the simulator, where nothing is ever closed, lets one stand.
    ///
    /// **And it is what says the volume takes the class**: once it is there at the class, a
    /// class not taken by anything else is a failure and no longer a count (`Device.canaryTook`).
    public static func makeCanary(in folder: URL) throws {
        try makeCanary(in: folder, on: .this)
    }

    package static func makeCanary(in folder: URL, anew: Bool = false, on device: Device) throws {
        let url = folder.appendingPathComponent(canaryName)
        // Only the process's own: a device a test made by hand says where its canary is itself.
        defer { if device.isProcess { state.withLock { $0.canary = url } } }
        // Where no class is asked for, none is read either, and one that is there stands. So
        // does one that reads back as no class at all: see below.
        if !anew, FileManager.default.fileExists(atPath: url.path) {
            guard let asks = device.asks else { return }
            let held = device.heldNow(url)
            if held == asks || held == nil { return }
        }
        // Made as the simulator makes anything: written, and what class came of it looked at
        // here rather than thrown for — there are three answers, and only one is a refusal.
        var alone = device
        alone.simulated = true
        alone.count = {}
        // A file of its own beside it, then one rename over it: whole or not at all, with no
        // moment in which there is no canary — and nothing of the old one kept, its mode
        // among what a write in place would carry over.
        let fresh = folder.appendingPathComponent(canaryName + "-new")
        do {
            try write(Data([1]), to: fresh, atomic: false, on: alone)
            // Its owner's to read, whatever this process's mask would have made it: a canary
            // the process cannot read back is, to the probe, a lock that never ends.
            chmod(fresh.path, 0o600)
            if let asks = device.asks, !device.simulated {
                switch device.heldNow(fresh) {
                case asks:
                    break
                case nil:
                    // **Written, and it reads back as no class at all**: a volume that keeps
                    // none. Nothing on it is ever closed by a lock, so its canary stands as
                    // the simulator's does, and is counted. Not what a locked device gives:
                    // there the class still reads back — seen on a locked Mac, of files at
                    // either class — and it is the write or the read that is refused.
                    device.count()
                default:
                    // Another, real class: it would read while the index is closed.
                    throw Refused(name: canaryName)
                }
            } else if device.asks != nil, device.heldNow(fresh) != device.asks {
                device.count()
            }
            guard rename(fresh.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Held to the class under its own name too: it is the canary that must be at it.
            if !device.simulated, let asks = device.asks, let held = device.heldNow(url), held != asks {
                throw Refused(name: canaryName)
            }
        } catch {
            try? FileManager.default.removeItem(at: fresh)
            // A canary left at a lesser class, whether or not this put it there, is worse
            // than none.
            if error is Refused, let asks = device.asks, let held = device.heldNow(url), held != asks {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Whether the canary in `folder` is there and at the class `device` asks for — read off
    /// the disk, not taken from nothing having been thrown.
    package static func canaryTook(in folder: URL, on device: Device) -> Bool {
        let url = folder.appendingPathComponent(canaryName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return device.asks.map { device.heldNow(url) == $0 } ?? true
    }

    // MARK: - The probe

    /// What a fresh look at the canary in `folder` finds (`ProtectedData.Canary`).
    ///
    /// **The read is the probe.** The canary is a closed file opened afresh, and a closed file
    /// cannot be opened under lock at either class. Where the class is complete — a phone —
    /// a scratch file is also made and unlinked beside it, and either refusal is a refusal: at
    /// complete nothing new can be made under lock either. At unless-open a new file is made
    /// while locked and says nothing, so a Mac is not asked that.
    ///
    /// **Made where there is none, and written anew where it is at another class** — whole, as
    /// a file of its own renamed over what was there, never removed first: a writer that looked between
    /// the two would find no canary and take the volume for one that keeps no class. `anew`
    /// writes it again whatever is there: what is tried once where it will not read on a
    /// device known to be unlocked.
    public static func probeCanary(in folder: URL, anew: Bool = false) -> ProtectedData.Canary {
        probeCanary(in: folder, anew: anew, on: .this)
    }

    package static func probeCanary(
        in folder: URL, anew: Bool = false, on device: Device,
        reading: (URL) throws -> Void = { _ = try Data(contentsOf: $0, options: [.uncached]) }
    ) -> ProtectedData.Canary {
        let url = folder.appendingPathComponent(canaryName)
        var written = false
        do {
            // Its folder with it, where this is the first launch there has been: "no folder"
            // is then one that could not be made, and not one nobody had made yet.
            try makeFolder(folder, excludedFromBackup: false, on: device)
            try makeCanary(in: folder, anew: anew, on: device)
            written = anew
            // A fresh URL and a fresh descriptor: nothing a run has open is asked.
            try reading(URL(fileURLWithPath: url.path))
            if device.phone, let asks = device.asks {
                let scratch = folder.appendingPathComponent(canaryName + "-probe")
                defer { try? FileManager.default.removeItem(at: scratch) }
                try Data([1]).write(to: scratch, options: option(for: asks))
            }
            return .reads
        } catch {
            // **Written anew a moment ago, and now not to be read**: no fault of a volume or
            // of a permission lets a write through and then refuses the read of what was
            // written. It is a locked screen at a class that takes new files — a Mac's.
            if written, isRefusal(error) { return .closed }
            return isNothingToWaitFor(error) ? .none : .refused
        }
    }

    /// Whether `error` is the system saying no — to a class, or to a file it will not open or
    /// make.
    package static func isRefusal(_ error: any Error) -> Bool {
        if error is Refused { return true }
        let said = error as NSError
        return posix(said).map { [EPERM, EACCES].contains($0) }
            ?? (said.domain == NSCocoaErrorDomain
                && [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(said.code))
    }

    /// Whether `error` is one of the few things that are plainly not a lock and that no unlock
    /// will change: no room, no folder to be had, a volume that takes no writes, a quota.
    /// **A named list, and everything off it is taken for a refusal** — an error nobody here
    /// knows is waited on, never opened past: with a person in front of an unlocked device a
    /// refusal reaches the same road anyway, so nothing is stranded by erring this way.
    package static func isNothingToWaitFor(_ error: any Error) -> Bool {
        let said = error as NSError
        if let code = posix(said) { return [ENOSPC, EDQUOT, EROFS, ENOENT, ENOTDIR, EEXIST].contains(code) }
        let named: [CocoaError.Code] = [
            .fileWriteOutOfSpace, .fileWriteVolumeReadOnly, .fileNoSuchFile, .fileReadNoSuchFile, .fileWriteFileExists,
        ]
        return said.domain == NSCocoaErrorDomain && named.map(\.rawValue).contains(said.code)
    }

    /// The system's own number for `error`, where it or what lies under it carries one.
    private static func posix(_ said: NSError) -> Int32? {
        if said.domain == NSPOSIXErrorDomain { return Int32(said.code) }
        if let under = said.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            return Int32(under.code)
        }
        return nil
    }

    // MARK: - A class not taken

    /// How many files and folders were made, since launch, that did not take the class.
    public static var refused: Int { state.withLock { $0.refused } }

    /// What a write is asked for so that the file is at `protection` from its first byte.
    private static func option(for protection: FileProtectionType) -> Data.WritingOptions {
        switch protection {
        case .completeUnlessOpen: .completeFileProtectionUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeFileProtectionUntilFirstUserAuthentication
        case FileProtectionType.none: .noFileProtection
        default: .completeFileProtection
        }
    }

    private struct State {
        var refused = 0
        var canary: URL?
        var noClass = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Makes through `make`, handed the class to ask for. **Where the volume is not known to
    /// take the class** — a Mac no canary has taken it on, or the simulator — and that throws,
    /// it is made again asking for none: whether it threw at the class or at something else,
    /// the second try says, and `settle` counts what came out. Where the canary took the class
    /// there is no second try, and on a phone there never is: its volume takes the class, and
    /// what throws there is the write's own failure.
    private static func made(on device: Device, _ make: (_ asked: FileProtectionType?) throws -> Void) throws {
        guard let asks = device.asks else { return try make(nil) }
        do {
            try device.asking()
            try make(asks)
        } catch {
            guard device.simulated || (!device.phone && !device.canaryTook()) else { throw error }
            try make(nil)
        }
    }

    /// What a call did to bring `url` into being, which is what a refusal may undo.
    private enum Made {
        /// It was there before the call, which wrote nothing into it: a folder asked for
        /// again, a file opened again.
        case wasThere
        /// It was there, and the call has just written what it holds.
        case written
        /// The call made the file.
        case file
        /// The call made these folders, the one asked for first and its parents after it.
        case folders([URL])
    }

    /// `url` was just made: at the class, or — where it was there before — brought to it; and
    /// what is done where it is at neither.
    ///
    /// **A failure only for what the call itself made or wrote.** A folder or a file that was
    /// there already and will not be brought is counted, as `bring` counts one: an install
    /// whose store folder will not change class must still open its store, and that folder not
    /// being at the class is said by the launch on a line of its own.
    ///
    /// **What the call made is removed, and nothing else**: the file; or the folders, the one
    /// asked for and then each parent it made, each only while empty and stopping at the
    /// first that is not — another writer may have made use of a parent meanwhile, and what
    /// it wrote there is not this call's to take.
    private static func settle(_ url: URL, _ made: Made, on device: Device) throws {
        guard !bringOne(url, on: device) else { return }
        if case .wasThere = made { return device.count() }
        guard device.throwsOnRefusal else { return device.count() }
        switch made {
        case .file:
            try? FileManager.default.removeItem(at: url)
        case .folders(let mine):
            for folder in mine where rmdir(folder.path) != 0 { break }
        case .wasThere, .written:
            break
        }
        throw Refused(name: url.lastPathComponent)
    }

    #if DEBUG
    /// **For the tests alone, and not in a release build at all**: from here on this process
    /// asks for no class — every folder and file is made as the system makes one, and nothing
    /// is brought or read back. Once, and never undone.
    ///
    /// A Mac refuses to open a protected file again while its screen is locked, so tests that
    /// made their scratch folders at the class passed or failed by whether somebody was at the
    /// machine. Whether the class is really asked for and really taken is held by the few
    /// tests that hand in `Device.real` and run only where the platform's class can be had.
    /// Nothing in `Sources/` or `Apps/` calls this; a test that reads the source says so.
    package static func askForNoClass() {
        state.withLock { $0.noClass = true }
    }
    #endif

    private static var asksForNoClass: Bool {
        #if DEBUG
        state.withLock { $0.noClass }
        #else
        false
        #endif
    }

    /// What decides a refusal, and what a test turns by hand.
    package struct Device: Sendable {
        /// The class asked for and read back against; nil asks for none and checks nothing.
        package var asks: FileProtectionType?
        /// The simulator: files are the Mac's underneath and nothing is ever closed, so a
        /// class not taken is only ever counted there.
        package var simulated: Bool
        /// A phone itself — not the simulator, and not its build run on a Mac. Its volume
        /// takes the class, so nothing is ever made there with none asked.
        package var phone: Bool
        /// This is the process's own device and not one a test made by hand: its canary is
        /// the one `makeCanary` last made, kept process-wide.
        var isProcess = false
        /// The class `url` is at, or nil where it cannot be asked — **as that URL knows it**:
        /// one a listing fetched the class for answers from what was fetched, and goes on
        /// answering the same after the file has changed. `heldNow` asks the disk.
        package var held: @Sendable (URL) -> FileProtectionType?
        /// Whether the canary is there at the class — which is what says this volume takes
        /// the class at all. Read off its attributes, so a locked screen, under which nothing
        /// of the canary's can be opened, does not look like a volume that takes none.
        package var canaryTook: @Sendable () -> Bool
        /// A class was not taken and the write stands.
        package var count: @Sendable () -> Void
        /// Asked just before anything is made at the class; a test throws here for a volume
        /// that refuses the asking itself.
        package var asking: @Sendable () throws -> Void

        /// The class `url` is at on the disk now, whatever that URL read before.
        package func heldNow(_ url: URL) -> FileProtectionType? { held(URL(fileURLWithPath: url.path)) }

        /// A class not taken is the write's failure: the volume takes the class, and this is
        /// not the simulator.
        package var throwsOnRefusal: Bool { !simulated && canaryTook() }

        package init(
            asks: FileProtectionType? = Guarded.platformClass, simulated: Bool = false, phone: Bool = false,
            held: @escaping @Sendable (URL) -> FileProtectionType?,
            canaryTook: @escaping @Sendable () -> Bool, count: @escaping @Sendable () -> Void,
            asking: @escaping @Sendable () throws -> Void = {}
        ) {
            self.asks = asks
            self.simulated = simulated
            self.phone = phone
            self.held = held
            self.canaryTook = canaryTook
            self.count = count
            self.asking = asking
        }

        /// What every call that names no device goes by: `real`, unless a test process said to
        /// ask for no class.
        package static var this: Device {
            var device = real
            if asksForNoClass { device.asks = nil }
            return device
        }

        /// This process on the platform it runs on, asking for the platform's class.
        package static let real: Device = {
            var device = Device(
                simulated: isSimulator, phone: isPhone,
                held: onDisk,
                canaryTook: {
                    guard let canary = state.withLock({ $0.canary }) else { return false }
                    return onDisk(URL(fileURLWithPath: canary.path)) == Guarded.platformClass
                },
                count: {
                    let total = state.withLock { state in
                        state.refused += 1
                        return state.refused
                    }
                    // Once, and as a count: which file it was is nobody's to read in a log.
                    if total == 1 { NetLog.protection.notice("A file was made that did not take the protection class; counted from here on") }
                }
            )
            device.isProcess = true
            return device
        }()

        /// The class `url` is at on the disk; from what a listing fetched with it, where it did.
        private static func onDisk(_ url: URL) -> FileProtectionType? {
            guard let held = try? url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection else { return nil }
            return classes[held]
        }

        /// The class as a listing names it, and as the rest of this file does.
        private static let classes: [URLFileProtection: FileProtectionType] = [
            .complete: .complete, .completeUnlessOpen: .completeUnlessOpen,
            .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication,
            URLFileProtection.none: FileProtectionType.none,
        ]

        private static var isPhone: Bool {
            #if os(iOS) && !targetEnvironment(simulator)
            !ProcessInfo.processInfo.isiOSAppOnMac
            #else
            false
            #endif
        }

        private static var isSimulator: Bool {
            #if targetEnvironment(simulator)
            true
            #else
            false
            #endif
        }
    }
}
