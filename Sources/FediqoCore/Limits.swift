import Foundation

/// The two limits a person sets on what this device holds (#249), side by side: how many months
/// are kept, and how much room the store may take. Whichever is reached first acts, and what it
/// lets go names it.
public enum StoreLimit: String, Codable, CaseIterable, Sendable {
    /// Keep posts: the latest months only (`KeepPolicy`).
    case months
    /// Room: the bytes this device gives the store and the picture copies together (`RoomPolicy`).
    case room
}

/// What one act of a limit let go of: how many posts, and from which sources. Nothing of the
/// posts themselves, which are gone.
public struct WentByLimit: Equatable, Sendable {
    public var posts: Int
    /// Folded hosts, sorted, so two acts over the same sources say the same thing.
    public var sources: [String]

    public init(posts: Int = 0, sources: [String] = []) {
        self.posts = posts
        self.sources = sources
    }

    public static let none = WentByLimit()
}

/// One line of the account a limit keeps (#251): which limit acted, when, how many posts and
/// picture copies went, and from which sources. **Never a post, never where it was read** — the
/// line is what can still be said once the posts are gone, and no more than that.
public struct LimitAct: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let limit: StoreLimit
    public let at: Date
    public let posts: Int
    /// Picture copies on disk that went; they come back when read again.
    public let copies: Int
    /// Folded hosts, sorted.
    public let sources: [String]

    public init(
        id: UUID = UUID(), limit: StoreLimit, at: Date, posts: Int, copies: Int = 0, sources: [String]
    ) {
        self.id = id
        self.limit = limit
        self.at = at
        self.posts = posts
        self.copies = copies
        self.sources = sources.map { $0.lowercased() }.sorted()
    }

    /// Whether the act let go of anything at all; a line is written only for one that did.
    public var isSomething: Bool { posts > 0 || copies > 0 }
}

/// The account, newest first and bounded (#251). Where lines are kept between runs is the
/// `LimitAccountStore`'s; this says what is kept.
public enum LimitAccount {
    /// How many lines are kept. A limit acts at most a few times a day, so this is years.
    public static let capacity = 200

    /// `act` at the head of `lines`, and the oldest past `capacity` gone.
    public static func adding(_ act: LimitAct, to lines: [LimitAct]) -> [LimitAct] {
        Array(([act] + lines).prefix(capacity))
    }
}

/// Where the account outlives a relaunch. The app hands the shell a file beside the index; a
/// test that does not care hands in none, and then the lines live for the run.
public protocol LimitAccountStore: Sendable {
    /// The lines as last written, newest first; empty where nothing was ever written.
    func read() -> [LimitAct]
    /// Writes `lines` in place of whatever was there.
    func write(_ lines: [LimitAct]) throws
}

/// The room policy (#249): the store and the picture copies together may weigh at most `room`
/// bytes, or anything where `room` is nil — no limit, the default.
public enum RoomPolicy {
    /// The rooms offered, in bytes: 100 MB, 250 MB, 500 MB, 1 GB, 2 GB. No limit is offered
    /// beside them.
    public static let choices: [Int] = [100, 250, 500, 1_000, 2_000].map { $0 * 1_000_000 }

    /// By how many bytes `total` is over `room`; zero where it is not, and where there is no room
    /// limit, so a limit never set lets nothing go.
    public static func over(total: Int, room: Int?) -> Int {
        guard let room, room > 0 else { return 0 }
        return max(0, total - room)
    }

    /// Whether going from `old` to `new` may let something go: any room after none, or a smaller
    /// one. Widening, or back to none, lets nothing go.
    public static func tightens(from old: Int?, to new: Int?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        return new < old
    }

    /// How many of `posts` posts to let go this round to win back `over` bytes, judged by the
    /// average a post weighs in a store of `bytes` — **and never the whole guess at once**: half
    /// of it, and no more than a quarter of what is held, so a store of a few heavy posts and many
    /// light ones cannot be cut past the room by an average that fits neither. At least one, and
    /// never more than there are. The caller weighs again once they are gone and asks again
    /// while it is still over.
    public static func postsToLetGo(over: Int, bytes: Int, posts: Int) -> Int {
        guard over > 0, posts > 0 else { return 0 }
        let each = max(1, bytes / posts)
        let guess = Int((Double(over) / Double(each)).rounded(.up))
        return min(posts, max(1, min((guess + 1) / 2, max(1, posts / 4))))
    }
}
