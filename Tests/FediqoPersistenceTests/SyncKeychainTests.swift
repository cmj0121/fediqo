import CryptoKit
import FediqoCore
import Foundation
import Security
import Synchronization
import Testing
@testable import FediqoPersistence

/// U4: the pair secret as a Keychain item — the queries they are kept under,
/// and the stores over a Keychain held in memory.
@Suite("Pairs in the Keychain")
struct SyncKeychainTests {
    @Test("Items are generic passwords, this device only after first unlock, never synchronizable")
    func queries() {
        let lookup = SyncKeychain.lookup(service: SyncKeychain.pairService, account: "D")
        #expect(lookup[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(lookup[kSecAttrService as String] as? String == "fediqo.sync.pair")
        #expect(lookup[kSecAttrAccount as String] as? String == "D")
        #expect(lookup[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(SyncKeychain.lookup(service: SyncKeychain.pairService, account: nil)[kSecAttrAccount as String] == nil)
        let adding = SyncKeychain.adding(service: SyncKeychain.pairService, account: "D", data: Data("x".utf8))
        #expect(adding[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(SyncKeychain.accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(adding[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(adding[kSecValueData as String] as? Data == Data("x".utf8))
        #expect(adding[kSecAttrService as String] as? String == "fediqo.sync.pair")
    }

    @Test("A pair written again goes in place: a failed write keeps the secret, and update leaves it as it was")
    func inPlace() throws {
        let items = MemoryKeychainItems()
        let store = KeychainPairStore(items: items)
        let secret = SymmetricKey(size: .bits256)
        let phone = PairedDevice(device: "PHONE", name: "Phone", pairedAt: Date(timeIntervalSince1970: 1))
        try store.keep(phone, secret: secret)
        try store.keep(phone, secret: SymmetricKey(size: .bits256))
        var merged = phone
        merged.lastMerged = Date(timeIntervalSince1970: 5)
        try store.update(merged)
        #expect(items.deletes == 0 && items.adds == 1, "never deleted to be written again")
        let kept = try #require(try store.secret(for: "PHONE"))
        items.failUpdates = true
        items.failAdds = true
        #expect(throws: SyncKeychainError.keychain(errSecIO)) { try store.keep(phone, secret: SymmetricKey(size: .bits256)) }
        #expect(throws: SyncKeychainError.keychain(errSecIO)) { try store.update(phone) }
        items.failUpdates = false
        #expect(try store.secret(for: "PHONE") == kept && store.pairs() == [merged], "a failed write leaves the pair as it was")
    }

    @Test("A pair and its secret are kept, listed, updated without the secret, and forgotten")
    func pairs() throws {
        let items = MemoryKeychainItems()
        let store = KeychainPairStore(items: items)
        let secret = SymmetricKey(size: .bits256)
        let phone = PairedDevice(device: "PHONE", name: "Phone", pairedAt: Date(timeIntervalSince1970: 2))
        let tablet = PairedDevice(device: "TAB", name: "Tablet", pairedAt: Date(timeIntervalSince1970: 1))
        try store.keep(phone, secret: secret)
        try store.keep(tablet, secret: SymmetricKey(size: .bits256))
        #expect(try store.pairs() == [tablet, phone])
        #expect(try store.secret(for: "PHONE") == secret)
        #expect(try store.secret(for: "NOBODY") == nil)
        #expect(try store.kept().map(\.pair) == [tablet, phone] && store.kept("PHONE")?.secret == secret)

        var merged = phone
        merged.firstMerged = true
        merged.lastMerged = Date(timeIntervalSince1970: 9)
        merged.name = "My phone"
        try store.update(merged)
        #expect(try store.pairs().last == merged)
        #expect(try store.secret(for: "PHONE") == secret)
        try store.update(PairedDevice(device: "NOBODY", name: "x", pairedAt: .now))
        #expect(try store.pairs().count == 2)

        let again = SymmetricKey(size: .bits256)
        try store.keep(phone, secret: again)
        #expect(try store.secret(for: "PHONE") == again && store.pairs().last == phone)

        try store.forget(device: "PHONE")
        #expect(try store.pairs() == [tablet])
        #expect(try store.secret(for: "PHONE") == nil)
        #expect(items.accounts(SyncKeychain.pairService) == ["TAB"])
        try store.forget(device: "PHONE")
    }

    @Test("The item holds the secret as base64 beside the pair")
    func item() throws {
        let items = MemoryKeychainItems()
        let secret = SymmetricKey(data: Data(repeating: 5, count: 32))
        try KeychainPairStore(items: items).keep(PairedDevice(device: "D", name: "n", pairedAt: .now), secret: secret)
        let data = try #require(try items.read(service: SyncKeychain.pairService, account: "D"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["secret"] as? String == Data(repeating: 5, count: 32).base64EncodedString())
        #expect((json["pair"] as? [String: Any])?["device"] as? String == "D")
    }
}

/// A Keychain in memory, keyed by service and account.
final class MemoryKeychainItems: SyncKeychainItems {
    private struct Held {
        var items: [String: [String: Data]] = [:]
        var adds = 0
        var deletes = 0
        var failAdds = false
        var failUpdates = false
    }

    private let held = Mutex(Held())

    var adds: Int { held.withLock { $0.adds } }
    var deletes: Int { held.withLock { $0.deletes } }

    var failAdds: Bool {
        get { held.withLock { $0.failAdds } }
        set { held.withLock { $0.failAdds = newValue } }
    }

    var failUpdates: Bool {
        get { held.withLock { $0.failUpdates } }
        set { held.withLock { $0.failUpdates = newValue } }
    }

    func accounts(_ service: String) -> [String] {
        held.withLock { $0.items[service, default: [:]].keys.sorted() }
    }

    func read(service: String, account: String) throws -> Data? {
        held.withLock { $0.items[service]?[account] }
    }

    func accounts(service: String) throws -> [String] {
        accounts(service)
    }

    func add(service: String, account: String, data: Data) throws {
        try held.withLock { held in
            if held.failAdds { throw SyncKeychainError.keychain(errSecIO) }
            guard held.items[service]?[account] == nil else { throw SyncKeychainError.keychain(errSecDuplicateItem) }
            held.items[service, default: [:]][account] = data
            held.adds += 1
        }
    }

    func update(service: String, account: String, data: Data) throws -> Bool {
        try held.withLock { held in
            if held.failUpdates { throw SyncKeychainError.keychain(errSecIO) }
            guard held.items[service]?[account] != nil else { return false }
            held.items[service]?[account] = data
            return true
        }
    }

    func delete(service: String, account: String) throws {
        held.withLock { held in
            if held.items[service]?.removeValue(forKey: account) != nil { held.deletes += 1 }
        }
    }
}
