import Foundation
import Security
import Synchronization

/// Where credentials live. The database keeps the fact of being signed in; whatever
/// proves it goes here and nowhere else.
public protocol SecretStore: Sendable {
    /// The secret kept under this name, or nil where none was.
    func secret(for account: String) throws -> Data?

    func setSecret(_ secret: Data, for account: String) throws

    /// Forgetting something never kept is not an error.
    func removeSecret(for account: String) throws
}

/// The two things Fediqo keeps, in two namespaces that cannot meet: app credentials under
/// `app:<endpoint>`, a token under the author_id it belongs to — an author_id is a URL, so
/// no endpoint spells one. JSON both ways, snake_case keys, dates as epoch seconds — the
/// same shapes the server itself used.
public extension SecretStore {
    func appCredentials(for endpoint: String) throws -> AppCredentials? {
        try read(AppCredentials.self, for: "app:\(endpoint)")
    }

    func setAppCredentials(_ credentials: AppCredentials, for endpoint: String) throws {
        try write(credentials, for: "app:\(endpoint)")
    }

    func removeAppCredentials(for endpoint: String) throws {
        try removeSecret(for: "app:\(endpoint)")
    }

    func token(for authorId: String) throws -> OAuthToken? {
        try read(OAuthToken.self, for: authorId)
    }

    func setToken(_ token: OAuthToken, for authorId: String) throws {
        try write(token, for: authorId)
    }

    func removeToken(for authorId: String) throws {
        try removeSecret(for: authorId)
    }
}

private extension SecretStore {
    func read<Value: Decodable>(_ type: Value.Type, for account: String) throws -> Value? {
        guard let data = try secret(for: account) else { return nil }
        return try SecretJSON.decoder.decode(type, from: data)
    }

    func write<Value: Encodable>(_ value: Value, for account: String) throws {
        try setSecret(SecretJSON.encoder.encode(value), for: account)
    }
}

enum SecretJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// The Keychain said no; the status says which no.
public struct KeychainFailure: Error, Sendable, Equatable {
    public let status: OSStatus
}

/// The real Keychain: one generic-password item per name, all under the "fediqo" service,
/// readable after first unlock. The data-protection keychain is deliberately not asked
/// for — this build signs ad hoc, and without a real team identity it would refuse us.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func secret(for account: String) throws -> Data? {
        var query = base(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess: return found as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainFailure(status: status)
        }
    }

    public func setSecret(_ secret: Data, for account: String) throws {
        var add = base(for: account)
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added != errSecSuccess else { return }
        guard added == errSecDuplicateItem else { throw KeychainFailure(status: added) }
        let updated = SecItemUpdate(base(for: account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        guard updated == errSecSuccess else { throw KeychainFailure(status: updated) }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(base(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }

    private func base(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "fediqo",
            kSecAttrAccount as String: account,
        ]
    }
}

/// The same contract in a dictionary, for tests and previews. Never persists.
public final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: Data]>([:])

    public init() {}

    public func secret(for account: String) throws -> Data? {
        secrets.withLock { $0[account] }
    }

    public func setSecret(_ secret: Data, for account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    public func removeSecret(for account: String) throws {
        secrets.withLock { $0[account] = nil }
    }
}
