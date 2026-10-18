import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// The words of a post let go leave the words index's bytes too (#360, K9, C27): FTS5 deletes
/// lazily, so a deleted doc's tokens stay in its segment until the index is rewritten, and
/// `letWordsGo` rewrites it after the act's save has landed.
///
/// **Asked of the bytes, as #292's tests ask** (`LetGoLeavesNothingTests`): every file in the
/// store's folder read whole, and searched for the tokens the index keeps — a post's
/// three-codepoint runs, each a field letter and four base-36 characters a codepoint
/// (`WordGrams`), never the words themselves. FTS5 writes a term after the first on a page as
/// what it adds to the one before, so only some of a doc's tokens are whole in the file at any
/// time: each test first finds some there, and none after.
@Suite("The words of what is let go leave the words index", .enabled(if: StoreFile.wordsCapable), .watched)
struct LetGoWordsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func note(_ n: Int, body: String) -> Note {
        Note(
            id: "p\(n)", source: n % 2 == 0 ? one : two, author: "A", handle: "a@one.example", body: body,
            postedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), categories: [.home]
        )
    }

    /// `count` posts saying distinctive words of `kind`, numbered from `from`, and `staying`
    /// posts after them saying ordinary ones.
    private static func notes(_ kind: LetGoGrams.Kind, going count: Int, staying: Int, from: Int = 0) -> (going: [Note], staying: [Note]) {
        let going = (from..<(from + count)).map { note($0, body: LetGoGrams.words($0, kind)) }
        let stays = (0..<staying).map { note(from + count + $0, body: LetGoGrams.ordinary($0)) }
        return (going, stays)
    }

    /// A file holding `going` and `staying`, its words index built and merged.
    private func file(in dir: URL, _ going: [Note], _ staying: [Note]) async throws -> StoreFile {
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: going + staying, sources: Self.sources))
        try await file.buildWords(chunk: 250, capable: true)
        return file
    }

    @Test("A save that lets rows go leaves their tokens in the file, and letWordsGo takes them out", arguments: LetGoGrams.Kind.allCases)
    func letGoThenRewritten(kind: LetGoGrams.Kind) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(kind, going: 120, staying: 60)
        let file = try await file(in: dir, going, staying)
        let needles = LetGoGrams.needles(going, besides: staying)
        #expect(!(try LetGoGrams.found(needles, in: dir)).isEmpty, "the premise: their tokens are in the file while held")
        #expect(try !file.wordsLetGoOwed())

        try await file.save(RowChanges(deletes: going.map(\.key)))
        #expect(!(try LetGoGrams.found(needles, in: dir)).isEmpty, "the premise: FTS5 deletes lazily, and the save alone leaves them")
        #expect(try file.wordsLetGoOwed())

        #expect(try await file.letWordsGo())
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty, "rewritten, and a token of a row let go still in the file")
        #expect(try !file.wordsLetGoOwed())
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        // What stays is still found by the index.
        #expect(try file.wordCandidates(Fold.key("ordinary words"))?.count == staying.count)
        try file.db.close()
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty, "closed, and a token readable in or beside the file")
    }

    @Test("Several saves that let rows go are one rewrite, and a second ask with nothing let go since does nothing")
    func coalesced() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.ascii, going: 60, staying: 20)
        let file = try await file(in: dir, going, staying)
        let needles = LetGoGrams.needles(going, besides: staying)
        try await file.save(RowChanges(deletes: going.prefix(30).map(\.key)))
        try await file.save(RowChanges(deletes: going.dropFirst(30).map(\.key)))
        #expect(try await file.letWordsGo())
        #expect(try await !file.letWordsGo(), "nothing let go since, and the index rewritten again")
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
        // A save that writes and deletes nothing owes nothing.
        try await file.save(RowChanges(upserts: [Self.note(9_999, body: "a new one")]))
        try await file.save(RowChanges(deletes: [Self.note(123_456, body: "").key]))
        #expect(try !file.wordsLetGoOwed(), "a delete of a row not in the file owes a rewrite")
    }

    @Test("Rows let go beyond what a save drains — left due for the builder — lose their docs before the rewrite")
    func manyLeftDue() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.cjk, going: StoreFile.drainedInSave + 200, staying: 40)
        let file = try await file(in: dir, going, staying)
        let needles = LetGoGrams.needles(going, besides: staying)
        #expect(!(try LetGoGrams.found(needles, in: dir)).isEmpty, "the premise")
        try await file.save(RowChanges(deletes: going.map(\.key)))
        #expect(try #require(try file.wordsState()).due == going.count, "the premise: more than a save drains, left due")
        #expect(try await file.letWordsGo())
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
    }

    @Test("A row let go whose rowid the next row takes leaves no token of its own")
    func rowidTaken() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.ascii, going: 80, staying: 40)
        // The ones let go are the newest rows, so a row written after takes a rowid of theirs.
        let file = try await file(in: dir, staying, going)
        let needles = LetGoGrams.needles(going, besides: staying)
        let late = Self.note(50_000, body: LetGoGrams.ordinary(7))
        try await file.save(RowChanges(upserts: [late], deletes: going.map(\.key)))
        #expect(try await file.letWordsGo())
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
    }

    @Test("compact() takes the tokens out first, then gives the room back", arguments: [false, true])
    func compactFirst(incremental: Bool) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.cjk, going: 120, staying: 40)
        let file = try await file(in: dir, going, staying)
        if incremental { try await file.compact() }
        let needles = LetGoGrams.needles(going, besides: staying)
        try await file.save(RowChanges(deletes: going.map(\.key)))
        try await file.compact()
        #expect(try !file.wordsLetGoOwed())
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
        #expect(try await file.db.read { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") } == 0, "the room the rewrite freed given back")
    }

    @Test("A save that empties the store — a read back — takes every doc with its rows in that save", arguments: LetGoGrams.Kind.allCases)
    func emptied(kind: LetGoGrams.Kind) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, _) = Self.notes(kind, going: 150, staying: 0)
        let file = try await file(in: dir, going, [])
        let needles = LetGoGrams.needles(going, besides: [])
        #expect(!(try LetGoGrams.found(needles, in: dir)).isEmpty, "the premise")
        let arriving = (0..<30).map { Self.note(1_000 + $0, body: LetGoGrams.ordinary($0)) }
        try await file.save(sources: Self.sources, notes: arriving)
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty, "the store replaced, and a token of what it held still in the file")
        #expect(try !file.wordsLetGoOwed())
        // What arrived is indexed as any row written is.
        #expect(try file.wordCandidates(Fold.key("ordinary words"))?.count == arriving.count)
    }

    @Test("Nothing where the file has no words index, or this SQLite cannot keep one")
    func nothingWithoutTheIndex() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.ascii, going: 10, staying: 10)
        let file = try StoreFile(at: dir)
        try await file.save(RowChanges(upserts: going + staying, sources: Self.sources))
        try await file.save(RowChanges(deletes: going.map(\.key)))
        #expect(try await !file.letWordsGo(), "no index, and a rewrite")
        #expect(try await file.db.read { db in try db.tableExists("note_words") } == false, "and one made")

        try await file.buildWords(chunk: 250, capable: true)
        try await file.save(RowChanges(deletes: staying.prefix(3).map(\.key)))
        #expect(try await !file.letWordsGo(capable: false), "the feature off, and a rewrite")
        #expect(try file.wordsLetGoOwed(), "and the debt forgotten")
        #expect(try await file.letWordsGo())
    }

    @Test("Owed in the file: a run that ends before the rewrite leaves it owed for the next")
    func owedAcrossARun() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.cjk, going: 60, staying: 20)
        let needles = LetGoGrams.needles(going, besides: staying)
        do {
            let file = try await file(in: dir, going, staying)
            try await file.save(RowChanges(deletes: going.map(\.key)))
            try file.db.close()
        }
        let again = try StoreFile(at: dir)
        #expect(try again.wordsLetGoOwed())
        // What a launch asks once its first page shows.
        await again.letWordsGoIfOwed(in: StoreSaver(store: ItemStore(), file: again))
        #expect(try !again.wordsLetGoOwed())
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
        #expect(try again.wordsShape()?.isClean == true)
    }

    @Test("A large letting go, drained in parts while FTS5 merges what it deleted, is rewritten until the index is clean")
    func deleteMerge() async throws {
        let dir = try scratch()
        let once = try scratch()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: once)
        }
        // A tenth and more of an index large enough that its deletes start a merge of their own.
        let (going, staying) = Self.notes(.cjk, going: 1_500, staying: 3_500)
        let needles = LetGoGrams.needles(going, besides: staying)
        for folder in [dir, once] {
            let file = try await Self.smallPaged(in: folder, staying + going)
            try await file.save(RowChanges(deletes: going.map(\.key)))
            #expect(try #require(try file.wordsState()).due == going.count, "the premise: left due, drained in parts")
            #expect(try await file.letWordsGo(
                capable: true, passes: folder == once ? 1 : StoreFile.rewritePasses, steps: folder != once, pause: .zero
            ))
            let shape = try #require(try file.wordsShape())
            if folder == once {
                // The premise: one optimize alone is not enough here.
                #expect(!shape.isClean, "one optimize left the index clean: \(shape)")
                #expect(try file.wordsLetGoOwed(), "the mark taken off an index that is not clean")
            } else {
                #expect(shape == .init(segments: 1, tombstonePages: 0))
                #expect(try !file.wordsLetGoOwed())
                #expect(try LetGoGrams.found(needles, in: folder).isEmpty)
            }
        }
    }

    /// A file holding `notes`, its words index built with small pages, so the merge FTS5 starts
    /// of itself spans many writes, as it does on a store of hundreds of thousands of rows.
    private static func smallPaged(in folder: URL, _ notes: [Note]) async throws -> StoreFile {
        let file = try StoreFile(at: folder)
        try await file.save(RowChanges(upserts: notes, sources: sources))
        try await file.db.write { db in
            _ = try StoreFile.makeWords(db, capable: true)
            try db.execute(sql: "INSERT INTO note_words(note_words, rank) VALUES ('pgsz', 64)")
        }
        try await file.buildWords(chunk: 250, capable: true)
        return file
    }

    @Test("Saves land between two merge steps — one letting more go, one writing — and the rewrite still ends clean, each step where a save would run")
    func savesBetweenSteps() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.cjk, going: 1_500, staying: 3_500)
        // The last staying posts go too, by a save made between two steps.
        let late = Array(staying.suffix(200))
        let stays = Array(staying.dropLast(200))
        let needles = LetGoGrams.needles(going + late, besides: stays)
        let file = try await Self.smallPaged(in: dir, stays + late + going)
        let saver = StoreSaver(store: ItemStore(), file: file)
        try await file.save(RowChanges(deletes: going.map(\.key)))
        final class Seen: @unchecked Sendable { var shape: StoreFile.WordsShape?; var owed = false }
        let seen = Seen()
        #expect(try await file.letWordsGo(capable: true, in: saver, pause: .zero, meanwhile: {
            // Between two steps nothing holds the saver: a save runs where it would.
            try await saver.exclusively {
                try await file.save(RowChanges(upserts: [Self.note(80_000, body: LetGoGrams.ordinary(1))], deletes: late.map(\.key)))
            }
            seen.shape = try file.wordsShape()
            seen.owed = try file.wordsLetGoOwed()
        }))
        #expect(seen.owed, "the mark off before the last write")
        #expect(seen.shape?.isClean == false, "the premise: the save landed mid-way through the rewrite")
        #expect(try file.wordsShape() == .init(segments: 1, tombstonePages: 0))
        #expect(try !file.wordsLetGoOwed())
        #expect(try file.wordsState() == .init(floor: 0, due: 0))
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
        #expect(try file.wordCandidates(Fold.key("ordinary words"))?.count == stays.count + 1)
    }

    @Test("A doc taken out for a row deleted by something else — an older build, sqlite3 — owes a rewrite, whether a save or the builder drains it")
    func goneByOthers() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.ascii, going: 700, staying: 40)
        let file = try await file(in: dir, going, staying)
        let needles = LetGoGrams.needles(going, besides: staying)
        // A few, by SQL alone: the next save drains them.
        try await file.db.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id IN ('p0', 'p1', 'p2')")
        }
        #expect(try !file.wordsLetGoOwed())
        try await file.save(RowChanges(upserts: [Self.note(90_000, body: "a new one")]))
        #expect(try file.wordsLetGoOwed(), "a save drained a gone row's doc and owed nothing")
        #expect(try await file.letWordsGo())

        // Many, by SQL alone: more than a save drains, so the builder does.
        try await file.db.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id LIKE 'p%' AND CAST(substr(id, 2) AS INTEGER) < 700")
        }
        try await file.save(RowChanges(upserts: [Self.note(90_001, body: "another")]))
        #expect(try !file.wordsLetGoOwed(), "the premise: left for the builder")
        _ = try await file.buildWordsStep(chunk: 250)
        #expect(try file.wordsLetGoOwed(), "the builder took out a gone row's doc and owed nothing")
        try await file.buildWords(chunk: 250, capable: true)
        #expect(try await file.letWordsGo())
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
    }
}

