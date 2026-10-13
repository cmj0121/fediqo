import FediqoPersistence
import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon as a sign-in and its ending meet it: a registration, a token a trade, the account
/// check, and the ask to end one — each answered as the test says, per token. It remembers what
/// the device held and had journalled at the moment each request was sent.
private actor LeftSource: HTTPSender {
    enum Ending: Sendable { case ends, offline, busy, refuses }

    struct Sent: Sendable {
        let path: String
        /// The token the request was about: the one it carried, or the one it asked to end.
        let token: String?
        let held: Bool
        let left: [MastodonLeft.State]
    }

    static let check = "/api/v1/accounts/verify_credentials"
    static let revoke = "/oauth/revoke"
    static let info = "/oauth/token/info"
    /// What a Mastodon answers the account check through a token it has ended, with a 401
    /// (`MastodonSignInCaptures.afterRevoke`).
    static let ended = #"{"error":"The access token was revoked"}"#

    private let tokens: MemoryMastodonTokens
    private let host: String
    private var endings: [String: Ending] = [:]
    private var everyEnding = Ending.ends
    private var accounts: [String: String] = [:]
    private var checks: [String: (status: Int, body: String)] = [:]
    private var words: [String: String?] = [:]
    private var next: [(string: String, dated: Bool)] = []
    private var issued = 0
    private var gated: (path: String, gate: Gate)?
    private(set) var holding = false
    private(set) var sent: [Sent] = []

    init(tokens: MemoryMastodonTokens, host: String) {
        self.tokens = tokens
        self.host = host
    }

    /// Which tokens this source was asked to end, in the order it was asked.
    var revoked: [String] { sent.filter { $0.path == Self.revoke }.compactMap(\.token) }
    var paths: [String] { sent.map(\.path) }

    func answer(_ ending: Ending, for token: String? = nil) {
        if let token { endings[token] = ending } else {
            everyEnding = ending
            endings = [:]
        }
    }

    /// Names the account `token` signs in; every other is account `1`.
    func name(_ token: String, account: String) { accounts[token] = account }

    /// Answers the account check through `token` with `status` and `body`: a 401 in the
    /// source's own words is a sign-in ended. Nothing answers it as any sign-in's.
    func check(_ token: String, answers status: Int?, saying body: String = LeftSource.ended) {
        checks[token] = status.map { ($0, body) }
    }

    /// Says `token` holds `scopes`, asked for its own account of it — or gives no answer,
    /// where nothing. Not told, it says what the device has filed beside the token.
    func words(of token: String, are scopes: String?) { words[token] = .some(scopes) }

    /// The next trade hands out `string` in place of a new one — dated as made long before
    /// its own answer, where `dated`.
    func handBack(_ string: String, dated: Bool = false) { next.append((string, dated)) }

    /// Holds the first request to `path` until `gate` opens.
    func hold(_ path: String, at gate: Gate) { gated = (path, gate) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        func field(_ name: String) -> String? {
            form.split(separator: "&").first { $0.hasPrefix(name + "=") }
                .map { String($0.dropFirst(name.count + 1)).removingPercentEncoding ?? "" }
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        let about = url.path == Self.revoke ? field("token") : bearer
        sent.append(Sent(
            path: url.path, token: about, held: ((try? tokens.token(host: host)) ?? nil) != nil,
            left: ((try? tokens.left(host: host)) ?? []).map(\.state)
        ))
        if let gated, gated.path == url.path {
            self.gated = nil
            holding = true
            await gated.gate.wait()
            holding = false
        }
        func answered(_ body: String, _ status: Int = 200, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        switch url.path {
        case "/api/v1/apps":
            let named = (field("scopes") ?? "").split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
            return answered(#"{"client_id":"cid","client_secret":"csecret","redirect_uri":"fediqo://oauth","scopes":[\#(named)]}"#)
        case "/oauth/token":
            if !next.isEmpty {
                let handed = next.removeFirst()
                guard handed.dated else { return answered(#"{"access_token":"\#(handed.string)"}"#) }
                return answered(
                    #"{"access_token":"\#(handed.string)","created_at":1791609000}"#, 200,
                    ["Date": "Sat, 10 Oct 2026 05:10:35 GMT"]
                )
            }
            issued += 1
            return answered(#"{"access_token":"tok-\#(issued)"}"#)
        case Self.check:
            let token = bearer ?? ""
            if let check = checks[token] {
                if check.status == 0 { throw URLError(.notConnectedToInternet) }
                return answered(check.body, check.status)
            }
            return answered(#"{"id":"\#(accounts[token] ?? "1")","acct":"reader"}"#)
        case Self.info:
            let token = bearer ?? ""
            if let said = words[token] {
                guard let said else { throw URLError(.notConnectedToInternet) }
                return answered(PartAskFixture.info(said))
            }
            return answered(PartAskFixture.info(((try? tokens.token(host: host)) ?? nil)?.scopes))
        case Self.revoke:
            switch endings[about ?? ""] ?? everyEnding {
            case .ends: return answered("{}")
            case .offline: throw URLError(.notConnectedToInternet)
            case .busy: return answered("{}", 503)
            case .refuses:
                return answered(#"{"error":"unauthorized_client","error_description":"You are not authorized to revoke this token"}"#, 403)
            }
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The source's own page: approves, after waiting at a gate where it has one.
@MainActor
private final class LeftPage: OAuthBrowser {
    private let gate: Gate?
    private(set) var opened = 0

    init(gate: Gate? = nil) { self.gate = gate }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened += 1
        await gate?.wait()
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

/// A clock that moves on a whole pause at every look, so no host is ever left alone when a
/// test comes to the front twice — and one a test turns by hand, where `step` is nothing.
private final class LeftClock: PacerClock, @unchecked Sendable {
    var at: TimeInterval
    private let step: TimeInterval

    init(step: TimeInterval = 60, at: TimeInterval = 0) {
        self.step = step
        self.at = at
    }

    func elapsed() -> TimeInterval {
        at += step
        return at
    }
    func sleep(until moment: TimeInterval) async throws {}
    func wall() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}

/// A Keychain over a memory one that can be locked — nothing of it read — and that can lose
/// what it holds at a keeping it refuses, as a delete followed by an add that fails does.
private final class LeftKeychain: MastodonTokenStore, @unchecked Sendable {
    let held: MemoryMastodonTokens
    var locked = false
    /// Who is signed in cannot be read, though everything else can.
    var blind = false
    /// How many keepings are refused with what was held gone.
    var losing = 0
    private static let refused = ForumCredentialError.keychain(-25_308)

    init(_ held: MemoryMastodonTokens) { self.held = held }

    private func open() throws { if locked { throw Self.refused } }

    func token(host: String) throws -> MastodonToken? { try open(); return try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try open(); try held.save(token) }
    func forget(host: String) throws { try open(); try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try open(); return try held.forget(token) }
    func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? {
        try open()
        return try held.forget(token, saidBySource: saidBySource)
    }
    func grants() throws -> [String: MastodonGrant] {
        try open()
        if blind { throw Self.refused }
        return try held.grants()
    }
    func parts() throws -> [String: MastodonHeld] { try open(); return try held.parts() }
    func update(_ token: MastodonToken) throws -> Bool { try open(); return try held.update(token) }
    func swap(expecting string: String?, with token: MastodonToken) throws -> Bool {
        try open()
        guard losing > 0 else { return try held.swap(expecting: string, with: token) }
        losing -= 1
        try held.forget(host: token.host)
        throw Self.refused
    }
    func left(host: String) throws -> [MastodonLeft] { try open(); return try held.left(host: host) }
    func leftHosts() throws -> Set<String> { try open(); return try held.leftHosts() }
    func journal(_ entry: MastodonLeft) throws { try open(); try held.journal(entry) }
    func journalLost(_ token: MastodonToken, accountID: String?) throws {
        try open()
        try held.journalLost(token, accountID: accountID)
    }
    func unjournal(_ entry: MastodonLeft) throws { try open(); try held.unjournal(entry) }
    func forgetLeft(host: String) throws { try open(); try held.forgetLeft(host: host) }
    func restoreLost(host: String) throws -> Bool {
        try open()
        guard losing == 0 else { throw Self.refused }
        return try held.restoreLost(host: host)
    }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// #347, Decision 9: a sign-in a wider one took the place of is left live at its source and
/// written down, and everything this device holds or left there ends when the person signs out.
@MainActor
@Suite("What this device left at a source")
struct MastodonLeftTests {
    private let host = "social.example"
    private static let acting = MastodonOAuth.scopes(writing: true)

    private typealias Made = (sessions: MastodonSessions, source: LeftSource, tokens: MemoryMastodonTokens)

    private func fresh(_ tokens: MemoryMastodonTokens = MemoryMastodonTokens(), through store: (any MastodonTokenStore)? = nil) -> Made {
        let source = LeftSource(tokens: tokens, host: host)
        let sessions = MastodonSessions(tokens: store ?? tokens, sender: source)
        sessions.clock = LeftClock()
        return (sessions, source, tokens)
    }

    /// The same Keychain and the same source after a quit: nothing in memory comes with it.
    private func relaunched(_ before: Made) -> MastodonSessions {
        let sessions = MastodonSessions(tokens: before.tokens, sender: before.source)
        sessions.clock = LeftClock()
        return sessions
    }

    /// Signed in to read as `tok-1`, then to read and act as `tok-2`: the first is left.
    private func widened() async throws -> Made {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(try held(made) == "tok-2")
        return made
    }

    /// `tok-1` left, `tok-2` owed an end the source did not give, `tok-3` held to read.
    private func owing() async throws -> Made {
        let made = try await widened()
        await made.source.answer(.offline, for: "tok-2")
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(try states(made) == [.left, .owed])
        return made
    }

    private func held(_ made: Made) throws -> String? { try made.tokens.token(host: host)?.accessToken }
    private func states(_ made: Made) throws -> [MastodonLeft.State] { try made.tokens.left(host: host).map(\.state) }

    private func token(_ string: String, scopes: String? = MastodonOAuth.reading, id: String? = "1") -> MastodonToken {
        let token = MastodonToken(host: host, accessToken: string, clientID: "cid", clientSecret: "csecret", scopes: scopes, asked: scopes)
        return id.map { token.named(accountID: $0, handle: "@reader@\(host)") } ?? token
    }

    private func unconfirmed(_ host: String) -> MastodonSessions.LeftTold { .init(kind: .unconfirmed, host: host) }

    // MARK: - §4's table: the token a wider one replaces

    @Test("A sign-in replaced by a wider one of the same account is left live and written down, with what it held and whose it was; nothing is asked of the source to end it")
    func widening() async throws {
        let made = try await widened()
        #expect(await made.source.revoked.isEmpty, "the sign-in another device may carry was ended")
        let left = try made.tokens.left(host: host)
        #expect(left.map(\.state) == [.left])
        #expect(left.first?.words == MastodonOAuth.reading)
        #expect(left.first?.accountID == "1")
        #expect(left.first?.isToken(token("tok-1")) == true)
        #expect(made.sessions.grants[host] == .writing)
        #expect(made.sessions.owed.isEmpty)
        #expect(made.sessions.leftTold.isEmpty)
    }

    @Test("The token a sign-in made is written down as pending before its check, and written as left before the wider one is kept — and neither note outlives the keeping")
    func notedBeforeEachStep() async throws {
        let made = try await widened()
        // The first check through each token is the sign-in's own; who the reader is, is asked after.
        let checks = await made.source.sent.filter { $0.path == LeftSource.check }.prefix(2)
        #expect(checks.map(\.token) == ["tok-1", "tok-2"])
        #expect(checks.map(\.left) == [[.pending], [.pending]], "a token was checked with no note to end it by")
        #expect(checks.map(\.held) == [false, true])
        #expect(try states(made) == [.left])
    }

    @Test("What the replaced sign-in was refused goes with the one that takes its place")
    func refusalsAreCarried() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        let narrow = try #require(try made.tokens.token(host: host))
        #expect(try made.tokens.update(narrow.recorded(refused: "read:follows write:follows")))
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(try made.tokens.token(host: host)?.refused == "read:follows write:follows")
    }

    @Test("Narrowing ends the wider sign-in at once, and every one left that may do what the new one may not; one left that may do no more stays left")
    func narrowing() async throws {
        let made = try await widened()
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(try states(made) == [.left, .left])
        #expect(try held(made) == "tok-3")
        #expect(await made.source.revoked.isEmpty)

        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(try held(made) == "tok-4")
        #expect(await made.source.revoked == ["tok-3", "tok-2"], "a sign-in that may act is still live after reading alone was chosen")
        let left = try made.tokens.left(host: host)
        #expect(left.map(\.state) == [.left])
        #expect(left.first?.isToken(token("tok-1")) == true)
    }

    @Test("Narrowing to words a left sign-in holds is handed that very sign-in: it is held again and no longer left, and the wider one is ended")
    func narrowingOntoALeftOne() async throws {
        let made = try await widened()
        await made.source.handBack("tok-1", dated: true)
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(try held(made) == "tok-1")
        #expect(try states(made).isEmpty, "the sign-in held is also written down as left")
        #expect(await made.source.revoked == ["tok-2"])
    }

    @Test("An ordinary sign-in that comes back as another account is kept, and the one it replaces is ended with everything left for it")
    func anotherAccount() async throws {
        let made = try await widened()
        await made.source.name("tok-3", account: "2")
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(try held(made) == "tok-3")
        #expect(await made.source.revoked == ["tok-2", "tok-1"])
        #expect(try states(made).isEmpty)
    }

    @Test("A sign-in asked for more where it stands that comes back as another account is not kept: it is ended, and the one held and what was left for it stand")
    func anotherAccountInPlace() async throws {
        let made = try await widened()
        await made.source.name("tok-3", account: "2")
        let answer = await made.sessions.ask([.notices], host: host, through: LeftPage())
        #expect(answer == .another)
        #expect(try held(made) == "tok-2")
        #expect(try states(made) == [.left])
        #expect(await made.source.revoked == ["tok-3"])
    }

    @Test("A sign-in whose account nobody has named is not shown to be the same one's: the token it replaces is ended, as before")
    func anAccountNobodyNamed() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old", id: nil))
        made.sessions.refresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(await made.source.revoked == ["tok-old"])
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold.isEmpty, "told after a question that had said it first")
    }

    @Test("Asked for more where it stands, a sign-in nobody could show to be the same account's is not asked at all: no page opens, nothing is ended, and there is nothing to tell")
    func anUnknownAccountIsNotAskedInPlace() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old", id: nil))
        made.sessions.refresh()
        await made.source.check("tok-old", answers: 200, saying: "{}")
        let page = LeftPage()
        #expect(await made.sessions.ask([.notices], host: host, through: page) == .unconfirmed)
        #expect(try held(made) == "tok-old")
        #expect(await made.source.revoked.isEmpty)
        #expect(made.sessions.leftTold.isEmpty)

        // One shown to be the same account's is left, and nothing is told.
        let same = try await widened()
        #expect(await same.sessions.ask([.notices], host: host, through: LeftPage()) == .allowed)
        #expect(await same.source.revoked.isEmpty)
        #expect(same.sessions.leftTold.isEmpty)
    }

    @Test("Beyond sixteen left, the oldest is ended once the new sign-in is kept")
    func theBackstop() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-held"))
        for number in 0..<MastodonSessions.mostLeft {
            try made.tokens.journal(MastodonLeft(token("left-\(number)"), as: .left))
        }
        made.sessions.refresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(await made.source.revoked == ["left-0"])
        let left = try made.tokens.left(host: host)
        #expect(left.count == MastodonSessions.mostLeft)
        #expect(left.last?.isToken(token("tok-held")) == true)
    }

    // MARK: - §4's table: a token made and not kept

    @Test("A fresh token that fails its check is ended and its note taken out; the sign-in held and what was left for it stand", arguments: [500, 401, 0])
    func theCheckFails(status: Int) async throws {
        let made = try await widened()
        await made.source.check("tok-3", answers: status)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) != nil)
        #expect(await made.source.revoked == ["tok-3"])
        #expect(try held(made) == "tok-2")
        #expect(try states(made) == [.left])
    }

    @Test("A token handed back that is one left, failing its check, is not ended: another device may be carrying it")
    func aLeftOneHandedBack() async throws {
        let made = try await widened()
        await made.source.handBack("tok-1")
        await made.source.check("tok-1", answers: 500)
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) != nil)
        #expect(await made.source.revoked.isEmpty)
        #expect(try held(made) == "tok-2")
        #expect(try states(made) == [.left])
    }

    @Test("A token handed back that is one a read back took out — still to be put back, or replaced — failing its check, is not ended: it is somebody's working sign-in, and may be this device's own again", arguments: [MastodonLeft.State.replacing, .replaced])
    func aReplacedOneHandedBack(_ state: MastodonLeft.State) async throws {
        let made = try await widened()
        try made.tokens.journal(MastodonLeft(token("tok-old"), as: state))
        await made.source.handBack("tok-old")
        await made.source.check("tok-old", answers: 500)
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) != nil)
        #expect(await made.source.revoked.isEmpty)
        #expect(try held(made) == "tok-2")
        #expect(try states(made) == [.left, state])
    }

    @Test("A token shown to have been made before this sign-in is somebody's: not kept, it is neither noted nor ended")
    func shownNotFresh() async throws {
        let made = try await widened()
        await made.source.handBack("tok-elsewhere", dated: true)
        await made.source.check("tok-elsewhere", answers: 500)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) != nil)
        #expect(await made.source.revoked.isEmpty)
        let noted = await made.source.sent.last { $0.path == LeftSource.check }?.left
        #expect(noted == [.left], "a token made elsewhere was written down as this sign-in's to end")
        #expect(try states(made) == [.left])
    }

    @Test("A token shown to have been made before this sign-in that comes back as another account, asked in place: not kept, and not ended — it is that account's working sign-in")
    func anotherAccountsHandedBack() async throws {
        let made = try await widened()
        await made.source.handBack("tok-theirs", dated: true)
        await made.source.name("tok-theirs", account: "2")
        let answer = await made.sessions.ask([.notices], host: host, through: LeftPage())
        #expect(answer == .another)
        #expect(await made.source.revoked.isEmpty)
        #expect(try held(made) == "tok-2")
        #expect(try states(made) == [.left])
    }

    @Test("Signed out while the source's page is up: the token that comes back is ended, and nothing is left on the device")
    func signedOutMeanwhile() async throws {
        let made = try await widened()
        let gate = Gate()
        let page = LeftPage(gate: gate)
        let pressing = Task { await made.sessions.signIn(host: host, through: page, writing: true) }
        defer { Task { await gate.open() } }
        #expect(await spun { page.opened == 1 })
        await made.sessions.signOut(host: host)
        await gate.open()
        #expect(await pressing.value == nil)
        #expect(await made.source.revoked == ["tok-2", "tok-1", "tok-3"])
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
    }

    @Test("A Keychain that will not keep the fresh token: it is ended, the sign-in held is still held, and is not written down as left")
    func theKeychainRefusesTheFreshOne() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        made.tokens.refuse(.changing)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == .keychain)
        #expect(try held(made) == "tok-1")
        #expect(try states(made).isEmpty, "a sign-in still held was left written down as left")
        #expect(await made.source.revoked == ["tok-2"])
        #expect(made.sessions.isSignedIn(host: host))
    }

    // MARK: - The three outcomes

    @Test("The note of a fresh token cannot be taken: it is not checked and not kept, and is ended from memory")
    func theNoteOfAFreshOneFails() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        made.tokens.refuse(.leaving)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == .keychain)
        #expect(await made.source.paths.filter { $0 == LeftSource.check }.count == 1, "a token nobody could note was checked")
        #expect(try held(made) == "tok-1")
        #expect(try states(made).isEmpty)
        #expect(await made.source.revoked == ["tok-2"])
    }

    @Test("The note of the replaced token cannot be taken, and nothing else fails: the fresh one is not kept and is ended, and the one held stands")
    func theNoteOfTheReplacedOneFails() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        // The note of the fresh token is taken; the one after it, of the token it replaces, is not.
        made.tokens.refuse(.leaving, after: 1)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == .keychain)
        #expect(try held(made) == "tok-1")
        #expect(made.sessions.grants[host] == .reading)
        #expect(await made.source.revoked == ["tok-2"])
        #expect(try states(made).isEmpty)
    }

    @Test("A note that cannot be taken loses none taken before it: the earlier sign-in left stays written down, and only the fresh token is ended")
    func aFailedNoteKeepsEarlierOnes() async throws {
        let made = try await widened()
        // The note of the fresh token is taken; the one after it, of the token it replaces, is not.
        made.tokens.refuse(.leaving, after: 1)
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == .keychain)
        #expect(try held(made) == "tok-2")
        #expect(await made.source.revoked == ["tok-3"])
        let left = try made.tokens.left(host: host)
        #expect(left.map(\.state) == [.left], "a write that failed took the journal with it")
        #expect(left.first?.isToken(token("tok-1")) == true)
    }

    @Test("A sign-in filed again at the front is still whose it was: the next wider sign-in of that account leaves it live, and ends nothing")
    func aRestoredOneIsWidened() async throws {
        let made = fresh()
        try made.tokens.journalLost(token("tok-mine"), accountID: nil)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(try held(made) == "tok-mine")

        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(await made.source.revoked.isEmpty, "the sign-in filed again was ended by the next wider one")
        let left = try made.tokens.left(host: host)
        #expect(left.map(\.state) == [.left])
        #expect(left.first?.isToken(token("tok-mine")) == true)
        #expect(left.first?.accountID == "1")
    }

    @Test("The sign-in the person held, lost in a keeping that failed and not put back: written down as lost, never ended, said under its row — and filed again as held at the next launch")
    func lostAndFiledAgain() async throws {
        let tokens = MemoryMastodonTokens()
        let keychain = LeftKeychain(tokens)
        let made = fresh(tokens, through: keychain)
        try tokens.save(token("tok-mine"))
        made.sessions.refresh()
        keychain.losing = 2

        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == .keychain)
        #expect(try held(made) == nil)
        #expect(try states(made) == [.lost])
        #expect(await made.source.revoked == ["tok-1"], "the sign-in the person held was ended for not being kept")
        #expect(made.sessions.lost == [host])
        #expect(!made.sessions.isSignedIn(host: host))
        #expect(made.sessions.leftLine(host: host, language: .english) == "This device could not keep the sign-in for \(host).")

        // The Keychain still refuses at the next launch: it stays lost, and is not ended.
        keychain.losing = 1
        let stuck = MastodonSessions(tokens: keychain, sender: made.source)
        await stuck.verifyAll()
        #expect(try states(made) == [.lost])
        #expect(await made.source.revoked == ["tok-1"])

        keychain.losing = 0
        let next = MastodonSessions(tokens: keychain, sender: made.source)
        await next.verifyAll()
        #expect(try held(made) == "tok-mine")
        #expect(try states(made).isEmpty)
        #expect(next.isSignedIn(host: host))
        #expect(next.lost.isEmpty)
        #expect(await made.source.revoked == ["tok-1"], "a sign-in filed again was ended")
        let checked = await made.source.sent.last { $0.path == LeftSource.check }?.token
        #expect(checked == "tok-mine", "the sign-in filed again was not checked with the rest")
    }

    @Test("A sign-in written down as lost is ended when the person signs out, clears or removes — and by nothing before")
    func lostEndsAtSignOut() async throws {
        let made = fresh()
        try made.tokens.journalLost(token("tok-mine"), accountID: nil)
        made.tokens.refuse(.adding, times: 9)
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.isEmpty)
        #expect((try states(made)) == [.lost])

        await made.sessions.signOut(host: host, forgettingApp: true)
        #expect(await made.source.revoked == ["tok-mine"])
        #expect(try states(made).isEmpty)
        #expect(try made.sessions.lost.isEmpty)
    }

    @Test("A journal with no sign-in whose one retry fails is dropped from the device and told, and nothing asks again after a quit")
    func aJournalWithNoSignIn() async throws {
        let made = fresh()
        try made.tokens.journal(MastodonLeft(token("tok-left"), as: .left))
        try made.tokens.journal(MastodonLeft(token("tok-owed"), as: .owed))
        await made.source.answer(.offline)

        await made.sessions.verifyAll()
        #expect(await made.source.revoked == ["tok-left", "tok-owed"])
        #expect(try states(made).isEmpty, "something waits on a device that shows no sign-in")
        #expect(made.sessions.leftTold == [unconfirmed(host)])

        let next = relaunched(made)
        await next.verifyAll()
        next.cameToFront()
        await next.leftSettled()
        #expect(await made.source.revoked.count == 2, "an end was owed across a quit")
        #expect(next.leftTold.isEmpty)
    }

    // MARK: - The launch, and coming to the front

    @Test("At launch and at the front an owed end is asked again, and one the source gives leaves the journal", arguments: [true, false])
    func owedIsAskedAgain(atLaunch: Bool) async throws {
        let made = try await owing()
        #expect(made.sessions.owed == [host: 1])
        #expect(made.sessions.leftLine(host: host, language: .english) == "1 earlier sign-in at \(host) could not be ended yet.")
        #expect(made.sessions.leftLine(host: host, language: .taiwanese) == "\(host) 上還有 1 個先前的登入尚未能結束。")
        #expect(made.sessions.leftTold.isEmpty, "an end owed while signed in was told as a sign-out")

        // Still unanswered: it stays owed, here and across a quit.
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(try states(made) == [.left, .owed])

        await made.source.answer(.ends)
        let sessions = atLaunch ? relaunched(made) : made.sessions
        if atLaunch { await sessions.verifyAll() } else {
            sessions.cameToFront()
            await sessions.leftSettled()
        }
        #expect(await made.source.revoked == ["tok-2", "tok-2", "tok-2"])
        #expect(try states(made) == [.left])
        #expect(try held(made) == "tok-3")
        #expect(sessions.owed.isEmpty)
        #expect(sessions.leftLine(host: host) == nil)
    }

    @Test("A source that refuses for good to end an owed sign-in: the note is dropped, and the person is told what to do")
    func refusedForGood() async throws {
        let made = try await owing()
        await made.source.answer(.refuses, for: "tok-2")
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(try states(made) == [.left])
        #expect(made.sessions.leftTold == [.init(kind: .refused, host: host)])
        #expect(made.sessions.owed.isEmpty)
        let line = ShellQuestion.left(.init(kind: .refused, host: host), language: .english).line
        #expect(line.contains("remove every Fediqo entry from \(host)'s list of authorised apps"))

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked == ["tok-2", "tok-2"], "a source that refused for good was asked again")
    }

    @Test("A device that cannot read what it holds ends nothing, restores nothing and drops nothing; once it can, what was left is gone through")
    func aLockedDevice() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.journal(MastodonLeft(token("tok-pending"), as: .pending))
        try tokens.journalLost(token("tok-lost"), accountID: nil)
        let keychain = LeftKeychain(tokens)
        keychain.locked = true
        let made = fresh(tokens, through: keychain)

        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.sent.isEmpty)
        #expect(try states(made) == [.pending, .lost])
        #expect(try held(made) == nil)

        keychain.locked = false
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(try held(made) == "tok-lost", "the sign-in the person held was not filed again")
        #expect(await made.source.revoked == ["tok-pending"])
        #expect(try states(made).isEmpty)
    }

    /// #344 beside #347: a launch may be made while what the device holds is closed. The
    /// sign-in held is then not read, and that is not its going — what leaving the app lets go
    /// of from the store for a reader who changed (`readersChangedWaiting`) stays empty.
    @Test("A launch behind a lock with a sign-in held and others left: nobody is taken for signed out, no reader is said to have changed, nothing is asked of the source or dropped — and at the unlock the sign-in is the one held, as it was")
    func aLockedLaunchHoldsItsSignIn() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token("tok-held"))
        try tokens.journal(MastodonLeft(token("tok-left"), as: .left, accountID: "1"))
        try tokens.journal(MastodonLeft(token("tok-owed"), as: .owed))
        let keychain = LeftKeychain(tokens)
        keychain.locked = true
        let made = fresh(tokens, through: keychain)

        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.sent.isEmpty)
        #expect(made.sessions.ended.isEmpty)
        #expect(made.sessions.leftTold.isEmpty)
        #expect(made.sessions.readersChangedWaiting.isEmpty, "a sign-in not read is not a reader gone")
        #expect(try held(made) == "tok-held")
        #expect(try states(made) == [.left, .owed])

        keychain.locked = false
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(made.sessions.isSignedIn(host: host))
        #expect(made.sessions.ended.isEmpty)
        #expect(made.sessions.readersChangedWaiting.isEmpty)
        #expect(try held(made) == "tok-held")
        #expect(await made.source.revoked == ["tok-owed"], "only what was owed an end is asked for one")
        #expect(try states(made) == [.left])
    }

    @Test("Where who is signed in cannot be read, nothing left is ended or dropped, though the journal itself can be read")
    func whoIsSignedInUnread() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.journal(MastodonLeft(token("tok-pending"), as: .pending))
        try tokens.journal(MastodonLeft(token("tok-owed"), as: .owed))
        let keychain = LeftKeychain(tokens)
        keychain.blind = true
        let made = fresh(tokens, through: keychain)
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.sent.isEmpty)
        #expect(try states(made) == [.pending, .owed])
        #expect(made.sessions.leftTold.isEmpty)
    }

    @Test("A token made and never kept, found at launch, is ended — unless it is the sign-in held, which only leaves the journal")
    func pendingAtLaunch() async throws {
        let quit = fresh()
        try quit.tokens.save(token("tok-held"))
        try quit.tokens.journal(MastodonLeft(token("tok-pending"), as: .pending))
        await relaunched(quit).verifyAll()
        #expect(await quit.source.revoked == ["tok-pending"])
        #expect(try states(quit).isEmpty)
        #expect(try held(quit) == "tok-held")

        let kept = fresh()
        try kept.tokens.journal(MastodonLeft(token("tok-held"), as: .pending))
        try kept.tokens.save(token("tok-held"))
        // Written after the save, as a note that could not be taken out would stand.
        try kept.tokens.journal(MastodonLeft(token("tok-held"), as: .pending))
        await relaunched(kept).verifyAll()
        #expect(await kept.source.revoked.isEmpty, "the sign-in held was ended as one never kept")
        #expect(try states(kept).isEmpty)
    }

    @Test("Sign-ins left by another account than the one now held are ended, and said; ones nobody can say whose they were are kept")
    func anotherAccountsChain() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-held", id: "2"))
        try made.tokens.journal(MastodonLeft(token("tok-theirs", id: "1"), as: .left))
        try made.tokens.journal(MastodonLeft(token("tok-mine", id: "2"), as: .left))
        try made.tokens.journal(MastodonLeft(token("tok-unsaid", id: nil), as: .left))
        await made.source.name("tok-held", account: "2")
        let sessions = relaunched(made)
        await sessions.verifyAll()
        #expect(await made.source.revoked == ["tok-theirs"])
        #expect(try states(made) == [.left, .left])
        #expect(sessions.leftTold == [.init(kind: .others, host: host)])
    }

    // MARK: - A sign-in ended from elsewhere

    @Test("A sign-in its source ended: what was left for it is ended at once, the notice says other devices are signed out too, and no left sign-in is fallen back on")
    func endedFromElsewhere() async throws {
        let made = try await widened()
        await made.source.check("tok-2", answers: 401)
        await made.sessions.learnWho(host: host)
        await made.sessions.leftSettled()

        #expect(made.sessions.ended == [host])
        #expect(made.sessions.endedLeft == [host])
        #expect(!made.sessions.isSignedIn(host: host))
        #expect(made.sessions.authorized(host: host, for: .timeline) == nil)
        #expect(await made.source.revoked == ["tok-1"])
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold.isEmpty)

        let notice = ShellQuestion.signedOut(hosts: made.sessions.ended, left: made.sessions.endedLeft, language: .english)
        let said = [notice.line, notice.help ?? ""].joined(separator: " ")
        #expect(said.contains("Other devices carrying an earlier form of the sign-in at \(host) are signed out too."))
        let plain = ShellQuestion.signedOut(hosts: [host], left: [], language: .english)
        #expect(plain == ShellQuestion.signedOut(hosts: [host], language: .english), "said of a sign-in that had left nothing")
        made.sessions.endedSeen()
        #expect(made.sessions.endedLeft.isEmpty)
    }

    @Test("A 401 that is not the source's own answer — a page, nothing, a password asked for by something in front of it — still takes the sign-in held, as before, and ends nothing this device left: no other device is signed out, then or once it lifts, and the person is told", arguments: [
        "<html><body><h1>401 Authorization Required</h1></body></html>", "", "HTTP Basic: Access denied.\n",
    ])
    func aBare401EndsNothing(body: String) async throws {
        let made = try await widened()
        await made.source.check("tok-2", answers: 401, saying: body)
        await made.sessions.learnWho(host: host)
        await made.sessions.leftSettled()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()

        #expect(await made.source.revoked.isEmpty, "another device was signed out on the word of something in front of the source")
        #expect(made.sessions.ended == [host])
        #expect(!made.sessions.isSignedIn(host: host))
        #expect(made.sessions.endedLeft.isEmpty, "other devices were said to be signed out")
        #expect(try states(made).isEmpty, "something waits on a device that shows no sign-in")
        #expect(made.sessions.leftTold == [unconfirmed(host)])

        // Whatever stood in front of the source has lifted — here, and after a quit.
        await made.source.check("tok-2", answers: nil)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        let next = relaunched(made)
        await next.verifyAll()
        next.cameToFront()
        await next.leftSettled()
        #expect(await made.source.revoked.isEmpty)
    }

    @Test("A 401 that is not the source's own, and a going-through of what was left with nothing in between — a pass already running, or the next launch: nothing is ended, since the sign-in and what was left for it went in one step", arguments: [false, true])
    func aBare401ThenAPassAtOnce(relaunch: Bool) async throws {
        let made = try await widened()
        try made.tokens.journal(MastodonLeft(token("tok-owed"), as: .owed))
        let mine = try #require(try made.tokens.token(host: host))
        // As the door does it, off the main actor: no turn of the session's comes between.
        #expect(try made.tokens.forget(mine, saidBySource: false) == 1)

        let sessions = relaunch ? relaunched(made) : made.sessions
        if relaunch { await sessions.verifyAll() } else { await sessions.settleLeft() }
        #expect(await made.source.revoked == ["tok-owed"], "a sign-in left for another device was ended on a bare 401")
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
    }

    @Test("The source's own 401, and a quit before the session heard of it: the next launch ends what was left, as the source's word says")
    func theSourcesOwn401ThenAQuit() async throws {
        let made = try await widened()
        let mine = try #require(try made.tokens.token(host: host))
        #expect(try made.tokens.forget(mine, saidBySource: true) == 0)
        await relaunched(made).verifyAll()
        #expect(await made.source.revoked == ["tok-1"])
        #expect(try states(made).isEmpty)
    }

    @Test("Ended from elsewhere and the left ones not confirmed ended: they leave the device, and the person is told")
    func endedFromElsewhereUnreachable() async throws {
        let made = try await widened()
        await made.source.check("tok-2", answers: 401)
        await made.source.answer(.busy)
        await made.sessions.verifyAll()
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold == [unconfirmed(host)])
    }

    @Test("Ended from elsewhere, then a quit before what was left was ended: the next launch ends it")
    func endedThenAQuit() async throws {
        let made = fresh()
        try made.tokens.journal(MastodonLeft(token("tok-left"), as: .left))
        await relaunched(made).verifyAll()
        #expect(await made.source.revoked == ["tok-left"])
        #expect(try states(made).isEmpty)
    }

    // MARK: - Signing out

    @Test("Signing out: everything leaves the device before the source is asked anything, then the one held is ended and each one left, whatever the one before was answered")
    func signOutReachable() async throws {
        let made = try await widened()
        await made.sessions.signOut(host: host)
        let ends = await made.source.sent.filter { $0.path == LeftSource.revoke }
        #expect(ends.compactMap(\.token) == ["tok-2", "tok-1"], "the one held is not ended first")
        #expect(ends.allSatisfy { !$0.held && $0.left.isEmpty }, "something was still on the device when the source was asked")
        #expect(made.sessions.leftTold.isEmpty)
        #expect(!made.sessions.isSignedIn(host: host))
    }

    @Test("Signing out with the source unreachable, busy, or refusing: nothing is left on the device, the person is told once with the remedy, and nothing is stored to ask again", arguments: ["offline", "busy", "refuses"])
    func signOutUnconfirmed(how: String) async throws {
        let made = try await widened()
        let ending: LeftSource.Ending = how == "offline" ? .offline : how == "busy" ? .busy : .refuses
        await made.source.answer(ending)
        await made.sessions.signOut(host: host)

        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(try made.tokens.leftHosts().isEmpty)
        #expect(await made.source.revoked == ["tok-2", "tok-1"], "one end failing stopped the next")
        #expect(made.sessions.leftTold == [unconfirmed(host)])
        let told = ShellQuestion.left(unconfirmed(host), language: .english)
        #expect(told.line == "\(host) did not confirm the sign-out. This device has forgotten the sign-in; to be sure it is ended everywhere, remove every Fediqo entry from \(host)'s list of authorised apps.")
        #expect(told.choices.isEmpty)

        // A quit forgets what was not confirmed: nothing was stored to ask again by.
        let next = relaunched(made)
        await next.verifyAll()
        #expect(await made.source.revoked.count == 2)
    }

    @Test("Signing out where what was left cannot be read: it leaves the device all the same, the one held is ended, and the person is told that not everything was confirmed")
    func signOutWithTheJournalUnread() async throws {
        let made = try await widened()
        made.tokens.refuse(.readingLeft)
        await made.sessions.signOut(host: host)

        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(try made.tokens.leftHosts().isEmpty, "something is left on a device that shows no sign-in")
        #expect(await made.source.revoked == ["tok-2"])
        #expect(made.sessions.leftTold == [unconfirmed(host)], "sign-ins left live and off the device, and nothing said")
    }

    @Test("An end a sign-out could not confirm never comes back to the Keychain, whoever signs in there afterwards: it is asked again from memory, and nothing is written down as owed", arguments: ["1", "2"])
    func aSignedOutEndStaysOutOfTheKeychain(account: String) async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        await made.source.answer(.offline)
        await made.sessions.signOut(host: host)
        await made.source.name("tok-2", account: account)
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(try held(made) == "tok-2")

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked == ["tok-1", "tok-1"])
        #expect(try states(made).isEmpty, "a sign-in the person signed out of was written back")
        #expect(try made.tokens.leftHosts().isEmpty)
        #expect(made.sessions.owed.isEmpty)
        #expect(made.sessions.leftLine(host: host) == nil)

        // Still asked from memory, until the source says it is ended.
        await made.source.answer(.ends)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 3)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 3)
        #expect(try held(made) == "tok-2")
    }

    @Test("What a sign-out could not confirm is asked again from memory while the app runs — at the front, and when the source next answers a read — until the source says it is ended; one it refuses for good is not")
    func askedAgainFromMemory() async throws {
        let made = try await widened()
        await made.source.answer(.offline)
        await made.sessions.signOut(host: host)

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked == ["tok-2", "tok-1", "tok-2", "tok-1"])
        #expect(made.sessions.leftTold == [unconfirmed(host)], "told again of the same sign-out")

        await made.source.answer(.ends, for: "tok-2")
        await made.sessions.learnWhoAgain(among: ["other.example"], within: .seconds(5))
        #expect(await made.source.revoked.count == 4, "a read of another source asked this one")
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.revoked.suffix(2) == ["tok-2", "tok-1"])

        await made.source.answer(.refuses, for: "tok-1")
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.suffix(1) == ["tok-1"], "one already ended was asked again")
        #expect(await made.source.revoked.count == 7, "one already ended was asked again")
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 7, "one the source refused for good is still asked")
        #expect(try states(made).isEmpty, "something was stored after a sign-out")
    }

    @Test("Signing out with the source answering for one and not the other: both leave the device, the person is told, and only the unanswered one is asked again")
    func signOutHalfAnswered() async throws {
        let made = try await widened()
        await made.source.answer(.offline, for: "tok-1")
        await made.sessions.signOut(host: host)
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold == [unconfirmed(host)])

        await made.source.answer(.ends)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked == ["tok-2", "tok-1", "tok-1"])
    }

    @Test("A sign-in handed back as the very string a sign-out could not confirm is the person's again: it is not asked to be ended from memory")
    func theUnconfirmedOneHeldAgain() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        await made.source.answer(.offline)
        await made.sessions.signOut(host: host)
        await made.source.answer(.ends)
        await made.source.handBack("tok-1")
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.revoked == ["tok-1"], "the sign-in held was ended behind its row")
        #expect(try held(made) == "tok-1")
        #expect(try made.sessions.isSignedIn(host: host))

        // A wider sign-in then leaves it live — and it is left, not one to end from memory.
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(try states(made) == [.left])
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.revoked == ["tok-1"], "a sign-in left for another device was ended before the sign-out")
        #expect(try states(made) == [.left])
        #expect(made.sessions.leftTold == [unconfirmed(host)], "told again, of nothing")
    }

    // MARK: - Shown first: what lands while something else is on its way

    @Test("Signed out, or removed, while a fresh token's check is out: the sign-out ends what was held and left, the sign-in ends its own token once, and nothing is left on the device", arguments: [false, true])
    func signedOutDuringTheCheck(removing: Bool) async throws {
        let made = try await widened()
        let gate = Gate()
        await made.source.hold(LeftSource.check, at: gate)
        let pressing = Task { await made.sessions.signIn(host: host, through: LeftPage(), writing: true) }
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)
        #expect(try states(made) == [.left, .pending])

        await made.sessions.signOut(host: host, forgettingApp: removing)
        #expect(await made.source.revoked == ["tok-2", "tok-1"], "the sign-out ended a token another sign-in is still checking")
        await gate.open()
        #expect(await pressing.value == nil)

        #expect(await made.source.revoked == ["tok-2", "tok-1", "tok-3"])
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(try (made.tokens.app(host: host) == nil) == removing)
        #expect(made.sessions.leftTold.isEmpty)
    }

    @Test("The app coming to the front while a fresh token's check is out does not end that token: it is the sign-in's own, and is kept")
    func theFrontDuringTheCheck() async throws {
        let made = try await widened()
        let gate = Gate()
        await made.source.hold(LeftSource.check, at: gate)
        let pressing = Task { await made.sessions.signIn(host: host, through: LeftPage(), writing: true) }
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.isEmpty, "a token still being checked was ended under its own sign-in")
        #expect(try states(made) == [.left, .pending])
        await gate.open()
        #expect(await pressing.value == nil)
        #expect(try held(made) == "tok-3")
        #expect(try states(made) == [.left, .left])
        #expect(await made.source.revoked.isEmpty)
    }

    @Test("A launch and a coming to the front that land together go through what was left once")
    func theFrontTwice() async throws {
        let made = try await owing()
        let gate = Gate()
        await made.source.hold(LeftSource.revoke, at: gate)
        made.sessions.cameToFront()
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)

        // The second finds the first still at it, and asks nothing of its own.
        await made.sessions.settleLeft()
        #expect(await made.source.revoked.count == 2)
        await gate.open()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 2)
        #expect(try states(made) == [.left, .owed])
    }

    @Test("While one going-through runs, any number of comings to the front line up one more and no more")
    func oneRunsAndOneWaits() async throws {
        let made = try await owing()
        let gate = Gate()
        await made.source.hold(LeftSource.revoke, at: gate)
        made.sessions.cameToFront()
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)

        for _ in 0..<5 { made.sessions.cameToFront() }
        await gate.open()
        await made.sessions.leftSettled()
        // The one that made it owed, the one running, and the one that waited.
        #expect(await made.source.revoked.count == 3)
        #expect(try states(made) == [.left, .owed])
    }

    @Test("A host gone through is left alone for a while, however often the app comes to the front or the host answers a read: nothing is asked again inside the pause, and it is once the pause is over")
    func leftAloneForAWhile() async throws {
        let made = try await owing()
        let clock = LeftClock(step: 0, at: 1_000_000)
        made.sessions.clock = clock
        let pause = MastodonSessions.leftPause

        for _ in 0..<3 {
            made.sessions.cameToFront()
            await made.sessions.leftSettled()
        }
        #expect(await made.source.revoked.count == 2, "asked at every coming to the front")
        clock.at += pause - 1
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 2)
        clock.at += 1
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 3)
        // The launch goes through everything once, whatever was asked a moment before it.
        await made.sessions.verifyAll()
        #expect(await made.source.revoked.count == 4)

        // What is asked again from memory keeps the same pause, and so does a read answered.
        await made.sessions.signOut(host: host)
        #expect(await made.source.revoked.suffix(3) == ["tok-3", "tok-1", "tok-2"])
        for _ in 0..<3 {
            await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
            made.sessions.cameToFront()
            await made.sessions.leftSettled()
        }
        #expect(await made.source.revoked.count == 7, "asked from memory at every read answered")
        clock.at += pause
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.revoked.count == 8)
    }

    @Test("A host skipped because what it holds could not be read is not left alone for that: it is gone through at the next coming to the front")
    func aSkipIsNoGoingThrough() async throws {
        let made = try await owing()
        made.sessions.clock = LeftClock(step: 0, at: 1_000_000)
        // The look for a lost sign-in to file again, and the look at what is held.
        made.tokens.refuse(.reading, times: 2)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 1)

        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 2, "a host nothing was asked of was left alone for the pause")
    }

    @Test("No more than so many ends are asked again from memory: beyond that the oldest is let go of, and told as not confirmed")
    func noMoreThanSoManyFromMemory() async throws {
        let made = fresh()
        await made.source.answer(.offline)
        let each = MastodonSessions.mostLeft + 1
        var told: [[MastodonSessions.LeftTold]] = []
        for name in ["a.example", "b.example", "c.example"] {
            func signIn(_ string: String) -> MastodonToken {
                MastodonToken(host: name, accessToken: string, clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading)
            }
            try made.tokens.save(signIn("held-\(name)"))
            for number in 1..<each {
                try made.tokens.journal(MastodonLeft(signIn("left-\(number)-\(name)"), as: .left))
            }
            made.sessions.refresh()
            await made.sessions.signOut(host: name)
            told.append(made.sessions.leftTold)
            while !made.sessions.leftTold.isEmpty { made.sessions.leftToldSeen() }
        }
        #expect(await made.source.revoked.count == 3 * each)
        #expect(told == [[unconfirmed("a.example")], [unconfirmed("b.example")], [unconfirmed("a.example"), unconfirmed("c.example")]])

        await made.source.answer(.ends)
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        let again = await made.source.revoked.dropFirst(3 * each)
        #expect(again.count == MastodonSessions.mostUnended)
        #expect(again.allSatisfy { !$0.hasSuffix("a.example") }, "one let go of was asked about again")
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.count == 3 * each + MastodonSessions.mostUnended)
    }

    @Test("Signed out while an owed end is being asked again: the answer that comes back after it writes nothing down, and the person is told once")
    func signedOutWhileAnOwedEndIsOut() async throws {
        let made = try await owing()
        let gate = Gate()
        await made.source.hold(LeftSource.revoke, at: gate)
        made.sessions.cameToFront()
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)

        await made.sessions.signOut(host: host)
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        await gate.open()
        await made.sessions.leftSettled()

        #expect(try states(made).isEmpty, "an end answered after the sign-out was written down as owed")
        #expect(made.sessions.leftTold == [unconfirmed(host)])
        #expect(made.sessions.owed.isEmpty)
    }

    @Test("A sign-in kept while the token it replaced is being ended: the end's answer is settled against what is held then, and stays owed")
    func keptWhileAnEndIsOut() async throws {
        let made = try await widened()
        await made.source.answer(.busy, for: "tok-2")
        let gate = Gate()
        await made.source.hold(LeftSource.revoke, at: gate)
        // Narrowing: `tok-2` is asked to end, and that ask waits.
        let narrowing = Task { await made.sessions.signIn(host: host, through: LeftPage()) }
        defer { Task { await gate.open() } }
        // Not caught, the ask this waits for was never sent, and the next one would wait at the
        // gate with nobody left to open it: opened here, so the check fails and does not park.
        let caught = await spun { await made.source.holding }
        if !caught { await gate.open() }
        #expect(caught)
        #expect(try held(made) == "tok-3")
        await gate.open()
        #expect(await narrowing.value == nil)
        #expect(try states(made) == [.left, .owed])
        #expect(try made.sessions.owed == [host: 1])
    }

    // MARK: - What is said first, and where

    private func shell(_ made: Made) async -> ShellSession {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), mastodon: made.sessions)
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        return session
    }

    @Test("Before a sign-out, a Clear or a Remove of a signed-in Mastodon, the question says other devices carrying the sign-in are signed out too — and says nothing of it where no sign-in is held", arguments: [DummyLanguage.english, .taiwanese])
    func saidBeforeItEnds(language: DummyLanguage) async throws {
        let made = try await widened()
        let session = await shell(made)
        let sentence = language == .english
            ? "Any other device carrying this sign-in is signed out too." : "帶著這個登入的其他裝置也會一起登出。"
        func says(_ question: ShellConfirmation) -> Bool {
            question.line.contains(sentence) || question.help?.contains(sentence) == true
        }
        // **The language is handed in**, never set for the process: another suite draws off
        // that while this one waits.
        let plain = session.signOutQuestion(host: host, language: language)
        #expect(!says(plain))
        #expect(says(session.sayingOthersSignedOut(plain, host: host, language: language)))
        #expect(says(session.clearQuestion(host: host, language: language)))
        #expect(says(session.removeQuestion(host: host, postsStay: false, language: language)))
        session.askSignOut(host: host)
        let asked = try #require(session.signOutAsk)
        #expect(asked.question != session.signOutQuestion(host: host))

        await made.sessions.signOut(host: host)
        #expect(!says(session.clearQuestion(host: host, language: language)))
        #expect(!says(session.removeQuestion(host: host, postsStay: false, language: language)))
    }

    @Test("A Clear or a Remove where no sign-in is held, and one this device could not keep or ones it left are still there, ends those too: the question says other devices are signed out, until nothing is left to end")
    func saidWhereOnlyLostOrLeft() async throws {
        let sentence = "Any other device carrying this sign-in is signed out too."
        func says(_ question: ShellConfirmation) -> Bool {
            question.line.contains(sentence) || question.help?.contains(sentence) == true
        }

        let lost = fresh()
        try lost.tokens.journalLost(token("tok-mine"), accountID: nil)
        lost.tokens.refuse(.adding, times: 9)
        await lost.sessions.verifyAll()
        let unkept = await shell(lost)
        #expect(!lost.sessions.isSignedIn(host: host))
        #expect(says(unkept.clearQuestion(host: host, language: .english)))
        #expect(says(unkept.removeQuestion(host: host, postsStay: false, language: .english)))

        // Left there, and a Keychain that would not let go of them when the source gave no answer.
        let left = fresh()
        try left.tokens.journal(MastodonLeft(token("tok-a"), as: .left))
        try left.tokens.journal(MastodonLeft(token("tok-b"), as: .left))
        left.tokens.refuse(.leaving, times: 9)
        await left.source.answer(.offline)
        await left.sessions.verifyAll()
        let journalled = await shell(left)
        #expect(try states(left) == [.left, .left])
        #expect(!left.sessions.isSignedIn(host: host))
        #expect(says(journalled.clearQuestion(host: host, language: .english)))
        #expect(says(journalled.removeQuestion(host: host, postsStay: false, language: .english)))

        await left.sessions.signOut(host: host, forgettingApp: true)
        #expect(!says(journalled.clearQuestion(host: host, language: .english)))
        #expect(!says(journalled.removeQuestion(host: host, postsStay: false, language: .english)))
    }

    @Test("The read-or-act question says which answer ends the sign-in held, before the page opens: reading alone where it acts, either where what it holds or whose it is is not known, another account's alone where reading keeps everything, and nothing where none is held")
    func theReadOrActQuestionSaysWhatEnds() async throws {
        let made = fresh()
        let session = await shell(made)
        func says(_ key: String) -> Bool {
            let question = session.signInQuestion(host: host, language: .english)
            let sentence = String(format: L10n.t(key, language: .english), host)
            return question.line.contains(sentence) || question.help?.contains(sentence) == true
        }
        let keys = ["account.signin.ask.ends.read", "account.signin.ask.ends.either", "account.signin.ask.ends.another"]
        #expect(keys.filter(says).isEmpty)
        #expect(session.signInQuestion(host: host, language: .english) == ShellQuestion.signIn(host: host, language: .english))

        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)
        #expect(keys.filter(says) == ["account.signin.ask.ends.another"])
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: true) == nil)
        #expect(keys.filter(says) == ["account.signin.ask.ends.read"])

        // After a quit nobody has yet said whose the sign-in is, but it was written down with
        // it, which is what the keeping goes by; and one kept with nothing written down.
        let quit = fresh(made.tokens)
        let later = await shell(quit)
        #expect(quit.sessions.signInEnds(host: host, notices: false) == .reading)
        try quit.tokens.save(MastodonToken(host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret"))
        quit.sessions.refresh()
        await quit.sessions.learnWho(host: host)
        #expect(quit.sessions.signInEnds(host: host, notices: false) == .either)
        _ = later
    }

    @Test("Removing a source whose sign-out the source did not confirm: the row is gone, so it is told as a notice, which stands over the pages until it is seen")
    func removeTellsAsANotice() async throws {
        let made = try await widened()
        let session = await shell(made)
        await made.source.answer(.offline)
        await session.remove(host: host)

        #expect(session.rows.allSatisfy { $0.source.host != host })
        #expect(try held(made) == nil)
        #expect(try states(made).isEmpty)
        #expect(try made.tokens.app(host: host) == nil)
        #expect(session.mastodon.leftTold == [unconfirmed(host)])
        #expect(session.raisesOverPages)
        session.mastodon.leftToldSeen()
        #expect(session.mastodon.leftTold.isEmpty)
        #expect(!session.raisesOverPages)
    }

    @Test("Every word this adds is in each language, and 繁體中文 reads the same under both its names")
    func everyWordIsTranslated() throws {
        let keys = [
            "account.signout.ask.others", "account.signin.ask.ends.read", "account.signin.ask.ends.either",
            "account.signin.ask.ends.another", "account.mastodon.ended.left", "account.left.owed",
            "account.signout.unconfirmed.title", "account.signout.unconfirmed.line", "account.left.refused.title",
            "account.left.refused.line", "account.left.others.title", "account.left.others.line",
        ]
        for key in keys {
            let english = L10n.t(key, language: .english)
            let chinese = L10n.t(key, language: .taiwanese)
            #expect(english != key, "\(key)")
            #expect(chinese != key, "\(key)")
            #expect(english != chinese, "\(key)")
        }
        #expect(L10n.t("account.signout.ask.others", language: .english) == "Any other device carrying this sign-in is signed out too.")
        #expect(L10n.t("account.left.owed", language: .english) == "%1$d earlier sign-ins at %2$@ could not be ended yet.")
        #expect(L10n.t("account.left.owed", language: .taiwanese) == "%2$@ 上還有 %1$d 個先前的登入尚未能結束。")
        #expect(L10n.t("account.signout.unconfirmed.line", language: .taiwanese)
            == "%1$@ 沒有確認登出。這台裝置已經忘掉這個登入；要確定它在各處都已結束，請到 %1$@ 的已授權應用程式清單，移除每一個 Fediqo 項目。")

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let tables = root.appending(path: "Sources/FediqoUI/Resources")
        let taiwan = try Data(contentsOf: tables.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: tables.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
    }

    // MARK: - A sign-in a package read back replaced

    /// The Keychain as a read back leaves it (`StorePackager.refile`): `old` written down,
    /// forgotten, and — where the package brings a sign-in for the host — `tok-pkg` filed in
    /// its place as one a package brought, saying it is account `id`'s. `state` is how far
    /// the read back got: every step held, or still one a later step may undo.
    private func readBack(
        over old: MastodonToken, bringing scopes: String?, saying id: String? = nil, _ state: MastodonLeft.State = .replaced
    ) throws -> Made {
        let made = fresh()
        try made.tokens.save(old)
        made.sessions.refresh()
        try made.tokens.journal(MastodonLeft(old, as: state))
        #expect(try made.tokens.forget(old))
        if let scopes {
            try made.tokens.save(.carried(
                host: host, accessToken: "tok-pkg", clientID: "cid-pkg", clientSecret: "csecret-pkg", scopes: scopes,
                asked: scopes, refused: nil, accountID: id, handle: nil
            ))
        }
        return made
    }

    @Test("A read back that put a sign-in over another: the source is asked whose the package's is and what it holds, and the one replaced is ended — through the one place that ends — where the source says another account's, and said; where it says the same account's, it is left as an earlier form and nothing is ended. What the package says of whose it is decides nothing", arguments: [
        ["2", "2", "ended"], ["1", "2", "ended"], ["", "2", "ended"], ["2", "1", "left"], ["", "1", "left"], ["1", "1", "left"],
    ])
    func readBackOverAnother(_ row: [String]) async throws {
        let made = try readBack(over: token("tok-old"), bringing: MastodonOAuth.reading, saying: row[0].isEmpty ? nil : row[0])
        await made.source.name("tok-pkg", account: row[1])
        let ended = row[2] == "ended"

        made.sessions.readBack()
        await made.sessions.leftSettled()

        #expect(await made.source.revoked == (ended ? ["tok-old"] : []))
        #expect(await made.source.paths == [LeftSource.check, LeftSource.info] + (ended ? [LeftSource.revoke] : []), "the source was not asked first")
        #expect(try states(made) == (ended ? [] : [.left]))
        #expect(try held(made) == "tok-pkg")
        #expect(made.sessions.leftTold == (ended ? [.init(kind: .others, host: host)] : []))
        #expect(try made.tokens.token(host: host)?.accountID == row[1], "the source's word for whose it is was not written over the package's")
    }

    @Test("A read back that put a sign-in of the same account over one: the one replaced is ended where the source says the one now held may do less, and left as an earlier form where it may do everything that one could — by what the source says it holds, whatever the package said", arguments: [
        // What the replaced one held, what the package says its own holds, what the source says: ended?
        [true, false, false, true], [true, true, false, true], [true, false, true, false], [false, true, true, false], [false, false, false, false],
    ])
    func readBackNarrower(_ row: [Bool]) async throws {
        func words(_ acts: Bool) -> String { acts ? Self.acting : MastodonOAuth.reading }
        let made = try readBack(over: token("tok-old", scopes: words(row[0])), bringing: words(row[1]), saying: "1")
        await made.source.words(of: "tok-pkg", are: words(row[2]))
        let ended = row[3]

        made.sessions.readBack()
        await made.sessions.leftSettled()

        #expect(await made.source.revoked == (ended ? ["tok-old"] : []))
        #expect(try states(made) == (ended ? [] : [.left]))
        #expect(try held(made) == "tok-pkg")
        #expect(made.sessions.leftTold.isEmpty)

        await made.sessions.signOut(host: host)
        #expect(await made.source.revoked == (ended ? ["tok-old", "tok-pkg"] : ["tok-pkg", "tok-old"]))
        #expect(try made.tokens.leftHosts().isEmpty)
    }

    @Test("A package naming another account, or fewer words, with its source out of reach ends nothing: the sign-in replaced stays written down, through a launch and a coming to the front — and is ended, as another's or as one that may do more, once the source itself says so", arguments: [0, 1, 2])
    func readBackOnThePackagesWordEndsNothing(_ how: Int) async throws {
        // 0: names another id, the account check unanswered. 1: says fewer words, the account
        // check unanswered. 2: says fewer words, and no account of the token is given.
        let made = try readBack(
            over: token("tok-old", scopes: how == 0 ? MastodonOAuth.reading : Self.acting), bringing: MastodonOAuth.reading,
            saying: how == 0 ? "2" : "1"
        )
        if how == 2 { await made.source.words(of: "tok-pkg", are: nil) } else { await made.source.check("tok-pkg", answers: 0) }

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        let relaunched = relaunched(made)
        await relaunched.verifyAll()

        #expect(await made.source.revoked.isEmpty, "a sign-in was ended on a package's word")
        #expect(try states(made) == [.replaced])
        #expect(try held(made) == "tok-pkg")
        #expect(made.sessions.leftTold.isEmpty && relaunched.leftTold.isEmpty)

        // The source answers, and says what the package said.
        if how == 0 { await made.source.name("tok-pkg", account: "2") }
        await made.source.check("tok-pkg", answers: nil)
        await made.source.words(of: "tok-pkg", are: MastodonOAuth.reading)
        made.sessions.readBack()
        await made.sessions.leftSettled()

        #expect(await made.source.revoked == ["tok-old"])
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold == (how == 0 ? [.init(kind: .others, host: host)] : []))
    }

    @Test("A sign-in a read back may yet put back is ended by nothing: not a launch, not a coming to the front, not the adopting of a read back, not another sign-in of that account landing — only by the person signing out")
    func whatMayBePutBackIsNotEnded() async throws {
        let made = try readBack(over: token("tok-old", scopes: Self.acting), bringing: MastodonOAuth.reading, saying: "2", .replacing)
        await made.source.name("tok-pkg", account: "2")

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)

        #expect(await made.source.revoked.allSatisfy { $0 != "tok-old" })
        #expect(try made.tokens.left(host: host).contains { $0.state == .replacing && $0.isToken(token("tok-old")) })

        await made.sessions.signOut(host: host)
        #expect(await made.source.revoked.contains("tok-old"))
        #expect(try made.tokens.leftHosts().isEmpty)
    }

    @Test("A read back that brought no sign-in for a source this device was signed in to: the one taken out stays written down and nothing ends it — at the adopting, a launch or a coming to the front, as the person decided; clearing the source ends it, and its question says so")
    func readBackBroughtNone() async throws {
        #expect(!MastodonSessions.endsWhatAReadBackLeftBare, "the person decided it is left, and this says it is ended")
        let made = try readBack(over: token("tok-old"), bringing: nil)

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(await made.source.sent.isEmpty, "a source was asked about a sign-in a read back took out with none put in its place")
        #expect(try states(made) == [.replaced])
        #expect(!made.sessions.isSignedIn(host: host))
        #expect(made.sessions.endsSignIns(host: host), "the Clear's question would not say a sign-in is ended")

        await made.sessions.signOut(host: host, forgettingApp: true)
        #expect(await made.source.revoked == ["tok-old"])
        #expect(try made.tokens.leftHosts().isEmpty)
    }

    @Test("A read back asks only the sources it took a sign-in out at: one it left nothing at is asked nothing, though something else is owed an end there")
    func readBackLeftNothing() async throws {
        let made = fresh()
        try made.tokens.save(.carried(
            host: host, accessToken: "tok-pkg", clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading,
            asked: nil, refused: nil, accountID: "1", handle: nil
        ))
        let other = MastodonToken(host: "other.example", accessToken: "tok-other", clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading)
        try made.tokens.save(.carried(
            host: other.host, accessToken: "tok-there", clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading,
            asked: nil, refused: nil, accountID: "1", handle: nil
        ))
        try made.tokens.journal(MastodonLeft(other, as: .owed))

        made.sessions.readBack()
        await made.sessions.leftSettled()

        #expect(made.sessions.isSignedIn(host: host) && made.sessions.isSignedIn(host: other.host))
        #expect(await made.source.sent.isEmpty)
        #expect(try made.tokens.left(host: other.host).map(\.state) == [.owed])
    }

    @Test("A chain an ordinary widening made is not touched by what a read back's sign-ins are settled by: a sign-in left that may do what the one held may not is ended by no launch and no coming to the front, as before")
    func aWidenedChainIsAsItWas() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-held"))
        try made.tokens.journal(MastodonLeft(token("tok-wider", scopes: Self.acting), as: .left))
        try made.tokens.journal(MastodonLeft(token("tok-unsaid", scopes: Self.acting, id: nil), as: .left))
        let sessions = relaunched(made)

        await sessions.verifyAll()
        sessions.cameToFront()
        await sessions.leftSettled()
        sessions.readBack()
        await sessions.leftSettled()

        #expect(await made.source.revoked.isEmpty)
        #expect(await made.source.paths == [LeftSource.check], "a source was asked for more than who the sign-in is")
        #expect(try states(made) == [.left, .left])
    }

    @Test("A sign-in a read back took out that says nothing of whose it was is neither ended nor called an earlier form: it stays written down until the person signs out")
    func aReplacedOneNobodyNamed() async throws {
        let made = try readBack(over: token("tok-old", scopes: Self.acting, id: nil), bringing: MastodonOAuth.reading, saying: "1")

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(await made.source.revoked.isEmpty)
        #expect(try states(made) == [.replaced])

        await made.sessions.signOut(host: host)
        #expect(await made.source.revoked == ["tok-pkg", "tok-old"])
    }

    @Test("Read backs do not pile sign-ins up past the most a device leaves at a source: once one has held and the source has said who the sign-in is, the oldest beyond that many is ended — and none is while the read back may yet be undone", arguments: [MastodonLeft.State.replaced, .replacing])
    func theBoundHoldsAfterAReadBack(_ state: MastodonLeft.State) async throws {
        let made = fresh()
        for index in 0..<MastodonSessions.mostLeft {
            try made.tokens.journal(MastodonLeft(token("tok-left-\(index)"), as: .left))
        }
        try made.tokens.journal(MastodonLeft(token("tok-old"), as: state))
        try made.tokens.save(.carried(
            host: host, accessToken: "tok-pkg", clientID: "cid", clientSecret: "csecret", scopes: MastodonOAuth.reading,
            asked: nil, refused: nil, accountID: "1", handle: nil
        ))

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()

        #expect(await made.source.revoked == (state == .replaced ? ["tok-left-0"] : []))
        #expect(try states(made).count == (state == .replaced ? MastodonSessions.mostLeft : MastodonSessions.mostLeft + 1))
    }

    @Test("Adopting what a package brought settles what its read back took out: the shell's own adopt ends the sign-in a package put another account's over")
    func adoptingSettlesWhatWasTakenOut() async throws {
        let made = try readBack(over: token("tok-old"), bringing: MastodonOAuth.reading, saying: "2")
        await made.source.name("tok-pkg", account: "2")
        let session = await shell(made)
        let suite = "fediqo.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await session.adoptReadBack(prefs: DummyPrefs(defaults: try #require(UserDefaults(suiteName: suite))))
        await made.sessions.leftSettled()

        #expect(await made.source.revoked == ["tok-old"])
    }

    /// Two devices' packagers over one package: the sender's, holding `tok-pkg` as account
    /// `2`, and the receiver's over `tokens` — a folder each, gone with `remove`.
    private struct Carry {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString).fdq")
        let folders = (0..<2).map { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        let suite = "fediqo.test.\(UUID().uuidString)"
        let sender = MemoryMastodonTokens()
        let key = PackageKey.password("open sesame")

        func packager(_ folder: Int, _ tokens: any MastodonTokenStore, protected: ProtectedData = .always) throws -> StorePackager {
            StorePackager(
                directory: folders[folder], file: folder == 0 ? try StoreFile(at: folders[0]) : nil, store: ItemStore(),
                media: nil, tokens: tokens, credentials: MemoryCredentials(),
                defaults: try #require(UserDefaults(suiteName: suite)), device: "a test", appVersion: "0.7.0",
                protected: protected, freeSpace: { _ in .max }, rounds: 1000
            )
        }

        /// The sender's whole store, or only what signs in, taken away to `package`.
        func takeAway(host: String, _ contents: PackageSummary.Contents) async throws {
            try sender.save(MastodonToken(
                host: host, accessToken: "tok-pkg", clientID: "cid-pkg", clientSecret: "csecret-pkg",
                scopes: MastodonOAuth.reading, asked: MastodonOAuth.reading, accountID: "2"
            ))
            try sender.save(MastodonApp(host: host, clientID: "cid-pkg", clientSecret: "csecret-pkg"))
            try await packager(0, sender).takeAway(to: package, key: key, pictures: false, contents: contents) { _ in }
        }

        func remove() {
            for folder in folders {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
                try? FileManager.default.removeItem(at: folder)
            }
            try? FileManager.default.removeItem(at: package)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    @Test("Taken away on one device and read back on another signed in there as somebody else: the sign-in the package replaces is written down by the read back itself, which asks no source anything, and ended by the session once the source has said whose the package's is; and each device's is marked as having ridden a package")
    func readBackThroughThePackager() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old"))
        made.sessions.refresh()
        await made.source.name("tok-pkg", account: "2")
        let carry = Carry()
        defer { carry.remove() }
        try await carry.takeAway(host: host, .signInsOnly)

        try await carry.packager(1, made.tokens).readBack(carry.package, key: carry.key, replacing: false) { _ in }
        #expect(try held(made) == "tok-pkg")
        #expect(try states(made) == [.replaced])
        #expect(await made.source.sent.isEmpty, "the read back itself asked a source something")

        made.sessions.readBack()
        await made.sessions.leftSettled()

        #expect(await made.source.revoked == ["tok-old"])
        #expect(try states(made).isEmpty)
        #expect(made.sessions.leftTold == [.init(kind: .others, host: host)])
        #expect(try carry.sender.token(host: host)?.packaged == true)
        #expect(try made.tokens.token(host: host)?.packaged == true)
    }

    @Test("A read back that files its sign-ins and then fails a later step: a going-through of what was left and a coming to the front, landing between the two, end nothing — and the sign-in put back is the one the person had, never asked to end")
    func aPassBetweenTheFilingAndTheUndo() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old", scopes: Self.acting))
        try made.tokens.journal(MastodonLeft(token("tok-earlier"), as: .left))
        made.sessions.refresh()
        await made.source.name("tok-pkg", account: "2")
        let carry = Carry()
        defer { carry.remove() }
        try await carry.takeAway(host: host, .whole)
        // The package's sign-in is in, the folder refuses the index from here, and the read
        // back waits where it is until the session has had its turn.
        let (reached, reach) = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let folder = carry.folders[1].path
        let seam = SeamTokens(inner: made.tokens) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
            reach.yield()
            resume.wait()
        }
        let packager = try carry.packager(1, seam)
        let reading = Task { try await packager.readBack(carry.package, key: carry.key, replacing: false) { _ in } }
        for await _ in reached { break }
        #expect(try held(made) == "tok-pkg")
        #expect(try states(made) == [.left, .replacing])

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.isEmpty, "a sign-in was ended while the read back could still be undone")

        resume.signal()
        await #expect(throws: (any Error).self) { try await reading.value }
        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()

        #expect(try held(made) == "tok-old")
        #expect(try states(made) == [.left], "the earlier form of the sign-in put back did not come back with it")
        #expect(await made.source.revoked.isEmpty, "the sign-in put back, or an earlier form of it, was ended at its source")
        #expect(made.sessions.isSignedIn(host: host))
    }

    @Test("A read back whose undo a locked device put off: until the device is unlocked and the undo done, a launch and a coming to the front end nothing — and the sign-in then put back is the one the person had, never asked to end")
    func aPassWhileTheUndoIsOwed() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old", scopes: Self.acting))
        try made.tokens.journal(MastodonLeft(token("tok-earlier"), as: .left))
        made.sessions.refresh()
        await made.source.name("tok-pkg", account: "2")
        let carry = Carry()
        defer { carry.remove() }
        try await carry.takeAway(host: host, .whole)
        // The device locks as the package's sign-in goes in: the folder takes no file, the
        // canary refuses, and the Keychain will not be written to put anything back.
        let folder = carry.folders[1].path
        let seam = SeamTokens(inner: made.tokens)
        seam.onFiled = { [seam] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
            seam.lock(true)
        }
        let protected = ProtectedData(
            flag: { true }, canary: { [seam] in seam.isLocked ? .refused : .reads },
            remade: { .refused }, unlockedForSomebody: { false }, changes: { AsyncStream { $0.finish() } }
        )
        let packager = try carry.packager(1, seam, protected: protected)

        await #expect(throws: (any Error).self) {
            try await packager.readBack(carry.package, key: carry.key, replacing: false) { _ in }
        }
        try #require(try held(made) == "tok-pkg", "the premise: the undo was put off")
        #expect(try states(made) == [.left, .replacing])

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(await made.source.revoked.isEmpty, "a sign-in was ended while its read back's undo was still owed")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        seam.lock(false)
        #expect(await packager.finishOwed())
        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()

        #expect(try held(made) == "tok-old")
        #expect(try states(made) == [.left], "the earlier form of the sign-in put back did not come back with it")
        #expect(await made.source.revoked.isEmpty, "the sign-in put back, or an earlier form of it, was ended at its source")
    }

    // MARK: - The earlier forms of a sign-in a read back took out

    /// `tok-old` held with `tok-earlier` left beneath it, both account `1`'s, then taken out
    /// by a read back that got as far as `state` — with nothing put in its place, or with
    /// `tok-pkg`, which the source says is account `2`'s.
    private func readBackOverAChain(_ state: MastodonLeft.State, bare: Bool, saying id: String? = "2") async throws -> Made {
        let made = fresh()
        try made.tokens.save(token("tok-old"))
        try made.tokens.journal(MastodonLeft(token("tok-earlier"), as: .left))
        made.sessions.refresh()
        try made.tokens.journal(MastodonLeft(token("tok-old"), as: state))
        #expect(try made.tokens.forget(token("tok-old")))
        if !bare {
            try made.tokens.save(.carried(
                host: host, accessToken: "tok-pkg", clientID: "cid-pkg", clientSecret: "csecret-pkg",
                scopes: MastodonOAuth.reading, asked: MastodonOAuth.reading, refused: nil, accountID: id, handle: nil
            ))
            await made.source.name("tok-pkg", account: "2")
        }
        return made
    }

    @Test("While a read back may yet be undone, the earlier forms of the sign-in it took out are ended by nothing — a launch, a coming to the front, the adopting — whether it put nothing in its place or another account's sign-in the source has named; and put back, the sign-in and every earlier form of it are as they were", arguments: [true, false])
    func aChainUnderAReadBackNotYetHeld(_ bare: Bool) async throws {
        let made = try await readBackOverAChain(.replacing, bare: bare)

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(await made.source.revoked.isEmpty, "an earlier form of a sign-in was ended while its read back could still be undone")
        #expect(try states(made) == [.left, .replacing])

        // The undo, as the packager does it: the package's out, the one held before back.
        try made.tokens.forget(host: host)
        try made.tokens.save(token("tok-old"))
        try made.tokens.unjournal(MastodonLeft(token("tok-old"), as: .replacing))
        made.sessions.readBack()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(try held(made) == "tok-old")
        #expect(try states(made) == [.left])
        #expect(await made.source.revoked.isEmpty)
    }

    @Test("A sign-in landing while a read back may yet be undone ends no earlier form of the sign-in that read back took out, though it is another account's, nor one beyond the most a device leaves: they go back with it", arguments: [true, false])
    func aSignInLandingUnderAReadBackNotYetHeld(_ bare: Bool) async throws {
        let made = try await readBackOverAChain(.replacing, bare: bare)
        for index in 0..<MastodonSessions.mostLeft {
            try made.tokens.journal(MastodonLeft(token("tok-left-\(index)"), as: .left))
        }
        await made.source.name("tok-1", account: "3")
        // The source has said whose the package's is, so signing in over it ends it.
        if !bare { await made.sessions.learnWho(host: host) }

        #expect(await made.sessions.signIn(host: host, through: LeftPage()) == nil)

        // Only the package's own, which the person signed in over as somebody else.
        #expect(await made.source.revoked == (bare ? [] : ["tok-pkg"]))
        #expect(try held(made) == "tok-1")
        #expect(try states(made).filter { $0 == .left }.count == MastodonSessions.mostLeft + 1)
        #expect(try states(made).contains(.replacing))
    }

    @Test("A sign-in a package brought that its source then ends, while the read back may yet be undone: the earlier forms of the sign-in it took out are not ended with it")
    func thePackagesOwnEndedUnderAReadBackNotYetHeld() async throws {
        let made = try await readBackOverAChain(.replacing, bare: false)
        made.sessions.refresh()
        await made.source.check("tok-pkg", answers: 401)

        await made.sessions.learnWho(host: host)
        await made.sessions.leftSettled()

        #expect(try held(made) == nil)
        #expect(await made.source.revoked.isEmpty)
        #expect(try states(made) == [.left, .replacing])
    }

    @Test("A sign-in a package brought that its source then ends, once the read back has held: the earlier forms of the sign-in it took out are not ended at once either — they follow the one that stands written down as replaced")
    func thePackagesOwnEndedUnderAReplacedHead() async throws {
        let made = try await readBackOverAChain(.replaced, bare: false)
        made.sessions.refresh()
        await made.source.check("tok-pkg", answers: 401)

        await made.sessions.learnWho(host: host)
        await made.sessions.leftSettled()

        #expect(try held(made) == nil)
        #expect(await made.source.revoked.isEmpty)
        #expect(try states(made) == [.left, .replaced])
        #expect(made.sessions.endedLeft.isEmpty, "the notice said other devices were signed out, and none was")
    }

    @Test("A 401 that is not the source's own, through the package's sign-in, while its read back may yet be undone: the notes of the earlier forms leave the device with it, as ever — and the undo puts them back with the sign-in it restores")
    func aBare401ThenTheUndo() async throws {
        let made = fresh()
        try made.tokens.save(token("tok-old", scopes: Self.acting))
        try made.tokens.journal(MastodonLeft(token("tok-earlier"), as: .left))
        made.sessions.refresh()
        let carry = Carry()
        defer { carry.remove() }
        try await carry.takeAway(host: host, .whole)
        let (reached, reach) = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let folder = carry.folders[1].path
        let seam = SeamTokens(inner: made.tokens) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
            reach.yield()
            resume.wait()
        }
        let packager = try carry.packager(1, seam)
        let reading = Task { try await packager.readBack(carry.package, key: carry.key, replacing: false) { _ in } }
        for await _ in reached { break }
        made.sessions.refresh()
        await made.source.check("tok-pkg", answers: 401, saying: "<html><body><h1>401 Authorization Required</h1></body></html>")

        await made.sessions.learnWho(host: host)
        await made.sessions.leftSettled()
        try #require(try held(made) == nil)
        try #require(try states(made) == [.replacing], "the premise: the earlier form's note went with the sign-in")

        resume.signal()
        await #expect(throws: (any Error).self) { try await reading.value }

        #expect(try held(made) == "tok-old")
        #expect(try states(made) == [.left], "the undo did not put back the note of the earlier form")
        #expect(try made.tokens.left(host: host).first?.isToken(token("tok-earlier")) == true)
        #expect(await made.source.revoked.isEmpty)
    }

    @Test("A read back that held and brought no sign-in for the source: the earlier forms of the one it took out are left with it — nothing is ended at a launch or a coming to the front — until the person decides; and whichever way that goes, they follow it")
    func aChainUnderABareReplacedHead() async throws {
        let made = try await readBackOverAChain(.replaced, bare: true)

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(await made.source.sent.isEmpty, "an earlier form was ended where the one a read back took out is left")
        #expect(try states(made) == [.left, .replaced])

        // The one switch, either way, over the journal as it stands — and over the others.
        let entries = try made.tokens.left(host: host)
        let earlier = try #require(entries.first), head = try #require(entries.last)
        for ending in [true, false] {
            #expect(MastodonSessions.endsWithNoneHeld(head, among: entries, endingBare: ending) == ending)
            #expect(MastodonSessions.endsWithNoneHeld(earlier, among: entries, endingBare: ending) == ending, "the chain did not follow its head")
            let notYet = [earlier, head.marked(.replacing)]
            #expect(!MastodonSessions.endsWithNoneHeld(earlier, among: notYet, endingBare: ending))
            #expect(!MastodonSessions.endsWithNoneHeld(notYet[1], among: notYet, endingBare: ending))
            // With no read back's own there, a left one is ended as it always was.
            #expect(MastodonSessions.endsWithNoneHeld(earlier, among: [earlier], endingBare: ending))
        }
        #expect(MastodonSessions.endsWithNoneHeld(head, among: entries) == MastodonSessions.endsWhatAReadBackLeftBare)
    }

    @Test("A package naming another account, with its source out of reach, ends no earlier form of the sign-in it replaced either: whose the one now held is, is what its source says, and nothing written beside it")
    func aChainUnderAnUnconfirmedPackage() async throws {
        let made = try await readBackOverAChain(.replaced, bare: false)
        await made.source.check("tok-pkg", answers: 0)

        made.sessions.readBack()
        await made.sessions.leftSettled()
        await made.sessions.verifyAll()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        await relaunched(made).verifyAll()

        #expect(await made.source.revoked.isEmpty, "a sign-in left was ended as another account's on a package's word")
        #expect(try states(made) == [.left, .replaced])
        #expect(made.sessions.leftTold.isEmpty)
    }

    @Test("Signing in over a sign-in that rode a package, whose source has not said whose it is this run: what is written beside it is not gone by — it is neither ended as another's nor left as an earlier form, but written down, saying nothing of whose it was, until the person signs out. Once its source has said, it is ended or left as any other", arguments: [
        ["1", "unsaid"], ["2", "unsaid"], ["1", "said"], ["2", "said"], ["1", "unsaid", "wider"], ["2", "unsaid", "wider"],
    ])
    func signingInOverOneThatRodeAPackage(_ row: [String]) async throws {
        let made = fresh()
        // Where it may do what the new sign-in may not — it acts, and the new one only reads
        // — it is ended whoever it is, as a narrowing and another account both are.
        let wider = row.count > 2
        let words = wider ? Self.acting : MastodonOAuth.reading
        try made.tokens.save(.carried(
            host: host, accessToken: "tok-pkg", clientID: "cid-pkg", clientSecret: "csecret-pkg",
            scopes: words, asked: words, refused: nil, accountID: row[0], handle: nil
        ))
        made.sessions.refresh()
        await made.source.name("tok-pkg", account: row[0])
        if row[1] == "said" { await made.sessions.learnWho(host: host) }

        // The new sign-in is account 1's: it reads and acts, or only reads over one that acts.
        #expect(await made.sessions.signIn(host: host, through: LeftPage(), writing: !wider) == nil)

        #expect(try held(made) == "tok-1")
        if wider {
            #expect(await made.source.revoked == ["tok-pkg"], "one that may do more than the new sign-in was spared")
            #expect(try states(made).isEmpty)
        } else if row[1] == "unsaid" {
            #expect(await made.source.revoked.isEmpty, "a sign-in was ended by what a package wrote beside it")
            #expect(try states(made) == [.replaced])
            #expect(try made.tokens.left(host: host).first?.accountID == nil)
        } else {
            #expect(await made.source.revoked == (row[0] == "1" ? [] : ["tok-pkg"]))
            #expect(try states(made) == (row[0] == "1" ? [.left] : []))
        }
        await made.sessions.signOut(host: host)
        #expect(try made.tokens.leftHosts().isEmpty)
    }

    // MARK: - Never logged

    @Test("What is told, what is owed and what was left print as hosts, states and counts — and the session writes no token, entry or secret into a log line")
    func neverLogged() async throws {
        let made = try await owing()
        await made.source.answer(.refuses, for: "tok-2")
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        let left = try made.tokens.left(host: host)
        var printed = "\(made.sessions.leftTold) \(made.sessions.owed) \(made.sessions.lost) \(left)"
        dump(made.sessions.leftTold, to: &printed)
        dump(left, to: &printed)
        #expect(!printed.contains("tok-"))
        #expect(!printed.contains("csecret"))

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let session = try String(contentsOf: root.appending(path: "Sources/FediqoUI/Shell/MastodonSignIn.swift"), encoding: .utf8)
        let logged = session.split(separator: "\n").filter { $0.contains("NetLog.") }
        #expect(!logged.isEmpty)
        for line in logged {
            #expect(line.contains("NetLog.line("), "\(line)")
            #expect(line.contains("host: "), "\(line)")
            #expect(line.contains("error: error"), "\(line)")
            #expect(line.components(separatedBy: "\\(").count == 2, "more than the one line is written into it: \(line)")
        }
    }
}

