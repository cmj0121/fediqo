import Foundation
import Security

/// What a Mastodon sign-in leaves on this device: the access token, and the app registration it
/// was issued to, which revoking it needs.
///
/// **It prints as its host and nothing else**, for `ForumCredential`'s reason: a description,
/// an error or a mirror is how a secret reaches a log. No `Codable` either; the Keychain value is
/// written by a private wire type below, and only there.
public struct MastodonToken: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let host: String
    public let accessToken: String
    public let clientID: String
    public let clientSecret: String
    /// What the sign-in that issued it asked for, or **nothing for a token kept before this app
    /// asked the reader anything about writing** (#69).
    ///
    /// The two are not the same fact and must not be spelt the same way: a token with the reading
    /// scopes written down is one whose reader was offered the writing part and said no, and a
    /// token with nothing written down is one whose reader was never asked. Both read and neither
    /// writes; only the second is owed the question.
    public let scopes: String?
    /// What the sign-in that issued it asked the source for, at its widest (#285), or nothing for
    /// a token kept before this was written down. **Not what it may do** — that is `scopes` — but
    /// what tells a sign-in that asked for bookmarks and was not given them from one made before
    /// bookmarks were asked for at all: the first is not asked again, and the second is owed it.
    public let asked: String?
    /// Whose sign-in this is, as its source said through it: the id the source gives the
    /// account, and its handle as `@user@host`. Nothing until the source has been asked — a
    /// token kept before this was written down, or one a package brought. **Kept with the
    /// sign-in**, so what the person writes can be named as theirs with no network at all.
    public let accountID: String?
    public let handle: String?

    public init(
        host: String, accessToken: String, clientID: String, clientSecret: String,
        scopes: String? = nil, asked: String? = nil, accountID: String? = nil, handle: String? = nil
    ) {
        self.accountID = accountID
        self.handle = handle
        self.host = host.lowercased()
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.asked = asked
    }

    /// This token, written down as issued by a sign-in that asked for `asked` — the fact beside
    /// it, and never the token itself.
    public func recorded(asked: String?) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            scopes: scopes, asked: asked, accountID: accountID, handle: handle
        )
    }

    /// This token, written down as the sign-in of the account its source named through it.
    public func named(accountID: String, handle: String) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            scopes: scopes, asked: asked, accountID: accountID, handle: handle
        )
    }

    /// Whether this sign-in asked for bookmarks and was not given them (#285).
    public var bookmarksRefused: Bool {
        MastodonOAuth.bookmarks(asked) && !MastodonOAuth.bookmarks(scopes)
    }

    /// Whether this sign-in asked for notices and was not given them (#323).
    public var noticesRefused: Bool {
        MastodonOAuth.notices(asked) && !MastodonOAuth.notices(scopes)
    }

    public var app: MastodonApp {
        MastodonApp(host: host, clientID: clientID, clientSecret: clientSecret)
    }

    public var description: String { "MastodonToken(host: \(host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host]) }
}

