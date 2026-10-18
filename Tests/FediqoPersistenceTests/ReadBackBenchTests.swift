import Darwin
@testable import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #360, K8, measured: a read back of a large store into a run that has its file open, and the
/// pages read beside it.
///
/// `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows, takes it away, and reads it back
/// over a copy of itself; `FEDIQO_BENCH_STORE=<folder>` does the same with two copies of the
/// `index.sqlite` there, each made afresh by backup (`StorePagesBenchTests.freshCopy`), the given
/// one never written. Prints how long the read back takes, the most the heap held above what it
/// held as it began (`malloc_zone_statistics`, sampled as it runs), and how long each page read
/// meanwhile waited — and, for what it replaced, the same of the whole-store path, reconstructed.
/// Counts and timings only — nothing a row says.
@Suite("A read back of a large store, measured", .serialized)
struct ReadBackBenchTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let key = PackageKey.password("password")

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    private static func p(_ share: Double, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    /// The bytes the heap holds in use now.
    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The most the heap held while it ran, sampled every millisecond or so.
    private final class HeapPeak: Sendable {
        private let peak = OSAllocatedUnfairLock(initialState: 0)
        private let running = OSAllocatedUnfairLock(initialState: true)

        func start() -> Task<Void, Never> {
            Task.detached(priority: .high) { [self] in
                while running.withLock({ $0 }) {
                    let now = ReadBackBenchTests.heapInUse()
                    peak.withLock { $0 = max($0, now) }
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }

        func stop() { running.withLock { $0 = false } }
        var most: Int { peak.withLock { $0 } }
    }

    /// Pages of All read newest first and on down, one after another, until stopped: how long
    /// each took.
    private final class Reader: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (stopped: false, waits: [Double]()))
        func stop() { state.withLock { $0.stopped = true } }
        var isStopped: Bool { state.withLock { $0.stopped } }
        var all: [Double] { state.withLock { $0.waits } }
        func add(_ wait: Double) { state.withLock { $0.waits.append(wait) } }
    }

    private static func read(_ file: StoreFile, sources: [Source], into reader: Reader) async {
        let definition = TimelineDefinition(name: "All", rules: [])
        let all = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
        var ask = PageAsk.newest
        var done = 0
        let clock = ContinuousClock()
        while !reader.isStopped {
            let began = clock.now
            guard let page = try? await file.page(all, ask) else { continue }
            reader.add(milliseconds(clock.now - began))
            done += 1
            ask = page.next.map { .before($0) } ?? .newest
            if done % 20 == 0 { ask = .newest }
        }
    }

    /// A run over the file in `dir`, as a launch makes one: the store held in part, its saver,
    /// and a packager over both.
    private static func run(in dir: URL, device: PackagerFixture.PackagerDevice) async throws -> (StoreFile, ItemStore, StoreSaver, StorePackager) {
        let file = try StoreFile(at: dir)
        try await file.makePageIndex()
        try await file.makeIndexes()
        let (sources, said) = try file.loadSources()
        let store = ItemStore(sources: sources, said: said, rows: file)
        let saver = StoreSaver(store: store, file: file)
        let packager = StorePackager(
            directory: dir, file: file, store: store, media: device.media, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a bench", appVersion: "0.7.0",
            saver: saver, freeSpace: { _ in .max }, rounds: 1000
        )
        return (file, store, saver, packager)
    }

    /// `body` timed, the heap's most above where it began sampled meanwhile, and pages of
    /// `file` read beside it.
    private static func measured(
        _ label: String, _ what: String, file: StoreFile, sources: [Source], _ body: () async throws -> Void
    ) async throws -> Int {
        _ = malloc_zone_pressure_relief(nil, 0)
        let start = heapInUse()
        let peak = HeapPeak()
        let sampling = peak.start()
        let beside = Reader()
        let reading = Task.detached { await read(file, sources: sources, into: beside) }
        let clock = ContinuousClock()
        let began = clock.now
        try await body()
        let took = milliseconds(clock.now - began)
        beside.stop()
        await reading.value
        peak.stop()
        await sampling.value
        let over = max(0, peak.most - start)
        print(String(
            format: "[readback \(label)] \(what): %.0f ms, heap at most %@ over the start (%@ at the start)",
            took, mb(over), mb(start)
        ))
        print(String(
            format: "[readback \(label)] \(what), pages beside: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d pages)",
            p(0.5, beside.all), p(0.95, beside.all), beside.all.max() ?? 0, beside.all.count
        ))
        return over
    }

    private static func bench(from fromDir: URL, onto ontoDir: URL, old oldDir: URL, label: String) async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let url = PackagerFixture.package()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            device.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: staging)
        }
        do {
            let (file, _, _, packager) = try await run(in: fromDir, device: device)
            let rows = try file.rowCount()
            print("[readback \(label)] \(rows) rows, \(file.bytesOnDisk() / 1_000_000) MB on disk")
            try await packager.takeAway(to: url, key: key, pictures: false) { _ in }
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("[readback \(label)] package \(size / 1_000_000) MB")
            try file.db.close()
        }

        // The read back as it is now: the file copied in, page by page.
        let (file, store, saver, packager) = try await run(in: ontoDir, device: device)
        let sources = await store.sources()
        let over = try await measured(label, "read back, the file copied in", file: file, sources: sources) {
            try await packager.readBack(url, key: key, replacing: true) { _ in }
            try await saver.save()
        }
        print("[readback \(label)] after: \(try file.rowCount()) rows, \(await store.pooled) pooled")
        try file.db.close()

        // The whole-store path it replaced, for what that was: the staged file read whole,
        // written over the open file, and laid into the store.
        if environment["FEDIQO_BENCH_OLD"] == "1" {
            let (oldFile, oldStore, oldSaver, _) = try await run(in: oldDir, device: device)
            let run = ReadBackOpenFileTests.Run(store: oldStore, saver: oldSaver, file: oldFile, packager: packager)
            _ = try await measured(label, "read back, the whole-store path", file: oldFile, sources: sources) {
                try await ReadBackOpenFileTests.readBackWhole(url, onto: run, in: staging)
            }
            try oldFile.db.close()
        }
        #expect(over < 64 * 1_048_576, "the heap held more than 64 MB over the start")
    }

    @Test("a read back of 270,000 synthetic rows over a copy of them, pages read beside it",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (from, onto, old) = (root.appendingPathComponent("from"), root.appendingPathComponent("onto"), root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        do {
            let file = try StoreFile(at: from)
            try await file.save(sources: sources, notes: [])
            for part in 0..<10 {
                let notes = (part * 27_000..<(part + 1) * 27_000).map { n in
                    Note(
                        id: "\(n)", source: sources[n % 3], author: "A", handle: "a\(n % 500)@one.example", body: words,
                        postedAt: start.addingTimeInterval(-Double((n * 7_919) % 270_000) * 60),
                        categories: n % 20 < 6 ? [.home] : [.public], kept: n % 1_000 == 0
                    )
                }
                try await file.save(RowChanges(upserts: notes))
            }
            try file.db.close()
        }
        for copy in [onto, old] {
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: from.appendingPathComponent(StoreFile.indexName), to: copy.appendingPathComponent(StoreFile.indexName)
            )
        }
        try await Self.bench(from: from, onto: onto, old: old, label: "synthetic")
    }

    @Test("a read back of a fresh copy of a real store over another, pages read beside it",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let from = try StorePagesBenchTests.freshCopy()
        let onto = try StorePagesBenchTests.freshCopy()
        let old = try StorePagesBenchTests.freshCopy()
        defer { for dir in [from, onto, old] { try? FileManager.default.removeItem(at: dir) } }
        try await Self.bench(from: from, onto: onto, old: old, label: "copy")
    }
}
