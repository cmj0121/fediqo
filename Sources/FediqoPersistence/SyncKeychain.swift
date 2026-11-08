import CryptoKit
import FediqoCore
import Foundation
import Security

/// The query dictionaries pairing keeps its items under, assertable as `ForumKeychain`'s are:
/// class generic password, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and
/// `kSecAttrSynchronizable` written explicitly false — a pair secret never follows the Apple
/// account to another device, and a restored backup never carries the device id (D1).
///
/// On macOS, as with `MastodonKeychain`, the items land in the file-based login keychain, which
/// never syncs but ignores the accessibility class: `kSecUseDataProtectionKeychain` needs a
/// team-signed build, and an ad-hoc one gets -34018. Once the app is team-signed, adding it to
/// every query here moves them.
public enum SyncKeychain {
    public static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    /// account = the peer's device id; data = JSON `{"secret": base64, "pair": PairedDevice}`.
    public static let pairService = "fediqo.sync.pair"
    /// account = `deviceAccount`; data = this device's id, UTF-8.
    public static let deviceService = "fediqo.sync.device"
    public static let deviceAccount = "this"

    public static func lookup(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public static func adding(service: String, account: String, data: Data) -> [String: Any] {
        var attributes = lookup(service: service, account: account)
        attributes[kSecAttrAccessible as String] = accessibility
        attributes[kSecAttrLabel as String] = "\(Fediqo.name) — \(service)"
        attributes[kSecValueData as String] = data
        return attributes
    }
}

public enum SyncKeychainError: Error, Equatable, Sendable {
    /// The Keychain refused, with its own status and nothing else.
    case keychain(OSStatus)
    /// An item is there that this build cannot read back.
    case unreadable
}

/// The five calls the stores make of the Keychain, behind a protocol so `swift test` never
/// touches it; what is tested there is the stores over a fake, and the queries above.
public protocol SyncKeychainItems: Sendable {
    /// The item's data, or nil where there is no such item.
    func read(service: String, account: String) throws -> Data?
    func accounts(service: String) throws -> [String]
    /// Fails as a duplicate where the item is already there.
    func add(service: String, account: String, data: Data) throws
    /// The item's data written in place; false, and nothing written, where there is no such item.
    func update(service: String, account: String, data: Data) throws -> Bool
    /// Silent where there is no such item.
    func delete(service: String, account: String) throws
}

/// The real Keychain.
public struct SecSyncKeychainItems: SyncKeychainItems {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = SyncKeychain.lookup(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
        guard let data = item as? Data else { throw SyncKeychainError.unreadable }
        return data
    }

    public func accounts(service: String) throws -> [String] {
        var query = SyncKeychain.lookup(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
        return (item as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func add(service: String, account: String, data: Data) throws {
        let status = SecItemAdd(SyncKeychain.adding(service: service, account: account, data: data) as CFDictionary, nil)
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
    }

    public func update(service: String, account: String, data: Data) throws -> Bool {
        let status = SecItemUpdate(
            SyncKeychain.lookup(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
        return true
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(SyncKeychain.lookup(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncKeychainError.keychain(status) }
    }
}

/// Pairs and their secrets, one Keychain item per paired device.
public struct KeychainPairStore: PairStore {
    private struct Item: Codable {
        let secret: Data
        let pair: PairedDevice
    }

    private let items: any SyncKeychainItems

    public init() {
        self.init(items: SecSyncKeychainItems())
    }

    public init(items: any SyncKeychainItems) {
        self.items = items
    }

    public func pairs() throws -> [PairedDevice] {
        try items.accounts(service: SyncKeychain.pairService)
            .compactMap { try item(for: $0)?.pair }
            .sorted { ($0.pairedAt, $0.device) < ($1.pairedAt, $1.device) }
    }

    public func secret(for device: String) throws -> SymmetricKey? {
        try item(for: device).map { SymmetricKey(data: $0.secret) }
    }

    public func keep(_ pair: PairedDevice, secret: SymmetricKey) throws {
        try write(Item(secret: secret.withUnsafeBytes { Data($0) }, pair: pair))
    }

    /// In place, where the pair is kept: the item is never taken away, and the secret goes
    /// back as it was read.
    public func update(_ pair: PairedDevice) throws {
        guard let held = try item(for: pair.device) else { return }
        _ = try items.update(service: SyncKeychain.pairService, account: pair.device, data: try JSONEncoder().encode(Item(secret: held.secret, pair: pair)))
    }

    public func forget(device: String) throws {
        try items.delete(service: SyncKeychain.pairService, account: device)
    }

    private func item(for device: String) throws -> Item? {
        guard let data = try items.read(service: SyncKeychain.pairService, account: device) else { return nil }
        guard let item = try? JSONDecoder().decode(Item.self, from: data), item.secret.count == 32,
              item.pair.device == device
        else { throw SyncKeychainError.unreadable }
        return item
    }

    /// Written in place where an item is there, added only where none is: a pair kept before
    /// is never deleted first, so a failed write leaves it as it was.
    private func write(_ item: Item) throws {
        let data = try JSONEncoder().encode(item)
        guard try !items.update(service: SyncKeychain.pairService, account: item.pair.device, data: data) else { return }
        try items.add(service: SyncKeychain.pairService, account: item.pair.device, data: data)
    }
}

/// This device's id, kept in the Keychain and made fresh only when its item is missing.
public struct KeychainDeviceIdentity: DeviceIdentityStore {
    private let items: any SyncKeychainItems

    public init() {
        self.init(items: SecSyncKeychainItems())
    }

    public init(items: any SyncKeychainItems) {
        self.items = items
    }

    public func deviceID() throws -> String {
        if let id = try kept() { return id }
        let id = UUID().uuidString
        do {
            try items.add(service: SyncKeychain.deviceService, account: SyncKeychain.deviceAccount, data: Data(id.utf8))
        } catch SyncKeychainError.keychain(errSecDuplicateItem) {
            // Another caller made one first: that one is the id.
            guard let first = try kept() else { throw SyncKeychainError.keychain(errSecDuplicateItem) }
            return first
        }
        return id
    }

    private func kept() throws -> String? {
        guard let data = try items.read(service: SyncKeychain.deviceService, account: SyncKeychain.deviceAccount) else { return nil }
        guard let id = String(data: data, encoding: .utf8), !id.isEmpty else { throw SyncKeychainError.unreadable }
        return id
    }
}
