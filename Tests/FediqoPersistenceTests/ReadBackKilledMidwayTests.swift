import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A read back killed midway leaves the store as it was, or as the package says — never empty,
/// and never with the store this device held deleted behind it (#247, #292).
///
/// **The commit is the real one, stopped where a kill would stop it.** A process cannot be
/// killed inside a test, so the packager tells a witness as it passes each point a kill can
/// leave on disk, and the witness copies the device's folder as it stands there. A launch is
/// then run on the copy: the sweep, the open, and a save.
///
/// The device here is one whose run has no open file of its own — the only kind whose read back
/// moves an index into place rather than saving through the one it holds.
@Suite("A read back killed midway")
struct ReadBackKilledMidwayTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    private static func post(_ id: Int, _ phrase: String) -> Note {
        Note(
            id: "https://\(mastodon.host)/users/ada/statuses/\(id)", source: mastodon, author: "Ada", handle: "@ada",
            body: phrase, postedAt: PackagerFixture.origin.addingTimeInterval(Double(id) * 60),
            categories: [.public], spoiler: "", statusID: "\(id)"
        )
    }

    private static let old = Array(repeating: "old-store-phrase", count: 5)
    private static let new = Array(repeating: "new-store-phrase", count: 3)

    /// The folders a witness copied, by the point the commit had reached.
    private final class Copies: @unchecked Sendable {
        private let lock = NSLock()
        private var taken: [StorePackager.CommitPoint: URL] = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-killed-\(UUID().uuidString)")

        func take(_ point: StorePackager.CommitPoint, of directory: URL) {
            let copy = root.appendingPathComponent("\(point)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: directory, to: copy)
            lock.withLock { taken[point] = copy }
        }

        subscript(point: StorePackager.CommitPoint) -> URL? { lock.withLock { taken[point] } }
    }

    /// A device holding `old-store-phrase` on disk with no file open on it, read back onto from
    /// a package holding `new-store-phrase`; the folder as it stood at each point of the commit.
    ///
    /// Where `refusing`, the commit's last step — the limits' account — cannot be written, so
    /// every step before it is undone, the index among them, and the read back throws.
    private func killed(refusing: Bool = false) async throws -> (Copies, cleanup: () -> Void) {
        let from = try await Device(sources: [Self.mastodon], notes: (1...3).map { Self.post($0, "new-store-phrase") })
        let onto = try await Device(noFile: true)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        try await from.packager().takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        do {
            let held = try StoreFile(at: onto.directory)
            try await held.save(sources: [Self.mastodon], notes: (1...5).map { Self.post($0, "old-store-phrase") })
            try held.db.close()
        }
        let copies = Copies()
        var packager = onto.packager()
        let folder = onto.directory
        packager.witness = { point in copies.take(point, of: folder) }
        if refusing {
            // Something the limits' account cannot be written over: a folder of its name, not empty.
            let blocking = folder.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
            try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
            try Data().write(to: blocking.appendingPathComponent("in the way"))
            await #expect(throws: (any Error).self) {
                try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
            }
            #expect(try StoreFile(at: folder).load().notes.map(\.body) == Self.old, "the premise: undone, the store is as it was")
            #expect(try names(in: folder) == ["index.sqlite", LimitAccountFile.name], "and nothing is left aside")
        } else {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
            #expect(try StoreFile(at: folder).load().notes.map(\.body) == Self.new, "the premise: unkilled, it lands")
        }
        return (copies, {
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: copies.root)
        })
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// What a launch does before anything else, and then what it opens.
    private func launch(in dir: URL) -> StoreFile.Opened {
        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: dir.appendingPathComponent("no-such-tmp"))
        return StoreFile.open(at: dir)
    }

    private func bodies(_ opened: StoreFile.Opened) -> [String] { opened.notes.map(\.body) }

    @Test("Killed with the package staged and nothing moved: the store is as it was, and the staging is gone")
    func killedStaged() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.staged])
        #expect(try names(in: dir).contains { $0.hasPrefix("incoming-") && !$0.hasPrefix("incoming-aside-") }, "the premise: a staging")
        #expect(try !names(in: dir).contains { $0.hasPrefix("incoming-aside-") }, "the premise: nothing aside")

        let opened = launch(in: dir)
        #expect(bodies(opened) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite"])
    }

    @Test("Killed with the old index aside and the new one not in place: the old index is the index again, the read back did not happen, and a save loses nothing")
    func killedAside() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        let before = try names(in: dir)
        #expect(!before.contains("index.sqlite"), "the premise: no index where the old one was")
        let aside = try #require(before.first { $0.hasPrefix("incoming-aside-") })
        #expect(!StorePackager.wasReplaced(dir.appendingPathComponent(aside), in: dir), "the premise: the marker does not say replaced")

        let opened = launch(in: dir)
        let file = try #require(opened.file)
        #expect(bodies(opened) == Self.old, "the store this device held is not what launch opened")
        #expect(opened.setAside == nil)
        #expect(try names(in: dir) == ["index.sqlite"], "the aside, its marker and the staging are settled")

        try await file.save(sources: opened.sources, notes: opened.notes, said: opened.said)
        #expect(bodies(StoreFile.open(at: dir)) == Self.old)
    }

    @Test("Killed with the new index in place: the package's store is the store, and the old one, replaced, is dropped")
    func killedReplaced() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.replaced])
        let aside = try #require(try names(in: dir).first { $0.hasPrefix("incoming-aside-") })
        #expect(StorePackager.wasReplaced(dir.appendingPathComponent(aside), in: dir), "the premise: the marker says replaced")

        let opened = launch(in: dir)
        #expect(bodies(opened) == Self.new)
        #expect(try names(in: dir) == ["index.sqlite"], "a replaced store outlived what replaced it")
        let old = Data("old-store-phrase".utf8)
        #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite")).range(of: old) == nil)
    }

    @Test("Killed with the new index in place and the marker not yet saying replaced: the marker says whose that index is, it goes, the old store opens, and nothing is left unsettled")
    func killedMovedIn() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedIn])
        let aside = dir.appendingPathComponent(try #require(try names(in: dir).first { $0.hasPrefix("incoming-aside-") }))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.replacingMark, "the premise")
        #expect(StoreFile.holdsNothing(indexAt: dir.appendingPathComponent("index.sqlite").path) == false, "the premise: the package's index, rows and all")
        #expect(!StorePackager.wasReplaced(aside, in: dir))

        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 1, unsettled: 0))
        let opened = launch(in: dir)
        #expect(opened.file != nil && bodies(opened) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite"])
    }

    @Test("The marker says the new index is on its way in before it is moved: killed there with nothing in place, the old index is put back")
    func killedBeforeTheMoveIn() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.replacing])
        let aside = dir.appendingPathComponent(try #require(try names(in: dir).first { $0.hasPrefix("incoming-aside-") }))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.replacingMark, "the word was not there before the move")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path), "the premise: nothing in place yet")
        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 1, unsettled: 0))
        #expect(bodies(StoreFile.open(at: dir)) == Self.old)
    }

    // MARK: - Nothing deletes an old index that was not replaced

    private func asideName(in dir: URL) throws -> String {
        try #require(try names(in: dir).first { $0.hasPrefix("incoming-aside-") })
    }

    private func sweep(_ dir: URL) {
        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: dir.appendingPathComponent("no-such-tmp"))
    }

    @Test("While the old index is aside and unsettled, opening makes no index and gives no file: nothing is read, nothing can be saved, and the folder is as it was")
    func unsettledOpensNothing() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        let before = try names(in: dir)
        #expect(StorePackager.hasUnsettledReadBack(in: dir))

        // No sweep first: what any path that opened without settling would meet.
        let opened = StoreFile.open(at: dir)
        #expect(opened.file == nil && opened.notes.isEmpty && opened.setAside == nil && !opened.storeIsNewer)
        #expect(try names(in: dir) == before, "an index was made in the gap")

        #expect(bodies(launch(in: dir)) == Self.old)
        #expect(!StorePackager.hasUnsettledReadBack(in: dir))
    }

    @Test("An old index that cannot be moved back stays aside with its marker, the run has no index at all, and a launch that can move it finishes")
    func whatCannotBePutBackIsKept() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        let name = try asideName(in: dir)
        let kept = dir.appendingPathComponent(name).appendingPathComponent("index.sqlite")
        // Something the old index's journal cannot be moved onto: a folder of that name, not empty.
        try Data("the old index's journal".utf8).write(to: dir.appendingPathComponent(name).appendingPathComponent("index.sqlite-journal"))
        let blocking = dir.appendingPathComponent("index.sqlite-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))

        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 0, unsettled: 1), "counted as what it is")
        let opened = launch(in: dir)
        #expect(FileManager.default.fileExists(atPath: kept.path), "an old index that could not be put back was let go")
        #expect(opened.file == nil && opened.notes.isEmpty, "the run was given an index of its own beside it")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path))

        try FileManager.default.removeItem(at: blocking)
        #expect(bodies(launch(in: dir)) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite"])
    }

    @Test("An index standing in the old one's place that holds anything is not deleted for it: both are kept, nothing changes, and the run has no index")
    func aStandingIndexWithRows() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        do {
            let standing = try StoreFile(at: dir)
            try await standing.save(sources: [Self.mastodon], notes: [Self.post(9, "somebodys-reading")])
            try standing.db.close()
        }
        // The staging beside them is the package's copy and nobody's store: the sweep takes it.
        let before = try names(in: dir).filter { !$0.hasPrefix("incoming-") || $0.hasPrefix("incoming-aside-") }
        let index = try Data(contentsOf: dir.appendingPathComponent("index.sqlite"))

        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 0, unsettled: 1))
        let opened = launch(in: dir)
        #expect(opened.file == nil && opened.notes.isEmpty)
        #expect(try names(in: dir) == before)
        #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite")) == index, "the standing index was touched")
        let aside = dir.appendingPathComponent(try asideName(in: dir))
        #expect(try Data(contentsOf: aside.appendingPathComponent("index.sqlite")).range(of: Data("old-store-phrase".utf8)) != nil)
    }

    @Test("An index standing in the old one's place that cannot be asked what it holds is not taken for empty: both are kept")
    func aStandingIndexThatCannotBeRead() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        let garbage = Data("not an index at all, however long it is".utf8)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))

        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 0, unsettled: 1))
        #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite")) == garbage)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(try asideName(in: dir)).appendingPathComponent("index.sqlite").path))
        #expect(StoreFile.open(at: dir).file == nil)
    }

    @Test("An index standing in the old one's place that holds nothing gives way: the old index is put back", arguments: [false, true])
    func aStandingIndexWithNothing(noTables: Bool) async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        if noTables {
            try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).close()
        } else {
            try StoreFile(at: dir).db.close()
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path), "the premise")
        #expect(StoreFile.holdsNothing(indexAt: dir.appendingPathComponent("index.sqlite").path) == true)

        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 1, unsettled: 0))
        #expect(bodies(StoreFile.open(at: dir)) == Self.old)
    }

    @Test("Whether an index holds nothing is asked without guessing: one with a source or a post holds something, and one that cannot be read is not known to hold nothing")
    func holdsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite").path
        let file = try StoreFile(at: dir)
        #expect(StoreFile.holdsNothing(indexAt: index) == true)
        try await file.save(sources: [Self.mastodon], notes: [])
        #expect(StoreFile.holdsNothing(indexAt: index) == false, "a source alone is something")
        try file.db.close()
        try Data("not an index at all, however long it is".utf8).write(to: URL(fileURLWithPath: index))
        #expect(StoreFile.holdsNothing(indexAt: index) != true)
    }

    // MARK: - A commit being undone

    @Test("Killed as the undo begins — the marker says so, the package's index still in place: that index goes and the old one is the store")
    func killedUndoing() async throws {
        let (copies, cleanup) = try await killed(refusing: true)
        defer { cleanup() }
        let dir = try #require(copies[.undoing])
        let aside = dir.appendingPathComponent(try asideName(in: dir))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.undoingMark, "the premise")
        #expect(StoreFile.holdsNothing(indexAt: dir.appendingPathComponent("index.sqlite").path) == false, "the premise: the package's index, rows and all")
        #expect(!StorePackager.wasReplaced(aside, in: dir))

        #expect(bodies(launch(in: dir)) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite", LimitAccountFile.name])
    }

    @Test("Killed mid-undo — the package's index taken out, the old one not yet back: the old one is put back, and nothing has deleted it")
    func killedInTheUndosGap() async throws {
        let (copies, cleanup) = try await killed(refusing: true)
        defer { cleanup() }
        let dir = try #require(copies[.undoneGap])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path), "the premise: no index in place")
        let aside = dir.appendingPathComponent(try asideName(in: dir))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) != StorePackager.replacedMark, "the marker still says replaced, with the new index gone")

        #expect(bodies(launch(in: dir)) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite", LimitAccountFile.name])
    }

    @Test("An undo that cannot take the package's index out moves nothing back: the old index and what SQLite kept beside it stay aside, and the next launch settles it")
    func anUndoThatCannotRemoveTheNewIndex() async throws {
        let from = try await Device(sources: [Self.mastodon], notes: (1...3).map { Self.post($0, "new-store-phrase") })
        let onto = try await Device(noFile: true)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        let folder = onto.directory
        let manager = FileManager.default
        let inPlace = folder.appendingPathComponent("index.sqlite").path
        defer {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: inPlace)
            from.remove(); onto.remove(); try? manager.removeItem(at: package)
        }
        try await from.packager().takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        do {
            let held = try StoreFile(at: folder)
            try await held.save(sources: [Self.mastodon], notes: (1...5).map { Self.post($0, "old-store-phrase") })
            try held.db.close()
        }
        // Something SQLite kept beside the old index, and the step after the index refusing.
        try Data("beside the old index".utf8).write(to: folder.appendingPathComponent("index.sqlite-shm"))
        let blocking = folder.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
        try manager.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))
        var packager = onto.packager()
        // As the undo reaches the package's index, that one file can no longer be taken out —
        // and nothing else in the folder is any harder to move than it was.
        packager.witness = { point in
            if point == .undoing { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: inPlace) }
        }
        await #expect(throws: PackageFault.self) {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try manager.attributesOfItem(atPath: inPlace)[.immutable] as? Bool == true, "the premise: it could not be removed")
        try manager.setAttributes([.immutable: false], ofItemAtPath: inPlace)

        let aside = folder.appendingPathComponent(try asideName(in: folder))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.undoingMark)
        #expect(manager.fileExists(atPath: aside.appendingPathComponent("index.sqlite").path), "the old index left the aside")
        #expect(manager.fileExists(atPath: aside.appendingPathComponent("index.sqlite-shm").path), "what was beside the old index was moved back beside the package's")
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("index.sqlite-shm").path))
        #expect(StoreFile.holdsNothing(indexAt: folder.appendingPathComponent("index.sqlite").path) == false, "the package's index is still in place")

        #expect(StorePackager.settleHalfCommits(in: folder) == (putBack: 1, unsettled: 0))
        #expect(try Data(contentsOf: folder.appendingPathComponent("index.sqlite-shm")) == Data("beside the old index".utf8))
        try manager.removeItem(at: folder.appendingPathComponent("index.sqlite-shm"))
        #expect(bodies(StoreFile.open(at: folder)) == Self.old)
    }

    @Test("A marker saying replaced beside no index is not a replaced store: the aside is put back, by the sweep and whatever a save does")
    func replacedWithNoIndexInPlace() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.replaced])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.sqlite"))
        let aside = dir.appendingPathComponent(try asideName(in: dir))
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.replacedMark, "the premise")
        #expect(!StorePackager.wasReplaced(aside, in: dir))
        #expect(StorePackager.hasUnsettledReadBack(in: dir))
        #expect(StoreFile.open(at: dir).file == nil, "an index was made beside the only store there is")

        #expect(bodies(launch(in: dir)) == Self.old)
        #expect(try names(in: dir) == ["index.sqlite"])
    }

    @Test("Killed while being put back — what SQLite kept beside the old index is back, the index is not — the next launch finishes, and what is already back is left")
    func killedWhilePuttingBack() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let dir = try #require(copies[.movedAside])
        // As a first launch left it: no index in place, the old journal already moved back.
        try Data("the old index's journal".utf8).write(to: dir.appendingPathComponent("index.sqlite-wal"))

        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: dir.appendingPathComponent("no-such-tmp"))
        #expect(try names(in: dir) == ["index.sqlite", "index.sqlite-wal"], "what was already back beside the gap was taken for the new index's")
        #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite-wal")) == Data("the old index's journal".utf8))
    }

    // MARK: - The staged index is scrubbed

    @Test("An index a read back moves into place has been rebuilt by this build first: it is marked, and has no page free")
    func theStagedIndexIsScrubbed() async throws {
        let (copies, cleanup) = try await killed()
        defer { cleanup() }
        let staged = try #require(copies[.staged])
        let incoming = staged.appendingPathComponent(try #require(try names(in: staged).first { $0.hasPrefix("incoming-") && !$0.hasPrefix("incoming-aside-") }))
        func header(_ index: URL) async throws -> (version: Int?, free: Int?) {
            var readOnly = Configuration()
            readOnly.readonly = true
            let raw = try DatabaseQueue(path: index.path, configuration: readOnly)
            return try await raw.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA user_version"), try Int.fetchOne(db, sql: "PRAGMA freelist_count"))
            }
        }
        let before = try await header(incoming.appendingPathComponent("index.sqlite"))
        #expect(before.version == StoreFile.scrubbed && before.free == 0, "staged and read, and not rebuilt before it could be moved in")
        let moved = try await header(try #require(copies[.replaced]).appendingPathComponent("index.sqlite"))
        #expect(moved.version == StoreFile.scrubbed && moved.free == 0)
    }
}
