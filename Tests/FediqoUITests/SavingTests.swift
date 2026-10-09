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
            return true
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
        session.persist = { (try? await saver.save()) != nil }

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
        session.persist = { (try? await saver.save()) != nil }

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
            return true
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
            return true
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

    // MARK: - A write that did not land

    private static let notOff = "Posts you let go could not be taken off this device yet. It will be tried again."

    @Test("A letting go whose write did not land is not passed over: the strip says once, aloud, that it could not be taken off this device yet and will be tried again — not again for the same thing — and a save that lands takes the line down")
    func aWriteThatDidNotLandIsSaid() async throws {
        L10n.language = .english
        let session = await Self.shell(6)
        var heard: [String] = []
        session.said.announce = { heard.append($0) }
        var lands = false
        session.persist = { lands }
        func span(_ days: Double) -> Range<Date> {
            LimitRoom.origin.addingTimeInterval(-86_400 * days)..<LimitRoom.origin.addingTimeInterval(-86_400 * (days - 1))
        }

        #expect(await session.letGo(span: span(5.5), host: nil) == 1)
        let line = try #require(session.said.lines.first)
        #expect(session.said.lines.count == 1 && line.what == .unwritten(.posts) && line.host.isEmpty)
        #expect(line.words(language: .english) == Self.notOff)
        #expect(heard == [Self.notOff])

        // The same thing again: one line, where it stood, and nothing said a second time.
        session.said.say(Said(.act(.boost, row: "r"), .refused, host: "alpha.test"))
        #expect(await session.letGo(span: span(4.5), host: nil) == 1)
        #expect(session.said.lines.map(\.id) == [Said.id(.act(.boost, row: "r"), host: "alpha.test"), line.id])
        #expect(heard.count(where: { $0 == Self.notOff }) == 1, "told twice of the same thing")

        // Another thing is another line; a source leaving takes neither, as neither is a source's.
        #expect(await !session.saveNow(.notice))
        session.said.forget(host: "alpha.test")
        #expect(session.said.lines.map(\.what) == [.unwritten(.notice), .unwritten(.posts)])

        // A save that lands, asked for by anything at all: both are off the device, and neither is said.
        lands = true
        session.saveSoon()
        await session.saved()
        #expect(session.said.lines.isEmpty)
        #expect(await session.saveNow(.posts) && session.said.lines.isEmpty)
    }

    @Test("Each way of asking for something to be gone from this device says its own thing where the write did not land: the months kept, a source cleared, a source removed",
          arguments: ["months", "clear", "remove"])
    func eachLettingGoSaysWhat(_ way: String) async throws {
        let session = await Self.shell(4)
        session.said.announce = { _ in }
        session.persist = { false }
        switch way {
        case "months":
            await session.store.ingest([Self.old])
            #expect(await session.keep(months: 1, from: LimitRoom.origin) == 1)
            #expect(session.said.lines.map(\.what) == [.unwritten(.posts)])
        case "clear":
            await session.clear(host: Self.alpha.host)
            #expect(session.said.lines.map(\.what) == [.unwritten(.cleared)])
        default:
            await session.remove(host: Self.alpha.host)
            #expect(session.said.lines.map(\.what) == [.unwritten(.source)], "said as two things, or as a Clear")
        }
    }

    private static let old = Note(
        id: "old", source: alpha, author: "Ada", handle: "@ada@alpha.test", body: "long ago",
        postedAt: LimitRoom.origin.addingTimeInterval(-86_400 * 400), categories: [.public], statusID: "old"
    )

    @Test("Everything that can be said not to be off this device yet has words of its own in each language, and none names a source")
    func theWordsOfAWriteThatDidNotLand() {
        let english = Set(Said.Unwritten.allCases.map { Said(.unwritten($0), .unreachable, host: "").words(language: .english) })
        #expect(english.count == Said.Unwritten.allCases.count)
        for gone in Said.Unwritten.allCases {
            let key = "said.unwritten.\(gone.rawValue)"
            for language in DummyLanguage.allCases {
                let words = L10n.t(key, language: language)
                #expect(words != key && !words.contains("%"), "\(key) has no words in \(language)")
            }
            #expect(L10n.t(key, language: .english) != L10n.t(key, language: .taiwanese))
        }
        #expect(Said(.unwritten(.post), .unreachable, host: "").words(language: .taiwanese) == "你收回的貼文還沒辦法從這個裝置上清掉。之後會再試一次。")
        #expect(Said(.unwritten(.cleared), .unreachable, host: "").words(language: .english)
            == "What you cleared could not be taken off this device yet. It will be tried again.")
    }

    @Test("What was said not to be off this device yet is taken down by a save this session never asked for: the saver tells every session when a save lands after one failed")
    func aSaveMadeElsewhereTakesTheLineDown() async throws {
        let session = await Self.shell(4)
        session.said.announce = { _ in }
        let failing = Mutex(true)
        let saver = StoreSaver(store: session.store) { _, _, _ in
            if failing.withLock({ $0 }) { throw CancellationError() }
        }
        session.persist = { (try? await saver.save()) != nil }
        // Held until the session is listening, so the landing below cannot come before it.
        let listening = Gate()
        let watchdog = hangGuard(listening)
        defer { watchdog.cancel() }
        session.savesLanded = {
            let landings = await saver.landings()
            await listening.open()
            return landings
        }
        let following = Task { await session.followSaves() }
        defer { following.cancel() }
        await listening.wait()

        let span = LimitRoom.origin.addingTimeInterval(-86_400 * 2.5)..<LimitRoom.origin.addingTimeInterval(1)
        #expect(await session.letGo(span: span, host: nil) == 3)
        #expect(session.said.lines.map(\.what) == [.unwritten(.posts)])
        #expect(SpanSection.unwritten(in: session))
        #expect(SpanSection.wentLine(3, offDevice: false, language: .english) == Self.notOff, "the count was said as done")
        #expect(SpanSection.wentLine(3, offDevice: false, language: .taiwanese) == "你放下的貼文還沒辦法從這個裝置上清掉。之後會再試一次。")
        #expect(SpanSection.wentLine(3, language: .english) == "3 posts let go.")

        // The disk is back, and the save that lands is the saver's own or another window's: not this session's.
        failing.withLock { $0 = false }
        try await saver.save()
        #expect(await spun { session.said.lines.isEmpty }, "the line still says what a landed save made untrue")
        #expect(!SpanSection.unwritten(in: session))
    }

    // MARK: - Remove and Clear wait for their write

    @Test("Removing a source that said nothing of the person waits for its write all the same: its posts are off the store and the write is asked for before anything else of the Remove goes on, and Remove is not done while it is held")
    func aRemoveWaitsForItsWrite() async throws {
        let session = await Self.shell(3)
        let entered = Gate()
        let watchdog = hangGuard(entered)
        defer { watchdog.cancel() }
        let release = Gate()
        let clearedBefore = session.cleared
        var seen: [(sources: Int, cleared: Int)] = []
        session.persist = {
            seen.append((await session.store.sources().count, session.cleared))
            await entered.open()
            await release.wait()
            return true
        }
        var done = false
        let press = Task {
            await session.remove(host: Self.alpha.host)
            done = true
        }
        await entered.wait()
        for _ in 0..<200 { await Task.yield() }
        #expect(seen.count == 1 && seen.first?.sources == 0, "the write was asked for before the store let the source go")
        #expect(seen.first?.cleared == clearedBefore, "the first write waited for is the Clear's, after the rest had gone on")
        #expect(!done, "Remove said it was done while the file still held the source's posts")

        await release.open()
        await press.value
        #expect(done && seen.count == 2, "and what the Clear inside it let go is waited for too")
    }

    @Test("A Clear waits for its write: it is not done while the write is held")
    func aClearWaitsForItsWrite() async throws {
        let session = await Self.shell(3)
        let entered = Gate()
        let watchdog = hangGuard(entered)
        defer { watchdog.cancel() }
        let release = Gate()
        var saves = 0
        session.persist = {
            saves += 1
            await entered.open()
            await release.wait()
            return true
        }
        var done = false
        let press = Task {
            await session.clear(host: Self.alpha.host)
            done = true
        }
        await entered.wait()
        for _ in 0..<200 { await Task.yield() }
        #expect(!done && saves == 1, "Clear said it was done before its write returned")

        await release.open()
        await press.value
        #expect(done && saves == 1)
    }

    // MARK: - A store read back

    @Test("A store read back leaves no mark and no line about what the one before it held: a press that had not arrived, and what the strip said, are let go as a Clear lets them go")
    func aReadBackResetsWhatWasSaid() async throws {
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: [Self.alpha], notes: Self.notes(2)),
            pictures: ShellPictures(http: FixtureHTTP()), emojis: EmojiCache(http: FixtureHTTP())
        )
        session.work = SourceWork()
        session.said.announce = { _ in }
        await session.reloadFromStore()
        let row = try Self.row(session, "0")
        #expect(session.acts.begin(row.id, .boost))
        session.acts.failed(row.id, .boost)
        session.said.say(Said(.act(.boost, row: row.id), .unreachable, host: Self.alpha.host))
        session.persist = { false }
        #expect(await !session.saveNow(.posts))
        #expect(session.acts.standing(of: row.id, .boost) == .failed && session.said.lines.count == 2)

        // The store replaced whole, as a read back replaces it, and then adopted.
        await session.store.replace(sources: [Self.alpha], notes: [])
        let name = "read-back-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        await session.adoptReadBack(prefs: DummyPrefs(defaults: try #require(UserDefaults(suiteName: name))))

        #expect(session.notes.isEmpty)
        #expect(session.acts.standings.isEmpty, "a mark stands on a row the store no longer holds")
        #expect(session.said.lines.isEmpty, "a line stands about a row the store no longer holds")
    }

    @Test("What follows a save runs once it has returned, and each ask after the one before it")
    func theTailRunsAfterItsSave() async throws {
        let session = await Self.shell(1)
        var order: [String] = []
        session.persist = {
            order.append("save")
            await Task.yield()
            order.append("saved")
            return true
        }
        session.saveSoon { order.append("measured") }
        session.saveSoon()
        #expect(order.isEmpty, "asking for a save ran it")

        await session.saved()
        #expect(order == ["save", "saved", "measured", "save", "saved"])
    }
}
