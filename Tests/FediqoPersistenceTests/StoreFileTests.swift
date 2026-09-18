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
        #expect(loaded.notes[0].handle == "@ada@first.example")
    }

    @Test("Handle, board, boost, reply, and cover survive a save and load")
    func rowFactsRoundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let source = Source(host: "forum.example", kind: .discuz)
        let note = Note(
            id: "discuz:forum.example:1",
            source: source,
            author: "Ada",
            handle: "@ada",
            body: "hello",
            title: "tool",
            board: "tools",
            boardID: "33",
            postedAt: origin,
            origins: [.publicTimeline],
            reply: Reply(handle: "@bob"),
            boostedBy: "Carol",
            sensitive: true,
            spoiler: "cover"
        )
        try file.save(sources: [source], notes: [note])
        let loaded = try file.load().notes[0]
        #expect(loaded.handle == "@ada")
        #expect(loaded.board == "tools")
        #expect(loaded.boardID == "33")
        #expect(loaded.reply?.handle == "@bob")
        #expect(loaded.boostedBy == "Carol")
        #expect(loaded.spoiler == "cover")
        #expect(loaded.sensitive == true)
    }

    @Test("Avatar and attachment hyperlinks survive a save and load")
    func mediaURLsRoundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        let source = Source(host: "first.example", kind: .mastodon)
        let avatar = URL(string: "https://cdn.example/ada.png")!
        let full = URL(string: "https://cdn.example/pic.jpg")!
        let note = Note(
            id: "https://first.example/users/ada/statuses/1",
            source: source,
            author: "Ada",
            handle: "@ada",
            body: "hi",
            postedAt: origin,
            origins: [.publicTimeline],
            avatarURL: avatar,
            attachments: [Attachment(kind: .image, url: full)]
        )
        try file.save(sources: [source], notes: [note])
        let loaded = try file.load().notes[0]
        #expect(loaded.avatarURL == avatar)
        #expect(loaded.attachments.map(\.url) == [full])
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

    @Test("Signed-in hosts survive a save and load")
    func signedInRoundTrip() throws {
        let file = try StoreFile(database: DatabaseQueue())
        try file.saveSignedIn(["forum.example", "other.example"])
        #expect(try file.loadSignedIn() == ["forum.example", "other.example"])
    }
}
