import Darwin
import FediqoCore
@testable import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #360, K3 (C25): the search searches everything this device holds, not only what was read so
/// far. Over a seeded file larger than the pool's cap, a session as a launch makes one: a post the
/// file holds and no page ever read is found; once the file has nothing further, the results are
/// the whole store's search; they stay in the pool while the search is open and go once it closes;
/// the count says "at least" until then; and the line that says only what was read so far was
/// searched shows exactly when only the pool was. No view.
@Suite("The search reads the file", .enabled(if: StoreFile.wordsCapable))
@MainActor
struct SearchFromFileTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    /// The pool's cap here: under what the search finds.
    private static let cap = 150

    /// `count` posts, newest first by id, a minute apart: the timeline's first pages.
    private static func posts(_ count: Int) -> [Note] {
        (0..<count).map { n in note(String(format: "p%04d", n), body: "words \(n)", at: at.addingTimeInterval(-Double(n) * 60)) }
    }

    /// Long before every post of `posts`: what no page of the timeline in front reaches.
    private static let deep = at.addingTimeInterval(-10_000_000)

    /// 230 posts a search for `needle` finds, past every page the timeline reads: more than two
    /// pages of results, and more than the pool's cap.
    private static let needles = (0..<230).map { n in
        note(String(format: "n%04d", n), body: n.isMultiple(of: 7) ? "a NEEDLE \(n)" : "a needle \(n)", at: deep.addingTimeInterval(Double(n)))
    }

    private static func note(_ id: String, body: String, at: Date) -> Note {
        Note(id: id, source: source, author: "A", handle: "a@one.example", body: body, postedAt: at, categories: [.home])
    }

    /// Whether the session's search was asked of the main thread: never.
    private actor Threads {
        private(set) var onMain = 0
        private(set) var asked = 0
        func saw(main: Bool) {
            asked += 1
            if main { onMain += 1 }
        }
    }

    /// A file of `posts` and the needles, its words index built (`words`) or not, and a session over
    /// it as a launch makes one, with a small cap, its first page read and drawn.
    private func launched(words: Bool = true, file searched: Bool = true) async throws -> (ShellSession, StoreFile, URL, Threads) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: Self.posts(600) + Self.needles)
            try await file.makeIndexes()
            if words { try await file.buildWords(chunk: 300, capable: true) }
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: file, cap: Self.cap)
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        let threads = Threads()
        if searched {
            session.readSearch = { query, search, ask, limit in
                await threads.saw(main: pthread_main_np() != 0)
                return try await file.search(query, search, ask, limit: limit)
            }
        }
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        return (session, file, dir, threads)
    }

    /// A search opened over the timeline in front for `pattern`, as the root opens one, and its
    /// first pages read from the file.
    private func opened(_ pattern: String, in session: ShellSession) async -> ShellSearch {
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = pattern
        search.settle(pattern)
        session.openSearch = search
        session.pagesOpened(OpenPages(searching: true, pattern: pattern, indexed: true))
        await session.coverSearch(session.searchAsk(search, latest: nil))
        return search
    }

    /// The foot of the results reached until the file has nothing further.
    private func readToTheEnd(_ session: ShellSession) async {
        while let more = session.searchFootReached() { await more.value }
    }

    /// What the whole store finds for `pattern` in the timeline in front, newest first.
    private func oracle(_ pattern: String, _ file: StoreFile) throws -> [String] {
        let all = try file.load().notes.sorted { $0.postedAt > $1.postedAt }
        let search = try #require(NoteSearch(pattern, sources: [Self.source], labels: ShellSearch.labels))
        let shown = CompiledTimeline(TimelineDefinition.all, sources: []).shown(all, TextIndex([]), targets: ReblogTargets(all))
        return search.found(shown, SearchIndex(all), targets: ReblogTargets(all)).map(\.key.rowID)
    }

    /// A stretch the timeline in front does not draw read into the pool past its cap, the
    /// timeline drawn again, and what that let go adopted.
    private func overflow(_ session: ShellSession, from file: StoreFile) async throws {
        _ = await session.store.take(try file.rows(Array(Self.posts(600)[200..<500]).map(\.key)))
        await session.reloadFromStore()
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        await session.reloadFromStore()
    }

    @Test("A post the file holds and no page read is found, the count at least so many until the file has nothing further, then the whole store's")
    func foundPastThePool() async throws {
        let (session, file, dir, threads) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deepest = try #require(Self.needles.first)
        #expect(session.heldNote(deepest.key.rowID) == nil, "never read")
        let search = await opened("needle", in: session)
        let first = try #require(session.searched(search, latest: nil))
        #expect(first.count >= ShellSession.pageRows && first.count < Self.needles.count)
        #expect(session.searchCount(found: first.count, searched: 0) == (atLeast: true, readSoFar: nil))
        await readToTheEnd(session)
        let found = try #require(session.searched(search, latest: nil)).map(\.id)
        #expect(found == (try oracle("needle", file)))
        #expect(found.count == Self.needles.count)
        #expect(found.contains(deepest.key.rowID))
        #expect(session.searchReading?.exhausted == true)
        #expect(session.searchCount(found: found.count, searched: 0) == (atLeast: false, readSoFar: nil))
        // Read by the store's actor, never the main thread.
        #expect(await threads.asked >= 3)
        #expect(await threads.onMain == 0)
    }

    @Test("What the search found stays in the pool while it is open, and goes once it closes")
    func closingLetsGo() async throws {
        let (session, file, dir, _) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let search = await opened("needle", in: session)
        await readToTheEnd(session)
        _ = session.searched(search, latest: nil)
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(Self.needles.allSatisfy { session.heldNote($0.key.rowID) != nil }, "kept while open")
        #expect(try #require(session.searched(search, latest: nil)).count == Self.needles.count)
        // Closed, as the root closes it.
        _ = search.close()
        session.pagesOpened(OpenPages())
        await session.coverSearch(session.searchAsk(search, latest: nil))
        #expect(session.searchReading == nil)
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(!Self.needles.contains { session.heldNote($0.key.rowID) != nil }, "let go once closed")
    }

    @Test("The line that says only what was read so far was searched shows exactly when only the pool was, and names what was")
    func readSoFarLine() async throws {
        let (session, _, dir, _) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Wildcards alone: nothing the index can narrow, so what is held alone is searched.
        let search = await opened("?", in: session)
        let found = try #require(session.searched(search, latest: nil))
        #expect(session.searchReading?.poolOnly == true)
        let searched = try #require(search.searchedCount)
        #expect(searched == session.notes.count { !$0.isPartOfTopic })
        let counted = session.searchCount(found: found.count, searched: searched)
        #expect(counted.readSoFar == L10n.count("search.readSoFar", searched))
        #expect(counted.atLeast == false)
        _ = search.close()
        let needle = await opened("needle", in: session)
        _ = session.searched(needle, latest: nil)
        #expect(session.searchCount(found: 0, searched: needle.searchedCount ?? 0).readSoFar == nil)
        _ = needle.close()
    }

    @Test("A pattern that names a category — a whole name, or one letter of one — searches the file too, and finds the whole store's", arguments: ["home", "e", "ome"])
    func categoryNamed(_ pattern: String) async throws {
        let (session, file, dir, _) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let search = await opened(pattern, in: session)
        await readToTheEnd(session)
        #expect(session.searchReading?.poolOnly == false)
        #expect(session.searchReading?.exhausted == true)
        let found = try #require(session.searched(search, latest: nil)).map(\.id)
        #expect(found == (try oracle(pattern, file)))
        #expect(found.contains(Self.needles[0].key.rowID), "found by its category, never read")
        #expect(session.searchCount(found: found.count, searched: search.searchedCount ?? 0) == (atLeast: false, readSoFar: nil))
    }

    @Test("What was searched is what the timeline lets through, not every post held")
    func searchedIsWhatTheTimelineShows() async throws {
        let notes = Self.posts(40) + Array(Self.needles.prefix(10))
        let search = ShellSearch()
        search.open(from: nil, over: notes)
        await search.indexed()
        search.text = "needle"
        search.settle("needle")
        let definition = TimelineDefinition(name: "T", rules: [try #require(Rule.keyword("words", in: .every))])
        let found = try #require(search.items(
            in: definition, text: TextIndex(notes), from: notes, revision: 1, sources: [Self.source], latest: nil
        ))
        #expect(found.isEmpty)
        #expect(search.searchedCount == 40)
        // Opened again over more: until its index lands, and an answer for what is asked now is
        // in hand, no count is known — and the line says nothing rather than the last one.
        let more = notes + Self.posts(60).suffix(20).map { Self.note("x" + $0.id, body: $0.body, at: $0.postedAt) }
        search.open(from: nil, over: more)
        search.text = "needle"
        search.settle("needle")
        #expect(search.items(in: definition, text: TextIndex(more), from: more, revision: 2, sources: [Self.source], latest: nil) == [])
        #expect(search.searchedCount == nil)
        await search.indexed()
        _ = search.items(in: definition, text: TextIndex(more), from: more, revision: 2, sources: [Self.source], latest: nil)
        #expect(search.searchedCount == 60)
        // A pattern settled and not yet answered for: none either.
        search.settle("need")
        search.text = "need"
        search.settle("need")
        let other = TimelineDefinition.all
        _ = search.items(in: other, text: TextIndex(more), from: more, revision: 2, sources: [Self.source], latest: nil)
        #expect(search.searchedCount == more.count)
    }

    @Test("Before what was searched is counted, the line says nothing")
    func lineWaitsForTheCount() async throws {
        let (session, _, dir, _) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let search = await opened("?", in: session)
        #expect(session.searchReading?.poolOnly == true)
        #expect(session.searchCount(found: 0, searched: nil) == (atLeast: false, readSoFar: nil))
        #expect(session.searchCount(found: 0, searched: 3).readSoFar == L10n.count("search.readSoFar", 3))
        _ = search.close()
    }

    @Test("A file that will not be read: the first page failing says only what was held was searched; a later one, at least so many, and asks again")
    func failures() async throws {
        let (session, file, dir, _) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Every asking fails.
        session.readSearch = { _, _, _, _ in throw FileRefused() }
        let first = await opened("needle", in: session)
        #expect(session.searchReading?.poolOnly == true)
        #expect(session.searchCount(found: 0, searched: 1).readSoFar != nil)
        _ = first.close()
        await session.coverSearch(nil)
        // The first page lands, the next fails, the one after lands.
        let asked = Asked()
        session.readSearch = { query, search, ask, limit in
            if await asked.next() == 2 { throw FileRefused() }
            return try await file.search(query, search, ask, limit: limit)
        }
        let second = await opened("needle", in: session)
        #expect(session.searchReading?.landed == true && session.searchReading?.poolOnly == false)
        await session.searchFootReached()?.value
        #expect(session.searchCount(found: 0, searched: 0) == (atLeast: true, readSoFar: nil))
        await readToTheEnd(session)
        #expect(session.searchReading?.exhausted == true)
        #expect(try #require(session.searched(second, latest: nil)).count == Self.needles.count)
    }

    /// A failure of the file's own, not a task given up.
    private struct FileRefused: Error {}

    /// Counts the askings.
    private actor Asked {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    @Test("With no words index, only the pool is searched and said to be; with no file, everything is held and nothing is said")
    func noIndexNoFile() async throws {
        let (bare, _, dir, _) = try await launched(words: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let search = await opened("needle", in: bare)
        #expect(bare.searchReading?.poolOnly == true)
        #expect(bare.searchCount(found: 0, searched: 0).readSoFar != nil)
        #expect(bare.heldNote(Self.needles[0].key.rowID) == nil, "the file was not read")

        let (unasked, _, other, _) = try await launched(file: false)
        defer { try? FileManager.default.removeItem(at: other) }
        _ = await opened("needle", in: unasked)
        #expect(unasked.searchAsk(unasked.openSearch, latest: nil) == nil)
        #expect(unasked.searchCount(found: 0, searched: 0) == (atLeast: false, readSoFar: nil))
    }

    @Test("While the words index is built, the search reads the file all the same and finds no less")
    func whileBuilding() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: Self.posts(600) + Self.needles)
            try await file.makeIndexes()
            try await file.db.write { db in _ = try StoreFile.makeWords(db, capable: true) }
            _ = try await file.buildWordsStep(chunk: 200)
            #expect(try #require(try file.wordsState()).floor > 0)
        }
        let held = StoreFile.open(at: dir, rows: false)
        let file = try #require(held.file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: held.sources, said: held.said, rows: file, cap: Self.cap)
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        session.readSearch = { query, search, ask, limit in try await file.search(query, search, ask, limit: limit) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        let search = await opened("needle", in: session)
        await readToTheEnd(session)
        #expect(session.searchReading?.poolOnly == false)
        #expect(try #require(session.searched(search, latest: nil)).map(\.id) == (try oracle("needle", file)))
        #expect(session.searchCount(found: 0, searched: 0).readSoFar == nil)
    }

    @Test("The count reads at least so many while the file has more to give")
    func countWords() {
        #expect(SearchBar.foundText(3, atLeast: true, language: .english) == "At least 3 found")
        #expect(SearchBar.foundText(3, atLeast: false, language: .english) == "3 found")
        #expect(SearchBar.foundText(3, atLeast: true, language: .taiwanese) == "至少找到 3 則")
        #expect(L10n.count("search.readSoFar", 1, language: .english) == "Searched only the 1 post read so far.")
        #expect(L10n.count("search.readSoFar", 2, language: .english) == "Searched only the 2 posts read so far.")
        #expect(L10n.count("search.readSoFar", 1, language: .taiwanese) == "只搜尋了目前讀進來的 1 則貼文。")
        #expect(String(format: L10n.t("search.atLeast", language: .taiwanese), 3) == "至少找到 3 則")
    }
}
