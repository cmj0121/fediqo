import Foundation
import Network
import SwiftUI
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// What may be reached beyond a source is a list the person reads, and edits (#226).
///
/// Every test builds its own `SourceWork` and its own `AllowanceBook` on a defaults suite of its
/// own, so nothing here reads or writes the app's shared list or its preferences.
@MainActor
@Suite("The list of what reaches beyond a source")
struct AllowanceListTests {
    private static let forum = "bbs.one.example"
    private static let other = "bbs.two.example"
    private static let cdn = "img.cdn.example"

    /// A book on a defaults suite of its own, with a gate that governs `hosts`; the suite is
    /// emptied when this goes.
    private final class Shelf {
        let suite = "fediqo.test.allowances.\(UUID().uuidString)"
        let defaults: UserDefaults
        let work = SourceWork()
        let book: AllowanceBook

        @MainActor
        init(_ hosts: [String] = [forum, other]) {
            defaults = UserDefaults(suiteName: suite)!
            work.govern(sources: hosts)
            book = AllowanceBook(defaults: defaults, work: work)
            book.sourcesChanged(hosts)
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    // MARK: - What the list says

    @Test("Each entry the app starts with says what it is, what it allows, when, and why, in every language")
    func theEntriesSaySo() {
        #expect(Allowance.standing.map(\.id) == Allowance.ID.builtIn)
        for entry in Allowance.standing {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = [entry.title(language: language), entry.what(language: language),
                            entry.whenText(language: language), entry.why(language: language)]
                for line in said {
                    #expect(!line.hasPrefix("allow."), "\(entry.id.rawValue) says a key in \(language): \(line)")
                    #expect(!line.isEmpty)
                }
                let spoken = entry.spoken(language: language)
                for line in said {
                    #expect(spoken.contains(line.trimmingCharacters(in: CharacterSet(charactersIn: ".。"))))
                }
            }
        }
        let check = Allowance.standing.first { $0.id == .personCheck }!
        #expect(check.hostsText().contains("www.google.com/recaptcha/"))
        #expect(check.hostsText().contains("*.hcaptcha.com"))
        #expect(!Allowance.standing[3].hostsText(language: .english).isEmpty, "a page followed says it goes anywhere")
    }

    @Test("A host the person added is marked as theirs, and says which source it serves")
    func anOwnEntrySaysSo() async {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            #expect(book.add(Self.cdn, for: Self.forum) == nil)
            let entry = book.own[0]
            #expect(entry.id.isOwn && entry.id.ownHost == Self.cdn)
            #expect(entry.title() == Self.cdn)
            let spoken = entry.spoken(language: .english)
            #expect(spoken.hasPrefix("\(Self.cdn). Yours. "))
            #expect(spoken.contains(Self.forum))
            #expect(entry.id.name(language: .english) == "\(Self.cdn) (yours)")
            #expect(!Allowance.standing.contains { $0.id.isOwn })
        }
    }

