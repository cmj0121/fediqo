import Foundation
import Testing

@testable import FediqoCore

/// One Mastodon timeline, paged the way Mastodon pages it: the newest `limit` with nothing asked,
/// those before `max_id`, and the `limit` immediately after `min_id` — each newest first. What it
/// holds can be cut from below, as a home timeline is kept only so long; an entry can be a boost,
/// listed under its own id; and one ask can be made to fail.
///
/// **An HTTP client and a sender both**, so the public timeline, read unsigned, and Home, read as
/// you, are asked of the same fixture.
actor TimelineServer: HTTPClient, HTTPSender {
    private let host: String
    private var held: [Int]
    /// Entries that are boosts, by their own id, of the post each boosted.
    private var boosts: [Int: Int] = [:]
    /// The ask, counted from one, that fails.
    private var failing: Int?
    private(set) var asked: [URL] = []

    init(host: String = "social.example", _ ids: some Sequence<Int>) {
        self.host = host
        held = Array(ids)
    }

    /// The paging each ask named, in order: `min_id=5`, `max_id=9`, or `newest`.
    var cursors: [String] {
        asked.map { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "min_id" || $0.name == "max_id" }.map { "\($0.name)=\($0.value!)" }
                ?? "newest"
        }
    }

    func post(_ ids: some Sequence<Int>) { held += ids }

    /// Keeps only what is `lowest` or newer: everything older is let go.
    func keep(from lowest: Int) { held = held.filter { $0 >= lowest } }

    /// Lists entry `id` as a boost of post `inner`.
    func boost(_ id: Int, of inner: Int) { boosts[id] = inner }

    /// Fails the `ask`th ask from now on, counting from one.
    func fail(ask: Int) { failing = asked.count + ask }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try answer(url)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try answer(request.url!)
    }

    private func answer(_ url: URL) throws -> (Data, HTTPURLResponse) {
        asked.append(url)
        if asked.count == failing { throw URLError(.timedOut) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let limit = value("limit").flatMap(Int.init) ?? 20
        let sorted = held.sorted()
        let page: [Int]
        if let min = value("min_id").flatMap(Int.init) {
            page = Array(sorted.filter { $0 > min }.prefix(limit)).reversed()
        } else if let max = value("max_id").flatMap(Int.init) {
            page = Array(sorted.filter { $0 < max }.suffix(limit)).reversed()
        } else {
            page = Array(sorted.suffix(limit)).reversed()
        }
        let body = "[" + page.map { id in
            boosts[id].map { Self.boost(id, of: $0, host: host) } ?? Self.status(id, host: host)
        }.joined(separator: ",") + "]"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    /// `id` minutes into 2024 — so a later id is a later post.
    private static func posted(_ id: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60))
    }

    /// Status `id`.
    static func status(_ id: Int, host: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","created_at":"\(posted(id))",
         "content":"<p>\(id)</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// Entry `id`, Bob's boost of status `inner`.
    static func boost(_ id: Int, of inner: Int, host: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/bob/statuses/\(id)/activity","created_at":"\(posted(id))",
         "content":"","account":{"username":"bob","acct":"bob","display_name":"Bob"},
         "reblog":\(status(inner, host: host))}
        """
    }
}

/// A microblog timeline read again reads on from where this device left it (#201).
@Suite("A timeline read again reads on from where this device left it")
struct ReadOnTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    /// Post `id` as a read of `categories` listed it — or listed by none, as the reader's own post
    /// or a search's find is.
    private static func note(
        _ id: Int, _ categories: Set<FediqoCore.Category> = [.public], listed: Bool = true
    ) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60),
            categories: categories, statusID: "\(id)",
            listed: listed ? Dictionary(uniqueKeysWithValues: categories.map { ($0, "\(id)") }) : [:]
        )
    }

    private static func key(_ id: Int) -> NoteKey { note(id).key }

    /// A store holding `ids` as the public timeline listed them.
    private func store(holding ids: some Sequence<Int>) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(ids.map { Self.note($0) })
        return store
    }

    private func readPublic(_ store: ItemStore, from server: TimelineServer) async throws -> ReadOn {
        let anchor = await store.newestListedID(host: Self.host, category: .public)
        let held = anchor == nil ? await store.held(host: Self.host, category: .public) : []
        let read = try await MastodonClient(http: server, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: anchor, holding: held)
        await store.land(read, of: .public, ifSourceHere: Self.host)
        return read
    }

    private func held(_ store: ItemStore) async -> [Int] {
        await store.all().compactMap { $0.statusID.flatMap(Int.init) }.sorted()
    }

    // MARK: - Ids

    @Test("A later id is a longer one, or the greater of two as long; never plain string order")
    func idOrder() {
        #expect(StatusID.later("10", than: "9"))
        #expect(!StatusID.later("9", than: "10"))
        #expect(StatusID.later("113000000000000001", than: "112999999999999999"))
        #expect(!StatusID.later("5", than: "5"))
        #expect(StatusID.later("010", than: "9"), "a leading nought changes nothing")
    }

    @Test("One before an id is the number one less, and nothing before what is not a number")
    func idBefore() {
        #expect(StatusID.before("10") == "9")
        #expect(StatusID.before("100") == "99")
        #expect(StatusID.before("113000000000000000") == "112999999999999999")
        #expect(StatusID.before("1") == "0")
        #expect(StatusID.before("0") == nil)
        #expect(StatusID.before("abc") == nil)
        #expect(StatusID.before("") == nil)
    }

    // MARK: - Reading on

    @Test("With nothing held, the newest stretch is read, as it always was")
    func noAnchor() async throws {
        let server = TimelineServer(1...100)
        let store = await store(holding: [])
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["newest"])
        #expect(await held(store) == Array(61...100))
        #expect(read.missingBelow == nil && read.newerRemainAbove == nil)
    }

    /// A store as a relaunch reads it back from rows saved before `listed` was kept: posts of the
    /// public timeline that no read is recorded as listing.
    private func upgraded(holding ids: ClosedRange<Int>) -> ItemStore {
        ItemStore(sources: [Self.source], notes: ids.map { Self.note($0, listed: false) })
    }

    @Test("Held from before listings were kept, and the newest stretch meets none of it: posts may be missing")
    func upgradedHole() async throws {
        let server = TimelineServer(1...300)
        let store = upgraded(holding: 1...10)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["newest"], "no anchor: the newest stretch, as before")
        #expect(read.missingBelow == Self.key(261), "below its oldest, where the hole is")
        #expect(await store.note(Self.key(261))?.gaps == [TimelineGap(.mayBeMissing, in: .public)])
    }

    @Test("Held from before listings were kept, and the newest stretch meets it: nothing is said")
    func upgradedMeets() async throws {
        let server = TimelineServer(1...300)
        let store = upgraded(holding: 271...280)
        let read = try await readPublic(store, from: server)
        #expect(read.missingBelow == nil)
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty })
        #expect(await store.newestListedID(host: Self.host, category: .public) == "300", "and it is read on from next")
    }

    @Test("More new posts than one stretch holds all arrive, in order, with no hole")
    func severalStretches() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...100)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["min_id=9", "min_id=49", "min_id=89"],
                "from one before the newest held, each on from the newest the last listed, none past a short one")
        #expect(await held(store) == Array(1...100), "every one of them, and no hole")
        #expect(read.missingBelow == nil, "the source gave back the post it was read on from")
        #expect(read.newerRemainAbove == nil, "a short stretch is the last")
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty })
    }

    @Test("Nothing newer: one ask, and nothing said")
    func nothingNewer() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        let revision = await store.revision
        _ = try await readPublic(store, from: server)
        #expect(await server.cursors == ["min_id=9"])
        #expect(await store.revision == revision, "the anchor again is no change")
    }

    @Test("Past the bound, the newest post read says newer remain; reading on from there brings the rest")
    func bound() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...300)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors.count == MastodonReadOn.bound, "no more than the bound in one read")
        #expect(await held(store) == Array(1...209), "five full stretches on from 10, with no hole")
        #expect(read.newerRemainAbove == Self.key(209))
        #expect(await store.note(Self.key(209))?.gaps == [TimelineGap(.newerRemain, in: .public)])

        let again = try await readPublic(store, from: server)
        #expect(await held(store) == Array(1...300))
        #expect(again.newerRemainAbove == nil)
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty }, "the place is read, and says so no more")
    }

    @Test("A full last stretch at the bound says more remain; a short one does not")
    func boundExactly() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        // Four full stretches from 10, and a fifth of one: the source has nothing newer.
        await server.post(11...170)
        let read = try await readPublic(store, from: server)
        #expect(await held(store) == Array(1...170))
        #expect(read.newerRemainAbove == nil)
    }

    @Test("Where the source no longer has the post read on from, posts may be missing below what it gave")
    func mayBeMissing() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...60)
        await server.keep(from: 31)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["min_id=9", "max_id=31"], "the stretch below was asked, and was empty")
        #expect(read.missingBelow == Self.key(31))
        #expect(await held(store) == Array(1...10) + Array(31...60), "what it gave is here; nothing is invented")
        #expect(await store.note(Self.key(31))?.gaps == [TimelineGap(.mayBeMissing, in: .public)])

        _ = try await readPublic(store, from: server)
        #expect(await store.note(Self.key(31))?.gaps == [TimelineGap(.mayBeMissing, in: .public)],
                "a later read does not take it back: nothing it reads can show they were not")
    }

    @Test("An anchor the source deleted says nothing is missing where the stretch below reaches past it")
    func anchorDeleted() async throws {
        let server = TimelineServer(Array(1...9) + Array(11...20))
        let store = await store(holding: 1...10)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["min_id=9", "max_id=11"])
        #expect(read.missingBelow == nil, "the stretch below reached past 10: only 10 went")
        #expect(await held(store) == Array(1...20))
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty })
    }

    @Test("A stretch that fails after the first keeps those before it, and says more may remain above them")
    func partial() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...300)
        await server.fail(ask: 3)
        let read = try await readPublic(store, from: server)
        #expect(read.stopped != nil, "the read did not come back whole")
        #expect(await held(store) == Array(1...89))
        #expect(read.newerRemainAbove == Self.key(89))
        #expect(await store.note(Self.key(89))?.gaps == [TimelineGap(.newerRemain, in: .public)])
    }

    @Test("A first stretch that fails fails the read, and nothing lands")
    func firstFails() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.fail(ask: 1)
        await #expect(throws: URLError.self) { try await readPublic(store, from: server) }
    }

    @Test("An id that is not a number is read on from itself, and claims no gap it cannot see")
    func notANumber() async throws {
        let http = FixtureHTTP([
            "https://\(Self.host)/api/v1/timelines/public?limit=40&min_id=abc": .text("[]"),
        ])
        let read = try await MastodonClient(http: http, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: "abc")
        #expect(read.notes.isEmpty && read.missingBelow == nil)
    }

    @Test("A read that goes nowhere newer stops rather than asking the same stretch again")
    func noProgress() async throws {
        let http = FixtureHTTP([
            // A server answering min_id with what is older than it: nothing it sent is newer than 10.
            "https://\(Self.host)/api/v1/timelines/public?limit=40&min_id=9":
                .text("[" + TimelineServer.status(5, host: Self.host) + "]"),
            "https://\(Self.host)/api/v1/timelines/public?limit=40&max_id=5": .text("[]"),
        ])
        _ = try await MastodonClient(http: http, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: "10")
        #expect(await http.requested.count == 2, "the one stretch, and the one below it")
    }

    // MARK: - The anchor

    @Test("The anchor is the newest id a read of that timeline listed, never a post gone or listed by none")
    func anchor() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest([Self.note(9), Self.note(10), Self.note(50, [.home])])
        #expect(await store.newestListedID(host: Self.host, category: .public) == "10")
        #expect(await store.newestListedID(host: Self.host, category: .home) == "50")
        #expect(await store.newestListedID(host: Self.host, category: .list(id: "7")) == nil)
        _ = await store.markGone(Self.key(10))
        #expect(await store.newestListedID(host: Self.host, category: .public) == "9")
        await store.hold([Self.note(20, listed: false)], ifSourceHere: Self.host)
        #expect(await store.newestListedID(host: Self.host, category: .public) == "9")
    }

    @Test("The reader's own post never moves the anchor: a read after it brings everything between")
    func ownPost() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        // What `MastodonWrite.post` keeps: the reader's status, in Home and public, listed by none.
        await store.ingest([Self.note(500, [.home, .public], listed: false)])
        await server.post(11...300)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors.first == "min_id=9")
        #expect(await held(store) == Array(1...209) + [500], "on from 10, and no hole")
        #expect(read.newerRemainAbove == Self.key(209), "and the place more belong is where they do")
        #expect(read.missingBelow == nil)
    }

    @Test("A boost as the newest post held reads on from the boost, says nothing is missing, and moves on")
    func boostNewest() async throws {
        let server = TimelineServer(1...10)
        await server.boost(10, of: 3)
        let store = await store(holding: [])
        _ = try await readPublic(store, from: server)
        let boosted = await store.all().first { $0.statusID == "3" }
        #expect(boosted?.listed[.public] == "10", "the boost's own id, not the post's")
        #expect(await store.newestListedID(host: Self.host, category: .public) == "10")

        await server.post(11...20)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["newest", "min_id=9"], "on from one before the boost")
        #expect(read.missingBelow == nil, "the boost came back: nothing is missing")
        #expect(await store.newestListedID(host: Self.host, category: .public) == "20", "and the anchor moved on")
        _ = try await readPublic(store, from: server)
        #expect(await server.cursors.last == "min_id=19")
    }

    // MARK: - Landing

    @Test("Two reads landing the same posts make no row twice, and the marks stay one each")
    func landingTwice() async {
        let store = ItemStore()
        await store.add(Self.source)
        let read = ReadOn(
            notes: (1...5).map { Self.note($0) }, missingBelow: Self.key(1), newerRemainAbove: Self.key(5)
        )
        await store.land(read, of: .public, ifSourceHere: Self.host)
        await store.land(read, of: .public, ifSourceHere: Self.host)
        #expect(await store.all().count == 5)
        #expect(await store.note(Self.key(1))?.gaps == [TimelineGap(.mayBeMissing, in: .public)])
        #expect(await store.note(Self.key(5))?.gaps == [TimelineGap(.newerRemain, in: .public)])
    }

    @Test("Newer remaining is one timeline's: Home read on leaves the public timeline's where it was")
    func oneTimelinesMark() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.land(ReadOn(notes: [Self.note(5)], newerRemainAbove: Self.key(5)), of: .public, ifSourceHere: Self.host)
        await store.land(ReadOn(notes: [Self.note(6, [.home])]), of: .home, ifSourceHere: Self.host)
        #expect(await store.note(Self.key(5))?.gaps == [TimelineGap(.newerRemain, in: .public)])
    }

    @Test("A source removed while its read was out gets nothing back, marks included")
    func sourceGone() async {
        let store = ItemStore()
        await store.land(ReadOn(notes: [Self.note(5)], newerRemainAbove: Self.key(5)), of: .public, ifSourceHere: Self.host)
        #expect(await store.all().isEmpty)
    }

    // MARK: - Home, read as you

    @Test("Home read as you reads on the same way, and says where it was rebuilt past what was held")
    func home() async throws {
        let server = TimelineServer(1...10)
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((1...10).map { Self.note($0, [.home]) })
        await server.post(11...120)
        await server.keep(from: 21)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        #expect(try await MastodonAccount(door: door, store: store).read())
        #expect(await server.cursors == ["min_id=9", "max_id=21", "min_id=60", "min_id=100"])
        #expect(await held(store) == Array(1...10) + Array(21...120))
        #expect(await store.note(Self.key(21))?.gaps == [TimelineGap(.mayBeMissing, in: .home)])
        #expect(await server.asked.allSatisfy { $0.path == "/api/v1/timelines/home" })
    }

    @Test("Home failing a stretch after the first lands what came, and says the read did not come back")
    func homePartial() async throws {
        let server = TimelineServer(1...10)
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((1...10).map { Self.note($0, [.home]) })
        await server.post(11...300)
        await server.fail(ask: 2)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        #expect(try await MastodonAccount(door: door, store: store).read() == false)
        #expect(await held(store) == Array(1...49))
        #expect(await store.note(Self.key(49))?.gaps == [TimelineGap(.newerRemain, in: .home)])
    }
}
