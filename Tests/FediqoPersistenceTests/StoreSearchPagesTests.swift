import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A search read from the file a page at a time through the words index (#360, K3, C25): whichever
/// way the file is asked — by the rows the index gives for the pattern, row by row of it, while it
/// is built — the pages laid end to end are what `SearchIndex` finds over the whole store through
/// the timeline's rules, no row missing, none twice; and where the file cannot narrow a pattern,
/// it says so rather than answer.
@Suite("A search read by the words index", .enabled(if: StoreFile.wordsCapable))
struct StoreSearchPagesTests {
    private static let one = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Seven")])
    private static let two = Source(host: "two.example", kind: .mastodon)
    /// A forum, read for one board.
    private static let three = Source(host: "three.example", kind: .discuz, boards: [BoardSubscription(fid: 34, name: "Swift Talk")])
    private static let sources = [one, two, three]

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
        "🇺🇸", "🇦🇺🇸🇪", "👍", " ", "rare", "#tag", "＃台灣",
    ]

    private static let authors = ["Ada", "Bob 台灣", "Cé", "Ｄｅｅ"]

    /// What is searched for: pieces, parts of them, wildcards, handles, names, hosts, and some no
    /// post holds, and some that name a category or a part of one: a list of one source, home,
    /// public, trends — found by what a post arrived through as well as its words.
    private static let patterns = [
        "swift", "SWIFT", "ｓｗｉ", "rocks", "台", "灣", "台灣", "日本", "café", "é", "🇺🇸", "👍", "rare", "ft r", "absent",
        "sw*ft", "s?ift", "台*語", "@a1", "a2@one", "one.exam", "two.example", "ada", "bob 台", "ｄｅｅ", "booster", "@zed",
        "#tag", "#台灣", "語", "e", "re", "sev", "Seven", "ome", "pub", "trends", "talk", "ft ta",
    ]

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Some 900 rows on few moments; a third of the posts with a copy from the other source under
    /// one id and time; a fifth reblogs — of posts held, of posts not — and quotes; some posts
    /// naming who boosted them.
    private static func seeded(_ random: inout Seeded) -> [Note] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let moments = (0..<50).map { base.addingTimeInterval(Double($0) * 60) }
        let categories: [[FediqoCore.Category]] = [[.public], [.home], [.public, .home], [.list(id: "7")], []]
        var notes: [Note] = []
        for post in 0..<650 {
            let at = moments[Int.random(in: 0..<moments.count, using: &random)]
            let host = Bool.random(using: &random) ? one : two
            var refs: [Reference] = []
            var reblog = false
            switch Int.random(in: 0..<10, using: &random) {
            case 0, 1:
                refs = [Reference(kind: .reblogs, id: "p\(Int.random(in: 0..<700, using: &random))")]
                reblog = true
            case 2: refs = [Reference(kind: .quotes, id: "p\(Int.random(in: 0..<650, using: &random))", state: .accepted)]
            default: break
            }
            let body = (0..<Int.random(in: 0...4, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined(separator: " ")
            let author = authors.randomElement(using: &random)!
            // A post that names who boosted it, as some sources send one; a reblog's own author
            // is who reblogged.
            let boosted = !reblog && post % 5 == 0
            func copy(_ source: Source) -> Note {
                Note(
                    id: "p\(post)", source: source, author: author, handle: "a\(post % 4)@one.example", body: body, postedAt: at,
                    categories: Set(categories.randomElement(using: &random)!),
                    boostedBy: boosted ? "Booster" : nil, boosterHandle: boosted ? "zed@two.example" : nil, refs: refs
                )
            }
            // A tenth on the forum's board, alone.
            if post % 10 == 9 {
                notes.append(Note(
                    id: "p\(post)", source: three, author: author, handle: "a\(post % 4)@three.example", body: body, postedAt: at,
                    categories: [.board(id: "34")]
                ))
                continue
            }
            notes.append(copy(host))
            if Int.random(in: 0..<3, using: &random) == 0 { notes.append(copy(host == one ? two : one)) }
        }
        notes.shuffle(using: &random)
        return notes
    }

    /// How much of the words index the file holds.
    enum Standing: CaseIterable, Sendable {
        case built, half, due, noReblogsIndex
    }

    private func store(_ standing: Standing?, seed: UInt64) async throws -> (StoreFile, [Note]) {
        var random = Seeded(state: seed)
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: Self.seeded(&random))
        try await file.makeIndexes()
        switch standing {
        case nil:
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
            // Bodies and names changed as an older build writes them: nothing drains them.
            try await file.db.write { db in
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.body', 'rare 台灣 ' || id) WHERE rowid % 37 = 0")
                try db.execute(sql: "UPDATE note SET facts = json_set(facts, '$.author', 'Ada swift') WHERE rowid % 43 = 0")
            }
            #expect(try #require(try file.wordsState()).due > 0)
        }
        if standing == .noReblogsIndex {
            try await file.db.write { db in try db.execute(sql: "DROP INDEX note_reblogs") }
        }
        return (file, try file.load().notes)
    }

    /// What the whole store's search finds in `query`, as the screens find it: the timeline's
    /// rules, then the pattern over `SearchIndex`, a reblog by the post it reblogs.
    private func oracle(_ loaded: [Note], _ query: PageQuery, _ search: NoteSearch) -> [NoteKey] {
        let arrival = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.key, $0) })
        let items = loaded.filter { !$0.isPartOfTopic }.sorted { a, b in
            if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
            if a.id != b.id { return a.id < b.id }
            return arrival[a.key]! < arrival[b.key]!
        }
        let targets = ReblogTargets(loaded)
        let shown = query.compiled.shown(items, TextIndex(items), targets: targets)
        return search.found(shown, SearchIndex(loaded), targets: targets).map(\.key)
    }

    /// A random timeline: everything, or a category, a source, a keyword, an author hidden.
    private static func timeline(_ random: inout Seeded) throws -> PageQuery {
        var rules: [Rule?] = []
        switch Int.random(in: 0..<5, using: &random) {
        case 0: rules.append(.category(.home, in: .source(host: one.host), sources: sources))
        case 1: rules.append(.source(two.host))
        case 2: rules.append(.keyword(["swift", "台", "rare"].randomElement(using: &random)!, in: .every))
        case 3: rules.append(.author("a1@one.example", in: .every, effect: .exclude, sources: sources))
        default: break
        }
        let definition = rules.isEmpty ? TimelineDefinition.all : TimelineDefinition(name: "T", rules: try rules.map { try #require($0) })
        return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
    }

    /// Every page of `search` from the newest down; nothing where the file answers none.
    private func down(
        _ file: StoreFile, _ query: PageQuery, _ search: NoteSearch, limit: Int, budget: Int, most: Int
    ) async throws -> [Page]? {
        var pages: [Page] = []
        var ask = PageAsk.newest
        while pages.count < 10_000 {
            guard let page = try await file.search(query, search, ask, limit: limit, scanBudget: budget, candidatesMost: most)
            else { return nil }
            pages.append(page)
            if page.exhausted { break }
            ask = .before(try #require(page.next))
        }
        return pages
    }

    @Test("random patterns over random timelines: the pages laid end to end are the whole store's search, however the index stands", arguments: Standing.allCases)
    func pagesAreTheWholeSearch(standing: Standing) async throws {
        let seed: UInt64 = 360_3 + UInt64(Standing.allCases.firstIndex(of: standing)!)
        let (file, loaded) = try await store(standing, seed: seed)
        var random = Seeded(state: seed)
        var plans: [String: Int] = [:]
        var found = 0
        for (trial, pattern) in Self.patterns.enumerated() {
            let query = try Self.timeline(&random)
            let search = try #require(NoteSearch(pattern, sources: Self.sources))
            let expected = oracle(loaded, query, search)
            found += expected.count
            for most in [StoreFile.wordsCandidatesMost, [3, 40, 150].randomElement(using: &random)!] {
                let match = try #require(StoreFile.searchMatch(search.pattern.literals))
                let also = StoreFile.searchCategories(search.namedCategories)
                let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, matches: [match], also: also, most: most) }
                let kind = switch plan {
                case .open: "open"
                case .index: "index"
                case .candidates: "candidates"
                }
                plans[kind, default: 0] += 1
                let limit = [1, 7, 100].randomElement(using: &random)!
                let budget = [40, 20_000].randomElement(using: &random)!
                let context = "\(standing) trial \(trial) \(pattern) \(kind) limit \(limit) budget \(budget)"
                let pages = try #require(try await down(file, query, search, limit: limit, budget: budget, most: most), "\(context)")
                let keys = pages.flatMap(\.rows).map(\.note.key)
                #expect(keys == expected, "\(context)")
                #expect(Set(keys).count == keys.count, "\(context): a row twice")
            }
        }
        #expect(found > 0)
        #expect(plans["open"] == nil)
        switch standing {
        case .half, .noReblogsIndex: #expect(plans["candidates"] == nil)
        case .built, .due: #expect(plans["candidates"] != nil && plans["index"] != nil)
        }
    }

    @Test("a pattern that names a category is read by the rows found where they are few, and row by row past the cap")
    func categoryCandidates() async throws {
        let (file, loaded) = try await store(.built, seed: 2)
        let query = PageQuery(
            timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: Self.sources)
        )
        // The list's name, rare in any text: its rows, with the few the index gives.
        let search = try #require(NoteSearch("Seven", sources: Self.sources))
        let match = try #require(StoreFile.searchMatch(search.pattern.literals))
        let also = StoreFile.searchCategories(search.namedCategories)
        let listed = loaded.count { $0.source.host == Self.one.host && $0.categories.contains(.list(id: "7")) }
        #expect(listed > 20)
        let plan = try await file.db.read { db in try StoreFile.wordsAsk(db, matches: [match], also: also, most: 5_000) }
        guard case .candidates(let rowids) = plan else { Issue.record("not by candidates"); return }
        #expect(rowids.count >= listed)
        // Past the cap, row by row: the category's rows count toward it as the index's do.
        let capped = try await file.db.read { db in try StoreFile.wordsAsk(db, matches: [match], also: also, most: listed - 1) }
        #expect(capped == .index)
        for most in [5_000, listed - 1] {
            let pages = try #require(try await down(file, query, search, limit: 7, budget: 20_000, most: most))
            #expect(pages.flatMap(\.rows).map(\.note.key) == oracle(loaded, query, search), "most \(most)")
        }
    }

    @Test("a pattern the file cannot narrow is answered by nothing: wildcards alone, no words index")
    func notNarrowed() async throws {
        let (built, _) = try await store(.built, seed: 1)
        let query = PageQuery(
            timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: Self.sources)
        )
        // Patterns of wildcards alone, whether or not they match a category's name.
        for pattern in ["*", "?", "?????????????"] {
            let search = try #require(NoteSearch(pattern, sources: Self.sources))
            #expect(try await built.search(query, search, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 5_000) == nil, "\(pattern)")
        }
        let search = try #require(NoteSearch("swift", sources: Self.sources))
        #expect(try await built.search(query, search, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 5_000) != nil)
        // This SQLite keeping none, as the app is told.
        #expect(try await built.search(query, search, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 5_000, capable: false) == nil)
        // A file with none made yet: an older build's, or one whose build has not begun.
        let (none, _) = try await store(nil, seed: 1)
        #expect(try await none.search(query, search, .newest, limit: 100, scanBudget: 20_000, candidatesMost: 5_000) == nil)
    }

    @Test("a pattern is asked as all its runs in the body, or all in the names beside it")
    func theMatch() throws {
        #expect(StoreFile.searchMatch([]) == nil)
        #expect(StoreFile.searchMatch([""]) == nil)
        let one = try #require(WordGrams.asked("ab", in: .body)).joined(separator: " AND ")
        let other = try #require(WordGrams.asked("ab", in: .other)).joined(separator: " AND ")
        #expect(StoreFile.searchMatch(["ab"]) == "(\(one)) OR (\(other))")
        let both = try #require(StoreFile.searchMatch(["swift", "台灣"]))
        #expect(both.components(separatedBy: " OR ").count == 2)
        #expect(both.contains(try #require(WordGrams.asked("台灣", in: .other)).first!))
        #expect(try #require(NoteSearch("a*b?cd", sources: [])).pattern.literals == ["a", "b", "cd"])
        // The categories a pattern names: a list on its own source, the shared ones on every source.
        let list = NoteSearch.NamedCategory(category: .list(id: "7"), host: Self.one.host)
        #expect(try #require(NoteSearch("sev", sources: Self.sources)).namedCategories == [list])
        let e = Set(try #require(NoteSearch("e", sources: Self.sources)).namedCategories)
        #expect(e == Set([list] + [FediqoCore.Category.home, .trends].map { NoteSearch.NamedCategory(category: $0, host: nil) }))
        #expect(try #require(NoteSearch("rocks", sources: Self.sources)).namedCategories.isEmpty)
    }

    @Test("a reblog is found by who reblogged it and by the post it reblogs, read past the pool and into the file")
    func reblogsBySearch() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        // A reblog's own author is who reblogged.
        func note(_ id: String, _ body: String, refs: [Reference] = [], by author: String = "A", at offset: Double = 0) -> Note {
            Note(
                id: id, source: Self.one, author: author, handle: "\(author.lowercased())@one.example", body: body,
                postedAt: at.addingTimeInterval(offset), categories: [.home], refs: refs
            )
        }
        let notes = [
            note("post", "台灣 needle", at: -100),
            note("boost", "", refs: [Reference(kind: .reblogs, id: "post")], by: "zed", at: 10),
            note("other", "nothing here", at: -50),
            note("boostOther", "", refs: [Reference(kind: .reblogs, id: "other")], by: "needleman", at: 20),
            note("boostNone", "", refs: [Reference(kind: .reblogs, id: "other")], by: "zed", at: 30),
        ]
        for most in [StoreFile.wordsCandidatesMost, 0] {
            let file = try StoreFile(at: try scratch())
            try await file.save(sources: Self.sources, notes: notes)
            try await file.buildWords(chunk: 300, capable: true)
            let query = PageQuery(
                timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: Self.sources)
            )
            let search = try #require(NoteSearch("needle", sources: Self.sources))
            let page = try #require(try await file.search(query, search, .newest, limit: 100, scanBudget: 20_000, candidatesMost: most))
            #expect(page.rows.map(\.note.id) == ["boostOther", "boost", "post"])
            #expect(page.exhausted)
        }
    }

    @Test("a save between two chunks of a search's page is read by the rest of it: the plan is made again")
    func savedMeanwhile() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let notes = (0..<600).map { n in
            Note(id: "p\(n)", source: Self.one, author: "A", handle: "a@one.example", body: "foo \(n)", postedAt: at.addingTimeInterval(Double(n)), categories: [.home])
        }
        let late = Note(id: "late", source: Self.one, author: "A", handle: "a@one.example", body: "nothing", postedAt: at.addingTimeInterval(-60), categories: [.home])
        let file = try StoreFile(at: try scratch())
        try await file.save(sources: Self.sources, notes: notes + [late])
        try await file.makeIndexes()
        try await file.buildWords(chunk: 300, capable: true)
        let query = PageQuery(
            timeline: TimelineDefinition.all.id, generation: 1, compiled: CompiledTimeline(TimelineDefinition.all, sources: Self.sources)
        )
        let search = try #require(NoteSearch("foo", sources: Self.sources))
        let page = try #require(try await file.search(
            query, search, .newest, limit: 1_000, scanBudget: 20_000, candidatesMost: StoreFile.wordsCandidatesMost
        ) { chunk in
            guard chunk == 1 else { return }
            try await file.save(RowChanges(upserts: [Note(
                id: late.id, source: late.source, author: "foo fighter", handle: late.handle, body: late.body,
                postedAt: late.postedAt, categories: late.categories
            )]))
        })
        #expect(page.rows.count == 601)
        #expect(page.rows.last?.note.id == "late")
    }
}
