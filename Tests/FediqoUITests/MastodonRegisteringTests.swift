import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon as far as registering with it goes: its own list of words, what it answers a
/// registration, and a token for whatever page was approved. It remembers every request, and
/// can hold its list or a registration at a gate.
private actor RegisteringHost: HTTPSender {
    static let listPath = "/.well-known/oauth-authorization-server"

    enum List: Sendable {
        /// No such address: 404.
        case none
        case words([String])
        case body(Data, status: Int = 200)
        /// Answered whole, from another address than the one asked.
        case from(String)
        case unreachable
        /// Answered too late for anybody still to be waiting: the wait ends when the ask is
        /// given up, and by itself after five seconds.
        case slow([String])
    }

    private let list: List
    /// Whether a registration's answer names back the words asked, as a 4.6 does.
    private let echoes: Bool
    /// A word this server does not know: a registration naming it is refused whole.
    private let unknown: String?
    /// Where the first ask for the list, or the first registration, waits before it is answered.
    private let listGate: Gate?
    private let appGate: Gate?
    /// A word this server leaves out of every token it issues, whatever the page asked.
    private let withheld: String?
    /// The client id every registration is answered with, where it is not the usual one.
    private let client: String?
    private var heldList = false
    private var heldApp = false
    private(set) var requests: [URLRequest] = []
    private var apps = 0
    private var issued = 0

    init(
        list: List = .none, echoes: Bool = true, unknown: String? = nil, holdingList listGate: Gate? = nil,
        holdingApp appGate: Gate? = nil, withholding withheld: String? = nil, client: String? = nil
    ) {
        self.withheld = withheld
        self.client = client
        self.list = list
        self.echoes = echoes
        self.unknown = unknown
        self.listGate = listGate
        self.appGate = appGate
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }
    var listAsks: Int { paths.filter { $0 == Self.listPath }.count }

    private static func asked(_ request: URLRequest, _ name: String) -> String {
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let field = form.split(separator: "&").first { $0.hasPrefix("\(name)=") }
        return String(field?.dropFirst(name.count + 1) ?? "").removingPercentEncoding ?? ""
    }

    /// The scopes each registration was asked for, in order.
    var registered: [String] {
        requests.filter { $0.url?.path == "/api/v1/apps" }.map { Self.asked($0, "scopes") }
    }

    var revoked: [String] {
        requests.filter { $0.url?.path == "/oauth/revoke" }.map { Self.asked($0, "token") }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        func answer(_ body: Data, _ status: Int = 200, from: URL? = nil) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: from ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func json(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) { answer(Data(body.utf8), status) }
        switch url.path {
        case Self.listPath:
            if let listGate, !heldList {
                heldList = true
                await listGate.wait()
            }
            switch list {
            case .none: return json("<html>Not Found</html>", 404)
            case .words(let words): return answer(try JSONSerialization.data(withJSONObject: ["scopes_supported": words]))
            case .body(let body, let status): return answer(body, status)
            case .from(let address):
                let words = MastodonRegistration.superset().split(separator: " ").map(String.init)
                return answer(try JSONSerialization.data(withJSONObject: ["scopes_supported": words]), from: URL(string: address)!)
            case .unreachable: throw URLError(.notConnectedToInternet)
            case .slow(let words):
                try await Task.sleep(for: .seconds(5))
                return answer(try JSONSerialization.data(withJSONObject: ["scopes_supported": words]))
            }
        case "/api/v1/apps":
            let scopes = Self.asked(request, "scopes")
            if let appGate, !heldApp {
                heldApp = true
                await appGate.wait()
            }
            if let unknown, scopes.split(separator: " ").contains(Substring(unknown)) {
                return json(#"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#, 422)
            }
            apps += 1
            let named = scopes.split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
            let echo = echoes ? #","redirect_uri":"fediqo://oauth","scopes":[\#(named)]"# : ""
            return json(#"{"client_id":"\#(client ?? "cid-\(apps)")","client_secret":"csecret-\#(apps)"\#(echo)}"#)
        case "/oauth/token":
            issued += 1
            let granted = Self.asked(request, "scope").split(separator: " ").filter { $0 != withheld ?? "" }
            return json(#"{"access_token":"tok-\#(issued)","scope":"\#(granted.joined(separator: " "))"}"#)
        case "/api/v1/accounts/verify_credentials":
            return json(#"{"id":"1","acct":"me"}"#)
        case "/oauth/revoke":
            return json("{}")
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The server's own page: approved, closed, or answered `invalid_scope` — after a gate, where
/// the test holds one.
@MainActor
private final class RegisteredPage: OAuthBrowser {
    enum Answer { case approve, close, invalidScope }

    private let answer: Answer
    private let gate: Gate?
    /// What each page asked the person to agree to, and the registration it was opened on.
    private(set) var scopes: [String] = []
    private(set) var clients: [String] = []

    init(_ answer: Answer = .approve, gate: Gate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        scopes.append(value("scope"))
        clients.append(value("client_id"))
        await gate?.wait()
        switch answer {
        case .approve: return URL(string: "fediqo://oauth?code=c&state=\(value("state"))")!
        case .invalidScope: return URL(string: "fediqo://oauth?error=invalid_scope&state=\(value("state"))")!
        case .close: throw MastodonSignInError.cancelled
        }
    }
}

/// One registration for every word a sign-in may be asked for (#347), as `MastodonSessions`
/// makes it: what a host is asked and in what order, what its own list takes away, what a
/// refusal and a page with no way back cost, and what a registration an earlier build made is
/// left as. The words and the list's reading are `MastodonRegistrationTests`' in the Core suite.
@MainActor
@Suite("Registering this app at a Mastodon")
struct MastodonRegisteringTests {
    private let host = "social.example"
    private static let whole = MastodonRegistration.superset()
    private static let words = MastodonRegistration.superset().split(separator: " ").map(String.init)
    private static let reading = MastodonOAuth.reading
    private static let acting = MastodonOAuth.scopes(writing: true)
    private static let leastReading = MastodonOAuth.scopes(search: false, writing: false, bookmarks: false)
    private static let leastActing = MastodonOAuth.scopes(search: false, writing: true, bookmarks: false)
    /// A sign-in to act with search and no bookmarks: what one asked for before #285.
    private static let actingLessBookmarks = MastodonOAuth.scopes(writing: true, bookmarks: false)

    private func sessions(_ server: RegisteringHost) -> (MastodonSessions, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        return (MastodonSessions(tokens: tokens, sender: server), tokens)
    }

    /// A sign-in an earlier build made, and the registration it made it on — for one exact string.
    private func earlier(_ tokens: MemoryMastodonTokens, scopes: String?) throws -> (MastodonToken, MastodonApp) {
        let app = MastodonApp(host: host, clientID: "cid-old", clientSecret: "csecret-old", scopes: scopes)
        let token = MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid-old", clientSecret: "csecret-old", scopes: scopes, asked: scopes
        )
        try tokens.save(app)
        try tokens.save(token)
        return (token, app)
    }

    // MARK: - What a host is asked, and in what order

    @Test("A first sign-in asks the host its list, registers once for everything, and opens one page for what was chosen", arguments: [false, true])
    func theOrder(writing: Bool) async throws {
        let server = RegisteringHost(list: .words(Self.words + ["read", "write", "push", "admin:write"]))
        let (mastodon, tokens) = sessions(server)
        let work = SourceWork()
        mastodon.work = work
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: writing) == nil)

        // (A sign-in that may act is then asked who it is, as before: a fifth ask, not this one's.)
        #expect(await server.paths.prefix(4) == [
            RegisteringHost.listPath, "/api/v1/apps", "/oauth/token", "/api/v1/accounts/verify_credentials",
        ])
        #expect(await server.registered == [Self.whole], "a larger list added a word, or took one")
        let chosen = writing ? Self.acting : Self.reading
        #expect(page.scopes == [chosen], "the registration is wider; the page is not")
        #expect(try tokens.app(host: host)?.scopes == Self.whole)
        #expect(try tokens.token(host: host)?.scopes == chosen)
        #expect(try tokens.token(host: host)?.asked == chosen)
        // The list is asked as anybody, and of this host: a plain GET with no sign-in on it.
        let asked = try #require(await server.requests.first)
        #expect(asked.url?.absoluteString == "https://\(host)\(RegisteringHost.listPath)")
        #expect(asked.value(forHTTPHeaderField: "Authorization") == nil && asked.httpBody == nil)
        // And it is in the run's record with the rest of the sign-in.
        let listed = work.record.filter { $0.purpose == .signIn && $0.source == host }
        #expect(listed.count == 4, "an ask of this sign-in is missing from the record")
    }

    @Test("What the host's list lacks is left out of the registration, and off the page where a sign-in is whole without it")
    func lessTheList() async throws {
        let server = RegisteringHost(list: .words(Self.words.filter { $0 != "write:bookmarks" }))
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        let without = Self.whole.replacingOccurrences(of: " write:bookmarks", with: "")
        #expect(await server.registered == [without], "one registration, and no refusal spent finding the word out")
        #expect(page.scopes == [MastodonOAuth.scopes(writing: true, bookmarks: false)], "search was dropped with bookmarks")
        #expect(try tokens.token(host: host)?.asked == Self.acting, "the host said it has none: the row stops offering it")
        #expect(mastodon.bookmarks(host: host) == .unavailable)
        #expect(mastodon.grants == [host: .writing])

        // The next sign-in is on the same registration: nothing more is registered, and the list
        // is not asked for again this run.
        await mastodon.signOut(host: host)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(), writing: true) == nil)
        #expect(await server.registered == [without])
        #expect(await server.listAsks == 1)
    }

    @Test("A host whose list has none of what a sign-in cannot do without is registered with for nothing, and no page opens")
    func theListHasNoneOfIt() async throws {
        let server = RegisteringHost(list: .words(Self.words.filter { $0 != "write:statuses" }))
        let (mastodon, tokens) = sessions(server)
        let (held, app) = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == .invalidScope)

        #expect(await server.paths == [RegisteringHost.listPath])
        #expect(page.scopes.isEmpty)
        #expect(try tokens.token(host: host) == held)
        #expect(try tokens.app(host: host) == app)
    }

    /// What a host may answer the ask for its list with, that is no list.
    private static func notAList(_ named: String) -> RegisteringHost.List {
        switch named {
        case "unreachable": .unreachable
        case "a redirect": .body(Data(), status: 302)
        case "answered from elsewhere": .from("https://elsewhere.example/.well-known/oauth-authorization-server")
        case "not a list": .body(Data(#"{"scopes_supported":"read write"}"#.utf8))
        case "a page": .body(Data("<html>hello</html>".utf8))
        case "somebody else's list": .words(["openid", "profile", "email"])
        case "only the coarse words": .words(["read", "write", "follow", "push"])
        case "past the ceiling": .body(Data(repeating: 0x20, count: SourceReach.wordListBody + 1))
        case "too many words": .words(words + (0...MastodonRegistration.listWords).map { "x:\($0)" })
        default: .none
        }
    }

    @Test("A host with no list that can be read is registered with for everything as it is, and that is no failure", arguments: [
        "no such address", "unreachable", "a redirect", "answered from elsewhere", "not a list", "a page",
        "somebody else's list", "only the coarse words", "past the ceiling", "too many words",
    ])
    func noList(named: String) async throws {
        let server = RegisteringHost(list: Self.notAList(named))
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(await server.registered == [Self.whole])
        #expect(page.scopes == [Self.acting])
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        #expect(await server.paths.prefix(2) == [RegisteringHost.listPath, "/api/v1/apps"])
        #expect(await server.listAsks == 1)
    }

    @Test("A list that does not come in time is no list: the registration goes without it")
    func aSlowList() async throws {
        let server = RegisteringHost(list: .slow(MastodonPart.reading.words))
        let (mastodon, tokens) = sessions(server)
        mastodon.wordListWait = .milliseconds(20)

        let failure = await mastodon.signIn(host: host, through: RegisteredPage(), writing: true)

        #expect(failure == nil)
        #expect(await server.registered == [Self.whole], "a list that came too late took words away")
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
    }

    @Test("The list's ceiling and its host are put on the plain client before it is listed or bounded, and it is asked in one place")
    func theListIsBoundedAsItArrives() throws {
        let live = try #require(SourceReach.wordList(URLSessionClient.signedIn()) as? URLSessionClient)
        #expect(live.byteLimit == SourceReach.wordListBody && live.sameOriginOnly)
        let wide = URLSessionClient(session: .shared, byteLimit: URLSessionClient.defaultByteLimit, sameOriginOnly: false)
        let narrowed = try #require(SourceReach.wordList(wide) as? URLSessionClient)
        #expect(narrowed.byteLimit == SourceReach.wordListBody && narrowed.sameOriginOnly)
        #expect(SourceReach.wordListBody >= MastodonRegistration.listBytes)

        let text = try Self.source("FediqoUI/Shell/MastodonSignIn.swift")
        #expect(text.contains("WatchedHTTP(sender: SourceReach.wordList(sender), for: .signIn, in: work)"))
        #expect(text.components(separatedBy: ".listedWords()").count == 2, "the list is asked for in more than one place")
        #expect(text.components(separatedBy: ".registered(for:").count == 2, "a registration is made in more than one place")
    }

    private static func source(_ path: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appending(path: "Sources").appending(path: path), encoding: .utf8)
    }

    @Test("No page opens by itself: nothing in a sign-in walks from one set of words to the next")
    func theRungsAreGone() throws {
        for path in ["FediqoUI/Shell/MastodonSignIn.swift", "FediqoCore/MastodonAuth.swift"] {
            let text = try Self.source(path)
            for gone in ["ladder", "rung", "known(writing", "putBack", "setAside"] {
                #expect(!text.contains(gone), "\(path) still has \(gone)")
            }
        }
        // One page a call: the browser is opened once in the session's sign-in, outside any loop.
        let session = try Self.source("FediqoUI/Shell/MastodonSignIn.swift")
        #expect(session.components(separatedBy: "oauth.signIn(as:").count == 2)
        let body = try #require(session.components(separatedBy: "    func signIn(\n").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        let loops = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("while ") || $0.hasPrefix("for ") || $0.hasPrefix("repeat") }
        #expect(loops.isEmpty, "the sign-in loops: \(loops)")
    }

    // MARK: - Refused

    @Test("A host that refuses everything is asked for what was chosen, then for less, a part at a time down to the least — and never again that run: each refusal is remembered")
    func theSteps() async throws {
        let server = RegisteringHost(unknown: "read:search")
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(await server.registered == [Self.whole, Self.acting, Self.actingLessBookmarks, Self.leastActing])
        #expect(page.scopes == [Self.leastActing], "one page, for what the host would register")
        #expect(try tokens.app(host: host)?.scopes == Self.leastActing)
        // Search alone parted the registration refused from the one made: the host has none.
        // Bookmarks were only left off on the way down, and nobody was asked for them.
        #expect(try tokens.token(host: host)?.asked == Self.actingLessBookmarks, "a word a narrower try left off was written down as asked")
        #expect(mastodon.bookmarks(host: host) == .unasked, "bookmarks read as refused, though the host was never asked for them alone")

        // Later presses that want more than the registration kept: the host is asked for
        // nothing it refused, and the kept registration serves.
        for _ in 0..<3 {
            let again = RegisteredPage()
            #expect(await mastodon.signIn(host: host, through: again, writing: true) == nil)
            #expect(again.scopes == [Self.leastActing])
        }
        #expect(await server.registered.count == 4)
        #expect(await server.listAsks == 1, "the list was asked for again though everything is no longer tried")
    }

    @Test("A host with no list that lacks one part alone costs a sign-in that part and no other: three registrations, one page, and the part is said to be one the host has none of", arguments: [false, true])
    func lacksOnePart(writing: Bool) async throws {
        // To act, it is bookmarks the host lacks; to read, search.
        let server = RegisteringHost(unknown: writing ? "write:bookmarks" : "read:search")
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: writing) == nil)

        let chosen = writing ? Self.acting : Self.reading
        let made = writing ? Self.actingLessBookmarks : Self.leastReading
        #expect(await server.registered == [Self.whole, chosen, made])
        #expect(page.scopes == [made])
        #expect(try tokens.token(host: host)?.scopes == made)
        #expect(MastodonOAuth.searches(made) == writing, "a host lacking bookmarks alone cost the sign-in its search")
        #expect(try tokens.token(host: host)?.asked == chosen, "what the host itself refused was not written down as asked")
        if writing { #expect(mastodon.bookmarks(host: host) == .unavailable) }
    }

    @Test("A sign-in to read on a host that lacks bookmarks alone keeps its search: everything refused, what was chosen is registered")
    func readingKeepsSearch() async throws {
        let server = RegisteringHost(unknown: "write:bookmarks")
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: false) == nil)

        #expect(await server.registered == [Self.whole, Self.reading])
        #expect(page.scopes == [Self.reading])
        #expect(try tokens.token(host: host)?.scopes == Self.reading)
        #expect(try tokens.token(host: host)?.asked == Self.reading)
    }

    @Test("Everything refused, a registration kept from before that can carry the page serves before anything narrower is registered: a sign-in held keeps its bookmarks")
    func aKeptRegistrationServesAfterARefusal() async throws {
        // A host with no search, and an earlier build's registration and sign-in: no search, with bookmarks.
        let server = RegisteringHost(unknown: "read:search")
        let (mastodon, tokens) = sessions(server)
        let older = MastodonOAuth.scopes(search: false, writing: true)
        let (_, app) = try earlier(tokens, scopes: older)
        mastodon.refresh()
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(await server.registered == [Self.whole], "a narrower registration was made though the one kept serves")
        #expect(page.clients == ["cid-old"] && page.scopes == [older])
        #expect(try tokens.app(host: host) == app)
        #expect(try tokens.token(host: host)?.scopes == older, "signing in again took bookmarks from a sign-in that held them")
        #expect(mastodon.bookmarks(host: host) == .allowed)
        #expect(try tokens.token(host: host)?.asked == older, "search, which no registration here was refused for alone, was written down as asked")
    }

    @Test("No registration narrower than the sign-in held is made: where the host refuses what is asked, the sign-in held stays as it was")
    func nothingNarrowerThanHeld() async throws {
        // Held with search, on a registration that cannot ask to act; the host has no acting.
        let server = RegisteringHost(unknown: "write:statuses")
        let (mastodon, tokens) = sessions(server)
        let (held, app) = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == .invalidScope)

        // Everything, then what was chosen, then that without bookmarks — and not without search.
        #expect(await server.registered == [Self.whole, Self.acting, Self.actingLessBookmarks])
        #expect(page.scopes.isEmpty)
        #expect(try tokens.token(host: host) == held)
        #expect(try tokens.app(host: host) == app)
        #expect(await server.revoked.isEmpty)
    }

    @Test("A host that refuses the least as well opens no page, keeps what was kept, and is not asked again for either")
    func refusedTwice() async throws {
        let server = RegisteringHost(unknown: "read:statuses")
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page) == .invalidScope)
        #expect(await server.registered == [Self.whole, Self.reading, Self.leastReading])
        let asked = await server.paths.count

        for _ in 0..<3 {
            #expect(await mastodon.signIn(host: host, through: page) == .invalidScope)
        }
        #expect(await server.paths.count == asked, "a host that has answered was asked again")
        #expect(page.scopes.isEmpty)
        #expect(try tokens.app(host: host) == nil)
        #expect(!mastodon.stranded(host: host), "a refusal is not a page with no way back")
    }

    @Test("A host that registers less than it was asked and says so is believed: the page asks for no word it left out")
    func aNarrowerEcho() async throws {
        // It lists nothing, and registers everything but names back no bookmarks.
        let server = NarrowingHost(leavingOut: "write:bookmarks")
        let tokens = MemoryMastodonTokens()
        let mastodon = MastodonSessions(tokens: tokens, sender: server)
        let page = RegisteredPage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(page.scopes == [MastodonOAuth.scopes(writing: true, bookmarks: false)])
        let recorded = try tokens.app(host: host)?.scopes
        #expect(recorded == Self.whole.replacingOccurrences(of: " write:bookmarks", with: ""), "more was recorded than the host named")
    }

    // MARK: - A page with no way back

    @Test("A page closed on a registration nothing confirmed: the next press registers for the least; closed again, the host is not asked again this run")
    func stranded() async throws {
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)

        let first = RegisteredPage(.close)
        #expect(await mastodon.signIn(host: host, through: first, writing: true) == nil)
        #expect(first.scopes == [Self.acting])
        #expect(try tokens.app(host: host) == nil, "the suspected registration was kept")
        #expect(!mastodon.stranded(host: host))

        let second = RegisteredPage(.close)
        #expect(await mastodon.signIn(host: host, through: second, writing: true) == .invalidScope, "the second strand is said")
        #expect(second.scopes == [Self.leastActing], "the second try still carried a part a sign-in is whole without")
        #expect(await server.registered == [Self.whole, Self.leastActing])
        #expect(try tokens.app(host: host) == nil)
        #expect(mastodon.stranded(host: host))

        // And no more registrations that run, whatever is pressed.
        let asked = await server.paths.count
        let third = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: third, writing: true) == .invalidScope)
        #expect(await mastodon.signIn(host: host, through: third, writing: false) == .invalidScope)
        #expect(await server.paths.count == asked && third.scopes.isEmpty)
        #expect(try tokens.token(host: host) == nil)
        #expect(await server.revoked.isEmpty)
    }

    @Test("After one such page the second try signs in for the least, and what it left off was not asked: each stays a lock at its own place")
    func theSecondTry() async throws {
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)

        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(page.scopes == [Self.leastActing])
        #expect(await server.registered == [Self.whole, Self.leastActing])
        #expect(try tokens.token(host: host)?.asked == Self.leastActing, "a part left off the page was written down as asked")
        #expect(mastodon.bookmarks(host: host) == .unasked, "bookmarks read as refused, though nobody was asked")
        #expect(mastodon.grants == [host: .writing] && !mastodon.stranded(host: host))
        #expect(await server.listAsks == 1)
    }

    @Test("A page closed on a registration the host confirmed is only a page closed, however often", arguments: [true, false])
    func confirmed(echoes: Bool) async throws {
        // Confirmed by naming the words back, or by the host's own list.
        let server = RegisteringHost(list: echoes ? .none : .words(Self.words), echoes: echoes)
        let (mastodon, tokens) = sessions(server)
        for _ in 0..<3 {
            #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        }
        #expect(!mastodon.stranded(host: host))
        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)
        #expect(page.scopes == [Self.acting], "a page merely closed cost the sign-in its search and bookmarks")
        #expect(await server.registered.allSatisfy { $0 == Self.whole })
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
    }

    @Test("A host that refuses everything and confirms nothing: a page closed once is suspected, closed twice the host is not asked again, and the second press registers once, for the least")
    func strandedAfterARefusal() async throws {
        let server = RegisteringHost(echoes: false, unknown: "write:bookmarks")
        let (mastodon, tokens) = sessions(server)

        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        let first = [Self.whole, Self.acting, Self.actingLessBookmarks]
        #expect(await server.registered == first)
        #expect(!mastodon.stranded(host: host))
        #expect(try tokens.app(host: host) == nil)

        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == .invalidScope)
        #expect(await server.registered == first + [Self.leastActing], "something the host refused was asked for again")
        #expect(mastodon.stranded(host: host))
        let asked = await server.paths.count
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(), writing: true) == .invalidScope)
        #expect(await server.paths.count == asked)
    }

    @Test("A page closed drops the registration it was opened on and no other: one another sign-in made meanwhile is left")
    func aClosedPageDropsOnlyItsOwn() async throws {
        let gate = Gate()
        let server = RegisteringHost()
        let (mastodon, tokens) = sessions(server)
        _ = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()
        let slow = RegisteredPage(.close, gate: gate)

        // A page on the registration kept from before, held open…
        let pressing = Task { await mastodon.signIn(host: host, through: slow, writing: false) }
        let up = await spun { slow.scopes.count == 1 }
        // …while a sign-in that wants more than it holds makes another, and finishes.
        let other = await mastodon.signIn(host: host, through: RegisteredPage(), writing: true)
        await gate.open()
        let failure = await pressing.value

        #expect(up, "the page never opened")
        #expect(other == nil)
        #expect(failure == nil)
        #expect(slow.clients == ["cid-old"])
        #expect(try tokens.app(host: host)?.clientID == "cid-1", "the registration the sign-in held was made on was dropped by another's page")
        #expect(try tokens.token(host: host)?.clientID == "cid-1")
    }

    @Test("A page that answers invalid_scope is taken as one with no way back: no second page, the registration dropped, and the next press is for the least")
    func invalidScopeAtThePage() async throws {
        let server = RegisteringHost()
        let (mastodon, tokens) = sessions(server)
        let first = RegisteredPage(.invalidScope)
        #expect(await mastodon.signIn(host: host, through: first, writing: true) == .invalidScope)
        #expect(first.scopes == [Self.acting])
        #expect(try tokens.app(host: host) == nil)
        #expect(!mastodon.stranded(host: host))

        let second = RegisteredPage(.invalidScope)
        #expect(await mastodon.signIn(host: host, through: second, writing: true) == .invalidScope)
        #expect(second.scopes == [Self.leastActing])
        #expect(mastodon.stranded(host: host))
        #expect(await server.registered == [Self.whole, Self.leastActing])
    }

    @Test("A sign-in held is untouched by a page with no way back: nothing is ended, it goes on as it was, and the second press registers exactly what it asks — never the least")
    func strandedWhileHeld() async throws {
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)
        let (held, _) = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()

        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        let second = RegisteredPage(.close)
        #expect(await mastodon.signIn(host: host, through: second, writing: true) == .invalidScope)

        #expect(await server.registered == [Self.whole, Self.acting])
        #expect(second.scopes == [Self.acting], "a sign-in held was asked on a page for less than the press asked")
        #expect(try tokens.token(host: host) == held)
        #expect(await server.revoked.isEmpty)
        #expect(mastodon.grants == [host: .reading])
    }

    @Test("After a page with no way back, a press approved with a sign-in held leaves it with no word fewer: what was asked is registered, and its page is the whole of it")
    func theSecondTryWhileHeld() async throws {
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)
        _ = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)

        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(page.scopes == [Self.acting], "the second try left search and bookmarks off, with a sign-in held that has search")
        #expect(await server.registered == [Self.whole, Self.acting])
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        #expect(MastodonOAuth.searches(try tokens.token(host: host)?.scopes))
    }

    @Test("A sign-in that came back through a registration confirms it: a later page closed under it is only a page closed, and the next press is asked whole")
    func aSignInConfirmsItsRegistration() async throws {
        // A host with no list that names nothing back: its registration is one nothing confirmed.
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(), writing: false) == nil)
        let held = try #require(try tokens.token(host: host))
        #expect(held.scopes == Self.reading)

        // Later, pressed for more, and the page closed.
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        #expect(try tokens.token(host: host) == held)

        // The next press, approved: everything is registered for again, and the page is the whole of what was asked.
        let wide = Self.acting
        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(await server.registered == [Self.whole, Self.whole], "a page closed under a working registration was taken for one with no way back")
        #expect(page.scopes == [wide])
        #expect(try tokens.token(host: host)?.scopes == wide, "a sign-in held came out with fewer words than it went in with")
        #expect(mastodon.bookmarks(host: host) == .allowed)
        // The same account's, and holding no more than the one kept: left live, and written down.
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        #expect(!mastodon.stranded(host: host))
    }

    @Test("A sign-in that would leave the one held with fewer of the words it asked is not kept: the one held stays, and the new one is ended — reading alone, which the person chose, is kept")
    func neverFewerThanHeld() async throws {
        // A host that issues every sign-in without search, whatever its page asked.
        let server = RegisteringHost(withholding: "read:search")
        let (mastodon, tokens) = sessions(server)
        let (held, _) = try earlier(tokens, scopes: Self.acting)
        mastodon.refresh()

        #expect(await mastodon.signIn(host: host, through: RegisteredPage(), writing: true) == .unreadable)

        #expect(try tokens.token(host: host) == held, "a server talked this device out of a sign-in it holds")
        #expect(await server.revoked == ["tok-1"], "the sign-in not kept was left live, or the one held was ended")
        #expect(mastodon.grants == [host: .writing] && mastodon.bookmarks(host: host) == .allowed)

        // Held without search to begin with, nothing is taken: kept as any other.
        let narrow = RegisteringHost(withholding: "read:search")
        let (other, kept) = sessions(narrow)
        _ = try earlier(kept, scopes: Self.leastActing)
        other.refresh()
        #expect(await other.signIn(host: host, through: RegisteredPage(), writing: true) == nil)
        #expect(try kept.token(host: host)?.scopes == MastodonOAuth.scopes(search: false, writing: true))

        // And "read only" is the person's own choice of less: kept, and the wider one ended.
        let plain = RegisteringHost()
        let (third, chosen) = sessions(plain)
        _ = try earlier(chosen, scopes: Self.acting)
        third.refresh()
        #expect(await third.signIn(host: host, through: RegisteredPage(), writing: false) == nil)
        #expect(try chosen.token(host: host)?.scopes == Self.reading)
        #expect(await plain.revoked == ["tok-old"])
    }

    // MARK: - What a run learnt, let go

    @Test("A sign-in kept at a host spends what was suspected of it: a page closed later is the first again, not the second")
    func aSignInKeptClearsTheSuspicion() async throws {
        let server = RegisteringHost(echoes: false)
        let (mastodon, tokens) = sessions(server)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(), writing: true) == nil)
        await mastodon.signOut(host: host)

        // Closed on the registration kept: dropped, as one from before is. Then closed on one made afresh.
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        let fresh = RegisteredPage(.close)
        #expect(await mastodon.signIn(host: host, through: fresh, writing: true) == nil, "one page closed after a sign-in that worked was said as the second")

        #expect(fresh.scopes == [Self.acting], "a host that has since signed in was still asked for the least")
        #expect(!mastodon.stranded(host: host))
        #expect(try tokens.app(host: host) == nil)
    }

    @Test("Removing a source lets go of everything the run learnt of its host: added again it is asked as one nothing is known of, and the sign-out waits on nothing")
    func removedIsForgotten() async throws {
        let server = RegisteringHost(echoes: false, unknown: "write:bookmarks")
        let (mastodon, _) = sessions(server)
        // It refused everything, and two pages ended with nothing sent back.
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == nil)
        #expect(await mastodon.signIn(host: host, through: RegisteredPage(.close), writing: true) == .invalidScope)
        #expect(mastodon.stranded(host: host))
        let before = await server.registered

        // A plain sign-out forgets none of it.
        await mastodon.signOut(host: host)
        #expect(mastodon.stranded(host: host))

        // Removed: the sign-out is not kept waiting, and the host may be asked again.
        let removing = Task { await mastodon.signOut(host: host, forgettingApp: true) }
        let removed = await spun { !mastodon.stranded(host: host) }
        await removing.value
        #expect(removed, "the sign-out waited, or the host is still not asked")

        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)
        #expect(await server.registered == before + [Self.whole, Self.acting, Self.actingLessBookmarks], "a refusal was held against a source added again")
        #expect(page.scopes == [Self.actingLessBookmarks])
    }

    @Test("A registration answered with no client id, or one too long to be one, is a registration that failed: no page, nothing kept, nothing held against the host", arguments: ["", String(repeating: "c", count: 513)])
    func aRegistrationWithNoClient(id: String) async throws {
        let server = RegisteringHost(echoes: false, client: id)
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        for _ in 0..<2 {
            #expect(await mastodon.signIn(host: host, through: page, writing: true) == .unreadable)
        }

        #expect(await server.registered == [Self.whole, Self.whole], "a failed registration was taken for a refusal of its words")
        #expect(page.scopes.isEmpty)
        #expect(try tokens.app(host: host) == nil)
        #expect(!mastodon.stranded(host: host))
    }

    // MARK: - A registration an earlier build made

    @Test("At launch a sign-in made on an earlier build's registration is asked who it is and nothing else: nothing is registered, listed or ended, and its registration is as it was", arguments: [
        MastodonOAuth.reading, MastodonOAuth.readingWithoutSearch, MastodonOAuth.scopes(writing: true, bookmarks: false),
        MastodonOAuth.scopes(writing: true), MastodonOAuth.scopes(writing: true, notices: true), nil,
    ] as [String?])
    func leftAloneAtLaunch(scopes: String?) async throws {
        let server = RegisteringHost()
        let tokens = MemoryMastodonTokens()
        let (held, app) = try earlier(tokens, scopes: scopes)
        let mastodon = MastodonSessions(tokens: tokens, sender: server)

        await mastodon.verifyAll()
        mastodon.refresh()

        #expect(await server.paths == ["/api/v1/accounts/verify_credentials"])
        #expect(try tokens.app(host: host) == app)
        #expect(try tokens.token(host: host)?.accessToken == held.accessToken)
        #expect(try tokens.token(host: host)?.scopes == scopes)
        #expect(mastodon.isSignedIn(host: host))
    }

    @Test("A registration an earlier build made serves a sign-in for the words it holds: nothing is asked of the host but the page")
    func servesWhatItHolds() async throws {
        let server = RegisteringHost()
        let (mastodon, tokens) = sessions(server)
        let (_, app) = try earlier(tokens, scopes: Self.acting)
        mastodon.refresh()

        for writing in [true, false] {
            let page = RegisteredPage()
            #expect(await mastodon.signIn(host: host, through: page, writing: writing) == nil)
            #expect(page.scopes == [writing ? Self.acting : Self.reading])
            #expect(page.clients == ["cid-old"])
        }
        #expect(await server.registered.isEmpty)
        #expect(await server.listAsks == 0)
        #expect(try tokens.app(host: host) == app)
    }

    @Test("Asked for a word it lacks, at a press, an earlier registration is made again for everything; a page then closed leaves the sign-in held as it was")
    func madeAgainAtAPress() async throws {
        let server = RegisteringHost()
        let (mastodon, tokens) = sessions(server)
        let (held, _) = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()

        let closed = RegisteredPage(.close)
        #expect(await mastodon.signIn(host: host, through: closed, writing: true) == nil)
        #expect(await server.registered == [Self.whole])
        #expect(closed.scopes == [Self.acting] && closed.clients == ["cid-1"])
        #expect(try tokens.token(host: host) == held, "the sign-in held was touched by a page closed")
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.app(host: host)?.scopes == Self.whole)

        // Pressed again and approved: the same registration, and only now is the old sign-in replaced.
        let page = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)
        #expect(await server.registered == [Self.whole])
        #expect(try tokens.token(host: host)?.clientID == "cid-1")
        #expect(await server.revoked == ["tok-old"])
    }

    // MARK: - Let go of meanwhile

    @Test("Signed out, or removed, while the host's list is out: nothing is registered, no page opens, and what was stored is as it was", arguments: [false, true])
    func letGoWhileTheListIsOut(removed: Bool) async throws {
        let gate = Gate()
        let server = RegisteringHost(list: .words(Self.words), holdingList: gate)
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage()

        let pressing = Task { await mastodon.signIn(host: host, through: page, writing: true) }
        let out = await spun { await server.listAsks == 1 }
        await mastodon.signOut(host: host, forgettingApp: removed)
        await gate.open()
        let failure = await pressing.value

        #expect(out, "the ask never went out")
        #expect(failure == nil)
        #expect(await server.registered.isEmpty, "a registration was spent on a source the person let go of")
        #expect(page.scopes.isEmpty)
        #expect(try tokens.app(host: host) == nil)
        #expect(try tokens.token(host: host) == nil)
    }

    @Test("Signed out, or removed, while the registration is out: it is kept nowhere, no page opens, and an earlier one is as the sign-out left it", arguments: [false, true])
    func letGoWhileTheRegistrationIsOut(removed: Bool) async throws {
        let gate = Gate()
        let server = RegisteringHost(holdingApp: gate)
        let (mastodon, tokens) = sessions(server)
        let (_, app) = try earlier(tokens, scopes: Self.reading)
        mastodon.refresh()
        let page = RegisteredPage()

        let pressing = Task { await mastodon.signIn(host: host, through: page, writing: true) }
        let out = await spun { await server.registered.count == 1 }
        await mastodon.signOut(host: host, forgettingApp: removed)
        await gate.open()
        let failure = await pressing.value

        #expect(out, "the ask never went out")
        #expect(failure == nil)
        #expect(page.scopes.isEmpty, "a page opened on a source the person let go of")
        #expect(try tokens.app(host: host) == (removed ? nil : app), "a registration landed after the person let go")
        #expect(try tokens.token(host: host) == nil)
        #expect(await server.registered.count == 1)
        #expect(await server.revoked == ["tok-old"])
    }

    @Test("Removed while the page is up, and the page then closed or answered invalid_scope: nothing is said, and nothing is concluded about the host", arguments: [false, true])
    func letGoWhileThePageIsUp(closed: Bool) async throws {
        let answer: RegisteredPage.Answer = closed ? .close : .invalidScope
        for echoes in [false, true] { try await letGo(answer, echoes: echoes) }
    }

    /// `echoes` false is a host that confirms nothing: left to itself, its page would be suspected.
    private func letGo(_ answer: RegisteredPage.Answer, echoes: Bool) async throws {
        let gate = Gate()
        let server = RegisteringHost(echoes: echoes)
        let (mastodon, tokens) = sessions(server)
        let page = RegisteredPage(answer, gate: gate)

        let pressing = Task { await mastodon.signIn(host: host, through: page, writing: true) }
        let up = await spun { page.scopes.count == 1 }
        await mastodon.signOut(host: host, forgettingApp: true)
        await gate.open()
        let failure = await pressing.value

        #expect(up, "the page never opened")
        #expect(failure == nil, "something was said under a row that is gone")
        #expect(try tokens.app(host: host) == nil)
        // Added again and signed in to: asked as a host nothing is known of.
        let again = RegisteredPage()
        #expect(await mastodon.signIn(host: host, through: again, writing: true) == nil)
        #expect(again.scopes == [Self.acting], "a page on a source let go of was held against the host")
        #expect(await server.registered == [Self.whole, Self.whole])
    }

    @Test("A registration another sign-in made while this one's was out is not written over; this one's still serves its own page")
    func anotherRegistrationIsLeft() async throws {
        let gate = Gate()
        let server = RegisteringHost(holdingApp: gate)
        let (mastodon, tokens) = sessions(server)
        let slow = RegisteredPage(.close)

        let pressing = Task { await mastodon.signIn(host: host, through: slow, writing: true) }
        let out = await spun { await server.registered.count == 1 }
        // The first registration is out; another sign-in on the same source finishes meanwhile.
        let quick = RegisteredPage()
        let other = await mastodon.signIn(host: host, through: quick, writing: true)
        let made = try tokens.app(host: host)
        await gate.open()
        let failure = await pressing.value

        #expect(out, "the ask never went out")
        #expect(other == nil)
        #expect(failure == nil)
        #expect(quick.clients == ["cid-1"] && slow.clients == ["cid-2"])
        #expect(made?.clientID == "cid-1")
        #expect(try tokens.app(host: host) == made, "a registration made meanwhile was written over, or dropped")
        #expect(try tokens.token(host: host)?.clientID == "cid-1")
    }

    @Test("A registration another sign-in kept while the list was out is used: nothing more is registered")
    func aRegistrationKeptMeanwhileIsUsed() async throws {
        let gate = Gate()
        let server = RegisteringHost(list: .words(Self.words), holdingList: gate)
        let (mastodon, tokens) = sessions(server)
        let slow = RegisteredPage()

        let pressing = Task { await mastodon.signIn(host: host, through: slow, writing: false) }
        let out = await spun { await server.listAsks == 1 }
        let other = await mastodon.signIn(host: host, through: RegisteredPage(), writing: true)
        await gate.open()
        let failure = await pressing.value

        #expect(out, "the ask never went out")
        #expect(other == nil)
        #expect(failure == nil)
        #expect(await server.registered == [Self.whole], "two sign-ins at once registered twice")
        #expect(slow.clients == ["cid-1"] && slow.scopes == [Self.reading])
        #expect(try tokens.app(host: host)?.clientID == "cid-1")
    }
}

/// A host that registers whatever it is asked and names back all of it but one word.
private actor NarrowingHost: HTTPSender {
    private let leftOut: String
    private var issued = 0

    init(leavingOut leftOut: String) { self.leftOut = leftOut }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        func json(_ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch url.path {
        case "/api/v1/apps":
            let named = MastodonRegistration.superset().split(separator: " ").filter { $0 != leftOut }
                .map { "\"\($0)\"" }.joined(separator: ",")
            return json(#"{"client_id":"cid","client_secret":"csecret","scopes":[\#(named)]}"#)
        case "/oauth/token":
            issued += 1
            return json(#"{"access_token":"tok-\#(issued)"}"#)
        case "/api/v1/accounts/verify_credentials":
            return json(#"{"id":"1","acct":"me"}"#)
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}
