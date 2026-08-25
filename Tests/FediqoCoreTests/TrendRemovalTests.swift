import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// A trending list is evidence about the posts on it and about the posts that have left it.
/// What it is never evidence about is a server nobody asked.
@Suite("Falling off a trending list")
struct TrendRemovalTests {
    private func marked(_ store: LocalStore) async throws -> [(key: String, removed: Int64?)] {
        try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT merge_key, removed_at FROM server_trends ORDER BY merge_key")
                .map { ($0["merge_key"] as String, $0["removed_at"] as Int64?) }
        }
    }

    @Test("A post the next list does not carry is marked as having left it")
    func leavingIsWrittenDown() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let first = makePost(uri: "https://one.example/1", at: 100)
        let second = makePost(uri: "https://one.example/2", at: 200)
        try await store.save([first, second], from: server, into: .trend)
        try await store.recordTrending([first, second], from: server)
        try await store.recordTrending([second], from: server, now: Date(timeIntervalSince1970: 9_000))

        let rows = try await marked(store)
        #expect(rows.first { $0.key == first.mergeKey }?.removed == 9_000_000)
        #expect(rows.first { $0.key == second.mergeKey }?.removed == nil)
    }

    @Test("A post back on the list rises again rather than becoming a second row")
    func comingBackLiftsTheMark() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let post = makePost(uri: "https://one.example/1", at: 100)
        let other = makePost(uri: "https://one.example/2", at: 200)
        try await store.save([post, other], from: server, into: .trend)
        try await store.recordTrending([post], from: server)
        try await store.recordTrending([other], from: server)
        try await store.recordTrending([post], from: server)

        let rows = try await marked(store)
        #expect(rows.count == 2)
        #expect(rows.first { $0.key == post.mergeKey }?.removed == nil)
    }

    @Test("An empty list decides nothing, because a server that said nothing said nothing")
    func nothingArrivingMarksNothing() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let post = makePost(uri: "https://one.example/1", at: 100)
        try await store.save([post], from: server, into: .trend)
        try await store.recordTrending([post], from: server)
        try await store.recordTrending([], from: server)

        #expect(try await marked(store).allSatisfy { $0.removed == nil })
    }

    @Test("What has left the list is not what the reader is shown")
    func aRemovedPostLeavesTheTimeline() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let gone = makePost(uri: "https://one.example/1", at: 100)
        let rising = makePost(uri: "https://one.example/2", at: 200)
        try await store.save([gone, rising], from: server, into: .trend)
        try await store.recordTrending([gone, rising], from: server)
        try await store.recordTrending([rising], from: server)

        let shown = try await store.timeline(matching: TimelineQuery(source: .trend))
        #expect(shown.map(\.mergeKey) == [rising.mergeKey])
    }
}
