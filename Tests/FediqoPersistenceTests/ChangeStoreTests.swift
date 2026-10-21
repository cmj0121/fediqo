import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A change of a published post waiting to be sent (#332), on disk: which post it changes is
/// kept with it, its files already on the post with them, behind a step of its own — a build
/// that knows nothing of changes would send it as a second post.
@Suite("A change waiting to be sent, on disk")
struct ChangeStoreTests {
    private static let mastodon = PackagerFixture.mastodon

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let change = Unsent(
        host: mastodon.host, text: "changed", audience: .unlisted, pressedAt: PackagerFixture.origin,
        spoiler: "", language: "fr", sensitive: true,
        media: [UnsentMedia(bytes: Data(), mime: "image/*", name: "a.png", description: "two herons", remoteID: "117")],
        changes: Unsent.Changes(item: NoteKey(host: mastodon.host, id: "https://one.example/users/me/statuses/9"), statusID: "9")
    )

    @Test("Quit and open again: the change comes back with the post it changes and its files already on the post; a post waiting comes back changing nothing")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let post = Unsent(host: Self.mastodon.host, text: "new", audience: .everyone, pressedAt: PackagerFixture.origin)
        try await StoreFile(at: dir).save(unsent: [Self.change, post])

        let read = StoreFile.open(at: dir).unsent
        #expect(read == [Self.change, post])
        #expect(read.first?.changes?.statusID == "9" && read.first?.media.first?.remoteID == "117")
        #expect(read.last?.changes == nil)
    }

    @Test("A cell naming the post that will not read is a text not read at all: sent as a post, a change would be a second post")
    func anUnreadableChangeIsNotRead() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(unsent: [Self.change])
        try await file.db.write { db in try db.execute(sql: "UPDATE unsent SET changes = 'nothing it can read'") }
        #expect(try file.loadUnsent().isEmpty)
    }

    @Test("A post given a time comes back with its time; a build that knows no v22-unsent-at sees a store with one as newer, and would not send it at once")
    func aTimeToSendComesBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = Date(timeIntervalSince1970: 1_792_003_600)
        let later = Unsent(host: Self.mastodon.host, text: "later", audience: .everyone, pressedAt: PackagerFixture.origin, at: at)
        try await StoreFile(at: dir).save(unsent: [later])
        let read = try #require(StoreFile.open(at: dir).unsent.first)
        #expect(read == later && read.at == at)
        #expect(try superseded(dir.appendingPathComponent("index.sqlite"), knowingNo: "v22-unsent-at"))
    }

    @Test("A quote waiting to be sent comes back with the post it quotes and who may quote it; a build that knows no v23-unsent-quoting sees a store with one as newer")
    func aQuoteComesBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quoting = Unsent.Changes(item: NoteKey(host: Self.mastodon.host, id: "https://one.example/users/ada/statuses/7"), statusID: "7")
        let quote = Unsent(
            host: Self.mastodon.host, text: "quoting", audience: .everyone, pressedAt: PackagerFixture.origin,
            quoting: quoting, quotePolicy: .followers
        )
        try await StoreFile(at: dir).save(unsent: [quote])
        let read = try #require(StoreFile.open(at: dir).unsent.first)
        #expect(read == quote && read.quoting == quoting && read.quotePolicy == .followers)
        #expect(try superseded(dir.appendingPathComponent("index.sqlite"), knowingNo: "v23-unsent-quoting"))
    }

    @Test("A build that knows no v20-unsent-changes sees a store with a change waiting as newer, and would not send it as a post")
    func aBuildBeforeChangesRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(unsent: [Self.change])
        #expect(try superseded(index, knowingNo: "v20-unsent-changes"))
    }

    /// Asked as `StoreFile` asks: read-only, of a migrator that knows every step this store
    /// records but `id`, which is among them.
    private func superseded(_ index: URL, knowingNo id: String) throws -> Bool {
        let steps = try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(steps.contains(id))
        var older = DatabaseMigrator()
        for step in steps where step != id { older.registerMigration(step) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded)
    }
}
