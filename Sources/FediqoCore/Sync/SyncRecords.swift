import Foundation

/// One record as it merges: its stamp and its value, or no value for a tombstone (D4). A
/// tombstone is never pruned and merges exactly like an edit.
public struct Stamped<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var stamp: SyncStamp
    /// nil: removed at `stamp`.
    public var value: Value?

    public init(_ value: Value?, at stamp: SyncStamp) {
        self.value = value
        self.stamp = stamp
    }

    public var isGone: Bool { value == nil }

    private enum CodingKeys: String, CodingKey {
        case stamp
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stamp = try container.decode(SyncStamp.self, forKey: .stamp)
        value = try container.decodeIfPresent(Value.self, forKey: .value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stamp, forKey: .stamp)
        try container.encodeIfPresent(value, forKey: .value)
    }
}

/// A source as it merges (D2): host, kind and boards. **Never lists** — a list id is one
/// account's. Codable by the kind's raw value; a kind this build cannot name throws
/// `SyncRefusal.peerNewer` (fail closed, never read as `.unknown`).
public struct SyncSource: Hashable, Sendable, Codable {
    public let host: String
    public let kind: ProtocolKind
    public let boards: [BoardSubscription]

    public init(host: String, kind: ProtocolKind, boards: [BoardSubscription]) {
        self.init(Source(host: host, kind: kind, boards: boards))
    }

    public init(_ source: Source) {
        host = source.host
        kind = source.kind
        boards = source.boards
    }

    private enum CodingKeys: String, CodingKey {
        case host, kind, boards
    }

    private struct Board: Codable {
        let fid: Int
        let name: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decode(String.self, forKey: .host)
        guard let kind = ProtocolKind(rawValue: try container.decode(String.self, forKey: .kind)) else {
            throw SyncRefusal.peerNewer
        }
        let boards = try container.decode([Board].self, forKey: .boards)
        guard host.isParsedHost, Set(boards.map(\.fid)).count == boards.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .host, in: container, debugDescription: "source host not as kept, or repeats a board")
        }
        self.init(host: host, kind: kind, boards: boards.map { BoardSubscription(fid: $0.fid, name: $0.name) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(boards.map { Board(fid: $0.fid, name: $0.name) }, forKey: .boards)
    }
}

/// A written timeline as it merges (D3: the whole definition is the unit). `body` is the
/// timelines file's own row JSON for it (`WrittenTimelineStore.body(of:)`, sorted keys), opaque
/// to Core; `name` is read out of it for the preview. A body this build cannot read refuses
/// the merge (`SyncLocal.readable`).
public struct SyncTimeline: Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String
    public let body: Data

    public init(id: UUID, name: String, body: Data) {
        self.id = id
        self.name = name
        self.body = body
    }
}

/// Everything one side merges: every source entry by host and every timeline entry by id,
/// tombstones included. Codable as two arrays sorted by key (`{"sources":[SourceEntry],
/// "timelines":[TimelineEntry]}`), each entry `{"host"|"id", "stamp", "value"?}`. A repeated key,
/// a host not as `Host.parse` keeps it, or a value whose own host or id is not its key, is
/// malformed. A source entry whose host `isLocalHost` is read past, never merged.
public struct SyncSnapshot: Hashable, Sendable, Codable {
    public var sources: [String: Stamped<SyncSource>]
    public var timelines: [UUID: Stamped<SyncTimeline>]

    public init(sources: [String: Stamped<SyncSource>] = [:], timelines: [UUID: Stamped<SyncTimeline>] = [:]) {
        self.sources = sources
        self.timelines = timelines
    }

    public static let empty = SyncSnapshot()

    /// It without any source whose host `isLocalHost`: what this side sends and merges.
    public var shared: SyncSnapshot {
        SyncSnapshot(sources: sources.filter { !$0.key.isLocalHost }, timelines: timelines)
    }

    /// The greatest stamp in it: what `SyncClock.witness` is told after a merge.
    public var newest: SyncStamp {
        (sources.values.map(\.stamp) + timelines.values.map(\.stamp)).max() ?? .zero
    }

    private enum CodingKeys: String, CodingKey {
        case sources, timelines
    }

    private struct SourceEntry: Codable {
        let host: String
        let stamp: SyncStamp
        let value: SyncSource?
    }

