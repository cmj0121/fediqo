import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// The limits' account beside the index (#251), and the index giving back the room its posts
/// let go of (#249).
@Suite("The limits' account on disk")
struct LimitAccountFileTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let source = Source(host: "alpha.test", kind: .mastodon)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("Lines written are read back by a file opened again on the same folder, newest first")
    func roundTrip() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try LimitAccountFile(directory: dir)
        #expect(file.read().isEmpty, "nothing yet reads as no lines")
        let lines = [
            LimitAct(limit: .room, at: origin.addingTimeInterval(60), posts: 0, copies: 4, sources: ["alpha.test"]),
            LimitAct(limit: .months, at: origin, posts: 2, sources: ["alpha.test", "beta.test"]),
        ]
        try file.write(lines)
        #expect(try LimitAccountFile(directory: dir).read() == lines)
        try file.write([])
        #expect(try LimitAccountFile(directory: dir).read().isEmpty)
    }

    @Test("A file this build cannot read is no lines, and the next write replaces it")
    func unreadableIsEmpty() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try LimitAccountFile(directory: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(LimitAccountFile.name))
        #expect(file.read().isEmpty)
        let line = LimitAct(limit: .months, at: origin, posts: 1, sources: [])
        try file.write([line])
        #expect(file.read() == [line])
    }

    @Test("An index that cannot be read takes its account aside with it")
    func accountGoesAsideWithTheIndex() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not an index".utf8).write(to: dir.appendingPathComponent("index.sqlite"))
        let line = LimitAct(limit: .months, at: origin, posts: 1, sources: ["alpha.test"])
        try LimitAccountFile(directory: dir).write([line])

        let opened = StoreFile.open(at: dir, now: origin)

        let aside = try #require(opened.setAside)
        #expect(opened.file != nil)
        #expect(try LimitAccountFile(directory: dir).read().isEmpty, "the lines stayed beside a fresh index")
        let movedName = aside.deletingPathExtension().lastPathComponent + "-" + LimitAccountFile.name
        let moved = dir.appendingPathComponent(movedName)
        #expect(FileManager.default.fileExists(atPath: moved.path), "the account was not moved beside the index")
    }

    @Test("What the rows weigh falls as they go, before the file does; compacting brings the file down to it")
    func heldFallsBeforeTheFile() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let body = String(repeating: "x", count: 4_000)
        let notes = (0..<100).map { n in
            Note(id: "\(n)", source: source, author: "Ada", handle: "@ada", body: body, postedAt: origin, categories: [.public])
        }
        try await file.save(sources: [source], notes: notes)
        let full = file.bytesOnDisk()
        let held = file.bytesHeld()
        #expect(held > 300_000)
        #expect(held <= full)
        try await file.save(sources: [source], notes: Array(notes.prefix(5)))
        #expect(file.bytesHeld() < held / 4, "the pages in use did not fall with the rows")
        #expect(file.bytesOnDisk() == full, "the file itself does not move until it is rebuilt")
        try await file.compact()
        #expect(file.bytesOnDisk() <= file.bytesHeld() + 8_192)
    }

    @Test("Compacting gives back the room rows let go of, so the measure sees them go")
    func compactShrinks() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let body = String(repeating: "x", count: 4_000)
        let notes = (0..<100).map { n in
            Note(id: "\(n)", source: source, author: "Ada", handle: "@ada", body: body, postedAt: origin, categories: [.public])
        }
        try await file.save(sources: [source], notes: notes)
        let full = file.bytesOnDisk()
        #expect(full > 300_000)
        try await file.save(sources: [source], notes: Array(notes.prefix(5)))
        try await file.compact()
        #expect(file.bytesOnDisk() < full / 4, "the file kept the pages its rows let go of")
        #expect(try file.load().notes.count == 5)
    }
}
