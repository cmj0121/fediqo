import FediqoCore
import Foundation
import GRDB
import os
import SQLite3
import Testing
@testable import FediqoPersistence

/// The platform's class, tried for real.
enum RealClass {
    /// Whether the platform's class can be had right now, by doing it: a folder made at it, a
    /// file written in it, closed, opened again and read.
    static let works: Bool = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("probe")
        do {
            try Guarded.makeFolder(folder, excludedFromBackup: false, on: .real)
            try Guarded.write(Data("probe".utf8), to: file, atomic: false, on: .real)
            return try Data(contentsOf: file) == Data("probe".utf8) && Guarded.Device.real.heldNow(file) == Guarded.platformClass
        } catch {
            return false
        }
    }()
}

/// #344: what a launch does so that everything on the device is at the class — the store's
/// folder and what SQLite makes in it, the folders the system writes into, and what an earlier
/// build left — and that SQLite's own temporary copies are made in the store's folder.
///
/// **One at a time**: where SQLite makes its temporary files is one variable for the whole
/// process, and each launch made here names its own folder to it.
///
/// **Held to the disk, with the tests' switch off** (`Guarded.Device.real`), and so run only
/// where the platform's class can be had (`works`): on a Mac whose screen is locked they are
/// skipped, and said to be.
@Suite(
    "Everything the app keeps is at the class", .serialized,
    .enabled(if: RealClass.works, "the platform's class cannot be had here now: a locked screen")
)
struct ProtectedFoldersTests {
    private static let lesser = FileProtectionType.completeUntilFirstUserAuthentication
    private static var lesserMade: [FileAttributeKey: Any] { [.protectionKey: lesser] }

    private static func held(_ url: URL) -> FileProtectionType? { Guarded.Device.real.heldNow(url) }

    /// A container of its own, **not** at the class, as a build before this one left it.
    private struct Container {
        let root: URL
        let places: ProtectedFolders.Places

        init(sandboxed: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            places = ProtectedFolders.Places(
                store: root.appendingPathComponent("Library/Application Support/Fediqo", isDirectory: true),
                caches: root.appendingPathComponent("Library/Caches/Fediqo", isDirectory: true),
                temporary: root.appendingPathComponent("tmp", isDirectory: true),
                library: root.appendingPathComponent("Library", isDirectory: true),
                bundleID: "b.id", sandboxed: sandboxed
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: lesserMade)
            try #require(held(root) == lesser)
        }

        /// SQLite is told to forget this container's folder before the folder goes: other
        /// suites' connections are open in this process, and none is to be left making its
        /// temporary files by a name that is no longer there.
        func remove() {
            StoreFile.keepTemporaries(in: nil)
            try? FileManager.default.removeItem(at: root)
        }

