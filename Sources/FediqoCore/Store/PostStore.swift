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

/// A post the store holds, and the server whose word on it is final — `posts.authority_url`,
/// derived once from the post's own canonical address and written when the row was.
///
/// The pair travels together because neither is any use alone for the one job it exists for:
/// asking whether a post is still there. The post says what to ask about, and the authority
/// says who to ask — never whoever handed it over, because a server that has stopped
/// carrying somebody else's post has said nothing about whether that post is still there.
public struct PostAuthority: Sendable, Equatable {
    public let post: Post
    /// `posts.authority_url` — a `servers.url` endpoint, `https://<host>` for Mastodon.
    public let authorityURL: String

    public init(post: Post, authorityURL: String) {
        self.post = post
        self.authorityURL = authorityURL
    }
}

/// Posts in and out of the store, as the "Writing" and "Reading" diagrams in
/// `docs/data-store.md` draw them. Raw SQL against the schema: the schema is the contract,
/// and there is no second description of it in Swift to drift.
extension LocalStore {
    // MARK: Writing

    /// One refresh, one transaction: servers and accounts first (the foreign keys say so),
    /// each once however many posts name them; then each post — inserted if new, otherwise
    /// touched, and rewritten only when the server it came from is the authority for it.
    /// Every hour these posts were posted in gets its `tag_buckets` recounted last.
    public func save(_ posts: [Post], from server: Server, now: Date = Date()) async throws {
        for post in posts {
            if post.authorId.isEmpty { throw PostStoreError.missingAuthor(uri: post.uri) }
            if post.sourceURL.isEmpty { throw PostStoreError.missingSource(uri: post.uri) }
        }
        // The Mastodon client stamps posts with `https://<host>`, which is `server.endpoint`
        // for it; a client for another protocol has to agree with its own scheme.
        let serverURL = server.endpoint
        let serverTitle = server.title
        let ms = Self.milliseconds(now)

        let (servers, accounts) = Self.references(in: posts, serverURL: serverURL, serverTitle: serverTitle)

        try await write { db in
            for row in servers { try Self.upsertServer(db, row, now: ms) }
            for row in accounts { try Self.upsertAccount(db, row, now: ms) }

            var hours: Set<Int64> = []
            for post in posts {
                let postedAt = try Self.writePost(db, post, authorityURL: Self.authorityURL(of: post), now: ms)
                hours.insert(Self.hourBucket(postedAt))
            }
            try Self.rewriteTagBuckets(db, hours: hours, now: ms)
        }
    }

