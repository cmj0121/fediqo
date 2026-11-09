import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// U3: the sources' stamps and tombstones in the index (`v25-sync-stamps`, D3, D4, D8) — read at
/// `.zero` from an older store, written with the sources, held in bounds however the file holds
/// them, and carried by a Move whole, so a merge with the device it came from changes nothing.
@Suite("Source stamps in the index")
struct SyncStampStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "Three")])

    private static func stamp(_ ms: Int64, _ device: String) -> SyncStamp {
        SyncStamp(ms: ms, counter: 0, device: device)
    }

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-stamps-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A store from before stamps opens with every source at .zero and no tombstone")
    func olderStoreReadsZero() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.one, Self.two], notes: [])
        }
        // The index as the build before this one left it: no stamp columns, no tombstones.
        do {
            let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
            try await queue.write { db in
                try db.execute(sql: "DROP TABLE source_gone")
                for column in ["stamp_ms", "stamp_n", "stamp_by"] {
                    try db.execute(sql: "ALTER TABLE source DROP COLUMN \(column)")
                }
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v25-sync-stamps'")
            }
        }
        let read = try StoreFile(at: dir).loadSources()
        #expect(Set(read.sources.map(\.host)) == [Self.one.host, Self.two.host])
        #expect(read.sync.gone.isEmpty)
        #expect(read.sync.stamps.values.allSatisfy { $0 == .zero })
        #expect(StoreFile.latestMigration == "v25-sync-stamps")
    }

    @Test("Stamps and tombstones are written with the sources, and a stamp alone moving is written too")
    func writtenAndReadBack() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let store = ItemStore(sources: [], rows: file)
        await store.stamp(with: SyncClock(device: "here"))
        func save() async throws {
            let changes = await store.takeChanges().changes
            try await file.save(changes)
            await store.wrote(changes)
        }
        await store.add(Self.one)
        await store.add(Self.two)
        try await save()
        await store.remove(host: Self.one.host)
        try await save()
        #expect(try file.loadSources().sync == (await store.sourceSync()))
        #expect(try file.loadSources().sync.gone[Self.one.host]?.device == "here")

        // The same source again at a later stamp: no source changes, the stamp does.
        let later = Self.stamp(SyncStamp.latestMs - 1, "there")
        _ = await store.settle(arrived: [Self.two.host: Stamped(SyncSource(Self.two), at: later)])
        let changes = await store.takeChanges().changes
        #expect(changes.sources == nil)
        #expect(changes.sourceSync != nil)
        try await file.save(changes)
        #expect(try file.loadSources().sync.stamps[Self.two.host] == later)
    }

    @Test("A stamp the file holds out of bounds is read within them, and the clock goes on")
    func boundedOnRead() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.one], notes: [])
        }
        do {
            let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
            try await queue.write { db in
                try db.execute(sql: "UPDATE source SET stamp_ms = ?, stamp_n = -7, stamp_by = 'x'", arguments: [Int64.max])
                try db.execute(
                    sql: "INSERT INTO source_gone (host, stamp_ms, stamp_n, stamp_by) VALUES ('gone.example', -5, ?, 'y')",
                    arguments: [Int64.max]
                )
            }
        }
        let file = try StoreFile(at: dir)
        let sync = try file.loadSources().sync
        #expect(sync.stamps[Self.one.host] == SyncStamp(ms: SyncStamp.latestMs, counter: 0, device: "x"))
        #expect(sync.gone["gone.example"] == SyncStamp(ms: 0, counter: .max, device: "y"))
        let store = ItemStore(sources: [Self.one], sync: sync, rows: file)
        await store.stamp(with: SyncClock(device: "here"))
        await store.add(Self.two)
        #expect(try #require(await store.sourceSync().stamps[Self.two.host]) > SyncStamp(ms: SyncStamp.latestMs, counter: 0, device: "x"))
    }

    @Test("A Move into B carries A's stamps and tombstones whole: a merge with A then removes nothing on A", arguments: [false, true])
    func moveThenMerge(inPart: Bool) async throws {
        let aSync = SourceSync(
            stamps: [Self.one.host: Self.stamp(100, "a"), Self.two.host: Self.stamp(110, "a")],
            gone: ["left.example": Self.stamp(120, "a")]
        )
        let from = try await Device(sources: [Self.one, Self.two], sync: aSync, inPart: inPart)
        // B held sources of its own, and a removal newer than A's stamp for a source A keeps:
        // were that kept past the Move, the merge would remove it on A.
        let bSync = SourceSync(
            stamps: ["bee.example": Self.stamp(500, "b")],
            gone: [Self.one.host: Self.stamp(900, "b")]
        )
        let onto = try await Device(sources: [Source(host: "bee.example", kind: .mastodon)], sync: bSync, inPart: inPart)
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false, contents: .whole) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: true) { _ in }

        let a = SyncSnapshot(sources: await from.store.syncEntries())
        let b = SyncSnapshot(sources: await onto.store.syncEntries())
        #expect(b == a)
        let plan = SyncMerge.plan(local: b, remote: a)
        #expect(plan.there.isEmpty, "the merge changes A: \(plan.there.summary)")
        #expect(plan.here.isEmpty)
        // And as B's file holds them, written by the read back and by B's next save.
        let changes = await onto.store.takeChanges().changes
        let reopened = try StoreFile(at: onto.directory)
        try await reopened.save(changes)
        #expect(try reopened.loadSources().sync == aSync)
    }
}
