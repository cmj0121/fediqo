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
// **With no anchor**, a timeline this device holds nothing of, the newest stretch is read, as
// it always was.

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
        case mayBeMissing
    }

    public let kind: Kind
    /// The timeline it is a gap of. A post Home and a list both carry can be whole in one.
    public let category: Category

    public init(_ kind: Kind, in category: Category) {
        self.kind = kind
        self.category = category
    }
}

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
    static func read(
        from anchor: String?, bound: Int = bound,
        newer: (String?) async throws -> [Listed],
        older: (String) async throws -> [Listed]
    ) async throws -> ReadOn {
        guard let anchor else { return ReadOn(notes: try await newer(nil).map(\.note)) }
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
