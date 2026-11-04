import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon answering as Mastodon pages a timeline: the newest `limit` with nothing asked, those
/// before `max_id`, and the `limit` immediately after `min_id` — each newest first. What it holds
/// can be cut from below, as a home timeline is kept only so long. It is a Mastodon when asked
/// what it is, and has nothing trending.
///
/// `FediqoCoreTests`' `TimelineServer`'s twin, as `FixtureHTTP` is: this target cannot see that one.
actor TimelineServer: HTTPClient {
    private let host: String
    private var held: [Int]
    private(set) var asked: [URL] = []
    /// A query the next ask carrying it waits on `gate` for, where one is set.
    private var holding: String?
    /// A query every ask carrying it fails on, where one is set.
    private var refusing: String?
    /// Whether an ask of the public timeline's newest stretch — no `min_id`, no `max_id` — fails.
    private var refusingNewest = false
    let gate = Gate()
    /// How many asks reached `gate`.
    private(set) var parked = 0

    init(host: String, _ ids: some Sequence<Int>) {
        self.host = host
        held = Array(ids)
    }

    /// The paging each timeline ask named, in order: `min_id=5`, `max_id=9`, or `newest`.
    var cursors: [String] {
        asked.filter { $0.path.hasPrefix("/api/v1/timelines/") }.map { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "min_id" || $0.name == "max_id" }.map { "\($0.name)=\($0.value!)" }
                ?? "newest"
        }
    }

    func post(_ ids: some Sequence<Int>) { held += ids }

    /// Keeps only what is `lowest` or newer: everything older is let go.
    func keep(from lowest: Int) { held = held.filter { $0 >= lowest } }

    /// Holds the asks whose query carries `query` until the gate opens.
    func hold(_ query: String) { holding = query }

    /// Fails every ask whose query carries `query`, or none where nil.
    func refuse(_ query: String?) { refusing = query }

    /// Fails every ask of the newest stretch where `refused`: a read on that reaches its bound
    /// then cannot catch up, and says newer remain above the newest it read, as before #283.
    func refuseNewest(_ refused: Bool) { refusingNewest = refused }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if let holding, url.query?.contains(holding) == true {
            parked += 1
            await gate.wait()
        }
        asked.append(url)
        if let refusing, url.query?.contains(refusing) == true { throw URLError(.timedOut) }
        if refusingNewest, url.path == "/api/v1/timelines/public",
           url.query?.contains("min_id") != true, url.query?.contains("max_id") != true {
            throw URLError(.timedOut)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        if url.path == "/api/v2/instance" {
            return (Data(#"{"domain":"\#(host)","title":"\#(host)","version":"4.3.1"}"#.utf8), response)
        }
        guard url.path == "/api/v1/timelines/public" else { return (Data("[]".utf8), response) }
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
        return (Data(("[" + page.map(status).joined(separator: ",") + "]").utf8), response)
    }

    private func status(_ id: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let posted = formatter.string(from: ReadOnTests.posted(id))
        return """
            {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","created_at":"\(posted)",
             "content":"<p>\(id)</p>","visibility":"public",
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
    }
}

/// A timeline read again reads its newest posts, and reading it down goes on from the oldest of
/// them, each source on its own (#470).
///
/// What a test can reach: what `r` and an ask for more ask and in what order, what lands, and that
/// the post being read stays. What it cannot: the rows drawn in light and dark on a Mac and a
/// phone, a finger or VoiceOver on them — those live in a lazy stack.
@MainActor
@Suite("A timeline read again reads its newest, and reading it down goes on from there", .watched)
struct ReadOnTests {
    private static let one = "one.example"
    private static let source = Source(host: one, kind: .mastodon)

    nonisolated static func posted(_ id: Int) -> Date {
        Date(timeIntervalSince1970: 1_704_067_200 + Double(id) * 60)
    }

    private static func note(_ id: Int) -> Note {
        Note(
            id: "https://\(one)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: posted(id), categories: [.public], statusID: "\(id)",
            listed: [.public: "\(id)"]
        )
    }

    private static func row(_ id: Int) -> String { note(id).key.rowID }

    /// A session over `store`, reading through `server`.
    private func shell(_ server: TimelineServer, store: ItemStore) async -> ShellSession {
        let session = ShellSession(
            http: server, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        session.deadlineSleep = TurnedClock().sleep
        await session.reloadFromStore()
        return session
    }

    /// A store holding `ids` of one.example's public timeline.
    private func store(holding ids: some Sequence<Int>) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(ids.map(Self.note))
        return store
    }

    /// The ids the timeline in front draws, top to bottom.
    private func drawn(_ session: ShellSession) -> [Int] {
        session.timelineItems(latest: nil).compactMap { $0.statusID.flatMap(Int.init) }
    }

    @Test("r reads the newest alone, whatever was held below it, and the post being read stays")
    func newestAlone() async throws {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        let selected = Self.row(5)
        await server.post(11...100)

        await session.reload.timeline(.all, in: session)

        #expect(await server.cursors == ["newest"])
        #expect(drawn(session) == Array((61...100).reversed()) + Array((1...10).reversed()), "what lies between is not read on to")
        let items = session.timelineItems(latest: nil)
        #expect(DummyCommand.focused(in: items, selected: selected) == .post(try #require(session.held(selected))))
        #expect(session.reload.line == nil)
    }

    @Test("Scrolling down reads on from the oldest post r brought, then from the oldest each read down brought")
    func downFromTheNewest() async throws {
        let server = TimelineServer(host: Self.one, 1...100)
        let session = await shell(server, store: await store(holding: 1...10))
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await server.cursors == ["newest", "max_id=61", "max_id=21"])
        #expect(drawn(session) == Array((1...100).reversed()), "no hole, and no row twice")
    }

    @Test("r again starts the place over: posts already held below are asked for again as they are reached")
    func startsOver() async throws {
        let server = TimelineServer(host: Self.one, 1...100)
        let session = await shell(server, store: await store(holding: []))
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await server.cursors == ["newest", "max_id=61", "newest", "max_id=61"])
    }

    @Test("With nothing read yet this run, scrolling down asks nothing: there is no place to read down from")
    func noPlaceYet() async {
        let server = TimelineServer(host: Self.one, 1...100)
        let session = await shell(server, store: await store(holding: 61...100))
        await session.reload.more(.all, in: session)
        #expect(await server.cursors.isEmpty)
    }

    @Test("The source having no more there, scrolling down asks nothing again until r")
    func ended() async {
        let server = TimelineServer(host: Self.one, 1...50)
        let session = await shell(server, store: await store(holding: []))
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await server.cursors == ["newest", "max_id=11", "max_id=1"], "nothing older than 1: it has no more")
        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(await server.cursors.suffix(2) == ["newest", "max_id=11"])
    }

    @Test("Each source reads down from its own place")
    func perSource() async {
        let two = "two.example"
        let server = TimelineServer(host: Self.one, 1...100)
        let store = await store(holding: [])
        await store.add(Source(host: two, kind: .mastodon))
        let session = await shell(server, store: store)
        await store.landNewest((1...5).map(Self.note), of: .public, ifSourceHere: Self.one)
        await store.landNewest([Note(
            id: "https://\(two)/users/bo/statuses/700", source: Source(host: two, kind: .mastodon), author: "Bo", handle: "@bo",
            body: "700", postedAt: Self.posted(700), categories: [.public], statusID: "700", listed: [.public: "700"]
        )], of: .public, ifSourceHere: two)
        await session.reloadFromStore()
        let places = await ShellReload.places(.all, in: session)
        #expect(places[Stretch(host: Self.one, category: .public)] == ReadDownPlace(id: "1"))
        #expect(places[Stretch(host: two, category: .public)] == ReadDownPlace(id: "700"))
    }
}
