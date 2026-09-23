import Foundation

// A microblog timeline read again reads on from where this device left it (#201).
//
// Reading a timeline used to ask for its newest stretch and nothing else. Where more arrived while
// the app was closed than one stretch holds, what lay between that stretch and the newest post
// already held was never asked for, and nothing said it was missing.
//
// **The anchor is the newest post held of that timeline**, worked out from what is held rather
// than written down beside it: every post a timeline brought carries that timeline among its
// categories, and the rows are on disk, so the anchor outlives a relaunch with nothing new kept.
// A post its source said is gone (#179) is not an anchor — the source will not hand it back.
//
// **Read on with `min_id`, never `since_id`.** `since_id` answers with the newest page above it
// and skips whatever does not fit; `min_id` answers with the posts immediately after it. Each
// stretch reads on from the newest the one before brought, toward the newest, until the source
// has nothing newer. At most `bound` stretches in one read: where the last of them still brought
// something, more may remain, and the newest post read says so.
//
// **Where the source no longer gives back what lay between.** The first stretch is asked from
// one before the anchor, so the anchor itself comes back first where the source still holds it.
// Where the first stretch brings posts and not the anchor, the source has let it go — a home
// timeline kept only so long, or rebuilt after a long absence — and what lay between it and the
// oldest post it did bring may be missing. That is said below that post. It is not proof: a
// post deleted without a read of it telling this device (#179) looks the same, which is why the
// words are "may be". An id that is not a number has no "one before", and so says nothing either
// way rather than claim a gap it cannot see.
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
        /// Newer posts remain above this one: the read that brought it stopped at its bound.
        /// Reaching it reads on.
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
    /// The oldest post of the first stretch, where the source did not give back the anchor.
    public var missingBelow: NoteKey?
    /// The newest post read, where the read stopped at its bound with more still coming.
    public var newerRemainAbove: NoteKey?

    public init(notes: [Note] = [], missingBelow: NoteKey? = nil, newerRemainAbove: NoteKey? = nil) {
        self.notes = notes
        self.missingBelow = missingBelow
        self.newerRemainAbove = newerRemainAbove
    }
}

enum MastodonReadOn {
    /// How many stretches one read asks at most — five of 40 posts.
    static let bound = 5

    /// One timeline, read on from `anchor`. `page` asks one stretch: the posts newer than the id
    /// it is handed, or the newest where it is handed nothing, each with the id the timeline
    /// lists it under — a boost's own, which is what the next stretch is asked after.
    static func read(
        from anchor: String?, bound: Int = bound,
        page: (String?) async throws -> [(listed: String, note: Note)]
    ) async throws -> ReadOn {
        guard let anchor else { return ReadOn(notes: try await page(nil).map(\.note)) }
        let before = StatusID.before(anchor)
        var cursor = before ?? anchor
        var read = ReadOn()
        for stretch in 0..<bound {
            let posts = try await page(cursor)
            read.notes += posts.map(\.note)
            if stretch == 0, before != nil, !posts.isEmpty,
               !posts.contains(where: { $0.listed == anchor || $0.note.statusID == anchor }) {
                read.missingBelow = posts.min { StatusID.later($1.listed, than: $0.listed) }?.note.key
            }
            let fresh = posts.filter { StatusID.later($0.listed, than: anchor) }
            guard let newest = fresh.max(by: { StatusID.later($1.listed, than: $0.listed) }),
                  StatusID.later(newest.listed, than: cursor)
            else { return read }
            cursor = newest.listed
            if stretch == bound - 1 { read.newerRemainAbove = newest.note.key }
        }
        return read
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
