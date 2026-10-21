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

/// A request made with a token whose content the source would not take (422), and its answer
/// as sent — which says what was refused, and is a stranger's words.
public struct MastodonUnprocessable: Error, Equatable, Sendable {
    public let body: Data
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
    ///
    /// **`carried` is what the sign-in held brings to either answer** (#347,
    /// `MastodonParts.carried`): the parts it was asked for where it stood. Reading and
    /// acting keeps every word of them; reading alone keeps the ones that read and asks for
    /// none that acts. `ticking` are parts ticked beside the answer — a first sign-in raised
    /// from a part's lock — which ride the same way. With neither, a choice is the string it
    /// always was.
    public static func scopes(
        search: Bool = true, writing wanted: Bool, bookmarks: Bool = true,
        notices: Bool = false, carried: String? = nil, ticking more: Set<MastodonPart> = []
    ) -> String {
        var ticked: Set<MastodonPart> = more.union([.reading])
        if search { ticked.insert(.search) }
        if wanted { ticked.insert(.acting) }
        if wanted, bookmarks { ticked.insert(.bookmarks) }
        if notices { ticked.insert(.notices) }
        return MastodonParts.page(held: carried, ticked: ticked, readOnly: !wanted)
    }

    /// The parts the two answers and what a sign-in carries of notices decide between them:
    /// never carried from the sign-in held by any other rule (`scopes`).
    public static let chosen: Set<MastodonPart> = [.reading, .search, .acting, .bookmarks, .notices]

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
    ///
    /// **`pending` is handed the token before it is checked** (#347), so whoever keeps a note
    /// of sign-ins made and not yet kept writes it down while nothing has been awaited on
    /// it: a quit during the check then leaves a note to end it by. Where the note cannot be
    /// taken the token is not checked, and comes back as one that could not be kept.
    /// **Not a token shown to be handed back** (`handedBack`): it was made by an earlier
    /// sign-in, here or on another device, and is not this one's to end.
    ///
    /// **`accountID` and `handle` are whose sign-in the check said it is**, off the answer
    /// the check already asks for — so a sign-in is named with no ask of its own, whatever it
    /// may do. Nothing where the check failed or named nobody (`MastodonWho.said`).
    public func signIn(
        as app: MastodonApp, asking page: String? = nil, through browser: any OAuthBrowser,
        pending: (@Sendable (MastodonToken) async throws -> Void)? = nil
    ) async throws -> (
        token: MastodonToken, failed: MastodonSignInError?, accountID: String?, handle: String?, handedBack: Bool
    ) {
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
        let handedBack = issued.handedBack
        do {
            if !handedBack { try await pending?(token) }
        } catch {
            return (token, .keychain, nil, nil, handedBack)
        }
        do {
            let who = try await verify(token)
            return (token, nil, who.id, who.handle, handedBack)
        } catch {
            return (token, error as? MastodonSignInError ?? .unreachable, nil, nil, handedBack)
        }
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
        // Only `access_denied` is the person's no (RFC 6749 §4.1.2.1). Anything else the source
        // says went wrong — `server_error`, `temporarily_unavailable` — is a failure of its own.
        switch value("error") {
        case "invalid_scope"?: throw MastodonSignInError.invalidScope
        case "access_denied"?: throw MastodonSignInError.denied
        case .some: throw MastodonSignInError.unreadable
        case nil: break
        }
        guard let code = value("code"), !code.isEmpty else { throw MastodonSignInError.unreadable }
        return code
    }

    /// The token, and **what the server says it granted** — which is not always what was asked
    /// for. `scope` is nothing where the server sent none; RFC 6749 lets it out only when the
    /// grant is exactly the request. `handedBack` where the answer shows the token was made
    /// before this trade (`handedBack(made:answered:after:)`).
    func exchange(
        code: String, verifier: String, clientID: String, clientSecret: String,
        scopes: String = MastodonOAuth.reading
    ) async throws -> (accessToken: String, scope: String?, handedBack: Bool) {
        struct Issued: Decodable {
            let access_token: String
            let scope: String?
            let created_at: Int?
        }
        let asked = ContinuousClock.now
        let (answer, date): (Issued, String?) = try await posted("/oauth/token", [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", Self.redirect),
            ("code_verifier", verifier),
            ("scope", scopes),
        ])
        guard !answer.access_token.isEmpty else { throw MastodonSignInError.unreadable }
        let handedBack = Self.handedBack(made: answer.created_at, answered: date, after: asked.duration(to: .now))
        return (answer.access_token, answer.scope, handedBack)
    }

