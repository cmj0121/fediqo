import CryptoKit
import Foundation
import Security

// Signing in to a Mastodon server: OAuth 2 authorization code with PKCE (S256) and `state`, on
// the server's own page, asking for what reading needs and — where the reader said so — for what
// writing needs.
//
// The app is registered once per host, for every word a sign-in may come to be asked for
// (`MastodonRegistration`), and its registration kept (`MastodonApp`), so a sign-in after a
// sign-out, and a page that asks for more, do not register again; Mastodon tokens do not expire, so there is no
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
    /// The server will not have the scopes: a registration it refuses for them, or
    /// `invalid_scope` where a code is traded. A registration it was said of is dropped, so the
    /// next attempt registers afresh.
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

/// A request made with a token, refused for want of a scope the token was not issued with.
public enum MastodonScopeError: Error, Equatable, Sendable {
    case outside
}

/// A refusal for want of a scope, told from every other 403 by what the server said (#319) —
/// asked of a real one (`MastodonSearchCaptures`): a suspended login and a proxy's own rule
/// are 403 too, and neither is mended by signing in again for more.
public enum MastodonScopeRefusal {
    /// The server's sentence, as a Mastodon writes it in English.
    static let sentence = "this action is outside the authorized scopes"
    /// How much of an answer is looked at: the sentence is short, and a page is not read.
    static let bodyLength = 4_096

    /// Whether an answer refuses for want of a scope: a 403 whose `WWW-Authenticate` names the
    /// error RFC 6750 has for it, or whose body is the server's own sentence for it. The
    /// header is looked at first, since the sentence is written in the reader's language.
    public static func isOne(status: Int, body: Data, authenticate: String?) -> Bool {
        guard status == 403 else { return false }
        if authenticate?.contains("insufficient_scope") == true { return true }
        guard body.count <= bodyLength, let said = try? JSONSerialization.jsonObject(with: body) else { return false }
        return ((said as? [String: Any])?["error"] as? String)?.lowercased() == sentence
    }
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
    public static let reading = scopes(writing: false)
    /// Decision 32: reading on a server that has no `read:search`. Everything but finding an old
    /// post again works; that says to sign in again.
    public static let readingWithoutSearch = scopes(search: false, writing: false)
    /// What writing needs (#69), and no more: `write:statuses` is a post, a boost, a reply and
    /// taking any of them back; `write:favourites` is a favourite. **Nothing here follows anybody,
    /// changes a profile or touches a filter** — those are other `write:` scopes and this app asks
    /// for none of them.
    ///
    /// **Asked for only where the reader said so.** It is never part of the reading pair above, so
    /// a sign-in that refuses the writing part is byte-for-byte the sign-in this app made before
    /// this existed.
    public static let writing = MastodonParts.page(held: nil, ticked: [.acting])
    /// What bookmarking needs (#285), and no more: a bookmark put on a post at its source, and
    /// taken off it. **Apart from `writing` and not a third word in it**, because `writes(_:)`
    /// asks for every word of that, and a sign-in made before this existed — which posts, boosts
    /// and favourites exactly as it did — would then read as one that cannot write at all.
    ///
    /// Asked for with the writing part and never without it: reading alone asks for what it
    /// always asked.
    public static let bookmarking = MastodonParts.page(held: nil, ticked: [.bookmarks])
    /// What reading notices needs (#323), and no more: what the source says happened to the
    /// reader. **Apart from `reading` and not a fifth word in it**, for `bookmarking`'s reason
    /// turned the other way: every sign-in made before this asked for `reading` to the letter,
    /// and a registration made for it would stop being one this build may start on.
    ///
    /// **Asked for only where the reader pressed for it on the notices page** — no sign-in asks
    /// for it unasked, so one that never wanted notices is byte-for-byte what it was.
    ///
    /// Dismissing a notice — and letting through or letting go one the source held back — is an
    /// act, so its word is asked for beside this only where the writing part is asked for too
    /// (`MastodonPart.wordsBesideActing`), and is never a word in `writing`.
    public static let noticing = MastodonParts.page(held: nil, ticked: [.notices])

