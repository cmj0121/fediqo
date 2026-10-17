@testable import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What is left of keeping within a room over a file (#360, C33, C26): a round of the room limit
/// read a hop at a time, a landed delete's keys no longer answered for, and the room the file
/// gives back a part at a time.
@Suite("Keeping within a room over a file, a part at a time")
struct StoreRoomInPartsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    private static let padding = String(repeating: "ordinary words about the day, and more of them. ", count: 8)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func key(_ i: Int) -> NoteKey { NoteKey(host: sources[i % 2].host, id: "p\(i)") }

    /// `count` posts a minute apart, newest first, over two sources: a reblog of a row two older
    /// every eleventh, a quote of one every thirteenth, one kept in forty. The oldest `going`
    /// say `phrase`, the rest `stays`, and none of those is kept or referred to.
    /// Every row in one of `tied` is posted at the moment of that run's first.
    private static func seed(
        _ count: Int, phrase: String = "gone", stays: String = "stays", going: Int = 0, tied: [Range<Int>] = []
    ) -> [Note] {
        (0..<count).map { i in
            let minute = tied.first { $0.contains(i) }?.lowerBound ?? i
            let source = sources[i % 2]
            var refs: [Reference] = []
            if i % 11 == 0, i + 2 < count - going {
                refs = [Reference(kind: .reblogs, id: "p\(i + 2)")]
            } else if i % 13 == 0, i + 4 < count - going {
                refs = [Reference(kind: .quotes, id: "p\(i + 4)", state: .accepted)]
            }
            return Note(
                id: "p\(i)", source: source, author: "A", handle: "a@\(source.host)",
                body: "\(i >= count - going ? phrase : stays) \(i) \(padding)",
                postedAt: at.addingTimeInterval(-Double(minute) * 60), categories: [.home],
                kept: i % 40 == 0 && i < count - going, refs: refs
            )
        }
    }

    private func file(_ notes: [Note], at dir: URL? = nil) async throws -> StoreFile {
        let file = try StoreFile(at: try dir ?? scratch())
        try await file.save(sources: Self.sources, notes: notes)
        try await file.makeIndexes()
        return file
    }

    /// What `store` owes the file, written and said to have landed, as the saver does.
    private func land(_ store: ItemStore, to file: StoreFile) async throws {
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
        await store.wrote(changes)
    }

    private func keysOnFile(_ file: StoreFile) throws -> Set<NoteKey> {
        Set(try file.load().notes.map(\.key))
    }

    private static func page(_ rows: [HeldRow]) -> Page {
        Page(timeline: UUID(), generation: 1, rows: rows, carried: [], next: nil, newest: nil, oldest: nil, exhausted: true)
    }

    // MARK: - A round in hops

    @Test("A round of the room limit over a file goes a hop at a time, and lets go what the whole store would", arguments: [2_500, 4_100])
    func inHops(count: Int) async throws {
        let notes = Self.seed(6_000)
        let file = try await file(notes)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 300)
        // Some of it read in, so the pool's rows are merged with the file's in every hop.
        _ = await pool.notes(stride(from: 0, to: 6_000, by: 7).map(Self.key))
        let hopsBefore = await pool.hopsTook.count
        let went = await pool.letGoOldest(count: count)
        #expect(went == (await whole.letGoOldest(count: count)))
        #expect(went.posts == count)
        let hops = await pool.hopsTook.count - hopsBefore
        #expect(hops >= (count + ItemStore.roomHop - 1) / ItemStore.roomHop, "\(hops) hops for \(count) posts")
        try await land(pool, to: file)
        #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)))
    }

    @Test("Rows of one moment across a hop's edge go in the order they arrived, as the whole store lets them go")
    func tiesAtAHopsEdge() async throws {
        // 4,600 rows, one in forty kept and so not among those a hop reads: the first hop's
        // edge falls inside a run of forty of one moment, and the second's inside a run of
        // seventy.
        let notes = Self.seed(4_600, tied: [2_530..<2_570, 470..<540])
        let file = try await file(notes)
        let first = try file.oldestKeys(ItemStore.roomHop, after: nil)
        let second = try file.oldestKeys(ItemStore.roomHop, after: first.next)
        let within = { (key: NoteKey?, run: Range<Int>) in run.map(Self.key).contains { $0 == key } }
        #expect(within(first.rows.last?.key, 2_530..<2_570), "the first hop's edge is not inside the tie")
        #expect(within(second.rows.last?.key, 470..<540), "the second hop's edge is not inside the tie")
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 300)
        _ = await pool.notes((2_520..<2_580).map(Self.key))
        for count in [1_990, 2_010, 4_005] {
            #expect(await pool.letGoOldest(count: count) == (await whole.letGoOldest(count: count)), "a round of \(count)")
            try await land(pool, to: file)
            #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)), "after a round of \(count)")
        }
    }

    @Test("A row kept between two hops, in a stretch not yet read, stays, as it would kept before the round")
    func keptBetweenHops() async throws {
        let notes = Self.seed(6_000)
        let file = try await file(notes)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 300)
        // A row the second hop reads: the 3,000th from the oldest. And one the pool holds.
        let later = Self.key(2_999)
        let pooled = Self.key(3_101)
        _ = await pool.notes([pooled])
        #expect(await whole.setKept(true, for: later))
        #expect(await whole.setKept(true, for: pooled))
        let once = OnceFlag()
        await pool.doBetweenHops { [pool] in
            guard once.first() else { return }
            _ = await pool.setKept(true, for: later)
            _ = await pool.setKept(true, for: pooled)
        }
        let went = await pool.letGoOldest(count: 5_000)
        #expect(went == (await whole.letGoOldest(count: 5_000)))
        try await land(pool, to: file)
        #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)))
        #expect(try keysOnFile(file).isSuperset(of: [later, pooled]))
    }

    @Test("A row that arrives between two hops behind them waits for the next round; one in the stretch not yet read is judged by this one")
    func arrivingBetweenHops() async throws {
        let notes = Self.seed(6_000)
        let file = try await file(notes)
        let whole = ItemStore(sources: Self.sources, notes: notes, readFromDisk: true)
        let pool = ItemStore(sources: Self.sources, rows: file, cap: 300)
        // Older than every row of the file: behind the hops already made.
        let old = Note(
            id: "arrived-old", source: Self.one, author: "A", handle: "a@one.example", body: "late",
            postedAt: Self.at.addingTimeInterval(-10_000 * 60), categories: [.home]
        )
        // Posted between two rows the later hops read: ahead of the hops made.
        let ahead = Note(
            id: "arrived-ahead", source: Self.one, author: "A", handle: "a@one.example", body: "late",
            postedAt: Self.at.addingTimeInterval(-1_500.5 * 60), categories: [.home]
        )
        // The whole store has the one ahead before its round, as the pool has it when its
        // hops reach that stretch.
        await whole.ingest([ahead])
        let once = OnceFlag()
        await pool.doBetweenHops { [pool] in
            guard once.first() else { return }
            await pool.ingest([old, ahead])
        }
        let went = await pool.letGoOldest(count: 5_000)
        #expect(went == (await whole.letGoOldest(count: 5_000)))
        #expect(await pool.note(old.key) != nil, "a row that arrived behind the hops was let go by them")
        #expect(await whole.note(ahead.key) == nil, "the premise: the whole store lets the one ahead go")
        #expect(await pool.note(ahead.key) == nil, "a row that arrived ahead of the hops was not judged by them")
        try await land(pool, to: file)
        // The file has every row the whole store keeps, and the one that arrived behind; neither
        // has the one ahead.
        #expect(try keysOnFile(file) == Set(await whole.snapshot().notes.map(\.key)).union([old.key]))
        #expect(try !keysOnFile(file).contains(ahead.key))
        // The next round begins from the oldest, and it is the first to go.
        await pool.doBetweenHops(nil)
        _ = await pool.letGoOldest(count: 1)
        #expect(await pool.note(old.key) == nil)
    }

    @Test("A round ends between two hops once a read back may put the file back, or is putting it back")
    func endsForAReadBack() async throws {
        let file = try await file(Self.seed(6_000))
        let pool = ItemStore(sources: Self.sources, rows: file)
        let once = OnceFlag()
        await pool.doBetweenHops { [pool] in
            guard once.first() else { return }
            await pool.mayBePutBack(true)
        }
        let went = await pool.letGoOldest(count: 5_000)
        #expect(went.posts > 0 && went.posts <= ItemStore.roomHop, "\(went.posts) went across the read back")
        // Held, nothing more goes; said no more, the next round goes on.
        #expect(await pool.letGoOldest(count: 100) == .none)
        await pool.mayBePutBack(false)
        #expect(await pool.letGoOldest(count: 100).posts == 100)
    }

    @Test("A step of the months limit lets nothing go while the file is being put back or may be, and the run ends there")
    func monthsStandDownForAReadBack() async throws {
        let file = try await file(Self.seed(3_000))
        let pool = ItemStore(sources: Self.sources, rows: file)
        let cutoff = try #require(await pool.setLimit(months: 1, from: Self.at.addingTimeInterval(30 * 86_400 - 86_400)))
        await pool.mayBePutBack(true)
        let held = await pool.letGoBeyond(cutoff, step: 500, after: nil)
        #expect(held.went == .none && held.next == nil)
        #expect(await pool.takeChanges().changes.deletes.isEmpty)
        // Said no more, the limit's steps let go again.
        await pool.mayBePutBack(false)
        let step = await pool.letGoBeyond(cutoff, step: 500, after: nil)
        #expect(step.went.posts > 0 && step.next != nil)
        // And between two steps, a read back that may put the file back ends the run.
        await pool.mayBePutBack(true)
        let next = await pool.letGoBeyond(cutoff, step: 500, after: step.next)
        #expect(next.went == .none && next.next == nil)
    }

    @Test("Asking whether anything may go reads a hop's worth of rows after the first")
    func holdsAsksInHops() async throws {
        // 5,000 rows, each odd one kept and quoting the even one older than it, which it so
        // spares — but for the newest ten: the one answer is found past 2,495 spared rows.
        let notes = (0..<5_000).map { (i: Int) -> Note in
            let quoting = i >= 10 && i % 2 == 1
            let refs: [Reference] = quoting ? [Reference(kind: .quotes, id: "p\(i + 1)", state: .accepted)] : []
            let posted = Self.at.addingTimeInterval(-Double(i) * 60)
            return Note(
                id: "p\(i)", source: Self.one, author: "A", handle: "a@one.example", body: "b \(i)",
                postedAt: posted, categories: [.home], kept: quoting, refs: refs
            )
        }
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let before = await pool.hopsTook.count
        #expect(await pool.holdsWhatRoomMayLetGo())
        let hops = await pool.hopsTook.count - before
        #expect(hops <= 3, "\(hops) hops to find a row that may go")
    }

    // MARK: - What the pool answers for

    @Test("A delete that landed leaves what the pool answers for; one that failed does not; and no row let go is read back")
    func landedLeavesLooked() async throws {
        let notes = Self.seed(3_000)
        let file = try await file(notes)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let read = (0..<100).map(Self.key)
        _ = await pool.notes(read)
        // The kept rows, read in once a run by the first question the room asks.
        #expect(await pool.holdsWhatRoomMayLetGo())
        let before = await pool.lookedCount
        let went = await pool.letGoOldest(count: 2_000)
        #expect(went.posts == 2_000)
        let grown = await pool.lookedCount
        #expect(grown >= before + 1_900)
        // A save that fails: what it carried is still answered for, and none of it is held.
        let failed = await pool.takeChanges().changes
        #expect(failed.deletes.count == 2_000)
        await pool.putBack(failed)
        #expect(await pool.lookedCount == grown)
        let oldest = Self.key(2_999)
        #expect(await pool.note(oldest) == nil)
        #expect(await pool.notes(failed.deletes).isEmpty, "a row let go was read back before its delete landed")
        // The next save lands: the keys leave, and the file no longer has the rows to give.
        try await land(pool, to: file)
        let after = await pool.lookedCount
        #expect(after <= before, "\(after) answered for, \(before) before")
        #expect(await pool.notes(failed.deletes).isEmpty)
        await pool.hold(Set(failed.deletes.prefix(50)), drawnAt: await pool.drawn)
        #expect(await pool.all().allSatisfy { !failed.deletes.contains($0.key) })
        #expect(try file.rowCount() == 1_000)
    }

    @Test("A page out when the delete lands keeps its keys answered for until it is back, and lays none of the rows it read before")
    func pageOutAcrossTheLanding() async throws {
        // The oldest thirty refer to nothing and nothing keeps them: the oldest twenty go.
        let file = try await file(Self.seed(600, going: 30))
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.holdsWhatRoomMayLetGo())
        let before = await pool.lookedCount
        let oldest = (590..<600).map(Self.key)
        let early = try file.rows(oldest)
        #expect(early.count == 10)
        let (began, reading) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let out = Task {
            try await pool.paged {
                reading.yield()
                for await _ in gate { break }
                return Self.page(early)
            }
        }
        for await _ in began { break }
        let went = await pool.letGoOldest(count: 20)
        #expect(went.posts == 20)
        try await land(pool, to: file)
        let whileOut = await pool.lookedCount
        #expect(whileOut == before + 20, "keys left while a page read before the landing was out")
        open.yield()
        _ = try await out.value
        #expect(await pool.lookedCount == before, "the page is back, and the keys stayed")
        for key in oldest { #expect(await pool.note(key) == nil, "a row let go was laid in from a page read before") }
    }

    @Test("The months limit's steps, each saved, leave what the pool answers for no larger than before")
    func monthsSteps() async throws {
        let file = try await file(Self.seed(3_000))
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = await pool.notes((0..<50).map(Self.key))
        #expect(await pool.holdsWhatRoomMayLetGo())
        let before = await pool.lookedCount
        // Rows a minute apart: a cut of a day leaves 1,440 of them and some they refer to.
        let cutoff = try #require(await pool.setLimit(months: 1, from: Self.at.addingTimeInterval(30 * 86_400 - 86_400)))
        var next: PageCursor?
        var went = 0
        repeat {
            let made = await pool.letGoBeyond(cutoff, step: 500, after: next)
            went += made.went.posts
            next = made.next
            try await land(pool, to: file)
        } while next != nil
        #expect(went > 1_000)
        #expect(await pool.lookedCount <= before)
        #expect(try file.rowCount() == 3_000 - went)
    }

    @Test("While a read back may put the file back, a landed delete's keys stay answered for, so its undo deletes them again")
    func readBackHoldsThem() async throws {
        let notes = Self.seed(800)
        let file = try await file(notes)
        let before = try file.load()
        let pool = ItemStore(sources: Self.sources, rows: file)
        // Let go before the read back writes, and landed after: no round runs once it may.
        let went = await pool.letGoOldest(count: 300)
        #expect(went.posts == 300)
        await pool.mayBePutBack(true)
        try await land(pool, to: file)
        #expect(await pool.lookedCount >= 300)
        // The undo puts the file back as it was, and owes each row the run let go a delete again.
        try await pool.restoring()
        try await file.save(sources: before.sources, notes: before.notes, said: before.said)
        await pool.oweEverything(fileHolds: before.notes.map(\.key), hosts: before.sources.map(\.host))
        try await land(pool, to: file)
        #expect(try file.rowCount() == 500)
        #expect(await pool.lookedCount < 300, "the deletes landed again and still answered for")
    }

    @Test("A read back whose undo of the index is refused for good, by no lock, holds the landed deletes no longer")
    func refusedUndoLetsGo() async throws {
        typealias Device = PackagerFixture.PackagerDevice
        let source = PackagerFixture.mastodon
        let from = try await Device(sources: [source], notes: (1...3).map { PackagerFixture.note("new-\($0)") })
        let held = (1...120).map { PackagerFixture.note("old-\($0)") }
        let onto = try await Device(sources: [source], notes: held)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        defer {
            from.remove()
            onto.remove()
            try? FileManager.default.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        let file = try #require(onto.file)
        // A store over the file that laid it in whole once this run and let most of it leave
        // the pool since: what the undo must read back first, and here cannot.
        let failing = StorePoolTests.Failing(file, failingFrom: nil)
        let pool = ItemStore(sources: [source], rows: failing, cap: 20)
        await pool.replace(sources: [source], notes: held)
        await pool.hold([], drawnAt: await pool.drawn)
        let packager = StorePackager(
            directory: onto.directory, file: file, store: pool, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            protected: .always, freeSpace: { _ in .max }, rounds: 1000
        )
        // The step after the index refuses, and the index's undo is refused for want of a read.
        let blocking = onto.directory.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
        try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))
        failing.fail(from: 1)
        await #expect(throws: PackageFault.unwound(steps: ["index"])) {
            try await packager.readBack(url, key: .password("password"), replacing: true) { _ in }
        }
        #expect(!packager.owesUndo, "refused by no lock, and still owed")
        #expect(await !pool.holdsForPutBack, "the landed deletes are held for an undo that will not come")
    }

    @Test("Said no more, the hold lets the landed keys go")
    func holdSaidNoMore() async throws {
        let file = try await file(Self.seed(800))
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.holdsWhatRoomMayLetGo())
        let before = await pool.lookedCount
        _ = await pool.letGoOldest(count: 300)
        await pool.mayBePutBack(true)
        try await land(pool, to: file)
        #expect(await pool.lookedCount >= before + 300)
        await pool.mayBePutBack(false)
        #expect(await pool.lookedCount == before)
    }

    // MARK: - The room given back a part at a time

    private static func pragma(_ file: StoreFile, _ name: String) async throws -> Int {
        try await file.db.read { db in try Int.fetchOne(db, sql: "PRAGMA \(name)") ?? 0 }
    }

    private static func rowids(_ file: StoreFile) async throws -> [Int64?] {
        try await file.db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT count(*), min(rowid), max(rowid), sum(rowid) FROM note")
            return (0..<4).map { (column: Int) -> Int64? in row?[column] }
        }
    }

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

    @Test("The scrub puts the file in the mode that gives room back a part at a time, and what it held is held")
    func theScrubSetsTheMode() async throws {
        let file = try await file(Self.seed(300))
        #expect(try await Self.pragma(file, "auto_vacuum") == 0)
        await file.scrubIfDue()
        #expect(try await Self.pragma(file, "auto_vacuum") == StoreFile.incremental)
        #expect(try file.rowCount() == 300)
        // Let go of nothing, and compacted: no step is made, and nothing moves.
        #expect(try await file.compactStep() == 0)
    }

    @Test("A file not yet in that mode is rebuilt whole by a compact, and is in it from then on")
    func notYetIncremental() async throws {
        let file = try await file(Self.seed(600))
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = await pool.letGoOldest(count: 400)
        try await land(pool, to: file)
        #expect(try await Self.pragma(file, "freelist_count") > 0)
        #expect(try await file.compactStep() == 0, "a step in a file not in the mode gave room back")
        try await file.compact()
        #expect(try await Self.pragma(file, "freelist_count") == 0)
        #expect(try await Self.pragma(file, "auto_vacuum") == StoreFile.incremental)
        // The next limit's room is given back in steps.
        _ = await pool.letGoOldest(count: 100)
        try await land(pool, to: file)
        #expect(try await file.compactStep(pages: 1) > 0, "the next compaction was not taken in steps")
    }

    @Test(
        "Once in that mode, the file gives back its freed pages a step at a time, moves no row, and nothing let go is left in any file of the folder",
        arguments: ["room-gone-phrase-7d2", "騰出的空間不留字"]
    )
    func inSteps(phrase: String) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try await file(Self.seed(2_000, phrase: phrase, stays: "stays-put-phrase", going: 1_500), at: dir)
        await file.scrubIfDue()
        #expect(try await Self.pragma(file, "auto_vacuum") == StoreFile.incremental)
        #expect(try files(in: dir, holding: phrase) == ["index.sqlite"], "the premise: the words are in the file while held")
        let pool = ItemStore(sources: Self.sources, rows: file)
        let went = await pool.letGoOldest(count: 1_500)
        #expect(went.posts == 1_500)
        try await land(pool, to: file)
        let pages = try await Self.pragma(file, "page_count")
        let free = try await Self.pragma(file, "freelist_count")
        let size = try await Self.pragma(file, "page_size")
        let held = file.bytesHeld()
        let rowids = try await Self.rowids(file)
        #expect(free > 64, "the premise: the let go left pages free")
        #expect(file.bytesOnDisk() == pages * size)
        var steps = 0
        while try await file.compactStep(pages: 32) > 0 { steps += 1 }
        steps += 1
        #expect(steps >= free / 32, "\(steps) steps for \(free) pages")
        #expect(try await Self.pragma(file, "freelist_count") == 0)
        // Shrunk by the pages freed, and what the rows weigh is what it was.
        let after = try await Self.pragma(file, "page_count")
        #expect(after <= pages - free && after >= pages - free - 2, "\(pages) pages, \(free) free, \(after) after")
        #expect(file.bytesOnDisk() == after * size)
        #expect(file.bytesHeld() <= held)
        #expect(try await Self.rowids(file) == rowids, "a step moved rows")
        #expect(try file.rowCount() == 500)
        // #292: what was let go is in no file of the folder, and what stays is where it was.
        let left = try files(in: dir, holding: phrase)
        #expect(left.isEmpty, "let go and compacted, and still readable in \(left)")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"])
    }

    @Test("compact() in that mode takes steps until no page is free")
    func compactLoops() async throws {
        let file = try await file(Self.seed(1_500))
        await file.scrubIfDue()
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = await pool.letGoOldest(count: 1_000)
        try await land(pool, to: file)
        let before = file.bytesOnDisk()
        try await file.compact()
        #expect(try await Self.pragma(file, "freelist_count") == 0)
        #expect(file.bytesOnDisk() < before)
        #expect(try await Self.pragma(file, "auto_vacuum") == StoreFile.incremental)
    }
}

/// True the first time it is asked, and never again.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    func first() -> Bool {
        lock.withLock {
            defer { asked = true }
            return !asked
        }
    }
}
