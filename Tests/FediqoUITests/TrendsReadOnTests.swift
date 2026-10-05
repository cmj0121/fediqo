import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// What is rising on a Mastodon source can be read on (#288).
///
/// What a test can reach: which stretch of a source's trending list is asked and from how far in;
/// what lands, once, at its publish time; a source saying it has no more and not being asked
/// again; a source failing beside one that lands; `r` starting from the top; a forum's Trends
/// left as they were. What it cannot: the line at the bottom of the timeline drawn in light and
/// dark, on a Mac and a phone.
@MainActor
@Suite("Reading on through what is rising")
struct TrendsReadOnTests {
    private static let one = "one.example"
    private static let two = "two.example"
    private static let forum = "install-c.example"

    private static func address(_ host: String, offset: Int = 0) -> String {
        "https://\(host)/api/v1/trends/statuses?limit=20" + (offset > 0 ? "&offset=\(offset)" : "")
    }

    /// One trending status of `host`, numbered `id` and published on the `id`th minute.
    private static func status(_ host: String, _ id: Int) -> String {
        let stamp = String(format: "2024-01-01T%02d:%02d:00.000Z", id / 60, id % 60)
        return """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
         "created_at":"\(stamp)","content":"<p>\(id)</p>",
         "visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// A stretch of `host`'s trending list holding the statuses numbered `ids`.
    private static func stretch(_ host: String, _ ids: [Int]) -> FixtureHTTP.Outcome {
        .text("[" + ids.map { status(host, $0) }.joined(separator: ",") + "]")
    }

    private static func key(_ host: String, _ id: Int) -> String { "https://\(host)/users/ada/statuses/\(id)" }

    /// A session with two Mastodon sources and a forum, holding nothing.
    private func shell(_ http: any HTTPClient, hosts: [String] = [one, two]) async -> ShellSession {
        let store = ItemStore()
        for host in hosts { await store.add(Source(host: host, kind: .mastodon)) }
        await store.add(Source(host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "Board")]))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        session.timelineID = .trends
        return session
    }

    private func trending(_ session: ShellSession) -> [String] {
        session.timelineItems(latest: nil).map(\.noteID)
    }

    /// What the timeline's foot says of the Trends timeline now, or nothing.
    private func foot(_ session: ShellSession) -> String? {
        ShellReload.trendsEndLine(session.reload.trendsEnded(of: .trends, in: session))
    }

    private func asked(_ http: FixtureHTTP, _ host: String) async -> [String] {
        await http.requested.map(\.absoluteString).filter { $0.contains(host) && $0.contains("/trends/") }
    }

    // MARK: - The source's own paging

    @Test("What is rising is asked a stretch at a time by how far into the list, the top with no offset at all")
    func theAsk() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, [1]),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, [2]),
        ])
        let client = MastodonClient(http: http, host: Self.one)
        let source = Source(host: Self.one, kind: .mastodon)
        #expect(MastodonClient.trendsStretch == 20)
        #expect(try await client.trending(source: source).map(\.statusID) == ["1"])
        let further = try await client.trending(source: source, offset: 40)
        #expect(further.map(\.statusID) == ["2"])
        #expect(further.allSatisfy { $0.categories == [.trends] })
        #expect(await http.requested.map(\.absoluteString) == [Self.address(Self.one), Self.address(Self.one, offset: 40)])
    }

    // MARK: - Reading on

    @Test("Reading on past the first stretch brings further trending posts from each Mastodon source, each once, where its publish time puts it")
    func readingOnBringsFurther() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, Array(81...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            Self.address(Self.two): Self.stretch(Self.two, Array(201...220)),
            Self.address(Self.two, offset: 20): Self.stretch(Self.two, Array(181...200)),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            MastodonInstance.address(Self.two): MastodonInstance.mastodon(Self.two),
        ])
        let session = await shell(http)
        await session.reload.timeline(.trends, in: session)
        let first = trending(session)
        #expect(first.count == 40, "the first stretch of each source")

        await session.reload.more(.trends, in: session)

        #expect(await asked(http, Self.one) == [Self.address(Self.one), Self.address(Self.one, offset: 20)])
        #expect(await asked(http, Self.two) == [Self.address(Self.two), Self.address(Self.two, offset: 20)])
        let second = trending(session)
        #expect(second.count == 80)
        #expect(Set(second).count == second.count, "a post was brought twice")
        #expect(second.contains(Self.key(Self.one, 81)) && second.contains(Self.key(Self.two, 181)))
        #expect(Set(first).isSubset(of: second), "what was there went")
        // Ordered by when each was published, like everything else, and carrying the category.
        let posted = session.timelineItems(latest: nil).map(\.postedAt)
        #expect(posted == posted.sorted(by: >), "what is rising was put in an order of its own")
        #expect(session.notes.allSatisfy { $0.categories == [.trends] })
        #expect(session.reload.line == nil && foot(session) == nil)

        // And on again, from where each had got to.
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 40))
        #expect(trending(session).contains(Self.key(Self.one, 61)))
    }

    @Test("A post that moved down the list between two asks comes again and is still one row, and the next ask starts under the stretch that brought it")
    func aPostThatMoved() async throws {
        // Between the asks, post 120 fell from the top stretch into the second.
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, [120] + Array(82...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ])
        let session = await shell(http, hosts: [Self.one])
        await session.reload.timeline(.trends, in: session)

        await session.reload.more(.trends, in: session)

        let rows = trending(session)
        #expect(rows.filter { $0 == Self.key(Self.one, 120) }.count == 1, "the post that moved is drawn twice")
        #expect(await session.store.snapshot().notes.filter { $0.statusID == "120" }.count == 1)
        #expect(rows.count == 39, "twenty, and the nineteen that were new")
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 40), "a post that came twice moved where the next ask starts")
    }

    // MARK: - No more, and failing

    @Test("A source with no more to give says so at the timeline's foot for as long as it is so, and is not asked again until the next reload; the other reads on")
    func noMoreIsSaidAndNotAskedAgain() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            // A short stretch: the source's own "no more".
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, [99, 100]),
            Self.address(Self.two): Self.stretch(Self.two, Array(201...220)),
            Self.address(Self.two, offset: 20): Self.stretch(Self.two, Array(181...200)),
            Self.address(Self.two, offset: 40): Self.stretch(Self.two, []),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            MastodonInstance.address(Self.two): MastodonInstance.mastodon(Self.two),
        ])
        let session = await shell(http)
        await session.reload.timeline(.trends, in: session)
        #expect(foot(session) == nil)

        await session.reload.more(.trends, in: session)
        #expect(trending(session).contains(Self.key(Self.one, 99)), "what the short stretch did bring landed")
        #expect(foot(session) == ShellReload.trendsEndLine([Self.one]), "it did not say it had no more")
        #expect(session.reload.line == nil, "the end of a list was said as a failure")
        #expect(session.toast == nil, "and it is not a line that passes")

        // Asked again: the source that ended is left alone, and the other's end joins it.
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).count == 2, "a source with no more was asked again")
        #expect(await asked(http, Self.two).last == Self.address(Self.two, offset: 40))
        #expect(foot(session) == ShellReload.trendsEndLine([Self.one, Self.two]), "the second source's end, an empty stretch")
        let before = await http.requested.count
        await session.reload.more(.trends, in: session)
        #expect(await http.requested.count == before, "nothing is left to ask")
        #expect(foot(session) == ShellReload.trendsEndLine([Self.one, Self.two]), "still so, and still said")
        // Only the timeline that reads what is rising says it.
        #expect(session.reload.trendsEnded(of: .all, in: session).isEmpty)

        // The next reload reads the top again: the foot says nothing, and reading on starts under it.
        await session.reload.timeline(.trends, in: session)
        #expect(foot(session) == nil)
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).suffix(2) == [Self.address(Self.one), Self.address(Self.one, offset: 20)])
    }

    @Test("The wait reading a source's top leaves reading on where it was: nothing is fetched again, a source that ended is not asked again, and the foot still says so — until r")
    func theWaitLeavesReadingOnAlone() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, Array(81...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            Self.address(Self.two): Self.stretch(Self.two, Array(201...220)),
            Self.address(Self.two, offset: 20): Self.stretch(Self.two, [199, 200]),
            "https://\(Self.one)/api/v1/timelines/public?limit=40": .text("[]"),
            "https://\(Self.two)/api/v1/timelines/public?limit=40": .text("[]"),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            MastodonInstance.address(Self.two): MastodonInstance.mastodon(Self.two),
        ])
        let session = await shell(http)
        await session.reload.timeline(.trends, in: session)
        await session.reload.more(.trends, in: session)
        #expect(foot(session) == ShellReload.trendsEndLine([Self.two]))
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 20))

        // The wait comes round, twice, and reads every source's usual reads — its trending top among them.
        await session.reload.held(in: session)
        await session.reload.held(in: session)
        #expect(await asked(http, Self.one).filter { $0 == Self.address(Self.one) }.count == 3, "the wait did not read the top")

        #expect(foot(session) == ShellReload.trendsEndLine([Self.two]), "the wait un-ended a source, or stopped saying so")
        #expect(session.toast == nil)
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 40), "the wait sent reading on back to the top")
        #expect(await asked(http, Self.two).filter { $0 == Self.address(Self.two, offset: 20) }.count == 1, "a source with no more was asked again after a wait")
        #expect(trending(session).contains(Self.key(Self.one, 61)))

        // The reader's own reload is what starts it over.
        await session.reload.timeline(.trends, in: session)
        #expect(foot(session) == nil)
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 20))
        #expect(await asked(http, Self.two).filter { $0 == Self.address(Self.two, offset: 20) }.count == 2)
    }

    @Test("A source that answers every ask with its top again has no more: the same posts twice is the end, said at the foot, and it is not asked further down for ever")
    func aSourceThatIgnoresHowFarIn() async throws {
        let top = Self.stretch(Self.one, Array(101...120))
        let http = FixtureHTTP([
            Self.address(Self.one): top,
            Self.address(Self.one, offset: 20): top,
            Self.address(Self.one, offset: 40): top,
            Self.address(Self.one, offset: 60): top,
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ])
        let session = await shell(http, hosts: [Self.one])
        await session.reload.timeline(.trends, in: session)

        for _ in 0..<5 { await session.reload.more(.trends, in: session) }

        #expect(await asked(http, Self.one) == [Self.address(Self.one), Self.address(Self.one, offset: 20)], "asked on without end")
        #expect(trending(session).count == 20)
        #expect(foot(session) == ShellReload.trendsEndLine([Self.one]))
        #expect(session.reload.failed.isEmpty)

        // And with nothing read of it this run, the top itself is never the end.
        let fresh = await shell(http, hosts: [Self.one])
        await fresh.reload.more(.trends, in: fresh)
        #expect(foot(fresh) == nil, "the top, all new to this run, was taken for the end")
        await fresh.reload.more(.trends, in: fresh)
        #expect(foot(fresh) == ShellReload.trendsEndLine([Self.one]))
    }

    @Test("What an earlier run already holds is not the source saying it has no more: a stretch of posts all held is read past")
    func whatIsHeldIsNotTheEnd() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, Array(81...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ])
        // An earlier run read the first two stretches; this one starts with them held.
        let earlier = await shell(http, hosts: [Self.one])
        await earlier.reload.timeline(.trends, in: earlier)
        await earlier.reload.more(.trends, in: earlier)
        let held = await earlier.store.snapshot()
        let session = ShellSession(
            http: http, store: ItemStore(sources: held.sources, notes: held.notes),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        session.timelineID = .trends
        await session.reload.timeline(.trends, in: session)

        await session.reload.more(.trends, in: session)
        #expect(foot(session) == nil, "posts an earlier run held were taken for the source's end")
        await session.reload.more(.trends, in: session)
        #expect(trending(session).contains(Self.key(Self.one, 61)), "reading on stopped at what was already held")
    }

    @Test("A reload stopped after the source answered and before its top landed leaves reading on where it was")
    func aStoppedReloadDoesNotStartOver() async throws {
        let http = HeldLater([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, Array(81...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ], holding: Self.address(Self.one))
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let session = await shell(http, hosts: [Self.one])
        await session.reload.timeline(.trends, in: session)
        await session.reload.more(.trends, in: session)
        #expect(await http.requested().last == Self.address(Self.one, offset: 20))

        // r, held on the wire at the source's top, and stopped there by the reader.
        await http.arm()
        let reload = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await http.holding })
        #expect(session.reload.stop())
        await http.gate.open()
        await reload.value

        await session.reload.more(.trends, in: session)
        #expect(await http.requested().last == Self.address(Self.one, offset: 40), "reading on went back under a top that never landed")
    }

    @Test("A source that fails says so in the reload's words, the others still land, and it is asked again from where it was")
    func aFailureBesideALanding() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): .text("", status: 503),
            Self.address(Self.two): Self.stretch(Self.two, Array(201...220)),
            Self.address(Self.two, offset: 20): Self.stretch(Self.two, Array(181...200)),
            Self.address(Self.two, offset: 40): Self.stretch(Self.two, Array(161...180)),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            MastodonInstance.address(Self.two): MastodonInstance.mastodon(Self.two),
        ])
        let session = await shell(http)
        await session.reload.timeline(.trends, in: session)

        await session.reload.more(.trends, in: session)

        #expect(session.reload.failed == [Self.one])
        #expect(session.reload.line == String(format: L10n.t("timeline.reload.failed"), Self.one))
        #expect(foot(session) == nil, "a failure was said as the end of the list")
        #expect(trending(session).contains(Self.key(Self.two, 181)), "the source beside it did not land")
        #expect(trending(session).count == 60)
        // Failed is not read: the same stretch is asked again, and the other goes on from its own place.
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).suffix(2) == [Self.address(Self.one, offset: 20), Self.address(Self.one, offset: 20)])
        #expect(await asked(http, Self.two).last == Self.address(Self.two, offset: 40))
    }

    // MARK: - From the top, and what is left alone

    @Test("r on Trends starts from the top again; and a top that came short is all there is")
    func rStartsFromTheTop() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, Array(101...120)),
            Self.address(Self.one, offset: 20): Self.stretch(Self.one, Array(81...100)),
            Self.address(Self.one, offset: 40): Self.stretch(Self.one, Array(61...80)),
            Self.address(Self.two): Self.stretch(Self.two, [201, 202, 203]),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            MastodonInstance.address(Self.two): MastodonInstance.mastodon(Self.two),
        ])
        let session = await shell(http)
        await session.reload.timeline(.trends, in: session)
        await session.reload.more(.trends, in: session)
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one).last == Self.address(Self.one, offset: 40))
        #expect(await asked(http, Self.two) == [Self.address(Self.two)], "three posts were the whole of it, and it was asked for more")

        await session.reload.timeline(.trends, in: session)
        await session.reload.more(.trends, in: session)

        #expect(await asked(http, Self.one).suffix(2) == [Self.address(Self.one), Self.address(Self.one, offset: 20)])
        let rows = trending(session)
        #expect(Set(rows).count == rows.count)
    }

    @Test("With nothing read of it this run — a relaunch — reading on starts at the top of the list")
    func withNothingReadThisRun() async throws {
        let http = FixtureHTTP([Self.address(Self.one): Self.stretch(Self.one, Array(101...120))])
        let session = await shell(http, hosts: [Self.one])
        await session.reload.more(.trends, in: session)
        #expect(await asked(http, Self.one) == [Self.address(Self.one)])
        #expect(trending(session).count == 20)
    }

    @Test("A forum's Trends are as they were: never read on, and nothing is said of them; a listing of everything goes down no ranking")
    func aForumAndAllAreLeftAlone() async throws {
        let http = FixtureHTTP([
            Self.address(Self.one): Self.stretch(Self.one, [1, 2]),
        ])
        let session = await shell(http, hosts: [Self.one])
        await session.reload.more(.trends, in: session)
        await session.reload.more(.trends, in: session)
        let requested = await http.requested.map(\.absoluteString)
        #expect(requested == [Self.address(Self.one)], "something was asked of the forum, or asked twice")
        #expect(foot(session) == ShellReload.trendsEndLine([Self.one]), "the forum was named, or the Mastodon was not")
        #expect(session.reload.failed.isEmpty)

        // The stretches a timeline continues: a Mastodon's Trends only where it is asked for by name.
        let mastodon = Source(host: Self.one, kind: .mastodon)
        let forum = Source(host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "Board")])
        #expect(ShellReload.stretches(of: mastodon, for: [.trends], signedIn: false) == [Stretch(host: Self.one, category: .trends)])
        #expect(ShellReload.stretches(of: mastodon, for: nil, signedIn: false) == [Stretch(host: Self.one, category: .public)])
        #expect(ShellReload.stretches(of: mastodon, for: [.public], signedIn: false) == [Stretch(host: Self.one, category: .public)])
        #expect(ShellReload.stretches(of: forum, for: [.trends], signedIn: false).isEmpty)
    }

    @Test("What is said when a source has no more names it, in both languages, and nothing is said of none", arguments: [DummyLanguage.english, .taiwanese])
    func theWords(language: DummyLanguage) throws {
        #expect(ShellReload.trendsEndLine([], language: language) == nil)
        let one = try #require(ShellReload.trendsEndLine([Self.one], language: language))
        #expect(one.contains(Self.one) && !one.contains("%") && !one.contains("timeline.trends"))
        let both = try #require(ShellReload.trendsEndLine([Self.one, Self.two], language: language))
        #expect(both.contains(Self.one) && both.contains(Self.two))
    }
}

/// A fixture that holds one address on the wire once it is armed, and not before — so a test
/// can read normally first and then catch one particular ask mid-flight.
private actor HeldLater: HTTPClient {
    private let inner: FixtureHTTP
    private let held: String
    private var armed = false
    nonisolated let gate = Gate()
    /// Whether the held address is waiting at the gate.
    private(set) var holding = false

    init(_ routes: [String: FixtureHTTP.Outcome], holding held: String) {
        inner = FixtureHTTP(routes)
        self.held = held
    }

    func arm() { armed = true }

    func requested() async -> [String] {
        await inner.requested.map(\.absoluteString)
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if armed, url.absoluteString == held {
            holding = true
            await gate.wait()
        }
        return try await inner.data(from: url)
    }
}