    /// The whole of what one sign-in asks for: reading, and the writing part after it where the
    /// reader agreed to it — with bookmarking after that, unless `bookmarks` is false, which is
    /// what a server with no bookmark scope is asked, and what a sign-in to act asked for
    /// before #285. Where `notices` is asked (#323), reading them comes after all of that, and
    /// dismissing them after it where the writing part is asked.
    ///
    /// **Reading first, writing next, then bookmarking, noticing and dismissing, always in this
    /// order**: one choice is one string, however it was reached.
    ///
    /// **The words and their order are the table's** (`MastodonParts.page`): this says which
    /// parts a choice ticks, and spells none of them. `search` is false for a server that has
    /// no search to allow (decision 32).
    public static func scopes(
        search: Bool = true, writing wanted: Bool, bookmarks: Bool = true,
        notices: Bool = false
    ) -> String {
        var ticked: Set<MastodonPart> = [.reading]
        if search { ticked.insert(.search) }
        if wanted { ticked.insert(.acting) }
        if wanted, bookmarks { ticked.insert(.bookmarks) }
        if notices { ticked.insert(.notices) }
        return MastodonParts.page(held: nil, ticked: ticked)
    }

    /// Whether a scope string bought reading notices (#323) — read scope by scope, as
    /// `writes(_:)` is.
    public static func notices(_ scopes: String?) -> Bool {
        MastodonParts.holds(.notices, in: scopes)
    }

    /// Whether a scope string bought dismissing notices (#323), read the same way.
    public static func dismisses(_ scopes: String?) -> Bool {
        MastodonParts.holdsBesideActing(.notices, in: scopes)
    }

    /// Whether a scope string bought searching (#319): `read:search` itself, or the whole of
    /// reading, which holds it — as the server names the two when it refuses for want of them.
    public static func searches(_ scopes: String?) -> Bool {
        MastodonParts.holds(.search, in: scopes) || MastodonParts.holdsEveryRead(in: scopes)
    }

    /// Whether a scope string bought bookmarking — read scope by scope, as `writes(_:)` is.
    public static func bookmarks(_ scopes: String?) -> Bool {
        MastodonParts.holds(.bookmarks, in: scopes)
    }

    /// Whether a scope string bought the writing part.
    ///
    /// **Compared scope by scope and never as a substring**, so a server that hands back the
    /// scopes in another order still reads as writing, and a scope that merely contains one of
    /// these words does not.
    public static func writes(_ scopes: String?) -> Bool {
        MastodonParts.holds(.acting, in: scopes)
    }

    let host: String
    private let sender: any HTTPSender

    public init(host: String, sender: any HTTPSender) {
        self.host = host.lowercased()
        self.sender = sender
    }

