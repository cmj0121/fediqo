import Foundation

/// What a merge changes on one side, record by record, and what a person is told of it.
public struct SyncChanges: Hashable, Sendable {
    /// Every source entry whose winner differs from what this side holds — live or tombstone,
    /// including a tombstone that only moved its stamp. Applied as given; **no new stamp**.
    public var sources: [String: Stamped<SyncSource>]
    public var timelines: [UUID: Stamped<SyncTimeline>]
    public var summary: SyncSummary

    public var isEmpty: Bool { sources.isEmpty && timelines.isEmpty }
}

/// What a person sees of one side's changes (D8 preview and the outcome after).
/// Added = none/tombstone → live; replaced = live → live with another value; removed =
/// live → tombstone. A stamp moving under an equal value, or tombstone → tombstone, is silent.
public struct SyncSummary: Hashable, Sendable, Codable {
    public var addedSources: [String]
    public var replacedSources: [String]
    public var removedSources: [String]
    public var addedTimelines: [String]
    public var replacedTimelines: [String]
    public var removedTimelines: [String]

    public init(
        addedSources: [String] = [],
        replacedSources: [String] = [],
        removedSources: [String] = [],
        addedTimelines: [String] = [],
        replacedTimelines: [String] = [],
        removedTimelines: [String] = []
    ) {
        self.addedSources = addedSources
        self.replacedSources = replacedSources
        self.removedSources = removedSources
        self.addedTimelines = addedTimelines
        self.replacedTimelines = replacedTimelines
        self.removedTimelines = removedTimelines
    }

    public var isEmpty: Bool {
        addedSources.isEmpty && replacedSources.isEmpty && removedSources.isEmpty
            && addedTimelines.isEmpty && replacedTimelines.isEmpty && removedTimelines.isEmpty
    }
}

/// The first merge after pairing, as shown before the yes (D8): what would change on each side.
public struct SyncPreview: Hashable, Sendable {
    public let here: SyncSummary
    public let there: SyncSummary

    public init(here: SyncSummary, there: SyncSummary) {
        self.here = here
        self.there = there
    }

    public var isEmpty: Bool { here.isEmpty && there.isEmpty }
}

/// One merge of two snapshots, from one side's view.
public struct SyncPlan: Hashable, Sendable {
    /// Both sides end with this.
    public let merged: SyncSnapshot
    /// What this side applies.
    public let here: SyncChanges
    /// What the other side applies (its own `plan` computes the same; used for the preview).
    public let there: SyncChanges

    public var preview: SyncPreview { SyncPreview(here: here.summary, there: there.summary) }
}

public enum SyncMerge {
    /// Per key, the entry that `wins`. Commutative, associative, idempotent.
    public static func merge(_ a: SyncSnapshot, _ b: SyncSnapshot) -> SyncSnapshot {
        SyncSnapshot(sources: merge(a.sources, b.sources), timelines: merge(a.timelines, b.timelines))
    }

    /// `merge(local, remote)` and what changes on each side.
    public static func plan(local: SyncSnapshot, remote: SyncSnapshot) -> SyncPlan {
        let merged = merge(local, remote)
        return SyncPlan(merged: merged, here: changes(from: local, to: merged), there: changes(from: remote, to: merged))
    }

    /// Whether `a` beats `b`: the greater stamp; at an equal stamp (only `.zero` in practice)
    /// a live value beats a tombstone, then the greater canonical bytes
    /// (`JSONEncoder` `.sortedKeys`) of the value win — deterministic on both sides.
    public static func wins<V>(_ a: Stamped<V>, over b: Stamped<V>) -> Bool {
        if a.stamp != b.stamp { return a.stamp > b.stamp }
        switch (a.value, b.value) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?): return canonical(y).lexicographicallyPrecedes(canonical(x))
        }
    }

    /// Whether any stamp in `snapshot` is more than `mostAhead` past `now`: such a snapshot is
    /// refused as `.clockAhead` (bounds a wrong clock; nothing is witnessed).
    public static func runsAhead(_ snapshot: SyncSnapshot, now: Date, mostAhead: Duration) -> Bool {
        let (seconds, attoseconds) = mostAhead.components
        let limit = Int64((now.timeIntervalSince1970 * 1000).rounded(.down)) + seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return snapshot.newest.ms > limit
    }

    private static func merge<K, V>(_ a: [K: Stamped<V>], _ b: [K: Stamped<V>]) -> [K: Stamped<V>] {
        a.merging(b) { x, y in wins(y, over: x) ? y : x }
    }

    private static func canonical<V: Encodable>(_ value: V) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func changes(from side: SyncSnapshot, to merged: SyncSnapshot) -> SyncChanges {
        let sources = merged.sources.filter { side.sources[$0.key] != $0.value }
        let timelines = merged.timelines.filter { side.timelines[$0.key] != $0.value }
        var summary = SyncSummary()
        for host in sources.keys.sorted() {
            switch kind(of: side.sources[host]?.value, to: sources[host]?.value) {
            case .added: summary.addedSources.append(host)
            case .replaced: summary.replacedSources.append(host)
            case .removed: summary.removedSources.append(host)
            case nil: break
            }
        }
        for id in timelines.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let before = side.timelines[id]?.value
            let after = timelines[id]?.value
            switch (kind(of: before, to: after), before, after) {
            case let (.added, _, now?): summary.addedTimelines.append(now.name)
            case let (.replaced, _, now?): summary.replacedTimelines.append(now.name)
            case let (.removed, was?, _): summary.removedTimelines.append(was.name)
            default: break
            }
        }
        return SyncChanges(sources: sources, timelines: timelines, summary: summary)
    }

    private enum Change { case added, replaced, removed }

    private static func kind<V: Equatable>(of before: V?, to after: V?) -> Change? {
        switch (before, after) {
        case (nil, nil): nil
        case (nil, _?): .added
        case (_?, nil): .removed
        case let (x?, y?): x == y ? nil : .replaced
        }
    }
}
