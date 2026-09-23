import Foundation
import Testing

@testable import FediqoCore

/// A place posts may be missing reads down when reached, and says so for good where the source
/// has nothing (#204).
@Suite("A place posts may be missing reads down from it")
struct ReadDownTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    private static func note(
        _ id: Int, _ category: FediqoCore.Category = .public, listed: Bool = true, handle: String = "@ada"
    ) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: handle,
            body: "\(id)", postedAt: posted(id), categories: [category], statusID: "\(id)",
            listed: listed ? [category: "\(id)"] : [:]
        )
    }

    private static func posted(_ id: Int) -> Date {
        Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60)
    }

    /// Post `id` as the public timeline lists it, under `id` — or under `listing`, as a boost is.
    private static func listing(_ id: Int, as listing: Int? = nil) -> Listed {
        (listed: "\(listing ?? id)", note: note(id))
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
        #expect(down.end == .further(from: "250"))
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
        #expect(down.end == .settled)
        #expect(await marked(store) == [31: [TimelineGap(.settled, in: .public)]])
        #expect(await store.note(Self.key(31))?.gaps.first?.since == moment)
        #expect(await store.missing(below: Self.key(31), in: .public) == nil, "a settled place asks nothing")
    }

    @Test("A source that runs out partway settles the place below the oldest post it gave")
    func settlesLower() async throws {
        let server = TimelineServer(20...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let down = try await readDown(store, from: server, at: 31)
        #expect(down.end == .settled)
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

    // MARK: - By listed ids alone

    @Test("A boost in the hole, of a post held below, does not fill it")
    func boostDoesNotFill() async throws {
        let server = TimelineServer(1...500)
        await server.boost(440, of: 5)
        let store = await store(holding: Array(1...10) + Array(450...500), markedAt: 450)
        let down = try await readDown(store, from: server, at: 450)
        #expect(down.end == .further(from: "250"), "440 is a boost of 5, not 5 listed where it stands")
        #expect(await store.note(Self.key(250))?.gaps == [Self.missing])
    }

    @Test("The reader's own post, listed by no timeline, is not what is held below: it does not fill the hole")
    func ownPostDoesNotFill() async throws {
        let server = TimelineServer(1...100)
        let store = await store(holding: Array(1...10) + Array(100...110), markedAt: 100)
        await store.ingest([Self.note(70, listed: false, handle: "@me@\(Self.host)")])
        let place = try #require(await store.missing(below: Self.key(100), in: .public, writtenBy: "@me@\(Self.host)"))
        #expect(place.held == Set((1...10).map(Self.key)) && place.floor == "10", "listed ids alone")
        _ = try await readDown(store, from: server, at: 100)
        #expect(await server.cursors == ["max_id=100", "max_id=60", "max_id=20"], "read on past 70, to 10")
        #expect(await held(store) == Array(1...110))
        #expect(await marked(store).isEmpty)
    }

    @Test("Held from before listings were kept, the reader's own post and a boost are still not below")
    func fallbackLeavesOwnAndBoosts() async throws {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((1...10).map { Self.note($0, listed: false) })
        let boost = Note(
            id: Self.note(50).id, source: Self.source, author: "Ada", handle: "@ada", body: "50",
            postedAt: Self.posted(8), categories: [.public], boostedBy: "Bob", statusID: "50"
        )
        await store.ingest([Self.note(20, listed: false, handle: "@me@\(Self.host)"), Self.note(100)])
        await store.ingest([boost])
        await store.land(ReadOn(missingBelow: Self.key(100)), of: .public, ifSourceHere: Self.host)
        let place = try #require(await store.missing(below: Self.key(100), in: .public, writtenBy: "@me@\(Self.host)"))
        #expect(place.floor == nil)
        #expect(!place.held.contains(Self.key(20)), "the reader wrote it")
        #expect(!place.held.contains(Self.key(50)), "a boost is held for when it was boosted")
        #expect(place.held.contains(Self.key(1)))
    }

    @Test("Held from before listings were kept, and signed in as nobody known yet: nothing is guessed or asked")
    func fallbackWaitsForWho() async throws {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((1...10).map { Self.note($0, listed: false) } + [Self.note(100)])
        await store.land(ReadOn(missingBelow: Self.key(100)), of: .public, ifSourceHere: Self.host)
        #expect(await store.missing(below: Self.key(100), in: .public, signedIn: true) == nil)
        #expect(await store.missing(below: Self.key(100), in: .public) != nil, "signed out, nothing is theirs")
        #expect(await store.missing(below: Self.key(100), in: .public, writtenBy: "@me@\(Self.host)", signedIn: true) != nil)
        #expect(await store.note(Self.key(100))?.gaps == [Self.missing], "the mark stays")
    }

    @Test("Where all held below is what a read down cannot meet, it still reads down rather than call the hole filled")
    func onlyUnmeetableBelow() async throws {
        let server = TimelineServer(90...100)
        let store = ItemStore()
        await store.add(Self.source)
        let me = "@me@\(Self.host)"
        await store.ingest([Self.note(20, listed: false, handle: me), Self.note(100)])
        await store.land(ReadOn(missingBelow: Self.key(100)), of: .public, ifSourceHere: Self.host)
        let place = try #require(await store.missing(below: Self.key(100), in: .public, writtenBy: me))
        #expect(place.held.isEmpty && place.hasBelow)
        let down = try await MastodonClient(http: server, host: Self.host)
            .publicTimeline(source: Self.source, readingDownFrom: place)
        #expect(down.end == .settled, "asked, and the source had nothing below 90")
        #expect(await server.cursors == ["max_id=100", "max_id=90"])
    }

    @Test("A mark moved down reads down from where the read stopped, whatever lists that post again later")
    func movedMarkKeepsItsID() async throws {
        let server = TimelineServer(1...500)
        let store = await store(holding: Array(1...10) + Array(450...500), markedAt: 450)
        _ = try await readDown(store, from: server, at: 450)
        var again = Self.note(250)
        again.listed = [.public: "480"]
        await store.ingest([again])
        #expect(await store.note(Self.key(250))?.listed[.public] == "480", "the premise: listed later again")
        #expect(await store.missing(below: Self.key(250), in: .public)?.listed == "250")
    }

    @Test("Where nothing read is taken in, the place stays on the post it was on, and says where to read from")
    func carrierRefused() async throws {
        let store = await store(holding: 450...500, markedAt: 450)
        let month = try #require(Calendar.current.date(byAdding: .month, value: 1, to: Self.posted(440)))
        await store.setRetention(months: 1, from: month)
        await store.land(
            ReadDown(notes: [Self.note(300), Self.note(250)], end: .further(from: "250")),
            below: Self.key(450), of: .public, ifSourceHere: Self.host
        )
        #expect(await store.note(Self.key(250)) == nil, "the premise: older than what is kept")
        #expect(await store.note(Self.key(450))?.gaps == [Self.missing])
        #expect(await store.note(Self.key(450))?.gaps.first?.from == "250")

        await store.land(ReadDown(notes: [Self.note(300)], end: .settled), below: Self.key(450), of: .public,
                         ifSourceHere: Self.host)
        #expect(await store.note(Self.key(450))?.gaps.map(\.kind) == [.settled], "settled, not lost")
    }

    @Test("A server answering with the same page settles nothing: it fails the read, or stops it where it got to")
    func samePage() async throws {
        let place = MissingPlace(post: Self.key(31), category: .public, listed: "31", held: [Self.key(5)], floor: "10")
        let same = [Self.listing(35), Self.listing(31)]
        await #expect(throws: ReadDownStalled.self) {
            try await MastodonReadOn.readDown(from: place) { _ in same }
        }
        let asks = Counter()
        let down = try await MastodonReadOn.readDown(from: place) { _ in
            await asks.next() == 1 ? (20...30).reversed().map { Self.listing($0) } : same
        }
        #expect(down.end == .further(from: "20"))
        #expect(down.stopped is ReadDownStalled)
    }

    @Test("A place settled again is one place, as of the later moment")
    func settledOnce() async throws {
        let server = TimelineServer(31...60)
        let store = await store(holding: Array(1...10) + Array(31...60), markedAt: 31)
        let first = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await readDown(store, from: server, at: 31, moment: first)
        await store.land(ReadOn(missingBelow: Self.key(31)), of: .public, ifSourceHere: Self.host)
        _ = try await readDown(store, from: server, at: 31, moment: first.addingTimeInterval(60))
        let gaps = try #require(await store.note(Self.key(31))?.gaps)
        #expect(gaps.filter { $0.kind == .settled }.count == 1)
        #expect(await store.settledCount() == 1)
    }

    @Test("A place on a post marked gone is counted as the post, not beside it")
    func settledOnGone() async {
        let store = ItemStore()
        await store.add(Self.source)
        var gone = Self.note(1)
        gone.gaps = [TimelineGap(.settled, in: .public, since: Date())]
        await store.ingest([gone])
        await store.markGone(Self.key(1))
        #expect(await store.settledCount() == 0)
        #expect(await store.goneCount() == 1)
    }

    @Test("A marked post its timeline listed under no id names no place to read down from")
    func noListingNoPlace() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest([Self.note(1), Self.note(31, listed: false)])
        await store.land(ReadOn(missingBelow: Self.key(31)), of: .public, ifSourceHere: Self.host)
        #expect(await store.missing(below: Self.key(31), in: .public) == nil)
    }
}

/// Counts asks, from one.
private actor Counter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
