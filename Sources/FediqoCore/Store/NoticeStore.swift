import Foundation
import GRDB

/// Notices in and out of the store, against `notices`, `notice_kinds` and `notice_marks` as
/// migration 012 draws them. Raw SQL against the schema, like every other store here: the
/// schema is the contract, and there is no second description of it in Swift to drift.
extension LocalStore {
    // MARK: Writing

    /// One arrival, kept. Says how many of them this device had not already been told about.
    ///
    /// Two transactions and not one, in this order and for this reason. A mention carries its
    /// status, and a status is a post like any other: it goes through the one path every post
    /// goes through, so it gets its author, its mentions, its emojis and an origin saying it
    /// arrived through `notice`. Only then are the notices written, because `post_key` is a
    /// real foreign key and a row pointing at a post that was never stored is a row SQLite is
    /// right to refuse.
    ///
    /// The actor is upserted here rather than in the post pass: whoever favourited a post is
    /// nobody's author, and `accounts` has to hold them before a notice may name them.
    ///
    /// Already-known events are ignored rather than rewritten. A reconnect asks for everything
    /// after a mark and a live stream carries some of the same events, so overlap is the
    /// normal case, not the exceptional one — and rewriting one would move `arrived_at`, which
    /// is the record of when this device first learned of it and must never be touched twice.
    @discardableResult
    public func save(_ notices: [Notice], from server: Server, as owner: String,
                     now: Date = Date()) async throws -> Int {
        guard !notices.isEmpty else { return 0 }

        let posts = notices.compactMap(\.post)
        if !posts.isEmpty {
            try await save(posts, from: server, into: .notice, as: owner)
        }

        let stamp = Self.milliseconds(now)
        let serverURL = server.endpoint
        let proto = server.socialProtocol.storeProto

        return try await write { db in
            var written = 0
            for notice in notices {
                try Self.upsertAccount(db, AccountRow(
                    id: notice.actorId,
                    proto: proto,
                    serverURL: nil,
                    handle: notice.actorHandle.isEmpty ? nil : notice.actorHandle,
                    displayName: notice.actorName.isEmpty ? nil : notice.actorName,
                    avatarURL: notice.actorAvatarURL?.absoluteString
                ), now: stamp)

                try db.execute(sql: """
                    INSERT INTO notices (server_url, remote_id, kind, owner_id, actor_id, post_key,
                                         noticed_at, arrived_at, seen_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                    ON CONFLICT (server_url, remote_id) DO NOTHING
                    """, arguments: [serverURL, notice.remoteId, notice.kind.rawValue, notice.ownerId,
                                     notice.actorId, notice.post?.mergeKey,
                                     Self.milliseconds(notice.noticedAt),
                                     Self.milliseconds(notice.arrivedAt), stamp])
                written += db.changesCount
            }
            return written
        }
    }

    /// Where a catch-up got to, so the next one asks for what happened after it rather than
    /// for the newest page. `nil` where this inbox has never been read on this device.
    public func noticeMark(from serverURL: String, as owner: String) async throws -> String? {
        try await read { db in
            try String.fetchOne(db, sql: """
                SELECT remote_id FROM notice_marks WHERE server_url = ? AND owner_id = ?
                """, arguments: [serverURL, owner])
        }
    }

    /// Moves the mark forward. Never backwards: a live event arriving while a catch-up is
    /// still walking an older page would otherwise rewind the mark and the next reconnect
    /// would re-read what it had already read. Ids on one server sort as strings the way they
    /// sort as events, which is Mastodon's own promise about them.
    public func setNoticeMark(_ remoteId: String, from serverURL: String, as owner: String,
                              now: Date = Date()) async throws {
        let stamp = Self.milliseconds(now)
        try await write { db in
            try db.execute(sql: """
                INSERT INTO notice_marks (server_url, owner_id, remote_id, read_at, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (server_url, owner_id) DO UPDATE SET
                    remote_id = max(excluded.remote_id, remote_id),
                    read_at   = excluded.read_at,
                    updated_at = excluded.read_at
                """, arguments: [serverURL, owner, remoteId, stamp, stamp])
        }
    }

