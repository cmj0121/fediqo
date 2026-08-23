import Foundation
import GRDB

/// A post the store will not write, because a column it may never backfill would be empty.
public enum PostStoreError: Error, Equatable, LocalizedError {
    case missingAuthor(uri: String)
    case missingSource(uri: String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthor(let uri): "\(uri) names no author."
        case .missingSource(let uri): "\(uri) names no source."
        }
    }
}

/// Posts in and out of the store, as the "Writing" and "Reading" diagrams in
/// `docs/data-store.md` draw them. Raw SQL against the schema: the schema is the contract,
/// and there is no second description of it in Swift to drift.
extension LocalStore {
    // MARK: Writing

    /// One refresh, one transaction: servers, accounts and tags first (the foreign keys say
    /// so), then each post — inserted if new, otherwise touched, and rewritten only when the
    /// server it came from is the authority for it. `.trending` also records the server's
    /// ranking. Every hour these posts were written in gets its `tag_buckets` recounted last.
    public func save(_ posts: [Post], from server: Server, mode: FeedMode, now: Date = Date()) async throws {
        for post in posts {
            if post.authorId.isEmpty { throw PostStoreError.missingAuthor(uri: post.uri) }
            if post.sourceURL.isEmpty { throw PostStoreError.missingSource(uri: post.uri) }
        }
        let serverURL = "https://\(server.host)"
        let serverTitle = server.title
        let ms = Self.milliseconds(now)

        try await write { db in
            for (index, post) in posts.enumerated() {
                let proto = post.socialProtocol.storeProto
                let authorityURL = Self.authorityURL(of: post)
                let authorServerURL = Self.endpoint(ofHost: post.authorId)
                let boosterServerURL = post.boostedById.flatMap(Self.endpoint(ofHost:))

                try Self.upsertServer(db, url: post.sourceURL, proto: proto,
                                      title: post.sourceURL == serverURL ? serverTitle : nil, now: ms)
                for url in [authorityURL, authorServerURL, boosterServerURL].compactMap({ $0 }) where url != post.sourceURL {
                    try Self.upsertServer(db, url: url, proto: proto, title: nil, now: ms)
                }

                try Self.upsertAccount(db, id: post.authorId, proto: proto, serverURL: authorServerURL,
                                       handle: post.authorHandle, displayName: post.authorName,
                                       avatarURL: post.authorAvatarURL?.absoluteString, now: ms)
                if let boostedById = post.boostedById {
                    try Self.upsertAccount(db, id: boostedById, proto: proto, serverURL: boosterServerURL,
                                           handle: nil, displayName: post.boostedBy, avatarURL: nil, now: ms)
                }

                // display is the lowercased tag today: Post.normalisedTags drops the casing. Once Post
                // keeps the spelling it saw, a DO UPDATE here recovers it for every tag.
                for tag in post.tags {
                    try db.execute(sql: "INSERT OR IGNORE INTO tags (tag, display, created_at) VALUES (?, ?, ?)",
                                   arguments: [tag, tag, ms])
                }

                try Self.writePost(db, post, authorityURL: authorityURL, now: ms)

                if mode == .trending {
                    try db.execute(sql: """
                        INSERT INTO server_trends (source_url, merge_key, rank, first_seen_at, last_seen_at, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (source_url, merge_key) DO UPDATE SET
                            rank = excluded.rank, last_seen_at = excluded.last_seen_at,
                            updated_at = CASE WHEN rank = excluded.rank THEN updated_at ELSE excluded.created_at END
                        """, arguments: [post.sourceURL, post.mergeKey, index, ms, ms, ms])
                }
            }

            try Self.rewriteTagBuckets(db, hours: Set(posts.map { Self.hourBucket(Self.milliseconds($0.createdAt)) }), now: ms)
        }
    }

    /// The remote says the post is gone. Marked once; a second report changes nothing.
    public func markDeleted(mergeKey: String, now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        try await write { db in
            try db.execute(sql: "UPDATE posts SET deleted_at = ? WHERE merge_key = ? AND deleted_at IS NULL",
                           arguments: [ms, mergeKey])
        }
    }

    /// The one DELETE the store performs: marked rows older than `olderThan` go, and
    /// `post_tags` / `server_trends` / `posts_fts` go with them. `tag_buckets` keeps its count.
    @discardableResult
    public func purgeDeleted(olderThan: Date) async throws -> Int {
        let ms = Self.milliseconds(olderThan)
        return try await write { db in
            try db.execute(sql: "DELETE FROM posts WHERE deleted_at IS NOT NULL AND deleted_at < ?", arguments: [ms])
            return db.changesCount
        }
    }

    // MARK: Reading

