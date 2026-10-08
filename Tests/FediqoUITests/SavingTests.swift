import FediqoPersistence
import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Saving is asked for and not waited for (`ShellSaving`), and nothing is lost by that.
///
/// What a test can reach: an act returning while its save is still held, and a letting go that
/// does not; the file after a flush
/// made at once, as leaving the app makes one, with `saved()` never awaited; how many writes a
/// run of acts comes to; and a tail running only once its save has returned. What it cannot: the
/// app's own flush on a scene going to the background — that is `Launch.pause()`, outside the
/// package, and it calls the same `StoreSaver.flush` these do.
@MainActor
@Suite("A save is asked for and not waited for", .serialized)
struct SavingTests {
    private static let alpha = LimitRoom.alpha

    private static func notes(_ count: Int) -> [Note] {
        (0..<count).map { n in
            Note(
                id: "\(n)", source: alpha, author: "Ada", handle: "@ada@alpha.test", body: "hello \(n)",
                postedAt: LimitRoom.origin.addingTimeInterval(-Double(n) * 86_400), categories: [.public],
                statusID: "\(n)"
            )
        }
    }

    private static func shell(_ count: Int) async -> ShellSession {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [alpha], notes: notes(count)))
        await session.reloadFromStore()
        return session
    }

    private static func row(_ session: ShellSession, _ id: String) throws -> DummyItem {
        DummyItem(try #require(session.notes.first { $0.id == id }))
    }

    /// Counts writes from inside a `@Sendable` write, without a hop.
    private final class Writes: Sendable {
        private let count = Mutex(0)
        func next() -> Int { count.withLock { $0 += 1; return $0 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test("The press returns while its save is still being written, and the row already shows it")
    func theActDoesNotWait() async throws {
        let session = await Self.shell(2)
        let entered = Gate()
        let release = Gate()
        var saved = 0
        session.persist = {
            await entered.open()
            await release.wait()
            saved += 1
        }

        // Returning at all is the point: a press that awaited the save would never get here.
        #expect(await session.toggleKept(try Self.row(session, "1")) == true)
        await entered.wait()
        #expect(try Self.row(session, "1").kept)
        #expect(saved == 0, "the save had returned before the press did")

        await release.open()
        await session.saved()
        #expect(saved == 1)
    }

    @Test("Kept, and the app left at once: the flush finds it, and it is in the file, with no save waited for")
    func leftAtOnceNothingIsLost() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = await Self.shell(2)
        let file = try StoreFile(at: dir)
        let saver = StoreSaver(store: session.store, file: file)
        session.persist = { try? await saver.save() }

        await session.setKept(true, on: try Self.row(session, "1"))
        // What `Launch.pause()` and `Launch.end()` do, and nothing between the press and it.
        #expect(await saver.flush(deadline: .seconds(60)) == .saved)

        #expect(try file.load().notes.first { $0.id == "1" }?.kept == true)
        #expect(try file.load().notes.first { $0.id == "0" }?.kept == false)
    }

    @Test("Left while the save asked for is still held: the flush waits behind it and writes what the press made")
    func leftWhileASaveIsHeld() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = await Self.shell(2)
        let file = try StoreFile(at: dir)
        let entered = Gate()
        let release = Gate()
        let writes = Writes()
        let saver = StoreSaver(store: session.store) { sources, notes, said in
            if writes.next() == 1 {
                await entered.open()
                await release.wait()
            }
            try await file.save(sources: sources, notes: notes, said: said)
        }
        session.persist = { try? await saver.save() }

        await session.setKept(true, on: try Self.row(session, "0"))
        await entered.wait()
        // A second press, whose save cannot have started: the first is still being written.
        await session.setKept(true, on: try Self.row(session, "1"))
        let flush = Task { await saver.flush(deadline: .seconds(60)) }
        await release.open()

        #expect(await flush.value == .saved)
        #expect(try file.load().notes.map(\.kept) == [true, true])
    }

    @Test("A run of presses while one save is being written is one more write, not one each")
    func aRunOfActsIsFewWrites() async throws {
        let session = await Self.shell(12)
        let entered = Gate()
        let release = Gate()
        let writes = Writes()
        let saver = StoreSaver(store: session.store) { _, _, _ in
            if writes.next() == 1 {
                await entered.open()
                await release.wait()
            }
        }
        var asked = 0
        session.persist = {
            asked += 1
            try? await saver.save()
        }

        await session.setKept(true, on: try Self.row(session, "0"))
        await entered.wait()
        for id in 1..<12 { await session.setKept(true, on: try Self.row(session, "\(id)")) }
        await release.open()
        await session.saved()

        #expect(asked == 12, "a press did not ask for its save")
        #expect(writes.value == 2, "the store was written once a press")
        #expect(await session.store.snapshot().notes.allSatisfy(\.kept))
    }

    @Test("Let go by dates: the count is not said while the write that takes the posts off the disk is held")
    func aPurgeWaitsForItsWrite() async throws {
        let session = await Self.shell(4)
        let entered = Gate()
        let release = Gate()
        var saved = 0
        session.persist = {
            await entered.open()
            await release.wait()
            saved += 1
        }
        session.measureStore = { 1 }
        var said: Int?
        let span = LimitRoom.origin.addingTimeInterval(-86_400 * 2.5)..<LimitRoom.origin.addingTimeInterval(1)
        let press = Task {
            said = await session.letGo(span: span, host: nil)
        }
        await entered.wait()
        // The store has let them go and the write is held. Every turn there is to take: the
        // press cannot get past a save it waits for, and would have within one had it not.
        for _ in 0..<200 { await Task.yield() }
        #expect(await session.store.snapshot().notes.count == 1)
        #expect(said == nil, "the count was said while the file still held what went")

        await release.open()
        await press.value
        #expect(said == 3)
        #expect(saved == 1)
        await session.saved()
        #expect(session.storeBytes == 1, "and the file is measured once it is written")
    }

    @Test("What follows a save runs once it has returned, and each ask after the one before it")
    func theTailRunsAfterItsSave() async throws {
        let session = await Self.shell(1)
        var order: [String] = []
        session.persist = {
            order.append("save")
            await Task.yield()
            order.append("saved")
        }
        session.saveSoon { order.append("measured") }
        session.saveSoon()
        #expect(order.isEmpty, "asking for a save ran it")

        await session.saved()
        #expect(order == ["save", "saved", "measured", "save", "saved"])
    }
}
