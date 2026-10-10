import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// A canary turned by hand: what each look at it answers, in order, the last one for ever
/// after — and how many looks there were.
final class CanaryByHand: Sendable {
    private let state: OSAllocatedUnfairLock<(answers: [ProtectedData.Canary], looks: Int)>

    init(_ answers: ProtectedData.Canary...) {
        state = OSAllocatedUnfairLock(initialState: (answers, 0))
    }

    var looks: Int { state.withLock { $0.looks } }

    var protected: ProtectedData {
        ProtectedData(
            flag: { true },
            canary: { [state] in
                state.withLock { state in
                    defer { state.looks += 1 }
                    return state.answers[min(state.looks, state.answers.count - 1)]
                }
            },
            remade: { .refused }, unlockedForSomebody: { false }, changes: { AsyncStream { $0.finish() } }
        )
    }
}

/// #344: a device that locks is never read as a damaged store. What decides is the canary and
/// nothing else — every code a lock might report is handed in here with the canary refusing,
/// and each must come out as the lock, with nothing on disk moved.
@Suite("A locked device damages nothing")
struct LockedStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A store of one source saved and closed in `dir`.
    private func store(in dir: URL) async throws {
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [])
        try file.db.close()
    }

    /// A file of anything where the index should be: not a database, which is damage.
    private func notADatabase(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("index.sqlite"))
    }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// What a lock might make SQLite or the system say, damage-class codes among them.
    static let codes: [ResultCode] = [
        .SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_ERROR, .SQLITE_IOERR, .SQLITE_AUTH, .SQLITE_CANTOPEN, .SQLITE_PERM,
    ]

    @Test("Whatever the first read reports, a canary that then refuses makes it the lock, and nothing is moved", arguments: codes)
    func refusedAfterTheFailure(code: ResultCode) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let before = try names(dir)
        // It read when the launch began, and the device locked while the store was being opened.
        let canary = CanaryByHand(.reads, .refused)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: canary.protected) { _ in
            asked += 1
            throw DatabaseError(resultCode: code)
        }
        #expect(opened.trouble == .unreachable(.locked))
        #expect(opened.file == nil && opened.setAside == nil)
        #expect(asked == 1, "no second try behind a canary that refuses")
        #expect(try names(dir) == before)
    }

    @Test("A canary that refuses before anything is asked is the lock, and the store is not asked at all")
    func refusedBefore() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try notADatabase(in: dir)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.refused).protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == .unreachable(.locked))
        #expect(asked == 0)
        #expect(try names(dir) == ["index.sqlite"])
    }

    @Test("A canary that refuses only after the second try is still the lock", arguments: codes)
    func refusedAfterTheSecondTry(code: ResultCode) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let before = try names(dir)
        let canary = CanaryByHand(.reads, .reads, .refused)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: canary.protected) { _ in
            asked += 1
            throw DatabaseError(resultCode: code)
        }
        #expect(opened.trouble == .unreachable(.locked))
        #expect(asked == 2)
        #expect(try names(dir) == before)
    }

    @Test("The same failure twice between three good canary reads is what it is: a damaged store is put aside")
    func damageIsStillDamage() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try notADatabase(in: dir)
        let canary = CanaryByHand(.reads)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: canary.protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == .damaged(replacedBy: .empty))
        #expect(opened.file != nil && opened.setAside != nil)
        #expect(asked == 3, "the read, the read again on a fresh connection, and the store made in its place")
        // The second try repeated the read and nothing else: the store was put aside once.
        #expect(try names(dir).filter { $0.hasPrefix("index-unreadable-") && $0.hasSuffix(".sqlite") }.count == 1)
        #expect(canary.looks == 4, "before the attempt, after the failure, after the second, and before anything is moved")
    }

    @Test("A canary that refuses at the last look, with the damage found twice over, still moves nothing")
    func refusedBeforeThePutAside() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try notADatabase(in: dir)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads, .reads, .reads, .refused).protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == .unreachable(.locked) && opened.setAside == nil && opened.file == nil)
        #expect(asked == 2)
        #expect(try names(dir) == ["index.sqlite"])
    }

    @Test("No store is made while the one chosen against is kept and could not be made the store again")
    func theOtherCouldNotBeReinstated() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let other = try aside(saying: StorePackager.displacedMark, in: dir, refused: false)
        try notADatabase(in: dir)
        // Its marker reads, and cannot be rewritten: the folder takes no new file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: other.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path) }
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == .unreachable(.putAsideOnly))
        #expect(opened.file == nil && opened.setAside != nil)
        #expect(asked == 2, "the damaged one twice, and none made in its place")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path), "an empty store here would, at its first save, remove the good one")
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("index.sqlite").path))
    }

    @Test("A second try that succeeds is the open: nothing is said and nothing put aside")
    func theSecondTryOpens() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { folder in
            asked += 1
            if asked == 1 { throw DatabaseError(resultCode: .SQLITE_NOTADB) }
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == nil && opened.setAside == nil)
        #expect(opened.sources.map(\.host) == [Self.mastodon.host])
        #expect(opened.file != nil)
        #expect(try names(dir).filter { $0.hasPrefix("index-unreadable") }.isEmpty)
    }

    @Test("A second try that fails another way is said by its own cause, and is never damage")
    func theSecondTryFailsOtherwise() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let before = try names(dir)
        var asked = 0
        let busy = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { _ in
            asked += 1
            if asked == 1 { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "a row")) }
            throw DatabaseError(resultCode: .SQLITE_BUSY)
        }
        #expect(busy.trouble == .unreachable(.inUse))
        // Two damage-class failures that are not the same failure are not damage either.
        asked = 0
        let mixed = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { _ in
            asked += 1
            throw DatabaseError(resultCode: asked == 1 ? .SQLITE_NOTADB : .SQLITE_CORRUPT)
        }
        #expect(mixed.trouble == .unreachable(.outOfReach))
        #expect(mixed.setAside == nil && busy.setAside == nil)
        #expect(try names(dir) == before)
    }

    @Test("With no canary nothing is classed as damage: a store that is not a database is one that could not be opened",
          arguments: [false, true])
    func noCanary(refusedButUnlocked: Bool) throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try notADatabase(in: dir)
        // None could be made — or one refuses on a device a person is known to have unlocked.
        // **Decided once, as the launch begins**: one that reads a moment later vouches for
        // nothing that was asked before it did.
        let canary = CanaryByHand(refusedButUnlocked ? .refused : .none, .reads)
        var asked = 0
        let opened = StoreFile.open(at: dir, now: Date(), protected: canary.protected, unlocked: refusedButUnlocked) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(opened.trouble == .unreachable(.outOfReach))
        #expect(opened.file == nil && opened.setAside == nil)
        #expect(asked == 1)
        #expect(try names(dir) == ["index.sqlite"])
    }

    @Test("With no canary a store that is whole still opens", arguments: [false, true])
    func noCanaryStillOpens(refusedButUnlocked: Bool) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let canary = CanaryByHand(refusedButUnlocked ? .refused : .none)
        let opened = StoreFile.open(at: dir, protected: canary.protected, unlocked: refusedButUnlocked)
        #expect(opened.trouble == nil && opened.file != nil)
        #expect(opened.sources.map(\.host) == [Self.mastodon.host])
    }

    // MARK: - Markers that will not be read

    /// An aside as a read back leaves one, with the old index in it and a marker saying `word`
    /// that the system then refuses to read — `chmod 000`, which gives what a lock gives.
    private func aside(saying word: Data, in dir: URL, refused: Bool) throws -> URL {
        let aside = dir.appendingPathComponent("incoming-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("index.sqlite"), to: aside.appendingPathComponent("index.sqlite"))
        let marker = aside.appendingPathComponent(StorePackager.committingMarker)
        try word.write(to: marker)
        if refused { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path) }
        return aside
    }

    @Test("A marker that will not be read is not a marker that says nothing: no index is opened, and nothing is settled")
    func aMarkerRefused() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        // Replaced, by its word — which nobody can read. Read as empty it would be "moved
        // aside, not replaced", and the old index put back over the package's.
        let aside = try aside(saying: StorePackager.replacedMark, in: dir, refused: true)
        #expect(throws: (any Error).self) { try StorePackager.word(in: aside) }
        #expect(throws: (any Error).self) { try StorePackager.unsettledReadBack(in: dir) }
        #expect(throws: (any Error).self) { try StorePackager.hasUnsettledReadBack(in: dir) }
        let before = try names(dir)
        let settled = StorePackager.settleHalfCommits(in: dir)
        #expect(settled.putBack == 0 && settled.unsettled == 1)
        #expect(try names(dir) == before)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("index.sqlite").path))
        // And where the index in place holds nothing — which beside a marker that says nothing
        // is removed, and the aside put back over it — an unreadable marker still settles nothing.
        let empty = scratch()
        defer { try? FileManager.default.removeItem(at: empty) }
        try await store(in: empty)
        let held = try self.aside(saying: StorePackager.replacedMark, in: empty, refused: true)
        try FileManager.default.removeItem(at: empty.appendingPathComponent("index.sqlite"))
        try StoreFile(at: empty).db.close()
        let inPlace = try Data(contentsOf: empty.appendingPathComponent("index.sqlite"))
        let again = StorePackager.settleHalfCommits(in: empty)
        #expect(again.putBack == 0 && again.unsettled == 1)
        #expect(try Data(contentsOf: empty.appendingPathComponent("index.sqlite")) == inPlace, "the package's index was removed for the old one")
        #expect(FileManager.default.fileExists(atPath: held.path))

        var asked = 0
        // The canary reads: not a lock, then, but a store out of reach — and none is opened.
        let out = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(out.trouble == .unreachable(.outOfReach) && out.file == nil)
        // The canary refuses once the marker has: the lock.
        let locked = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads, .refused).protected) { folder in
            asked += 1
            return try StoreFile(at: folder)
        }
        #expect(locked.trouble == .unreachable(.locked) && locked.file == nil)
        #expect(asked == 0)
        #expect(try names(dir) == before)
    }

    @Test("A damaged store beside a store chosen against whose marker will not be read is not moved, and nothing is made in its place")
    func theOtherStoresMarkerRefused() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store(in: dir)
        let other = try aside(saying: StorePackager.displacedMark, in: dir, refused: true)
        try notADatabase(in: dir)
        #expect(throws: (any Error).self) { try StorePackager.reinstateDisplaced(in: dir) }
        let before = try names(dir)
        let opened = StoreFile.open(at: dir, protected: CanaryByHand(.reads).protected)
        #expect(opened.file == nil && opened.setAside == nil)
        #expect(opened.trouble == .unreachable(.outOfReach))
        #expect(try names(dir) == before, "an empty store made here would take the other with it at its first save")
        // The same where it could be read as the launch began and not a moment later, when
        // the damage has been found and the store is about to be put aside: a device that
        // locked in between.
        let marker = other.appendingPathComponent(StorePackager.committingMarker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        var asked = 0
        let between = StoreFile.open(at: dir, now: Date(), protected: CanaryByHand(.reads).protected) { folder in
            asked += 1
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
            return try StoreFile(at: folder)
        }
        #expect(asked == 2, "the damage was found, twice over")
        #expect(between.file == nil && between.setAside == nil && between.trouble == .unreachable(.outOfReach))
        #expect(try names(dir) == before)
        // Readable again, the other is the store to put back, as before.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.appendingPathComponent(StorePackager.committingMarker).path)
        #expect(StoreFile.open(at: dir, protected: CanaryByHand(.reads).protected).trouble == .unreachable(.otherComesBack))
    }

    // MARK: - The sweep

    @Test("Nothing is settled and nothing swept unless the canary reads", arguments: [ProtectedData.Canary.refused, .none])
    func theSweepWaits(canary: ProtectedData.Canary) async throws {
        let dir = scratch(), temporary = scratch()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: temporary)
        }
        try await store(in: dir)
        _ = try aside(saying: Data(), in: dir, refused: false)
        let staging = dir.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        let scratchIndex = temporary.appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        for folder in [staging, scratchIndex] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let before = try (names(dir), names(temporary))
        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: temporary, protected: CanaryByHand(canary).protected)
        #expect(try names(dir) == before.0)
        #expect(try names(temporary) == before.1)
        // And where it reads, the same sweep does what it always did.
        StorePackager.sweepLeftovers(directory: dir, media: nil, temporary: temporary, protected: CanaryByHand(.reads).protected)
        #expect(try names(temporary).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: - The limits' account

    @Test("The limits' account that will not be read throws, where none at all is no lines")
    func theAccountRefused() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try LimitAccountFile(directory: dir)
        #expect(try account.read().isEmpty)
        let line = LimitAct(limit: .months, at: PackagerFixture.origin, posts: 2, sources: ["alpha.test"])
        try account.write([line])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: account.url.path)
        #expect(throws: (any Error).self) { try account.read() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: account.url.path)
        #expect(try account.read() == [line])
    }

    @Test("A take-away does not pack an empty account for one it could not read, and a read back does not take one for none")
    func theAccountInAPackage() async throws {
        let device = try await PackagerFixture.populated()
        defer { device.remove() }
        let account = try LimitAccountFile(directory: device.directory)
        try account.write([LimitAct(limit: .months, at: PackagerFixture.origin, posts: 2, sources: ["alpha.test"])])
        let held = try Data(contentsOf: account.url)
        let package = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try await device.packager().takeAway(to: package, key: .password("open sesame"), pictures: false, contents: .whole) { _ in }

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: account.url.path)
        let second = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        await #expect(throws: (any Error).self) {
            try await device.packager().takeAway(to: second, key: .password("open sesame"), pictures: false, contents: .whole) { _ in }
        }
        await #expect(throws: (any Error).self) {
            try await device.packager().readBack(package, key: .password("open sesame"), replacing: true) { _ in }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: account.url.path)
        #expect(try Data(contentsOf: account.url) == held, "what it could not read it did not write over, or remove")
    }
}
