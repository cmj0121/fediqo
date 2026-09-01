import Foundation
import GRDB

/// The one order a timeline is in, in both of the languages it has to be said in.
///
/// Newest first, `mergeKey` breaking the ties, so that two posts sharing a millisecond still
/// have a below and an above and a page boundary can fall between them.
///
/// **Why this is a type and not a function on `Post`.** It was `Post.isOlder`, whose own
/// documentation claimed to be the single spelling of the order and then listed the store's cut
/// and its `ORDER BY` among the things it had consolidated — which the store did not use. So
/// the one spelling that could silently disagree was the one that had not been consolidated,
/// and the post that falls between two spellings is skipped without anybody being told. Here
/// the comparator and the SQL are members of one type, and a query that wants the order asks
/// for it rather than writing it out again.
///
/// It is also not a fact about a post. "Which of these is further down" is a question about a
/// view of posts: a post out of any list has no below.
public enum TimelineOrder {
    /// Further down the timeline than `other`.
    public static func isOlder(_ post: Post, than other: Post) -> Bool {
        post.createdAt == other.createdAt ? post.mergeKey > other.mergeKey
                                          : post.createdAt < other.createdAt
    }

    /// The `ORDER BY` tail every page of the timeline is read with.
    ///
    /// Written for a query whose posts table is aliased `p`, which every one of them does. The
    /// two columns run opposite ways — newest first, and then the *larger* `merge_key` further
    /// down — which is the same tiebreak `isOlder` gives and the reason `cut` cannot be a row
    /// comparison.
    static let newestFirst = "p.posted_at DESC, p.merge_key"

    /// The same order read from the other end. A conversation is read from the top down, and
    /// the timeline's order is newest first, so this is the one place that says so.
    static let oldestFirst = "p.posted_at, p.merge_key"

    /// Everything strictly further down the timeline than `post`, and the values it binds —
    /// nothing at all where there is no cursor, because the first page starts at the top.
    ///
    /// The cursor is the pair the order is made of, so the tiebreak is in the cut as well as in
    /// the sort: two posts written in the same millisecond are ordinary, and with the timestamp
    /// alone a boundary falling between them would either repeat the first or skip the second.
    /// Never OFFSET — a page written in between would shift every count under it.
    ///
    /// The two columns run opposite ways, so this cannot be the one row-value comparison
    /// `(a, b) < (?, ?)`: that wants both going the same way. SQLite makes what it can of the
    /// OR instead — it seeks on `posted_at` alone and re-checks the whole condition per row, so
    /// the only rows read and dropped are those sharing the cursor's own millisecond.
    static func cut(before post: Post?) -> Cut {
        guard let post else { return Cut(sql: "", arguments: []) }
        let at = LocalStore.milliseconds(post.createdAt)
        return Cut(sql: "AND (p.posted_at < ? OR (p.posted_at = ? AND p.merge_key > ?))",
                   arguments: [at.databaseValue, at.databaseValue, post.mergeKey.databaseValue])
    }

    /// Where a page starts, in the two halves a query needs it in: the clause, and the values
    /// it binds. Bound as `DatabaseValue` so the whole of it can cross into the read.
    struct Cut: Sendable {
        let sql: String
        let arguments: [DatabaseValue]
    }
}
