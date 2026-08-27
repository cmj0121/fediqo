import Foundation
import GRDB

/// What one account has done to one post, as far as anybody has told us.
///
/// Every field is optional and `nil` means **never told**, which is not `false`. Most of this
/// app's reading is done as a stranger, and a server answering a stranger says nothing about
/// whether an account of yours favourited the status — so a screen may draw an unfilled star
/// for `nil` and may not call it "not favourited".
public struct PostMarks: Sendable, Hashable {
    public var favourited: Bool?
    public var reblogged: Bool?
    public var bookmarked: Bool?

    public init(favourited: Bool? = nil, reblogged: Bool? = nil, bookmarked: Bool? = nil) {
        self.favourited = favourited
        self.reblogged = reblogged
        self.bookmarked = bookmarked
    }

    public static let unknown = PostMarks()

    public var areKnown: Bool { favourited != nil || reblogged != nil || bookmarked != nil }

    /// The same marks with one of them answered. What an action does to what the screen holds,
    /// worked out here so the row and the store cannot disagree about it.
    public func setting(_ action: PostAction, to done: Bool) -> PostMarks {
        var marks = self
        switch action {
        case .favourite: marks.favourited = done
        case .reblog: marks.reblogged = done
        case .bookmark: marks.bookmarked = done
        }
        return marks
    }

    public func value(of action: PostAction) -> Bool? {
        switch action {
        case .favourite: favourited
        case .reblog: reblogged
        case .bookmark: bookmarked
        }
    }
}

/// The three things an account can do to somebody else's post and undo again.
///
/// Replying is not among them: it makes a new post rather than marking this one, and it goes
/// through the composer. Keeping is not either — that is this device's own answer and no
/// account's, which is why it lives on the post rather than here.
public enum PostAction: String, Sendable, CaseIterable {
    case favourite, reblog, bookmark

    /// The column each one is written to. Named once, so the SQL below cannot spell it
    /// differently from the mapping above.
    var column: String {
        switch self {
        case .favourite: "favourited_at"
        case .reblog: "reblogged_at"
        case .bookmark: "bookmarked_at"
        }
    }
}

/// What the reader has muted, and whether it was their own machine or a server that was told.
///
/// The two are separate rows rather than a flag, because this app promises it can always say
/// which of the two hid something — and a single row with a flag on it cannot say both.
public struct Mute: Sendable, Hashable {
    public enum Kind: String, Sendable { case author, host }

    public let kind: Kind
    /// An actor URI for an author, a bare hostname for a host.
    public let value: String
    /// Which server is carrying it out, or `nil` for this device's own rule.
    public let serverURL: String?
    public let mutedAt: Date

    public init(kind: Kind, value: String, serverURL: String? = nil, mutedAt: Date) {
        self.kind = kind
        self.value = value
        self.serverURL = serverURL
        self.mutedAt = mutedAt
    }

    public var isLocal: Bool { serverURL == nil }
}

extension LocalStore {
    // MARK: - Marks

