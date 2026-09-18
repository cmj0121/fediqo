import Foundation
import Testing
@testable import FediqoPersistence

@Suite("Multimedia copies")
struct MediaCacheTests {
    @Test("A copy is still there, and forget drops that host only")
    func storeAndForget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        let url = URL(string: "https://cdn.example/pic.jpg")!
        try cache.store(Data("pic".utf8), host: "a.example", url: url)
        try cache.store(Data("other".utf8), host: "b.example", url: url)
        #expect(cache.data(host: "a.example", url: url) == Data("pic".utf8))
        #expect(cache.bytes(host: "a.example") > 0)
        try cache.forget(host: "a.example")
        #expect(cache.data(host: "a.example", url: url) == nil)
        #expect(cache.data(host: "b.example", url: url) == Data("other".utf8))
    }
}
