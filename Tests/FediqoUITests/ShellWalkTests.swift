import Darwin
import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #359, G5: a walk over a seeded file of some three thousand rows, with the pool held to five
/// hundred — down a timeline to its foot, through two others and back, and up again to its
/// newest — and at every step what is drawn is what the file holds there and what the whole
/// store draws there, what is held is all that a held row holds, and the pool keeps within its
/// cap and what the screens draw. Over the file, no view, and **nothing timed**: what is asserted
/// is what is drawn, held and read where. Six times the cap rather than the twenty thousand rows
/// the design asked, so the walk reaches both ends in a few seconds; the long walk is
/// `ShellWalkBenchTests`'.
@Suite("A walk through a large store, a stretch at a time")
@MainActor
struct ShellWalkTests {
    private static let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    /// The pool's cap in this walk: under what the timeline in front draws at its widest.
    private static let cap = 500
    /// How many posts the file holds, beside the copies and reblogs of some of them.
    private static let posts = 3_000
    /// How many drawn rows the place moves a step: a page's worth, five anchors' — the window
    /// reads on and lets go at each as at every anchor, and the walk takes a fifth as long.
    private static let step = ShellSession.pageRows

    private static func name(_ n: Int) -> String { String(format: "p%05d", n) }

    /// One post, the `n`th from the newest: three at each moment, a source each, so the store
    /// orders a moment's by id. Every fortieth is carried by the next source too, a millisecond
    /// newer; every hundred-and-first quotes a post three hundred and three below it, a page or
    /// more away; and one deep down is kept.
    private static func post(_ n: Int) -> Note {
        let quotes = n % 101 == 0 && n + 303 < posts
        return Note(
            id: name(n), source: sources[n % 3], author: "A", handle: "a\(n % 7)@one.example", body: "words \(n)",
            postedAt: at.addingTimeInterval(-Double(n / 3) * 60), categories: [.home], statusID: "s\(n)",
            kept: n == posts - 50,
            refs: quotes ? [Reference(kind: .quotes, id: name(n + 303), statusID: "s\(n + 303)", state: .accepted)] : []
        )
    }

    /// Every row of the file, newest first: each post, its copy where it has one, and — every
    /// ninety-seventh — a reblog of the post three hundred and fifty-one below it, of its source.
    private static func seeded() -> [Note] {
        var notes: [Note] = []
        notes.reserveCapacity(posts + posts / 30)
        for n in 0..<posts {
            let note = post(n)
            notes.append(note)
            if n % 40 == 0 {
                notes.append(Note(
                    id: note.id, source: sources[(n + 1) % 3], author: "A", handle: note.handle, body: note.body,
                    postedAt: note.postedAt.addingTimeInterval(0.001), categories: [.home]
                ))
            }
            if n % 97 == 0, n + 351 < posts {
                notes.append(Note(
                    id: "r\(name(n))", source: sources[n % 3], author: "B", handle: "b@one.example", body: "",
                    postedAt: note.postedAt.addingTimeInterval(10), categories: [.home],
                    refs: [Reference(kind: .reblogs, id: name(n + 351), statusID: "s\(n + 351)")]
                ))
            }
        }
        return notes
    }

    /// The pages read, and how many of them were read on the main thread.
    actor Pages {
        private(set) var read = 0
        private(set) var onMain = 0

        func note(main: Bool) {
            read += 1
            if main { onMain += 1 }
        }
    }

    /// A walk's file, a session over it with a small cap as a launch makes one, and a session
    /// over every row held whole: what each window of the first is compared with.
    private struct Walk {
        let session: ShellSession
        let file: StoreFile
        let dir: URL
        let pages: Pages
        let whole: ShellSession
        let queries: [TimelineQuery]
        /// Each timeline as the whole store draws it, by its query.
        var drawnWhole: [TimelineQuery: [DummyItem]] = [:]
    }

