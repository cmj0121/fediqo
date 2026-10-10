import FediqoCore
import Foundation
import os

/// What a launch does so that everything on this device is at the class (#344), beyond what
/// each write does for itself (`Guarded`): the folders the system writes into for the app are
/// made and classed before it writes there, and what an earlier build or an earlier run left
/// is brought to the class.
///
/// **Every launch, and no mark that it was done.** Bringing changes nothing where everything
/// is at the class already, and a mark could be lost, or kept while a file came from elsewhere.
public enum ProtectedFolders {
    /// Where this app's files are.
    public struct Places: Sendable {
        /// The store's folder: the index, what lies beside it, the canary.
        var store: URL
        /// The app's own folder under Caches: the picture copies.
        var caches: URL
        var temporary: URL
        var library: URL
        var bundleID: String
        /// Whether the temporary directory is this app's alone. Outside a sandbox it is every
        /// program's the person runs, and nothing in it but what this app named is touched.
        var sandboxed: Bool
        /// The iPhone build on a phone: there the system keeps the app's preferences, its
        /// cookies and its caches inside the app's own container, and is asked to close them
        /// (the entitlement). A Mac build asks nothing of the kind — **and neither does the
        /// iPhone build run on a Mac**: a Mac goes on running behind a locked screen, and
        /// its preferences are written by another process that opens the file afresh, which
        /// a file brought to the class would refuse.
        var phoneBuild = false

        /// This app's own, in its container.
        public static var container: Places {
            let manager = FileManager.default
            return Places(
                store: StoreFile.applicationSupportDirectory,
                caches: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Fediqo", isDirectory: true),
                temporary: manager.temporaryDirectory,
                library: manager.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                bundleID: ForumWebsiteData.bundleID, sandboxed: ForumWebsiteData.isSandboxed,
                phoneBuild: isPhoneBuild
            )
        }

        private static var isPhoneBuild: Bool {
            #if os(macOS)
            false
            #else
            !ProcessInfo.processInfo.isiOSAppOnMac
            #endif
        }

        /// What the film player keeps of a film while it plays, which nothing else removes.
        var playerCache: URL { temporary.appendingPathComponent("MediaCache", isDirectory: true) }

        /// The system's cache and its network storage for this app, by the app's own name.
        var perApp: [URL] {
            ["Caches", "HTTPStorages"].map {
                library.appendingPathComponent($0, isDirectory: true).appendingPathComponent(bundleID, isDirectory: true)
            }
        }

        /// The folders the system writes into for the app, each made and classed before it
        /// does: what is written into a folder takes the folder's class.
        var systemWritten: [URL] {
            guard sandboxed else { return perApp }
            return [temporary, playerCache]
                + ["WebKit", "TemporaryItems"].map { temporary.appendingPathComponent($0, isDirectory: true) }
                + perApp
        }

        /// What the system keeps of the app's windows: the picture in the app switcher, a
        /// Mac's saved state. The system's to make and never made here — brought where found.
        /// Outside a sandbox the Library is the person's own, shared with every program they
        /// run, and only what carries this app's name in it is this app's.
        var systemKept: [URL] {
            let named = ["Saved Application State/\(bundleID).savedState"]
            return ((sandboxed ? ["SplashBoard", "Caches/Snapshots"] : []) + named).map {
                library.appendingPathComponent($0, isDirectory: true)
            }
        }

        /// Folders of the system's own that were there before this build asked for anything:
        /// the preferences, the cookies, and the top of Caches. **What the entitlement asks
        /// reaches what is made from then on**, and may not reach a folder an earlier install
        /// already had, or the file in it the system writes again and again — so each is
        /// brought, itself and what it holds directly, and **nothing below that**: under them
        /// are the system's trees, which are not this app's to walk. Only for the iPhone build
        /// on a phone, in its sandbox; anywhere else the Library is not this app's alone.
        var systemOwned: [URL] {
            guard sandboxed, phoneBuild else { return [] }
            return ["Preferences", "Cookies", "Caches"].map { library.appendingPathComponent($0, isDirectory: true) }
        }
    }

    /// What `first` found, each read off the disk and none taken from nothing having thrown.
    public struct Found: Sendable, Equatable {
        /// How many things in the store's folder would not take the class.
        public var refused = 0
        /// Whether the canary is there, at the class.
        public var canary = false
        /// The store's folder, the index or its journal is not at the class, where the canary is.
        public var indexNotAtClass = false
        /// Whether SQLite's temporary files are made in the store's folder, at the class.
        public var temporaries = false
    }

