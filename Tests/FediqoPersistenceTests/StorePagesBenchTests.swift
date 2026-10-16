import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long a page takes on a store the size people hold (#357). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 rows and times it; `FEDIQO_BENCH_STORE=<folder>`
/// times a copy of the `index.sqlite` in that folder, made afresh first so the folder given is
/// never opened. Only timings and counts are printed — nothing a row says.
@Suite("A page on a large store, timed", .serialized)
struct StorePagesBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    private static func time<T>(_ work: () async throws -> T) async rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await work()
        return (value, clock.now - start)
    }

    private static func query(_ rules: [Rule?], sources: [Source]) -> PageQuery {
        let definition = TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
        return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
    }

    /// Times the laps every store is put through, and returns the warm newest page of the first
    /// source's home timeline.
    private static func laps(_ file: StoreFile, sources: [Source], label: String) async throws -> Duration {
        let (_, built) = try await time { try await file.makeIndexes() }
        print("[\(label)] indexes made: \(milliseconds(built))")
        var home = Duration.zero
        for (n, source) in sources.enumerated() {
            let timeline = query([
                .source(source.host), .category(.home, in: .source(host: source.host), sources: sources),
            ], sources: sources)
            let (cold, first) = try await time { try await file.page(timeline, .newest) }
            var warm: [Duration] = []
            for _ in 0..<5 { warm.append(try await time { try await file.page(timeline, .newest) }.1) }
            let median = warm.sorted()[2]
            if n == 0 { home = median }
            print("[\(label)] source \(n) + home, newest 100: first \(milliseconds(first)), warm \(milliseconds(median)), \(cold.rows.count) rows")
        }
        let all = query([], sources: sources)
        let (_, everything) = try await time { try await file.page(all, .newest) }
        print("[\(label)] All, newest 100: \(milliseconds(everything))")
        let nothing = query([.source(sources[0].host), .category(.list(id: "none"), in: .source(host: sources[0].host), sources: sources)], sources: sources)
        let (short, none) = try await time { try await file.page(nothing, .newest) }
        print("[\(label)] no match, first page: \(milliseconds(none)), \(short.rows.count) rows, exhausted \(short.exhausted)")
        let words = query([.keyword("the", in: .every)], sources: sources)
        let (said, keyword) = try await time { try await file.page(words, .newest) }
        print("[\(label)] keyword, newest 100: \(milliseconds(keyword)), \(said.rows.count) rows")
        var ask = PageAsk.newest
        let (_, ten) = try await time {
            for _ in 0..<10 {
                let page = try await file.page(all, ask)
                guard let next = page.next else { break }
                ask = .before(next)
            }
        }
        print("[\(label)] All, ten pages down: \(milliseconds(ten))")
        return home
    }

    @Test("270,000 rows: the newest 100 of a source and a category in under 50 ms",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        var notes: [Note] = []
        notes.reserveCapacity(270_000)
        for n in 0..<270_000 {
            let categories: Set<FediqoCore.Category> = switch n % 20 {
            case 0..<6: [.home]
            case 6: [.trends]
            case 7: [.home, .public]
            default: [.public]
            }
            notes.append(Note(
                id: "\(n)", source: sources[n % 3], author: "A", handle: "a\(n % 500)@one.example", body: words,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % 270_000) * 60), categories: categories
            ))
        }
        let file = try StoreFile(at: dir)
        let (_, saved) = try await Self.time { try await file.save(sources: sources, notes: notes) }
        print("[synthetic] 270,000 rows written: \(Self.milliseconds(saved)), \(file.bytesOnDisk() / 1_000_000) MB")
        let home = try await Self.laps(file, sources: sources, label: "synthetic")
        #expect(home < .milliseconds(50))
    }

    @Test("a copy of a real store, timed", .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let given = URL(fileURLWithPath: try #require(Self.environment["FEDIQO_BENCH_STORE"]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(
            at: given.appendingPathComponent(StoreFile.indexName), to: dir.appendingPathComponent(StoreFile.indexName)
        )
        let (file, opened) = try await Self.time { try StoreFile(at: dir) }
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        let rows = try await file.db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0 }
        print("[copy] \(rows) rows, \(sources.count) sources, \(file.bytesOnDisk() / 1_000_000) MB; opened in \(Self.milliseconds(opened))")
        let home = try await Self.laps(file, sources: sources, label: "copy")
        #expect(home < .milliseconds(50))
    }
}
