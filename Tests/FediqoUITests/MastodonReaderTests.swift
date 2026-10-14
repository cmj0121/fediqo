import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon as a sign-in meets it — a registration, a trade, the account check, the ask to
/// end a sign-in — that says who each token signs in, and can hold one account check until a
/// test lets it go. **A held check has no clock of its own**: the check that holds it arms a
/// guard that lets it go when the run has gone still, and waits for it to arrive by the work
/// that was to send it.
private actor ReaderSource: HTTPClient, HTTPSender {
    struct Sent: Sendable, Equatable {
        let host: String
        let path: String
        let bearer: String?
    }

    static let check = "/api/v1/accounts/verify_credentials"

    private var saying: [String: (status: Int, body: String)] = [:]
    private var handedBack: [String] = []
    private var issued = 0
    private var holdsNext = false
    private var heldCheck: [CheckedContinuation<Void, Never>] = []
    /// Whether the held check has arrived.
    private(set) var arrived = false
    private(set) var sent: [Sent] = []

    var checks: Int { sent.count { $0.path == Self.check } }
    var revoked: Int { sent.count { $0.path == "/oauth/revoke" } }

    /// What the account check answers through `token`; through any other, account `1`,
    /// `reader`.
    func says(_ token: String, _ body: String, status: Int = 200) { saying[token] = (status, body) }

    /// The next trade hands out `string` in place of a new one.
    func handBack(_ string: String) { handedBack.append(string) }

    /// Holds the next account check until `release`.
    func holdNextCheck() {
        holdsNext = true
        arrived = false
    }

    func release() {
        holdsNext = false
        for check in heldCheck { check.resume() }
        heldCheck = []
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let bearer = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        sent.append(Sent(host: url.host ?? "", path: url.path, bearer: bearer))
        func answered(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch url.path {
        case "/api/v1/apps":
            let asked = form.split(separator: "&").first { $0.hasPrefix("scopes=") }
                .map { String($0.dropFirst("scopes=".count)).removingPercentEncoding ?? "" } ?? ""
            let named = asked.split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
            return answered(#"{"client_id":"cid","client_secret":"csecret","redirect_uri":"fediqo://oauth","scopes":[\#(named)]}"#)
        case "/oauth/token":
            if !handedBack.isEmpty { return answered(#"{"access_token":"\#(handedBack.removeFirst())"}"#) }
            issued += 1
            return answered(#"{"access_token":"tok-\#(issued)"}"#)
        case Self.check:
            if holdsNext {
                holdsNext = false
                arrived = true
                await withCheckedContinuation { heldCheck.append($0) }
            }
            let said = saying[bearer ?? ""] ?? (200, #"{"id":"1","acct":"reader"}"#)
            return answered(said.body, said.status)
        case "/oauth/revoke":
            return answered("{}")
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The source's own page, approving.
@MainActor
private final class ReaderPage: OAuthBrowser {
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

/// A store that lets a test file a sign-in at the moment a note is about to be written beside
/// the one held, or a sign-in has just been kept — as a package read back does from another
/// thread — and whose every look can be made to fail, as a Keychain read on a locked device
/// does.
private final class Racing: MastodonTokenStore, @unchecked Sendable {
    private let held: MemoryMastodonTokens
    var beforeUpdate: (() -> Void)?
    /// Run once a swap has kept its sign-in, before anything looks at what is held.
    var afterSwap: (() -> Void)?
    var locked = false

    init(_ held: MemoryMastodonTokens) { self.held = held }

    func update(_ token: MastodonToken) throws -> Bool {
        beforeUpdate?()
        beforeUpdate = nil
        return try held.update(token)
    }

    private func open() throws {
        if locked { throw ForumCredentialError.keychain(-25_308) }
    }

    func swap(expecting string: String?, with token: MastodonToken) throws -> Bool {
        let kept = try held.swap(expecting: string, with: token)
        afterSwap?()
        afterSwap = nil
        return kept
    }

    func token(host: String) throws -> MastodonToken? { try open(); return try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? { try held.forget(token, saidBySource: saidBySource) }
    func grants() throws -> [String: MastodonGrant] { try open(); return try held.grants() }
    func parts() throws -> [String: MastodonHeld] { try open(); return try held.parts() }
    func left(host: String) throws -> [MastodonLeft] { try held.left(host: host) }
    func leftHosts() throws -> Set<String> { try held.leftHosts() }
    func journal(_ entry: MastodonLeft) throws { try held.journal(entry) }
    func journalLost(_ token: MastodonToken, accountID: String?) throws { try held.journalLost(token, accountID: accountID) }
    func unjournal(_ entry: MastodonLeft) throws { try held.unjournal(entry) }
    func forgetLeft(host: String) throws { try held.forgetLeft(host: host) }
    func restoreLost(host: String) throws -> Bool { try held.restoreLost(host: host) }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// #347, F1 §5: who the reader is at a source is what the sign-in's own check said — for a
/// sign-in that only reads as for one that acts — kept with the sign-in and nowhere else, and
/// laid only on the sign-in it was said through.
@MainActor
@Suite("Who the reader is, from the sign-in's own check", .watched)
struct MastodonReaderTests {
    private let host = "social.example"
    private let named = "@reader@social.example"

    private typealias Made = (sessions: MastodonSessions, source: ReaderSource, tokens: MemoryMastodonTokens)

    private func fresh(_ tokens: MemoryMastodonTokens = MemoryMastodonTokens()) -> Made {
        let source = ReaderSource()
        let sessions = MastodonSessions(tokens: tokens, sender: source)
        // A door's deadline, on a clock nobody turns: no check here waits for one to pass.
        sessions.deadlineSleep = TurnedClock().sleep
        return (sessions, source, tokens)
    }

    /// A sign-in kept by an earlier run, with nothing said yet of whose it is.
    private func kept(_ string: String = "tok-old", scopes: String? = MastodonOAuth.scopes(writing: false)) throws -> Made {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(string, scopes: scopes))
        return fresh(tokens)
    }

    private func token(_ string: String, scopes: String? = MastodonOAuth.scopes(writing: false)) -> MastodonToken {
        MastodonToken(host: host, accessToken: string, clientID: "cid", clientSecret: "csecret", scopes: scopes, asked: scopes)
    }

    private func held(_ made: Made) throws -> MastodonToken? { try made.tokens.token(host: host) }

    /// The lines of a source file that are code: a comment may say anything.
    private func codeLines(of text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - Every sign-in is named by its own check

    @Test("A sign-in is named by its own check, whatever it may do: the reader's handle and the account's id are known as it is kept, written with it, and the source is asked who they are once — not a second time for a sign-in that acts", arguments: [false, true])
    func everySignInIsNamedAsItIsKept(writing: Bool) async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: writing) == nil)

        #expect(made.sessions.handles[host] == named)
        #expect(made.sessions.reader(host: host)?.id == "1")
        let kept = try #require(try held(made))
        #expect(kept.accountID == "1")
        #expect(kept.handle == named)
        #expect(await made.source.checks == 1)
        let hosts = Set(await made.source.sent.map(\.host))
        #expect(hosts == [host], "asked of the sign-in's own source and no other")
    }

    @Test("A launch asks each source that holds a sign-in who the reader is once, a sign-in to read as one to act, and nothing else — and a device with none asks nobody")
    func whatALaunchAsks() async throws {
        for scopes in [MastodonOAuth.scopes(writing: false), MastodonOAuth.scopes(writing: true)] {
            let made = try kept(scopes: scopes)
            await made.sessions.verifyAll()
            #expect(await made.source.sent.map(\.path) == [ReaderSource.check])
            #expect(made.sessions.handles[host] == named)
            #expect(try held(made)?.accountID == "1")
        }
        let nobody = fresh()
        await nobody.sessions.verifyAll()
        #expect(await nobody.source.sent.isEmpty)
    }

    @Test("Who a sign-in is, is written beside it in place: a Keychain that would refuse to add the sign-in back loses nothing of it, and the sign-in is still the one held, now named")
    func whoItIsIsWrittenInPlace() async throws {
        let made = try kept()
        let before = try #require(try held(made))
        // A save deletes and then adds: with the add refused, it would lose the sign-in.
        made.tokens.refuse(.adding, times: 8)
        await made.sessions.learnWho(host: host)

        let after = try #require(try held(made), "the note of who it is cost the person their sign-in")
        #expect(after.accessToken == before.accessToken)
        #expect(after.stamp == before.stamp)
        #expect(after.accountID == "1")
        #expect(after.handle == named)
        #expect(after.scopes == before.scopes)
        #expect(made.sessions.isSignedIn(host: host))
    }

    @Test("A note of who it is that the Keychain refuses changes nothing held, and the reader is still known for the run by what the source said through that very sign-in")
    func aRefusedNoteLosesNothing() async throws {
        let made = try kept()
        made.tokens.refuse(.changing, times: 8)
        await made.sessions.learnWho(host: host)
        let after = try #require(try held(made))
        #expect(after.accountID == nil)
        #expect(made.sessions.handles[host] == named)
        #expect(made.sessions.reader(host: host)?.id == "1")
    }

    // MARK: - A sign-in the source will not name

    @Test("A source that refuses the check — the sign-in lacks the word that reads the account — names nobody: a sign-in made so is not kept, and one already held stays signed in, unnamed, with no page of the reader's own and nothing ended")
    func aSignInTheCheckIsRefused() async throws {
        let refusal = #"{"error":"This action is outside the authorized scopes"}"#
        let made = fresh()
        await made.source.says("tok-1", refusal, status: 403)
        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == .http(403))
        #expect(try held(made) == nil)
        #expect(made.sessions.handles[host] == nil)

        let older = try kept()
        await older.source.says("tok-old", refusal, status: 403)
        await older.sessions.verifyAll()
        #expect(older.sessions.isSignedIn(host: host))
        #expect(older.sessions.ended.isEmpty)
        #expect(older.sessions.handles[host] == nil)
        #expect(older.sessions.reader(host: host) == nil)
        #expect(try held(older)?.accountID == nil)
        #expect(await older.source.revoked == 0)
        #expect(await older.source.checks == 1, "and it is not asked again")
    }

    @Test("A handle that is another server's is not the reader's here: the sign-in is named by its id alone, kept so, and there is no handle to open a page by")
    func aHandleOfAnotherServer() async throws {
        let made = fresh()
        await made.source.says("tok-1", #"{"id":"1","acct":"eve@other.example"}"#)
        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(made.sessions.handles[host] == nil)
        let reader = try #require(made.sessions.reader(host: host))
        #expect(reader.id == "1")
        #expect(reader.handle == nil)
        let kept = try #require(try held(made))
        #expect(kept.accountID == "1")
        #expect(kept.handle == nil)

        // And at a launch, through the door's own check.
        let later = fresh(made.tokens)
        await later.source.says("tok-1", #"{"id":"1","acct":"eve@other.example"}"#)
        await later.sessions.verifyAll()
        #expect(later.sessions.handles[host] == nil)
        #expect(later.sessions.reader(host: host)?.id == "1")
    }

    // MARK: - Shown first

    enum Meanwhile: String, CaseIterable, Sendable {
        case signedOut, removed, signedInAgain, packageReadBack, journalGoneThrough
    }

    @Test("What the check answers is laid only on the sign-in it was asked through: a sign-out, a Remove, another sign-in, or a package read back from another thread while the source is still answering leaves the late answer on nobody — and a going-through of what was left changes nothing of it", arguments: Meanwhile.allCases)
    func aLateAnswerLandsOnNobodyElse(meanwhile: Meanwhile) async throws {
        let made = try kept()
        await made.source.holdNextCheck()
        let guardTask = watching("the account check, held at the source") { [source = made.source] in await source.release() }
        defer { guardTask.cancel() }
        let asking = Task { await made.sessions.learnWho(host: host) }
        defer { Task { await made.source.release() } }
        // Not arrived, the check this holds was never sent, and the next one sent would wait in
        // its place with nobody to let it go: let go here, so the check fails and does not park.
        let arrived = await met("the account check has arrived at the source", by: asking) { await made.source.arrived }
        if !arrived { await made.source.release() }

        let tokens = made.tokens
        let other = token("tok-pkg")
        switch meanwhile {
        case .signedOut:
            await made.sessions.signOut(host: host)
        case .removed:
            await made.sessions.signOut(host: host, forgettingApp: true)
        case .signedInAgain:
            await made.source.says("tok-1", #"{"id":"2","acct":"other"}"#)
            #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        case .packageReadBack:
            // As a read back files it: off the main actor, through the store.
            try await Task.detached { try tokens.save(other) }.value
        case .journalGoneThrough:
            try made.tokens.journal(MastodonLeft(token("tok-before").named(accountID: "1", handle: nil), as: .left))
            await made.sessions.settleLeft()
        }
        await made.source.release()
        await asking.value

        let now = try held(made)
        switch meanwhile {
        case .signedOut, .removed:
            #expect(now == nil)
            #expect(made.sessions.handles[host] == nil)
            #expect(made.sessions.reader(host: host) == nil)
            #expect(try made.tokens.left(host: host).isEmpty)
        case .signedInAgain:
            #expect(now?.accessToken == "tok-1")
            #expect(now?.accountID == "2", "the answer about the sign-in before was written onto this one")
            #expect(made.sessions.handles[host] == "@other@social.example")
            #expect(made.sessions.reader(host: host)?.id == "2")
        case .packageReadBack:
            #expect(now?.accessToken == "tok-pkg")
            #expect(now?.accountID == nil, "a sign-in a package brought was named by an answer about another")
            #expect(now?.handle == nil)
            #expect(made.sessions.handles[host] == nil)
            #expect(made.sessions.reader(host: host) == nil)
        case .journalGoneThrough:
            #expect(now?.accessToken == "tok-old")
            #expect(now?.accountID == "1")
            #expect(made.sessions.handles[host] == named)
            #expect(try made.tokens.left(host: host).map(\.state) == [.left])
            #expect(await made.source.revoked == 0)
        }
    }

    @Test("A late answer that names no id is laid on nobody else either: the handle a source gave through one sign-in is not shown for the sign-in that took its place while it answered")
    func aLateAnswerWithNoIdLandsOnNobodyElse() async throws {
        let made = try kept()
        await made.source.says("tok-old", #"{"acct":"reader"}"#)
        await made.source.holdNextCheck()
        let guardTask = watching("the account check, held at the source") { [source = made.source] in await source.release() }
        defer { guardTask.cancel() }
        let asking = Task { await made.sessions.learnWho(host: host) }
        defer { Task { await made.source.release() } }
        // Not arrived, the check this holds was never sent, and the next one sent would wait in
        // its place with nobody to let it go: let go here, so the check fails and does not park.
        let arrived = await met("the account check has arrived at the source", by: asking) { await made.source.arrived }
        if !arrived { await made.source.release() }
        try made.tokens.save(token("tok-pkg"))
        await made.source.release()
        await asking.value
        #expect(made.sessions.handles[host] == nil)
        #expect(try held(made)?.handle == nil)
    }

    @Test("A sign-in filed from another thread between the look at what is held and the note of who it is, is not named by that note: the write is only over the string the answer came through, and nothing of the answer is shown")
    func replacedBetweenTheLookAndTheWrite() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token("tok-old"))
        let racing = Racing(tokens)
        let source = ReaderSource()
        let sessions = MastodonSessions(tokens: racing, sender: source)
        sessions.deadlineSleep = TurnedClock().sleep
        let other = token("tok-pkg")
        racing.beforeUpdate = { try? tokens.save(other) }
        await sessions.learnWho(host: host)

        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "tok-pkg")
        #expect(now.accountID == nil)
        #expect(sessions.handles[host] == nil)
        #expect(sessions.reader(host: host) == nil)
    }

    @Test("A sign-in filed from another thread between a sign-in being kept and the look that follows is not named by that sign-in's check: nothing of it is shown for the one a package brought, and the first read that reaches the source asks who reads it now")
    func replacedBetweenTheKeepAndTheLook() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token("tok-old"))
        let racing = Racing(tokens)
        let source = ReaderSource()
        let sessions = MastodonSessions(tokens: racing, sender: source)
        sessions.deadlineSleep = TurnedClock().sleep
        let other = token("tok-pkg")
        racing.afterSwap = { try? tokens.save(other) }
        await source.says("tok-pkg", #"{"id":"2","acct":"other"}"#)
        _ = await sessions.signIn(host: host, through: ReaderPage(), writing: true)

        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "tok-pkg")
        #expect(now.accountID == nil)
        #expect(sessions.handles[host] == nil, "the sign-in just made is shown as the one a package brought")
        #expect(sessions.reader(host: host) == nil)

        await sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(sessions.handles[host] == "@other@social.example")
        #expect(sessions.reader(host: host)?.id == "2")
    }

    // MARK: - A handle the source no longer gives

    @Test("A handle is written beside a sign-in only as long as its source gives it: a later check that names the account and no handle of its own takes the handle written before away, the same account's as another's", arguments: ["1", "2"])
    func aHandleNoLongerGivenIsUnwritten(id: String) async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token("tok-old").named(accountID: "1", handle: named))
        let made = fresh(tokens)
        #expect(made.sessions.reader(host: host)?.handle == named, "the premise")
        await made.source.says("tok-old", #"{"id":"\#(id)","acct":"eve@other.example"}"#)
        await made.sessions.learnWho(host: host)

        let after = try #require(try held(made))
        #expect(after.accountID == id)
        #expect(after.handle == nil, "the handle of a check before stands beside what this one said")
        let reader = try #require(made.sessions.reader(host: host))
        #expect(reader.id == id)
        #expect(reader.handle == nil)
        #expect(made.sessions.handles[host] == nil)
    }

    @Test("A handle an earlier build wrote beside a sign-in is shown only where it would be taken today: one that names another server, or is no name a line of ours can hold, is no handle — and the id beside it still names the reader", arguments: [
        "@eve@other.example", "@rea\u{202E}der@social.example", "@re\u{0430}der@social.example", "reader",
    ])
    func anOldHandleIsReadByTodaysRule(written: String) throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token("tok-old").named(accountID: "1", handle: written))
        let made = fresh(tokens)
        let reader = try #require(made.sessions.reader(host: host))
        #expect(reader.id == "1")
        #expect(reader.handle == nil)
    }

    // MARK: - A device that is locked

    @Test("A look the Keychain refuses is not a sign-out: who the reader is stands as it was, and is there again with no relaunch and no ask once the Keychain reads — and it invents nobody: a sign-in gone or replaced meanwhile, and one signed out, has no reader")
    func aRefusedLookKeepsWhoTheReaderIs() async throws {
        let tokens = MemoryMastodonTokens()
        let racing = Racing(tokens)
        let source = ReaderSource()
        let sessions = MastodonSessions(tokens: racing, sender: source)
        sessions.deadlineSleep = TurnedClock().sleep
        #expect(await sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(sessions.handles[host] == named)

        racing.locked = true
        sessions.refresh()
        #expect(!sessions.isSignedIn(host: host), "the premise: the look found nothing")
        racing.locked = false
        sessions.refresh()
        #expect(sessions.isSignedIn(host: host))
        #expect(sessions.handles[host] == named)
        #expect(sessions.reader(host: host)?.id == "1")
        await sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await source.checks == 1)

        // Replaced while no look could be had: nobody until its own source says.
        racing.locked = true
        sessions.refresh()
        try tokens.save(token("tok-pkg"))
        await source.says("tok-pkg", #"{"id":"2","acct":"other"}"#)
        racing.locked = false
        sessions.refresh()
        #expect(sessions.handles[host] == nil)
        await sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(sessions.handles[host] == "@other@social.example")

        // Gone while no look could be had.
        racing.locked = true
        sessions.refresh()
        try tokens.forget(host: host)
        racing.locked = false
        sessions.refresh()
        #expect(sessions.handles.isEmpty)
        #expect(sessions.reader(host: host) == nil)

        #expect(await sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(sessions.handles[host] != nil)
        racing.locked = true
        sessions.refresh()
        racing.locked = false
        await sessions.signOut(host: host)
        #expect(sessions.handles.isEmpty)
        #expect(sessions.reader(host: host) == nil)
    }

    @Test("A sign-in replaced from outside while the app runs is nobody until its own source says: what was known of the one before is let go at the next look, and the first read that reaches that source asks who the reader is now — once")
    func replacedFromOutsideItIsAskedAgain() async throws {
        let made = try kept()
        await made.sessions.verifyAll()
        #expect(made.sessions.handles[host] == named)
        let asked = await made.source.checks

        try made.tokens.save(token("tok-pkg"))
        await made.source.says("tok-pkg", #"{"id":"2","acct":"other"}"#)
        made.sessions.refresh()
        #expect(made.sessions.handles[host] == nil, "the reader before is shown as the one a package brought")
        #expect(made.sessions.reader(host: host) == nil)
        #expect(await made.source.checks == asked, "a look asks nobody")

        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(made.sessions.handles[host] == "@other@social.example")
        #expect(try held(made)?.accountID == "2")
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.checks == asked + 1)
    }

    // MARK: - Whose rows

    @Test("A sign-in made over one of the same account is the same reader, told by the id and not by a handle: what the source said that reader did to its posts stays theirs — and another account's, or one nobody named, is another reader")
    func theSameReaderIsToldByTheId() async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(made.sessions.takeReadersChanged() == [host], "a first sign-in is a new reader")

        await made.source.says("tok-2", #"{"id":"1","acct":"renamed"}"#)
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(made.sessions.takeReadersChanged().isEmpty, "the same account, renamed, read as another reader")
        // A sign-in made here has said who it is: no read that follows asks for it again.
        let asked = await made.source.checks
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.checks == asked)

        await made.source.says("tok-3", #"{"id":"2","acct":"reader"}"#)
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(made.sessions.takeReadersChanged() == [host], "another account under the same name read as the same reader")

        await made.source.says("tok-4", "{}")
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(made.sessions.takeReadersChanged() == [host])
    }

    // MARK: - The count

    @Test("The count of a source's sign-ins moves once each time the sign-in held there becomes another — kept, widened, narrowed, replaced from outside, ended by the source, signed out — and never for the same one written again: named, noted, handed back, or filed again unchanged")
    func theCountMovesWithTheSignInHeld() async throws {
        let made = fresh()
        func count() -> Int { made.sessions.changes[host, default: 0] }
        #expect(count() == 0)

        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(count() == 1, "kept")

        // The same sign-in, written again: who it is, a refusal noted, a look.
        await made.source.says("tok-1", #"{"id":"1","acct":"renamed"}"#)
        await made.sessions.learnWho(host: host)
        #expect(try held(made)?.handle == "@renamed@social.example")
        let noted = try #require(try held(made)).recorded(refused: "write:bookmarks")
        #expect(try made.tokens.update(noted))
        made.sessions.refresh()
        made.sessions.cameToFront()
        await made.sessions.leftSettled()
        #expect(count() == 1, "the same sign-in written again")

        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(try held(made)?.accessToken == "tok-2")
        #expect(count() == 2, "widened")

        await made.source.handBack("tok-2")
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(count() == 2, "the same sign-in handed back")

        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(count() == 3, "narrowed")

        let same = try #require(try held(made))
        try made.tokens.save(token(same.accessToken))
        made.sessions.refresh()
        #expect(count() == 3, "the same sign-in filed again from outside")

        try made.tokens.save(token("tok-pkg"))
        #expect(count() == 3, "nothing has looked yet")
        made.sessions.refresh()
        #expect(count() == 4, "replaced from outside")

        await made.source.says("tok-pkg", #"{"error":"The access token was revoked"}"#, status: 401)
        await made.sessions.learnWho(host: host)
        #expect(!made.sessions.isSignedIn(host: host))
        #expect(count() == 5, "ended by its source")

        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(count() == 6)
        await made.sessions.signOut(host: host)
        #expect(count() == 7, "signed out")
        made.sessions.refresh()
        #expect(count() == 7)
        #expect(made.sessions.changes["other.example"] == nil)
    }

    @Test("A sign-in an earlier build kept, with no mark of its filing, is not taken for another when this build first writes who it is beside it")
    func anEarlierBuildsSignInIsNotCounted() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.fileUnstamped(token("tok-old"))
        #expect(try tokens.token(host: host)?.stamp == nil)
        let made = fresh(tokens)
        let before = made.sessions.changes[host, default: 0]
        await made.sessions.verifyAll()
        made.sessions.refresh()
        #expect(try tokens.token(host: host)?.stamp != nil, "this build marks what it writes")
        #expect(made.sessions.handles[host] == named)
        #expect(made.sessions.changes[host, default: 0] == before)
        #expect(await made.source.checks == 1)
        await made.sessions.learnWhoAgain(among: [host], within: .seconds(5))
        #expect(await made.source.checks == 1, "and its reader is not asked for again")

        // Replaced from outside before this build has written anything beside it: another.
        let other = MemoryMastodonTokens()
        try other.fileUnstamped(token("tok-old"))
        let replaced = fresh(other)
        try other.save(token("tok-pkg"))
        replaced.sessions.refresh()
        #expect(replaced.sessions.changes[host, default: 0] == 1)
    }

    @Test("The count is a signal to draw again and nothing else: it is moved in one place, where the look at who is signed in finds another sign-in, and read only where a page decides whether it may be drawn — nothing is kept, ended, named or asked on it")
    func nothingDecidesOnTheCount() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let sources = root.appending(path: "Sources/FediqoUI")
        var named: [String: Int] = [:]
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) ?? .init()
        where file.pathExtension == "swift" {
            let text = codeLines(of: try String(contentsOf: file, encoding: .utf8)).joined(separator: "\n")
            let uses = text.components(separatedBy: "changes[").count - 1
            if uses > 0 { named[file.lastPathComponent] = uses }
        }
        #expect(named == ["MastodonSignIn.swift": 1, "ShellPerson.swift": 1])

        let signIn = try String(contentsOf: sources.appending(path: "Shell/MastodonSignIn.swift"), encoding: .utf8)
        let bump = try #require(codeLines(of: signIn).first { $0.contains("changes[") })
        #expect(bump.contains("changes[host, default: 0] += 1"))
        for word in ["if ", "guard ", "while ", "switch ", "?"] {
            #expect(!bump.contains(word))
        }
    }

    // MARK: - Kept only with the sign-in

    @Test("Who the reader is leaves with the sign-in: after a sign-out, a Clear or a Remove nothing on the device names the account — not the sign-in, not what it left, not the run — and the next run knows nobody there", arguments: [false, true])
    func itLeavesWithTheSignIn(forgettingApp: Bool) async throws {
        let made = fresh()
        #expect(await made.sessions.signIn(host: host, through: ReaderPage()) == nil)
        #expect(await made.sessions.signIn(host: host, through: ReaderPage(), writing: true) == nil)
        #expect(try made.tokens.left(host: host).map(\.accountID) == ["1"], "the one left says whose it was")

        await made.sessions.signOut(host: host, forgettingApp: forgettingApp)
        #expect(try held(made) == nil)
        #expect(try made.tokens.left(host: host).isEmpty)
        #expect(try made.tokens.leftHosts().isEmpty)
        #expect(made.sessions.handles.isEmpty)
        #expect(made.sessions.reader(host: host) == nil)
        if forgettingApp { #expect(try made.tokens.app(host: host) == nil) }

        // The very string filed again from outside is nobody's: nothing of the run remembers.
        try made.tokens.save(token("tok-2", scopes: MastodonOAuth.scopes(writing: true)))
        made.sessions.refresh()
        #expect(made.sessions.reader(host: host) == nil)
        #expect(made.sessions.handles[host] == nil)
        try made.tokens.forget(host: host)

        let next = fresh(made.tokens)
        await next.sessions.verifyAll()
        #expect(next.sessions.handles.isEmpty)
        #expect(next.sessions.reader(host: host) == nil)
        #expect(await next.source.sent.isEmpty)
    }

    @Test("No line this file logs names the reader: neither the id nor the handle is put into a log, and a sign-in prints as its host")
    func nothingLogsWhoTheReaderIs() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        for file in ["FediqoUI/Shell/MastodonSignIn.swift", "FediqoCore/MastodonWho.swift", "FediqoCore/MastodonAuth.swift"] {
            let text = try String(contentsOf: root.appending(path: "Sources/\(file)"), encoding: .utf8)
            for line in codeLines(of: text) where line.contains("NetLog") || line.contains("print(") {
                for word in ["handle", "accountID", "who.", ".id"] {
                    #expect(!line.contains(word), "\(file): \(line)")
                }
            }
        }
        let token = self.token("tok").named(accountID: "account-7", handle: "@secret@social.example")
        let printed = "\(token) \(String(reflecting: token)) \(MastodonLeft(token, as: .left))"
        #expect(!printed.contains("account-7"))
        #expect(!printed.contains("secret"))
    }

    // MARK: - What a person sees

    private func session(_ made: Made) async -> ShellSession {
        let session = ShellSession(http: made.source, store: ItemStore(), mastodon: made.sessions)
        session.work = SourceWork()
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        return session
    }

    @Test("A sign-in that only reads has the reader's own page as soon as it is made: the source row's menu gains \"Your page\" first, the source's page says who is signed in with the press beside it — and a sign-in whose source gave no handle of its own has neither")
    func aReadingSignInHasItsOwnPage() async throws {
        let made = fresh()
        let session = await session(made)
        func row() throws -> SourceRow { try #require(session.rows.first { $0.id == host }) }
        var opened: [DummyPerson] = []
        let account = AccountPane(session: session, onOwnPage: { opened.append($0) })
        let sheet = JoinSheet(session: session, onOwnPage: { opened.append($0) })
        let entryBefore = account.ownPage(try row()) != nil
        #expect(!entryBefore, "nobody is signed in")
        #expect(sheet.ownPage(at: host) == nil)

        #expect(await session.mastodon.signIn(host: host, through: ReaderPage()) == nil)
        #expect(session.mastodon.grants[host] == .reading)
        let me = try #require(ShellPersonPages.own(at: host, in: session))
        #expect(me.handle == named)
        #expect(ShellPersonPages.askedAs(at: host, in: session) == .reader(named))
        account.ownPage(try row())?()
        #expect(opened.map(\.handle) == [named])
        let line = OwnPageLine.words(try #require(sheet.ownPage(at: host)), language: .english)
        #expect(line == "Signed in as @reader@social.example.")
        #expect(SourceRow.ownPageLabel(host, language: .english) == "Your page at social.example")
        #expect(await made.source.checks == 1)

        // Another account, whose source names it as another server's: no page to open.
        await made.source.says("tok-2", #"{"id":"2","acct":"eve@other.example"}"#)
        #expect(await session.mastodon.signIn(host: host, through: ReaderPage()) == nil)
        #expect(ShellPersonPages.own(at: host, in: session) == nil)
        let entryAfter = account.ownPage(try row()) != nil
        #expect(!entryAfter)
        #expect(sheet.ownPage(at: host) == nil)
        #expect(ShellPersonPages.askedAs(at: host, in: session) == .reader(nil))
    }
}
