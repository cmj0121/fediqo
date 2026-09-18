import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

@Suite("The on-device index")
struct StoreFileTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Sources and slim notes survive a save and load")
    func roundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let source = Source(host: "first.example", kind: .mastodon)
        let forum = Source(
            host: "forum.example",
            kind: .discuz,
            boards: [BoardSubscription(fid: 33, name: "a")]
        )
        let note = Note(
            id: "https://first.example/users/ada/statuses/1",
            source: source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "hello",
            title: nil,
            postedAt: origin,
            origins: [.publicTimeline, .trending]
        )
        try file.save(sources: [source, forum], notes: [note])
        let loaded = try file.load()
        #expect(loaded.sources.map(\.host) == ["first.example", "forum.example"])
        #expect(loaded.sources.last?.boards.map(\.fid) == [33])
        #expect(loaded.notes.count == 1)
        #expect(loaded.notes[0].id == note.id)
        #expect(loaded.notes[0].source.host == "first.example")
        #expect(loaded.notes[0].author == "Ada")
        #expect(loaded.notes[0].body == "hello")
        #expect(loaded.notes[0].origins == [.publicTimeline, .trending])
        #expect(loaded.notes[0].postedAt == origin)
    }

    @Test("Two sources carrying the same id stay two rows")
    func twoSourcesTwoRows() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let one = Source(host: "a.example", kind: .mastodon)
        let two = Source(host: "b.example", kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        try file.save(
            sources: [one, two],
            notes: [
                Note(id: uri, source: one, author: "Ada", handle: "", body: "a", postedAt: origin, origins: [.publicTimeline]),
                Note(id: uri, source: two, author: "Ada", handle: "", body: "b", postedAt: origin, origins: [.trending]),
            ]
        )
        let loaded = try file.load()
        #expect(loaded.notes.count == 2)
        #expect(Set(loaded.notes.map(\.source.host)) == ["a.example", "b.example"])
    }

    @Test("A directory is excluded from backup")
    func excludedFromBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try StoreFile(at: dir)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("An empty index loads as nothing")
    func emptyLoad() throws {
        let loaded = try StoreFile(database: DatabaseQueue()).load()
        #expect(loaded.sources.isEmpty)
        #expect(loaded.notes.isEmpty)
    }

    @Test("A title and the source's kind come back")
    func titleAndKind() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz)
        let note = Note(
            id: "tid-7", source: forum, author: "Ada", handle: "", body: "b",
            title: "A thread", postedAt: origin, origins: [.trending]
        )
        try file.save(sources: [forum], notes: [note])
        let loaded = try file.load()
        #expect(loaded.notes.first?.title == "A thread")
        #expect(loaded.notes.first?.source.kind == .discuz)
        #expect(loaded.sources.first?.kind == .discuz)
    }

    @Test("A note seen in no list comes back seen in no list")
    func emptyOrigins() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let source = Source(host: "first.example", kind: .mastodon)
        let note = Note(id: "1", source: source, author: "Ada", handle: "", body: "b", postedAt: origin, origins: [])
        try file.save(sources: [source], notes: [note])
        #expect(try file.load().notes.first?.origins == [])
    }

    @Test("A second StoreFile on the same directory reads what the first saved")
    func reopenSameDirectory() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        let note = Note(id: "1", source: source, author: "Ada", handle: "", body: "b", postedAt: origin, origins: [.trending])
        try StoreFile(at: dir).save(sources: [source], notes: [note])
        let again = try StoreFile(at: dir)
        let loaded = try again.load()
        #expect(loaded.sources == [source])
        #expect(loaded.notes.map(\.key) == [note.key])
        try again.save(sources: [], notes: [])
        #expect(try StoreFile(at: dir).load().sources.isEmpty)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
