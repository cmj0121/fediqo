import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A link's preview on disk (#335): written with its row and read back by a relaunch, every part
/// as it went in; a cell that will not read costs the row its preview and nothing else; and behind
/// a step of its own (`v19-card`), so a build that knows nothing of it refuses the store.
@Suite("A link's preview, on disk")
struct CardStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let card = PostCard(
        title: "Tom & Jerry <3", description: "What the page is about", provider: "Site", author: "Ada",
        url: URL(string: "https://example.org/page"), image: URL(string: "https://example.org/p.png"),
        width: 64, height: 32, missingAttribution: false
    )

    private static func note(_ id: String, card: PostCard?) -> Note {
        Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "post \(id)",
            postedAt: PackagerFixture.origin, categories: [.home], statusID: id, card: card
        )
    }

    @Test("Quit and open again: each post's preview is as it went in, words and addresses alike, and one with none has none")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bare = PostCard(title: "Only a title")
        let notes = [Self.note("1", card: Self.card), Self.note("2", card: nil), Self.note("3", card: bare)]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == notes)
        #expect(opened.notes[0].card == Self.card && opened.notes[1].card == nil && opened.notes[2].card == bare)
    }

    @Test("A cell that will not read, or names an address this device would not go to, costs the row its preview or that address — never the row, and never the store")
    func aDamagedCell() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: (1...4).map { Self.note("\($0)", card: Self.card) })
        let long = String(repeating: "x", count: PostCard.titleLength * 3)
        let huge = String(repeating: "y", count: 9_000)
        let queue = try DatabaseQueue(path: index.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE note SET card = 'not json' WHERE id = '1'")
            try db.execute(sql: #"UPDATE note SET card = '{"title":"t","url":"javascript:alert(1)","image":"https://u:p@example.org/p.png","width":-3,"height":5}' WHERE id = '2'"#)
            try db.execute(sql: "UPDATE note SET card = ? WHERE id = '3'", arguments: [#"{"title":"\#(long)\nline","description":"a &amp; b"}"#])
            try db.execute(sql: "UPDATE note SET card = ? WHERE id = '4'", arguments: [#"{"title":"\#(huge)"}"#])
        }
        try queue.close()

        let opened = StoreFile.open(at: dir)
        #expect(opened.file != nil && opened.setAside == nil)
        #expect(opened.notes.map(\.id) == ["1", "2", "3", "4"])
        #expect(opened.notes[0].card == nil && opened.notes[0].body == "post 1")
        #expect(opened.notes[1].card == PostCard(title: "t"), "no address it would not go to, and no side alone")
        let bounded = try #require(opened.notes[2].card)
        #expect(bounded.title.count <= PostCard.titleLength + 2 && bounded.title.hasSuffix("…") && !bounded.title.contains("\n"))
        #expect(bounded.description == "a &amp; b", "not decoded a second time")
        #expect(opened.notes[3].card == nil, "a cell past what a card is is not read")
    }

    @Test("A build that knows no v19-card sees this build's store as newer, and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1", card: Self.card)])
        let before = try Data(contentsOf: index)
        let steps = try await DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(steps.contains("v19-card"))
        var older = DatabaseMigrator()
        for step in steps where step != "v19-card" { older.registerMigration(step) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        #expect(try await DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded))
        #expect(try Data(contentsOf: index) == before)
    }
}
