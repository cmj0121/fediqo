import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long a page takes on a store the size people hold (#357). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 rows and times it; `FEDIQO_BENCH_STORE=<folder>`
/// times a copy of the `index.sqlite` in that folder, made afresh first so the folder given is
/// never opened. Only timings and counts are printed — nothing a row says.
@Suite("A page on a large store, timed", .serialized)
struct StorePagesBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    private static func time<T>(_ work: () async throws -> T) async rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await work()
        return (value, clock.now - start)
    }

    private static func query(_ rules: [Rule?], sources: [Source]) -> PageQuery {
        let definition = TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
        return PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
    }

    /// Times the laps every store is put through, and returns the warm newest page of the first
    /// source's home timeline.
    private static func laps(_ file: StoreFile, sources: [Source], label: String) async throws -> Duration {
        let (_, built) = try await time { try await file.makeIndexes() }
        print("[\(label)] indexes made: \(milliseconds(built))")
        var home = Duration.zero
        for (n, source) in sources.enumerated() {
            let timeline = query([
                .source(source.host), .category(.home, in: .source(host: source.host), sources: sources),
            ], sources: sources)
            let (cold, first) = try await time { try await file.page(timeline, .newest) }
            var warm: [Duration] = []
            for _ in 0..<5 { warm.append(try await time { try await file.page(timeline, .newest) }.1) }
            let median = warm.sorted()[2]
            if n == 0 { home = median }
            print("[\(label)] source \(n) + home, newest 100: first \(milliseconds(first)), warm \(milliseconds(median)), \(cold.rows.count) rows")
        }
        let all = query([], sources: sources)
        let (_, everything) = try await time { try await file.page(all, .newest) }
        print("[\(label)] All, newest 100: \(milliseconds(everything))")
        let nothing = query([.source(sources[0].host), .category(.list(id: "none"), in: .source(host: sources[0].host), sources: sources)], sources: sources)
        let (short, none) = try await time { try await file.page(nothing, .newest) }
        print("[\(label)] no match, first page: \(milliseconds(none)), \(short.rows.count) rows, exhausted \(short.exhausted)")
        let words = query([.keyword("the", in: .every)], sources: sources)
        let (said, keyword) = try await time { try await file.page(words, .newest) }
        print("[\(label)] keyword, newest 100: \(milliseconds(keyword)), \(said.rows.count) rows")
        var ask = PageAsk.newest
        let (_, ten) = try await time {
            for _ in 0..<10 {
                let page = try await file.page(all, ask)
                guard let next = page.next else { break }
                ask = .before(next)
            }
        }
        print("[\(label)] All, ten pages down: \(milliseconds(ten))")
        return home
    }

    @Test("270,000 rows: the newest 100 of a source and a category in under 50 ms",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        var notes: [Note] = []
        notes.reserveCapacity(270_000)
        for n in 0..<270_000 {
            let categories: Set<FediqoCore.Category> = switch n % 20 {
            case 0..<6: [.home]
            case 6: [.trends]
            case 7: [.home, .public]
            default: [.public]
            }
            notes.append(Note(
                id: "\(n)", source: sources[n % 3], author: "A", handle: "a\(n % 500)@one.example", body: words,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % 270_000) * 60), categories: categories
            ))
        }
        let file = try StoreFile(at: dir)
        let (_, saved) = try await Self.time { try await file.save(sources: sources, notes: notes) }
        print("[synthetic] 270,000 rows written: \(Self.milliseconds(saved)), \(file.bytesOnDisk() / 1_000_000) MB")
        let home = try await Self.laps(file, sources: sources, label: "synthetic")
        #expect(home < .milliseconds(50))
    }

    /// One launch as the app makes it (#357, H3b): the open, which reads no row and is all the
    /// timeline place waits for; the indexes set going; the first page of All read and laid into
    /// the pool. Returns how long from the open's start until the page was in hand.
    private static func launch(_ dir: URL, label: String) async throws -> (first: Duration, early: Duration?) {
        let clock = ContinuousClock()
        let start = clock.now
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let placed = clock.now - start
        let store = ItemStore(sources: opened.sources, said: opened.said, notices: opened.notices, unsent: opened.unsent, rows: file)
        let pageIndex = Task.detached { () -> Duration in
            let begun = clock.now
            try? await file.makePageIndex()
            return clock.now - begun
        }
        let all = TimelineDefinition.all
        let asked = PageQuery(timeline: all.id, generation: 1, compiled: CompiledTimeline(all, sources: []))
        // Beside the first page, as the session asks it: a provisional one while the pages'
        // index is being made (C15), laid in as it comes.
        let provisional = Task { () -> (Duration, Int)? in
            guard let early = try? await file.provisionalPage(asked) else { return nil }
            await store.take(early.rows + early.carried)
            return (clock.now - start, early.rows.count)
        }
        let page = try await file.page(asked, .newest)
        await store.take(page.rows + page.carried)
        let inHand = clock.now - start
        let early = await provisional.value
        let (pool, drawn) = await time { await store.all() }
        let made = await pageIndex.value
        // What waits for the timeline to show: the rest of the indexes, one by one, then the scrub.
        var rest: [String] = []
        for sql in StoreFile.pageIndexes.dropFirst() {
            let (_, lap) = try await time { try await file.db.write { db in try db.execute(sql: sql) } }
            rest.append("\(sql.split(separator: " ")[sql.hasPrefix("DROP") ? 4 : 5]) \(milliseconds(lap))")
        }
        let (_, scrubbed) = await time { await file.scrubIfDue() }
        let earlyText = early.map { "provisional page in hand \(milliseconds($0.0)), \($0.1) rows; " } ?? "no provisional page; "
        print("[launch \(label)] open, sources read (place settles): \(milliseconds(placed)); \(earlyText)first page in hand: \(milliseconds(inHand)), \(page.rows.count) rows, pool \(pool.count) (all() \(milliseconds(drawn))); page index \(milliseconds(made)); after it: \(rest.joined(separator: ", ")); scrub \(milliseconds(scrubbed))")
        try file.db.close()
        return (inHand, early?.0)
    }

    @Test("a copy of a real store, launched: the first page in hand within half a second of the open",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func launchedCopy() async throws {
        let dir = try Self.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await Self.launch(dir, label: "first, indexes made")
        let next = try await Self.launch(dir, label: "next").first
        let again = try await Self.launch(dir, label: "next again").first
        print("[launch] first \(Self.milliseconds(first.first)), next \(Self.milliseconds(next)), again \(Self.milliseconds(again))")
        #expect(next < .milliseconds(500) && again < .milliseconds(500))
        // A first launch draws a provisional page within half a second (C15).
        let early = try #require(first.early, "no provisional page on a file without the pages' index")
        #expect(early < .milliseconds(500))
    }

    /// A copy of the given store made afresh by SQLite's own backup, the given one opened read
    /// only, and the indexes this build makes dropped from the copy: an older build's file, as a
    /// first launch of this one meets it.
    static func freshCopy() throws -> URL {
        let given = URL(fileURLWithPath: try #require(environment["FEDIQO_BENCH_STORE"]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: given.appendingPathComponent(StoreFile.indexName).path, configuration: readOnly)
        let copy = try DatabaseQueue(path: dir.appendingPathComponent(StoreFile.indexName).path)
        try source.backup(to: copy)
        try copy.writeWithoutTransaction { db in
            for name in ["note_page", "note_status", "note_owing", "note_kept", "note_gone", "note_refers", "note_cites", "note_cites_many", "note_marked", "note_marked_vote", "note_marked_standing"] {
                try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
            }
        }
        try source.close()
        try copy.close()
        return dir
    }

    @Test("a first launch on a fresh copy of a real store, its indexes timed one by one",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func firstLaunchIndexes() async throws {
        // The pages' index alone, nothing queued beside it.
        do {
            let dir = try Self.freshCopy()
            defer { try? FileManager.default.removeItem(at: dir) }
            let opened = StoreFile.open(at: dir, rows: false)
            let file = try #require(opened.file)
            let (_, alone) = try await Self.time { try await file.makePageIndex() }
            print("[first] note_page alone, after the open: \(Self.milliseconds(alone))")
            for sql in StoreFile.pageIndexes.dropFirst() {
                let name = sql.split(separator: " ")[sql.hasPrefix("DROP") ? 4 : 5]
                let (_, lap) = try await Self.time { try await file.db.write { db in try db.execute(sql: sql) } }
                print("[first] \(name): \(Self.milliseconds(lap))")
            }
            try file.db.close()
        }
        // The launch as the app makes it, on another fresh copy.
        let dir = try Self.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await Self.launch(dir, label: "first, fresh copy")
        print("[first] launch, first page in hand: \(Self.milliseconds(first.first)), provisional \(first.early.map(Self.milliseconds) ?? "none")")
    }

    @Test("a copy of a real store, timed", .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let given = URL(fileURLWithPath: try #require(Self.environment["FEDIQO_BENCH_STORE"]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(
            at: given.appendingPathComponent(StoreFile.indexName), to: dir.appendingPathComponent(StoreFile.indexName)
        )
        let (file, opened) = try await Self.time { try StoreFile(at: dir) }
        let sources = try await file.db.read(StoreFile.sourcesByHost).values.sorted { $0.host < $1.host }
        let rows = try await file.db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0 }
        print("[copy] \(rows) rows, \(sources.count) sources, \(file.bytesOnDisk() / 1_000_000) MB; opened in \(Self.milliseconds(opened))")
        let home = try await Self.laps(file, sources: sources, label: "copy")
        #expect(home < .milliseconds(50))
    }
}
