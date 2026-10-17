import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A keyword timeline read a page at a time by the words index (#360, K2): whichever way the
/// file is asked — by the rows the index gives, row by row of the index, or with no index at all —
/// and whatever stands of it — built, half built, rows due, `note_reblogs` gone — the pages laid
/// end to end are what the whole store would show, no row missing, none twice, no run split.
@Suite("A keyword timeline read by the words index", .enabled(if: StoreFile.wordsCapable))
struct StoreWordPagesTests {
    private static let one = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Seven")])
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

    /// Pieces a body is made of, some rare and some everywhere, that fold into each other.
    private static let pieces = [
        "swift", "Swift", "ＳＷＩＦＴ", "rocks", "plain", "words", "台灣", "台", "灣", "日本語", "café", "cafe\u{301}",
        "🇺🇸", "🇦🇺🇸🇪", "👍", " ", " ", "rare",
    ]

    /// What keywords are drawn from: pieces, parts of them, and some no body holds.
    private static let keywords = [
        "swift", "SWIFT", "ｓｗｉ", "rocks", "台", "灣", "台灣", "日本", "café", "é", "🇺🇸", "👍", "rare", "ft r", "absent", "語",
    ]

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Some 900 rows on few moments; a third of the posts with a copy from the other source under
    /// one id and time; a fifth reblogs — of posts held, of posts not, of reblogs, of a post only
    /// the other source holds — and quotes. Written in no order of time.
    private static func seeded(_ random: inout Seeded) -> [Note] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let moments = (0..<50).map { base.addingTimeInterval(Double($0) * 60) }
        let categories: [[FediqoCore.Category]] = [[.public], [.home], [.public, .home], [.list(id: "7")], []]
        var notes: [Note] = []
        for post in 0..<650 {
            let at = moments[Int.random(in: 0..<moments.count, using: &random)]
            let host = Bool.random(using: &random) ? one : two
            var refs: [Reference] = []
            switch Int.random(in: 0..<10, using: &random) {
            case 0, 1: refs = [Reference(kind: .reblogs, id: "p\(Int.random(in: 0..<700, using: &random))")]
            case 2: refs = [Reference(kind: .quotes, id: "p\(Int.random(in: 0..<650, using: &random))", state: .accepted)]
            default: break
            }
            let body = (0..<Int.random(in: 0...4, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined(separator: " ")
            func copy(_ source: Source) -> Note {
                Note(
                    id: "p\(post)", source: source, author: "A", handle: "a\(post % 4)@one.example", body: body, postedAt: at,
                    categories: Set(categories.randomElement(using: &random)!), refs: refs
                )
            }
            notes.append(copy(host))
            if Int.random(in: 0..<3, using: &random) == 0 { notes.append(copy(host == one ? two : one)) }
        }
        notes.shuffle(using: &random)
        return notes
    }

    /// How much of the words index the file holds.
    enum Standing: CaseIterable, Sendable {
        /// None: an older build's file, or a SQLite with no FTS5.
        case none
        /// Built to the bottom, nothing due.
        case built
        /// Begun, the floor part way down.
        case half
        /// Built, then rows written by SQL alone — an older build's — so some are due.
        case due
        /// Built, `note_reblogs` gone.
        case noReblogsIndex
    }

    private func store(_ standing: Standing, seed: UInt64) async throws -> (StoreFile, [Note]) {
        var random = Seeded(state: seed)
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: Self.seeded(&random))
        try await file.makeIndexes()
        switch standing {
        case .none:
            break
        case .built, .due, .noReblogsIndex:
            try await file.buildWords(chunk: 300, capable: true)
        case .half:
            _ = try await file.db.write { db in try StoreFile.makeWords(db, capable: true) }
            try await file.db.write { db in try db.execute(sql: StoreFile.reblogsIndex) }
            _ = try await file.buildWordsStep(chunk: 200)
            _ = try await file.buildWordsStep(chunk: 200)
        }
        if standing == .due {
            // Bodies changed, and rows written anew, as an older build writes: nothing drains them.
            try await file.db.write { db in
                try db.execute(sql: """
                    UPDATE note SET facts = json_set(facts, '$.body', 'rare 台灣 ' || id) WHERE rowid % 37 = 0
                    """)
                try db.execute(sql: """
                    INSERT INTO note (host, id, posted_at, categories, facts, gone_at, kept, bookmarked, edited_at, earlier, language, refs, refs_due)
                    SELECT host, id || 'x', posted_at, categories, json_set(facts, '$.body', 'swift rare'), gone_at, kept, bookmarked,
                    edited_at, earlier, language, refs, refs_due FROM note WHERE rowid % 41 = 0
                    """)
            }
            #expect(try #require(try file.wordsState()).due > 0)
        }
        if standing == .noReblogsIndex {
            try await file.db.write { db in try db.execute(sql: "DROP INDEX note_reblogs") }
        }
        // Some reblogs as an older build may have written them: another reference first.
        try await file.db.write { db in try Self.oddify(db, "rowid % 3 = 0") }
        return (file, try file.load().notes)
    }

    /// The reblogs `which` names given a reference before their reblog, of another kind and naming
    /// nothing held.
    private static func oddify(_ db: Database, _ which: String) throws {
        try db.execute(sql: """
            UPDATE note SET refs = json_array(json_set(json_extract(refs, '$[0]'), '$.kind', 'answers', '$.id', 'nothing'), json(json_extract(refs, '$[0]')))
            WHERE json_valid(refs) AND json_extract(refs, '$[0].kind') = 'reblogs' AND \(which)
            """)
    }

    /// What the whole store shows for `query`, as the screens make it.
    private func oracle(_ loaded: [Note], _ query: PageQuery) -> [NoteKey] {
        let arrival = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.key, $0) })
        let items = loaded.filter { !$0.isPartOfTopic }.sorted { a, b in
            if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
            if a.id != b.id { return a.id < b.id }
            return arrival[a.key]! < arrival[b.key]!
        }
        return query.compiled.shown(items, TextIndex(items), targets: ReblogTargets(loaded)).map(\.key)
    }

    /// A random timeline with keywords: one to three, every source or one's, beside a category,
    /// a source, an author, a keyword hidden, a source hidden — any of them or none.
    private static func timeline(_ random: inout Seeded) throws -> PageQuery {
        func scope() -> RuleScope {
            Int.random(in: 0..<3, using: &random) == 0 ? .source(host: [one, two].randomElement(using: &random)!.host) : .every
        }
        var rules: [Rule?] = (0..<Int.random(in: 1...3, using: &random)).map { _ in
            .keyword(keywords.randomElement(using: &random)!, in: scope())
        }
        if Bool.random(using: &random) {
            rules.append(.category([.home, .public, .list(id: "7")].randomElement(using: &random)!, in: .source(host: one.host), sources: sources))
            if Bool.random(using: &random) { rules.append(.category(.home, in: .source(host: two.host), sources: sources)) }
        }
        if Int.random(in: 0..<3, using: &random) == 0 { rules.append(.source(one.host)) }
        if Int.random(in: 0..<4, using: &random) == 0 { rules.append(.author("a1@one.example", in: .every, sources: sources)) }
        if Int.random(in: 0..<3, using: &random) == 0 { rules.append(.keyword(keywords.randomElement(using: &random)!, in: scope(), effect: .exclude)) }
        if Int.random(in: 0..<5, using: &random) == 0 { rules.append(.source(two.host, effect: .exclude)) }
        let definition = TimelineDefinition(name: "T", rules: try rules.map { try #require($0) })
        return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
    }

    /// Every page from the newest down.
    private func down(_ file: StoreFile, _ query: PageQuery, limit: Int, budget: Int, most: Int) async throws -> [Page] {
        var pages: [Page] = []
        var ask = PageAsk.newest
        while pages.count < 10_000 {
            let page = try await file.page(query, ask, limit: limit, scanBudget: budget, candidatesMost: most)
            pages.append(page)
            if page.exhausted { break }
            ask = .before(try #require(page.next))
        }
        return pages
    }

    /// Every page from `bottom` up, put back newest first.
    private func up(_ file: StoreFile, _ query: PageQuery, from bottom: PageCursor, limit: Int, most: Int) async throws -> [Page] {
        var pages: [Page] = []
        var from = bottom
        while pages.count < 10_000 {
            let page = try await file.page(query, .after(from), limit: limit, scanBudget: 20_000, candidatesMost: most)
            pages.append(page)
            if page.exhausted { break }
            from = try #require(page.next)
        }
        return pages.reversed()
    }

    /// No row twice, and no page ending inside a run of one post's copies.
    private func whole(_ pages: [Page], _ context: String) {
        let keys = pages.flatMap(\.rows).map(\.note.key)
        #expect(Set(keys).count == keys.count, "\(context): a row twice")
        let shown = pages.filter { !$0.rows.isEmpty }
        for (page, next) in zip(shown, shown.dropFirst()) {
            let last = page.rows.last!.note, first = next.rows.first!.note
            #expect(last.postedAt != first.postedAt || last.id != first.id, "\(context): a run split")
        }
    }

    @Test("random rule sets with keywords: the pages laid end to end are the whole store's, however the index stands", arguments: Standing.allCases)
    func pagesAreTheWhole(standing: Standing) async throws {
        let seed: UInt64 = 360_2 + UInt64(Standing.allCases.firstIndex(of: standing)!)
        let (file, loaded) = try await store(standing, seed: seed)
        var random = Seeded(state: seed)
        let bottom = try #require(try await down(file, PageQuery(
            timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: Self.sources)
        ), limit: 5_000, budget: 20_000, most: 0).last?.next)
        let bottomKey = try await file.db.read { db in
            try Row.fetchOne(db, sql: "SELECT host, id FROM note WHERE rowid = ?", arguments: [bottom.rowid])
                .map { NoteKey(host: $0["host"], id: $0["id"]) }
        }
        var asked: [String: Int] = [:]
        var shown = 0
        for trial in 0..<24 {
            let query = try Self.timeline(&random)
            let expected = oracle(loaded, query)
            shown += expected.count
            // Read by what the index gives, and row by row of it.
            // Caps that the posts two keywords share can hide, too.
            for most in [StoreFile.wordsCandidatesMost, [3, 40, 150, 400].randomElement(using: &random)!] {
                let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: most) }
                let kind = switch plan {
                case .open: "open"
                case .index: "index"
                case .candidates: "candidates"
                }
                asked[kind, default: 0] += 1
                let limit = [1, 3, 17, 100].randomElement(using: &random)!
                let budget = [40, 20_000].randomElement(using: &random)!
                let context = "\(standing) trial \(trial) \(kind) limit \(limit) budget \(budget)"
                let pages = try await down(file, query, limit: limit, budget: budget, most: most)
                #expect(pages.flatMap(\.rows).map(\.note.key) == expected, "\(context): down")
                whole(pages, context)
                if trial % 3 == 0 {
                    let upward = try await up(file, query, from: bottom, limit: limit, most: most)
                    #expect(upward.flatMap(\.rows).map(\.note.key) == expected.filter { $0 != bottomKey }, "\(context): up")
                    whole(upward, context + " up")
                }
            }
        }
        #expect(shown > 0)
        switch standing {
        case .none: #expect(asked.keys.sorted() == ["open"])
        case .half, .noReblogsIndex: #expect(asked["candidates"] == nil && asked["index"] != nil)
        case .built, .due: #expect(asked["candidates"] != nil && asked["index"] != nil)
        }
    }

    @Test("a reblog is found by the words of the post it reblogs, and a post found brings its reblogs")
    func reblogsByTheirPost() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func note(_ id: String, _ body: String, source: Source = Self.one, refs: [Reference] = [], at offset: Double = 0) -> Note {
            Note(id: id, source: source, author: "A", handle: "a@one.example", body: body, postedAt: at.addingTimeInterval(offset), categories: [.home], refs: refs)
        }
        let notes = [
            note("post", "台灣 swift", at: -100),
            note("boost", "", refs: [Reference(kind: .reblogs, id: "post")], at: 10),
            note("other", "nothing here", at: -50),
            note("boostOther", "", refs: [Reference(kind: .reblogs, id: "other")], at: 20),
            // A reblog on another source of a post only this one holds: not the post it reblogs.
            note("boostElsewhere", "", source: Self.two, refs: [Reference(kind: .reblogs, id: "post")], at: 30),
            // Made odd below: another reference before its reblog, as an older build may write.
            note("boostOdd", "", refs: [Reference(kind: .reblogs, id: "post")], at: 25),
        ]
        for most in [StoreFile.wordsCandidatesMost, 0] {
            let file = try StoreFile(at: try scratch())
            try await file.save(sources: Self.sources, notes: notes)
            try await file.buildWords(chunk: 300, capable: true)
            try await file.db.write { db in try Self.oddify(db, "id = 'boostOdd'") }
            let definition = TimelineDefinition(name: "T", rules: [try #require(Rule.keyword("台灣", in: .every))])
            let query = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: Self.sources))
            let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: most) }
            if most > 0 {
                guard case .candidates(let rowids) = plan else { Issue.record("not by candidates"); continue }
                #expect(rowids.count == 3)
            } else {
                #expect(plan == .index)
            }
            let page = try await file.page(query, .newest, limit: 100, scanBudget: 20_000, candidatesMost: most)
            #expect(page.rows.map(\.note.id) == ["boostOdd", "boost", "post"])
            #expect(page.exhausted)
        }
    }

    @Test("keywords that find the same posts never hide the rest behind the cap")
    func overlapUnderTheCap() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let notes = (1...12).map { n in
            Note(
                id: "p\(n)", source: Self.one, author: "A", handle: "a@one.example", body: n <= 8 ? "foo bar" : "bar",
                postedAt: at.addingTimeInterval(Double(n)), categories: [.home]
            )
        }
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes)
        try await file.buildWords(chunk: 300, capable: true)
        let definition = TimelineDefinition(name: "T", rules: [
            try #require(Rule.keyword("foo", in: .every)), try #require(Rule.keyword("bar", in: .every)),
        ])
        let query = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: Self.sources))
        let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: 10) }
        #expect(plan == .index)
        let page = try await file.page(query, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 10)
        #expect(page.rows.count == 12)
        // Under a cap they all fit in, by the index's answer.
        let wide = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: 20) }
        guard case .candidates(let rowids) = wide else { Issue.record("not by candidates"); return }
        #expect(rowids.count == 12)
    }

    @Test("the reblogs of the posts found count toward the cap too")
    func reblogsUnderTheCap() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let post = Note(id: "post", source: Self.one, author: "A", handle: "a@one.example", body: "foo", postedAt: at, categories: [.home])
        let boosts = (0..<5).map { n in
            Note(
                id: "boost\(n)", source: Self.one, author: "B", handle: "b@one.example", body: "",
                postedAt: at.addingTimeInterval(Double(n + 1)), categories: [.home], refs: [Reference(kind: .reblogs, id: "post")]
            )
        }
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: [post] + boosts)
        try await file.buildWords(chunk: 300, capable: true)
        let definition = TimelineDefinition(name: "T", rules: [try #require(Rule.keyword("foo", in: .every))])
        let query = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: Self.sources))
        let narrow = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: 4) }
        #expect(narrow == .index)
        let wide = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: 6) }
        guard case .candidates(let rowids) = wide else { Issue.record("not by candidates"); return }
        #expect(rowids.count == 6)
        for most in [4, 6] {
            let page = try await file.page(query, .newest, limit: 100, scanBudget: 20_000, candidatesMost: most)
            #expect(page.rows.count == 6)
        }
    }

    /// A store of 600 posts that say `foo`, and one older that says nothing yet.
    private func fooStore() async throws -> (StoreFile, PageQuery, Note) {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let notes = (0..<600).map { n in
            Note(id: "p\(n)", source: Self.one, author: "A", handle: "a@one.example", body: "foo \(n)", postedAt: at.addingTimeInterval(Double(n)), categories: [.home])
        }
        let late = Note(id: "late", source: Self.one, author: "A", handle: "a@one.example", body: "nothing", postedAt: at.addingTimeInterval(-60), categories: [.home])
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes + [late])
        try await file.makeIndexes()
        try await file.buildWords(chunk: 300, capable: true)
        let definition = TimelineDefinition(name: "T", rules: [try #require(Rule.keyword("foo", in: .every))])
        return (file, PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: Self.sources)), late)
    }

    @Test("a save between two chunks of a page is read by the rest of it: the plan is made again")
    func savedMeanwhile() async throws {
        let (file, query, late) = try await fooStore()
        let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, query.compiled.prefilter, most: StoreFile.wordsCandidatesMost) }
        guard case .candidates = plan else { Issue.record("not by candidates"); return }
        let page = try await file.page(query, .newest, limit: 1_000, scanBudget: 20_000, candidatesMost: StoreFile.wordsCandidatesMost) { chunk in
            guard chunk == 1 else { return }
            try await file.save(RowChanges(upserts: [Note(
                id: late.id, source: late.source, author: late.author, handle: late.handle, body: "foo at last",
                postedAt: late.postedAt, categories: late.categories
            )]))
        }
        #expect(page.rows.count == 601)
        #expect(page.rows.last?.note.id == "late")
    }

    @Test("another copy of the app saving into the file between two chunks of a page: the rest of it reads what it wrote")
    func otherConnectionMeanwhile() async throws {
        let (file, query, _) = try await fooStore()
        let path = file.db.path
        let page = try await file.page(query, .newest, limit: 1_000, scanBudget: 20_000, candidatesMost: StoreFile.wordsCandidatesMost) { chunk in
            guard chunk == 1 else { return }
            let other = try DatabaseQueue(path: path)
            try await other.write { db in
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', 'foo at last') WHERE id = 'late'")
            }
            try other.close()
        }
        #expect(page.rows.count == 601)
        #expect(page.rows.last?.note.id == "late")
    }

    @Test("rows renumbered between two chunks of a page — a VACUUM's — are read by the rest of it")
    func renumberedMeanwhile() async throws {
        let (file, query, _) = try await fooStore()
        let page = try await file.page(query, .newest, limit: 1_000, scanBudget: 20_000, candidatesMost: StoreFile.wordsCandidatesMost) { chunk in
            guard chunk == 1 else { return }
            try await file.db.writeWithoutTransaction { db in
                try StoreFile.guardingRowids(db) { try db.execute(sql: "UPDATE note SET rowid = rowid + 1000") }
            }
        }
        #expect(page.rows.count == 600)
        #expect(Set(page.rows.map(\.note.id)).count == 600)
    }

    @Test("asked row by row, a reblog's post is read by its key, and the index's answer once a read")
    func rowByRowPlan() async throws {
        var random = Seeded(state: 1)
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: Self.seeded(&random))
        try await file.makeIndexes()
        try await file.buildWords(chunk: 300, capable: true)
        let detail = try await file.db.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT rowid, (\(StoreFile.mayHold)) FROM note INDEXED BY note_page
                ORDER BY posted_at DESC, id ASC, rowid ASC LIMIT 100
                """, arguments: ["b0000", "b0000"]).map { $0["detail"] as String }
        }
        #expect(detail.contains { $0.contains("SEARCH t") && $0.contains("host=? AND id=?") })
        #expect(!detail.contains { $0.contains("CORRELATED") && $0.contains("LIST SUBQUERY") })
    }

    @Test("a hit of the index hides nothing: a keyword hidden stays the rules' alone")
    func excludesStayCertain() throws {
        let definition = TimelineDefinition(name: "T", rules: [
            try #require(Rule.keyword("swift", in: .every)), try #require(Rule.keyword("rocks", in: .source(host: "one.example"), effect: .exclude)),
        ])
        let prefilter = CompiledTimeline(definition, sources: Self.sources).prefilter
        #expect(prefilter.excludes.isEmpty)
        #expect(prefilter.groups == [[.words("swift", host: nil)]])
    }
}
