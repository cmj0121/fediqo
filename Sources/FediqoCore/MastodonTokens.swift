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

    public init(
        host: String, accessToken: String, clientID: String, clientSecret: String,
        scopes: String? = nil
    ) {
        self.host = host.lowercased()
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
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
    /// for why that distinction is the whole point. `kSecAttrGeneric` comes back from the
    /// attributes-only query, verified against the real Keychain because no test here may touch it.
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
                clientSecret: token.clientSecret, scopes: token.scopes
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
                clientSecret: value.clientSecret, scopes: value.scopes
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

    public func grants() throws -> [String: MastodonGrant] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(MastodonKeychain.allItems() as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        guard let rows = item as? [[String: Any]] else { return [:] }
        return rows.reduce(into: [:]) { grants, row in
            guard let host = (row[kSecAttrAccount as String] as? String)?.lowercased() else {
                return
            }
            grants[host] = MastodonKeychain.grant(row)
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
