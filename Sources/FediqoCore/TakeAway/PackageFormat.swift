import CryptoKit
import Foundation

/// What one take-away file is (#247): the `FDQ1` framed package.
///
/// **A framed stream rather than an archive.** The payload is already three kinds of file and a
/// plist of settings, every option ends in chunked AEAD over gigabytes, and a frame of our own is
/// the smallest thing that can be verified chunk by chunk before a byte of the store changes —
/// with nothing new for the constitution to defend. It carries a version so it can change.
///
///     prelude   plaintext, fixed: magic, version, keying, salt, rounds, nonce prefix, taken-at,
///               with-pictures, byte total. Read without a password; its bytes are the header's
///               AAD, so a prelude altered fails the header's tag.
///     header    one sealed box (JSON `PackageHeader`). Wrong password = its tag fails, before
///               anything else is read — and it is what #252's question is asked from.
///     entries   in order, each a sealed record (`kind`, `name`, `length`) then 1 MiB chunks,
///               each sealed under nonce = prefix ‖ counter and AAD = entry index ‖ chunk index
///               ‖ last flag. A tag failing is `.altered`.
///     footer    one sealed box (`entryCount`, `chunkCount`); missing or short is `.cutShort`.
///
/// Every box on the wire is `u32 length` then AES-GCM's combined nonce ‖ ciphertext ‖ tag. All
/// integers are little-endian.
public enum PackageFormat {
    public static let magic = Data("FDQ1".utf8)
    /// The one version this build writes and the highest it reads.
    public static let version: UInt16 = 1
    /// What a chunk holds at most, so a package of gigabytes is never more than this in memory.
    public static let chunkBytes = 1 << 20
    /// PBKDF2 rounds for a password, written in the prelude so it can rise later.
    public static let rounds: UInt32 = 600_000
    /// The prelude's fixed length, in bytes: `Prelude.encode` writes exactly this many.
    static let preludeBytes = 4 + 2 + 1 + 1 + 16 + 4 + 4 + 8 + 1 + 8

    /// A sealed box may not be longer than this on the wire: a chunk, its nonce and its tag,
    /// with room for a record or the header. A length past it is not one this writer made.
    static let maxBoxBytes = chunkBytes + 4096

    /// How a package's keys are made: from a password the person set, or from a key handed over
    /// another way (#253, Decision 2).
    public enum Keying: UInt8, Sendable {
        case password = 1
        case direct = 2
    }

    /// The plaintext head of the file. What `PackageReader` reads before a password is asked.
    public struct Prelude: Sendable, Equatable {
        public let keying: Keying
        public let salt: Data
        public let rounds: UInt32
        /// The four bytes every nonce in this package starts with; the counter follows.
        public let noncePrefix: Data
        public let takenAt: Date
        public let withPictures: Bool
        /// What every entry's plaintext adds up to: what reading back needs on disk.
        public let bytes: Int

        init(
            keying: Keying, salt: Data, rounds: UInt32, noncePrefix: Data, takenAt: Date,
            withPictures: Bool, bytes: Int
        ) {
            self.keying = keying
            self.salt = salt
            self.rounds = rounds
            self.noncePrefix = noncePrefix
            self.takenAt = takenAt
            self.withPictures = withPictures
            self.bytes = bytes
        }

        func encode() -> Data {
            var out = Data()
            out.append(PackageFormat.magic)
            out.appendLE(PackageFormat.version)
            out.append(keying.rawValue)
            out.append(0)
            out.append(salt)
            out.appendLE(rounds)
            out.append(noncePrefix)
            out.appendLE(takenAt.timeIntervalSince1970.bitPattern)
            out.append(withPictures ? 1 : 0)
            out.appendLE(UInt64(bytes))
            return out
        }

