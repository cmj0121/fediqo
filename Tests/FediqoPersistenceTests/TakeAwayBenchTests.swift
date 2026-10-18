import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #360, K7, timed: a take-away of a large store held in part, and the pages read beside it.
///
/// `FEDIQO_BENCH=1` builds a store of 270,000 synthetic rows; `FEDIQO_BENCH_STORE=<folder>` takes
/// a copy of the `index.sqlite` there made afresh by backup (`StorePagesBenchTests.freshCopy`),
/// the given one opened read only and never written. Prints how long the copy takes, how large
/// the package is, and how long each page read meanwhile waited. Counts and timings only —
/// nothing a row says.
@Suite("A take-away of a large store, timed", .serialized)
struct TakeAwayBenchTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    private static func p(_ share: Double, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    /// Pages of All read newest first and on down, one after another, until `stop` says so: how
    /// long each took.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var waits: [Double] = []

        func stop() { lock.withLock { stopped = true } }
        var isStopped: Bool { lock.withLock { stopped } }
        var all: [Double] { lock.withLock { waits } }
        func add(_ wait: Double) { lock.withLock { waits.append(wait) } }
    }

    private static func read(_ file: StoreFile, sources: [Source], into reader: Reader, count: Int? = nil) async throws {
        let definition = TimelineDefinition(name: "All", rules: [])
        let all = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
        var ask = PageAsk.newest
        var done = 0
        let clock = ContinuousClock()
        while !reader.isStopped, count.map({ done < $0 }) ?? true {
            let began = clock.now
            let page = try await file.page(all, ask)
            reader.add(milliseconds(clock.now - began))
            done += 1
            ask = page.next.map { .before($0) } ?? .newest
            if done % 20 == 0 { ask = .newest }
        }
    }

    private static func run(_ dir: URL, label: String) async throws {
        let file = try StoreFile(at: dir)
        try await file.makeIndexes()
        let (sources, said) = try file.loadSources()
        let rows = try await file.db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0 }
        let words = try await file.db.read(StoreFile.hasWords)
        print("[takeaway \(label)] \(rows) rows, \(file.bytesOnDisk() / 1_000_000) MB on disk, words index \(words ? "built" : "none")")
        let store = ItemStore(sources: sources, said: said, rows: file)
        let saver = StoreSaver(store: store, file: file)

        // Pages alone, for what the wait is beside.
        let alone = Reader()
        try await read(file, sources: sources, into: alone, count: 60)
        print(String(
            format: "[takeaway \(label)] page alone: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d pages)",
            p(0.5, alone.all), p(0.95, alone.all), alone.all.max() ?? 0, alone.all.count
        ))

        // The copy, with pages read beside it the whole time.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let beside = Reader()
        let reading = Task { try await read(file, sources: sources, into: beside) }
        let clock = ContinuousClock()
        let began = clock.now
        try await saver.afterSaving { try await file.snapshot(into: scratch) }
        let held = milliseconds(clock.now - began)
        let snapshotBytes = StoreFile.bytesOnDisk(indexAt: scratch.appendingPathComponent(StoreFile.indexName).path)
        let scrubbing = clock.now
        let copy = try await StoreFile.takenCopy(in: scratch)
        let scrubbed = milliseconds(clock.now - scrubbing)
        let copied = milliseconds(clock.now - began)
        beside.stop()
        try await reading.value
        let copyBytes = StoreFile.bytesOnDisk(indexAt: scratch.appendingPathComponent(StoreFile.indexName).path)
        print(String(
            format: "[takeaway \(label)] copy: %.0f ms (saves held %.0f ms for %d MB, then %.0f ms made into %d MB), %d posts, %d kept",
            copied, held, snapshotBytes / 1_000_000, scrubbed, copyBytes / 1_000_000, copy.posts, copy.kept
        ))
        print(String(
            format: "[takeaway \(label)] page during the copy: p50 %.1f ms, p95 %.1f ms, max %.1f ms (%d pages)",
            p(0.5, beside.all), p(0.95, beside.all), beside.all.max() ?? 0, beside.all.count
        ))

        // The whole take-away, sealed.
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let url = PackagerFixture.package()
        defer { device.remove(); try? FileManager.default.removeItem(at: url) }
        let packager = StorePackager(
            directory: dir, file: file, store: store, media: device.media, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a bench", appVersion: "0.7.0",
            saver: saver, rounds: 1000
        )
        let whole = clock.now
        try await packager.takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        let took = milliseconds(clock.now - whole)
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "[takeaway \(label)] whole take-away: %.0f ms, package %d MB", took, size / 1_000_000))
    }

    @Test("a take-away of 270,000 synthetic rows, pages read beside it",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        let notes = (0..<270_000).map { n in
            Note(
                id: "\(n)", source: sources[n % 3], author: "A", handle: "a\(n % 500)@one.example", body: words,
                postedAt: start.addingTimeInterval(-Double((n * 7_919) % 270_000) * 60),
                categories: n % 20 < 6 ? [.home] : [.public], kept: n % 1_000 == 0
            )
        }
        let file = try StoreFile(at: dir)
        try await file.save(sources: sources, notes: notes)
        if Self.environment["FEDIQO_BENCH_WORDS"] == "1" {
            try await file.buildWords(chunk: 2_000, capable: StoreFile.wordsCapable)
        }
        try await Self.run(dir, label: "synthetic")
    }

    @Test("a take-away of a fresh copy of a real store, pages read beside it",
          .enabled(if: environment["FEDIQO_BENCH_STORE"] != nil))
    func copied() async throws {
        let dir = try StorePagesBenchTests.freshCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.run(dir, label: "copy")
    }
}
