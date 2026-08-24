import Foundation
import GRDB

/// One source's part of the store, guessed from what its posts carry.
///
/// An estimate, and the name says so wherever it is passed: SQLite keeps one file, not one
/// per server, and it files nothing by who sent it. What can be counted exactly is the text
/// each source's posts brought with them — the words, the media addresses, the URIs and the
/// extras — so that is what is counted, and the file is divided in the same proportion.
/// Indexes, the FTS table, page slack and the tags every source shares are not divided at
/// all; they are simply carried by whoever brought the most text. Near enough to be worth
/// showing, never near enough to be called the truth.
public struct SourceByteEstimate: Sendable, Hashable, Identifiable {
    /// The address the posts came from, spelled as `servers.url` and `Server.endpoint` spell
    /// it, so a screen can join these to its own rows without translating.
    public let endpoint: String
    /// The bare hostname, for saying it out loud.
    public let host: String
    /// The bytes this source's posts carry, counted exactly. Not disk: no index, no
    /// overhead, nothing this source shares with another.
    public let contentBytes: Int64
    /// This source's part of every source's content bytes, `0...1`. These sum to 1 across the
    /// list whenever anything is stored at all, which is what makes the split a split.
    public let share: Double
    /// `share` of the real file, where there is a file to take a share of. `nil` for a store
    /// that never touched a disk.
    public let estimatedBytes: Int64?

    public var id: String { endpoint }

    public init(endpoint: String, host: String, contentBytes: Int64, share: Double, estimatedBytes: Int64?) {
        self.endpoint = endpoint
        self.host = host
        self.contentBytes = contentBytes
        self.share = share
        self.estimatedBytes = estimatedBytes
    }
}

/// What the store is keeping, read in one piece as a screen would show it.
///
/// Two kinds of number, and the names keep them apart. `posts`, `oldestPostedAt` and
/// `diskBytes` are exact — a count, a timestamp and a file size, all of them facts. Only
/// `bySource` is a guess, and it says so in its element's type.
///
/// Nothing here is about the network: this is what is on this machine, and how much of it
/// there is. What we asked other people's machines for is `APIAccounting`, counted somewhere
/// else entirely and over a different span.
public struct Statistics: Sendable, Hashable {
    /// Every post row the store holds — including ones a server has since deleted and the
    /// purge has not reached yet, because they are still stored and still weigh something.
    public let posts: Int
    /// When the oldest of them was posted, or nothing at all where there are none.
    public let oldestPostedAt: Date?
    /// The database and the two files SQLite keeps beside it, together. `nil` for a store
    /// with no file — an in-memory one weighs nothing on disk because it is not on one.
    public let diskBytes: Int64?
    /// One entry per source that handed a post over, heaviest first. Not the same list as
    /// the sources you chose: a server you have since dropped is still here while its posts
    /// are.
    public let bySource: [SourceByteEstimate]

    public init(posts: Int, oldestPostedAt: Date?, diskBytes: Int64?, bySource: [SourceByteEstimate]) {
        self.posts = posts
        self.oldestPostedAt = oldestPostedAt
        self.diskBytes = diskBytes
        self.bySource = bySource
    }

    /// What a screen shows when there is no store at all — the same shape as a store that
    /// has never been written to, because to a reader those are the same thing.
    public static let empty = Statistics(posts: 0, oldestPostedAt: nil, diskBytes: nil, bySource: [])
}

extension LocalStore {
    /// Everything above, gathered in one pass.
    ///
    /// `async` and isolated to nothing, so a screen calling this from the main actor leaves
    /// it: the counting runs on the database's own queue, and the file sizes are read on a
    /// generic executor rather than back on the caller's. A screen that counted every post
    /// on the main actor would be a screen that stopped drawing while it did.
    public func statistics() async throws -> Statistics {
        let (posts, oldest, sources) = try await read { db -> (Int, Int64?, [(String, Int64)]) in
            let posts = try Int.fetchOne(db, sql: "SELECT count(*) FROM posts") ?? 0
            // A NULL `min` and no row at all both come back as nothing, which is the answer
            // an empty store should give anyway.
            let oldest = try Int64.fetchOne(db, sql: "SELECT min(posted_at) FROM posts")
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_url AS endpoint, sum(\(Self.contentBytes)) AS bytes
                FROM posts
                GROUP BY source_url
                ORDER BY bytes DESC, source_url
                """)
            return (posts, oldest, rows.map { ($0["endpoint"], $0["bytes"] ?? Int64(0)) })
        }

        let disk = fileBytes()
        let whole = sources.reduce(Int64(0)) { $0 + $1.1 }
        return Statistics(
            posts: posts,
            oldestPostedAt: oldest.map(Self.date),
            diskBytes: disk,
            bySource: sources.map { endpoint, bytes in
                // Nothing stored is nothing to divide. Guarded rather than assumed: a store
                // can hold posts whose every text field is empty, and 0/0 would put a NaN on
                // the screen.
                let share = whole > 0 ? Double(bytes) / Double(whole) : 0
                return SourceByteEstimate(
                    endpoint: endpoint,
                    host: Self.host(of: endpoint),
                    contentBytes: bytes,
                    share: share,
                    estimatedBytes: disk.map { Int64((Double($0) * share).rounded()) }
                )
            }
        )
    }

    /// What one post carries, in bytes rather than characters — `length` counts characters
    /// on TEXT, and a post written in Chinese would read as a third of the room it takes.
    /// Every field a post arrived with, and none of the local bookkeeping around it.
    private static let contentBytes = """
        length(CAST(text AS BLOB))
        + length(CAST(coalesce(media_urls, '') AS BLOB))
        + length(CAST(uri AS BLOB))
        + length(CAST(coalesce(origin_uri, '') AS BLOB))
        + length(CAST(coalesce(web_url, '') AS BLOB))
        + length(CAST(coalesce(extras, '') AS BLOB))
        """

    /// The database file and the write-ahead log and shared-memory files beside it, added
    /// up — all three are this store on disk, and WAL means the largest of them is often not
    /// the one named `store.sqlite`. `nil` where the database is not a file at all:
    /// `FileManager` answers that on its own, so `:memory:` needs no special case here.
    private func fileBytes() -> Int64? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return nil }
        return ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? manager.attributesOfItem(atPath: path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
