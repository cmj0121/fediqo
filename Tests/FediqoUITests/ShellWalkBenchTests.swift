import Darwin
@testable import FediqoCore
@testable import FediqoPersistence
import Foundation
import GRDB
import os
@preconcurrency import SQLite3
import Testing
@testable import FediqoUI

/// A long walk through a large store, measured (#359, G5; #360, K-12). **Skipped unless asked
/// for**: `FEDIQO_BENCH=1` builds a store of 270,000 rows; `FEDIQO_BENCH_STORE=<folder>` walks a
/// copy of the `index.sqlite` in that folder, made by SQLite's own backup from the one given
/// opened read only, so the folder given is never written. All is read 200,000 rows down, an
/// anchor every twenty rows as the list reports them, and every 5,000 rows a source's home (or
/// its public timeline, or the source alone, whichever first has a page of rows) is switched to,
/// read 500 rows down and left; then the last 50,000 rows of it are read twice more, up and
/// down again — a stretch read again must add nothing. Only counts, sizes, timings and type
/// names are printed — nothing a row says, and no source by name.
///
/// What is measured: the process's footprint (`phys_footprint`, free memory given back first),
/// the heap's bytes in use and their high-water mark (`malloc_zone_statistics`), SQLite's own
/// heap and its page cache (`sqlite3_status64`, `sqlite3_db_status`), and a census of every
/// collection the store and the session hold — every 5,000 rows, each just after a pass of the
/// letting go, so the pool is let down alike each time. At the first page, at 50,000 rows,
/// after the walk and after the stretch read again, `heap` counts the process's allocations by
/// type, where it may read this process. Beside it, how long the main actor is held at a
/// stretch, by a probe that waits on it without pause; how long a page takes; the pool's size;
/// and how long each pass of the letting go took on the store's actor.
@Suite("A long walk through a large store, measured", .serialized)
@MainActor
struct ShellWalkBenchTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let down = 200_000
    private static let again = 50_000
    private static let leg = 5_000
    private static let aside = 500

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func ms(_ value: Double) -> String { String(format: "%.2f ms", value) }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    private static func signedMB(_ bytes: Int) -> String { String(format: "%+.2f MB", Double(bytes) / 1_048_576) }

    /// The process's footprint as the system counts it against the app, free memory given back
    /// to the system first, so what was freed is not counted.
    private static func footprint() -> Int {
        _ = malloc_zone_pressure_relief(nil, 0)
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(usage.ri_phys_footprint) : 0
    }

    /// The bytes every malloc zone holds in use now, and the most they held at once.
    private static func heapInUse() -> (now: Int, most: Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Int(stats.size_in_use), Int(stats.max_size_in_use))
    }

    /// One of SQLite's process-wide figures: now, and the most since the process began.
    private static func sqliteStatus(_ op: Int32) -> (now: Int, most: Int) {
        var now: sqlite3_int64 = 0
        var most: sqlite3_int64 = 0
        guard sqlite3_status64(op, &now, &most, 0) == SQLITE_OK else { return (-1, -1) }
        return (Int(now), Int(most))
    }

    /// Everything measured at one moment, `rows` into the walk.
    struct Sample {
        let rows: Int
        let footprint: Int
        let inUse: Int
        let mostInUse: Int
        /// SQLite's own heap, and its high-water mark.
        let sqlite: Int
        let sqliteMost: Int
        /// SQLite's page cache from its own slots and from the heap.
        let pageCache: Int
        let pageCacheOverflow: Int
        /// The one connection's page cache and its prepared statements (`sqlite3_db_status`).
        let dbCache: Int
        let dbStatements: Int
        let census: [String: Int]
    }

    private static func sample(rows: Int, file: StoreFile, store: ItemStore, session: ShellSession, bench: [String: Int]) async -> Sample {
        let footprint = Self.footprint()
        let heap = heapInUse()
        let sqlite = sqliteStatus(SQLITE_STATUS_MEMORY_USED)
        let used = sqliteStatus(SQLITE_STATUS_PAGECACHE_USED)
        let overflow = sqliteStatus(SQLITE_STATUS_PAGECACHE_OVERFLOW)
        let db = (try? await file.db.read { db -> (Int, Int) in
            var cache: Int32 = 0
            var statements: Int32 = 0
            var most: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_USED, &cache, &most, 0)
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_STMT_USED, &statements, &most, 0)
            return (Int(cache), Int(statements))
        }) ?? (-1, -1)
        var census: [String: Int] = [:]
        for (key, value) in await store.census() { census["store." + key] = value }
        for (key, value) in session.census() { census["session." + key] = value }
        for (key, value) in bench { census["bench." + key] = value }
        return Sample(
            rows: rows, footprint: footprint, inUse: heap.now, mostInUse: heap.most, sqlite: sqlite.now,
            sqliteMost: sqlite.most, pageCache: used.now, pageCacheOverflow: overflow.now, dbCache: db.0,
            dbStatements: db.1, census: census
        )
    }

    // MARK: - Counts by type, as `heap` reads this process

    /// Allocations by type — the type's name and the image it is of, nothing it holds — and how
    /// many there are and their bytes.
    typealias Classes = [String: (count: Int, bytes: Int)]

    /// `heap` run on this process, its table of allocations by type kept, names and counts
    /// only; nothing where it cannot read this process, with why.
    nonisolated private static func classes() async -> Result<Classes, HeapUnread> {
        await Task.detached(priority: .userInitiated) { () -> Result<Classes, HeapUnread> in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("heap-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: out) }
            guard FileManager.default.createFile(atPath: out.path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: out.path)
            else { return .failure(HeapUnread(why: "no file for its table")) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
            process.arguments = [String(getpid())]
            process.standardOutput = handle
            process.standardError = handle
            do { try process.run() } catch { return .failure(HeapUnread(why: "it would not start")) }
            process.waitUntilExit()
            try? handle.close()
            guard let text = try? String(contentsOf: out, encoding: .utf8) else {
                return .failure(HeapUnread(why: "its table would not read"))
            }
            let table = Self.parse(text)
            guard process.terminationStatus == 0, !table.isEmpty else {
                // Its own word on why, where it says one: a sentence of the tool's, no content.
                let said = text.split(separator: "\n").last { $0.contains("rror") || $0.contains("not") || $0.contains("denied") }
                return .failure(HeapUnread(why: "exit \(process.terminationStatus): " + (said.map(String.init) ?? "no table")))
            }
            return .success(table)
        }.value
    }

    struct HeapUnread: Error {
        let why: String
    }

    /// The rows of `heap`'s table of counts by type: the columns as its header places them.
    nonisolated private static func parse(_ text: String) -> Classes {
        var table: Classes = [:]
        var name: String.Index?
        var type: String.Index?
        var header: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("CLASS_NAME"), line.contains("COUNT"), let at = line.range(of: "CLASS_NAME"), let typeAt = line.range(of: "TYPE") {
                header = line
                name = at.lowerBound
                type = typeAt.lowerBound
                continue
            }
            guard let header, let name, let type else { continue }
            if line.hasPrefix("   =====") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let count = Int(fields[0]), let bytes = Int(fields[1]) else { continue }
            // The name, its kind and its image as one: a long name runs over the columns after it.
            _ = type
            let nameOffset = header.distance(from: header.startIndex, to: name)
            let chars = Array(line)
            guard chars.count > nameOffset else { continue }
            let key = String(chars[nameOffset...]).split(separator: " ").joined(separator: " ")
            let held = table[key] ?? (0, 0)
            table[key] = (held.count + count, held.bytes + bytes)
        }
        return table
    }

    /// The types whose count grew most from `from` to `to`, and the totals.
    private static func printGrowth(_ label: String, from: Classes, to: Classes, between: String) {
        let total = { (table: Classes) in table.values.reduce((0, 0)) { ($0.0 + $1.count, $0.1 + $1.bytes) } }
        let (fromCount, fromBytes) = total(from)
        let (toCount, toBytes) = total(to)
        print("[walk \(label)] heap \(between): \(fromCount) → \(toCount) allocations, \(mb(fromBytes)) → \(mb(toBytes))")
        let names = Set(from.keys).union(to.keys)
        let grown = names.map { name in
            (name: name, count: (to[name]?.count ?? 0) - (from[name]?.count ?? 0), bytes: (to[name]?.bytes ?? 0) - (from[name]?.bytes ?? 0))
        }
        let byCount = grown.sorted { $0.count > $1.count }.prefix(20)
        print("[walk \(label)]   20 types grown most by count \(between) (Δcount, Δbytes, count now):")
        for row in byCount {
            print("[walk \(label)]     \(String(format: "%+8d", row.count))  \(signedMB(row.bytes))  \(to[row.name]?.count ?? 0)  \(row.name)")
        }
        let byBytes = grown.sorted { $0.bytes > $1.bytes }.prefix(10)
        print("[walk \(label)]   10 types grown most by bytes \(between):")
        for row in byBytes {
            print("[walk \(label)]     \(signedMB(row.bytes))  \(String(format: "%+8d", row.count))  \(row.name)")
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    /// Waits on the main actor without pause, off it, and keeps how long each wait took: a wait
    /// begun just as the main actor takes up a stretch of work lasts as long as that stretch.
    /// Nothing is kept while it is told to look away — while `heap` holds the process still.
    final class MainProbe: Sendable {
        private let waits = OSAllocatedUnfairLock<[Double]>(initialState: [])
        private let running = OSAllocatedUnfairLock(initialState: true)
        private let away = OSAllocatedUnfairLock(initialState: false)

        func start() -> Task<Void, Never> {
            Task.detached(priority: .userInitiated) { [self] in
                let clock = ContinuousClock()
                while running.withLock({ $0 }) {
                    let asked = clock.now
                    await MainActor.run {}
                    // Only the stretches are kept: millions of waits on an idle main actor would
                    // be the footprint's growth themselves.
                    let waited = ShellWalkBenchTests.milliseconds(clock.now - asked)
                    if waited >= 0.1, !away.withLock({ $0 }) { waits.withLock { $0.append(waited) } }
                }
            }
        }

        func stop() { running.withLock { $0 = false } }

        func lookAway(_ looking: Bool) { away.withLock { $0 = looking } }

        /// The stretches the main actor was held for: every wait longer than a tenth of a
        /// millisecond, the rest being a main actor with nothing to do.
        var stretches: [Double] { waits.withLock { $0 } }
        var count: Int { waits.withLock { $0.count } }
    }

    /// No network: every ask fails at once, and only how many were asked is kept — a fixture
    /// that keeps every address asked would be the footprint's growth itself.
    final class Unreachable: HTTPClient {
        private let asked = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { asked.withLock { $0 } }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            asked.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
    }

    /// How long each page took, read off the main actor.
    final class PageTimes: Sendable {
        private let times = OSAllocatedUnfairLock<[Double]>(initialState: [])
        func add(_ value: Double) { times.withLock { $0.append(value) } }
        var all: [Double] { times.withLock { $0 } }
        var count: Int { times.withLock { $0.count } }
    }

    /// A store of 270,000 rows in `dir`, as round 1's bench builds it, written a tenth at a time.
    private static func synthetic(in dir: URL) async throws {
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: [])
        for part in 0..<10 {
            var notes: [Note] = []
            notes.reserveCapacity(27_000)
            for n in part * 27_000..<(part + 1) * 27_000 {
                let categories: Set<FediqoCore.Category> = switch n % 20 {
                case 0..<6: [.home]
                case 6: [.trends]
                case 7: [.home, .public]
                default: [.public]
                }
                notes.append(Note(
                    id: "\(n)", source: sources[n % 3], author: "A", handle: "a\(n % 500)@one.example", body: words,
                    postedAt: start.addingTimeInterval(-Double((n * 7_919) % 270_000) * 60), categories: categories,
                    statusID: "\(n)"
                ))
            }
            try await file.save(RowChanges(upserts: notes))
        }
        try await file.makeIndexes()
        try file.db.close()
    }

    /// A copy of the `index.sqlite` in the folder given, in a folder of its own, made by SQLite's
    /// own backup from the given one opened read only: the one given is never written.
    private static func copy(into dir: URL) throws {
        let given = URL(fileURLWithPath: try #require(environment["FEDIQO_BENCH_STORE"]))
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: given.appendingPathComponent(StoreFile.indexName).path, configuration: readOnly)
        let copy = try DatabaseQueue(path: dir.appendingPathComponent(StoreFile.indexName).path)
        try source.backup(to: copy)
        try source.close()
        try copy.close()
    }

    /// The walk over the store in `dir`, opened as a launch opens it, its numbers printed.
    private func walk(_ dir: URL, label: String) async throws -> (growth: Int, p95: Double, eviction: Double) {
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        // The indexes a launch makes, made before anything is measured.
        try await file.makeIndexes()
        let rows = try file.rowCount()
        let store = ItemStore(sources: opened.sources, said: opened.said, rows: file)
        let network = Unreachable()
        let session = ShellSession(http: network, store: store)
        let times = PageTimes()
        session.readPage = { query, ask, limit in
            let clock = ContinuousClock()
            let begun = clock.now
            let page = try await file.page(query, ask, limit: limit)
            times.add(Self.milliseconds(clock.now - begun))
            return page
        }
        // A source and a category of it: the home, or else the public timeline, of the source
        // the file holds most rows of whose timeline has a page of rows; else that source alone.
        let counts = try file.rowCounts()
        let bySize = opened.sources.sorted { (counts[$0.host]?.count ?? 0) > (counts[$1.host]?.count ?? 0) }
        var chosen: TimelineDefinition?
        var kind = "a source alone"
        search: for category in [FediqoCore.Category.home, .public] {
            for source in bySize {
                guard let rule = Rule.category(category, in: .source(host: source.host), sources: opened.sources) else { continue }
                let definition = TimelineDefinition(name: "Aside", rules: [rule])
                let asked = PageQuery(
                    timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: opened.sources)
                )
                guard try await file.page(asked, .newest).rows.count >= ShellSession.pageRows else { continue }
                chosen = definition
                kind = category == .home ? "a source's home" : "a source's public timeline"
                break search
            }
        }
        if chosen == nil, let source = bySize.first {
            chosen = TimelineDefinition(name: "Aside", rules: [try #require(Rule.source(source.host))])
        }
        let aside = try #require(chosen)
        session.written = [aside]
        await session.reprojectSources()
        print("[walk \(label)] \(rows) rows, \(opened.sources.count) sources, pool cap \(ItemStore.poolCap); aside: \(kind)")

        let probe = MainProbe()
        let probing = probe.start()
        defer {
            probe.stop()
            probing.cancel()
        }
        await session.cover(latest: nil)
        _ = session.timelineItems(latest: nil)
        await session.holdDrawn()
        var pools: [Int] = []
        var drawings: [Double] = []
        var merges: [Double] = []
        /// The bench's own lists, counted beside the census: what it keeps is in the heap too.
        func bench() -> [String: Int] {
            ["pools": pools.count, "drawings": drawings.count, "merges": merges.count, "pages": times.count, "stretches": probe.count]
        }
        let first = await Self.sample(rows: 0, file: file, store: store, session: session, bench: bench())
        print("[walk \(label)] after the first page: footprint \(Self.mb(first.footprint)), heap in use \(Self.mb(first.inUse)), pool \(await store.pooled)")
        var samples: [Sample] = [first]
        var classes: [(rows: Int, label: String, table: Classes)] = []
        var heapUnread: String?
        /// `heap`'s counts by type now, the probe looking away while it holds the process still.
        func countClasses(_ rows: Int, _ named: String) async {
            guard heapUnread == nil else { return }
            probe.lookAway(true)
            let read = await Self.classes()
            await MainActor.run {}
            probe.lookAway(false)
            switch read {
            case .success(let table):
                classes.append((rows, named, table))
                print("[walk \(label)] heap read at \(named): \(table.count) types")
            case .failure(let unread):
                heapUnread = unread.why
                print("[walk \(label)] heap could not read this process: \(unread.why)")
            }
        }
        await countClasses(0, "the first page")
        let clock = ContinuousClock()

        /// The place moved `by` drawn rows from `row`, as the list reports it, and the window
        /// moved round it; then drawn as the pane draws it.
        func step(_ row: String, by: Int) async -> String {
            let drawn = session.timelineDrawn(latest: nil)
            guard !drawn.ids.isEmpty else { return row }
            let at = drawn.index[row] ?? 0
            let next = drawn.ids[min(max(at + by, 0), drawn.ids.count - 1)]
            await session.scrolled(to: next, of: session.currentTimeline, latest: nil)?.value
            let begun = clock.now
            _ = session.timelineShown(latest: nil, anchor: next, moving: true)
            drawings.append(Self.milliseconds(clock.now - begun))
            // The drawing worked out afresh, as each landing works it out once: every tenth step,
            // so the probe's stretches are the walk's and not this one's.
            if pools.count % 10 == 0 {
                let afresh = clock.now
                _ = session.timelineItems(under: session.timelineDrawingKey(latest: nil))
                merges.append(Self.milliseconds(clock.now - afresh))
            }
            pools.append(await store.pooled)
            return next
        }

        func switchTo(_ query: TimelineQuery, leaving row: String) async -> String {
            session.timelineLeft(session.currentTimeline, at: row)
            session.timelineID = query
            let begun = clock.now
            let drawn = session.timelineDrawn(latest: nil)
            drawings.append(Self.milliseconds(clock.now - begun))
            let place = session.anchors[query].flatMap { drawn.index[$0] == nil ? nil : $0 }
            await session.cover(latest: nil)
            return place ?? session.timelineIDs(latest: nil).first ?? ""
        }

        /// Measured at the next step after the next pass of the letting go, from `rows`: the
        /// pool then let down to the same size each time, so what it holds moves no figure.
        var due: (rows: Int, passes: Int)?
        func sample() async {
            guard let asked = due, await store.evictionPasses > asked.passes else { return }
            due = nil
            samples.append(await Self.sample(rows: asked.rows, file: file, store: store, session: session, bench: bench()))
        }

        var row = session.timelineIDs(latest: nil).first ?? ""
        var walked = 0
        var asideRow: String?
        /// Down `rows` rows from `row`, the source's timeline beside All read a stretch every
        /// 5,000: whether the foot of All was reached.
        func walkDown(_ rows: Int) async -> Bool {
            var gone = 0
            while gone < rows {
                let before = row
                row = await step(row, by: ShellSession.readAhead)
                gone += ShellSession.readAhead
                walked += ShellSession.readAhead
                await sample()
                if walked % Self.leg == 0 {
                    due = (walked, await store.evictionPasses)
                    var stretch = await switchTo(.written(aside.id), leaving: row)
                    if let asideRow, session.timelineDrawn(latest: nil).index[asideRow] != nil { stretch = asideRow }
                    for _ in 0..<(Self.aside / ShellSession.readAhead) { stretch = await step(stretch, by: ShellSession.readAhead) }
                    asideRow = stretch
                    row = await switchTo(.all, leaving: stretch)
                }
                if walked == 50_000 { await countClasses(walked, "50,000 rows") }
                if row == before, session.coverage[.all]?.exhausted == true {
                    print("[walk \(label)] the foot of All reached at \(walked) rows")
                    return true
                }
            }
            return false
        }

        let begun = clock.now
        // Four legs of 50,000 down.
        var footAt: Int?
        for _ in 0..<(Self.down / 50_000) where footAt == nil {
            if await walkDown(50_000) { footAt = walked }
        }
        // A sample at the end of the walk whatever the leg's count, after the next pass.
        let walkEnd = walked
        due = (walkEnd, await store.evictionPasses)
        var settle = 0
        while due != nil, settle < 50 {
            row = await step(row, by: -ShellSession.readAhead)
            row = await step(row, by: ShellSession.readAhead)
            settle += 1
            await sample()
        }
        await countClasses(walkEnd, "the end of the walk")
        let walkSeconds = Self.milliseconds(clock.now - begun) / 1000
        // The last 50,000 rows read again: up, then down again.
        var climbed = 0
        while climbed < Self.again {
            row = await step(row, by: -ShellSession.readAhead)
            climbed += ShellSession.readAhead
            walked += ShellSession.readAhead
            await sample()
            if walked % Self.leg == 0 { due = (walked, await store.evictionPasses) }
        }
        _ = await walkDown(Self.again)
        due = (walked, await store.evictionPasses)
        settle = 0
        while due != nil, settle < 50 {
            row = await step(row, by: -ShellSession.readAhead)
            row = await step(row, by: ShellSession.readAhead)
            settle += 1
            await sample()
        }
        await countClasses(walked, "the stretch read twice more")
        let elapsed = Self.milliseconds(clock.now - begun) / 1000
        let evictions = await store.passesTook.map(Self.milliseconds)
        probe.stop()
        await probing.value

        let stretches = probe.stretches
        let pages = times.all
        let peak = samples.map(\.footprint).max() ?? first.footprint
        let growth = peak - first.footprint
        print("[walk \(label)] walked \(walkEnd) down in \(String(format: "%.0f s", walkSeconds)), then \(walked - walkEnd) read again; \(String(format: "%.0f s", elapsed)) in all; \(pages.count) pages, \(await store.evictionPasses) passes of the letting go")
        print("[walk \(label)] asks of the network, none answered: \(network.count)")
        print("[walk \(label)] pool: max \(pools.max() ?? 0), median \(Int(Self.percentile(pools.map(Double.init), 0.5))), at the end \(await store.pooled)")
        print("[walk \(label)] main actor held: \(stretches.count) stretches over 0.1 ms, 95th \(Self.ms(Self.percentile(stretches, 0.95))), 99th \(Self.ms(Self.percentile(stretches, 0.99))), max \(Self.ms(stretches.max() ?? 0)); over 16 ms: \(stretches.filter { $0 >= 16 }.count)")
        print("[walk \(label)] drawing a step: 95th \(Self.ms(Self.percentile(drawings, 0.95))), max \(Self.ms(drawings.max() ?? 0))")
        print("[walk \(label)] the drawing worked out afresh: 95th \(Self.ms(Self.percentile(merges, 0.95))), max \(Self.ms(merges.max() ?? 0))")
        print("[walk \(label)] pages: median \(Self.ms(Self.percentile(pages, 0.5))), 95th \(Self.ms(Self.percentile(pages, 0.95))), max \(Self.ms(pages.max() ?? 0))")
        print("[walk \(label)] a pass of the letting go: \(evictions.count) passes, median \(Self.ms(Self.percentile(evictions, 0.5))), 95th \(Self.ms(Self.percentile(evictions, 0.95))), max \(Self.ms(evictions.max() ?? 0))")

        // The allocator every 5,000 rows.
        print("[walk \(label)] allocator (MB): rows | footprint | heap in use | heap most | sqlite | sqlite most | page cache | overflow | db cache | db statements")
        for s in samples {
            print("[walk \(label)]   \(String(format: "%7d", s.rows)) | " + [s.footprint, s.inUse, s.mostInUse, s.sqlite, s.sqliteMost, s.pageCache, s.pageCacheOverflow, s.dbCache, s.dbStatements].map { String(format: "%7.2f", Double($0) / 1_048_576) }.joined(separator: " | "))
        }
        if samples.allSatisfy({ $0.mostInUse == 0 }) {
            print("[walk \(label)]   (the malloc zones keep no high-water mark here: `max_size_in_use` reads 0)")
        }
        if samples.allSatisfy({ $0.sqlite == 0 }) {
            print("[walk \(label)]   (this SQLite keeps no count of its heap — built without memory statistics: `SQLITE_STATUS_MEMORY_USED` reads 0; its page cache is `db cache`)")
        }
        // The census at the checkpoints, and its change over the last 150,000 rows of the walk.
        let marks = [0, 50_000, 100_000, 150_000, walkEnd, walkEnd + Self.again, walked]
        func at(_ rows: Int) -> Sample { samples.last { $0.rows <= rows } ?? first }
        let checkpoints = marks.map(at)
        let from = at(50_000)
        let to = at(walkEnd)
        print("[walk \(label)] census at rows " + checkpoints.map { String($0.rows) }.joined(separator: " / ") + " | Δ \(from.rows)→\(to.rows)")
        let keys = Set(samples.flatMap(\.census.keys)).sorted()
        for key in keys where samples.contains(where: { ($0.census[key] ?? 0) != 0 }) {
            let values = checkpoints.map { String($0.census[key] ?? 0) }.joined(separator: " / ")
            let delta = (to.census[key] ?? 0) - (from.census[key] ?? 0)
            print("[walk \(label)]   \(key): \(values) | \(delta >= 0 ? "+" : "")\(delta)")
        }
        let zero = keys.filter { key in samples.allSatisfy { ($0.census[key] ?? 0) == 0 } }
        print("[walk \(label)]   zero throughout: \(zero.joined(separator: ", "))")
        // Every key that moved over the last 150,000 rows, every 5,000.
        let moved = keys.filter { key in
            let window = samples.filter { $0.rows >= from.rows && $0.rows <= to.rows }.map { $0.census[key] ?? 0 }
            return (window.max() ?? 0) != (window.min() ?? 0)
        }
        for key in moved {
            print("[walk \(label)]   \(key) every 5,000: " + samples.map { String($0.census[key] ?? 0) }.joined(separator: " "))
        }
        print("[walk \(label)] over \(from.rows)→\(to.rows): heap in use \(Self.signedMB(to.inUse - from.inUse)), footprint \(Self.signedMB(to.footprint - from.footprint)), sqlite \(Self.signedMB(to.sqlite - from.sqlite)); read again \(to.rows)→\(walked): heap in use \(Self.signedMB(at(walked).inUse - to.inUse))")

        // Counts by type between the points `heap` read.
        if let heapUnread {
            print("[walk \(label)] no counts by type: \(heapUnread)")
        } else {
            for (a, b) in zip(classes, classes.dropFirst()) {
                Self.printGrowth(label, from: a.table, to: b.table, between: "\(a.label) → \(b.label)")
            }
            if let start = classes.first, let end = classes.last, classes.count > 2 {
                Self.printGrowth(label, from: start.table, to: end.table, between: "\(start.label) → \(end.label)")
            }
        }
        try file.db.close()
        return (growth, Self.percentile(stretches, 0.95), evictions.max() ?? 0)
    }

    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("270,000 rows walked: the footprint grows under 64 MB, the main actor is held under 16 ms at the 95th, a letting go takes under 5 ms",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.synthetic(in: dir)
        let (growth, p95, eviction) = try await walk(dir, label: "synthetic")
        #expect(growth < 64 * 1_048_576)
        #expect(p95 < 16)
        #expect(eviction < 5)
    }

    @Test("a copy of a real store walked: the footprint grows under 64 MB, the main actor is held under 16 ms at the 95th, a letting go takes under 5 ms",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.copy(into: dir)
        let (growth, p95, eviction) = try await walk(dir, label: "copy")
        #expect(growth < 64 * 1_048_576)
        #expect(p95 < 16)
        #expect(eviction < 5)
    }
}
