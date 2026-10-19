import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #359, G3: a timeline drawn as a window round the reader's place. Every twenty rows the place
/// moves, the stretch ahead is read again, a page is read below or above where fewer than two
/// hundred rows are left that way, and the far side is let go where more than three hundred and
/// fifty are; a timeline switched away from keeps fifty rows each side of where it was left,
/// drawn at once on the way back and read again then. Over a seeded file, no view.
@Suite("A timeline drawn as a window round the place")
@MainActor
struct TimelineWindowTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let other = Source(host: "two.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// `count` posts, newest first by id, `run` of them at each moment a minute apart: the
    /// store's order is the ids' order.
    private static func posts(_ count: Int, run: Int = 1, from source: Source = source, later: TimeInterval = 0) -> [Note] {
        (0..<count).map { n in
            Note(
                id: name(n), source: source, author: "A", handle: "a@one.example", body: "words \(n)",
                postedAt: at.addingTimeInterval(-Double(n / run) * 60 + later), categories: [.home]
            )
        }
    }

    /// The same posts carried by a second source too, its copies a millisecond newer: every row
    /// drawn is two of the file's.
    private static func copied(_ count: Int) -> [Note] {
        posts(count) + posts(count, from: other, later: 0.001)
    }

    private static func name(_ n: Int) -> String { String(format: "p%04d", n) }

    /// Where a drawn row stands among the posts.
    private static func number(_ item: DummyItem) -> Int? { Int(item.noteID.dropFirst()) }

    /// A file of posts and a session over it as a launch makes one, its first page read.
    private func launched(_ count: Int, run: Int = 1, notes: [Note]? = nil) async throws -> (ShellSession, StoreFile, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source, Self.other], notes: notes ?? Self.posts(count, run: run))
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: file)
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        return (session, file, dir)
    }

    /// The drawn rows are one stretch of the file, in its order, with none missing between.
    private func unbroken(_ items: [DummyItem]) -> Bool {
        let numbers = items.compactMap(Self.number)
        return numbers.count == items.count && zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// The place moved `step` rows on from `row` in the drawing as it now is, and the window
    /// moved round it: the row it is now.
    private func move(_ session: ShellSession, from row: String, by step: Int) async -> String {
        let drawn = session.timelineDrawn(latest: nil)
        let at = drawn.index[row] ?? 0
        let next = drawn.ids[min(max(at + step, 0), drawn.ids.count - 1)]
        await session.placed(.all, at: next, latest: nil)
        return next
    }

    @Test("Walked to the foot and back to the head, a window never draws more than about seven hundred rows, and always one unbroken stretch")
    func walkStaysWithinTheWindow() async throws {
        let (session, _, dir) = try await launched(1_200, run: 7)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        var most = 0
        var steps = 0
        // Down, an anchor every twenty rows, to the last row there is.
        while steps < 500 {
            steps += 1
            let before = row
            row = await move(session, from: row, by: ShellSession.readAhead)
            let items = session.timelineItems(latest: nil)
            most = max(most, items.count)
            #expect(items.count <= 700)
            #expect(unbroken(items))
            if row == before { break }
        }
        let foot = session.timelineItems(latest: nil)
        #expect(foot.last.flatMap(Self.number) == 1_199, "read to the foot of the file")
        #expect(foot.first.flatMap(Self.number).map { $0 > 0 } == true, "the head let go on the way")
        #expect(session.timelineReadsAbove(latest: nil))
        // And up again, to the newest.
        steps = 0
        while steps < 500 {
            steps += 1
            let drawn = session.timelineDrawn(latest: nil)
            if drawn.index[row] == 0, session.coverage[.all]?.ceiling == nil { break }
            row = await move(session, from: row, by: -ShellSession.readAhead)
            let items = session.timelineItems(latest: nil)
            most = max(most, items.count)
            #expect(items.count <= 700)
            #expect(unbroken(items))
        }
        let head = session.timelineItems(latest: nil)
        #expect(head.first.flatMap(Self.number) == 0, "read back up to the newest")
        #expect(head.last.flatMap(Self.number).map { $0 < 1_199 } == true, "the foot let go on the way")
        #expect(!session.timelineReadsAbove(latest: nil))
        #expect(most > 500, "the window was never as wide as it is let grow")
    }

    @Test("An edge let go inside a run of one moment draws the run only as far as the edge's row, in the store's order")
    func edgeInsideARun() async throws {
        let (session, _, dir) = try await launched(400, run: 7)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        for _ in 0..<6 { row = await move(session, from: row, by: ShellSession.readAhead) }
        let ids = session.timelineIDs(latest: nil)
        #expect(ids.count > 160)
        let place = ids[100]
        session.timelineLeft(.all, at: place)
        let items = session.timelineItems(latest: nil)
        #expect(items.count == 2 * ShellSession.keptAway + 1)
        #expect(items.first?.id == ids[50] && items.last?.id == ids[150])
        // Row 150 is the fourth of its moment's seven: the three after it are not drawn.
        #expect(items.last.flatMap(Self.number) == 150)
        #expect(!items.contains { Self.number($0) == 151 })
        #expect(unbroken(items))
    }

    /// Holds every page asked below a cursor until opened.
    actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false
        private(set) var held = 0

        func pass(_ ask: PageAsk) async {
            guard case .before = ask, !opened else { return }
            held += 1
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    @Test("A page whose edge moved while it was out is laid in, and changes no edge")
    func pageToAMovedEdge() async throws {
        let (session, file, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        session.readPage = { query, ask, limit in
            await gate.pass(ask)
            return try await file.page(query, ask, limit: limit)
        }
        let place = session.timelineIDs(latest: nil)[ShellSession.readAhead]
        let placing = Task { await session.placed(.all, at: place, latest: nil) }
        while await gate.held == 0 { await Task.yield() }
        // The page below is out; the timeline is put behind another, its floor drawn in.
        session.timelineLeft(.all, at: place)
        let left = try #require(session.coverage[.all])
        let drawn = session.timelineIDs(latest: nil)
        await gate.open()
        await placing.value
        await session.reloadFromStore()
        let now = try #require(session.coverage[.all])
        #expect(now.floor == left.floor && now.floorMoved == left.floorMoved && !now.exhausted)
        #expect(session.notes.contains { $0.id == Self.name(150) }, "its rows are laid in all the same")
        #expect(session.timelineIDs(latest: nil) == drawn, "the page drew rows past the edge")
    }

    /// Counts the pages asked of it, and never answers one.
    actor Asked {
        private(set) var count = 0
        func ask() { count += 1 }
    }

    /// Down the timeline until the place is past row `deep`: the row it is at.
    private func walk(_ session: ShellSession, past deep: Int) async -> String {
        var row = session.timelineIDs(latest: nil)[0]
        while let item = session.timelineItems(latest: nil).first(where: { $0.id == row }), (Self.number(item) ?? 0) < deep {
            row = await move(session, from: row, by: ShellSession.readAhead)
        }
        return row
    }

    @Test("A timeline come back to draws the row it was left at with at most fifty above it, before any page is read (Risk 6)")
    func switchBackDrawsAtOnce() async throws {
        let (session, file, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = await walk(session, past: 400)
        session.timelineLeft(.all, at: left)
        session.stream = .trends
        _ = session.timelineItems(latest: nil)
        let asked = Asked()
        session.readPage = { query, ask, limit in
            await asked.ask()
            return try await file.page(query, ask, limit: limit)
        }
        session.stream = .timeline
        session.timelineID = .all
        let items = session.timelineItems(latest: nil)
        let at = try #require(items.firstIndex { $0.id == left })
        #expect(at <= ShellSession.keptAway)
        #expect(items.count <= 2 * ShellSession.keptAway + 1)
        #expect(await asked.count == 0, "a page was read to draw it")
        let key = try #require(NoteKey(rowID: left))
        #expect(session.coverage[.all]?.pinned.contains(key) == true)
        // Then its stretch is read again, and the window grows back round the place.
        await session.cover(latest: nil)
        #expect(await asked.count > 0)
        let grown = session.timelineItems(latest: nil)
        #expect(grown.count > items.count && grown.contains { $0.id == left })
        #expect(unbroken(grown))
    }

    @Test("A row written into the file inside a timeline's stretch while it was behind another shows once it is read again on the way back")
    func writtenWhileBehind() async throws {
        let (session, file, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = await walk(session, past: 300)
        let number = try #require(session.timelineItems(latest: nil).first { $0.id == left }.flatMap(Self.number))
        session.timelineLeft(.all, at: left)
        session.stream = .trends
        _ = session.timelineItems(latest: nil)
        // Between two rows ten below the place, by a hand the pool never heard of.
        let late = Note(
            id: "late", source: Self.source, author: "A", handle: "a@one.example", body: "words late",
            postedAt: Self.at.addingTimeInterval(-Double(number + 10) * 60 + 30), categories: [.home]
        )
        try await file.save(RowChanges(upserts: [late]))
        session.stream = .timeline
        session.timelineID = .all
        #expect(!session.timelineItems(latest: nil).contains { $0.noteID == "late" })
        await session.cover(latest: nil)
        let items = session.timelineItems(latest: nil)
        let at = try #require(items.firstIndex { $0.noteID == "late" })
        #expect(items[at - 1].noteID == Self.name(number + 9) && items[at + 1].noteID == Self.name(number + 10))
    }

    @Test("A timeline drawn a moment ago and never left reads nothing when its pane asks again")
    func notLeftReadsNothing() async throws {
        let (session, _, dir) = try await launched(300)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = session.notesRevision
        await session.cover(latest: nil)
        #expect(session.notesRevision == before)
    }

    @Test("Rows let go below the place ease out where they stood, and move nothing above it; where motion is reduced they simply go")
    func lettingGoBelow() async throws {
        let (session, _, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await walk(session, past: 100)
        let ids = session.timelineIDs(latest: nil)
        let place = ids[40]
        session.timelineLeft(.all, at: place)
        let drawn = session.timelineDrawn(latest: nil)
        #expect(drawn.ids == Array(ids.prefix(91)), "only the foot let go")
        #expect(!drawn.movedAbove(place), "a stretch let go below would move the reader")
        #expect(!session.timelineShown(latest: nil, anchor: place, moving: true).leaving.isEmpty)
        let still = session.timelineShown(latest: nil, anchor: place, moving: false)
        #expect(still.leaving.isEmpty && still.rows.map(\.id) == drawn.ids)
        #expect(!EasesIn.startsHidden(arrived: true, reduceMotion: true))
    }

    @Test("Rows let go above the place go at once, and the place is held")
    func lettingGoAbove() async throws {
        let (session, _, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        var steps = 0
        while session.coverage[.all]?.ceiling == nil, steps < 100 {
            steps += 1
            row = await move(session, from: row, by: ShellSession.readAhead)
        }
        let drawn = session.timelineDrawn(latest: nil)
        #expect(drawn.index[row] == ShellSession.windowRows)
        #expect(drawn.movedAbove(row), "the place would not be held")
        #expect(!drawn.left.isEmpty)
        #expect(session.timelineReadsAbove(latest: nil), "the head says nothing of the rows above it")
        let moving = session.timelineShown(latest: nil, anchor: row, moving: true)
        #expect(moving.leaving.isEmpty && moving.rows.map(\.id) == drawn.ids)
        let still = session.timelineShown(latest: nil, anchor: row, moving: false)
        #expect(still.leaving.isEmpty && still.rows.map(\.id) == drawn.ids)
    }

    @Test("A page read above the place lands above it, and the place is held")
    func pageAboveHoldsThePlace() async throws {
        let (session, _, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = await walk(session, past: 400)
        session.timelineLeft(.all, at: left)
        // Read up from fifty above the place.
        let up = await move(session, from: left, by: 0)
        let drawn = session.timelineDrawn(latest: nil)
        #expect(drawn.movedAbove(up), "a page above that would move the reader")
        #expect((drawn.index[up] ?? 0) > ShellSession.keptAway)
    }

    @Test("Walked by the scroll's own reports, the window reads on, lets go and stays one stretch of at most about seven hundred rows")
    func walkByTheScroll() async throws {
        let (session, _, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        var row = session.timelineIDs(latest: nil)[0]
        for _ in 0..<500 {
            let drawn = session.timelineDrawn(latest: nil)
            let at = drawn.index[row] ?? 0
            guard at + 1 < drawn.ids.count else { break }
            row = drawn.ids[min(at + ShellSession.readAhead / 2, drawn.ids.count - 1)]
            await session.scrolled(to: row, of: .all, latest: nil)?.value
            let items = session.timelineItems(latest: nil)
            #expect(items.count <= 700)
            #expect(unbroken(items))
        }
        let items = session.timelineItems(latest: nil)
        #expect(items.last.flatMap(Self.number) == 999, "read to the foot of the file")
        #expect(items.first.flatMap(Self.number).map { $0 > 0 } == true, "the head let go on the way")
    }

    @Test("A list too short to scroll twenty rows still reads on: from its top, and from its foot coming into view")
    func shortListReadsOn() async throws {
        let (session, _, dir) = try await launched(0, notes: Self.copied(400))
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = session.timelineItems(latest: nil)
        #expect(first.count < ShellSession.pageRows, "a page of the file's rows draws as fewer")
        #expect(first.allSatisfy { $0.otherCopies.count == 1 })
        // The top where it was: no anchor, and fewer than two hundred rows below.
        await session.scrolled(to: first[0].id, of: .all, latest: nil)?.value
        let more = session.timelineItems(latest: nil)
        #expect(more.count > first.count)
        // The foot coming into view reads on as well.
        await session.footReached(.all, latest: nil)?.value
        #expect(session.timelineItems(latest: nil).count > more.count)
    }

    @Test("A post carried by two sources is never split at an edge: the row there still merges both copies")
    func copiesNotSplitAtAnEdge() async throws {
        let (session, _, dir) = try await launched(0, notes: Self.copied(400))
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await walk(session, past: 150)
        let ids = session.timelineIDs(latest: nil)
        #expect(ids.count > 160)
        session.timelineLeft(.all, at: ids[100])
        let items = session.timelineItems(latest: nil)
        #expect(items.count == 2 * ShellSession.keptAway + 1)
        #expect(items.last?.id == ids[150])
        #expect(items.allSatisfy { $0.otherCopies.count == 1 }, "a copy left out past an edge")
        #expect(items.map(\.id) == Array(ids[50...150]), "a row drawn as another copy than before")
    }

    @Test("Rows the file let go at both edges leave the timeline reading on past them, down and up")
    func edgeRowsLetGo() async throws {
        let (session, file, dir) = try await launched(1_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = await walk(session, past: 400)
        session.timelineLeft(.all, at: left)
        let kept = session.timelineItems(latest: nil)
        let top = try #require(kept.first.flatMap(Self.number))
        let foot = try #require(kept.last.flatMap(Self.number))
        try await file.save(RowChanges(deletes: [
            NoteKey(host: Self.source.host, id: Self.name(top)), NoteKey(host: Self.source.host, id: Self.name(foot)),
        ]))
        // Come back to: read again from its head, and grown back both ways.
        await session.cover(latest: nil)
        let items = session.timelineItems(latest: nil)
        #expect(items.first.flatMap(Self.number).map { $0 < top } == true, "nothing read above the head")
        #expect(items.last.flatMap(Self.number).map { $0 > foot } == true, "nothing read below the foot")
        #expect(unbroken(items))
        #expect(session.coverage[.all]?.behind == false)
    }
}
