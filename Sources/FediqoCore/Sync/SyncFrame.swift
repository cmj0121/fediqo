import Foundation

/// What two devices say inside `NearbyChannel` (sealed) about pairing and syncing, carried as
/// `NearbyFrame.sync`: `[version: UInt8][kind: UInt8][JSON body]`.
///
/// Pairing says `pairHello` and then `paired` (`SyncPairing`). A version or kind this build
/// does not know, or a body that does not read, is `.malformed`.
public enum SyncFrame: Sendable, Equatable {
    case pairHello(PairHello)              // kind 6
    case paired                            // kind 7

    public static let version: UInt8 = 1
    public static let label = "fediqo-sync-1"

    enum Kind: UInt8 {
        case pairHello = 6, paired = 7
    }

    public func encode() throws -> Data {
        switch self {
        case .pairHello(let hello):
            return Data([Self.version, Kind.pairHello.rawValue]) + (try JSONEncoder().encode(hello))
        case .paired:
            return Data([Self.version, Kind.paired.rawValue])
        }
    }

    public static func decode(_ data: Data) throws -> SyncFrame {
        let bytes = [UInt8](data.prefix(2))
        guard bytes.count == 2, bytes[0] == version, let kind = Kind(rawValue: bytes[1]) else {
            throw NearbyRefusal.malformed
        }
        let body = data.dropFirst(2)
        switch kind {
        case .pairHello:
            guard let hello = try? JSONDecoder().decode(PairHello.self, from: body), hello.isWellFormed else {
                throw NearbyRefusal.malformed
            }
            return .pairHello(hello)
        case .paired:
            guard body.isEmpty else { throw NearbyRefusal.malformed }
            return .paired
        }
    }
}

/// Who a device is, and its half of the pair secret, said once at pairing.
public struct PairHello: Hashable, Sendable, Codable {
    public let device: String
    public let name: String
    /// Exactly 32 random bytes, else `.malformed`.
    public let nonce: Data

    public init(device: String, name: String, nonce: Data) {
        self.device = device
        self.name = name
        self.nonce = nonce
    }

    var isWellFormed: Bool {
        nonce.count == 32 && !device.isEmpty && device.utf8.count <= 64 && name.utf8.count <= 256
    }
}
