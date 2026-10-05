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
    /// How many earlier wordings of changed posts are held with them (#286): part of what this
    /// device holds, and so part of what it says it holds.
    public let earlier: Int
    /// Newest stretch first. Only stretches holding a post are listed.
    public let byPeriod: [Bucket]

    /// What the person keeps of some of the posts held (#284, #294): how many, and what their
    /// words weigh.
    ///
    /// **Words, and said to be words.** `bytes` is what the posts say — body, title, warning, and
    /// every earlier wording held with them (#286) — as the bytes they are written in: a figure
    /// counted from the notes themselves, so it needs no read of the disk and is the same on
    /// every device holding them. It is not what their rows take in the index, which carries
    /// more than words, and it is not their pictures: a picture copy is kept by its source and
    /// not by its post (`MediaCopies`), so no copy can be said to be a kept post's.
    public struct Kept: Equatable, Sendable {
        public let posts: Int
        public let bytes: Int

        public static let none = Kept(posts: 0, bytes: 0)
    }

    /// Everything kept, every source together.
    public let kept: Kept
    /// What is kept from each source, by folded host — one that has been removed included, since
    /// a kept post outlives its source and still names it. A host with nothing kept is absent.
    public let keptBySource: [String: Kept]
    /// Of each source's kept posts, how many are kept through another source too (#294): a post
    /// two sources carry is two rows here and one on screen (`SamePost`), and it is drawn as
    /// kept while either copy is. So stopping keeping one source's copies leaves these kept —
    /// which the act that does it has to be able to say. A host with none is absent.
    public let keptElsewhereBySource: [String: Int]

    public init(notes: [Note], per period: HeldPeriod, calendar: Calendar = .current) {
        posts = notes.count
        bySource = Dictionary(grouping: notes, by: \.source.host).mapValues(\.count)
        let apart = notes.filter { $0.holding == .aside }
        aside = apart.count
        asideBySource = Dictionary(grouping: apart, by: \.source.host).mapValues(\.count)
        earlier = notes.reduce(0) { $0 + $1.earlier.count }
        let keeping = notes.filter(\.kept)
        kept = Kept(posts: keeping.count, bytes: keeping.reduce(0) { $0 + $1.wordBytes })
        keptBySource = Dictionary(grouping: keeping, by: \.source.host).mapValues { held in
            Kept(posts: held.count, bytes: held.reduce(0) { $0 + $1.wordBytes })
        }
        var elsewhere: [String: Int] = [:]
        for copies in SamePost.gathered(keeping) where Set(copies.map(\.source.host)).count > 1 {
            for copy in copies { elsewhere[copy.source.host, default: 0] += 1 }
        }
        keptElsewhereBySource = elsewhere
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

    /// What is kept from `host`, or nothing.
    public func kept(host: String) -> Kept {
        keptBySource[host.lowercased()] ?? .none
    }

    /// How many of `kept(host:).posts` stay kept through another source's copy.
    public func keptElsewhere(host: String) -> Int {
        keptElsewhereBySource[host.lowercased()] ?? 0
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
