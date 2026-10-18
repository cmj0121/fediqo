import FediqoCore
@testable import FediqoPersistence
import Foundation
import GRDB
import Testing

/// #360, K4 (C31): the file's breakdown by week and month, read off the page index.
@Suite("The file counts its weeks and months")
struct StorePeriodsTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// `count` posts a day apart, newest first.
    private static func posts(_ count: Int) -> [Note] {
        (0..<count).map { n in
            Note(
                id: "p\(n)", source: source, author: "A", handle: "a@one.example", body: "b \(n)",
                postedAt: at.addingTimeInterval(-Double(n) * 86_400), categories: [.home]
            )
        }
    }

    private func seeded(_ notes: [Note]) async throws -> (StoreFile, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: notes)
        try await file.makeIndexes()
        return (file, dir)
    }

    @Test("A time held as a number or as bytes is no row of any period, and the count still ends")
    func timesNotText() async throws {
        let notes = Self.posts(40)
        let (file, dir) = try await seeded(notes)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await file.db.write { db in
            try db.execute(sql: "UPDATE note SET posted_at = 1790000000 WHERE id = 'p3'")
            try db.execute(sql: "UPDATE note SET posted_at = x'00ff' WHERE id = 'p7'")
            try db.execute(sql: "UPDATE note SET posted_at = 'no moment' WHERE id = 'p11'")
        }
        let texts = notes.filter { !["p3", "p7", "p11"].contains($0.id) }
        for period in HeldPeriod.allCases {
            let counted = try file.rowsByPeriod(period, calendar: .current)
            #expect(counted == Holdings(notes: texts, per: period).byPeriod)
            #expect(counted.map(\.posts).reduce(0, +) == texts.count)
        }
    }

    @Test("At most the newest periods asked for are counted")
    func most() async throws {
        let notes = Self.posts(120)
        let (file, dir) = try await seeded(notes)
        defer { try? FileManager.default.removeItem(at: dir) }
        let weeks = Holdings(notes: notes, per: .week).byPeriod
        #expect(weeks.count > 12)
        #expect(try file.rowsByPeriod(.week, calendar: .current, most: 12) == Array(weeks.prefix(12)))
        #expect(try file.rowsByPeriod(.week, calendar: .current, most: 0).isEmpty)
    }
}
