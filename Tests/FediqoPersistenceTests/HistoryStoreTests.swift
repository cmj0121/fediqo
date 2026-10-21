import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// What a changed post said before as its source keeps it (#332), on disk: the change it was
/// asked for is written with the row, so a relaunch owes nothing already answered — and a row
/// written before says it was never asked, and owes one ask.
@Suite("A changed post's history, on disk")
struct HistoryStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private static func changed(_ id: String, historyAt: Date?) -> Note {
        let base = PackagerFixture.note(id)
        let editedAt = Date(timeIntervalSince1970: 1_792_000_000.123)
        return Note(
            id: base.id, source: base.source, author: base.author, handle: base.handle, body: "now",
            postedAt: base.postedAt, categories: base.categories, statusID: id, editedAt: editedAt,
            earlier: [Wording(body: "before", until: editedAt)], historyAt: historyAt
        )
    }

    @Test("The change a row's history was answered for is read back by a relaunch, which owes nothing of it; a row never asked still owes")
    func readBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let answered = Self.changed("1", historyAt: Date(timeIntervalSince1970: 1_792_000_000.123))
        let never = Self.changed("2", historyAt: nil)
        let opened = StoreFile.open(at: dir)
        try await #require(opened.file).save(sources: [Self.mastodon], notes: [answered, never])

        let again = StoreFile.open(at: dir)
        let byID = Dictionary(uniqueKeysWithValues: again.notes.map { ($0.id, $0) })
        #expect(byID["1"]?.historyAt.map { ($0.timeIntervalSince1970 * 1000).rounded() } == 1_792_000_000_123)
        #expect(byID["1"]?.historyOwed == false && byID["2"]?.historyOwed == true)
        #expect(byID["1"]?.earlier == answered.earlier)
        let store = ItemStore(sources: again.sources, notes: again.notes)
        #expect(await store.historyOwed(host: Self.mastodon.host).map(\.item.id) == ["2"])
    }
}
