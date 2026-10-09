import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Several Mastodons answering for their notices, each by host, path and the id asked before,
/// and remembering what they were asked. A source with no gathered read routed answers 404 to
/// it, as one older than that read does.
private actor NoticeSources: HTTPSender {
    enum Outcome: Sendable {
        case body(String)
        case status(Int)
        /// Answers only once the gate opens — and, as a real transport does, not at all to a
        /// request whose asker walked away meanwhile.
        case held(Gate, String, Int = 200)
    }

    private var routes: [String: Outcome]
    private(set) var asked: [String] = []

    init(_ routes: [String: Outcome]) {
        self.routes = routes
    }

    func set(_ key: String, _ outcome: Outcome?) {
        routes[key] = outcome
    }

    /// What was asked of the single read, which is the one these sources answer with.
    var reads: [String] { asked.filter { $0.contains("/api/v1/notifications") } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FixtureHTTPError.unmapped
        }
        let before = parts.queryItems?.first { $0.name == "max_id" }?.value
        let key = "\(parts.host ?? "")\(parts.path)" + (before.map { "?\($0)" } ?? "")
        asked.append(key)
        func answer(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch routes[key] {
        case .body(let body)?: return answer(body)
        case .status(let status)?: return answer(#"{"error":"no"}"#, status)
        case .held(let gate, let body, let status)?:
            await gate.wait()
            try Task.checkCancellation()
            return answer(body, status)
        case nil:
            if parts.path == "/api/v2/notifications" { return answer(#"{"error":"Not Found"}"#, 404) }
            throw FixtureHTTPError.unmapped
        }
    }
}

/// A token store that can be locked: who is signed in and what their sign-in may do is still
/// answered, as it is off the items' attributes, and no token can be read.
private final class LockableTokens: MastodonTokenStore, @unchecked Sendable {
    private let held = MemoryMastodonTokens()
    private let lock = NSLock()
    private var isLocked = false

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    func token(host: String) throws -> MastodonToken? {
        if locked { throw ForumCredentialError.keychain(-25_308) }
        return try held.token(host: host)
    }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func bookmarking() throws -> Set<String> { try held.bookmarking() }
    func bookmarksRefused() throws -> Set<String> { try held.bookmarksRefused() }
    func noticing() throws -> Set<String> { try held.noticing() }
    func dismissing() throws -> Set<String> { try held.dismissing() }
    func noticesRefused() throws -> Set<String> { try held.noticesRefused() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

@MainActor
@Suite("Every signed-in source's notices as one list")
struct NoticeListTests {
    private static let a = "a.example"
    private static let b = "b.example"
    private static let v1 = "/api/v1/notifications"
    private static let v2 = "/api/v2/notifications"
    private static let reads = MastodonOAuth.scopes(writing: false, notices: true)

    /// One notice of the single read, at `minute` past the hour.
    private static func one(_ id: Int, at minute: Int, type: String = "favourite") -> String {
        """
        {"id":"\(id)","type":"\(type)","created_at":"\(String(format: "2024-06-01T00:%02d:00.000Z", minute))",
         "account":{"id":"1","username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func body(_ notices: [String]) -> String {
        "[" + notices.joined(separator: ",") + "]"
    }

    private static func page(_ notices: String...) -> NoticeSources.Outcome {
        .body(body(notices))
    }

    /// One line of the gathered read: `count` favourites of one post, the page reaching down to `low`.
    private static func gathered(count: Int, newest: Int, low: Int, at minute: Int) -> NoticeSources.Outcome {
        .body("""
        {"accounts":[],"statuses":[],"notification_groups":[{"group_key":"favourite-9-1",
         "notifications_count":\(count),"type":"favourite","most_recent_notification_id":\(newest),
         "page_min_id":"\(low)","page_max_id":"\(newest)",
         "latest_page_notification_at":"\(String(format: "2024-06-01T00:%02d:00.000Z", minute))",
         "sample_account_ids":[]}]}
        """)
    }

    /// A reads from 50 down to 20 in two stretches, B from 45 down to 5 in two — B's first
    /// stretch reaching below A's.
    private static let two: [String: NoticeSources.Outcome] = [
        "\(a)\(v1)": page(one(4, at: 50), one(3, at: 40)),
        "\(a)\(v1)?3": page(one(2, at: 30), one(1, at: 20)),
        "\(a)\(v1)?1": page(),
        "\(b)\(v1)": page(one(8, at: 45), one(7, at: 10)),
        "\(b)\(v1)?7": page(one(6, at: 5)),
        "\(b)\(v1)?6": page(),
    ]

    /// A session holding each of `hosts` as a Mastodon, signed in with `scopes` where it names any.
    private func shell(
        _ routes: [String: NoticeSources.Outcome], signedIn hosts: [String: String?] = [a: reads, b: reads],
        tokens: any MastodonTokenStore = MemoryMastodonTokens()
    ) async throws -> (ShellSession, NoticeSources, any MastodonTokenStore) {
        for (host, scopes) in hosts {
            guard let scopes else { continue }
            try tokens.save(Self.token(host, scopes: scopes))
        }
        let server = NoticeSources(routes)
        let store = ItemStore(sources: hosts.keys.sorted().map { Source(host: $0, kind: .mastodon) }, notes: [])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        session.noticeList.deadline = .seconds(5)
        return (session, server, tokens)
    }

    private static func token(_ host: String, _ access: String? = nil, scopes: String = reads) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: access ?? "tok-\(host)", clientID: "cid", clientSecret: "csecret", scopes: scopes
        )
    }

    /// Each line as its host's first letter and its id: `a4`.
    private func drawn(_ lines: [Notice]) -> [String] {
        lines.map { "\($0.source.host.prefix(1))\($0.newestID)" }
    }

    private static func minute(_ minute: Int) -> Date {
        ISO8601DateFormatter().date(from: String(format: "2024-06-01T00:%02d:00Z", minute))!
    }

    // MARK: - Who is asked, and when

    @Test("Nothing is asked until the page reads, and then only the sources whose sign-in may read notices")
    func onlyAllowedSourcesAreAskedAndOnlyOnARead() async throws {
        let plain = MastodonOAuth.scopes(writing: false)
        let (session, server, _) = try await shell(
            Self.two, signedIn: [Self.a: Self.reads, Self.b: Self.reads, "c.example": plain, "d.example": nil]
        )
        for _ in 0..<50 { await Task.yield() }
        #expect(await server.asked.isEmpty, "a source was asked with nobody reading")
        #expect(ShellNoticeList.asked(in: session).map(\.host) == [Self.a, Self.b])

        await session.noticeList.read(in: session)

        #expect(Set(await server.asked) == [
            "\(Self.a)\(Self.v2)", "\(Self.a)\(Self.v1)", "\(Self.b)\(Self.v2)", "\(Self.b)\(Self.v1)",
        ])
        #expect(session.noticeList.standing(host: "c.example") == .unread)
        #expect(!session.noticeList.isReading)
    }

    @Test("A read asked for while one is on the wire waits on it, and reads again where a source may be asked that it did not ask")
    func aSourceAllowedMeanwhileIsAsked() async throws {
        let gate = Gate()
        var routes = Self.two
        routes["\(Self.a)\(Self.v1)"] = .held(gate, Self.body([Self.one(4, at: 50), Self.one(3, at: 40)]))
        let (session, server, tokens) = try await shell(
            routes, signedIn: [Self.a: Self.reads, Self.b: MastodonOAuth.scopes(writing: false)]
        )
        let list = session.noticeList

        let first = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 1 })
        let second = Task { await list.read(in: session) }
        for _ in 0..<50 { await Task.yield() }
        #expect(await server.reads.count == 1, "a second read went out beside the first")
        try tokens.save(Self.token(Self.b))
        session.mastodon.refresh()
        await gate.open()
        await first.value
        await second.value

        #expect(await server.reads.contains("\(Self.b)\(Self.v1)"), "the source allowed meanwhile was not asked")
        #expect(drawn(list.lines) == ["a4", "b8", "a3"])

        // And where nothing changed, the one read serves both.
        let asked = await server.asked.count
        let gated = Gate()
        await server.set("\(Self.b)\(Self.v1)", .held(gated, Self.body([Self.one(8, at: 45), Self.one(7, at: 10)])))
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(4, at: 50), Self.one(3, at: 40)))
        let third = Task { await list.read(in: session) }
        #expect(await spun { await server.asked.count == asked + 2 })
        let fourth = Task { await list.read(in: session) }
        for _ in 0..<50 { await Task.yield() }
        await gated.open()
        await third.value
        await fourth.value
        #expect(await server.asked.count == asked + 2)
    }

    // MARK: - The merge and the cut

    @Test("Two sources stand as one list in time order, cut at the latest moment both have reached")
    func mergedAndCutWhereEverySourceHasReached() async throws {
        let (session, _, _) = try await shell(Self.two)
        let list = session.noticeList

        await list.read(in: session)

        // A has reached :40 and B :10, and both have more: below :40 A has not been asked.
        #expect(list.floor == Self.minute(40))
        #expect(drawn(list.lines) == ["a4", "b8", "a3"])
        #expect(list.reaches[Self.b]?.notices.map(\.newestID) == ["8", "7"], "what lies below the cut was let go of")
        #expect(list.lines.map(\.source.host) == [Self.a, Self.b, Self.a], "a line lost its source")
        #expect(list.hasMore(in: session))
        #expect(list.failures.isEmpty)
    }

    @Test("Nothing of a first read is drawn until every source asked has answered or failed, so no line drawn is taken back")
    func aFirstReadIsDrawnOnceEverySourceHasAnswered() async throws {
        let gate = Gate()
        var routes = Self.two
        // A is the one out: B's stretch reaches below where A's will stop the list.
        routes["\(Self.a)\(Self.v1)"] = .held(gate, Self.body([Self.one(4, at: 50), Self.one(3, at: 40)]))
        let (session, _, _) = try await shell(routes)
        let list = session.noticeList

        let reading = Task { await list.read(in: session) }
        #expect(await spun { list.standing(host: Self.b) == .read })

        #expect(list.lines.isEmpty, "a line was drawn that a later answer could take back")
        #expect(list.isReading && list.readingHosts == [Self.a])
        #expect(!list.hasMore(in: session))
        await gate.open()
        await reading.value

        #expect(drawn(list.lines) == ["a4", "b8", "a3"])
        #expect(list.readingHosts.isEmpty)
    }

    @Test("Reading on asks only the source the list stops at, and held lines appear as the others catch up")
    func readingOnReachesOlderOnesFromEach() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)

        await list.readOn(in: session)
        #expect(await server.reads.suffix(1) == ["\(Self.a)\(Self.v1)?3"], "a source read further down was asked again")
        #expect(list.floor == Self.minute(20))
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1"])

        // A has no more: it stops holding the list, and B's held line stands.
        await list.readOn(in: session)
        #expect(await server.reads.suffix(1) == ["\(Self.a)\(Self.v1)?1"])
        #expect(list.floor == Self.minute(10))
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7"])

        await list.readOn(in: session)
        #expect(await server.reads.suffix(1) == ["\(Self.b)\(Self.v1)?7"])
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7", "b6"])

        await list.readOn(in: session)
        #expect(list.floor == nil && !list.hasMore(in: session))
        let asked = await server.asked.count
        await list.readOn(in: session)
        #expect(await server.asked.count == asked, "a source with no more was asked past its end")
        #expect(await server.asked.filter { $0.contains(Self.v2) }.count == 2, "a source was asked twice which read it has")
    }

    @Test("A second reading on while one is on the wire asks nothing")
    func readingOnTwiceAsksOnce() async throws {
        let gate = Gate()
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await server.set("\(Self.a)\(Self.v1)?3", .held(gate, Self.body([Self.one(2, at: 30), Self.one(1, at: 20)])))

        let first = Task { await list.readOn(in: session) }
        #expect(await spun { await server.reads.last == "\(Self.a)\(Self.v1)?3" })
        #expect(!list.hasMore(in: session), "the foot offered to ask while it was asking")
        await list.readOn(in: session)
        await gate.open()
        await first.value

        #expect(await server.reads.filter { $0.hasSuffix("?3") }.count == 1)
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1"])
    }

    @Test("A gathered line the source cut at a page edge comes back folded into the line held")
    func aGatheredLineIsFoldedOnReadingOn() async throws {
        let (session, _, _) = try await shell([
            "\(Self.a)\(Self.v2)": Self.gathered(count: 3, newest: 6, low: 5, at: 30),
            "\(Self.a)\(Self.v2)?5": Self.gathered(count: 1, newest: 4, low: 4, at: 20),
            "\(Self.a)\(Self.v2)?4": .body(#"{"accounts":[],"statuses":[],"notification_groups":[]}"#),
        ], signedIn: [Self.a: Self.reads])
        let list = session.noticeList

        await list.read(in: session)
        await list.readOn(in: session)

        #expect(list.lines.count == 1, "one line was drawn twice")
        #expect(list.lines.first?.count == 3)
        #expect(list.lines.first?.oldestID == "4" && list.lines.first?.at == Self.minute(30))
        #expect(list.reaches[Self.a]?.gathered == true)
    }

    @Test("A source that answers reading on with nothing older is at its end")
    func aSourceThatIgnoresTheAskEnds() async throws {
        let (session, server, _) = try await shell([
            "\(Self.a)\(Self.v1)": Self.page(Self.one(4, at: 50)),
            "\(Self.a)\(Self.v1)?4": Self.page(Self.one(4, at: 50)),
        ], signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        await list.read(in: session)

        await list.readOn(in: session)

        #expect(drawn(list.lines) == ["a4"])
        #expect(!list.hasMore(in: session) && list.floor == nil)
        let asked = await server.asked.count
        await list.readOn(in: session)
        #expect(await server.asked.count == asked)
    }

    // MARK: - Read again from the top

    @Test("Read again, a source whose newest stretch meets what is held keeps how far down it was read")
    func aTopThatMeetsWhatIsHeldKeepsTheDepth() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1"])

        // A new notice at the top, and 4 gone at the source: the stretch still names 3.
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(5, at: 55), Self.one(3, at: 40)))
        await list.read(in: session)

        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["5", "3", "2", "1"])
        #expect(list.reaches[Self.a]?.before == "1", "the depth read to was forgotten")
        #expect(list.floor == Self.minute(20))
        #expect(drawn(list.lines) == ["a5", "b8", "a3", "a2", "a1"])
        #expect(await server.reads.suffix(2).sorted() == ["\(Self.a)\(Self.v1)", "\(Self.b)\(Self.v1)"])
    }

    @Test("Read again, a source whose newest stretch meets nothing held is cut there: the stretch between was never read")
    func aTopThatMeetsNothingReplaces() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)

        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(9, at: 59), Self.one(8, at: 58)))
        await list.read(in: session)

        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["9", "8"])
        #expect(list.reaches[Self.a]?.before == "8")
        #expect(list.floor == Self.minute(58))
        #expect(drawn(list.lines) == ["a9", "a8"], "a line stood below a stretch nobody read")
    }

    @Test("A gathered line held from further down that gains a notice does not join the new top to the old depth: only its name is shared")
    func aSharedGroupNameIsNotAMeeting() async throws {
        let (session, server, _) = try await shell([
            "\(Self.a)\(Self.v2)": Self.gathered(count: 2, newest: 6, low: 5, at: 30),
            "\(Self.b)\(Self.v1)": Self.page(Self.one(8, at: 45), Self.one(7, at: 10)),
        ])
        let list = session.noticeList
        await list.read(in: session)
        #expect(list.floor == Self.minute(30) && drawn(list.lines) == ["b8", "a6"])

        // The same group, come back at the top: notices 7 to 18 lie between, read by nobody.
        await server.set("\(Self.a)\(Self.v2)", Self.gathered(count: 3, newest: 20, low: 19, at: 50))
        await list.read(in: session)

        let line = try #require(list.reaches[Self.a]?.notices.first)
        #expect(list.reaches[Self.a]?.notices.count == 1)
        #expect(line.newestID == "20" && line.oldestID == "19", "the new top was joined to a depth it does not reach")
        #expect(list.reaches[Self.a]?.before == "19")
        #expect(list.floor == Self.minute(50), "the list went on below a stretch nobody read")
        #expect(drawn(list.lines) == ["a20"])
    }

    @Test("A gathered line come back in a stretch that reaches down to the newest notice held is folded, and the depth kept")
    func aGatheredTopThatReachesWhatIsHeldIsJoined() async throws {
        let (session, server, _) = try await shell([
            "\(Self.a)\(Self.v2)": Self.gathered(count: 2, newest: 6, low: 5, at: 30),
            "\(Self.a)\(Self.v2)?5": Self.gathered(count: 1, newest: 4, low: 3, at: 20),
        ], signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)
        #expect(list.floor == Self.minute(20), "how far down a source was read was taken off a folded line")

        await server.set("\(Self.a)\(Self.v2)", Self.gathered(count: 4, newest: 8, low: 6, at: 50))
        await list.read(in: session)

        let line = try #require(list.reaches[Self.a]?.notices.first)
        #expect(list.reaches[Self.a]?.notices.count == 1)
        #expect(line.newestID == "8" && line.oldestID == "3" && line.count == 4)
        #expect(list.reaches[Self.a]?.before == "3", "the depth read to was forgotten")
        #expect(list.floor == Self.minute(20))
    }

    // MARK: - A source that fails or refuses

    @Test("A source refused after it was read down keeps what it had, stays named, and stops holding the list, so the others are read on")
    func aSourceRefusedAtDepthStopsHoldingTheList() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)
        await server.set("\(Self.a)\(Self.v1)?1", .status(403))

        await list.readOn(in: session)

        #expect(list.failures.map(\.host) == [Self.a] && list.failures.first?.why == .refused)
        #expect(session.mastodon.notices(host: Self.a) == .unavailable)
        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["4", "3", "2", "1"])
        #expect(list.floor == Self.minute(10), "a source nobody can ask held the list")
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7"])

        #expect(list.hasMore(in: session))
        await list.readOn(in: session)
        #expect(await server.reads.last == "\(Self.b)\(Self.v1)?7")
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7", "b6"])
        #expect(list.failures.map(\.host) == [Self.a], "the source stopped being named")
    }

    @Test("A 401 at depth from a source still signed in and still allowed keeps holding the list, and asking by name asks it again")
    func aRefusalThatLeavesTheSourceAskableHoldsTheList() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)
        let older = "\(Self.a)\(Self.v1)?1"
        await server.set(older, .status(401))
        await server.set("\(Self.a)/api/v1/accounts/verify_credentials", .body(#"{"id":"1","acct":"me"}"#))

        await list.readOn(in: session)

        #expect(list.standing(host: Self.a) == .failed(.refused))
        #expect(session.mastodon.isSignedIn(host: Self.a) && session.mastodon.notices(host: Self.a) == .allowed)
        #expect(list.floor == Self.minute(20), "a source that can be asked again let the list go on below it")
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1"])
        #expect(!list.hasMore(in: session))

        await server.set(older, Self.page())
        await list.retry(host: Self.a, in: session)
        #expect(await server.reads.last == older)
        #expect(list.failures.isEmpty && list.floor == Self.minute(10))
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7"])
    }

    @Test("A source whose sign-in may no longer read notices is named as refused at the next read, and does not hold the list")
    func aSourceNoLongerAllowedStopsHoldingTheList() async throws {
        let (session, server, tokens) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        #expect(list.floor == Self.minute(40))

        try tokens.save(Self.token(Self.a, scopes: MastodonOAuth.scopes(writing: false)))
        session.mastodon.refresh()
        let asked = await server.asked.filter { $0.hasPrefix(Self.a) }.count
        await list.readOn(in: session)

        #expect(await server.asked.filter { $0.hasPrefix(Self.a) }.count == asked)
        #expect(list.standing(host: Self.a) == .failed(.refused))
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "b7", "b6"])
    }

    @Test("One source failing is named, keeps what it had and still holds the list where it stood, and the others land")
    func aFailingSourceIsNamedAndNothingIsEmptied() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)

        await server.set("\(Self.a)\(Self.v1)", .status(503))
        await server.set("\(Self.b)\(Self.v1)", Self.page(Self.one(9, at: 55), Self.one(8, at: 45)))
        await list.read(in: session)

        #expect(list.failures.map(\.host) == [Self.a] && list.failures.first?.why == .unreachable)
        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["4", "3"], "a failure emptied what was held")
        #expect(list.floor == Self.minute(40))
        #expect(drawn(list.lines) == ["b9", "a4", "b8", "a3"])
        #expect(!list.isReading)

        // Asked again by name, it is asked for what failed: its newest.
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(4, at: 50), Self.one(3, at: 40)))
        await list.retry(host: Self.a, in: session)
        #expect(await server.reads.last == "\(Self.a)\(Self.v1)")
        #expect(list.failures.isEmpty)
        #expect(drawn(list.lines) == ["b9", "a4", "b8", "a3"])
    }

    @Test("A source that fails reading on keeps its depth and holds the list there, is not asked by the foot, and is asked again by name")
    func aSourceThatFailsReadingOnIsRetriedByName() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        let older = "\(Self.a)\(Self.v1)?3"
        await server.set(older, .status(429))

        await list.readOn(in: session)

        #expect(list.failures.map(\.host) == [Self.a])
        #expect(list.failures.first?.why == .unreachable, "too many requests was said as a refusal")
        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["4", "3"] && list.reaches[Self.a]?.before == "3")
        #expect(list.floor == Self.minute(40), "a line stood below what the failed source was not asked for")
        #expect(drawn(list.lines) == ["a4", "b8", "a3"])

        #expect(!list.hasMore(in: session))
        let asked = await server.asked.count
        await list.readOn(in: session)
        #expect(await server.asked.count == asked, "the foot asked a source that failed")

        await server.set(older, Self.page(Self.one(2, at: 30), Self.one(1, at: 20)))
        await list.retry(host: Self.a, in: session)
        #expect(await server.reads.last == older, "it was not asked from where it stood")
        #expect(list.failures.isEmpty)
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1"])

        // A source that did not fail is not asked by name.
        let after = await server.asked.count
        await list.retry(host: Self.b, in: session)
        #expect(await server.asked.count == after)
    }

    @Test("A source that cannot be reached on the first read is named while the other's notices stand")
    func aSourceDarkFromTheStartIsNamed() async throws {
        var routes = Self.two
        routes["\(Self.a)\(Self.v1)"] = nil
        let (session, _, _) = try await shell(routes)
        let list = session.noticeList

        await list.read(in: session)

        #expect(list.standing(host: Self.a) == .failed(.unreachable))
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    @Test("A 403 from a sign-in that says it may read notices is remembered for the run, and the source is not asked again")
    func aRefusalIsToldToTheSignIn() async throws {
        var routes = Self.two
        routes["\(Self.a)\(Self.v2)"] = .status(403)
        let (session, server, tokens) = try await shell(routes)
        let list = session.noticeList

        await list.read(in: session)

        #expect(list.failures.map(\.host) == [Self.a] && list.failures.first?.why == .refused)
        #expect(session.mastodon.notices(host: Self.a) == .unavailable)
        #expect(session.mastodon.isSignedIn(host: Self.a), "a refusal signed the reader out")
        #expect(try tokens.token(host: Self.a)?.scopes == Self.reads, "a refusal rewrote what the sign-in holds")
        #expect(drawn(list.lines) == ["b8", "b7"])

        let asked = await server.asked.filter { $0.hasPrefix(Self.a) }.count
        await list.read(in: session)
        await list.retry(host: Self.a, in: session)
        #expect(await server.asked.filter { $0.hasPrefix(Self.a) }.count == asked)
        #expect(list.standing(host: Self.a) == .failed(.refused), "the source stopped being named")
    }

    @Test("A sign-in the server ended is told as one, and what that source said goes with it")
    func anEndedSignInLetsGo() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)

        await server.set("\(Self.a)\(Self.v1)", .status(401))
        await server.set("\(Self.a)/api/v1/accounts/verify_credentials", .status(401))
        await list.read(in: session)

        #expect(!session.mastodon.isSignedIn(host: Self.a))
        #expect(session.mastodon.ended == [Self.a])
        #expect(list.reaches[Self.a] == nil && list.failures.isEmpty)
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    @Test("A source whose token cannot be read is not asked, and the foot does not offer what it would not ask")
    func aLockedTokenIsNotOfferedAtTheFoot() async throws {
        let locking = LockableTokens()
        let (session, server, _) = try await shell([
            "\(Self.a)\(Self.v1)": Self.page(Self.one(4, at: 50)),
            "\(Self.a)\(Self.v1)?4": Self.page(Self.one(3, at: 40)),
        ], signedIn: [Self.a: Self.reads], tokens: locking)
        let list = session.noticeList
        await list.read(in: session)
        #expect(list.hasMore(in: session))
        let asked = await server.asked.count

        locking.locked = true
        await list.readOn(in: session)

        #expect(await server.asked.count == asked)
        #expect(!list.hasMore(in: session), "the foot offers a reading on that asks nobody")
        #expect(drawn(list.lines) == ["a4"] && list.failures.isEmpty)

        locking.locked = false
        await list.read(in: session)
        #expect(list.hasMore(in: session))
    }

    // MARK: - Let go of, stopped, replaced

    @Test("Signing out of a source, or clearing it, takes its notices before the server is asked anything, and an answer on its way lands nowhere", arguments: [false, true])
    func aSignOutTakesItsNotices(clearing: Bool) async throws {
        let gate = Gate()
        let revoke = Gate()
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        await server.set("\(Self.a)\(Self.v1)", .held(gate, Self.body([Self.one(5, at: 58)])))
        await server.set("\(Self.a)/oauth/revoke", .held(revoke, "{}"))

        let reading = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 4 })
        #expect(list.isReading)
        let leaving = Task {
            if clearing { await session.clear(host: Self.a) } else { await session.signOut(host: Self.a) }
        }
        #expect(await spun { await server.asked.contains("\(Self.a)/oauth/revoke") })
        #expect(list.reaches[Self.a] == nil, "the notices stood while the server was asked to forget the sign-in")
        #expect(drawn(list.lines) == ["b8", "b7"])
        await revoke.open()
        await leaving.value
        await gate.open()
        await reading.value

        #expect(list.reaches[Self.a] == nil)
        #expect(drawn(list.lines) == ["b8", "b7"])
        #expect(!list.isReading)
    }

    @Test("A sign-in the server ended elsewhere takes its notices as it is told")
    func aSignInEndedElsewhereTakesItsNotices() async throws {
        let (session, _, tokens) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)

        try tokens.forget(host: Self.a)
        session.mastodon.endedByServer(host: Self.a)

        #expect(list.reaches[Self.a] == nil)
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    @Test("A source whose reader is no longer the one its notices were read as lets go of them")
    func aChangedReaderTakesTheirNotices() async throws {
        let (session, _, tokens) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)

        try tokens.forget(host: Self.a)
        session.mastodon.refresh()
        #expect(list.reaches[Self.a] != nil)
        await session.forgetReaderMarksDue()

        #expect(list.reaches[Self.a] == nil)
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    @Test("A read that is stopped leaves every source as it was")
    func aStoppedReadChangesNothing() async throws {
        let gate = Gate()
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        let before = list.reaches
        await server.set("\(Self.a)\(Self.v1)", .held(gate, Self.body([Self.one(5, at: 58)])))
        await server.set("\(Self.b)\(Self.v1)", .held(gate, Self.body([Self.one(9, at: 59)])))

        let reading = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 4 })
        #expect(list.stop())
        #expect(list.reaches == before && !list.isReading)
        await gate.open()
        await reading.value

        #expect(list.reaches == before, "an answer to a stopped read landed")
        #expect(drawn(list.lines) == ["a4", "b8", "a3"])
        #expect(!list.stop())
    }

    @Test("The reader walking away from a read is not a source failing")
    func walkingAwayIsNotAFailure() async throws {
        let gate = Gate()
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        await list.read(in: session)
        let before = list.reaches
        await server.set("\(Self.a)\(Self.v1)", .held(gate, Self.body([Self.one(5, at: 58)])))
        await server.set("\(Self.b)\(Self.v1)", .held(gate, Self.body([Self.one(9, at: 59)])))

        let reading = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 4 })
        reading.cancel()
        await gate.open()
        await reading.value

        #expect(list.failures.isEmpty, "a walk away was said as a failure")
        #expect(list.reaches == before && !list.isReading)
        #expect(drawn(list.lines) == ["a4", "b8", "a3"])
    }

    @Test("An answer asked with a sign-in since replaced is not laid on the one held now")
    func anAnswerToAReplacedSignInIsDropped() async throws {
        let gate = Gate()
        var routes = Self.two
        routes["\(Self.a)\(Self.v1)"] = .held(gate, Self.body([Self.one(4, at: 50)]))
        let (session, server, tokens) = try await shell(routes)
        let list = session.noticeList

        let reading = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 2 })
        try tokens.save(Self.token(Self.a, "tok-other"))
        await gate.open()
        await reading.value

        #expect(list.reaches[Self.a] == nil, "somebody else's notices were drawn")
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    @Test("A failure or a refusal that comes back about a sign-in since replaced says nothing of the one held now", arguments: [503, 403, 401])
    func aFailureOfAReplacedSignInIsDropped(status: Int) async throws {
        let gate = Gate()
        var routes = Self.two
        routes["\(Self.a)\(Self.v1)"] = .held(gate, #"{"error":"no"}"#, status)
        routes["\(Self.a)/api/v1/accounts/verify_credentials"] = .status(401)
        let (session, server, tokens) = try await shell(routes)
        let list = session.noticeList

        let reading = Task { await list.read(in: session) }
        #expect(await spun { await server.reads.count == 2 })
        try tokens.save(Self.token(Self.a, "tok-other"))
        await gate.open()
        await reading.value

        #expect(list.failures.isEmpty, "the sign-in held now was named for another's failure")
        #expect(list.reaches[Self.a] == nil)
        #expect(session.mastodon.isSignedIn(host: Self.a) && session.mastodon.ended.isEmpty)
        #expect(session.mastodon.notices(host: Self.a) == .allowed)
        #expect(try tokens.token(host: Self.a)?.accessToken == "tok-other")
        #expect(drawn(list.lines) == ["b8", "b7"])
    }

    // MARK: - Narrowing

    @Test("A narrowed kind is hidden with nothing asked, every unknown kind goes under one word, and the choice holds after a relaunch")
    func aNarrowedKindIsHiddenAndKept() async throws {
        let name = "fediqo.test.notices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Constructing prefs sets the shell's language from what is kept; English, as every
        // other suite here sets it, so a run in parallel is not moved.
        defaults.set("en", forKey: "fediqo.dummy.language")
        let (session, server, _) = try await shell([
            "\(Self.a)\(Self.v1)": Self.page(
                Self.one(5, at: 50, type: "mention"), Self.one(4, at: 40), Self.one(3, at: 30, type: "status"),
                Self.one(2, at: 20, type: "quoted_update"), Self.one(1, at: 10, type: "admin.report")
            ),
            "\(Self.a)\(Self.v1)?1": Self.page(),
        ], signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        await list.read(in: session)
        let asked = await server.asked.count

        #expect(DummyPrefs(defaults: defaults).noticesHidden.isEmpty, "every kind is shown by default")
        #expect(drawn(list.shown(hiding: DummyPrefs(defaults: defaults).noticesHidden)) == ["a5", "a4", "a3", "a2", "a1"])

        let prefs = DummyPrefs(defaults: defaults)
        prefs.noticesHidden = [Notice.Kind.favourite.narrowedAs, Notice.Kind.unknown("status").narrowedAs]
        #expect(drawn(list.shown(hiding: prefs.noticesHidden)) == ["a5", "a1"])
        #expect(list.lines.count == 5, "narrowing let go of what is held")
        #expect(await server.asked.count == asked, "narrowing asked a source")

        let relaunched = DummyPrefs(defaults: defaults)
        #expect(relaunched.noticesHidden == ["favourite", "unknown"])
        #expect(drawn(list.shown(hiding: relaunched.noticesHidden)) == ["a5", "a1"])

        relaunched.noticesHidden = []
        #expect(DummyPrefs(defaults: defaults).noticesHidden.isEmpty)
    }

    // MARK: - The bound

    @Test("Reading on stops where a source is held to the most kept of one for a run, the foot says so and not that there are no more, and a reload still reads the newest")
    func aSourceIsHeldToABound() async throws {
        #expect(ShellNoticeList.capacity == 2_000)
        let (session, server, _) = try await shell(Self.two, signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        #expect(list.capacity == ShellNoticeList.capacity)
        list.capacity = 3

        await list.read(in: session)
        #expect(drawn(list.lines) == ["a4", "a3"])
        #expect(!list.isFull && NoticesPane.foot(in: session) == .more)

        // The next stretch brings the fourth line: the newest three stay, and reading on ends.
        await list.readOn(in: session)
        #expect(drawn(list.lines) == ["a4", "a3", "a2"])
        #expect(list.reaches[Self.a]?.notices.count == 3, "more is held of one source than the bound")
        #expect(list.isFull && !list.hasMore(in: session) && list.floor == nil)
        #expect(NoticesPane.foot(in: session) == .full, "the foot says there are no more, and there are")
        let asked = await server.asked.count
        await list.readOn(in: session)
        #expect(await server.asked.count == asked, "a source held to the bound was read on")

        // A reload reads the newest, joined to what is held, and the bound still holds.
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(5, at: 55), Self.one(4, at: 50), Self.one(3, at: 40)))
        await list.read(in: session)
        #expect(drawn(list.lines) == ["a5", "a4", "a3"])
        #expect(list.standing(host: Self.a) == .read && list.failures.isEmpty)
        #expect(list.isFull && NoticesPane.foot(in: session) == .full)
        await list.readOn(in: session)
        #expect(await server.asked.count == asked + 1, "only the reload asked")

        // One joined to nothing held starts the source again: it is read on as any is.
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(20, at: 58), Self.one(19, at: 57)))
        await server.set("\(Self.a)\(Self.v1)?19", Self.page(Self.one(18, at: 56)))
        await list.read(in: session)
        #expect(drawn(list.lines) == ["a20", "a19"])
        #expect(!list.isFull && NoticesPane.foot(in: session) == .more)
        await list.readOn(in: session)
        #expect(drawn(list.lines) == ["a20", "a19", "a18"])
        #expect(list.isFull, "a source with more at the bound is read on past it")
    }

    /// Groups of the gathered read: each a key, its newest id, the lowest id of the group on
    /// this page, and its minute.
    private static func groups(_ lines: [(key: String, newest: Int, low: Int, at: Int)]) -> NoticeSources.Outcome {
        .body(#"{"accounts":[],"statuses":[],"notification_groups":["# + lines.map {
            """
            {"group_key":"\($0.key)","notifications_count":2,"type":"favourite","most_recent_notification_id":\($0.newest),
             "page_min_id":"\($0.low)","page_max_id":"\($0.newest)",
             "latest_page_notification_at":"\(String(format: "2024-06-01T00:%02d:00.000Z", $0.at))","sample_account_ids":[]}
            """
        }.joined(separator: ",") + "]}")
    }

    /// A gathered source whose second line reaches down to id 3 — below the third line's 6.
    private static let reaching: [String: NoticeSources.Outcome] = [
        "\(a)\(v2)": groups([("g1", 10, 9, 50), ("g2", 8, 3, 40), ("g3", 6, 5, 30)]),
        // Asked before the second line's newest: its older members, and the line below it.
        "\(a)\(v2)?8": groups([("g2", 7, 3, 40), ("g3", 6, 5, 30)]),
    ]

    @Test("A gathered source at the bound resumes from its last kept line's newest notice: the line left out below it is asked for again, none skipped and none twice")
    func theBoundResumesAGatheredSource() async throws {
        let (session, server, _) = try await shell(Self.reaching, signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        list.capacity = 2
        await list.read(in: session)
        #expect(list.lines.map(\.id).map { $0.suffix(2) } == ["g1", "g2"] && list.isFull)
        #expect(list.reaches[Self.a]?.notices.last?.oldestID == "3", "the premise: the kept line reaches below the one left out")

        list.took(try #require(list.lines.first))
        await list.readOn(in: session)

        #expect(await server.asked.suffix(1) == ["\(Self.a)\(Self.v2)?8"], "asked below the line left out")
        #expect(list.failures.isEmpty)
        #expect(list.lines.map(\.id).map { $0.suffix(2) } == ["g2", "g3"])
    }

    @Test("A gathered source stopped at the months limit resumes, under a longer limit, from its last kept line's newest notice: the line the limit left out is asked for again, none skipped and none twice")
    func theLimitResumesAGatheredSource() async throws {
        let (session, server, _) = try await shell(Self.reaching, signedIn: [Self.a: Self.reads])
        let list = session.noticeList
        let now = ISO8601DateFormatter().date(from: "2024-07-01T00:35:00Z")!
        await session.keep(months: 1, from: now)
        await list.read(in: session)
        #expect(list.lines.map(\.id).map { $0.suffix(2) } == ["g1", "g2"])
        #expect(list.isAtLimit && !list.hasMore(in: session) && NoticesPane.foot(in: session) == .limit)

        await session.keep(months: 3, from: now)
        #expect(list.hasMore(in: session))
        await list.readOn(in: session)

        #expect(await server.asked.suffix(1) == ["\(Self.a)\(Self.v2)?8"], "asked below the line left out")
        #expect(list.failures.isEmpty)
        #expect(list.lines.map(\.id).map { $0.suffix(2) } == ["g1", "g2", "g3"])
    }

    @Test("A source at the bound is not read on even where another source stops the list at the very moment it was read down to")
    func aFullSourceAtTheFloorIsNotReadOn() async throws {
        var routes = Self.two
        // A reaches the bound at :30 after its second stretch; B's first stretch stops at :30 too.
        routes["\(Self.b)\(Self.v1)"] = Self.page(Self.one(8, at: 45), Self.one(7, at: 30))
        let (session, server, _) = try await shell(routes)
        let list = session.noticeList
        list.capacity = 3
        await list.read(in: session)
        await list.readOn(in: session)
        #expect(list.fullHosts == [Self.a])
        #expect(list.reaches[Self.a]?.reached == Self.minute(30) && list.floor == Self.minute(30), "the premise: the two meet")

        await list.readOn(in: session)

        #expect(await server.reads.suffix(1) == ["\(Self.b)\(Self.v1)?7"])
        #expect(await server.reads.filter { $0.hasPrefix(Self.a) }.count == 2, "a source at the bound was read on")
    }

    @Test("A source read to its own end at the bound has no more, and is not said to be held short; another source is read on beside one that is")
    func theBoundIsOneSourcesOwn() async throws {
        var end = ShellNoticeList.Reach()
        end.notices = (0..<3).map {
            Notice(source: Source(host: Self.a, kind: .mastodon), handle: .one(id: "\($0)"), kind: .favourite, people: [],
                   at: Self.minute($0), newestID: "\($0)", oldestID: "\($0)")
        }
        end.bound(to: 3)
        #expect(!end.full && end.notices.count == 3)
        end.before = "0"
        end.bound(to: 3)
        #expect(end.full && end.before == "0" && end.holds == nil, "full keeps where it stopped, and does not hold the list")
        end.empty()
        #expect(!end.full)

        // A reaches the bound with more to give; B, under the same bound, is read on to its end.
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        list.capacity = 4
        await list.read(in: session)
        await list.readOn(in: session)
        #expect(list.reaches[Self.a]?.full == true && list.reaches[Self.b]?.full == false)
        #expect(list.floor == Self.minute(10), "a source held to the bound still holds the list up")
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7"])
        #expect(NoticesPane.foot(in: session) == .more)
        await list.readOn(in: session)
        await list.readOn(in: session)
        #expect(await server.reads.suffix(2) == ["\(Self.b)\(Self.v1)?7", "\(Self.b)\(Self.v1)?6"])
        #expect(drawn(list.lines) == ["a4", "b8", "a3", "a2", "a1", "b7", "b6"])
        #expect(list.reaches[Self.b]?.full == false && !list.hasMore(in: session))
        #expect(NoticesPane.foot(in: session) == .full)
    }

    @Test("A source held to the bound is named above the list from the moment it is, while the others are read on; reading it afresh takes the name down")
    func aFullSourceIsNamed() async throws {
        let (session, server, _) = try await shell(Self.two)
        let list = session.noticeList
        list.capacity = 4
        await list.read(in: session)
        #expect(list.fullHosts.isEmpty && NoticesPane.lines(in: session).isEmpty)

        // A reaches the bound while B still has more: named at once, and the foot still reads on.
        await list.readOn(in: session)
        #expect(list.reaches[Self.a]?.holds == nil, "a full source held the list, and stopped the others")
        #expect(list.fullHosts == [Self.a])
        #expect(NoticesPane.lines(in: session) == [.full(host: Self.a)])
        #expect(NoticesPane.foot(in: session) == .more)
        #expect(NoticesPane.standsOut(.full(host: Self.a)) && !NoticesPane.isFailure(.full(host: Self.a)))
        #expect(
            NoticesLine.full(host: Self.a).words(language: .english)
                == "Fediqo holds as many notices from a.example as it keeps of one source: its older notices are not shown, and may belong among the lines below. They are read again once there is room — when notices are dismissed, or the months limit lets old ones go."
        )
        #expect(NoticesLine.full(host: Self.a).words(language: .taiwanese).contains(Self.a))
        #expect(
            NoticesLine.full(host: Self.a).words(language: .taiwanese) != NoticesLine.full(host: Self.a).words(language: .english)
        )

        // Every source done: the name stands, and the foot says the limit too.
        await list.readOn(in: session)
        await list.readOn(in: session)
        #expect(NoticesPane.lines(in: session) == [.full(host: Self.a)] && NoticesPane.foot(in: session) == .full)

        // Named after what failed, before what was never asked.
        let lines = NoticesLine.lines(
            reading: [], failures: [(Self.b, .unreachable)], askable: [Self.b],
            hosts: [("c.example", .unasked)], full: [Self.a]
        )
        #expect(lines == [.failed(host: Self.b, why: .unreachable, again: true), .full(host: Self.a), .unasked(host: "c.example")])

        // Read afresh from a top joined to nothing held, the source starts again, unnamed.
        await server.set("\(Self.a)\(Self.v1)", Self.page(Self.one(20, at: 58)))
        await list.read(in: session)
        #expect(list.fullHosts.isEmpty && NoticesPane.lines(in: session).isEmpty)
    }
}
