import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A timeline read from the file a page at a time (#357): the indexes made outside the migrator,
/// and pages that, laid end to end, are what the whole store would show — no row missing, none
/// twice, copies of one post never split — whichever way they are read and however small.
@Suite("A timeline read a page at a time")
struct StorePagesTests {
    private static let one = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Seven")])
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let sources = [one, two, forum]

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

    /// A thousand-odd rows on few moments, so many share a time; a third of the posts with a
    /// copy from the other source under the same id and time; reblogs and quotes of each other;
    /// handles in ASCII, in full width and with a mark; a forum's dated and undated replies.
    /// Written in no order of time, so the file's order is not the timeline's.
    static func seeded() -> [Note] {
        var random = Seeded(state: 357)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let moments = (0..<60).map { base.addingTimeInterval(Double($0) * 60) }
        let handles = ["@ada@one.example", "bob@two.example", "@ＢＯＢ@two.example", "@Zoë@one.example", "@Cy@two.example"]
        let bodies = ["hello swift", "nothing", "Swift rocks", "plain words"]
        let categories: [[FediqoCore.Category]] = [[.public], [.home], [.trends], [.public, .home], [.list(id: "7")], []]
        var notes: [Note] = []
        for post in 0..<600 {
            let at = moments[Int.random(in: 0..<moments.count, using: &random)]
            let host = Bool.random(using: &random) ? one : two
            var refs: [Reference] = []
            switch Int.random(in: 0..<10, using: &random) {
            case 0, 1: refs = [Reference(kind: .reblogs, id: "p\(Int.random(in: 0..<600, using: &random))")]
            case 2: refs = [Reference(kind: .quotes, id: "p\(Int.random(in: 0..<600, using: &random))", state: .accepted)]
            default: break
            }
            func copy(_ source: Source) -> Note {
                Note(
                    id: "p\(post)", source: source, author: "A", handle: handles.randomElement(using: &random)!,
                    body: bodies.randomElement(using: &random)!, postedAt: at,
                    categories: Set(categories.randomElement(using: &random)!),
                    kept: Int.random(in: 0..<5, using: &random) == 0,
                    language: ["en", "ja", nil].randomElement(using: &random)!, refs: refs
                )
            }
            notes.append(copy(host))
            if Int.random(in: 0..<3, using: &random) == 0 { notes.append(copy(host == one ? two : one)) }
        }
        for reply in 1...20 {
            let dated = reply % 2 == 0
            notes.append(Note(
                id: "discuz:forum.example:5:post:\(reply)", source: forum, author: "F", handle: "f@forum.example",
                body: "", postedAt: moments[reply], categories: [.board(id: "2")],
                opening: ForumOpening(words: "reply \(reply)", floor: reply, postedAt: dated ? moments[reply] : nil)
            ))
        }
        notes.append(Note(
            id: "discuz:forum.example:5", source: forum, author: "F", handle: "f@forum.example", body: "topic",
            postedAt: moments[0], categories: [.board(id: "2")]
        ))
        // Ids that are not ASCII, and one not in NFC: SQLite orders them by bytes.
        for (n, id) in ["pe\u{301}", "p\u{E9}t\u{E9}", "p日本"].enumerated() {
            notes.append(Note(
                id: id, source: one, author: "A", handle: "a@one.example", body: "accent \(n)", postedAt: moments[n],
                categories: [.home, .public]
            ))
        }
        notes.shuffle(using: &random)
        return notes
    }

    private func store(_ notes: [Note] = seeded()) async throws -> (StoreFile, [Note]) {
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes)
        return (file, try file.load().notes)
    }

    /// What the whole store shows for `compiled`, as the screens make it: every item in the
    /// store's order (`ItemStore.storeOrder`, arrival being the file's order), the rules, the
    /// latest date, and the months kept.
    private func oracle(_ loaded: [Note], _ query: PageQuery) -> [NoteKey] {
        let arrival = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.key, $0) })
        let items = loaded.filter { !$0.isPartOfTopic }.sorted { a, b in
            if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
            if a.id != b.id { return a.id < b.id }
            return arrival[a.key]! < arrival[b.key]!
        }
        return query.compiled.shown(items, TextIndex(items), targets: ReblogTargets(loaded))
            .filter { note in query.latestEnd.map { note.postedAt < $0 } ?? true }
            .filter { note in query.keepFrom.map { note.kept || note.postedAt >= $0 } ?? true }
            .map(\.key)
    }

    /// Every page from the newest down, until the file says there is nothing older.
    private func down(_ file: StoreFile, _ query: PageQuery, limit: Int, budget: Int = 20_000) async throws -> [Page] {
        var pages: [Page] = []
        var ask = PageAsk.newest
        while pages.count < 10_000 {
            let page = try await file.page(query, ask, limit: limit, scanBudget: budget)
            pages.append(page)
            if page.exhausted { break }
            ask = .before(try #require(page.next))
        }
        return pages
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
            let base = Date(timeIntervalSince1970: 1_790_000_000)
            let sources = Self.sources
            return [
                try query([]),
                try query([.source("one.example"), .category(.home, in: .source(host: "one.example"), sources: sources)]),
                try query([.category(.public, in: .every, sources: sources), .source("two.example", effect: .exclude)]),
                try query([.author("bob@two.example", in: .every, sources: sources)]),
                try query([.author("zoë@one.example", in: .every, sources: sources)]),
                try query([.author("ada@one.example", in: .every, effect: .exclude, sources: sources)]),
                try query([.keyword("swift", in: .every)]),
                try query([.field("language", is: .option("ja"), in: .every)]),
                try query([
                    .category(.list(id: "7"), in: .source(host: "one.example"), sources: sources),
                    .keyword("nothing", in: .every, effect: .exclude),
                ]),
                try query([.category(.board(id: "2"), in: .source(host: "forum.example"), sources: sources)]),
                try query(
                    [.category(.trends, in: .every, sources: sources)],
                    latestEnd: base.addingTimeInterval(40 * 60), keepFrom: base.addingTimeInterval(10 * 60)
                ),
            ]
        }
    }

    // MARK: - The indexes

    @Test("the indexes are made outside the migrator, once, and the store stays one an older build opens")
    func indexes() async throws {
        let dir = try scratch()
        let file = try StoreFile(at: dir)
        let migrations = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        try await file.makeIndexes()
        try await file.makeIndexes()
        let names = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'note'") }
        #expect(Set(names).isSuperset(of: ["note_page", "note_status", "note_owing"]))
        let after = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(after == migrations)
        // Opened again, it is the store it was: no newer build's, and the indexes still there.
        let again = try StoreFile(at: dir)
        let kept = try await again.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'note'") }
        #expect(Set(kept).isSuperset(of: ["note_page", "note_status", "note_owing"]))
    }

    @Test("a store with no indexes — an older build's — gets them at its first page")
    func indexedAtFirstPage() async throws {
        let (file, _) = try await store()
        let before = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'note'") }
        #expect(!before.contains("note_page"))
        _ = try await file.page(try query([]), .newest)
        let after = try await file.db.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'note'") }
        #expect(after.contains("note_page"))
    }

    @Test("the page query reads by note_page and sorts nothing")
    func plan() async throws {
        let (file, _) = try await store()
        try await file.makeIndexes()
        let detail = try await file.db.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT rowid, posted_at, id FROM note INDEXED BY note_page
                WHERE host = 'one.example' ORDER BY posted_at DESC, id ASC, rowid ASC LIMIT 100
                """).map { $0["detail"] as String }
        }
        #expect(detail.contains { $0.contains("note_page") })
        #expect(!detail.contains { $0.contains("TEMP B-TREE") })
    }

    // MARK: - Pages laid end to end

    @Test("newest, then each page before the last, is the whole store's timeline: no gap, no row twice", arguments: [1, 7, 100])
    func downIsTheWhole(limit: Int) async throws {
        let (file, loaded) = try await store()
        for query in try timelines {
            let pages = try await down(file, query, limit: limit)
            let read = pages.flatMap(\.rows).map(\.note.key)
            #expect(!read.isEmpty)
            #expect(read == oracle(loaded, query))
            for page in pages.dropLast() { #expect(page.rows.count >= min(limit, 1)) }
        }
    }

    /// All is everything held (#282): every category of every source — Home, a list, the public
    /// timeline, Trends, the reader's marks, a forum's board, and posts no timeline listed, as a
    /// search or an opened thread brings them — in the one order. A busy source filling the
    /// first page holds back nothing of the others: reading down reaches every one of them.
    @Test("All, read down page after page, is every post held of every source and category in one order")
    func allIsEverything() async throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let kinds: [Set<FediqoCore.Category>] = [[.home], [.list(id: "7")], [.trends], [.bookmarks], [.favourites], []]
        var notes: [Note] = (0..<300).map { minute in
            Note(
                id: "busy\(minute)", source: Self.two, author: "B", handle: "b@two.example", body: "busy",
                postedAt: base.addingTimeInterval(Double(10_000 + minute) * 60), categories: [.public]
            )
        }
        for (n, categories) in kinds.enumerated() {
            notes.append(Note(
                id: "one\(n)", source: Self.one, author: "A", handle: "a@one.example", body: "one",
                postedAt: base.addingTimeInterval(Double(n) * 60), categories: categories
            ))
        }
        notes.append(Note(
            id: "discuz:forum.example:9", source: Self.forum, author: "F", handle: "f@forum.example", body: "topic",
            postedAt: base.addingTimeInterval(30 * 60), categories: [.board(id: "2")]
        ))
        let (file, loaded) = try await store(notes)
        let all = PageQuery(
            timeline: TimelineDefinition.all.id, generation: 1,
            compiled: CompiledTimeline(.all, sources: Self.sources), latestEnd: nil, keepFrom: nil
        )
        let pages = try await down(file, all, limit: 100)
        let first = try #require(pages.first)
        #expect(first.rows.allSatisfy { $0.note.source.host == Self.two.host }, "the busy source fills the newest page")
        let read = pages.flatMap(\.rows).map(\.note.key)
        #expect(Set(read) == Set(loaded.map(\.key)), "and every post held is read, of every source and category")
        #expect(read.count == loaded.count, "each once")
        #expect(read == oracle(loaded, all), "newest first, in the one order")
    }

    @Test("a page never ends inside the copies of one post", arguments: [1, 2, 7])
    func runsWhole(limit: Int) async throws {
        let (file, _) = try await store()
        let pages = try await down(file, try query([]), limit: limit)
        for (page, next) in zip(pages, pages.dropFirst()) {
            guard let last = page.rows.last?.note, let first = next.rows.first?.note else { continue }
            #expect(last.postedAt != first.postedAt || last.id != first.id)
        }
        // Some page here did read past its limit to finish a run.
        #expect(pages.contains { $0.rows.count > limit })
    }

    @Test("each page after the oldest, read upwards, is the same timeline turned round", arguments: [1, 7, 100])
    func upIsTheWhole(limit: Int) async throws {
        let (file, loaded) = try await store()
        // The oldest row of the file, by the order read: where reading up starts from.
        let bottom = try #require(try await down(file, try query([]), limit: 5_000).last?.next)
        let bottomKey = try await file.db.read { db in
            try Row.fetchOne(db, sql: "SELECT host, id FROM note WHERE rowid = ?", arguments: [bottom.rowid])
                .map { NoteKey(host: $0["host"], id: $0["id"]) }
        }
        for query in try timelines {
            var pages: [Page] = []
            var from = bottom
            while pages.count < 10_000 {
                let page = try await file.page(query, .after(from), limit: limit)
                pages.append(page)
                if page.exhausted { break }
                from = try #require(page.next)
            }
            let read = pages.reversed().flatMap(\.rows).map(\.note.key)
            #expect(read == oracle(loaded, query).filter { $0 != bottomKey })
        }
    }

    @Test("a row comes back as the file holds it, under the order it arrived in")
    func rowsAsHeld() async throws {
        let (file, loaded) = try await store()
        let rows = try await down(file, try query([]), limit: 50).flatMap(\.rows)
        let byKey = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.key, ($1, Int64($0 + 1))) })
        for row in rows {
            #expect(row.note == byKey[row.note.key]?.0)
            #expect(row.arrival == byKey[row.note.key]?.1)
        }
    }

    @Test("what SQL can say it says exactly: a source and a category narrow to the rows shown, a keyword to nothing")
    func narrowed() async throws {
        let (file, loaded) = try await store()
        let sources = Self.sources
        let exact = try query([
            .source("one.example"), .category(.home, in: .source(host: "one.example"), sources: sources),
            .author("ada@one.example", in: .every, effect: .exclude, sources: sources),
        ])
        let words = try query([.source("one.example"), .keyword("swift", in: .every)])
        #expect(exact.compiled.prefilter.groups.count == 2)
        #expect(exact.compiled.prefilter.excludes == [.handle("ada@one.example", host: nil)])
        #expect(words.compiled.prefilter.groups == [[.host("one.example")], [.words("swift", host: nil)]])
        #expect(words.compiled.prefilter.readsWhatIsSaid)
        func hits(_ query: PageQuery) async throws -> Int {
            let (hit, arguments) = StoreFile.hit(query.compiled.prefilter, keepFrom: nil)
            return try await file.db.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE \(hit)", arguments: arguments) ?? 0
            }
        }
        #expect(try await hits(exact) == oracle(loaded, exact).count)
        #expect(try await hits(words) == loaded.filter { $0.source.host == "one.example" }.count)
    }

    // MARK: - Asked from a row already held

    @Test("after the top of the newest page come only the rows newer than it, as they land")
    func newerThanTheTop() async throws {
        let (file, _) = try await store()
        let sources = Self.sources
        for (round, query) in [try query([]), try query([.category(.home, in: .every, sources: sources)])].enumerated() {
            let top = try await file.page(query, .newest, limit: 7)
            let newest = try #require(top.newest)
            let none = try await file.page(query, .after(newest))
            #expect(none.rows.isEmpty && none.exhausted)
            // Each round's later than everything before it, the last round's included.
            let later = Date(timeIntervalSince1970: 1_800_000_000 + Double(round) * 1_000)
            let landed: [Note] = (0..<30).map { (n: Int) -> Note in
                let source: Source = n % 2 == 0 ? Self.one : Self.two
                let categories: Set<FediqoCore.Category> = n % 3 == 0 ? [.home] : [.public]
                return Note(
                    id: "new\(n)-\(query.timeline)", source: source, author: "A", handle: "a@one.example",
                    body: "new", postedAt: later.addingTimeInterval(Double(n / 3)), categories: categories
                )
            }
            try await file.save(RowChanges(upserts: landed))
            var read: [NoteKey] = []
            var from = newest
            while true {
                let page = try await file.page(query, .after(from), limit: 4)
                read = page.rows.map(\.note.key) + read
                if page.exhausted { break }
                from = try #require(page.next)
            }
            let all = try file.load().notes
            let fresh = Set(landed.map { $0.key })
            #expect(read == oracle(all, query).filter(fresh.contains))
            #expect(!read.isEmpty)
        }
    }

    @Test("before and after a row of the pool, by its key or its place: the rest of the timeline, no gap, no row twice")
    func fromARowHeld() async throws {
        let (file, loaded) = try await store()
        for query in try timelines {
            let whole = oracle(loaded, query)
            let rows = try await down(file, query, limit: 1_000).flatMap(\.rows)
            for n in stride(from: 0, to: whole.count, by: max(1, whole.count / 5)) {
                let key = whole[n]
                var older: [NoteKey] = []
                var ask = PageAsk.beforeRow(key)
                while true {
                    let page = try await file.page(query, ask, limit: 9)
                    older += page.rows.map(\.note.key)
                    if page.exhausted { break }
                    ask = .before(try #require(page.oldest))
                }
                #expect(older == Array(whole[(n + 1)...]))
                var newer: [NoteKey] = []
                ask = .afterRow(key)
                while true {
                    let page = try await file.page(query, ask, limit: 9)
                    newer = page.rows.map(\.note.key) + newer
                    if page.exhausted { break }
                    ask = .after(try #require(page.newest))
                }
                #expect(newer == Array(whole[..<n]))
                // A row's own place asks the same as its key.
                let place = try #require(rows[n].place)
                let byPlace = try await file.page(query, .before(place), limit: 9)
                let byKey = try await file.page(query, .beforeRow(key), limit: 9)
                #expect(byPlace.rows.map(\.note.key) == byKey.rows.map(\.note.key))
            }
        }
        await #expect(throws: StoreFile.NotOnDisk.self) {
            try await file.page(try query([]), .beforeRow(NoteKey(host: "one.example", id: "absent")))
        }
    }

    // MARK: - The budget

    @Test("a timeline that shows nothing costs a bounded read each page, short and not exhausted until the end")
    func budget() async throws {
        let (file, loaded) = try await store()
        let pages = try await down(file, try query([.source("nowhere.example")]), limit: 100, budget: 300)
        #expect(pages.allSatisfy { $0.rows.isEmpty })
        #expect(pages.count >= loaded.count / 300)
        #expect(pages.dropLast().allSatisfy { !$0.exhausted })
        #expect(Set(pages.compactMap { $0.next }).count == pages.count)
    }

    @Test("a sparse timeline read with a small budget still comes whole", arguments: [10, 50, 333])
    func sparse(budget: Int) async throws {
        let (file, loaded) = try await store()
        let query = try query([.author("zoë@one.example", in: .every, sources: Self.sources), .keyword("rocks", in: .every)])
        let read = try await down(file, query, limit: 3, budget: budget).flatMap(\.rows).map(\.note.key)
        #expect(!read.isEmpty)
        #expect(read == oracle(loaded, query))
    }

    // MARK: - What a page holds besides

    @Test("what a shown row holds with it comes as carried, and what that holds in turn")
    func carried() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func post(_ id: String, _ categories: Set<FediqoCore.Category>, refs: [Reference] = []) -> Note {
            Note(id: id, source: Self.one, author: "A", handle: "a@one.example", body: "b \(id)", postedAt: at, categories: categories, refs: refs)
        }
        let notes = [
            post("boost", [.home], refs: [Reference(kind: .reblogs, id: "target")]),
            post("target", [.public], refs: [Reference(kind: .quotes, id: "deeper", state: .accepted)]),
            post("deeper", [.public]),
            post("quoting", [.home], refs: [Reference(kind: .quotes, id: "absent", state: .accepted)]),
            Note(
                id: "discuz:forum.example:9:post:3", source: Self.forum, author: "F", handle: "f@forum.example", body: "",
                postedAt: at, categories: [.board(id: "2")], opening: ForumOpening(words: "r", floor: 3, postedAt: at)
            ),
            Note(id: "discuz:forum.example:9", source: Self.forum, author: "F", handle: "f@forum.example", body: "topic", postedAt: at.addingTimeInterval(-60), categories: []),
        ]
        let (file, _) = try await store(notes)
        let home = try await file.page(try query([.category(.home, in: .every, sources: Self.sources)]), .newest)
        #expect(Set(home.rows.map(\.note.id)) == ["boost", "quoting"])
        #expect(Set(home.carried.map(\.note.id)) == ["target", "deeper"])
        let board = try await file.page(try query([.category(.board(id: "2"), in: .source(host: "forum.example"), sources: Self.sources)]), .newest)
        #expect(board.rows.map(\.note.id) == ["discuz:forum.example:9:post:3"])
        #expect(board.carried.map(\.note.id) == ["discuz:forum.example:9"])
    }

    @Test("a row that will not decode is passed over, and the rows round it are read")
    func undecodable() async throws {
        let (file, loaded) = try await store()
        try await file.db.write { db in
            try db.execute(sql: """
                INSERT INTO note (host, id, posted_at, categories, facts) VALUES
                ('one.example', 'broken', '2026-09-20 12:00:00.000', '[{"kind":"home"}]', '{not json'),
                ('one.example', 'odd', '2026-09-20 12:00:00.000', 'nor this', '{"handle":1}')
                """)
        }
        for query in try timelines {
            let read = try await down(file, query, limit: 7).flatMap(\.rows).map(\.note.key)
            #expect(read == oracle(loaded, query))
        }
    }

    @Test("a cancelled read stops between chunks")
    func cancelled() async throws {
        let (file, _) = try await store()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await file.page(try query([.source("nowhere.example")]), .newest)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
