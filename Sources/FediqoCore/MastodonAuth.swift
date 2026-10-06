import CryptoKit
import Foundation
import Security

// Signing in to a Mastodon server: OAuth 2 authorization code with PKCE (S256) and `state`, on
// the server's own page, asking for what reading needs and — where the reader said so — for what
// writing needs.
//
// The app is registered once per host and its registration kept (`MastodonApp`), so a sign-in
// after a sign-out does not register again; Mastodon tokens do not expire, so there is no
// refresh. PKCE is always sent: a server older than 4.3 ignores it,
// and `state` and the client secret still bind the flow there.

/// Opens the server's authorization page and hands back the address it finished on.
@MainActor
public protocol OAuthBrowser: Sendable {
    /// Throws `MastodonSignInError.cancelled` where the reader closed it.
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL
}

/// Why a sign-in did not finish. **Status codes only** — no token, code, state or verifier ever
/// travels in an error.
public enum MastodonSignInError: Error, Equatable, Sendable {
    /// The reader closed the page.
    case cancelled
    /// The reader said no on the server's page.
    case denied
    /// The callback's `state` is not the one sent: not this attempt's answer.
    case stateMismatch
    case unreachable
    case http(Int)
    case unreadable
    /// The token was issued and this device could not keep it.
    case keychain
    /// The server no longer knows this app's registration (`invalid_client`): register again.
    case clientRejected
    /// The server answered `invalid_scope`: the registration was made for other scopes than
    /// this build asks for. It is dropped, so the next attempt registers afresh.
    ///
    /// **From the token exchange, or from a registration refused for its scopes — not, on a
    /// Mastodon, from its sign-in page** (#298). Asked there for a scope the registration does
    /// not include, a Mastodon 4.6 shows a page of its own (HTTP 400) and redirects nowhere:
    /// no `error=invalid_scope` comes back to this app, and no `state`. The person closes the
    /// page, which is a sign-in cancelled. `code(from:)` still reads the redirect for a server
    /// that does send one; nothing here relies on a Mastodon doing so, because the page is
    /// only ever asked for scopes its registration was made with.
    case invalidScope
}

/// A request made with a token, answered.
public enum MastodonAuthError: Error, Equatable, Sendable {
    /// 401: the server no longer honours this token. The token is already gone from this device.
    case signedOut
    /// Any other refusal — 403 included, which is a token outside its scope or a suspended
    /// login, not a revoked one.
    case http(Int)
}

/// A PKCE pair (RFC 7636): a random verifier and its S256 challenge.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func make() -> PKCE { PKCE(verifier: random(bytes: 32)) }

    /// Unpadded base64url of `bytes` random bytes.
    static func random(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "no randomness to sign in with")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One host's sign-in, each step a function a test can drive.
public struct MastodonOAuth: Sendable {
    public static let callbackScheme = "fediqo"
    public static let redirect = "fediqo://oauth"
    /// Decision 8: what Home, lists, the account check and finding a post again by its address
    /// (#29) need, and no more. A token issued before `read:search` was asked for lacks it.
    public static let reading = "read:statuses read:lists read:accounts read:search"
    /// Decision 32: what is asked of a server that refuses `read:search` (`invalid_scope`), once.
    /// Everything but finding an old post again works; that says to sign in again.
    public static let readingWithoutSearch = "read:statuses read:lists read:accounts"
    /// What writing needs (#69), and no more: `write:statuses` is a post, a boost, a reply and
    /// taking any of them back; `write:favourites` is a favourite. **Nothing here follows anybody,
    /// changes a profile or touches a filter** — those are other `write:` scopes and this app asks
    /// for none of them.
    ///
    /// **Asked for only where the reader said so.** It is never part of the reading pair above, so
    /// a sign-in that refuses the writing part is byte-for-byte the sign-in this app made before
    /// this existed.
    public static let writing = "write:statuses write:favourites"
    /// What bookmarking needs (#285), and no more: a bookmark put on a post at its source, and
    /// taken off it. **Apart from `writing` and not a third word in it**, because `writes(_:)`
    /// asks for every word of that, and a sign-in made before this existed — which posts, boosts
    /// and favourites exactly as it did — would then read as one that cannot write at all.
    ///
    /// Asked for with the writing part and never without it: reading alone asks for what it
    /// always asked.
    public static let bookmarking = "write:bookmarks"