    /// Opens the server's page for `app`, checks the answer, trades the code for a token and
    /// checks that the token works. Nothing is saved here, **and nothing is revoked here**: the
    /// token is handed back with why its check failed, or nothing where it passed.
    ///
    /// **The page asks for `page`, which may be less than the registration was made for**
    /// (#347) — and never a word it was not made for: a server answers such a page with one of
    /// its own and sends nothing back, so it is refused here, before anything opens. Left out,
    /// the page asks for everything the registration records.
    ///
    /// A server answers the same words on the same registration with the token it already
    /// issued, so the one in hand may be the sign-in this device holds — and a check fails for a
    /// timeout or a 5xx as for a refusal. Whether to ask the server to end it is for whoever
    /// knows what is held.
    public func signIn(
        as app: MastodonApp, asking page: String? = nil, through browser: any OAuthBrowser
    ) async throws -> (token: MastodonToken, failed: MastodonSignInError?) {
        if let page, !MastodonRegistration.holds(page, on: app.scopes) {
            throw MastodonSignInError.unreadable
        }
        let pkce = PKCE.make()
        let state = PKCE.random(bytes: 16)
        let scopes = page ?? app.scopes ?? Self.reading
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
            return (token, error as? MastodonSignInError ?? .unreachable)
        }
        return (token, nil)
    }

    /// What a sign-in that asked for `asked` is written down as holding, from the server's own
    /// word about it: the scopes it named that were asked for, in the order they were asked, or
    /// all of `asked` where it named none — RFC 6749 lets the word out only when the grant is
    /// exactly the request. A narrower answer narrows; nothing in it can widen.
    static func granted(_ echo: String?, of asked: String) -> String {
        named(echo.map { $0.split(separator: " ").map(String.init) } ?? [], of: asked)
    }

    /// `granted(_:of:)`, for an answer that names its words one by one: a registration's.
    static func named(_ echo: [String], of asked: String) -> String {
        guard !echo.isEmpty else { return asked }
        let named = Set(echo)
        return asked.split(separator: " ").map(String.init).filter(named.contains).joined(separator: " ")
    }

    /// How long a client id or secret may be: a Mastodon's are forty-three characters.
    static let clientBytes = 512

    /// This app, registered on the server with the callback and `scopes`.
    ///
    /// **A server that refuses the registration for its scopes** — a 4xx whose own `error` says
    /// so — is `invalidScope`: it refuses the whole of it for one word it does not know, and
    /// names none. Any other refusal, and every failure that names no scope, is what it was.
    public func register(scopes: String = MastodonOAuth.reading) async throws -> MastodonApp {
        try await registered(for: scopes).app
    }

    /// `register(scopes:)`, and whether the server said which of the words asked it registered.
    ///
    /// **What is recorded is what was asked and the server named, never more** — all of what
    /// was asked where it named none, as an older server does. A page is only ever opened for
    /// words its registration records, so a word the server left out is asked on no page.
    ///
    /// **A registration that names a callback other than this app's is not one of ours**: a
    /// code sent there would be somebody else's to trade. It is refused, and nothing is kept.
    /// **Nor is one with no client id or secret, or one longer than `clientBytes`**: both are
    /// kept in the Keychain and sent on every page, and a server's word is not kept unbounded.
    public func registered(for scopes: String) async throws -> (app: MastodonApp, echoed: Bool) {
        let answer: Registered = try await post("/api/v1/apps", [
            ("client_name", Fediqo.name),
            ("redirect_uris", Self.redirect),
            ("scopes", scopes),
        ])
        guard answer.callbacks.allSatisfy({ $0 == Self.redirect }) else { throw MastodonSignInError.unreadable }
        for named in [answer.clientID, answer.clientSecret] {
            guard !named.isEmpty, named.utf8.count <= Self.clientBytes else { throw MastodonSignInError.unreadable }
        }
        let app = MastodonApp(
            host: host, clientID: answer.clientID, clientSecret: answer.clientSecret,
            scopes: Self.named(answer.scopes, of: scopes)
        )
        return (app, !answer.scopes.isEmpty)
    }

    /// A registration's answer. **Only the two keys must be there**; what it says of scopes and
    /// callbacks is read where it is said, as one string or as a list — a Mastodon has written
    /// both — and is nothing where it is neither.
    private struct Registered: Decodable {
        let clientID: String
        let clientSecret: String
        let scopes: [String]
        let callbacks: [String]

        private enum Key: String, CodingKey {
            case clientID = "client_id", clientSecret = "client_secret", scopes
            case callback = "redirect_uri", callbacks = "redirect_uris"
        }

        init(from decoder: any Decoder) throws {
            let said = try decoder.container(keyedBy: Key.self)
            clientID = try said.decode(String.self, forKey: .clientID)
            clientSecret = try said.decode(String.self, forKey: .clientSecret)
            func words(_ key: Key) -> [String] {
                if let list = try? said.decode([String].self, forKey: key) { return list }
                let one = (try? said.decode(String.self, forKey: key)) ?? ""
                return one.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            scopes = words(.scopes)
            callbacks = words(.callback) + words(.callbacks)
        }
    }

    /// The host's own list of the scope words it knows, or nothing where it gives none — a
    /// host that publishes no list, is slow, answers anything but 200, sends the ask elsewhere,
    /// or writes what cannot be read. **Nothing is an answer here and never a failure**: the
    /// registration is then asked as it is.
    ///
    /// Asked with no sign-in, of this host alone, and read as a stranger's writing
    /// (`MastodonRegistration.listed`). What bounds the body as it arrives, and refuses a
    /// redirect off the host, is the client this was built over.
    public func listedWords() async -> Set<String>? {
        guard let url = Host.httpsURL(host: host, path: MastodonRegistration.listPath) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (body, response) = try? await sender.send(request), response.statusCode == 200,
              let answered = response.url, answered.scheme == "https", answered.host() == url.host(),
              answered.port == url.port
        else { return nil }
        return MastodonRegistration.listed(in: body)
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
        // able to open this app's callback could end a sign-in the person is in the middle of,
        // and have its registration dropped.
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

    /// `get(path:query:)`, and beside the body what the answer's `Link` header says: where a
    /// list that pages by its own word names its next stretch. Nothing where it sent none.
    public func getLinked(path: String, query: [URLQueryItem] = []) async throws -> (body: Data, link: String?) {
        let answer = try await send(path: path, query: query)
        return (try await finish(answer, path: path), answer.link)
    }

    /// A form POST through the same door: the token, the 401 rule, and never off this host.
    /// As `get`, with a not-found of the address told from every other refusal: throws
    /// `MastodonHostMoreError.noSuchAddress` where the host says it has no such address
    /// (`MastodonHostNotFound`) — which is a word about the host, and nothing about the sign-in.
    public func getAtAddress(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let result = try await send(path: path, query: query)
        if MastodonHostNotFound.isOfTheAddress(status: result.status, body: result.body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        return try await finish(result, path: path)
    }

    /// As `get`, with a refusal for want of a scope told from every other 403 (#319): throws
    /// `MastodonScopeError.outside` where the server says the token was not issued with what
    /// the ask needs (`MastodonScopeRefusal`), and what `get` throws for any other refusal.
    public func getInScope(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let result = try await send(path: path, query: query)
        if MastodonScopeRefusal.isOne(status: result.status, body: result.body, authenticate: result.authenticate) {
            throw MastodonScopeError.outside
        }
        return try await finish(result, path: path)
    }

    public func post(path: String, form: [(String, String)]) async throws -> Data {
        try await post(path: path, form: form, headers: [:])
    }

    /// `post(path:form:)`, with headers of the request's own beside the door's.
    public func post(path: String, form: [(String, String)], headers: [String: String]) async throws -> Data {
        try await finish(try await send(path: path, method: "POST", form: form, headers: headers), path: path)
    }

    /// A PATCH carrying a body of several parts through the same door (#312): a file's bytes
    /// beside fields of text, with the token, the 401 rule, and never off this host.
    ///
    /// **The body is made before anything is sent** — every name checked, the whole of it
    /// under `limit` — and one that will not do is thrown as a `MultipartError`, with nothing
    /// asked of the source. `limit` is for a source that says it takes less: it only ever
    /// lowers the bound, and one above `MultipartBody.byteLimit` is that.
    public func patch(
        path: String, parts: [MultipartPart], limit: Int = MultipartBody.byteLimit
    ) async throws -> Data {
        let body = try MultipartBody(parts, limit: min(limit, MultipartBody.byteLimit))
        return try await finish(try await send(path: path, method: "PATCH", parts: body), path: path)
    }

    /// Who the reader is on this source, as `@user@host` — the spelling `Note.handle` takes, so a
    /// post can be told to be theirs by comparing the two (#109).
    ///
    /// **Asked of the source, and written down nowhere by this call.** It is the account check's
    /// own answer, and a sign-in to a different account on the same host is a different answer.
    /// Where it is remembered it is with the sign-in it was said through, and goes with it
    /// (`MastodonToken.accountID` and `handle`, in the sign-in's Keychain item) — never apart
    /// from one, which would be this device deciding whose posts are whose.
    public func handle() async throws -> String {
        try await who().handle
    }

    /// `handle()`, and beside it the id this source gives the account, where it says one: what
    /// names the account whatever it is renamed to, and what its own posts are read by.
    public func who() async throws -> (id: String?, handle: String) {
        struct Me: Decodable { let id: String?; let acct: String }
        let data = try await get(path: Self.accountCheck)
        guard let me = try? MastodonJSON.decoder.decode(Me.self, from: data) else {
            throw MastodonWriteError.unreadable
        }
        return (me.id, StatusDTO.handle(me.acct, host: token.host))
    }

    /// A DELETE through the same door (#109): taking back what the reader wrote.
    public func delete(path: String) async throws -> Data {
        try await finish(try await send(path: path, method: "DELETE"), path: path)
    }

    /// What one request was answered: its body, its status, and its `Link` and
    /// `WWW-Authenticate` headers where it sent them.
    private struct Answered {
        let body: Data
        let status: Int
        let link: String?
        let authenticate: String?
    }

    private func finish(_ result: Answered, path: String) async throws -> Data {
        switch result.status {
        case 200..<300:
            return result.body
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
        form: [(String, String)]? = nil,
        parts: MultipartBody? = nil,
        headers: [String: String] = [:]
    ) async throws -> Answered {
        guard let url = Host.httpsURL(host: token.host, path: path, query: query) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Before the door's own, which nothing handed in replaces.
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form { request.setForm(form) }
        if let parts {
            request.setValue(parts.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = parts.data
        }
        let (body, response) = try await sender.send(request)
        return Answered(
            body: body, status: response.statusCode, link: response.value(forHTTPHeaderField: "Link"),
            authenticate: response.value(forHTTPHeaderField: "WWW-Authenticate")
        )
    }
}
