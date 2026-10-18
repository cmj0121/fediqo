import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// The months limit kept in the file a step at a time (#360, C32): each step reads at most so
/// many of the file's rows past the limit, lets go what the whole store would let go, and a save
/// lands between two steps — so what is left once every step ran is what the whole store keeps.
@Suite("The months limit over a file, a step at a time")
struct StoreMonthsInPartsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

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

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func post(
        _ id: String, _ source: Source = one, daysAgo: Double, refs: [Reference] = [], kept: Bool = false, body: String? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "A", handle: "a@\(source.host)", body: body ?? "b \(id)",
            postedAt: now.addingTimeInterval(-daysAgo * 86_400), categories: [.home], kept: kept, refs: refs
        )
    }

    /// `count` posts over two sources, posted up to two years back: a reblog of another row of
    /// its source every so often, a quote or an answer of one, and some kept — on both sides of
    /// any cutoff, so a row past it is held by one inside it, by a kept one, and by one past it.
    private static func seed(_ count: Int, seed: UInt64) -> [Note] {
        var random = Seeded(state: seed)
        return (0..<count).map { n in
            let source = sources[n % 2]
            // Another row of the same source.
            let other = "p\(2 * Int.random(in: 0..<(count / 2), using: &random) + n % 2)"
            var refs: [Reference] = []
            switch Int.random(in: 0..<20, using: &random) {
            case 0..<3: refs = [Reference(kind: .reblogs, id: other)]
            case 3..<5: refs = [Reference(kind: .quotes, id: other, state: .accepted)]
            case 5: refs = [Reference(kind: .answers, id: other)]
            default: break
            }
            return post(
                "p\(n)", source, daysAgo: Double.random(in: 0..<730, using: &random), refs: refs,
                kept: Int.random(in: 0..<25, using: &random) == 0
            )
        }
    }

    private func file(_ notes: [Note]) async throws -> StoreFile {
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes)
        try await file.makeIndexes()
        return file
    }

    private func keysOnFile(_ file: StoreFile) throws -> Set<NoteKey> {
        Set(try file.load().notes.map(\.key))
    }

    /// Every step of the limit over `pool`, each saved before the next, and what each let go.
    private func steps(
        _ pool: ItemStore, months: Int, step: Int, to file: StoreFile, between: (Int) async throws -> Void = { _ in }
    ) async throws -> [WentByLimit] {
        var went: [WentByLimit] = []
        var next: PageCursor?
        let cutoff = try #require(await pool.setLimit(months: months, from: Self.now))
        repeat {
            let made = await pool.letGoBeyond(cutoff, step: step, after: next)
            went.append(made.went)
            next = made.next
            try await file.save(await pool.takeChanges().changes)
            try await between(went.count)
        } while next != nil
        return went
    }

    @Test(
        "What is left once every step ran is what the whole store keeps, whatever the pool held, pinned or changed",
        arguments: [(1 as UInt64, 3), (2, 12), (3, 6), (4, 1)]
    )
    func asTheWholeStore(seed: UInt64, months: Int) async throws {
        let notes = Self.seed(400, seed: seed)
        let file = try await file(notes)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        // A small pool, so rows read leave it again and are read back as they are wanted.
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 30)
        // Some rows read into the pool, some of them drawn, and one kept and one let go of
        // keeping there and not saved — the same said to the whole store.
        var random = Seeded(state: seed &+ 99)
        let read = notes.indices.filter { _ in Int.random(in: 0..<4, using: &random) == 0 }.map { notes[$0].key }
        _ = await pool.notes(read)
        await pool.hold(Set(read.prefix(20)), drawnAt: await pool.drawn)
        for key in read.prefix(6) {
            let kept = !(notes.first { $0.key == key }?.kept ?? false)
            #expect(await pool.setKept(kept, for: key) == (await whole.setKept(kept, for: key)))
        }
        await whole.letGoBeyond(months: months, from: Self.now)
        let went = try await steps(pool, months: months, step: 7, to: file)
        let left = Set(await whole.snapshot().notes.map(\.key))
        #expect(try keysOnFile(file) == left)
        #expect(went.map(\.posts).reduce(0, +) == notes.count - left.count)
        #expect(went.count > 2, "taken in more than one step")
        // Nothing the pool still holds is a row that went.
        for key in read where !left.contains(key) { #expect(await pool.note(key) == nil) }
    }

    @Test("A step reads no more of the file than it is given, and lets no more go")
    func bounded() async throws {
        let notes = Self.seed(300, seed: 7)
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        var reads: [Int] = []
        var cursor: PageCursor?
        let cutoff = try #require(KeepPolicy.cutoff(keepingMonths: 2, from: Self.now, calendar: .current))
        repeat {
            let read = try file.beyond(cutoff, limit: 11, after: cursor)
            reads.append(read.rows.count)
            cursor = read.next
        } while cursor != nil
        #expect(reads.allSatisfy { $0 <= 11 })
        #expect(reads.reduce(0, +) == notes.filter { !$0.kept && $0.postedAt < cutoff }.count)
        // The kept rows laid in, as the first letting go lays them, with what they reblog or quote.
        #expect(await pool.readKept())
        let pooled = await pool.pooled - (try file.keptRows().count)
        let went = try await steps(pool, months: 2, step: 11, to: file)
        // The first step lets go of the pool's own past the limit too, and each after it no more
        // than it read.
        #expect(went[0].posts <= 11 + pooled)
        #expect(went.dropFirst().allSatisfy { $0.posts <= 11 })
        #expect(went.count == reads.count)
    }

    @Test("A row past the limit that is drawn, or whose change is on its way to the file, goes all the same")
    func pinnedAndTouchedGo() async throws {
        let old = Self.post("old", daysAgo: 400)
        let drawn = Self.post("drawn", daysAgo: 300)
        let recent = Self.post("recent", daysAgo: 1)
        let file = try await file([old, drawn, recent])
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = await pool.notes([old.key, drawn.key, recent.key])
        await pool.hold([drawn.key, old.key], drawnAt: await pool.drawn)
        // A change to the old row is on its way to the file when the limit acts.
        #expect(await pool.setKept(true, for: old.key))
        #expect(await pool.setKept(false, for: old.key) == true)
        let inFlight = await pool.takeChanges().changes
        #expect(inFlight.upserts.map(\.key) == [old.key])
        let cutoff = try #require(await pool.setLimit(months: 1, from: Self.now))
        let made = await pool.letGoBeyond(cutoff, step: 2_000, after: nil)
        #expect(made.went.posts == 2 && made.next == nil)
        // The save in flight fails: what it carried is taken back, and the row is still to go.
        await pool.putBack(inFlight)
        let owed = await pool.takeChanges().changes
        #expect(owed.upserts.isEmpty)
        #expect(Set(owed.deletes) == [old.key, drawn.key])
        try await file.save(owed)
        #expect(try keysOnFile(file) == [recent.key])
        #expect(await pool.note(old.key) == nil)
        #expect(await pool.note(drawn.key) == nil)
        // Said to be drawn again, neither is read back in.
        await pool.hold([drawn.key, old.key, recent.key], drawnAt: await pool.drawn)
        #expect(await pool.note(drawn.key) == nil)
        #expect(Set(await pool.all().map(\.key)) == [recent.key])
    }

    @Test("Spared as the whole store spares: by a kept row or one inside the limit, a reblog never, and never by a row past it")
    func spared() async throws {
        let notes = [
            Self.post("in", daysAgo: 1, refs: [Reference(kind: .quotes, id: "quoted", state: .accepted)]),
            Self.post("quoted", daysAgo: 400),
            Self.post("kept-reblog", daysAgo: 500, refs: [Reference(kind: .reblogs, id: "reblogged")], kept: true),
            Self.post("reblogged", daysAgo: 600),
            Self.post("past-quoting", daysAgo: 200, refs: [Reference(kind: .quotes, id: "past-quoted", state: .accepted)]),
            Self.post("past-quoted", daysAgo: 300),
            Self.post("in-quoting-reblog", daysAgo: 2, refs: [Reference(kind: .quotes, id: "old-reblog", state: .accepted)]),
            Self.post("old-reblog", daysAgo: 300, refs: [Reference(kind: .reblogs, id: "x")]),
            Self.post("x", daysAgo: 301),
            Self.post("other-host", Self.two, daysAgo: 1, refs: [Reference(kind: .quotes, id: "unheld", state: .accepted)]),
            Self.post("unheld", daysAgo: 400),
        ]
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let went = try await steps(pool, months: 3, step: 2, to: file)
        #expect(Set(try keysOnFile(file).map(\.id)) == ["in", "quoted", "kept-reblog", "reblogged", "in-quoting-reblog", "other-host"])
        #expect(went.map(\.posts).reduce(0, +) == 5)
        #expect(Set(went.flatMap(\.sources)) == ["one.example"])
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        await whole.letGoBeyond(months: 3, from: Self.now)
        #expect(Set(await whole.snapshot().notes.map(\.key)) == (try keysOnFile(file)))
    }

    @Test("What lands and is saved between two steps stays, and so does an old post it quotes")
    func arrivalsBetween() async throws {
        let notes = (0..<12).map { Self.post("old\($0)", daysAgo: 200 + Double($0)) } + [Self.post("new", daysAgo: 1)]
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let went = try await steps(pool, months: 3, step: 3, to: file) { step in
            guard step == 1 else { return }
            // Lands after the first step and is written before the second: it quotes a post the
            // steps have yet to reach.
            await pool.ingest([Self.post("arrived", daysAgo: 0, refs: [Reference(kind: .quotes, id: "old0", state: .accepted)])])
            try await file.save(await pool.takeChanges().changes)
        }
        #expect(Set(try keysOnFile(file).map(\.id)) == ["new", "arrived", "old0"])
        #expect(went.map(\.posts).reduce(0, +) == 11)
    }

    @Test("Over a file, every step at once lets go what the whole store would, and a page shows none past the limit")
    func allAtOnce() async throws {
        let notes = Self.seed(120, seed: 11)
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let went = await pool.letGoBeyond(months: 4, from: Self.now)
        #expect(went == (await whole.letGoBeyond(months: 4, from: Self.now)))
        try await file.save(await pool.takeChanges().changes)
        #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)))
    }

    @Test("What refers to a row is found by the id it names, and only a row of several references is read whole")
    func citesIndexed() async throws {
        let file = try await file([
            Self.post("a", daysAgo: 1, refs: [Reference(kind: .quotes, id: "b", state: .accepted)]),
            Self.post("b", daysAgo: 2),
            Self.post("c", daysAgo: 3, refs: [Reference(kind: .answers, statusID: "s"), Reference(kind: .quotes, id: "b", state: .accepted)]),
        ])
        let plan = try await file.db.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT rowid FROM note WHERE host = 'one.example' AND instr(refs, '"id"') > 0
                AND \(StoreFile.firstCited) IN (SELECT value FROM json_each('["b"]'))
                """).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("note_cites") }, "\(plan)")
        let found = try file.referring(to: [NoteKey(host: "one.example", id: "b")])
        #expect(Set(found.map(\.key.id)) == ["a", "c"])
        let staying = try file.referring(to: [NoteKey(host: "one.example", id: "b")], stayingFrom: Self.now.addingTimeInterval(-2 * 86_400))
        #expect(staying.map(\.key.id) == ["a"])
    }

    @Test("A step under a limit moved since lets nothing go: the newer limit's steps decide")
    func movedLimitStepsNothing() async throws {
        let notes = (0..<10).map { Self.post("p\($0)", daysAgo: 40 * Double($0)) }
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let short = try #require(await pool.setLimit(months: 1, from: Self.now))
        let first = await pool.letGoBeyond(short, step: 2, after: nil)
        #expect(first.went.posts == 2 && first.next != nil)
        // The person keeps a year now: the shorter run's next step is of a limit gone.
        let year = try #require(await pool.setLimit(months: 12, from: Self.now))
        let stale = await pool.letGoBeyond(short, step: 2, after: first.next)
        #expect(stale.went == .none && stale.next == nil)
        #expect(await pool.keepFrom == year)
        var next: PageCursor?
        repeat {
            next = await pool.letGoBeyond(year, step: 2, after: next).next
        } while next != nil
        try await file.save(await pool.takeChanges().changes)
        // What the short limit's one step let go stays gone; past that, only the year's cut.
        let left = Set(try keysOnFile(file).map(\.id))
        let oldest = notes.sorted { $0.postedAt < $1.postedAt }.prefix(2).map(\.id)
        let expected = Set(notes.filter { $0.postedAt >= year }.map(\.id)).subtracting(oldest)
        #expect(left == expected)
    }

    @Test("A row read in while the steps run, behind them, and gone from the pool again, is judged by the next step")
    func readInBehindTheCursor() async throws {
        let quoting = Self.post("quoting", daysAgo: 1, refs: [Reference(kind: .quotes, id: "quoted", state: .accepted)])
        let quoted = Self.post("quoted", daysAgo: 500)
        let others = (0..<6).map { Self.post("old\($0)", daysAgo: 300 - Double($0)) }
        let notes = [quoting, quoted] + others
        let file = try await file(notes)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 1)
        await pool.hold([], drawnAt: await pool.drawn)
        let cutoff = try #require(await pool.setLimit(months: 3, from: Self.now))
        // The first step passes the quoted post — spared by the post that quotes it.
        let first = await pool.letGoBeyond(cutoff, step: 2, after: nil)
        #expect(first.went.posts == 1 && first.next != nil)
        try await file.save(await pool.takeChanges().changes)
        // Then its author takes the quoting post back, and a page reads the quoted post in,
        // which leaves the pool again before the next step.
        await pool.forget(quoting.key)
        await whole.forget(quoting.key)
        try await file.save(await pool.takeChanges().changes)
        #expect(await pool.note(quoted.key) != nil)
        // A landing moves what is drawn past the read, so the read may leave.
        let fresh = Self.post("fresh", daysAgo: 0)
        await pool.ingest([fresh])
        await whole.ingest([fresh])
        try await file.save(await pool.takeChanges().changes)
        await pool.hold([], drawnAt: await pool.drawn)
        let left = await pool.pooled; #expect(left <= 1, "the premise: the quoted post left the pool, the landing alone stays (\(left))")
        var next = first.next
        while next != nil {
            next = await pool.letGoBeyond(cutoff, step: 2, after: next).next
            try await file.save(await pool.takeChanges().changes)
        }
        await whole.letGoBeyond(months: 3, from: Self.now)
        #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)))
        #expect(try keysOnFile(file) == [fresh.key])
    }

    // MARK: - #292

    /// Every file under `folder` holding `phrase`, by name.
    private func files(in folder: URL, holding phrase: String) throws -> [String] {
        let needle = Data(phrase.utf8)
        return try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted().filter { name in
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                return false
            }
            return try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    @Test("A row the months limit let go leaves no word of it in the file once the step is saved", arguments: ["months-gone-phrase-91c", "過了期限就不留下"])
    func leavesNothing(phrase: String) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let padding = String(repeating: "ordinary words about the day, and more of them. ", count: 12)
        let file = try StoreFile(at: dir)
        let notes = (0..<300).map { n in
            Self.post("p\(n)", daysAgo: n < 250 ? 400 + Double(n) : 1, body: "\(n < 250 ? phrase : "stays-put-phrase") \(padding)")
        }
        try await file.save(sources: Self.sources, notes: notes)
        #expect(try files(in: dir, holding: phrase) == ["index.sqlite"], "the premise: the words are in the file while held")
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = await pool.notes(notes.prefix(20).map(\.key))
        let went = try await steps(pool, months: 1, step: 100, to: file)
        #expect(went.map(\.posts).reduce(0, +) == 250)
        #expect(try files(in: dir, holding: phrase).isEmpty, "let go and saved, and still readable in the file")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"])
    }
}