    /// The whole of what one sign-in asks for: reading, and the writing part after it where the
    /// reader agreed to it — with bookmarking after that, unless `bookmarks` is false, which is
    /// the rung a server that refuses the bookmark scope is asked on, and what a sign-in to act
    /// asked for before #285.
    ///
    /// **Reading first, writing next, bookmarking last, always in this order**, because the string
    /// is also what a registration records and what `known(writing:)` compares against — two
    /// spellings of one ask would register twice for one choice.
    public static func scopes(
        reading: String = reading, writing wanted: Bool, bookmarks: Bool = true
    ) -> String {
        guard wanted else { return reading }
        return bookmarks ? "\(reading) \(Self.writing) \(bookmarking)" : "\(reading) \(Self.writing)"
    }

    /// The ladder one answer is asked on, widest first: what a sign-in registers for, and what it
    /// falls back to, a rung at a time, where the server answers `invalid_scope`.
    ///
    /// Reading has decision 32's two rungs: with `read:search`, and without. Reading and acting
    /// has four (#285): those two with bookmarking, then the same two without it — so a server
    /// that has no bookmark scope leaves the reader with the read-and-write sign-in they asked
    /// for, which is what such a sign-in was before bookmarks were asked for at all. Nothing the
    /// callback carries says which word was refused, so the rungs are tried in order.
    ///
    /// **One owner for every rung.** `MastodonSessions.signIn` needs them in order and needs to
    /// know which registrations it may reuse, and those were two derivations of one ladder in two
    /// files — true together only by inspection. `known(writing:)` is read off this.
    public static func ladder(writing wanted: Bool) -> [String] {
        let readings = [reading, readingWithoutSearch]
        guard wanted else { return readings }
        return readings.map { scopes(reading: $0, writing: true) }
            + readings.map { scopes(reading: $0, writing: true, bookmarks: false) }
    }

    /// The registrations this build may start a sign-in on that wants `writing`, or not: the
    /// rungs of its ladder that ask for everything the answer asks for but `read:search`.
    ///
    /// **It is per writing choice and not one list of everything.** A registration made for
    /// reading alone cannot carry a page that asks to write — the server answers `invalid_scope` —
    /// so a reader who signs in again to add writing must register again. The two rungs inside one
    /// choice are decision 32's: a host that refused `read:search` keeps its narrower registration
    /// rather than registering afresh every time.
    ///
    /// **A registration made for acting without bookmarks is not one of them** (#285), though it
    /// is a rung: a sign-in started on it would never ask for bookmarks, and a reader asked to
    /// allow them would be sent to a page that does not mention them. It is reached only by
    /// falling to it, within one sign-in.
    public static func known(writing wanted: Bool) -> Set<String> {
        Set(ladder(writing: wanted).filter { !wanted || bookmarks($0) })
    }

    /// Whether a scope string bought bookmarking — read scope by scope, as `writes(_:)` is.
    public static func bookmarks(_ scopes: String?) -> Bool {
        guard let scopes else { return false }
        return scopes.split(separator: " ").contains(Substring(bookmarking))
    }

    /// Whether a scope string bought the writing part.
    ///
    /// **Compared scope by scope and never as a substring**, so a server that hands back the
    /// scopes in another order still reads as writing, and a scope that merely contains one of
    /// these words does not.
    public static func writes(_ scopes: String?) -> Bool {
        guard let scopes else { return false }
        let granted = Set(scopes.split(separator: " "))
        return writingScopes.allSatisfy(granted.contains)
    }

