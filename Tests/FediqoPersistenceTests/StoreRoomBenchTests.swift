@testable import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long each hop of the room limit holds the store's actor over a large file, and each step
/// of giving the file its room back (#360, C33, C26). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows; `FEDIQO_BENCH_STORE=<folder>` runs
/// on a copy of the store in that folder, made afresh by SQLite's backup with the given one
/// opened read only and never written. Only counts and timings are printed — nothing a row says.
@Suite("The room limit on a large store, timed", .serialized)
struct StoreRoomBenchTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    private static func p(_ share: Double, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    /// 270,000 rows a minute apart over three sources: a reblog of an older row every tenth, a
    /// quote of an older one every thirtieth, one kept in a thousand.
    private static func seed() -> [Note] {
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        return (0..<270_000).map { n in
            let source = sources[n % 3]
            var refs: [Reference] = []
            if n % 10 == 0, n + 3 < 270_000 {
                refs = [Reference(kind: .reblogs, id: "\(n + 3)")]
            } else if n % 30 == 1, n + 3 < 270_000 {
                refs = [Reference(kind: .quotes, id: "\(n + 3)", state: .accepted)]
            }
            return Note(
                id: "\(n)", source: source, author: "A", handle: "a\(n % 500)@\(source.host)", body: words,
                postedAt: start.addingTimeInterval(-Double(n) * 60), categories: [.home], kept: n % 1000 == 0, refs: refs
            )
        }
    }

    private static func pragma(_ file: StoreFile, _ name: String) async throws -> Int {
        try await file.db.read { db in try Int.fetchOne(db, sql: "PRAGMA \(name)") ?? 0 }
    }

    /// `rounds` rounds of the room limit over `file`, each of `count` posts and saved as the
    /// saver saves (the store told it landed), then the file given its room back a step at a
    /// time: each hop and each step timed apart.
    private static func walk(_ file: StoreFile, sources: [Source], rounds: Int, count: Int, label: String) async throws {
        let clock = ContinuousClock()
        let scrubbing = clock.now
        await file.scrubIfDue()
        var scrubbed = milliseconds(clock.now - scrubbing)
        // A copy the scrub had no cause to rebuild is rebuilt here as the scrub would: the
        // copy is this bench's own.
        if try await pragma(file, "auto_vacuum") != StoreFile.incremental {
            let rebuilding = clock.now
            try await file.db.writeWithoutTransaction { db in try StoreFile.rebuild(db) }
            scrubbed = milliseconds(clock.now - rebuilding)
        }
        let mode = try await pragma(file, "auto_vacuum")
        let pool = ItemStore(sources: sources, rows: file)
        let rows = try file.rowCount()
        _ = await pool.holdsWhatRoomMayLetGo()
        let lookedAtStart = await pool.lookedCount
        var hops: [Double] = []
        var saves: [Double] = []
        var looked: [Int] = []
        var went = 0
        for _ in 0..<rounds {
            let before = await pool.hopsTook.count
            went += await pool.letGoOldest(count: count).posts
            hops += await pool.hopsTook.dropFirst(before).map(milliseconds)
            let saving = clock.now
            let (changes, _) = await pool.takeChanges()
            try await file.save(changes)
            await pool.wrote(changes)
            saves.append(milliseconds(clock.now - saving))
            looked.append(await pool.lookedCount)
        }
        print(String(
            format: "[room] %@: %d rows, scrub %.0f ms (mode %d), %d rounds of %d: %d went, %d hops; hop p50 %.1f p95 %.1f max %.1f ms; save p95 %.1f max %.1f ms",
            label, rows, scrubbed, mode, rounds, count, went, hops.count,
            p(0.5, hops), p(0.95, hops), hops.max() ?? 0, p(0.95, saves), saves.max() ?? 0
        ))
        print("[room] \(label): answered for at the start \(lookedAtStart), after each saved round \(looked.map(String.init).joined(separator: ", "))")

        let pages = try await pragma(file, "page_count")
        let free = try await pragma(file, "freelist_count")
        let size = try await pragma(file, "page_size")
        var steps: [Double] = []
        while true {
            let began = clock.now
            let left = try await file.compactStep()
            steps.append(milliseconds(clock.now - began))
            if left == 0 { break }
            await Task.yield()
        }
        let after = try await pragma(file, "page_count")
        print(String(
            format: "[room] %@: %d pages of %d B, %d free; %d steps of %d: step p50 %.1f p95 %.1f max %.1f ms, total %.0f ms; %d pages after (%d given back), %d free",
            label, pages, size, free, steps.count, StoreFile.compactPages,
            p(0.5, steps), p(0.95, steps), steps.max() ?? 0, steps.reduce(0, +), after, pages - after,
            try await pragma(file, "freelist_count")
        ))
        try file.db.close()
    }

    @Test("270,000 rows: each hop of the room limit, its save, and each step giving the room back",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: Self.sources, notes: Self.seed())
        try await file.makeIndexes()
        try await Self.walk(file, sources: Self.sources, rounds: 6, count: 10_000, label: "synthetic")
    }

    @Test("a copy of a real store: each hop of the room limit, its save, and each step giving the room back",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let dir = try Self.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.makeIndexes()
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        let rows = try file.rowCount()
        try await Self.walk(file, sources: sources, rounds: 3, count: max(1, rows / 20), label: "copy")
    }

    /// A copy of the given store made afresh by SQLite's own backup, the given one opened read
    /// only and never written.
    private static func freshCopy() throws -> URL {
        let given = URL(fileURLWithPath: try #require(environment["FEDIQO_BENCH_STORE"]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: given.appendingPathComponent(StoreFile.indexName).path, configuration: readOnly)
        let copy = try DatabaseQueue(path: dir.appendingPathComponent(StoreFile.indexName).path)
        try source.backup(to: copy)
        try source.close()
        try copy.close()
        return dir
    }
}
