import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #170: while a reload runs, its toast names one piece of it — the source's host and the
/// timeline or board it reads, by the name the reader knows — and counts the others as "+2".
///
/// The line is built from `SourceWork`'s entries alone, so the pieces are asserted two ways: the
/// line itself from entries made by hand, and the entries each reload path makes, noted as each
/// of its requests goes out. Every test builds its own `SourceWork`; none sets the shell's
/// language, and each line is asked for in a language named.
@MainActor
@Suite("The reload toast names what it is reading", .serialized)
struct ReloadToastTests {
    private static let one = "one.example"
    private static let since = Date(timeIntervalSince1970: 1_000)

    private static func entry(
        _ second: Double, _ host: String, _ purpose: SourceWork.Purpose = .timeline,
        _ name: SourceWork.Name? = nil
    ) -> SourceWork.Running {
        SourceWork.Running(host: host, purpose: purpose, name: name, since: since.addingTimeInterval(second))
    }

    private static func line(
        _ running: [Int: SourceWork.Running], _ language: DummyLanguage = .english
    ) -> String? {
        TimelineToast.reloading(running, reading: [.timeline], language: language)
    }

    // MARK: - The line

    @Test("One piece: the host and the name it is read under, in both languages")
    func onePiece() {
        let running = [1: Self.entry(0, "mastodon.social", .timeline, .public)]
        #expect(Self.line(running) == "Reloading mastodon.social Public")
        #expect(Self.line(running, .taiwanese) == "重新載入 mastodon.social 公開")

        let board = [1: Self.entry(0, "520cc.cc", .timeline, .called("正妹相簿"))]
        #expect(Self.line(board) == "Reloading 520cc.cc 正妹相簿")
        #expect(Self.line(board, .taiwanese) == "重新載入 520cc.cc 正妹相簿")

        let unnamed = [1: Self.entry(0, "forum.example")]
        #expect(Self.line(unnamed) == "Reloading forum.example", "a front page is its host alone")
        #expect(Self.line(unnamed, .taiwanese) == "重新載入 forum.example")
    }

    @Test("Three pieces: the one running longest is named, and the others counted")
    func threePieces() {
        var running = [
            7: Self.entry(2, "two.example", .timeline, .trends),
            3: Self.entry(0, Self.one, .timeline, .home),
            5: Self.entry(1, "forum.example", .timeline, .called("Child")),
        ]
        #expect(Self.line(running) == "Reloading one.example Home +2")
        #expect(Self.line(running, .taiwanese) == "重新載入 one.example 首頁 +2")

        // The one named ends: the line moves to the longest still running, and the count falls.
        running[3] = nil
        #expect(Self.line(running) == "Reloading forum.example Child +1")
        running[7] = nil
        #expect(Self.line(running) == "Reloading forum.example Child")
        running[5] = nil
        #expect(Self.line(running) == nil, "none left: the toast says its plain word, or ends")
    }

    @Test("Two started in the same instant: the one begun first is named, and it holds still")
    func aTie() {
        let running = [
            9: Self.entry(0, "b.example", .timeline, .trends),
            4: Self.entry(0, "a.example", .timeline, .public),
        ]
        #expect(Self.line(running) == "Reloading a.example Public +1")
    }

