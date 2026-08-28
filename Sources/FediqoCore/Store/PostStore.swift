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
    ///
    /// `feed` is what this server was asked for and `reader` is who it was asked as, and the
    /// pair is written beside each post rather than into it: a post is one row whichever base
    /// sources carried it, and arriving again through another one adds an origin instead of
    /// replacing anything. `reader` is kept only where the source has an owner — a public
    /// timeline belongs to nobody, and neither does a trending list.
    public func save(_ posts: [Post], from server: Server, into feed: BaseSource = .public,
                     as reader: String? = nil, now: Date = Date()) async throws {
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

            // Whose home this was, or nobody's. Decided once here rather than at each call
            // site, so the schema's rule — an account only where the source has one — cannot
            // be broken by a caller passing the reader along with the wrong feed.
            let account = feed.needsAccount ? reader : nil
            var hours: Set<Int64> = []
            for post in posts {
                let postedAt = try Self.writePost(db, post, authorityURL: Self.authorityURL(of: post), now: ms)
                try Self.recordOrigin(db, post.mergeKey, from: post.sourceURL,
                                      into: feed, as: account, now: ms)
                hours.insert(Self.hourBucket(postedAt))
            }
            try Self.rewriteTagBuckets(db, hours: hours, now: ms)
        }
    }

    /// The server's ranking of posts already saved: a post's rank is its place in the list the
    /// server handed over. Seen again at the same rank, the row is touched, not updated. A post
    /// back on the list after falling off it rises again — the mark is lifted, not a second row.
    ///
    /// The list is also evidence about the posts that are *not* on it, and that is the whole of
    /// why `removed_at` exists. Staleness cannot stand in for it: `ServerBackoff` is built to
    /// stop asking a server that is not answering, so "not seen for a day" covers a post that
    /// fell off the list and a server nobody has asked, which are not the same fact. What is
    /// written is the narrower true thing, the way 003 taught `deleted_at` to say one: **the
    /// list this server hands over no longer contains this post** — not that it has stopped
    /// rising, which a list with a length cannot tell anybody.
    ///
    /// An empty list decides nothing, and marks nothing. A server that has turned trending off,
    /// or has nothing to say this hour, is not a server telling us a hundred posts retired at
    /// the same instant; that reading belongs to the 24-hour window a screen already applies.
    public func recordTrending(_ posts: [Post], from server: Server, now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        let arrived = posts.map(\.mergeKey)
        let sourceURL = server.endpoint
        try await write { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO server_trends (source_url, merge_key, rank, first_seen_at, last_seen_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (source_url, merge_key) DO UPDATE SET
                    rank = excluded.rank, last_seen_at = excluded.last_seen_at, removed_at = NULL,
                    \(Self.touchClause(unchanged: "rank = excluded.rank AND removed_at IS NULL"))
                """)
            for (index, post) in posts.enumerated() {
                try insert.execute(arguments: [post.sourceURL, post.mergeKey, index, ms, ms, ms])
            }
            guard !arrived.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: arrived.count).joined(separator: ", ")
            try db.execute(sql: """
                UPDATE server_trends SET removed_at = ?, updated_at = ?
                WHERE source_url = ? AND removed_at IS NULL AND merge_key NOT IN (\(placeholders))
                """, arguments: StatementArguments([ms, ms, sourceURL] as [any DatabaseValueConvertible])
                    + StatementArguments(arrived))
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
    /// The two columns run opposite ways, so the cut cannot be the one row-value comparison
    /// `(a, b) < (?, ?)` — that wants both going the same way. SQLite makes what it can of the
    /// OR instead: it seeks on `posted_at` alone and re-checks the whole condition per row, so
    /// the only rows read and dropped are those sharing the cursor's own millisecond. Measured
    /// on 2026-08-25: `SEARCH p USING INDEX posts_by_time (posted_at<?)`, no temp b-tree, and a
    /// page two hundred thousand rows down costs what the first page costs. Worth knowing: this
    /// plan holds because nothing here runs ANALYZE, so if `PRAGMA optimize` is ever added,
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

    /// One timeline's page: the posts its base source carried, with its rules applied, in the
    /// order its base source puts them in.
    ///
    /// The rules are the same rules `TimelineFilter.admits` is, spelled for SQLite to run.
    /// Two spellings of one thing is exactly the drift this codebase writes tests against, so
    /// `TimelineFilterTests` runs a corpus through both and holds them to the same answer.
    ///
    /// **A ranked source takes no cursor.** `before` is a place on a thread of time, and a
    /// trending list is not one: it is a snapshot somebody curated, and there is nothing
    /// behind it a reader was reading towards (see `SourceClient.trending`). So a ranked
    /// source answers its whole list, cut to `limit`, and a cursor handed in is ignored
    /// rather than quietly turned into a page boundary that means nothing.
    public func timeline(matching query: TimelineQuery, limit: Int = 200,
                         before: Post? = nil, now: Date = Date()) async throws -> [Post] {
        let (rules, ruleArguments) = Self.conditions(of: query)
        let ms = Self.milliseconds(now.addingTimeInterval(-Self.trendingWindow))

        if query.source.ranked {
            let arguments = StatementArguments(([ms] + ruleArguments + [limit]).map(\.databaseValue))
            return try await read { db in
                let rows = try Row.fetchAll(db, sql: """
                    \(Self.postSelect)
                    JOIN server_trends t ON t.merge_key = p.merge_key
                    WHERE t.last_seen_at >= ? AND t.removed_at IS NULL AND p.deleted_at IS NULL
                    \(rules)
                    GROUP BY p.merge_key
                    ORDER BY min(t.rank), p.posted_at DESC, p.merge_key
                    LIMIT ?
                    """, arguments: arguments)
                return try Self.posts(from: rows, db)
            }
        }

        let cursor = before.map { (postedAt: Self.milliseconds($0.createdAt), key: $0.mergeKey) }
        let keyset = cursor == nil ? "" : "AND (p.posted_at < ? OR (p.posted_at = ? AND p.merge_key > ?))"
        // Which base source carried it, and — where the timeline names one — whose reading it
        // was in. A `home` timeline with no account named is every home this device reads.
        var origin = "AND EXISTS (SELECT 1 FROM post_origins o WHERE o.merge_key = p.merge_key AND o.feed = ?"
        var originArguments: [any DatabaseValueConvertible] = [query.source.rawValue]
        if let account = query.account {
            origin += " AND o.author_id = ?"
            originArguments.append(account)
        }
        origin += ")"
        let originClause = origin

        var values: [any DatabaseValueConvertible] = originArguments + ruleArguments
        if let cursor { values += [cursor.postedAt, cursor.postedAt, cursor.key] }
        values.append(limit)
        let arguments = StatementArguments(values.map(\.databaseValue))

        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                WHERE p.deleted_at IS NULL
                \(originClause)
                \(rules)
                \(keyset)
                ORDER BY p.posted_at DESC, p.merge_key
                LIMIT ?
                """, arguments: arguments)
            return try Self.posts(from: rows, db)
        }
    }

    /// How far back a trending list is believed. A snapshot nobody has refreshed for a day is
    /// not evidence about what is rising now, and a server inside a long wait is exactly how
    /// one gets that old.
    static let trendingWindow: TimeInterval = 24 * 60 * 60

    /// The rules as SQL: one `AND` per rule, and its arguments in the same order.
    ///
    /// Every fragment is written so that negating it is `NOT (…)` and nothing else — no
    /// second spelling per rule, and no rule whose negation quietly means something narrower
    /// than "everything this one did not keep".
    private static func conditions(of query: TimelineQuery)
        -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var sql: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        for filter in query.filters {
            let fragment: String
            switch filter.kind {
            case .tag:
                fragment = "EXISTS (SELECT 1 FROM post_tags pt WHERE pt.merge_key = p.merge_key AND pt.tag = ?)"
                arguments.append(filter.value)
            case .author:
                fragment = "(p.author_id = ? OR a.handle = ?)"
                arguments += [filter.value, filter.value]
            case .mention:
                fragment = """
                    EXISTS (SELECT 1 FROM post_mentions pm WHERE pm.merge_key = p.merge_key
                            AND (pm.mention_uri = ? OR pm.handle = ?))
                    """
                arguments += [filter.value, filter.value]
            case .server:
                fragment = "(p.source_url = ? OR p.source_url = 'https://' || ?)"
                arguments += [filter.value, filter.value]
            case .media:
                fragment = "(p.media_urls IS NOT NULL AND json_array_length(p.media_urls) > 0)"
            }
            sql.append("AND \(filter.negate ? "NOT (\(fragment))" : fragment)")
        }
        return (sql.joined(separator: "\n"), arguments)
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

    /// What this server first handed over inside `postedIn`, named and no more than named —
    /// the rows a page from that server covering that stretch should have contained, so that
    /// whatever the page left out can be *asked* about.
    ///
    /// Keys rather than whole posts, because of what the caller does with them. Every timeline
    /// page runs this, a refresh's as much as a reach-down's, and on a healthy page the page
    /// contained every one of them and the whole answer is discarded. Building a `Post` per
    /// row to find that out is the accounts join and a second query for the tags, once per
    /// page, to answer a question the merge key alone answers. `posts(named:)` builds the ones
    /// that survive the diff — with the authority for each, off the same row — which on a
    /// healthy page is none of them.
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
    ///
    /// In no order, because the answer is a set the page is diffed against and never a list
    /// anybody reads. What order the survivors reach the queue in is `posts(named:)`'s to say.
    ///
    /// A fourth thing is left out, and it is `feed`'s doing: a page is only evidence about the
    /// source it came through. A post the store holds because this server's public timeline
    /// carried it is not something that server's *home* page for somebody was ever going to
    /// contain, and diffing the two would suspect half the store every time a home page
    /// arrived. `as` narrows it once more where the source has an owner — one reader's home is
    /// not evidence about another's.
    public func postKeys(from sourceURL: String, through feed: BaseSource, as reader: String? = nil,
                         postedIn range: ClosedRange<Date>) async throws -> [String] {
        let (from, to) = (Self.milliseconds(range.lowerBound), Self.milliseconds(range.upperBound))
        let owner = reader == nil ? "" : "AND o.author_id = ?"
        var values: [any DatabaseValueConvertible] = [sourceURL, from, to, sourceURL, feed.rawValue]
        if let reader { values.append(reader) }
        let arguments = StatementArguments(values.map(\.databaseValue))
        return try await read { db in
            try String.fetchAll(db, sql: """
                SELECT p.merge_key FROM posts p
                WHERE p.source_url = ? AND p.posted_at >= ? AND p.posted_at <= ?
                  AND p.deleted_at IS NULL AND p.authority_url IS NOT NULL
                  AND EXISTS (SELECT 1 FROM post_origins o
                              WHERE o.merge_key = p.merge_key AND o.source_url = ? AND o.feed = ? \(owner))
                """, arguments: arguments)
        }
    }

    /// The whole of each of `keys`, with the server whose word on it is final — the rows
    /// `postKeys(from:postedIn:)` named, built once the diff has cut them down to the handful
    /// that are actually going to be asked about.
    ///
    /// The same two rows are left out here as there, and for the same reasons: one already
    /// marked is past being suspected, and one with no `authority_url` has nobody who could be
    /// asked. So a key the answer does not carry back is a key there is nothing to ask about —
    /// including one marked between the two reads, which is a post already gone.
    public func posts(named keys: [String]) async throws -> [PostAuthority] {
        guard !keys.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                \(Self.postSelect)
                WHERE p.merge_key IN (\(placeholders))
                  AND p.deleted_at IS NULL AND p.authority_url IS NOT NULL
                ORDER BY p.posted_at DESC, p.merge_key
                """, arguments: StatementArguments(keys))
            // `posts(from:_:)` maps the rows in order, so the two line up pair for pair.
            return zip(try Self.posts(from: rows, db), rows).map {
                PostAuthority(post: $0, authorityURL: $1["authority_url"])
            }
        }
    }

    // MARK: - Rows

    /// The one shape a post is read back in. Shared with `ThreadStore`, which reads the same
    /// rows by a different question — a conversation rather than a page.
    static let postSelect = """
        SELECT p.*, a.handle, a.display_name, a.avatar_url, b.display_name AS booster_name
        FROM posts p
        JOIN accounts a ON a.author_id = p.author_id
        LEFT JOIN accounts b ON b.author_id = p.boosted_by
        """

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func posts(from rows: [Row], _ db: Database) throws -> [Post] {
        guard !rows.isEmpty else { return [] }
        let keys = rows.map { $0["merge_key"] as String }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        var tags: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT merge_key, tag FROM post_tags WHERE merge_key IN (\(placeholders)) ORDER BY rowid",
                                    arguments: StatementArguments(keys)) {
            tags[row["merge_key"], default: []].append(row["tag"])
        }
        // What came attached, in the order the source gave it. A post stored before migration
        // 005 has no rows here at all; `post(from:…)` falls back to the one column 001 kept.
        var media: [String: [Attachment]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT merge_key, kind, url, preview_url, alt FROM post_media
            WHERE merge_key IN (\(placeholders)) ORDER BY merge_key, position
            """, arguments: StatementArguments(keys)) {
            media[row["merge_key"], default: []].append(Attachment(
                kind: Attachment.Kind(rawValue: row["kind"]) ?? .unknown,
                url: (row["url"] as String?).flatMap(URL.init(string:)),
                previewURL: (row["preview_url"] as String?).flatMap(URL.init(string:)),
                alt: row["alt"]))
        }
        var mentions: [String: [Mention]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT merge_key, mention_uri, handle FROM post_mentions
            WHERE merge_key IN (\(placeholders)) ORDER BY rowid
            """, arguments: StatementArguments(keys)) {
            mentions[row["merge_key"], default: []].append(Mention(uri: row["mention_uri"], handle: row["handle"]))
        }
        var emojis: [String: [CustomEmoji]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT merge_key, shortcode, url, static_url FROM post_emojis
            WHERE merge_key IN (\(placeholders)) ORDER BY rowid
            """, arguments: StatementArguments(keys)) {
            guard let address = URL(string: row["url"]) else { continue }
            emojis[row["merge_key"], default: []].append(CustomEmoji(
                shortcode: row["shortcode"], url: address,
                staticURL: (row["static_url"] as String?).flatMap(URL.init(string:))))
        }
        return rows.map { post(from: $0, tags: tags[$0["merge_key"]] ?? [],
                               mentions: mentions[$0["merge_key"]] ?? [],
                               emojis: emojis[$0["merge_key"]] ?? [],
                               media: media[$0["merge_key"]]) }
    }

    private static func post(from row: Row, tags: [String], mentions: [Mention],
                             emojis: [CustomEmoji], media: [Attachment]?) -> Post {
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
            attachments: media ?? legacyAttachments(in: row),
            sensitive: (row["sensitive"] as Int?).map { $0 == 1 },
            spoiler: row["spoiler_text"],
            counts: Counts(replies: row["replies_count"], reblogs: row["reblogs_count"],
                           favourites: row["favourites_count"]),
            application: (row["application"] as String?).map {
                Application(name: $0, website: (row["application_url"] as String?).flatMap(URL.init(string:)))
            },
            webURL: (row["web_url"] as String?).flatMap(URL.init(string:)),
            inReplyToURI: row["in_reply_to_uri"],
            tags: tags,
            mentions: mentions,
            emojis: emojis,
            boostedBy: row["booster_name"],
            boostedById: row["boosted_by"],
            sources: [host(of: sourceURL)]
        )
    }

    /// What 001 kept of a post's attachments: one address each, whichever of the file and its
    /// still the server offered first, and no word about which it was. They come back as
    /// `unknown` — an address that can be drawn, and nothing claimed beyond that.
    private static func legacyAttachments(in row: Row) -> [Attachment] {
        let json: String? = row["media_urls"]
        let urls = json.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
        return urls.compactMap(URL.init(string:)).map(Attachment.unknown(displaying:))
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

        let find = try db.cachedStatement(sql: """
            SELECT text, media_urls, web_url, authority_url, sensitive, spoiler_text
            FROM posts WHERE merge_key = ?
            """)
        guard let existing = try Row.fetchOne(find, arguments: [key]) else {
            // `media_urls` is written as well as `post_media`, and not instead of it. 001's
            // column is what an older build reads, and the rule that a stored field is never
            // rewritten cuts both ways: the column stays true rather than being abandoned.
            try db.cachedStatement(sql: """
                INSERT INTO posts (merge_key, proto, origin_uri, uri, authority_url, source_url, posted_at, author_id,
                                   text, media_urls, web_url, in_reply_to_uri, boosted_by, extras, deleted_at,
                                   sensitive, spoiler_text, replies_count, reblogs_count, favourites_count,
                                   application, application_url, last_seen_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """).execute(arguments: [key, post.socialProtocol.storeProto, post.originURI, post.uri, authorityURL,
                                         post.sourceURL, postedAt, post.authorId,
                                         post.text, mediaJSON, webURL, post.inReplyToURI, post.boostedById,
                                         post.sensitive.map { $0 ? 1 : 0 }, post.spoiler,
                                         post.counts.replies, post.counts.reblogs, post.counts.favourites,
                                         post.application?.name, post.application?.website?.absoluteString,
                                         now, now])
            try insertTags(db, post.tags, for: key, now: now)
            try insertMentions(db, post.mentions, for: key, now: now)
            try insertEmojis(db, post.emojis, for: key, now: now)
            try insertMedia(db, post.attachments, for: key, now: now)
            return postedAt
        }

        try db.cachedStatement(sql: "UPDATE posts SET last_seen_at = ? WHERE merge_key = ?").execute(arguments: [now, key])

        guard (existing["authority_url"] as String?) == post.sourceURL else { return postedAt }

        // The counts move on their own and are not an edit: somebody favouriting a post is not
        // its author changing it. So they are written on every sighting from the authority and
        // never touch `updated_at`, which means what it has always meant — an authority edited
        // this. Only what the authority actually said is written: a server that sends no counts
        // has told us nothing, and nothing must not overwrite something.
        try updateCounts(db, post.counts, for: key)

        let contentChanged = (existing["text"] as String) != post.text
            || (existing["media_urls"] as String?) != mediaJSON
            || (existing["web_url"] as String?) != webURL
            || (existing["sensitive"] as Int?).map({ $0 == 1 }) != post.sensitive
            || (existing["spoiler_text"] as String?) != post.spoiler
        let storedTags = try String.fetchAll(db.cachedStatement(sql: "SELECT tag FROM post_tags WHERE merge_key = ? ORDER BY rowid"),
                                             arguments: [key])
        let tagsChanged = storedTags != post.tags
        let storedMentions = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT mention_uri, handle FROM post_mentions WHERE merge_key = ? ORDER BY rowid
            """), arguments: [key]).map { Mention(uri: $0["mention_uri"], handle: $0["handle"]) }
        let mentionsChanged = storedMentions != post.mentions
        let storedEmojis = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT shortcode, url, static_url FROM post_emojis WHERE merge_key = ? ORDER BY rowid
            """), arguments: [key]).compactMap { row -> CustomEmoji? in
            guard let address = URL(string: row["url"]) else { return nil }
            return CustomEmoji(shortcode: row["shortcode"], url: address,
                               staticURL: (row["static_url"] as String?).flatMap(URL.init(string:)))
        }
        let emojisChanged = storedEmojis != post.emojis
        guard contentChanged || tagsChanged || mentionsChanged || emojisChanged else { return postedAt }

        try db.cachedStatement(sql: "UPDATE posts SET updated_at = ? WHERE merge_key = ?").execute(arguments: [now, key])
        if contentChanged {
            try db.cachedStatement(sql: """
                UPDATE posts SET text = ?, media_urls = ?, web_url = ?, sensitive = ?, spoiler_text = ?
                WHERE merge_key = ?
                """).execute(arguments: [post.text, mediaJSON, webURL,
                                         post.sensitive.map { $0 ? 1 : 0 }, post.spoiler, key])
            // The attachments go with the words: an edit that swapped a picture is the same
            // edit, and the rows are rewritten whole rather than merged, for the reason the
            // tags are — half an old set and half a new one is not a state anything produced.
            try db.cachedStatement(sql: "DELETE FROM post_media WHERE merge_key = ?").execute(arguments: [key])
            try insertMedia(db, post.attachments, for: key, now: now)
        }
        if tagsChanged {
            try db.cachedStatement(sql: "DELETE FROM post_tags WHERE merge_key = ?").execute(arguments: [key])
            try insertTags(db, post.tags, for: key, now: now)
        }
        if mentionsChanged {
            try db.cachedStatement(sql: "DELETE FROM post_mentions WHERE merge_key = ?").execute(arguments: [key])
            try insertMentions(db, post.mentions, for: key, now: now)
        }
        // An author who changed their emoji, or a server that started sending them: the set is
        // rewritten whole for the reason the tags are — half an old set and half a new one is
        // not a state anything produced.
        if emojisChanged {
            try db.cachedStatement(sql: "DELETE FROM post_emojis WHERE merge_key = ?").execute(arguments: [key])
            try insertEmojis(db, post.emojis, for: key, now: now)
        }
        return postedAt
    }

    /// The pictures the post is partly written in. `OR IGNORE` and not a merge: the primary
    /// key is (post, shortcode), so a server that named one shortcode twice has named it once.
    private static func insertEmojis(_ db: Database, _ emojis: [CustomEmoji], for key: String, now: Int64) throws {
        guard !emojis.isEmpty else { return }
        let insert = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO post_emojis (merge_key, shortcode, url, static_url, created_at)
            VALUES (?, ?, ?, ?, ?)
            """)
        for emoji in emojis {
            try insert.execute(arguments: [key, emoji.shortcode, emoji.url.absoluteString,
                                           emoji.staticURL?.absoluteString, now])
        }
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

    /// Who the post names. No `accounts` row is written for them: a mention is a name in a
    /// post, and writing a half-empty account row for every stranger a post greets would fill
    /// the table this device keys identity on with people it has never been handed.
    private static func insertMentions(_ db: Database, _ mentions: [Mention], for key: String, now: Int64) throws {
        let insert = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO post_mentions (merge_key, mention_uri, handle, created_at) VALUES (?, ?, ?, ?)
            """)
        for mention in mentions {
            try insert.execute(arguments: [key, mention.uri, mention.handle, now])
        }
    }

    /// One sighting of one post through one base source, written beside the post and never
    /// into it. Being told again moves `last_seen_at` and nothing else; being told by somebody
    /// else, or through another source, is another row.
    ///
    /// Two statements because uniqueness is two partial indexes, and a conflict target has to
    /// name the one it means. `author_id` is NULL for a source nobody owns, and NULLs are
    /// distinct to a unique index — which is exactly why the anonymous rows are kept unique by
    /// an index that leaves the column out.
    private static func recordOrigin(_ db: Database, _ key: String, from sourceURL: String,
                                     into feed: BaseSource, as account: String?, now: Int64) throws {
        let statement = if account == nil {
            try db.cachedStatement(sql: """
                INSERT INTO post_origins (source_url, feed, author_id, merge_key,
                                          first_seen_at, last_seen_at, created_at)
                VALUES (?, ?, NULL, ?, ?, ?, ?)
                ON CONFLICT (source_url, feed, merge_key) WHERE author_id IS NULL DO UPDATE SET
                    last_seen_at = excluded.last_seen_at, updated_at = excluded.created_at
                """)
        } else {
            try db.cachedStatement(sql: """
                INSERT INTO post_origins (source_url, feed, author_id, merge_key,
                                          first_seen_at, last_seen_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (source_url, feed, author_id, merge_key) WHERE author_id IS NOT NULL DO UPDATE SET
                    last_seen_at = excluded.last_seen_at, updated_at = excluded.created_at
                """)
        }
        let arguments: [(any DatabaseValueConvertible)?] = account == nil
            ? [sourceURL, feed.rawValue, key, now, now, now]
            : [sourceURL, feed.rawValue, account, key, now, now, now]
        try statement.execute(arguments: StatementArguments(arguments))
    }

    /// What came attached, in the order it came. `position` is that order, so a post read
    /// again writes the same rows rather than growing new ones.
    private static func insertMedia(_ db: Database, _ attachments: [Attachment],
                                    for key: String, now: Int64) throws {
        let insert = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO post_media (merge_key, position, kind, url, preview_url, alt, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        for (position, attachment) in attachments.enumerated() where !attachment.isEmpty {
            try insert.execute(arguments: [key, position, attachment.kind.rawValue,
                                           attachment.url?.absoluteString,
                                           attachment.previewURL?.absoluteString,
                                           attachment.alt, now])
        }
    }

    /// The three numbers, each written only where the source said one. `coalesce` keeps what is
    /// known rather than letting a server that sends no counts blank the ones another gave.
    private static func updateCounts(_ db: Database, _ counts: Counts, for key: String) throws {
        guard counts.areKnown else { return }
        try db.cachedStatement(sql: """
            UPDATE posts SET replies_count = coalesce(?, replies_count),
                             reblogs_count = coalesce(?, reblogs_count),
                             favourites_count = coalesce(?, favourites_count)
            WHERE merge_key = ?
            """).execute(arguments: [counts.replies, counts.reblogs, counts.favourites, key])
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
