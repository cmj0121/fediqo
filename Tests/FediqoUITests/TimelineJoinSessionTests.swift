import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #372: a source added later joins the timelines the reader already wrote — kept once over what the device holds
/// now, and read at once for what they want of it.
@MainActor
@Suite("A source joining the timelines already written, from the session", .watched)
struct TimelineJoinSessionTests {
    private static let a = "a.example"
    private static let y = "y.example"

    private static func publicAddress(_ host: String) -> String {
        "https://\(host)/api/v1/timelines/public?limit=40"
    }

    private static func trendsAddress(_ host: String) -> String {
        "https://\(host)/api/v1/trends/statuses?limit=20"
    }

    private static func timeline(_ host: String, _ id: String) -> FixtureHTTP.Outcome {
        .text("""
        [{"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
          "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
          "account":{"username":"ada","acct":"ada","display_name":"Ada"}}]
        """)
    }

    private static var routes: [String: FixtureHTTP.Outcome] {
        [
            publicAddress(a): timeline(a, "1"),
            trendsAddress(a): timeline(a, "4"),
            publicAddress(y): timeline(y, "2"),
            trendsAddress(y): timeline(y, "3"),
            MastodonInstance.address(a): MastodonInstance.mastodon(a),
            MastodonInstance.address(y): MastodonInstance.mastodon(y),
        ]
    }

    private static let sources = [Source(host: a, kind: .mastodon), Source(host: y, kind: .mastodon)]

    /// Only A's public: what a timeline written before Y came reads.
    private static func onlyA(_ name: String = "Mine") -> TimelineDefinition {
        TimelineDefinition(name: name, rules: [
            Rule.source(a)!, Rule.category(.public, in: .source(host: a), sources: sources)!,
        ])
    }

