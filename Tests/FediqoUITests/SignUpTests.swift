import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A place a request or a page stops at, which says when something has got there.
private actor Door {
    private var arrivals = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        arrivals += 1
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func arrived() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// A Mastodon as far as making an account on its form goes: every answer after the form is
/// scripted, in the order they were found on a real server.
private actor SignUpServer: HTTPSender {
    static let unconfirmed = #"{"id":"7","acct":"new","state":{"functional":false,"confirmed":false,"approved":false,"error_code":"pending_confirmation","error":"x"}}"#
    static let unapproved = #"{"id":"7","acct":"new","state":{"functional":false,"confirmed":true,"approved":false,"error_code":"pending_approval","error":"x"}}"#
    static let works = #"{"id":"7","acct":"new","state":{"functional":true,"confirmed":true,"approved":true,"error_code":null,"error":null}}"#

    enum Answer: Sendable {
        case body(String, status: Int = 200)
        case dark
    }

    private var standings: [Answer]
    private let resend: Answer
    private let revoke: Answer
    /// Where the first read as the person waits.
    private var homeDoor: Door?
    /// Where the next look at the account's standing waits.
    private var standingGate: Door?
    private(set) var requests: [URLRequest] = []

    init(_ standings: [Answer], resend: Answer = .body("{}"), revoke: Answer = .body("{}"), holding gate: Door? = nil, holdingHome homeDoor: Door? = nil) {
        self.standings = standings
        self.resend = resend
        self.revoke = revoke
        self.homeDoor = homeDoor
        self.standingGate = gate
    }

    func paths(_ path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    var standingsAsked: Int { paths("/api/v1/accounts/verify_credentials").count }
    var revoked: Int { paths("/oauth/revoke").count }
    /// The tokens this host was asked to end, in order.
    var revokedTokens: [String] {
        paths("/oauth/revoke").compactMap { request in
            String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&")
                .first { $0.hasPrefix("token=") }.map { String($0.dropFirst("token=".count)) }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        func answered(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch url.path {
        case "/api/v1/apps":
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let field = form.split(separator: "&").first { $0.hasPrefix("scopes=") }
            let asked = String(field?.dropFirst("scopes=".count) ?? "").removingPercentEncoding ?? ""
            let named = asked.replacingOccurrences(of: "+", with: " ").split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
            return answered(#"{"client_id":"new-cid","client_secret":"new-secret","redirect_uri":"fediqo://oauth","scopes":[\#(named)]}"#)
        case "/oauth/token":
            return answered(#"{"access_token":"new-token"}"#)
        case "/oauth/revoke":
            switch revoke {
            case .body(let body, let status): return answered(body, status)
            case .dark: throw URLError(.notConnectedToInternet)
            }
        case "/api/v1/timelines/home":
            if let door = homeDoor {
                homeDoor = nil
                await door.wait()
            }
            return answered("[]")
        case "/api/v1/accounts/verify_credentials":
            // The usual check is never asked of a new account: only this one answers.
            guard url.query == "allow_nonfunctional=true" else { return answered("{}", 403) }
            if let gate = standingGate {
                standingGate = nil
                await gate.wait()
            }
            switch standings.isEmpty ? .dark : standings.removeFirst() {
            case .body(let body, let status): return answered(body, status)
            case .dark: throw URLError(.notConnectedToInternet)
            }
        case "/api/v1/emails/confirmations":
            switch resend {
            case .body(let body, let status): return answered(body, status)
            case .dark: throw URLError(.notConnectedToInternet)
            }
        default:
            return answered("", 404)
        }
    }
}

/// Memory, that can refuse a look or a keeping as a Keychain does.
private final class SignUpTokens: MastodonTokenStore, @unchecked Sendable {
    let held = MemoryMastodonTokens()
    var refusesReading = false
    var refusesSwap = false
    private static let refused = ForumCredentialError.keychain(-25_308)

    func token(host: String) throws -> MastodonToken? {
        if refusesReading { throw Self.refused }
        return try held.token(host: host)
    }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? { try held.forget(token, saidBySource: saidBySource) }
    func update(_ token: MastodonToken) throws -> Bool { try held.update(token) }
    func swap(expecting string: String?, with token: MastodonToken) throws -> Bool {
        if refusesSwap { throw Self.refused }
        return try held.swap(expecting: string, with: token)
    }
    func left(host: String) throws -> [MastodonLeft] { try held.left(host: host) }
    func leftHosts() throws -> Set<String> { try held.leftHosts() }
    func journal(_ entry: MastodonLeft) throws { try held.journal(entry) }
    func journalLost(_ token: MastodonToken, accountID: String?) throws { try held.journalLost(token, accountID: accountID) }
    func unjournal(_ entry: MastodonLeft) throws { try held.unjournal(entry) }
    func forgetLeft(host: String) throws { try held.forgetLeft(host: host) }
    func restoreLost(host: String) throws -> Bool { try held.restoreLost(host: host) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func parts() throws -> [String: MastodonHeld] { try held.parts() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// The host's form: sent, or closed, or a page that waits at a gate first.
@MainActor
private final class Form: OAuthBrowser {
    private let closes: Bool
    private let gate: Door?
    private(set) var opened: [URL] = []

    init(closes: Bool = false, gate: Door? = nil) {
        self.closes = closes
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        opened.append(url)
        await gate?.wait()
        if closes { throw MastodonSignInError.cancelled }
        let state = Self.query(url, "state") ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// #435: making an account from the add-source flow, driven with the host's form as a fixture.
@MainActor
@Suite("Making an account at a Mastodon from adding a source", .serialized, .watched)
struct SignUpTests {
    private static let host = "social.example"
    private static let open = MastodonSignUp(open: true)
    private static let closed = MastodonSignUp(open: false)

    init() {
        L10n.language = .english
    }

    private static func preview(_ terms: MastodonSignUp? = open) -> SourcePreview {
        SourcePreview(host: host, kind: .mastodon, profile: .stated(SourceProfile(host: host, kind: .mastodon, signUp: terms)))
    }

    private static let timeline = FixtureHTTP([
        "/api/v2/instance": .text(#"{"domain":"social.example","title":"S"}"#),
        "/api/v1/timelines/public": .text("[]"),
        "/api/v1/trends/statuses": .text("[]"),
    ])

    private func shell(_ server: SignUpServer, http: FixtureHTTP = Self.timeline) -> (ShellSession, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        return (shell(server, http: http, store: tokens), tokens)
    }

    private func shell(_ server: SignUpServer, http: FixtureHTTP = Self.timeline, store tokens: any MastodonTokenStore) -> ShellSession {
        let session = ShellSession(
            http: http, store: ItemStore(),
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.stage = .previewing(Self.preview(), from: .field, ticked: [])
        return session
    }

    /// The press, its question and an answer, as the page makes them.
    private func press(_ session: ShellSession, through form: Form, terms: MastodonSignUp = open, invitation: String = "") async {
        session.signUp.ask(Self.preview(terms), invitation: invitation, in: session)
        guard let ask = session.signUp.asked else { return }
        await session.signUp.answer(ask, writing: true, through: form, in: session)
    }

    /// Nothing of the host on this device: no row, no sign-in, no note, no registration.
    private func deviceUnchanged(_ session: ShellSession, _ tokens: MemoryMastodonTokens) throws {
        #expect(!session.isAdded(Self.host))
        #expect(!session.isSignedIn(host: Self.host))
        #expect(try tokens.token(host: Self.host) == nil)
        #expect(try tokens.app(host: Self.host) == nil)
        #expect(try tokens.left(host: Self.host).isEmpty)
    }

    // MARK: - Where it is offered

    @Test("It is offered only where a look said so, and nobody signed in there")
    func whereOffered() throws {
        let (session, tokens) = shell(SignUpServer([]))
        #expect(session.signUp.terms(for: Self.preview(), in: session) == Self.open)
        #expect(session.signUp.terms(for: Self.preview(nil), in: session) == nil)
        #expect(session.signUp.terms(for: SourcePreview(host: Self.host, kind: .mastodon, profile: .silent(host: Self.host, kind: .mastodon)), in: session) == nil)

        try tokens.save(MastodonToken(host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
        #expect(session.signUp.terms(for: Self.preview(), in: session) == nil)
    }

    @Test("A closed host draws the act only with an invitation that reads as one")
    func theClosedHost() {
        var said = SignUpOfferSaid(host: Self.host, terms: Self.closed)
        #expect(said.asksInvitation && !said.offersAct && said.lines().isEmpty)
        said.invitation = "a/b"
        #expect(!said.offersAct && said.invitationUnread && said.lines().count == 1)
        said.invitation = "https://social.example/invite/abc"
        #expect(said.offersAct && !said.invitationUnread && said.lines().isEmpty)

        let open = SignUpOfferSaid(host: Self.host, terms: MastodonSignUp(open: true, approvalRequired: true, minAge: 16))
        #expect(!open.asksInvitation && open.offersAct && open.lines().count == 2)
    }

    @Test("A press at a closed host without a good invitation puts no question, and with one the form carries its code")
    func theInvitationReachesTheForm() async {
        let (session, _) = shell(SignUpServer([.body(SignUpServer.unconfirmed)]))
        session.signUp.ask(Self.preview(Self.closed), invitation: "", in: session)
        #expect(session.signUp.asked == nil)
        session.signUp.ask(Self.preview(Self.closed), invitation: "../x", in: session)
        #expect(session.signUp.asked == nil)

        let form = Form()
        await press(session, through: form, terms: Self.closed, invitation: "https://social.example/invite/abc")
        #expect(Form.query(form.opened[0], "prompt") == "create")
        #expect(Form.query(form.opened[0], "invite_code") == "abc")
        session.signUp.leave(in: session)
    }

    @Test("An open host's form asks for no invitation, whatever was typed")
    func noInvitationWhereNoneIsAsked() async {
        let (session, _) = shell(SignUpServer([.body(SignUpServer.unconfirmed)]))
        let form = Form()
        await press(session, through: form, invitation: "abc")
        #expect(Form.query(form.opened[0], "invite_code") == nil)
        session.signUp.leave(in: session)
    }

    // MARK: - Stopping part way

    @Test("The form closed leaves the device as it was, says nothing at an open host, and keeps the preview")
    func closingTheForm() async throws {
        let (session, tokens) = shell(SignUpServer([]))
        await press(session, through: Form(closes: true))
        try deviceUnchanged(session, tokens)
        #expect(session.signUp.told == nil && session.signUp.mail == nil && !session.signUp.busy)
        #expect(session.stage?.inlinePreview?.host == Self.host)
    }

    @Test("The form closed at a closed host says the invitation may not have been taken")
    func closingAtAClosedHost() async throws {
        let (session, tokens) = shell(SignUpServer([]))
        await press(session, through: Form(closes: true), terms: Self.closed, invitation: "abc")
        try deviceUnchanged(session, tokens)
        #expect(session.signUp.told?.kind == .invitation)
    }

    @Test("An unconfirmed account puts up the mail step with nothing on the device, and a 403 on the usual check is never met")
    func theMailStep() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        #expect(session.signUp.mail?.host == Self.host)
        #expect(session.signUp.told == nil && session.signUp.busy)
        try deviceUnchanged(session, tokens)
        #expect(await server.standingsAsked == 1)
        session.signUp.leave(in: session)
    }

    @Test("Leaving the mail step drops the token, asks the host to end it, says how to come back, and writes nothing; leaving twice does it once")
    func leaving() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        let going = session.signUp.leave(in: session)
        #expect(session.signUp.leave(in: session) == nil, "the sheet going after its button is the same leaving")
        await going?.value
        #expect(session.signUp.mail == nil && !session.signUp.busy)
        #expect(session.signUp.told?.kind == .confirm)
        #expect(await server.revoked == 1)
        try deviceUnchanged(session, tokens)
    }

    @Test("Waiting for approval there is nothing to wait with: the token goes and the person is told")
    func approval() async throws {
        let server = SignUpServer([.body(SignUpServer.unapproved)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        #expect(session.signUp.mail == nil && session.signUp.told?.kind == .approval)
        try deviceUnchanged(session, tokens)
    }

    @Test("A host that will not say how the account stands is told as made, and nothing is kept")
    func unsaid() async throws {
        let (session, tokens) = shell(SignUpServer([.body("{}", status: 403)]))
        await press(session, through: Form())
        #expect(session.signUp.mail == nil && session.signUp.told?.kind == .confirm)
        try deviceUnchanged(session, tokens)
    }

    @Test("A form whose trade fails says so, and that an account may stand there")
    func theTradeFails() async throws {
        let (session, tokens) = shell(SignUpServer([]))
        let gone = StateChecked()
        await session.signUp.answer(
            ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil), writing: false, through: gone, in: session
        )
        #expect(session.signUp.told?.kind == .failed && !session.signUp.busy)
        try deviceUnchanged(session, tokens)
    }

    /// A form answering with another attempt's state.
    @MainActor
    private final class StateChecked: OAuthBrowser {
        func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
            URL(string: "fediqo://oauth?code=c&state=another")!
        }
    }

    // MARK: - On to signed in

    @Test("Functional at once, it ends signed in as any source added: the row, the token named, the registration filed, the preview gone")
    func functionalAtOnce() async throws {
        let server = SignUpServer([.body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        #expect(session.isAdded(Self.host) && session.isSignedIn(host: Self.host))
        #expect(session.stage == nil && session.signUp.mail == nil && !session.signUp.busy)
        let held = try #require(try tokens.token(host: Self.host))
        #expect(held.accessToken == "new-token" && held.accountID == "7" && held.handle?.contains("new") == true)
        #expect(try tokens.app(host: Self.host)?.clientID == "new-cid")
        #expect(try tokens.left(host: Self.host).isEmpty)
        #expect(await server.revoked == 0)
        #expect(session.progress == nil)
        let home = await server.paths("/api/v1/timelines/home")
        #expect(home.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token", "read as the person at once")
    }

    @Test("Confirmed while the mail step is up, a press ends signed in; until then a press says it still waits")
    func confirmedByAPress() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.unconfirmed), .body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        await session.signUp.check(in: session)
        #expect(session.signUp.mail?.note == .stillWaiting)
        try deviceUnchanged(session, tokens)
        await session.signUp.check(in: session)
        #expect(session.signUp.mail == nil && session.isAdded(Self.host) && session.isSignedIn(host: Self.host))
    }

    @Test("The dark while reading leaves the step up and says so; a token the host no longer knows ends it")
    func readingFails() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .dark, .body("", status: 401), .body(#"{"error":"The access token was revoked"}"#, status: 401)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        await session.signUp.check(in: session)
        #expect(session.signUp.mail?.note == .unreachable && session.signUp.mail?.reading == false)
        await session.signUp.check(in: session)
        #expect(session.signUp.mail?.note == .unreachable, "a bare 401 is something in front of the source")
        await session.signUp.check(in: session)
        #expect(session.signUp.mail == nil && session.signUp.told?.kind == .gone)
        try deviceUnchanged(session, tokens)
    }

    @Test("Either answer's form asks the word a real server wants for the mail again, and reading alone no word that acts besides; the question says so")
    func theWordsOfTheForm() async throws {
        for (writing, words) in [
            (false, "read:statuses read:lists read:accounts read:search write:accounts"),
            (true, "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks write:accounts"),
        ] {
            let (session, _) = shell(SignUpServer([.body(SignUpServer.unconfirmed)]))
            let form = Form()
            session.signUp.ask(Self.preview(), invitation: "", in: session)
            let ask = try #require(session.signUp.asked)
            await session.signUp.answer(ask, writing: writing, through: form, in: session)
            let page = try #require(form.opened.first)
            let scope = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
            #expect(scope == words)
            session.signUp.leave(in: session)
        }
        #expect(ShellQuestion.signUp(host: Self.host, language: .english).line.contains("change your profile"))
    }

    @Test("Asking for the mail again says it was asked; a refusal says so and reads how the account stands")
    func resending() async throws {
        let sent = SignUpServer([.body(SignUpServer.unconfirmed)])
        let (session, _) = shell(sent)
        await press(session, through: Form())
        await session.signUp.resend(in: session)
        #expect(session.signUp.mail?.note == .resent && session.signUp.mail?.resending == false)
        #expect(await sent.paths("/api/v1/emails/confirmations").first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        session.signUp.leave(in: session)

        let waiting = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.unconfirmed), .dark], resend: .body("{}", status: 429))
        let (stood, _) = shell(waiting)
        await press(stood, through: Form())
        await stood.signUp.resend(in: stood)
        #expect(stood.signUp.mail?.note == .resendFailed && stood.signUp.mail?.reading == false, "the refusal stays, past the read after it")
        await stood.signUp.resend(in: stood)
        #expect(stood.signUp.mail?.note == .resendFailed, "and past a read that finds the dark")
        stood.signUp.leave(in: stood)

        let refused = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.works)], resend: .body("{}", status: 403))
        let (confirmed, _) = shell(refused)
        await press(confirmed, through: Form())
        await confirmed.signUp.resend(in: confirmed)
        #expect(confirmed.isSignedIn(host: Self.host), "a 403 is an account confirmed since")
    }

    @Test("A source that cannot be added after all leaves no token, and the person is told")
    func notAdded() async throws {
        let server = SignUpServer([.body(SignUpServer.works)])
        let (session, tokens) = shell(server, http: FixtureHTTP([:]))
        await press(session, through: Form())
        try deviceUnchanged(session, tokens)
        #expect(session.signUp.told?.kind == .notAdded)
        #expect(await server.revoked == 1)
    }

    // MARK: - Two at once

    @Test("A second press while a form is up opens no second form")
    func twoPresses() async {
        let gate = Door()
        let form = Form(closes: true, gate: gate)
        let (session, _) = shell(SignUpServer([]))
        let ask = ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil)
        let first = Task { await session.signUp.answer(ask, writing: false, through: form, in: session) }
        await gate.arrived()
        await session.signUp.answer(ask, writing: true, through: form, in: session)
        session.signUp.ask(Self.preview(), invitation: "", in: session)
        #expect(session.signUp.asked == nil, "no question while one is up")
        #expect(form.opened.count == 1)
        await gate.open()
        await first.value
        #expect(!session.signUp.busy)
    }

    @Test("Two looks at once are one ask")
    func twoChecks() async {
        let gate = Door()
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.unconfirmed)])
        let (session, _) = shell(server)
        await press(session, through: Form())
        await server.hold(gate)
        let first = Task { await session.signUp.check(in: session) }
        await gate.arrived()
        await session.signUp.check(in: session)
        #expect(await server.standingsAsked == 2, "the first after the form, and this one")
        await gate.open()
        await first.value
        session.signUp.leave(in: session)
    }

    @Test("An answer that comes after the person left lands nowhere, a working account included")
    func leftWhileReading() async throws {
        let gate = Door()
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        await server.hold(gate)
        let reading = Task { await session.signUp.check(in: session) }
        await gate.arrived()
        let going = session.signUp.leave(in: session)
        await gate.open()
        await reading.value
        await going?.value
        #expect(session.signUp.told?.kind == .confirm && session.signUp.mail == nil)
        try deviceUnchanged(session, tokens)
    }

    @Test("The host let go of while the step stood takes the attempt with it: nothing is kept and the step goes")
    func letGoWhileUp() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        await session.mastodon.signOut(host: Self.host)
        await session.signUp.check(in: session)
        #expect(session.signUp.mail == nil && !session.signUp.busy)
        try deviceUnchanged(session, tokens)
    }

    @Test("A sign-in filed at the host while the step stood is neither replaced nor ended, and the row says so")
    func anotherFiled() async throws {
        let server = SignUpServer([.body(SignUpServer.unconfirmed), .body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        await press(session, through: Form())
        try tokens.save(MastodonToken(host: Self.host, accessToken: "other", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
        await session.signUp.check(in: session)
        #expect(try tokens.token(host: Self.host)?.accessToken == "other")
        #expect(await server.revokedTokens == ["new-token"], "the one filed is not ended, and this one is")
        #expect(session.isAdded(Self.host))
        #expect(session.rowRefusal?.key == "account.signin.replaced")
    }

    @Test("A source subscribed to while the form was up is not added twice, and is signed in")
    func subscribedMeanwhile() async throws {
        let gate = Door()
        let form = Form(gate: gate)
        let (session, _) = shell(SignUpServer([.body(SignUpServer.works)]))
        let ask = ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil)
        let answering = Task { await session.signUp.answer(ask, writing: false, through: form, in: session) }
        await gate.arrived()
        await session.confirm()
        #expect(session.isAdded(Self.host))
        await gate.open()
        await answering.value
        #expect(session.isSignedIn(host: Self.host) && session.sources.count == 1)
    }

    // MARK: - What it says and how it is laid out

    @Test("A new look puts down what the last attempt told")
    func aNewLook() async {
        let (session, _) = shell(SignUpServer([.body(SignUpServer.unapproved)]))
        await press(session, through: Form())
        #expect(session.signUp.told != nil)
        session.stage = nil
        session.hostname = "not a host"
        await session.add()
        #expect(session.signUp.told == nil)
    }

    /// Every line of a table about this, by key.
    private func table(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appending(path: "Sources/FediqoUI/Resources/\(language).lproj/Localizable.strings")
        var lines: [String: String] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") where line.hasPrefix("\"account.signup.") {
            let parts = line.components(separatedBy: "\" = \"")
            lines[String(parts[0].dropFirst())] = parts.count == 2 ? parts[1] : nil
        }
        return lines
    }

    @Test("Every key is in every table with the same placeholders, in Chinese in zh-Hant and zh-TW alike, and each is one this code says")
    func theWords() throws {
        func places(_ text: String) -> [String] { text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted() }
        let english = try table("en")
        #expect(english.count == 28)
        for language in ["zh-Hant", "zh-TW"] {
            let chinese = try table(language)
            #expect(Set(chinese.keys) == Set(english.keys), "\(language)")
            for (key, written) in english {
                let other = try #require(chinese[key], "\(language) \(key)")
                #expect(other != written && places(other) == places(written), "\(language) \(key)")
            }
        }
        #expect(try table("zh-Hant") == table("zh-TW"))

        var said: Set<String> = []
        for language in [DummyLanguage.english, .taiwanese] {
            let kinds: [ShellSignUp.Told.Kind] = [.confirm, .approval, .invitation, .failed, .gone, .notAdded]
            for kind in kinds {
                let words = ShellSignUp.Told(kind: kind, host: Self.host).words(language: language)
                #expect(words.contains(Self.host) && !words.contains("account.signup"), "\(kind)")
                said.insert("account.signup.told.\(kind.rawValue)")
            }
            for (note, key) in [
                (ShellSignUp.Mail.Note.stillWaiting, "waiting"), (.unreachable, "unreachable"), (.resent, "resent"), (.resendFailed, "resendFailed"),
            ] {
                #expect(ShellSignUp.Mail(host: Self.host, note: note).noteWords(language: language)?.contains(Self.host) == true)
                said.insert("account.signup.mail.note.\(key)")
            }
            let mail = ShellSignUp.Mail(host: Self.host)
            #expect(mail.lines(language: language).count == 4 && mail.lines(language: language).allSatisfy { $0.contains(Self.host) })
            #expect(mail.heldLine(language: language).contains(Self.host))
            let offer = SignUpOfferSaid(host: Self.host, terms: MastodonSignUp(open: false, approvalRequired: true, minAge: 16), invitation: "?")
            for line in offer.lines(language: language) + [offer.act(language: language), offer.help(language: language)] {
                #expect(line.contains(Self.host), "\(line)")
            }
            #expect(offer.lines(language: language).contains { $0.contains("16") })
            let question = ShellQuestion.signUp(host: Self.host, language: language)
            #expect(question.title.contains(Self.host))
            #expect(question.choices.map(\.id) == [ShellQuestion.signInRead, ShellQuestion.signInWrite])
        }
        // Said by name in the code: the keys the loops above do not build.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code = ""
        for name in ["ShellSignUp", "SignUpViews", "ShellSession"] {
            code += try String(contentsOf: root.appending(path: "Sources/FediqoUI/Shell/\(name).swift"), encoding: .utf8)
        }
        for key in english.keys where !said.contains(key) {
            #expect(code.contains("\"\(key)\""), "\(key) is said by nothing")
        }
    }

    @Test("Refused or unanswered, a token let go of is asked about once and told of nowhere, whatever the Keychain says")
    func theQuietEnding() async throws {
        for revoke in [SignUpServer.Answer.body("{}", status: 500), .dark, .body(#"{"error":"unauthorized_client"}"#, status: 403)] {
            let server = SignUpServer([.body(SignUpServer.unconfirmed)], revoke: revoke)
            let tokens = SignUpTokens()
            let session = shell(server, store: tokens)
            await press(session, through: Form())
            tokens.refusesReading = true
            await session.signUp.leave(in: session)?.value
            tokens.refusesReading = false
            #expect(await server.revoked == 1)
            #expect(session.mastodon.leftTold.isEmpty)
            await session.mastodon.settleLeft()
            #expect(await server.revoked == 1, "kept to ask again by nothing")
            #expect(try tokens.left(host: Self.host).isEmpty && tokens.app(host: Self.host) == nil)
        }
    }

    @Test("A sign-in that cannot be kept leaves the source added and signed out, the keychain's sentence under its row, and the token ended")
    func keepFails() async throws {
        let server = SignUpServer([.body(SignUpServer.works)])
        let tokens = SignUpTokens()
        tokens.refusesSwap = true
        let session = shell(server, store: tokens)
        await press(session, through: Form())
        #expect(session.isAdded(Self.host) && !session.isSignedIn(host: Self.host))
        #expect(session.rowRefusal?.key == ShellSession.signInFailureKey(.keychain))
        #expect(await server.revokedTokens == ["new-token"])
        #expect(try tokens.token(host: Self.host) == nil && tokens.app(host: Self.host) == nil)
        #expect(!session.signUp.busy)
    }

    @Test("A sheet of the page's own stage goes when the mail step rises")
    func theStageSheetGoes() async {
        let (session, _) = shell(SignUpServer([.body(SignUpServer.unconfirmed)]))
        session.stage = .browsing
        await press(session, through: Form())
        #expect(session.signUp.mail != nil && session.stage == nil)
        session.signUp.leave(in: session)
    }

    @Test("Whatever sheet stands, a held attempt is never without its step: from the moment of the trade, with its way out")
    func neverInvisible() async throws {
        let door = Door()
        let server = SignUpServer([.body(SignUpServer.unconfirmed)], holding: door)
        let (session, tokens) = shell(server)
        #expect(session.signUp.heldStep == nil)
        let ask = ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil)
        let answering = Task { await session.signUp.answer(ask, writing: false, through: Form(), in: session) }
        await door.arrived()
        #expect(session.signUp.mail == nil && session.signUp.heldStep?.reading == true && session.signUp.heldStep?.host == Self.host)
        let going = session.signUp.leave(in: session)
        #expect(session.signUp.heldStep == nil)
        await door.open()
        await answering.value
        await going?.value
        #expect(session.signUp.mail == nil && !session.signUp.busy && session.signUp.told?.kind == .confirm)
        try deviceUnchanged(session, tokens)

        let (up, _) = shell(SignUpServer([.body(SignUpServer.unconfirmed)]))
        await press(up, through: Form())
        #expect(up.signUp.heldStep == up.signUp.mail && up.signUp.heldStep != nil)
        up.signUp.leave(in: up)
        #expect(up.signUp.heldStep == nil)
    }

    @Test("Signed out while the form was up, what comes back is ended and nothing is kept or said")
    func signedOutOnTheForm() async throws {
        let door = Door()
        let server = SignUpServer([.body(SignUpServer.works)])
        let (session, tokens) = shell(server)
        let ask = ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil)
        let answering = Task { await session.signUp.answer(ask, writing: false, through: Form(gate: door), in: session) }
        await door.arrived()
        await session.mastodon.signOut(host: Self.host)
        await door.open()
        await answering.value
        #expect(!session.signUp.busy && session.signUp.mail == nil && session.signUp.told == nil)
        #expect(await server.revoked == 1)
        try deviceUnchanged(session, tokens)
    }

    @Test("It stays the one attempt until the keeping and the first read are done")
    func oneUntilDone() async {
        let door = Door()
        let (session, _) = shell(SignUpServer([.body(SignUpServer.works)], holdingHome: door))
        let ask = ShellSignUp.Ask(preview: Self.preview(), terms: Self.open, invite: nil)
        let answering = Task { await session.signUp.answer(ask, writing: false, through: Form(), in: session) }
        await door.arrived()
        #expect(session.signUp.busy && session.isSignedIn(host: Self.host))
        #expect(session.signUp.heldStep == nil, "nothing is left to leave")
        await door.open()
        await answering.value
        #expect(!session.signUp.busy)
    }

    private func width(_ view: some View, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
        let hosted = NSHostingView(rootView: VStack(spacing: 0) { view }.frame(width: width).environment(\.colorScheme, scheme))
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize
    }

    @Test("The offer is laid out to the width it is given, light and dark, at a closed host growing by its act only once an invitation reads")
    func theOfferLaidOut() {
        let long = "a-rather-long-name-of-a-server.example"
        for (at, scheme) in [(CGFloat(720), ColorScheme.light), (720, .dark), (320, .light), (320, .dark)] {
            func drawn(_ terms: MastodonSignUp, _ typed: String = "") -> CGSize {
                width(SignUpOffer(said: SignUpOfferSaid(host: long, terms: terms, invitation: typed), invitation: .constant(typed)), at, scheme)
            }
            let waiting = drawn(Self.closed)
            let invited = drawn(Self.closed, "abc")
            #expect(waiting.width == at && invited.width == at)
            #expect(invited.height > waiting.height)
            let told = drawn(MastodonSignUp(open: true, approvalRequired: true, minAge: 16))
            #expect(told.width == at && told.height > drawn(Self.open).height)
        }
    }

    @Test("The mail step is laid out to the width it is given, light and dark, and grows by a note")
    func theMailStepLaidOut() {
        for (at, scheme) in [(CGFloat(720), ColorScheme.light), (720, .dark), (320, .light), (320, .dark)] {
            let plain = width(SignUpMailSheet(said: ShellSignUp.Mail(host: "a-rather-long-name-of-a-server.example")), at, scheme)
            let noted = width(SignUpMailSheet(said: ShellSignUp.Mail(host: "a-rather-long-name-of-a-server.example", note: .stillWaiting)), at, scheme)
            #expect(plain.width == at && noted.width == at)
            #expect(noted.height > plain.height)
        }
    }

    @Test("The line a held attempt stands as is laid out to the width it is given, light and dark, and grows by a note")
    func theHeldLineLaidOut() {
        for (at, scheme) in [(CGFloat(720), ColorScheme.light), (720, .dark), (320, .light), (320, .dark)] {
            let plain = width(SignUpHeldLine(said: ShellSignUp.Mail(host: Self.host)), at, scheme)
            let noted = width(SignUpHeldLine(said: ShellSignUp.Mail(host: Self.host, note: .unreachable)), at, scheme)
            #expect(plain.width == at && noted.width == at && noted.height > plain.height)
        }
    }

    @Test("What an attempt told is laid out to the width it is given, light and dark, and wraps where narrow")
    func theToldLaidOut() {
        let told = ShellSignUp.Told(kind: .approval, host: Self.host)
        for scheme in [ColorScheme.light, .dark] {
            let wide = width(SignUpToldLine(told: told), 720, scheme)
            let narrow = width(SignUpToldLine(told: told), 320, scheme)
            #expect(wide.width == 720 && narrow.width == 320)
            #expect(narrow.height > wide.height)
        }
    }
}

extension SignUpServer {
    /// The next look at the account's standing waits at `gate`.
    func hold(_ gate: Door) {
        standingGate = gate
    }
}