    /// `writing`, split once. This is asked of every held token at launch and again whenever the
    /// app comes to the front, so the constant is split once rather than once per item.
    private static let writingScopes: [Substring] = writing.split(separator: " ")

    let host: String
    private let sender: any HTTPSender

    public init(host: String, sender: any HTTPSender) {
        self.host = host.lowercased()
        self.sender = sender
    }

    /// Opens the server's page for `app`, checks the answer, trades the code for a token and
    /// proves the token works. Nothing is saved here. A token that fails the check is revoked
    /// before the failure is reported, so no working token is left behind on the server.
    public func signIn(as app: MastodonApp, through browser: any OAuthBrowser) async throws
        -> MastodonToken
    {
        let pkce = PKCE.make()
        let state = PKCE.random(bytes: 16)
        let scopes = app.scopes ?? Self.reading
        guard let page = authorizeURL(
            clientID: app.clientID, challenge: pkce.challenge, state: state, scopes: scopes
        ) else { throw MastodonSignInError.unreadable }
        let callback = try await browser.authorize(page, callbackScheme: Self.callbackScheme)
        let code = try Self.code(from: callback, state: state)
        let issued = try await exchange(
            code: code, verifier: pkce.verifier, clientID: app.clientID,
            clientSecret: app.clientSecret, scopes: scopes
        )
        let token = MastodonToken(
            host: host,
            accessToken: issued.accessToken,
            clientID: app.clientID,
            clientSecret: app.clientSecret,
            // What this token may actually do, kept with it — the one record of what the reader
            // agreed to. Without it a token kept by an earlier build and a token whose reader
            // refused the writing part are the same thing, and one of them has been asked and the
            // other has not.
            //
            // **The server's own answer where it sent one, and what was asked for only where it
            // did not.** A server may issue a narrower grant than it was asked for, and a row
            // reading back the asked string would say "read and write" about a token that cannot
            // write — the row's job is to say what may be done on the source, not what this
            // device intended.
            //
            // **And never more than was asked**: only the words of its answer that the page
            // asked for are written down (`Self.granted`). A server naming a scope the reader
            // was never shown cannot make this device think it holds it.
            scopes: Self.granted(issued.scope, of: scopes),
            asked: scopes
        )
        do {
            try await verify(token)
        } catch {
            await revoke(token)
            throw error
        }
        return token
    }

    /// What a sign-in that asked for `asked` is written down as holding, from the server's own
    /// word about it: the scopes it named that were asked for, in the order they were asked, or
    /// all of `asked` where it named none — RFC 6749 lets the word out only when the grant is
    /// exactly the request. A narrower answer narrows; nothing in it can widen.
    static func granted(_ echo: String?, of asked: String) -> String {
        guard let echo, !echo.isEmpty else { return asked }
        let named = Set(echo.split(separator: " "))
        return asked.split(separator: " ").filter(named.contains).joined(separator: " ")
    }

    /// This app, registered on the server with the callback and `scopes`, which it records.
    ///
    /// **A server that refuses the registration for its scopes** — a 4xx whose own `error` says
    /// so — is `invalidScope`, as its page answering `invalid_scope` is, so a sign-in falls a
    /// rung either way. Any other refusal, and every failure that names no scope, is what it was.
    public func register(scopes: String = MastodonOAuth.reading) async throws -> MastodonApp {
        struct Registered: Decodable {
            let client_id: String
            let client_secret: String
        }
        let answer: Registered = try await post("/api/v1/apps", [
            ("client_name", Fediqo.name),
            ("redirect_uris", Self.redirect),
            ("scopes", scopes),
        ])
        return MastodonApp(
            host: host, clientID: answer.client_id, clientSecret: answer.client_secret, scopes: scopes
        )
    }

