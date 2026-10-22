import Foundation
import Testing
@testable import FediqoCore

/// #347, #309: how a Mastodon widens a sign-in, held against the real one this checkout brings
/// up (`make servers`, Mastodon 4.6.6) **through its own pages** — the writer signed in at
/// `/auth/sign_in`, this app's own `signIn` opening `/oauth/authorize`, and the page's own
/// Authorize or Deny form sent back. Nothing is minted in the server. What the same server
/// answered once is kept in `MastodonSignInCaptures`.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Asked gently.** Two registrations a run — one in the check that asks what a registration
/// echoes, one in the check of the registration this app itself makes: this server takes five
/// in ten minutes from anywhere, and the other suites make two.
/// The one every sign-in here starts on is the seed's — made in the server, which holds it to
/// the scopes it knows as it does one made through its API. Every token made here is revoked
/// when its check ends, **however it ends** (`revokingWhatItMade`): a page is shown only where
/// no token of the words asked lives, so one left live would fail the next run.
@MainActor
@Suite("What a Mastodon says of widening a sign-in", .enabled(if: LocalServers.requested), .serialized)
struct MastodonSignInSaysTests {
    private typealias Captures = MastodonSignInCaptures

    private static let host = LocalServers.mastodon
    private static let refusedWords = "\(Captures.narrow) read:mutes write:mutes"

    private func signer() throws -> MastodonOAuth {
        MastodonOAuth(host: Self.host, sender: try LocalHTTP.client())
    }

