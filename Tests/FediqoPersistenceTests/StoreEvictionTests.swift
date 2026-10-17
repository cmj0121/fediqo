@testable import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// Rows let go of the pool and read again from the file (#359, G-1, G-2): **with a cap of 50,
/// every way into the store merges as the store read whole does** — the rows let go are read
/// back as the file holds them and as the run's changes leave them — what a row that stays
/// holds stays with it, and nothing changed, on its way to the file, kept, drawn or newer than
/// what is drawn ever leaves.
@Suite("Rows let go of the pool and read again")
struct StoreEvictionTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    private static let size = 240
    private static let cap = 50

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `i`th row's id: rows three apart are of one host, so each refers within its own.
    private static func id(_ i: Int) -> String { "p\(i)" }
    private static func source(_ i: Int) -> Source { i % 3 == 0 ? two : one }
    private static func key(_ i: Int) -> NoteKey { NoteKey(host: source(i).host, id: id(i)) }
    private static let keys = (0..<size).map(key)

    /// Posts ten minutes apart, newest first, each listed by its timeline: reblogs and quotes of
    /// an older post, kept posts, posts saying what the reader did, and posts carrying "newer
    /// posts remain".
    private static func seed() -> [Note] {
        (0..<size).map { i in
            let source = source(i)
            var refs: [Reference] = []
            if i % 17 == 0, i + 3 < size {
                refs = [Reference(kind: .reblogs, id: id(i + 3))]
            } else if i % 19 == 0, i + 6 < size {
                refs = [Reference(kind: .quotes, id: id(i + 6), state: .accepted)]
            }
            let category: FediqoCore.Category = i % 4 == 0 ? .public : .home
            return Note(
                id: id(i), source: source, author: "A", handle: "a@\(source.host)", body: "b \(i)",
                postedAt: at.addingTimeInterval(-Double(i) * 600), categories: [category],
                favourited: i % 5 == 0 ? true : nil, statusID: "s\(i)",
                gaps: i % 29 == 0 ? [TimelineGap(.newerRemain, in: category)] : [],
                listed: [category: "\(100_000 - i)"], kept: i % 41 == 0, refs: refs
            )
        }
    }

    private static func post(_ id: String, _ source: Source = one, refs: [Reference] = []) -> Note {
        Note(
            id: id, source: source, author: "A", handle: "a@\(source.host)", body: "b \(id)",
            postedAt: at.addingTimeInterval(600), categories: [.home], statusID: id, refs: refs
        )
    }

    /// Two files holding the seed: one for the store over the file, one for the store read whole.
    private func twoFiles() async throws -> (pooled: StoreFile, whole: StoreFile) {
        let settled = await ItemStore(sources: Self.sources, notes: Self.seed()).snapshot()
        let pooled = try StoreFile(at: try scratch())
        let whole = try StoreFile(at: try scratch())
        for file in [pooled, whole] {
            try await file.save(sources: settled.sources, notes: settled.notes, said: settled.said)
            try await file.makeIndexes()
        }
        return (pooled, whole)
    }

    private func wholeStore(_ file: StoreFile) throws -> ItemStore {
        let loaded = try file.load()
        return ItemStore(sources: loaded.sources, notes: loaded.notes, said: loaded.said, readFromDisk: true)
    }

    /// Every row of the seed but `except` read into `pool`, twenty at a time, oldest seen first.
    private func readAll(_ pool: ItemStore, except: Set<NoteKey> = []) async {
        let wanted = Self.keys.filter { !except.contains($0) }
        for start in stride(from: 0, to: wanted.count, by: 20) {
            _ = await pool.notes(Array(wanted[start..<min(start + 20, wanted.count)]))
        }
    }

    /// What `store` owes the file, written and said to have landed, as the saver does.
    private func land(_ store: ItemStore, to file: StoreFile) async throws {
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
        await store.wrote(changes)
    }

    private func save(_ store: ItemStore, to file: StoreFile) async throws {
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
    }

    /// Saved, every row read in again, and the pool let down to its cap with nothing drawn.
    private func churn(_ pool: ItemStore, _ file: StoreFile) async throws {
        try await land(pool, to: file)
        await readAll(pool)
        await pool.hold([], drawnAt: await pool.drawn)
        #expect(await pool.pooled <= Self.cap)
        try await heldWhole(pool, file)
    }

    private func pooledKeys(_ pool: ItemStore) async -> Set<NoteKey> {
        Set((await pool.all() + pool.replies()).map(\.key))
    }

    /// I2: what every row of the pool holds with it is in the pool, where the file has it.
    private func heldWhole(_ pool: ItemStore, _ file: StoreFile) async throws {
        let pooled = await pool.all() + pool.replies()
        #expect(pooled.count == (await pool.pooled))
        let reached = Set(pooled.flatMap { $0.heldWith + [$0.topicKey].compactMap { $0 } })
        let onFile = Set(try file.rows(Array(reached)).map(\.note.key))
        let missing = onFile.subtracting(pooled.map(\.key))
        #expect(missing.isEmpty, "\(missing.count) rows held by a row of the pool are not in it")
    }

    private func rows(_ file: StoreFile) throws -> [NoteKey: Note] {
        Dictionary(uniqueKeysWithValues: try file.load().notes.map { ($0.key, $0) })
    }

    /// `act` on a store over the file, let down to 50 rows first and again whenever `act`
    /// churns it, and on the store read whole: the same answer; every row of the seed read
    /// again as the whole store holds it; and once both are saved, the same rows on disk.
    /// `targets` are rows the pool let go of before `act` begins.
    private func agree<Answer: Equatable & Sendable>(
        targets: [Int] = [],
        _ act: @Sendable (ItemStore, _ churn: @Sendable () async throws -> Void) async throws -> Answer
    ) async throws {
        let (pooledFile, wholeFile) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: pooledFile, cap: Self.cap)
        await readAll(pool)
        await pool.hold([], drawnAt: await pool.drawn)
        #expect(await pool.pooled <= Self.cap)
        try await heldWhole(pool, pooledFile)
        let left = await pooledKeys(pool)
        for target in targets { #expect(!left.contains(Self.key(target)), "row \(target) is still in the pool") }
        let whole = try wholeStore(wholeFile)
        let answer = try await act(pool) { try await churn(pool, pooledFile) }
        #expect(answer == (try await act(whole) {}))
        try await churn(pool, pooledFile)
        let pooledRows = await pool.notes(Self.keys)
        let wholeRows = await whole.notes(Self.keys)
        let differing = Self.keys.filter { pooledRows[$0] != wholeRows[$0] }
        #expect(differing.isEmpty, "read again, \(differing.count) rows differ: \(differing.prefix(5).map(\.id))")
        try await land(pool, to: pooledFile)
        try await save(whole, to: wholeFile)
        let onPooled = try rows(pooledFile)
        let onWhole = try rows(wholeFile)
        #expect(Set(onPooled.keys) == Set(onWhole.keys))
        let differingOnDisk = onWhole.keys.filter { onPooled[$0] != onWhole[$0] }
        #expect(differingOnDisk.isEmpty, "\(differingOnDisk.count) rows differ on disk")
    }

    // MARK: - Every way in, after rows left and are read again

    @Test("a landing merges with rows let go of the pool as with rows held")
    func admit() async throws {
        try await agree(targets: [1, 2, 4]) { store, churn in
            var copy = Self.seed()[1]
            copy.categories = [.public]
            copy.counts = Counts(replies: 3)
            await store.ingest([
                copy,
                Self.post("n1", refs: [Reference(kind: .quotes, id: Self.id(2), state: .accepted)]),
                Self.post("n2", refs: [Reference(kind: .reblogs, id: Self.id(4))]),
            ])
            try await churn()
            return await store.note(NoteKey(host: "one.example", id: "n1"))?.refsUnheld
        }
    }

    @Test("a read on takes newer posts remain off rows let go, and marks the one it names, which stays")
    func readOn() async throws {
        try await agree(targets: [9, 87]) { store, churn in
            var copy = Self.seed()[9]
            copy.listed = [.home: "200000"]
            await store.land(ReadOn(notes: [copy], newerRemainAbove: Self.key(9)), of: .home, ifSourceHere: "two.example")
            try await churn()
            return await store.newestListedID(host: "two.example", category: .home)
        }
    }

    @Test("the newest id a timeline listed counts the rows let go of the pool")
    func newestListed() async throws {
        try await agree(targets: [1, 2, 5]) { store, _ in
            var newest: [String?] = []
            for host in ["one.example", "two.example"] {
                for category: FediqoCore.Category in [.home, .public] {
                    newest.append(await store.newestListedID(host: host, category: category))
                }
            }
            return newest
        }
    }

    @Test("the newest listed row that left, read again and taken back, gives way to the next that left")
    func newestListedTakenBack() async throws {
        try await agree(targets: [1, 2]) { store, _ in
            await store.forget(Self.key(1), at: Self.at)
            return await store.newestListedID(host: "one.example", category: .home)
        }
    }

    @Test("keeping and un-keeping reach rows let go of the pool")
    func kept() async throws {
        try await agree(targets: [5]) { store, churn in
            let kept = [await store.setKept(true, for: Self.key(5)), await store.setKept(false, for: Self.key(41))]
            try await churn()
            return kept
        }
    }

    @Test("a post taken back goes whether or not it was let go of the pool")
    func forget() async throws {
        try await agree(targets: [2, 25, 51]) { store, churn in
            for i in [2, 25, 51] { await store.forget(Self.key(i), at: Self.at) }
            try await churn()
            return await store.note(Self.key(54)) != nil
        }
    }

    @Test("marks taken back and given again by the next reader are kept by a row read again after it left")
    func readerMarks() async throws {
        try await agree(targets: [5]) { store, churn in
            await store.forgetReaderMarks(host: "one.example")
            try await churn()
            var copy = Self.seed()[5]
            copy.asked = ReadMoment.now()
            await store.ingest([copy])
            try await churn()
            return [await store.note(Self.key(5))?.favourited, await store.note(Self.key(10))?.favourited]
        }
    }

    @Test("a post named by its source's id is found again once the row that found it first has left")
    func named() async throws {
        try await agree { store, churn in
            let quoting = { (id: String) in
                Self.post(id, refs: [Reference(kind: .quotes, statusID: "s4", state: .accepted)])
            }
            await store.ingest([quoting("a1")])
            try await churn()
            if store.heldInPart {
                let left = await pooledKeys(store)
                #expect(!left.contains(NoteKey(host: "one.example", id: "a1")) && !left.contains(Self.key(4)))
            }
            await store.ingest([quoting("b1")])
            return await store.note(NoteKey(host: "one.example", id: "b1"))?.refs
        }
    }

    // MARK: - What never leaves

    @Test("nothing changed, on its way to the file, kept, drawn or laid in since the drawing leaves")
    func whatStays() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        let pins = Set((10..<15).map(Self.key))
        let late = Set([Self.key(22), Self.key(23)])
        await readAll(pool, except: late)
        #expect(await pool.setKept(true, for: Self.key(30)))
        try await land(pool, to: file)
        #expect(await pool.markGone(Self.key(31)))
        let (taken, _) = await pool.takeChanges()
        try await file.save(taken)
        #expect(await pool.markGone(Self.key(32)))
        let drawnAt = await pool.drawn
        _ = await pool.notes(Array(late))
        let before = await pool.drawn
        await pool.hold(pins, drawnAt: drawnAt)
        #expect(await pool.drawn > before)
        #expect(await pool.pooled <= Self.cap)
        let staying = pins.union(late).union([30, 31, 32].map(Self.key))
        #expect(staying.isSubset(of: await pooledKeys(pool)))
        try await heldWhole(pool, file)
        // Landed, the save's row is the file's; drawn again, the rest still stay.
        await pool.wrote(taken)
        await readAll(pool)
        await pool.hold(pins, drawnAt: await pool.drawn)
        let left = await pooledKeys(pool)
        #expect(pins.union([30, 32].map(Self.key)).isSubset(of: left))
        try await heldWhole(pool, file)
    }

    @Test("no row leaves while a page is out, so a page read before a change cannot lay an older copy in")
    func waitsForPages() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        await readAll(pool)
        // Before the screens first say what they draw, nothing leaves.
        try await land(pool, to: file)
        #expect(await pool.pooled == Self.size)
        let marked = Self.key(7)
        let early = try file.rows([marked])
        let (began, reading) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let out = Task {
            try await pool.paged {
                reading.yield()
                for await _ in gate { break }
                return Page(
                    timeline: UUID(), generation: 1, rows: early, carried: [], next: nil, newest: nil, oldest: nil,
                    exhausted: true
                )
            }
        }
        for await _ in began { break }
        #expect(await pool.markGone(marked, at: Self.at))
        try await land(pool, to: file)
        await pool.hold([], drawnAt: await pool.drawn)
        #expect(await pool.pooled == Self.size)
        open.yield()
        _ = try await out.value
        #expect(await pool.pooled <= Self.cap)
        #expect(await pool.note(marked)?.goneSince == Self.at)
        try await heldWhole(pool, file)
    }

    @Test("a store held whole never lets a row go")
    func wholeNeverLeaves() async {
        let whole = ItemStore(sources: Self.sources, notes: Self.seed())
        await whole.hold([], drawnAt: 0)
        #expect(await whole.pooled == Self.size)
    }

    @Test("what each screen draws stays beside what another draws, and goes once that screen is gone")
    func screensHoldTheirOwn() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        let one = UUID()
        let two = UUID()
        let first = Self.key(1)
        let second = Self.key(2)
        // Each screen says it draws before anything is read: what is read since stays, until
        // both have said what they draw of it.
        var at = await pool.drawn
        await pool.hold([first], drawnAt: at, by: one)
        await pool.hold([second], drawnAt: at, by: two)
        await readAll(pool)
        at = await pool.drawn
        await pool.hold([first], drawnAt: at, by: one)
        #expect(await pool.pooled > Self.cap, "the other screen's drawing is older than what was read")
        await pool.hold([first], drawnAt: at, by: one)
        await pool.hold([second], drawnAt: at, by: two)
        #expect(await pool.pooled <= Self.cap)
        #expect(await pooledKeys(pool).isSuperset(of: [first, second]))
        // The second says it draws nothing now: what the first draws stays all the same.
        await readAll(pool)
        at = await pool.drawn
        await pool.hold([first], drawnAt: at, by: one)
        await pool.hold([], drawnAt: at, by: two)
        #expect(await pooledKeys(pool).contains(first))
        #expect(!(await pooledKeys(pool)).contains(second))
        // The first gone: what it drew goes as any row.
        await readAll(pool)
        at = await pool.drawn
        await pool.hold([], drawnAt: at, by: two)
        #expect(await pooledKeys(pool).contains(first))
        await pool.letGoOfPins(by: one)
        #expect(!(await pooledKeys(pool)).contains(first))
        #expect(await pool.pooled <= Self.cap)
        // What the screen gone says after — a saying on its way as it went — is not heard.
        await readAll(pool)
        _ = await pool.notes([first])
        await pool.hold([first], drawnAt: 0, by: one)
        at = await pool.drawn
        await pool.hold([], drawnAt: at, by: two)
        #expect(!(await pooledKeys(pool)).contains(first))
        #expect(await pool.pooled <= Self.cap)
    }

    @Test("a copy that arrived this run, let go and read again, stays after the copy that arrived before it")
    func arrivalKept() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        let first = Self.post("dup")
        let second = Self.post("dup", Self.two)
        await pool.ingest([first])
        await pool.ingest([second])
        try await land(pool, to: file)
        await readAll(pool)
        await pool.hold([first.key], drawnAt: await pool.drawn)
        #expect(!(await pooledKeys(pool)).contains(second.key))
        _ = await pool.notes([second.key])
        let order = await pool.all().map(\.key)
        let firstAt = try #require(order.firstIndex(of: first.key))
        let secondAt = try #require(order.firstIndex(of: second.key))
        #expect(firstAt < secondAt)
    }

    @Test("the rows let go since a read back are read in again before the file is put back")
    func restoringReadsBack() async throws {
        let (pooledFile, wholeFile) = try await twoFiles()
        let previous = try pooledFile.load()
        let pool = ItemStore(sources: Self.sources, rows: pooledFile, cap: Self.cap)
        let whole = try wholeStore(wholeFile)
        await readAll(pool)
        await pool.hold([], drawnAt: await pool.drawn)
        let package = Self.seed().map { note in
            var read = note
            if !note.isReblog { read.counts = Counts(replies: 7) }
            return read
        }
        for (store, file) in [(pool, pooledFile), (whole, wholeFile)] {
            try await file.save(sources: Self.sources, notes: package)
            await store.replace(sources: Self.sources, notes: package)
        }
        // Laid in whole after the last drawing: nothing leaves before the next.
        await pool.wrote(RowChanges())
        #expect(await pool.pooled == Self.size)
        await pool.hold([], drawnAt: await pool.drawn)
        #expect(await pool.pooled <= Self.cap)
        // The undo: what left is read in again, the file put back, every row held owed again.
        for (store, file) in [(pool, pooledFile), (whole, wholeFile)] {
            try await store.restoring()
            try await file.save(sources: previous.sources, notes: previous.notes, said: previous.said)
            await store.oweEverything(fileHolds: previous.notes.map(\.key), hosts: previous.sources.map(\.host))
            try await save(store, to: file)
        }
        #expect(await pool.pooled == Self.size)
        let onPooled = try rows(pooledFile)
        let onWhole = try rows(wholeFile)
        #expect(onPooled == onWhole)
        #expect(onWhole[Self.key(1)]?.counts.replies == 7)
    }

    @Test("where what left will not be read in again, the undo is refused before the file is put back")
    func restoringRefused() async throws {
        let (file, _) = try await twoFiles()
        let failing = StorePoolTests.Failing(file, failingFrom: nil)
        let pool = ItemStore(sources: Self.sources, rows: failing, cap: Self.cap)
        await pool.replace(sources: Self.sources, notes: Self.seed())
        await pool.hold([], drawnAt: await pool.drawn)
        let left = Self.size - (await pool.pooled)
        #expect(left > 0)
        failing.fail(from: 1)
        await #expect(throws: RowsNotReadBack(count: left)) { try await pool.restoring() }
        // Asked again once the file reads: every one of them is read in.
        failing.fail(from: nil)
        try await pool.restoring()
        #expect(await pool.pooled == Self.size)
    }

    @Test("a pass over five thousand rows that can let none go is not made again until something moves")
    func passTakesLittle() async throws {
        let count = 5_500
        let notes = (0..<count).map { i in
            Note(
                id: "q\(i)", source: Self.one, author: "A", handle: "a@one.example", body: "b",
                postedAt: Self.at.addingTimeInterval(-Double(i)), categories: [.home],
                refs: i % 10 == 0 && i + 1 < count ? [Reference(kind: .quotes, id: "q\(i + 1)", state: .accepted)] : []
            )
        }
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 5_000)
        let keys = notes.map(\.key)
        for start in stride(from: 0, to: count, by: 500) { _ = await pool.notes(Array(keys[start..<start + 500])) }
        // Every row drawn: nothing may go, and asked again, nothing is looked at again.
        let all = Set(keys)
        await pool.hold(all, drawnAt: await pool.drawn)
        #expect(await pool.pooled == count)
        #expect(await pool.evictionPasses == 1)
        await pool.hold(all, drawnAt: await pool.drawn)
        #expect(await pool.evictionPasses == 1)
        // What is drawn changed: a pass again, and the pool down to nine tenths of its cap.
        await pool.hold([], drawnAt: await pool.drawn)
        #expect(await pool.evictionPasses == 2)
        #expect(await pool.pooled == 4_500)
    }
}
