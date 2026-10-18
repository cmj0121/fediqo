import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A keyword timeline's page on a store the size people hold (#360, K2). **Skipped unless asked
/// for**: `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows with keywords found in 1, 50
/// and 50,000 of them; `FEDIQO_BENCH_STORE=<folder>` a copy of the `index.sqlite` in that folder,
/// made afresh so the folder given is never opened for writing, and deleted after — its keywords
/// chosen by how many rows hold them, and never printed. Only counts and timings are printed.
@Suite("A keyword timeline on a large store, timed", .serialized, .enabled(if: StoreFile.wordsCapable))
struct StoreWordPagesBenchTests {
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

    /// A timeline of one source and one category, with one keyword.
    private struct Asked {
        let label: String
        let query: PageQuery
    }

    private static func timeline(host: String, category: FediqoCore.Category?, keyword: String, sources: [Source], label: String) -> Asked {
        let rules: [Rule?] = [
            .source(host), category.flatMap { .category($0, in: .source(host: host), sources: sources) }, .keyword(keyword, in: .every),
        ]
        let definition = TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
        return Asked(label: label, query: PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources)))
    }

    private static func plan(_ file: StoreFile, _ query: PageQuery, most: Int) throws -> String {
        switch try file.db.read({ db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: most) }) {
        case .open: "open"
        case .index: "index"
        case .candidates(let rowids): "candidates (\(rowids.count))"
        }
    }

    /// The newest page of each, built: the first asking, then the median of five, by the plan
    /// chosen and by the walk forced; then, the index started again, while it is built.
    private static func measure(_ file: StoreFile, _ asked: [Asked], label: String) async throws -> [Double] {
        let clock = ContinuousClock()
        var firsts: [Double] = []
        // The same timeline with no keyword, for how much of the top of the store it shows.
        if let some = asked.first {
            let definition = TimelineDefinition(name: "T", rules: some.query.compiled.definition.rules.filter { $0.kind.tag != .keyword })
            let plain = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: []))
            _ = try await file.page(plain, .newest)
            let start = clock.now
            let page = try await file.page(plain, .newest)
            let took = milliseconds(clock.now - start)
            let top = try await file.page(plain, .newest, limit: 20_000, scanBudget: 20_000).rows.count
            print(String(format: "[\(label)] the timeline with no keyword: newest page %.1f ms, %d rows; %d of the store's newest 20,000 rows", took, page.rows.count, top))
        }
        for each in asked {
            let start = clock.now
            let page = try await file.page(each.query, .newest)
            let first = milliseconds(clock.now - start)
            firsts.append(first)
            var warm: [Double] = []
            for _ in 0..<5 {
                let start = clock.now
                _ = try await file.page(each.query, .newest)
                warm.append(milliseconds(clock.now - start))
            }
            var walked: [Double] = []
            var walkedRows = 0
            for _ in 0..<3 {
                let start = clock.now
                walkedRows = try await file.page(each.query, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 0).rows.count
                walked.append(milliseconds(clock.now - start))
            }
            print(String(
                format: "[\(label)] \(each.label): \(try plan(file, each.query, most: StoreFile.wordsCandidatesMost)); first page %.1f ms, warm %.1f ms, %d rows, exhausted \(page.exhausted); walked row by row %.1f ms, %d rows",
                first, warm.sorted()[2], page.rows.count, walked.sorted()[1], walkedRows
            ))
        }
        // Started again — as after a read back — and read while it is built.
        try await file.db.write { db in
            try db.execute(sql: "DELETE FROM note_words_state")
            _ = try StoreFile.makeWords(db, capable: true)
        }
        let builder = Task.detached(priority: .utility) {
            while try await file.buildWordsStep() { try await Task.sleep(for: StoreFile.wordsPause) }
        }
        var during: [[Double]] = asked.map { _ in [] }
        var plans: [Set<String>] = asked.map { _ in [] }
        var rows: [[Int]] = asked.map { _ in [] }
        let began = clock.now
        while clock.now - began < .seconds(20) {
            for (n, each) in asked.enumerated() {
                plans[n].insert(try plan(file, each.query, most: StoreFile.wordsCandidatesMost))
                let start = clock.now
                let page = try await file.page(each.query, .newest)
                during[n].append(milliseconds(clock.now - start))
                rows[n].append(page.rows.count)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        builder.cancel()
        _ = try? await builder.value
        let state = try file.wordsState()
        for (n, each) in asked.enumerated() {
            let sorted = during[n].sorted()
            print(String(
                format: "[\(label)] during the build, \(each.label): \(plans[n].sorted().joined(separator: ", ")); %d pages, median %.1f ms, p95 %.1f ms, max %.1f ms; rows %d–%d",
                sorted.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!,
                rows[n].min()!, rows[n].max()!
            ))
        }
        let rowCount = try file.rowCount()
        print("[\(label)] the build stopped after 20 s with the floor at \(state?.floor ?? -1) of \(rowCount) rows")
        return firsts
    }

    private static func build(_ file: StoreFile, label: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await file.buildWords(chunk: StoreFile.wordsChunk, capable: true)
        print(String(format: "[\(label)] words built in %.1f s", milliseconds(clock.now - start) / 1000))
    }

    @Test("270,000 synthetic rows: a keyword found in 1, 50 and 50,000 rows draws its first page in under 50 ms",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = 270_000
        var random = Seeded(state: 3602)
        let characters = (0..<3_000).map { Character(Unicode.Scalar(0x4E00 + $0 * 7)!) }
        let vocabulary = (0..<2_000).map { _ in
            String((0..<Int.random(in: 3...9, using: &random)).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement(using: &random)! })
        }
        let cjk = Zipf(characters.count)
        let latin = Zipf(vocabulary.count)
        // The rows each keyword is put in: the one is the first row, of the timeline's source
        // and category; the rest anywhere.
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
            let categories: Set<FediqoCore.Category> = n % 20 < 6 ? [.home] : [.public]
            notes.append(Note(
                id: "\(n)", source: sources[n % 3], author: "Name \(n % 500)", handle: "a\(n % 500)@one.example", body: body,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % count) * 60), categories: categories
            ))
        }
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: notes)
        try await file.makeIndexes()
        try await Self.build(file, label: "synthetic")
        let asked = [("1 row", "鬱龘"), ("50 rows", "鸞鷹"), ("50,000 rows", "麤麟")].map { label, keyword in
            Self.timeline(host: "one.example", category: .home, keyword: keyword, sources: sources, label: label)
        }
        let firsts = try await Self.measure(file, asked, label: "synthetic")
        #expect(firsts.allSatisfy { $0 < 50 })
    }

    @Test("a copy of a real store: a keyword found in about 1, 50 and 50,000 rows, timed",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let given = URL(fileURLWithPath: try #require(Self.environment["FEDIQO_BENCH_STORE"]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
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
        let rowCount = try file.rowCount()
        print("[copy] \(rowCount) rows, \(sources.count) sources")
        try await Self.build(file, label: "copy")
        // The source and category most of the newest 20,000 rows came by, of those a rule names
        // with no id: a timeline a reader reads now.
        let (host, kind) = try await file.db.read { db -> (String, String?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT n.host AS host, json_extract(j.value, '$.kind') AS kind, count(*) AS c FROM note n, json_each(CASE WHEN json_valid(n.categories) THEN n.categories ELSE '[]' END) j
                WHERE n.rowid IN (SELECT rowid FROM note INDEXED BY note_page ORDER BY posted_at DESC, id ASC LIMIT 20000)
                AND j.type = 'object' AND json_extract(j.value, '$.kind') IN ('home', 'public', 'trends')
                GROUP BY 1, 2 ORDER BY c DESC LIMIT 1
                """)
            return (row?["host"] ?? sources[0].host, row?["kind"])
        }
        let category: FediqoCore.Category? = switch kind {
        case "home": .home
        case "public": .public
        case "trends": .trends
        default: nil
        }
        // Keywords by how many rows the index gives for them: one- and two-character runs of
        // some bodies of the timeline's own rows, each counted over the whole store, and the
        // nearest to each aim taken. Never printed.
        let bodies = try await file.db.read { db in
            try String.fetchAll(db, sql: """
                SELECT json_extract(facts, '$.body') FROM note WHERE json_valid(facts) AND json_type(facts, '$.body') = 'text'
                AND host = ? AND instr(categories, ?) > 0 AND rowid % 13 = 0 LIMIT 1500
                """, arguments: [host, kind.map { "\"\($0)\"" } ?? ""])
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
        var counted: [(String, Int)] = []
        let every = runs.sorted()
        for (n, run) in every.enumerated() where n % max(1, every.count / 6_000) == 0 {
            guard let tokens = WordGrams.asked(run) else { continue }
            let found = try await file.db.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM note_words WHERE note_words MATCH ?", arguments: [WordGrams.match(tokens)]) ?? 0
            }
            if found > 0 { counted.append((run, found)) }
        }
        var asked: [Asked] = []
        for aim in [1, 50, 50_000] {
            guard let nearest = counted.min(by: { abs(log(Double($0.1) / Double(aim))) < abs(log(Double($1.1) / Double(aim))) }) else { continue }
            asked.append(Self.timeline(
                host: host, category: category, keyword: nearest.0, sources: sources, label: "aim \(aim), found in \(nearest.1) rows"
            ))
        }
        _ = try await Self.measure(file, asked, label: "copy")
        try file.db.close()
    }
}
