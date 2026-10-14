import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #344: as a phone is left, what was just done is written before the device can lock — the
/// save first and to its end, under a grant that outlives it.
@MainActor
@Suite("Leaving writes what was just done, before anything else and before the grant is given back")
struct LeavingTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)

    /// What happened, in the order it did.
    private final class Record: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [String]())
        func note(_ what: String) { state.withLock { $0.append(what) } }
        var all: [String] { state.withLock { $0 } }
    }

    private final class Grant: BackgroundGranting {
        let record: Record
        private(set) var ended = 0
        init(_ record: Record) { self.record = record }
        func end() {
            ended += 1
            record.note("grant given back")
        }
    }

    /// A write held shut by the check: it says when it has begun, and ends when let go — or,
    /// should the leaving end without ever reaching it, says that instead. Nothing here waits
    /// on what can no longer happen.
    private final class HeldWrite: Sendable {
        private struct State {
            var began = false
            var over = false
            var released = false
            var reached: [CheckedContinuation<Bool, Never>] = []
            var parked: [CheckedContinuation<Void, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Called by the write: begun, and parked until released.
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

        /// Whether the write began — answered as soon as it has, or as soon as the leaving is over.
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

        func leavingIsOver() {
            let waiting = state.withLock { state in
                state.over = true
                defer { state.reached = [] }
                return state.reached
            }
            waiting.forEach { $0.resume(returning: false) }
        }
    }

    private func store() async -> ItemStore {
        let store = ItemStore(sources: [Self.alpha], notes: [])
        await store.hold(Unsent(host: Self.alpha.host, text: "words", audience: .everyone))
        await store.hold(NoticeReach(host: Self.alpha.host, before: "9", gathered: true))
        return store
    }

    @Test("The save is first and waited for to its end: nothing else leaving does, and not the grant's going, happens while the write is still running")
    func theWriteIsHeld() async throws {
        let record = Record(), held = HeldWrite(), grant = Grant(record)
        let saver = StoreSaver(
            store: await store(),
            write: { _, _, _ in
                record.note("items begun")
                await held.hold()
                record.note("items written")
            },
            writeUnsent: { _ in record.note("words written") },
            writeNotices: { _ in record.note("notices written") }
        )
        // The clock stands still: however long a slow run holds the write, the ten seconds are
        // not what this check is about (`theRestIsSkipped` is).
        let began = ContinuousClock.now
        let leaving = Task { @MainActor in
            await Leaving.leave(
                holding: grant, decide: { record.note("decided what is saved") }, saver: saver, protected: .always,
                clock: { began }, then: { record.note("the rest of leaving") }
            )
            held.leavingIsOver()
        }
        try #require(await held.reached(), "leaving ended without the store's write ever beginning")
        // The write is running, and has been for as long as the check cares to hold it.
        #expect(record.all == ["decided what is saved", "words written", "notices written", "items begun"])
        #expect(grant.ended == 0, "the grant was given back under a write still running")
        held.release()
        await leaving.value
        #expect(record.all == [
            "decided what is saved", "words written", "notices written", "items begun", "items written",
            "the rest of leaving", "grant given back",
        ])
        #expect(grant.ended == 1)
    }

    @Test("The rest of leaving is skipped where the canary refuses, or the ten seconds are spent — and the canary is asked once at most")
    func theRestIsSkipped() async throws {
        func leave(canary: CanaryTurned, took: Duration) async -> (did: [String], ended: Int) {
            let record = Record(), grant = Grant(record)
            let saver = StoreSaver(store: await store(), write: { _, _, _ in record.note("saved") }, protected: canary.protected)
            let began = ContinuousClock.now
            var asked = 0
            await Leaving.leave(
                holding: grant, decide: {}, saver: saver, protected: canary.protected,
                clock: {
                    asked += 1
                    return asked == 1 ? began : began + took
                },
                then: { record.note("the rest of leaving") }
            )
            return (record.all, grant.ended)
        }
        let reading = CanaryTurned(.reads)
        #expect(await leave(canary: reading, took: .seconds(1)).did == ["saved", "the rest of leaving", "grant given back"])
        #expect(reading.looks == 1, "one probe on the way out: on a phone each is a file made and unlinked")
        let locked = CanaryTurned(.refused)
        let behindALock = await leave(canary: locked, took: .seconds(1))
        #expect(behindALock.did == ["saved", "grant given back"] && behindALock.ended == 1)
        #expect(locked.looks == 1)
        let slow = CanaryTurned(.reads)
        #expect(await leave(canary: slow, took: .seconds(11)).did == ["saved", "grant given back"])
        #expect(slow.looks == 0, "with the time spent there is nothing to ask it for")
        #expect(Leaving.bound == .seconds(10))
    }

    @Test("The rest of leaving is not done under an app the person came back to while the save ran")
    func cameBack() async throws {
        let record = Record(), grant = Grant(record)
        let canary = CanaryTurned(.reads)
        let saver = StoreSaver(store: await store(), write: { _, _, _ in record.note("saved") }, protected: canary.protected)
        await Leaving.leave(
            holding: grant, decide: {}, saver: saver, protected: canary.protected, stillLeft: { false },
            then: { record.note("the rest of leaving") }
        )
        #expect(record.all == ["saved", "grant given back"])
        #expect(canary.looks == 0, "nothing to ask the canary for")
        #expect(grant.ended == 1)
    }

    @Test("A save that fails as the app is left is owed and tried no other way; the grant is still given back, once")
    func theSaveFails() async throws {
        struct Refused: Error {}
        let record = Record(), grant = Grant(record)
        let canary = CanaryTurned(.refused)
        let saver = StoreSaver(
            store: await store(), write: { _, _, _ in
                record.note("items tried")
                throw Refused()
            },
            protected: canary.protected
        )
        await Leaving.leave(holding: grant, decide: {}, saver: saver, protected: canary.protected, then: { record.note("the rest of leaving") })
        #expect(record.all == ["items tried", "grant given back"], "one honest try, and nothing written anywhere else")
        #expect(grant.ended == 1)
        // Owed: written when the device is back.
        await saver.owedNow()
        #expect(await saver.isHeldForALock)
        #expect(await saver.finished() == false)
    }

    // MARK: - A write cut off

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("A write cut off mid-transaction leaves a journal, and the next launch rolls it back: the store as it was, and nothing taken for damage")
    func aWriteCutOff() async throws {
        let dir = scratch(), cut = scratch()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: cut)
        }
        let file = try StoreFile(at: dir)
        let notes = (1...400).map { id in
            Note(
                id: "https://alpha.test/\(id)", source: Self.alpha, author: "Ada", handle: "@ada",
                body: "held \(id) " + String(repeating: "and some more words. ", count: 40),
                postedAt: PackagerFixture.origin.addingTimeInterval(Double(id)), categories: [.public], statusID: "\(id)"
            )
        }
        try await file.save(sources: [Self.alpha], notes: notes)
        // A save's transaction, with the index and its journal copied as they stand partway —
        // what the disk holds where the process is stopped there — and then undone here.
        try await file.db.writeWithoutTransaction { db in
            // Next to no cache, so that the pages being rewritten are on disk, and the journal
            // that holds them as they were is too, before the transaction ends.
            try db.execute(sql: "PRAGMA cache_size = 5")
            try db.execute(sql: "PRAGMA cache_spill = 5")
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM source")
            try FileManager.default.copyItem(at: dir, to: cut)
            try db.execute(sql: "ROLLBACK")
        }
        let journal = cut.appendingPathComponent("index.sqlite-journal")
        try #require(FileManager.default.fileExists(atPath: journal.path), "the premise: a journal beside the index")
        try #require(try Data(contentsOf: journal).count > 4096, "the premise: with the pages as they were in it")
        // The copied index is not the index as it was: pages of it had been rewritten when it
        // was stopped, and only the journal still holds them as they were.
        try file.db.close()
        let whole = try Data(contentsOf: dir.appendingPathComponent("index.sqlite"))
        try #require(try Data(contentsOf: cut.appendingPathComponent("index.sqlite")) != whole, "the premise: the index itself was cut off mid-write")

        // The next launch, under the canary's rule: rolled back as it is opened, read whole.
        let opened = StoreFile.open(at: cut, protected: CanaryByHand(.reads).protected)
        #expect(opened.trouble == nil && opened.setAside == nil, "\(String(describing: opened.trouble))")
        #expect(opened.sources.map(\.host) == [Self.alpha.host])
        #expect(opened.notes.count == 400)
        #expect(!FileManager.default.fileExists(atPath: journal.path), "the journal is gone once it has been rolled back")
        // (Rolled back and then rebuilt by the open, so its bytes are not compared: what it holds is.)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cut.path).filter { $0.hasPrefix("index-unreadable") }.isEmpty)
    }

    // MARK: - The app

    @Test("On a phone the app leaves through this, under a grant taken as it is told; a Mac has no such step, and a quit still waits for its write")
    func theApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        // The phone: the grant first, then everything under it, in `Leaving`'s order.
        let taken = try #require(code.range(of: "let grant = BackgroundGrant()\n        Task { await launch.pause(holding: grant) }"))
        #expect(count("BackgroundGrant()") == 1 && count("launch.pause(holding: grant)") == 1)
        #expect(count("Launch.shared?.pause(") == 0, "through the run the window holds: a grant taken always has somebody to end it")
        let leave = try #require(code.range(of: """
            await Leaving.leave(
                        holding: grant, decide: { await forgetChangedReaders() }, saver: saver, protected: protected,
                        stillLeft: { UIApplication.shared.applicationState != .active },
                        then: { await forums.dropCache(within: StoreSaver.deadline) }
                    )
            """))
        #expect(leave.lowerBound < taken.lowerBound)
        #expect(count("Leaving.leave(") == 1 && count("grant.end()") == 0, "given back by the leaving, and nowhere else but the system's own notice")
        #expect(code.contains("private final class BackgroundGrant: BackgroundGranting {"))
        #expect(code.contains("beginBackgroundTask(withName: \"Save the index\") { [weak self] in\n            self?.end()"))
        // The Mac: what it always was, where a phase is delivered at all; and no grant.
        #expect(count("launch.pause()") == 1)
        let phone = try #require(code.range(of: "#if os(iOS)\n    func pause(holding grant: any BackgroundGranting) async {"))
        let mac = try #require(code.range(of: "#else\n    func pause() async {\n        await forgetChangedReaders()\n        _ = await saver.flush()"))
        #expect(phone.lowerBound < mac.lowerBound)
        // A quit: its write is waited for, to the deadline a quit has.
        #expect(code.contains("func end() async {\n        await forgetChangedReaders()\n        _ = await saver.flush()"))
        #expect(count("saver.flush()") == 2 && count("saver.finished()") == 0)
        // And the leaving itself waits for the save's end, not for a deadline: a check that
        // holds the write cannot tell the two apart without waiting out the deadline, so this
        // one line is held to the source.
        let leaving = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/Leaving.swift"), encoding: .utf8)
        #expect(leaving.contains("        await decide()\n        await saver.finished()\n        if stillLeft(), clock() - began < bound, protected.canary() != .refused { await then() }\n        grant.end()"))
        #expect(!leaving.contains("flush("))
        let saver = try String(contentsOf: root.appendingPathComponent("Sources/FediqoPersistence/StoreSaver.swift"), encoding: .utf8)
        #expect(saver.contains("public func finished() async -> Bool {\n        (try? await save()) != nil\n    }"))
    }
}