    /// What each of these posts is marked with, for one account. Posts with nothing recorded
    /// are absent rather than present-and-empty: never-told is the absence of an answer.
    public func marks(of keys: [String], as authorId: String) async throws -> [String: PostMarks] {
        guard !keys.isEmpty else { return [:] }
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT merge_key, favourited_at, reblogged_at, bookmarked_at
                FROM post_marks WHERE author_id = ? AND merge_key IN (\(placeholders))
                """, arguments: StatementArguments([authorId] + keys))
            return rows.reduce(into: [:]) { found, row in
                found[row["merge_key"]] = PostMarks(
                    favourited: (row["favourited_at"] as Int64?).map { _ in true },
                    reblogged: (row["reblogged_at"] as Int64?).map { _ in true },
                    bookmarked: (row["bookmarked_at"] as Int64?).map { _ in true }
                )
            }
        }
    }

    /// Writes one answer down, or takes it back.
    ///
    /// Undoing writes NULL rather than a row saying "undone at": once it is undone there is
    /// nothing left to remember, and remembering that somebody unfavourited something is a
    /// reading record — which this app does not keep.
    ///
    /// The account must already be in `accounts`; it is, because it is one of the reader's own
    /// and signing in wrote it there.
    public func mark(_ action: PostAction, on mergeKey: String, as authorId: String,
                     done: Bool, now: Date = Date()) async throws {
        let stamp = Self.milliseconds(now)
        try await write { db in
            try db.execute(sql: """
                INSERT INTO post_marks (merge_key, author_id, \(action.column), created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (merge_key, author_id) DO UPDATE SET
                    \(action.column) = excluded.\(action.column),
                    updated_at = excluded.created_at
                """, arguments: [mergeKey, authorId, done ? stamp : nil, stamp])
        }
    }

    /// What a read as an account told us about a page of posts, written down in one pass.
    ///
    /// Only what the server actually answered: a `nil` in `PostMarks` leaves the column alone
    /// rather than clearing it, because "this read said nothing" and "this account has not
    /// done it" are the two things this schema exists to keep apart.
    public func record(_ marks: [String: PostMarks], as authorId: String,
                       now: Date = Date()) async throws {
        guard !marks.isEmpty else { return }
        let stamp = Self.milliseconds(now)
        try await write { db in
            for (key, mark) in marks {
                for action in PostAction.allCases {
                    guard let done = mark.value(of: action) else { continue }
                    try db.execute(sql: """
                        INSERT INTO post_marks (merge_key, author_id, \(action.column), created_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT (merge_key, author_id) DO UPDATE SET
                            \(action.column) = excluded.\(action.column),
                            updated_at = excluded.created_at
                        """, arguments: [key, authorId, done ? stamp : nil, stamp])
                }
            }
        }
    }

    // MARK: - Kept

    /// Whether this device holds on to a post. No server is told, which is the whole of what
    /// separates it from a bookmark.
    public func keep(_ mergeKey: String, kept: Bool, now: Date = Date()) async throws {
        try await write { db in
            try db.execute(sql: "UPDATE posts SET kept_at = ? WHERE merge_key = ?",
                           arguments: [kept ? Self.milliseconds(now) : nil, mergeKey])
        }
    }

    public func kept(among keys: [String]) async throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            return try Set(String.fetchAll(db, sql: """
                SELECT merge_key FROM posts
                WHERE kept_at IS NOT NULL AND merge_key IN (\(placeholders))
                """, arguments: StatementArguments(keys)))
        }
    }

    // MARK: - Mutes

    /// Every standing mute, this device's own and the ones servers are carrying out.
    public func mutes() async throws -> [Mute] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, value, server_url, muted_at FROM mutes ORDER BY muted_at DESC
                """).compactMap { row in
                guard let kind = Mute.Kind(rawValue: row["kind"]) else { return nil }
                return Mute(kind: kind, value: row["value"], serverURL: row["server_url"],
                            mutedAt: Self.date(row["muted_at"]))
            }
        }
    }

    /// Puts a mute up, or takes it down. `serverURL` nil is this device's own rule.
    public func mute(_ kind: Mute.Kind, _ value: String, on serverURL: String? = nil,
                     muted: Bool, now: Date = Date()) async throws {
        let stamp = Self.milliseconds(now)
        try await write { db in
            guard muted else {
                if let serverURL {
                    try db.execute(sql: "DELETE FROM mutes WHERE kind = ? AND value = ? AND server_url = ?",
                                   arguments: [kind.rawValue, value, serverURL])
                } else {
                    try db.execute(sql: "DELETE FROM mutes WHERE kind = ? AND value = ? AND server_url IS NULL",
                                   arguments: [kind.rawValue, value])
                }
                return
            }
            // The unique indexes are partial — one for local rules, one per server — so the
            // conflict target has to name the same partial index rather than the bare columns.
            let target = serverURL == nil ? "(kind, value) WHERE server_url IS NULL"
                                          : "(kind, value, server_url) WHERE server_url IS NOT NULL"
            try db.execute(sql: """
                INSERT INTO mutes (kind, value, server_url, muted_at, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT \(target) DO UPDATE SET muted_at = excluded.muted_at,
                                                    updated_at = excluded.created_at
                """, arguments: [kind.rawValue, value, serverURL, stamp, stamp])
        }
    }
}

/// `?, ?, ?` for an `IN` list. GRDB has `databaseQuestionMarks` of its own on some versions;
/// this is spelled here so the SQL above does not depend on which.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
