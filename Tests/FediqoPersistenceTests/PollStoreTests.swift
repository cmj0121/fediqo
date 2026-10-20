import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A post's poll on disk (#331): written with its row and read back by a relaunch, the reader's
/// vote taken off the file with their other marks when their sign-in ends, and a poll waiting to
/// go with a post kept beside it, behind a step of its own.
@Suite("A poll, on disk")
struct PollStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let voted = Poll(
        id: "34830", choices: [.init(title: "Tea", votes: 6), .init(title: "Coffee", votes: 4)],
        multiple: true, endsAt: Date(timeIntervalSince1970: 2_000_000_000), votes: 10, voters: 9,
        voted: true, ownVotes: [1]
    )

    private static func note(_ id: String, poll: Poll?) -> Note {
        var note = Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "which \(id)?",
            postedAt: PackagerFixture.origin, categories: [.public], statusID: id, poll: poll
        )
        note.asked = .now()
        return note
    }

    @Test("Quit and open again: each post's poll is as its source last said it — the figures, when it ends, and the reader's vote — and one with none has none")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hidden = Poll(id: "40001", choices: [.init(title: "Mon", votes: nil), .init(title: "Fri", votes: nil)], expired: true)
        let notes = [Self.note("1", poll: Self.voted), Self.note("2", poll: nil), Self.note("3", poll: hidden)]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == notes)
        #expect(opened.notes[0].poll == Self.voted)
        #expect(opened.notes[1].poll == nil)
        #expect(opened.notes[2].poll?.countsHidden == true && opened.notes[2].poll?.expired == true)
    }

    @Test("A poll ending at a moment with its milliseconds reads back as the same moment, so the same copy read again after a relaunch changes nothing")
    func theEndIsTheSameMoment() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // As the wire spells it, and as a decoder reads it: a moment that is no whole second.
        let ends = try #require(ISO8601DateFormatter.fractional.date(from: "2036-10-20T08:00:00.123Z"))
        let poll = Poll(id: "34830", choices: Self.voted.choices, endsAt: ends, votes: 10)
        let copy = Self.note("1", poll: poll)
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [copy])

        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.first?.poll?.endsAt == ends)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let before = await store.revision
        await store.ingest([Self.note("1", poll: poll)], ifSourceHere: Self.mastodon.host)
        #expect(await store.refresh([Self.note("1", poll: poll)], ifSourceHere: Self.mastodon.host) == false)
        #expect(await store.revision == before, "the same poll read again was taken for a change")
    }

    @Test("A sign-in that ended takes the reader's vote off a poll on the file — a row read in or not — and leaves how the poll stands")
    func theFileForgetsTheVote() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [Self.note("1", poll: Self.voted), Self.note("2", poll: nil)])
        try await file.makeIndexes()
        let store = ItemStore(sources: [Self.mastodon], rows: file)
        #expect(await store.forgetReaderMarks(host: Self.mastodon.host))
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)

        let poll = try #require(StoreFile.open(at: dir).notes.first { $0.id == "1" }?.poll)
        #expect(poll.voted == nil && poll.ownVotes.isEmpty)
        #expect(poll.choices == Self.voted.choices && poll.votes == 10)
    }

    @Test("A poll waiting to go with a post comes back with it, every choice as typed")
    func anUnsentPollComesBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = Unsent(
            host: Self.mastodon.host, text: "which?", audience: .everyone, pressedAt: PackagerFixture.origin,
            poll: NewPoll(choices: ["Tea ", "", "Coffee"], multiple: true, runs: 3600, hidesTotals: true)
        )
        try await StoreFile(at: dir).save(unsent: [waiting])

        let read = try #require(StoreFile.open(at: dir).unsent.first)
        #expect(read == waiting)
        #expect(read.poll?.choices == ["Tea ", "", "Coffee"] && read.poll?.said == ["Tea", "Coffee"])
    }

    @Test("A build that knows no v16-poll sees a store with a poll waiting as newer, and would not send the post without it")
    func aBuildBeforePollsRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(unsent: [Unsent(
            host: Self.mastodon.host, text: "which?", audience: .everyone, poll: NewPoll(choices: ["a", "b"])
        )])
        #expect(try superseded(index, knowingNo: "v16-poll"))
    }

    /// Asked as `StoreFile` asks: read-only, of a migrator that knows every step this store
    /// records but `id` — and that it is the last.
    private func superseded(_ index: URL, knowingNo id: String) throws -> Bool {
        let steps = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(steps.last == id)
        var older = DatabaseMigrator()
        for step in steps where step != id { older.registerMigration(step) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded)
    }
}

private extension ISO8601DateFormatter {
    /// A moment spelled to the millisecond, as a source spells one.
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