    @Test("What is typed is read as a host, and what is no host, the source itself or a repeat is refused")
    func whatIsTyped() async {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            #expect(book.add("", for: Self.forum) == .notAHost)
            #expect(book.add("not a host", for: Self.forum) == .notAHost)
            #expect(book.add("localhost", for: Self.forum) == .notAHost)
            #expect(book.add("https://BBS.one.example/x", for: Self.forum) == .itsOwnHost)
            #expect(book.add("https://IMG.cdn.example/a/b.png?x=1", for: Self.forum) == nil)
            #expect(book.own.map { $0.hosts[0].host } == [Self.cdn], "only the host is kept")
            #expect(book.add(Self.cdn, for: Self.forum) == .alreadyThere)
            #expect(book.add(Self.cdn, for: Self.other) == nil, "one host may serve two sources")
            #expect(book.own.count == 2)
        }
    }

    // MARK: - Switching one off

    @Test("The directory switched off is not reached and adding by name still works; on again, it is", .timeLimit(.minutes(1)))
    func theDirectoryOff() async throws {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            let http = FixtureHTTP(["/servers": .text("[]")])
            let session = ShellSession(
                http: http, store: ItemStore(),
                mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: RefusedSender())
            )
            session.work = work
            book.set(.directory, on: false)
            #expect(!book.isOn(.directory))
            session.browse()
            session.chooseProtocol(.mastodon)
            await session.loadCatalog()
            #expect(session.catalog == .off)
            #expect(await http.requested.isEmpty, "the directory was reached")
            #expect(work.admission(reached: ServerDirectory.host, source: nil, for: .directory) == nil)
            #expect(work.record.isEmpty)
            // A source named still has what it is asked before it is one.
            work.named("new.example")
            #expect(work.admits(reached: "new.example", source: nil, for: .joining))
            // Back on, with no relaunch: the next browse reaches it, listed as itself.
            book.set(.directory, on: true)
            await session.loadCatalog()
            #expect(session.catalog == .empty)
            #expect(await http.requested.map(\.host) == [ServerDirectory.host])
            #expect(work.record.last?.allowedBy == .directory)
        }
    }

    @Test("A forum's browser lets through what an entry allows only while the entry is on")
    func aCheckOff() async {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            let engine = ForumWebEngine(host: Self.forum, dataStore: .nonPersistent())
            engine.work = work
            await engine.signingIn(true)
            let elsewhere = URL(string: "https://id.provider.example/login")!
            #expect(engine.decide(elsewhere, mainFrame: true))
            book.set(.signInPage, on: false)
            #expect(!engine.decide(elsewhere, mainFrame: true), "switched off, a page followed away is refused")
            book.set(.personCheck, on: false)
            #expect(!PageRules.rules(.signIn, of: Self.forum, allowing: work.allowances).contains("recaptcha"))
            #expect(await spun { engine.ruledWith?.contains("recaptcha") == false },
                    "the page in front of the person is ruled again at once")
            book.set(.personCheck, on: true)
            #expect(await spun { engine.ruledWith?.contains("recaptcha") == true })
            await engine.signingIn(false)
        }
    }

    // MARK: - A host of the person's own

    @Test("A host added for a source lets that source's pages reach it, named, and removed it no longer does")
    func anOwnHost() async throws {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            book.add(Self.cdn, for: Self.forum)
            let id = Allowance.ID.own(host: Self.cdn, source: Self.forum)
            // The forum's pages may pull it in; another forum's may not.
            let filter = #"^https://img\\.cdn\\.example/"#
            #expect(PageRules.rules(.forum, of: Self.forum, allowing: work.allowances).contains(filter))
            #expect(PageRules.rules(.signIn, of: Self.forum, allowing: work.allowances).contains(filter))
            #expect(!PageRules.rules(.forum, of: Self.other, allowing: work.allowances).contains(filter))
            #expect(!PageRules.rules(.page, allowing: work.allowances).contains(filter), "not a page a post links to")
            #expect(await PageRules.list(.forum, of: Self.forum, allowing: work.allowances) != nil, "it compiles")
            // A frame of it, and what the page says it pulled in, are listed under the forum.
            let engine = ForumWebEngine(host: Self.forum, dataStore: .nonPersistent())
            engine.work = work
            let picture = URL(string: "https://\(Self.cdn)/a/b.png")!
            #expect(engine.decide(picture, mainFrame: false))
            #expect(!engine.decide(picture, mainFrame: true), "the forum's page does not move there")
            engine.pulledIn([picture.absoluteString, "https://tracker.example/p.gif", "https://bbs.one.example/x.png"])
            let rows = work.record
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.source == Self.forum && $0.reached == Self.cdn })
            #expect(rows.allSatisfy { $0.allowedBy == id && $0.purpose == .pagePart })
            // What the source points to there is named by the entry too.
            let http = FixtureHTTP([picture.absoluteString: .text("")])
            _ = try await WatchedHTTP(http, for: .picture, source: Self.forum, in: work).data(from: picture)
            #expect(work.record.last?.allowedBy == id)
            _ = try? await WatchedHTTP(http, for: .picture, source: Self.other, in: work).data(from: picture)
            #expect(work.record.last?.allowedBy == nil, "another source's pointing is its own")
            // Removed: the forum's pages may no longer pull it in, and nothing is named by it.
            book.remove(id)
            #expect(book.own.isEmpty)
            #expect(!PageRules.rules(.forum, of: Self.forum, allowing: work.allowances).contains(filter))
            let before = work.record.count
            #expect(engine.decide(picture, mainFrame: false), "a frame is the rules' to block")
            engine.pulledIn([picture.absoluteString])
            #expect(work.record.count == before)
        }
    }

    // MARK: - Kept

    @Test("After a relaunch the list is as the person left it, and it names nothing reached or when")
    func itOutlivesARelaunch() async throws {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            book.set(.directory, on: false)
            book.add(Self.cdn, for: Self.forum)
            // Something is reached, and none of it is kept.
            work.note(host: Self.cdn, for: .pagePart, source: Self.forum, allowedBy: book.own[0].id)
            let again = AllowanceBook(defaults: defaults, work: SourceWork())
            #expect(again.off == [.directory])
            #expect(again.own == book.own)
            #expect(!again.work.allows(.directory), "handed to the gate as it opens")
            let data = try #require(defaults.data(forKey: AllowanceBook.key))
            let kept = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(kept.keys) == ["off", "own"])
            let own = try #require(kept["own"] as? [[String: String]])
            #expect(own == [["host": Self.cdn, "source": Self.forum]])
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("pagePart") && !text.contains("\"at\""), "an act was kept: \(text)")
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fediqo") } == [AllowanceBook.key])
        }
    }

    @Test("A source removed takes the hosts added for it; one missing at launch is kept, reaching nothing")
    func aSourceRemoved() async {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            book.add(Self.cdn, for: Self.forum)
            book.add("pics.example", for: Self.other)
            book.sourcesChanged([Self.other])
            #expect(book.own.map(\.source) == [Self.other])
            #expect(!work.allowances.contains { $0.source == Self.forum })
            let kept = String(decoding: defaults.data(forKey: AllowanceBook.key) ?? Data(), as: UTF8.self)
            #expect(!kept.contains(Self.forum), "a removed source is still named")
            // A launch whose store names fewer sources takes that as what there is, not a removal.
            let again = AllowanceBook(defaults: defaults, work: SourceWork())
            again.sourcesChanged([])
            #expect(again.own.count == 1)
        }
    }

    // MARK: - Where it is drawn and said

    @Test("An act an entry let through names it, on its line and to VoiceOver")
    func aLineNamesItsEntry() {
        let at = Date(timeIntervalSince1970: 0)
        let plain = SourceAct(id: 1, reached: Self.forum, purpose: .timeline, at: at)
        #expect(plain.allowedText() == nil)
        let directory = SourceAct(
            id: 2, reached: ServerDirectory.host, purpose: .directory, at: at, allowedBy: .directory
        )
        #expect(directory.allowedText(language: .english) == "Let through by Directory of servers")
        #expect(directory.spoken(language: .english).hasSuffix(", let through by Directory of servers"))
        #expect(directory.spoken(language: .taiwanese).hasSuffix("由「來源目錄」放行"))
        let own = SourceAct(
            id: 3, reached: Self.cdn, pointedBy: Self.forum, purpose: .pagePart, at: at,
            allowedBy: .own(host: Self.cdn, source: Self.forum)
        )
        #expect(own.spoken(language: .english).hasPrefix("\(Self.forum), "))
        #expect(own.spoken(language: .english).hasSuffix("let through by \(Self.cdn) (yours)"))
    }

    @Test("Every word the list says is there in all three languages the app ships")
    func theWords() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        var keys = ["prefs.tab.reach", "account.catalog.off", "activity.row.allowed", "activity.row.spoken.allowed",
                    "allow.builtIn", "allow.builtIn.footer", "allow.own", "allow.own.none", "allow.own.footer",
                    "allow.own.noSource", "allow.own.source", "allow.own.host", "allow.own.add", "allow.own.remove",
                    "allow.own.mark", "allow.own.name", "allow.own.what", "allow.own.why", "allow.own.gone",
                    "allow.own.refused.notAHost", "allow.own.refused.itsOwnHost", "allow.own.refused.alreadyThere",
                    "allow.when.adding", "allow.when.forumPage", "allow.when.signingIn", "allow.when.own",
                    "allow.hosts.anywhere", "allow.spoken.joiner", "work.purpose.pagePart"]
        for id in Allowance.ID.builtIn {
            keys += ["title", "what", "why"].map { "allow.\(id.rawValue).\($0)" }
        }
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
    }

    /// No view inspector, so what VoiceOver reads is pinned by what the section draws: each of the
    /// app's entries a switch labelled with everything it says — the switch speaks its own state —
    /// and each of the person's one element labelled the same, with its remove button named.
    @Test("VoiceOver speaks every entry, and its state")
    func itIsSpoken() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/AllowanceSection.swift")
        let section = try String(contentsOf: file, encoding: .utf8)
        #expect(section.contains("Toggle(isOn: on(entry.id)) { EntryText(entry: entry) }\n                    .accessibilityLabel(Text(entry.spoken()))"))
        #expect(section.contains(".accessibilityLabel(String(format: L10n.t(\"allow.own.remove\"), entry.title()))"))
        #expect(section.contains(".accessibilityLabel(Text(entry.spoken()"))
        for reach in ["http", "begin(", "note(", "URLSession"] {
            #expect(!section.contains(reach), "the list reaches for \(reach)")
        }
    }

    @Test("The list draws in light and in dark, with an entry of the person's", arguments: [ColorScheme.light, .dark])
    func drawsInBothSchemes(_ scheme: ColorScheme) async throws {
        let shelf = Shelf()
        let (book, work, defaults) = (shelf.book, shelf.work, shelf.defaults)
        _ = (book, work, defaults)
        do {
            book.add(Self.cdn, for: Self.forum)
            let renderer = ImageRenderer(
                content: VStack(alignment: .leading) {
                    AllowanceSection(book: book, sources: [Self.forum])
                }
                .environment(\.colorScheme, scheme)
                .frame(width: 360)
                .padding()
                .background(ShellChrome.page(scheme))
            )
            let image = try #require(renderer.cgImage)
            #expect(image.width > 0 && image.height > 100)
        }
    }
}

