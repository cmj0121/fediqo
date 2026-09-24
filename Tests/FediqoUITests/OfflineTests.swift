import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A network that is off until the test turns it on: every request, read or write, fails as a
/// machine with no network fails — `URLError.notConnectedToInternet`, at once — and every one is
/// counted, so "asked nothing" is something a test can hold.
///
/// Lit, it answers by path: the instance document, the account check, and an empty page for any
/// other read, which is a source with nothing new rather than a failure.
private actor Network: HTTPClient, HTTPSender {
    private let routes: [String: String]
    private(set) var lit = false
    private(set) var asked: [String] = []
    private var hanging: Set<String> = []

    init(_ routes: [String: String]) {
        self.routes = routes
    }

    func light() { lit = true }

    /// A path whose server is up but never answers in time — what a reload's deadline throws.
    func hang(_ path: String) { hanging.insert(path) }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try answer(url)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try answer(request.url!)
    }

    private func answer(_ url: URL) throws -> (Data, HTTPURLResponse) {
        asked.append(url.path)
        guard lit else { throw URLError(.notConnectedToInternet) }
        if hanging.contains(url.path) { throw URLError(.timedOut) }
        let body = routes[url.path] ?? "[]"
        return (
            Data(body.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

/// The page a sign-in would open. With the network off it is never reached: the server is asked
/// to register this app first, and that is what fails.
@MainActor
private final class NoPage: OAuthBrowser {
    private(set) var opened = 0

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened += 1
        throw MastodonSignInError.cancelled
    }
}

/// Defaults whose values live in this object only, so a timeline written here reaches no disk.
private final class OfflineDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

/// #222: with the network off, what this device holds reads, rules and search work, and what
/// needs a network says so in 0.4.0's words — and when the network returns, the next ask reaches
/// its source without a relaunch.
///
/// **One session, launched dark.** Every test builds the app's session over a store that already
/// holds what an earlier run brought, with a network that fails every request the way a machine
/// with Wi-Fi off does. No sentence is compared against English: each is compared against the
/// key 0.4.0 wrote it under, in whatever language the run is in.
@MainActor
@Suite("With the network off")
struct OfflineTests {
    private static let host = "social.example"
    private static let writing = MastodonOAuth.scopes(writing: true)

    private static let source = Source(host: host, kind: .mastodon)

    private static func note(_ id: String, _ body: String, at t: Double) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada",
            handle: "@ada@\(host)", body: body, postedAt: Date(timeIntervalSince1970: t),
            categories: [.public], statusID: id
        )
    }

    /// What an earlier run brought and this device kept.
    private static let held = [
        note("1", "swift on the train", at: 2),
        note("2", "spoiler: the ending", at: 1),
    ]

    private static let routes: [String: String] = [
        "/api/v2/instance": #"""
            {"domain":"social.example","title":"social.example","version":"4.3.1",
             "configuration":{"statuses":{"max_characters":2000}}}
            """#,
        "/api/v1/accounts/verify_credentials": #"{"acct":"me"}"#,
        "/api/v1/timelines/public": #"""
            [{"id":"3","uri":"https://social.example/users/ada/statuses/3",
              "created_at":"2024-01-03T00:00:00.000Z","content":"<p>back online</p>",
              "account":{"username":"ada","acct":"ada","display_name":"Ada"}}]
            """#,
    ]

    /// A session as a launch with no network builds it: the store read from this device, the
    /// sign-in read from the Keychain, and a network that answers nothing.
    /// What the source said about itself last run, as the store kept it (#188): a ceiling the
    /// live document above disagrees with, so a refresh is told apart from a kept word.
    private static let keptAt = Date(timeIntervalSince1970: 1_750_000_000)
    private static let kept = SourceProfile(
        host: host, kind: .mastodon, title: "Social, as it was", statusLimit: 1500
    ).said(at: keptAt)

    private func launch(signedIn: Bool = true, said: SourceProfile? = nil) async throws -> (ShellSession, Network) {
        let network = Network(Self.routes)
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok", clientID: "cid", clientSecret: "secret",
                scopes: Self.writing
            ))
        }
        // As a launch builds it: the source and its last word read back from disk together.
        let store = ItemStore(sources: [Self.source], notes: [], said: said.map { [$0] } ?? [])
        await store.ingest(Self.held)
        let session = ShellSession(
            http: network, store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: network),
            posts: ForumPosts(http: network),
            timelines: WrittenTimelineStore(defaults: OfflineDefaults())
        )
        await session.reloadFromStore()
        session.mastodon.refresh()
        return (session, network)
    }

    private func shown(_ session: ShellSession) -> [String] {
        session.timelineItems(latest: nil).map(\.body)
    }

    // MARK: - What does not need a network

    @Test("With the network off from launch, the timeline reads what this device holds, asking nothing")
    func timelineReads() async throws {
        let (session, network) = try await launch()
        session.timelineID = .all

        #expect(shown(session) == ["swift on the train", "spoiler: the ending"])
        #expect(await network.asked.isEmpty, "drawing a timeline is a query of the store")
    }

    @Test("With the network off, a rule written now changes what the timeline shows")
    func ruleApplies() async throws {
        let (session, network) = try await launch()
        var draft = TimelineDraft(new: 1)
        draft.name = "No spoilers"
        draft.rules = [try #require(Rule.keyword("spoiler", in: .every, effect: .exclude))]
        session.commit(draft)

        #expect(session.timelineID == .written(draft.id))
        #expect(shown(session) == ["swift on the train"])

        var changed = draft
        changed.rules = [try #require(Rule.keyword("swift", in: .every, effect: .exclude))]
        session.commit(changed)
        #expect(shown(session) == ["spoiler: the ending"], "and changing it changes the timeline")
        #expect(await network.asked.isEmpty)
    }

    @Test("With the network off, a search finds a post this device holds")
    func searchFinds() async throws {
        let (session, network) = try await launch()
        session.timelineID = .all
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = "train"
        search.settle("train")

        #expect(session.searched(search, latest: nil)?.map(\.body) == ["swift on the train"])
        #expect(await network.asked.isEmpty)
    }

    // MARK: - What does need one, saying so

    @Test("Asking a source with the network off ends, and says the source could not be reloaded")
    func reloadSaysSo() async throws {
        let (session, _) = try await launch()
        session.timelineID = .all

        await session.reload.timeline(.all, in: session)

        #expect(!session.reload.running, "the ask ended; nothing is left waiting")
        #expect(session.reload.failed == [Self.host])
        #expect(session.reload.line == String(format: L10n.t("timeline.reload.failed"), Self.host))
        #expect(session.reload.unspoken == nil, "a dark network is not a server that changed")
        #expect(shown(session) == ["swift on the train", "spoiler: the ending"],
                "and what was held is still drawn")
    }

    @Test("Posting with the network off keeps the draft and names the source that did not answer")
    func postSaysSo() async throws {
        let (session, _) = try await launch()
        session.sources = await session.store.sources()
        session.prepareCompose()
        #expect(session.composeHost == Self.host)
        session.composeDraft = "written on a plane"

        await #expect(throws: URLError.self) { try await session.post() }

        #expect(session.composeDraft == "written on a plane", "nothing written is lost")
        #expect(session.isSignedIn(host: Self.host), "a dark network is not a sign-out")
        let failed = try #require(ComposerSheet.failedAt(session), "the failure names a source")
        #expect(failed == Self.host)
        #expect(
            ComposerSheet.surface(offered: session.writableSources, draft: session.composeDraft, failed: failed)
                == .composing,
            "the editor and its failure plate stay, not the empty notice"
        )
        #expect(session.canPost, "and the same draft can be sent again once the network is back")
        #expect(ShellFailure.spoken([failed]).contains(Self.host))
    }

    @Test("Signing in with the network off says the source could not be reached, and opens no page")
    func signInSaysSo() async throws {
        let (session, _) = try await launch(signedIn: false)
        session.sources = await session.store.sources()
        let page = NoPage()

        await session.signIn(host: Self.host, through: page)

        #expect(page.opened == 0)
        #expect(!session.isSignedIn(host: Self.host))
        #expect(session.rowRefusal?.host == Self.host)
        #expect(session.rowRefusal?.key == "account.mastodon.failed.unreachable")
    }

    @Test("Adding a source with the network off says the host could not be reached")
    func addSaysSo() async throws {
        let (session, _) = try await launch()
        session.hostname = "elsewhere.example"

        await session.add()

        #expect(session.refuse == L10n.t("account.refuse.network"))
        #expect(!session.checking, "the look ended")
    }

    // MARK: - When it returns

    @Test("Turning the network back on lets the next reload reach its source, with no relaunch")
    func reloadAfterReturn() async throws {
        let (session, network) = try await launch()
        session.timelineID = .all
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed == [Self.host])

        await network.light()
        await session.reload.timeline(.all, in: session)

        #expect(session.reload.failed.isEmpty)
        #expect(session.reload.line == nil)
        #expect(shown(session).contains("back online"), "what the source sent landed")
    }

    // MARK: - What a source said about itself (#188)

    @Test("After a relaunch with the network off, a source's page says what it last said about itself, and when")
    func sourceSaysWhatItSaid() async throws {
        let (session, network) = try await launch(said: Self.kept)

        let row = try #require(session.rows.first)
        #expect(row.profile == .stated(Self.kept), "drawn from what was kept, before anything asks")
        session.openSource(host: Self.host)
        guard case .previewing(let preview, .joined, _) = session.stage else {
            Issue.record("the source's page did not open")
            return
        }
        #expect(preview.profile == .stated(Self.kept))
        let line = try #require(SourcePreviewView.asOfLine(Self.kept, host: Self.host, language: .english))
        #expect(line.hasPrefix("As \(Self.host) said it, "), "and says when: \(line)")
        #expect(await network.asked.isEmpty)
    }

    @Test("The composer knows how long a post may be before anything is asked, and a dark ask leaves it so")
    func composerKnowsTheCeiling() async throws {
        let (session, network) = try await launch(said: Self.kept)
        session.prepareCompose()
        #expect(session.composeHost == Self.host)
        #expect(session.postLimit(of: Self.host) == 1500, "what the source said, before anything is asked")
        #expect(await network.asked.isEmpty)

        await session.refreshPostLimit()

        #expect(session.postLimit(of: Self.host) == 1500, "a dark network is not a new ceiling")
        #expect(await network.asked == ["/api/v2/instance"], "asked behind the kept word, once")
        #expect(await session.store.said(host: Self.host) == Self.kept, "and the kept word stands")

        await network.light()
        await session.refreshPostLimit()
        #expect(session.postLimit(of: Self.host) == 2000, "the next open asks again, and hears the source now")
        #expect(await session.store.said(host: Self.host)?.statusLimit == 2000)
    }

    @Test("A dark reload leaves what was kept standing, as of when it was said")
    func darkReloadKeepsTheWord() async throws {
        let (session, _) = try await launch(said: Self.kept)

        await session.reload.timeline(.all, in: session)

        #expect(session.rows.first?.profile == .stated(Self.kept))
        #expect(await session.store.said(host: Self.host) == Self.kept, "not settled, and not lost")
    }

    @Test("When the network returns, the next reload replaces what was kept with what the source says now")
    func reloadReplacesTheWord() async throws {
        let (session, network) = try await launch(said: Self.kept)
        await network.light()

        await session.reload.timeline(.all, in: session)

        let now = try #require(await session.store.said(host: Self.host))
        #expect(now.statusLimit == 2000)
        #expect(now.title == Self.host)
        #expect(try #require(now.asOf) > Self.keptAt, "marked as of the ask that just landed")
        #expect(session.rows.first?.profile == .stated(now), "the page draws the new word")
        #expect(session.postLimit(of: Self.host) == 2000, "and the composer reads the new ceiling")
        #expect(await network.asked.filter { $0 == "/api/v2/instance" }.count == 1, "one document, read twice")
    }

    @Test("A source this device kept no word of is asked by the composer, and the answer is kept from then on")
    func composerAskKeepsTheWord() async throws {
        let (session, network) = try await launch()
        await network.light()
        session.prepareCompose()

        await session.refreshPostLimit()

        #expect(session.postLimit(of: Self.host) == 2000)
        #expect(await session.store.said(host: Self.host)?.statusLimit == 2000, "written down for the next launch")
    }

    @Test("What a server says it is is asked again once the network is back, not written off")
    func flavourAskedAgain() async throws {
        let (session, network) = try await launch()
        await session.reload.timeline(.all, in: session)
        #expect(session.flavours.flavour(of: Self.host) == nil, "a dark network is not an answer")

        await network.light()
        await session.reload.timeline(.all, in: session)

        #expect(session.flavours.flavour(of: Self.host) == .said(.mastodon))
    }

    @Test("A server that is up but hangs is settled, and not asked what it is on every reload")
    func hangIsSettled() async throws {
        let (session, network) = try await launch()
        await network.light()
        await network.hang("/api/v2/instance")

        await session.reload.timeline(.all, in: session)
        #expect(session.flavours.flavour(of: Self.host) == .unsaid, "a timeout is an answer for this run")
        await session.reload.timeline(.all, in: session)

        #expect(await network.asked.filter { $0 == "/api/v2/instance" }.count == 1)
    }

    @Test("Only a network that is not there is dark; a slow or refusing server is not")
    func whatIsDark() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed] {
            #expect(DarkNetwork.caused(URLError(code)), "\(code)")
        }
        for code in [URLError.timedOut, .cancelled, .badServerResponse, .secureConnectionFailed] {
            #expect(!DarkNetwork.caused(URLError(code)), "\(code)")
        }
        #expect(!DarkNetwork.caused(MastodonRequestError.http(503)))
    }

    @Test("Who you are on a source, not learnt at a launch with no network, is learnt by the first read that gets through")
    func whoAfterReturn() async throws {
        let (session, network) = try await launch()
        await session.mastodon.verifyAll()
        #expect(session.mastodon.handles[Self.host] == nil)
        await session.reload.timeline(.all, in: session)
        #expect(session.mastodon.handles[Self.host] == nil, "still dark: nothing learnt")

        await network.light()
        await session.reload.timeline(.all, in: session)

        #expect(!session.reload.running, "the reload did not wait on the account check")
        #expect(await spun { session.mastodon.handles[Self.host] == "@me@\(Self.host)" })
        let checks = await network.asked.filter { $0 == "/api/v1/accounts/verify_credentials" }.count
        #expect(checks == 2, "once dark at launch, once when the network came back")
        await session.reload.timeline(.all, in: session)
        // Room for an account check the reload might have started to reach the wire.
        _ = await spun(1_000) { false }
        #expect(
            await network.asked.filter { $0 == "/api/v1/accounts/verify_credentials" }.count == checks,
            "learnt once, and not asked again on every reload"
        )
    }

    @Test("How long a post may be, not learnt with the network off, is asked again once it is back")
    func limitAfterReturn() async throws {
        let (session, network) = try await launch()
        session.composeHost = Self.host

        await session.refreshPostLimit()
        #expect(session.postLimit(of: Self.host) == MastodonWrite.defaultLimit)

        await network.light()
        await session.refreshPostLimit()

        #expect(session.postLimit(of: Self.host) == 2000)
    }
}
