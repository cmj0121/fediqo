import Darwin
@testable import FediqoCore
@testable import FediqoPersistence
import Foundation
import os
import Testing
@testable import FediqoUI

/// A long walk through a large store, measured (#359, G5). **Skipped unless asked for**:
/// `FEDIQO_BENCH=1` builds a store of 270,000 rows; `FEDIQO_BENCH_STORE=<folder>` walks a copy
/// of the `index.sqlite` in that folder, made afresh first so the folder given is never opened.
/// All is read 50,000 rows down and 5,000 back up, an anchor every twenty rows as the list
/// reports them, and every 5,000 rows a source's home (or its public timeline, or the source
/// alone, whichever first has a page of rows) is switched to, read 500 rows down and left.
/// Only counts and timings are printed — nothing a row says, and no source by name.
///
/// What is measured: the process's footprint (`phys_footprint`) after the first page and every
/// 5,000 rows, free memory given back first; how long the main actor is held at a stretch,
/// by a probe that waits on it without pause; how long a page takes; the pool's size; and a
/// pass of the letting go over the pool as the walk leaves it.
@Suite("A long walk through a large store, measured", .serialized)
@MainActor
struct ShellWalkBenchTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let down = 50_000
    private static let up = 5_000
    private static let leg = 5_000
    private static let aside = 500

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func ms(_ value: Double) -> String { String(format: "%.2f ms", value) }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

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

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    /// Waits on the main actor without pause, off it, and keeps how long each wait took: a wait
    /// begun just as the main actor takes up a stretch of work lasts as long as that stretch.
    final class MainProbe: Sendable {
        private let waits = OSAllocatedUnfairLock<[Double]>(initialState: [])
        private let running = OSAllocatedUnfairLock(initialState: true)

        func start() -> Task<Void, Never> {
            Task.detached(priority: .userInitiated) { [self] in
                let clock = ContinuousClock()
                while running.withLock({ $0 }) {
                    let asked = clock.now
                    await MainActor.run {}
                    // Only the stretches are kept: millions of waits on an idle main actor would
                    // be the footprint's growth themselves.
                    let waited = ShellWalkBenchTests.milliseconds(clock.now - asked)
                    if waited >= 0.1 { waits.withLock { $0.append(waited) } }
                }
            }
        }

        func stop() { running.withLock { $0 = false } }

        /// The stretches the main actor was held for: every wait longer than a tenth of a
        /// millisecond, the rest being a main actor with nothing to do.
        var stretches: [Double] { waits.withLock { $0 } }
    }

    /// How long each page took, read off the main actor.
    final class PageTimes: Sendable {
        private let times = OSAllocatedUnfairLock<[Double]>(initialState: [])
        func add(_ value: Double) { times.withLock { $0.append(value) } }
        var all: [Double] { times.withLock { $0 } }
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

    /// A copy of the `index.sqlite` in the folder given, in a folder of its own: the one given
    /// is never opened.
    private static func copy(into dir: URL) throws {
        let given = URL(fileURLWithPath: try #require(environment["FEDIQO_BENCH_STORE"]))
        try FileManager.default.copyItem(
            at: given.appendingPathComponent(StoreFile.indexName), to: dir.appendingPathComponent(StoreFile.indexName)
        )
    }

    /// The walk over the store in `dir`, opened as a launch opens it, its numbers printed.
    private func walk(_ dir: URL, label: String) async throws -> (growth: Int, p95: Double, eviction: Double) {
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        // The indexes a launch makes, made before anything is measured.
        try await file.makeIndexes()
        let rows = try file.rowCount()
        let store = ItemStore(sources: opened.sources, said: opened.said, rows: file)
        let session = ShellSession(http: FixtureHTTP(), store: store)
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
        let first = Self.footprint()
        print("[walk \(label)] after the first page: footprint \(Self.mb(first)), pool \(await store.pooled)")
        var footprints: [(rows: Int, bytes: Int)] = [(0, first)]
        var pools: [Int] = []
        var evictions: [Double] = []
        var drawings: [Double] = []
        var merges: [Double] = []
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

        /// A pass of the letting go over the pool as the walk left it: the file's oldest rows
        /// read in past the cap, and what the screens draw said again.
        func evictionPass() async throws {
            _ = await store.take(try file.oldest(600, after: nil).rows)
            guard let now = session.drawnNow() else { return }
            let before = await store.evictionPasses
            let begun = clock.now
            await store.hold(now.pins, drawnAt: now.at, by: session.screen)
            let took = Self.milliseconds(clock.now - begun)
            if await store.evictionPasses > before { evictions.append(took) }
            await session.reloadFromStore()
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

        var row = session.timelineIDs(latest: nil).first ?? ""
        var walked = 0
        var asideRow: String?
        let begun = clock.now
        while walked < Self.down {
            let before = row
            row = await step(row, by: ShellSession.readAhead)
            walked += ShellSession.readAhead
            if walked % Self.leg == 0 {
                footprints.append((walked, Self.footprint()))
                try await evictionPass()
                // The source's timeline beside All, read a stretch down and left.
                var stretch = await switchTo(.written(aside.id), leaving: row)
                if let asideRow, session.timelineDrawn(latest: nil).index[asideRow] != nil { stretch = asideRow }
                for _ in 0..<(Self.aside / ShellSession.readAhead) { stretch = await step(stretch, by: ShellSession.readAhead) }
                asideRow = stretch
                row = await switchTo(.all, leaving: stretch)
            }
            if row == before, session.coverage[.all]?.exhausted == true {
                print("[walk \(label)] the foot of All reached at \(walked) rows")
                break
            }
        }
        var climbed = 0
        while climbed < Self.up {
            row = await step(row, by: -ShellSession.readAhead)
            climbed += ShellSession.readAhead
        }
        let elapsed = Self.milliseconds(clock.now - begun) / 1000
        footprints.append((walked + climbed, Self.footprint()))
        try await evictionPass()
        probe.stop()
        await probing.value

        let stretches = probe.stretches
        let pages = times.all
        let peak = footprints.map(\.bytes).max() ?? first
        let growth = peak - first
        let tenth = footprints.first { $0.rows >= 10_000 }?.bytes ?? first
        let trend = (footprints.last?.bytes ?? first) - tenth
        print("[walk \(label)] walked \(walked) down, \(climbed) up in \(String(format: "%.0f s", elapsed)); \(pages.count) pages, \(await store.evictionPasses) passes of the letting go")
        print("[walk \(label)] footprint: " + footprints.map { "\($0.rows): \(Self.mb($0.bytes))" }.joined(separator: ", "))
        print("[walk \(label)] footprint growth after the first page \(Self.mb(growth)) (peak), from 10,000 rows to the end \(Self.mb(trend))")
        print("[walk \(label)] pool: max \(pools.max() ?? 0), median \(Int(Self.percentile(pools.map(Double.init), 0.5))), at the end \(await store.pooled)")
        print("[walk \(label)] main actor held: \(stretches.count) stretches over 0.1 ms, 95th \(Self.ms(Self.percentile(stretches, 0.95))), 99th \(Self.ms(Self.percentile(stretches, 0.99))), max \(Self.ms(stretches.max() ?? 0)); over 16 ms: \(stretches.filter { $0 >= 16 }.count)")
        print("[walk \(label)] drawing a step: 95th \(Self.ms(Self.percentile(drawings, 0.95))), max \(Self.ms(drawings.max() ?? 0))")
        print("[walk \(label)] the drawing worked out afresh: 95th \(Self.ms(Self.percentile(merges, 0.95))), max \(Self.ms(merges.max() ?? 0))")
        print("[walk \(label)] pages: median \(Self.ms(Self.percentile(pages, 0.5))), 95th \(Self.ms(Self.percentile(pages, 0.95))), max \(Self.ms(pages.max() ?? 0))")
        print("[walk \(label)] a pass of the letting go: \(evictions.count) timed, median \(Self.ms(Self.percentile(evictions, 0.5))), max \(Self.ms(evictions.max() ?? 0))")
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