        /// The prelude in `data`, which must be exactly `preludeBytes` long — or why it is not.
        static func decode(_ data: Data) throws -> Prelude {
            guard data.count == PackageFormat.preludeBytes else { throw PackageRefusal.cutShort }
            var cursor = Cursor(data)
            guard cursor.take(4) == PackageFormat.magic else { throw PackageRefusal.notOurs }
            let version: UInt16 = cursor.le()
            guard version <= PackageFormat.version else { throw PackageRefusal.newer }
            guard let keying = Keying(rawValue: cursor.byte()) else { throw PackageRefusal.newer }
            _ = cursor.byte()
            let salt = cursor.take(16)
            let rounds: UInt32 = cursor.le()
            let prefix = cursor.take(4)
            let seconds = Double(bitPattern: cursor.le())
            let withPictures = cursor.byte() != 0
            let bytes: UInt64 = cursor.le()
            guard rounds > 0, seconds.isFinite, bytes <= UInt64(Int.max) else { throw PackageRefusal.altered }
            return Prelude(
                keying: keying, salt: salt, rounds: rounds, noncePrefix: prefix,
                takenAt: Date(timeIntervalSince1970: seconds), withPictures: withPictures, bytes: Int(bytes)
            )
        }
    }

    /// What one entry is: its kind from a fixed list, a name within the kind, and its length.
    /// A kind this build does not know is a package a newer build wrote (`.newer`).
    public struct Entry: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable, CaseIterable {
            /// The index, as one SQLite file. Its name is `index.sqlite`.
            case store
            /// The person's settings: every `fediqo.` default, as a plist.
            case settings
            /// What signs in: tokens, app registrations and forum credentials, as JSON. The only
            /// place they ride.
            case secrets
            /// A source's self-description (#188). Named by its host.
            case profile
            /// One picture copy, named `<host digest>/<url digest>`.
            case picture
        }

        public let kind: Kind
        public let name: String
        public let length: Int

        public init(kind: Kind, name: String, length: Int) {
            self.kind = kind
            self.name = name
            self.length = length
        }
    }

    /// The sealed footer: what the package says it wrote, checked against what was read.
    struct Footer: Codable, Equatable {
        var entryCount: Int
        var chunkCount: Int
    }

    /// The AAD of each box, so a box moved to another place in the file fails its tag.
    enum Place {
        case header
        case record(entry: Int)
        case chunk(entry: Int, index: Int, last: Bool)
        case footer

        var aad: Data {
            var out = Data()
            switch self {
            case .header:
                out.append(Data("header".utf8))
            case .record(let entry):
                out.append(Data("record".utf8))
                out.appendLE(UInt32(entry))
            case .chunk(let entry, let index, let last):
                out.append(Data("chunk".utf8))
                out.appendLE(UInt32(entry))
                out.appendLE(UInt32(index))
                out.append(last ? 1 : 0)
            case .footer:
                out.append(Data("footer".utf8))
            }
            return out
        }
    }

    /// The nonce of the `counter`th box: the package's prefix, then the counter.
    static func nonce(prefix: Data, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = prefix
        bytes.appendLE(counter)
        return try AES.GCM.Nonce(data: bytes)
    }
}

/// Why a package cannot be read back (#252). Each is its own sentence on screen; none touches
/// the store.
public enum PackageRefusal: Error, Sendable, Equatable {
    /// Not one of ours: the file does not start as a package does.
    case notOurs
    /// Written by a newer build: a version, a keying or an entry kind this one does not know.
    /// Refused closed rather than read in part.
    case newer
    /// The password does not open it: the header's tag failed, before anything else was read.
    case wrongPassword
    /// A tag failed past the header, or a record does not add up: the file is not as written.
    case altered
    /// The file ends before its footer: what was taken away was not all of it.
    case cutShort
}

/// How a package is locked: by a password the person set (#247), or by a key handed over
/// another way (#253) — a random key sent inside a session the pairing code proved.
public enum PackageKey: Sendable {
    case password(String)
    case direct(SymmetricKey)

