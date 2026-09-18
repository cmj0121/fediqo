import Foundation

/// How long a stretch of time one line of the breakdown covers (#7).
public enum HeldPeriod: String, CaseIterable, Sendable {
    case week
    case month

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

/// What this device holds, counted: in total, by source, and by week or month (#7).
///
/// **Counted in one pass per figure, over notes already read out of the store.** A readout drawn
/// on every body pass must not filter the whole index once per source row, so the notes are
/// grouped once by host and once by period, and each row reads its figure out of a dictionary.
public struct Holdings: Equatable, Sendable {
    /// One stretch of the breakdown: the week or month starting at `start`, and its posts.
    public struct Bucket: Equatable, Sendable {
        public let start: Date
        public let posts: Int
    }

    public let posts: Int
    /// Posts held from each source, by folded host. A host holding none is absent.
    public let bySource: [String: Int]
    /// Newest stretch first. Only stretches holding a post are listed.
    public let byPeriod: [Bucket]

    public init(notes: [Note], per period: HeldPeriod, calendar: Calendar = .current) {
        posts = notes.count
        bySource = Dictionary(grouping: notes, by: \.source.host).mapValues(\.count)
        let component = period.component
        byPeriod = Dictionary(grouping: notes) {
            calendar.dateInterval(of: component, for: $0.postedAt)?.start ?? $0.postedAt
        }
        .map { Bucket(start: $0.key, posts: $0.value.count) }
        .sorted { $0.start > $1.start }
    }

    public func posts(host: String) -> Int {
        bySource[host.lowercased()] ?? 0
    }
}

/// The reader's time policy: keep everything (nil, the default), or only the latest months (#7).
public enum KeepPolicy {
    /// The moment before which a note goes, keeping the latest `months` months as of `now` —
    /// or nothing, where `months` is nil or not a positive count, because that is keeping forever.
    public static func cutoff(keepingMonths months: Int?, from now: Date, calendar: Calendar = .current) -> Date? {
        guard let months, months > 0 else { return nil }
        return calendar.date(byAdding: .month, value: -months, to: now)
    }

    /// Whether going from keeping `old` to keeping `new` would drop posts: any window after
    /// forever, or a narrower one. Widening, or going back to forever, drops nothing.
    public static func shortens(from old: Int?, to new: Int?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        return new < old
    }
}
