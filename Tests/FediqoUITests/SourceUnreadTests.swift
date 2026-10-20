import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source whose reads keep failing says so where the person reads (#371): on its row and its
/// detail, and on each timeline drawn from what of it is failing — after `UnreadRuns.rounds`
/// rounds in a row, and no longer once a read goes through.
@MainActor
@Suite("A source whose reads keep failing says so", .watched)
struct SourceUnreadTests {
    private static let one = "one.example"
    private static let two = "two.example"
    private static let forum = "forum.example"
    private static let since = Date(timeIntervalSince1970: 1_790_000_000)

    init() {
        L10n.language = .english
    }

    private static func timeline(_ host: String, _ ids: String...) -> FixtureHTTP.Outcome {
        .text("[" + ids.map { id in
            """
            {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
             "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }.joined(separator: ",") + "]")
    }

    private static func publicAddress(_ host: String) -> String { "https://\(host)/api/v1/timelines/public?limit=40" }
    private static func trendsAddress(_ host: String) -> String { "https://\(host)/api/v1/trends/statuses?limit=20" }
    private static let boardAddress = "https://\(forum)/forum.php?mod=forumdisplay&fid=34&filter=author&orderby=dateline"

    private static let board = FixtureHTTP.Outcome.text(#"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=34">工具箱讨论区</a></h1>
    <table id="threadlisttableid">
    <tbody id="normalthread_40125"><tr>
    <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">工具箱一键下载安装</a></th>
    <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
    <td class="num"><a href="forum.php?mod=viewthread&tid=40125" class="xi2">7</a><em>120</em></td>
    </tr></tbody>
    </table></body></html>
    """#)

    /// Every route the three sources' usual reads take, answering.
    private static var everything: [String: FixtureHTTP.Outcome] {
        [
            publicAddress(one): timeline(one, "1"),
            publicAddress(one) + "&min_id=0": timeline(one, "1"),
            trendsAddress(one): timeline(one, "2"),
            publicAddress(two): timeline(two, "3"),
            publicAddress(two) + "&min_id=2": timeline(two, "3"),
            trendsAddress(two): timeline(two, "4"),
            boardAddress: board,
            MastodonInstance.address(one): MastodonInstance.mastodon(one),
            MastodonInstance.address(two): MastodonInstance.mastodon(two),
        ]
    }

    /// Two Mastodons and a Discuz! reading board 34, over `http`, its rounds ended at `since`.
    private func shell(
        _ http: any HTTPClient, mastodon: MastodonSessions = MastodonSessions(tokens: MemoryMastodonTokens(), sender: Answers()),
        lists: [ListSubscription] = []
    ) async -> ShellSession {
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon, lists: lists))
        await store.add(Source(host: Self.two, kind: .mastodon))
        await store.add(Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "工具箱讨论区")]
        ))
        let session = ShellSession(http: http, store: store, mastodon: mastodon, posts: ForumPosts(http: http))
        session.deadlinesUnturned()
        session.work = SourceWork()
        session.reload.now = { Self.since }
        await session.reloadFromStore()
        return session
    }

    private func written(_ name: String, _ category: FediqoCore.Category, of host: String, in session: ShellSession) throws -> TimelineQuery {
        let definition = TimelineDefinition(name: name, rules: [
            try #require(Rule.category(category, in: .source(host: host), sources: session.sources)),
        ])
        session.written.append(definition)
        return .written(definition.id)
    }

    private static func when(_ language: DummyLanguage = .english) -> String {
        since.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(L10n.locale(language)))
    }

    // MARK: - The count, as a rule

    @Test("A division failed in fewer rounds than the count says nothing; at the count it says since the first and why the last")
    func theCount() {
        var runs = UnreadRuns()
        let later = Self.since.addingTimeInterval(120)
        for round in 0..<UnreadRuns.rounds {
            #expect(runs.said(Self.one).isEmpty, "after \(round) rounds")
            runs.round(
                Self.one, asked: nil, read: false,
                failed: [.of(.home): round == 0 ? .refused : .outOfReach],
                at: round == 0 ? Self.since : later
            )
        }
        #expect(UnreadRuns.rounds == 3)
        #expect(runs.said(Self.one) == [.of(.home): UnreadRuns.Run(rounds: 3, since: Self.since, why: .outOfReach)])
        #expect(runs.said(Self.two).isEmpty, "only the source that failed")
    }

    @Test("A failure once, then a read, is never said; the word goes on the first read, and comes back only after the same run")
    func resetOnRead() {
        var runs = UnreadRuns()
        for _ in 0..<10 {
            runs.round(Self.one, asked: nil, read: false, failed: [.whole: .outOfReach], at: Self.since)
            runs.round(Self.one, asked: nil, read: true, failed: [:], at: Self.since)
            #expect(runs.said(Self.one).isEmpty)
        }
        for _ in 0..<3 { runs.round(Self.one, asked: nil, read: false, failed: [.whole: .outOfReach], at: Self.since) }
        #expect(!runs.said(Self.one).isEmpty)
        runs.round(Self.one, asked: nil, read: true, failed: [:], at: Self.since)
        #expect(runs.said(Self.one).isEmpty, "gone on the first read that goes through")
        #expect(!runs.saysAny)
        for _ in 0..<2 { runs.round(Self.one, asked: nil, read: false, failed: [.whole: .outOfReach], at: Self.since) }
        #expect(runs.said(Self.one).isEmpty, "two failures are not the run")
        runs.round(Self.one, asked: nil, read: false, failed: [.whole: .outOfReach], at: Self.since)
        #expect(!runs.said(Self.one).isEmpty)
    }

    @Test("A round that asked only some of a source counts only those; a failure naming nothing counts against the whole")
    func onlyWhatWasAsked() {
        var runs = UnreadRuns()
        for _ in 0..<3 { runs.round(Self.one, asked: nil, read: false, failed: [.of(.home): .outOfReach], at: Self.since) }
        // A timeline of its public timeline alone read it: Home was not asked, and still fails.
        runs.round(Self.one, asked: [.public], read: true, failed: [:], at: Self.since)
        #expect(runs.said(Self.one).keys.contains(.of(.home)))
        runs.round(Self.one, asked: [.home], read: true, failed: [:], at: Self.since)
        #expect(runs.said(Self.one).isEmpty)
        for _ in 0..<3 { runs.round(Self.two, asked: nil, read: false, failed: [:], at: Self.since) }
        #expect(runs.said(Self.two) == [.whole: UnreadRuns.Run(rounds: 3, since: Self.since, why: .outOfReach)])
        runs.forget(Self.two)
        #expect(runs.said(Self.two).isEmpty, "a source let go of says nothing")
    }

    @Test("Why, in three words: refused, out of reach, not understood")
    func theWhy() {
        let refused: [any Error] = [
            MastodonAuthError.signedOut, MastodonAuthError.http(403), MastodonRequestError.http(401),
            MastodonRequestError.http(422), MastodonScopeError.outside, DiscuzRequestError.challenged,
            DiscuzRequestError.restricted, DiscuzRequestError.refused(403), DiscourseRequestError.refused(401),
        ]
        let reach: [any Error] = [
            URLError(.timedOut), URLError(.notConnectedToInternet), MastodonAuthError.http(503),
            MastodonRequestError.http(500), MastodonRequestError.http(429), DiscuzRequestError.refused(503),
            ForumTransportError.timedOut, ForumTransportError.unreachable("x"), FixtureHTTPError.unreachable,
        ]
        let understood: [any Error] = [
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")), DiscuzRequestError.undecodable,
            DiscuzRequestError.noThreads, ForumTransportError.unreadable, MastodonRequestError.http(404),
        ]
        for error in refused { #expect(UnreadWhy.of(error) == .refused, "\(error)") }
        for error in reach { #expect(UnreadWhy.of(error) == .outOfReach, "\(error)") }
        for error in understood { #expect(UnreadWhy.of(error) == .notUnderstood, "\(error)") }
    }

    @Test("Every word is in English, Taiwanese Mandarin and Traditional Chinese, and the line reads whole in each")
    func theWords() throws {
        let keys = [
            "timeline.unread.one", "timeline.unread.many", "source.unread.whole", "source.unread.parts",
            "source.unread.refused", "source.unread.reach", "source.unread.understood",
        ]
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys { #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)") }
        }
        let run = UnreadRuns.Run(rounds: 3, since: Self.since, why: .refused)
        #expect(UnreadRuns.line(Self.one, [.whole: run], sources: [], language: .english)
            == "one.example: not read since \(Self.when()) — refused.")
        #expect(UnreadRuns.line(Self.one, [.of(.home): run], sources: [], language: .english)
            == "Home on one.example: not read since \(Self.when()) — refused.")
        let taiwan = try #require(UnreadRuns.line(Self.one, [.of(.home): run], sources: [], language: .taiwanese))
        #expect(taiwan.contains("one.example") && taiwan.contains("被拒絕") && !taiwan.contains("%"))
    }

    // MARK: - Read through the reload

    @Test("A source failing three rounds of All is said on its row, its detail and All; a read that goes through takes it away")
    func throughTheReload() async throws {
        var failing = Self.everything
        failing[Self.publicAddress(Self.one)] = .fail
        failing[Self.trendsAddress(Self.one)] = .body(Data(), status: 503)
        let wire = Switched(failing: failing, answering: Self.everything)
        let session = await shell(wire)
        let two = try written("Two", .public, of: Self.two, in: session)
        let ofOne = try written("One", .public, of: Self.one, in: session)

        for round in 1...2 {
            await session.reload.timeline(.all, in: session)
            #expect(session.reload.failed == [Self.one], "the premise, round \(round)")
            #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) == nil, "not yet, round \(round)")
            #expect(session.reload.unreadLines(of: .all, in: session).isEmpty)
        }
        await session.reload.held(in: session)
        let line = try #require(session.reload.unreadLine(host: Self.one, sources: session.sources, language: .english))
        #expect(line == "Public and Trends on one.example: not read since \(Self.when()) — out of reach.")
        #expect(session.reload.unreadLine(host: Self.two, sources: session.sources) == nil)
        #expect(JoinSheet(session: session).standingLines(Self.one, language: .english).contains(line), "its detail")
        #expect(session.reload.unreadLines(of: .all, in: session, language: .english) == [line])
        #expect(session.reload.unreadLines(of: ofOne, in: session, language: .english)
            == ["Public on one.example: not read since \(Self.when()) — out of reach."], "only what it draws of it")
        #expect(session.reload.unreadLines(of: two, in: session).isEmpty, "a timeline not drawn from it says nothing")
        #expect(ShellReload.unreadHead([line], language: .english)
            == "One of this timeline's sources is not being read. " + line)

        await wire.answer()
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed.isEmpty)
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) == nil)
        #expect(session.reload.unreadLines(of: .all, in: session).isEmpty)
    }

    @Test("What the reload does not count as a failure is never said: no Trends where the timeline came")
    func noTrendsIsNotUnread() async {
        var routes = Self.everything
        routes[Self.trendsAddress(Self.one)] = .body(Data(), status: 404)
        let session = await shell(FixtureHTTP(routes))
        for _ in 0..<5 { await session.reload.held(in: session) }
        #expect(session.reload.failed.isEmpty)
        #expect(!session.reload.unreadRuns.saysAny)
    }

    @Test("A board that keeps failing is said by its name")
    func aBoard() async {
        var routes = Self.everything
        routes[Self.boardAddress] = .fail
        let session = await shell(FixtureHTTP(routes))
        for _ in 0..<3 { await session.reload.held(in: session) }
        #expect(session.reload.unreadLine(host: Self.forum, sources: session.sources, language: .english)
            == "工具箱讨论区 on forum.example: not read since \(Self.when()) — out of reach.")
    }

    @Test("Home read as you that the server keeps answering 503 is said, as out of reach, on the timelines that draw on Home")
    func homeAsYou() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let sender = Answers(status: 503)
        let session = await shell(FixtureHTTP(Self.everything), mastodon: MastodonSessions(tokens: tokens, sender: sender))
        let home = try written("Home", .home, of: Self.one, in: session)
        let trends = try written("Trends", .trends, of: Self.one, in: session)
        for _ in 0..<3 { await session.reload.held(in: session) }
        let line = "Home on one.example: not read since \(Self.when()) — out of reach."
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources, language: .english) == line)
        #expect(session.reload.unreadLines(of: home, in: session, language: .english) == [line])
        #expect(session.reload.unreadLines(of: trends, in: session).isEmpty, "its Trends are read")
        await sender.set(200)
        await session.reload.held(in: session)
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) == nil)
    }

    @Test("What a round excuses is neither a failure nor a read: the run it was part of stands as it was")
    func excusedStands() {
        var runs = UnreadRuns()
        for _ in 0..<2 { runs.round(Self.one, asked: [.public], read: false, failed: [.of(.public): .refused], at: Self.since) }
        runs.round(Self.one, asked: nil, read: true, failed: [:], excused: [.of(.public)], at: Self.since)
        #expect(runs.runs[Self.one]?[.of(.public)]?.rounds == 2)
        runs.round(Self.one, asked: nil, read: false, failed: [.of(.public): .refused, .of(.home): .outOfReach], excused: [.of(.public)], at: Self.since)
        #expect(runs.runs[Self.one]?[.of(.public)]?.rounds == 2, "nor counted where the round failed otherwise")
        runs.forgetAsYou(Self.one)
        #expect(runs.runs[Self.one]?[.of(.home)] == nil && runs.runs[Self.one]?[.of(.public)]?.rounds == 2,
                "a sign-out forgets what the sign-in read, and only that")
    }

    @Test("A public timeline that asks a sign-in, read by r on its own timeline, is not cleared by a wait that excuses it")
    func aWaitDoesNotClearWhatItExcused() async throws {
        var routes = Self.everything
        routes[Self.publicAddress(Self.one)] = .body(Data(), status: 422)
        let session = await shell(FixtureHTTP(routes))
        let ofOne = try written("One", .public, of: Self.one, in: session)
        for _ in 0..<2 { await session.reload.timeline(ofOne, in: session) }
        #expect(session.reload.unreadRuns.runs[Self.one]?[.of(.public)]?.rounds == 2)
        await session.reload.held(in: session)
        #expect(session.reload.failed.isEmpty, "the premise: the wait reads it, by the join's rule")
        #expect(session.reload.unreadRuns.runs[Self.one]?[.of(.public)]?.rounds == 2, "the wait left the run alone")
        await session.reload.timeline(ofOne, in: session)
        #expect(session.reload.unreadLines(of: ofOne, in: session, language: .english)
            == ["Public on one.example: not read since \(Self.when()) — refused."])
    }

    @Test("The names of the lists not read are said on the source alone, and no timeline says them")
    func listNames() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let doors = Doors(Self.everything, failing: ["/api/v1/lists"])
        let session = await shell(
            doors, mastodon: MastodonSessions(tokens: tokens, sender: doors), lists: [ListSubscription(id: "7", name: "Friends")]
        )
        let home = try written("Home", .home, of: Self.one, in: session)
        let friends = try written("Friends", .list(id: "7"), of: Self.one, in: session)
        for _ in 0..<3 { await session.reload.held(in: session) }
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources, language: .english)
            == "List names on one.example: not read since \(Self.when()) — out of reach.")
        for query in [TimelineQuery.all, home, friends] {
            #expect(session.reload.unreadLines(of: query, in: session).isEmpty, "\(query)")
        }
        for _ in 0..<2 { await session.reload.timeline(home, in: session) }
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) != nil, "an r of Home does not read them")
        await doors.answer()
        await session.reload.held(in: session)
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) == nil)
    }

    @Test("Signing out takes away what the sign-in was not reading")
    func signOutForgets() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let session = await shell(FixtureHTTP(Self.everything), mastodon: MastodonSessions(tokens: tokens, sender: Answers(status: 503)))
        for _ in 0..<3 { await session.reload.held(in: session) }
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) != nil, "the premise")
        await session.signOut(host: Self.one)
        #expect(session.reload.unreadLine(host: Self.one, sources: session.sources) == nil)
    }

    @Test("A read stopped before it ended is neither a failure nor a read")
    func aStoppedRead() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let doors = Doors(Self.everything, failing: ["/api/v1/timelines/public"])
        let session = await shell(doors, mastodon: MastodonSessions(tokens: tokens, sender: doors))
        let ofOne = try written("One", .public, of: Self.one, in: session)
        for _ in 0..<2 { await session.reload.timeline(ofOne, in: session) }
        #expect(session.reload.unreadRuns.runs[Self.one]?[.of(.public)]?.rounds == 2)
        await doors.answer(holding: "/api/v1/timelines/home")
        let round = Task { await session.reload.held(in: session) }
        await met("Home is asked, and held", by: round) { await doors.asked.contains("/api/v1/timelines/home") }
        session.reload.stop(host: Self.one)
        await doors.gate.open()
        await round.value
        #expect(session.reload.unreadRuns.runs[Self.one]?[.of(.public)]?.rounds == 2, "a stopped round took nothing off")
        await session.reload.held(in: session)
        #expect(session.reload.unreadRuns.runs[Self.one] == nil, "the next read that goes through does")
    }

    // MARK: - Heard

    @Test("VoiceOver hears it: the row's sentence carries the line and its … warns, and the timeline's head is labelled by it")
    func heard() {
        let line = "one.example: not read since \(Self.when()) — out of reach."
        let row = SourceRow(source: Source(host: Self.one, kind: .mastodon), profile: .unasked(host: Self.one, kind: .mastodon))
        let view = SourceRowView(
            row: row, actsLive: true, waiting: nil, refusal: nil, unread: line,
            clearAsks: { ShellQuestion.clear(host: Self.one, detailKey: "account.clear.detail", language: .english) },
            removeAsks: { ShellQuestion.remove(host: Self.one, boards: 0, language: .english) },
            presses: SourceRow.Presses()
        )
        #expect(view.said == [line])
        #expect(view.heard.hasSuffix(line))
        #expect(view.saying == .warns)
        let source = try? ShellSource.shell("UnreadSourcesHead")
        #expect(source?.contains(".accessibilityLabel(Text(line))") == true, "the head is one element, labelled by its line")
    }
}

