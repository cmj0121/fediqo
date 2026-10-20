import Foundation
import Testing
@testable import FediqoCore

/// A source whose answers can change between two reads, as one whose reader un-marks a post
/// elsewhere does: each ask by path and query, and what it is answered now.
private actor MarksServer: HTTPClient, HTTPSender {
    enum Answer: Sendable {
        case json(String, link: String? = nil, status: Int = 200)
        case fail
    }

    private var routes: [String: Answer]
    private(set) var asked: [String] = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func answer(_ routes: [String: Answer]) {
        self.routes = routes
        asked = []
    }

    func forget() { asked = [] }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let ask = url.path + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        switch routes[ask] {
        case .json(let body, let link, let status):
            var headers = link.map { ["Link": $0] } ?? [:]
            if status == 403 { headers["WWW-Authenticate"] = MastodonMarksCaptures.outsideScopeHeader }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        case .fail:
            throw URLError(.notConnectedToInternet)
        case nil:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// #317, in the half of it Core holds: what the reader bookmarked and favourited at a Mastodon,
/// read as two of its categories — paged by the source's own number for each mark, which is no
/// post's id; read on to the oldest mark with no post twice; and a post un-marked elsewhere
/// leaving the category at the next read that can tell. Read from what a real 4.6.6 answered
/// (`MastodonMarksCaptures`).
@Suite("Bookmarks and favourites, read as categories of a Mastodon")
struct MastodonMarksTests {
    private typealias Captures = MastodonMarksCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let bookmarks = "/api/v1/bookmarks"
    private static let favourites = "/api/v1/favourites"

    /// The captured stretches of two, by the ask that brought each.
    private static var byTwo: [String: MarksServer.Answer] {
        let stretches = Captures.bookmarkStretches
        return [
            "\(bookmarks)?limit=2": .json(stretches[0].body, link: stretches[0].link),
            "\(bookmarks)?limit=2&max_id=4": .json(stretches[1].body, link: stretches[1].link),
            "\(bookmarks)?limit=2&max_id=2": .json(stretches[2].body, link: stretches[2].link),
        ]
    }

    private func reader(
        _ routes: [String: MarksServer.Answer], length: Int = 2, reach: Int = MastodonMarks.bound
    ) async throws -> (MastodonMarks, ItemStore, MarksServer) {
        let store = ItemStore()
        await store.add(Self.source)
        let server = MarksServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        let door = MastodonAuthorized(token: Self.token, sender: server, store: tokens)
        return (MastodonMarks(door: door, store: store, length: length, reach: reach), store, server)
    }

    /// Which of the five posts the store holds through `category`, by the number it was written as.
    private func held(_ store: ItemStore, _ category: FediqoCore.Category) async -> [Int] {
        await store.all().filter { $0.categories.contains(category) }
            .compactMap { note in Captures.ids.firstIndex(of: note.statusID ?? "").map { $0 + 1 } }
            .sorted()
    }

    /// Reads every mark there is, down to the end, the way a listing does: a read, then read on
    /// below the lowest floor held until there is no floor left to read below.
    private func readToTheEnd(_ marks: MastodonMarks, _ store: ItemStore) async throws {
        try await marks.read(.bookmarks)
        var cursor = await store.lowestMark(host: Captures.host, category: .bookmarks)
        while let below = cursor, below != MastodonMarks.end { cursor = try await marks.older(.bookmarks, than: below) }
    }

    // MARK: - Read, and read on

    @Test("A first read asks the newest stretch of marks and no more, as the reader, and lands its posts through the category — in mark order on the wire, which is no order of ids or of when they were written")
    func aFirstReadIsOneStretch() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await marks.read(.bookmarks)
        #expect(await server.asked == ["\(Self.bookmarks)?limit=2"])
        #expect(await held(store, .bookmarks) == [2, 4])
        let notes = await store.all()
        #expect(notes.allSatisfy { $0.source == Self.source && $0.bookmarked == true })
        #expect(notes.allSatisfy { $0.listed[.bookmarks] == "4:5" }, "listed under the marks their stretch held, never a post's id")
        #expect(notes.allSatisfy { $0.gaps.isEmpty }, "no place is said missing by a post's id")
        // The source listed the fourth before the second: mark order, not publish order.
        #expect(Captures.ids[3] > Captures.ids[1])
    }

    @Test("Reading on goes below the lowest mark held, a stretch at a time, until the source names no next; it reaches the oldest mark, and no post lands twice")
    func readingOnReachesTheOldestMark() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        #expect(await server.asked == [
            "\(Self.bookmarks)?limit=2", "\(Self.bookmarks)?limit=2&max_id=4", "\(Self.bookmarks)?limit=2&max_id=2",
        ])
        let notes = await store.all()
        #expect(notes.count == 5, "one row a post")
        #expect(Set(notes.map(\.key)).count == 5)
        #expect(await held(store, .bookmarks) == [1, 2, 3, 4, 5])
        #expect(await store.lowestMark(host: Captures.host, category: .bookmarks) == MastodonMarks.end)
        // At the end, there is nothing below to ask.
        #expect(try await marks.older(.bookmarks, than: MastodonMarks.end) == nil)
        #expect(await server.asked.count == 3)
        // Held, they stand by when each was written, as every timeline's rows do.
        let byTime = notes.sorted { $0.postedAt < $1.postedAt }.map(\.statusID)
        #expect(byTime == Captures.ids)
    }

    @Test("A read once all is held walks as far down as what is held, and reaching the end decides of every post: the same five, each once")
    func aReadAgainWalksAsFarAsWhatIsHeld() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        await server.answer(Self.byTwo)
        try await marks.read(.bookmarks)
        #expect(await server.asked.count == 3)
        #expect(await store.all().count == 5)
        #expect(await held(store, .bookmarks) == [1, 2, 3, 4, 5])
    }

    @Test("Favourites are a category of their own, read the same way, and a post marked both ways carries both")
    func favouritesAreTheirOwn() async throws {
        var routes = Self.byTwo
        routes["\(Self.favourites)?limit=2"] = .json(Captures.favourites.body, link: Captures.favourites.link)
        let (marks, store, _) = try await reader(routes)
        try await readToTheEnd(marks, store)
        try await marks.read(.favourites)
        #expect(await held(store, .favourites) == [1, 5])
        #expect(await held(store, .bookmarks) == [1, 2, 3, 4, 5])
        #expect(await store.all().count == 5)
        let first = try #require(await store.all().first { $0.statusID == Captures.ids[0] })
        #expect(first.categories == [.bookmarks, .favourites])
        #expect(first.listed[.favourites] == "0:2" && first.listed[.bookmarks] == "2:3")
    }

    // MARK: - Un-marked elsewhere

    @Test("A post un-marked elsewhere leaves the category at the next read that reaches its mark; the post itself stays held, and keeps what else it came through")
    func unmarkedLeavesTheCategory() async throws {
        var routes = Self.byTwo
        routes["\(Self.favourites)?limit=2"] = .json(Captures.favourites.body, link: Captures.favourites.link)
        let (marks, store, server) = try await reader(routes)
        try await readToTheEnd(marks, store)
        try await marks.read(.favourites)
        // The first post's bookmark came off at the source; the server lists four, and the end.
        await server.answer(["\(Self.bookmarks)?limit=2": .json(Captures.bookmarksAfterOne.body, link: Captures.bookmarksAfterOne.link)])
        try await marks.read(.bookmarks)
        #expect(await held(store, .bookmarks) == [2, 3, 4, 5])
        let first = try #require(await store.all().first { $0.statusID == Captures.ids[0] })
        #expect(first.categories == [.favourites], "still a favourite")
        #expect(first.listed[.bookmarks] == nil)
        #expect(await store.all().count == 5, "nothing let go")
    }

    @Test("A post un-marked elsewhere that came through nothing else stays held all the same, through no category, until something lets it go")
    func unmarkedAloneStaysHeld() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        await server.answer(["\(Self.bookmarks)?limit=2": .json(Captures.bookmarksAfterOne.body, link: Captures.bookmarksAfterOne.link)])
        try await marks.read(.bookmarks)
        let first = try #require(await store.all().first { $0.statusID == Captures.ids[0] })
        #expect(first.categories.isEmpty)
        #expect(await store.all().count == 5)
    }

    @Test("A read that stops above a post's mark says nothing of it: a post held under a lower floor stays in the category, and only the posts the walk passed are decided")
    func aBoundedReadDecidesOnlyWhatItPassed() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        // The first and the fourth un-marked; a read of one stretch reaches the mark `3` and stops.
        await server.answer([
            "\(Self.bookmarks)?limit=2": .json(
                Captures.listing([Captures.post2, Captures.post5]),
                link: #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=3>; rel="next""#
            ),
        ])
        let once = MastodonMarks(
            door: MastodonAuthorized(token: Self.token, sender: server, store: try Self.tokens()), store: store, length: 2, reach: 1
        )
        try await once.read(.bookmarks)
        // The fourth was held under `4`, at or above where the walk reached: it is decided, and gone.
        // The first was held under `2`, below it: its mark may lie further down, and it stays.
        #expect(await held(store, .bookmarks) == [1, 2, 3, 5])
    }

    private static func tokens() throws -> MemoryMastodonTokens {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return tokens
    }

    @Test("A post met on two stretches of one walk — the list moved under it — is one row, under the newer of its two floors")
    func metTwiceIsOneRow() async throws {
        let read = try await MastodonMarks.walk(.bookmarks, holding: [NoteKey(host: Captures.host, id: "x"): "1"]) { cursor in
            let page = cursor == nil ? [Captures.post4, Captures.post2] : [Captures.post2, Captures.post1]
            let listed = try MastodonJSON.decoder.decode([StatusDTO].self, from: Data(Captures.listing(page).utf8)).map {
                $0.listed(source: Self.source, category: .bookmarks, sent: ReadMoment.now())
            }
            return MastodonMarks.Stretch(listed: listed, next: cursor == nil ? "4" : nil)
        }
        #expect(read.notes.map(\.statusID) == [Captures.ids[3], Captures.ids[1], Captures.ids[0]])
        #expect(read.notes[1].listed[.bookmarks] == "4", "the newer floor")
        #expect(read.reachedEnd && read.whole && read.connected == false)
    }

    // MARK: - Refused, or failed: nothing changes

    @Test("A source that refuses the read for want of its word is a failure, and nothing on this device changes")
    func aRefusalChangesNothing() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        let before = await store.all()
        await server.answer(["\(Self.bookmarks)?limit=2": .json(Captures.outsideScope, status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) { try await marks.read(.bookmarks) }
        #expect(await store.all() == before)
    }

    @Test("A read that fails after its first stretch lands nothing at all — neither the stretch that came nor any un-marking — and throws")
    func aFailureLandsNothing() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        let before = await store.all()
        await server.answer([
            "\(Self.bookmarks)?limit=2": .json(Captures.listing([Captures.post3]), link: #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=4>; rel="next""#),
            "\(Self.bookmarks)?limit=2&max_id=4": .fail,
        ])
        await #expect(throws: URLError.self) { try await marks.read(.bookmarks) }
        #expect(await store.all() == before)
    }

    @Test("A source that names as next a mark no older than the one it was asked below is not paging: the read fails, and nothing lands")
    func notPagingFails() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        let before = await store.all()
        await server.answer([
            "\(Self.bookmarks)?limit=2": .json(Captures.bookmarkStretches[0].body, link: Captures.bookmarkStretches[0].link),
            "\(Self.bookmarks)?limit=2&max_id=4": .json(Captures.bookmarkStretches[0].body, link: Captures.bookmarkStretches[0].link),
        ])
        await #expect(throws: MarksNotPaging.self) { try await marks.read(.bookmarks) }
        #expect(await store.all() == before)
        await #expect(throws: MarksNotPaging.self) { try await marks.older(.bookmarks, than: "4") }
    }

    @Test("Nothing is read into a source no longer here, and nothing is asked of a category that is no mark")
    func onlyMarksAndOnlyHere() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await marks.read(.home)
        #expect(try await marks.older(.public, than: "4") == nil)
        #expect(await server.asked.isEmpty)
        _ = await store.remove(host: Captures.host)
        try await marks.read(.bookmarks)
        #expect(await store.all().isEmpty)
    }

    // MARK: - Read on by the source's next; deep un-marks; places missing; outrun reads

    /// One post a stretch, numbered by mark: post `n` is marked `n`, the newest mark first.
    private static func single(_ n: Int, of count: Int, bookmarked: Int? = nil) -> MarksServer.Answer {
        let post = Captures.posts[(n - 1) % Captures.posts.count]
        let next = n > 1 ? #"<https://mastodon.localhost/api/v1/bookmarks?limit=1&max_id=\#(n)>; rel="next", "# : ""
        return .json(Captures.listing([post]), link: next + #"<https://mastodon.localhost/api/v1/bookmarks?limit=1&min_id=\#(n)>; rel="prev""#)
    }

    @Test("Reading on is moved on by the source's own next, whatever landed: a stretch that is empty and names a next all the same hands that next back, and nothing is asked twice")
    func readOnMovesOnWhateverLanded() async throws {
        var routes = Self.byTwo
        routes["\(Self.bookmarks)?limit=2&max_id=4"] = .json("[]", link: #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=2>; rel="next""#)
        let (marks, store, server) = try await reader(routes)
        try await marks.read(.bookmarks)
        let floor = try #require(await store.lowestMark(host: Captures.host, category: .bookmarks))
        #expect(floor == "4")
        let next = try await marks.older(.bookmarks, than: floor)
        #expect(next == "2", "the source's next, though nothing landed")
        #expect(await store.lowestMark(host: Captures.host, category: .bookmarks) == "4", "the premise: what is held did not move")
        #expect(try await marks.older(.bookmarks, than: try #require(next)) == nil)
        #expect(await held(store, .bookmarks) == [2, 3, 4])
        #expect(await server.asked == ["\(Self.bookmarks)?limit=2", "\(Self.bookmarks)?limit=2&max_id=4", "\(Self.bookmarks)?limit=2&max_id=2"])
    }

    @Test("A stretch read on decides what it went through: a post held with its mark inside it, and not brought back, leaves the category; one whose mark may lie outside stays")
    func readingOnDecidesWhatItCovers() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        // The first post's bookmark came off; the stretch below `4` now holds the fifth alone.
        await server.answer([
            "\(Self.bookmarks)?limit=2&max_id=4": .json(
                Captures.listing([Captures.post5]),
                link: #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=2>; rel="next", <https://mastodon.localhost/api/v1/bookmarks?limit=2&min_id=3>; rel="prev""#
            ),
        ])
        _ = try await marks.older(.bookmarks, than: "4")
        // The first was held between `2` and `3`, inside what was read; the fourth, second and
        // third were held outside it.
        #expect(await held(store, .bookmarks) == [2, 3, 4, 5])
    }

    @Test("A post un-marked deep down — further than the wait's walk reads — leaves the category at the next reload the person asks for, which walks on past every mark held; the wait's walk leaves it")
    func deepUnmarksAtTheNextReload() async throws {
        let count = 7
        var routes: [String: MarksServer.Answer] = ["\(Self.bookmarks)?limit=1": Self.single(count, of: count)]
        for n in 1..<count { routes["\(Self.bookmarks)?limit=1&max_id=\(n + 1)"] = Self.single(n, of: count) }
        let store = ItemStore()
        await store.add(Self.source)
        let server = MarksServer(routes)
        let door = MastodonAuthorized(token: Self.token, sender: server, store: try Self.tokens())
        let marks = MastodonMarks(door: door, store: store, length: 1, reach: 2, thoroughReach: 25)
        try await readToTheEnd(marks, store)
        #expect(await held(store, .bookmarks) == [1, 2, 3, 4, 5])
        #expect(await store.all().first { $0.statusID == Captures.ids[0] }?.categories.contains(.bookmarks) == true)
        // The deepest mark, the first post's, came off: the stretch below `2` is empty and the end.
        routes["\(Self.bookmarks)?limit=1&max_id=2"] = .json("[]", link: nil)
        await server.answer(routes)
        try await marks.read(.bookmarks, thorough: false)
        #expect(await server.asked.count == 1, "the wait's walk met only what is held, and stopped")
        let first = { await store.all().first { $0.statusID == Captures.ids[0] } }
        #expect(await first()?.listed[.bookmarks] != nil, "the wait did not reach it")
        await server.answer(routes)
        try await marks.read(.bookmarks)
        #expect(await server.asked.count == count, "the reload walked to the end")
        let deep = try #require(await first())
        // Posts six and one are the same capture: the first post is still marked as the sixth.
        #expect(deep.listed[.bookmarks] == "6:6", "only the deeper mark is gone, and the post is listed by the one it still has")
    }

    @Test("A walk that reaches its bound having met nothing held — more marked since than it reads — says where marks may be missing on the lowest post it brought; reading down from there fills it, and the place goes")
    func aPlaceMissingIsSaidAndFilled() async throws {
        let (marks, store, server) = try await reader(Self.byTwo, reach: 1)
        // The third post alone held, under the end.
        await server.answer(["\(Self.bookmarks)?limit=2&max_id=2": .json(Captures.bookmarkStretches[2].body, link: Captures.bookmarkStretches[2].link)])
        _ = try await marks.older(.bookmarks, than: "2")
        #expect(await held(store, .bookmarks) == [3])
        // Four marked since; a walk of one stretch brings two of them and meets nothing held.
        await server.answer(Self.byTwo)
        try await marks.read(.bookmarks)
        let lowest = try #require(await store.all().first { $0.statusID == Captures.ids[1] })
        #expect(lowest.gaps == [TimelineGap(.mayBeMissing, in: .bookmarks)])
        #expect(await store.markHole(lowest.key, in: .bookmarks) == "4")
        // Read down: below `4` brings the fifth and the first; one stretch is the bound, and it
        // met nothing held, so the place moves down to `2`.
        await server.forget()
        try await marks.readDown(.bookmarks, below: lowest.key)
        #expect(await server.asked == ["\(Self.bookmarks)?limit=2&max_id=4"])
        #expect(await store.markHole(lowest.key, in: .bookmarks) == "2")
        // Again: below `2` is the third, held — the place is filled, and goes.
        try await marks.readDown(.bookmarks, below: lowest.key)
        #expect(await store.markHole(lowest.key, in: .bookmarks) == nil)
        #expect(await held(store, .bookmarks) == [1, 2, 3, 4, 5])
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty })
    }

    @Test("The wait's walk stops at the first stretch that brings only what is held; a reload walks to the lowest mark held")
    func theWaitStopsWhereItMeetsWhatIsHeld() async throws {
        let (marks, store, server) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        await server.forget()
        try await marks.read(.bookmarks, thorough: false)
        #expect(await server.asked == ["\(Self.bookmarks)?limit=2"])
        await server.forget()
        try await marks.read(.bookmarks)
        #expect(await server.asked.count == 3)
    }

    @Test("A read outrun by a later one decides nothing, and brings back no post the later one found no longer marked; what else it brought lands")
    func anOutrunReadDecidesNothing() async throws {
        let (marks, store, _) = try await reader(Self.byTwo)
        try await readToTheEnd(marks, store)
        // Each post as a read hands it over, saying when it was sent.
        let notes = try Captures.posts.map { post in
            var note = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(post.utf8))
                .listed(source: Self.source, category: .bookmarks, sent: ReadMoment.now()).note
            note.listed = [.bookmarks: "0:5"]
            return note
        }
        let first = notes[0], fourth = notes[3]
        let early = await store.beginMarks()
        let late = await store.beginMarks()
        // The later read lands first: everything but the first post, to the end.
        let later = notes.filter { $0.key != first.key }
        await store.land(MarksRead(notes: later, covered: MarkCover(low: MastodonMarks.end), whole: true, begun: late), of: .bookmarks, ifSourceHere: Captures.host)
        #expect(await held(store, .bookmarks) == [2, 3, 4, 5])
        // The earlier one lands last, bringing the first back and not the fourth: neither counts.
        await store.land(MarksRead(notes: [first], covered: MarkCover(low: MastodonMarks.end), whole: true, begun: early), of: .bookmarks, ifSourceHere: Captures.host)
        #expect(await held(store, .bookmarks) == [2, 3, 4, 5])
        #expect(await store.all().first { $0.key == fourth.key }?.categories.contains(.bookmarks) == true)
    }

    @Test("What two reads say of one post's mark is their overlap; where they do not overlap, it was marked again, and the later is where it is")
    func spansMerge() {
        let held = MarkSpan(floor: "2", ceiling: "5")
        #expect(held.merged(with: MarkSpan(floor: "3", ceiling: "7")) == MarkSpan(floor: "3", ceiling: "5"))
        #expect(held.merged(with: MarkSpan(floor: "9", ceiling: "9")) == MarkSpan(floor: "9", ceiling: "9"))
        #expect(MarkSpan(floor: "4").merged(with: MarkSpan(floor: "2", ceiling: "6")) == MarkSpan(floor: "4", ceiling: "6"))
        #expect(MarkSpan(listed: "4:10") == MarkSpan(floor: "4", ceiling: "10") && MarkSpan(listed: "4")?.ceiling == nil)
        #expect(MarkCover(low: "2", high: "4").contains(MarkSpan(floor: "2", ceiling: "3")))
        #expect(!MarkCover(low: "2", high: "4").contains(MarkSpan(floor: "2", ceiling: "4")))
        #expect(!MarkCover(low: "2", high: "4").contains(MarkSpan(floor: "2")), "a span with no ceiling may lie above")
        #expect(MarkCover(low: "2").contains(MarkSpan(floor: "2")))
        #expect(MastodonLink.previous(in: Captures.bookmarkStretches[0].link) == "5")
        #expect(MastodonLink.previous(in: #"<https://x.example/a?min_id=../x>; rel="prev""#) == nil)
    }

    @Test("A post with a poll that arrives through bookmarks keeps its poll, and read again through them with only its figures moved it is not changed: no earlier wording is kept for it")
    func aPollComesWithItsPost() async throws {
        let polled = MastodonPollCaptures.status(id: "9", poll: MastodonPollCaptures.open)
        let (marks, store, server) = try await reader(["\(Self.bookmarks)?limit=2": .json("[" + polled + "]")])
        try await marks.read(.bookmarks)
        let first = try #require(await store.all().first)
        #expect(first.categories == [.bookmarks])
        let poll = try #require(first.poll)
        #expect(poll.choices.map(\.title) == ["Tea", "Coffee", "Water"])
        // Read again, the figures moved and nothing was edited.
        let moved = MastodonPollCaptures.open.replacingOccurrences(of: #""votes_count": 10"#, with: #""votes_count": 11"#)
        await server.answer(["\(Self.bookmarks)?limit=2": .json("[" + MastodonPollCaptures.status(id: "9", poll: moved) + "]")])
        try await marks.read(.bookmarks)
        let again = try #require(await store.all().first)
        #expect(again.poll != nil && again.earlier.isEmpty, "no revision for a read of the same post")
        #expect(again.categories == [.bookmarks])
        #expect(await store.all().count == 1)
    }

    // MARK: - What a sign-in needs

    @Test("Reading marks is a part of its own: both words, which only read, asked of no sign-in unless pressed for, and standing without acting")
    func thePart() {
        #expect(MastodonPart.marks.words == ["read:bookmarks", "read:favourites"])
        #expect(!MastodonPart.marks.rider && !MastodonPart.marks.needsActing)
        #expect(MastodonPart.marks.wordsBesideActing.isEmpty)
        for writing in [false, true] {
            let asked = MastodonOAuth.scopes(writing: writing)
            #expect(!asked.contains("read:bookmarks") && !asked.contains("read:favourites"), "a sign-in asks for it only where pressed")
        }
        let reading = MastodonOAuth.scopes(writing: false)
        let page = MastodonParts.page(held: reading, ticked: [.marks])
        #expect(page == reading + " read:bookmarks read:favourites")
        #expect(MastodonParts.everything.contains("read:bookmarks read:favourites"), "the registration holds it, so a page may ask it")
    }

    @Test("Each category is read only by a sign-in holding its own word, or the source's one word for every read")
    func whatReadsWhich() {
        #expect(MastodonParts.readsMarks(.bookmarks, in: "read:statuses read:bookmarks"))
        #expect(!MastodonParts.readsMarks(.favourites, in: "read:statuses read:bookmarks"))
        #expect(MastodonParts.readsMarks(.favourites, in: "read write"))
        #expect(!MastodonParts.readsMarks(.bookmarks, in: "write:bookmarks"), "bookmarking is not reading bookmarks")
        #expect(!MastodonParts.readsMarks(.bookmarks, in: "read:bookmarksx"))
        #expect(!MastodonParts.readsMarks(.home, in: "read"))
        #expect(!MastodonParts.readsMarks(.bookmarks, in: nil))
    }

    @Test("A Mastodon offers its marks as categories only to a sign-in that reads them; a rule can name them on a source that has them, and nowhere else")
    func offered() throws {
        let offers = ProtocolKind.mastodon.offers
        #expect(offers.marks && offers.serves(.bookmarks) && offers.serves(.favourites))
        #expect(!ProtocolKind.discuz.offers.serves(.bookmarks))
        #expect(offers.categories(of: Self.source, signedIn: true, marks: true) == [.public, .trends, .home, .bookmarks, .favourites])
        #expect(offers.categories(of: Self.source, signedIn: true) == [.public, .trends, .home])
        #expect(offers.categories(of: Self.source, signedIn: false, marks: true) == [.public, .trends])
        let forum = Source(host: "f.example", kind: .discuz)
        #expect(Rule.category(.bookmarks, in: .source(host: forum.host), sources: [forum]) == nil)
        #expect(Rule.category(.bookmarks, in: .source(host: Self.source.host), sources: [Self.source]) != nil)
        #expect(Category.bookmarks.isMarks && Category.favourites.isMarks && !Category.home.isMarks)
    }
}
