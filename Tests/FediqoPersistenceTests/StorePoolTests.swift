import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// `ItemStore` over the file's rows (#357): a pool that holds what was read, reads a row it
/// lacks by key, and shows of a timeline, from where its pages were read up, exactly what the
/// whole store would — the rows, what each says it refers to, and the order of their copies.
@Suite("The store as a pool read from the file")
struct StorePoolTests {
    private static let one = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Seven")])
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let sources = [one, two, forum]
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func post(
        _ id: String, _ source: Source = one, at moment: Date = at, _ categories: Set<FediqoCore.Category> = [.home],
        statusID: String? = nil, refs: [Reference] = [], refsDue: Bool = false, gaps: Set<TimelineGap> = [], kept: Bool = false
    ) -> Note {
        Note(
            id: id, source: source, author: "A", handle: "a@\(source.host)", body: "b \(id)", postedAt: moment,
            categories: categories, statusID: statusID, gaps: gaps, kept: kept, refs: refs, refsDue: refsDue
        )
    }

    /// The pages' seed, and rows whose meaning the whole store's opening changes: one owing a
    /// load of a post the file holds, one saying a post is gone that the file holds, one quoting
    /// a post nobody holds.
    private static func seeded() -> [Note] {
        StorePagesTests.seeded() + [
            post("owes", at: at.addingTimeInterval(30 * 60), refs: [Reference(kind: .quotes, statusID: "s-quoted", state: .accepted)], refsDue: true),
            post("quoted", at: at.addingTimeInterval(-3_600), [], statusID: "s-quoted"),
            post("answering", two, at: at.addingTimeInterval(31 * 60), refs: [Reference(kind: .answers, statusID: "s-answered", gone: true)]),
            post("answered", two, at: at.addingTimeInterval(-7_200), [], statusID: "s-answered"),
            post("quoting-absent", at: at.addingTimeInterval(32 * 60), refs: [Reference(kind: .quotes, id: "absent", state: .accepted)]),
        ]
    }