/// This app's registration on one server, kept so a second sign-in does not register again.
/// Prints as its host, as the token does: the secret is a secret.
public struct MastodonApp: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let host: String
    public let clientID: String
    public let clientSecret: String
    /// The scopes it was registered for, or nothing for one kept before they were recorded. A
    /// registration made for scopes the sign-in in hand does not ask for — including the other
    /// answer to #69's writing question — is registered again; see `MastodonOAuth.known(writing:)`.
    public let scopes: String?

    public init(host: String, clientID: String, clientSecret: String, scopes: String? = nil) {
        self.host = host.lowercased()
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    public var description: String { "MastodonApp(host: \(host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host]) }
}

/// Where a Mastodon token and its app registration live. A protocol so `swift test` never
/// touches the real Keychain — see `ForumCredentialStore`.
public protocol MastodonTokenStore: Sendable {
    func token(host: String) throws -> MastodonToken?
    func save(_ token: MastodonToken) throws
    func forget(host: String) throws
    /// Forgets `token` only while it is still the one held for its host, and says whether it was.
    /// A late 401 for a token the reader has since replaced must not take the new one with it.
    func forget(_ token: MastodonToken) throws -> Bool
    /// What each held token's sign-in bought, **without reading one** (#69).
    ///
    /// **The scopes ride as an item attribute rather than inside the value, and that is the whole
    /// reason this is a separate question from `token(host:)`.** Reading a generic password's
    /// *data* is what makes macOS ask the reader to allow access; reading its attributes does not.
    /// A source page that had to open every token to say what may be done on its rows would put an
    /// access prompt in front of the launch screen, once per source — and in `swift test` it hangs
    /// on the first one. The scopes are not a secret; the token is.
    func grants() throws -> [String: MastodonGrant]
    /// The hosts whose sign-in may bookmark (#285), **without reading a token** — `grants()`'s
    /// rule and for its reason, read off the same attribute. Apart from `grants()` because it is
    /// another question: a sign-in made before bookmarks were asked for writes as it always did,
    /// and only lacks this.
    func bookmarking() throws -> Set<String>
    /// The hosts whose sign-in asked for bookmarks and was not given them (#285), **without
    /// reading a token** — so the row and Account stop offering to ask a source that has already
    /// answered, across a relaunch. A sign-in made before bookmarks were asked for is in neither
    /// this nor `bookmarking()`.
    func bookmarksRefused() throws -> Set<String>
    /// The hosts whose sign-in may read notices (#323), **without reading a token** —
    /// `bookmarking()`'s rule, off the same attribute. A sign-in made before notices were asked
    /// for is not among them, and does everything it did.
    func noticing() throws -> Set<String>
    /// The hosts whose sign-in may dismiss notices (#323), read the same way.
    func dismissing() throws -> Set<String>
    /// The hosts whose sign-in asked for notices and was not given them (#323), **without
    /// reading a token** — `bookmarksRefused()`'s rule: a sign-in that never asked is in neither
    /// this nor `noticing()`.
    func noticesRefused() throws -> Set<String>
    /// `noticing()`, `dismissing()` and `noticesRefused()` at once, each nothing where it could
    /// not be had — for whoever asks all three, so a store that answers them off one look makes
    /// that look once. A store that does not say is asked each in turn.
    func noticeGrants() -> MastodonNoticeGrants

    func app(host: String) throws -> MastodonApp?
    func save(_ app: MastodonApp) throws
    func forgetApp(host: String) throws
}

extension MastodonTokenStore {
    /// Which hosts hold a token, **without reading one** — the keys of `grants()`, so that the two
    /// answers are one query and cannot come to disagree about who is signed in.
    public func signedInHosts() throws -> Set<String> {
        Set(try grants().keys)
    }

    /// No host, for a store that does not say: nothing is bookmarked through a sign-in nobody
    /// can show bought it.
    public func bookmarking() throws -> Set<String> { [] }

    /// No host, for a store that does not say: a source nobody can show was asked is asked.
    public func bookmarksRefused() throws -> Set<String> { [] }

    /// No host, for a store that does not say: no notice is read through a sign-in nobody can
    /// show bought it.
    public func noticing() throws -> Set<String> { [] }

    /// No host, for a store that does not say, as `noticing()` is.
    public func dismissing() throws -> Set<String> { [] }

    /// No host, for a store that does not say: a source nobody can show was asked is asked.
    public func noticesRefused() throws -> Set<String> { [] }

    /// The three asked one by one, each failing by itself.
    public func noticeGrants() -> MastodonNoticeGrants {
        MastodonNoticeGrants(
            noticing: try? noticing(), dismissing: try? dismissing(), refused: try? noticesRefused()
        )
    }
}

/// What the held sign-ins may do with notices (#323), by host: `MastodonTokenStore`'s three
/// answers about them together. One that is nothing could not be read, which is not "no host".
public struct MastodonNoticeGrants: Equatable, Sendable {
    public let noticing: Set<String>?
    public let dismissing: Set<String>?
    public let refused: Set<String>?

    public init(noticing: Set<String>?, dismissing: Set<String>?, refused: Set<String>?) {
        self.noticing = noticing
        self.dismissing = dismissing
        self.refused = refused
    }
}

/// The query dictionaries, built where a test can read them back.
///
/// A generic password and not an internet password: a token is not a website's password, must
/// never be offered by AutoFill on the server's own login form, and cannot collide with
/// `ForumKeychain`'s items. The service is what makes an item this app's — every query is scoped
/// by it, so nothing here can read or delete another program's item.
///
/// **Where the item actually lives differs by platform.** On iOS it is in the data-protection
/// keychain and `WhenUnlockedThisDeviceOnly` holds: never synced, never restored onto other
/// hardware. On macOS, as with the forum password, it lands in the file-based login keychain —
/// `kSecUseDataProtectionKeychain` needs a team-signed build, and an ad-hoc Debug build gets
/// -34018. That keychain never syncs, but it ignores the accessibility attribute, so
/// "this device only" is not enforced there. Once the app is team-signed, adding
/// `kSecUseDataProtectionKeychain` to every query here moves it.
public enum MastodonKeychain {
    public static let service = "fediqo.mastodon"
    /// The app registration's items, apart from the tokens so that listing who is signed in never
    /// counts a registration.
    public static let appService = "fediqo.mastodon.app"

    /// `kSecAttrSynchronizable` written false rather than left to a default, and
    /// `WhenUnlockedThisDeviceOnly`: the token does not follow the Apple account to another
    /// device, and is not restored from a backup onto other hardware.
    public static func lookup(host: String, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.lowercased(),
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// **The scopes ride as an attribute as well as inside the value** (#69), so that what may be
    /// done on a source is readable without reading the secret — see `MastodonTokenStore.grants()`
    /// for why that distinction is the whole point.
    ///
    /// **What this rests on, and what no test here can see:** that `kSecAttrGeneric` written with
    /// `SecItemAdd` comes back from an attributes-only `SecItemCopyMatching`. That round trip was
    /// verified by hand against the real Keychain on macOS and iOS; `swift test` may not touch the
    /// Keychain at all, so the suite pins only the dictionary this file builds and CI can never
    /// prove the other half. `KeychainMastodonTokens.grants()` says which way it fails.
    ///
    /// **Absent, and not empty, for a token kept before the question** — see `MastodonGrant`. The
    /// attribute and the value cannot drift: both are written from one token in one call, and
    /// `save` deletes before it adds, so no second item with a stale one can exist.
    public static func attributes(for token: MastodonToken) -> [String: Any] {
        var attributes = item(
            lookup(host: token.host), label: token.host, value: Wire.encode(token)
        )
        if let scopes = token.scopes {
            attributes[kSecAttrGeneric as String] = Data(scopes.utf8)
        }
        // What the sign-in asked for (#285), beside what it was given and for the same reason:
        // readable without the secret. Scope names, which are not one. **Fails the safe way** if
        // it ever stops coming back: a source that had refused bookmarks is offered the question
        // once more, and nothing is widened.
        if let asked = token.asked {
            attributes[kSecAttrComment as String] = asked
        }
        return attributes
    }

    public static func attributes(for app: MastodonApp) -> [String: Any] {
        item(
            lookup(host: app.host, service: appService), label: "\(app.host) app",
            value: Wire.encode(app)
        )
    }

    private static func item(_ lookup: [String: Any], label: String, value: Data) -> [String: Any] {
        var attributes = lookup
        attributes[kSecAttrLabel as String] = "\(Fediqo.name) — \(label)"
        attributes[kSecAttrAccessible as String] = ForumKeychain.accessibility
        attributes[kSecValueData as String] = value
        return attributes
    }

    /// What one item's attributes say its sign-in bought.
    public static func grant(_ row: [String: Any]) -> MastodonGrant {
        guard let data = row[kSecAttrGeneric as String] as? Data else { return .unasked }
        return MastodonGrant.of(scopes: String(decoding: data, as: UTF8.self))
    }

    /// Whether one item's attributes say its sign-in may bookmark (#285). A token kept before
    /// the scopes were written down says nothing, and nothing is no.
    public static func bookmarks(_ row: [String: Any]) -> Bool {
        guard let data = row[kSecAttrGeneric as String] as? Data else { return false }
        return MastodonOAuth.bookmarks(String(decoding: data, as: UTF8.self))
    }

    /// Whether one item's attributes say its sign-in asked for bookmarks and was not given them
    /// (#285): asked is written down, and what it was given leaves them out.
    public static func bookmarksRefused(_ row: [String: Any]) -> Bool {
        MastodonOAuth.bookmarks(row[kSecAttrComment as String] as? String) && !bookmarks(row)
    }

    /// Whether one item's attributes say its sign-in may read notices (#323). Nothing written
    /// down is no, as it is for bookmarks.
    public static func notices(_ row: [String: Any]) -> Bool {
        guard let data = row[kSecAttrGeneric as String] as? Data else { return false }
        return MastodonOAuth.notices(String(decoding: data, as: UTF8.self))
    }

    /// Whether one item's attributes say its sign-in may dismiss notices (#323).
    public static func dismisses(_ row: [String: Any]) -> Bool {
        guard let data = row[kSecAttrGeneric as String] as? Data else { return false }
        return MastodonOAuth.dismisses(String(decoding: data, as: UTF8.self))
    }

    /// Whether one item's attributes say its sign-in asked for notices and was not given them
    /// (#323): asked is written down, and what it was given leaves them out.
    public static func noticesRefused(_ row: [String: Any]) -> Bool {
        MastodonOAuth.notices(row[kSecAttrComment as String] as? String) && !notices(row)
    }

    /// Every host this app holds a token for, attributes only — no `kSecReturnData`.
    public static func allItems() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
    }

    /// The items' values. The one place a token or a registration is turned into bytes and back.
    enum Wire {
        private struct Token: Codable {
            var accessToken: String
            var clientID: String
            var clientSecret: String
            /// Absent in an item kept before a sign-in asked about writing — which is what makes
            /// that reader one this app still owes the question to.
            var scopes: String?
            /// Absent in an item kept before what a sign-in asked for was written down (#285).
            var asked: String?
            /// Absent in an item kept before whose sign-in it is was written down, and until
            /// its source has said. Optional and ignored by a build that does not know them.
            var accountID: String?
            var handle: String?
        }

        private struct App: Codable {
            var clientID: String
            var clientSecret: String
            /// Absent in an item kept before the scopes were recorded.
            var scopes: String?
        }

        static func encode(_ token: MastodonToken) -> Data {
            let value = Token(
                accessToken: token.accessToken, clientID: token.clientID,
                clientSecret: token.clientSecret, scopes: token.scopes, asked: token.asked,
                accountID: token.accountID, handle: token.handle
            )
            return (try? JSONEncoder().encode(value)) ?? Data()
        }

        static func encode(_ app: MastodonApp) -> Data {
            let value = App(clientID: app.clientID, clientSecret: app.clientSecret, scopes: app.scopes)
            return (try? JSONEncoder().encode(value)) ?? Data()
        }

        static func decode(_ data: Data, host: String) -> MastodonToken? {
            guard let value = try? JSONDecoder().decode(Token.self, from: data),
                  !value.accessToken.isEmpty
            else { return nil }
            return MastodonToken(
                host: host, accessToken: value.accessToken, clientID: value.clientID,
                clientSecret: value.clientSecret, scopes: value.scopes, asked: value.asked,
                accountID: value.accountID, handle: value.handle
            )
        }

        static func decodeApp(_ data: Data, host: String) -> MastodonApp? {
            guard let value = try? JSONDecoder().decode(App.self, from: data),
                  !value.clientID.isEmpty
            else { return nil }
            return MastodonApp(
                host: host, clientID: value.clientID, clientSecret: value.clientSecret, scopes: value.scopes
            )
        }
    }
}

/// The real one.
public struct KeychainMastodonTokens: MastodonTokenStore {
    public init() {}

    public func token(host: String) throws -> MastodonToken? {
        try read(MastodonKeychain.lookup(host: host)).flatMap {
            MastodonKeychain.Wire.decode($0, host: host)
        }
    }

    public func save(_ token: MastodonToken) throws {
        try forget(host: token.host)
        try add(MastodonKeychain.attributes(for: token))
    }

    public func forget(host: String) throws {
        try delete(MastodonKeychain.lookup(host: host))
    }

    public func forget(_ token: MastodonToken) throws -> Bool {
        guard try self.token(host: token.host)?.accessToken == token.accessToken else { return false }
        try forget(host: token.host)
        return true
    }

    /// **The one unproven step in the grant model, named here rather than left to be found.**
    /// Every row's answer to what may be done on its source comes from `kSecAttrGeneric` arriving
    /// back in these rows — see `MastodonKeychain.attributes(for:)`, which writes it. The round
    /// trip was verified by hand against the real Keychain on macOS and iOS and **cannot be
    /// verified by CI**: `swift test` may not touch the Keychain, so what the suite pins is the
    /// dictionary handed to `SecItemAdd`, not what `SecItemCopyMatching` hands back.
    ///
    /// **Which way it fails, if that attribute ever stops coming back:** `MastodonKeychain.grant`
    /// reads a missing one as `.unasked`, so every host degrades together — Account names every
    /// source as one that signed in before the question, every row says read, and nothing writes.
    /// No token is lost, no reading changes, and nothing is widened; the app asks the question
    /// again. That is the safe direction, and it is the reason this rests where it does.
    public func grants() throws -> [String: MastodonGrant] {
        try rows().mapValues(MastodonKeychain.grant)
    }

    /// `grants()`'s query and its failure direction: an attribute that stops coming back is a
    /// host that may not bookmark, and the row asks again.
    public func bookmarking() throws -> Set<String> {
        Set(try rows().filter { MastodonKeychain.bookmarks($0.value) }.keys)
    }

    public func bookmarksRefused() throws -> Set<String> {
        Set(try rows().filter { MastodonKeychain.bookmarksRefused($0.value) }.keys)
    }

    /// `bookmarking()`'s query and its failure direction: an attribute that stops coming back is
    /// a host that may not read notices, and the notices page asks again.
    public func noticing() throws -> Set<String> {
        Set(try rows().filter { MastodonKeychain.notices($0.value) }.keys)
    }

    public func dismissing() throws -> Set<String> {
        Set(try rows().filter { MastodonKeychain.dismisses($0.value) }.keys)
    }

    public func noticesRefused() throws -> Set<String> {
        Set(try rows().filter { MastodonKeychain.noticesRefused($0.value) }.keys)
    }

    /// One query for the three: they are read off the same rows, so they are had or not together.
    public func noticeGrants() -> MastodonNoticeGrants {
        guard let rows = try? rows() else {
            return MastodonNoticeGrants(noticing: nil, dismissing: nil, refused: nil)
        }
        return MastodonNoticeGrants(
            noticing: Set(rows.filter { MastodonKeychain.notices($0.value) }.keys),
            dismissing: Set(rows.filter { MastodonKeychain.dismisses($0.value) }.keys),
            refused: Set(rows.filter { MastodonKeychain.noticesRefused($0.value) }.keys)
        )
    }

    /// Every held token's attributes, by host, and never a value.
    private func rows() throws -> [String: [String: Any]] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(MastodonKeychain.allItems() as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        guard let rows = item as? [[String: Any]] else { return [:] }
        return rows.reduce(into: [:]) { found, row in
            guard let host = (row[kSecAttrAccount as String] as? String)?.lowercased() else {
                return
            }
            found[host] = row
        }
    }

    public func app(host: String) throws -> MastodonApp? {
        try read(MastodonKeychain.lookup(host: host, service: MastodonKeychain.appService))
            .flatMap { MastodonKeychain.Wire.decodeApp($0, host: host) }
    }

    public func save(_ app: MastodonApp) throws {
        try forgetApp(host: app.host)
        try add(MastodonKeychain.attributes(for: app))
    }

    public func forgetApp(host: String) throws {
        try delete(MastodonKeychain.lookup(host: host, service: MastodonKeychain.appService))
    }

    private func read(_ lookup: [String: Any]) throws -> Data? {
        var query = lookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        return item as? Data
    }

    /// Callers delete first: `SecItemAdd` over an existing item changes nothing.
    private func add(_ attributes: [String: Any]) throws {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
    }

    private func delete(_ lookup: [String: Any]) throws {
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForumCredentialError.keychain(status)
        }
    }
}

