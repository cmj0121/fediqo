import FediqoCore
import Foundation
import GRDB
import SQLite3
import Testing
@testable import FediqoPersistence

/// A store that could not be opened is handled for what it is, and is not kept forever (#295).
///
/// **Real failures where a file can be made to give them**: another connection holding the
/// index for a store in use, a file of anything for one that is not a database, pages written
/// over for one that is corrupt, a folder that takes no writes for one out of reach. A disk with
/// no room is the one a test cannot make, and is handed in where the index is opened.
///
/// Each test is a launch, or several: what `open` gives, what is on disk afterwards, what a save
/// may delete, and what the next launch finds.
@Suite("A store that did not open")
struct StoreTroubleTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func posts(_ count: Int, _ words: String = "held") -> [Note] {
        (1...count).map { id in
            Note(
                id: "https://\(mastodon.host)/\(id)", source: mastodon, author: "Ada", handle: "@ada",
                body: "\(words) \(id) " + String(repeating: "and some more words. ", count: 20),
                postedAt: PackagerFixture.origin.addingTimeInterval(Double(id)), categories: [.public], statusID: "\(id)"
            )
        }
    }

    /// A store of `count` posts saved and closed in `dir`.
    private func store(_ count: Int, _ words: String = "held", in dir: URL) async throws {
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.posts(count, words))
        try file.db.close()
    }

    private var index: String { "index.sqlite" }

    /// Every file under `dir`, by name, with its bytes: what "nothing on disk changed" means.
    private func disk(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            out[name] = isFolder.boolValue ? Data() : try Data(contentsOf: url)
        }
        return out
    }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func asides(_ dir: URL) throws -> [String] {
        try names(dir).filter { $0.hasPrefix("index-unreadable-") }
    }

    private func bodies(_ opened: StoreFile.Opened) -> [String] {
        opened.notes.map { String($0.body.prefix(4)) }
    }

    /// A launch: a short wait on another connection, so a test of one in use does not sit out
    /// the three seconds a real launch gives it.
    private func launch(_ dir: URL) -> StoreFile.Opened {
        StoreFile.open(at: dir, busyWait: 0.05)
    }

    // MARK: - Why it would not open

    @Test("What a failure says about the store is read off what was reported: five of SQLite's codes and a row that will not decode are damage, and everything else is the moment")
    func theCauses() {
        func code(_ code: ResultCode) -> StoreFile.Cause { StoreFile.cause(of: DatabaseError(resultCode: code)) }
        for damage in [ResultCode.SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_ERROR, .SQLITE_CONSTRAINT, .SQLITE_MISMATCH] {
            #expect(code(damage) == .damaged, "\(damage)")
        }
        #expect(code(ResultCode(rawValue: 11 | (1 << 8))) == .damaged, "an extended code is read by its primary one")
        #expect(code(.SQLITE_BUSY) == .unreachable(.inUse) && code(.SQLITE_LOCKED) == .unreachable(.inUse))
        #expect(code(ResultCode(rawValue: 5 | (2 << 8))) == .unreachable(.inUse), "BUSY_SNAPSHOT is busy")
        #expect(code(.SQLITE_FULL) == .unreachable(.noRoom))
        for moment in [
            ResultCode.SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_NOMEM, .SQLITE_AUTH,
            .SQLITE_PROTOCOL, .SQLITE_INTERRUPT, .SQLITE_INTERNAL, .SQLITE_NOLFS, .SQLITE_TOOBIG, ResultCode(rawValue: 250),
        ] {
            #expect(code(moment) == .unreachable(.outOfReach), "\(moment)")
        }
        let undecodable = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(StoreFile.cause(of: undecodable) == .damaged)
        #expect(StoreFile.cause(of: CocoaError(.fileWriteNoPermission)) == .unreachable(.outOfReach))
        #expect(StoreFile.cause(of: CocoaError(.fileWriteOutOfSpace)) == .unreachable(.noRoom))
        #expect(StoreFile.cause(of: POSIXError(.ENOSPC)) == .unreachable(.noRoom))
        struct Unknown: Error {}
        #expect(StoreFile.cause(of: Unknown()) == .unreachable(.outOfReach), "what is not known to be damage is not treated as damage")
    }

    // MARK: - Out of reach for now: nothing moves

    /// Another connection holding the index as a save does, until `release()`.
    private final class Holder: @unchecked Sendable {
        private var handle: OpaquePointer?

        init(_ path: String) throws {
            guard sqlite3_open(path, &handle) == SQLITE_OK,
                  sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK
            else { throw CocoaError(.fileLocking) }
        }

        func release() {
            sqlite3_exec(handle, "COMMIT", nil, nil, nil)
            sqlite3_close(handle)
            handle = nil
        }
    }

    @Test("With another copy of the app holding the store, a launch says it is in use, has no store, and changes no byte on disk; once the other has finished, the next launch opens the same store")
    func inUse() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(6, in: dir)
        let other = try Holder(dir.appendingPathComponent(index).path)
        let before = try disk(dir).filter { !$0.key.hasSuffix("-journal") }

        let opened = launch(dir)
        #expect(opened.trouble == .unreachable(.inUse))
        #expect(opened.file == nil && opened.notes.isEmpty && opened.setAside == nil && !opened.storeIsNewer)
        #expect(try disk(dir).filter { !$0.key.hasSuffix("-journal") } == before, "a store in use was moved or written")
        #expect(try asides(dir).isEmpty)

        other.release()
        let again = launch(dir)
        #expect(again.trouble == nil && again.file != nil)
        #expect(again.notes.count == 6 && bodies(again).allSatisfy { $0 == "held" })
    }

    @Test("With no room left to open it in, the same: nothing is put aside, nothing is made, and the store opens once there is room")
    func noRoom() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(6, in: dir)
        let before = try disk(dir)

        let opened = StoreFile.open(at: dir, now: Date()) { _ in throw DatabaseError(resultCode: .SQLITE_FULL) }
        #expect(opened.trouble == .unreachable(.noRoom) && opened.file == nil && opened.setAside == nil)
        #expect(try disk(dir) == before)

        #expect(launch(dir).notes.count == 6)
    }

    @Test("A folder that takes no writes is out of reach: the launch has no store and changes nothing, and the same store opens once it can be written")
    func outOfReach() async throws {
        let dir = scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try await store(6, in: dir)
        let before = try disk(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.appendingPathComponent(index).path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let opened = launch(dir)
        #expect(opened.trouble == .unreachable(.outOfReach), "\(String(describing: opened.trouble))")
        #expect(opened.file == nil && opened.setAside == nil)
        #expect(try disk(dir) == before)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(index).path)
        let again = launch(dir)
        #expect(again.trouble == nil && again.notes.count == 6)
    }

    @Test("The folder refusing before the index is even opened, and any failure nobody here knows, are the moment too: nothing moves")
    func beforeItIsOpened() async throws {
        struct Unknown: Error {}
        for failure in [CocoaError(.fileWriteNoPermission) as any Error, Unknown(), DatabaseError(resultCode: .SQLITE_IOERR)] {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            try await store(3, in: dir)
            let before = try disk(dir)
            let opened = StoreFile.open(at: dir, now: Date()) { _ in throw failure }
            #expect(opened.trouble == .unreachable(.outOfReach) && opened.file == nil)
            #expect(try disk(dir) == before, "\(failure)")
        }
    }

    // MARK: - Damaged: put aside, and an empty one in its place

    enum Damage: String, CaseIterable, Sendable { case notADatabase, pagesWrittenOver, aRowThatWillNotDecode, aTableThatIsNotOurs }

    /// A store in `dir` damaged in one of the ways a file can be.
    private func damaged(_ way: Damage, in dir: URL) async throws {
        let file = dir.appendingPathComponent(index)
        switch way {
        case .notADatabase:
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 9_000).write(to: file)
        case .pagesWrittenOver:
            try await store(200, in: dir)
            var bytes = try Data(contentsOf: file)
            #expect(bytes.count > 40_000, "the premise: a store of many pages")
            // Every page after the first, written over: the header still says it is a database.
            bytes.replaceSubrange(4_096..<bytes.count, with: Data(repeating: 0xEE, count: bytes.count - 4_096))
            try bytes.write(to: file)
        case .aRowThatWillNotDecode:
            try await store(6, in: dir)
            let raw = try DatabaseQueue(path: file.path)
            try await raw.write { db in try db.execute(sql: "UPDATE note SET facts = 'not what a row is'") }
            try raw.close()
        case .aTableThatIsNotOurs:
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = try DatabaseQueue(path: file.path)
            try await raw.write { db in try db.execute(sql: "CREATE TABLE source (anything TEXT)") }
            try raw.close()
        }
    }

    @Test(
        "A store whose contents are damaged is put aside byte for byte, an empty one opens in its place, and the launch says so",
        arguments: Damage.allCases
    )
    func damagedIsPutAside(_ way: Damage) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(way, in: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent(index))

        let opened = launch(dir)
        #expect(opened.trouble == .damaged(replacedBy: .empty), "\(String(describing: opened.trouble))")
        let aside = try #require(opened.setAside)
        // A migration that fails has already written down that it began: every other damage is
        // found before a byte is written.
        if way != .aTableThatIsNotOurs { #expect(try Data(contentsOf: aside) == before) }
        let file = try #require(opened.file)
        #expect(opened.notes.isEmpty)
        #expect(try file.load().notes.isEmpty)
        #expect(try asides(dir) == [aside.lastPathComponent])
    }

    @Test("A damaged store put aside with no new one made in its place is said as that — not as nothing changed — and the next launch opens an empty one and says the rest")
    func putAsideOnly() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date()) { folder in
            asked += 1
            // The damaged one, and then the one that would have taken its place.
            if asked == 1 { return try StoreFile(at: folder, busyWait: 0.05) }
            throw DatabaseError(resultCode: .SQLITE_FULL)
        }
        #expect(opened.trouble == .unreachable(.putAsideOnly), "\(String(describing: opened.trouble))")
        #expect(opened.file == nil && opened.setAside != nil)
        #expect(try asides(dir).count == 1)

        let next = launch(dir)
        #expect(next.trouble == .damaged(replacedBy: .empty) && next.file != nil && next.notes.isEmpty)
    }

    @Test("A damaged store that cannot be moved aside is left where it is, and nothing is made beside it")
    func damagedButNotMovable() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Damage reported with no index there to move: the moving fails.
        let opened = StoreFile.open(at: dir, now: Date()) { _ in throw DatabaseError(resultCode: .SQLITE_NOTADB) }
        #expect(opened.trouble == .unreachable(.outOfReach) && opened.file == nil && opened.setAside == nil)
        #expect(try names(dir).isEmpty)
    }

    // MARK: - Told, and saved, and only then deleted

    @Test("A store put aside is kept through every save until the person has been told; told, the next save that succeeds deletes it with everything kept beside it, and nothing else")
    func toldThenSaved() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        try LimitAccountFile(directory: dir).write([LimitAct(limit: .months, at: PackagerFixture.origin, posts: 1, sources: [])])
        // What sits beside the store and is nobody's to delete.
        try Data("the person's own".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let opened = launch(dir)
        let file = try #require(opened.file)
        // What SQLite had kept beside the store goes aside with it; SQLite itself throws away a
        // journal that is not one, so this one is laid beside the store put aside.
        let aside = try #require(opened.setAside)
        try Data("a journal".utf8).write(to: URL(fileURLWithPath: aside.path + "-journal"))
        let put = try asides(dir)
        let all = try names(dir)
        #expect(put.count == 3, "the store, what SQLite kept beside it, and its limits' account: \(put) of \(all)")
        let before = try disk(dir).filter { put.contains($0.key) }

        try await file.save(sources: [Self.mastodon], notes: Self.posts(2))
        try await file.save(sources: [Self.mastodon], notes: Self.posts(3))
        #expect(try disk(dir).filter { put.contains($0.key) } == before, "saved, and deleted before the person was told")

        StoreFile.told(in: dir)
        #expect(try disk(dir).filter { put.contains($0.key) } == before, "told, and deleted before what took its place was saved")
        #expect(try asides(dir).count == 4, "told is a mark beside it")

        try await file.save(sources: [Self.mastodon], notes: Self.posts(3))
        #expect(try asides(dir).isEmpty, "told and saved, and still there")
        #expect(try names(dir) == [index, "notes.txt"])
        try file.db.close()
        let next = launch(dir)
        #expect(next.trouble == nil && next.notes.count == 3)
    }

    @Test("A launch quit before the person was told keeps the store put aside, and the next launch says it again — with the store that took its place open as usual")
    func quitBeforeTold() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.aRowThatWillNotDecode, in: dir)
        let first = launch(dir)
        let aside = try #require(first.setAside)
        try await first.file?.save(sources: [Self.mastodon], notes: Self.posts(2, "anew"))
        try first.file?.db.close()

        let second = launch(dir)
        #expect(second.trouble == .damaged(replacedBy: .empty), "a store put aside and never spoken of")
        #expect(second.setAside == nil && bodies(second) == ["anew", "anew"])
        try await second.file?.save(sources: second.sources, notes: second.notes)
        #expect(FileManager.default.fileExists(atPath: aside.path), "deleted with nobody told")
    }

    @Test("Told, and then quit before a save: the next launch does not say it again, and its first save deletes the store put aside")
    func toldThenQuit() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        let first = launch(dir)
        let aside = try #require(first.setAside)
        StoreFile.told(in: dir)
        try first.file?.db.close()

        let second = launch(dir)
        #expect(second.trouble == nil)
        #expect(FileManager.default.fileExists(atPath: aside.path), "an open deleted it")
        try await second.file?.save(sources: [], notes: [])
        #expect(try asides(dir).isEmpty)
    }

    @Test("A save that fails deletes nothing, told or not")
    func aFailedSave() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        let opened = launch(dir)
        let file = try #require(opened.file)
        StoreFile.told(in: dir)
        let before = try asides(dir)
        try file.db.close()
        await #expect(throws: (any Error).self) { try await file.save(sources: [], notes: []) }
        #expect(try asides(dir) == before)
    }

    @Test("Every store put aside by earlier runs goes once told and saved; one put aside after the telling does not")
    func earlierRuns() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        let first = launch(dir)
        try first.file?.db.close()
        try Data(repeating: 0x5A, count: 9_000).write(to: dir.appendingPathComponent(index))
        let second = StoreFile.open(at: dir, now: Date().addingTimeInterval(5), busyWait: 0.05)
        #expect(try asides(dir).count == 2, "the premise: two put aside, by two launches")
        StoreFile.told(in: dir)

        // And a third, after the person was told of the first two.
        let later = dir.appendingPathComponent("index-unreadable-later.sqlite")
        try Data("a third".utf8).write(to: later)
        try await second.file?.save(sources: [], notes: [])
        #expect(try asides(dir) == [later.lastPathComponent], "what nobody was told of was deleted, or what they were told of was not")
        try second.file?.db.close()
        #expect(launch(dir).trouble == .damaged(replacedBy: .empty), "and that one is still to be said")
    }

    // MARK: - The answer

    @Test("Being told of a damaged store marks it and saves again — though nothing has changed since the last save — and the store put aside is gone; an answer to anything else changes nothing")
    func theAnswer() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await damaged(.notADatabase, in: dir)
        let opened = launch(dir)
        let file = try #require(opened.file)
        let saver = StoreSaver(store: ItemStore(), file: file)
        try await saver.save()
        #expect(try asides(dir).count == 1, "the premise: saved already, and not yet told")

        await saver.answered(.told, to: .unreachable(.inUse), in: dir)
        await saver.answered(.keepInPlace, to: .damaged(replacedBy: .empty), in: dir)
        #expect(try asides(dir).count == 1, "an answer that is not being told of it deleted it")

        await saver.answered(.told, to: .damaged(replacedBy: .empty), in: dir)
        #expect(try asides(dir).isEmpty, "told, with nothing new to save, and never deleted")
    }

    // MARK: - Two stores

    /// As a read back killed midway and a run that did not settle it left the folder: the store
    /// this device held moved out of the way, and another, holding posts of its own, in its place.
    private func twoStores(in dir: URL) async throws -> URL {
        try await store(5, "olds", in: dir)
        let aside = dir.appendingPathComponent("incoming-aside-0000", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try Data().write(to: aside.appendingPathComponent(StorePackager.committingMarker))
        try FileManager.default.moveItem(at: dir.appendingPathComponent(index), to: aside.appendingPathComponent(index))
        try await store(2, "news", in: dir)
        return aside
    }

    private func sweep(_ dir: URL) {
        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: dir.appendingPathComponent("no-such-tmp"))
    }

    @Test("Two stores are said to be two, with what each holds: the launch opens neither, makes nothing and changes nothing")
    func twoStoresAreSaid() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await twoStores(in: dir)
        let before = try disk(dir)
        sweep(dir)

        let opened = launch(dir)
        guard case .twoStores(let inPlace, let setAside) = opened.trouble else {
            Issue.record("\(String(describing: opened.trouble))")
            return
        }
        #expect(inPlace.posts == 2 && setAside.posts == 5)
        #expect(inPlace.written != nil && setAside.written != nil)
        #expect(opened.file == nil && opened.notes.isEmpty)
        #expect(try disk(dir) == before, "glancing at two stores changed one")
    }

    @Test("Keeping the one in place moves nothing: the other is kept through the next launch and its sweep, and goes only once the chosen one has opened and saved")
    func keepInPlace() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aside = try await twoStores(in: dir)
        let other = try Data(contentsOf: aside.appendingPathComponent(index))

        StorePackager.choose(.keepInPlace, in: dir)
        #expect(StorePackager.wasDisplaced(aside))
        #expect(try Data(contentsOf: aside.appendingPathComponent(index)) == other, "choosing deleted the store not chosen")

        sweep(dir)
        let opened = launch(dir)
        #expect(opened.trouble == nil && bodies(opened) == ["news", "news"])
        #expect(try Data(contentsOf: aside.appendingPathComponent(index)) == other, "deleted before the chosen one had saved")

        try await opened.file?.save(sources: opened.sources, notes: opened.notes)
        #expect(try names(dir) == [index])
    }

    @Test("Putting back the one set aside makes it the store; the one that stood in its place is kept, displaced, until the chosen one has opened and saved")
    func putBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await twoStores(in: dir)
        let standing = try Data(contentsOf: dir.appendingPathComponent(index))

        StorePackager.choose(.putBack, in: dir)
        let kept = try names(dir).filter { $0.hasPrefix("incoming-aside-") }
        #expect(kept.count == 1, "the old aside is settled, and one holds what stood in its place: \(kept)")
        let displaced = dir.appendingPathComponent(try #require(kept.first))
        #expect(StorePackager.wasDisplaced(displaced))
        #expect(try Data(contentsOf: displaced.appendingPathComponent(index)) == standing)

        sweep(dir)
        let opened = launch(dir)
        #expect(opened.trouble == nil && bodies(opened) == Array(repeating: "olds", count: 5))
        #expect(FileManager.default.fileExists(atPath: displaced.appendingPathComponent(index).path), "deleted before the chosen one had saved")

        try await opened.file?.save(sources: opened.sources, notes: opened.notes)
        #expect(try names(dir) == [index])
    }

    @Test("Should the store chosen prove damaged, the other is not lost: it is the store again at the launch after, and the damaged one is put aside to be said", arguments: [StorePackager.Choice.keepInPlace, .putBack])
    func theChosenOneIsDamaged(_ choice: StorePackager.Choice) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await twoStores(in: dir)
        StorePackager.choose(choice, in: dir)
        // What the choice left in place, damaged before it is ever opened.
        try Data(repeating: 0x5A, count: 9_000).write(to: dir.appendingPathComponent(index))

        sweep(dir)
        let first = launch(dir)
        #expect(first.trouble == .unreachable(.otherComesBack), "\(String(describing: first.trouble))")
        #expect(first.file == nil && first.setAside != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(index).path), "an empty store was made in the other's way")

        sweep(dir)
        let second = launch(dir)
        let other = choice == .keepInPlace ? Array(repeating: "olds", count: 5) : ["news", "news"]
        #expect(bodies(second) == other, "the store not chosen was lost with the one that was")
        #expect(second.trouble == .damaged(replacedBy: .otherStore), "said as though an empty store had taken its place")

        // Told, and saved: the damaged one goes, and the note of what replaced it with it.
        StoreFile.told(in: dir)
        try await second.file?.save(sources: second.sources, notes: second.notes)
        #expect(try names(dir) == [index])
    }

    @Test("A choice cut short while the store in place was being moved leaves both stores, hands back what it had taken from beside one, and is asked again")
    func aChoiceCutShort() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await twoStores(in: dir)
        let half = dir.appendingPathComponent("incoming-aside-9999", isDirectory: true)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try StorePackager.displacedMark.write(to: half.appendingPathComponent(StorePackager.committingMarker))
        try Data("beside the one in place".utf8).write(to: half.appendingPathComponent(index + "-shm"))

        sweep(dir)
        #expect(!FileManager.default.fileExists(atPath: half.path))
        #expect(try Data(contentsOf: dir.appendingPathComponent(index + "-shm")) == Data("beside the one in place".utf8))
        guard case .twoStores = launch(dir).trouble else {
            Issue.record("not asked again")
            return
        }
    }

    @Test("A store moved out of the way with nothing in its place, and not yet put back, is a store that could not be opened: nothing is made where it belongs")
    func notPutBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aside = try await twoStores(in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(index))
        let before = try disk(dir)

        let opened = launch(dir)
        #expect(opened.trouble == .unreachable(.readBackInterrupted) && opened.file == nil)
        #expect(try disk(dir) == before)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent(index).path))
    }

    @Test("A store another connection is writing at that moment is waited on before it is said to be unreadable")
    func theGlanceWaits() async throws {
        #expect(StoreGlance.wait == 1)
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(4, in: dir)
        let file = dir.appendingPathComponent(index)
        #expect(StoreGlance.of(indexAt: file).posts == 4)
        // Held, and let go from another task while the glance waits — given far longer than the
        // letting go can take, so a slow machine is not what this measures.
        let other = try Holder(file.path)
        let releasing = Task.detached { other.release() }
        #expect(StoreGlance.of(indexAt: file, wait: 30).posts == 4, "busy for a moment, and said to be unreadable")
        await releasing.value
        // And one that is not a store at all is still said to be so.
        try Data(repeating: 0x5A, count: 9_000).write(to: file)
        #expect(StoreGlance.of(indexAt: file).posts == nil)
    }

    // MARK: - No read back, and no take-away of nothing, in a run with no store

    /// A packager as a launch that could not open the store builds one.
    private func packager(_ device: PackagerFixture.PackagerDevice, storeNotOpened: Bool, storeIsNewer: Bool = false) -> StorePackager {
        StorePackager(
            directory: device.directory, file: nil, store: device.store, media: device.media, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            storeIsNewer: storeIsNewer, storeNotOpened: storeNotOpened, freeSpace: { _ in .max }, rounds: 1000
        )
    }

    @Test("In a run that did not open the store, a read back that would replace it is refused with its own reason, before anything on disk moves — the store in use is still there, byte for byte")
    func noReadBack() async throws {
        let from = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: Self.posts(3, "news"))
        let onto = try await PackagerFixture.PackagerDevice(noFile: true)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: package) }
        try await from.packager().takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        try await store(5, "olds", in: onto.directory)
        let before = try disk(onto.directory)

        await #expect(throws: PackageFault.storeNotOpened) {
            try await packager(onto, storeNotOpened: true).readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try disk(onto.directory) == before, "a store that could not be opened was moved aside")

        // The premise: the same packager, told the store was simply not there, reads it back.
        try await packager(onto, storeNotOpened: false).readBack(package, key: .password("password"), replacing: true) { _ in }
        #expect(await onto.store.all().count == 3)
    }

    @Test("In a run that holds none of what this device holds — its store did not open, or is a newer build's — a take-away says there is nothing to take and writes no file")
    func nothingToTake() async throws {
        for (notOpened, newer) in [(true, false), (false, true)] {
            let device = try await PackagerFixture.PackagerDevice(noFile: true)
            let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
            defer { device.remove(); try? FileManager.default.removeItem(at: package) }
            await #expect(throws: PackageFault.nothingToTake) {
                try await packager(device, storeNotOpened: notOpened, storeIsNewer: newer)
                    .takeAway(to: package, key: .password("password"), pictures: false) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: package.path), "an empty package was written")
        }
    }

    @Test("A device nearby is told the same two things in their own words, and not as something else that refused")
    func nearbySaysTheSame() {
        #expect(NearbyRefusal(PackageFault.storeNotOpened) == .storeNotOpened)
        #expect(NearbyRefusal(PackageFault.nothingToTake) == .nothingToTake)
    }

    // MARK: - Neither damaged nor out of reach

    @Test("A store that opens says nothing, and a newer build's is left as found and says only that")
    func nothingToSay() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(3, in: dir)
        #expect(launch(dir).trouble == nil)

        let raw = try DatabaseQueue(path: dir.appendingPathComponent(index).path)
        try await raw.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')") }
        try raw.close()
        let before = try disk(dir)
        let newer = launch(dir)
        #expect(newer.storeIsNewer && newer.trouble == nil && newer.file == nil)
        #expect(try disk(dir) == before)
    }

    @Test("Opening waits on another connection for as long as it is given before saying the store is in use, and the wait a launch gives is a save's length")
    func theWait() async throws {
        #expect(StoreFile.busyWait == 3)
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(3, in: dir)
        let file = try StoreFile(at: dir, busyWait: 1.5)
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") } == 1_500)
    }
}