/// A Keychain over a memory one, as a read back's packager meets it: it runs `onFiled` once,
/// when the package's registration — the last thing a read back files — is in, and can be
/// locked: nothing of it written, though what it holds still reads.
private final class SeamTokens: MastodonTokenStore, @unchecked Sendable {
    let inner: MemoryMastodonTokens
    var onFiled: (@Sendable () -> Void)?
    private let state = NSLock()
    private var locked = false
    private var ran = false

    init(inner: MemoryMastodonTokens, onFiled: (@Sendable () -> Void)? = nil) {
        self.inner = inner
        self.onFiled = onFiled
    }

    var isLocked: Bool { state.withLock { locked } }
    func lock(_ locked: Bool) { state.withLock { self.locked = locked } }
    private func open() throws { if isLocked { throw ForumCredentialError.keychain(-25_308) } }

    func token(host: String) throws -> MastodonToken? { try inner.token(host: host) }
    func save(_ token: MastodonToken) throws { try open(); try inner.save(token) }
    func forget(host: String) throws { try open(); try inner.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try open(); return try inner.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try inner.grants() }
    func parts() throws -> [String: MastodonHeld] { try inner.parts() }
    func update(_ token: MastodonToken) throws -> Bool { try open(); return try inner.update(token) }
    func swap(expecting held: String?, with token: MastodonToken) throws -> Bool {
        try open()
        return try inner.swap(expecting: held, with: token)
    }
    func left(host: String) throws -> [MastodonLeft] { try inner.left(host: host) }
    func leftHosts() throws -> Set<String> { try inner.leftHosts() }
    func journal(_ entry: MastodonLeft) throws { try open(); try inner.journal(entry) }
    func unjournal(_ entry: MastodonLeft) throws { try open(); try inner.unjournal(entry) }
    func app(host: String) throws -> MastodonApp? { try inner.app(host: host) }
    func save(_ app: MastodonApp) throws {
        try open()
        try inner.save(app)
        let first = state.withLock { () -> Bool in
            defer { ran = true }
            return !ran
        }
        if first { onFiled?() }
    }
    func forgetApp(host: String) throws { try open(); try inner.forgetApp(host: host) }
}