/// Distinctive words, and the tokens of them the words index keeps (`WordGrams`), searched for
/// in a folder's bytes.
enum LetGoGrams {
    enum Kind: String, CaseIterable, Sendable {
        case ascii, cjk
    }

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

    /// Post `n`'s words: runs of letters and digits no ordinary post says, or of CJK characters
    /// — about a hundred and fifty, so a few hundred posts fill many of the index's pages.
    static func words(_ n: Int, _ kind: Kind) -> String {
        var random = Seeded(state: UInt64(n) &* 7_919 &+ (kind == .cjk ? 1 : 0))
        let letters = Array("qxzjkv0123456789")
        return (0..<15).map { _ -> String in
            String((0..<10).map { _ -> Character in
                switch kind {
                case .ascii: letters.randomElement(using: &random)!
                case .cjk: Character(Unicode.Scalar(UInt32.random(in: 0x4E00...0x9FA5, using: &random))!)
                }
            })
        }.joined(separator: " ")
    }

    /// Words every staying post says, and a number.
    static func ordinary(_ n: Int) -> String {
        "ordinary words about the day \(n)"
    }

    /// The tokens of a body's three-codepoint runs, as the index keeps them.
    static func trigrams(_ body: String) -> Set<String> {
        let doc = WordGrams.doc(body: body, handle: "", author: "", boosterHandle: nil, boostedBy: nil, host: "")
        return Set(doc.split(separator: " ").map(String.init).filter { $0.utf8.count == 13 && $0.hasPrefix("b") })
    }

    /// The tokens of `going`'s bodies no post of `staying` has.
    static func needles(_ going: [Note], besides staying: [Note]) -> Set<String> {
        let stays = staying.reduce(into: Set<String>()) { $0.formUnion(trigrams($1.body)) }
        return going.reduce(into: Set<String>()) { $0.formUnion(trigrams($1.body)) }.subtracting(stays)
    }

    /// Which of `needles` are whole somewhere in a file under `folder` — the index, a journal,
    /// anything — read byte by byte, once a file.
    static func found(_ needles: Set<String>, in folder: URL) throws -> Set<String> {
        let wanted = Set(needles.map { Array($0.utf8) })
        guard let width = wanted.first?.count else { return [] }
        var found = Set<String>()
        for name in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            let bytes = [UInt8](try Data(contentsOf: url))
            guard bytes.count >= width else { continue }
            for start in 0...(bytes.count - width) where bytes[start] == 0x62 {
                let window = Array(bytes[start..<(start + width)])
                if wanted.contains(window) { found.insert(String(decoding: window, as: UTF8.self)) }
            }
        }
        return found
    }
}