    /// Checks that the source honours `token`, and hands back who its answer says the token
    /// signs in (`MastodonWho.said`): nobody, where it names none.
    @discardableResult
    func verify(_ token: MastodonToken) async throws -> MastodonWho {
        guard let url = Host.httpsURL(host: host, path: "/api/v1/accounts/verify_credentials")
        else { throw MastodonSignInError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonSignInError.http(response.statusCode)
        }
        return MastodonWho.said(body, at: host)
    }

    /// Where a source gives its own account of a token (#347). Fixed on the host, as every
    /// address here is.
    static let tokenInfoPath = "/oauth/token/info"
    /// The most words a source's account of a token is read for.
    static let tokenInfoWords = 128

    /// The words `token` holds **as its source says** (#347) — what a sign-in this device did
    /// not make itself is believed to hold, and nothing a package wrote beside it. Nothing,
    /// where the source answered and named no list of them.
    ///
    /// Read as a stranger's: from the token's own host, bounded, and for the list alone.
    public func words(of token: MastodonToken) async throws -> [String]? {
        guard let url = Host.httpsURL(host: host, path: Self.tokenInfoPath) else { throw MastodonSignInError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonSignInError.http(response.statusCode)
        }
        guard let said = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = said["scope"] as? [Any], entries.count <= Self.tokenInfoWords
        else { return nil }
        let words = entries.compactMap { $0 as? String }
        guard words.count == entries.count, words.allSatisfy(MastodonRegistration.isWord) else { return nil }
        return words
    }

    /// Asks the server to end a sign-in, and says what it answered. Best effort: signing out
    /// is done on this device before this is asked, and nothing it answers changes that.
    ///
    /// **Only a 2xx is the source saying it has** — it answers so the first time and every
    /// time after. **A 403 saying `unauthorized_client` is a refusal that asking again will
    /// not change**: the sign-in is not this registration's to end. Anything else is no
    /// answer to go by.
    @discardableResult
    public func revoke(_ left: MastodonLeft) async -> MastodonEnd {
        guard let request = Self.form(host: host, path: "/oauth/revoke", [
            ("client_id", left.clientID),
            ("client_secret", left.clientSecret),
            ("token", left.accessToken),
        ]), let (body, response) = try? await sender.send(request)
        else { return .unanswered }
        if (200..<300).contains(response.statusCode) { return .ended }
        // The source's own word for it, and not any 403: one from something in front of the
        // source says nothing of whose the sign-in is.
        let said = (try? JSONDecoder().decode(Refusal.self, from: body))?.error
        return response.statusCode == 403 && said == "unauthorized_client" ? .refused : .unanswered
    }

    private struct Refusal: Decodable { let error: String }

    private func post<Answer: Decodable>(
        _ path: String, _ fields: [(String, String)]
    ) async throws -> Answer {
        try await posted(path, fields).answer
    }

    /// `post`, and the moment the server says it answered, as its `Date` header spells it.
    private func posted<Answer: Decodable>(
        _ path: String, _ fields: [(String, String)]
    ) async throws -> (answer: Answer, date: String?) {
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
        return (answer, response.value(forHTTPHeaderField: "Date"))
    }

    /// Whether a token its answer dates `made` was made before the trade that answer, dated
    /// `answered`, belongs to (#347): handed back, and so a sign-in somebody already has.
    ///
    /// A Mastodon dates a token the second it makes it, and a token handed back keeps its
    /// first date. `took` is how long the trade took, as this device counted it.
    ///
    /// **Shown only where the token cannot have been made by this trade**: both dates are
    /// whole seconds, so the token was made before the second after `made`, and the trade
    /// was sent no sooner than `took` before `answered`. It is handed back where the first
    /// is no later than the second — two seconds apart for a server that answers at once,
    /// and more for one that is slow. **Anything less certain — or either date missing or
    /// unreadable — is a token made here**, which is what every token was before this: one
    /// not kept is then ended, where a fresh one read as handed back would be dropped live.
    static func handedBack(made: Int?, answered: String?, after took: Duration) -> Bool {
        guard let made, let answered else { return false }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: answered) else { return false }
        let waited = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        return Double(made + 1) <= date.timeIntervalSince1970 - max(0, waited)
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

/// The hosts whose source said, **in its own words**, that the sign-in held there is over
/// (#347) — noted by the door that heard it, and taken once by whoever goes on to end the
/// earlier sign-ins this device left there.
///
/// **A bare 401 is not that.** Anything in front of a source can answer 401 to everything — a
/// maintenance page behind a password, a firewall, a network's own sign-in page — and ending
/// what was left on its word would sign the person's other devices out for good once it lifts.
public final class MastodonEndings: @unchecked Sendable {
    private let lock = NSLock()
    private var said: Set<String> = []
    private var dropped: Set<String> = []