/// The one tests and previews use. Never written to disk.
public final class MemoryMastodonTokens: MastodonTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: MastodonToken] = [:]
    private var apps: [String: MastodonApp] = [:]

    public init() {}

    public func token(host: String) throws -> MastodonToken? {
        lock.withLock { held[host.lowercased()] }
    }

    public func save(_ token: MastodonToken) throws {
        lock.withLock { held[token.host] = token }
    }

    public func forget(host: String) throws {
        _ = lock.withLock { held.removeValue(forKey: host.lowercased()) }
    }

    public func forget(_ token: MastodonToken) throws -> Bool {
        lock.withLock {
            guard held[token.host]?.accessToken == token.accessToken else { return false }
            held[token.host] = nil
            return true
        }
    }

    public func grants() throws -> [String: MastodonGrant] {
        lock.withLock { held.mapValues(\.grant) }
    }

    public func bookmarking() throws -> Set<String> {
        lock.withLock { Set(held.filter { MastodonOAuth.bookmarks($0.value.scopes) }.keys) }
    }

    public func bookmarksRefused() throws -> Set<String> {
        lock.withLock { Set(held.filter(\.value.bookmarksRefused).keys) }
    }

    public func noticing() throws -> Set<String> {
        lock.withLock { Set(held.filter { MastodonOAuth.notices($0.value.scopes) }.keys) }
    }

    public func dismissing() throws -> Set<String> {
        lock.withLock { Set(held.filter { MastodonOAuth.dismisses($0.value.scopes) }.keys) }
    }

    public func noticesRefused() throws -> Set<String> {
        lock.withLock { Set(held.filter(\.value.noticesRefused).keys) }
    }

    public func app(host: String) throws -> MastodonApp? {
        lock.withLock { apps[host.lowercased()] }
    }

    public func save(_ app: MastodonApp) throws {
        lock.withLock { apps[app.host] = app }
    }

    public func forgetApp(host: String) throws {
        _ = lock.withLock { apps.removeValue(forKey: host.lowercased()) }
    }
}
