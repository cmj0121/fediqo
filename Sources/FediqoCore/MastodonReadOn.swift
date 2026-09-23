import Foundation

// A microblog timeline read again reads on from where this device left it (#201).
//
// Reading a timeline used to ask for its newest stretch and nothing else. Where more arrived while
// the app was closed than one stretch holds, what lay between that stretch and the newest post
// already held was never asked for, and nothing said it was missing.
//
// **The anchor is the newest id that timeline listed a post under**, kept with each post a read of
// it brought (`Note.listed`), so it outlives a relaunch with the rows. A boost's own id, not the
// boosted post's: that is what the timeline pages by. A post the reader wrote, and anything a
// search or a thread brought, was listed by no timeline and never moves it; nor does a post its
// source said is gone (#179), which the source will not hand back. A row stored before this was
// listed by nothing, so a timeline held only from then is read as one held nowhere.
//
// **Read on with `min_id`, never `since_id`.** `since_id` answers with the newest page above it
// and skips whatever does not fit; `min_id` answers with the posts immediately after it. Each
// stretch reads on from the newest the one before listed, toward the newest, until a stretch
// comes back short of a full one. At most `bound` stretches in one read: where the last of them
// was full, more may remain, and the newest post read says so. A stretch that fails after the
// first keeps what came before it, and says more may remain above that the same way.
//
// **Where the source no longer gives back what lay between.** The first stretch is asked from
// one before the anchor, so the anchor itself comes back first where the source still holds it.
// Where the first stretch brings posts and not the anchor, one stretch before its oldest is asked
// too. Reaching down to the anchor or past it, the anchor was only deleted and nothing lies
// between: that stretch lands, and nothing is said. Coming back empty or short of it — a home
// timeline kept only so long, or rebuilt after a long absence — posts may be missing below the
// oldest post read, and that is said there. "May be": a post deleted without this device hearing
// (#179) is not told from one let go, and neither is a stretch that could not be asked. An id
// that is not a number has no "one before", and says nothing either way rather than claim a gap
// it cannot see.
//
// **With no anchor**, the newest stretch is read, as it always was. Where this device holds
// posts of that timeline all the same — rows stored before `Note.listed` was kept, which name no
// anchor — and the newest stretch shares none of them, what lay between was not read, and posts
// may be missing below its oldest. It is not read on from their ids instead: a post the reader
// wrote is among them, and reading on from it is the hole this rule exists against.
//
// **Reaching where posts may be missing reads down from it** (#204), before the id the marked
// post was listed under, a bounded stretch at a time, toward what is held below it. Reaching an id
// at or below the newest this timeline listed a held post under — or a post held there, listed as
// itself and not boosted — fills the hole, and the mark goes: listed ids decide, never when a post
// was written or boosted. The bound reached first moves the mark down to the oldest post read, and
// the mark keeps that id to read on from. Only a source answering with nothing settles it: what
// lay there is no longer there, which is said for good and let go as a post deleted at its source
// is (#179). Posts none older than asked are a server not paging, and fail the stretch.

/// Mastodon's ids, compared and stepped as the numbers they are.
public enum StatusID {
    /// Whether `a` names a later status than `b`. A Mastodon id grows with time and a longer one
    /// is a later one; plain string order would put "9" after "10".
    public static func later(_ a: String, than b: String) -> Bool {
        let a = trimmed(a), b = trimmed(b)
        return a.count != b.count ? a.count > b.count : a > b
    }

    /// The id one before `id`, so a read of what is newer than it still brings `id` back.
    /// Nothing for an id that is not a positive decimal number.
    public static func before(_ id: String) -> String? {
        let digits = Array(trimmed(id))
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits != ["0"] else {
            return nil
        }
        var out = digits
        var index = out.count - 1
        while out[index] == "0" {
            out[index] = "9"
            index -= 1
        }
        out[index] = Character(String(out[index].wholeNumberValue! - 1))
        let stepped = trimmed(String(out))
        return stepped.isEmpty ? "0" : stepped
    }

    private static func trimmed(_ id: String) -> String {
        String(id.drop { $0 == "0" })
    }
}

/// A place in one timeline where it is not whole (#201), kept with the post it sits against.
public struct TimelineGap: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Newer posts may remain above this one: the read that brought it stopped at its bound,
        /// or failed a stretch later. Reaching it reads on.
        case newerRemain
        /// The source did not give back what lay below this one, and posts may be missing there.
        /// Reaching it reads down (#204).
        case mayBeMissing
        /// Read down, the source answered that it has nothing more below this one (#204): what lay
        /// there is no longer there. Asks nothing again, and is let go as a post deleted at its
        /// source is.
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

    /// **One of each kind per timeline per post**: two are the same place whatever moment or id
    /// each carries, so a set of them never says one place twice.
    public static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.category == b.category
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(category)
    }
}