    /// Before the index is opened, and before anything else of the app's runs: the store's
    /// folder and the canary made, the folder SQLite's temporary copies go in made and named
    /// to it, the index and what lies beside it brought to the class, what the film player
    /// left let go, and the folders the system writes into made and classed.
    ///
    /// **Only what an open can reach is walked here**, on the main actor: the store's folder
    /// and what it holds directly — the index, its journal, the marks — and each folder a
    /// read back put a store aside in, which a sweep may move back into place before the open.
    /// A rename keeps a file's class, so those are brought before anything is moved. What
    /// else lies under the folder — a staging of pictures, which the sweep removes — is left
    /// to `rest`. Nothing here opens a connection, and all of it is done before one is.
    @discardableResult
    public static func first(_ places: Places = .container) -> Found {
        first(places, on: .this)
    }

    package static func first(_ places: Places, on device: Guarded.Device) -> Found {
        var found = Found()
        do {
            try Guarded.makeFolder(places.store, excludedFromBackup: true, on: device)
            try Guarded.makeCanary(in: places.store, on: device)
        } catch {
            NetLog.protection.error("The canary could not be made at the protection class: \(String(describing: type(of: error)), privacy: .public)")
        }
        found.canary = Guarded.canaryTook(in: places.store, on: device)
        // Before any connection is opened, the probes a sweep makes included: where SQLite
        // makes a rebuild's copy of the index. Emptied first — SQLite unlinks each file as it
        // opens it, so only a run killed between the two could have left one.
        let manager = FileManager.default
        let temporaries = places.store.appendingPathComponent(StoreFile.temporariesName, isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: temporaries.path)) ?? [] {
            try? manager.removeItem(at: temporaries.appendingPathComponent(name))
        }
        try? Guarded.makeFolder(temporaries, excludedFromBackup: false, on: device)
        found.temporaries = manager.fileExists(atPath: temporaries.path) && at(device, temporaries)
        if found.temporaries {
            StoreFile.keepTemporaries(in: temporaries)
        } else {
            NetLog.protection.error("No folder at the protection class for the index's temporary copies; they are made in the temporary directory")
        }
        found.refused = Guarded.bring(places.store, below: false, on: device)
        for name in (try? manager.contentsOfDirectory(atPath: places.store.path)) ?? []
        where name.hasPrefix(StoreFile.readBackAsidePrefix) {
            found.refused += Guarded.bring(places.store.appendingPathComponent(name, isDirectory: true), on: device)
        }
        // Its own line, and not only a number among the others: the index is what the class
        // is for. Said wherever the canary took the class — a phone or a Mac — since there a
        // file that did not is a file that should have.
        if found.canary {
            let index = places.store.appendingPathComponent(StoreFile.indexName)
            found.indexNotAtClass = [places.store, index, URL(fileURLWithPath: index.path + "-journal")].contains { file in
                manager.fileExists(atPath: file.path) && !at(device, file)
            }
        }
        if found.indexNotAtClass { NetLog.protection.fault("the index is not at the class") }
        if found.refused > 0 {
            NetLog.protection.error("\(found.refused, privacy: .public) of what the store's folder holds would not take the protection class")
        }
        // Swept and not only classed: nothing else ever removes what a film left here.
        if places.sandboxed { try? manager.removeItem(at: places.playerCache) }
        for folder in places.systemWritten {
            try? Guarded.makeFolder(folder, excludedFromBackup: false, on: device)
        }
        return found
    }

    /// Whether `url` is at the class `device` asks for; yes where it asks for none.
    private static func at(_ device: Guarded.Device, _ url: URL) -> Bool {
        device.asks.map { device.heldNow(url) == $0 } ?? true
    }

    /// The rest, which may be a good deal and is nothing a first frame waits for: everything
    /// under the store's folder that `first` did not walk, the picture copies, the temporary
    /// directory, what the system keeps for the app, and — for the iPhone build — the tops of
    /// the folders the system had made before this build asked for the class (`systemOwned`). **Off the main actor** — it is a walk
    /// of every file. Returns how many would not take the class.
    @discardableResult
    public static func rest(_ places: Places = .container) -> Int {
        rest(places, on: .this)
    }

    package static func rest(_ places: Places, on device: Guarded.Device) -> Int {
        // The temporary directory whole where it is this app's alone; where it is not, the one
        // folder in it that outlives a run (`PageRules`).
        let scratch = places.sandboxed
            ? places.temporary : places.temporary.appendingPathComponent("FediqoPageRules", isDirectory: true)
        let roots = [places.store, places.caches, scratch] + places.perApp + places.systemKept
        let refused = roots.reduce(0) { $0 + Guarded.bring($1, on: device) }
            + places.systemOwned.reduce(0) { $0 + Guarded.bring($1, below: false, on: device) }
        let counted = Guarded.refused
        if refused > 0 || counted > 0 {
            NetLog.protection.error("\(refused, privacy: .public) file(s) already here would not take the protection class; \(counted, privacy: .public) made since launch did not")
        }
        return refused
    }
}
