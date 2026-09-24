import AVFoundation
import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// Nothing reaches a host the person did not add (#220).
///
/// Every outward act belongs to a source the person added: the source itself, or something it
/// pointed to. The one gate is `SourceWork.admits`, asked by `WatchedHTTP` before a request
/// leaves, by the reader before a page moves and by the player before a film plays; a client used
/// without the gate in front of it is refused on the wire (`Outward`).
@MainActor
@Suite("Only what the person added is reached")
struct OnlyAddedTests {
    private static let source = "one.example"
    private static let stranger = "tracker.example"

    private static func governed(_ hosts: [String] = [source]) -> SourceWork {
        let work = SourceWork()
        work.govern(sources: hosts)
        return work
    }

    // MARK: - The gate

    @Test("A source's own host, and what it pointed to, are let through; a host nobody added is not")
    func theGate() {
        let work = Self.governed()
        #expect(work.admits(reached: Self.source, source: nil))
        #expect(work.admits(reached: "files.cdn.example", source: Self.source), "a picture it pointed to")
        #expect(!work.admits(reached: Self.stranger, source: nil))
        #expect(!work.admits(reached: "files.cdn.example", source: Self.stranger), "pointed to by nobody added")
        #expect(!work.admits(reached: "", source: nil))
    }

    @Test("A host is the same host in any case, with a port, and with or without www")
    func folding() {
        let work = Self.governed(["BBS.Example.org:8443"])
        #expect(work.admits(reached: "bbs.example.org", source: nil))
        #expect(work.admits(reached: "www.bbs.example.org", source: nil))
        #expect(work.admits(reached: "x.example", source: " BBS.example.ORG "))
        #expect(!work.admits(reached: "example.org", source: nil))
    }

    @Test("A host the person names to add is theirs, until the source is let go")
    func naming() {
        let work = Self.governed()
        #expect(!work.admits(reached: "new.example", source: nil))
        work.named("New.Example")
        #expect(work.admits(reached: "new.example", source: nil))
        work.sourcesChanged([Self.source, "new.example"])
        work.sourcesChanged([Self.source])
        #expect(!work.admits(reached: "new.example", source: nil), "removing it takes the naming back")
        work.sourcesChanged([])
        #expect(!work.admits(reached: Self.source, source: nil))
    }

    @Test("A record nobody said anything to governs nothing, and a change of sources does not start it")
    func ungoverned() {
        let work = SourceWork()
        work.sourcesChanged([Self.source])
        #expect(work.admits(reached: Self.stranger, source: nil))
    }

    // MARK: - The request path