/// Answers every signed-in request with `status` and an empty list, the status changed by hand.
private actor Answers: HTTPSender {
    private var status: Int

    init(status: Int = 200) {
        self.status = status
    }

    func set(_ status: Int) {
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// One set of routes, then another once `answer()` is called.
private actor Switched: HTTPClient {
    private let failing: FixtureHTTP
    private let answering: FixtureHTTP
    private var answers = false

    init(failing: [String: FixtureHTTP.Outcome], answering: [String: FixtureHTTP.Outcome]) {
        self.failing = FixtureHTTP(failing)
        self.answering = FixtureHTTP(answering)
    }

    func answer() {
        answers = true
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await (answers ? answering : failing).data(from: url)
    }
}

/// Every route of the three sources, signed in or not, each path in `failing` answered 503
/// until `answer` is called — which may hold one path, signed in, until `gate` opens.
private actor Doors: HTTPClient, HTTPSender {
    private let fixture: FixtureHTTP
    private var failing: Set<String>
    private var holding: String?
    let gate = Gate()
    private(set) var asked: [String] = []

    init(_ routes: [String: FixtureHTTP.Outcome], failing: Set<String>) {
        fixture = FixtureHTTP(routes)
        self.failing = failing
    }

    func answer(holding path: String? = nil) {
        failing = []
        holding = path
    }

    private func refused(_ url: URL) -> (Data, HTTPURLResponse)? {
        guard failing.contains(url.path) else { return nil }
        return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if let refused = refused(url) { return refused }
        return try await fixture.data(from: url)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        asked.append(url.path)
        if url.path == holding { await gate.wait() }
        try Task.checkCancellation()
        if let refused = refused(url) { return refused }
        return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
