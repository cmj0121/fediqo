import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon answering what an ask in place sends it, by path, and remembering each request.
/// Every answer can be changed, and any path held at a gate, so a test acts between two steps.
actor PartServer: HTTPSender {
    static let check = "/api/v1/accounts/verify_credentials"
    static let info = "/oauth/token/info"
    static let list = "/.well-known/oauth-authorization-server"
    static let apps = "/api/v1/apps"
    static let trade = "/oauth/token"
    static let revoke = "/oauth/revoke"

    /// How one path is answered where it is not answered as a 4.6 would.
    enum Answer: Sendable {
        case body(String, Int = 200)
        case fails
    }

    private let tokens: MemoryMastodonTokens
    private var answers: [String: Answer] = [:]
    private var gates: [String: Gate] = [:]
    /// Who the account check names, by the token it is asked with. Unlisted, account `1`.
    private var accounts: [String: String?] = [:]
    /// The words this host's own list names, where it gives one.
    private var listed: [String]?
    /// Whether a registration's answer names the words it was made for.
    private var echoes = true
    /// Words this host registers for none of, with no list of its own to say so.
    private var unregistered: Set<String> = []
    /// The words a trade says it granted, where it says other than it was asked.
    private var grants: String?
    private var issued = 0
    /// The token whose account check waits at a gate, where one does.
    private var heldCheck: (token: String, gate: Gate)?
    private(set) var requests: [URLRequest] = []
    /// The paths held at a gate now.
    private(set) var waiting: [String] = []

    init(tokens: MemoryMastodonTokens) {
        self.tokens = tokens
    }

    func answer(_ path: String, _ answer: Answer?) { answers[path] = answer }
    func hold(_ path: String, at gate: Gate?) { gates[path] = gate }
    func holdCheck(of token: String, at gate: Gate) { heldCheck = (token, gate) }
    func name(_ token: String, as account: String?) { accounts[token] = .some(account) }
    func lists(_ words: [String]?) { listed = words }
    func registersNone(of words: [String]) { unregistered = Set(words) }
    func echoesNothing() { echoes = false }
    func grant(_ words: String?) { grants = words }
    func forget() { requests = [] }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    /// The token strings this server was asked to end, in order.
    var revoked: [String] { requests.filter { $0.url?.path == Self.revoke }.compactMap { Self.field("token", of: $0) } }

    /// The words each registration was asked for, in order.
    var registered: [String] { requests.filter { $0.url?.path == Self.apps }.compactMap { Self.field("scopes", of: $0) } }

    private static func field(_ name: String, of request: URLRequest) -> String? {
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let field = form.split(separator: "&").first { $0.hasPrefix(name + "=") }
        return field.map { String($0.dropFirst(name.count + 1)).removingPercentEncoding ?? "" }
    }

    private static func bearer(_ request: URLRequest) -> String {
        String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        requests.append(request)
        let checked = url.path == Self.check && heldCheck?.token == Self.bearer(request)
        if let gate = gates[url.path] ?? (checked ? heldCheck?.gate : nil) {
            waiting.append(url.path)
            await gate.wait()
            waiting.removeAll { $0 == url.path }
        }
        func answered(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch answers[url.path] {
        case .body(let body, let status)?: return answered(body, status)
        case .fails?: throw URLError(.notConnectedToInternet)
        case nil: break
        }
        switch url.path {
        case Self.check:
            guard let account = accounts[Self.bearer(request)] ?? "1" else { return answered("{}") }
            return answered(#"{"id":"\#(account)","acct":"me"}"#)
        case Self.info:
            let held = (try? tokens.token(host: url.host() ?? "")) ?? nil
            return answered(PartAskFixture.info(held?.scopes))
        case Self.list:
            guard let listed else { return answered("{}", 404) }
            return answered(#"{"scopes_supported":[\#(listed.map { "\"\($0)\"" }.joined(separator: ","))]}"#)
        case Self.apps:
            let asked = (Self.field("scopes", of: request) ?? "").split(separator: " ").map(String.init)
            let known = listed.map(Set(asked).isSubset) ?? true
            if !known || !unregistered.isDisjoint(with: asked) {
                return answered(#"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#, 422)
            }
            let named = echoes ? #","scopes":[\#(asked.map { "\"\($0)\"" }.joined(separator: ","))]"# : ""
            return answered(#"{"client_id":"cid","client_secret":"csecret","redirect_uri":"fediqo://oauth"\#(named)}"#)
        case Self.trade:
            issued += 1
            let scope = grants.map { #","scope":"\#($0)""# } ?? ""
            return answered(#"{"access_token":"new-\#(issued)"\#(scope)}"#)
        case Self.revoke:
            return answered("{}")
        case "/api/v1/timelines/home":
            return answered("[]")
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The source's own page, answered by the test.
@MainActor
final class PartPage: OAuthBrowser {
    enum Answer {
        case allow, close, refuse, refuseForged
        /// The page came back saying something went wrong, in the source's own word for it.
        case fault(String)
    }

    private let answer: Answer
    private let gate: Gate?
    private(set) var opened = 0
    /// What each page asked the person to agree to, in order.
    private(set) var scopes: [String] = []

    init(_ answer: Answer = .allow, gate: Gate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened += 1
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        scopes.append(items.first { $0.name == "scope" }?.value ?? "")
        await gate?.wait()
        let state = items.first { $0.name == "state" }?.value ?? ""
        switch answer {
        case .allow: return URL(string: "fediqo://oauth?code=c&state=\(state)")!
        case .close: throw MastodonSignInError.cancelled
        case .refuse: return URL(string: "fediqo://oauth?error=access_denied&state=\(state)")!
        case .refuseForged: return URL(string: "fediqo://oauth?error=access_denied&state=other")!
        case .fault(let error): return URL(string: "fediqo://oauth?error=\(error)&state=\(state)")!
        }
    }
}

/// #347 — a sign-in already held is asked for a further part where it stands: one question,
/// one page of the source's own, and the sign-in the person had left exactly as it was by
/// everything but a yes there.
@MainActor
@Suite("Asking a sign-in for a part where it stands", .watched)
struct PartAskTests {
    private typealias S = PartServer
    private let host = "social.example"
    private let forum = "bbs.example.org"
    /// A sign-in that reads and acts, made before bookmarks were asked for.
    private static let acting = MastodonOAuth.scopes(writing: true, bookmarks: false)
    private static let wider = MastodonOAuth.scopes(writing: true)
    private static let reading = MastodonOAuth.reading

    /// A session holding `scopes` at the host under the token string `held-1`, filed as a
    /// package or an earlier run files one: nobody has asked its source anything of it.
    private func shell(
        holding scopes: String? = PartAskTests.acting, asked: String? = nil
    ) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes,
                asked: asked ?? scopes
            ))
        }
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        for source in [Source(host: host, kind: .mastodon), Source(host: forum, kind: .discuz)] {
            await session.store.add(source)
        }
        session.sources = await session.store.sources()
        // A door's deadline, on a clock nobody turns: an ask held at a gate is not ended by one,
        // and no check here waits for one to pass.
        session.mastodon.deadlineSleep = TurnedClock().sleep
        return (session, server, tokens)
    }

    /// What is held, as a line a test compares before and after: the string, its words, what
    /// it was asked and refused, and the mark of its filing.
    private func kept(_ tokens: MemoryMastodonTokens) throws -> [String?] {
        let token = try tokens.token(host: host)
        return [token?.accessToken, token?.scopes, token?.asked, token?.refused, token?.stamp]
    }

    /// The bookmark question raised as a press raises it, and answered yes.
    private func press(_ session: ShellSession, through page: PartPage) async {
        await session.allowBookmarks(host: host, through: page)
    }

    private func said(_ key: String) -> String {
        String(format: L10n.t(key), host)
    }

    private func post(in session: ShellSession) async -> DummyItem {
        let note = Note(
            id: "https://social.example/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: "9"
        )
        await session.store.ingest([note])
        await session.reloadFromStore()
        return DummyItem(note)
    }

    // MARK: - What is asked of the source, and in what order

    @Test("A sign-in made this run is asked in place with two requests and one page: the trade and the new sign-in's check — its account and its words are already this device's own")
    func aSignInMadeThisRun() async throws {
        let (session, server, tokens) = try await shell(holding: nil)
        await session.signIn(host: host, through: PartPage(), writing: false)
        let first = try #require(try tokens.token(host: host))
        await server.forget()

        let page = PartPage()
        let answer = await session.mastodon.ask([.notices], host: host, through: page)

        #expect(answer == .allowed)
        #expect(await server.paths == [S.trade, S.check])
        #expect(page.scopes == [Self.reading + " read:notifications"])
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken != first.accessToken && now.scopes == Self.reading + " read:notifications")
        // The sign-in it took the place of is left live, and written down to be ended later.
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        #expect(session.mastodon.standing(.notices, host: host) == .held)
    }

    @Test("A sign-in this device has not confirmed costs two asks before its page — whose it is, then the source's own account of its words — and the page, the trade and the check after; the pressed bookmark is not sent")
    func aSignInNotConfirmed() async throws {
        let (session, server, tokens) = try await shell()
        let row = await post(in: session)
        #expect(session.acts(on: row).asks(.bookmark))
        #expect(session.askToBookmark(row))
        let ask = try #require(session.partAsks.open)
        #expect(await server.paths.isEmpty, "the press itself asked the source something")
        #expect(ShellQuestion.part(ask) == ShellQuestion.bookmarks(host: host).inPlace(at: host))

        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        let asked = await server.paths.filter { $0 != "/api/v1/timelines/home" }
        #expect(asked == [S.check, S.info, S.list, S.apps, S.trade, S.check])
        let bearers = await server.requests.prefix(2).map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(bearers == ["Bearer held-1", "Bearer held-1"])
        #expect(page.scopes == [Self.wider])
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(try tokens.token(host: host)?.asked == Self.wider)
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        // The act whose lock was pressed is offered now, and was not carried out.
        #expect(session.acts(on: row).offers(.bookmark) && !session.acts(on: row).asks(.bookmark))
        let all: [String] = await server.paths
        #expect(all.allSatisfy { !$0.contains("bookmark") }, "the act whose lock was pressed was carried out by itself")
        #expect(session.rowRefusal == nil && session.toast == nil)

        // Its words are this device's own now: asked again, nothing is confirmed twice.
        await server.forget()
        let second = PartPage(.close)
        _ = await session.mastodon.ask([.notices], host: host, through: second)
        let again: [String] = await server.paths
        #expect(second.opened == 1)
        #expect(again.isEmpty, "a sign-in made this run was asked about again before its page")
    }

    // MARK: - Before any page

    @Test("Where the source does not say whose sign-in it is — no id, an error, no answer — no page opens, nothing held changes, and the place says so with what to do", arguments: [0, 1, 2])
    func theAccountNotConfirmed(_ how: Int) async throws {
        let (session, server, tokens) = try await shell()
        switch how {
        case 0: await server.name("held-1", as: nil)
        case 1: await server.answer(S.check, .body("{}", 500))
        default: await server.answer(S.check, .fails)
        }
        let before = try kept(tokens)
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(await server.paths == [S.check], "a sign-in nobody could name was asked about further")
        #expect(try kept(tokens) == before)
        #expect(session.rowRefusal?.key == "part.ask.unconfirmed")
        #expect(session.toast?.text == said("part.ask.unconfirmed"))
        #expect(session.mastodon.bookmarks(host: host) == .unasked, "it may be asked again later")
    }

    @Test("Words a sign-in is filed with are not believed until its source has said them: the page is built from the source's own account of the token, which is written over what was filed")
    func theWordsAreTheSourcesOwn() async throws {
        // Filed as holding notices, which its source says it does not.
        let (session, server, tokens) = try await shell(holding: Self.acting + " read:notifications")
        await server.answer(S.info, .body(PartAskFixture.info(Self.acting)))
        let page = PartPage()
        #expect(session.askBookmarks(host: host))
        let first = try #require(session.partAsks.open)
        // Filed as reading notices and not as dismissing them: the words that say the page
        // asks to dismiss are not this page's, and the plain ones are said.
        #expect(ShellQuestion.part(first) == ShellQuestion.bookmarks(host: host).inPlace(at: host))

        session.partAsks.answer(first, through: page, in: session)
        await session.partAsks.landed(host: host)

        // What the question said the sign-in has is not what it has: no page on that question,
        // and the question again, drawn from what the source says.
        #expect(page.opened == 0, "a page opened on a question drawn from what the source does not say")
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        var again = try #require(session.partAsks.open)
        #expect(again.again, "a question put again did not say it was")
        again.again = false
        #expect(ShellQuestion.part(again) == ShellQuestion.bookmarks(host: host).inPlace(at: host))
        again.again = true
        #expect(session.toast == nil)
        #expect(session.rowRefusal == nil)

        session.partAsks.answer(again, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [Self.wider], "the page asked for a word only the device's own note held")
        #expect(try tokens.token(host: host)?.scopes == Self.wider)
        #expect(session.mastodon.notices(host: host) != .allowed)
    }

    @Test("A package that files the very token this device made, saying it holds more, is believed in nothing it says: asked in place, the source is asked again whose the sign-in is and what it holds before any page, and the page is built from the source's own account of it")
    func theVeryTokenFromAPackage() async throws {
        let (session, server, tokens) = try await shell(holding: nil)
        await session.signIn(host: host, through: PartPage(), writing: false)
        let made = try #require(try tokens.token(host: host))
        // As a read back files it: forgotten, then filed as the package says it is.
        try tokens.forget(host: host)
        let claimed = Self.reading + " read:follows write:follows"
        try tokens.save(.carried(
            host: host, accessToken: made.accessToken, clientID: made.clientID, clientSecret: made.clientSecret,
            scopes: claimed, asked: claimed, refused: nil, accountID: made.accountID, handle: made.handle
        ))
        session.mastodon.readBack()
        await session.mastodon.leftSettled()
        await server.answer(S.info, .body(PartAskFixture.info(Self.reading)))
        await server.forget()

        let page = PartPage()
        let answer = await session.mastodon.ask([.notices], host: host, through: page)

        #expect(answer == .allowed)
        #expect(Array(await server.paths.prefix(2)) == [S.check, S.info], "what a package said of a sign-in was taken for this device's own word")
        #expect(page.scopes == [Self.reading + " read:notifications"], "the page carried a word only the package said the sign-in holds")
    }

    @Test("Where the source gives no account of the token — an error, no answer, no list of words — no page opens and nothing held changes", arguments: [0, 1, 2])
    func noAccountOfTheToken(_ how: Int) async throws {
        let (session, server, tokens) = try await shell()
        switch how {
        case 0: await server.answer(S.info, .body("{}", 404))
        case 1: await server.answer(S.info, .fails)
        default: await server.answer(S.info, .body(#"{"resource_owner_id":1}"#))
        }
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(await server.paths == [S.check, S.info])
        let token = try tokens.token(host: host)
        #expect(token?.accessToken == "held-1" && token?.scopes == Self.acting && token?.refused == nil)
        #expect(session.rowRefusal?.key == "part.ask.unconfirmed")
        #expect(await server.revoked.isEmpty)
    }

    // MARK: - What the page came to

    @Test("Refused on the source's page: no sign-in is made, and the refusal is written beside the one held — in place, never by a save — with what the page asked; it may be asked again, and a yes then clears it")
    func refusedOnThePage() async throws {
        let (session, server, tokens) = try await shell()
        let before = try kept(tokens)
        // A save deletes before it adds: with adding refused, anything but an update in place
        // would lose the sign-in here.
        tokens.refuse(.adding, times: 100)

        await press(session, through: PartPage(.refuse))

        let sent: [String] = await server.paths
        #expect(!sent.contains(S.trade), "a refusal was traded for a sign-in")
        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "held-1" && token.scopes == Self.acting && token.stamp == before[4])
        #expect(token.refused == "write:bookmarks")
        #expect(token.asked == Self.wider, "what a page asked is every word of it, beside what was asked before")
        #expect(session.mastodon.standing(.bookmarks, host: host) == .refused)
        #expect(session.mastodon.bookmarks(host: host) == .unasked)
        // Said with no press in it: the press is the place's own line.
        #expect(session.toast?.text == said("part.ask.refused.said"))
        #expect(await server.revoked.isEmpty)
        #expect(session.acts(on: await post(in: session)).asks(.bookmark))

        tokens.refuse(.adding, times: 0)
        await press(session, through: PartPage())
        #expect(try tokens.token(host: host)?.refused == nil)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .held)
    }

    @Test("A refusal the device cannot write down, a refusal that is not this page's own, and a page closed each leave the sign-in as it was and the part never asked", arguments: [0, 1, 2])
    func nothingIsWrittenThatWasNotSaid(_ how: Int) async throws {
        let (session, server, tokens) = try await shell()
        let page: PartPage
        switch how {
        case 0:
            // The one write before it — who the sign-in is — goes through; the note does not.
            tokens.refuse(.changing, times: 100, after: 1)
            page = PartPage(.refuse)
        case 1: page = PartPage(.refuseForged)
        default: page = PartPage(.close)
        }

        await press(session, through: page)

        #expect(page.opened == 1)
        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "held-1" && token.scopes == Self.acting)
        #expect(token.refused == nil && token.asked == Self.acting)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .unasked)
        #expect(session.isSignedIn(host: host))
        #expect(await server.revoked.isEmpty)
        // A page closed says nothing, as any sign-in's does.
        if how == 2 { #expect(session.toast == nil && session.rowRefusal == nil) }
    }

    @Test("A source that has none of the part opens no page: it is said once, the part is not offered again this run, and a second press sends nothing")
    func theSourceHasNone() async throws {
        let (session, server, tokens) = try await shell()
        let known = MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "write:bookmarks" }
        await server.lists(known)
        let before = try kept(tokens)
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(await server.registered.isEmpty, "a source whose own list has none of it was registered with")
        #expect(session.toast?.text == L10n.t("account.bookmarks.unavailable"))
        #expect(session.mastodon.bookmarks(host: host) == .unavailable)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .notGiven)
        // Said by the source itself, so written down as asked: a relaunch does not offer it.
        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == before[0] && token.scopes == before[1] && token.refused == nil)
        #expect(token.asked == Self.acting + " write:bookmarks")
        let asked = await server.paths.count
        #expect(!session.askBookmarks(host: host))
        await press(session, through: page)
        let after: Int = await server.paths.count
        #expect(after == asked)
        #expect(page.opened == 0)
    }

    @Test("A registration kept from before that cannot carry bookmarks is not paged for them: at a source that refuses to register for them no page opens, where a page that asked nothing new used to")
    func aRegistrationThatCannotCarryThePart() async throws {
        let (session, server, tokens) = try await shell()
        try tokens.save(MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: Self.acting))
        await server.answer(S.apps, .body(#"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#, 422))
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(await server.registered == [MastodonRegistration.superset(), Self.wider])
        #expect(session.mastodon.bookmarks(host: host) == .unavailable)
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        #expect(try tokens.app(host: host)?.scopes == Self.acting, "the registration that serves the sign-in held was dropped")
    }

    @Test("A source whose own list has dropped a word the sign-in holds is not paged for a sign-in that would come back without it: signing in again opens no page whose sign-in would only be thrown away")
    func aPageThatWouldLeaveLessIsNotOpened() async throws {
        let (session, server, tokens) = try await shell(holding: Self.wider)
        let known = MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "read:search" }
        await server.lists(known)
        let page = PartPage()

        await session.signIn(host: host, through: page, writing: true)

        #expect(page.opened == 0, "a page opened whose sign-in this device then refuses to keep")
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        #expect(await server.revoked.isEmpty)
        let registered: [String] = await server.registered
        #expect(!registered.contains(MastodonRegistration.superset(listed: Set(known))))
    }

    @Test("The page signed in another account, or one the source does not name: what came back is not kept and is ended, the sign-in held is untouched, and the place says which", arguments: [true, false])
    func anotherAccount(_ named: Bool) async throws {
        let (session, server, tokens) = try await shell()
        await server.name("new-1", as: named ? "2" : nil)
        let before = try kept(tokens)

        await press(session, through: PartPage())

        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "held-1" && token.scopes == before[1] && token.refused == nil)
        #expect(token.accountID == "1")
        #expect(await server.revoked == ["new-1"], "a sign-in nobody kept was left live, or the one held was ended")
        #expect(try tokens.left(host: host).isEmpty)
        let key = named ? "part.ask.another" : "part.ask.unnamed"
        #expect(session.rowRefusal?.key == key && session.toast?.text == said(key))
        #expect(session.mastodon.bookmarks(host: host) == .unasked)
    }

    @Test("The source answered with less than the sign-in held has: what came back is not kept and is ended, the sign-in held is untouched, and the place says so")
    func lessThanHeld() async throws {
        let (session, server, tokens) = try await shell()
        await server.grant(Self.reading + " write:bookmarks")

        await press(session, through: PartPage())

        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "held-1" && token.scopes == Self.acting)
        #expect(await server.revoked == ["new-1"])
        #expect(session.rowRefusal?.key == "part.ask.less" && session.toast?.text == said("part.ask.less"))
    }

    @Test("A source whose page ends twice with nothing sent back, on a registration nothing confirmed, is not asked again this run — said once, and every later press sends nothing")
    func stranded() async throws {
        let (session, server, tokens) = try await shell()
        await server.echoesNothing()

        await press(session, through: PartPage(.close))
        #expect(session.toast == nil, "a page closed once was said to be more")
        await press(session, through: PartPage(.close))

        #expect(session.rowRefusal?.key == "part.ask.stranded" && session.toast?.text == said("part.ask.stranded"))
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        let asked = await server.paths.count
        let page = PartPage()
        await press(session, through: page)
        #expect(page.opened == 0)
        #expect(await server.paths.count == asked)
        #expect(await server.revoked.isEmpty)
    }

    @Test("A sign-in holding a word this build does not use is told first that asking gives it up and ends the sign-in this device had: the page leaves the word out, and the old sign-in is ended, not left")
    func aWordGivenUp() async throws {
        let (session, server, tokens) = try await shell(holding: Self.acting + " push")
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.givesUp == ["push"])
        let told = String(format: L10n.t("part.ask.givesUp", language: .english), "push", host)
        let help = try #require(ShellQuestion.part(ask, language: .english).help)
        #expect(help.contains(told) && !help.contains("stays live"), "the sign-in before was said to stay live where asking ends it")
        #expect(told == "This sign-in also has push, which this version of Fediqo does not use. Asking gives that up, and the sign-in this device had is ended at social.example.")

        // Never without its question: nobody was told.
        let silent = PartPage()
        #expect(await session.mastodon.ask([.bookmarks], host: host, through: silent) == .putDown)
        #expect(silent.opened == 0)

        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [Self.wider])
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(await server.revoked == ["held-1"])
        #expect(try tokens.left(host: host).isEmpty)
    }

    @Test("What a sign-in has been asked is every page's words, and a part refused stays refused when another is allowed")
    func askedIsAUnion() async throws {
        let (session, _, tokens) = try await shell(holding: Self.reading)

        #expect(await session.mastodon.ask([.notices], host: host, through: PartPage(.refuse)) == .refused)
        #expect(try tokens.token(host: host)?.asked == Self.reading + " read:notifications")
        #expect(await session.mastodon.ask([.acting], host: host, through: PartPage()) == .allowed)

        let token = try #require(try tokens.token(host: host))
        let acting = MastodonParts.page(held: Self.reading, ticked: [.acting])
        #expect(token.scopes == acting)
        #expect(token.asked == Self.reading + " read:notifications write:statuses write:favourites")
        #expect(token.refused == "read:notifications")
        #expect(session.mastodon.standing(.notices, host: host) == .refused)
    }

    // MARK: - One entry in one place

    /// No part can be added from a test — the table is an enum, closed on purpose. What is
    /// shown instead is that nothing on the way asks which part it is: every part the table
    /// has, those no place asks for today among them, goes the whole way by its entry alone.
    @Test("Every part of the table is asked in place by its entry alone: the page is the table's, the question and what is said are found by the part's name, and the file names no part but the one that keeps earlier words", arguments: MastodonPart.allCases)
    func aPartIsItsEntry(_ part: MastodonPart) async throws {
        let others = Set(MastodonPart.allCases).subtracting([part])
        // A sign-in is believed to be one only where it reads: without the words of reading,
        // it holds the source's one word for every read, as one made by something else may.
        let coarse = part == .reading ? " read" : ""
        let (session, _, tokens) = try await shell(holding: MastodonParts.page(held: nil, ticked: others) + coarse)
        #expect(session.mastodon.standing(part, host: host) == .unasked)
        #expect(session.partAsks.raise([part], host: host, in: session))
        let ask = try #require(session.partAsks.open)
        // Its sentences are written, in every table: a key nobody wrote is said as itself.
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        for what in ["title", "line", "detail"] {
            let key = "part.\(part.rawValue).ask.\(what)"
            for table in tables { #expect(table.contains("\n\"\(key)\" = \""), "\(key) is written in no table") }
            #expect(L10n.t(key, language: .english) != key)
            #expect(L10n.t(key, language: .taiwanese) != key)
        }
        if PartWords.earlier[part] == nil {
            let question = ShellQuestion.part(ask, language: .english)
            #expect(question.title == String(format: L10n.t("part.\(part.rawValue).ask.title", language: .english), host))
            #expect(question.line == L10n.t("part.\(part.rawValue).ask.line", language: .english))
            #expect(PartWords.said(.hasNone, of: [part]) == "part.ask.none")
            #expect(PartWords.said(.failed(.unreachable), of: [part]) == "part.ask.failed")
        }

        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        // Reading is what a page is built over, so a sign-in without its words is one no page
        // can widen: it is told to sign in again, and nothing is put in its place (#347).
        guard part != .reading else {
            #expect(page.opened == 0)
            #expect(session.toast?.text == "This sign-in at social.example cannot be added to where it stands. Sign out and sign in again, choosing what to allow.")
            #expect(try tokens.token(host: host)?.accessToken == "held-1")
            return
        }
        #expect(page.scopes == [ask.said], "the page asked for other than its question was drawn for")
        #expect(page.scopes == [MastodonParts.page(held: MastodonParts.page(held: nil, ticked: others), ticked: [part])])
        #expect(session.mastodon.standing(part, host: host) == .held)
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
    }

    /// One of the three string tables, as it is written.
    private static func table(_ language: String) throws -> String {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        return try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
    }

    @Test("A question about several parts words every one of them, and what is said of them is no one part's own sentence")
    func severalPartsAreEachWorded() async throws {
        let (session, _, _) = try await shell(holding: Self.reading)
        #expect(session.partAsks.raise([.notices, .acting], host: host, in: session))
        let ask = try #require(session.partAsks.open)
        let question = ShellQuestion.part(ask, language: .english)
        let help = try #require(question.help)
        #expect(question.title == "Ask social.example to allow more?")
        for part in ["acting", "notices"] {
            let line = L10n.t("part.\(part).ask.line", language: .english)
            let detail = String(format: L10n.t("part.\(part).ask.detail", language: .english), host)
            #expect(line != "part.\(part).ask.line")
            #expect(question.line.contains(line), "the question's line says nothing of \(part)")
            #expect(help.contains(detail), "the question's detail says nothing of \(part)")
        }
        #expect(PartWords.said(.hasNone, of: [.acting, .search]) == "part.ask.none")
        #expect(PartWords.said(.failed(.unreachable), of: [.acting, .search]) == "part.ask.failed")
        // Notices asked with the bookmarks their question was worded to name are notices' own.
        #expect(PartWords.said(.failed(.unreachable), of: [.bookmarks, .notices]) == "notices.ask.failed")
    }

    @Test("The file an ask is put and said in names one part, where it keeps the words bookmarks were asked in before")
    func theAskNamesNoPart() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/ShellPartAsk.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        // A part named as a value: `.bookmarks` standing by itself, not a function of that name.
        let cases = MastodonPart.allCases.map(\.rawValue).joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_\\)\\]`])\\.(\(cases))\\b")
        let found = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let named = found.map { String(text[Range($0.range(at: 1), in: text)!]) }
        #expect(named == ["bookmarks"])
    }

    // MARK: - While the ask is out

    /// Where an ask waits, and what happens there meanwhile.
    enum Step: String, CaseIterable, Sendable { case check, info, register, page, trade, newCheck }
    enum Meanwhile: String, CaseIterable, Sendable { case signOut, remove, replaced }

    @Test("Signed out, removed, or the sign-in replaced while an ask waits — at the check, the source's account of the token, the registration, the page, the trade or the new sign-in's check: nothing is put over what is then held, and what was made is ended",
          arguments: Step.allCases, Meanwhile.allCases)
    func whileItWaits(_ step: Step, _ meanwhile: Meanwhile) async throws {
        let (session, server, tokens) = try await shell()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the ask, held where it waits")
        defer { guardTask.cancel() }
        let page = PartPage(gate: step == .page ? gate : nil)
        let path: String? = switch step {
        case .check, .newCheck: S.check
        case .info: S.info
        case .register: S.apps
        case .trade: S.trade
        case .page: nil
        }
        // The check of the sign-in held goes through where it is the new one's that waits.
        if step == .newCheck {
            await server.holdCheck(of: "new-1", at: gate)
        } else if let path {
            await server.hold(path, at: gate)
        }
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.answer(ask, through: page, in: session)
        let asking = Task { await session.partAsks.landed(host: host) }
        await met("the ask is waiting at \(step.rawValue)", by: asking) {
            if let path { await server.waiting.contains(path) } else { page.opened == 1 }
        }

        // No second question, and no second page, while this one is out. Not waited for
        // here: an ask that did go out would wait where the first one waits.
        #expect(!session.askBookmarks(host: host))
        #expect(session.toast?.text == String(format: L10n.t("part.ask.asking"), host), "a press while the source is being asked did nothing and said nothing")
        let second = Task { await session.mastodon.ask([.bookmarks], host: self.host, through: page) }

        let other = MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reading)
        var leaving: Task<Void, Never>?
        switch meanwhile {
        case .signOut: leaving = Task { await session.signOut(host: host) }
        case .remove: leaving = Task { await session.mastodon.signOut(host: host, forgettingApp: true) }
        case .replaced: try tokens.save(other)
        }
        if let leaving {
            await met("the sign-in is off this device", by: leaving) { (try? tokens.token(host: self.host)) == .some(nil) }
        }
        await gate.open()
        await session.partAsks.landed(host: host)
        #expect(await second.value == .busy)
        await session.mastodon.leftSettled()

        let held = try tokens.token(host: host)?.accessToken
        #expect(held == (meanwhile == .replaced ? "other-1" : nil), "an ask put its sign-in over what the person had come to hold")
        #expect(page.opened <= 1)
        // A sign-in is made once the page has come back, and not before.
        let made = [Step.page, .trade, .newCheck].contains(step)
        let ended = await server.revoked
        if made {
            #expect(ended.contains("new-1"), "a sign-in nobody kept was left live")
        } else {
            #expect(page.opened == 0, "a page opened about a sign-in the person no longer held")
        }
        if meanwhile == .replaced { #expect(!ended.contains("other-1") && !ended.contains("held-1")) }
        #expect(session.rowRefusal == nil, "something was said of a sign-in that is no longer there")
    }

    @Test("The reader's name asked for again while the page is up writes beside the sign-in held and costs the person nothing: what they allow is kept")
    func aNoteWrittenWhileThePageIsUp() async throws {
        let (session, _, tokens) = try await shell()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the ask, held where it waits")
        defer { guardTask.cancel() }
        let page = PartPage(gate: gate)
        #expect(session.askBookmarks(host: host))
        session.partAsks.answer(try #require(session.partAsks.open), through: page, in: session)
        let asking = Task { await session.partAsks.landed(host: host) }
        await met("the source's page is up", by: asking) { page.opened == 1 }

        await session.mastodon.learnWho(host: host)
        await gate.open()
        await session.partAsks.landed(host: host)

        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(session.mastodon.bookmarks(host: host) == .allowed)
    }

    @Test("A question put down asks nothing; one raised over another takes its place; and a yes to a question about a sign-in since replaced opens no page")
    func questionsPutDown() async throws {
        let (session, server, tokens) = try await shell()
        #expect(session.askBookmarks(host: host))
        let first = try #require(session.partAsks.open)
        session.partAsks.putDown()
        #expect(session.partAsks.open == nil && session.bookmarkAsk == nil)
        #expect(await server.paths.isEmpty)

        #expect(session.partAsks.raise([.notices], host: host, in: session))
        #expect(session.partAsks.raise([.bookmarks], host: host, in: session))
        #expect(session.partAsks.open == first, "two questions stood open at once, or the later did not take the earlier's place")
        session.partAsks.putDown()

        // The same words under another string: another sign-in, which nobody asked about.
        try tokens.save(MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting))
        session.mastodon.refresh()
        let page = PartPage()
        await session.allow(first, through: page)
        #expect(page.opened == 0)
        #expect(await server.paths.isEmpty)
        #expect(try tokens.token(host: host)?.accessToken == "other-1")
    }

    @Test("A page asks no word its question did not name: where the sign-in has come to hold more since the question was drawn, so that the same tick would now ask a further word, no page opens")
    func noWordTheQuestionDidNotName() async throws {
        let (session, server, tokens) = try await shell(holding: Self.reading)
        #expect(session.partAsks.raise([.notices], host: host, in: session))
        let ask = try #require(session.partAsks.open)
        #expect(ask.said == Self.reading + " read:notifications")
        // The same sign-in, now one that acts: notices ticked would ask to dismiss them too.
        _ = try tokens.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        let page = PartPage()

        // Answered as its card answers it: put down, then handed over.
        session.partAsks.putDown()
        await session.allow(ask, through: page)

        #expect(page.opened == 0, "a page asked for a word the person was never told of")
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        #expect(await server.revoked.isEmpty)
        // Not a yes that came to nothing: the question again, naming the further word.
        let again = try #require(session.partAsks.open)
        #expect(again.said == Self.acting + " read:notifications write:notifications")
    }

    // MARK: - Whose the sign-in held is, where nothing written says

    /// A sign-in an earlier build filed, whose id this device cannot write beside it: who it
    /// is, is known for this run alone.
    private func unnamedShell() async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let (session, server, tokens) = try await shell(holding: nil)
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reading, asked: Self.reading
        ))
        session.mastodon.refresh()
        tokens.refuse(.changing, times: 100)
        return (session, server, tokens)
    }

    /// What this run learnt of the sign-in held is let go of, the sign-in itself staying: the
    /// first note this device can write beside it marks it, and the next look takes that for
    /// a sign-in nobody has asked about.
    private func forgetWho(_ session: ShellSession, _ tokens: MemoryMastodonTokens) throws {
        tokens.refuse(.changing, times: 0)
        _ = try tokens.update(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", asked: Self.reading
        ))
        session.mastodon.refresh()
    }

    @Test("Asked in place, the sign-in held is the account its ask confirmed: where its id was never written beside it and what this run learnt of it was let go of while the page was up, the wider sign-in still leaves it live and written down as left, and its reader is the one who was here")
    func theOwnerIsTheOneTheAskConfirmed() async throws {
        let (session, server, tokens) = try await unnamedShell()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the ask, held where it waits")
        defer { guardTask.cancel() }
        let page = PartPage(gate: gate)
        let asking = Task { await session.mastodon.ask([.notices], host: self.host, through: page) }
        await met("the ask has reached its page", by: asking) { page.opened == 1 }
        #expect(try tokens.token(host: host)?.accountID == nil)
        try forgetWho(session, tokens)
        _ = session.mastodon.takeReadersChanged()

        await gate.open()
        #expect(await asking.value == .allowed)
        await session.mastodon.leftSettled()

        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        let ended: [String] = await server.revoked
        #expect(ended.isEmpty, "the sign-in the person had was ended, nobody having been told")
        #expect(try tokens.left(host: host).map(\.state) == [.left])
        #expect(try tokens.left(host: host).map(\.accountID) == ["1"])
        #expect(session.mastodon.readersChangedWaiting.isEmpty, "the same reader was taken for another")
        #expect(session.mastodon.leftTold.isEmpty)
    }

    /// Everything an ask in place can come to once it has begun.
    enum InPlace: String, CaseIterable, Sendable {
        case allowed, notGiven, closed, refused, another, unnamed, less, tradeFails, checkFails, notKept, hasNone
    }

    @Test("Whatever an ask in place comes to, it ends no sign-in for want of knowing whose it is: with the id written nowhere and what this run learnt let go of while the page was up, the sign-in the person had is still held, or is left live and written down", arguments: InPlace.allCases)
    func noOutcomeEndsASignInNobodyCanName(_ outcome: InPlace) async throws {
        let (session, server, tokens) = try await unnamedShell()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the ask, held where it waits")
        defer { guardTask.cancel() }
        var answer = PartPage.Answer.allow
        switch outcome {
        case .closed: answer = .close
        case .refused: answer = .refuse
        case .another: await server.name("new-1", as: "2")
        case .unnamed: await server.name("new-1", as: nil)
        case .less: await server.grant("read:statuses read:lists read:notifications")
        case .notGiven: await server.grant(Self.reading)
        case .tradeFails: await server.answer(S.trade, .body("{}", 500))
        case .hasNone: await server.lists(MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "read:notifications" })
        case .allowed, .checkFails, .notKept: break
        }
        let page = PartPage(answer, gate: gate)
        var over = false
        let asking = Task {
            defer { over = true }
            return await session.mastodon.ask([.notices], host: self.host, through: page)
        }
        // No `by:`: the ask ending with no page up is one of the two things waited for.
        await met("the ask's page is up, or the ask has ended without one") { page.opened == 1 || over }
        let paged = page.opened == 1
        let pages = outcome != .hasNone
        #expect(paged == pages)
        if paged {
            try forgetWho(session, tokens)
            if outcome == .checkFails { await server.answer(S.check, .body("{}", 500)) }
            if outcome == .notKept { tokens.refuse(.changing, times: 100) }
        }

        await gate.open()
        let came = await asking.value
        await session.mastodon.leftSettled()

        let ended: [String] = await server.revoked
        #expect(!ended.contains("held-1"), "\(outcome.rawValue) ended the sign-in the person had, nobody having been told")
        let kept = [InPlace.allowed, .notGiven].contains(outcome)
        let widened = came == .allowed || came == .notGiven
        #expect(widened == kept, "\(outcome.rawValue) came to \(came)")
        let held = try tokens.token(host: host)?.accessToken
        let holds = kept ? "new-1" : "held-1"
        #expect(held == holds)
        let left: [MastodonLeft.State] = kept ? [.left] : []
        #expect(try tokens.left(host: host).map(\.state) == left)
        #expect(session.mastodon.leftTold.isEmpty)
    }

    // MARK: - What the question was drawn from, and what is held at its yes

    @Test("A sign-in from an earlier build, marked by this one's first note while its question stood open, is the sign-in the question was about: the question stands, and its one yes opens the page — nothing held differs, and nothing is asked twice")
    func anOlderSignInMarkedMeanwhile() async throws {
        let (session, _, tokens) = try await shell(holding: nil)
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.stamp == nil)
        await session.mastodon.learnWho(host: host)
        #expect(try tokens.token(host: host)?.stamp != nil)
        #expect(session.partAsks.open == ask, "a question was taken from under the person for a mark this device made itself")
        let page = PartPage()

        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [Self.wider], "a second yes was asked for where nothing held had changed")
        #expect(session.partAsks.open == nil)
    }

    @Test("A sign-in from an earlier build that this one has named — at launch, as every sign-in is — is asked by one question: the press reads the mark that note gave it, and its yes opens the page")
    func anOlderSignInNamedBeforeThePress() async throws {
        let (session, _, tokens) = try await shell(holding: nil)
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: host)
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.stamp != nil, "a question was drawn from what rode beside the sign-in before this device marked it")
        let page = PartPage()

        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.scopes == [Self.wider])
        #expect(session.partAsks.open == nil)
    }

    @Test("A question about a sign-in an earlier build filed is not one about another held since: its yes opens no page and puts no question, nobody having pressed about that one")
    func anOlderSignInReplacedMeanwhile() async throws {
        let (session, server, tokens) = try await shell(holding: nil)
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.stamp == nil)
        session.partAsks.putDown()
        try tokens.save(MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting))
        session.mastodon.refresh()
        let page = PartPage()

        await session.allow(ask, through: page)

        #expect(page.opened == 0, "a page opened about a sign-in the question was never about")
        #expect(session.partAsks.open == nil, "a question nobody pressed for was put")
        #expect(await server.paths.isEmpty)
        #expect(try tokens.token(host: host)?.accessToken == "other-1")
    }

    @Test("A question raised about a sign-in goes with it — signed out of, removed, or replaced: no sign-in filed at that source later brings it back, nobody having pressed", arguments: [0, 1, 2])
    func aQuestionGoesWithItsSignIn(_ how: Int) async throws {
        let (session, _, tokens) = try await shell(holding: nil)
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        #expect(session.askBookmarks(host: host))
        #expect(session.partAsks.open?.stamp == .some(nil))
        switch how {
        case 0: await session.signOut(host: host)
        case 1: await session.mastodon.signOut(host: host, forgettingApp: true)
        default:
            try tokens.save(MastodonToken(host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting))
            session.mastodon.refresh()
        }
        #expect(session.partAsks.open == nil, "a question stood open about a sign-in that is gone")
        // Another that an earlier build filed, as a store carried over from one holds it.
        try tokens.fileUnstamped(MastodonToken(
            host: host, accessToken: "other-2", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        #expect(session.partAsks.open == nil, "a question nobody pressed for came back with a later sign-in")
    }

    @Test("A question put again lands seconds after its yes, and takes the place of no question the person has opened since about another source: that one stands, nothing is said over it, and the place goes on offering its press")
    func aQuestionPutAgainTakesNoOthersPlace() async throws {
        let (session, server, tokens) = try await shell(holding: Self.acting + " read:notifications")
        let elsewhere = "other.example"
        try tokens.save(MastodonToken(
            host: elsewhere, accessToken: "there-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        // Filed as holding notices, which its source says it does not: its yes opens no page.
        await server.answer(S.info, .body(PartAskFixture.info(Self.acting)))
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the ask, held where it waits")
        defer { guardTask.cancel() }
        await server.hold(S.info, at: gate)
        #expect(session.askBookmarks(host: host))
        let first = try #require(session.partAsks.open)
        let page = PartPage()
        session.partAsks.answer(first, through: page, in: session)
        let asking = Task { await session.partAsks.landed(host: host) }
        await met("the ask has reached the source's account of the token", by: asking) {
            await server.waiting.contains(S.info)
        }
        #expect(session.askBookmarks(host: elsewhere))
        let other = try #require(session.partAsks.open)

        await gate.open()
        await session.partAsks.landed(host: host)

        #expect(page.opened == 0)
        #expect(session.partAsks.open == other, "a question the person had open was replaced under their hand")
        #expect(session.toast == nil)
        #expect(session.rowRefusal == nil)
        session.partAsks.putDown()
        #expect(session.askBookmarks(host: host), "the place stopped offering to ask again")
        #expect(session.partAsks.open?.host == host)
    }

    @Test("A word this build does not use, which only the source's own account of the sign-in shows, is not given up on a question that never said so: the question is put again, saying it")
    func aWordGivenUpFoundAtTheYes() async throws {
        let (session, server, tokens) = try await shell(asked: Self.acting + " push")
        await server.answer(S.info, .body(PartAskFixture.info(Self.acting + " push")))
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.givesUp.isEmpty)
        let page = PartPage()

        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)

        #expect(page.opened == 0)
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        let again = try #require(session.partAsks.open)
        #expect(again.givesUp == ["push"])
        session.partAsks.answer(again, through: page, in: session)
        await session.partAsks.landed(host: host)
        #expect(page.scopes == [Self.wider])
        #expect(await server.revoked == ["held-1"])
    }

    /// The words of each part, written out: what a page is held against, and never read off
    /// the table the page is built from.
    private static let written: [MastodonPart: Set<String>] = [
        .reading: ["read:statuses", "read:lists", "read:accounts"],
        .search: ["read:search"],
        .acting: ["write:statuses", "write:favourites"],
        .bookmarks: ["write:bookmarks"],
        .notices: ["read:notifications"],
        .follows: ["read:follows", "write:follows"],
        .account: ["write:accounts"],
        .media: ["write:media"],
    ]

    private static func split(_ scopes: String) -> Set<String> {
        Set(scopes.split(separator: " ").map(String.init))
    }

    /// Every word a question drawn from `held` with `tick` pressed names: the held ones this
    /// build knows, the part's own, and dismissing where the tick brings notices and acting
    /// together.
    private static func wordsNamed(held: String, tick: MastodonPart) -> Set<String> {
        let known = written.values.reduce(into: Set(["write:notifications"])) { $0.formUnion($1) }
        var named = split(held).intersection(known).union(written[tick] ?? [])
        let both = named.isSuperset(of: ["write:statuses", "write:favourites", "read:notifications"])
        if both, tick == .notices || tick == .acting { named.insert("write:notifications") }
        return named
    }

    /// Whether a question's words say its page asks to dismiss notices — and not that it does
    /// not, which the question of a sign-in that only reads says in as many words.
    private static func saysDismissing(_ question: ShellConfirmation) -> Bool {
        let text = question.line + " " + (question.help ?? "")
        return text.contains("to dismiss") && !text.contains("not asked to dismiss")
    }

    @Test("No page carries a word its question, as drawn, did not name — whatever the sign-in is filed as holding and whatever its source then says it holds; where the two differ no page opens on that question, and the one put again is held to the same. And an act a page brings in beside acting is said by its question in words, whichever part was pressed", arguments: MastodonPart.allCases)
    func thePageIsItsQuestions(_ tick: MastodonPart) async throws {
        let reads = "read:statuses read:lists read:accounts"
        let finds = reads + " read:search"
        let acts = finds + " write:statuses write:favourites"
        let notified = " read:notifications"
        let follows = " read:follows write:follows"
        let all = acts + " write:bookmarks read:notifications write:notifications"
        // What is filed as held, what is filed as asked, and what the source says is held —
        // never a word outside what was asked, which is believed of no source.
        let states: [(filed: String, asked: String, source: String)] = [
            (reads, reads, reads), (finds, finds, finds), (acts, acts, acts),
            (reads + notified, reads + notified, reads + notified),
            (finds + notified, finds + notified, finds + notified),
            (acts + notified, acts + notified, acts + notified),
            (acts + " write:bookmarks", acts + " write:bookmarks", acts + " write:bookmarks"),
            (all, all, all),
            // Follows, beside a sign-in that only reads and one that does everything: whole,
            // and held in part.
            (finds + follows, finds + follows, finds + follows),
            (reads + " read:follows", reads + " read:follows", reads + " read:follows"),
            (all + follows, all + follows, all + follows),
            (acts + notified + " write:follows", acts + notified + " write:follows", acts + notified + " write:follows"),
            // Filed without follows, which its source says it holds; and the other way.
            (finds, finds + follows, finds + follows),
            (acts + follows, acts + follows, acts),
            // A word this build does not use.
            (acts + " push", acts + " push", acts + " push"),
            // Filed as holding less than its source says.
            (acts, acts + notified, acts + notified),
            (reads, all, all),
            (acts, acts + " push", acts + " push"),
            // Filed as holding more than its source says.
            (acts + notified, acts + notified, acts),
            (all, all, acts),
            (acts, acts, reads),
            (acts + " push", acts + " push", acts),
        ]
        for state in states {
            let (session, server, _) = try await shell(holding: state.filed, asked: state.asked)
            await server.answer(S.info, .body(PartAskFixture.info(state.source)))
            let page = PartPage()
            guard session.partAsks.raise([tick], host: host, in: session) else { continue }
            // A yes to the question put, and to the one put again in its place.
            var drawn = state.filed
            for _ in 0..<2 {
                guard page.opened == 0, let ask = session.partAsks.open else { break }
                let named = Self.wordsNamed(held: drawn, tick: tick)
                #expect(Self.split(ask.said) == named, "a question was drawn for other than what is held and ticked")
                // Dismissing, where this page is what adds it: said in the question's words.
                let had: Bool = Self.split(drawn).contains("write:notifications")
                let brings: Bool = named.contains("write:notifications") && !had
                let question = ShellQuestion.part(ask, language: .english)
                if brings {
                    #expect(Self.saysDismissing(question), "ticking \(tick.rawValue) over \(drawn): the page asks to dismiss notices and its question does not say so")
                } else {
                    let text = question.line + " " + (question.help ?? "")
                    #expect(!text.contains("also asks to dismiss"), "a question said its page asks to dismiss notices, and it does not")
                }
                session.partAsks.answer(ask, through: page, in: session)
                await session.partAsks.landed(host: host)
                let paged = Self.split(page.scopes.joined(separator: " "))
                #expect(paged.isSubset(of: named), "a page carried a word its question did not name")
                drawn = state.source
            }
            #expect(page.opened <= 1)
            let same = state.filed == state.source
            if same { #expect(page.opened == 1, "a question drawn from what is held opened no page") }
        }
    }

    // MARK: - What the source says that is not believed

    @Test("An account of the token that is no believable one — an empty list, one without the words every sign-in reads by, a body past what a list may bring, or one that leaves nothing of what was asked — opens no page and is written nowhere: the sign-in is filed as it was", arguments: [0, 1, 2, 3])
    func anAccountNotBelieved(_ how: Int) async throws {
        let (session, server, tokens) = try await shell(asked: how == 3 ? "read:search" : nil)
        switch how {
        case 0: await server.answer(S.info, .body(#"{"scope":[]}"#))
        case 1: await server.answer(S.info, .body(#"{"scope":["write:statuses","write:favourites","read:search"]}"#))
        case 2:
            let listed = Self.acting.split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
            let padding = String(repeating: "x", count: 64 << 10)
            await server.answer(S.info, .body("{\"scope\":[\(listed)],\"pad\":\"\(padding)\"}"))
        default: break
        }
        let before = try kept(tokens)
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(await server.paths == [S.check, S.info])
        #expect(try kept(tokens) == before, "what a source said that is no account of a sign-in was written over it")
        #expect(session.rowRefusal?.key == "part.ask.unconfirmed")
        #expect(session.mastodon.bookmarks(host: host) == .unasked, "it may be asked again later")
    }

    @Test("A believable account of a token is a list of words that reads, word for word: such a list is written over what was filed even where it is shorter — and a sign-in holding only the source's one word for every read is put no page, which could carry no reading")
    func anAccountBelieved() async throws {
        let (session, server, tokens) = try await shell()
        await server.answer(S.info, .body(PartAskFixture.info(Self.reading)))
        let page = PartPage()
        await press(session, through: page)
        #expect(page.opened == 0)
        #expect(try tokens.token(host: host)?.scopes == Self.reading)

        let (coarse, _, _) = try await shell(holding: "read write")
        #expect(coarse.partAsks.raise([.notices], host: host, in: coarse))
        let ask = try #require(coarse.partAsks.open)
        #expect(ask.givesUp == ["read", "write"])
        let wide = PartPage()
        await coarse.allow(ask, through: wide)
        #expect(wide.opened == 0, "a page of \(wide.scopes) took the place of a sign-in that reads")
    }

    // MARK: - What is said of an answer

    @Test("Allowed on the page, and the source gave everything the sign-in had but not the part: the sign-in that came back is kept, and it is said that the source has none to allow — as the bookmark's own ask said it — with nothing noted of the host for the run")
    func keptWithoutThePart() async throws {
        let (session, server, tokens) = try await shell()
        await server.grant(Self.acting)

        await press(session, through: PartPage())

        let token = try #require(try tokens.token(host: host))
        #expect(token.accessToken == "new-1")
        #expect(token.scopes == Self.acting)
        #expect(session.toast?.text == L10n.t("account.bookmarks.unavailable"))
        #expect(session.rowRefusal == nil)
        #expect(session.mastodon.bookmarks(host: host) == .unavailable)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .notGiven)
        // This answer's fact and not the host's: another sign-in there is asked as any is.
        try tokens.save(MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.acting
        ))
        session.mastodon.refresh()
        #expect(session.mastodon.standing(.bookmarks, host: host) == .unasked)

        // A part with no sentence of its own from before: the table's.
        let (other, source, held) = try await shell(holding: Self.reading)
        await source.grant(Self.reading)
        let answer = await other.mastodon.ask([.notices], host: host, through: PartPage())
        #expect(answer != .allowed)
        // Notices have a line of their own for it, on their page.
        #expect(PartWords.said(answer, of: [.notices]) == "notices.source.refused")
        #expect(PartWords.said(answer, of: [.acting]) == "part.ask.none")
        #expect(try held.token(host: host)?.accessToken == "new-1")
    }

    @Test("A source whose own list lacks a word the sign-in holds cannot be asked in place — and is not said to have none of the part pressed for, which stays offered")
    func theSourceLacksAWordHeld() async throws {
        let (session, server, tokens) = try await shell()
        let known = MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "read:search" }
        await server.lists(known)
        let before = try kept(tokens)
        let page = PartPage()

        await press(session, through: page)

        #expect(page.opened == 0)
        #expect(session.toast?.text == L10n.t("account.bookmarks.failed"))
        #expect(session.mastodon.bookmarks(host: host) == .unasked)
        #expect(session.mastodon.standing(.bookmarks, host: host) == .unasked)
        #expect(try kept(tokens) == before)
    }

    @Test("A page that comes back saying something went wrong at the source is not the person's no: nothing is written beside the sign-in, and it is said as a failure", arguments: ["server_error", "temporarily_unavailable"])
    func aPageThatWentWrong(_ error: String) async throws {
        let (session, server, tokens) = try await shell()
        let before = try kept(tokens)

        await press(session, through: PartPage(.fault(error)))

        #expect(try kept(tokens) == before, "a failure at the source was written down as the person's refusal")
        #expect(session.mastodon.standing(.bookmarks, host: host) == .unasked)
        #expect(session.toast?.text == L10n.t("account.bookmarks.failed"))
        #expect(await server.revoked.isEmpty)
    }

    @Test("The words a question says are given up are a few, each cut short, and then a count: what a source chose to call its words does not fill the question")
    func manyWordsGivenUp() async throws {
        let long = String(repeating: "x", count: 64)
        let (session, _, _) = try await shell(holding: Self.acting + " push follow \(long) admin:read crypto")
        #expect(session.askBookmarks(host: host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.givesUp.count == 5)
        let help = try #require(ShellQuestion.part(ask, language: .english).help)
        let shown = "push, follow, " + String(repeating: "x", count: 24) + "… and 2 more"
        #expect(help.contains("This sign-in also has \(shown), which"))
        #expect(!help.contains("crypto"))

        let plain = try #require(ShellQuestion.bookmarks(host: host, language: .english).inPlace(at: host, language: .english).help)
        let most = (100..<228).map { String(long.dropLast(3)) + String($0) }
        let full = PartAsk(host: host, ticked: [.bookmarks], said: Self.wider, givesUp: most, stamp: nil)
        let longest = try #require(ShellQuestion.part(full, language: .english).help)
        #expect(longest.count < plain.count + 320)
        #expect(longest.contains("and 125 more"))
    }

    // MARK: - What a place draws

    @Test("A sign-in that only reads, one with bookmarks, and no sign-in are put no bookmark question, and a forum source is not asked anything of the kind")
    func whoIsNotAsked() async throws {
        for scopes in [nil, Self.reading, Self.wider] as [String?] {
            let (session, server, _) = try await shell(holding: scopes)
            #expect(!session.askBookmarks(host: host))
            #expect(!session.askBookmarks(host: forum))
            #expect(!session.partAsks.raise(Set(MastodonPart.allCases), host: forum, in: session))
            #expect(session.mastodon.standing(.bookmarks, host: forum) == nil)
            #expect(session.partAsks.open == nil)
            #expect(session.rows.first { $0.source.host == forum }?.owed == .nothing)
            #expect(await server.paths.isEmpty)
        }
    }

    // MARK: - The words

    @Test("Every sentence an ask says is written in English and in Traditional Chinese with the same arguments, the table's own words to the letter, and the third table is the second byte for byte")
    func theWords() throws {
        let english = [
            "part.ask.refused": "This was refused on %@'s page. Ask again",
            "part.ask.none": "%@ has none to allow.",
            "part.ask.another": "%@ signed in a different account. Nothing was changed. To use that account, sign out of this one first.",
            "part.ask.less": "%@ answered with less than this sign-in already has. Nothing was changed; ask again later.",
            "part.ask.unconfirmed": "Fediqo could not confirm whose sign-in this is at %@, so it was not asked. Try again later, or sign out and sign in again, choosing what to allow.",
            "part.ask.givesUp": "This sign-in also has %1$@, which this version of Fediqo does not use. Asking gives that up, and the sign-in this device had is ended at %2$@.",
            "part.ask.stranded": "%@ could not be asked for this in this run.",
            "part.ask.failed": "%@ could not be asked for this just now. The sign-in you have goes on as it is.",
            "part.ask.refused.said": "This was refused on %@'s page.",
            "part.ask.unnamed": "%@'s page was allowed, but Fediqo could not confirm whose account it signed in, so nothing was changed. Try again later, or sign out and sign in again, choosing what to allow.",
            "part.ask.givesUp.more": "%1$@ and %2$d more",
        ]
        let chinese = [
            "part.ask.refused": "這一項在 %@ 的頁面上被拒絕了。再問一次",
            "part.ask.none": "%@ 沒有這一項可以允許。",
            "part.ask.another": "%@ 登入的是另一個帳號。什麼都沒有改變。要用那個帳號，請先登出這一個。",
            "part.ask.less": "%@ 回覆的比這個登入原有的還少。什麼都沒有改變，請稍後再問。",
            "part.ask.unconfirmed": "Fediqo 無法確認這是 %@ 上哪個帳號的登入，所以沒有詢問。請稍後再試，或登出後重新登入，並選擇要允許的項目。",
            "part.ask.givesUp": "這個登入還有 %1$@，這個版本的 Fediqo 用不到。詢問之後會放棄它，這台裝置原本的登入也會在 %2$@ 那邊結束。",
            "part.ask.stranded": "這次執行期間無法向 %@ 詢問這一項。",
            "part.ask.failed": "現在無法向 %@ 詢問這一項。你原有的登入照舊。",
            "part.ask.refused.said": "這一項在 %@ 的頁面上被拒絕了。",
            "part.ask.unnamed": "%@ 的頁面已經允許了，但 Fediqo 無法確認登入的是哪個帳號，所以什麼都沒有改變。請稍後再試，或登出後重新登入，並選擇要允許的項目。",
            "part.ask.givesUp.more": "%1$@ 等，另外還有 %2$d 項",
        ]
        func specifiers(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%(\\d\\$)?[@d]")
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (key, words) in english {
            #expect(L10n.t(key, language: .english) == words)
            #expect(L10n.t(key, language: .taiwanese) == chinese[key])
            #expect(specifiers(words) == specifiers(chinese[key] ?? ""), "\(key) takes other arguments in Chinese")
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let taiwan = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
    }
}