    @Test("A request that belongs to nobody added never leaves and is not written to the record")
    func refusedRequest() async throws {
        let work = Self.governed()
        let wire = FixtureHTTP(["/": .text("ok")])
        let watched = WatchedHTTP(wire, for: .timeline, in: work)
        await #expect(throws: OutwardRefusal.noSource) {
            try await watched.data(from: URL(string: "https://\(Self.stranger)/")!)
        }
        #expect(await wire.requested.isEmpty)
        #expect(work.record.isEmpty)
        _ = try await watched.data(from: URL(string: "https://\(Self.source)/")!)
        #expect(await wire.requested.count == 1)
        #expect(work.record.map(\.source) == [Self.source])
    }

    @Test("What the gate lets through reaches the wire marked as let through, and nothing else is")
    func theMarkReachesTheWire() async throws {
        let wire = MarkReader()
        #expect(Outward.admitted == false)
        _ = try await WatchedHTTP(wire, for: .picture, source: Self.source, in: Self.governed())
            .data(from: URL(string: "https://cdn.example/a.png")!)
        _ = try await wire.data(from: URL(string: "https://\(Self.source)/")!)
        #expect(wire.marks == [true, false])
    }

    /// The hole #218 left: a client handed around without `WatchedHTTP` in front of it would reach
    /// its host and be written nowhere. Now it reaches nothing.
    @Test("A live client used without the gate reaches nothing")
    func anUnwatchedClientIsRefused() async {
        let live: [(String, any HTTPClient)] = [
            ("default", URLSessionClient()), ("signed in", URLSessionClient.signedIn()),
            ("pictures", ShellPictures.live), ("forum posts", ForumPosts.live),
        ]
        for (name, client) in live {
            #expect((client as? URLSessionClient)?.watchedOnly == true, "\(name) takes an unwatched request")
            await #expect(throws: OutwardRefusal.unwatched, "\(name)") {
                try await client.data(from: URL(string: "https://\(Self.source)/")!)
            }
        }
    }

    @Test("A forum's browser used without the gate reaches nothing either")
    func anUnwatchedForumIsRefused() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        await #expect(throws: OutwardRefusal.unwatched) {
            try await forums.transport(host: Self.source).data(from: URL(string: "https://\(Self.source)/")!)
        }
    }

    @Test("Reading a timeline names only the sources added, and a stranger's address is refused", .timeLimit(.minutes(1)))
    func aRunNamesOnlyAddedSources() async throws {
        let work = Self.governed([])
        let http = FixtureHTTP([
            "https://one.example/api/v1/trends/statuses?limit=20": .text("[]"),
            MastodonInstance.address(Self.source): MastodonInstance.mastodon(Self.source),
        ])
        let store = ItemStore()
        await store.add(Source(host: Self.source, kind: .mastodon))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: SilentSender())
        )
        session.work = work
        await session.reloadFromStore()
        await session.reload.timeline(.trends, in: session)
        #expect(!work.record.isEmpty)
        #expect(work.record.allSatisfy { $0.source == Self.source })
        await #expect(throws: OutwardRefusal.noSource) {
            try await WatchedHTTP(http, for: .timeline, in: work)
                .data(from: URL(string: "https://\(Self.stranger)/api/v1/instance")!)
        }
    }

    @Test("The app says which sources there are before anything is asked, and the add field names a host")
    func theAppGoverns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        let governs = try #require(app.range(of: "FediqoRootView.onlyToSources(opened.sources.map(\\.host))"))
        let asks = try #require(app.range(of: "mastodon.verifyAll()"))
        #expect(governs.lowerBound < asks.lowerBound, "governed before the first ask")
        let session = try String(
            contentsOf: root.appendingPathComponent("Sources/FediqoUI/Shell/ShellSession.swift"), encoding: .utf8
        )
        #expect(session.contains("work.sourcesChanged(sources.map(\\.host))"))
        #expect(session.contains("work.named(parsed)"))
    }

    /// The directory of servers the browser used to list is a third party: nobody the person
    /// added. It is not asked, and the sheet says why rather than that it could not be reached.
    @Test("The directory of servers is nobody the person added, and is not asked", .timeLimit(.minutes(1)))
    func theDirectory() async {
        let http = FixtureHTTP()
        let session = ShellSession(
            http: http, store: ItemStore(),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: SilentSender())
        )
        session.work = Self.governed()
        await session.loadCatalog()
        #expect(session.catalog == .refused)
        #expect(await http.requested.isEmpty)
        for language in [DummyLanguage.english, .taiwanese] {
            let said = L10n.t("account.catalog.refused", language: language)
            #expect(said != "account.catalog.refused")
            #expect(said != L10n.t("account.catalog.failed", language: language))
        }
    }

    // MARK: - Pages and films

    @Test("A page opened from nobody added is refused, and one a source pointed to is not")
    func pages() {
        let reader = ShellReader()
        reader.work = Self.governed()
        #expect(reader.open(URL(string: "https://blog.example/a")!, from: Self.source))
        #expect(reader.decide(URL(string: "https://blog.example/a")!, mainFrame: true))
        #expect(reader.work.record.map(\.source) == [Self.source])
        #expect(reader.open(URL(string: "https://blog.example/b")!, from: nil))
        #expect(!reader.decide(URL(string: "https://blog.example/b")!, mainFrame: true))
        #expect(reader.reading?.refused == true)
        #expect(reader.work.record.count == 1)
    }

    @Test("A film nobody added pointed to is not played")
    func films() {
        let playback = ShellPlayback()
        playback.work = Self.governed()
        playback.makePlayer = { _ in AVPlayer() }
        playback.toggle(URL(string: "https://media.example/v.mp4"), of: "p", on: .row, from: Self.stranger)
        #expect(playback.player == nil)
        #expect(playback.work.record.isEmpty)
        playback.toggle(URL(string: "https://media.example/w.mp4"), of: "q", on: .row, from: Self.source)
        #expect(playback.player != nil)
        #expect(playback.work.record.map(\.source) == [Self.source])
    }
}

