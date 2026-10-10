import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #344: what is this device's alone — a post kept, a post let go, a source added or removed —
/// is written ahead of the full save, in a transaction that stays small, so that it is on
/// disk whether or not the full save gets to its end before a lock or a quit.
@Suite("What is this device's alone is written first")
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
        private let state = OSAllocatedUnfairLock(initialState: (said: [String](), own: [OwnChanges]()))
        func note(_ what: String) { state.withLock { $0.said.append(what) } }
        func own(_ changes: OwnChanges) { state.withLock { $0.own.append(changes) } }
        var said: [String] { state.withLock { $0.said } }
        var own: [OwnChanges] { state.withLock { $0.own } }
    }

    /// The items write, held shut: it says when it has been reached, and ends when let go — or
    /// answers at once that the save ended without reaching it.
    private final class HeldItems: Sendable {
        private struct State {
            var began = false, over = false, released = false
            var reached: [CheckedContinuation<Bool, Never>] = []
            var parked: [CheckedContinuation<Void, Never>] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func hold() async {
            let waiting = state.withLock { state in
                state.began = true
                defer { state.reached = [] }
                return state.reached
            }
            waiting.forEach { $0.resume(returning: true) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let free = state.withLock { state in
                    if state.released { return true }
                    state.parked.append(continuation)
                    return false
                }
                if free { continuation.resume() }
            }
        }

        func reached() async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let known: Bool? = state.withLock { state in
                    if state.began { return true }
                    if state.over { return false }
                    state.reached.append(continuation)
                    return nil
                }
                if let known { continuation.resume(returning: known) }
            }
        }

        func release() {
            let parked = state.withLock { state in
                state.released = true
                defer { state.parked = [] }
                return state.parked
            }
            parked.forEach { $0.resume() }
        }

        func over() {
            let waiting = state.withLock { state in
                state.over = true
                defer { state.reached = [] }
                return state.reached
            }
            waiting.forEach { $0.resume(returning: false) }
        }
    }

    /// A store on disk holding `notes` from two sources, read as a launch reads it, and a
    /// saver on it whose items write the check holds.
    private func launched(in dir: URL, _ record: Record, _ held: HeldItems?) async throws -> (store: ItemStore, saver: StoreSaver, file: StoreFile) {
        do {
            let first = try StoreFile(at: dir)
            try await first.save(sources: [Self.alpha, Self.beta], notes: Self.notes)
            try first.db.close()
        }
        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        await store.hold(Unsent(host: Self.alpha.host, text: "words", audience: .everyone))
        await store.hold(NoticeReach(host: Self.alpha.host, before: "9", gathered: true))
        let saver = StoreSaver(
            store: store,
            write: { sources, notes, said in
                record.note("items begun")
                if let held { await held.hold() }
                try await file.save(sources: sources, notes: notes, said: said)
                record.note("items written")
            },
            writeUnsent: { texts in
                record.note("words")
                try await file.save(unsent: texts)
            },
            writeNotices: { reaches in
                record.note("notices")
                try await file.save(notices: reaches)
            },
            protected: .always, remake: nil,
            writeOwn: { changes in
                record.note("the device's own")
                record.own(changes)
                try await file.save(own: changes)
            },
            holding: (opened.sources, opened.notes)
        )
        return (store, saver, file)
    }

    @Test("With the full save held — or never finished — a post kept, a post let go and a source removed are already on disk, after the words and the notices")
    func onDiskBeforeTheItems() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record(), held = HeldItems()
        let (store, saver, _) = try await launched(in: dir, record, held)
        // What the person did a moment before leaving, or quitting.
        let kept = Self.notes[0].key
        #expect(await store.setKept(true, for: kept))
        await letGo(Self.notes[1], in: store)
        await store.remove(host: Self.beta.host)
        let saving = Task {
            _ = await saver.finished()
            held.over()
        }
        try #require(await held.reached(), "the save ended without the full write ever beginning")
        #expect(record.said == ["words", "notices", "the device's own", "items begun"])
        // The index as it is on disk, with the full save still not written: read by a
        // connection of its own, as the next launch would.
        let path = dir.appendingPathComponent("index.sqlite").path
        let disk = try DatabaseQueue(path: path, configuration: StoreFile.configuration(readOnly: true))
        let rows = try await disk.read { db in
            try Row.fetchAll(db, sql: "SELECT host, id, kept FROM note ORDER BY id").map { ($0["id"] as String, $0["kept"] as Bool) }
        }
        let hosts = try await disk.read { try String.fetchAll($0, sql: "SELECT host FROM source ORDER BY host") }
        #expect(hosts == [Self.alpha.host], "the removed source is still on disk, its token gone")
        #expect(rows.map(\.0) == [Self.notes[0].id, Self.notes[2].id, Self.notes[3].id], "the post let go, or the removed source's posts, are still on disk")
        #expect(rows.first { $0.0 == kept.id }?.1 == true, "the keep was not written")
        #expect(rows.filter(\.1).count == 1)
        try disk.close()
        // And when the full save does land it says the same, and nothing is written twice over.
        held.release()
        await saving.value
        #expect(record.said == ["words", "notices", "the device's own", "items begun", "items written"])
        let whole = StoreFile.open(at: dir)
        #expect(whole.sources.map(\.host) == [Self.alpha.host])
        #expect(Set(whole.notes.map(\.id)) == [Self.notes[0].id, Self.notes[2].id, Self.notes[3].id])
        #expect(whole.notes.first { $0.id == kept.id }?.kept == true)
    }

    @Test("Only what changed is in it, however it came about between two saves — and nothing where nothing of the device's own changed")
    func whatIsInIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, _) = try await launched(in: dir, record, nil)
        // Kept and then let go between saves: a row gone, and no keep of a row that is not there.
        let first = Self.notes[0].key, second = Self.notes[1].key, third = Self.notes[2]
        _ = await store.setKept(true, for: first)
        _ = await store.setKept(false, for: first)
        await letGo(Self.notes[0], in: store)
        // Let go, and back from its source before the save: a row still there.
        await letGo(third, in: store)
        await store.ingest([third])
        // Kept, and still held.
        _ = await store.setKept(true, for: second)
        try await saver.save()
        try #require(record.own.count == 1)
        #expect(record.own[0] == OwnChanges(gone: [first], kept: [.init(key: second, kept: true)]))
        // What the sources say, read again, is none of it: no small write, only the full one.
        await store.ingest([Self.note(9, from: Self.alpha)])
        try await saver.save()
        #expect(record.own.count == 1)
        // A source added, with what it follows; and one removed.
        let gamma = Source(host: "gamma.test", kind: .mastodon)
        await store.add(gamma)
        _ = await store.remove(host: Self.beta.host)
        try await saver.save()
        try #require(record.own.count == 2)
        #expect(record.own[1].removed == [Self.beta.host])
        #expect(record.own[1].sources.map(\.source.host) == [gamma.host])
        #expect(Set(record.own[1].gone) == Set(Self.notes[4...].map(\.key)), "its posts go with it")
        #expect(record.own[1].kept.isEmpty)
        // Nothing moved: nothing asked of the disk.
        let before = record.said
        try await saver.save()
        #expect(record.said == before)
        // A post that arrived since the launch, and was written by a full save, is a row like
        // any other: let go, it is in the small write too.
        let arrived = Self.note(9, from: Self.alpha)
        await letGo(arrived, in: store)
        try await saver.save()
        #expect(record.own.last == OwnChanges(gone: [arrived.key]))
    }

    @Test("A small write that fails is still owed, whole: the same set is written by the next save")
    func stillOwedAfterAFailure() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Refused: Error {}
        let opened: StoreFile.Opened
        do {
            let first = try StoreFile(at: dir)
            try await first.save(sources: [Self.alpha], notes: Array(Self.notes[..<4]))
            try first.db.close()
            opened = StoreFile.open(at: dir)
        }
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let record = Record()
        let refusing = OSAllocatedUnfairLock(initialState: true)
        let saver = StoreSaver(
            store: store,
            write: { _, _, _ in
                if refusing.withLock({ $0 }) { throw Refused() }
                record.note("items written")
            },
            writeUnsent: nil, writeNotices: nil, protected: .always, remake: nil,
            writeOwn: { changes in
                record.own(changes)
                if refusing.withLock({ $0 }) { throw Refused() }
            },
            holding: (opened.sources, opened.notes)
        )
        _ = await store.setKept(true, for: Self.notes[0].key)
        await letGo(Self.notes[1], in: store)
        await #expect(throws: Refused.self) { try await saver.save() }
        refusing.withLock { $0 = false }
        try await saver.resave()
        try #require(record.own.count == 2)
        #expect(record.own[0] == record.own[1], "what a failed write did not land is owed again, the same")
        #expect(record.own[0].gone == [Self.notes[1].key] && record.own[0].kept == [.init(key: Self.notes[0].key, kept: true)])
        // Landed: owed no more.
        try await saver.resave()
        #expect(record.own.count == 2)
    }

    @Test("What the small write landed is not written again when the full save after it fails: only what is still not on disk is owed")
    func landedThoughTheItemsDidNot() async throws {
        struct Refused: Error {}
        let store = ItemStore(sources: [Self.alpha], notes: Array(Self.notes[..<4]))
        let record = Record()
        let refusing = OSAllocatedUnfairLock(initialState: true)
        let saver = StoreSaver(
            store: store,
            write: { _, _, _ in
                if refusing.withLock({ $0 }) { throw Refused() }
                record.note("items written")
            },
            writeUnsent: nil, writeNotices: nil, protected: .always, remake: nil,
            writeOwn: { record.own($0) }, holding: ([Self.alpha], Array(Self.notes[..<4]))
        )
        _ = await store.setKept(true, for: Self.notes[0].key)
        await #expect(throws: Refused.self) { try await saver.save() }
        #expect(record.own == [OwnChanges(kept: [.init(key: Self.notes[0].key, kept: true)])])
        // The full save is tried again, cut off again: the keep is on disk already, and is not sent twice.
        await #expect(throws: Refused.self) { try await saver.resave() }
        #expect(record.own.count == 1)
        // Something more of the device's own meanwhile: that, and only that.
        await letGo(Self.notes[1], in: store)
        refusing.withLock { $0 = false }
        try await saver.save()
        #expect(record.own.count == 2 && record.own[1] == OwnChanges(gone: [Self.notes[1].key]))
    }

    @Test("An index replaced through the file, past the saver, is not set against what the saver knew: nothing is written ahead until a full save has said what it holds")
    func theIndexReplaced() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, _) = try await launched(in: dir, record, nil)
        // A read back: the package's store written through the file, and the store in memory replaced.
        await saver.indexReplaced()
        let theirs = (20...23).map { Self.note($0, from: Self.alpha) }
        await store.replace(sources: [Self.alpha], notes: theirs)
        try await saver.save()
        #expect(record.own.isEmpty, "every post of the old store sent to be deleted, one by one, ahead of the items")
        #expect(record.said.last == "items written")
        // From that full save on it is known again.
        await letGo(theirs[0], in: store)
        try await saver.save()
        #expect(record.own == [OwnChanges(gone: [theirs[0].key])])
        // Held to the source: the packager says so where it writes the index itself, and where it writes it back.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packager = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StorePackager.swift"), encoding: .utf8)
        #expect(packager.components(separatedBy: "await saver?.indexReplaced()").count - 1 == 2)
        #expect(packager.contains("replacingNotices: []\n            )\n            // Written through the file, past the saver"))
    }

    @Test("A save with nothing new copies nothing out of the store to find that out — and neither does leaving")
    @MainActor
    func nothingNewNothingCopied() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = Record()
        let (store, saver, _) = try await launched(in: dir, record, nil)
        _ = await store.setKept(true, for: Self.notes[0].key)
        try await saver.save()
        let taken = await saver.snapshots
        #expect(taken == 2, "once for what is the device's own, once for the items")
        try await saver.save()
        _ = await saver.finished()
        final class Grant: BackgroundGranting { func end() {} }
        await Leaving.leave(holding: Grant(), decide: {}, saver: saver, protected: .always, then: {})
        #expect(await saver.snapshots == taken, "the whole store copied to learn that nothing had changed")
    }

    @Test("Where nothing says what the index holds — a saver handed nothing a launch read — the first full save does, and the small write begins after it")
    func withoutWhatALaunchRead() async throws {
        let store = ItemStore(sources: [Self.alpha], notes: Array(Self.notes[..<4]))
        let record = Record()
        let saver = StoreSaver(
            store: store, write: { _, _, _ in record.note("items written") },
            writeUnsent: nil, writeNotices: nil, protected: .always, remake: nil,
            writeOwn: { record.own($0) }, holding: nil
        )
        _ = await store.setKept(true, for: Self.notes[0].key)
        try await saver.save()
        #expect(record.own.isEmpty && record.said == ["items written"], "written ahead on a guess at what the index held")
        _ = await store.setKept(true, for: Self.notes[1].key)
        try await saver.save()
        #expect(record.own == [OwnChanges(kept: [.init(key: Self.notes[1].key, kept: true)])])
    }
}