        /// A file an earlier build or the system left, at the lesser class, parents and all.
        @discardableResult
        func left(_ path: String, under base: URL) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: lesserMade
            )
            try #require(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8), attributes: lesserMade))
            try #require(held(url) == lesser)
            return url
        }
    }

    /// A device that reads the disk truly but for the files `refusing` names, and whose canary
    /// is `container`'s own: taken where it is there at the class and not among those named.
    private static func device(
        _ container: Container, simulated: Bool = false, refusing: @escaping @Sendable (String) -> Bool
    ) -> Guarded.Device {
        let canary = container.places.store.appendingPathComponent(Guarded.canaryName)
        return Guarded.Device(
            asks: Guarded.platformClass, simulated: simulated,
            held: { refusing($0.lastPathComponent) ? lesser : held($0) },
            canaryTook: { !refusing(Guarded.canaryName) && held(canary) == Guarded.platformClass }, count: {}
        )
    }

    // MARK: - The store's folder

    @Test("The index SQLite makes, and the folder it is in, are at the class")
    func theIndex() async throws {
        let container = try Container()
        defer { container.remove() }
        // The folder as the launch makes it; the store itself is opened as every test opens one.
        try makeExcludedFromBackup(container.places.store, on: .real)
        let file = try StoreFile(at: container.places.store)
        try await file.save(sources: [Source(host: "alpha.test", kind: .mastodon)], notes: [])
        let index = container.places.store.appendingPathComponent(StoreFile.indexName)
        #expect(Self.held(container.places.store) == Guarded.platformClass)
        #expect(Self.held(index) == Guarded.platformClass, "made by SQLite, in a folder that hands the class down")
    }

    /// The files this process holds open under one folder, asked from inside SQLite as it works.
    private final class OpenFiles: Sendable {
        struct File: Hashable { let folder: String, links: Int, protection: Int32 }
        let under: String
        private let found = OSAllocatedUnfairLock(initialState: Set<File>())
        init(under root: URL) { under = "/\(root.lastPathComponent)/" }
        var seen: Set<File> { found.withLock { $0 } }

        /// `F_GETPROTECTIONCLASS`, which the headers keep from Swift, and what it answers for
        /// the platform's class: 1 is complete, 2 complete unless open.
        static let protectionClass: Int32 = 63
        static let asked: Int32 = Guarded.platformClass == .complete ? 1 : 2

        func look() {
            for descriptor in Int32(3)..<getdtablesize() {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                var status = stat()
                guard fcntl(descriptor, F_GETPATH, &path) == 0, fstat(descriptor, &status) == 0 else { continue }
                let url = URL(fileURLWithPath: String(cString: path))
                guard url.path.contains(under), url.lastPathComponent.hasPrefix("etilqs_") else { continue }
                let file = File(
                    folder: url.deletingLastPathComponent().lastPathComponent, links: Int(status.st_nlink),
                    protection: fcntl(descriptor, Self.protectionClass)
                )
                found.withLock { _ = $0.insert(file) }
            }
        }
    }

    @Test("A rebuild's copy of the index is made in the store's own folder, at the class, with no name left to it")
    func aRebuildsCopy() async throws {
        let container = try Container()
        defer { container.remove() }
        #expect(ProtectedFolders.first(container.places, on: .real).temporaries)
        let temporaries = container.places.store.appendingPathComponent(StoreFile.temporariesName, isDirectory: true)
        #expect(Self.held(temporaries) == Guarded.platformClass)
        #expect(StoreFile.temporaries == temporaries.path)
        let file = try StoreFile(at: container.places.store)
        // A few megabytes, and a connection told to keep next to none of them in its cache:
        // left to itself SQLite holds a copy this small in memory and makes no file at all.
        try await file.db.write { db in
            try db.execute(sql: "CREATE TABLE pad(x BLOB)")
            for _ in 0..<40 { try db.execute(sql: "INSERT INTO pad VALUES (zeroblob(100000))") }
        }
        try await file.db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA cache_size = 10")
            try db.execute(sql: "PRAGMA cache_spill = 10")
        }
        let watch = OpenFiles(under: container.root)
        try await file.db.writeWithoutTransaction { db in
            sqlite3_progress_handler(db.sqliteConnection, 100, { context in
                Unmanaged<OpenFiles>.fromOpaque(context!).takeUnretainedValue().look()
                return 0
            }, Unmanaged.passUnretained(watch).toOpaque())
        }
        try await file.compact()
        try await file.db.writeWithoutTransaction { db in sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }
        #expect(
            watch.seen == [OpenFiles.File(folder: StoreFile.temporariesName, links: 0, protection: OpenFiles.asked)],
            "seen open while the rebuild ran: \(watch.seen)"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaries.path).isEmpty)
    }

    @Test("What a run killed mid-rebuild left in that folder is gone at the next launch, and the folder is brought")
    func staleTemporaries() throws {
        let container = try Container()
        defer { container.remove() }
        let stale = try container.left("\(StoreFile.temporariesName)/etilqs_1b6b07c507150a52", under: container.places.store)
        #expect(ProtectedFolders.first(container.places, on: .real).temporaries)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(Self.held(stale.deletingLastPathComponent()) == Guarded.platformClass)
        #expect(StoreFile.temporaries == stale.deletingLastPathComponent().path)
        // And the name is taken back before the folder goes, so no other suite's connection
        // is left making its temporary files by a name that is not there.
        container.remove()
        #expect(StoreFile.temporaries == nil)
    }

    @Test("A folder that will not take the class is not named to SQLite")
    func temporariesRefused() throws {
        let container = try Container()
        defer { container.remove() }
        let refusing = Self.device(container) { $0 == StoreFile.temporariesName }
        let found = ProtectedFolders.first(container.places, on: refusing)
        #expect(found == ProtectedFolders.Found(refused: 0, canary: true, indexNotAtClass: false, temporaries: false))
        #expect(!FileManager.default.fileExists(atPath: container.places.store.appendingPathComponent(StoreFile.temporariesName).path), "not left at a lesser class either")
        #expect(StoreFile.temporaries != container.places.store.appendingPathComponent(StoreFile.temporariesName).path)
    }

    @Test("A launch makes the folder and the canary, and brings what an open can reach: the index, what lies beside it, a store put aside")
    func first() throws {
        let container = try Container()
        defer { container.remove() }
        let reached = try ["index.sqlite", "index.sqlite-journal", "limits.json", "store.sqlite", "incoming-aside-1/index.sqlite"].map {
            try container.left($0, under: container.places.store)
        }
        // A staging of pictures, which the sweep removes: not walked before the first frame.
        let staged = try container.left("incoming-1/media/a/b", under: container.places.store)
        let found = ProtectedFolders.first(container.places, on: .real)
        #expect(found == ProtectedFolders.Found(refused: 0, canary: true, indexNotAtClass: false, temporaries: true))
        let canary = container.places.store.appendingPathComponent(Guarded.canaryName)
        #expect(Self.held(canary) == Guarded.platformClass)
        #expect(try !Data(contentsOf: canary).isEmpty)
        #expect(reached.allSatisfy { Self.held($0) == Guarded.platformClass })
        #expect(Self.held(container.places.store.appendingPathComponent("incoming-1")) == Guarded.platformClass, "the folder itself, at the top")
        #expect(Self.held(staged) == Self.lesser)
        #expect(try container.places.store.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(ProtectedFolders.rest(container.places, on: .real) == 0)
        #expect(Self.held(staged) == Guarded.platformClass, "and the rest of the folder by the walk that follows")
    }

    @Test("The store's folder, the index or its journal not taking the class is said on its own, wherever the canary took it",
          arguments: ["Fediqo", "index.sqlite", "index.sqlite-journal"])
    func theIndexRefused(name: String) throws {
        let container = try Container()
        defer { container.remove() }
        for file in ["index.sqlite", "index.sqlite-journal", "limits.json"] { try container.left(file, under: container.places.store) }
        let found = ProtectedFolders.first(container.places, on: Self.device(container) { $0 == name })
        #expect(found == ProtectedFolders.Found(refused: 1, canary: true, indexNotAtClass: true, temporaries: true))
        // Something else in the folder is a number, not that line.
        let other = ProtectedFolders.first(container.places, on: Self.device(container) { $0 == "limits.json" })
        #expect(other == ProtectedFolders.Found(refused: 1, canary: true, indexNotAtClass: false, temporaries: true))
    }

    @Test("An install whose store folder will not come to the class still opens its store")
    func theFolderWillNotChange() async throws {
        let container = try Container()
        defer { container.remove() }
        try container.left("limits.json", under: container.places.store)
        let device = Self.device(container) { $0 == "Fediqo" }
        // The launch: the folder counted (no canary yet), the canary made, and it takes the class.
        let found = ProtectedFolders.first(container.places, on: device)
        #expect(found == ProtectedFolders.Found(refused: 1, canary: true, indexNotAtClass: true, temporaries: true))
        #expect(device.throwsOnRefusal)
        // Then what opening the store asks first, of the same folder: counted again, not thrown.
        try makeExcludedFromBackup(container.places.store, on: device)
        let file = try StoreFile(at: container.places.store)
        try await file.save(sources: [Source(host: "alpha.test", kind: .mastodon)], notes: [])
        #expect(try file.load().sources.map(\.host) == ["alpha.test"])
    }

    @Test("With no canary there is nothing to say the class can be had, and the index is only counted")
    func noCanary() throws {
        let container = try Container()
        defer { container.remove() }
        try container.left("index.sqlite", under: container.places.store)
        let refusing = Self.device(container) { $0 == "index.sqlite" || $0 == Guarded.canaryName }
        let found = ProtectedFolders.first(container.places, on: refusing)
        #expect(found == ProtectedFolders.Found(refused: 1, canary: false, indexNotAtClass: false, temporaries: true))
        #expect(!FileManager.default.fileExists(atPath: container.places.store.appendingPathComponent(Guarded.canaryName).path))
    }

    @Test("A canary left at a lesser class — the simulator lets one stand — is not said to be there")
    func aLesserCanary() throws {
        let container = try Container()
        defer { container.remove() }
        let simulator = Self.device(container, simulated: true) { $0 == Guarded.canaryName }
        let found = ProtectedFolders.first(container.places, on: simulator)
        #expect(FileManager.default.fileExists(atPath: container.places.store.appendingPathComponent(Guarded.canaryName).path))
        #expect(found == ProtectedFolders.Found(refused: 1, canary: false, indexNotAtClass: false, temporaries: true))
    }

    // MARK: - What the system writes

    @Test("The folders the system writes into are made at the class, and what the film player left is gone")
    func systemWritten() throws {
        let container = try Container()
        defer { container.remove() }
        let film = try container.left("MediaCache/CachedMedia-1", under: container.places.temporary)
        ProtectedFolders.first(container.places, on: .real)
        #expect(!FileManager.default.fileExists(atPath: film.path))
        let made = ["tmp", "tmp/MediaCache", "tmp/WebKit", "tmp/TemporaryItems", "Library/Caches/b.id", "Library/HTTPStorages/b.id"]
        for path in made {
            #expect(Self.held(container.root.appendingPathComponent(path)) == Guarded.platformClass, "\(path)")
        }
        // What is written there afterwards, by whoever writes it, takes the folder's class.
        let later = container.places.temporary.appendingPathComponent("MediaCache/CachedMedia-2")
        try #require(FileManager.default.createFile(atPath: later.path, contents: Data("x".utf8)))
        #expect(Self.held(later) == Guarded.platformClass)
    }

    @Test("Outside a sandbox the temporary directory is every program's, and nothing in it is touched")
    func outsideASandbox() throws {
        let container = try Container(sandboxed: false)
        defer { container.remove() }
        let film = try container.left("MediaCache/CachedMedia-1", under: container.places.temporary)
        let stranger = try container.left("another-program/file", under: container.places.temporary)
        // The person's own Library: the system's pictures of every program's windows are not this app's.
        let pictures = try [
            container.left("SplashBoard/Snapshots/another", under: container.places.library),
            container.left("Caches/Snapshots/another/picture", under: container.places.library),
        ]
        let state = try container.left("Saved Application State/b.id.savedState/windows.plist", under: container.places.library)
        let rules = try container.left("FediqoPageRules/list", under: container.places.temporary)
        ProtectedFolders.first(container.places, on: .real)
        #expect(ProtectedFolders.rest(container.places, on: .real) == 0)
        #expect(FileManager.default.fileExists(atPath: film.path))
        #expect(Self.held(film) == Self.lesser)
        #expect(Self.held(stranger) == Self.lesser)
        #expect(pictures.allSatisfy { Self.held($0) == Self.lesser })
        #expect(Self.held(state) == Guarded.platformClass, "what carries this app's name is this app's")
        #expect(Self.held(container.places.temporary) == Self.lesser)
        #expect(Self.held(rules) == Guarded.platformClass, "the one folder there that is this app's and outlives a run")
        #expect(Self.held(container.root.appendingPathComponent("Library/Caches/b.id")) == Guarded.platformClass)
    }

    @Test("The rest is brought: the picture copies, the temporary directory, and what the system keeps for the app")
    func rest() throws {
        let container = try Container()
        defer { container.remove() }
        let old = try [
            container.left("media/host/copy", under: container.places.caches),
            container.left("incoming-1/media/a/b", under: container.places.store),
            container.left("SplashBoard/Snapshots/sceneID/picture.ktx", under: container.places.library),
            container.left("CFNetworkDownload_1.tmp", under: container.places.temporary),
            container.left("WebKit/x/y", under: container.places.temporary),
            container.left("Caches/b.id/Cache.db", under: container.places.library),
            container.left("HTTPStorages/b.id/httpstorages.sqlite", under: container.places.library),
            container.left("Saved Application State/b.id.savedState/windows.plist", under: container.places.library),
        ]
        let another = try container.left("Caches/another.id/Cache.db", under: container.places.library)
        #expect(ProtectedFolders.rest(container.places, on: .real) == 0)
        #expect(old.allSatisfy { Self.held($0) == Guarded.platformClass })
        #expect(Self.held(another) == Self.lesser, "only what is this app's")
        // The system's to make: one that is not there is not made.
        #expect(!FileManager.default.fileExists(atPath: container.places.library.appendingPathComponent("Caches/Snapshots").path))
        let refusing = Self.device(container) { $0 == "copy" || $0 == "Cache.db" }
        #expect(ProtectedFolders.rest(container.places, on: refusing) == 2)
    }

    // MARK: - Each of the app's own, where it is made

    @Test("The forum store's folders are at the class, and what WebKit left in them is brought before it opens them")
    func theForumStore() throws {
        let container = try Container()
        defer { container.remove() }
        let found = ForumWebsiteData.directories(library: container.places.library, sandboxed: true, bundleID: "b.id")
        let cookies = try container.left("Cookies/Cookies.binarycookies", under: found.store)
        try ForumWebsiteData.markOutOfBackups(library: container.places.library, sandboxed: true, bundleID: "b.id", on: .real)
        #expect([found.root, found.store, cookies].allSatisfy { Self.held($0) == Guarded.platformClass })
    }
}

