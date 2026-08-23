import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// A file that is not a database is set aside, not fought with.
@Suite("Recovering the local store")
struct LocalStoreRecoveryTests {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Garbage where the store should be is moved aside and a fresh store opened")
    func garbageIsSetAside() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        try Data("this is not a database, and never was, not even a little".utf8).write(to: URL(fileURLWithPath: path))

        let store = try LocalStore.openRecovering(path: path, now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(try await store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM protocols") } == 3)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: "\(path).corrupt-1700000000"))
    }

    @Test("A store that opens is opened, and nothing is set aside")
    func healthyIsLeftAlone() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        _ = try LocalStore.openRecovering(path: path)
        _ = try LocalStore.openRecovering(path: path)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.contains(".corrupt-") })
    }
}