/// A place posts may be missing, as reading down from it needs it (#204): `ItemStore.missing`.
///
/// **Decided by listed ids alone** wherever this timeline listed what is held: a post's key is
/// shared by its boosts, and when a post was written or boosted says nothing of where its
/// timeline listed it.
public struct MissingPlace: Sendable {
    /// The post the mark sits against, and the timeline it is of.
    public let post: NoteKey
    public let category: Category
    /// The id a read down reads before: the mark's own, or the one this timeline listed it under.
    public let listed: String
    /// The posts held of that timeline below it, each listed as itself and not as a boost — what
    /// a read down meets, under its own listing, to fill the hole.
    public let held: Set<NoteKey>
    /// The newest id among them. A read down listing at or below it has passed the hole, even
    /// where the post under that id is one the source has since deleted.
    public let floor: String?
    /// Whether anything at all of that timeline is held below it — `held` less what it leaves out.
    /// Where nothing is, there is no hole; where only what `held` leaves out is, there still is.
    public let hasBelow: Bool

    public init(
        post: NoteKey, category: Category, listed: String, held: Set<NoteKey>, floor: String?,
        hasBelow: Bool? = nil
    ) {
        self.post = post
        self.category = category
        self.listed = listed
        self.held = held
        self.floor = floor
        self.hasBelow = hasBelow ?? (!held.isEmpty || floor != nil)
    }

    /// Whether `post`, read down, is one held below the mark or reaches down past them. A boost
    /// shares the key of the post it boosts, which may be held far below: only its id says where
    /// it stands.
    func meets(_ post: Listed) -> Bool {
        if let floor, !StatusID.later(post.listed, than: floor) { return true }
        return post.note.boostedBy == nil && held.contains(post.note.key)
    }
}

/// What reading down from a place posts may be missing brought (#204).
public struct ReadDown: Sendable {
    public enum End: Equatable, Sendable {
        /// It met what this device holds: the hole is filled, and the mark goes.
        case met
        /// The bound stopped it first, or a stretch after the first failed: posts may still be
        /// missing below `from`, the oldest id it read, and the mark moves down to there.
        case further(from: String)
        /// The source had nothing more: what lay there is no longer there, below the oldest post
        /// read — or below the marked post itself, where it read none.
        case settled
    }

    /// Every post the read brought, newest first, each carrying the id it was listed under.
    public var notes: [Note] = []
    public var end: End
    /// What failed a stretch after the first. What came before it is still the read above.
    public var stopped: (any Error)?

    public init(notes: [Note] = [], end: End) {
        self.notes = notes
        self.end = end
    }
}

/// A stretch read down that brought posts and none older than it asked for: a server that did not
/// page as asked (#204). Not the source having nothing more — that is an empty stretch — so it
/// settles nothing, and fails the stretch as any failure does.
public struct ReadDownStalled: Error, Equatable {}

/// What reading one timeline on brought (#201).
public struct ReadOn: Sendable {
    /// Every post the read brought, the anchor again among them where the source still had it.
    public var notes: [Note] = []
    /// The oldest post read, where the source did not give back what lay between it and the anchor.
    public var missingBelow: NoteKey?
    /// The newest post read, where more may remain above it.
    public var newerRemainAbove: NoteKey?
    /// What failed a stretch after the first. What came before it is still the read above.
    public var stopped: (any Error)?

    public init(notes: [Note] = [], missingBelow: NoteKey? = nil, newerRemainAbove: NoteKey? = nil) {
        self.notes = notes
        self.missingBelow = missingBelow
        self.newerRemainAbove = newerRemainAbove
    }
}

/// One post as a timeline listed it: under its own id, a boost's being the boost's.
typealias Listed = (listed: String, note: Note)

enum MastodonReadOn {
    /// How many stretches one read asks at most — five of `limit` posts.
    static let bound = 5
    /// How many posts one stretch asks for. A stretch that brings fewer is the last.
    static let limit = 40

