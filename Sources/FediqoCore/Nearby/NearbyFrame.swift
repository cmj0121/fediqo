import Foundation

/// What two devices say to each other while a store moves between them (#253), and how each
/// rides: one tag byte, then the frame's own bytes. The package itself rides as `bytes`
/// frames, unchanged from the file on the sender's disk, so every check #252 makes on a file
/// is made on what arrived.
///
///     both    ──hello──▶◀──hello──          a fresh key-agreement key each, and
///             ──confirm▶◀─confirm─          proof each holds the code (`NearbyChannel`)
///     sender  ──offer──▶  receiver          what would move, for the question on both screens
///             ◀─accept──                    the receiver's person said yes (or `refuse`)
///             ──key────▶                    the package's own key, sent only inside the session
///             ◀─have────                    how many bytes the receiver already holds
///             ──bytes──▶ …                  the file from that offset
///             ──done───▶                    nothing more to send
///             ◀─done────                    read back whole; both may close
///
/// Everything after the confirmation rides as `sealed`: the frame's own encoding, sealed under
/// the key the two agreed (`NearbyChannel`), so a recording of the wire and the code together
/// open nothing.
public enum NearbyFrame: Sendable, Equatable {
    case offer(NearbyOffer)
    case accept
    case refuse
    /// The package's 32-byte key: a random key the code never is.
    case key(Data)
    /// How many bytes of the file the receiver holds, so the sender resumes there.
    case have(Int64)
    case bytes(Data)
    case done
    /// A fresh P-256 key-agreement public key (X9.63, 65 bytes): the first thing each side sends.
    case hello(Data)
    /// Proof of the agreed key and the code: an HMAC over the two keys.
    case confirm(Data)
    /// Any frame after the confirmation, sealed under the agreed key.
    case sealed(Data)

    /// The most a `bytes` frame carries, and the most any frame may be on the wire.
    public static let mostBytes = 256 * 1024
    static let mostFrameBytes = mostBytes + 4096

    public enum Tag: UInt8 {
        case offer = 1, accept, refuse, key, have, bytes, done, hello, confirm, sealed
    }

    /// The frame as it rides: tag, then its bytes.
    public func encode() throws -> Data {
        var out = Data()
        switch self {
        case .offer(let offer):
            out.append(Tag.offer.rawValue)
            out.append(try JSONEncoder().encode(offer))
        case .accept: out.append(Tag.accept.rawValue)
        case .refuse: out.append(Tag.refuse.rawValue)
        case .key(let key):
            out.append(Tag.key.rawValue)
            out.append(key)
        case .have(let count):
            out.append(Tag.have.rawValue)
            out.appendLE(count)
        case .bytes(let data):
            out.append(Tag.bytes.rawValue)
            out.append(data)
        case .done: out.append(Tag.done.rawValue)
        case .hello(let key):
            out.append(Tag.hello.rawValue)
            out.append(key)
        case .confirm(let mac):
            out.append(Tag.confirm.rawValue)
            out.append(mac)
        case .sealed(let box):
            out.append(Tag.sealed.rawValue)
            out.append(box)
        }
        return out
    }

    /// The frame in `data`, or `NearbyRefusal.malformed` where no build of ours wrote it.
    public static func decode(_ data: Data) throws -> NearbyFrame {
        guard let first = data.first, let tag = Tag(rawValue: first), data.count <= mostFrameBytes else {
            throw NearbyRefusal.malformed
        }
        let body = data.dropFirst()
        switch tag {
        case .offer:
            // A newer build's package is said as that, so the person is told to update rather
            // than that the other device spoke wrongly.
            do {
                return .offer(try JSONDecoder().decode(NearbyOffer.self, from: body))
            } catch let refusal as PackageRefusal {
                throw refusal
            } catch {
                throw NearbyRefusal.malformed
            }
        case .accept:
            guard body.isEmpty else { throw NearbyRefusal.malformed }
            return .accept
        case .refuse:
            guard body.isEmpty else { throw NearbyRefusal.malformed }
            return .refuse
        case .key:
            guard body.count == 32 else { throw NearbyRefusal.malformed }
            return .key(Data(body))
        case .have:
            guard body.count == 8 else { throw NearbyRefusal.malformed }
            let count = Int64(bitPattern: body.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
            guard count >= 0 else { throw NearbyRefusal.malformed }
            return .have(count)
        case .bytes:
            guard !body.isEmpty, body.count <= mostBytes else { throw NearbyRefusal.malformed }
            return .bytes(Data(body))
        case .done:
            guard body.isEmpty else { throw NearbyRefusal.malformed }
            return .done
        case .hello:
            guard body.count == 65 else { throw NearbyRefusal.malformed }
            return .hello(Data(body))
        case .confirm:
            guard body.count == 32 else { throw NearbyRefusal.malformed }
            return .confirm(Data(body))
        case .sealed:
            guard body.count >= 28 else { throw NearbyRefusal.malformed }
            return .sealed(Data(body))
        }
    }
}

/// What the sender offers: the package's header as #252's question is asked from it, the
/// file's length on the wire, and an id so a link that dropped and came back carries on the
/// same offer without asking again.
public struct NearbyOffer: Sendable, Equatable, Codable {
    public let id: String
    public let summary: PackageSummary
    /// The package file's length in bytes: what the wire carries, and what `have` counts.
    public let fileBytes: Int64

    /// The longest file an offer may name: a terabyte, past any store, so the room check's
    /// arithmetic never overflows on a number a stranger typed.
    public static let mostFileBytes: Int64 = 1 << 40

    public init(id: String = UUID().uuidString, summary: PackageSummary, fileBytes: Int64) {
        self.id = id
        self.summary = summary
        self.fileBytes = fileBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, summary, fileBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        summary = try container.decode(PackageSummary.self, forKey: .summary)
        fileBytes = try container.decode(Int64.self, forKey: .fileBytes)
        guard fileBytes >= 0, fileBytes <= Self.mostFileBytes, !id.isEmpty, id.count <= 64 else { throw NearbyRefusal.malformed }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(summary, forKey: .summary)
        try container.encode(fileBytes, forKey: .fileBytes)
    }
}

/// The summary on the wire: its header as the package seals it, and the three facts the
/// prelude holds beside it.
extension PackageSummary: Codable {
    enum CodingKeys: String, CodingKey {
        case header, takenAt, withPictures, bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let header = try container.decode(Header.self, forKey: .header)
        let seconds = try container.decode(Double.self, forKey: .takenAt)
        guard seconds.isFinite else { throw NearbyRefusal.malformed }
        let bytes = try container.decode(Int.self, forKey: .bytes)
        guard bytes >= 0 else { throw NearbyRefusal.malformed }
        let prelude = PackageFormat.Prelude(
            keying: .direct, salt: Data(), rounds: 1, noncePrefix: Data(),
            takenAt: Date(timeIntervalSince1970: seconds),
            withPictures: try container.decode(Bool.self, forKey: .withPictures), bytes: bytes
        )
        self = try header.summary(prelude)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Header(self), forKey: .header)
        try container.encode(takenAt.timeIntervalSince1970, forKey: .takenAt)
        try container.encode(withPictures, forKey: .withPictures)
        try container.encode(bytes, forKey: .bytes)
    }
}
