import Foundation
import Testing

@testable import FediqoPersistence

@Suite("The forum cookie store, out of backups")
struct ForumWebsiteDataTests {
    @Test("The store's directory is where WebKit keeps it, inside a sandbox and outside one")
    func directories() {
        let library = URL(fileURLWithPath: "/L", isDirectory: true)
        let id = ForumWebsiteData.identifier.uuidString.lowercased()
        let inside = ForumWebsiteData.directories(library: library, sandboxed: true, bundleID: "b.id")
        #expect(inside.root.path == "/L/WebKit")
        #expect(inside.store.path == "/L/WebKit/WebsiteDataStore/\(id)")
        // Outside a sandbox `~/Library/WebKit` is every unsandboxed app's, and is not marked.
        let outside = ForumWebsiteData.directories(library: library, sandboxed: false, bundleID: "b.id")
        #expect(outside.root.path == "/L/WebKit/b.id")
        #expect(outside.store.path == "/L/WebKit/b.id/WebsiteDataStore/\(id)")
    }

    @Test("WebKit's lower-case spelling of the id is the one used", arguments: [true, false])
    func lowerCase(sandboxed: Bool) {
        let store = ForumWebsiteData.directories(
            library: URL(fileURLWithPath: "/L"), sandboxed: sandboxed, bundleID: "b"
        ).store
        #expect(store.lastPathComponent == store.lastPathComponent.lowercased())
    }

    @Test("Both directories are made and marked out of backups, and marking again is harmless")
    func marked() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        try ForumWebsiteData.markOutOfBackups(library: library, sandboxed: true, bundleID: "b.id")
        try ForumWebsiteData.markOutOfBackups(library: library, sandboxed: true, bundleID: "b.id")
        let found = ForumWebsiteData.directories(library: library, sandboxed: true, bundleID: "b.id")
        for directory in [found.root, found.store] {
            #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }
}