    private func seededFile(_ notes: [Note] = seeded()) async throws -> StoreFile {
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes)
        return file
    }

    /// The store as a launch before this held it: every row read.
    private func wholeStore(_ file: StoreFile) throws -> ItemStore {
        let loaded = try file.load()
        return ItemStore(sources: loaded.sources, notes: loaded.notes, said: loaded.said, readFromDisk: true)
    }

    private func query(_ rules: [Rule?], latestEnd: Date? = nil, keepFrom: Date? = nil) throws -> PageQuery {
        let definition = TimelineDefinition(name: "T", rules: try rules.map { try #require($0) })
        return PageQuery(
            timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: Self.sources),
            latestEnd: latestEnd, keepFrom: keepFrom
        )
    }

    private var timelines: [PageQuery] {
        get throws {
            let sources = Self.sources
            return [
                try query([]),
                try query([.source("one.example"), .category(.home, in: .source(host: "one.example"), sources: sources)]),
                try query([.category(.public, in: .every, sources: sources), .source("two.example", effect: .exclude)]),
                try query([.author("bob@two.example", in: .every, sources: sources)]),
                try query([.keyword("swift", in: .every)]),
                try query([.category(.board(id: "2"), in: .source(host: "forum.example"), sources: sources)]),
                try query(
                    [.category(.trends, in: .every, sources: sources)],
                    latestEnd: Self.at.addingTimeInterval(40 * 60), keepFrom: Self.at.addingTimeInterval(10 * 60)
                ),
            ]
        }
    }

    /// What a screen draws of `items` for `query`: the rules, the latest date, the months kept.
    private func shown(_ items: [Note], _ query: PageQuery) -> [Note] {
        query.compiled.shown(items, TextIndex(items), targets: ReblogTargets(items))
            .filter { note in query.latestEnd.map { note.postedAt < $0 } ?? true }
            .filter { note in query.keepFrom.map { note.kept || note.postedAt >= $0 } ?? true }
    }

    /// `pages` pages of `query` from the newest down, laid into `pool`: the last row shown.
    private func read(_ query: PageQuery, pages: Int, limit: Int, from file: StoreFile, into pool: ItemStore) async throws -> NoteKey? {
        var ask = PageAsk.newest
        var last: NoteKey?
        for _ in 0..<pages {
            let page = try await file.page(query, ask, limit: limit)
            await pool.take(page.rows + page.carried)
            last = page.rows.last?.note.key ?? last
            if page.exhausted { break }
            ask = .before(try #require(page.next))
        }
        return last
    }

    /// `list` down to and with the row under `key`.
    private func down(to key: NoteKey, _ list: [Note]) throws -> [Note] {
        Array(list.prefix(through: try #require(list.firstIndex { $0.key == key })))
    }

    // MARK: - What a page shows

    @Test("a timeline's pages laid in the pool show what the whole store shows down to them", arguments: [1, 2, 5])
    func pagesShowTheWhole(pages: Int) async throws {
        let file = try await seededFile()
        let whole = try wholeStore(file)
        let everything = await whole.all()
        for query in try timelines {
            let pool = ItemStore(sources: Self.sources, rows: file)
            let floor = try #require(try await read(query, pages: pages, limit: 20, from: file, into: pool))
            let drawn = try down(to: floor, shown(await pool.all(), query))
            #expect(!drawn.isEmpty)
            #expect(drawn == (try down(to: floor, shown(everything, query))))
        }
        // The rows the whole store's opening settled come into the pool settled the same way.
        let pool = ItemStore(sources: Self.sources, rows: file)
        for id in ["owes", "answering", "quoting-absent"] {
            let key = NoteKey(host: id == "answering" ? "two.example" : "one.example", id: id)
            _ = await pool.note(key)
            let mine = await pool.all().first { $0.key == key }
            #expect(mine != nil)
            #expect(mine == everything.first { $0.key == key })
        }
    }

    @Test("what a pooled row holds with it is pooled wherever the file has it")
    func referencesHeld() async throws {
        let file = try await seededFile()
        let onDisk = Set(try file.load().notes.map(\.key))
        let pool = ItemStore(sources: Self.sources, rows: file)
        for query in try timelines { _ = try await read(query, pages: 2, limit: 15, from: file, into: pool) }
        let pooled = await pool.all() + pool.replies()
        let keys = Set(pooled.map(\.key))
        for note in pooled {
            for key in note.heldWith + [note.topicKey].compactMap({ $0 }) where onDisk.contains(key) {
                #expect(keys.contains(key), "\(note.key.id) holds \(key.id)")
            }
        }
    }

    // MARK: - Every way in reads first

    @Test("a copy of a row the file holds and the pool does not merges as it would with the row held")
    func landsOnTheFilesRow() async throws {
        let file = try await seededFile()
        let whole = try wholeStore(file)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let loaded = try file.load().notes
        let kept = try #require(loaded.first { $0.kept && !$0.isReblog && $0.source.kind == .mastodon })
        let plain = try #require(loaded.first { !$0.kept && !$0.isReblog && !$0.categories.contains(.trends) && $0.source.kind == .mastodon })
        var copies: [Note] = []
        for held in [kept, plain] {
            var copy = held
            copy.kept = false
            copy.categories = [.trends]
            copy.counts = Counts(replies: 9)
            copies.append(copy)
        }
        for store in [whole, pool] {
            _ = await store.takeChanges()
            await store.ingest(copies)
        }
        for key in [kept.key, plain.key] {
            let mine = try #require(await pool.note(key))
            #expect(mine == (await whole.note(key)))
            #expect(mine.categories.contains(.trends) && mine.categories.isSuperset(of: loaded.first { $0.key == key }!.categories))
        }
        #expect(await pool.note(kept.key)?.kept == true)
        let written = await pool.takeChanges().changes
        let wholeWritten = await whole.takeChanges().changes
        #expect(Set(written.upserts.map(\.key)) == Set(wholeWritten.upserts.map(\.key)))
        #expect(Set(written.upserts) == Set(wholeWritten.upserts))
    }

    @Test("a row let go is not read back from the file before the save that deletes it")
    func letGoStaysGone() async throws {
        let file = try await seededFile()
        let pool = ItemStore(sources: Self.sources, rows: file)
        let key = NoteKey(host: "one.example", id: "quoting-absent")
        #expect(await pool.note(key) != nil)
        await pool.forget(key)
        #expect(await pool.note(key) == nil)
        let again = try file.rows([key])
        #expect(await pool.take(again) == false)
        #expect(await pool.all().contains { $0.key == key } == false)
        #expect(await pool.takeChanges().changes.deletes == [key])
        #expect(try file.rows([key]).count == 1)
    }

    @Test("a row read from the file reached nothing a whole store would not, and owes no write for being read")
    func readOwesNothing() async throws {
        let file = try await seededFile()
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = try await read(try query([]), pages: 3, limit: 50, from: file, into: pool)
        let revision = await pool.revision
        #expect(revision == 0)
        // What the whole store's opening owed a write of, the pool owes: the rows it settled.
        let owed = Set(await pool.takeChanges().changes.upserts.map(\.key.id))
        #expect(owed.isSubset(of: ["owes", "answering"]))
    }

    @Test("a copy new this run of a post the file holds stands after the file's copy, as it arrived after it")
    func fileCopyFirst() async throws {
        let file = try await seededFile([Self.post("p", Self.one)])
        let whole = try wholeStore(file)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let later = Self.post("p", Self.two)
        for store in [whole, pool] { await store.ingest([later]) }
        _ = try await read(try query([]), pages: 1, limit: 10, from: file, into: pool)
        #expect(await pool.all().map(\.key.host) == ["one.example", "two.example"])
        #expect(await pool.all() == (await whole.all()))
    }

    @Test("a mark a read on said again comes off a row the file still has it on, once read")
    func remainSaidAgain() async throws {
        let remain = TimelineGap(.newerRemain, in: .home)
        let old = Self.post("old", at: Self.at.addingTimeInterval(-60), gaps: [remain])
        let file = try await seededFile([old])
        let whole = try wholeStore(file)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let fresh = Self.post("new")
        for store in [whole, pool] {
            await store.land(ReadOn(notes: [fresh], newerRemainAbove: fresh.key), of: .home, ifSourceHere: "one.example")
        }
        _ = try await read(try query([]), pages: 1, limit: 10, from: file, into: pool)
        #expect(await pool.note(old.key)?.gaps == [])
        #expect(await pool.all() == (await whole.all()))
    }

    // MARK: - A file that will not be read

    /// The file, failing every read from the `failingFrom`th on (counted from 1) while `failing`
    /// — as a locked device's file fails.
    final class Failing: HeldRows, @unchecked Sendable {
        struct Locked: Error {}
        private let file: StoreFile
        private let lock = NSLock()
        private var calls = 0
        private var from: Int?

        init(_ file: StoreFile, failingFrom from: Int? = 1) {
            self.file = file
            self.from = from
        }

        func fail(from: Int?) {
            lock.withLock {
                calls = 0
                self.from = from
            }
        }

        private func call<T>(_ read: () throws -> T) throws -> T {
            let fails = lock.withLock {
                calls += 1
                return from.map { calls >= $0 } ?? false
            }
            if fails { throw Locked() }
            return try read()
        }

        func rows(_ keys: [NoteKey]) throws -> [HeldRow] { try call { try file.rows(keys) } }
        func rows(host: String, idPrefix: String) throws -> [HeldRow] { try call { try file.rows(host: host, idPrefix: idPrefix) } }
        func rows(host: String, statusIDs: [String]) throws -> [HeldRow] { try call { try file.rows(host: host, statusIDs: statusIDs) } }
        func keptRows() throws -> [HeldRow] {
            lock.withLock { keptReads += 1 }
            return try call { try file.keptRows() }
        }
        func reblogged(by keys: [NoteKey]) throws -> [NoteKey] { try call { try file.reblogged(by: keys) } }
        func keys(_ selection: RowSelection) throws -> [NoteKey] { try call { try file.keys(selection) } }
        func oldest(_ limit: Int, after: PageCursor?) throws -> (rows: [HeldRow], next: PageCursor?) {
            try call { try file.oldest(limit, after: after) }
        }
        func referring(to keys: [NoteKey]) throws -> [Referrer] { try call { try file.referring(to: keys) } }
        func beyond(_ cutoff: Date, limit: Int, after: PageCursor?) throws -> (rows: [PastLimit], next: PageCursor?) {
            try call { try file.beyond(cutoff, limit: limit, after: after) }
        }
        func referring(to keys: [NoteKey], stayingFrom cutoff: Date) throws -> [Referrer] {
            try call { try file.referring(to: keys, stayingFrom: cutoff) }
        }
        func marked(_ hosts: StoreOp.Hosts) throws -> Bool { try call { try file.marked(hosts) } }
        func rowCount() throws -> Int { try call { try file.rowCount() } }
        func rowCounts() throws -> [String: HostRows] { try call { try file.rowCounts() } }
        func oldestStatusID(host: String, category: FediqoCore.Category) throws -> String? {
            try call { try file.oldestStatusID(host: host, category: category) }
        }

        /// How many times the kept rows were asked for.
        var keptAsked: Int { lock.withLock { keptReads } }
        private var keptReads = 0
    }

    @Test("a copy of a row the file would not be read for is not taken over it, and is once the file reads")
    func unreadIsNotAbsent() async throws {
        let held = Self.post("held", Self.one, [.home], kept: true)
        let file = try await seededFile([held])
        let failing = Failing(file)
        let pool = ItemStore(sources: Self.sources, rows: failing)
        var copy = held
        copy.kept = false
        copy.categories = [.trends]
        await pool.ingest([copy])
        #expect(await pool.note(held.key) == nil)
        #expect(await pool.takeChanges().changes.upserts.isEmpty)
        #expect(await pool.revision == 0)
        failing.fail(from: nil)
        await pool.ingest([copy])
        let now = try #require(await pool.note(held.key))
        #expect(now.kept)
        #expect(now.categories == Set<FediqoCore.Category>([.home, .trends]))
    }

    @Test("a row whose reference the file would not be read for is not laid in without it")
    func allOrNothing() async throws {
        let target = Self.post("target", Self.one, [])
        let boost = Self.post("boost", refs: [Reference(kind: .reblogs, id: "target")])
        let file = try await seededFile([target, boost])
        let failing = Failing(file, failingFrom: 2)
        let pool = ItemStore(sources: Self.sources, rows: failing)
        #expect(await pool.note(boost.key) == nil)
        #expect(await pool.all().isEmpty)
        failing.fail(from: nil)
        #expect(await pool.note(boost.key) != nil)
        #expect(Set(await pool.all().map(\.key.id)) == ["boost", "target"])
    }

    @Test("a row that will not decode is not taken for absent: a copy of it is not written over it")
    func undecodableIsNotAbsent() async throws {
        let file = try await seededFile([Self.post("fine")])
        try await file.db.write { db in
            try db.execute(sql: """
                INSERT INTO note (host, id, posted_at, categories, facts, kept) VALUES
                ('one.example', 'broken', '2026-09-20 12:00:00.000', '[{"kind":"home"}]', '{not json', 1)
                """)
        }
        let pool = ItemStore(sources: Self.sources, rows: file)
        await pool.ingest([Self.post("broken"), Self.post("other")])
        #expect(await pool.note(NoteKey(host: "one.example", id: "broken")) == nil)
        #expect(await pool.takeChanges().changes.upserts.map(\.key.id) == ["other"])
    }

    @Test("a post a kept reblog only the file holds reblogs is not let go when its source takes it back")
    func keptReblogOnDisk() async throws {
        let target = Self.post("target", Self.one, at: Self.at.addingTimeInterval(-600), [])
        let boost = Self.post("boost", refs: [Reference(kind: .reblogs, id: "target")], kept: true)
        let file = try await seededFile([target, boost])
        let whole = try wholeStore(file)
        let pool = ItemStore(sources: Self.sources, rows: file)
        let moment = Self.at.addingTimeInterval(60)
        for store in [whole, pool] { await store.forget(target.key, at: moment) }
        #expect(await pool.note(target.key)?.goneSince == moment)
        #expect(await pool.all() == (await whole.all()))
        // And with the file unreadable, nothing is let go at all.
        let locked = ItemStore(sources: Self.sources, rows: Failing(file))
        await locked.forget(target.key, at: moment)
        #expect(await locked.takeChanges().changes.deletes.isEmpty)
    }

    @Test("a kept row that will not decode still holds what it reblogs, and the kept rows are read once a run")
    func undecodableKept() async throws {
        let target = Self.post("target", Self.one, at: Self.at.addingTimeInterval(-600), [])
        let other = Self.post("other")
        let file = try await seededFile([target, other])
        try await file.db.write { db in
            try db.execute(sql: """
                INSERT INTO note (host, id, posted_at, categories, facts, kept, refs) VALUES
                ('one.example', 'broken', '2026-09-20 12:00:00.000', '[{"kind":"home"}]', '{not json', 1,
                 '[{"kind":"reblogs","id":"target"}]')
                """)
        }
        let counted = Failing(file, failingFrom: nil)
        let pool = ItemStore(sources: Self.sources, rows: counted)
        await pool.forget(other.key)
        await pool.forget(target.key, at: Self.at)
        #expect(await pool.note(other.key) == nil)
        #expect(await pool.note(target.key)?.goneSince == Self.at)
        #expect(await pool.takeChanges().changes.deletes == [other.key])
        #expect(counted.keptAsked == 1)
    }

    @Test("the months limit over a file lets go of what the whole store would, from it and from the pool, and no page shows a row past it")
    func monthsLeaveTheFile() async throws {
        let now = Self.at
        let old = Self.post("old", Self.one, at: now.addingTimeInterval(-400 * 86_400))
        let unread = Self.post("unread", Self.one, at: now.addingTimeInterval(-410 * 86_400))
        let quotedOld = Self.post("quoted-old", Self.one, at: now.addingTimeInterval(-500 * 86_400), [])
        let recent = Self.post("recent", Self.one, at: now.addingTimeInterval(-60), refs: [Reference(kind: .quotes, id: "quoted-old", state: .accepted)])
        let file = try await seededFile([old, unread, quotedOld, recent])
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = try await read(try query([]), pages: 1, limit: 3, from: file, into: pool)
        let went = await pool.letGoBeyond(months: 1, from: now)
        #expect(went == WentByLimit(posts: 2, sources: ["one.example"]))
        // The post an in-window one quotes stays, as it stays in the whole store.
        #expect(await pool.note(old.key) == nil)
        #expect(Set(await pool.all().map(\.key.id)) == ["quoted-old", "recent"])
        let changes = await pool.takeChanges().changes
        #expect(Set(changes.deletes) == [old.key, unread.key] && changes.upserts.isEmpty)
        try await file.save(changes)
        #expect(try file.rows([old.key, unread.key]).isEmpty)
        let cutoff = try #require(KeepPolicy.cutoff(keepingMonths: 1, from: now, calendar: .current))
        let page = try await file.page(try query([], keepFrom: cutoff), .newest)
        #expect(page.rows.map(\.note.key.id) == ["recent"])
    }

    @Test("a save that fails after the months limit acted still owes the delete of a row past it, and not its change")
    func monthsThenAFailedSave() async throws {
        let now = Self.at
        let old = Self.post("old", Self.one, at: now.addingTimeInterval(-400 * 86_400))
        let file = try await seededFile([old, Self.post("recent", Self.one, at: now.addingTimeInterval(-60))])
        let pool = ItemStore(sources: Self.sources, rows: file)
        _ = try await read(try query([]), pages: 1, limit: 10, from: file, into: pool)
        // A change to the old row is on its way to the file when the limit acts.
        #expect(await pool.setKept(true, for: old.key))
        #expect(await pool.setKept(false, for: old.key) == true)
        let taken = await pool.takeChanges().changes
        #expect(taken.upserts.map(\.key) == [old.key])
        await pool.letGoBeyond(months: 1, from: now)
        await pool.putBack(taken)
        let again = await pool.takeChanges().changes
        #expect(again.deletes == [old.key])
        #expect(again.upserts.isEmpty)
        try await file.save(again)
        #expect(try file.rows([old.key]).isEmpty)
        #expect(await pool.note(old.key) == nil)
    }

    @Test("a copy landing while a save is in flight is written with its newer word, whether the save lands or fails")
    func copyWhileSaving() async throws {
        for fails in [false, true] {
            let held = Self.post("held", Self.one, [.home])
            let file = try await seededFile([held])
            let pool = ItemStore(sources: Self.sources, rows: file)
            var first = held
            first.categories = [.trends]
            await pool.ingest([first])
            let inFlight = await pool.takeChanges().changes
            var second = held
            second.categories = [.public]
            await pool.ingest([second])
            if fails { await pool.putBack(inFlight) } else { try await file.save(inFlight) }
            let next = await pool.takeChanges().changes
            #expect(next.deletes.isEmpty)
            let every: Set<FediqoCore.Category> = [.home, .trends, .public]
            #expect(next.upserts.map(\.categories) == [every])
            try await file.save(next)
            #expect(try file.rows([held.key]).first?.note.categories == every)
        }
    }

    @Test("the kept rows are read by an index of their own")
    func keptIndexed() async throws {
        let file = try await seededFile()
        try await file.makeIndexes()
        let detail = try await file.db.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT rowid AS rowid, * FROM note WHERE kept").map { $0["detail"] as String }
        }
        #expect(detail.contains { $0.contains("note_kept") })
    }

    @Test("a topic found in a board passes it to its replies the file holds and the pool did not")
    func boardReachesTheFile() async throws {
        let reply = Note(
            id: "discuz:forum.example:9:post:3", source: Self.forum, author: "F", handle: "f@forum.example", body: "",
            postedAt: Self.at, categories: [], opening: ForumOpening(words: "r", floor: 3, postedAt: Self.at)
        )
        let topic = Self.post("discuz:forum.example:9", Self.forum, at: Self.at.addingTimeInterval(-60), [])
        let file = try await seededFile([topic, reply])
        let whole = try wholeStore(file)
        let pool = ItemStore(sources: Self.sources, rows: file)
        var boarded = topic
        boarded.categories = [.board(id: "2")]
        for store in [whole, pool] { await store.ingest([boarded]) }
        #expect(await pool.note(reply.key)?.categories == [.board(id: "2")])
        #expect(await pool.all() == (await whole.all()))
    }
}