    /// The timeline: what is stored, newest first, `merge_key` breaking ties so a page lands in
    /// the same place on every refresh.
    public func timeline(limit: Int = 200) async throws -> [Post] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                WHERE p.deleted_at IS NULL
                ORDER BY p.posted_at DESC, p.merge_key
                LIMIT ?
                """, arguments: [limit])
            return try Self.posts(from: rows, db)
        }
    }

    /// What the servers said was trending, as of their last sighting on or after `since`.
    /// A post several servers list once, at its best rank; ties break the way
    /// `TimelineLoader` breaks them, so a refresh lands in the same order the store showed.
    public func trending(since: Date, limit: Int = 100) async throws -> [Post] {
        let ms = Self.milliseconds(since)
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                JOIN server_trends t ON t.merge_key = p.merge_key
                WHERE t.last_seen_at >= ? AND p.deleted_at IS NULL
                GROUP BY p.merge_key
                ORDER BY min(t.rank), p.posted_at DESC, p.merge_key
                LIMIT ?
                """, arguments: [ms, limit])
            return try Self.posts(from: rows, db)
        }
    }

    // MARK: - Rows

    private static let postSelect = """
        SELECT p.*, a.handle, a.display_name, a.avatar_url, b.display_name AS booster_name
        FROM posts p
        JOIN accounts a ON a.author_id = p.author_id
        LEFT JOIN accounts b ON b.author_id = p.boosted_by
        """

    private static func posts(from rows: [Row], _ db: Database) throws -> [Post] {
        guard !rows.isEmpty else { return [] }
        let keys = rows.map { $0["merge_key"] as String }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        var tags: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT merge_key, tag FROM post_tags WHERE merge_key IN (\(placeholders)) ORDER BY rowid",
                                    arguments: StatementArguments(keys)) {
            tags[row["merge_key"], default: []].append(row["tag"])
        }
        return rows.map { post(from: $0, tags: tags[$0["merge_key"]] ?? []) }
    }

    private static func post(from row: Row, tags: [String]) -> Post {
        let mediaJSON: String? = row["media_urls"]
        let media = mediaJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let sourceURL: String = row["source_url"]
        return Post(
            uri: row["uri"],
            originURI: row["origin_uri"],
            socialProtocol: SocialProtocol(storeProto: row["proto"]),
            sourceURL: sourceURL,
            createdAt: date(row["posted_at"]),
            authorId: row["author_id"],
            authorName: row["display_name"] ?? "",
            authorHandle: row["handle"] ?? "",
            authorAvatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:)),
            text: row["text"],
            mediaURLs: media.compactMap(URL.init(string:)),
            webURL: (row["web_url"] as String?).flatMap(URL.init(string:)),
            inReplyToURI: row["in_reply_to_uri"],
            tags: tags,
            boostedBy: row["booster_name"],
            boostedById: row["boosted_by"],
            sources: [URL(string: sourceURL)?.host ?? sourceURL]
        )
    }

    // MARK: - Writes

    private static func upsertServer(_ db: Database, url: String, proto: String, title: String?, now: Int64) throws {
        let host = URL(string: url)?.host ?? url
        // A title fills in once known and is never blanked; selected_at and position are local
        // and never touched here.
        try db.execute(sql: """
            INSERT INTO servers (url, host, proto, title, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (url) DO UPDATE SET
                title      = coalesce(excluded.title, title),
                updated_at = CASE WHEN coalesce(excluded.title, title) IS title THEN updated_at ELSE excluded.created_at END
            """, arguments: [url, host, proto, title, now])
    }

    private static func upsertAccount(_ db: Database, id: String, proto: String, serverURL: String?,
                                      handle: String?, displayName: String?, avatarURL: String?, now: Int64) throws {
        // A NULL never erases what a fuller sighting wrote (a booster arrives with a name only);
        // updated_at moves only when something actually changed.
        try db.execute(sql: """
            INSERT INTO accounts (author_id, proto, server_url, handle, display_name, avatar_url, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (author_id) DO UPDATE SET
                handle       = coalesce(excluded.handle, handle),
                display_name = coalesce(excluded.display_name, display_name),
                avatar_url   = coalesce(excluded.avatar_url, avatar_url),
                updated_at   = CASE WHEN coalesce(excluded.handle, handle) IS handle
                                     AND coalesce(excluded.display_name, display_name) IS display_name
                                     AND coalesce(excluded.avatar_url, avatar_url) IS avatar_url
                                    THEN updated_at ELSE excluded.created_at END
            """, arguments: [id, proto, serverURL, handle, displayName, avatarURL, now])
    }

    private static func writePost(_ db: Database, _ post: Post, authorityURL: String?, now: Int64) throws {
        let key = post.mergeKey
        let media = post.mediaURLs.map(\.absoluteString)
        let mediaJSON = String(decoding: try JSONEncoder().encode(media), as: UTF8.self)
        let webURL = post.webURL?.absoluteString

        guard let existing = try Row.fetchOne(db, sql: "SELECT text, media_urls, web_url, authority_url FROM posts WHERE merge_key = ?",
                                              arguments: [key]) else {
            try db.execute(sql: """
                INSERT INTO posts (merge_key, proto, origin_uri, uri, authority_url, source_url, posted_at, author_id,
                                   text, media_urls, web_url, in_reply_to_uri, boosted_by, extras, deleted_at,
                                   last_seen_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, NULL)
                """, arguments: [key, post.socialProtocol.storeProto, post.originURI, post.uri, authorityURL,
                                 post.sourceURL, milliseconds(post.createdAt), post.authorId,
                                 post.text, mediaJSON, webURL, post.inReplyToURI, post.boostedById, now, now])
            try insertTags(db, post.tags, for: key, now: now)
            return
        }

        try db.execute(sql: "UPDATE posts SET last_seen_at = ? WHERE merge_key = ?", arguments: [now, key])

        guard (existing["authority_url"] as String?) == post.sourceURL else { return }

        let contentChanged = (existing["text"] as String) != post.text
            || (existing["media_urls"] as String?) != mediaJSON
            || (existing["web_url"] as String?) != webURL
        let storedTags = try String.fetchAll(db, sql: "SELECT tag FROM post_tags WHERE merge_key = ? ORDER BY rowid", arguments: [key])
        let tagsChanged = storedTags != post.tags
        guard contentChanged || tagsChanged else { return }

        try db.execute(sql: "UPDATE posts SET updated_at = ? WHERE merge_key = ?", arguments: [now, key])
        if contentChanged {
            try db.execute(sql: "UPDATE posts SET text = ?, media_urls = ?, web_url = ? WHERE merge_key = ?",
                           arguments: [post.text, mediaJSON, webURL, key])
        }
        if tagsChanged {
            try db.execute(sql: "DELETE FROM post_tags WHERE merge_key = ?", arguments: [key])
            try insertTags(db, post.tags, for: key, now: now)
        }
    }

    private static func insertTags(_ db: Database, _ tags: [String], for key: String, now: Int64) throws {
        for tag in tags {
            try db.execute(sql: "INSERT OR IGNORE INTO post_tags (merge_key, tag, created_at) VALUES (?, ?, ?)",
                           arguments: [key, tag, now])
        }
    }

    private static let hour: Int64 = 3_600_000

    static func hourBucket(_ ms: Int64) -> Int64 { ms - ms % hour }

    /// Every hour a post of this save was posted in, recounted from what is here now. A count
    /// only ever goes up: a purge, or a post arriving late, cannot unsay what was counted.
    private static func rewriteTagBuckets(_ db: Database, hours: Set<Int64>, now: Int64) throws {
        for bucket in hours.sorted() {
            try db.execute(sql: """
                INSERT INTO tag_buckets (bucket_at, tag, posts, authors, created_at)
                SELECT ?, tag, count(*), count(DISTINCT author_id), ?
                FROM post_tags JOIN posts USING (merge_key)
                WHERE posted_at >= ? AND posted_at < ? AND deleted_at IS NULL
                GROUP BY tag
                ON CONFLICT (bucket_at, tag) DO UPDATE SET
                    posts      = max(posts, excluded.posts),
                    authors    = max(authors, excluded.authors),
                    updated_at = CASE WHEN posts >= excluded.posts AND authors >= excluded.authors
                                      THEN updated_at ELSE excluded.created_at END
                """, arguments: [bucket, now, bucket, bucket + hour])
        }
    }

    // MARK: - Derivations

    /// Who the post's truth rests on: the origin in the URI for Mastodon, nothing otherwise.
    private static func authorityURL(of post: Post) -> String? {
        guard post.socialProtocol == .mastodon || post.socialProtocol == .activityPub else { return nil }
        return post.originURI.flatMap(endpoint(ofHost:))
    }

    /// `https://<host>` of an https URL, or nothing when it is not one.
    private static func endpoint(ofHost uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "https", let host = url.host else { return nil }
        return "https://\(host)"
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

extension SocialProtocol {
    /// The `protocols.proto` row. `protocols` has one row for Mastodon and plain ActivityPub,
    /// so `.activityPub` is stored as `'mastodon'` and a reader gets `.mastodon` back.
    var storeProto: String {
        switch self {
        case .mastodon, .activityPub: "mastodon"
        case .atProto: "atproto"
        case .nostr: "nostr"
        }
    }

    init(storeProto: String) {
        switch storeProto {
        case "atproto": self = .atProto
        case "nostr": self = .nostr
        default: self = .mastodon
        }
    }
}
