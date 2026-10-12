import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// A canary a test turns, which counts how often it was asked.
final class CanaryTurned: Sendable {
    private let state: OSAllocatedUnfairLock<(answer: ProtectedData.Canary, looks: Int)>

    init(_ answer: ProtectedData.Canary) { state = OSAllocatedUnfairLock(initialState: (answer, 0)) }

    func turn(_ answer: ProtectedData.Canary) { state.withLock { $0.answer = answer } }
    var looks: Int { state.withLock { $0.looks } }

    var protected: ProtectedData {
        ProtectedData(
            // The system's own word says "unavailable" throughout: nothing here may go by it.
            flag: { false },
            canary: { [state] in
                state.withLock { state in
                    state.looks += 1
                    return state.answer
                }
            },
            remade: { .refused }, unlockedForSomebody: { false }, changes: { AsyncStream { $0.finish() } }
        )
    }
}

/// #344: a save a locked device refuses is not trouble. It is owed, held without spending the
/// follower's tries, and written when the canary reads again — over a connection that the
/// same store may make again, to the same file and no other.
@Suite("A save refused by a lock is owed, and written on unlock")
struct OwedSaveTests {
    private static let source = Source(host: "alpha.test", kind: .mastodon)

    /// What the saver's writes did: how many were asked, and whether they are refused now.
    private final class Disk: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (refusing: false, asked: 0, landed: 0))
        struct Refused: Error {}
        func refuse(_ refusing: Bool) { state.withLock { $0.refusing = refusing } }
        var asked: Int { state.withLock { $0.asked } }
        var landed: Int { state.withLock { $0.landed } }
        func write() throws {
            try state.withLock { state in
                state.asked += 1
                if state.refusing { throw Refused() }
                state.landed += 1
            }
        }
    }

    private func saver(_ disk: Disk, _ canary: CanaryTurned) -> StoreSaver {
        StoreSaver(
            store: ItemStore(sources: [Self.source], notes: []),
            write: { _, _, _ in try disk.write() }, protected: canary.protected
        )
    }

    @Test("A save that goes through asks the canary nothing — and is held by nothing, whatever the canary would say")
    func noProbeWhereNothingFailed() async throws {
        // A Mac behind a locked screen: a fresh read of the canary is refused, and the
        // connection the app holds goes on writing.
        let disk = Disk(), canary = CanaryTurned(.refused)
        let saver = saver(disk, canary)
        try await saver.save()
        try await saver.resave()
        await saver.owedNow()
        try await saver.retry(gap: .zero) { _ in }
        #expect(disk.landed == 2)
        #expect(canary.looks == 0, "a probe is a file made and unlinked on a phone: not before a write, and not where nothing is owed")
        #expect(await !saver.isHeldForALock)
    }

    @Test("A save refused while the canary refuses is held: the follower spends no try on it, however often it comes round")
    func heldNotCountedDown() async throws {
        let disk = Disk(), canary = CanaryTurned(.refused)
        let saver = saver(disk, canary)
        disk.refuse(true)
        await #expect(throws: Disk.Refused.self) { try await saver.save() }
        #expect(disk.asked == 1)
        let slept = OSAllocatedUnfairLock(initialState: 0)
        for _ in 0..<12 { try await saver.retry(gap: .seconds(60)) { _ in slept.withLock { $0 += 1 } } }
        #expect(disk.asked == 1, "tried again behind a lock")
        #expect(slept.withLock { $0 } == 0)
        #expect(await saver.isHeldForALock)
        #expect(canary.looks == 1, "asked why once, for the one failure")

        // Unlocked, and the disk taking writes again: one ask writes it — and the tries a lock
        // did not spend are all still there for a failure that is no lock.
        canary.turn(.reads)
        disk.refuse(false)
        await saver.owedNow()
        #expect(disk.landed == 1)
        #expect(await !saver.isHeldForALock)
        disk.refuse(true)
        await #expect(throws: Disk.Refused.self) { try await saver.resave() }
        let before = disk.asked
        for _ in 0..<12 { try await saver.retry(gap: .seconds(60)) { _ in } }
        #expect(disk.asked - before == StoreSaver.retries, "five tries for trouble that is no lock, and then it is left")
    }

    @Test("Asked while the canary still refuses, what is owed stays owed and nothing is tried; with no canary at all it is tried")
    func owedNowAsksTheCanary() async throws {
        let disk = Disk(), canary = CanaryTurned(.refused)
        let saver = saver(disk, canary)
        disk.refuse(true)
        await #expect(throws: Disk.Refused.self) { try await saver.save() }
        disk.refuse(false)
        await saver.owedNow()
        #expect(disk.asked == 1 && disk.landed == 0)
        #expect(await saver.isHeldForALock)
        // No canary: nothing says it is a lock, and the save is simply made.
        canary.turn(.none)
        await saver.owedNow()
        #expect(disk.landed == 1)
    }

    @Test("A device that locks again as the owed save is tried makes no connection again: only a failure between two good canary reads does")
    func lockedAgainAsItWasTried() async throws {
        let disk = Disk(), canary = CanaryTurned(.refused)
        let made = OSAllocatedUnfairLock(initialState: 0)
        let saver = StoreSaver(
            store: ItemStore(sources: [Self.source], notes: []),
            write: { _, _, _ in
                // The write is refused — and by then the canary is too.
                canary.turn(.refused)
                try disk.write()
            },
            writeUnsent: nil, writeNotices: nil, protected: canary.protected, remake: { made.withLock { $0 += 1 } }
        )
        disk.refuse(true)
        await #expect(throws: Disk.Refused.self) { try await saver.save() }
        await saver.owedNow()
        #expect(await saver.isHeldForALock)
        canary.turn(.reads)
        await saver.owedNow()
        #expect(disk.asked == 2, "tried once, the canary having read")
        #expect(made.withLock { $0 } == 0, "a connection made again behind a lock")
        // And where it reads before the failure and after, it is made again, and the save tried.
        let steady = StoreSaver(
            store: ItemStore(sources: [Self.source], notes: []), write: { _, _, _ in try disk.write() },
            writeUnsent: nil, writeNotices: nil, protected: canary.protected, remake: { made.withLock { $0 += 1 } }
        )
        canary.turn(.refused)
        await #expect(throws: Disk.Refused.self) { try await steady.save() }
        await steady.owedNow()
        canary.turn(.reads)
        var before = disk.asked
        await steady.owedNow()
        #expect(made.withLock { $0 } == 1 && disk.asked - before == 2)
        // **Once for a run of failures**: locked and unlocked again with the disk still
        // refusing, the save is tried and no second connection is made.
        canary.turn(.refused)
        await steady.owedNow()
        canary.turn(.reads)
        before = disk.asked
        await steady.owedNow()
        #expect(made.withLock { $0 } == 1 && disk.asked - before == 1)
        // A save landing ends the run: the next failures may have it made again.
        disk.refuse(false)
        try await steady.resave()
        disk.refuse(true)
        canary.turn(.refused)
        await #expect(throws: Disk.Refused.self) { try await steady.resave() }
        await steady.owedNow()
        canary.turn(.reads)
        await steady.owedNow()
        #expect(made.withLock { $0 } == 2)
    }

    @Test("Trouble that is no lock is not touched by a wake-up, however many come: the follower's handful of tries is all it gets")
    func troubleThatIsNoLock() async throws {
        // A full disk, on a Mac where a window coming back into sight is a wake-up.
        let disk = Disk(), canary = CanaryTurned(.reads)
        let made = OSAllocatedUnfairLock(initialState: 0)
        let saver = StoreSaver(
            store: ItemStore(sources: [Self.source], notes: []), write: { _, _, _ in try disk.write() },
            writeUnsent: nil, writeNotices: nil, protected: canary.protected, remake: { made.withLock { $0 += 1 } }
        )
        disk.refuse(true)
        await #expect(throws: Disk.Refused.self) { try await saver.save() }
        for _ in 0..<20 { await saver.owedNow() }
        #expect(disk.asked == 1, "saved again at a wake-up, with nothing to say a lock had ended")
        #expect(made.withLock { $0 } == 0)
        #expect(await !saver.isHeldForALock)
        // The follower's bound stands, wake-ups arriving between its tries or not.
        for _ in 0..<12 {
            try await saver.retry(gap: .seconds(60)) { _ in }
            await saver.owedNow()
        }
        #expect(disk.asked == 1 + StoreSaver.retries)
        #expect(made.withLock { $0 } == 0)
    }

    // MARK: - The connection made again

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("Where the save still fails with the canary reading, the store's own connection is made again and the save lands — to the same file")
    func theConnectionMadeAgain() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let store = ItemStore(sources: [Self.source], notes: [])
        let canary = CanaryTurned(.refused)
        let saver = StoreSaver(store: store, file: file, protected: canary.protected)
        try await saver.save()
        // A phone locked and unlocked: the connection it held is no use any more.
        try file.db.close()
        await store.add(Source(host: "beta.test", kind: .mastodon))
        await #expect(throws: (any Error).self) { try await saver.save() }
        await saver.owedNow()
        #expect(await saver.isHeldForALock, "still locked: nothing is made again behind a lock")
        canary.turn(.reads)
        await saver.owedNow()
        #expect(await !saver.isHeldForALock)
        let opened = StoreFile.open(at: dir)
        #expect(Set(opened.sources.map(\.host)) == ["alpha.test", "beta.test"], "what was done since the lock is on disk")
        #expect(opened.trouble == nil)
    }

    @Test("A connection is made again only to the very file that was opened: not to another at its path, and never for a store that was no file")
    func onlyTheSameFile() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: [])
        // A rebuild writes back into the same file: it is still that file afterwards.
        try await file.compact()
        try file.remakeConnection()
        #expect(try file.load().sources.map(\.host) == ["alpha.test"])
        // A build after this one has written it since: not made again, and not written by this one.
        let later = scratch()
        defer { try? FileManager.default.removeItem(at: later) }
        let newer = try StoreFile(at: later)
        try await newer.db.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999-of-a-later-build')") }
        #expect(throws: StoreFile.Newer.self) { try newer.remakeConnection() }
        // Another file where it was — put aside and a new one made, by anything at all.
        let index = dir.appendingPathComponent("index.sqlite")
        try FileManager.default.moveItem(at: index, to: dir.appendingPathComponent("moved-away.sqlite"))
        let other = scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        try StoreFile(at: other).db.close()
        try FileManager.default.copyItem(at: other.appendingPathComponent("index.sqlite"), to: index)
        #expect(throws: StoreFile.Remake.anotherFile) { try file.remakeConnection() }
        try FileManager.default.removeItem(at: index)
        #expect(throws: StoreFile.Remake.anotherFile) { try file.remakeConnection() }
        #expect(!FileManager.default.fileExists(atPath: index.path), "making it again made a file")
        // A store that was never a file opened by path has nothing to make again.
        #expect(throws: StoreFile.Remake.notOpenedOnDisk) { try StoreFile(database: DatabaseQueue()).remakeConnection() }
    }

    @Test("A run with no store has no connection to make, by construction: the saver is handed one only with a file")
    func noFileNoRemake() async throws {
        let canary = CanaryTurned(.reads)
        let saver = StoreSaver(store: ItemStore(sources: [Self.source], notes: []), file: nil, protected: canary.protected)
        try await saver.save()
        await saver.owedNow()
        #expect(await !saver.isHeldForALock)
        #expect(canary.looks == 0)
        // Held to the source: the one call, inside the one place a file is in hand.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var uses: [String: Int] = [:]
        let sources = root.appendingPathComponent("Sources")
        for path in try FileManager.default.subpathsOfDirectory(atPath: sources.path) where path.hasSuffix(".swift") {
            let url = sources.appendingPathComponent(path)
            let count = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "remakeConnection(").count - 1
            if count > 0 { uses[url.lastPathComponent] = count }
        }
        #expect(uses == ["StoreFile.swift": 1, "StoreSaver.swift": 1])
        let code = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StoreSaver.swift"), encoding: .utf8)
        let inHand = try #require(code.range(of: "if let file {"))
        let made = try #require(code.range(of: "remake = { try file.remakeConnection() }"))
        let handed = try #require(code.range(of: "protected: protected, remake: remake"))
        #expect(inHand.upperBound < made.lowerBound && made.upperBound < handed.lowerBound)
    }

    // MARK: - A lock met midway

    @Test("A take-away or a read back that meets a file the system will not make says the device is locked where the canary refuses, and what it is where it does not")
    func lockedMidway() async throws {
        let from = try await PackagerFixture.populated()
        defer { from.remove() }
        let package = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try await from.packager().takeAway(to: package, key: .password("open sesame"), pictures: false, contents: .whole) { _ in }
        let onto = try await PackagerFixture.PackagerDevice()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: onto.directory.path)
            onto.remove()
        }
        // It read when the read back began; then the folder takes no new file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: onto.directory.path)
        await #expect(throws: PackageFault.locked) {
            try await onto.packager(protected: CanaryByHand(.reads, .refused).protected)
                .readBack(package, key: .password("open sesame"), replacing: true) { _ in }
        }
        // The same refusal with a canary that reads is not a lock, and is not said to be one.
        do {
            try await onto.packager(protected: CanaryByHand(.reads).protected)
                .readBack(package, key: .password("open sesame"), replacing: true) { _ in }
            Issue.record("it was not refused at all")
        } catch {
            #expect(error as? PackageFault != .locked)
            #expect(Guarded.isRefusal(error))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: onto.directory.path)
        // A package whose index will not open as a store: said as that where the canary reads,
        // and as the lock where it has come to refuse — a lock says nothing of the package.
        let bad = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
        let junk = Data(repeating: 0x5A, count: 64)
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let pieces: [(PackageFormat.Entry.Kind, String, Data)] = [
            (.store, "index.sqlite", junk), (.settings, "settings", settings), (.secrets, "secrets", Data()),
        ]
        let summary = PackageSummary(
            contents: .whole, sources: [], posts: 0, timelines: 0, takenAt: PackagerFixture.origin, withPictures: false,
            bytes: pieces.reduce(0) { $0 + $1.2.count }, hasSecrets: false, device: "a test", appVersion: "0.7.0",
            entryCount: pieces.count, kept: 0
        )
        let writer = try PackageWriter(to: bad, key: .password("open sesame"), summary: summary, rounds: 1000)
        for (kind, name, data) in pieces {
            var sent = false
            try writer.add(kind, name: name, bytes: data.count) { _ in
                defer { sent = true }
                return sent ? nil : data
            }
        }
        try writer.finish()
        await #expect(throws: PackageFault.unreadableStore) {
            try await onto.packager(protected: CanaryByHand(.reads).protected)
                .readBack(bad, key: .password("open sesame"), replacing: true) { _ in }
        }
        await #expect(throws: PackageFault.locked) {
            try await onto.packager(protected: CanaryByHand(.reads, .refused).protected)
                .readBack(bad, key: .password("open sesame"), replacing: true) { _ in }
        }
        #expect(onto.packager(protected: CanaryByHand(.refused).protected).isLocked())
        #expect(!onto.packager().isLocked())
    }
}

