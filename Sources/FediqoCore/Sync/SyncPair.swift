import CryptoKit
import Foundation

/// A device this one is paired with (D1). No secret in it.
public struct PairedDevice: Hashable, Sendable, Codable, Identifiable {
    public var id: String { device }
    /// The other device's id (its `DeviceIdentityStore.deviceID()`), as it said at pairing.
    public let device: String
    /// What it calls itself, said inside the sealed channel at pairing and at every join.
    public var name: String
    public let pairedAt: Date
    /// Whether the first merge (D8) was said yes to and applied on both sides.
    public var firstMerged: Bool
    public var lastMerged: Date?

    public init(device: String, name: String, pairedAt: Date, firstMerged: Bool = false, lastMerged: Date? = nil) {
        self.device = device
        self.name = name
        self.pairedAt = pairedAt
        self.firstMerged = firstMerged
        self.lastMerged = lastMerged
    }
}

/// Where pairs and their secrets live. A protocol so `swift test` never touches the Keychain.
public protocol PairStore: Sendable {
    func pairs() throws -> [PairedDevice]
    /// The 32-byte pair secret, or nil where not paired.
    func secret(for device: String) throws -> SymmetricKey?
    /// Keeps (or replaces — a pairing again) the pair and its secret.
    func keep(_ pair: PairedDevice, secret: SymmetricKey) throws
    /// Name, firstMerged, lastMerged; the secret untouched. Silent where not paired.
    func update(_ pair: PairedDevice) throws
    /// Gone on this side; the other no longer finds it (its tags and psk never match again).
    func forget(device: String) throws
}

/// This device's id, made once.
public protocol DeviceIdentityStore: Sendable {
    /// The id kept, or a fresh UUID string kept now **only where none is kept** (a restored
    /// backup never carries a ThisDeviceOnly item, so it never shares one). A read that fails
    /// any other way throws, and nothing fresh is made (else the id would rotate).
    func deviceID() throws -> String
}

/// The most pairs one device keeps (one listener each).
public enum PairLimit { public static let most = 8 }
