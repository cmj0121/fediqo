import Foundation
import Testing

@testable import FediqoCore

/// A place posts may be missing reads down when reached, and says so for good where the source
/// has nothing (#204).
@Suite("A place posts may be missing reads down from it")
struct ReadDownTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    private static func note(_ id: Int, _ category: FediqoCore.Category = .public) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60),
            categories: [category], statusID: "\(id)", listed: [category: "\(id)"]
        )
    }

    private static func key(_ id: Int) -> NoteKey { note(id).key }

    private static let missing = TimelineGap(.mayBeMissing, in: .public)

    /// A store holding `ids` of the public timeline, with posts that may be missing below `marked`.
    private func store(holding ids: some Sequence<Int>, markedAt marked: Int) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(ids.map { Self.note($0) })
        await store.land(ReadOn(missingBelow: Self.key(marked)), of: .public, ifSourceHere: Self.host)
        return store
    }

    private func readDown(_ store: ItemStore, from server: TimelineServer, at marked: Int,
                          moment: Date = Date()) async throws -> ReadDown {
        let place = try #require(await store.missing(below: Self.key(marked), in: .public))
        let down = try await MastodonClient(http: server, host: Self.host)
            .publicTimeline(source: Self.source, readingDownFrom: place)
        await store.land(down, below: Self.key(marked), of: .public, at: moment, ifSourceHere: Self.host)
        return down
    }

    private func held(_ store: ItemStore) async -> [Int] {
        await store.all().compactMap { $0.statusID.flatMap(Int.init) }.sorted()
    }

    private func marked(_ store: ItemStore) async -> [Int: Set<TimelineGap>] {
        Dictionary(uniqueKeysWithValues: await store.all().filter { !$0.gaps.isEmpty }.map {
            (Int($0.statusID!)!, $0.gaps)
        })
    }

    @Test("A place the source can still fill is filled in order, with no row twice, and the mark goes")
    func filled() async throws {
        let server = TimelineServer(1...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let down = try await readDown(store, from: server, at: 31)
        #expect(await server.cursors == ["max_id=31"], "one stretch reached what was held")
        #expect(down.end == .met)
        #expect(await held(store) == Array(1...60), "every one, once each")
        #expect(await marked(store).isEmpty, "the mark went")
    }

    @Test("It meets an id at or below what is held even where that post itself is gone from the source")
    func meetsByID() async throws {
        let server = TimelineServer(Array(1...9) + Array(11...60))
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let down = try await readDown(store, from: server, at: 31)
        #expect(down.end == .met)
        #expect(await marked(store).isEmpty)
    }

    @Test("The bound reached first moves the mark down to the oldest post read; reaching it again goes on")
    func boundMovesDown() async throws {
        let server = TimelineServer(1...500)
        let store = await store(holding: Array(1...10) + Array(450...500), markedAt: 450)
        let down = try await readDown(store, from: server, at: 450)
        #expect(down.end == .further(below: Self.key(250)))
        #expect(await server.cursors == ["max_id=450", "max_id=410", "max_id=370", "max_id=330", "max_id=290"])
        #expect(await held(store) == Array(1...10) + Array(250...500))
        #expect(await marked(store) == [250: [Self.missing]], "still may be missing, lower down")

        _ = try await readDown(store, from: server, at: 250)
        _ = try await readDown(store, from: server, at: 50)
        #expect(await held(store) == Array(1...500), "no hole, no row twice")
        #expect(await marked(store).isEmpty)
    }

    @Test("A source with nothing more settles the place, as of the moment it said so")
    func settles() async throws {
        let server = TimelineServer(31...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let moment = Date(timeIntervalSince1970: 1_750_000_000)
        let down = try await readDown(store, from: server, at: 31, moment: moment)
        #expect(down.end == .settled(below: nil))
        #expect(await marked(store) == [31: [TimelineGap(.settled, in: .public, since: moment)]])
        #expect(await store.missing(below: Self.key(31), in: .public) == nil, "a settled place asks nothing")
    }

    @Test("A source that runs out partway settles the place below the oldest post it gave")
    func settlesLower() async throws {
        let server = TimelineServer(20...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let down = try await readDown(store, from: server, at: 31)
        #expect(down.end == .settled(below: Self.key(20)))
        #expect(await held(store) == Array(1...10) + Array(20...60))
        #expect(await marked(store)[20]?.first?.kind == .settled)
        #expect(await marked(store)[31] == nil)
    }

    @Test("A first stretch that fails leaves the mark as it was, and trying again fills it")
    func failedThenAgain() async throws {
        let server = TimelineServer(1...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        await server.fail(ask: 1)
        await #expect(throws: URLError.self) { try await readDown(store, from: server, at: 31) }
        #expect(await marked(store) == [31: [Self.missing]])
        #expect(await held(store) == Array(1...10) + Array(31...60))

        _ = try await readDown(store, from: server, at: 31)
        #expect(await held(store) == Array(1...60))
        #expect(await marked(store).isEmpty)
    }

    @Test("A stretch that fails after the first lands what came, and the mark moves down to it")
    func failedLater() async throws {
        let server = TimelineServer(1...500)
        let store = await store(holding: Array(1...10) + Array(450...500), markedAt: 450)
        await server.fail(ask: 2)
        let down = try await readDown(store, from: server, at: 450)
        #expect(down.stopped != nil)
        #expect(await marked(store) == [410: [Self.missing]])
    }

    @Test("With nothing held below the mark there is no hole: nothing is asked, and the mark goes")
    func nothingBelow() async throws {
        let server = TimelineServer(1...60)
        let store = await store(holding: 31...60, markedAt: 31)
        _ = try await readDown(store, from: server, at: 31)
        #expect(await server.asked.isEmpty)
        #expect(await marked(store).isEmpty)
    }

    @Test("Home read as you reads down the same way")
    func home() async throws {
        let server = TimelineServer(1...60)
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((Array(1...10) + Array(31...60)).map { Self.note($0, .home) })
        await store.land(ReadOn(missingBelow: Self.key(31)), of: .home, ifSourceHere: Self.host)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        try await MastodonAccount(door: door, store: store).readDown(.home, below: Self.key(31))
        #expect(await server.cursors == ["max_id=31"])
        #expect(await server.asked.allSatisfy { $0.path == "/api/v1/timelines/home" })
        #expect(await held(store) == Array(1...60))
        #expect(await marked(store).isEmpty)
    }

    @Test("Settled places are counted, and let go by the wait and the press; the post they sit by stays")
    func lettingSettledGo() async {
        let store = ItemStore()
        await store.add(Self.source)
        let origin = Date(timeIntervalSince1970: 1_750_000_000)
        var early = Self.note(1)
        early.gaps = [TimelineGap(.settled, in: .public, since: origin)]
        var late = Self.note(2)
        late.gaps = [TimelineGap(.settled, in: .public, since: origin.addingTimeInterval(86_400 * 3)),
                     Self.missing]
        await store.ingest([early, late])
        #expect(await store.settledCount() == 2)
        #expect(await store.goneCount() == 0, "a place is not a post")

        #expect(await store.letSettledGo(markedBy: origin.addingTimeInterval(86_400)) == 1)
        #expect(await store.note(Self.key(1))?.gaps == [])
        #expect(await store.all().count == 2, "the posts stay")
        #expect(await store.letSettledGo() == 1)
        #expect(await store.note(Self.key(2))?.gaps == [Self.missing], "only the settled mark went")
        #expect(await store.settledCount() == 0)
        #expect(await store.letSettledGo() == 0)
    }
}
