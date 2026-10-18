import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// The words index on a store the size people hold (#360, K1). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows; `FEDIQO_BENCH_STORE=<folder>` a
/// copy of the `index.sqlite` in that folder, made afresh first so the folder given is never
/// opened for writing, and deleted after. Only sizes, counts and timings are printed — nothing a
/// row says.
@Suite("The words index on a large store, timed", .serialized, .enabled(if: StoreFile.wordsCapable))
struct StoreWordsBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    private static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

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

    /// 60 % of posts CJK, 20–200 characters from 3,000 by Zipf; 40 % Latin, words of a
    /// vocabulary of 2,000 by Zipf — as the K0 design's measure.
    static func synthetic(_ count: Int) -> [Note] {
        var random = Seeded(state: 360)
        let characters = (0..<3_000).map { Character(Unicode.Scalar(0x4E00 + $0 * 7)!) }
        let vocabulary = (0..<2_000).map { _ in
            String((0..<Int.random(in: 3...9, using: &random)).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement(using: &random)! })
        }
        let cjk = Zipf(characters.count)
        let latin = Zipf(vocabulary.count)
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { n in
            let body: String
            if Int.random(in: 0..<10, using: &random) < 6 {
                body = String((0..<Int.random(in: 20...200, using: &random)).map { _ in characters[cjk.draw(&random)] })
            } else {
                body = (0..<Int.random(in: 5...40, using: &random)).map { _ in vocabulary[latin.draw(&random)] }.joined(separator: " ")
            }
            let categories: Set<FediqoCore.Category> = n % 20 < 6 ? [.home] : [.public]
            return Note(
                id: "\(n)", source: sources[n % 3], author: "Name \(n % 500)", handle: "a\(n % 500)@one.example", body: body,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % count) * 60), categories: categories
            )
        }
    }

    /// The bytes the words index takes in the file: by `dbstat` where this SQLite has it, by
    /// the pages in use before and after otherwise.
    private static func wordsBytes(_ file: StoreFile) -> Int? {
        try? file.db.read { db in
            try Int.fetchOne(db, sql: "SELECT sum(pgsize) FROM dbstat WHERE name LIKE 'note_words%'")
        }
    }

    /// Builds the words index while pages are read beside it, as a launch would, and prints what
    /// it took.
    private static func build(_ file: StoreFile, label: String) async throws -> Double {
        let rows = try await file.db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0 }
        let text = try await file.db.read { db in
            try Int.fetchOne(db, sql: "SELECT sum(length(CAST(json_extract(facts, '$.body') AS BLOB))) FROM note WHERE json_valid(facts)") ?? 0
        }
        let held = file.bytesHeld()
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        print("[\(label)] \(rows) rows, \(sources.count) sources; file \(megabytes(file.bytesOnDisk())), in use \(megabytes(held)); body text \(megabytes(text))")
        let clock = ContinuousClock()
        // Pages beside the build, as a reader scrolling would ask them: a source's home and All,
        // the newest and a few pages down, one after another until the build is done.
        let queries = sources.prefix(3).map { source in
            let definition = TimelineDefinition(name: "T", rules: [Rule?]([
                .source(source.host), .category(.home, in: .source(host: source.host), sources: sources),
            ]).compactMap { $0 })
            return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
        } + [PageQuery(timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: sources))]
        // The same pages with nothing beside them, for what the build adds.
        var alone: [Double] = []
        for turn in 0..<(queries.count * 4) {
            var ask = PageAsk.newest
            for _ in 0..<3 {
                let start = clock.now
                let page = try await file.page(queries[turn % queries.count], ask)
                alone.append(milliseconds(clock.now - start))
                guard let next = page.next else { break }
                ask = .before(next)
            }
        }
        alone.sort()
        print(String(
            format: "[\(label)] pages before the build: %d, median %.1f ms, p95 %.1f ms",
            alone.count, alone[alone.count / 2], alone[min(alone.count - 1, Int(Double(alone.count) * 0.95))]
        ))
        let reblogsStart = clock.now
        try await file.db.write { db in try db.execute(sql: StoreFile.reblogsIndex) }
        print(String(format: "[\(label)] note_reblogs made: %.1f ms", milliseconds(clock.now - reblogsStart)))
        let begun = clock.now
        // As `buildWords`, its two halves timed apart: the docs, then the merging.
        let builder = Task.detached(priority: .utility) { () -> (docs: Duration, all: Duration, merges: Int, worst: Duration) in
            _ = try await file.db.write { db in try StoreFile.makeWords(db, capable: true) }
            while try await file.buildWordsStep() { try await Task.sleep(for: StoreFile.wordsPause) }
            let docs = clock.now - begun
            var merges = 0
            var worst = Duration.zero
            while true {
                let start = clock.now
                let more = try await file.mergeWordsStep()
                worst = max(worst, clock.now - start)
                merges += 1
                if !more { break }
                try await Task.sleep(for: StoreFile.wordsPause)
            }
            return (docs, clock.now - begun, merges, worst)
        }
        let reading = Task { () -> [Double] in
            var pages: [Double] = []
            var turn = 0
            do {
                while !Task.isCancelled {
                    let query = queries[turn % queries.count]
                    turn += 1
                    var ask = PageAsk.newest
                    for _ in 0..<3 {
                        let start = clock.now
                        let page = try await file.page(query, ask)
                        pages.append(milliseconds(clock.now - start))
                        guard let next = page.next else { break }
                        ask = .before(next)
                    }
                    // A reader's pace, a few pages a second, rather than pages back to back.
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {}
            return pages
        }
        let built = try await builder.value
        let took = milliseconds(built.all)
        print(String(
            format: "[\(label)] docs made in %.1f s, then %d merge steps in %.1f s, the longest %.0f ms",
            milliseconds(built.docs) / 1000, built.merges, (milliseconds(built.all) - milliseconds(built.docs)) / 1000, milliseconds(built.worst)
        ))
        reading.cancel()
        var pages = await reading.value
        let after = file.bytesHeld()
        let index = wordsBytes(file) ?? (after - held)
        pages.sort()
        let p95 = pages.isEmpty ? 0 : pages[min(pages.count - 1, Int(Double(pages.count) * 0.95))]
        print(String(
            format: "[\(label)] words built in %.1f s (%.0f µs a row); index \(megabytes(index)) (%.2f× the body text, %.0f %% of the file before); file now \(megabytes(file.bytesOnDisk()))",
            took / 1000, took * 1000 / Double(max(rows, 1)), Double(index) / Double(max(text, 1)), Double(index) * 100 / Double(max(held, 1))
        ))
        print(String(
            format: "[\(label)] pages during the build: %d, median %.1f ms, p95 %.1f ms, max %.1f ms",
            pages.count, pages.isEmpty ? 0 : pages[pages.count / 2], p95, pages.last ?? 0
        ))
        // A save as the app makes one, after: forty rows written and their docs made with it.
        let some = try await file.db.read { db in try Int64.fetchAll(db, sql: "SELECT rowid FROM note ORDER BY rowid DESC LIMIT 40") }
        // A reader's marks on forty rows: the update trigger asked, nothing due.
        let marksStart = clock.now
        try await file.db.write { db in
            for rowid in some {
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.favourited', json('true')) WHERE rowid = ?", arguments: [rowid])
            }
            StoreFile.drainWordsInSave(db)
        }
        print(String(format: "[\(label)] forty rows' marks changed in one save, the trigger asked: %.1f ms", milliseconds(clock.now - marksStart)))
        try await file.db.write { db in try db.execute(sql: "DROP TRIGGER note_words_upd") }
        let bareStart = clock.now
        try await file.db.write { db in
            for rowid in some {
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.favourited', json('false')) WHERE rowid = ?", arguments: [rowid])
            }
        }
        print(String(format: "[\(label)] the same with no update trigger: %.1f ms", milliseconds(clock.now - bareStart)))
        // Put back as it was, alone: through `makeWords` a lost trigger starts the index again.
        try await file.db.write { db in try db.execute(sql: StoreFile.wordsSchema.last!) }
        let saveStart = clock.now
        try await file.db.write { db in
            for rowid in some {
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', json_extract(facts, '$.body') || ' ') WHERE rowid = ?", arguments: [rowid])
            }
            StoreFile.drainWordsInSave(db)
        }
        print(String(format: "[\(label)] forty rows' words changed and their docs made in one save: %.1f ms", milliseconds(clock.now - saveStart)))
        let newStart = clock.now
        try await file.db.write { db in
            try db.execute(sql: """
                INSERT INTO note (host, id, posted_at, categories, facts, gone_at, kept, bookmarked, edited_at, earlier, language, refs, refs_due)
                SELECT host, id || '-new', posted_at, categories, facts, gone_at, kept, bookmarked, edited_at, earlier, language, refs, refs_due
                FROM note WHERE rowid IN (SELECT value FROM json_each(?))
                """, arguments: [String(decoding: try JSONEncoder().encode(some), as: UTF8.self)])
            StoreFile.drainWordsInSave(db)
        }
        print(String(format: "[\(label)] forty new rows and their docs made in one save: %.1f ms", milliseconds(clock.now - newStart)))
        // Merged into one (what C27 runs after a letting go), and forty more.
        let optimizeStart = clock.now
        try await file.db.write { db in try db.execute(sql: "INSERT INTO note_words(note_words) VALUES ('optimize')") }
        print(String(format: "[\(label)] optimize: %.1f ms; file in use \(megabytes(file.bytesHeld()))", milliseconds(clock.now - optimizeStart)))
        let againStart = clock.now
        try await file.db.write { db in
            try db.execute(sql: """
                INSERT INTO note (host, id, posted_at, categories, facts, gone_at, kept, bookmarked, edited_at, earlier, language, refs, refs_due)
                SELECT host, id || '-again', posted_at, categories, facts, gone_at, kept, bookmarked, edited_at, earlier, language, refs, refs_due
                FROM note WHERE rowid IN (SELECT value FROM json_each(?))
                """, arguments: [String(decoding: try JSONEncoder().encode(some), as: UTF8.self)])
            StoreFile.drainWordsInSave(db)
        }
        print(String(format: "[\(label)] after it, forty new rows and their docs in one save: %.1f ms", milliseconds(clock.now - againStart)))
        // A keyword asked of the index, by size of answer.
        for keyword in ["的", "一二", Fold.key(String(Character(Unicode.Scalar(0x4E00)!))) + Fold.key(String(Character(Unicode.Scalar(0x4E07)!)))] {
            let start = clock.now
            let found = try file.wordCandidates(keyword)?.count ?? -1
            print(String(format: "[\(label)] candidates of a %d-character keyword: %d in %.1f ms", keyword.count, found, milliseconds(clock.now - start)))
        }
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        return p95
    }

    @Test("270,000 synthetic rows: the words built behind pages that wait under 250 ms",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = Self.synthetic(270_000)
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: notes)
        try await file.makeIndexes()
        // The cutting alone, in Swift, for the share of the build it is.
        let clock = ContinuousClock()
        let cutStart = clock.now
        var tokens = 0
        for note in notes {
            tokens += WordGrams.doc(
                body: note.body, handle: note.handle, author: note.author,
                boosterHandle: note.boosterHandle, boostedBy: note.boostedBy, host: note.source.host
            ).utf8.count
        }
        print(String(format: "[synthetic] words cut in Swift alone: %.1f s, %@ of docs", Self.milliseconds(clock.now - cutStart) / 1000, Self.megabytes(tokens)))
        let p95 = try await Self.build(file, label: "synthetic")
        #expect(p95 < 250)
    }

    @Test("a copy of a real store: the words built behind pages that wait under 250 ms",
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
        let p95 = try await Self.build(file, label: "copy")
        try file.db.close()
        #expect(p95 < 250)
    }
}
