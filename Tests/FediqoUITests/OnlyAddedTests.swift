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

    @Test("A source named in Unicode owns what is asked of its punycode, and the other way round")
    func internationalNames() {
        let work = Self.governed(["Bücher.Example"])
        #expect(work.admits(reached: "xn--bcher-kva.example", source: nil))
        #expect(work.admits(reached: "b%C3%BCcher.example", source: nil), "as URL.host() hands it back")
        #expect(work.admits(reached: "cdn.example", source: "BÜCHER.example"))
        let ascii = Self.governed(["xn--fsqu00a.xn--g6w251d"])
        #expect(ascii.admits(reached: "例子.測試", source: nil))
        #expect(!ascii.admits(reached: "例子.example", source: nil))
    }

    /// Two windows each adopt the store's sources in their own time; a window adopting late must
    /// not take back a source another has already seen added. So the gate hears from the store
    /// alone, in the order its sources change.
    @Test("The gate hears which sources there are from the store, in the order they change", .timeLimit(.minutes(1)))
    func oneWriter() async {
        let work = Self.governed([])
        let store = ItemStore()
        await store.watchSources { work.sourcesChanged($0) }
        await store.add(Source(host: "new.example", kind: .mastodon))
        #expect(work.admits(reached: "new.example", source: nil))
        await store.remove(host: "new.example")
        #expect(!work.admits(reached: "new.example", source: nil))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let session = try? String(
            contentsOf: root.appendingPathComponent("Sources/FediqoUI/Shell/ShellSession.swift"), encoding: .utf8
        )
        #expect(session?.contains("sourcesChanged") == false, "a window's own copy feeds the gate")
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
        await store.watchSources { work.sourcesChanged($0) }
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
        let governs = try #require(app.range(of: "FediqoRootView.onlyToSources(\n            opened.sources.map(\\.host), kept: store, read: opened.file != nil && opened.setAside == nil\n        )"))
        let asks = try #require(app.range(of: "mastodon.verifyAll()"))
        #expect(governs.lowerBound < asks.lowerBound, "governed before the first ask")
        let session = try String(
            contentsOf: root.appendingPathComponent("Sources/FediqoUI/Shell/ShellSession.swift"), encoding: .utf8
        )
        #expect(session.contains("work.named(parsed)"))
    }

    /// The directory of servers is a third party let through by one entry, for one purpose: it is
    /// asked while a source is being added, listed as itself, and reached by nothing else.
    @Test("The directory is asked while a source is added, listed as itself, and reached by nothing else", .timeLimit(.minutes(1)))
    func theDirectory() async throws {
        let http = FixtureHTTP(["/servers": .text("[]")])
        let session = ShellSession(
            http: http, store: ItemStore(),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: SilentSender())
        )
        let work = Self.governed()
        session.work = work
        session.browse()
        session.chooseProtocol(.mastodon)
        await session.loadCatalog()
        #expect(session.catalog == .empty)
        #expect(await http.requested.map(\.host) == [ServerDirectory.host])
        let row = try #require(work.record.first)
        #expect(row.source == ServerDirectory.host && row.purpose == .directory && row.allowedBy == .directory)
        // Any other purpose, or any other host for this one, is nobody's.
        await #expect(throws: OutwardRefusal.noSource) {
            try await WatchedHTTP(http, for: .timeline, in: work)
                .data(from: URL(string: "https://\(ServerDirectory.host)/servers")!)
        }
        await #expect(throws: OutwardRefusal.noSource) {
            try await WatchedHTTP(http, for: .directory, in: work)
                .data(from: URL(string: "https://\(Self.stranger)/servers")!)
        }
        #expect(await http.requested.count == 1)
        #expect(work.record.count == 1)
        // Out of the browse step, the directory is nobody's again.
        session.stage = nil
        await #expect(throws: OutwardRefusal.noSource) {
            try await WatchedHTTP(http, for: .directory, in: work)
                .data(from: URL(string: "https://\(ServerDirectory.host)/servers")!)
        }
        #expect(await http.requested.count == 1)
    }

    @Test("A window that goes while its add sheet browses takes the directory with it")
    func aClosedWindowStopsBrowsing() {
        let work = Self.governed()
        do {
            let session = ShellSession(
                http: FixtureHTTP(), store: ItemStore(),
                mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: SilentSender())
            )
            session.work = work
            session.browse()
            #expect(work.admission(reached: ServerDirectory.host, source: nil, for: .directory) != nil)
        }
        #expect(work.admission(reached: ServerDirectory.host, source: nil, for: .directory) == nil)
    }

    @Test("The directory is let through only while some window's add sheet is browsing")
    func addingIsARuntimeState() {
        let work = Self.governed()
        // Held for the test: an identifier of an object already gone may be any other's.
        let windows = (NSObject(), NSObject())
        let one = ObjectIdentifier(windows.0), two = ObjectIdentifier(windows.1)
        defer { withExtendedLifetime(windows) {} }
        let host = ServerDirectory.host
        #expect(work.admission(reached: host, source: nil, for: .directory) == nil)
        work.adding(true, by: one)
        work.adding(true, by: two)
        #expect(work.admission(reached: host, source: nil, for: .directory) == .allowed(.directory))
        work.adding(false, by: one)
        #expect(work.admission(reached: host, source: nil, for: .directory) != nil, "another window still browses")
        work.adding(false, by: two)
        #expect(work.admission(reached: host, source: nil, for: .directory) == nil)
    }

    @Test("Only the add sheet's browse step reads the directory")
    func theDirectoryHasOneDoor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var doors: [String] = []
        var calls: [String] = []
        let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("for: .directory") { doors.append(url.lastPathComponent) }
                if line.contains("loadCatalog()"), !line.contains("func loadCatalog") { calls.append(String(line)) }
            }
        }
        #expect(doors == ["ShellSession.swift"])
        #expect(calls.count == 1 && calls[0].contains("Task { await loadCatalog() }"))
        let session = try String(
            contentsOf: root.appendingPathComponent("Sources/FediqoUI/Shell/ShellSession.swift"), encoding: .utf8
        )
        let choose = try #require(session.range(of: "func chooseProtocol("))
        let call = try #require(session.range(of: "Task { await loadCatalog() }"))
        #expect(choose.lowerBound < call.lowerBound, "asked from the browse step")
    }

    // MARK: - What reaches past a source

    @Test("What reaches past a source is one list, and each entry says when it applies")
    func theAllowances() {
        let list = Allowance.standing
        #expect(Set(list.map(\.id)) == Set(Allowance.ID.builtIn))
        #expect(list.first { $0.id == .directory }?.when == .adding)
        #expect(list.first { $0.id == .personCheck }?.when == .signingIn)
        #expect(list.first { $0.id == .signInPage }?.when == .signingIn)
        let check = list.first { $0.id == .personCheck }!
        for address in [
            "https://www.google.com/recaptcha/api2/anchor", "https://www.gstatic.com/recaptcha/releases/x.js",
            "https://www.recaptcha.net/recaptcha/api.js", "https://newassets.hcaptcha.com/c/x",
            "https://static.geetest.com/v4/gt4.js", "https://turing.captcha.qq.com/TCaptcha.js",
            "https://captcha.gtimg.com/1/x.js",
        ] {
            #expect(check.allows(URL(string: address)!), "\(address)")
        }
        for address in [
            "https://www.google.com/search?q=x", "https://www.google-analytics.com/collect",
            "https://www.gstatic.com/fonts/x", "http://hcaptcha.com/x", "https://notgeetest.com/x",
        ] {
            #expect(!check.allows(URL(string: address)!), "\(address)")
        }
        #expect(Allowance.applying(.forumPage).map(\.id) == [.forumChallenge])
        #expect(Set(Allowance.applying(.signingIn).map(\.id)) == [.forumChallenge, .personCheck, .signInPage])
    }

    @Test("A forum's browser stays on its site, but for the check and the pages its sign-in shows")
    func theForumBrowser() async {
        let forum = "bbs.one.example"
        let work = Self.governed([forum])
        let engine = ForumWebEngine(host: forum, dataStore: .nonPersistent())
        engine.work = work
        let captcha = URL(string: "https://www.google.com/recaptcha/api2/anchor")!
        let elsewhere = URL(string: "https://id.provider.example/login")!
        // Reading: its own site, a sibling included, and nothing else; no check but Cloudflare's.
        #expect(engine.decide(URL(string: "https://www.bbs.one.example/forum.php")!, mainFrame: true))
        #expect(!engine.decide(URL(string: "https://static.one.example/x")!, mainFrame: true),
                "a sibling is not the forum's own host")
        #expect(!engine.decide(elsewhere, mainFrame: true))
        #expect(!engine.decide(URL(string: "http://bbs.one.example/")!, mainFrame: true))
        #expect(engine.decide(URL(string: "about:blank")!, mainFrame: true))
        _ = engine.decide(captcha, mainFrame: false)
        _ = engine.decide(URL(string: "https://challenges.cloudflare.com/turnstile/x")!, mainFrame: false)
        #expect(work.record.map(\.allowedBy) == [.forumChallenge], "a frame the reading lets through is listed")
        // Signing in: the check and a page followed away, each under the forum.
        await engine.signingIn(true)
        #expect(engine.decide(elsewhere, mainFrame: true))
        _ = engine.decide(captcha, mainFrame: false)
        _ = engine.decide(URL(string: "https://tracker.example/pixel")!, mainFrame: false)
        let rows = work.record.suffix(2)
        #expect(rows.map(\.source) == [forum, forum])
        #expect(rows.map(\.reached) == ["id.provider.example", "www.google.com"])
        #expect(rows.map(\.purpose) == [.signInPage, .personCheck])
        #expect(rows.map(\.allowedBy) == [.signInPage, .personCheck])
        await engine.signingIn(false)
        #expect(!engine.decide(elsewhere, mainFrame: true), "and only while the sheet is up")
        // A forum the gate no longer admits goes nowhere.
        work.sourcesChanged([])
        #expect(!engine.decide(URL(string: "https://bbs.one.example/")!, mainFrame: true))
    }

    @Test("Outside its sign-in a forum's browser does not follow its page to a neighbour under com.tw")
    func noNeighbourUnderAPublicSuffix() {
        let engine = ForumWebEngine(host: "forum.com.tw", dataStore: .nonPersistent())
        engine.work = Self.governed(["forum.com.tw"])
        #expect(engine.decide(URL(string: "https://www.forum.com.tw/thread")!, mainFrame: true))
        #expect(!engine.decide(URL(string: "https://tracker.com.tw/r")!, mainFrame: true))
        #expect(engine.work.record.isEmpty)
    }

    @Test("A sign-in turned on and then off at once ends off, however the two finish")
    func aStaleSignInDoesNotLand() async {
        let engine = ForumWebEngine(host: "bbs.one.example", dataStore: .nonPersistent())
        let on = Task { await engine.signingIn(true) }
        let off = Task { await engine.signingIn(false) }
        await on.value
        await off.value
        #expect(!engine.signingIn)
        #expect(engine.ruledAs == .forum)
    }

    @Test("The sheet turns the sign-in's allowances on as it opens and off as it goes")
    func theSheetSaysSo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(
            contentsOf: root.appendingPathComponent("Sources/FediqoUI/Shell/ForumSignInSheet.swift"), encoding: .utf8
        )
        #expect(sheet.contains("await engine.signingIn(true)"))
        #expect(sheet.contains(".onDisappear { [engine] in Task { await engine.signingIn(false) } }"))
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
    @Test("The rules are built from the list: a link page lets nothing through, a forum Cloudflare, a sign-in its checks")
    func theRules() throws {
        for kind in [PageRules.Kind.page, .forum, .signIn] {
            let data = Data(PageRules.rules(kind).utf8)
            let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let first = try #require(rules.first)
            #expect((first["trigger"] as? [String: Any])?["load-type"] as? [String] == ["third-party"])
            #expect((first["action"] as? [String: String])?["type"] == "block")
            let frames = kind.allowances(Allowance.standing).flatMap(\.hosts).count
            #expect(rules.count == 1 + frames)
        }
        #expect(PageRules.rules(.page) == #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block"}}]"#)
        #expect(PageRules.rules(.forum).contains(#"^https://challenges\\.cloudflare\\.com/"#))
        #expect(!PageRules.rules(.forum).contains("recaptcha"))
        #expect(PageRules.rules(.signIn).contains(#"^https://www\\.google\\.com/recaptcha/"#))
        #expect(PageRules.rules(.signIn).contains(#"^https://([^/]*\\.)?hcaptcha\\.com/"#))
    }

    @Test("Every list compiles")
    func compiles() async {
        for kind in [PageRules.Kind.page, .forum, .signIn] {
            #expect(await PageRules.list(kind) != nil, "\(kind)")
        }
    }

    /// Fails only a list of its own, so no page another test is loading meanwhile is refused.
    @Test("A compile that failed is asked again, not remembered for the run")
    func aFailureIsNotKept() async {
        let real = PageRules.compile
        defer { PageRules.compile = real }
        let marker = "notkept" + String(UInt64.random(in: 0...UInt64.max), radix: 16)
        let rules = PageRules.rules(
            .forum, of: "failure.example", allowing: [Allowance.own(host: marker + ".example", for: "failure.example")]
        )
        PageRules.compile = { text in text.contains(marker) ? nil : await real(text) }
        #expect(await PageRules.compiled(rules) == nil)
        PageRules.compile = real
        #expect(await PageRules.compiled(rules) != nil, "the next page is not refused for the run")
    }

    /// The same page as below, with an entry of the list letting one outside host through: loaded
    /// under the sign-in's rules, that host is reached and the others are not.
    @Test("An entry the list holds lets its host through, and no other", .timeLimit(.minutes(1)))
    func anEntryLetsItsHostThrough() async throws {
        let served = Served()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(served, forURLScheme: Served.scheme)
        let list = [Allowance(
            id: .personCheck, when: .signingIn, reach: .frame,
            hosts: [Allowance.Pattern(host: "cdn.example", scheme: Served.scheme)]
        )]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FediqoPageRulesTest")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: folder))
        let rules = try #require(try await store.compileContentRuleList(
            forIdentifier: "entry", encodedContentRuleList: PageRules.rules(.signIn, allowing: list)
        ))
        configuration.userContentController.add(rules)
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.load(URLRequest(url: URL(string: "\(Served.scheme)://bbs.forum.example/thread")!))
        for _ in 0..<400 where !served.hosts.contains("cdn.example") {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(served.hosts.contains("cdn.example"), "the entry's host is let through")
        #expect(!served.hosts.contains("tracker.example"), "and nothing else is")
        _ = view
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
            #expect(await PageRules.install(on: configuration.userContentController, .forum))
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
