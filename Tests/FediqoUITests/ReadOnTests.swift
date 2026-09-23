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

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if let holding, url.query?.contains(holding) == true {
            parked += 1
            await gate.wait()
        }
        asked.append(url)
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

/// A microblog timeline read again reads on from where this device left it, and says where it
/// cannot (#201).
///
/// What a test can reach: what `r`, the wait and a place reached ask and in what order; what lands,
/// with no hole and no row twice; where the list says the timeline is not whole, in which
/// timelines, and in which words; and that the post being read stays. What it cannot: the row
/// drawn in light and dark on a Mac and a phone, a finger or VoiceOver on it — those live in a
/// lazy stack.
@MainActor
@Suite("A timeline read again reads on from where this device left it")
struct ReadOnTests {
    private static let one = "one.example"
    private static let source = Source(host: one, kind: .mastodon)
    private static let stretch = Stretch(host: one, category: .public)

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

    @Test("r with more new posts than a stretch holds brings every one, in order, with no hole; the post being read stays")
    func everyOneInOrder() async throws {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        let selected = Self.row(5)
        await server.post(11...100)

        await session.reload.timeline(.all, in: session)

        #expect(await server.cursors == ["min_id=9", "min_id=49", "min_id=89"])
        #expect(drawn(session) == Array((1...100).reversed()), "every one, newest first, none twice")
        let items = session.timelineItems(latest: nil)
        #expect(DummyCommand.focused(in: items, selected: selected) == .post(try #require(session.held(selected))))
        #expect(session.gapMarks(in: items).isEmpty, "whole, and nothing says otherwise")
        #expect(session.reload.line == nil)
    }

    @Test("Past the bound the place says more belong there; reaching it reads them, nothing moves, no row twice")
    func boundThenReachIt() async throws {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        await server.post(11...300)

        await session.reload.timeline(.all, in: session)
        let newest = try #require(drawn(session).first)
        #expect(newest < 300, "the bound stopped it short")
        #expect(drawn(session) == Array((1...newest).reversed()), "what came, came with no hole")
        let marks = session.gapMarks(in: session.timelineItems(latest: nil))
        #expect(marks == [Self.row(newest): TimelineGapMarks(above: [Self.stretch])], "said above the newest read")

        // Trends reads no public timeline, so it says nothing of one.
        session.timelineID = .trends
        #expect(session.gapMarks(in: session.timelineItems(latest: nil)).isEmpty)
        session.timelineID = nil

        // Reached — scrolled, walked or pressed to — as `r` lands too: both read on from the
        // same newest post, and nothing lands twice.
        let landed = session.reload.landed
        async let reached: Void = session.reload.readOn(Self.stretch, in: session)
        async let pressed: Void = session.reload.timeline(.all, in: session)
        _ = await (reached, pressed)
        #expect(drawn(session) == Array((1...300).reversed()), "every one, once each")
        #expect(session.gapMarks(in: session.timelineItems(latest: nil)).isEmpty, "read, and said no more")
        #expect(session.reload.landed <= landed + 1, "only r re-centres; reaching the place does not")
        #expect(session.reload.asking.isEmpty)
    }

    @Test("Reaching the place alone does not re-centre the list")
    func reachingDoesNotMove() async {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        await server.post(11...300)
        await session.reload.timeline(.all, in: session)
        let landed = session.reload.landed
        await session.reload.readOn(Self.stretch, in: session)
        #expect(session.reload.landed == landed)
        #expect(drawn(session).count == 300)
    }

    @Test("Where the source no longer gives back what lay between, the place says posts may be missing")
    func mayBeMissing() async {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        await server.post(11...60)
        await server.keep(from: 31)

        await session.reload.timeline(.all, in: session)

        #expect(drawn(session) == Array((31...60).reversed()) + Array((1...10).reversed()), "nothing invented")
        let marks = session.gapMarks(in: session.timelineItems(latest: nil))
        #expect(marks == [Self.row(31): TimelineGapMarks(below: [Self.stretch])], "said below the oldest it gave")
        #expect(session.reload.line == nil, "the source answered: nothing failed")
    }

    @Test("Listing as you go after a relaunch reads on below what was held, and leaves no hole")
    func moreAfterRelaunch() async throws {
        // Held from the last run: 51 to 60. While the app was closed, 61 to 200 arrived.
        let server = TimelineServer(host: Self.one, 1...200)
        let before = await store(holding: 51...60)
        let snapshot = await before.snapshot()
        let session = await shell(server, store: ItemStore(sources: snapshot.sources, notes: snapshot.notes))

        await session.reload.timeline(.all, in: session)
        #expect(drawn(session) == Array((51...200).reversed()), "today's newest reaches what was held")
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        #expect(drawn(session) == Array((1...200).reversed()), "and on below it, with no hole")
        #expect(await server.cursors.suffix(2) == ["max_id=51", "max_id=11"])
    }

    @Test("A place reached while an ask for more is out waits for it, then reads on")
    func reachedWhileMore() async throws {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        await server.post(11...300)
        await session.reload.timeline(.all, in: session)
        #expect(drawn(session).first == 209)

        await server.hold("max_id")
        let guardTask = hangGuard(server.gate)
        defer { guardTask.cancel() }
        let more = Task { await session.reload.more(.all, in: session) }
        #expect(await spun { await server.parked == 1 })
        await session.reload.readOn(Self.stretch, in: session)
        #expect(session.reload.asking == [.more], "not dropped, and not beside the other")
        await server.gate.open()
        await more.value
        #expect(await spun { drawn(session).first == 300 && session.reload.asking.isEmpty }, "read on once that one ended")
    }

    @Test("A place reached while r reads its source asks nothing: r reads it on from there")
    func reachedWhileR() async throws {
        let server = TimelineServer(host: Self.one, 1...10)
        let session = await shell(server, store: await store(holding: 1...10))
        await server.post(11...300)
        await session.reload.timeline(.all, in: session)

        await server.hold("min_id=208")
        let guardTask = hangGuard(server.gate)
        defer { guardTask.cancel() }
        let reload = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await server.parked == 1 })
        await session.reload.readOn(Self.stretch, in: session)
        #expect(session.reload.asking == [.timeline])
        await server.gate.open()
        await reload.value
        for _ in 0..<200 { await Task.yield() }
        #expect(drawn(session).first == 300)
        #expect(await server.cursors.filter { $0 == "min_id=208" }.count == 1, "asked once, by r")
    }

    @Test("The words are said in English and in 中文, naming the source, in every bundle")
    func words() throws {
        for kind in [TimelineGap.Kind.newerRemain, .mayBeMissing] {
            let english = TimelineGapRow.words(kind, host: Self.one, language: .english)
            let chinese = TimelineGapRow.words(kind, host: Self.one, language: .taiwanese)
            #expect(english.contains(Self.one) && chinese.contains(Self.one))
            #expect(english != chinese)
            #expect(!english.hasPrefix("timeline.gap"))
        }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let hant = try String(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"), encoding: .utf8)
        #expect(hant.contains("\"timeline.gap.more\"") && hant.contains("\"timeline.gap.missing\""))
    }
}
