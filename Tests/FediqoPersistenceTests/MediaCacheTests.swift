import Foundation
import Testing
@testable import FediqoPersistence

@Suite("Multimedia copies")
struct MediaCacheTests {
    private let url = URL(string: "https://cdn.example/pic.jpg")!

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("A copy is still there, and forget drops that host only")
    func storeAndForget() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        try cache.store(Data("pic".utf8), host: "a.example", url: url)
        try cache.store(Data("other".utf8), host: "b.example", url: url)
        #expect(cache.data(host: "a.example", url: url) == Data("pic".utf8))
        #expect(cache.bytes(host: "a.example") == 3)
        cache.forget(host: "a.example")
        #expect(cache.data(host: "a.example", url: url) == nil)
        #expect(cache.bytes(host: "a.example") == 0)
        #expect(cache.data(host: "b.example", url: url) == Data("other".utf8))
    }

    @Test("An address never kept is a miss, and so is a host never kept")
    func miss() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        try cache.store(Data("pic".utf8), host: "a.example", url: url)
        #expect(cache.data(host: "a.example", url: URL(string: "https://cdn.example/other.jpg")!) == nil)
        #expect(cache.data(host: "b.example", url: url) == nil)
        cache.forget(host: "never.example")
    }

    @Test("A copy too large for any picture is not read back")
    func tooLarge() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        try cache.store(Data(count: MediaCache.maxBytes + 1), host: "a.example", url: url)
        #expect(cache.data(host: "a.example", url: url) == nil)
    }

    @Test("Remove drops one copy and leaves the rest")
    func removeOne() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        let other = URL(string: "https://cdn.example/other.jpg")!
        try cache.store(Data("pic".utf8), host: "a.example", url: url)
        try cache.store(Data("other".utf8), host: "a.example", url: other)
        cache.remove(host: "a.example", url: url)
        cache.remove(host: "a.example", url: url)
        #expect(cache.data(host: "a.example", url: url) == nil)
        #expect(cache.data(host: "a.example", url: other) == Data("other".utf8))
    }

    @Test("Keep-only drops every host not named, whatever its spelling")
    func keepOnly() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        for host in ["a.example", "b.example", "c.example"] {
            try cache.store(Data(host.utf8), host: host, url: url)
        }
        cache.keepOnly(hosts: ["A.example", "c.example"])
        #expect(cache.data(host: "a.example", url: url) == Data("a.example".utf8))
        #expect(cache.data(host: "b.example", url: url) == nil)
        #expect(cache.data(host: "c.example", url: url) == Data("c.example".utf8))
        cache.keepOnly(hosts: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("Two spellings of one host are one folder")
    func hostFolded() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        try cache.store(Data("pic".utf8), host: "A.Example", url: url)
        #expect(cache.data(host: "a.example", url: url) == Data("pic".utf8))
    }

    @Test("A copy survives a relaunch on the same directory")
    func relaunch() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try MediaCache(directory: dir).store(Data("pic".utf8), host: "a.example", url: url)
        #expect(try MediaCache(directory: dir).data(host: "a.example", url: url) == Data("pic".utf8))
    }

    @Test("The directory is excluded from backup")
    func excludedFromBackup() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        let values = try cache.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("The app's cache lives under Caches")
    func underCaches() throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = try MediaCache.caches()
        #expect(cache.directory.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path))
        #expect(cache.directory.lastPathComponent == "media")
    }

    /// A host is whatever a server, or a reader's typing, said it was. None of these may name a
    /// folder anywhere but inside the cache, so a `forget` of one deletes nothing outside it.
    @Test("No host reaches outside the cache", arguments: ["", ".", "..", "../..", "a/../..", "/", "a/b"])
    func hostCannotEscape(host: String) throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("media/inner", isDirectory: true)
        let cache = try MediaCache(directory: dir)
        let sibling = root.appendingPathComponent("media/keep.txt")
        let outside = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        try Data("keep".utf8).write(to: outside)
        try cache.store(Data("other".utf8), host: "a.example", url: url)

        #expect(cache.folder(for: host).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        try cache.store(Data("pic".utf8), host: host, url: url)
        #expect(cache.data(host: host, url: url) == Data("pic".utf8))
        cache.forget(host: host)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(cache.data(host: "a.example", url: url) == Data("other".utf8))
        #expect(cache.data(host: host, url: url) == nil)
    }
}
