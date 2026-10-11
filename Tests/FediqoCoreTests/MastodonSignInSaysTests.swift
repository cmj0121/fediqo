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
/// **Asked gently.** No registration: this server takes five in ten minutes from anywhere, so
/// the one every sign-in here starts on is the seed's — made in the server, which holds it to
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
        for token in made.tokens { await oauth.revoke(token) }
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

    private func ask(_ token: String, _ path: String) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    private static let check = "/api/v1/accounts/verify_credentials"
    private static let standing = "/api/v1/accounts/relationships?id[]=1"

    /// The scopes the server itself says a token holds.
    private func held(_ token: MastodonToken) async throws -> Set<String> {
        Set(try await ask(token.accessToken, "/oauth/token/info").object["scope"] as? [String] ?? [])
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
            await oauth.revoke(wide)
            let gone = try await ask(wide.accessToken, Self.check)
            #expect(gone.status == 401 && gone.error == "The access token was revoked")
            #expect(gone.header("WWW-Authenticate") == Captures.afterRevokeHeader)
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)

            // A wrong secret revokes nothing.
            await oauth.revoke(MastodonToken(host: Self.host, accessToken: narrow.accessToken, clientID: narrow.clientID, clientSecret: "wrong"))
            #expect(try await ask(narrow.accessToken, Self.check).status == 200)

            // Revoking the narrower one signs out every holder of that string.
            await oauth.revoke(narrow)
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

    /// The server's own pages, used as the writer uses them at a browser: signed in with the
    /// seed's dummy password, shown the page a sign-in opens, and the page's own Authorize or
    /// Deny form sent back with every field it carried. It remembers which pages it was shown
    /// — by the scopes each asked — and where each sign-in was sent.
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
        private(set) var shown: [String] = []
        private(set) var callbacks: [URL] = []

        init(host: String, browser: LocalBrowser, answer: Press = .authorize) {
            self.host = host
            self.browser = browser
            self.answer = answer
        }

        func signIn() async throws {
            let door = try #require(URL(string: "https://\(host)/auth/sign_in"))
            let page = try await browser.send(URLRequest(url: door))
            let form = try #require(Self.forms(in: page.0).first { $0.contains { $0.0 == "user[email]" } }, "the door's form")
            let signedIn = try await browser.send(Self.post(door, form.filter { !$0.0.hasPrefix("user[") } + [
                ("user[email]", "writer@example.com"), ("user[password]", "LocalOnlyPass1"),
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
