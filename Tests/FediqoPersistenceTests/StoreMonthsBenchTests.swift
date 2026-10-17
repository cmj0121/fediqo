import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long each step of the months limit holds the store's actor over a large file (#360, C32).
/// **Skipped unless asked for**: `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows;
/// `FEDIQO_BENCH_STORE=<folder>` steps through a copy of the store in that folder, which is
/// opened read only and never written. Only counts and timings are printed — nothing a row says.
@Suite("The months limit on a large store, timed", .serialized)
struct StoreMonthsBenchTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    /// 270,000 rows a minute apart over three sources, half a year of them: a reblog of an older
    /// row every tenth, a quote of an older one every thirtieth, one kept in a thousand.
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

    /// Every step of the limit over `file`, each saved before the next, timed apart: the step on
    /// the store's actor, and its save.
    private static func walk(_ file: StoreFile, sources: [Source], months: Int, from now: Date, label: String) async throws {
        let pool = ItemStore(sources: sources, rows: file)
        let clock = ContinuousClock()
        var steps: [Double] = []
        var saves: [Double] = []
        var went = 0
        var next: PageCursor?
        let rows = try file.rowCount()
        let cutoff = try #require(await pool.setLimit(months: months, from: now))
        repeat {
            let began = clock.now
            let made = await pool.letGoBeyond(cutoff, step: ItemStore.beyondStep, after: next)
            steps.append(milliseconds(clock.now - began))
            next = made.next
            went += made.went.posts
            let saving = clock.now
            try await file.save(await pool.takeChanges().changes)
            saves.append(milliseconds(clock.now - saving))
        } while next != nil
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))] }
        print(String(
            format: "[months] %@: %d rows, %d months: %d steps, %d went, %d left; step p50 %.1f p95 %.1f max %.1f ms; save p95 %.1f max %.1f ms",
            label, rows, months, steps.count, went, try file.rowCount(),
            steps.sorted()[steps.count / 2], p95(steps), steps.max() ?? 0, p95(saves), saves.max() ?? 0
        ))
    }

    @Test("270,000 rows: each step of the months limit, and its save", .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        for months in [3, 1] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = try StoreFile(at: dir)
            try await file.save(sources: Self.sources, notes: Self.seed())
            try await file.makeIndexes()
            try await Self.walk(file, sources: Self.sources, months: months, from: Self.start, label: "synthetic")
        }
    }

    @Test("a copy of a real store: each step of the months limit, and its save", .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let given = URL(fileURLWithPath: try #require(Self.environment["FEDIQO_BENCH_STORE"]))
        for months in [12, 3] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            // Copied by SQLite's own backup, the given one opened read only.
            var readOnly = Configuration()
            readOnly.readonly = true
            let source = try DatabaseQueue(path: given.appendingPathComponent(StoreFile.indexName).path, configuration: readOnly)
            let copy = try DatabaseQueue(path: dir.appendingPathComponent(StoreFile.indexName).path)
            try source.backup(to: copy)
            try source.close()
            try copy.close()
            let file = try StoreFile(at: dir)
            try await file.makeIndexes()
            let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
            try await Self.walk(file, sources: sources, months: months, from: Date(), label: "copy")
        }
    }
}