    var keying: PackageFormat.Keying {
        switch self {
        case .password: .password
        case .direct: .direct
        }
    }
}

/// What the header says a package holds — #252's question, read from the header alone and
/// before an entry is touched.
public struct PackageSummary: Sendable, Equatable {
    /// What the package holds: the whole store, or only what signs in (#6).
    public enum Contents: String, Sendable, Codable {
        case whole
        case signInsOnly
    }

    public struct SourceLine: Sendable, Equatable, Codable {
        public let host: String
        public let kind: ProtocolKind

        public init(host: String, kind: ProtocolKind) {
            self.host = host
            self.kind = kind
        }
    }

    public let contents: Contents
    public let sources: [SourceLine]
    public let posts: Int
    public let timelines: Int
    public let takenAt: Date
    public let withPictures: Bool
    /// What every entry adds up to, in bytes.
    public let bytes: Int
    public let hasSecrets: Bool
    /// The device it was taken from, as that device names itself.
    public let device: String
    public let appVersion: String
    public let entryCount: Int

    public init(
        contents: Contents = .whole, sources: [SourceLine], posts: Int, timelines: Int, takenAt: Date,
        withPictures: Bool, bytes: Int, hasSecrets: Bool, device: String, appVersion: String,
        entryCount: Int
    ) {
        self.contents = contents
        self.sources = sources
        self.posts = posts
        self.timelines = timelines
        self.takenAt = takenAt
        self.withPictures = withPictures
        self.bytes = bytes
        self.hasSecrets = hasSecrets
        self.device = device
        self.appVersion = appVersion
        self.entryCount = entryCount
    }

    /// The header as it rides, sealed, after the prelude. The date, the picture flag and the
    /// byte total live in the prelude, which is the header's AAD, so they are covered by its tag
    /// without being written twice.
    struct Header: Codable {
        var contents: String
        var sources: [PackageSummary.SourceLine]
        var posts: Int
        var timelines: Int
        var hasSecrets: Bool
        var device: String
        var appVersion: String
        var entryCount: Int

        init(_ summary: PackageSummary) {
            contents = summary.contents.rawValue
            sources = summary.sources
            posts = summary.posts
            timelines = summary.timelines
            hasSecrets = summary.hasSecrets
            device = summary.device
            appVersion = summary.appVersion
            entryCount = summary.entryCount
        }

        /// The summary, with the prelude's facts joined. A `contents` this build does not know is
        /// a newer build's.
        func summary(_ prelude: PackageFormat.Prelude) throws -> PackageSummary {
            guard let contents = PackageSummary.Contents(rawValue: contents) else { throw PackageRefusal.newer }
            guard posts >= 0, timelines >= 0, entryCount >= 0 else { throw PackageRefusal.altered }
            return PackageSummary(
                contents: contents, sources: sources, posts: posts, timelines: timelines,
                takenAt: prelude.takenAt, withPictures: prelude.withPictures, bytes: prelude.bytes,
                hasSecrets: hasSecrets, device: device, appVersion: appVersion, entryCount: entryCount
            )
        }
    }
}

/// A `ProtocolKind` on the wire is its raw spelling; one this build does not know reads as
/// `.unknown`, as the index reads it, so a package is not refused for a kind the store itself
/// would carry.
extension ProtocolKind: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProtocolKind(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

/// A reading position in a `Data`, for the fixed-layout prelude.
struct Cursor {
    private let data: Data
    private var at: Int

    init(_ data: Data) {
        self.data = data
        at = data.startIndex
    }

    mutating func take(_ count: Int) -> Data {
        let slice = data[at..<at + count]
        at += count
        return Data(slice)
    }

    mutating func byte() -> UInt8 {
        let value = data[at]
        at += 1
        return value
    }

    mutating func le<T: FixedWidthInteger>() -> T {
        let slice = take(MemoryLayout<T>.size)
        return slice.withUnsafeBytes { $0.loadUnaligned(as: T.self) }.littleEndian
    }
}
