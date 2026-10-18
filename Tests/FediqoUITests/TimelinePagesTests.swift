import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #357, H3b: a launch reads no row. The timeline is there from the sources alone, drawn as being
/// read until its first page lands; the place moving toward its foot reads the page below from
/// this device before anything asks a source (#359); and a timeline drawn a moment ago is drawn
/// again for nothing.
@Suite("A timeline read from this device a page at a time")
@MainActor
struct TimelinePagesTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// `count` posts, a minute apart, the newest first by id `p0`.
    private static func posts(_ count: Int) -> [Note] {
        (0..<count).map { n in
            Note(
                id: "p\(n)", source: source, author: "A", handle: "a@one.example", body: "words \(n)",
                postedAt: at.addingTimeInterval(-Double(n) * 60), categories: [.home]
            )
        }
    }

    /// A file of `count` posts and a session over it as a launch makes one: no row read.
    private func launched(_ count: Int = 250, notes: [Note]? = nil) async throws -> (ShellSession, ItemStore, StoreFile, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: notes ?? Self.posts(count))
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let store = ItemStore(sources: opened.sources, said: opened.said, rows: file)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        return (session, store, file, dir)
    }

    @Test("Before any row is read the timeline can be entered, and is drawn as being read, not as empty")
    func placeSettlesFromSources() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        #expect(session.availability.timelineEnabled)
        #expect(session.notes.isEmpty, "no row read to get there")
        #expect(session.timelineItems(latest: nil).isEmpty)
        #expect(session.timelineLoading(latest: nil))
    }

    @Test("The first page lands in the pool and is drawn, newest first, and nothing more is read")
    func firstPage() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        let items = session.timelineItems(latest: nil)
        #expect(items.count == ShellSession.pageRows)
        #expect(items.first?.noteID == "p0" && items.last?.noteID == "p99")
        #expect(!session.timelineLoading(latest: nil))
        #expect(session.notes.count < 250, "the pool, not the store")
        // Asked again for what it already has, it reads nothing.
        let before = session.notesRevision
        await session.cover(latest: nil)
        #expect(session.notesRevision == before)
    }

    @Test("A post held for another reason, below what was read, is not drawn under the page")
    func drawnOnlyAsFarAsRead() async throws {
        let (session, store, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        // Read in by key, as a thread or a quote would read it.
        #expect(await store.note(NoteKey(host: Self.source.host, id: "p240")) != nil)
        await session.reloadFromStore()
        #expect(session.notes.contains { $0.id == "p240" })
        #expect(!session.timelineItems(latest: nil).contains { $0.noteID == "p240" })
    }

    @Test("The place moving toward the foot reads the page below from this device, and the file's end is where a source would be asked")
    func readOnFromTheFile() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        #expect(session.readsOnFromFile(.all))
        var items = session.timelineItems(latest: nil)
        await session.placed(.all, at: items[ShellSession.readAhead].id, latest: nil)
        items = session.timelineItems(latest: nil)
        #expect(items.count == 200)
        #expect(Set(items.map(\.noteID)).count == 200, "no row twice where the stretch was read again")
        await session.placed(.all, at: items[2 * ShellSession.readAhead].id, latest: nil)
        items = session.timelineItems(latest: nil)
        #expect(items.count == 250 && items.last?.noteID == "p249")
        #expect(!session.readsOnFromFile(.all), "nothing below: the sources are asked from here on")
    }

    @Test("A switch back to a timeline drawn a moment ago draws nothing again")
    func switchBackIsFree() async throws {
        let (session, _, _, dir) = try await launched(30)
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        let drawn = session.timelineEvaluations
        session.timelineID = .trends
        _ = session.timelineItems(latest: nil)
        session.timelineID = .all
        #expect(session.timelineItems(latest: nil).count == 30)
        #expect(session.timelineEvaluations == drawn, "All was drawn again on the way back")
    }

    @Test("A store held whole pages nothing: never drawn as being read")
    func wholeStorePagesNothing() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: Self.posts(5)))
        await session.reloadFromStore()
        #expect(!session.timelineLoading(latest: nil))
        #expect(session.timelineItems(latest: nil).count == 5)
        #expect(!session.readsOnFromFile(.all))
    }

    /// Holds the first read asked of it until opened, as a slow file would, and hears of its
    /// task being given up only once it goes on — as a read of the file does, between chunks.
    actor Held {
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false
        private(set) var asked = 0

        func pass() async {
            asked += 1
            guard asked == 1, !opened else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    @Test("A first page given up with its task, and asked again before it heard, is read again and lands")
    func givenUpAndAskedAgain() async throws {
        let (session, _, file, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = Held()
        session.readPage = { query, ask, limit in
            await held.pass()
            try Task.checkCancellation()
            return try await file.page(query, ask, limit: limit)
        }
        await session.reprojectSources()
        // Shown, then switched away from: the pane's task is given up.
        let first = Task { await session.cover(latest: nil) }
        while await held.asked == 0 { await Task.yield() }
        first.cancel()
        // Switched back before the read heard.
        await session.cover(latest: nil)
        #expect(!session.timelineLoading(latest: nil), "left waiting on the read given up")
        #expect(session.timelineItems(latest: nil).count == ShellSession.pageRows)
        // And the read given up, when it hears, changes nothing.
        await held.open()
        await first.value
        #expect(!session.timelineLoading(latest: nil))
        #expect(session.timelineItems(latest: nil).count == ShellSession.pageRows)
    }

    @Test("After a read back the timeline in front is asked for again at once, and lands")
    func readBackAsksAgain() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        let before = session.timelineAsk(latest: nil)
        session.forgetCoverage()
        #expect(session.timelineAsk(latest: nil) != before, "the pane's task would not be begun again")
        #expect(session.timelineLoading(latest: nil))
        await session.cover(latest: nil)
        #expect(session.timelineItems(latest: nil).count == ShellSession.pageRows)
    }

    @Test("A gap's mark is read off the timeline as drawn, latest date and all, and leaves the drawing as it was")
    func gapMarksAsDrawn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var posts = Self.posts(150)
        posts[0] = Note(
            id: "p0", source: Self.source, author: "A", handle: "a@one.example", body: "words 0", postedAt: Self.at,
            categories: [.home], gaps: [TimelineGap(.newerRemain, in: .home)]
        )
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: posts)
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: file))
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        await session.reprojectSources()
        let latest = try #require(LatestDate("2030-12-31"))
        await session.cover(latest: latest)
        let drawn = session.timelineItems(latest: latest)
        #expect(drawn.count == ShellSession.pageRows)
        let evaluations = session.timelineEvaluations
        #expect(ShellReload.says(.more(Stretch(host: Self.source.host, category: .home)), in: session))
        #expect(session.timelineItems(latest: latest).count == ShellSession.pageRows)
        #expect(session.timelineEvaluations == evaluations, "the drawing on screen was drawn over")
    }

    @Test("A file still making its pages' index draws a provisional page, reads nothing below it, and gives way to the first page with the rows both hold kept")
    func provisionalThenFirstPage() async throws {
        // Saved oldest first, as they arrived: the newest by arrival are the newest by time —
        // all but one, which arrived first and was posted after them all.
        let late = Note(
            id: "late", source: Self.source, author: "A", handle: "a@one.example", body: "words late",
            postedAt: Self.at.addingTimeInterval(60), categories: [.home]
        )
        let (session, _, file, dir) = try await launched(notes: [late] + Self.posts(250).reversed())
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = Held()
        session.readPage = { query, ask, limit in
            await held.pass()
            return try await file.page(query, ask, limit: limit)
        }
        session.readEarly = { query, limit in try await file.provisionalPage(query, limit: limit) }
        await session.reprojectSources()
        let first = Task { await session.cover(latest: nil) }
        for _ in 0..<2000 where session.timelineItems(latest: nil).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let early = session.timelineItems(latest: nil)
        #expect(early.count == ShellSession.pageRows)
        #expect(early.first?.noteID == "p0" && !early.contains { $0.noteID == "late" }, "by arrival, not by time")
        #expect(session.timelineLoading(latest: nil), "still reading its first page")
        await held.open()
        await first.value
        let real = session.timelineItems(latest: nil)
        #expect(real.count == ShellSession.pageRows && real.first?.noteID == "late")
        #expect(!session.timelineLoading(latest: nil))
        // The rows both hold are the same rows, in the same order; only the new one eases in.
        let kept = Set(early.map(\.id))
        #expect(real.filter { kept.contains($0.id) }.map(\.id) == early.filter { Set(real.map(\.id)).contains($0.id) }.map(\.id))
        #expect(session.timelineDrawn(latest: nil).arrived == [real[0].id])
        // The index is made: no provisional page is asked for again this run.
        #expect(session.readEarly == nil)
    }

    @Test("A reader moving down a provisional page reads nothing below it, and reads on once the first page lands")
    func footReachedWhileProvisional() async throws {
        let (session, _, file, dir) = try await launched(notes: Self.posts(250).reversed())
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = Held()
        session.readPage = { query, ask, limit in
            await held.pass()
            return try await file.page(query, ask, limit: limit)
        }
        session.readEarly = { query, limit in try await file.provisionalPage(query, limit: limit) }
        await session.reprojectSources()
        let first = Task { await session.cover(latest: nil) }
        for _ in 0..<2000 where session.timelineItems(latest: nil).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let early = session.timelineItems(latest: nil)
        #expect(early.count == ShellSession.pageRows)
        await session.placed(.all, at: early[early.count - ShellSession.readAhead].id, latest: nil)
        #expect(session.timelineItems(latest: nil).map(\.id) == early.map(\.id), "nothing read below a provisional page")
        await held.open()
        await first.value
        #expect(session.timelineItems(latest: nil).count == 2 * ShellSession.pageRows, "read on from where the reader was")
    }

    @Test("Rows ease in once: drawn again — scrolled to, or come back to — they are simply there")
    func arrivedHandedOnce() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        #expect(session.timelineItems(latest: nil).isEmpty)
        await session.cover(latest: nil)
        #expect(session.timelineArrived(latest: nil).count == ShellSession.pageRows)
        #expect(session.timelineArrived(latest: nil).isEmpty, "a second pass over the same drawing")
        session.timelineID = .trends
        _ = session.timelineItems(latest: nil)
        session.timelineID = .all
        #expect(session.timelineArrived(latest: nil).isEmpty, "a switch back to the drawing kept")
    }

    @Test("Where the row being read was not drawn before, no row that left eases out")
    func noAnchorNoFade() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: Self.posts(10)))
        await session.reloadFromStore()
        _ = session.timelineItems(latest: nil)
        session.notes = session.notes.filter { $0.id != "p7" }
        let drawn = session.timelineItems(latest: nil)
        let shown = session.timelineShown(latest: nil, anchor: "one.example:nowhere", moving: true)
        #expect(shown.leaving.isEmpty && shown.rows.map(\.id) == drawn.map(\.id))
    }

    @Test("A page landing at the foot eases in its own rows, and none of those already drawn")
    func footPageArrives() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        // Drawn as being read first, as the pane draws it.
        #expect(session.timelineItems(latest: nil).isEmpty)
        await session.cover(latest: nil)
        let before = session.timelineItems(latest: nil)
        #expect(session.timelineDrawn(latest: nil).arrived == Set(before.map(\.id)), "drawn from none: every row comes in")
        await session.placed(.all, at: before[ShellSession.readAhead].id, latest: nil)
        let after = session.timelineDrawn(latest: nil)
        #expect(Array(after.ids.prefix(before.count)) == before.map(\.id), "rows drawn already stay where they were")
        #expect(after.arrived == Set(after.ids.dropFirst(before.count)))
    }

    @Test("A row that arrived starts unseen and eases in; where motion is reduced it is simply there")
    func easesInUnlessMotionReduced() {
        #expect(EasesIn.startsHidden(arrived: true, reduceMotion: false))
        #expect(!EasesIn.startsHidden(arrived: true, reduceMotion: true))
        #expect(!EasesIn.startsHidden(arrived: false, reduceMotion: false))
        #expect(!EasesIn.startsHidden(arrived: false, reduceMotion: true))
    }

    @Test("A row that left eases out where it stood, at or below the row being read; above it, it goes at once; reduced motion shows only what is drawn")
    func rowsLeaveWhereTheyStood() async throws {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: Self.posts(10)))
        await session.reloadFromStore()
        let before = session.timelineItems(latest: nil)
        let id = { (n: Int) in before[n].id }
        // Two go: one above the row being read, one below it.
        session.notes = session.notes.filter { $0.id != "p2" && $0.id != "p7" }
        let drawn = session.timelineItems(latest: nil)
        #expect(drawn.count == 8 && session.timelineDrawn(latest: nil).left == [id(2), id(7)])
        let shown = session.timelineShown(latest: nil, anchor: id(5), moving: true)
        #expect(shown.rows.map(\.id) == [0, 1, 3, 4, 5, 6, 7, 8, 9].map(id), "the one below eases out where it stood")
        #expect(shown.leaving == [id(7)])
        // Where motion is reduced it simply goes.
        #expect(session.timelineShown(latest: nil, anchor: id(5), moving: false).rows.map(\.id) == drawn.map(\.id))
        // And once it has eased out, it is gone, and the list is told.
        let ended = session.leavingEnded
        // Waited for by the step, however busy the run: the fade's own clock is no test's.
        for _ in 0..<500 where session.leavingEnded == ended {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.leavingEnded == ended + 1)
        #expect(session.timelineShown(latest: nil, anchor: id(5), moving: true).rows.map(\.id) == drawn.map(\.id))
    }

    @Test("Asked for its rows as drawn, a timeline never drawn draws nothing")
    func asDrawnNeverDrawn() async {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: Self.posts(5)))
        await session.reloadFromStore()
        #expect(session.timelineItemsAsDrawn().isEmpty)
        #expect(session.timelineEvaluations == 0)
    }

    @Test("A months limit moved reads the timeline afresh: its first page asked again for what it now is")
    func limitMovedReadsAfresh() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.reprojectSources()
        let before = session.timelineAsk(latest: nil)
        await session.keep(months: 1, from: Self.at)
        #expect(session.timelineAsk(latest: nil) != before)
        #expect(session.timelineLoading(latest: nil))
    }
}
