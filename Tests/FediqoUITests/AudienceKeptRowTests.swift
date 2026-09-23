import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// #208 — the audience mark and the counts on a row, after a relaunch: a new `StoreFile` opened on
/// the same folder, and nothing asked of any network, is what a row is drawn from.
@Suite("A row's audience and counts after a relaunch")
struct AudienceKeptRowTests {
    @Test("A row drawn from what a relaunch read carries the audience and counts it was saved with")
    func rowAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "first.example", kind: .mastodon)
        let note = Note(
            id: "1", source: source, author: "Ada", handle: "@ada@first.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            audience: .followers, counts: Counts(replies: 2, reblogs: 1, favourites: 3), statusID: "1"
        )
        try await StoreFile(at: dir).save(sources: [source], notes: [note])
        let row = try #require(StoreFile.open(at: dir).notes.first.map(DummyItem.init))
        #expect(row.audience == .followers)
        #expect(row.counts.replies == 2)
        #expect(row.counts.reblogs == 1)
        #expect(row.counts.favourites == 3)
    }
}