    @Test("Work that is not the reload is neither named nor counted")
    func notTheReload() {
        let others: [SourceWork.Purpose] = [
            .picture, .emoji, .signIn, .signInCheck, .boards, .serverCheck, .lists, .directory,
        ]
        var running: [Int: SourceWork.Running] = [:]
        for (at, purpose) in others.enumerated() {
            running[at] = Self.entry(0, "cdn.example", purpose, .called("x"))
        }
        #expect(Self.line(running) == nil)
        running[99] = Self.entry(5, Self.one, .timeline, .home)
        #expect(Self.line(running) == "Reloading one.example Home")

        // An open thread's reload counts its own reads, and not a timeline's.
        let thread = [
            1: Self.entry(0, Self.one, .conversation),
            2: Self.entry(1, "forum.example", .forumReplies),
            3: Self.entry(0, "two.example", .timeline, .public),
        ]
        #expect(TimelineToast.reloading(
            thread, reading: [.conversation, .forumPost, .forumReplies], language: .english
        ) == "Reloading one.example +1")
    }

    @Test("The loading toast keeps its plain word until a piece is running; the others are unchanged")
    func theOtherLines() {
        let toast = TimelineToast.shown(
            running: true, line: L10n.t("timeline.reload.progress", language: .english),
            stopped: false, note: nil
        )
        #expect(toast?.kind == .loading)
        let stopped = TimelineToast.shown(
            running: false, line: L10n.t("timeline.reload.stopped", language: .english),
            stopped: true, note: nil
        )
        #expect(stopped?.text == "Reload stopped.")
        #expect(TimelineToast.reloading([:], reading: [.timeline], language: .english) == nil)
    }

    @Test("Every word of it is in both tables")
    func theStrings() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["timeline.reload.piece", "timeline.reload.host", "timeline.reload.more"] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    // MARK: - What each reload names

    @Test("A reload says which of its purposes are its own, while it runs", .timeLimit(.minutes(1)))
    func whatAReloadReads() async {
        let asked = MastodonInstance.address(Self.one)
        let gated = GatedHTTP([asked: MastodonInstance.mastodon(Self.one)], holding: asked)
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        let session = ShellSession(http: gated, store: store)
        session.work = SourceWork()
        await session.reloadFromStore()
        let running = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        #expect(session.reload.reading == [.timeline])
        await gated.gate.open()
        await running.value
        // Several reloads may run at once (#175), so what is read is what is running: nothing now.
        #expect(session.reload.reading.isEmpty)
    }

    @Test("A Mastodon's Public and Trends are read under those names", .timeLimit(.minutes(1)))
    func publicAndTrends() async {
        let work = SourceWork()
        let http = Noting(FixtureHTTP([
            "https://\(Self.one)/api/v1/timelines/public?limit=40": .text("[]"),
            "https://\(Self.one)/api/v1/trends/statuses?limit=20": .text("[]"),
            MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
        ]), work: work)
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: NotingSender(work: work))
        )
        session.work = work
        await session.reloadFromStore()

        await session.reload.timeline(.all, in: session)

        #expect(await http.seen("/api/v1/timelines/public") == ["Reloading one.example Public"])
        #expect(await http.seen("/api/v1/trends/statuses") == ["Reloading one.example Trends"])
        #expect(await http.seen("/api/v2/instance") == ["-"], "asking what a server is is not the reload")
        #expect(work.now.isEmpty)
    }

    @Test("Signed in, Home and a list are read under Home and the list's own title", .timeLimit(.minutes(1)))
    func homeAndAList() async throws {
        let work = SourceWork()
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let sender = NotingSender(work: work, bodies: [
            "/api/v1/lists": #"[{"id":"42","title":"Friends"}]"#,
        ])
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.subscribe(host: Self.one, toLists: [ListSubscription(id: "42", name: "Friends")])
        let session = ShellSession(
            http: FixtureHTTP([
                "https://\(Self.one)/api/v1/timelines/public?limit=40": .text("[]"),
                "https://\(Self.one)/api/v1/trends/statuses?limit=20": .text("[]"),
                MastodonInstance.address(Self.one): MastodonInstance.mastodon(Self.one),
            ]),
            store: store, mastodon: MastodonSessions(tokens: tokens, sender: sender)
        )
        session.work = work
        session.mastodon.work = work
        await session.reloadFromStore()

        await session.reload.timeline(.all, in: session)

        #expect(await sender.seen("/api/v1/timelines/home") == ["Reloading one.example Home"])
        #expect(await sender.seen("/api/v1/timelines/list/42") == ["Reloading one.example Friends"])
        #expect(await sender.seen("/api/v1/lists") == ["-"], "reading the lists' names is not a timeline")
        #expect(await sender.everything.allSatisfy { !$0.contains("42") }, "never a list's id")
        #expect(work.now.isEmpty)
    }

    @Test("A forum's boards are read under their names, never their numbers", .timeLimit(.minutes(1)))
    func aForumsBoards() async {
        let work = SourceWork()
        let http = Noting(FixtureHTTP(SubBoardChoiceTests.routes), work: work)
        let store = ItemStore()
        await store.add(Source(host: SubBoardChoiceTests.host, kind: .discuz, boards: [
            BoardSubscription(fid: 434, name: "Child"),
            BoardSubscription(fid: 40, name: "Neighbour"),
        ]))
        let session = ShellSession(http: http, store: store)
        session.work = work
        await session.reloadFromStore()

        await session.reload.timeline(.all, in: session)

        let host = SubBoardChoiceTests.host
        #expect(await http.seen(SubBoardChoiceTests.read(434)) == ["Reloading \(host) Child"])
        #expect(await http.seen(SubBoardChoiceTests.read(40)) == ["Reloading \(host) Neighbour"])
        for line in await http.everything {
            #expect(!line.contains("434") && !line.contains("fid") && !line.contains("/"), "\(line)")
        }
    }
}

/// The toast's line at the moment each request goes out, from inside its watch — "-" where the
/// reload has no piece of its own running.
private func toastLine(_ work: SourceWork) -> String {
    TimelineToast.reloading(work.now, reading: [.timeline], language: .english) ?? "-"
}

/// An HTTP client noting the toast's line as each request goes out.
private actor Noting: HTTPClient {
    private let inner: FixtureHTTP
    private let work: SourceWork
    private var noted: [(url: URL, line: String)] = []

    init(_ inner: FixtureHTTP, work: SourceWork) {
        self.inner = inner
        self.work = work
    }

    /// What the toast said each time `url` — a whole address, or a path — was asked for.
    func seen(_ url: String) -> [String] {
        noted.filter { $0.url.absoluteString == url || $0.url.path == url }.map(\.line)
    }

    var everything: [String] { noted.map(\.line) }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        noted.append((url, toastLine(work)))
        return try await inner.data(from: url)
    }
}

/// A signed-in door noting the toast's line as each request goes out, answering each path with
/// its body, or an empty timeline.
private actor NotingSender: HTTPSender {
    private let work: SourceWork
    private let bodies: [String: String]
    private var noted: [(path: String, line: String)] = []

    init(work: SourceWork, bodies: [String: String] = [:]) {
        self.work = work
        self.bodies = bodies
    }

    func seen(_ path: String) -> [String] {
        noted.filter { $0.path == path }.map(\.line)
    }

    var everything: [String] { noted.map(\.line) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        noted.append((url.path, toastLine(work)))
        let body = bodies[url.path] ?? "[]"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