    /// The seed's registration, asked for `scopes` of what it was registered for.
    private func app(asking scopes: String) throws -> MastodonApp {
        let registered = try #require(
            try LocalServers.seeded().signIn,
            "servers/.run/mastodon-tokens.json was seeded before this registration was: run `make servers` again"
        )
        return MastodonApp(host: Self.host, clientID: registered.id, clientSecret: registered.secret, scopes: scopes)
    }

    /// The tokens a check made, so that each is revoked when the check ends.
    private final class Made {
        private(set) var tokens: [MastodonToken] = []

        func keep(_ token: MastodonToken) -> MastodonToken {
            tokens.append(token)
            return token
        }
    }

    /// `check`, and then every token it made revoked — whether it returned or threw.
    private func revokingWhatItMade(_ oauth: MastodonOAuth, _ check: (Made) async throws -> Void) async throws {
        let made = Made()
        let thrown: (any Error)?
        do {
            try await check(made)
            thrown = nil
        } catch {
            thrown = error
        }
        for token in made.tokens { await oauth.revoke(MastodonLeft(token, as: .left)) }
        if let thrown { throw thrown }
    }

    /// One answer, whole: its status and its body as JSON where it is JSON.
    private struct Answer {
        let status: Int
        let response: HTTPURLResponse
        let body: Data

        var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var error: String? { object["error"] as? String }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    /// `path` asked with `token`, or as nobody where there is none — read, unless `method`
    /// says otherwise, when `form` is what is sent.
    private func ask(_ token: String?, _ path: String, _ method: String = "GET", form: String = "") async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if method != "GET" {
            request.httpMethod = method
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    private static let check = "/api/v1/accounts/verify_credentials"
    private static let standing = "/api/v1/accounts/relationships?id[]=1"
    private static let info = "/oauth/token/info"
    /// The name `servers/mastodon/seed.rb` gives the registration these sign-ins start on,
    /// which is what the person's list of authorised apps shows it under.
    private static let registrationName = "fediqo-servers-signin-ask"

    /// The scopes the server itself says a token holds.
    private func held(_ token: MastodonToken) async throws -> Set<String> {
        Set(try await ask(token.accessToken, Self.info).object["scope"] as? [String] ?? [])
    }

    private static func list(_ scopes: String) -> [String] {
        scopes.split(separator: " ").map(String.init)
    }

    private static func words(_ scopes: String) -> Set<String> {
        Set(scopes.split(separator: " ").map(String.init))
    }

    // MARK: - 1. Narrower, wider, the same again, and revoking

    @Test("A registration made for more opens a page that asks for less, and the token says it holds exactly what was asked; a wider page of the same registration is shown while the narrower token lives and both then work side by side; the same words asked again open no page and are answered with the very same token; revoking the wider leaves the narrower, revoking with a wrong secret takes nothing, and revoking the narrower signs out every holder of it — after which the page is shown again")
    func narrowerWiderAndTheSameAgain() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        #expect(Self.words(try #require(try LocalServers.seeded().signIn).scopes) == Self.words(Captures.registered))
        #expect(Self.words(Captures.registered).isSuperset(of: Self.words(Captures.wide)))
        try await revokingWhatItMade(oauth) { made in
            // Nobody signed in yet: the page sends them to the door.
            let closed = try await pages.open(try #require(oauth.authorizeURL(clientID: try app(asking: Captures.narrow).clientID, challenge: "x", state: "s")))
            #expect(closed.status == 302 && closed.header("Location") == "https://\(Self.host)/auth/sign_in")
            try await pages.signIn()

            // Less than the registration holds.
            let narrow = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            #expect(pages.shown == [Captures.narrow], "the page was shown, asking for the four")
            #expect(narrow.scopes == Captures.narrow && narrow.asked == Captures.narrow)
            #expect(try await held(narrow) == Self.words(Captures.narrow))

            // Wider, while the narrower lives.
            let wide = made.keep(try await oauth.signIn(as: try app(asking: Captures.wide), through: pages).token)
            #expect(pages.shown == [Captures.narrow, Captures.wide], "shown again for the wider one")
            #expect(wide.accessToken != narrow.accessToken && wide.scopes == Captures.wide)
            #expect(try await held(wide) == Self.words(Captures.wide))
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)
            #expect(try await ask(wide.accessToken, Self.check).status == 200)
            let refused = try await ask(narrow.accessToken, Self.standing)
            #expect(refused.status == 403 && refused.header("WWW-Authenticate")?.contains("read:follows") == true)
            #expect(try await ask(wide.accessToken, Self.standing).status == 200)

            // The same words again, and in another order: no page, and the same token.
            let again = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            let turned = Captures.narrow.split(separator: " ").reversed().joined(separator: " ")
            let reordered = made.keep(try await oauth.signIn(as: try app(asking: turned), through: pages).token)
            #expect(pages.shown == [Captures.narrow, Captures.wide], "sent straight on both times")
            #expect(again.accessToken == narrow.accessToken && reordered.accessToken == narrow.accessToken)

            // Revoking the wider one takes the wider one.
            await oauth.revoke(MastodonLeft(wide, as: .left))
            let gone = try await ask(wide.accessToken, Self.check)
            #expect(gone.status == 401 && gone.error == "The access token was revoked")
            #expect(gone.header("WWW-Authenticate") == Captures.afterRevokeHeader)
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)

            // A wrong secret revokes nothing.
            let wrong = MastodonToken(host: Self.host, accessToken: narrow.accessToken, clientID: narrow.clientID, clientSecret: "wrong")
            let refusal = await oauth.revoke(MastodonLeft(wrong, as: .left))
            #expect(refusal == .refused, "a refusal that asking again will not change")
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)

            // Revoking the narrower one signs out every holder of that string.
            await oauth.revoke(MastodonLeft(narrow, as: .left))
            #expect(try await ask(again.accessToken, Self.check).status == 401)
            let afresh = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            #expect(pages.shown == [Captures.narrow, Captures.wide, Captures.narrow], "no token of those words: the page again")
            #expect(afresh.accessToken != narrow.accessToken)
        }
    }

    // MARK: - 2. Refused, and outside the registration

    @Test("The person pressing Deny is sent to this app's callback with a refusal and the state it was sent, which this app takes for a sign-in declined, and a token held is untouched by it; a word the registration does not hold, the whole of read, or no scope at all is answered with a page of the server's own and nothing is sent to the callback")
    func refusedAndOutside() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        try await revokingWhatItMade(oauth) { made in
            let kept = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)

            let refusing = Pages(host: Self.host, browser: pages.browser, answer: .deny)
            await #expect(throws: MastodonSignInError.denied) {
                _ = try await oauth.signIn(as: try app(asking: Self.refusedWords), through: refusing)
            }
            #expect(refusing.shown == [Self.refusedWords])
            let callback = try #require(refusing.callbacks.last)
            let said = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(callback.scheme == MastodonOAuth.callbackScheme && said.first { $0.name == "error" }?.value == "access_denied")
            #expect(said.contains { $0.name == "state" && $0.value?.isEmpty == false } && !said.contains { $0.name == "code" })
            #expect(try await ask(kept.accessToken, Self.check).status == 200)

            let clientID = try app(asking: Captures.narrow).clientID
            for scopes in ["\(Captures.narrow) read:blocks", "read", ""] {
                let page = try await pages.open(try #require(oauth.authorizeURL(clientID: clientID, challenge: "x", state: "s", scopes: scopes)))
                #expect(page.status == 400 && page.header("Location") == nil, "\(scopes): \(page.status)")
                #expect(String(decoding: page.body, as: UTF8.self).contains(Captures.outsideScope), "\(scopes)")
            }
            #expect(try await ask(kept.accessToken, Self.check).status == 200)
        }
    }

    // MARK: - 3. The same words again, and the check of it failing

    /// #347: what stood behind a live fault. Signing in again for the words a sign-in already
    /// has is answered with that sign-in's own token, so a check of it that fails — a timeout
    /// or a 5xx as much as a refusal — must end nothing: the token in hand is the one held.
    @Test("The same words asked again by a sign-in whose check then fails: no page, the very same token handed back beside the failure, the server asked to end nothing — and the token held still answers")
    func theSameAgainWithTheCheckFailing() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        try await revokingWhatItMade(oauth) { made in
            let first = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            #expect(pages.shown == [Captures.narrow])

            let failing = FailedCheck(try LocalHTTP.client(), at: Self.check)
            let again = try await MastodonOAuth(host: Self.host, sender: failing)
                .signIn(as: try app(asking: Captures.narrow), through: pages)
            _ = made.keep(again.token)
            #expect(pages.shown == [Captures.narrow], "sent straight on")
            #expect(again.token.accessToken == first.accessToken, "the very same token")
            #expect(again.failed == .http(503))
            #expect(await failing.asked == ["/oauth/token", Self.check], "nothing asked the server to end it")
            #expect(try await ask(first.accessToken, Self.check).status == 200)
        }
    }

    /// The real server, but for the account check: that one is answered 503 here and never sent.
    private actor FailedCheck: HTTPSender {
        private let server: any HTTPSender
        private let check: String
        private(set) var asked: [String] = []

        init(_ server: any HTTPSender, at check: String) {
            self.server = server
            self.check = check
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            asked.append(path)
            guard path == check, let url = request.url,
                  let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)
            else { return try await server.send(request) }
            return (Data(), unavailable)
        }
    }

    // MARK: - 4. The host's own list of words, and a registration for all of them

    @Test("The host says which words it knows at one address, to anybody: a list holding every word of every part this app asks for or will, and not the word it refuses a registration for; beside the list it names only addresses on itself, at the paths this app already uses; and it is at no other address")
    func theHostsOwnListOfWords() async throws {
        try await LocalServers.requireHealthy()
        let said = try await ask(nil, Captures.wordListPath)
        let json: Bool = said.header("Content-Type")?.hasPrefix("application/json") == true
        #expect(said.status == 200 && json)
        #expect(String(decoding: said.body, as: UTF8.self) == Captures.wordList)
        let known = Set(try #require(said.object["scopes_supported"] as? [String], "a list of words"))
        #expect(known.isSuperset(of: Self.words(Captures.everyPart)))
        #expect(known.isSuperset(of: Self.words(MastodonOAuth.scopes(writing: true, notices: true))), "all a sign-in asks today")
        #expect(!known.contains("write:nonsense"), "the word `MastodonSaysTests` is refused a registration for")
        for (name, path) in Captures.namedPaths {
            let named: String? = said.object[name] as? String
            #expect(named == "https://\(Self.host)\(path)", "\(name)")
        }
        let signedIn = try await ask(try #require(try LocalServers.seeded().notices).reading.token, Captures.wordListPath)
        #expect(signedIn.body == said.body, "the same to a sign-in")
        for elsewhere in ["/.well-known/openid-configuration", "/.well-known/oauth-protected-resource"] {
            #expect(try await ask(nil, elsewhere).status == 404, "\(elsewhere)")
        }
    }

    @Test("A registration for every word of every part, those of later stories among them, is taken whole: its answer echoes the words as a list, in the order asked, with this app's callback and no other")
    func oneRegistrationForEveryPart() async throws {
        try await LocalServers.requireHealthy()
        let heard = Heard(try LocalHTTP.client())
        let app = try await MastodonOAuth(host: Self.host, sender: heard).register(scopes: Captures.everyPart)
        let registered: Bool = !app.clientID.isEmpty && !app.clientSecret.isEmpty
        #expect(registered && app.scopes == Captures.everyPart)
        let answer = try #require(await heard.answers.last)
        #expect(answer.path == "/api/v1/apps" && answer.status == 200)
        let said = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any] ?? [:]
        let echoed: [String]? = said["scopes"] as? [String]
        let callbacks: [String]? = said["redirect_uris"] as? [String]
        #expect(echoed == Self.list(Captures.everyPart))
        #expect(callbacks == [MastodonOAuth.redirect])
        let captured = (try? JSONSerialization.jsonObject(with: Data(Captures.widestRegistration.utf8))) as? [String: Any] ?? [:]
        #expect(Set(said.keys) == Set(captured.keys), "the same things as it answered once")
    }

    @Test("The registration this app makes — every word of its parts, less what the host's own list lacks, read and asked as the app reads and asks — is taken whole and named back; a page of it for the reading words is shown asking for those alone, and the sign-in it gives reads as the reader and holds no word more")
    func theRegistrationThisAppMakes() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let listed = try #require(await oauth.listedWords(), "the host's own list, as this app reads it")
        #expect(listed.count == 47)
        let whole = MastodonRegistration.superset(listed: listed)
        #expect(whole == MastodonParts.everything, "a 4.6 lacks none of them")
        let registered = try await oauth.registered(for: whole)
        #expect(registered.echoed && registered.app.scopes == whole)

        let reading = MastodonOAuth.reading
        let page = try #require(MastodonRegistration.page(reading, on: registered.app.scopes))
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await revokingWhatItMade(oauth) { made in
            try await pages.signIn()
            let signed = try await oauth.signIn(as: registered.app, asking: page, through: pages)
            let token = made.keep(signed.token)
            #expect(signed.failed == nil, "its own check of the token")
            #expect(pages.shown == [reading], "the registration is wider; the page is not")
            #expect(token.scopes == reading && token.asked == reading)
            #expect(try await held(token) == Self.words(reading))
            #expect(try await ask(token.accessToken, Self.check).status == 200)
            #expect(try await ask(token.accessToken, "/api/v1/timelines/home").status == 200)
            // A word the registration holds and the page did not ask is not the sign-in's.
            #expect(try await ask(token.accessToken, "/api/v1/notifications").status == 403)
        }
    }

    // MARK: - Tending (#380)

    /// What the seed made for the checks of tending, or a failure saying to seed again.
    private static func tending() throws -> [String: Any] {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(all["tending"] as? [String: Any], "servers/.run/mastodon-tokens.json was seeded before tending was: run `make servers` again")
    }

    @Test("Tending's two words are on the host's own list; a registration made before them cannot carry a page asking for them — this app opens none — and the server, asked for such a page all the same, shows a page of its own and sends nothing back")
    func aRegistrationMadeBeforeTending() async throws {
        try await LocalServers.requireHealthy()
        let listed = try #require(await signer().listedWords())
        #expect(listed.isSuperset(of: MastodonPart.tending.words))
        let old = try #require(try LocalServers.seeded().signIn)
        let asking = MastodonParts.page(held: nil, ticked: [.reading, .tending])
        #expect(MastodonRegistration.page(asking, on: old.scopes) == nil, "no page is opened on it")
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        var page = try #require(URLComponents(string: "https://\(Self.host)/oauth/authorize"))
        page.queryItems = [
            URLQueryItem(name: "client_id", value: old.id), URLQueryItem(name: "redirect_uri", value: MastodonOAuth.redirect),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: asking),
        ]
        let opened = try await pages.open(try #require(page.url))
        #expect(opened.status == 400 && opened.header("Location") == nil, "a page of its own: \(opened.status)")
    }

    @Test("This app's registration as it is made now, signed through on the server's own page by the seed's Admin for reading and tending, gives a token holding both of tending's words, with which the reports are read")
    func theAdminSignsInForTending() async throws {
        try await LocalServers.requireHealthy()
        let tending = try Self.tending()
        let app = try #require(tending["app"] as? [String: String])
        let registered = MastodonApp(
            host: Self.host, clientID: try #require(app["id"]), clientSecret: try #require(app["secret"]), scopes: app["scopes"]
        )
        let asking = MastodonParts.page(held: nil, ticked: [.reading, .tending])
        let oauth = try signer()
        let person = (try #require(tending["adminEmail"] as? String), try #require(tending["adminPassword"] as? String))
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser(), as: person)
        try await revokingWhatItMade(oauth) { made in
            try await pages.signIn()
            let signed = try await oauth.signIn(as: registered, asking: asking, through: pages)
            let token = made.keep(signed.token)
            #expect(signed.failed == nil && pages.shown == [asking])
            #expect(MastodonParts.holds(.tending, in: token.scopes) && token.scopes == asking)
            #expect(try await held(token) == Self.words(asking))
            #expect(try await ask(token.accessToken, "/api/v1/admin/reports").status == 200)
        }
    }

    // MARK: - 5. The source's own account of a token, and of whose it is

    @Test("The source's own account of a token is given to any token that lives, whatever its words: the words it was made with as a list in that order — the whole of read never spelt out — beside a number of the server's own for the person, which is not the account's id; a token that is none, and no token, are answered 401")
    func theSourcesOwnAccountOfAToken() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let notices = try #require(seeded.notices)
        let oneWord = try #require(seeded.people?.narrow, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")

        let whole = try await ask(seeded.writer, Self.info)
        #expect(whole.status == 200)
        #expect(Set(whole.object.keys) == Captures.infoNames)
        let everything: [String]? = whole.object["scope"] as? [String]
        #expect(everything == ["read", "write"])
        let neverEnds: Bool = whole.object["expires_in"] is NSNull
        let dated: Bool = whole.object["created_at"] is Int
        #expect(neverEnds && dated)
        // The registration is named by its client id, which is not printed.
        let registration: String? = (whole.object["application"] as? [String: Any])?["uid"] as? String
        let namesRegistration: Bool = registration?.isEmpty == false
        #expect(namesRegistration)

        let signIns: [(token: String, scopes: String)] = [
            (notices.reading.token, notices.reading.scopes), (notices.acting.token, notices.acting.scopes),
            (notices.dismissing.token, notices.dismissing.scopes), (oneWord.token, "read:statuses"),
        ]
        for signIn in signIns {
            let said = try await ask(signIn.token, Self.info)
            let listed: [String]? = said.object["scope"] as? [String]
            #expect(said.status == 200, "\(signIn.scopes)")
            #expect(listed == Self.list(signIn.scopes))
        }

        // The number is the server's own for the person: the account check names the account.
        let owner = try #require(whole.object["resource_owner_id"] as? Int)
        let account = try #require(try await ask(seeded.writer, Self.check).object["id"] as? String)
        #expect(String(owner) != account)

        for none in ["not-a-token", nil] {
            let refused = try await ask(none, Self.info)
            #expect(refused.status == 401 && refused.header("WWW-Authenticate") == Captures.invalidInfoHeader)
            #expect(String(decoding: refused.body, as: UTF8.self) == Captures.invalidInfo)
        }
    }

    @Test("The account check answers the reading words alone with the account's id and its name, which this app reads as who the sign-in is; a sign-in without the word for accounts is refused it with a 403 naming the words that would do")
    func theAccountCheckWithTheReadingWords() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let reading = try #require(seeded.notices).reading
        #expect(reading.scopes == MastodonOAuth.reading)

        let said = try await ask(reading.token, Self.check)
        let id = try #require(said.object["id"] as? String)
        let name = try #require(said.object["acct"] as? String)
        let named: Bool = !id.isEmpty && !name.isEmpty
        let bare: Bool = !name.contains("@")
        #expect(said.status == 200 && named && bare, "an id, and a name with no host")

        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(
            host: Self.host, accessToken: reading.token, clientID: "x", clientSecret: "x", scopes: reading.scopes, asked: reading.scopes
        )
        try tokens.save(token)
        let who = try await MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens).who()
        #expect(who.id == id)
        #expect(who.handle == StatusDTO.handle(name, host: Self.host))

        let oneWord = try #require(seeded.people?.narrow, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")
        let refused = try await ask(oneWord.token, Self.check)
        #expect(refused.status == 403 && refused.header("WWW-Authenticate") == Captures.checkRefusedHeader)
    }

    // MARK: - 6. A token handed back says when it was first made

    @Test("A token handed back for the same words keeps the moment it was first made: a fresh one is dated the second its own answer is, the same one handed back later is dated as before under a later answer, and the source's own account of it says the same moment")
    func aTokenHandedBackSaysWhenItWasFirstMade() async throws {
        try await LocalServers.requireHealthy()
        let heard = Heard(try LocalHTTP.client())
        let oauth = MastodonOAuth(host: Self.host, sender: heard)
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        try await revokingWhatItMade(oauth) { made in
            let first = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            let fresh = try #require(await heard.lastTrade(), "a trade dated by the token and by its answer")
            let lag: Int = fresh.answered - fresh.made
            #expect((0...1).contains(lag), "made as it was answered: \(lag)s")

            // The server dates a token in whole seconds. This is the one pause here, and it waits
            // for nothing: it lets that clock move on, so that a token made by the second trade
            // could not be dated as the first was.
            try await Task.sleep(for: .seconds(2))

            let second = try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages)
            let again = made.keep(second.token)
            #expect(second.handedBack, "this app did not see that the token was made before this trade")
            let handedBack = try #require(await heard.lastTrade())
            let same: Bool = again.accessToken == first.accessToken
            #expect(same && pages.shown == [Captures.narrow], "no page, and the same token")
            #expect(handedBack.made == fresh.made, "dated as it first was")
            let later: Int = handedBack.answered - handedBack.made
            #expect(later >= 2, "under an answer dated \(later)s after it")
            let account: Int? = try await ask(first.accessToken, Self.info).object["created_at"] as? Int
            #expect(account == fresh.made, "and the source's own account of it says the same")
        }
    }

    // MARK: - 7. A sign-in a wider one took the place of, and signing out

    @Test("A sign-in a wider one of the same registration took the place of goes on answering, written down as left, until the device signs out; signing out ends the one held and the one left, each confirmed, and both then answer as ended")
    func aReplacedSignInLivesUntilTheSignOut() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        let store = MemoryMastodonTokens()
        try await revokingWhatItMade(oauth) { made in
            let first = try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages)
            let narrow = made.keep(first.token)
            #expect(first.failed == nil && !first.handedBack)
            #expect(try store.swap(expecting: nil, with: narrow))

            // Asked for more: the fresh token is noted before its check, the one it replaces
            // is written down as left, and only then is the wider one put in its place.
            let second = try await oauth.signIn(as: try app(asking: Captures.wide), through: pages) { fresh in
                try store.journal(MastodonLeft(fresh, as: .pending))
            }
            let wide = made.keep(second.token)
            let sameAccount: Bool = first.accountID != nil && first.accountID == second.accountID
            #expect(second.failed == nil && sameAccount, "both checks name the one account, by id")
            try store.journal(MastodonLeft(narrow, as: .left, accountID: first.accountID))
            #expect(try store.swap(expecting: narrow.accessToken, with: wide))
            let left = try store.left(host: Self.host)
            #expect(left.map(\.state) == [.left] && left.first?.isToken(narrow) == true)

            // Nothing asked the source to end the narrower one: another device carrying it reads on.
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)
            #expect(try await ask(wide.accessToken, Self.check).status == 200)

            // Signing out: everything leaves the device, then the one held and each one left is ended.
            let held = try #require(try store.token(host: Self.host))
            try store.forget(host: Self.host)
            try store.forgetLeft(host: Self.host)
            let heldEnded = await oauth.revoke(MastodonLeft(held, as: .left))
            #expect(heldEnded == .ended)
            for entry in left {
                let ended = await oauth.revoke(entry)
                #expect(ended == .ended)
            }
            for token in [narrow, wide] {
                let gone = try await ask(token.accessToken, Self.check)
                #expect(gone.status == 401 && gone.error == "The access token was revoked")
            }
        }
    }

    // MARK: - 8. Asked for a part where it stands

    @Test("A reading sign-in asked where it stands for bookmarks — a page of the same registration for the words its source says it holds and that one part — comes back wider and as the same account, while the one it had goes on answering; and the source's own account of each, as this app reads it, is the words each was made with")
    func aReadingSignInAskedInPlace() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        try await revokingWhatItMade(oauth) { made in
            let reading = MastodonOAuth.reading
            let first = try await oauth.signIn(as: try app(asking: reading), through: pages)
            let held = made.keep(first.token)
            #expect(first.failed == nil && !first.handedBack)

            // What the page is built from: the source's own account of the token held.
            let said = try #require(try await oauth.words(of: held))
            #expect(said == Self.list(reading))
            let page = MastodonParts.page(held: MastodonParts.believed(said, asked: held.asked), ticked: [.bookmarks])
            #expect(page == reading + " write:bookmarks")

            let second = try await oauth.signIn(as: try app(asking: page), through: pages)
            let wider = made.keep(second.token)
            #expect(second.failed == nil && !second.handedBack)
            #expect(pages.shown == [reading, page], "each was a page of its own, for exactly the words asked")
            let another: Bool = wider.accessToken != held.accessToken
            let sameAccount: Bool = first.accountID != nil && first.accountID == second.accountID
            #expect(another && sameAccount, "a second sign-in of the one account, by id")
            #expect(wider.clientID == held.clientID, "the same registration served both")
            #expect(wider.scopes == page)
            #expect(try await oauth.words(of: wider) == Self.list(page))

            // Nothing ended the one it had: another device carrying it reads on.
            #expect(try await ask(held.accessToken, Self.check).status == 200)
            #expect(try await ask(wider.accessToken, Self.check).status == 200)
        }
    }

    // MARK: - 9. Follows, asked of a sign-in that only reads

    /// How the reader stands to one person, as `relationships` answers it: a list of one.
    private static func relation(in answer: Answer) -> [String: Any] {
        let said = try? JSONSerialization.jsonObject(with: answer.body)
        return (said as? [[String: Any]])?.first ?? [:]
    }

    /// #347, #313: a part stands by itself. A sign-in that only reads, asked where it stands
    /// for follows, comes back able to follow and still unable to post.
    @Test("A reading sign-in asked where it stands for follows — a page of the same registration for what its source says it holds and the two words of follows — comes back holding both beside what it had, as the same account, while the one it had goes on answering and is still refused how the reader stands to anybody; with it the source says how the reader stands to somebody, follows them and unfollows them, and still refuses a post for want of the word to write one")
    func aReadingSignInAskedForFollows() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        let seeded = try LocalServers.seeded()
        let other = try #require(
            seeded.people?.followable,
            "servers/.run/mastodon-tokens.json was seeded before this person was: run `make servers` again"
        )
        let account = "/api/v1/accounts/\(other.id)"
        let stands = "/api/v1/accounts/relationships?id[]=\(other.id)"
        try await revokingWhatItMade(oauth) { made in
            let reading = MastodonOAuth.reading
            let first = try await oauth.signIn(as: try app(asking: reading), through: pages)
            let narrow = made.keep(first.token)
            #expect(first.failed == nil)
            #expect(!first.handedBack)
            let unread = try await ask(narrow.accessToken, stands)
            #expect(unread.status == 403)
            #expect(unread.header("WWW-Authenticate") == Captures.standingRefusedHeader)

            // The page: what the source says the sign-in holds, and follows — nothing else.
            let said = try #require(try await oauth.words(of: narrow))
            let page = MastodonParts.page(held: MastodonParts.believed(said, asked: narrow.asked), ticked: [.follows])
            #expect(page == "read:statuses read:lists read:accounts read:search read:follows write:follows")
            let second = try await oauth.signIn(as: try app(asking: page), through: pages)
            let wider = made.keep(second.token)
            #expect(second.failed == nil)
            #expect(!second.handedBack)
            #expect(pages.shown == [reading, page], "each was a page of its own, for exactly the words asked")
            let another: Bool = wider.accessToken != narrow.accessToken
            #expect(another, "a second sign-in, not the first handed back")
            let named: Bool = first.accountID != nil
            let sameAccount: Bool = first.accountID == second.accountID
            #expect(named)
            #expect(sameAccount, "the one account, by id")
            let oneRegistration: Bool = wider.clientID == narrow.clientID
            #expect(oneRegistration, "the same registration served both")
            #expect(wider.scopes == page)
            #expect(try await oauth.words(of: wider) == Self.list(page))

            // Nothing ended the one it had, and it holds no more than it did.
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)
            #expect(try await ask(narrow.accessToken, stands).status == 403)
            #expect(try await ask(wider.accessToken, Self.check).status == 200)

            let stood = try await ask(wider.accessToken, stands)
            #expect(stood.status == 200)
            let isThem: Bool = Self.relation(in: stood)["id"] as? String == other.id
            #expect(isThem, "one entry, for the person asked about")
            #expect(Set(Self.relation(in: stood).keys) == Captures.standingNames)
            #expect(Self.relation(in: stood)["following"] as? Bool == false)

            // Followed, then unfollowed — **and unfollowed however this ends**, by the
            // sign-in itself or, where that fails, by the writer's own for everything.
            let thrown: (any Error)?
            do {
                // The sign-in it took the place of may still not follow.
                let refused = try await ask(narrow.accessToken, account + "/follow", "POST")
                #expect(refused.status == 403)
                #expect(refused.header("WWW-Authenticate") == Captures.followRefusedHeader)

                let followed = try await ask(wider.accessToken, account + "/follow", "POST")
                #expect(followed.status == 200)
                #expect(followed.object["following"] as? Bool == true)
                #expect(Set(followed.object.keys) == Captures.standingNames)
                let now = try await ask(wider.accessToken, stands)
                #expect(Self.relation(in: now)["following"] as? Bool == true)

                // Holding follows is not writing: no post, for want of its own word.
                let post = try await ask(wider.accessToken, "/api/v1/statuses", "POST", form: "status=fediqo347+never+posted")
                #expect(post.status == 403)
                #expect(post.header("WWW-Authenticate") == Captures.postRefusedHeader)
                if let posted = post.object["id"] as? String {
                    _ = try? await ask(seeded.writer, "/api/v1/statuses/\(posted)", "DELETE")
                }
                thrown = nil
            } catch {
                thrown = error
            }
            let unfollowed = try? await ask(wider.accessToken, account + "/unfollow", "POST")
            if unfollowed?.status != 200 { _ = try? await ask(seeded.writer, account + "/unfollow", "POST") }
            if let thrown { throw thrown }
            #expect(unfollowed?.status == 200)
            #expect(unfollowed?.object["following"] as? Bool == false)
            let after = try await ask(wider.accessToken, stands)
            #expect(Self.relation(in: after)["following"] as? Bool == false)
        }
    }

    // MARK: - 10. The person's own list of authorised apps

    @Test("Two sign-ins of one registration are one entry on the person's list of authorised apps, which says what the registration was made for and not what either holds; removing it ends both at once and no other registration's, the source's own account of each then answering as for a token that never was; and the registration goes on opening its page")
    func removingTheEntryEndsEveryTokenOfIt() async throws {
        try await LocalServers.requireHealthy()
        let oauth = try signer()
        let pages = Pages(host: Self.host, browser: try LocalHTTP.browser())
        try await pages.signIn()
        let seeded = try LocalServers.seeded()
        #expect(Self.words(try #require(seeded.signIn).scopes) == Self.words(Captures.registered))
        let another = try #require(seeded.notices).reading.token
        try await revokingWhatItMade(oauth) { made in
            let narrow = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            let wide = made.keep(try await oauth.signIn(as: try app(asking: Captures.wide), through: pages).token)

            let entries = try await pages.entries(named: Self.registrationName)
            #expect(entries.count == 1, "one entry, for two tokens")
            let entry = try #require(entries.first)
            #expect(entry.permissions == Captures.entryPermissions, "the registration's words, though neither token may post")

            let removed = try await pages.remove(entry)
            #expect(removed.status == 302 && removed.header("Location") == "https://\(Self.host)/oauth/authorized_applications")
            for token in [narrow, wide] {
                let gone = try await ask(token.accessToken, Self.check)
                #expect(gone.status == 401 && gone.error == "The access token was revoked")
                let account = try await ask(token.accessToken, Self.info)
                #expect(account.status == 401 && account.header("WWW-Authenticate") == Captures.invalidInfoHeader)
                #expect(String(decoding: account.body, as: UTF8.self) == Captures.invalidInfo, "invalid, not revoked")
            }
            let untouched = try await ask(another, Self.check)
            #expect(untouched.status == 200, "another registration's sign-in, the same person's")
            #expect(try await pages.entries(named: Self.registrationName).isEmpty)

            let afresh = made.keep(try await oauth.signIn(as: try app(asking: Captures.narrow), through: pages).token)
            let renewed: Bool = afresh.accessToken != narrow.accessToken
            #expect(renewed && pages.shown == [Captures.narrow, Captures.wide, Captures.narrow], "the page again, and a new token")
        }
    }

    /// The real server, and what it answered to each ask — kept in memory for the check that
    /// asked, and **never printed**: a trade's answer holds a token.
    private actor Heard: HTTPSender {
        struct Said {
            let path: String
            let status: Int
            let body: Data
            let date: String?
        }

        private let server: any HTTPSender
        private(set) var answers: [Said] = []

        init(_ server: any HTTPSender) {
            self.server = server
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (body, response) = try await server.send(request)
            answers.append(Said(
                path: request.url?.path ?? "", status: response.statusCode, body: body,
                date: response.value(forHTTPHeaderField: "Date")
            ))
            return (body, response)
        }

        /// Of the last code traded: when its token says it was made, and when the answer that
        /// carried it is dated — both in seconds, and neither the token.
        func lastTrade() -> (made: Int, answered: Int)? {
            struct Issued: Decodable { let created_at: Int }
            let dated = DateFormatter()
            dated.locale = Locale(identifier: "en_US_POSIX")
            dated.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let trade = answers.last(where: { $0.path == "/oauth/token" }),
                  let issued = try? JSONDecoder().decode(Issued.self, from: trade.body),
                  let answered = trade.date.flatMap(dated.date(from:))
            else { return nil }
            return (issued.created_at, Int(answered.timeIntervalSince1970))
        }
    }

    /// The server's own pages, used as the writer uses them at a browser: signed in with the
    /// seed's dummy password, shown the page a sign-in opens, and the page's own Authorize or
    /// Deny form sent back with every field it carried. It remembers which pages it was shown
    /// — by the scopes each asked — and where each sign-in was sent. It also reads the person's
    /// own list of authorised apps, and presses an entry's Revoke.
    private final class Pages: OAuthBrowser {
        enum Press: Sendable {
            case authorize, deny
        }

        struct Opened: Sendable {
            let status: Int
            let response: HTTPURLResponse
            let body: Data
            func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        }

        let host: String
        let browser: LocalBrowser
        private let answer: Press
        /// Whom the door is signed in as: the writer, unless a check names somebody else.
        private let person: (email: String, password: String)
        private(set) var shown: [String] = []
        private(set) var callbacks: [URL] = []

        init(
            host: String, browser: LocalBrowser, answer: Press = .authorize,
            as person: (email: String, password: String) = ("writer@example.com", "LocalOnlyPass1")
        ) {
            self.host = host
            self.browser = browser
            self.answer = answer
            self.person = person
        }

        func signIn() async throws {
            let door = try #require(URL(string: "https://\(host)/auth/sign_in"))
            let page = try await browser.send(URLRequest(url: door))
            let form = try #require(Self.forms(in: page.0).first { $0.contains { $0.0 == "user[email]" } }, "the door's form")
            let signedIn = try await browser.send(Self.post(door, form.filter { !$0.0.hasPrefix("user[") } + [
                ("user[email]", person.email), ("user[password]", person.password),
            ]))
            try #require(signedIn.1.statusCode == 302, "signed in: \(signedIn.1.statusCode)")
        }

        func open(_ url: URL) async throws -> Opened {
            // Asked for in English: the page of the server's own is written in the language asked.
            var request = URLRequest(url: url)
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            let page = try await browser.send(request)
            return Opened(status: page.1.statusCode, response: page.1, body: page.0)
        }

        func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
            let page = try await open(url)
            if page.status == 302 {
                let onward = try #require(page.header("Location").flatMap(URL.init(string:)), "sent on")
                try #require(onward.scheme == callbackScheme, "sent on to: \(onward.scheme ?? "")")
                callbacks.append(onward)
                return onward
            }
            try #require(page.status == 200, "the page to answer: \(page.status)")
            let asked = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            shown.append(asked.first { $0.name == "scope" }?.value ?? "")
            let forms = Self.forms(in: page.body)
            let denies: ([(String, String)]) -> Bool = { $0.contains { $0 == ("_method", "delete") } }
            let form = try #require(forms.first { $0.contains { $0.0 == "client_id" } && denies($0) == (answer == .deny) }, "the page's form")
            // The page carries what the address asked back to the server, unchanged.
            for name in MastodonSignInCaptures.pageFields {
                #expect(form.first { $0.0 == name }?.1 == asked.first { $0.name == name }?.value, "\(name)")
            }
            let target = try #require(URL(string: "https://\(host)/oauth/authorize"))
            let answered = try await browser.send(Self.post(target, form))
            let onward = try #require(answered.1.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)), "sent on: \(answered.1.statusCode)")
            try #require(answered.1.statusCode == 302 && onward.scheme == callbackScheme)
            callbacks.append(onward)
            return onward
        }

        /// One registration on the person's list of authorised apps: the number the page
        /// knows it by, what the page says it may do — each line's two phrases, in order — and
        /// the page's own token, which its Revoke sends back.
        struct Entry: Sendable {
            let id: String
            let permissions: String
            fileprivate let pageToken: String
        }

        /// The entries of the list that carry `name`.
        func entries(named name: String) async throws -> [Entry] {
            let page = try await open(try #require(URL(string: "https://\(host)/oauth/authorized_applications")))
            try #require(page.status == 200, "the list of authorised apps: \(page.status)")
            let html = String(decoding: page.body, as: UTF8.self)
            let pageToken = try #require(Self.matches(#"<meta name="csrf-token" content="([^"]*)""#, in: html).first, "the page's token")
            // Each entry runs to where the next begins.
            let pieces = html.components(separatedBy: #"<div class="applications-list__item" id="doorkeeper_application_"#).dropFirst()
            return pieces.compactMap { piece in
                guard let id = Self.matches(#"^(\d+)""#, in: piece).first,
                      let title = Self.matches(#"<strong\b[^>]*>\s*(.*?)\s*</strong>"#, in: piece).first,
                      Self.unescaped(title) == name
                else { return nil }
                let said = Self.matches(#"permissions-list__item__text__(?:title|type)">\s*(.*?)\s*</div>"#, in: piece)
                return Entry(id: id, permissions: said.map(Self.unescaped).joined(separator: " "), pageToken: Self.unescaped(pageToken))
            }
        }

        /// The entry's own Revoke, as the page sends it.
        func remove(_ entry: Entry) async throws -> Opened {
            let target = try #require(URL(string: "https://\(host)/oauth/authorized_applications/\(entry.id)"))
            let answered = try await browser.send(Self.post(target, [("_method", "delete"), ("authenticity_token", entry.pageToken)]))
            return Opened(status: answered.1.statusCode, response: answered.1, body: answered.0)
        }

        /// Every form on a page, as the fields it would send: each input's name and value.
        private static func forms(in page: Data) -> [[(String, String)]] {
            let html = String(decoding: page, as: UTF8.self)
            return matches(#"<form\b[^>]*>(.*?)</form>"#, in: html).map { form in
                matches(#"<input\b[^>]*>"#, in: form, group: 0).compactMap { input in
                    guard let name = matches(#"\bname="([^"]*)""#, in: input).first else { return nil }
                    return (unescaped(name), unescaped(matches(#"\bvalue="([^"]*)""#, in: input).first ?? ""))
                }
            }
        }

        private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: group), in: text).map { String(text[$0]) }
            }
        }

        private static func unescaped(_ text: String) -> String {
            [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
                .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }

        private static func post(_ url: URL, _ form: [(String, String)]) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setForm(form)
            return request
        }
    }
}
