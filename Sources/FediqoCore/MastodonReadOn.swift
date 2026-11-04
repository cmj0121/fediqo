import Foundation

// Where a microblog timeline is read from (#470).
//
// A timeline read again reads its newest posts, and nothing below them: what lay between them
// and what an earlier read held is not read on to, nor said to be missing. **Reading it down goes
// on from the oldest post its latest read brought** (`ReadDownPlace`), one source and timeline at a
// time, and asks the source again for what lies below, whatever this device already holds there.
// This replaces reading on from the newest post held (#201) and marking where a timeline was not
// whole (#201, #204); `TimelineGap` stays only for the rows that carry such marks, which nothing
// draws any more, and for the reader's marks (#317).

/// Mastodon's ids, compared and stepped as the numbers they are.
public enum StatusID {
    /// Whether `a` names a later status than `b`. A Mastodon id grows with time and a longer one
    /// is a later one; plain string order would put "9" after "10".
    public static func later(_ a: String, than b: String) -> Bool {
        let a = trimmed(a), b = trimmed(b)
        return a.count != b.count ? a.count > b.count : a > b
    }

    private static func trimmed(_ id: String) -> String {
        String(id.drop { $0 == "0" })
    }
}

/// Where one timeline of one source is read down from (#470): the oldest post its latest read
/// brought, listed under `id`. `ended` where a read down from it brought nothing older: its source
/// has no more there, and it is not asked again until the newest is read again.
public struct ReadDownPlace: Hashable, Sendable {
    public let id: String
    public let ended: Bool

    public init(id: String, ended: Bool = false) {
        self.id = id
        self.ended = ended
    }
}

/// A place in one timeline where it is not whole (#201), kept with the post it sits against.
/// Nothing draws or reads one any more (#470); the reader's marks still say theirs, and rows on
/// file still carry the others.
public struct TimelineGap: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Newer posts may remain above this one. No longer said (#470): only rows on file carry it.
        case newerRemain
        /// The source did not give back what lay below this one, and posts may be missing there.
        case mayBeMissing
        /// The source answered that it has nothing more below this one (#204). No longer said
        /// (#470); one on file is let go as a post deleted at its source is.
        case settled
    }

    public let kind: Kind
    /// The timeline it is a gap of. A post Home and a list both carry can be whole in one.
    public let category: Category
    /// When the source said it had nothing more there — a settled place's own moment, which the
    /// wait that lets deleted posts go counts from, as it counts from `Note.goneSince`. Nothing on
    /// the other two.
    public let since: Date?
    /// Where posts may be missing below, the id a read down reads before (#204), where it is not
    /// the one this timeline listed the post under: a mark moved down by a read that stopped short
    /// keeps the oldest id that read reached, which a later listing of the same post cannot move.
    public let from: String?

    public init(_ kind: Kind, in category: Category, since: Date? = nil, from: String? = nil) {
        self.kind = kind
        self.category = category
        self.since = since
        self.from = from
    }

}

/// A post's places, **one of each kind per timeline** (#369): each is found, put and taken off by
/// its kind and timeline, whatever moment or id it carries. Two places are equal only where they
/// say the same of it, moment and id too — so a place moved down, or settled again, is a change to
/// its post, which the post is held and written with.
extension Set<TimelineGap> {
    /// The place of `kind` said in `category`, or nothing.
    public func gap(_ kind: TimelineGap.Kind, in category: Category) -> TimelineGap? {
        first { $0.kind == kind && $0.category == category }
    }

    /// `gap`, in place of any of its kind said in its timeline before.
    public mutating func place(_ gap: TimelineGap) {
        clear(gap.kind, in: gap.category)
        insert(gap)
    }

    /// `gap`, where nothing of its kind is said in its timeline yet: what is said there stays.
    public mutating func add(_ gap: TimelineGap) {
        if self.gap(gap.kind, in: gap.category) == nil { insert(gap) }
    }

    /// Whatever of `kind` is said in `category`, taken off.
    public mutating func clear(_ kind: TimelineGap.Kind, in category: Category) {
        if let said = gap(kind, in: category) { remove(said) }
    }
}

/// One item as a timeline listed it, under its own id — a reblog's being the reblog's (#290) —
/// and what came with it in the payload without being listed: the post a reblog reblogs.
typealias Listed = (listed: String, note: Note, carried: [Note])

extension Array where Element == Listed {
    /// Every note a stretch brought: each item listed, and what it carried.
    var landing: [Note] { flatMap { [$0.note] + $0.carried } }
}

enum MastodonReadOn {
    /// How many posts one stretch asks for.
    static let limit = 40
}

extension Dictionary where Key == Category, Value == String {
    /// These listings and `other`'s, keeping the later id where both list one timeline — and of
    /// the reader's marks (#317), what both spans say of the post together (`MarkSpan.merged`).
    func later(_ other: Self) -> Self {
        var merged = self
        for (category, id) in other {
            guard let held = merged[category] else {
                merged[category] = id
                continue
            }
            if category.isMarks, let was = MarkSpan(listed: held), let now = MarkSpan(listed: id) {
                merged[category] = was.merged(with: now).listed
            } else if StatusID.later(id, than: held) {
                merged[category] = id
            }
        }
        return merged
    }
}
