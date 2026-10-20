import Darwin
import FediqoCore
@testable import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #360, K4 (C31): every count the screens say over a store held in part, on a seeded file
/// larger than the pool's cap, as a launch makes the session: its figure, and whether it says
/// "at least". Exact: the total, each source, each week and month (from the file), what is kept
/// and what stays kept on a remove or a stop keeping once the kept rows are read, a span's,
/// the gone posts', what a press let go, and what a read back brings. At least: the earlier
/// wordings, what is held of a person and under a hashtag (search is K3's own, in
/// `SearchFromFileTests`). And no count is read of the file on the main thread. No view.
@Suite("Counts over a store held in part, exact or at least")
@MainActor
struct CountsFromFileTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)
    /// The pool's cap here: well under what the file holds.
    private static let cap = 100
    private static let swift = PostTag("#swift")!
    private static let person = DummyPerson(making: note("x", author: "P", handle: "p@one.example", body: "", at: at))!

    private static func note(
        _ id: String, author: String = "A", handle: String = "a@one.example", body: String, at: Date,
        kept: Bool = false, goneSince: Date? = nil, earlier: [Wording] = []
    ) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, postedAt: at, categories: [.home],
            goneSince: goneSince, kept: kept, earlier: earlier
        )
    }

    /// 400 posts three hours apart, newest first — some seven weeks over two or three months:
    /// every fourth the person's, every tenth under the hashtag, every 25th with a wording before.
    private static let posts = (0..<400).map { n in
        note(
            String(format: "p%04d", n), author: n.isMultiple(of: 4) ? "P" : "A",
            handle: n.isMultiple(of: 4) ? "p@one.example" : "a@one.example",
            body: n.isMultiple(of: 10) ? "words \(n) #swift" : "words \(n)", at: at.addingTimeInterval(-Double(n) * 10_800),
            earlier: n.isMultiple(of: 25) ? [Wording(body: "before \(n)", until: at.addingTimeInterval(-Double(n) * 10_800 + 60))] : []
        )
    }

    /// 30 kept posts long before every post of `posts`, an hour apart.
    private static let kept = (0..<30).map { n in
        note(String(format: "k%03d", n), body: "kept \(n)", at: at.addingTimeInterval(-17_000_000 - Double(n) * 3_600), kept: true)
    }

    /// 20 posts their source said were gone, longer before still.
    private static let gone = (0..<20).map { n in
        note(
            String(format: "g%03d", n), body: "gone \(n)", at: at.addingTimeInterval(-26_000_000 - Double(n) * 3_600),
            goneSince: at.addingTimeInterval(-8_000_000)
        )
    }

    private static var everything: [Note] { posts + kept + gone }

    /// The file, every read of it counted by whether it was made on the main thread.
    final class Watched: HeldRows, @unchecked Sendable {
        private let file: StoreFile
        private let lock = NSLock()
        private var main = 0
        private var reads = 0

        init(_ file: StoreFile) { self.file = file }

        /// How many reads there were, and how many of them on the main thread.
        var counted: (reads: Int, onMain: Int) { lock.withLock { (reads, main) } }

        private func call<T>(_ read: () throws -> T) throws -> T {
            let onMain = pthread_main_np() != 0
            lock.withLock {
                reads += 1
                if onMain { main += 1 }
            }
            return try read()
        }

        func rows(_ keys: [NoteKey]) throws -> [HeldRow] { try call { try file.rows(keys) } }
        func rows(host: String, idPrefix: String) throws -> [HeldRow] { try call { try file.rows(host: host, idPrefix: idPrefix) } }
        func rows(host: String, statusIDs: [String]) throws -> [HeldRow] { try call { try file.rows(host: host, statusIDs: statusIDs) } }
        func keptRows() throws -> [HeldRow] { try call { try file.keptRows() } }
        func reblogged(by keys: [NoteKey]) throws -> [NoteKey] { try call { try file.reblogged(by: keys) } }
        func keys(_ selection: RowSelection) throws -> [NoteKey] { try call { try file.keys(selection) } }
        func keys(host: String, in category: FediqoCore.Category) throws -> [NoteKey] {
            try call { try file.keys(host: host, in: category) }
        }
        func oldest(_ limit: Int, after: PageCursor?) throws -> (rows: [HeldRow], next: PageCursor?) {
            try call { try file.oldest(limit, after: after) }
        }
        func oldestKeys(_ limit: Int, after: PageCursor?) throws -> (rows: [OldestRow], next: PageCursor?) {
            try call { try file.oldestKeys(limit, after: after) }
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
        func rowsByPeriod(_ period: HeldPeriod, calendar: Calendar, most: Int) throws -> [Holdings.Bucket] {
            try call { try file.rowsByPeriod(period, calendar: calendar, most: most) }
        }
        func oldestStatusID(host: String, category: FediqoCore.Category) throws -> String? {
            try call { try file.oldestStatusID(host: host, category: category) }
        }
        func newestListed(host: String, category: FediqoCore.Category) throws -> (id: String, key: NoteKey)? {
            try call { try file.newestListed(host: host, category: category) }
        }
    }

    /// A file of `everything`, and a session over it as a launch makes one, with a small cap, its
    /// first page read and drawn: the pool holds part of the file.
    private func launched() async throws -> (ShellSession, StoreFile, Watched, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.source], notes: Self.everything)
            try await file.makeIndexes()
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let watched = Watched(file)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: opened.sources, said: opened.said, rows: watched, cap: Self.cap)
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        await session.reprojectSources()
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        let pooled = await session.store.pooled
        #expect(pooled > 0 && pooled < Self.everything.count, "the premise: the pool holds part of the file")
        return (session, file, watched, dir)
    }

    // MARK: - Exact

    @Test("The total and each source's posts: at least before the file is counted, then exactly the file's")
    func totalAndSource() async throws {
        let (session, _, watched, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let total = Self.everything.count
        #expect(session.postsHeldTotal.atLeast && session.postsHeld(host: Self.source.host).atLeast)
        #expect(session.postsHeldTotal.count < total)
        await session.readRowCounts()
        #expect(session.postsHeldTotal == (total, false))
        #expect(session.postsHeld(host: Self.source.host) == (total, false))
        #expect(UsagePane.totalLine(session.postsHeldTotal, onDisk: nil) == L10n.count("prefs.held.posts", total))
        #expect(watched.counted.reads > 0 && watched.counted.onMain == 0, "no count read on the main thread")
    }

    @Test("Each week and each month: at least the pool's before the file is counted, then exactly the whole store's")
    func weeksAndMonths() async throws {
        let (session, file, watched, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try file.load().notes
        #expect(session.heldByPeriod().atLeast, "at least, before the file is counted")
        await session.readRowCounts()
        for period in HeldPeriod.allCases {
            session.heldPeriod = period
            let oracle = Holdings(notes: all, per: period).byPeriod
            #expect(oracle.count > 1, "the posts span more than one \(period)")
            let counted = session.heldByPeriod()
            #expect(!counted.atLeast)
            #expect(counted.buckets == Array(oracle.prefix(UsagePane.stretchesShown)), "the file's newest \(period)s are the whole store's")
            #expect(counted.buckets.count == min(oracle.count, UsagePane.stretchesShown), "no more counted than Usage shows")
            let newest = try #require(counted.buckets.first)
            #expect(UsagePane.postsLine(newest.posts, atLeast: counted.atLeast, language: .english) == "\(newest.posts) posts")
        }
        #expect(watched.counted.reads > 0 && watched.counted.onMain == 0, "no count read on the main thread")
    }

    @Test("The file's own breakdown keeps the calendar's weeks: a week starting on Monday and one on Sunday count apart")
    func weeksByTheCalendar() async throws {
        let (_, file, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try file.load().notes
        for (first, zone) in [(1, "America/New_York"), (2, "Asia/Kolkata"), (2, "Asia/Kathmandu")] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.firstWeekday = first
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            for period in HeldPeriod.allCases {
                #expect(try file.rowsByPeriod(period, calendar: calendar) == Holdings(notes: all, per: period, calendar: calendar).byPeriod)
            }
        }
    }

    @Test("Posts not yet written: the breakdown says at least what the pool holds until they are, then the file's exactly again")
    func weeksWhileSavesAreOwed() async throws {
        let (session, file, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        session.heldPeriod = .week
        await session.readRowCounts()
        let before = session.heldByPeriod()
        #expect(!before.atLeast)
        let newestWeek = try #require(before.buckets.first)
        // Thirty posts in the newest week, held and not yet written.
        let arriving = (0..<30).map { n in
            Self.note(String(format: "q%03d", n), body: "new \(n)", at: Self.at.addingTimeInterval(Double(n + 1)))
        }
        await session.store.ingest(arriving)
        await session.reloadFromStore()
        let owed = session.heldByPeriod()
        #expect(owed.atLeast, "a change not written: at least")
        #expect(owed.buckets == session.holdings.byPeriod, "the pool's, which are all held")
        await session.readRowCounts()
        #expect(session.heldByPeriod().atLeast, "counted while owed: still at least")
        // Written, and counted again: exactly, the thirty with the rest.
        let (changes, _) = await session.store.takeChanges()
        try await file.save(changes)
        await session.store.wrote(changes)
        await session.readRowCounts()
        let written = session.heldByPeriod()
        #expect(!written.atLeast)
        #expect(written.buckets.first == Holdings.Bucket(start: newestWeek.start, posts: newestWeek.posts + arriving.count))
    }

    @Test("Counted in another calendar's weeks: at least the pool's until counted in this one, then exactly")
    func calendarChanged() async throws {
        let (session, file, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try file.load().notes
        session.heldPeriod = .week
        var other = Calendar.current
        other.firstWeekday = Calendar.current.firstWeekday == 1 ? 2 : 1
        other.timeZone = try #require(TimeZone(identifier: Calendar.current.timeZone.identifier == "Asia/Kathmandu" ? "America/New_York" : "Asia/Kathmandu"))
        await session.readRowCounts(calendar: other)
        #expect(session.heldByPeriod(calendar: other) == (Array(Holdings(notes: all, per: .week, calendar: other).byPeriod.prefix(UsagePane.stretchesShown)), false))
        #expect(!session.periodsExact())
        let stale = session.heldByPeriod()
        #expect(stale.atLeast && stale.buckets == session.holdings.byPeriod, "another calendar's count: the pool's, at least")
        await session.readRowCounts()
        #expect(session.periodsExact())
        #expect(session.heldByPeriod() == (Array(Holdings(notes: all, per: .week).byPeriod.prefix(UsagePane.stretchesShown)), false))
    }

    @Test("What is kept, and what stays kept on a remove or a stop keeping: at least until the kept rows are read, then exact")
    func keptExactOnceRead() async throws {
        let (session, _, watched, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Self.kept.count
        #expect(session.keptAtLeast, "at least, before the kept rows are read")
        await session.readKeptRows()
        #expect(session.keptRowsRead == true)
        #expect(!session.keptAtLeast)
        #expect(session.holdings.kept.posts == kept)
        #expect(session.holdings.kept(host: Self.source.host).posts == kept)
        #expect(KeptSection.figure(session.holdings.kept, atLeast: session.keptAtLeast, language: .english)
            .hasPrefix(L10n.count("usage.kept.posts", kept, language: .english)))
        let remove = session.removeQuestion(host: Self.source.host, postsStay: false, language: .english)
        #expect(remove.line.contains("the \(kept) you keep") && !remove.line.contains("at least"))
        let lines = KeptSection.lines(session.holdings, sources: [Self.source.host])
        let ask = KeptSection.ask(try #require(lines.first), atLeast: session.keptAtLeast)
        #expect(ask.posts == kept && !ask.atLeast)
        #expect(ShellQuestion.stopKeeping(ask, language: .english).title == "Stop keeping \(kept) posts?")
        // What went at the press: every kept row of the file.
        #expect(await session.stopKeeping(host: nil) == StoppedKeeping(ordinary: kept, elsewhere: 0))
        #expect(watched.counted.onMain == 0, "no count read on the main thread")
    }

    @Test("A span: the posts it would let go are every one of the file's, and what went at the press is that many")
    func spanExact() async throws {
        let (session, file, watched, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try file.load().notes
        let span = at(-Double(399) * 10_800 - 1)..<at(1)
        let going = all.filter { !$0.kept && span.contains($0.postedAt) }.count
        #expect(going == Self.posts.count)
        #expect(await session.spanHeld(span, host: nil) < going, "the row's live figure is the pool's, at least so many")
        #expect(await session.spanGoing(span, host: nil) == going)
        let question = ShellQuestion.letGo(SpanAsk(from: span.lowerBound, to: span.upperBound, host: nil, atLeast: true)
            .counting(going), language: .english)
        #expect(question.title == "Let go of \(going) posts?")
        #expect(await session.letGo(span: span, host: nil) == going)
        #expect(SpanSection.wentLine(going, language: .english) == L10n.count("prefs.span.went", going, language: .english))
        #expect(watched.counted.onMain == 0, "no count read on the main thread")
    }

    @Test("The posts gone from their source: every one the file holds goes, and that many are said")
    func goneExact() async throws {
        let (session, _, watched, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let went = await session.letGoneGo(waitingDays: 1, keepingMonths: nil, from: Self.at)
        #expect(went.posts == Self.gone.count)
        #expect(watched.counted.onMain == 0, "no count read on the main thread")
    }

    @Test("A read back names the posts and kept of the package, whatever the pool holds")
    func carryExact() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = PackageSummary(
            sources: [.init(host: Self.source.host, kind: .mastodon)], posts: Self.everything.count, timelines: 1,
            takenAt: Self.at, withPictures: false, bytes: 1, hasSecrets: false, device: "D", appVersion: "1",
            entryCount: 1, kept: Self.kept.count
        )
        let ask = ShellQuestion.readBack(summary, held: true, language: .english)
        #expect(ask.title == "Read back \(Self.everything.count) posts?")
        #expect(!ask.title.lowercased().contains("at least"))
        #expect(await session.store.pooled < Self.everything.count)
    }

    // MARK: - At least

    @Test("The earlier wordings: of the pool, and said to be at least so many")
    func earlierAtLeast() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        await session.readRowCounts()
        let pooled = session.holdings.earlier
        #expect(pooled > 0 && pooled < Self.posts.filter { !$0.earlier.isEmpty }.count)
        let figure = try #require(UsagePane.earlierFigure(pooled, atLeast: session.store.heldInPart, language: .english))
        #expect(figure == L10n.count("prefs.held.earlier.count.atLeast", pooled, language: .english) && figure.hasPrefix("At least"))
    }

    @Test("What is held of a person: of the pool, and said to be at least so many, in either language")
    func personAtLeast() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = session.heldPosts(of: Self.person).count
        #expect(held > 0 && held < Self.posts.filter { $0.handle == "p@one.example" }.count)
        #expect(session.heldAtLeast)
        let head = PersonHeadSaid.made(
            of: Self.person, said: nil, tabs: [.posts], held: held, heldAtLeast: session.heldAtLeast, standing: nil,
            language: .english
        )
        #expect(head.held == "At least \(held) posts here")
        #expect(PersonHeadSaid.heldLine(held, atLeast: true, language: .taiwanese) == "這裡至少有 \(held) 則")
        #expect(PersonHeadSaid.heldLine(held, language: .english) == "\(held) posts here", "held whole, as before")
    }

    @Test("What is held under a hashtag: of the pool, and said to be at least so many, in either language")
    func tagAtLeast() async throws {
        let (session, _, _, dir) = try await launched()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = session.heldPosts(under: Self.swift, latest: nil).count
        #expect(held > 0 && held < Self.posts.filter { $0.body.contains("#swift") }.count)
        let said = TagPageSaid.made(of: Self.swift, held: held, heldAtLeast: session.heldAtLeast, language: .english)
        #expect(said.figure.figure == "\(held)+")
        #expect(said.figure.spoken == "At least \(held) posts here")
        let zh = TagPageSaid.made(of: Self.swift, held: held, heldAtLeast: true, language: .taiwanese)
        #expect(zh.figure.spoken == "這裡至少有 \(held) 則")
        let whole = TagPageSaid.made(of: Self.swift, held: held, language: .english)
        #expect(whole.figure.figure == "\(held)" && whole.figure.spoken == "\(held) posts here", "held whole, as before")
    }

    private func at(_ offset: TimeInterval) -> Date { Self.at.addingTimeInterval(offset) }
}