    private struct TimelineEntry: Codable {
        let id: UUID
        let stamp: SyncStamp
        let value: SyncTimeline?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceEntries = try container.decode([SourceEntry].self, forKey: .sources)
        let timelineEntries = try container.decode([TimelineEntry].self, forKey: .timelines)
        var sources: [String: Stamped<SyncSource>] = [:]
        var seen: Set<String> = []
        for entry in sourceEntries {
            guard entry.host.isParsedHost,
                  entry.value.map({ $0.host == entry.host }) ?? true,
                  seen.insert(entry.host).inserted
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sources, in: container, debugDescription: "source entry repeated, misnamed or not as kept")
            }
            if !entry.host.isLocalHost { sources[entry.host] = Stamped(entry.value, at: entry.stamp) }
        }
        var timelines: [UUID: Stamped<SyncTimeline>] = [:]
        for entry in timelineEntries {
            guard entry.value.map({ $0.id == entry.id }) ?? true,
                  timelines.updateValue(Stamped(entry.value, at: entry.stamp), forKey: entry.id) == nil
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timelines, in: container, debugDescription: "timeline entry \(entry.id) repeated or misnamed")
            }
        }
        self.init(sources: sources, timelines: timelines)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            sources.sorted { $0.key < $1.key }.map { SourceEntry(host: $0.key, stamp: $0.value.stamp, value: $0.value.value) },
            forKey: .sources)
        try container.encode(
            timelines.sorted { $0.key.uuidString < $1.key.uuidString }
                .map { TimelineEntry(id: $0.key, stamp: $0.value.stamp, value: $0.value.value) },
            forKey: .timelines)
    }
}

extension String {
    /// Exactly what `Host.parse` makes of it (lowercase, no scheme, path, query or userinfo):
    /// the only spelling a source host is kept in. Anything else in a snapshot is malformed.
    fileprivate var isParsedHost: Bool { (try? Host.parse(self)) == self }

    /// A parsed host that is this device or its link — loopback (`localhost`, 0/8, 127/8, `::`,
    /// `::1`) or link-local (169.254/16, fe80::/10), a port or one trailing dot aside. Never
    /// merged either way: left out of what is sent, ignored in what arrives. A merged source
    /// is fetched from, and a peer's word must not point that fetch back inside the device or
    /// its LAN; a person's own such source still stays theirs, here only.
    var isLocalHost: Bool {
        var name = self
        if hasPrefix("["), hasSuffix("]") {
            let inner = String(dropFirst().dropLast())
            var address = in6_addr()
            if inet_pton(AF_INET6, inner, &address) == 1 {
                let bytes = withUnsafeBytes(of: address) { Array($0) }
                let unspecifiedOrLoopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] <= 1
                let linkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
                let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
                return unspecifiedOrLoopback || linkLocal || (mapped && Self.isLocalIPv4(bytes[12], bytes[13]))
            }
            // `Host.parse` keeps a name with a port bracketed: "[a.example:8443]".
            name = inner.lastIndex(of: ":").map { String(inner[..<$0]) } ?? inner
        }
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        var address = in_addr()
        guard inet_aton(name, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address.s_addr) { Array($0) }
        return Self.isLocalIPv4(bytes[0], bytes[1])
    }

    /// 0/8, 127/8 or 169.254/16, by an IPv4 address's first two bytes.
    private static func isLocalIPv4(_ first: UInt8, _ second: UInt8) -> Bool {
        first == 0 || first == 127 || (first == 169 && second == 254)
    }
}

/// The source stamps and tombstones a store keeps (U3) beside its `[Source]`.
/// Invariant: a host is in `stamps` (live; a host missing reads `.zero`) or in `gone`, never both.
public struct SourceSync: Sendable, Equatable {
    public var stamps: [String: SyncStamp]
    /// Tombstones by host, never pruned (D4).
    public var gone: [String: SyncStamp]

    public init(stamps: [String: SyncStamp] = [:], gone: [String: SyncStamp] = [:]) {
        self.stamps = stamps
        self.gone = gone
    }

    /// `sources` and these stamps as merge entries.
    public func entries(_ sources: [Source]) -> [String: Stamped<SyncSource>] {
        var entries = gone.mapValues { Stamped<SyncSource>(nil, at: $0) }
        for source in sources {
            entries[source.host] = Stamped(SyncSource(source), at: stamps[source.host] ?? .zero)
        }
        return entries
    }

    public var newest: SyncStamp {
        (Array(stamps.values) + Array(gone.values)).max() ?? .zero
    }
}
