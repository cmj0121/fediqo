import Foundation
import Testing
@testable import FediqoCore

/// What the store says about itself: what it holds, how far back it goes, and how much room
/// it takes — the exact numbers exactly, and the split between sources as the estimate it is.
@Suite("What the store is keeping")
struct StoreStatisticsTests {
    private let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
    private let two = Server(host: "two.example", socialProtocol: .mastodon, title: "Two")

    @Test("The count is every post, and the oldest date is the oldest post's")
    func countsAndOldest() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([
            makePost(uri: "https://one.example/3", at: 3_000, from: "one.example"),
            makePost(uri: "https://one.example/1", at: 1_000, from: "one.example"),
            makePost(uri: "https://one.example/2", at: 2_000, from: "one.example"),
        ], from: one)

        let statistics = try await store.statistics()

        #expect(statistics.posts == 3)
        #expect(statistics.oldestPostedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Each source's share is its own bytes over everybody's, and the shares are the whole")
    func sharesSumToOne() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([
            makePost(uri: "https://one.example/1", at: 1_000, from: "one.example", text: String(repeating: "a", count: 400)),
        ], from: one)
        try await store.save([
            makePost(uri: "https://two.example/1", at: 1_100, from: "two.example", text: "short"),
            makePost(uri: "https://two.example/2", at: 1_200, from: "two.example", text: "short"),
        ], from: two)

        let statistics = try await store.statistics()
        let whole = statistics.bySource.reduce(Int64(0)) { $0 + $1.contentBytes }

        #expect(statistics.bySource.map(\.host) == ["one.example", "two.example"])
        #expect(whole > 0)
        for source in statistics.bySource {
            #expect(abs(source.share - Double(source.contentBytes) / Double(whole)) < 0.000_001)
        }
        #expect(abs(statistics.bySource.reduce(0) { $0 + $1.share } - 1) < 0.000_001)
    }

    @Test("A post in Chinese is counted in the bytes it takes, not the characters it has")
    func bytesNotCharacters() async throws {
        let store = try LocalStore.inMemory()
        // Six characters, and eighteen bytes of UTF-8 — the difference this test exists for.
        try await store.save([makePost(uri: "https://one.example/1", at: 1_000, text: "今天天氣很好")], from: one)

        let statistics = try await store.statistics()
        // The text, the address it came from, and the empty JSON array `media_urls` always
        // holds. Nothing else on this post is written at all.
        let expected = 18 + "https://one.example/1".utf8.count + "[]".utf8.count

        #expect(statistics.bySource.count == 1)
        #expect(statistics.bySource[0].contentBytes == Int64(expected))
    }

    @Test("An empty store answers with zeroes, no oldest date, and nothing divided by nothing")
    func emptyStore() async throws {
        let store = try LocalStore.inMemory()

        let statistics = try await store.statistics()

        #expect(statistics.posts == 0)
        #expect(statistics.oldestPostedAt == nil)
        #expect(statistics.bySource.isEmpty)
    }

    @Test("A store with no file weighs nothing on disk, and says nothing rather than zero")
    func inMemoryHasNoFile() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://one.example/1", at: 1_000)], from: one)

        let statistics = try await store.statistics()

        #expect(statistics.diskBytes == nil)
        #expect(statistics.bySource.count == 1)
        #expect(statistics.bySource[0].contentBytes > 0)
        #expect(statistics.bySource[0].estimatedBytes == nil)
    }

    @Test("A store in a file weighs what the file weighs, and the estimates divide that")
    func onDisk() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try LocalStore(path: path)
        try await store.save([makePost(uri: "https://one.example/1", at: 1_000, from: "one.example")], from: one)
        try await store.save([makePost(uri: "https://two.example/1", at: 1_100, from: "two.example")], from: two)

        let statistics = try await store.statistics()
        let disk = try #require(statistics.diskBytes)
        let estimated = statistics.bySource.compactMap(\.estimatedBytes).reduce(Int64(0), +)
        let database = try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)

        // The database and its write-ahead log together, so never smaller than the database.
        #expect(disk >= database.int64Value)
        // Rounding is the only thing between the parts and the whole; one byte a source is
        // the most it can cost.
        #expect(abs(estimated - disk) <= Int64(statistics.bySource.count))
    }
}
