import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// Whom a post's source says it mentions, kept on this device with the row — #310.
@Suite("Whom a post mentions, kept with its row")
struct MentionStoreTests {
    private let source = Source(host: "one.example", kind: .mastodon)

    private func note(_ id: String, mentions: [String]) -> Note {
        Note(
            id: "https://one.example/users/bob/statuses/\(id)", source: source, author: "Bob",
            handle: "@bob@one.example", body: "@ada and @cyd", postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.public], mentions: mentions, statusID: id
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("Whom a post mentions comes back after a relaunch, in the order listed; a post that mentions nobody comes back so")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let listed = ["@ada@one.example", "@cyd@two.example"]
        try await StoreFile(at: dir).save(sources: [source], notes: [note("1", mentions: listed), note("2", mentions: [])])
        let byID = Dictionary(uniqueKeysWithValues: StoreFile.open(at: dir).notes.map { ($0.statusID, $0) })
        #expect(byID["1"]?.mentions == listed)
        #expect(byID["2"]?.mentions == [])
        #expect(byID["1"] == note("1", mentions: listed), "and nothing else of the row moved")
    }
}
