import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence
@testable import FediqoUI

/// The months limit over a store read from its file a part at a time (#360, C32): kept in the
/// file a step at a time, each step written before the next, and one line in the limits' account
/// for the act, its steps summed.
@MainActor
@Suite("The months limit kept a step at a time", .serialized)
struct MonthsInPartsTests {
    private static let origin = LimitRoom.origin
    private static let alpha = LimitRoom.alpha
    private static let beta = LimitRoom.beta

    /// A session over the file in `dir`, holding `notes`, written by a saver as the app's is.
    private func session(at dir: URL, notes: [Note]) async throws -> (ShellSession, ItemStore, StoreFile, Saves) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.alpha, Self.beta], notes: notes)
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let store = ItemStore(sources: opened.sources, said: opened.said, rows: file)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        let saver = StoreSaver(store: store, file: file)
        let saves = Saves()
        session.persist = {
            saves.count += 1
            return (try? await saver.save()) != nil
        }
        session.limitStore = try LimitAccountFile(directory: dir)
        await session.loadLimitAccount()
        return (session, store, file, saves)
    }

    final class Saves: @unchecked Sendable {
        var count = 0
    }

    @Test("Over a file, the rows past the limit go a step at a time, each written, and the account says them once, summed")
    func stepsSummed() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = (0..<9).map { LimitRoom.note("old\($0)", daysAgo: 200 + Double($0), from: $0.isMultiple(of: 2) ? Self.alpha : Self.beta) }
        let recent = (0..<3).map { LimitRoom.note("new\($0)", daysAgo: Double($0), from: Self.alpha) }
        let (session, store, file, saves) = try await session(at: dir, notes: old + recent)
        // An old row read in and drawn: it goes all the same, and nothing drawn keeps it.
        _ = await store.notes([old[0].key])
        await store.hold([old[0].key], drawnAt: await store.drawn)

        #expect(await session.keep(months: 3, from: Self.origin, step: 2) == 9)
        await session.saved()
        #expect(saves.count == 4, "one save a step that let something go: the drawn row and two read, then two at a time")
        #expect(try file.rowCount() == 3)
        #expect(await store.note(old[0].key) == nil)
        #expect(!session.notes.contains { $0.id.hasPrefix("old") })
        #expect(session.keepFrom != nil)
        let act = try #require(session.limitAccount.first)
        #expect(session.limitAccount.count == 1)
        #expect(act.limit == .months && act.posts == 9 && act.sources == [Self.alpha.host, Self.beta.host])

        // Nothing more past the limit: nothing goes, and no line is written.
        #expect(await session.keep(months: 3, from: Self.origin, step: 2) == 0)
        #expect(session.limitAccount.count == 1)
    }

    /// Twenty posts of one source, one every thirty days back from the origin.
    private static func spaced() -> [Note] {
        (0..<20).map { LimitRoom.note("p\($0)", daysAgo: 30 * Double($0), from: alpha) }
    }

    @Test("A limit set again while one is stepping ends it: the newer limit decides what is cut and kept, and each run's line is true of what it let go")
    func newerLimitEndsTheOlder() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = Self.spaced()
        let (session, store, file, _) = try await session(at: dir, notes: notes)
        // Inside the shorter limit's first step, once it let a row go, the person keeps a year.
        var newer: Int?
        session.adopting = {
            guard newer == nil else { return }
            newer = -1
            newer = await session.keep(months: 12, from: Self.origin, step: 1)
        }
        let older = await session.keep(months: 1, from: Self.origin, step: 1)
        session.adopting = nil
        await session.saved()
        let year = try #require(KeepPolicy.cutoff(keepingMonths: 12, from: Self.origin, calendar: .current))
        #expect(await store.keepFrom == year)
        #expect(session.keepFrom == year)
        // The shorter limit's one step let the oldest go; the year's steps the rest past a year.
        #expect(older == 1)
        let pastAYear = notes.filter { $0.postedAt < year }.count
        #expect(newer == pastAYear - 1)
        #expect(try file.rowCount() == notes.count - pastAYear)
        // Two lines, newest first: the shorter run's own, written as it ended after the year's,
        // then the year's.
        #expect(session.limitAccount.map(\.posts) == [1, pastAYear - 1])
    }

    @Test("A run whose task is cancelled ends after the step in hand, written, and its line says what went")
    func cancelledRunEnds() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = Self.spaced()
        let (session, store, file, _) = try await session(at: dir, notes: notes)
        final class Box: @unchecked Sendable { var task: Task<(posts: Int, ended: Bool), Never>? }
        let box = Box()
        session.adopting = { box.task?.cancel() }
        let run = Task { await session.keepRun(months: 1, from: Self.origin, step: 1) }
        box.task = run
        let ran = await run.value
        session.adopting = nil
        await session.saved()
        #expect(ran.posts >= 1 && !ran.ended)
        #expect(try file.rowCount() == notes.count - ran.posts, "what the steps let go is written")
        #expect(session.limitAccount.map(\.posts) == [ran.posts])
        // The limit stays set: every page is still cut by it, and the next run finishes the rest.
        let month = try #require(KeepPolicy.cutoff(keepingMonths: 1, from: Self.origin, calendar: .current))
        #expect(await store.keepFrom == month)
        let rest = await session.keep(months: 1, from: Self.origin, step: 1)
        #expect(ran.posts + rest == notes.filter { $0.postedAt < month }.count)
    }
}
