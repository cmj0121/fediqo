import Foundation
import GRDB

/// Where one composed post went.
///
/// The rows of `publications`, read back. `Composition` is the identity the composer made when
/// the reader pressed send; everything else is what each destination became.
public struct Publication: Sendable, Hashable {
    /// The account it went as.
    public let authorId: String
    /// The server it went to, as a `servers.url` endpoint.
    public let serverURL: String
    /// The post it became there, where this device still holds it. `nil` where the post has
    /// since been purged — that it was published is not a fact about the row that was purged.
    public let mergeKey: String?
    /// Its address on that server, which stays whatever happens to the post here.
    public let uri: String

    public init(authorId: String, serverURL: String, mergeKey: String?, uri: String) {
        self.authorId = authorId
        self.serverURL = serverURL
        self.mergeKey = mergeKey
        self.uri = uri
    }
}

extension LocalStore {
    /// Writes down that one composed post reached these places.
    ///
    /// One transaction for the lot, because a composition is one act: half a record is worse
    /// than none — it would tell #5 that two of three posts are the same post and leave the
    /// third looking like somebody else's.
    ///
    /// Only what happened is written. A destination that refused has no address to record and
    /// nothing to collapse, and it was reported to the reader when it could still be acted on.
    public func recordPublication(_ composition: String, of published: [Publication],
                                  now: Date = Date()) async throws {
        guard !published.isEmpty else { return }
        let ms = Self.milliseconds(now)
        try await write { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO publications (composition, author_id, server_url, merge_key, uri, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (composition, author_id) DO UPDATE SET
                    merge_key = excluded.merge_key, uri = excluded.uri
                """)
            for row in published {
                try insert.execute(arguments: [composition, row.authorId, row.serverURL,
                                               row.mergeKey, row.uri, ms])
            }
        }
    }

    /// Everywhere a post went, where this app is the one that sent it.
    ///
    /// Asked of a post rather than of a composition, because that is how both readers of it
    /// ask: a row wants to say where it went, and #5 wants to know what else is the same post.
    /// Empty for every post this app did not publish, which is nearly all of them.
    public func published(with mergeKey: String) async throws -> [Publication] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.author_id, p.server_url, p.merge_key, p.uri
                FROM publications p
                WHERE p.composition = (SELECT composition FROM publications WHERE merge_key = ? LIMIT 1)
                ORDER BY p.server_url
                """, arguments: [mergeKey])
                .map { Publication(authorId: $0["author_id"], serverURL: $0["server_url"],
                                   mergeKey: $0["merge_key"], uri: $0["uri"]) }
        }
    }
}
