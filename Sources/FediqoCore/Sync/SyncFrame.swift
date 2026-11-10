import Foundation

/// What two paired devices say inside `NearbyChannel` (sealed), carried as `NearbyFrame.sync`:
/// `[version: UInt8][kind: UInt8][JSON body]`.
///
///     both  ──hello──▶◀──hello──        who each is (checked against the pair), merged yet?
///     both  ──snapshot▶◀─snapshot─       every entry, tombstones included
///           (each computes SyncMerge.plan; first merge and anything to change → dialer asks)
///     dialer──answer──▶                 yes/no (first merge only)
///     both  ──applied─▶◀─applied──       written here or not; both yes → merged
///     any   ──refused─▶                 a reason, then close
///     any   ──versionRefused▶           fixed shape, any version: [v][0xFF][newest]
///
/// Pairing says `pairHello` and then `paired` (`SyncPairing`). **`versionRefused` keeps its
/// shape forever**, so builds on any two versions can still tell each other who must update.
public enum SyncFrame: Sendable, Equatable {
    case hello(SyncHello)                  // kind 1
    case snapshot(SyncSnapshot)            // kind 2; `.tooLarge` past NearbyFrame.mostBytes
    case answer(Bool)                      // kind 3
    case applied(Bool)                     // kind 4
    case refused(SyncRefusal)              // kind 5
    case pairHello(PairHello)              // kind 6
    case paired                            // kind 7
    case versionRefused(newest: UInt8)     // kind 0xFF — readable whatever byte 0 says

    public static let version: UInt8 = 1
    public static let label = "fediqo-sync-1"

    enum Kind: UInt8 {
        case hello = 1, snapshot, answer, applied, refused, pairHello, paired
        case versionRefused = 0xFF
    }

    /// The frame as it rides. A snapshot past `NearbyFrame.mostBytes` throws `SyncRefusal.tooLarge`.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data
        switch self {
        case .hello(let hello): data = Self.head(.hello) + (try encoder.encode(hello))
        case .snapshot(let snapshot): data = Self.head(.snapshot) + (try encoder.encode(snapshot))
        case .answer(let yes): data = Self.head(.answer) + (try encoder.encode(yes))
        case .applied(let done): data = Self.head(.applied) + (try encoder.encode(done))
        case .refused(let refusal): data = Self.head(.refused) + (try encoder.encode(refusal))
        case .pairHello(let hello): data = Self.head(.pairHello) + (try encoder.encode(hello))
        case .paired: data = Self.head(.paired)
        case .versionRefused(let newest): data = Self.head(.versionRefused) + Data([newest])
        }
        guard data.count <= NearbyFrame.mostBytes else { throw SyncRefusal.tooLarge }
        return data
    }

    private static func head(_ kind: Kind) -> Data {
        Data([version, kind.rawValue])
    }

    /// The frame in `data`. `versionRefused` reads whatever byte 0 says. Otherwise a byte 0 not
    /// `version` throws `SyncRefusal.otherVersion(byte0)`; an unknown kind or a body that does
    /// not read is `NearbyRefusal.malformed`, and a source of a kind this build cannot name is
    /// `SyncRefusal.peerNewer`.
    public static func decode(_ data: Data) throws -> SyncFrame {
        let bytes = [UInt8](data.prefix(2))
        guard bytes.count == 2 else { throw NearbyRefusal.malformed }
        if bytes[1] == Kind.versionRefused.rawValue {
            guard data.count == 3, let newest = data.last else { throw NearbyRefusal.malformed }
            return .versionRefused(newest: newest)
        }
        guard bytes[0] == version else { throw SyncRefusal.otherVersion(bytes[0]) }
        guard let kind = Kind(rawValue: bytes[1]) else { throw NearbyRefusal.malformed }
        let body = Data(data.dropFirst(2))
        switch kind {
        case .hello:
            let hello = try read(SyncHello.self, body)
            guard hello.isWellFormed else { throw NearbyRefusal.malformed }
            return .hello(hello)
        case .snapshot: return .snapshot(try read(SyncSnapshot.self, body))
        case .answer: return .answer(try read(Bool.self, body))
        case .applied: return .applied(try read(Bool.self, body))
        case .refused: return .refused(try read(SyncRefusal.self, body))
        case .pairHello:
            let hello = try read(PairHello.self, body)
            guard hello.isWellFormed else { throw NearbyRefusal.malformed }
            return .pairHello(hello)
        case .paired:
            guard body.isEmpty else { throw NearbyRefusal.malformed }
            return .paired
        case .versionRefused:
            throw NearbyRefusal.malformed
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch let refusal as SyncRefusal {
            throw refusal
        } catch {
            throw NearbyRefusal.malformed
        }
    }
}

/// Who a device is at every join, checked against the pair it was found under.
public struct SyncHello: Hashable, Sendable, Codable {
    /// Must equal the pair's `device`, else `.notPaired`.
    public let device: String
    /// Updates `PairedDevice.name`.
    public let name: String
    /// Either side false → the first-merge question (D8).
    public let firstMerged: Bool

    public init(device: String, name: String, firstMerged: Bool) {
        self.device = device
        self.name = name
        self.firstMerged = firstMerged
    }

    var isWellFormed: Bool {
        !device.isEmpty && device.utf8.count <= 64 && name.utf8.count <= 256
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
