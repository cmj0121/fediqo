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

/// A timeline read again reads its newest posts, and reading it down goes on from the oldest of
/// them, each source and timeline on its own (#470).
@Suite("A timeline read again reads its newest, and reading it down goes on from there")
struct ReadOnTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    /// Post `id` as a read of `categories` listed it.
    private static func note(_ id: Int, _ categories: Set<FediqoCore.Category> = [.public]) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60),
            categories: categories, statusID: "\(id)",
            listed: Dictionary(uniqueKeysWithValues: categories.map { ($0, "\(id)") })
        )
    }

    private func held(_ store: ItemStore) async -> [Int] {
        await store.all().compactMap { $0.statusID.flatMap(Int.init) }.sorted()
    }

    /// A store of the one source, holding `ids` as Home listed them, and the account reading it.
    private func home(holding ids: some Sequence<Int>, on server: TimelineServer) async throws -> (ItemStore, MastodonAccount) {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(ids.map { Self.note($0, [.home]) })
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (store, MastodonAccount(door: door, store: store))
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

    // MARK: - The newest

    @Test("A read asks for the newest alone, whatever is held below; nothing is said of what lies between, and reading down starts at its oldest")
    func newest() async throws {
        let server = TimelineServer(1...120)
        let (store, account) = try await home(holding: 1...10, on: server)
        #expect(try await account.read())
        #expect(await server.cursors == ["newest"])
        #expect(await held(store) == Array(1...10) + Array(81...120))
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "81"))
        #expect(await store.all().allSatisfy { $0.gaps.isEmpty }, "no place is said to be missing anything")
    }

    @Test("Read again, the place starts over at the newest read's oldest, however far down it was read")
    func startsOver() async throws {
        let server = TimelineServer(1...120)
        let (store, account) = try await home(holding: [], on: server)
        _ = try await account.read()
        _ = try await account.older(.home, than: "81")
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "41"))
        await server.post(121...130)
        _ = try await account.read()
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "91"))
    }

    // MARK: - Reading down

    @Test("Read down from the place, the posts older than it are asked again even where they are held, and the place moves to the oldest brought")
    func down() async throws {
        let server = TimelineServer(1...120)
        let (store, account) = try await home(holding: 1...80, on: server)
        _ = try await account.read()
        let brought = try await account.older(.home, than: "81")
        #expect(await server.cursors == ["newest", "max_id=81"])
        #expect(brought.compactMap { $0.statusID.flatMap(Int.init) }.sorted() == Array(41...80), "held already, and asked all the same")
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "41"))
    }

    @Test("Nothing older brought, the source has no more there: the place stays, said to have ended")
    func end() async throws {
        let server = TimelineServer(1...30)
        let (store, account) = try await home(holding: [], on: server)
        _ = try await account.read()
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "1"))
        _ = try await account.older(.home, than: "1")
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "1", ended: true))
        _ = try await account.read()
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "1"), "read again, it is asked again")
    }

    @Test("A read down that lands after the newest was read again leaves the place to that read")
    func outrun() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.landNewest((81...120).map { Self.note($0) }, of: .public, ifSourceHere: Self.host)
        await store.landNewest((91...130).map { Self.note($0) }, of: .public, ifSourceHere: Self.host)
        await store.landOlder((41...80).map { Self.note($0) }, of: .public, below: "81", ifSourceHere: Self.host)
        #expect(await store.readDownPlace(host: Self.host, category: .public) == ReadDownPlace(id: "91"))
        #expect(await held(store).contains(41), "what it brought is taken in all the same")
    }

    // MARK: - Each on its own

    @Test("Each timeline of each source has its own place: one read leaves the others where they are")
    func eachOnItsOwn() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let store = ItemStore()
        await store.add(Self.source)
        await store.add(other)
        await store.landNewest((81...120).map { Self.note($0, [.home]) }, of: .home, ifSourceHere: Self.host)
        let read = try await MastodonClient(http: TimelineServer(1...60), host: Self.host).publicTimeline(source: Self.source)
        await store.landNewest(read, of: .public, ifSourceHere: Self.host)
        #expect(await store.readDownPlace(host: Self.host, category: .home) == ReadDownPlace(id: "81"))
        #expect(await store.readDownPlace(host: Self.host, category: .public) == ReadDownPlace(id: "21"))
        #expect(await store.readDownPlace(host: "other.example", category: .home) == nil)
    }

    @Test("A source removed keeps no place, and one removed while its read was out gets nothing back")
    func removed() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.landNewest((81...120).map { Self.note($0) }, of: .public, ifSourceHere: Self.host)
        _ = await store.remove(host: Self.host)
        #expect(await store.readDownPlace(host: Self.host, category: .public) == nil)
        await store.landNewest((81...120).map { Self.note($0) }, of: .public, ifSourceHere: Self.host)
        #expect(await store.all().isEmpty)
        #expect(await store.readDownPlace(host: Self.host, category: .public) == nil)
    }
}
