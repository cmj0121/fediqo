@testable import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// The store's census (#360, K-12): how many entries each collection it holds has — what the
/// long walk prints to find what grows with rows walked. Counts only, asserted as counts.
@Suite("The store's census")
struct StoreCensusTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an empty store counts nothing in any collection")
    func empty() async {
        let census = await ItemStore().census()
        #expect(!census.isEmpty)
        #expect(census.filter { $0.value != 0 }.isEmpty)
    }

    @Test("a page of N rows read into a pool over the file: the pool, and when each was seen, count N", arguments: [1, 40, 250])
    func pageRead(rows: Int) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = (0..<rows).map { n in
            Note(
                id: "p\(n)", source: Self.source, author: "A", handle: "a@one.example", body: "b",
                postedAt: Self.at.addingTimeInterval(-Double(n) * 60), categories: [.home], statusID: "s\(n)"
            )
        }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: notes)
        let pool = ItemStore(sources: [Self.source], rows: file)
        #expect(await pool.census()["pool"] == 0)
        let definition = TimelineDefinition(name: "T", rules: [])
        let query = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: [Self.source]))
        let page = try await file.page(query, .newest, limit: rows)
        #expect(page.rows.count == rows)
        await pool.take(page.rows + page.carried)
        let census = await pool.census()
        #expect(census["pool"] == rows)
        #expect(census["pool.seen"] == rows)
        // Nothing written, nothing let go, nothing asked of a source.
        #expect(census["pool.touched"] == 0)
        #expect(census["pool.dropped"] == 0)
        #expect(census["opsOwed"] == 0)
        #expect(census["inFlight"] == 0)
        try file.db.close()
    }
}
