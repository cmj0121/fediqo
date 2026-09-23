import Foundation
import Testing

@testable import FediqoCore

/// One Mastodon timeline, paged the way Mastodon pages it: the newest `limit` with nothing asked,
/// those before `max_id`, and the `limit` immediately after `min_id` — each newest first. What it
/// holds can be cut from below, as a home timeline is kept only so long.
///
/// **An HTTP client and a sender both**, so the public timeline, read unsigned, and Home, read as
/// you, are asked of the same fixture.
actor TimelineServer: HTTPClient, HTTPSender {
    private let host: String
    private var held: [Int]
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

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try answer(url)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try answer(request.url!)
    }

    private func answer(_ url: URL) throws -> (Data, HTTPURLResponse) {
        asked.append(url)
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
        let body = "[" + page.map { Self.status($0, host: host) }.joined(separator: ",") + "]"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    /// Status `id`, posted `id` minutes into 2024 — so a later id is a later post.
    static func status(_ id: Int, host: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let posted = formatter.string(from: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60))
        return """
            {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","created_at":"\(posted)",
             "content":"<p>\(id)</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
    }
}

/// A microblog timeline read again reads on from where this device left it (#201).
@Suite("A timeline read again reads on from where this device left it")
struct ReadOnTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    private static func note(_ id: Int, _ categories: Set<FediqoCore.Category> = [.public]) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60),
            categories: categories, statusID: "\(id)"
        )
    }

    private static func key(_ id: Int) -> NoteKey { note(id).key }

    /// A store holding `ids` of the public timeline, and a client reading `server`.
    private func store(holding ids: some Sequence<Int>) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(ids.map { Self.note($0) })
        return store
    }

    private func readPublic(_ store: ItemStore, from server: TimelineServer) async throws -> ReadOn {
        let anchor = await store.newestStatusID(host: Self.host, category: .public)
        let read = try await MastodonClient(http: server, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: anchor)
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

    @Test("More new posts than one stretch holds all arrive, in order, with no hole")
    func severalStretches() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...100)
        let read = try await readPublic(store, from: server)
        #expect(await server.cursors == ["min_id=9", "min_id=49", "min_id=89", "min_id=100"],
                "from one before the newest held, each stretch on from the newest the last brought")
        #expect(await held(store) == Array(1...100), "every one of them, and no hole")
        #expect(read.missingBelow == nil, "the source gave back the post it was read on from")
        #expect(read.newerRemainAbove == nil, "read until the source had nothing newer")
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
        let newest = try #require(await held(store).last)
        #expect(await held(store) == Array(1...newest), "what came, came with no hole")
        #expect(read.newerRemainAbove == Self.key(newest))
        #expect(await store.note(Self.key(newest))?.gaps == [TimelineGap(.newerRemain, in: .public)])

        let again = try await readPublic(store, from: server)
        #expect(await held(store) == Array(1...300))
        #expect(again.newerRemainAbove == nil)
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty }, "the place is read, and says so no more")
    }

    @Test("Where the source no longer has the post read on from, posts may be missing below what it gave")
    func mayBeMissing() async throws {
        let server = TimelineServer(1...10)
        let store = await store(holding: 1...10)
        await server.post(11...60)
        await server.keep(from: 31)
        let read = try await readPublic(store, from: server)
        #expect(read.missingBelow == Self.key(31))
        #expect(await held(store) == Array(1...10) + Array(31...60), "what it gave is here; nothing is invented")
        #expect(await store.note(Self.key(31))?.gaps == [TimelineGap(.mayBeMissing, in: .public)])

        _ = try await readPublic(store, from: server)
        #expect(await store.note(Self.key(31))?.gaps == [TimelineGap(.mayBeMissing, in: .public)],
                "a later read does not take it back: nothing it reads can show they were not")
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
            "https://\(Self.host)/api/v1/timelines/public?limit=40&min_id=9": .text("[" + TimelineServer.status(5, host: Self.host) + "]"),
        ])
        _ = try await MastodonClient(http: http, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: "10")
        #expect(await http.requested.count == 1)
    }

    // MARK: - The anchor

    @Test("The anchor is the newest of that timeline, by number, and never a post gone or only held aside")
    func anchor() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest([Self.note(9), Self.note(10), Self.note(50, [.home])])
        #expect(await store.newestStatusID(host: Self.host, category: .public) == "10")
        #expect(await store.newestStatusID(host: Self.host, category: .home) == "50")
        #expect(await store.newestStatusID(host: Self.host, category: .list(id: "7")) == nil)
        _ = await store.markGone(Self.key(10))
        #expect(await store.newestStatusID(host: Self.host, category: .public) == "9")
        await store.hold([Self.note(20)], ifSourceHere: Self.host)
        #expect(await store.newestStatusID(host: Self.host, category: .public) == "9")
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
        #expect(await server.cursors == ["min_id=9", "min_id=60", "min_id=100", "min_id=120"])
        #expect(await held(store) == Array(1...10) + Array(21...120))
        #expect(await store.note(Self.key(21))?.gaps == [TimelineGap(.mayBeMissing, in: .home)])
        #expect(await server.asked.allSatisfy { $0.path == "/api/v1/timelines/home" })
    }
}