    private func launched() async throws -> Walk {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notes = Self.seeded()
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: Self.sources, notes: notes)
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: file, cap: Self.cap)
        )
        let pages = Pages()
        session.readPage = { query, ask, limit in
            await pages.note(main: pthread_main_np() != 0)
            return try await file.page(query, ask, limit: limit)
        }
        let one = TimelineDefinition(name: "One", rules: [try #require(Rule.source(Self.sources[0].host))])
        let three = TimelineDefinition(name: "Three", rules: [try #require(Rule.source(Self.sources[2].host))])
        session.written = [one, three]
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        // The same rows held whole, in the order the file took them, drawn with no file.
        let whole = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: Self.sources, notes: try file.load().notes))
        whole.written = [one, three]
        await whole.reprojectSources()
        await whole.reloadFromStore()
        var walk = Walk(
            session: session, file: file, dir: dir, pages: pages, whole: whole,
            queries: [.all, .written(one.id), .written(three.id)]
        )
        for query in walk.queries {
            whole.timelineID = query
            walk.drawnWhole[query] = whole.timelineItems(latest: nil)
        }
        return walk
    }

    /// What the file holds inside the window of the timeline in front, read by the file's own
    /// selection of a span and not by its pages: through the timeline's one rule on a source,
    /// every row more than a millisecond inside the edges by its key alone, and the rows round
    /// each edge read and cut to it in the store's order. Kept rows too, which no span selects.
    private func onFile(_ walk: Walk, reach: TimelineCoverage.Reach) throws -> Set<NoteKey> {
        let file = walk.file
        let query = walk.session.currentTimeline
        let host = walk.session.definition(of: query).rules.lazy.compactMap { rule -> String? in
            if case .source(let host) = rule.kind { return host }
            return nil
        }.first
        func moment(_ millisecond: Int64) -> Date { Date(timeIntervalSince1970: Double(millisecond) / 1000) }
        let low = reach.floor.map { moment($0.millisecond + 2) } ?? .distantPast
        let high = reach.ceiling.map { moment($0.millisecond - 1) } ?? .distantFuture
        var keys = low < high ? Set(try file.keys(.span(low..<high, host: host))) : []
        var near: [NoteKey] = []
        for clip in [reach.floor, reach.ceiling].compactMap({ $0 }) {
            near += try file.keys(.span(moment(clip.millisecond - 1)..<moment(clip.millisecond + 2), host: host))
        }
        let cut = try file.rows(near).map(\.note) + file.keptRows().map(\.note).filter { host == nil || $0.key.host == host }
        keys.formUnion(cut.filter { !$0.isPartOfTopic && reach.holds($0) }.map(\.key))
        return keys
    }

    /// The rows the whole store draws inside `reach`, as the timeline in front: the stretch of its
    /// drawing round the edges found by the moment, and cut by where each row's copies stand.
    private func drawnWhole(_ walk: Walk, reach: TimelineCoverage.Reach) -> [DummyItem] {
        let items = walk.drawnWhole[walk.session.currentTimeline] ?? []
        let newest = reach.ceiling.map { Date(timeIntervalSince1970: Double($0.millisecond) / 1000 + 2) } ?? .distantFuture
        let oldest = reach.floor.map { Date(timeIntervalSince1970: Double($0.millisecond) / 1000 - 2) } ?? .distantPast
        // Newest first: the first row no newer than `newest`, and the first older than `oldest`.
        func first(_ older: (DummyItem) -> Bool) -> Int {
            var (low, high) = (0, items.count)
            while low < high {
                let mid = (low + high) / 2
                if older(items[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let from = first { $0.postedAt <= newest }
        let to = max(from, first { $0.postedAt < oldest })
        return items[from..<to].filter { reach.holds($0, held: walk.whole.heldNote) }
    }

    /// Everything a step must leave true, asserted where it was taken.
    private func check(_ walk: Walk, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let session = walk.session
        await session.holdDrawn()
        let query = session.currentTimeline
        let drawn = session.timelineDrawn(latest: nil)
        let items = drawn.items
        #expect(items.count <= 700, "\(step): the window drew \(items.count) rows", sourceLocation: sourceLocation)
        let reach = try #require(
            session.coverage[query]?.reach(for: session.coverageKey(of: query, latest: nil)), sourceLocation: sourceLocation
        )
        // I1′: the window is what the file holds there, every row of it and none past it.
        let file = try onFile(walk, reach: reach)
        let shown = items.reduce(into: Set<NoteKey>()) { $0.formUnion(ShellSession.keys(of: $1)) }
        let missing = file.subtracting(shown)
        #expect(missing.isEmpty, "\(step): \(missing.count) rows of the window on file not drawn", sourceLocation: sourceLocation)
        let stray = items.filter { item in !ShellSession.keys(of: item).contains(where: file.contains) }
        #expect(stray.isEmpty, "\(step): \(stray.count) rows drawn outside the window", sourceLocation: sourceLocation)
        // And drawn as the whole store draws the same stretch: the same rows, in the same order —
        // but for a post at an edge with a copy past it, which the window draws as its copy
        // inside wherever the one past it is not held, and the whole store as the newer.
        let whole = drawnWhole(walk, reach: reach)
        let straddling = Set(whole.filter { item in
            !([item.id] + item.otherCopies.map(\.id)).allSatisfy { walk.whole.heldNote($0).map(reach.holds) ?? false }
        }.map(\.noteID))
        let inside = { (items: [DummyItem]) in items.filter { !straddling.contains($0.noteID) }.map(\.id) }
        #expect(inside(items) == inside(whole), "\(step): drawn otherwise than the whole store draws the window", sourceLocation: sourceLocation)
        #expect(straddling.isSubset(of: Set(items.map(\.noteID))), "\(step): a post at an edge not drawn", sourceLocation: sourceLocation)
        // I2: what a held row holds with it is held, wherever the file has it.
        let pool = await session.store.all()
        let pooled = Set(pool.map(\.key))
        let held = Set(pool.flatMap { $0.heldWith + [$0.topicKey].compactMap { $0 } })
        let unheld = try walk.file.rows(Array(held.subtracting(pooled))).count
        #expect(unheld == 0, "\(step): \(unheld) rows held with a pooled row and not pooled", sourceLocation: sourceLocation)
        // The pool within its cap, but for what the screens draw and the kept row.
        let mustStay = (session.drawnNow()?.pins ?? []).union(pool.filter(\.kept).map(\.key))
        let count = await session.store.pooled
        #expect(count <= Self.cap + mustStay.count, "\(step): \(count) rows pooled, \(mustStay.count) to stay", sourceLocation: sourceLocation)
    }

    /// The place moved `step` drawn rows on from `row`, the window moved round it, and every
    /// step's checks made: the row it is at now.
    private func move(_ walk: Walk, from row: String, by step: Int, _ label: String) async throws -> String {
        let session = walk.session
        let drawn = session.timelineDrawn(latest: nil)
        let at = drawn.index[row] ?? 0
        let next = drawn.ids[min(max(at + step, 0), drawn.ids.count - 1)]
        await session.placed(session.currentTimeline, at: next, latest: nil)
        try await check(walk, label)
        return next
    }

    /// Down the timeline in front `rows` drawn rows, or to its foot: the row it is at.
    private func down(_ walk: Walk, from start: String, rows: Int, step: Int) async throws -> String {
        var row = start
        var gone = 0
        while gone < rows {
            let before = row
            row = try await move(walk, from: row, by: step, "down \(gone)")
            gone += step
            if row == before { break }
        }
        return row
    }

    /// Switched from the timeline in front, left at `row`, to `query`, whose first page or
    /// stretch again is read: the row it draws first.
    private func switchTo(_ query: TimelineQuery, _ walk: Walk, leaving row: String) async throws -> String {
        let session = walk.session
        session.timelineLeft(session.currentTimeline, at: row)
        session.timelineID = query
        _ = session.timelineItems(latest: nil)
        await session.cover(latest: nil)
        try await check(walk, "switched to \(query.id)")
        return session.coverage[query].flatMap { held in held.landed ? session.anchors[query] : nil }
            ?? session.timelineIDs(latest: nil)[0]
    }

    @Test("Down to the foot, through two other timelines and back, and up to the newest: every window is the file's, all a held row holds is held, and the pool keeps to its cap")
    func walk() async throws {
        var walk = try await launched()
        defer { try? FileManager.default.removeItem(at: walk.dir) }
        let session = walk.session
        try await check(walk, "the first page")
        // Down All to its foot.
        var row = session.timelineIDs(latest: nil)[0]
        row = try await down(walk, from: row, rows: .max, step: Self.step)
        #expect(session.coverage[.all]?.exhausted == true, "read to the foot of the file")
        #expect(session.timelineItems(latest: nil).last?.noteID == Self.name(Self.posts - 1))
        let leftAll = row
        // Into the first source's timeline, down a stretch, and a row written into it later.
        row = try await switchTo(walk.queries[1], walk, leaving: row)
        row = try await down(walk, from: row, rows: 1_200, step: Self.step)
        let leftOne = row
        let deepInOne = try #require(session.timelineItems(latest: nil).first { $0.id == leftOne })
        // Into the third source's, and down a stretch of it too.
        row = try await switchTo(walk.queries[2], walk, leaving: row)
        row = try await down(walk, from: row, rows: 600, step: Self.step)
        // A post written to the file inside the first's window while it is behind the third.
        let late = Note(
            id: "late", source: Self.sources[0], author: "A", handle: "a@one.example", body: "words late",
            postedAt: deepInOne.postedAt.addingTimeInterval(-30), categories: [.home], statusID: "s-late"
        )
        try await walk.file.save(RowChanges(upserts: [late]))
        // The whole store holds it too, as the file does.
        await walk.whole.store.ingest([late])
        await walk.whole.reloadFromStore()
        for query in walk.queries {
            walk.whole.timelineID = query
            walk.drawnWhole[query] = walk.whole.timelineItems(latest: nil)
        }
        // Back to All, left deep down: drawn at once round where it was left, before any page.
        let before = await walk.pages.read
        session.timelineLeft(session.currentTimeline, at: row)
        session.timelineID = .all
        let back = session.timelineItems(latest: nil)
        let at = try #require(back.firstIndex { $0.id == leftAll })
        #expect(at <= ShellSession.keptAway && back.count <= 2 * ShellSession.keptAway + 1)
        #expect(await walk.pages.read == before, "a page was read to draw it")
        await session.cover(latest: nil)
        try await check(walk, "back to All")
        // Back to the first: the post written while it was behind is drawn once read again.
        row = try await switchTo(walk.queries[1], walk, leaving: leftAll)
        #expect(session.timelineItems(latest: nil).contains { $0.noteID == "late" })
        row = try await switchTo(.all, walk, leaving: row)
        // Up All to its newest.
        var steps = 0
        while steps < 1_000 {
            steps += 1
            if session.timelineDrawn(latest: nil).index[row] == 0, session.coverage[.all]?.ceiling == nil { break }
            row = try await move(walk, from: row, by: -Self.step, "up \(steps)")
        }
        #expect(session.timelineIDs(latest: nil).first == walk.drawnWhole[.all]?.first?.id, "the newest drawn first")
        #expect(session.coverage[.all]?.ceiling == nil, "read up to the newest")
        // Every page was read off the main thread.
        #expect(await walk.pages.read > 100)
        #expect(await walk.pages.onMain == 0)
        // Usage counts the file's posts, whatever the pool holds now.
        await session.readRowCounts()
        let held = try walk.file.rowCount()
        let total = session.postsHeldTotal
        #expect(total.count == held && !total.atLeast)
        for source in Self.sources {
            let ofIt = try walk.file.keys(.host(source.host)).count + (try walk.file.keptRows().filter { $0.note.key.host == source.host }.count)
            #expect(session.postsHeld(host: source.host) == (ofIt, false))
        }
        #expect(await session.store.pooled < held / 4, "the pool holds a stretch, not the file")
    }
}
