import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// How long each letting go takes over a file the size people hold (#357, H2b). **Skipped
/// unless asked for**: `FEDIQO_BENCH=1` builds a store of 270,000 rows and times each read the
/// store makes of the file, and each act with the save behind it. Only timings and counts are
/// printed — nothing a row says.
@Suite("Letting go on a large store, timed", .serialized)
struct StoreLettingGoBenchTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let sources = ["one.example", "two.example", "three.example"].map { Source(host: $0, kind: .mastodon) }
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    private static func time<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let began = clock.now
        let value = try await work()
        print("[letting go] \(label): \(milliseconds(clock.now - began))")
        return value
    }

    /// 270,000 rows a minute apart over three sources: the first two read signed in (home, every
    /// row saying what the reader did), the third public and saying nothing; a reblog of an older
    /// row every tenth, a quote every thirtieth; one kept in a thousand, one gone in two hundred.
    private static func seed() -> [Note] {
        let words = String(repeating: "words of a post that is about as long as one is ", count: 12)
        return (0..<270_000).map { n in
            let source = sources[n % 3]
            let signed = n % 3 != 2
            var refs: [Reference] = []
            if n % 10 == 0, n + 3 < 270_000 {
                refs = [Reference(kind: .reblogs, id: "\(n + 3)")]
            } else if n % 30 == 1, n + 3 < 270_000 {
                refs = [Reference(kind: .quotes, id: "\(n + 3)", state: .accepted)]
            }
            return Note(
                id: "\(n)", source: source, author: "A", handle: "a\(n % 500)@\(source.host)", body: words,
                postedAt: start.addingTimeInterval(-Double(n) * 60), categories: signed ? [.home] : [.public],
                boosted: signed ? false : nil, favourited: signed ? n % 7 == 0 : nil, bookmarked: signed && n % 50 == 0 ? true : nil,
                goneSince: n % 200 == 0 ? start : nil, kept: n % 1000 == 0, refs: refs
            )
        }
    }

    @Test("270,000 rows: every read a letting go makes of the file, and every act with its save",
          .enabled(if: environment["FEDIQO_BENCH"] == "1"))
    func synthetic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await Self.time("270,000 rows written") { try await file.save(sources: Self.sources, notes: Self.seed()) }
        try await Self.time("indexes made") { try await file.makeIndexes() }
        print("[letting go] \(file.bytesOnDisk() / 1_000_000) MB")

        // The reads, alone.
        let rows = try await Self.time("rows counted") { try file.rowCount() }
        let day = Self.start.addingTimeInterval(-2 * 86_400)..<Self.start.addingTimeInterval(-86_400)
        let week = Self.start.addingTimeInterval(-14 * 86_400)..<Self.start.addingTimeInterval(-7 * 86_400)
        let ofHost = try await Self.time("keys of a host") { try file.keys(.host("three.example")) }
        let ofDay = try await Self.time("keys of a day") { try file.keys(.span(day, host: nil)) }
        let ofWeek = try await Self.time("keys of a week, one host") { try file.keys(.span(week, host: "one.example")) }
        let gone = try await Self.time("keys marked gone") { try file.keys(.gone(markedBy: nil)) }
        print("[letting go] \(rows) rows; host \(ofHost.count), day \(ofDay.count), week \(ofWeek.count), gone \(gone.count)")
        let oldest = try await Self.time("oldest 2,000") { try file.oldest(2_000, after: nil) }
        _ = try await Self.time("oldest 2,000 past a cursor") { try file.oldest(2_000, after: oldest.next) }
        let referring = try await Self.time("what refers to 2,000") { try file.referring(to: oldest.rows.map(\.note.key)) }
        print("[letting go] \(oldest.rows.count) oldest, \(referring.count) referring")
        let some = try await Self.time("marked, a signed host with marks") { try file.marked(.only("one.example")) }
        let none = try await Self.time("marked, a public host with none") { try file.marked(.only("three.example")) }
        let launch = try await Self.time("marked, every host but the signed ones (launch)") {
            try file.marked(.allBut(["one.example", "two.example"]))
        }
        let nobody = try await Self.time("marked, every host but all (none to scan)") {
            try file.marked(.allBut(Set(Self.sources.map(\.host))))
        }
        print("[letting go] marked: \(some) \(none) \(launch) \(nobody)")

        // The acts, each with the save behind it.
        let pool = ItemStore(sources: Self.sources, rows: file)
        func saved() async throws {
            let (changes, _) = await pool.takeChanges()
            try await Self.time("  saved \(changes.upserts.count) up, \(changes.deletes.count) down, \(changes.ops.count) ops") {
                try await file.save(changes)
            }
        }
        _ = try await Self.time("question: count going, a week") { await pool.countGoing(span: week) }
        let span = await Self.time("let go a day") { await pool.letGo(span: day) }
        try await saved()
        let wentGone = await Self.time("let gone go") { await pool.letGoneGo() }
        try await saved()
        let room = await Self.time("room: oldest 2,000") { await pool.letGoOldest(count: 2_000) }
        try await saved()
        let rounds = await Self.time("room: 12 rounds of 500, none saved between") {
            var went = 0
            for _ in 0..<12 { went += await pool.letGoOldest(count: 500).posts }
            return went
        }
        try await saved()
        var saving = Duration.zero
        let between = try await Self.time("room: 12 rounds of 500, each saved (as the limit runs)") {
            var went = 0
            for _ in 0..<12 {
                went += await pool.letGoOldest(count: 500).posts
                let clock = ContinuousClock()
                let began = clock.now
                try await file.save(await pool.takeChanges().changes)
                saving += clock.now - began
            }
            return went
        }
        print("[letting go]   of which saving: \(Self.milliseconds(saving)), \(between) went")
        _ = await Self.time("forget reader marks, one host") { await pool.forgetReaderMarks(host: "one.example") }
        try await saved()
        _ = await Self.time("stop keeping") { await pool.stopKeeping() }
        try await saved()
        _ = await Self.time("remove a host") { await pool.remove(host: "three.example") }
        try await saved()
        print("[letting go] went: day \(span), gone \(wentGone), room \(room.posts) + \(rounds); \(try file.rowCount()) rows left")
    }
}