    /// One timeline, read on from `anchor`. `newer` asks one stretch: the posts listed after the
    /// id it is handed, or the newest where it is handed nothing. `older` asks the stretch before
    /// an id, to tell an anchor deleted from what the source let go.
    ///
    /// `held` is the posts this device holds of that timeline, asked only where there is no anchor.
    static func read(
        from anchor: String?, holding held: Set<NoteKey> = [], bound: Int = bound,
        newer: (String?) async throws -> [Listed],
        older: (String) async throws -> [Listed]
    ) async throws -> ReadOn {
        guard let anchor else {
            let posts = try await newer(nil)
            var read = ReadOn(notes: posts.map(\.note))
            if !held.isEmpty, let oldest = oldest(posts), !posts.contains(where: { held.contains($0.note.key) }) {
                read.missingBelow = oldest.note.key
            }
            return read
        }
        let before = StatusID.before(anchor)
        var cursor = before ?? anchor
        var last: NoteKey?
        var read = ReadOn()
        for stretch in 0..<bound {
            let posts: [Listed]
            do {
                posts = try await newer(cursor)
            } catch where stretch > 0 && !ends(error) {
                read.stopped = error
                read.newerRemainAbove = last
                return read
            }
            read.notes += posts.map(\.note)
            if stretch == 0, before != nil, let oldest = oldest(posts),
               !posts.contains(where: { $0.listed == anchor }) {
                let below: [Listed]
                do {
                    below = try await older(oldest.listed)
                } catch where !ends(error) {
                    below = []
                }
                read.notes += below.map(\.note)
                if !below.contains(where: { !StatusID.later($0.listed, than: anchor) }) {
                    read.missingBelow = (self.oldest(below) ?? oldest).note.key
                }
            }
            guard let newest = posts.filter({ StatusID.later($0.listed, than: cursor) })
                .max(by: { StatusID.later($1.listed, than: $0.listed) })
            else { return read }
            cursor = newest.listed
            last = newest.note.key
            guard posts.count >= limit else { return read }
            if stretch == bound - 1 { read.newerRemainAbove = newest.note.key }
        }
        return read
    }

    /// One timeline read down from a place posts may be missing (#204), toward what is held below
    /// it: before the id the marked post was listed under, then before the oldest each stretch
    /// brought, at most `bound` stretches. `older` asks the stretch before an id.
    ///
    /// **Meeting what is held ends it**: the hole is filled. **A stretch that comes back empty
    /// ends it too**, and says the source has nothing more there. A short stretch does not: a
    /// server that filters what it lists answers short and still has more, so only nothing is
    /// nothing. With nothing at all held below the mark there is no hole to fill, and nothing is
    /// asked; with only posts it cannot meet held there, it reads on, and ends by settling or at
    /// the bound.
    /// A first stretch that fails fails the read, and the mark stays as it was.
    static func readDown(
        from place: MissingPlace, bound: Int = bound, older: (String) async throws -> [Listed]
    ) async throws -> ReadDown {
        guard place.hasBelow else { return ReadDown(end: .met) }
        var cursor = place.listed
        var read = ReadDown(end: .settled)
        for stretch in 0..<bound {
            let posts: [Listed]
            do {
                posts = try await older(cursor)
                // Only nothing is nothing more there. Posts none older than asked, meeting nothing
                // held, are a server that did not page as asked: a failure, which settles nothing.
                if !posts.isEmpty, !posts.contains(where: place.meets),
                   !posts.contains(where: { StatusID.later(cursor, than: $0.listed) }) {
                    throw ReadDownStalled()
                }
            } catch where stretch > 0 && !ends(error) {
                read.stopped = error
                read.end = .further(from: cursor)
                return read
            }
            read.notes += posts.map(\.note)
            if posts.contains(where: place.meets) {
                read.end = .met
                return read
            }
            guard let oldest = oldest(posts.filter { StatusID.later(cursor, than: $0.listed) }) else {
                read.end = .settled
                return read
            }
            cursor = oldest.listed
            read.end = .further(from: cursor)
        }
        return read
    }

    private static func oldest(_ posts: [Listed]) -> Listed? {
        posts.min { StatusID.later($1.listed, than: $0.listed) }
    }

    /// Whether `error` ends the whole read rather than one stretch of it: a sign-out by the
    /// server, or a reader walking away — after either, nothing read may land.
    static func ends(_ error: any Error) -> Bool {
        if (error as? MastodonAuthError) == .signedOut { return true }
        return Cancellation.happened(error)
    }
}

extension Dictionary where Key == Category, Value == String {
    /// These listings and `other`'s, keeping the later id where both list one timeline.
    func later(_ other: Self) -> Self {
        merging(other) { StatusID.later($1, than: $0) ? $1 : $0 }
    }
}

extension MastodonPage {
    /// The stretch immediately newer than a post (#201): `min_id`, checked as `max_id` is.
    static func newer(than minID: String?) throws -> [URLQueryItem] {
        guard let minID else { return [] }
        guard ListSubscription.isPathSegment(minID) else { throw MastodonRequestError.invalidURL }
        return [URLQueryItem(name: "min_id", value: minID)]
    }
}
