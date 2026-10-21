import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// Whether the reader pinned a post and quieted its conversation (#334), on disk: written with its
/// row as the source last said it — yes, no, or nothing — read back by a relaunch, taken off the
/// file with the reader's other marks when their sign-in ends, and behind a step of its own
/// (`v18-standing`) so a build that knows nothing of it refuses the store.
@Suite("A pin and a quieted conversation, on disk")
struct StandingStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func note(_ id: String, pinned: Bool?, muted: Bool?) -> Note {
        var note = Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "post \(id)",
            postedAt: PackagerFixture.origin, categories: [.home], pinned: pinned, muted: muted, statusID: id
        )
        note.asked = .now()
        return note
    }

    private static let notes = [
        note("1", pinned: true, muted: false), note("2", pinned: nil, muted: true), note("3", pinned: false, muted: nil),
        note("4", pinned: nil, muted: nil),
    ]

    @Test("Quit and open again: each post's pin and quiet are as its source last said them, nothing included")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: Self.notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == Self.notes)
        #expect(opened.notes.map(\.pinned) == [true, nil, false, nil])
        #expect(opened.notes.map(\.muted) == [false, true, nil, nil])
    }

    @Test("A sign-in that ended takes both words off the file — a row read in or not — and leaves the post")
    func theFileForgetsThem() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: Self.notes)
        try await file.makeIndexes()
        let store = ItemStore(sources: [Self.mastodon], rows: file)
        #expect(await store.forgetReaderMarks(host: Self.mastodon.host))
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)

        let opened = StoreFile.open(at: dir).notes
        #expect(opened.map(\.id) == ["1", "2", "3", "4"])
        #expect(opened.allSatisfy { $0.pinned == nil && $0.muted == nil })
        #expect(opened.map(\.body) == Self.notes.map(\.body))
    }

    @Test("A build that knows no v18-standing sees this build's store as newer, and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: Self.notes)
        let before = try Data(contentsOf: index)
        let steps = try await DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(steps.last == "v18-standing")
        var older = DatabaseMigrator()
        for step in steps where step != "v18-standing" { older.registerMigration(step) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        #expect(try await DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded))
        #expect(try Data(contentsOf: index) == before)
    }
}