    private func shell(
        kept: [TimelineDefinition], defaults: CountingDefaults = CountingDefaults(),
        routes: [String: FixtureHTTP.Outcome] = routes, wire: (any HTTPClient)? = nil
    ) async -> (ShellSession, FixtureHTTP, WrittenTimelineStore) {
        let fixture = FixtureHTTP(routes)
        let http = wire ?? fixture
        let store = ItemStore()
        for source in Self.sources { await store.add(source) }
        let timelines = WrittenTimelineStore(defaults: defaults)
        timelines.save(kept)
        let session = ShellSession(
            http: http, store: store, mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Refuse()),
            posts: ForumPosts(http: http), timelines: timelines
        )
        session.deadlinesUnturned()
        session.work = SourceWork()
        await session.reloadFromStore()
        session.written = kept
        return (session, fixture, timelines)
    }

    private func kept(_ store: WrittenTimelineStore) -> [TimelineDefinition]? {
        guard case .timelines(let kept) = store.load() else { return nil }
        return kept
    }

    @Test("Nothing chosen does nothing: the kept timelines are not even read")
    func nothingChosen() async {
        let mine = Self.onlyA()
        let defaults = CountingDefaults()
        let (session, http, store) = await shell(kept: [mine], defaults: defaults)
        defaults.set("no build wrote this", forKey: store.key)
        let saves = defaults.sets
        await session.joinTimelines([:], host: Self.y)
        #expect(!session.timelinesUnreadable, "nothing chosen reads nothing, so finds nothing unreadable")
        #expect(defaults.sets == saves)
        #expect(session.written == [mine])
        #expect(await http.requested.isEmpty)
    }

    @Test("Kept timelines read again whole say they are readable again")
    func readableAgain() async throws {
        let mine = Self.onlyA()
        let (session, _, store) = await shell(kept: [mine])
        session.timelinesUnreadable = true
        await session.joinTimelines([mine.id: [.public]], host: Self.y)
        #expect(!session.timelinesUnreadable)
        #expect(try #require(kept(store)) == session.written)
        #expect(session.written != [mine])
    }

    @Test("The re-ask leaves what the last wait said of another source standing, and says what it found of Y")
    func waitsFailureStands() async {
        let wire = JoinWire(Self.routes)
        let mine = Self.onlyA()
        let (session, _, _) = await shell(kept: [mine], wire: wire)
        await wire.down(Self.a)
        await session.reload.held(in: session)
        #expect(session.reload.failed == [Self.a], "the premise: the wait could not read A")

        await wire.down(Self.y)
        await session.joinTimelines([mine.id: [.public]], host: Self.y)
        #expect(session.reload.failed == [Self.a, Self.y], "A as the wait said it, and Y as the re-ask found it")

        await wire.up(Self.y)
        await session.reload.joined(FetchAsk(host: Self.y, categories: [.public]), in: session)
        #expect(session.reload.failed == [Self.a], "Y read now is not still failing; A still is")
    }

    @Test("An r landing while the re-ask is on the wire clears what it read, and the re-ask does not bring it back")
    func rLandingDuringTheReAsk() async throws {
        let wire = JoinWire(Self.routes, holding: Self.publicAddress(Self.y))
        let guarding = watching(wire.gate, "Y's public, held on the wire")
        defer { guarding.cancel() }
        let mine = Self.onlyA()
        let wholeA = TimelineDefinition(name: "A", rules: [Rule.source(Self.a)!])
        let (session, _, _) = await shell(kept: [mine, wholeA], wire: wire)
        await wire.down(Self.a)
        await session.reload.held(in: session)
        #expect(session.reload.failed == [Self.a], "the premise: the wait could not read A")

        await wire.up(Self.a)
        await wire.hold()
        let joining = Task { await session.joinTimelines([mine.id: [.public]], host: Self.y) }
        #expect(await met("the re-ask is held on the wire", by: joining) { await wire.reached })
        await session.reload.timeline(.written(wholeA.id), in: session)
        #expect(session.reload.failed.isEmpty, "r read A whole")

        await wire.gate.open()
        await joining.value
        #expect(session.reload.failed.isEmpty, "the re-ask left A as r left it")
        #expect(session.notes.contains { $0.source.host == Self.y })
    }

    @Test("The re-ask is every category the joined timelines want of Y, or its usual reads where any wants those")
    func reAskCategories() {
        func timeline(_ rules: [Rule?]) -> TimelineDefinition { TimelineDefinition(name: "t", rules: rules.map { $0! }) }
        let publicY = timeline([Rule.category(.public, in: .source(host: Self.y), sources: Self.sources)])
        let homeY = timeline([Rule.category(.home, in: .source(host: Self.y), sources: Self.sources)])
        let wholeY = timeline([Rule.source(Self.a), Rule.source(Self.y)])
        #expect(ShellSession.ask(Self.y, joining: [publicY, homeY], sources: Self.sources)
            == FetchAsk(host: Self.y, categories: [.public, .home]))
        #expect(ShellSession.ask(Self.y, joining: [publicY, wholeY], sources: Self.sources)
            == FetchAsk(host: Self.y, categories: nil))
        #expect(ShellSession.ask(Self.y, joining: [Self.onlyA()], sources: Self.sources) == nil)
    }

    @Test("Chosen: kept once over what is kept now, adopted, and Y asked once for what the joined timeline wants")
    func joinsOverTheKeptCopy() async throws {
        let mine = Self.onlyA()
        let other = Self.onlyA("Other")
        let defaults = CountingDefaults()
        let (session, http, store) = await shell(kept: [mine, other], defaults: defaults)
        // Another window renamed the other timeline and kept it after this one read them.
        var renamed = other
        renamed.name = "Renamed elsewhere"
        store.save([mine, renamed])
        let saves = defaults.sets

        await session.joinTimelines([mine.id: [.public]], host: "Y.example")

        #expect(defaults.sets == saves + 1, "kept once")
        let joined = try #require(kept(store))
        #expect(joined.map(\.id) == [mine.id, other.id])
        #expect(joined[1].name == "Renamed elsewhere", "the other window's change is not written over")
        #expect(Set(joined[0].rules.map(\.kind)) == Set(mine.rules.map(\.kind)).union([
            .source(host: Self.y), .category(.public, in: .source(host: Self.y)),
        ]))
        #expect(session.written == joined)
        let asked = await http.requested.map(\.absoluteString)
        #expect(asked.filter { $0 == Self.publicAddress(Self.y) }.count == 1)
        #expect(!asked.contains(Self.trendsAddress(Self.y)), "asked for what the timeline wants, not its usual reads")
        #expect(!asked.contains { $0.contains(Self.a) }, "only the source that joined is asked")
        #expect(session.notes.contains { $0.source.host == Self.y })
    }

    @Test("A choice that adds nothing keeps nothing and asks nobody")
    func choiceAddingNothing() async {
        let mine = Self.onlyA()
        let defaults = CountingDefaults()
        let (session, http, store) = await shell(kept: [mine], defaults: defaults)
        let saves = defaults.sets
        await session.joinTimelines([mine.id: []], host: Self.y)
        #expect(defaults.sets == saves)
        #expect(kept(store) == [mine])
        #expect(await http.requested.isEmpty)
    }

    @Test("Timelines that cannot be read are not written over, and say so")
    func unreadable() async {
        let mine = Self.onlyA()
        let defaults = CountingDefaults()
        let (session, http, store) = await shell(kept: [mine], defaults: defaults)
        defaults.set("no build wrote this", forKey: store.key)
        let saves = defaults.sets
        await session.joinTimelines([mine.id: [.public]], host: Self.y)
        #expect(session.timelinesUnreadable)
        #expect(defaults.sets == saves)
        #expect(defaults.object(forKey: store.key) as? String == "no build wrote this")
        #expect(session.written == [mine])
        #expect(await http.requested.isEmpty)
    }

    @Test("Offers are the core's for this session's sources, and none while the timelines cannot be read")
    func offers() async {
        let mine = Self.onlyA()
        let (session, _, _) = await shell(kept: [mine])
        #expect(session.timelineJoinOffers(host: Self.y).map(\.id) == [mine.id])
        #expect(session.timelineJoinOffers(host: Self.y).first?.divisions == [TimelineJoinDivision(category: .public, locked: false)])
        #expect(session.joinsTimelines(host: Self.y))
        session.timelinesUnreadable = true
        #expect(session.timelineJoinOffers(host: Self.y).isEmpty)
        #expect(!session.joinsTimelines(host: Self.y))
    }
}

/// The suite's routes, with any host put out of reach and back, and one address held behind a gate.
private actor JoinWire: HTTPClient {
    private let inner: FixtureHTTP
    private let held: String?
    private var gone: Set<String> = []
    let gate = Gate()
    private var holding = false
    private(set) var reached = false

    init(_ routes: [String: FixtureHTTP.Outcome], holding held: String? = nil) {
        inner = FixtureHTTP(routes)
        self.held = held
    }

    func down(_ host: String) { gone.insert(host) }
    func up(_ host: String) { gone.remove(host) }
    /// From now on the held address waits for the gate.
    func hold() { holding = true }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if let host = url.host, gone.contains(host), url.path != "/api/v2/instance" { throw FixtureHTTPError.unreachable }
        if holding, url.absoluteString == held {
            reached = true
            await gate.wait()
        }
        return try await inner.data(from: url)
    }
}

/// Defaults whose values live in this object only, counting each value set.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private(set) var sets = 0

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) {
        sets += 1
        values[key] = value
    }
    override func removeObject(forKey key: String) { values[key] = nil }
}

/// A signed-in door that answers every request with a refusal.
private struct Refuse: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
}
