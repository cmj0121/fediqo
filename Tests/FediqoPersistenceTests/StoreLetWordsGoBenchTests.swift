import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long taking the words of what was let go out of the words index takes on a store the size
/// people hold, and how long pages wait meanwhile (#360, K9, C27). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows, as the words bench does;
/// `FEDIQO_BENCH_STORE=<folder>` runs on a copy of the store in that folder made afresh by
/// SQLite's backup (`StorePagesBenchTests.freshCopy`), the given one opened read only. Only
/// counts and timings are printed — nothing a row says — and nothing is asserted of them.
@Suite("The words of what is let go taken out, timed", .serialized, .enabled(if: StoreFile.wordsCapable))
struct StoreLetWordsGoBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    private static func p(_ share: Double, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    private static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    /// Pages read one after another, a reader's pace, until cancelled: each one's time.
    private static func reading(_ file: StoreFile, _ queries: [PageQuery]) -> Task<[Double], Never> {
        Task.detached {
            let clock = ContinuousClock()
            var pages: [Double] = []
            var turn = 0
            do {
                while !Task.isCancelled {
                    let start = clock.now
                    _ = try await file.page(queries[turn % queries.count], .newest)
                    pages.append(Self.milliseconds(clock.now - start))
                    turn += 1
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch {}
            return pages
        }
    }

    /// Acts letting go of `counts` rows each — the oldest posted, saved as the saver saves —
    /// each followed by `letWordsGo` with pages read beside it, then the room given back.
    private static func walk(_ file: StoreFile, counts: [Int], label: String) async throws {
        let clock = ContinuousClock()
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        let queries = [TimelineDefinition.all].map {
            PageQuery(timeline: $0.id, generation: 1, compiled: CompiledTimeline($0, sources: sources))
        }
        let building = clock.now
        try await file.buildWords(chunk: 2_000, capable: true)
        let words = try await file.db.read { db in
            try Int.fetchOne(db, sql: "SELECT sum(pgsize) FROM dbstat WHERE name LIKE 'note_words%'")
        } ?? 0
        print(String(
            format: "[let go words] %@: %d rows; words built in %.1f s, index %@, file %@",
            label, try file.rowCount(), milliseconds(clock.now - building) / 1000, megabytes(words), megabytes(file.bytesOnDisk())
        ))
        // Pages with nothing beside them.
        let alone = Self.reading(file, queries)
        try await Task.sleep(for: .seconds(1))
        alone.cancel()
        let quiet = await alone.value
        print(String(format: "[let go words] %@: pages alone: %d, p50 %.1f p95 %.1f max %.1f ms", label, quiet.count, p(0.5, quiet), p(0.95, quiet), quiet.max() ?? 0))
        let nothing = clock.now
        let idle = try await file.letWordsGo()
        print(String(format: "[let go words] %@: asked with nothing let go: %.2f ms (rewrote %@)", label, milliseconds(clock.now - nothing), idle ? "yes" : "no"))

        // Each write where a save would run, on its own, as the app's.
        let saver = StoreSaver(store: ItemStore(), file: file)
        print("[let go words] \(label): | let go | save | left due | drain writes of 500 / of 100, longest | rewrite in steps | pages beside: n, p50, p95, max | clean | index after |")
        for count in counts {
            let keys = try await file.db.read { db in
                try Row.fetchAll(db, sql: "SELECT host, id FROM note ORDER BY posted_at LIMIT ?", arguments: [count])
                    .map { NoteKey(host: $0["host"], id: $0["id"]) }
            }
            let saving = clock.now
            try await file.save(RowChanges(deletes: keys))
            let saved = milliseconds(clock.now - saving)
            let due = try file.wordsState()?.due ?? 0
            // What one drain write holds the queue for, by its size: three of each, where as many
            // are due.
            var drains: [Int: Double] = [:]
            for size in [500, 100] where (try file.wordsState()?.due ?? 0) >= 3 * size {
                for _ in 0..<3 {
                    let began = clock.now
                    _ = try await file.db.write { db in try StoreFile.drainWords(db, limit: size) }
                    drains[size] = max(drains[size] ?? 0, milliseconds(clock.now - began))
                }
            }
            let beside = Self.reading(file, queries)
            try await Task.sleep(for: .milliseconds(200))
            let start = clock.now
            _ = try await file.letWordsGo(in: saver)
            let whole = milliseconds(clock.now - start)
            let shape = try file.wordsShape()
            try await Task.sleep(for: .milliseconds(200))
            beside.cancel()
            let pages = await beside.value
            let after = try await file.db.read { db in
                try Int.fetchOne(db, sql: "SELECT sum(pgsize) FROM dbstat WHERE name LIKE 'note_words%'")
            } ?? 0
            let clean = "\(shape?.isClean == true ? "yes" : "no") (\(shape?.segments ?? -1) seg, \(shape?.tombstonePages ?? -1) tomb, owed \(try file.wordsLetGoOwed()))"
            print(String(
                format: "[let go words] %@: | %d | %.0f ms | %d | %@ / %@ ms | %.0f ms | %d, %.1f, %.1f, %.0f ms | %@ | %@ |",
                label, keys.count, saved, due,
                drains[500].map { String(format: "%.0f", $0) } ?? "-", drains[100].map { String(format: "%.0f", $0) } ?? "-",
                whole, pages.count, p(0.5, pages), p(0.95, pages), pages.max() ?? 0, clean, megabytes(after)
            ))
        }
        let compacting = clock.now
        try await file.compact()
        print(String(format: "[let go words] %@: compact after: %.0f ms, file %@", label, milliseconds(clock.now - compacting), megabytes(file.bytesOnDisk())))
        try file.db.close()
    }

    @Test("270,000 synthetic rows: the words of what was let go taken out, and pages beside it",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: StoreWordsBenchTests.synthetic(270_000))
        try await file.makeIndexes()
        try await Self.walk(file, counts: [100, 400, 2_000, 10_000, 27_000], label: "synthetic")
    }

    @Test("a copy of a real store: the words of what was let go taken out, and pages beside it",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let dir = try StorePagesBenchTests.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.makeIndexes()
        let rows = try file.rowCount()
        try await Self.walk(file, counts: [100, 400, 2_000, 10_000, 27_000].filter { $0 < rows / 2 }, label: "copy")
    }
}
