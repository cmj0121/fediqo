import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #164: Preferences lists what is being asked of the sources right now — the source, what for,
/// and for how long — and nothing that has ended, and nothing a request carried.
///
/// Every test builds its own `SourceWork` and hands it to the object under test, so nothing here
/// reads or writes the app's shared one, and suites running beside this one cannot show up in it.
@MainActor
@Suite("What is in flight", .serialized)
struct SourceWorkTests {
    private static let host = "one.example"

    /// What is running, as host and purpose — the whole of what the page can be told.
    private static func running(_ work: SourceWork) -> [String] {
        work.now.values.map { "\($0.host) \($0.purpose.rawValue)" }.sorted()
    }

    // MARK: - The registry

    @Test("Work is listed from its start to its end, and ending it twice is nothing")
    func beginAndEnd() {
        let work = SourceWork()
        let first = work.begin(host: "One.Example", for: .timeline)
        let second = work.begin(host: "two.example", for: .picture)
        #expect(Self.running(work) == ["one.example timeline", "two.example picture"])
        work.end(first)
        work.end(first)
        #expect(Self.running(work) == ["two.example picture"])
        work.end(second)
        #expect(work.now.isEmpty)
    }

    @Test("A piece of work leaves the list whether it lands, fails or is stopped")
    func everyWayOut() async {
        let work = SourceWork()
        let landed = await work.watching(host: Self.host, for: .signIn) {
            #expect(Self.running(work) == ["one.example signIn"])
            return 1
        }
        #expect(landed == 1)
        #expect(work.now.isEmpty)

        await #expect(throws: FixtureHTTPError.self) {
            try await work.watching(host: Self.host, for: .signIn) { () throws -> Int in
                throw FixtureHTTPError.unreachable
            }
        }
        #expect(work.now.isEmpty)

        let stopped = Task {
            try await work.watching(host: Self.host, for: .signIn) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        #expect(await spun { !work.now.isEmpty })
        stopped.cancel()
        _ = await stopped.result
        #expect(work.now.isEmpty, "a stopped piece of work stayed listed")
    }

    // MARK: - The waist

