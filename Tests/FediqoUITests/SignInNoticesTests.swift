import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A server answering the sign-in by path and remembering what it was asked. `granting` is the
/// `scope` its token answer names, where it names one.
private actor NoticeServer: HTTPSender {
    private let granting: String?
    /// A scope this server does not know: a registration that asks for it is refused for its
    /// scopes.
    private let refuses: String?
    /// Where the first revoke waits before it is answered, so a test can act while it is out.
    private let revokeGate: Gate?
    /// Whether a revoke is waiting at the gate.
    private(set) var holding = false
    private var held = false
    private(set) var requests: [URLRequest] = []
    private var issued = 0

    init(granting: String? = nil, refuses: String? = nil, holdingRevoke revokeGate: Gate? = nil) {
        self.granting = granting
        self.refuses = refuses?.replacingOccurrences(of: ":", with: "%3A")
        self.revokeGate = revokeGate
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    /// The scopes each registration was made for, in order.
    var registered: [String] {
        requests.filter { $0.url?.path == "/api/v1/apps" }.map {
            let form = String(decoding: $0.httpBody ?? Data(), as: UTF8.self)
            let field = form.split(separator: "&").first { $0.hasPrefix("scopes=") }
            return String(field?.dropFirst("scopes=".count) ?? "").removingPercentEncoding ?? ""
        }
    }

    /// Which tokens this server was asked to forget, in order.
    var revoked: [String] {
        requests.filter { $0.url?.path == "/oauth/revoke" }.map {
            let form = String(decoding: $0.httpBody ?? Data(), as: UTF8.self)
            return form.split(separator: "&").first { $0.hasPrefix("token=") }
                .map { String($0.dropFirst("token=".count)) } ?? ""
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        func answer(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch url.path {
        case "/api/v1/apps":
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if let refuses, form.contains(refuses) {
                return answer(#"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#, 422)
            }
            return answer(#"{"client_id":"cid","client_secret":"csecret"}"#)
        case "/oauth/token":
            issued += 1
            let scope = granting.map { #","scope":"\#($0)""# } ?? ""
            return answer(#"{"access_token":"tok-\#(issued)"\#(scope)}"#)
        case "/api/v1/accounts/verify_credentials":
            return answer(#"{"id":"1","acct":"me"}"#)
        case "/oauth/revoke":
            if let revokeGate, !held {
                held = true
                holding = true
                await revokeGate.wait()
                holding = false
            }
            return answer("{}")
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The server's own page: approves with the state it was sent, or is closed by the reader.
@MainActor
private final class NoticePage: OAuthBrowser {
    private let closes: Bool
    private let gate: Gate?
    /// What each page asked the reader to agree to, in order.
    private(set) var scopes: [String] = []

    init(closes: Bool = false, gate: Gate? = nil) {
        self.closes = closes
        self.gate = gate
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        scopes.append(items.first { $0.name == "scope" }?.value ?? "")
        await gate?.wait()
        guard !closes else { throw MastodonSignInError.cancelled }
        let state = items.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

/// A token store whose look at who may read notices fails, though each token can still be read.
/// It counts the tokens it is asked to read.
private final class BlindToNotices: MastodonTokenStore, @unchecked Sendable {
    private let held: MemoryMastodonTokens
    private let blind = ForumCredentialError.keychain(-25_308)
    private(set) var reads = 0

    init(_ held: MemoryMastodonTokens) { self.held = held }

    func token(host: String) throws -> MastodonToken? {
        reads += 1
        return try held.token(host: host)
    }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func noticing() throws -> Set<String> { throw blind }
    func dismissing() throws -> Set<String> { throw blind }
    func noticesRefused() throws -> Set<String> { throw blind }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// A token store that cannot say who is signed in, though it answers who may read notices and
/// each token can still be read.
private final class BlindToGrants: MastodonTokenStore, @unchecked Sendable {
    private let held: MemoryMastodonTokens

    init(_ held: MemoryMastodonTokens) { self.held = held }

    func token(host: String) throws -> MastodonToken? { try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { throw ForumCredentialError.keychain(-25_308) }
    func noticing() throws -> Set<String> { try held.noticing() }
    func dismissing() throws -> Set<String> { try held.dismissing() }
    func noticesRefused() throws -> Set<String> { try held.noticesRefused() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// A token store that answers every look, counts the tokens it is asked to read, and whose
/// `save` of a token deletes the one held and then fails to add, for the first `failing` saves.
private final class WatchedTokens: MastodonTokenStore, @unchecked Sendable {
    private let held: MemoryMastodonTokens
    private var failing: Int
    private(set) var reads = 0

    init(_ held: MemoryMastodonTokens, failing: Int = 0) {
        self.held = held
        self.failing = failing
    }

    func token(host: String) throws -> MastodonToken? {
        reads += 1
        return try held.token(host: host)
    }
    func save(_ token: MastodonToken) throws {
        guard failing > 0 else { return try held.save(token) }
        failing -= 1
        try held.forget(host: token.host)
        throw ForumCredentialError.keychain(-25_308)
    }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func bookmarking() throws -> Set<String> { try held.bookmarking() }
    func bookmarksRefused() throws -> Set<String> { try held.bookmarksRefused() }
    func noticing() throws -> Set<String> { try held.noticing() }
    func dismissing() throws -> Set<String> { try held.dismissing() }
    func noticesRefused() throws -> Set<String> { try held.noticesRefused() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// What a sign-in asks for so notices can be read, and how one made before this stands (#323).
///
/// What a test can reach: the standing of each kind of earlier sign-in, the page and the
/// registration a sign-in asks on with and without notices, what is carried and what a sign-out
/// forgets, and a refusal. The question put before the page opens is the notices page's.
@MainActor
@Suite("A sign-in and the notices it may read")
struct SignInNoticesTests {
    private let host = "social.example"
    private static let reading = MastodonOAuth.reading
    /// What a sign-in to read and act was before bookmarks were asked for, and after.
    private static let before = MastodonOAuth.scopes(writing: true, bookmarks: false)
    private static let acting = MastodonOAuth.scopes(writing: true)

    private func sessions(
        holding scopes: String?? = .none, asked: String? = nil, app: String? = nil,
        server: NoticeServer = NoticeServer()
    ) throws -> (MastodonSessions, NoticeServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret",
                scopes: scopes, asked: asked
            ))
        }
        if let app {
            try tokens.save(MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: app))
        }
        return (MastodonSessions(tokens: tokens, sender: server), server, tokens)
    }

    @Test("A sign-in made before notices were asked for is one to be asked — for notices, and for nothing else")
    func anEarlierSignInIsToBeAskedAndNothingElseMoves() async throws {
        let earlier: [(String?, MastodonGrant, SourceWriting, BookmarkStanding)] = [
            (nil, .unasked, .reads, .unavailable),
            (Self.reading, .reading, .reads, .unavailable),
            (Self.before, .writing, .writes, .unasked),
            (Self.acting, .writing, .writes, .allowed),
        ]
        for (scopes, grant, writing, bookmarks) in earlier {
            let label = scopes ?? "nothing written down"
            let (mastodon, server, tokens) = try sessions(holding: .some(scopes), asked: scopes)

            #expect(mastodon.notices(host: host) == .unasked, "\(label)")
            #expect(!mastodon.dismisses(host: host), "\(label)")
            #expect(mastodon.noticeHosts.isEmpty && mastodon.dismissHosts.isEmpty && mastodon.noticesRefused.isEmpty)
            // Everything it did, it does.
            #expect(mastodon.isSignedIn(host: host), "\(label)")
            #expect(mastodon.grants == [host: grant], "\(label)")
            #expect(mastodon.writing(host: host, kind: .mastodon) == writing, "\(label)")
            #expect(mastodon.bookmarks(host: host) == bookmarks, "\(label)")
            #expect(mastodon.bookmarksRefused.isEmpty && mastodon.writeRefused.isEmpty)
            // And telling it apart asked nobody and wrote nothing.
            #expect(try tokens.token(host: host)?.scopes == scopes)
            #expect(await server.paths.isEmpty)
        }
    }

    @Test("Nobody signed in has no notices to ask for")
    func nobodySignedIn() throws {
        let (mastodon, _, _) = try sessions()
        #expect(mastodon.notices(host: host) == .unavailable)
        #expect(!mastodon.dismisses(host: host))
    }

    @Test("A sign-in asks for no notices unless told to: to read and to act, on a fresh source, the page is what it was")
    func notAskedUnasked() async throws {
        for writing in [false, true] {
            let (mastodon, server, tokens) = try sessions()
            let page = NoticePage()
            #expect(await mastodon.signIn(host: host, through: page, writing: writing) == nil)
            let asked = writing ? Self.acting : Self.reading
            #expect(page.scopes == [asked])
            #expect(await server.registered == [asked])
            #expect(try tokens.token(host: host)?.scopes == asked)
            #expect(mastodon.notices(host: host) == .unasked)
            #expect(!mastodon.dismisses(host: host))
        }
    }

    @Test("Asked for notices, a sign-in that reads may read them; one that acts may dismiss them too, and keeps everything it had")
    func askedInPlace() async throws {
        for (held, writing) in [(Self.reading, false), (Self.acting, true)] {
            // The registration the held sign-in was made on cannot ask for notices.
            let (mastodon, server, tokens) = try sessions(holding: .some(held), asked: held, app: held)
            let page = NoticePage()

            #expect(await mastodon.signIn(host: host, through: page, writing: writing, notices: true) == nil)

            let asked = MastodonOAuth.scopes(writing: writing, notices: true)
            #expect(page.scopes == [asked], "the page did not name notices")
            #expect(await server.registered == [asked], "a registration that cannot ask for notices was reused")
            #expect(try tokens.app(host: host)?.scopes == asked)
            #expect(try tokens.token(host: host)?.scopes == asked)
            #expect(try tokens.token(host: host)?.asked == asked)
            #expect(await server.revoked == ["tok-old"], "the sign-in it replaced is still live at the server")
            #expect(mastodon.notices(host: host) == .allowed)
            #expect(mastodon.dismisses(host: host) == writing, "dismissing is an act")
            #expect(mastodon.grants == [host: writing ? .writing : .reading])
            #expect(mastodon.writing(host: host, kind: .mastodon) == (writing ? .writes : .reads))
            #expect(mastodon.bookmarks(host: host) == (writing ? .allowed : .unavailable))
        }
    }

    @Test("Once allowed, a later sign-in on that source carries notices; a sign-out forgets them, and the next sign-in asks for none")
    func carriedWhileHeldAndForgottenWithASignOut() async throws {
        let (mastodon, server, tokens) = try sessions(holding: .some(Self.reading), asked: Self.reading)
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: false, notices: true) == nil)

        // Adding the acting part does not take notices away, and adds dismissing.
        let adding = NoticePage()
        #expect(await mastodon.signIn(host: host, through: adding, writing: true) == nil)
        #expect(adding.scopes == [MastodonOAuth.scopes(writing: true, notices: true)])
        #expect(mastodon.notices(host: host) == .allowed && mastodon.dismisses(host: host))
        #expect(mastodon.grants == [host: .writing])

        // Said outright, a sign-in may leave them out.
        let narrowing = NoticePage()
        #expect(await mastodon.signIn(host: host, through: narrowing, writing: true, notices: false) == nil)
        #expect(narrowing.scopes == [Self.acting])
        #expect(mastodon.notices(host: host) == .unasked && !mastodon.dismisses(host: host))

        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true, notices: true) == nil)
        await mastodon.signOut(host: host)
        #expect(mastodon.notices(host: host) == .unavailable)
        #expect(mastodon.noticeHosts.isEmpty && mastodon.dismissHosts.isEmpty)
        // The registration kept from before the sign-out was made for notices: it is not started on.
        #expect(try tokens.app(host: host)?.scopes == MastodonOAuth.scopes(writing: true, notices: true))
        let fresh = NoticePage()
        #expect(await mastodon.signIn(host: host, through: fresh, writing: true) == nil)
        #expect(fresh.scopes == [Self.acting], "a fresh sign-in asked for notices nobody pressed for")
        #expect(await server.registered.last == Self.acting)
        #expect(mastodon.notices(host: host) == .unasked)
    }

    /// The registration the held sign-in was made on, as a test can tell it from one made since.
    private var heldApp: MastodonApp {
        MastodonApp(host: host, clientID: "cid-held", clientSecret: "csecret-held", scopes: Self.acting)
    }

    @Test("A page closed leaves the sign-in held as it was, registration and all, and it may be asked again")
    func aClosedPageTakesNothing() async throws {
        let (mastodon, server, tokens) = try sessions(holding: .some(Self.acting), asked: Self.acting)
        try tokens.save(heldApp)
        let page = NoticePage(closes: true)

        #expect(await mastodon.signIn(host: host, through: page, writing: true, notices: true) == nil)

        #expect(page.scopes == [MastodonOAuth.scopes(writing: true, notices: true)])
        #expect(try tokens.token(host: host)?.accessToken == "tok-old")
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.app(host: host) == heldApp, "the reader was left with a registration made for notices")
        #expect(mastodon.notices(host: host) == .unasked, "a page closed is not the source's answer")
        #expect(mastodon.grants == [host: .writing])
        #expect(mastodon.writing(host: host, kind: .mastodon) == .writes)
        #expect(mastodon.bookmarks(host: host) == .allowed)

        // And the next ordinary sign-in starts on the registration it had, registering nothing.
        let registered = await server.registered.count
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true) == nil)
        #expect(await server.registered.count == registered)
    }

    @Test("A server that knows no such scope leaves the sign-in held as it was, opens no page, is said to have none, and is not asked again")
    func aServerWithoutNotices() async throws {
        let (mastodon, server, tokens) = try sessions(
            holding: .some(Self.acting), asked: Self.acting, server: NoticeServer(refuses: MastodonOAuth.noticing)
        )
        try tokens.save(heldApp)
        let page = NoticePage()

        #expect(await mastodon.signIn(host: host, through: page, writing: true, notices: true) == .invalidScope)

        let ladder = MastodonOAuth.ladder(writing: true, notices: true)
        #expect(await server.registered == ladder, "a rung was asked that the ladder does not have")
        #expect(page.scopes.isEmpty)
        #expect(try tokens.token(host: host)?.accessToken == "tok-old")
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.app(host: host) == heldApp)
        #expect(mastodon.grants == [host: .writing])
        #expect(mastodon.writing(host: host, kind: .mastodon) == .writes)
        #expect(mastodon.bookmarks(host: host) == .allowed)
        #expect(mastodon.notices(host: host) == .unavailable)

        // A second press sends nothing: no registration, no page.
        let asked = await server.paths.count
        #expect(await mastodon.signIn(host: host, through: page, writing: true, notices: true) == .invalidScope)
        #expect(await server.paths.count == asked, "a source that has answered was asked again")
        #expect(page.scopes.isEmpty)
        #expect(try tokens.app(host: host) == heldApp)

        // An ordinary sign-in is a fresh answer, asks for no notices, and they may be asked again.
        let again = NoticePage()
        #expect(await mastodon.signIn(host: host, through: again, writing: true) == nil)
        #expect(again.scopes == [Self.acting])
        #expect(mastodon.notices(host: host) == .unasked)
    }

    @Test("A sign-out clears a refused ask with everything else of the sign-in")
    func aSignOutForgetsARefusedAsk() async throws {
        let (mastodon, _, _) = try sessions(
            holding: .some(Self.reading), asked: Self.reading, server: NoticeServer(refuses: MastodonOAuth.noticing)
        )
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: false, notices: true) == .invalidScope)
        #expect(mastodon.noticesTurnedAway == [host])
        await mastodon.signOut(host: host)
        #expect(mastodon.noticesTurnedAway.isEmpty)
    }

    @Test("A sign-in whose notices were refused carries none into the next ordinary sign-in, and the refusal goes with the sign-in it answered")
    func aRefusalIsNotCarried() async throws {
        let (mastodon, server, tokens) = try sessions(
            holding: .some(Self.acting), asked: Self.acting, server: NoticeServer(granting: Self.acting)
        )
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true, notices: true) == nil)
        #expect(mastodon.notices(host: host) == .unavailable)

        // While that sign-in is held, a press sends nothing.
        let asked = await server.paths.count
        let pressed = NoticePage()
        #expect(await mastodon.signIn(host: host, through: pressed, writing: true, notices: true) == .invalidScope)
        #expect(await server.paths.count == asked && pressed.scopes.isEmpty)

        // The next ordinary sign-in asks for what the reader agreed to and no more.
        let page = NoticePage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)
        #expect(page.scopes == [Self.acting], "notices were asked for with nobody pressing")
        #expect(try tokens.token(host: host)?.asked == Self.acting)
        #expect(mastodon.noticesRefused.isEmpty)
        #expect(mastodon.notices(host: host) == .unasked)
    }

    @Test("A sign-in that carried notices and was refused for the writing part says nothing about notices: the one held still reads them")
    func aCarriedSignInRefusedIsNotARefusalOfNotices() async throws {
        let reads = MastodonOAuth.scopes(writing: false, notices: true)
        let (mastodon, server, tokens) = try sessions(
            holding: .some(reads), asked: reads, app: reads, server: NoticeServer(refuses: "write:statuses")
        )
        #expect(mastodon.notices(host: host) == .allowed)
        let page = NoticePage()

        // Adding the acting part, on a server that will not have it: every rung is refused.
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == .invalidScope)

        #expect(await server.registered == MastodonOAuth.ladder(writing: true, notices: true))
        #expect(page.scopes.isEmpty)
        #expect(try tokens.token(host: host)?.accessToken == "tok-old")
        #expect(try tokens.token(host: host)?.scopes == reads)
        #expect(await server.revoked.isEmpty)
        #expect(mastodon.noticesTurnedAway.isEmpty, "a refusal of the writing part was laid on notices")
        #expect(mastodon.notices(host: host) == .allowed)
        #expect(mastodon.grants == [host: .reading])
    }

    @Test("A registration another sign-in made while the notices page was open is not written over when that page is closed")
    func anotherSignInsRegistrationIsLeft() async throws {
        let (mastodon, server, tokens) = try sessions(holding: .some(Self.acting), asked: Self.acting)
        try tokens.save(heldApp)
        let gate = Gate()
        let page = NoticePage(closes: true, gate: gate)

        let pressing = Task { await mastodon.signIn(host: host, through: page, writing: true, notices: true) }
        #expect(await spun { page.scopes.count == 1 })
        // The notices page is up; an ordinary sign-in on the same source finishes meanwhile.
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true) == nil)
        let made = try #require(try tokens.app(host: host))
        #expect(made.scopes == Self.acting && made != heldApp)
        await gate.open()
        #expect(await pressing.value == nil)

        #expect(try tokens.app(host: host) == made, "the older registration was put over the newer one")
        #expect(try tokens.token(host: host)?.accessToken == "tok-1")
        #expect(await server.revoked == ["tok-old"])
        #expect(mastodon.notices(host: host) == .unasked)
    }

    @Test("Where the new sign-in cannot be kept, the one held is put back on the registration it was made on")
    func aSignInThatCannotBeKept() async throws {
        let held = MemoryMastodonTokens()
        try held.save(MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid-held", clientSecret: "csecret-held",
            scopes: Self.acting, asked: Self.acting
        ))
        try held.save(heldApp)
        let server = NoticeServer()
        let mastodon = MastodonSessions(tokens: WatchedTokens(held, failing: 1), sender: server)

        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true, notices: true) == .keychain)

        #expect(try held.token(host: host)?.accessToken == "tok-old")
        #expect(try held.app(host: host) == heldApp, "the sign-in put back stands beside a registration made for notices")
        #expect(await server.revoked == ["tok-1"])
        #expect(mastodon.notices(host: host) == .unasked, "a Keychain that failed is not the source's answer")
        #expect(mastodon.grants == [host: .writing] && mastodon.bookmarks(host: host) == .allowed)
    }

    @Test("An ordinary sign-in reads no token before the server's page opens, where the look at notices could be had")
    func noTokenIsReadBeforeThePage() async throws {
        for holding in [nil, Self.acting, MastodonOAuth.scopes(writing: true, notices: true)] as [String?] {
            let held = MemoryMastodonTokens()
            if let holding {
                try held.save(MastodonToken(
                    host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret", scopes: holding
                ))
            }
            let tokens = WatchedTokens(held)
            let mastodon = MastodonSessions(tokens: tokens, sender: NoticeServer())
            let gate = Gate()
            let page = NoticePage(gate: gate)

            let pressing = Task { await mastodon.signIn(host: host, through: page, writing: true) }
            #expect(await spun { page.scopes.count == 1 })
            #expect(tokens.reads == 0, "a token was read before the page opened, holding \(holding ?? "nothing")")
            #expect(page.scopes == [MastodonOAuth.scopes(writing: true, notices: MastodonOAuth.notices(holding))])
            await gate.open()
            #expect(await pressing.value == nil)
        }
    }

    @Test("Where who is signed in could not be read, an answer about notices is not taken for a no: the next sign-in reads the sign-in held and carries them")
    func carriedThoughWhoIsSignedInWasNotRead() async throws {
        let allowed = MastodonOAuth.scopes(writing: false, notices: true)
        let held = MemoryMastodonTokens()
        try held.save(MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret", scopes: allowed, asked: allowed
        ))
        let mastodon = MastodonSessions(tokens: BlindToGrants(held), sender: NoticeServer())
        #expect(mastodon.noticeHosts.isEmpty && mastodon.grants.isEmpty)

        let page = NoticePage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(page.scopes == [MastodonOAuth.scopes(writing: true, notices: true)], "notices were dropped unasked")
        #expect(try held.token(host: host)?.scopes == MastodonOAuth.scopes(writing: true, notices: true))
    }

    @Test("A sign-in started while the server is still being asked to forget the old token carries what the new one holds")
    func carriedFromTheSignInJustKept() async throws {
        let allowed = MastodonOAuth.scopes(writing: true, notices: true)
        let gate = Gate()
        let server = NoticeServer(holdingRevoke: gate)
        let (mastodon, _, tokens) = try sessions(holding: .some(allowed), asked: allowed, server: server)

        // The reader leaves notices out; the new sign-in is kept, and the old one's revoke is out.
        let narrowing = Task { await mastodon.signIn(host: host, through: NoticePage(), writing: true, notices: false) }
        #expect(await spun { await server.holding })
        #expect(try tokens.token(host: host)?.scopes == Self.acting)

        let page = NoticePage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)
        #expect(page.scopes == [Self.acting], "it carried what the sign-in it replaced had held")

        await gate.open()
        #expect(await narrowing.value == nil)
        #expect(mastodon.notices(host: host) == .unasked)
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
    }

    @Test("Where the look at who may read notices failed, the next sign-in still carries them: it reads the sign-in held")
    func carriedThoughTheLookFailed() async throws {
        let allowed = MastodonOAuth.scopes(writing: false, notices: true)
        let held = MemoryMastodonTokens()
        try held.save(MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret", scopes: allowed, asked: allowed
        ))
        let mastodon = MastodonSessions(tokens: BlindToNotices(held), sender: NoticeServer())
        #expect(mastodon.noticeHosts.isEmpty && mastodon.grants == [host: .reading])

        let page = NoticePage()
        #expect(await mastodon.signIn(host: host, through: page, writing: true) == nil)

        #expect(page.scopes == [MastodonOAuth.scopes(writing: true, notices: true)], "notices were dropped unasked")
        #expect(try held.token(host: host)?.scopes == MastodonOAuth.scopes(writing: true, notices: true))
    }

    @Test("What the question before an ordinary sign-in is told it carries is what the sign-in carries, where the look failed too")
    func theQuestionIsToldWhatIsCarried() async throws {
        let allowed = MastodonOAuth.scopes(writing: false, notices: true)
        let held = MemoryMastodonTokens()
        try held.save(MastodonToken(
            host: host, accessToken: "tok-old", clientID: "cid", clientSecret: "csecret", scopes: allowed, asked: allowed
        ))
        let blind = MastodonSessions(tokens: BlindToNotices(held), sender: NoticeServer())
        #expect(blind.noticeHosts.isEmpty && blind.carriesNotices(host: host), "the question would say less than the page asks")
        #expect(blind.carriesNotices(host: host.uppercased()))
        #expect(!blind.carriesNotices(host: "elsewhere.example"))

        let (plain, _, _) = try sessions(holding: .some(Self.acting), asked: Self.acting)
        #expect(!plain.carriesNotices(host: host))
        let (nobody, _, _) = try sessions()
        #expect(!nobody.carriesNotices(host: host))
        // A sign-in whose notices were refused holds none, and carries none.
        let (refused, _, _) = try sessions(holding: .some(Self.acting), asked: MastodonOAuth.scopes(writing: true, notices: true))
        #expect(refused.notices(host: host) == .unavailable && !refused.carriesNotices(host: host))
    }

    @Test("A server that grants the sign-in and leaves notices out of its answer is not asked again, across a relaunch; everything else it granted stands")
    func aServerGrantingLess() async throws {
        let (mastodon, _, tokens) = try sessions(
            holding: .some(Self.acting), asked: Self.acting, server: NoticeServer(granting: Self.acting)
        )
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true, notices: true) == nil)
        #expect(try tokens.token(host: host)?.scopes == Self.acting)
        #expect(mastodon.notices(host: host) == .unavailable)
        #expect(!mastodon.dismisses(host: host))
        #expect(mastodon.grants == [host: .writing] && mastodon.bookmarks(host: host) == .allowed)

        let relaunched = MastodonSessions(tokens: tokens, sender: NoticeServer())
        #expect(relaunched.notices(host: host) == .unavailable)
        #expect(relaunched.noticesRefused == [host] && relaunched.bookmarksRefused.isEmpty)
    }

    @Test("A read of notices the source forbids is not asked there again this run, and the sign-in is not touched; a refusal about a sign-in since replaced is not laid on the one held")
    func turnedAwayThisRun() async throws {
        let allowed = MastodonOAuth.scopes(writing: true, notices: true)
        let (mastodon, _, tokens) = try sessions(holding: .some(allowed), asked: allowed)
        let held = try #require(try tokens.token(host: host))
        #expect(mastodon.notices(host: host) == .allowed)

        let earlier = MastodonToken(host: host, accessToken: "tok-gone", clientID: "cid", clientSecret: "csecret", scopes: allowed)
        mastodon.refusedNotices(host: host, sentWith: earlier)
        #expect(mastodon.notices(host: host) == .allowed)

        mastodon.refusedNotices(host: host.uppercased(), sentWith: held)
        #expect(mastodon.notices(host: host) == .unavailable)
        #expect(mastodon.noticesTurnedAway == [host])
        #expect(try tokens.token(host: host) == held, "one refusal rewrote what the sign-in holds")
        #expect(mastodon.grants == [host: .writing] && mastodon.bookmarks(host: host) == .allowed)
        #expect(MastodonSessions(tokens: tokens, sender: NoticeServer()).notices(host: host) == .allowed, "it was written down")

        // A sign-in is a fresh answer from the server.
        #expect(await mastodon.signIn(host: host, through: NoticePage(), writing: true) == nil)
        #expect(mastodon.noticesTurnedAway.isEmpty)
        #expect(mastodon.notices(host: host) == .allowed)
    }
}
