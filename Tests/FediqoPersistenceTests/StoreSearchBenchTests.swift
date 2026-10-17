import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A search read from the file on a store the size people hold (#360, K3). **Skipped unless asked
/// for**: `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows with words found in 1, 50 and
/// 50,000 of them, a handle in some 540, and a category's name everywhere and one rare;
/// `FEDIQO_BENCH_STORE=<folder>` a fresh copy of the
/// store in that folder (`StorePagesBenchTests.freshCopy`, a backup read only), deleted after — its
/// patterns chosen by how many rows the index gives for them, and never printed. Only counts and
/// timings are printed, and nothing is asserted of a time.
@Suite("A search on a large store, timed", .serialized, .enabled(if: StoreFile.wordsCapable))
struct StoreSearchBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    /// The same numbers every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Draws from `count` things, the first far likelier than the last (Zipf, s = 1).
    private struct Zipf {
        let cumulative: [Double]
        init(_ count: Int) {
            var sum = 0.0
            cumulative = (1...count).map { sum += 1 / Double($0); return sum }
        }

        func draw(_ random: inout Seeded) -> Int {
            let target = Double.random(in: 0..<cumulative.last!, using: &random)
            var low = 0, high = cumulative.count - 1
            while low < high {
                let middle = (low + high) / 2
                if cumulative[middle] < target { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    /// One pattern searched for, and what it is called in what is printed.
    private struct Asked {
        let label: String
        let search: NoteSearch
    }

    private static func timeline(_ rules: [Rule?], sources: [Source]) -> PageQuery {
        let definition = rules.isEmpty ? TimelineDefinition.all : TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
        return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
    }

    private static func plan(_ file: StoreFile, _ search: NoteSearch) throws -> String {
        guard let match = StoreFile.searchMatch(search.pattern.literals) else { return "none" }
        let also = StoreFile.searchCategories(search.namedCategories)
        let named = also.isEmpty ? "" : ", \(also.count) categories named"
        return switch try file.db.read({ db in try StoreFile.wordsAsk(db, matches: [match], also: also, most: StoreFile.wordsCandidatesMost) }) {
        case .open: "open"
        case .index: "index\(named)"
        case .candidates(let rowids): "candidates (\(rowids.count))\(named)"
        }
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// For each timeline and pattern: the newest page, the first asking and the median of five;
    /// then pages read on to the end, or twenty of them, as a reader scrolling the results reads
    /// them. Then, the index started again, the newest page while it is built.
    private static func measure(_ file: StoreFile, _ asked: [Asked], timelines: [(String, PageQuery)], label: String) async throws {
        let clock = ContinuousClock()
        print("[\(label)] timeline | pattern | plan | first page ms | warm ms | rows | pages read | rows found | ms a page | exhausted")
        for (name, query) in timelines {
            for each in asked {
                let start = clock.now
                guard let page = try await file.search(query, each.search, .newest) else {
                    print("[\(label)] \(name) | \(each.label) | not narrowed")
                    continue
                }
                let first = milliseconds(clock.now - start)
                var warm: [Double] = []
                for _ in 0..<5 {
                    let start = clock.now
                    _ = try await file.search(query, each.search, .newest)
                    warm.append(milliseconds(clock.now - start))
                }
                var pages = 1
                var found = page.rows.count
                var next = page.next
                var exhausted = page.exhausted
                var took: [Double] = []
                while !exhausted, pages < 20, let from = next {
                    let start = clock.now
                    guard let more = try await file.search(query, each.search, .before(from)) else { break }
                    took.append(milliseconds(clock.now - start))
                    pages += 1
                    found += more.rows.count
                    next = more.next
                    exhausted = more.exhausted
                }
                print(String(
                    format: "[\(label)] \(name) | \(each.label) | \(try plan(file, each.search)) | %.1f | %.1f | %d | %d | %d | %@ | \(exhausted)",
                    first, median(warm), page.rows.count, pages, found, took.isEmpty ? "—" : String(format: "%.1f", median(took))
                ))
            }
        }
        // Started again — as after a read back — and searched while it is built.
        try await file.db.write { db in
            try db.execute(sql: "DELETE FROM note_words_state")
            _ = try StoreFile.makeWords(db, capable: true)
        }
        let builder = Task.detached(priority: .utility) {
            while try await file.buildWordsStep() { try await Task.sleep(for: StoreFile.wordsPause) }
        }
        let query = timelines[0].1
        // The rarest, and the last, searched to the end as the build begins: every row not built yet is asked
        // of its fields before it is read whole.
        for rare in [asked.first, asked.last].compactMap({ $0 }) {
            let start = clock.now
            var pages = 0
            var found = 0
            var ask = PageAsk.newest
            var slowest = 0.0
            while true {
                let at = clock.now
                guard let page = try await file.search(query, rare.search, ask) else { break }
                slowest = max(slowest, milliseconds(clock.now - at))
                pages += 1
                found += page.rows.count
                guard !page.exhausted, let next = page.next else { break }
                ask = .before(next)
            }
            let floor = try file.wordsState()?.floor ?? -1
            print(String(
                format: "[\(label)] during the build, \(timelines[0].0) | \(rare.label) walked to the end: %.1f s, %d pages (slowest %.0f ms), %d found; floor then at %lld",
                milliseconds(clock.now - start) / 1000, pages, slowest, found, floor
            ))
        }
        var during: [[Double]] = asked.map { _ in [] }
        var rows: [[Int]] = asked.map { _ in [] }
        let began = clock.now
        while clock.now - began < .seconds(20) {
            for (n, each) in asked.enumerated() {
                let start = clock.now
                let page = try await file.search(query, each.search, .newest)
                during[n].append(milliseconds(clock.now - start))
                rows[n].append(page?.rows.count ?? -1)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        builder.cancel()
        _ = try? await builder.value
        let state = try file.wordsState()
        print("[\(label)] during the build, \(timelines[0].0) | pattern | pages | median ms | p95 ms | max ms | rows")
        for (n, each) in asked.enumerated() {
            let sorted = during[n].sorted()
            print(String(
                format: "[\(label)] during the build | \(each.label) | %d | %.1f | %.1f | %.1f | %d–%d",
                sorted.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!,
                rows[n].min()!, rows[n].max()!
            ))
        }
        print("[\(label)] the build stopped after 20 s with the floor at \(state?.floor ?? -1) of \(try file.rowCount()) rows")
    }

    private static func build(_ file: StoreFile, label: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await file.buildWords(chunk: StoreFile.wordsChunk, capable: true)
        print(String(format: "[\(label)] words built in %.1f s", milliseconds(clock.now - start) / 1000))
    }

    @Test("270,000 synthetic rows: a search found in 1, 50, some 540 and 50,000 rows, timed",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = 270_000
        var random = Seeded(state: 3603)
        let characters = (0..<3_000).map { Character(Unicode.Scalar(0x4E00 + $0 * 7)!) }
        let vocabulary = (0..<2_000).map { _ in
            String((0..<Int.random(in: 3...9, using: &random)).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement(using: &random)! })
        }
        let cjk = Zipf(characters.count)
        let latin = Zipf(vocabulary.count)
        var fifty: Set<Int> = []
        while fifty.count < 50 { fifty.insert(Int.random(in: 1..<count, using: &random)) }
        var many: Set<Int> = []
        while many.count < 50_000 { many.insert(Int.random(in: 1..<count, using: &random)) }
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var notes: [Note] = []
        notes.reserveCapacity(count)
        for n in 0..<count {
            var body: String
            if Int.random(in: 0..<10, using: &random) < 6 {
                body = String((0..<Int.random(in: 20...200, using: &random)).map { _ in characters[cjk.draw(&random)] })
            } else {
                body = (0..<Int.random(in: 5...40, using: &random)).map { _ in vocabulary[latin.draw(&random)] }.joined(separator: " ")
            }
            if n == 0 { body += " 鬱龘" }
            if fifty.contains(n) { body += " 鸞鷹" }
            if many.contains(n) { body += " 麤麟" }
            // A rare category, whose name no text holds: one row in two thousand trending.
            let categories: Set<FediqoCore.Category> = n % 2_000 == 7 ? [.trends] : n % 20 < 6 ? [.home] : [.public]
            notes.append(Note(
                id: "\(n)", source: sources[n % 3], author: "Name \(n % 500)", handle: "a\(n % 500)@one.example", body: body,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % count) * 60), categories: categories
            ))
        }
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: notes)
        try await file.makeIndexes()
        try await Self.build(file, label: "synthetic")
        let asked = try [("1 row", "鬱龘"), ("50 rows", "鸞鷹"), ("about 540 rows, a handle", "@a7@"), ("50,000 rows", "麤麟"), ("a category's name, home", "home"), ("a rare category's name, trends", "trends")].map { label, pattern in
            Asked(label: label, search: try #require(NoteSearch(pattern, sources: sources)))
        }
        try await Self.measure(file, asked, timelines: [
            ("All", Self.timeline([], sources: sources)),
            ("a source's home", Self.timeline([.source("one.example"), .category(.home, in: .source(host: "one.example"), sources: sources)], sources: sources)),
        ], label: "synthetic")
    }

    @Test("a copy of a real store: a search found in about 1, 50, 500 and 50,000 rows, timed",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let dir = try StorePagesBenchTests.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.makeIndexes()
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        print("[copy] \(try file.rowCount()) rows, \(sources.count) sources")
        try await Self.build(file, label: "copy")
        // Patterns by how many rows the index gives for them: one- and two-character runs of some
        // bodies, each counted over the whole store, and the nearest to each aim taken among those
        // that name no category. Never printed.
        let bodies = try await file.db.read { db in
            try String.fetchAll(db, sql: """
                SELECT json_extract(facts, '$.body') FROM note WHERE json_valid(facts) AND json_type(facts, '$.body') = 'text'
                AND rowid % 13 = 0 LIMIT 1500
                """)
        }
        var runs: Set<String> = []
        for body in bodies {
            let characters = Array(Fold.key(body))
            for start in characters.indices where !characters[start].isWhitespace {
                runs.insert(String(characters[start]))
                if start + 1 < characters.count, !characters[start + 1].isWhitespace {
                    runs.insert(String(characters[start...start + 1]))
                }
            }
        }
        var counted: [(NoteSearch, Int)] = []
        let every = runs.sorted()
        for (n, run) in every.enumerated() where n % max(1, every.count / 6_000) == 0 {
            guard let search = NoteSearch(run, sources: sources), search.namedCategories.isEmpty,
                  let match = StoreFile.searchMatch(search.pattern.literals) else { continue }
            let found = try await file.db.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM note_words WHERE note_words MATCH ?", arguments: [match]) ?? 0
            }
            if found > 0 { counted.append((search, found)) }
        }
        var asked: [Asked] = []
        for aim in [1, 50, 500, 50_000] {
            guard let nearest = counted.min(by: { abs(log(Double($0.1) / Double(aim))) < abs(log(Double($1.1) / Double(aim))) }) else { continue }
            asked.append(Asked(label: "aim \(aim), the index gives \(nearest.1) rows", search: nearest.0))
        }
        try await Self.measure(file, asked, timelines: [("All", Self.timeline([], sources: sources))], label: "copy")
        try file.db.close()
    }
}
