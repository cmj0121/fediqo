import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// Who may quote a post, and how many do (#330), on disk: written with its row and read back by a
/// relaunch; a cell that will not read costs the row that word alone; and behind a step of its own
/// (`v21-quotes`), so a build that knows nothing of it refuses the store.
@Suite("Who may quote a post, on disk")
struct QuoteApprovalStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func note(_ id: String, approval: QuoteApproval?, quotes: Int?, may: QuoteApproval.Reader? = nil) -> Note {
        var note = Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "post \(id)", postedAt: PackagerFixture.origin,
            categories: [.home], counts: Counts(reblogs: 1, quotes: quotes), statusID: id, quoteApproval: approval, mayQuote: may
        )
        note.asked = .now()
        return note
    }

    @Test("Quit and open again: who may quote each post, the reader's word and how many quote it are as they went in; one that said nothing says nothing")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = [
            Self.note("1", approval: QuoteApproval(automatic: ["public"]), quotes: 2, may: .automatic),
            Self.note("2", approval: QuoteApproval(automatic: ["followers"], manual: ["public"]), quotes: 0, may: .manual),
            Self.note("3", approval: nil, quotes: nil),
        ]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.counts.quotes) == [2, 0, nil])
        #expect(opened.notes.map(\.mayQuote) == [.automatic, .manual, nil])
    }

    @Test("A sign-in that ended takes the reader's word on quoting off the file — a row read in or not — and leaves who may quote")
    func theFileForgetsTheReader() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [Self.note("1", approval: QuoteApproval(automatic: ["public"]), quotes: 1, may: .automatic)])
        try await file.makeIndexes()
        let store = ItemStore(sources: [Self.mastodon], rows: file)
        #expect(await store.forgetReaderMarks(host: Self.mastodon.host))
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
        let read = try #require(StoreFile.open(at: dir).notes.first)
        #expect(read.mayQuote == nil && read.quoteApproval == QuoteApproval(automatic: ["public"]))
    }

    @Test("A cell that will not read costs the row who may quote it and nothing else; a reader's word this build does not know is no word")
    func aDamagedCell() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let approval = QuoteApproval(automatic: ["public"])
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1", approval: approval, quotes: 1), Self.note("2", approval: approval, quotes: 1, may: .automatic)])
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE note SET quote_approval = 'not json' WHERE id = '1'")
            try db.execute(sql: "UPDATE note SET may_quote = 'someday' WHERE id = '2'")
            let long = String(repeating: "x", count: 40)
            try db.execute(sql: "UPDATE note SET quote_approval = ? WHERE id = '2'", arguments: [#"{"automatic":["public","","\#(long)"],"manual":[""]}"#])
        }
        try queue.close()
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.map(\.id) == ["1", "2"] && opened.setAside == nil)
        #expect(opened.notes[0].quoteApproval == nil && opened.notes[0].counts.quotes == 1)
        #expect(opened.notes[1].mayQuote == nil && opened.notes[1].quoteApproval == approval, "held to the wire's filter")
    }

    @Test("A build that knows no v21-quotes sees this build's store as newer, and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1", approval: nil, quotes: 3)])
        let before = try Data(contentsOf: index)
        let steps = try await DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(steps.contains("v21-quotes"))
        var older = DatabaseMigrator()
        for step in steps where step != "v21-quotes" { older.registerMigration(step) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        #expect(try await DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded))
        #expect(try Data(contentsOf: index) == before)
    }
}
