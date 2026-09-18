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

    @Test("Board names holding separators, quotes and emoji survive", arguments: [
        "a\u{1e}b", "a\u{1f}b", "\u{1f}", "", "\"quoted\", [brackets]", "水 🌊 board", "comma,semi;colon",
    ])
    func oddBoardNames(name: String) throws {
        let file = try StoreFile(database: DatabaseQueue())
        let boards = [BoardSubscription(fid: 1, name: name), BoardSubscription(fid: 2, name: "plain")]
        try file.save(sources: [Source(host: "forum.example", kind: .discuz, boards: boards)], notes: [])
        #expect(try file.load().sources.first?.boards == boards)
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

@Suite("Opening the index at launch")
struct StoreFileOpenTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let garbage = Data("this is not a database, and it is the reader's only copy".utf8)

    @Test("A healthy index opens with what it held and sets nothing aside")
    func healthy() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "first.example", kind: .mastodon)
        try StoreFile(at: dir).save(sources: [source], notes: [])
        let opened = StoreFile.open(at: dir)
        #expect(opened.file != nil)
        #expect(opened.sources == [source])
        #expect(opened.setAside == nil)
    }

    @Test("A directory with no index opens empty and writable")
    func fresh() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        #expect(opened.file != nil)
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        #expect(opened.setAside == nil)
    }

    @Test("A corrupt index is moved aside, byte for byte, and a save does not touch it")
    func corruptIsSetAside() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = StoreFile.open(at: dir, now: now)
        let aside = try #require(opened.setAside)
        #expect(aside.lastPathComponent == "index-unreadable-20270115T080000Z.sqlite")
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        let file = try #require(opened.file)
        let source = Source(host: "first.example", kind: .mastodon)
        try file.save(sources: [source], notes: [])
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(try StoreFile(at: dir).load().sources == [source])
    }

    @Test("Setting aside twice in one second keeps both copies")
    func twoInOneSecond() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let first = try #require(StoreFile.open(at: dir, now: now).setAside)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let second = try #require(StoreFile.open(at: dir, now: now).setAside)
        #expect(first != second)
        #expect(second.lastPathComponent == "index-unreadable-20270115T080000Z-2.sqlite")
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("An index whose migration fails is set aside, not migrated over")
    func failedMigrationIsSetAside() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A `source` table the migrator did not make: v1 cannot create its own over it.
        try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "CREATE TABLE source (anything TEXT)")
            try db.execute(sql: "INSERT INTO source VALUES ('keep me')")
        }
        let opened = StoreFile.open(at: dir)
        let aside = try #require(opened.setAside)
        let kept = try DatabaseQueue(path: aside.path).read { db in
            try String.fetchOne(db, sql: "SELECT anything FROM source")
        }
        #expect(kept == "keep me")
        #expect(opened.file != nil)
    }

    @Test("A row that cannot be decoded fails the load, and the file is set aside")
    func undecodableRowIsSetAside() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try file.save(sources: [Source(host: "forum.example", kind: .discuz)], notes: [])
        try file.db.write { db in
            try db.execute(sql: "UPDATE source SET boards = 'not json'")
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside != nil)
        #expect(opened.sources.isEmpty)
    }

    @Test("When the directory cannot be made, the run gets no file to save to")
    func noDirectoryNoFile() throws {
        let blocker = scratch()
        defer { try? FileManager.default.removeItem(at: blocker) }
        try garbage.write(to: blocker)
        let opened = StoreFile.open(at: blocker.appendingPathComponent("Fediqo", isDirectory: true))
        #expect(opened.file == nil)
        #expect(opened.setAside == nil)
        #expect(try Data(contentsOf: blocker) == garbage)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
