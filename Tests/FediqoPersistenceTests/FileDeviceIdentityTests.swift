import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// D1: this device's id, in a file beside the store — made only where it is missing, excluded
/// from backup, and never made afresh over a file that will not read.
@Suite("This device's id, kept in a file")
struct FileDeviceIdentityTests {
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-device-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Made once where missing, and the same id from then on")
    func madeOnlyWhenMissing() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = FileDeviceIdentity(directory: dir)
        let first = try identity.deviceID()
        #expect(UUID(uuidString: first) != nil)
        #expect(try identity.deviceID() == first)
        #expect(try FileDeviceIdentity(directory: dir).deviceID() == first)

        let kept = UUID().uuidString
        try Data(kept.utf8).write(to: identity.url)
        #expect(try identity.deviceID() == kept, "an id already kept is the id")
    }

    @Test("Excluded from backup, so a restored device never shares it")
    func excludedFromBackup() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = FileDeviceIdentity(directory: dir)
        _ = try identity.deviceID()
        #expect(try identity.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("A marking that will not take still hands back the id kept")
    func markingFailsKeepsID() throws {
        let dir = try Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(FileDeviceIdentity.name).path)
            try? FileManager.default.removeItem(at: dir)
        }
        let identity = FileDeviceIdentity(directory: dir)
        let kept = UUID().uuidString
        try Data(kept.utf8).write(to: identity.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: identity.url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var probe = identity.url
        #expect(throws: (any Error).self, "the premise: a read-only file refuses the marking") { try probe.setResourceValues(values) }
        #expect(try identity.deviceID() == kept)
    }

    @Test("A file that will not read throws, and nothing is made over it")
    func unreadableThrows() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = FileDeviceIdentity(directory: dir)
        try Data("not an id".utf8).write(to: identity.url)
        #expect(throws: (any Error).self) { try identity.deviceID() }
        #expect(try Data(contentsOf: identity.url) == Data("not an id".utf8))

        let other = try Self.folder()
        defer { try? FileManager.default.removeItem(at: other) }
        let blocked = FileDeviceIdentity(directory: other)
        try FileManager.default.createDirectory(at: blocked.url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try blocked.deviceID() }

        let missing = FileDeviceIdentity(directory: other.appendingPathComponent("no-such-folder", isDirectory: true))
        #expect(throws: (any Error).self) { try missing.deviceID() }
        #expect(!FileManager.default.fileExists(atPath: missing.url.path))
    }
}