/// What a page shown in the app may pull in beside itself (#220): nothing from another site.
///
/// Loaded for real, off screen, through a scheme of this test's own — so every load the page makes
/// comes to `Served`, and nothing reaches a network.
@MainActor
@Suite("A page shown in the app reaches no third party", .serialized)
struct PageRulesTests {
    @Test("The rules block every other site's load, and a forum's let Cloudflare's challenge alone through")
    func theRules() throws {
        for forum in [false, true] {
            let data = Data(PageRules.rules(forum: forum).utf8)
            let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let first = try #require(rules.first)
            #expect((first["trigger"] as? [String: Any])?["load-type"] as? [String] == ["third-party"])
            #expect((first["action"] as? [String: String])?["type"] == "block")
            #expect(rules.count == (forum ? 2 : 1))
        }
        let exception = PageRules.rules(forum: true)
        #expect(exception.contains(#"^https://challenges\\.cloudflare\\.com/"#))
    }

    @Test("Both lists compile")
    func compiles() async {
        #expect(await PageRules.list(forum: false) != nil)
        #expect(await PageRules.list(forum: true) != nil)
    }

    @Test(
        "A page's own site loads beside it and no other site does; without the rules the other would",
        .timeLimit(.minutes(1)), arguments: [true, false]
    )
    func aPageLoads(ruled: Bool) async throws {
        let served = Served()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(served, forURLScheme: Served.scheme)
        if ruled {
            #expect(await PageRules.install(on: configuration.userContentController, forum: true))
        }
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.load(URLRequest(url: URL(string: "\(Served.scheme)://bbs.forum.example/thread")!))
        for _ in 0..<400 where !served.hosts.contains("static.forum.example") {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The page's own picture came; what the page asked of the others had every chance to.
        try await Task.sleep(for: .milliseconds(300))
        #expect(served.hosts.contains("bbs.forum.example"))
        #expect(served.hosts.contains("static.forum.example"), "the page's own site is read")
        let strangers = served.hosts.intersection(["tracker.example", "cdn.example"])
        if ruled {
            #expect(strangers.isEmpty, "a third party was reached: \(strangers)")
        } else {
            #expect(!strangers.isEmpty, "the page does ask the others, so the rules are what stops them")
        }
        _ = view
    }
}

/// Serves a forum's page that asks for its own picture, a tracker's pixel and a library off
/// somebody's CDN, and remembers every host asked.
@MainActor
private final class Served: NSObject, WKURLSchemeHandler {
    static let scheme = "fediqo-test"
    private(set) var hosts: Set<String> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        hosts.insert(url.host() ?? "")
        let page = """
            <html><body>
            <img src="\(Self.scheme)://static.forum.example/own.png">
            <img src="\(Self.scheme)://tracker.example/pixel.png">
            <script src="\(Self.scheme)://cdn.example/lib.js"></script>
            </body></html>
            """
        let isPage = url.path == "/thread"
        let body = Data((isPage ? page : "").utf8)
        task.didReceive(URLResponse(
            url: url, mimeType: isPage ? "text/html" : "application/octet-stream",
            expectedContentLength: body.count, textEncodingName: "utf-8"
        ))
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Answers every request, and remembers whether each came through the gate.
private final class MarkReader: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    var marks: [Bool] { lock.withLock { seen } }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let mark = Outward.admitted
        lock.withLock { seen.append(mark) }
        return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct SilentSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