    public init() {}

    func note(_ host: String, saidBySource: Bool, dropped count: Int) {
        lock.withLock {
            if saidBySource { said.insert(host.lowercased()) }
            if count > 0 { dropped.insert(host.lowercased()) }
        }
    }

    /// Whether `host`'s source said so since this was last asked. Asked once: the answer
    /// goes with the asking.
    public func takeSaid(_ host: String) -> Bool {
        lock.withLock { said.remove(host.lowercased()) != nil }
    }

    /// The hosts where a 401 that was not the source's own took earlier sign-ins off this
    /// device unended, since this was last asked: what the person is yet to be told.
    public func takeDropped() -> Set<String> {
        lock.withLock {
            defer { dropped = [] }
            return dropped
        }
    }

    /// Whether a 401's body is a Mastodon's own answer to a token it does not honour — JSON
    /// that names an `error`, as it answers one revoked ("The access token was revoked") and
    /// one it never knew ("The access token is invalid"). A page, a line of text and nothing
    /// at all are somebody else's.
    ///
    /// **JSON naming an `error` from something that is not the source still passes**: the
    /// sentence itself is the source's to word, and in the language asked for, so it is
    /// not read. To follow up, once a capture of a revoked token's 401 shows the source
    /// sends it: require `WWW-Authenticate: Bearer … error="invalid_token"` as well.
    static func isSourcesOwn(_ body: Data) -> Bool {
        struct Said: Decodable { let error: String }
        return (try? JSONDecoder().decode(Said.self, from: body))?.error.isEmpty == false
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
///
/// **Whether the source said so itself is noted apart** (#347, `MastodonEndings`): any 401
/// from the account check forgets the token, as it always has, and only one that reads as the
/// source's own answer is a reason to end anything else. Any other takes the earlier sign-ins
/// left there off the device unended, with the token and in one step of the store.
public struct MastodonAuthorized: Sendable {
    public let token: MastodonToken
    private let sender: any HTTPSender
    private let store: any MastodonTokenStore
    private let endings: MastodonEndings?

    public init(
        token: MastodonToken, sender: any HTTPSender, store: any MastodonTokenStore,
        endings: MastodonEndings? = nil
    ) {
        self.token = token
        self.sender = sender
        self.store = store
        self.endings = endings
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

    /// `getLinked(path:query:)`, with a not-found of the address told apart as `getAtAddress`
    /// tells it (#315, #318): a list paged by its `Link` header at an address a host may not have.
    public func getLinkedAtAddress(path: String, query: [URLQueryItem] = []) async throws -> (body: Data, link: String?) {
        let result = try await send(path: path, query: query)
        if MastodonHostNotFound.isOfTheAddress(status: result.status, body: result.body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        return (try await finish(result, path: path), result.link)
    }

    /// An act at an address a host may not have, through the same door (#315, #318): `method`,
    /// with `form` where it has one. A not-found of the address throws
    /// `MastodonHostMoreError.noSuchAddress`, as `getAtAddress` does; a 422 throws
    /// `MastodonUnprocessable` with the source's answer, as `patch(path:form:)` does; anything
    /// else is what `get` throws.
    public func actAtAddress(path: String, method: String, form: [(String, String)]? = nil) async throws -> Data {
        let result = try await send(path: path, method: method, form: form)
        if MastodonHostNotFound.isOfTheAddress(status: result.status, body: result.body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
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

    /// `getAtAddress` and `getInScope` at once (#321): a not-found of the address throws
    /// `MastodonHostMoreError.noSuchAddress`, a refusal for want of a scope
    /// `MastodonScopeError.outside`, and anything else what `get` throws.
    public func getAtAddressInScope(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let result = try await send(path: path, query: query)
        if MastodonHostNotFound.isOfTheAddress(status: result.status, body: result.body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        if MastodonScopeRefusal.isOne(status: result.status, body: result.body, authenticate: result.authenticate) {
            throw MastodonScopeError.outside
        }
        return try await finish(result, path: path)
    }

    public func post(path: String, form: [(String, String)]) async throws -> Data {
        try await post(path: path, form: form, headers: [:])
    }

    /// `post(path:form:)`, with what was sent refused told from every other refusal (#334): a 422
    /// throws `MastodonUnprocessable` with the source's answer, as `patch(path:form:)` does.
    public func postRefusable(path: String, form: [(String, String)]) async throws -> Data {
        let result = try await send(path: path, method: "POST", form: form)
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
        return try await finish(result, path: path)
    }

    /// `post(path:form:)`, with headers of the request's own beside the door's.
    public func post(path: String, form: [(String, String)], headers: [String: String]) async throws -> Data {
        try await finish(try await send(path: path, method: "POST", form: form, headers: headers), path: path)
    }

    /// A POST carrying a file through the same door: the token, the 401 rule, and never off
    /// this host. **`limit` is the caller's**, not lowered to `MultipartBody.byteLimit` — a
    /// film the source takes is larger than a profile picture, and the wrapper's own ceiling
    /// is not the source's. The body is made before anything is sent. A 422 throws
    /// `MastodonUnprocessable` with the source's answer, as `patch(path:parts:)` does, so a
    /// file the source refused is not taken for a post that may have landed.
    public func post(
        path: String, parts: [MultipartPart], limit: Int, headers: [String: String] = [:]
    ) async throws -> Data {
        let body = try MultipartBody(parts, limit: limit)
        let result = try await send(path: path, method: "POST", parts: body, headers: headers)
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
        return try await finish(result, path: path)
    }

    /// A PATCH carrying a body of several parts through the same door (#312): a file's bytes
    /// beside fields of text, with the token, the 401 rule, and never off this host.
    ///
    /// **The body is made before anything is sent** — every name checked, the whole of it
    /// under `limit` — and one that will not do is thrown as a `MultipartError`, with nothing
    /// asked of the source. `limit` is for a source that says it takes less: it only ever
    /// lowers the bound, and one above `MultipartBody.byteLimit` is that. As `patch(path:form:)`,
    /// a 422 throws `MastodonUnprocessable` with the source's answer.
    public func patch(
        path: String, parts: [MultipartPart], limit: Int = MultipartBody.byteLimit
    ) async throws -> Data {
        let body = try MultipartBody(parts, limit: min(limit, MultipartBody.byteLimit))
        let result = try await send(path: path, method: "PATCH", parts: body)
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
        return try await finish(result, path: path)
    }

    /// A PATCH carrying a form through the same door (#312). As `post(path:form:)`, with what
    /// was sent refused told from every other refusal: a 422 throws `MastodonUnprocessable`
    /// with the source's answer, which says what it would not take.
    public func patch(path: String, form: [(String, String)]) async throws -> Data {
        let result = try await send(path: path, method: "PATCH", form: form)
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
        return try await finish(result, path: path)
    }

    /// A PUT with no body through the same door (#321): a reaction put on an announcement. As
    /// `patch(path:form:)`, a 422 throws `MastodonUnprocessable` with the source's answer.
    public func put(path: String) async throws -> Data {
        let result = try await send(path: path, method: "PUT")
        if result.status == 422 { throw MastodonUnprocessable(body: result.body) }
        return try await finish(result, path: path)
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
        guard let handle = try await who().handle else { throw MastodonWriteError.unreadable }
        return handle
    }

    /// Who the reader is on this source, as its account check says through this sign-in
    /// (`MastodonWho.said`): the id it gives the account, which names it whatever it is
    /// renamed to, and a handle only where it is this source's own.
    public func who() async throws -> MastodonWho {
        let data = try await get(path: Self.accountCheck)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw MastodonWriteError.unreadable
        }
        return MastodonWho.said(data, at: token.host)
    }

    /// A DELETE through the same door (#109): taking back what the reader wrote.
    public func delete(path: String) async throws -> Data {
        try await finish(try await send(path: path, method: "DELETE"), path: path)
    }

    /// A DELETE carrying a form through the same door (#314): a block of a whole server taken
    /// back, which the source names by the form and not by the address.
    public func delete(path: String, form: [(String, String)]) async throws -> Data {
        try await finish(try await send(path: path, method: "DELETE", form: form), path: path)
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
            let check = path == Self.accountCheck ? result : try? await send(path: Self.accountCheck)
            guard let check, check.status == 401 else { throw MastodonAuthError.http(401) }
            let own = MastodonEndings.isSourcesOwn(check.body)
            // One step in the store: no pass over what was left can come between the two.
            guard let dropped = try? store.forget(token, saidBySource: own) else { throw MastodonAuthError.http(401) }
            endings?.note(token.host, saidBySource: own, dropped: dropped)
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