/// #344: a save's failure is said in the log by its kind and SQLite's number — never by the
/// error's own words, which can carry what was being written.
@Suite("A failed save of what is this device's own is logged by its kind alone")
struct SaveFailureLogTests {
    @Test("What is said of an error is its type and SQLite's code, and nothing of its message, its statement or its arguments")
    func kind() {
        let raised = DatabaseError(
            resultCode: .SQLITE_IOERR_WRITE, message: "disk I/O error at one.example",
            sql: "UPDATE source SET title = ? WHERE host = ?", arguments: ["A small place", "one.example"]
        )
        let said = StoreSaver.kind(of: raised)
        #expect(said == "DatabaseError \(ResultCode.SQLITE_IOERR_WRITE.rawValue)")
        #expect(!said.contains("one.example") && !said.contains("UPDATE") && !said.contains("small"))
        struct Refusal: Error { let host = "one.example" }
        #expect(StoreSaver.kind(of: Refusal()) == "Refusal")
    }

    @Test("The line for what is this device's own says only that, in public")
    func theLine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StoreSaver.swift"), encoding: .utf8)
        let line = try #require(code.split(separator: "\n").first { $0.contains("Saving what is this device's own failed") })
        #expect(line.contains("\\(Self.kind(of: error), privacy: .public)") && !line.contains("String(describing: error)"))
    }
}