    /// The server's ranking of posts already saved: a post's rank is its place in the list the
    /// server handed over. Seen again at the same rank, the row is touched, not updated.
    public func recordTrending(_ posts: [Post], from server: Server, now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        try await write { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO server_trends (source_url, merge_key, rank, first_seen_at, last_seen_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (source_url, merge_key) DO UPDATE SET
                    rank = excluded.rank, last_seen_at = excluded.last_seen_at,
                    \(Self.touchClause(unchanged: "rank = excluded.rank"))
                """)
            for (index, post) in posts.enumerated() {
                try insert.execute(arguments: [post.sourceURL, post.mergeKey, index, ms, ms, ms])
            }
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
    ///
    /// `before` is a post already read, and what comes back is the page that follows it in
    /// that same order. The cursor is the pair the order is made of — `(posted_at, merge_key)`
    /// — and the page is cut with `posted_at < it, or the same instant and a later merge_key`,
    /// which `posts_by_time` answers in its own order. Two posts posted in the same
    /// millisecond are ordinary, so the tiebreak is in the cut and not only in the sort: with
    /// the timestamp alone, a boundary falling between them would either repeat the first or
    /// skip the second. Never OFFSET — a page written in between would shift every count under
    /// it — so nothing is skipped and nothing arrives twice.
    ///
    /// SQLite walks the index down from the newest and drops what is above the cut rather than
    /// seeking to it: a mixed order cannot be asked for as one comparison, since `(a, b) < (?, ?)`
    /// wants both columns going the same way and these do not. It costs a walk over the pages
    /// already read, which is the price of the tiebreak. Worth knowing: this plan holds because
    /// nothing here runs ANALYZE. With statistics gathered, SQLite prefers a multi-index OR and
    /// sorts the result, which throws the LIMIT away — so if `PRAGMA optimize` is ever added,
    /// read this plan again before believing it.
    public func timeline(limit: Int = 200, before: Post? = nil) async throws -> [Post] {
        let cursor = before.map { (postedAt: Self.milliseconds($0.createdAt), key: $0.mergeKey) }
        let keyset = cursor == nil ? "" : "AND (p.posted_at < ? OR (p.posted_at = ? AND p.merge_key > ?))"
        return try await read { db in
            var arguments: [any DatabaseValueConvertible] = []
            if let cursor { arguments += [cursor.postedAt, cursor.postedAt, cursor.key] }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                WHERE p.deleted_at IS NULL
                \(keyset)
                ORDER BY p.posted_at DESC, p.merge_key
                LIMIT ?
                """, arguments: StatementArguments(arguments))
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

    /// What this server first handed over inside `postedIn`, each with the server whose word
    /// on it is final — the rows a page from that server covering that stretch should have
    /// contained, so that whatever the page left out can be *asked* about.
    ///
    /// Nothing here is evidence of anything on its own. A row this hands back and a page did
    /// not contain is a suspect, never a verdict: a server takes blocked accounts and
    /// filtered posts out of a range it has already chosen, so absence is as much a fact
    /// about the reader's settings as about the post. Only an answer from the authority
    /// writes `deleted_at`.
    ///
    /// Three things are left out, and each for its own reason. `source_url` is only the
    /// **first** server to hand a post over, so this is narrower than "every post that server
    /// carries" and deliberately so — a post credited to somebody else is not evidence about
    /// this server's page. Rows already marked are past being suspected. And rows with no
    /// `authority_url` — Nostr's, and anything whose canonical address named no server — have
    /// nobody who could be asked, so suspecting one would only ever hold a place in a queue
    /// that never empties.
    public func posts(from sourceURL: String, postedIn range: ClosedRange<Date>) async throws -> [PostAuthority] {
        let (from, to) = (Self.milliseconds(range.lowerBound), Self.milliseconds(range.upperBound))
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                WHERE p.source_url = ? AND p.posted_at >= ? AND p.posted_at <= ?
                  AND p.deleted_at IS NULL AND p.authority_url IS NOT NULL
                ORDER BY p.posted_at DESC, p.merge_key
                """, arguments: [sourceURL, from, to])
            // `posts(from:_:)` maps the rows in order, so the two line up pair for pair.
            return zip(try Self.posts(from: rows, db), rows).map {
                PostAuthority(post: $0, authorityURL: $1["authority_url"])
            }
        }
    }

    // MARK: - Rows

    private static let postSelect = """
        SELECT p.*, a.handle, a.display_name, a.avatar_url, b.display_name AS booster_name
        FROM posts p
        JOIN accounts a ON a.author_id = p.author_id
        LEFT JOIN accounts b ON b.author_id = p.boosted_by
        """

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

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
        let media = mediaJSON.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
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
            sources: [host(of: sourceURL)]
        )
    }

    // MARK: - Writes

    /// A `servers` row as one refresh sees it. `title` is what it learned, if anything.
    struct ServerRow: Sendable {
        let url: String
        let proto: String
        var title: String?
    }

    /// An `accounts` row as one refresh sees it. A booster arrives with a name only.
    struct AccountRow: Sendable {
        let id: String
        let proto: String
        let serverURL: String?
        var handle: String?
        var displayName: String?
        var avatarURL: String?
    }

    /// Every server and account `posts` name, each once, in first-seen order — so the writes
    /// land the same way on every refresh. A later sighting only fills in what an earlier one
    /// left blank.
    private static func references(in posts: [Post], serverURL: String, serverTitle: String)
        -> (servers: [ServerRow], accounts: [AccountRow]) {
        var servers: [ServerRow] = []
        var accounts: [AccountRow] = []
        for post in posts {
            let proto = post.socialProtocol.storeProto
            let authorServerURL = endpoint(ofHost: post.authorId)
            let boosterServerURL = post.boostedById.flatMap(endpoint(ofHost:))

            servers.note(ServerRow(url: post.sourceURL, proto: proto,
                                   title: post.sourceURL == serverURL ? serverTitle : nil))
            for url in [authorityURL(of: post), authorServerURL, boosterServerURL].compactMap({ $0 }) {
                servers.note(ServerRow(url: url, proto: proto, title: nil))
            }
            accounts.note(AccountRow(id: post.authorId, proto: proto, serverURL: authorServerURL,
                                     handle: post.authorHandle, displayName: post.authorName,
                                     avatarURL: post.authorAvatarURL?.absoluteString))
            if let boostedById = post.boostedById {
                accounts.note(AccountRow(id: boostedById, proto: proto, serverURL: boosterServerURL,
                                         handle: nil, displayName: post.boostedBy, avatarURL: nil))
            }
        }
        return (servers, accounts)
    }

    /// The row a chosen or signed-in server writes. A title that is only the host (what
    /// `Server.init` fills in when none was given) is no title, and must not blank one the
    /// network taught the row.
    static func serverRow(_ server: Server) -> ServerRow {
        ServerRow(url: server.endpoint, proto: server.socialProtocol.storeProto,
                  title: server.title == server.host ? nil : server.title)
    }

    /// `updated_at = CASE …`: it moves only when something actually changed, and `unchanged`
    /// says — in terms of the row and `excluded` — when nothing did.
    private static func touchClause(unchanged: String) -> String {
        "updated_at = CASE WHEN \(unchanged) THEN updated_at ELSE excluded.created_at END"
    }

    static func upsertServer(_ db: Database, _ server: ServerRow, now: Int64) throws {
        // A title fills in once known and is never blanked; selected_at and position are local
        // and never touched here.
        try db.execute(sql: """
            INSERT INTO servers (url, host, proto, title, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (url) DO UPDATE SET
                title = coalesce(excluded.title, title),
                \(touchClause(unchanged: "coalesce(excluded.title, title) IS title"))
            """, arguments: [server.url, host(of: server.url), server.proto, server.title, now])
    }

    static func upsertAccount(_ db: Database, _ account: AccountRow, now: Int64) throws {
        // A NULL never erases what a fuller sighting wrote.
        try db.execute(sql: """
            INSERT INTO accounts (author_id, proto, server_url, handle, display_name, avatar_url, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (author_id) DO UPDATE SET
                handle       = coalesce(excluded.handle, handle),
                display_name = coalesce(excluded.display_name, display_name),
                avatar_url   = coalesce(excluded.avatar_url, avatar_url),
                \(touchClause(unchanged: """
                    coalesce(excluded.handle, handle) IS handle
                    AND coalesce(excluded.display_name, display_name) IS display_name
                    AND coalesce(excluded.avatar_url, avatar_url) IS avatar_url
                    """))
            """, arguments: [account.id, account.proto, account.serverURL, account.handle,
                             account.displayName, account.avatarURL, now])
    }

    /// Writes one post and says when it was posted, so the caller can recount that hour. The
    /// statements are cached on the connection: a refresh prepares each of them once.
    private static func writePost(_ db: Database, _ post: Post, authorityURL: String?, now: Int64) throws -> Int64 {
        let key = post.mergeKey
        let postedAt = milliseconds(post.createdAt)
        let media = post.mediaURLs.map(\.absoluteString)
        let mediaJSON = String(decoding: try encoder.encode(media), as: UTF8.self)
        let webURL = post.webURL?.absoluteString

        let find = try db.cachedStatement(sql: "SELECT text, media_urls, web_url, authority_url FROM posts WHERE merge_key = ?")
        guard let existing = try Row.fetchOne(find, arguments: [key]) else {
            try db.cachedStatement(sql: """
                INSERT INTO posts (merge_key, proto, origin_uri, uri, authority_url, source_url, posted_at, author_id,
                                   text, media_urls, web_url, in_reply_to_uri, boosted_by, extras, deleted_at,
                                   last_seen_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, NULL)
                """).execute(arguments: [key, post.socialProtocol.storeProto, post.originURI, post.uri, authorityURL,
                                         post.sourceURL, postedAt, post.authorId,
                                         post.text, mediaJSON, webURL, post.inReplyToURI, post.boostedById, now, now])
            try insertTags(db, post.tags, for: key, now: now)
            return postedAt
        }

        try db.cachedStatement(sql: "UPDATE posts SET last_seen_at = ? WHERE merge_key = ?").execute(arguments: [now, key])

        guard (existing["authority_url"] as String?) == post.sourceURL else { return postedAt }

        let contentChanged = (existing["text"] as String) != post.text
            || (existing["media_urls"] as String?) != mediaJSON
            || (existing["web_url"] as String?) != webURL
        let storedTags = try String.fetchAll(db.cachedStatement(sql: "SELECT tag FROM post_tags WHERE merge_key = ? ORDER BY rowid"),
                                             arguments: [key])
        let tagsChanged = storedTags != post.tags
        guard contentChanged || tagsChanged else { return postedAt }

        try db.cachedStatement(sql: "UPDATE posts SET updated_at = ? WHERE merge_key = ?").execute(arguments: [now, key])
        if contentChanged {
            try db.cachedStatement(sql: "UPDATE posts SET text = ?, media_urls = ?, web_url = ? WHERE merge_key = ?")
                .execute(arguments: [post.text, mediaJSON, webURL, key])
        }
        if tagsChanged {
            try db.cachedStatement(sql: "DELETE FROM post_tags WHERE merge_key = ?").execute(arguments: [key])
            try insertTags(db, post.tags, for: key, now: now)
        }
        return postedAt
    }

    /// The post's tags: into `tags` if not yet known, and into `post_tags` for this post.
    /// display is the lowercased tag today: Post.normalisedTags drops the casing. Once Post
    /// keeps the spelling it saw, a DO UPDATE here recovers it for every tag.
    private static func insertTags(_ db: Database, _ tags: [String], for key: String, now: Int64) throws {
        let tag = try db.cachedStatement(sql: "INSERT OR IGNORE INTO tags (tag, display, created_at) VALUES (?, ?, ?)")
        let postTag = try db.cachedStatement(sql: "INSERT OR IGNORE INTO post_tags (merge_key, tag, created_at) VALUES (?, ?, ?)")
        for name in tags {
            try tag.execute(arguments: [name, name, now])
            try postTag.execute(arguments: [key, name, now])
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
                    \(touchClause(unchanged: "posts >= excluded.posts AND authors >= excluded.authors"))
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

    static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// The host of a URL, or the string itself when it has none.
    static func host(of url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

private extension Array where Element == LocalStore.ServerRow {
    /// Once per url, in first-seen order; a title learned later fills in.
    mutating func note(_ row: Element) {
        if let index = firstIndex(where: { $0.url == row.url }) {
            if self[index].title == nil { self[index].title = row.title }
        } else {
            append(row)
        }
    }
}

private extension Array where Element == LocalStore.AccountRow {
    /// Once per id, in first-seen order; a fuller sighting fills in what a thinner one left.
    mutating func note(_ row: Element) {
        guard let index = firstIndex(where: { $0.id == row.id }) else { return append(row) }
        if self[index].handle == nil { self[index].handle = row.handle }
        if self[index].displayName == nil { self[index].displayName = row.displayName }
        if self[index].avatarURL == nil { self[index].avatarURL = row.avatarURL }
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