    /// The reader looked. Marks every notice at or before `upTo` that was not marked already —
    /// "at or before", because what a reader saw is a screenful with a bottom edge, and the
    /// ones that arrived while they were reading it are not among them.
    @discardableResult
    public func markNoticesSeen(upTo: Date, now: Date = Date()) async throws -> Int {
        let stamp = Self.milliseconds(now)
        let edge = Self.milliseconds(upTo)
        return try await write { db in
            try db.execute(sql: """
                UPDATE notices SET seen_at = ? WHERE seen_at IS NULL AND noticed_at <= ?
                """, arguments: [stamp, edge])
            return db.changesCount
        }
    }

    // MARK: Reading

    /// How many are still unread. What a bell shows, and the only question the partial index
    /// on `seen_at IS NULL` was built for.
    public func unseenNoticeCount() async throws -> Int {
        try await read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notices WHERE seen_at IS NULL") ?? 0
        }
    }

    /// The inbox, newest first, with each notice's post attached where it had one.
    ///
    /// One transaction, and the posts read through `PostStore`'s own row reader rather than a
    /// second shape written here: a post drawn in this list and the same post drawn in a
    /// timeline must not be able to come out differently. Two reads would also leave a gap a
    /// rotation could fall into — a mention whose post was purged between them would draw as
    /// a mention of nothing.
    ///
    /// `before` is a notice already shown, and what comes back is what is older than it. The
    /// pair is compared rather than the time alone: several events can share a millisecond,
    /// and paging on time alone would either repeat them or step over them.
    public func notices(limit: Int = 100, before: Notice? = nil) async throws -> [Notice] {
        let edge = before.map { (Self.milliseconds($0.noticedAt), $0.remoteId) }
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.server_url, n.remote_id, n.kind, n.owner_id, n.post_key,
                       n.noticed_at, n.arrived_at, n.seen_at,
                       a.author_id, a.handle, a.display_name, a.avatar_url
                FROM notices n
                JOIN accounts a ON a.author_id = n.actor_id
                \(edge == nil ? "" : "WHERE (n.noticed_at, n.remote_id) < (?, ?)")
                ORDER BY n.noticed_at DESC, n.remote_id DESC
                LIMIT ?
                """, arguments: edge.map { [$0.0, $0.1, limit] } ?? [limit])

            let keys = Array(Set(rows.compactMap { $0["post_key"] as String? }))
            var byKey: [String: Post] = [:]
            if !keys.isEmpty {
                let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
                let postRows = try Row.fetchAll(db, sql: """
                    \(Self.postSelect)
                    WHERE p.merge_key IN (\(placeholders))
                      AND p.deleted_at IS NULL AND p.authority_url IS NOT NULL
                    """, arguments: StatementArguments(keys))
                byKey = Dictionary(try Self.posts(from: postRows, db).map { ($0.mergeKey, $0) },
                                   uniquingKeysWith: { first, _ in first })
            }

            return rows.compactMap { row -> Notice? in
                // A kind the store holds and this build cannot draw is skipped rather than
                // guessed at. It cannot happen while `notice_kinds` and `NoticeKind` agree —
                // a test holds them identical — and this is what happens the day they do not.
                guard let kind = NoticeKind(rawValue: row["kind"]) else { return nil }
                let key = row["post_key"] as String?
                return Notice(
                    remoteId: row["remote_id"],
                    serverURL: row["server_url"],
                    kind: kind,
                    ownerId: row["owner_id"],
                    actorId: row["author_id"],
                    actorName: row["display_name"] ?? "",
                    actorHandle: row["handle"] ?? "",
                    actorAvatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:)),
                    post: key.flatMap { byKey[$0] },
                    // The key the notice's own row carries, kept whether or not the post it
                    // names is still here — which is what lets two events about one post be one
                    // row after the post has rotated away (#124).
                    postKey: key,
                    noticedAt: Self.date(row["noticed_at"]),
                    arrivedAt: Self.date(row["arrived_at"]),
                    seenAt: (row["seen_at"] as Int64?).map(Self.date)
                )
            }
        }
    }
}
