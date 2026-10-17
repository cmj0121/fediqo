import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// The words index (#360, K1): made outside the migrator, kept in step by triggers whatever
/// writes the file, built a chunk at a time — and at every moment every row a keyword finds by
/// `Fold.contains` is among the rows the index gives for it.
@Suite("The words index", .enabled(if: StoreFile.wordsCapable), .watched)
struct StoreWordsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]

    /// The same numbers every run, so a failure is one that can be had again.
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

    /// Pieces that fold, compose, join or split in ways a byte search could trip on.
    private static let pieces = [
        "Swift", "swift", "ＳＷＩＦＴ", "ｶﾀｶﾅ", "カタカナ", "台灣", "台", "灣", "日本語", "中文字",
        "café", "cafe\u{301}", "e\u{331}", "İSTANBUL", "istanbul", "I", "\u{00A0}", "\u{202F}", "\u{3000}",
        " ", "#tag", "🇺🇸", "🇦🇺", "🇸🇪", "👍", "👍🏽", "👨‍👩‍👧", "a", "の", "ß",
    ]

    private static func text(_ random: inout Seeded, most: Int = 6) -> String {
        (0..<Int.random(in: 0...most, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func note(_ n: Int, body: String, boosted: Bool? = nil, counts: Counts = Counts()) -> Note {
        Note(
            id: "p\(n)", source: n % 2 == 0 ? one : two, author: "A", handle: "a\(n % 3)@one.example", body: body,
            postedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), categories: [.home],
            boosted: boosted, counts: counts
        )
    }

    /// Every row's rowid and body, as the file holds it.
    private static func bodies(_ file: StoreFile) throws -> [Int64: String] {
        try file.db.read { db in
            var bodies: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT rowid AS r, json_extract(facts, '$.body') AS b FROM note") {
                bodies[row["r"]] = row["b"] ?? ""
            }
            return bodies
        }
    }

    /// For each keyword: the rows `Fold.contains` finds are all candidates.
    private static func checkSuperset(_ file: StoreFile, _ keywords: [String], _ step: String) throws -> Int {
        let bodies = try bodies(file)
        var narrowed = 0
        for keyword in keywords {
            let asked = Fold.key(keyword)
            let found = Set(bodies.filter { Fold.contains(Fold.key($0.value), asked) }.keys)
            guard let candidates = try file.wordCandidates(asked) else { continue }
            let missing = found.subtracting(candidates)
            #expect(missing.isEmpty, "\(step): \(keyword.unicodeScalars.map(\.value)) missed \(missing.count)")
            if candidates.count < bodies.count { narrowed += 1 }
        }
        return narrowed
    }

    private static func make(_ file: StoreFile) async throws {
        _ = try await file.db.write { db in try StoreFile.makeWords(db, capable: true) }
    }

    @Test("random texts and random writes — saves, deletes, an older build's rewrite in raw SQL, a VACUUM — never hide a row Fold.contains finds")
    func superset() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        var random = Seeded(state: 360)
        var next = 0
        var held: [Int: String] = [:]
        func fresh(_ count: Int) -> [Note] {
            (0..<count).map { _ in
                defer { next += 1 }
                let body = Self.text(&random)
                held[next] = body
                return Self.note(next, body: body)
            }
        }
        // Rows before the index is made: below its floor.
        try await file.save(RowChanges(upserts: fresh(30), sources: Self.sources))
        try await Self.make(file)
        var keywords: [String] = []
        for _ in 0..<12 { keywords.append(Self.text(&random, most: 2)) }
        keywords += ["台", "灣", "台灣", "ＳＷＩ", "istanbul", "é", "🇺🇸", "👍", "e", "a\u{00A0}"]
        var narrowed = 0
        for step in 0..<120 {
            // One- and two-character stretches of a held body, as keywords.
            if let body = held.values.randomElement(using: &random), !body.isEmpty {
                let characters = Array(body)
                let start = Int.random(in: 0..<characters.count, using: &random)
                keywords.append(String(characters[start...min(start + Int.random(in: 0...1, using: &random), characters.count - 1)]))
            }
            let kind = Int.random(in: 0..<10, using: &random)
            switch kind {
            case 0, 1:
                try await file.save(RowChanges(upserts: fresh(Int.random(in: 1...4, using: &random))))
            case 2:
                // A body changed, saved as the app saves it.
                guard let n = held.keys.randomElement(using: &random) else { break }
                let body = Self.text(&random)
                held[n] = body
                try await file.save(RowChanges(upserts: [Self.note(n, body: body)]))
            case 3:
                // A reader's mark and the counts, the words as they were.
                guard let n = held.keys.randomElement(using: &random) else { break }
                try await file.save(RowChanges(upserts: [Self.note(n, body: held[n]!, boosted: true, counts: Counts(replies: step))]))
            case 4:
                guard let n = held.keys.randomElement(using: &random) else { break }
                held[n] = nil
                try await file.save(RowChanges(deletes: [Self.note(n, body: "").key]))
            case 5:
                // An older build's whole save: every row deleted and written again, by SQL alone.
                try await file.db.write { db in
                    try db.execute(sql: "CREATE TEMP TABLE kept AS SELECT * FROM note")
                    try db.execute(sql: "DELETE FROM note")
                    try db.execute(sql: "INSERT INTO note SELECT * FROM kept ORDER BY random()")
                    try db.execute(sql: "DROP TABLE kept")
                }
            case 6:
                // An older build's change of words, by SQL alone.
                guard let n = held.keys.randomElement(using: &random) else { break }
                let body = Self.text(&random)
                held[n] = body
                try await file.db.write { db in
                    try db.execute(
                        sql: "UPDATE note SET facts = json_set(facts, '$.body', ?) WHERE id = ?", arguments: [body, "p\(n)"]
                    )
                }
            case 7:
                try await file.compact()
            default:
                for _ in 0..<Int.random(in: 1...3, using: &random) { _ = try await file.buildWordsStep(chunk: 7) }
            }
            narrowed += try Self.checkSuperset(file, keywords, "step \(step) (\(kind))")
        }
        // Built to the end: nothing below the floor and nothing due, so every candidate is a match.
        try await file.buildWords(chunk: 7, capable: true)
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        let built = try Self.checkSuperset(file, keywords, "built")
        #expect(built > keywords.count / 2)
        #expect(narrowed > 0)
    }

    @Test("a write between a build step's read and its write — a change of words, a delete, an older build's rewrite — hides no row")
    func writesMeanwhile() async throws {
        let meanwhile: [@Sendable (StoreFile) async throws -> Void] = [
            { file in
                try await file.db.write { db in
                    try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', '新聞 swift') WHERE rowid IN (SELECT rowid FROM note ORDER BY rowid DESC LIMIT 3)")
                }
            },
            { file in try await file.save(RowChanges(upserts: [Self.note(17, body: "回來了")], deletes: [Self.note(17, body: "").key])) },
            { file in
                try await file.db.write { db in
                    try db.execute(sql: "CREATE TEMP TABLE kept AS SELECT * FROM note")
                    try db.execute(sql: "DELETE FROM note")
                    try db.execute(sql: "INSERT INTO note SELECT * FROM kept ORDER BY id DESC")
                    try db.execute(sql: "DROP TABLE kept")
                }
            },
            { file in try await file.save(RowChanges(upserts: (100..<104).map { Self.note($0, body: "後來 \($0)") })) },
        ]
        for (n, write) in meanwhile.enumerated() {
            for builtFirst in [false, true] {
                let dir = try scratch()
                defer { try? FileManager.default.removeItem(at: dir) }
                let file = try StoreFile(at: dir)
                try await file.save(RowChanges(upserts: (0..<40).map { Self.note($0, body: "台灣 \($0)") }, sources: Self.sources))
                try await Self.make(file)
                // A gap in the first chunk, which a rewrite meanwhile fills with a row not read.
                try await file.db.write { db in try db.execute(sql: "DELETE FROM note WHERE rowid = 37") }
                if builtFirst {
                    try await file.buildWords(chunk: 250, capable: true)
                    // Due rows for the step to drain.
                    try await file.db.write { db in try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', 'due ' || id) WHERE rowid % 4 = 0") }
                }
                let keywords = ["台灣", "新聞", "swift", "回來", "後來", "due", "1", "p"]
                _ = try await file.buildWordsStep(chunk: 8) { try await write(file) }
                _ = try Self.checkSuperset(file, keywords, "meanwhile \(n), built \(builtFirst), after the step")
                try await file.buildWords(chunk: 8, capable: true)
                #expect(try file.wordsState() == .init(floor: 0, due: 0))
                _ = try Self.checkSuperset(file, keywords, "meanwhile \(n), built \(builtFirst), built")
            }
        }
    }

    @Test("a reader's mark, a count, a bookmark, kept — and their taking back — mark nothing due; words do")
    func marksAreNotWords() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<20).map { Self.note($0, body: "台灣 \($0)") }, sources: Self.sources))
        try await file.buildWords(chunk: 250, capable: true)
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        try await file.db.write { db in
            try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.boosted', json('true'), '$.favourited', json('true'))")
            try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.counts', json('{\"replies\":3}'))")
            try db.execute(sql: "UPDATE note SET bookmarked = 1, kept = 1, refs_due = 1, categories = '[]'")
            try StoreFile.make(StoreOp(number: 1, kind: .forgetReaderMarks(.allBut([]))), in: db)
        }
        #expect(try file.wordsState()?.due == 0)
        try await file.db.write { db in
            try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', 'other') WHERE id IN ('p1', 'p2')")
            try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.boostedBy', 'B') WHERE id = 'p3'")
        }
        #expect(try file.wordsState()?.due == 3)
        // And an ordinary save makes the docs of what it marked, in its own transaction.
        try await file.save(RowChanges(upserts: [Self.note(99, body: "新的字")]))
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        let added = try #require(try await file.db.read { db in try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE id = 'p99'") })
        #expect(try file.wordCandidates(Fold.key("新的")) == [added])
        #expect(try file.wordCandidates(Fold.key("台灣"))?.count == 18)
    }

    @Test("a save of more than it drains leaves the rest due, for the builder")
    func manyAreTheBuilders() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: [Self.note(0, body: "x")], sources: Self.sources))
        let builder = Self.builder(file)
        await builder.begin()
        await builder.idle()
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        // Few: made by the save itself, and the builder not asked.
        try await file.save(RowChanges(upserts: (1...10).map { Self.note($0, body: "y\($0)") }))
        #expect(try file.wordsState()?.due == 0)
        #expect(await builder.runs == 1)
        // Many: left due, passing every keyword meanwhile, and the builder set going again.
        try await file.save(RowChanges(upserts: (11...610).map { Self.note($0, body: "y\($0)") }))
        #expect(try file.wordCandidates("y")?.count == 610)
        await met("the builder took up what the save left") { ((try? file.wordsState()) ?? nil) == .init(floor: 0, due: 0) }
        await builder.idle()
        #expect(await builder.runs == 2)
        #expect(try file.wordCandidates("y")?.count == 610)
        #expect(try file.wordCandidates("x")?.count == 1)
        await builder.end()
    }

    /// A builder as the app's, but with no pause and its writes made as they come.
    private static func builder(
        _ file: StoreFile, protected: ProtectedData = .always,
        exclusively: @escaping WordsBuilder.Exclusively = { body in try await body() }
    ) -> WordsBuilder {
        WordsBuilder(file: file, exclusively: exclusively, protected: protected, chunk: 50, pause: .zero, capable: true)
    }

    @Test("the builder makes both indexes of what reblogs, as a build of the words does: a file that came with neither — a read back's — has both after it")
    func builderMakesBothReblogIndexes() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<20).map { Self.note($0, body: "r\($0)") }, sources: Self.sources))
        try file.dropDerivedObjects()
        let names = { try await file.db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'note_reblogs%' ORDER BY name")
        } }
        #expect(try await names().isEmpty, "the premise: a read back's file has neither")
        let builder = Self.builder(file)
        await builder.start()
        await builder.idle()
        #expect(try await names() == ["note_reblogs", "note_reblogs_odd"])
        await builder.end()
    }

    @Test("the builder stands down while the device is locked, and a wake-up sets it going again from where it stood")
    func builderStandsDown() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<200).map { Self.note($0, body: "z\($0)") }, sources: Self.sources))
        let available = OSAllocatedUnfairLock(initialState: false)
        let (wakes, wake) = AsyncStream<Void>.makeStream()
        let protected = ProtectedData(
            flag: { available.withLock { $0 } }, canary: { .reads }, remade: { .reads },
            unlockedForSomebody: { true }, changes: { wakes }
        )
        let builder = Self.builder(file, protected: protected)
        await builder.begin()
        await builder.idle()
        #expect(try file.wordsState() == nil)
        available.withLock { $0 = true }
        wake.yield()
        await met("a wake-up set the build going") { ((try? file.wordsState()) ?? nil) == .init(floor: 0, due: 0) }
        await builder.idle()
        await builder.end()
        wake.finish()
    }

    @Test("a build that fails says so and is tried again at the next asking; one ended is never set going")
    func builderFailsAndEnds() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<20).map { Self.note($0, body: "f\($0)") }, sources: Self.sources))
        let tries = OSAllocatedUnfairLock(initialState: 0)
        let builder = Self.builder(file) { body in
            if tries.withLock({ $0 += 1; return $0 }) == 1 { throw DatabaseError(resultCode: .SQLITE_BUSY) }
            return try await body()
        }
        await builder.begin()
        await builder.idle()
        #expect(await builder.failures == 1)
        #expect(try file.wordsState() == nil)
        await builder.start()
        await builder.idle()
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        await builder.end()
        await builder.start()
        #expect(await builder.runs == 2)
    }

    @Test("an index that lost a trigger is not trusted, and is built again from the start")
    func lostTrigger() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<20).map { Self.note($0, body: "t\($0)") }, sources: Self.sources))
        try await file.buildWords(chunk: 250, capable: true)
        // A rebuild of the table drops its triggers; rows written then are marked by nothing.
        try await file.db.write { db in
            try db.execute(sql: "DROP TRIGGER note_words_upd")
            try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', '失去的字') WHERE id = 'p3'")
        }
        #expect(try file.wordsState() == nil)
        #expect(try file.wordCandidates(Fold.key("失去")) == nil)
        try await file.buildWords(chunk: 250, capable: true)
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        let lost = try #require(try await file.db.read { db in try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE id = 'p3'") })
        #expect(try file.wordCandidates(Fold.key("失去")) == [lost])
        #expect(try file.wordCandidates("t3") == [])
    }

    @Test("built newest first, a chunk a write, and taken up again where it stopped by the next opening")
    func resumable() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<100).map { Self.note($0, body: "w\($0)") }, sources: Self.sources))
        try await Self.make(file)
        #expect(try file.wordsState() == .init(floor: 101, due: 0))
        #expect(try await file.buildWordsStep(chunk: 30))
        #expect(try file.wordsState()?.floor == 71)
        // Cancelled, it stops between chunks.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await file.buildWords(chunk: 30, capable: true)
        }
        _ = try? await cancelled.value
        #expect(try file.wordsState()?.floor == 71)
        try file.db.close()
        let again = try StoreFile(at: dir)
        #expect(try again.wordsState()?.floor == 71)
        try await again.buildWords(chunk: 30, capable: true)
        #expect(try again.wordsState() == .init(floor: 0, due: 0))
        #expect(try again.wordCandidates("w9")?.count == 11)
    }

    @Test("a VACUUM that renumbers the rows builds the index again from the start; one that does not leaves it")
    func rowidGuard() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: (0..<40).map { Self.note($0, body: "v\($0)") }, sources: Self.sources))
        try await file.buildWords(chunk: 250, capable: true)
        try await file.save(RowChanges(deletes: (0..<20).map { Self.note($0 * 2, body: "").key }))
        // SQLite keeps the rowids here: nothing is rebuilt.
        try await file.compact()
        await file.scrubIfDue()
        file.scrub()
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        // Renumbered — what SQLite says a VACUUM may do.
        try await file.db.writeWithoutTransaction { db in
            try StoreFile.guardingRowids(db) { try db.execute(sql: "UPDATE note SET rowid = rowid + 1000") }
        }
        let highest = try await file.db.read { db in try Int64.fetchOne(db, sql: "SELECT max(rowid) FROM note") ?? 0 }
        #expect(try file.wordsState() == .init(floor: highest + 1, due: 0))
        #expect(try file.wordCandidates("v1")?.count == 20)
        try await file.buildWords(chunk: 250, capable: true)
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        let ones = try Self.bodies(file).filter { Fold.contains($0.value, "v1") }.count
        #expect(try file.wordCandidates("v1")?.count == ones)
    }

    @Test("the build makes the index a post's reblogs are found by, and a lookup by the post's name uses it")
    func reblogsIndex() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let post = Self.note(1, body: "words")
        let reblog = Note(
            id: "r1", source: Self.two, author: "B", handle: "b@two.example", body: "",
            postedAt: post.postedAt, categories: [.home], refs: [Reference(kind: .reblogs, id: "p1")]
        )
        try await file.save(RowChanges(upserts: [post, reblog], sources: Self.sources))
        try await file.buildWords(chunk: 250, capable: true)
        let lookup = "SELECT id FROM note INDEXED BY note_reblogs WHERE instr(refs, '\"reblogs\"') > 0 AND host = ? AND (CASE WHEN json_valid(refs) THEN json_extract(refs, '$[0].id') END) = ?"
        let found = try await file.db.read { db in try String.fetchAll(db, sql: lookup, arguments: ["two.example", "p1"]) }
        #expect(found == ["r1"])
    }

    @Test("where SQLite cannot keep it, nothing is made and the store saves as it did")
    func off() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.buildWords(chunk: 250, capable: false)
        try await file.save(RowChanges(upserts: [Self.note(0, body: "x")], sources: Self.sources))
        #expect(try file.wordsState() == nil)
        #expect(try file.wordCandidates("x") == nil)
        let made = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'note_words%' OR name = 'note_reblogs'") }
        #expect(made.isEmpty)
    }
}

/// **The words suites are never skipped where they should run.** They are enabled only where
/// SQLite can keep the index; on a Mac it always can — every SDK this builds with ships 3.43 or
/// later, with FTS5 — so a Mac that says otherwise is a fault, and fails here rather than
/// passing by running nothing.
@Suite("The words index can be kept here")
struct StoreWordsCapableTests {
    @Test("on a Mac, SQLite keeps the words index")
    func capable() {
        #if os(macOS)
        #expect(StoreFile.wordsCapable)
        #endif
    }
}