/// A page shown in a forum's browser, with a host the person added for that forum (#226): loaded
/// for real, off screen, and nothing reaches a network — a scheme of this test's own, or loopback.
@MainActor
@Suite("A host the person added, on a forum's page", .serialized)
struct AllowanceOnAPageTests {
    @Test(
        "The forum's page reaches the host added for it; without the entry it does not",
        .timeLimit(.minutes(1)), arguments: [true, false]
    )
    func thePageReachesIt(added: Bool) async throws {
        let forum = "bbs.forum.example"
        let entry = Allowance(
            id: .own(host: "cdn.example", source: forum), when: .forumPage, reach: .frame,
            hosts: [Allowance.Pattern(host: "cdn.example", scheme: PageServed.scheme)], source: forum
        )
        let list = Allowance.standing + (added ? [entry] : [])
        let served = PageServed()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(served, forURLScheme: PageServed.scheme)
        let rules = try #require(await PageRules.list(.forum, of: forum, allowing: list))
        configuration.userContentController.add(rules)
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.load(URLRequest(url: URL(string: "\(PageServed.scheme)://\(forum)/thread")!))
        for _ in 0..<400 where !served.hosts.contains("static.forum.example") {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(served.hosts.contains("static.forum.example"))
        #expect(!served.hosts.contains("tracker.example"), "a host nobody added was reached")
        #expect(served.hosts.contains("cdn.example") == added)
        _ = view
    }

    /// What a page pulls in never passes the browser's navigation policy, so the page says it,
    /// from a world its own scripts cannot reach. Served on loopback, since a page's resource
    /// timing is kept for `http` and not for a scheme of a test's own: the page is `localhost`,
    /// the host the person added is `127.0.0.1`.
    @Test("What the page pulled in from the host added is listed under the forum, naming the entry", .timeLimit(.minutes(1)))
    func whatThePagePulledInIsListed() async throws {
        let server = try LoopServer()
        let port = try await server.start()
        defer { server.stop() }
        let forum = "localhost"
        let work = SourceWork()
        work.govern(sources: [forum])
        let entry = Allowance(
            id: .own(host: "127.0.0.1", source: forum), when: .forumPage, reach: .frame,
            hosts: [Allowance.Pattern(host: "127.0.0.1", scheme: "http")], source: forum
        )
        work.allow(Allowance.standing + [entry])
        let engine = ForumWebEngine(host: forum, dataStore: .nonPersistent())
        engine.work = work
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        for script in ForumWebEngine.userScripts { configuration.userContentController.addUserScript(script) }
        configuration.userContentController.add(
            PulledInHandler(engine), contentWorld: .defaultClient, name: ForumWebEngine.pulledInMessage
        )
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.load(URLRequest(url: URL(string: "http://localhost:\(port)/thread")!))
        #expect(await spun(2_000_000) { work.record.contains { $0.reached == "127.0.0.1" } },
                "what the page pulled in was not listed: \(server.asked)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.asked.contains { $0.hasPrefix("127.0.0.1") }, "the premise: the page did pull it in")
        let rows = work.record
        #expect(rows.count == 1, "its own picture is the forum's, not an entry's: \(rows)")
        #expect(rows.first?.source == forum && rows.first?.allowedBy == entry.id && rows.first?.purpose == .pagePart)
        _ = view
    }
}

/// A plain HTTP server on loopback: `/thread` is a page asking for a picture of its own and one
/// at `127.0.0.1`; everything else is a byte. Remembers the host and first line of every request.
private final class LoopServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [String] = []
    var asked: [String] { lock.withLock { seen } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let lines = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n")
            let first = String(lines.first ?? "")
            let host = lines.first { $0.lowercased().hasPrefix("host:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? ""
            self?.lock.withLock { self?.seen.append(host + " " + first) }
            let isPage = first.contains("/thread")
            let port = host.split(separator: ":").last.map(String.init) ?? ""
            let body = isPage
                ? "<html><body><img src=\"http://127.0.0.1:\(port)/p.png\"><img src=\"/own.png\"></body></html>"
                : "x"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(isPage ? "text/html" : "image/png")\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Serves a forum's page that asks for its own picture, a tracker's pixel and a picture off
/// another host, and remembers every host asked.
@MainActor
private final class PageServed: NSObject, WKURLSchemeHandler {
    static let scheme = "fediqo-allow"
    private(set) var hosts: Set<String> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        hosts.insert(url.host() ?? "")
        let page = """
            <html><body>
            <img src="\(Self.scheme)://static.forum.example/own.png">
            <img src="\(Self.scheme)://tracker.example/pixel.png">
            <img src="\(Self.scheme)://cdn.example/picture.png">
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

private struct RefusedSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