    @Test("A request is listed by its host alone while it runs, and not after it answers or fails")
    func aRequest() async throws {
        let work = SourceWork()
        let url = "https://one.example/api/v1/timelines/public?limit=40&access_token=secret"
        let http = GatedHTTP([url: .text("[]"), "/fails": .fail], holding: url)
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let client = WatchedHTTP(http, for: .timeline, in: work)

        let asking = Task { try await client.data(from: URL(string: url)!) }
        #expect(await spun { await http.asks == 1 })
        #expect(Self.running(work) == ["one.example timeline"], "only the host, only the purpose")
        await http.gate.open()
        _ = try await asking.value
        #expect(work.now.isEmpty)

        await #expect(throws: FixtureHTTPError.self) {
            try await client.data(from: URL(string: "https://one.example/fails")!)
        }
        #expect(work.now.isEmpty, "a failed request stayed listed")
    }

    @Test("A request the reader walks away from leaves the list")
    func aStoppedRequest() async {
        let work = SourceWork()
        let client = WatchedHTTP(Parked(), for: .picture, in: work)
        let asking = Task { try await client.data(from: URL(string: "https://cdn.example/a.png")!) }
        #expect(await spun { !work.now.isEmpty })
        asking.cancel()
        _ = await asking.result
        #expect(work.now.isEmpty)
    }

    @Test("A request that is sent, not fetched, is listed the same way")
    func aSentRequest() async throws {
        let work = SourceWork()
        let sender = GatedSender()
        let watchdog = hangGuard(sender.gate)
        defer { watchdog.cancel() }
        let client = WatchedHTTP(sender: sender, for: .write, in: work)
        var request = URLRequest(url: URL(string: "https://one.example/api/v1/statuses")!)
        request.httpMethod = "POST"
        let sending = Task { try await client.send(request) }
        #expect(await spun { await sender.asks == 1 })
        #expect(Self.running(work) == ["one.example write"])
        await sender.gate.open()
        _ = try? await sending.value
        #expect(work.now.isEmpty)
    }

    // MARK: - Each path, while it runs

    private static let thread = "https://forum.example/forum.php?mod=viewthread&tid=40125&mobile=2"

    @Test("A forum row whose post is being read is listed as that, and leaves when it lands")
    func aForumPost() async {
        let work = SourceWork()
        let http = GatedHTTP([Self.thread: .text("<div></div>")], holding: Self.thread)
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let posts = ForumPosts(http: http)
        posts.work = work
        let ref = ForumThreadRef(host: "forum.example", tid: 40125)

        let reading = Task { await posts.fetch(ref) }
        #expect(await spun { await http.asks == 1 })
        #expect(Self.running(work) == ["forum.example forumPost"])
        await http.gate.open()
        await reading.value
        #expect(work.now.isEmpty)
    }

    @Test("A forum post's replies are listed as replies")
    func forumReplies() async {
        let work = SourceWork()
        let http = GatedHTTP([Self.thread: .text("<div></div>")], holding: Self.thread)
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let posts = ForumPosts(http: http)
        posts.work = work

        let reading = Task { await posts.fetchReplies(ForumThreadRef(host: "forum.example", tid: 40125)) }
        #expect(await spun { await http.asks >= 1 })
        #expect(Set(Self.running(work)) == ["forum.example forumReplies"])
        await http.gate.open()
        await reading.value
        #expect(work.now.isEmpty)
    }

    @Test("Reloading a timeline is listed per source while it runs, and leaves when it ends",
          .timeLimit(.minutes(1)))
    func aTimelineReload() async {
        let work = SourceWork()
        let http = GatedHTTP([
            "https://one.example/api/v1/trends/statuses?limit=20": .text("[]"),
            MastodonInstance.address(Self.host): MastodonInstance.mastodon(Self.host),
        ], holding: "/api/v1/trends/statuses")
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: GatedSender())
        )
        session.work = work
        await session.reloadFromStore()

        let reloading = Task { await session.reload.timeline(.trends, in: session) }
        #expect(await spun { await http.asks == 1 })
        #expect(Self.running(work) == ["one.example timeline"])
        await http.gate.open()
        await reloading.value
        #expect(work.now.isEmpty)
    }

    @Test("A Mastodon's sign-in checked at launch is listed while it is asked")
    func aMastodonLaunchCheck() async throws {
        let work = SourceWork()
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let sender = GatedSender()
        let watchdog = hangGuard(sender.gate)
        defer { watchdog.cancel() }
        let mastodon = MastodonSessions(tokens: tokens, sender: sender)
        mastodon.work = work

        let checking = Task { await mastodon.verifyAll() }
        #expect(await spun { await sender.asks == 1 })
        #expect(Self.running(work) == ["one.example signInCheck"])
        await sender.gate.open()
        await checking.value
        #expect(work.now.isEmpty)
    }

    @Test("What goes through the signed-in door is listed as what its caller said it is for")
    func theSignedInDoor() async throws {
        let work = SourceWork()
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let sender = GatedSender()
        let watchdog = hangGuard(sender.gate)
        defer { watchdog.cancel() }
        let mastodon = MastodonSessions(tokens: tokens, sender: sender)
        mastodon.work = work
        let door = try #require(mastodon.authorized(host: Self.host, for: .write))

        let acting = Task { _ = try? await door.handle() }
        #expect(await spun { await sender.asks == 1 })
        #expect(Self.running(work) == ["one.example write"])
        await sender.gate.open()
        await acting.value
        #expect(work.now.isEmpty)
    }

    @Test("A forum signing itself in again at launch is listed from the start until it settles")
    func aForumLaunchSignIn() async throws {
        let work = SourceWork()
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: "forum.example", username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        forums.work = work
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }

        forums.signInAgain(hosts: ["forum.example"]) { _ in
            await gate.wait()
            return .handOver(.unreachable)
        }
        #expect(Self.running(work) == ["forum.example signIn"])
        await gate.open()
        #expect(await spun { !forums.isSigningInAgain(host: "forum.example") })
        #expect(await spun { work.now.isEmpty }, "a settled sign-in stayed listed")
    }

    @Test("Pictures on one host are one line with a count, and none once they have come")
    func picturesGather() async {
        let work = SourceWork()
        let http = GatedHTTP([:], holding: "/a.png")
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let pictures = ShellPictures(http: http, enforcingViewerContract: false)
        pictures.work = work

        let first = Task {
            await pictures.fetch(URL(string: "https://cdn.example/a.png?1"), scale: 2, tier: .deck, host: Self.host)
        }
        let second = Task {
            await pictures.fetch(URL(string: "https://cdn.example/a.png?2"), scale: 2, tier: .deck, host: Self.host)
        }
        #expect(await spun { await http.asks == 2 })
        let rows = SourceWorkRow.rows(of: Array(work.now))
        #expect(rows.count == 1)
        #expect(rows.first?.host == "cdn.example")
        #expect(rows.first?.purpose == .picture)
        #expect(rows.first?.count == 2)
        await http.gate.open()
        await first.value
        await second.value
        #expect(work.now.isEmpty)
    }

    // MARK: - The lines

    @Test("What the page draws follows the work as it starts and ends")
    func thePageFollows() async {
        let work = SourceWork()
        let token = work.begin(host: Self.host, for: .timeline)
        #expect(await spun { work.rows.map(\.host) == [Self.host] }, "the page never saw it start")
        work.end(token)
        #expect(await spun { work.rows.isEmpty }, "the page never saw it end")
    }

    @Test("Lines are longest-running first; pictures gather per host; the rest are one each")
    func theLines() {
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ second: Double, _ host: String, _ purpose: SourceWork.Purpose) -> SourceWork.Running {
            SourceWork.Running(host: host, purpose: purpose, since: start.addingTimeInterval(second))
        }
        let running = [
            at(0, "b.example", .timeline),
            at(1, "cdn.example", .picture),
            at(1, "a.example", .timeline),
            at(2, "cdn.example", .picture),
            at(2, "other.example", .picture),
            at(2, "b.example", .timeline),
        ]
        let rows = SourceWorkRow.rows(of: running.enumerated().map { (key: $0.offset, value: $0.element) })
        #expect(rows.map(\.host) == [
            "b.example", "a.example", "cdn.example", "b.example", "other.example",
        ])
        #expect(rows.map(\.count) == [1, 1, 2, 1, 1])
        #expect(rows[2].since == start.addingTimeInterval(1), "a gathered line is as old as its oldest")
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("How long, and what for, in both languages")
    func theWords() {
        let since = Date(timeIntervalSince1970: 0)
        #expect(SourceWorkRow.elapsed(since: since, now: since.addingTimeInterval(7), language: .english) == "7 s")
        #expect(SourceWorkRow.elapsed(since: since, now: since.addingTimeInterval(125), language: .english)
            == "2 min 5 s")
        #expect(SourceWorkRow.elapsed(since: since, now: since.addingTimeInterval(125), language: .taiwanese)
            == "2 分 5 秒")
        #expect(SourceWorkRow.elapsed(since: since, now: since.addingTimeInterval(-3), language: .english) == "0 s")

        let pictures = SourceWorkRow(id: "p", host: "cdn.example", purpose: .picture, count: 3, since: since)
        #expect(pictures.purposeText(language: .english) == "Pictures · 3 at once")
        #expect(pictures.purposeText(language: .taiwanese) == "圖片 · 同時 3 個")
        let one = SourceWorkRow(id: "t", host: "a.example", purpose: .timeline, count: 1, since: since)
        #expect(one.purposeText(language: .english) == "Reading a timeline")

        for language in [DummyLanguage.english, .taiwanese] {
            for key in SourceWork.Purpose.allCases.map(\.titleKey)
                + ["prefs.tab.work", "work.title", "work.none", "work.footer", "work.count"] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    /// No view inspector here, so what the page may reach is pinned by what its file says: the
    /// registry's lines and nothing that could send, stop or show a request.
    @Test("Opening the page asks nothing of anybody")
    func thePageSendsNothing() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/SourceWorkSection.swift")
        let page = try String(contentsOf: file, encoding: .utf8)
        #expect(page.contains("work.rows"))
        for reach in ["http", "session", "Task", ".task", "end(", "begin(", "URL"] {
            #expect(!page.contains(reach), "the page reaches for \(reach)")
        }
        let work = SourceWork()
        _ = SourceWorkSection(work: work)
        #expect(work.now.isEmpty)
    }
}

/// A request that never answers, and gives up when the reader walks away.
private struct Parked: HTTPClient {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(30))
        throw URLError(.timedOut)
    }
}

/// A sender that holds every request until the test opens it, then answers 500.
private actor GatedSender: HTTPSender {
    let gate = Gate()
    private(set) var asks = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        asks += 1
        await gate.wait()
        let url = request.url ?? URL(string: "https://unknown.example")!
        return (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
