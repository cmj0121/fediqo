import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #359, G4: what the screens draw is said to the store, which lets go of none of it. Every
/// kind of page open over the timeline — a conversation, somebody's page, a hashtag's, the
/// search's results, an answer being written, a quote — keeps its rows through a letting go
/// while it is open, and lets them go once it is not; the pool stays within its cap and what is
/// drawn through a walk; and the newest of a timeline read deep is read afresh. Over a seeded
/// file, with a small cap, no view.
@Suite("What is drawn stays in the pool")
@MainActor
struct PinnedPagesTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    /// The pool's cap in these tests: over the first page, under the first page and a stretch.
    private static let cap = 150

    /// `count` posts by A, newest first by id, a minute apart.
    private static func posts(_ count: Int) -> [Note] {
        (0..<count).map { n in
            note(name(n), body: "words \(n)", at: at.addingTimeInterval(-Double(n) * 60), statusID: String(9_000 - n))
        }
    }

    private static func name(_ n: Int) -> String { String(format: "p%04d", n) }

    /// Long before every post of `posts`: what no page of the timeline in front reaches.
    private static let deep = at.addingTimeInterval(-10_000_000)

    private static func note(
        _ id: String, body: String, at: Date = deep, author: String = "A", handle: String = "a@one.example",
        reply: String? = nil, statusID: String? = nil, refs: [Reference] = []
    ) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, postedAt: at, categories: [.home],
            statusID: statusID, refs: refs + (reply.map { [Reference.answers($0, to: nil)] } ?? [])
        )
    }

    /// A conversation: a post and two answers to it.
    private static let thread = [
        note("t-root", body: "the root", statusID: "s-root"),
        note("t-one", body: "one answer", at: deep.addingTimeInterval(60), reply: "s-root", statusID: "s-one"),
        note("t-two", body: "another answer", at: deep.addingTimeInterval(120), reply: "s-root", statusID: "s-two"),
    ]
    /// Three posts by somebody else.
    private static let theirs = (0..<3).map { n in
        note("c-\(n)", body: "theirs \(n)", at: deep.addingTimeInterval(Double(n)), author: "C", handle: "c@one.example")
    }
    /// Three posts under one hashtag.
    private static let tagged = (0..<3).map { n in
        note("h-\(n)", body: "under #walking \(n)", at: deep.addingTimeInterval(Double(n)))
    }
    /// Three posts a search finds.
    private static let found = (0..<3).map { n in
        note("f-\(n)", body: "a needle \(n)", at: deep.addingTimeInterval(Double(n)))
    }
    /// A post long ago, and the newest post of all quoting it.
    private static let quoted = note("q-quoted", body: "the quoted", statusID: "s-quoted")
    private static let quoting = note(
        "q-quoting", body: "quoting it", at: at.addingTimeInterval(60),
        refs: [Reference(kind: .quotes, id: "q-quoted", statusID: "s-quoted", state: .accepted)]
    )

    private static var specials: [Note] { thread + theirs + tagged + found + [quoted] }

    private static func key(_ note: Note) -> NoteKey { note.key }

    /// A file of posts and the pages' posts, and a session over it as a launch makes one, with a
    /// small cap, its first page read and drawn.
    private func launched(_ count: Int = 600, cap: Int = cap, extra: [Note] = []) async throws -> (ShellSession, StoreFile, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: Self.posts(count) + Self.specials + [Self.quoting] + extra)
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: file, cap: cap)
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        return (session, file, dir)
    }

    /// The rows under `notes` read into the pool, as a page or a look-up would, and adopted.
    private func read(_ notes: [Note], into session: ShellSession, from file: StoreFile) async throws {
        _ = await session.store.take(try file.rows(notes.map(\.key)))
        await session.reloadFromStore()
    }

    /// A stretch the timeline in front does not draw read into the pool past its cap, the
    /// timeline drawn again, and what that let go adopted: what a reader walking elsewhere does.
    private func overflow(_ session: ShellSession, from file: StoreFile) async throws {
        let before = await session.store.pooled
        try await read(Array(Self.posts(600)[200..<500]), into: session, from: file)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        await session.reloadFromStore()
        #expect(await session.store.pooled < before + 300, "rows were let go")
    }

    private func held(_ notes: [Note], in session: ShellSession) -> Bool {
        notes.allSatisfy { session.heldNote($0.key.rowID) != nil }
    }

    /// Each kind of page, opened over the timeline (or not), and what it draws.
    enum Kind: CaseIterable {
        case thread, person, tag, search, answer
    }

    /// The posts a page of `kind` draws.
    private static func drawn(by kind: Kind) -> [Note] {
        switch kind {
        case .thread: thread
        case .person: theirs
        case .tag: tagged
        case .search: found
        case .answer: [thread[1], thread[0]]
        }
    }

    /// The page of `kind` opened in `session`, its rows read in; what it draws, as its pane would.
    private func open(_ kind: Kind, in session: ShellSession) async throws -> () -> [String] {
        switch kind {
        case .thread:
            let root = try #require(session.held(Self.thread[0].key.rowID))
            await session.conversations.redraw(root, in: session)
            session.reload.inFront = root
            session.pagesOpened(OpenPages(steps: [.thread(root.id)]))
            return { session.conversations.conversation(around: root).inOrder.map(\.id) }
        case .person:
            let who = try #require(DummyPerson(handle: "c@one.example", host: Self.source.host))
            session.pagesOpened(OpenPages(steps: [.person(who)]))
            return { session.heldPosts(of: who).map(\.id) }
        case .tag:
            let tag = try #require(PostTag.found(in: "#walking").first)
            session.pagesOpened(OpenPages(steps: [.tag(tag)]))
            return { session.heldPosts(under: tag, latest: nil).map(\.id) }
        case .search:
            let search = ShellSearch()
            search.open(from: nil, over: session.notes)
            await search.indexed()
            search.text = "needle"
            search.settle("needle")
            session.openSearch = search
            session.pagesOpened(OpenPages(searching: true, pattern: "needle", indexed: true))
            return { session.searched(search, latest: nil)?.map(\.id) ?? [] }
        case .answer:
            let item = try #require(session.held(Self.thread[1].key.rowID))
            let root = try #require(session.held(Self.thread[0].key.rowID))
            session.answering = AnswerTarget(item: item, root: root, start: .everyone)
            return { [session.answering?.item.id, session.answering?.root.id].compactMap { $0 } }
        }
    }

    @Test("A page open over the timeline keeps every row it draws through a letting go", arguments: Kind.allCases)
    func openPageKeepsItsRows(_ kind: Kind) async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await read(Self.drawn(by: kind), into: session, from: file)
        let draws = try await open(kind, in: session)
        let before = draws()
        #expect(before.count == Self.drawn(by: kind).count, "the page draws its rows")
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(held(Self.drawn(by: kind), in: session))
        #expect(Set(draws()) == Set(before), "the page draws what it drew")
    }

    @Test("The same rows, no page open, are let go as any other", arguments: Kind.allCases)
    func closedPageKeepsNone(_ kind: Kind) async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await read(Self.drawn(by: kind), into: session, from: file)
        try await overflow(session, from: file)
        #expect(!Self.drawn(by: kind).contains { session.heldNote($0.key.rowID) != nil })
    }

    @Test("A page under another keeps its rows; left, it keeps none")
    func pageUnderAnotherThenLeft() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await read(Self.theirs + Self.thread, into: session, from: file)
        let root = try #require(session.held(Self.thread[0].key.rowID))
        await session.conversations.redraw(root, in: session)
        let who = try #require(DummyPerson(handle: "c@one.example", host: Self.source.host))
        // Their page, and a conversation opened over it.
        session.pagesOpened(OpenPages(steps: [.person(who), .thread(root.id)]))
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(held(Self.theirs + Self.thread, in: session))
        // Both left: what they drew goes as any row drawn nowhere.
        session.pagesOpened(OpenPages())
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(!(Self.theirs + Self.thread).contains { session.heldNote($0.key.rowID) != nil })
    }

    @Test("A page open in one window keeps its rows while another window reads on")
    func pageInAnotherWindow() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = ShellSession(http: FixtureHTTP(), store: session.store)
        other.readPage = session.readPage
        await other.reprojectSources()
        await other.cover(latest: nil)
        _ = other.timelineItems(latest: nil)
        await other.holdDrawn()
        try await read(Self.theirs, into: session, from: file)
        let who = try #require(DummyPerson(handle: "c@one.example", host: Self.source.host))
        session.pagesOpened(OpenPages(steps: [.person(who)]))
        await session.holdDrawn()
        // The other window reads past the cap, and both adopt what it read, as each window
        // follows the one store; this one's page keeps what it draws.
        let before = await session.store.pooled
        try await read(Array(Self.posts(600)[200..<500]), into: other, from: file)
        for window in [other, session] {
            await window.reloadFromStore()
            _ = window.timelineItems(latest: nil)
            await window.holdDrawn()
        }
        await other.reloadFromStore()
        await session.reloadFromStore()
        #expect(await session.store.pooled < before + 300, "rows were let go")
        #expect(held(Self.theirs, in: session))
        #expect(!Self.theirs.contains { other.heldNote($0.key.rowID) == nil }, "the other window holds them too")
        #expect(session.heldPosts(of: who).count == Self.theirs.count)
    }

    @Test("A window gone says nothing more, and what it drew goes; shown again, it says what it draws afresh")
    func windowGoneAndBack() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = ShellSession(http: FixtureHTTP(), store: session.store)
        other.readPage = session.readPage
        await other.reprojectSources()
        await other.cover(latest: nil)
        _ = other.timelineItems(latest: nil)
        await other.holdDrawn()
        try await read(Self.theirs, into: session, from: file)
        let who = try #require(DummyPerson(handle: "c@one.example", host: Self.source.host))
        session.pagesOpened(OpenPages(steps: [.person(who)]))
        await session.holdDrawn()
        let was = session.screen
        // A saying on its way as the window goes, and one asked after: neither keeps its page.
        session.pinsMoved()
        await session.screenGone()
        await session.holdDrawn()
        #expect(session.heldLast == nil)
        try await read(Array(Self.posts(600)[200..<500]), into: other, from: file)
        _ = other.timelineItems(latest: nil)
        await other.holdDrawn()
        await other.reloadFromStore()
        #expect(!Self.theirs.contains { other.heldNote($0.key.rowID) != nil }, "what the window gone drew went")
        // Shown again: a new screen to the store, which hears what it draws.
        session.screenOpened()
        #expect(session.screen != was)
        try await read(Self.theirs, into: session, from: file)
        #expect(session.heldLast != nil, "said again, with nothing held back by the last saying")
        #expect(session.heldLast?.pins.isSuperset(of: Self.theirs.map(\.key)) == true)
    }

    @Test("A landing merges the timeline in front once, for the store and for the pane")
    func landingMergesOnce() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = session.timelineEvaluations
        try await read(Self.theirs, into: session, from: file)
        _ = session.timelineItems(latest: nil)
        _ = session.timelineItems(latest: nil)
        #expect(session.timelineEvaluations == before + 1)
    }

    @Test("A post quoted by its source's id alone stays while the quoting row is drawn")
    func quotedByStatusIDStays() async throws {
        let deep = Self.note("q-deep", body: "quoted by its id", statusID: "s-deep")
        let quoting = Self.note(
            "q-by-id", body: "quoting by id", at: Self.at.addingTimeInterval(120),
            refs: [Reference(kind: .quotes, statusID: "s-deep", state: .accepted)]
        )
        let (session, file, dir) = try await launched(extra: [deep, quoting])
        defer { try? FileManager.default.removeItem(at: dir) }
        try await read([deep], into: session, from: file)
        let row = try #require(session.timelineItems(latest: nil).first { $0.id == quoting.key.rowID })
        #expect(row.quotedRowID == nil)
        #expect(session.quotedRow(of: row) == deep.key.rowID)
        await session.holdDrawn()
        try await overflow(session, from: file)
        #expect(held([deep], in: session))
        let after = try #require(session.timelineItems(latest: nil).first { $0.id == quoting.key.rowID })
        #expect(session.quotedRow(of: after) == deep.key.rowID)
    }

    @Test("A timeline's next stretch is asked from the oldest post the file holds, not the oldest left in the pool")
    func oldestFromTheFile() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await overflow(session, from: file)
        let pooled = ShellReload.oldest(.home, of: Self.source.host, in: session.notes)
        let onFile = await session.store.oldestStatusID(host: Self.source.host, category: .home)
        #expect(onFile == String(9_000 - 599))
        #expect(pooled != onFile, "the oldest were let go of the pool")
        #expect(ShellReload.older(pooled, onFile) == onFile)
        #expect(ShellReload.older(onFile, pooled) == onFile)
        #expect(await session.store.oldestStatusID(host: Self.source.host, category: .public) == nil)
    }

    @Test("A source removed whose posts the file alone holds is named by the kind they wrote down, and its posts can be let go by span")
    func removedSourceFromTheFile() async throws {
        let gone = Source(host: "gone.example", kind: .gotosocial)
        let theirs = Note(
            id: "g-0", source: gone, author: "G", handle: "g@gone.example", body: "left behind",
            postedAt: Self.deep, categories: [.home]
        )
        let (session, _, dir) = try await launched(extra: [theirs])
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.readRowCounts()
        #expect(session.holdings.posts(host: gone.host) == 0)
        #expect(UsageSourceList.removed(session).first { $0.host == gone.host }?.kind == .gotosocial)
        #expect(SpanSection.hosts(session.holdings, onFile: session.hostsHeld).contains(gone.host))
    }

    @Test("A post quoted by a row drawn stays with it, and the row still opens it")
    func quotedPostStaysWithItsRow() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let row = try #require(session.timelineItems(latest: nil).first { $0.id == Self.quoting.key.rowID })
        #expect(row.quotedRowID == Self.quoted.key.rowID)
        try await overflow(session, from: file)
        #expect(held([Self.quoted], in: session))
        let after = try #require(session.timelineItems(latest: nil).first { $0.id == Self.quoting.key.rowID })
        #expect(after.quotedRowID == Self.quoted.key.rowID)
        #expect(session.quotedRow(of: after) == Self.quoted.key.rowID)
    }

    @Test("Walked down and back up, the pool stays within its cap and what is drawn, and every row drawn is held")
    func walkStaysWithinCapAndPins() async throws {
        let (session, _, dir) = try await launched(1_500, cap: 300)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        var most = 0
        var lettingGo = false
        func step(_ by: Int) async -> Bool {
            let drawn = session.timelineDrawn(latest: nil)
            let at = drawn.index[row] ?? 0
            let next = drawn.ids[min(max(at + by, 0), drawn.ids.count - 1)]
            guard next != row else { return false }
            row = next
            await session.placed(.all, at: next, latest: nil)
            return true
        }
        func check() async {
            let items = session.timelineItems(latest: nil)
            await session.holdDrawn()
            await session.reloadFromStore()
            let pooled = await session.store.pooled
            let pins = session.heldLast?.pins.count ?? 0
            most = max(most, pooled)
            if pooled > 300 { lettingGo = true }
            #expect(pooled <= 300 + pins)
            #expect(items.allSatisfy { session.heldNote($0.id) != nil }, "every row drawn is held")
        }
        for _ in 0..<200 {
            guard await step(ShellSession.readAhead) else { break }
            await check()
        }
        #expect(session.coverage[.all]?.exhausted == true, "read to the foot")
        for _ in 0..<200 {
            guard await step(-ShellSession.readAhead) else { break }
            await check()
        }
        #expect(lettingGo, "the walk read past the cap")
        #expect(most < 1_000, "rows were let go on the way")
    }

    @Test("To the top of a timeline read deep reads its newest page afresh and draws it there")
    func newestReadAfresh() async throws {
        let (session, _, dir) = try await launched(1_200, cap: 2_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        for _ in 0..<40 {
            let drawn = session.timelineDrawn(latest: nil)
            row = drawn.ids[min((drawn.index[row] ?? 0) + ShellSession.readAhead, drawn.ids.count - 1)]
            await session.placed(.all, at: row, latest: nil)
        }
        #expect(session.timelineReadsAbove(latest: nil), "the head was let go on the way down")
        #expect(await session.readNewest(.all))
        let items = session.timelineItems(latest: nil)
        #expect(items.first?.id == Self.quoting.key.rowID, "the newest is drawn")
        #expect(!session.timelineReadsAbove(latest: nil))
        #expect(items.count <= 2 * ShellSession.pageRows)
        // Drawn to its newest, it is read afresh no more.
        #expect(await !session.readNewest(.all))
    }

    @Test("Usage counts each source's posts as the file holds them, not as the pool does")
    func usageCountsTheFile() async throws {
        let (session, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await overflow(session, from: file)
        let pooled = session.holdings.posts(host: Self.source.host)
        #expect(session.postsHeld(host: Self.source.host).atLeast, "at least, before the file is counted")
        await session.readRowCounts()
        let total = 600 + Self.specials.count + 1
        #expect(pooled < total)
        #expect(session.postsHeld(host: Self.source.host) == (total, false))
        #expect(session.postsHeldTotal == (total, false))
        #expect(UsagePane.postsLine(session.postsHeld(host: Self.source.host), language: .english) == "\(total) posts")
        // The search is over the pool, as it was.
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = "words"
        search.settle("words")
        #expect((session.searched(search, latest: nil)?.count ?? 0) <= pooled)
    }

    @Test("A store held whole says nothing of what is drawn, and counts as it did")
    func wholeStoreSaysNothing() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        session.notes = Self.posts(3)
        _ = session.timelineItems(latest: nil)
        #expect(session.drawnNow() == nil)
        await session.readRowCounts()
        #expect(session.rowsOnFile == nil)
        #expect(session.postsHeld(host: Self.source.host) == (3, false))
    }
}
