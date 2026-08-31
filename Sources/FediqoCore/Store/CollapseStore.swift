import Foundation
import GRDB

/// One post that this store made out of more than one.
///
/// #5's last promise, and the one that is about being wrong rather than being right: *"Getting
/// it wrong is visible: a debug view can show what was collapsed and why."* Every other line of
/// that issue is a rule the app follows silently; this is the one that says a reader must be
/// able to check it.
///
/// It is not a list of posts. It is a list of decisions — each one a row this store has, the
/// several it was made from, and which of the two reasons it had.
public struct Collapse: Sendable, Hashable {
    /// Why two arrivals were treated as one post.
    ///
    /// Two reasons and they are not the same kind of thing, which is the whole reason to draw
    /// them apart. One is an inference from what two servers said; the other is knowledge,
    /// because this app was the one that sent them.
    public enum Reason: Sendable, Hashable {
        /// Both servers handed over a post naming this canonical address. A good inference —
        /// and if it is ever wrong, it is wrong here, which is why the address is carried.
        case sameAddress(String)
        /// This app published it, to these servers, and wrote down where. Nothing was inferred.
        case published
    }

    public let mergeKey: String
    /// Enough of the post to recognise it. Not the post itself: this is a view of a decision,
    /// and a reader checking one wants to see which post and then the reasoning.
    public let says: String
    /// Every server that carried it, in the order the store keeps them.
    public let sources: [String]
    public let reason: Reason

    public init(mergeKey: String, says: String, sources: [String], reason: Reason) {
        self.mergeKey = mergeKey
        self.says = says
        self.sources = sources
        self.reason = reason
    }
}

extension LocalStore {
    /// Every post here that was made out of more than one arrival, newest first.
    ///
    /// "More than one" is asked of `post_origins`, because that is what a collapse leaves
    /// behind: one row in `posts` and a row per server that carried it. A post one server
    /// handed over is not a decision and is not here.
    ///
    /// A boost and its original are never in this list together, and that is not a filter — it
    /// is `mergeKey`, which carries the booster, so the two were never one row to begin with.
    public func collapses(limit: Int = 100) async throws -> [Collapse] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.merge_key, p.text, p.origin_uri,
                       EXISTS (SELECT 1 FROM publications WHERE merge_key = p.merge_key) AS published
                FROM posts p
                WHERE p.deleted_at IS NULL
                  AND (SELECT count(*) FROM post_origins WHERE merge_key = p.merge_key) > 1
                ORDER BY p.posted_at DESC, p.merge_key
                LIMIT ?
                """, arguments: [limit])
            guard !rows.isEmpty else { return [] }

            let keys = rows.map { $0["merge_key"] as String }
            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
            var carriedBy: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT merge_key, source_url FROM post_origins
                WHERE merge_key IN (\(placeholders)) ORDER BY source_url
                """, arguments: StatementArguments(keys)) {
                carriedBy[row["merge_key"], default: []].append(Self.host(of: row["source_url"]))
            }

            return rows.map { row in
                let key: String = row["merge_key"]
                // Published wins where both are true. It is the stronger of the two: the
                // addresses may also agree, but agreement is what we would have guessed and
                // this is what we know.
                let reason: Collapse.Reason = (row["published"] as Bool)
                    ? .published
                    : .sameAddress(row["origin_uri"] ?? key)
                return Collapse(mergeKey: key, says: row["text"],
                                sources: carriedBy[key] ?? [], reason: reason)
            }
        }
    }
}