/// #344: how a connection to the index is made, whatever class its folder is at.
@Suite("Every connection to the index is made one way")
struct StoreConnectionTests {
    @Test("Every connection is made one way, and none is told to keep a rebuild's copy in memory")
    func connections() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try StoreFile(at: folder)
        let path = folder.appendingPathComponent(StoreFile.indexName).path
        let probe = try DatabaseQueue(path: path, configuration: StoreFile.configuration(readOnly: true))
        for db in [file.db, probe] {
            // Not 2, which is memory: a copy of the whole index is more than a phone gives an app.
            #expect(try db.read { try Int.fetchOne($0, sql: "PRAGMA temp_store") } != 2)
            let built = try db.read { try String.fetchAll($0, sql: "PRAGMA compile_options") }
            #expect(!built.isEmpty)
            #expect(!built.contains("TEMP_STORE=2") && !built.contains("TEMP_STORE=3"), "built to keep them in memory")
        }
        #expect(try probe.read { sqlite3_db_readonly($0.sqliteConnection, "main") } == 1)
        #expect(try file.db.read { sqlite3_db_readonly($0.sqliteConnection, "main") } == 0)
        #expect(StoreFile.configuration(busyWait: 3).busyMode.isTimeout(3))
    }
}

private extension Database.BusyMode {
    func isTimeout(_ seconds: TimeInterval) -> Bool {
        if case .timeout(let wait) = self { return wait == seconds }
        return false
    }
}