    func authorizeURL(
        clientID: String, challenge: String, state: String, scopes: String = MastodonOAuth.reading
    ) -> URL? {
        Host.httpsURL(host: host, path: "/oauth/authorize", query: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
    }

    /// The code in the server's answer, once the answer is shown to be this attempt's: at this
    /// app's own callback, carrying the state it was sent.
    static func code(from callback: URL, state: String) throws -> String {
        guard callback.scheme?.lowercased() == callbackScheme,
              callback.host()?.lowercased() == "oauth"
        else { throw MastodonSignInError.unreadable }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // **The state before anything the answer says**, a refusal included: RFC 6749 §4.1.2.1
        // has the server send it back on an error as on a code, and an `error=` that does not
        // carry this attempt's state is not this attempt's answer. Acted on unchecked, anything
        // able to open this app's callback could walk a sign-in down its ladder — a registration
        // and a page for each rung.
        guard value("state") == state else { throw MastodonSignInError.stateMismatch }
        if let error = value("error") {
            throw error == "invalid_scope" ? MastodonSignInError.invalidScope : MastodonSignInError.denied
        }
        guard let code = value("code"), !code.isEmpty else { throw MastodonSignInError.unreadable }
        return code
    }

    /// The token, and **what the server says it granted** — which is not always what was asked
    /// for. `scope` is nothing where the server sent none; RFC 6749 lets it out only when the
    /// grant is exactly the request.
    func exchange(
        code: String, verifier: String, clientID: String, clientSecret: String,
        scopes: String = MastodonOAuth.reading
    ) async throws -> (accessToken: String, scope: String?) {
        struct Issued: Decodable {
            let access_token: String
            let scope: String?
        }
        let answer: Issued = try await post("/oauth/token", [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", Self.redirect),
            ("code_verifier", verifier),
            ("scope", scopes),
        ])
        guard !answer.access_token.isEmpty else { throw MastodonSignInError.unreadable }
        return (answer.access_token, answer.scope)
    }

    func verify(_ token: MastodonToken) async throws {
        guard let url = Host.httpsURL(host: host, path: "/api/v1/accounts/verify_credentials")
        else { throw MastodonSignInError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonSignInError.http(response.statusCode)
        }
    }

    /// Asks the server to forget the token. Best effort: signing out is done on this device
    /// before this is asked, and nothing it answers changes that.
    public func revoke(_ token: MastodonToken) async {
        guard let request = Self.form(host: host, path: "/oauth/revoke", [
            ("client_id", token.clientID),
            ("client_secret", token.clientSecret),
            ("token", token.accessToken),
        ]) else { return }
        _ = try? await sender.send(request)
    }

    private struct Refusal: Decodable { let error: String }

    private func post<Answer: Decodable>(
        _ path: String, _ fields: [(String, String)]
    ) async throws -> Answer {
        guard let request = Self.form(host: host, path: path, fields) else {
            throw MastodonSignInError.unreadable
        }
        let (body, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let refusal = (try? JSONDecoder().decode(Refusal.self, from: body))?.error
            if refusal == "invalid_client" { throw MastodonSignInError.clientRejected }
            // The server's own word that it is the scopes it will not have: `invalid_scope` at
            // the token, and a registration it refuses for them — a 422 whose sentence names
            // them, which is read in English because it is asked for in English (`form`). Only a 4xx that says so — a
            // failed connection, a 5xx, or a refusal about anything else stays what it was.
            if (400..<500).contains(response.statusCode), let refusal,
               refusal.lowercased().contains("scope")
            {
                throw MastodonSignInError.invalidScope
            }
            throw MastodonSignInError.http(response.statusCode)
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: body) else {
            throw MastodonSignInError.unreadable
        }
        return answer
    }

    /// A transport failure is `.unreachable`; a reader walking away is `.cancelled`.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await sender.send(request)
        } catch {
            if Task.isCancelled || Cancellation.happened(error) {
                throw MastodonSignInError.cancelled
            }
            throw MastodonSignInError.unreachable
        }
    }

    static func form(host: String, path: String, _ fields: [(String, String)]) -> URLRequest? {
        guard let url = Host.httpsURL(host: host, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setForm(fields)
        // **Answered in English, whatever this device speaks** (#298). A Mastodon writes its
        // refusal of a registration in the language the request asks for — "Validation failed:
        // Scopes doesn't match those configured on the server." reads 校驗失敗：範圍… to a
        // device set to Chinese — and that sentence is all that says the refusal is about the
        // scopes (`post`). Left to the system's header, a reader in any language but English
        // would have the refusal read as a plain failure, and the sign-in would not fall back.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }
}

extension URLRequest {
    /// `fields` as this request's form body, and the header that says so — the one encoding a
    /// sign-in and a signed-in write both send.
    ///
    /// Everything but RFC 3986's unreserved characters is escaped, so a `+`, `&` or `=` inside
    /// a secret or a status stays inside it.
    mutating func setForm(_ fields: [(String, String)]) {
        func escape(_ value: String) -> String {
            var unreserved = CharacterSet.alphanumerics
            unreserved.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        httpBody = Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }
}

/// The one door a signed-in request goes through (#25b reads Home and lists here).
///
/// The address is built from the token's own host, so the token is only ever sent there; a
/// redirect that leaves that origin is refused by `CappedBody`.
///
/// **Only a confirmed 401 signs out.** A 401 from any endpoint but the account check is asked
/// again of the account check, because a proxy in front of one path, or one endpoint's own rule,
/// must not wipe a token that works. Confirmed, the token is forgotten — only if it is still the
/// one held, so a late answer about a replaced token cannot take the new one — and `.signedOut`
/// is thrown. 403, 5xx and a failed connection leave it alone.
public struct MastodonAuthorized: Sendable {
    public let token: MastodonToken
    private let sender: any HTTPSender
    private let store: any MastodonTokenStore

    public init(token: MastodonToken, sender: any HTTPSender, store: any MastodonTokenStore) {
        self.token = token
        self.sender = sender
        self.store = store
    }

    static let accountCheck = "/api/v1/accounts/verify_credentials"

    public func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await finish(try await send(path: path, query: query), path: path)
    }

    /// A form POST through the same door: the token, the 401 rule, and never off this host.
    public func post(path: String, form: [(String, String)]) async throws -> Data {
        try await finish(try await send(path: path, method: "POST", form: form), path: path)
    }

    /// Who the reader is on this source, as `@user@host` — the spelling `Note.handle` takes, so a
    /// post can be told to be theirs by comparing the two (#109).
    ///
    /// **Asked of the source and never written down.** It is the account check's own answer, and
    /// a sign-in to a different account on the same host is a different answer: remembering it
    /// would be this device deciding whose posts are whose.
    public func handle() async throws -> String {
        struct Me: Decodable { let acct: String }
        let data = try await get(path: Self.accountCheck)
        guard let me = try? MastodonJSON.decoder.decode(Me.self, from: data) else {
            throw MastodonWriteError.unreadable
        }
        return StatusDTO.handle(me.acct, host: token.host)
    }

    /// A DELETE through the same door (#109): taking back what the reader wrote.
    public func delete(path: String) async throws -> Data {
        try await finish(try await send(path: path, method: "DELETE"), path: path)
    }

    private func finish(_ result: (Data, status: Int), path: String) async throws -> Data {
        switch result.status {
        case 200..<300:
            return result.0
        case 401:
            if path != Self.accountCheck,
               (try? await send(path: Self.accountCheck))?.status != 401
            {
                throw MastodonAuthError.http(401)
            }
            guard (try? store.forget(token)) == true else { throw MastodonAuthError.http(401) }
            throw MastodonAuthError.signedOut
        default:
            throw MastodonAuthError.http(result.status)
        }
    }

    private func send(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        form: [(String, String)]? = nil
    ) async throws -> (Data, status: Int) {
        guard let url = Host.httpsURL(host: token.host, path: path, query: query) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form { request.setForm(form) }
        let (body, response) = try await sender.send(request)
        return (body, response.statusCode)
    }
}
