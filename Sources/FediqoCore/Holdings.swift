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
/// **Counted over everything the store holds, and the rows no timeline shows are said apart**
/// (#194). A search's finds, a conversation's answers, a forum topic's replies and a quoted post
/// are held aside (`Holding.aside`) and written down like any other row, so `posts` counts them
/// with the rest — the one figure an export, a drop or a limit is measured against — and `aside`
/// says how many of them there are, so a reader can see what accumulated without a timeline
/// bringing it. `notes` is therefore the store's whole holding, arrived and aside together; a
/// count made from `all()` alone would lie by exactly what `aside()` holds.
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

    /// Every post held, those held aside included.
    public let posts: Int
    /// How many of `posts` are held aside, and no timeline shows.
    public let aside: Int
    /// Posts held from each source, by folded host, aside ones included. A host holding none is
    /// absent.
    public let bySource: [String: Int]
    /// Of `bySource`, those held aside. A host holding none aside is absent.
    public let asideBySource: [String: Int]
    /// Newest stretch first. Only stretches holding a post are listed.
    public let byPeriod: [Bucket]

    public init(notes: [Note], per period: HeldPeriod, calendar: Calendar = .current) {
        posts = notes.count
        bySource = Dictionary(grouping: notes, by: \.source.host).mapValues(\.count)
        let apart = notes.filter { $0.holding == .aside }
        aside = apart.count
        asideBySource = Dictionary(grouping: apart, by: \.source.host).mapValues(\.count)
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

    /// How many of `posts(host:)` are held aside from the timelines.
    public func aside(host: String) -> Int {
        asideBySource[host.lowercased()] ?? 0
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

/// How long a post its source deleted stays on this device, marked, before it is let go (#179):
/// a number of days, or never where nil — the default.
///
/// **This device's wait, and the keep-for window beside it.** Both are about how long a post
/// stays, so where they disagree the shorter one wins: a post kept for at most three months is
/// not kept for ninety days because its source let it go. `cutoff` answers with which one did.
public enum GoneWait {
    /// The moment at or before which a post marked gone goes, as of `now`, and whether the keep-for
    /// window set it rather than the wait. Nothing where neither is set — keep them all, marked.
    public static func cutoff(
        days: Int?, keepingMonths months: Int?, from now: Date, calendar: Calendar = .current
    ) -> (cutoff: Date?, keepWins: Bool) {
        let waited = days.flatMap { $0 > 0 ? calendar.date(byAdding: .day, value: -$0, to: now) : nil }
        let kept = KeepPolicy.cutoff(keepingMonths: months, from: now, calendar: calendar)
        switch (waited, kept) {
        case (nil, nil): return (nil, false)
        case (let waited?, nil): return (waited, false)
        case (nil, let kept?): return (kept, true)
        // The later moment is the shorter wait. A tie is the wait's own.
        case (let waited?, let kept?): return kept > waited ? (kept, true) : (waited, false)
        }
    }
}
