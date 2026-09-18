import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

@Suite("The on-device index")
struct StoreFileTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let mastodon = Source(host: "first.example", kind: .mastodon)

    private func note(
        id: String = "1",
        source: Source? = nil,
        handle: String = "@ada",
        title: String? = nil,
        board: String? = nil,
        boardID: String? = nil,
        origins: Set<FetchOrigin> = [.publicTimeline],
        reply: Reply? = nil,
        boostedBy: String? = nil,
        avatarURL: URL? = nil,
        attachments: [FediqoCore.Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil
    ) -> Note {
        Note(
            id: id, source: source ?? mastodon, author: "Ada", handle: handle, body: "hello",
            title: title, board: board, boardID: boardID, postedAt: origin, origins: origins,
            reply: reply, boostedBy: boostedBy, avatarURL: avatarURL, attachments: attachments,
            sensitive: sensitive, spoiler: spoiler, emojis: emojis, url: url
        )
    }

    @Test("Sources and slim notes survive a save and load")
    func roundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a")])
        let saved = note(id: "https://first.example/users/ada/statuses/1", origins: [.publicTimeline, .trending])
        try file.save(sources: [mastodon, forum], notes: [saved])
        let loaded = try file.load()
        #expect(loaded.sources == [mastodon, forum])
        #expect(loaded.notes == [saved])
    }

    @Test("A loaded note has every row fact and its multimedia hyperlinks")
    func rowFactsWithMultimedia() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz)
        let picture = URL(string: "https://forum.example/a.png")
        let saved = note(
            source: forum, title: "tool", board: "tools", boardID: "33",
            reply: Reply(handle: "@bob"), boostedBy: "Carol",
            avatarURL: picture, attachments: [FediqoCore.Attachment(kind: .image, url: picture)],
            sensitive: true, spoiler: "cover"
        )
        try file.save(sources: [forum], notes: [saved])
        #expect(try file.load().notes == [saved])
    }

    @Test("A reply whose parent's handle is unknown comes back a reply")
    func replyWithoutHandle() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = [note(id: "1", reply: Reply(handle: nil)), note(id: "2")]
        try file.save(sources: [mastodon], notes: saved)
        #expect(Set(try file.load().notes) == Set(saved))
    }

    @Test("Unset sensitive and spoiler stay unset, apart from false and empty", arguments: [
        (Bool?.none, String?.none), (false, ""), (true, "cover"),
    ])
    func unsetStaysUnset(sensitive: Bool?, spoiler: String?) throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = note(sensitive: sensitive, spoiler: spoiler)
        try file.save(sources: [mastodon], notes: [saved])
        #expect(try file.load().notes == [saved])
    }

    @Test("Row facts survive a relaunch on the same directory")
    func rowFactsSurviveRelaunch() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = note(board: "tools", boardID: "33", reply: Reply(handle: nil), boostedBy: "Carol", sensitive: true, spoiler: "")
        try StoreFile(at: dir).save(sources: [mastodon], notes: [saved])
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.notes == [saved])
    }

    @Test("A note whose host has no source row is dropped on load")
    func orphanDropped() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let kept = note(id: "1")
        let orphan = note(id: "2", source: Source(host: "gone.example", kind: .mastodon))
        try file.save(sources: [mastodon], notes: [kept, orphan])
        #expect(try file.load().notes == [kept])
    }

    @Test("A note takes its source, boards and all, from the source row")
    func sourceFromRow() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        try file.save(sources: [forum], notes: [note(source: Source(host: "forum.example", kind: .discuz))])
        #expect(try file.load().notes.first?.source == forum)
    }

    /// Every field an attachment and an emoji carry, a picture with only a preview among them:
    /// what a row drew before a relaunch — the alt text, the shape it reserved — is what it draws
    /// after.
    private var multimedia: Note {
        note(
            avatarURL: URL(string: "https://cdn.example/ada.png"),
            attachments: [
                FediqoCore.Attachment(
                    kind: .image,
                    url: URL(string: "https://cdn.example/pic.jpg"),
                    previewURL: URL(string: "https://cdn.example/pic-small.jpg"),
                    alt: "a cat on a mat",
                    width: 1200,
                    height: 800
                ),
                FediqoCore.Attachment(kind: .video, previewURL: URL(string: "https://cdn.example/clip.jpg")),
                FediqoCore.Attachment(kind: .unknown, url: URL(string: "https://cdn.example/file.bin"), alt: "",
                                      width: 0, height: 5),
            ],
            emojis: [
                CustomEmoji(shortcode: "blobcat", url: URL(string: "https://cdn.example/blobcat.gif")!,
                            staticURL: URL(string: "https://cdn.example/blobcat.png")),
                CustomEmoji(shortcode: "ok", url: URL(string: "https://cdn.example/ok.png")!),
            ],
            url: URL(string: "https://first.example/@ada/1")
        )
    }

    @Test("Every attachment field, every emoji, and the post's address survive a save and load")
    func multimediaRoundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = multimedia
        try file.save(sources: [mastodon], notes: [saved])
        let loaded = try #require(try file.load().notes.first)
        #expect(loaded == saved)
        // Spelled out, so a `==` that stopped comparing a field could not pass this quietly.
        #expect(loaded.attachments.map(\.alt) == ["a cat on a mat", "", ""])
        #expect(loaded.attachments.map(\.width) == [1200, nil, nil])
        #expect(loaded.attachments.map(\.height) == [800, nil, nil])
        #expect(loaded.attachments.map(\.kind) == [.image, .video, .unknown])
        #expect(loaded.attachments[1].url == nil)
        #expect(loaded.attachments[1].previewURL == URL(string: "https://cdn.example/clip.jpg"))
        #expect(loaded.emojis.map(\.staticURL) == [URL(string: "https://cdn.example/blobcat.png"), nil])
        #expect(loaded.url == URL(string: "https://first.example/@ada/1"))
        #expect(loaded.avatarURL == URL(string: "https://cdn.example/ada.png"))
    }

    @Test("A note with no multimedia comes back with none")
    func noMultimedia() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = note()
        try file.save(sources: [mastodon], notes: [saved])
        let loaded = try #require(try file.load().notes.first)
        #expect(loaded.attachments.isEmpty && loaded.emojis.isEmpty)
        #expect(loaded.avatarURL == nil && loaded.url == nil)
    }

    @Test("Multimedia survives a relaunch on the same directory")
    func multimediaSurvivesRelaunch() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try StoreFile(at: dir).save(sources: [mastodon], notes: [multimedia])
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.notes == [multimedia])
    }

    @Test("Two sources carrying the same id stay two rows")
    func twoSourcesTwoRows() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let one = Source(host: "a.example", kind: .mastodon)
        let two = Source(host: "b.example", kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        let saved = [note(id: uri, source: one), note(id: uri, source: two, origins: [.trending])]
        try file.save(sources: [one, two], notes: saved)
        #expect(Set(try file.load().notes) == Set(saved))
    }

    @Test("A directory is excluded from backup")
    func excludedFromBackup() throws {
        let dir = scratch()
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
        let saved = note(id: "tid-7", source: forum, title: "A thread", origins: [.trending])
        try file.save(sources: [forum], notes: [saved])
        let loaded = try file.load()
        #expect(loaded.notes == [saved])
        #expect(loaded.sources.first?.kind == .discuz)
    }

    @Test("A note seen in no list comes back seen in no list")
    func emptyOrigins() throws {
        let file = try StoreFile(database: DatabaseQueue())
        try file.save(sources: [mastodon], notes: [note(origins: [])])
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
        let saved = note(source: source, origins: [.trending])
        try StoreFile(at: dir).save(sources: [source], notes: [saved])
        let again = try StoreFile(at: dir)
        let loaded = try again.load()
        #expect(loaded.sources == [source])
        #expect(loaded.notes == [saved])
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
        #expect(aside.lastPathComponent.hasPrefix("index-unreadable-20270115T080000"))
        #expect(aside.pathExtension == "sqlite")
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        let file = try #require(opened.file)
        let source = Source(host: "first.example", kind: .mastodon)
        try file.save(sources: [source], notes: [])
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(try StoreFile(at: dir).load().sources == [source])
    }

    @Test("Two indexes set aside at the same moment get two names, and both are kept")
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
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
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
