import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What lets rows go, or changes many at once, **over a file the store holds only part of**
/// (#357, H2b): the room limit, a source removed, a span of days, posts gone from their source,
/// keeping stopped, a reader's marks taken back. Each is held to the store read whole: the same
/// act on both, both saved, and the two files hold the same rows, each as the other holds it.
@Suite("Letting go over a file the store holds in part")
struct StoreLettingGoTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    /// How many rows the seeded store holds.
    private static let size = 3_000

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `i`th row's id: rows three apart are of one host, so each refers within its own.
    private static func id(_ i: Int) -> String { "p\(i)" }
    private static func source(_ i: Int) -> Source { i % 3 == 0 ? two : one }

    /// A store of every kind of row a letting go asks about: posts ten minutes apart, newest
    /// first, every seventh posted in the same moment as the one before; kept posts; reblogs of
    /// an older post, some of them kept; posts quoting an older one; posts marked gone; posts
    /// saying what the reader did; posts owing a load as the reader.
    private static func seed() -> [Note] {
        (0..<size).map { i in
            let moment = at.addingTimeInterval(-Double(i - (i % 7 == 6 ? 1 : 0)) * 600)
            let source = source(i)
            var refs: [Reference] = []
            if i % 17 == 0, i + 3 < size {
                refs = [Reference(kind: .reblogs, id: id(i + 3))]
            } else if i % 19 == 0, i + 6 < size {
                refs = [Reference(kind: .quotes, id: id(i + 6), state: .accepted)]
            } else if i % 23 == 0 {
                refs = [Reference(kind: .quotes, statusID: "s-elsewhere-\(i)", state: .accepted)]
            }
            return Note(
                id: id(i), source: source, author: "A", handle: "a@\(source.host)", body: "b \(i)", postedAt: moment,
                categories: i % 4 == 0 ? [.public] : [.home],
                boosted: i % 10 == 0 ? false : nil, favourited: i % 5 == 0 ? true : nil, bookmarked: i % 11 == 0 ? true : nil,
                statusID: "s\(i)", goneSince: i % 13 == 0 ? at.addingTimeInterval(-Double(i % 5) * 86_400) : nil,
                kept: i % 97 == 0 || (i % 17 == 0 && i % 2 == 0), refs: refs, refsDue: i % 23 == 0
            )
        }
    }

    /// Two files holding the same rows, as a launch's store opened whole would leave them: one
    /// for the store over the file, one for the store read whole.
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

    /// The store over `file`, with every fifth row read in — some of what is let go is in the
    /// pool, most of it is not.
    private func pool(_ file: StoreFile) async -> ItemStore {
        let pool = ItemStore(sources: Self.sources, rows: file)
        let some = stride(from: 0, to: Self.size, by: 5).map { NoteKey(host: Self.source($0).host, id: Self.id($0)) }
        _ = await pool.notes(some)
        return pool
    }

    /// What `store` owes the file, written as the saver writes it.
    private func save(_ store: ItemStore, to file: StoreFile) async throws {
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
    }

    /// What `store` owes the file, written and said to have landed, as the saver does (#359).
    private func land(_ store: ItemStore, to file: StoreFile) async throws {
        let (changes, _) = await store.takeChanges()
        try await file.save(changes)
        await store.wrote(changes)
    }

    /// `rows` as a timeline's page hands them in.
    private static func page(_ rows: [HeldRow]) -> Page {
        Page(timeline: UUID(), generation: 1, rows: rows, carried: [], next: nil, newest: nil, oldest: nil, exhausted: true)
    }

    private func rows(_ file: StoreFile) throws -> [NoteKey: Note] {
        Dictionary(uniqueKeysWithValues: try file.load().notes.map { ($0.key, $0) })
    }

    /// `act` on the store over the file and on the store read whole: the same answer, and once
    /// both are saved, the same rows on disk — every one of them as the other holds it.
    private func agree<Answer: Equatable & Sendable>(
        changes: Bool = true, _ comment: Comment? = nil, _ act: @Sendable (ItemStore) async -> Answer
    ) async throws {
        let (pooledFile, wholeFile) = try await twoFiles()
        let pool = await pool(pooledFile)
        let whole = try wholeStore(wholeFile)
        let before = try rows(wholeFile)
        let answer = await act(pool)
        #expect(answer == (await act(whole)), comment)
        try await save(pool, to: pooledFile)
        try await save(whole, to: wholeFile)
        let pooled = try rows(pooledFile)
        let wholly = try rows(wholeFile)
        #expect(pooled.count == wholly.count, comment)
        #expect(Set(pooled.keys) == Set(wholly.keys), comment)
        let differing = wholly.keys.filter { pooled[$0] != wholly[$0] }
        #expect(differing.isEmpty, "\(differing.count) rows differ")
        if changes { #expect(wholly != before, "the act changed nothing, so nothing was compared") }
    }

    // MARK: - Each act changes exactly the rows it names

    @Test("removing a source lets go of exactly its rows the whole store would, read or not")
    func removeSource() async throws {
        try await agree { await $0.remove(host: "two.example") }
        try await agree(changes: false) { await $0.remove(host: "two.example", keepingPosts: true) }
    }

    @Test("letting a span go lets go of exactly its rows, from one host or every one", arguments: [nil, "one.example"])
    func span(host: String?) async throws {
        let span = Self.at.addingTimeInterval(-10 * 86_400)..<Self.at.addingTimeInterval(-2 * 86_400)
        try await agree { await $0.letGo(span: span, host: host) }
        // The question before the press names every post that goes, read or not (C14).
        try await agree(changes: false) { await $0.countGoing(span: span, host: host) }
        let (file, _) = try await twoFiles()
        let pool = await pool(file)
        let read = await pool.count(span: span, host: host)
        let going = await pool.countGoing(span: span, host: host)
        #expect(read < going)
        #expect(await pool.letGo(span: span, host: host) == going)
    }

    @Test("letting gone posts go lets go of exactly the marked rows, by the wait or all of them")
    func gone() async throws {
        try await agree { await $0.letGoneGo(markedBy: Self.at.addingTimeInterval(-2 * 86_400)) }
        try await agree { await $0.letGoneGo() }
    }

    @Test("stopping keeping un-keeps exactly the kept rows, of one host or every one")
    func stopKeeping() async throws {
        try await agree { await $0.stopKeeping(host: "one.example") }
        try await agree { await $0.stopKeeping() }
    }

    @Test("taking a reader's marks back changes exactly the rows of the hosts it names")
    func readerMarks() async throws {
        try await agree { await $0.forgetReaderMarks(host: "one.example") }
        try await agree { await $0.forgetReaderMarks(keeping: ["two.example"]) }
        try await agree { await $0.forgetReaderMarks(keeping: []) }
    }

    @Test("the room limit lets go of the oldest of the file, sparing what the whole store spares", arguments: [1, 7, 150, 900])
    func room(count: Int) async throws {
        try await agree { await $0.letGoOldest(count: count) }
        try await agree(changes: false) { await $0.holdsWhatRoomMayLetGo() }
    }

    @Test("the room limit, asked again and again, keeps agreeing with the whole store")
    func roomRounds() async throws {
        try await agree { store in
            var went: [WentByLimit] = []
            for count in [40, 400, 4_000] { went.append(await store.letGoOldest(count: count)) }
            return went
        }
    }

    @Test("the room limit weighs a post by every row of the file")
    func rowsHeld() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.rowsHeld() == Self.size)
        #expect(await ItemStore(sources: Self.sources, notes: Self.seed()).rowsHeld() == nil)
    }

    // MARK: - What the pool holds meanwhile

    @Test("a row let go from the file is not read back in, before the save lands or after")
    func letGoStaysGone() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        let span = Self.at.addingTimeInterval(-3 * 86_400)..<Self.at.addingTimeInterval(-2 * 86_400)
        let named = try file.keys(.span(span, host: nil))
        let went = await pool.letGo(span: span)
        #expect(went > 0)
        // What stays of those days is what a kept reblog holds: the rest is not read back in.
        let held = Set(await pool.notes(named).keys)
        #expect(held.count == named.count - went)
        try await save(pool, to: file)
        #expect(Set(await pool.notes(named).keys) == held)
        #expect(Set(try file.keys(.span(span, host: nil))) == held)
        #expect(try file.rowCount() == Self.size - went)
    }

    @Test("a row read in while a reader's marks are still to be taken back on the file is read without them")
    func marksNotReadBack() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        let marked = NoteKey(host: "one.example", id: Self.id(5))
        #expect(try file.rows([marked]).first?.note.favourited == true)
        #expect(await pool.forgetReaderMarks(host: "one.example"))
        #expect(await pool.note(marked)?.favourited == nil)
        // Taken by a save that has not landed: still read without them.
        let (changes, _) = await pool.takeChanges()
        #expect(changes.ops.count == 1)
        let other = NoteKey(host: "one.example", id: Self.id(10))
        #expect(await pool.note(other)?.favourited == nil)
        try await file.save(changes)
        #expect(try file.rows([marked, other]).allSatisfy { $0.note.favourited == nil && $0.note.boosted == nil })
        // Nothing left to take back: a second sweep writes nothing.
        #expect(await pool.forgetReaderMarks(host: "one.example") == false)
        #expect(await pool.takeChanges().changes.isEmpty)
    }

    @Test("a row read before the marks were taken back on the file, and laid in after, is laid in without them")
    func marksNotLaidInLate() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        let marked = NoteKey(host: "one.example", id: Self.id(5))
        let early = try file.rows([marked])
        #expect(early.first?.note.favourited == true)
        #expect(await pool.forgetReaderMarks(keeping: []))
        try await save(pool, to: file)
        await pool.take(early)
        #expect(await pool.note(marked)?.favourited == nil)
        // Written again for a change of its own, it is written without them.
        #expect(await pool.setKept(true, for: marked))
        try await save(pool, to: file)
        #expect(try file.rows([marked]).first.map { $0.note.favourited == nil && $0.note.kept } == true)
    }

    @Test("a read back undone over a store held in part deletes only what was let go, and takes the marks back again")
    func undoOverAPool() async throws {
        let (file, _) = try await twoFiles()
        let before = try file.load()
        let pool = await pool(file)
        let span = Self.at.addingTimeInterval(-3 * 86_400)..<Self.at.addingTimeInterval(-2 * 86_400)
        let went = await pool.letGo(span: span)
        #expect(went > 0)
        #expect(await pool.forgetReaderMarks(keeping: []))
        try await save(pool, to: file)
        // The undo writes the store back as it was when the read back began.
        try await file.save(sources: before.sources, notes: before.notes, said: before.said)
        await pool.oweEverything(fileHolds: before.notes.map(\.key), hosts: before.sources.map(\.host))
        try await save(pool, to: file)
        #expect(try file.rowCount() == Self.size - went)
        #expect(try !file.marked(.allBut([])))
    }

    @Test("a page read before the marks were taken back, and out while that lands, is laid in without them")
    func pageOutHoldsSettling() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        let marked = NoteKey(host: "one.example", id: Self.id(5))
        let early = try file.rows([marked])
        #expect(early.first?.note.favourited == true)
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
        #expect(await pool.forgetReaderMarks(keeping: []))
        try await land(pool, to: file)
        open.yield()
        _ = try await out.value
        #expect(await pool.note(marked)?.favourited == nil)
    }

    @Test("marks taken back and landed, then given again on the file, are kept by a row read in after")
    func marksGivenAgainKept() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.forgetReaderMarks(keeping: []))
        try await land(pool, to: file)
        // Marked by the reader signed in since and saved, as a row the pool let go would be.
        let paged = Self.seed()[5]
        let byKey = Self.seed()[10]
        try await file.save(RowChanges(upserts: [paged, byKey]))
        let page = try await pool.paged { Self.page(try file.rows([paged.key])) }
        #expect(page.rows.map(\.note.key) == [paged.key])
        #expect(await pool.note(paged.key)?.favourited == true)
        #expect(await pool.notes([byKey.key])[byKey.key]?.favourited == true)
        #expect(await pool.takeChanges().changes.isEmpty)
    }

    @Test("a read back undone owes every change of the run again, and a row read in after is read as they leave it")
    func undoOwesOpsAgain() async throws {
        let (file, _) = try await twoFiles()
        let before = try file.load()
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.forgetReaderMarks(keeping: []))
        let (made, _) = await pool.takeChanges()
        try await file.save(made)
        await pool.wrote(made)
        await pool.restoring()
        try await file.save(sources: before.sources, notes: before.notes, said: before.said)
        // Read before the store is told what the file was put back to, and a save landing
        // meanwhile: still read as the marks taken back leave them.
        let marked = NoteKey(host: "one.example", id: Self.id(5))
        let page = try await pool.paged { Self.page(try file.rows([marked])) }
        #expect(page.rows.first?.note.favourited == true)
        #expect(await pool.note(marked)?.favourited == nil)
        await pool.wrote(RowChanges())
        let byKey = NoteKey(host: "one.example", id: Self.id(10))
        #expect(await pool.notes([byKey])[byKey]?.favourited == nil)
        await pool.oweEverything(fileHolds: before.notes.map(\.key), hosts: before.sources.map(\.host))
        let after = NoteKey(host: "two.example", id: Self.id(15))
        #expect(await pool.notes([after])[after]?.favourited == nil)
        let (owed, _) = await pool.takeChanges()
        #expect(owed.ops == made.ops)
        try await file.save(owed)
        await pool.wrote(owed)
        #expect(try !file.marked(.allBut([])))
    }

    @Test("a save taken before a read back laid the file in whole, and handed back, makes none of its changes of rows on the new file")
    func putBackAfterReplace() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.forgetReaderMarks(keeping: []))
        let (taken, _) = await pool.takeChanges()
        #expect(taken.ops.count == 1)
        await pool.replace(sources: Self.sources, notes: Array(Self.seed().prefix(10)))
        await pool.putBack(taken)
        #expect(await pool.takeChanges().changes.ops.isEmpty)
    }

    @Test("a write of the marks that did not land is made by the next")
    func marksPutBack() async throws {
        let (file, _) = try await twoFiles()
        let pool = ItemStore(sources: Self.sources, rows: file)
        #expect(await pool.forgetReaderMarks(keeping: []))
        let (failed, _) = await pool.takeChanges()
        await pool.putBack(failed)
        let key = NoteKey(host: "two.example", id: Self.id(15))
        #expect(await pool.note(key)?.favourited == nil)
        let (again, _) = await pool.takeChanges()
        #expect(again.ops == failed.ops)
        try await file.save(again)
        #expect(try !file.marked(.allBut([])))
    }

    @Test("where the file will not say which rows a letting go names, nothing goes")
    func unreadLetsNothingGo() async throws {
        let (file, _) = try await twoFiles()
        let failing = StorePoolTests.Failing(file)
        let pool = ItemStore(sources: Self.sources, rows: failing)
        let span = Self.at.addingTimeInterval(-10 * 86_400)..<Self.at
        #expect(await pool.letGo(span: span) == 0)
        #expect(await pool.letGoneGo() == 0)
        #expect(await pool.letGoOldest(count: 10) == .none)
        #expect(await pool.stopKeeping() == 0)
        #expect(await pool.takeChanges().changes.upserts.isEmpty)
        failing.fail(from: nil)
        #expect(await pool.letGo(span: span) > 0)
    }

    // MARK: - Taking away

    @Test("a take-away of a store held in part is refused with its own reason, and writes no file")
    func takeAwayRefused() async throws {
        let device = try await PackagerFixture.PackagerDevice(sources: Self.sources, notes: Array(Self.seed().prefix(20)))
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        defer { device.remove(); try? FileManager.default.removeItem(at: package) }
        let file = try #require(device.file)
        let packager = StorePackager(
            directory: device.directory, file: file, store: ItemStore(sources: Self.sources, rows: file),
            media: device.media, tokens: device.tokens, credentials: device.credentials, defaults: device.defaults,
            device: "a test", appVersion: "0.7.0", freeSpace: { _ in .max }, rounds: 1000
        )
        await #expect(throws: PackageFault.heldInPart) {
            try await packager.takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: package.path))
        #expect(NearbyRefusal(PackageFault.heldInPart) == .heldInPart)
    }
}
