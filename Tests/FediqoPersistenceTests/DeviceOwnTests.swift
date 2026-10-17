import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #357: a save writes what changed, by row, in one transaction — so what is this device's
/// alone (#344), a post kept, a post let go, a source added or removed, is on disk with a
/// write the size of the change, whatever the store weighs.
@Suite("A save writes what changed, by row")
struct DeviceOwnTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)

    private static func note(_ id: Int, from source: Source) -> Note {
        Note(
            id: "https://\(source.host)/\(id)", source: source, author: "Ada", handle: "@ada", body: "post \(id)",
            postedAt: PackagerFixture.origin.addingTimeInterval(Double(id) * 60), categories: [.public], statusID: "\(id)"
        )
    }

    private static let notes = (1...4).map { note($0, from: alpha) } + (5...8).map { note($0, from: beta) }

    /// Lets one post go, as the person does by hand: the row is no longer held.
    private func letGo(_ note: Note, in store: ItemStore) async {
        let gone = await store.letGo(span: note.postedAt..<note.postedAt.addingTimeInterval(1), host: note.source.host)
        #expect(gone == 1, "the premise: it was let go")
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// What was asked of the disk, in order.
    private final class Record: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (said: [String](), rows: [RowChanges]()))
        func note(_ what: String) { state.withLock { $0.said.append(what) } }
        func rows(_ changes: RowChanges) { state.withLock { $0.rows.append(changes) } }
        var said: [String] { state.withLock { $0.said } }
        var rows: [RowChanges] { state.withLock { $0.rows } }
    }

    /// A store on disk holding `notes` from two sources, read as a launch reads it, and a
    /// saver on it that says what it was asked to write.
    private func launched(in dir: URL, _ record: Record) async throws -> (store: ItemStore, saver: StoreSaver, file: StoreFile) {
        do {
            let first = try StoreFile(at: dir)
            try await first.save(sources: [Self.alpha, Self.beta], notes: Self.notes)
            try first.db.close()
        }
        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        let store = ItemStore(sources: opened.sources, notes: opened.notes, readFromDisk: true)
        await store.hold(Unsent(host: Self.alpha.host, text: "words", audience: .everyone))
        await store.hold(NoticeReach(host: Self.alpha.host, before: "9", gathered: true))
        let saver = StoreSaver(
            store: store,
            write: { changes in
                record.rows(changes)
                try await file.save(changes)
                record.note("rows")
            },
            writeUnsent: { texts in
                record.note("words")
                try await file.save(unsent: texts)
            },
            writeNotices: { reaches in
                record.note("notices")
                try await file.save(notices: reaches)
            }
        )
        return (store, saver, file)
    }

    /// How many rows the file's own connection has inserted, changed or deleted so far.
    private func changesCount(_ file: StoreFile) async throws -> Int {
        try await file.db.read { $0.totalChangesCount }
    }

    private func rowid(_ key: NoteKey, in file: StoreFile) async throws -> Int64? {
        try await file.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE host = ? AND id = ?", arguments: [key.host, key.id])
        }
    }

    @Test("A save after one post changed writes that one row, and the row keeps its place; a post new to the file is one row too, added last")
    func oneChangeOneRow() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, saver, file) = try await launched(in: dir, Record())
        try await saver.save()
        let kept = Self.notes[2].key
        let place = try #require(try await rowid(kept, in: file))
        var before = try await changesCount(file)
        #expect(await store.setKept(true, for: kept))
        try await saver.save()
        #expect(try await changesCount(file) - before == 1, "more than the one row written for one post kept")
        #expect(try await rowid(kept, in: file) == place, "the row was written again somewhere else")

        before = try await changesCount(file)
        let arrived = Self.note(9, from: Self.alpha)
        await store.ingest([arrived])
        try await saver.save()
        #expect(try await changesCount(file) - before == 1)
        let last = try await file.db.read { try Int64.fetchOne($0, sql: "SELECT max(rowid) FROM note") }
        #expect(try await rowid(arrived.key, in: file) == last, "a post that arrived last is not the file's last row")

        before = try await changesCount(file)
        await letGo(Self.notes[0], in: store)
        try await saver.save()
        #expect(try await changesCount(file) - before == 1)
        // Nothing moved: nothing written at all.
        before = try await changesCount(file)
        try await saver.save()
        #expect(try await changesCount(file) == before)
    }

    @Test("A post kept, a post let go and a source removed are on disk after one save, written after the words and the notices — and survive the next launch")
    func theDevicesOwnOnDisk() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, file) = try await launched(in: dir, record)
        let kept = Self.notes[0].key
        #expect(await store.setKept(true, for: kept))
        #expect(await store.markGone(Self.notes[3].key))
        await letGo(Self.notes[1], in: store)
        await store.remove(host: Self.beta.host)
        #expect(await saver.finished())
        #expect(record.said == ["words", "notices", "rows"])
        try file.db.close()
        let whole = StoreFile.open(at: dir)
        #expect(whole.sources.map(\.host) == [Self.alpha.host], "the removed source is still on disk")
        #expect(whole.notes.map(\.id) == [Self.notes[0].id, Self.notes[2].id, Self.notes[3].id], "a post let go, or the removed source's, is still on disk — or the order the rows arrived in is not kept")
        #expect(whole.notes.first { $0.id == kept.id }?.kept == true, "the keep was not written")
        #expect(whole.notes.filter(\.kept).count == 1)
        #expect(whole.notes.first { $0.id == Self.notes[3].id }?.goneSince != nil, "the mark that the post is gone was not written")
    }

    @Test("Only what changed is in it, however it came about between two saves")
    func whatIsInIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, _) = try await launched(in: dir, record)
        // Kept and then let go between saves: a row gone, and no keep of a row that is not there.
        let first = Self.notes[0].key, second = Self.notes[1].key
        _ = await store.setKept(true, for: first)
        _ = await store.setKept(false, for: first)
        await letGo(Self.notes[0], in: store)
        // Kept, and still held.
        _ = await store.setKept(true, for: second)
        try await saver.save()
        try #require(record.rows.count == 1)
        #expect(record.rows[0].deletes == [first])
        #expect(record.rows[0].upserts.map(\.key) == [second] && record.rows[0].upserts[0].kept)
        #expect(record.rows[0].sources == nil && record.rows[0].removedHosts.isEmpty, "the sources written, none of them changed")
        // A source added; and one removed, its posts with it.
        let gamma = Source(host: "gamma.test", kind: .mastodon)
        await store.add(gamma)
        _ = await store.remove(host: Self.beta.host)
        try await saver.save()
        try #require(record.rows.count == 2)
        #expect(record.rows[1].removedHosts == [Self.beta.host])
        #expect(record.rows[1].sources?.map(\.host) == [Self.alpha.host, gamma.host])
        #expect(Set(record.rows[1].deletes) == Set(Self.notes[4...].map(\.key)), "its posts go with it")
        #expect(record.rows[1].upserts.isEmpty)
        // Added and removed between two saves: never on disk, so nothing to remove.
        let delta = Source(host: "delta.test", kind: .mastodon)
        await store.add(delta)
        _ = await store.remove(host: delta.host)
        try await saver.save()
        #expect(record.rows.count == 3 && record.rows[2].sources == nil)
        #expect(record.rows[2].removedHosts == [delta.host], "a removal is deleted whether or not the file held it")
    }

    @Test("A write that fails is still owed, whole — and a row changed again meanwhile is written as it stands then")
    func stillOwedAfterAFailure() async throws {
        struct Refused: Error {}
        let store = ItemStore(sources: [Self.alpha], notes: Array(Self.notes[..<4]), readFromDisk: true)
        let record = Record()
        let refusing = OSAllocatedUnfairLock(initialState: true)
        let saver = StoreSaver(store: store, write: { changes in
            record.rows(changes)
            if refusing.withLock({ $0 }) { throw Refused() }
        })
        _ = await store.setKept(true, for: Self.notes[0].key)
        await letGo(Self.notes[1], in: store)
        _ = await store.remove(host: Self.beta.host)
        await #expect(throws: Refused.self) { try await saver.save() }
        refusing.withLock { $0 = false }
        try await saver.resave()
        try #require(record.rows.count == 2)
        #expect(record.rows[0] == record.rows[1], "what a failed write did not land is owed again, the same")
        #expect(record.rows[0].deletes == [Self.notes[1].key] && record.rows[0].upserts.map(\.key) == [Self.notes[0].key])
        // Landed: owed no more.
        try await saver.resave()
        #expect(record.rows.count == 3 && record.rows[2].isEmpty)

        // Failed once more, and the kept post kept no longer before the next try: the newer word.
        refusing.withLock { $0 = true }
        _ = await store.setKept(true, for: Self.notes[2].key)
        await #expect(throws: Refused.self) { try await saver.save() }
        _ = await store.setKept(false, for: Self.notes[2].key)
        refusing.withLock { $0 = false }
        try await saver.save()
        #expect(record.rows.last?.upserts.map(\.kept) == [false])
    }

    @Test("A read back writes the package's rows through the file: the next save writes only the rows the store holds otherwise, and nothing of the store before it")
    func theIndexReplaced() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, file) = try await launched(in: dir, record)
        // Changed and never saved before the read back: the package's store replaces it.
        _ = await store.setKept(true, for: Self.notes[0].key)
        var theirs = (20...23).map { Self.note($0, from: Self.alpha) }
        theirs[1].refsDue = true
        try await file.save(sources: [Self.alpha], notes: theirs)
        await store.replace(sources: [Self.alpha], notes: theirs)
        try await saver.save()
        try #require(record.rows.count == 1)
        #expect(record.rows[0].upserts.map(\.key) == [theirs[1].key], "only the row the store holds otherwise — no longer owing a load")
        #expect(record.rows[0].upserts.first?.refsDue == false)
        #expect(record.rows[0].deletes.isEmpty)
        try file.db.close()
        #expect(Set(StoreFile.open(at: dir).notes.map(\.id)) == Set(theirs.map(\.id)))
        // Held to the source: the packager no longer tells the saver anything.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packager = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StorePackager.swift"), encoding: .utf8)
        #expect(!packager.contains("indexReplaced"))
    }

    @Test("A post let go and taken in again before a save is written where it now arrived, after every row before it")
    func letGoAndBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, saver, file) = try await launched(in: dir, Record())
        await letGo(Self.notes[0], in: store)
        await store.ingest([Self.notes[0]])
        try await saver.save()
        let last = try await file.db.read { try Int64.fetchOne($0, sql: "SELECT max(rowid) FROM note") }
        #expect(try await rowid(Self.notes[0].key, in: file) == last, "kept where it stood before it was let go")
        try file.db.close()
        #expect(StoreFile.open(at: dir).notes.last?.id == Self.notes[0].id)
    }

    @Test("A row the file holds that is no item — a host with no source row, and no kind — is deleted by the first save after the launch that skipped it")
    func skippedRowsGo() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let first = try StoreFile(at: dir)
            try await first.save(sources: [Self.alpha, Self.beta], notes: Self.notes)
            // Beta forgotten by a build before the kind was written on every row.
            try await first.db.write { db in
                try db.execute(sql: "DELETE FROM source WHERE host = ?", arguments: [Self.beta.host])
                try db.execute(sql: "UPDATE note SET facts = json_remove(facts, '$.kind') WHERE host = ?", arguments: [Self.beta.host])
            }
            try first.db.close()
        }
        let opened = StoreFile.open(at: dir)
        #expect(Set(opened.skipped) == Set(Self.notes[4...].map(\.key)))
        let store = ItemStore(sources: opened.sources, notes: opened.notes, readFromDisk: true, skipped: opened.skipped)
        let file = try #require(opened.file)
        try await StoreSaver(store: store, file: file).save()
        let left = try await file.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note WHERE host = ?", arguments: [Self.beta.host]) }
        #expect(left == 0, "a row nothing draws stays on disk")
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") } == 4)
    }

    /// The index undo of a read back, as `StorePackager.commitIndex` makes it, where a lock held
    /// it past a save: the file set aside, the package's store copied into it, a save landing
    /// into that, then the aside copied back (#360).
    @Test("An index undo done after a save landed into the package's store leaves nothing that save wrote off disk, and nothing let go on it")
    func anUndoAfterASave() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, saver, file) = try await launched(in: dir, Record())
        try await saver.save()
        let aside = dir.appendingPathComponent("undo-aside-test", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try await file.snapshot(into: aside)
        let hosts = try file.sourceHosts()
        let theirs = (20...23).map { Self.note($0, from: Self.alpha) }
        let package = scratch()
        defer { try? FileManager.default.removeItem(at: package) }
        let staged = try StoreFile(at: package)
        try await staged.save(sources: [Self.alpha], notes: theirs)
        try await file.copy(from: staged.db)
        #expect(try file.loadUnsent().map(\.text) == ["words"], "the texts waiting stay the file's")
        // Meanwhile, the session goes on and its save lands in the package's file.
        let arrived = Self.note(9, from: Self.alpha)
        #expect(await store.setKept(true, for: Self.notes[2].key))
        await store.ingest([arrived])
        await letGo(Self.notes[1], in: store)
        try await saver.save()
        // The undo, done at last; then the packager's own resave.
        await store.restoring()
        try await file.putBack(from: aside)
        await store.oweEverything(hosts: hosts, fileHolds: try file.noteKeys())
        try await saver.resave()
        try file.db.close()
        let whole = StoreFile.open(at: dir)
        let ids = Set(whole.notes.map(\.id))
        #expect(ids == Set((Self.notes.map(\.id) + [arrived.id]).filter { $0 != Self.notes[1].id }))
        #expect(whole.notes.first { $0.id == Self.notes[2].id }?.kept == true)
        #expect(whole.sources.map(\.host) == [Self.alpha.host, Self.beta.host])
        // Held to the source: the packager's undo owes the store again after writing it back.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packager = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StorePackager.swift"), encoding: .utf8)
        #expect(packager.contains("try await file.putBack(from: aside)\n                // Read before the aside goes"))
        #expect(packager.contains("await store.oweEverything(hosts: hosts, fileHolds: keys)"))
    }

    @Test("A save with nothing new takes nothing out of the store to find that out — and neither does leaving")
    @MainActor
    func nothingNewNothingTaken() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, saver, _) = try await launched(in: dir, Record())
        _ = await store.setKept(true, for: Self.notes[0].key)
        try await saver.save()
        let taken = await saver.takes
        #expect(taken == 1)
        try await saver.save()
        _ = await saver.finished()
        final class Grant: BackgroundGranting { func end() {} }
        await Leaving.leave(holding: Grant(), decide: {}, saver: saver, protected: .always, then: {})
        #expect(await saver.takes == taken, "the store asked for what changed with nothing changed")
    }

    @Test("A store made of rows the file may not hold owes every one of them: its first save writes them all")
    func madeOfRowsOwesThem() async throws {
        let store = ItemStore(sources: [Self.alpha], notes: Array(Self.notes[..<4]))
        let record = Record()
        let saver = StoreSaver(store: store, write: { record.rows($0) })
        try await saver.save()
        #expect(record.rows.first?.upserts.map(\.key) == Self.notes[..<4].map(\.key), "not every row, or not in the order they arrived")
        #expect(record.rows.first?.sources == [Self.alpha])
    }
}
