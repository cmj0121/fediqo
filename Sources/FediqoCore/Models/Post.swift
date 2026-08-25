import Foundation

/// One row of the timeline, whatever protocol it arrived by and however many servers
/// handed it over. `sources` is the list of those servers — the seed of "merged, not
/// repeated": two servers carrying the same post produce one `Post` with two sources.
///
/// Everything a network hands over is carried from the first read, because the store
/// writes it once and never backfills: a field left out today is an empty column on every
/// post already stored, forever.
public struct Post: Sendable, Hashable, Identifiable {
    /// The address we were handed — a server's local number for the post.
    public let uri: String
    /// The post's own canonical id, the same everywhere; `nil` when a source gives none.
    public let originURI: String?
    public let socialProtocol: SocialProtocol
    /// Normalised endpoint of the first server to hand it over, `https://<host>` for Mastodon.
    public let sourceURL: String
    public let createdAt: Date
    /// Stable actor URI / did / npub — never the handle, which a profile may rename.
    public let authorId: String
    public let authorName: String
    public let authorHandle: String
    public let authorAvatarURL: URL?
    public let text: String
    public let mediaURLs: [URL]
    public let webURL: URL?
    /// The parent's address. Not a reference: a reply routinely arrives before its parent.
    public let inReplyToURI: String?
    /// NFC, lowercased, no leading `#`, no repeats, in the order the source gave them.
    public let tags: [String]
    /// The accounts the post names, in the order the source gave them. Carried from the first
    /// read like everything else here: the store writes a post once and never backfills it.
    public let mentions: [Mention]
    /// The booster's display name — what the row shows.
    public let boostedBy: String?
    /// The booster's `authorId` — what identity is built on.
    public let boostedById: String?
    public private(set) var sources: [String]

    public var isBoost: Bool { boostedById != nil }

    /// What counts as "the same post": identity only, two tiers, first match wins — the
    /// same two the store keys on. Two servers carrying one post agree on its canonical id,
    /// so they collapse; a boost carries the original's id but is a different row, so who
    /// boosted it is part of the key. Merging those two would be exactly the silent
    /// collapse #5 forbids. The booster is named by id rather than display name, because
    /// names change and two people may share one.
    ///
    /// Worked out once, in `init`, and kept — because it is asked for constantly and computing
    /// it allocates a string for every boost, every time. A merged page asks it of every post,
    /// so does the sort under it, so does the reconciler's diff, and a screen asks it once per
    /// row per pass of its body. Nothing it is made of can change after `init`: `uri`,
    /// `originURI` and `boostedById` are all `let`, and `sources` — the one field that moves —
    /// is no part of identity.
    public let mergeKey: String

    public var id: String { mergeKey }

    public init(
        uri: String,
        originURI: String? = nil,
        socialProtocol: SocialProtocol,
        sourceURL: String,
        createdAt: Date,
        authorId: String,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        text: String,
        mediaURLs: [URL] = [],
        webURL: URL? = nil,
        inReplyToURI: String? = nil,
        tags: [String] = [],
        mentions: [Mention] = [],
        boostedBy: String? = nil,
        boostedById: String? = nil,
        sources: [String] = []
    ) {
        self.uri = uri
        self.originURI = originURI
        self.socialProtocol = socialProtocol
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.authorId = authorId
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.mediaURLs = mediaURLs
        self.webURL = webURL
        self.inReplyToURI = inReplyToURI
        self.tags = Self.normalisedTags(tags)
        self.mentions = Mention.folded(mentions)
        self.boostedBy = boostedBy
        self.boostedById = boostedById
        self.sources = sources
        let identity = originURI ?? uri
        self.mergeKey = boostedById.map { "boost:\($0)|\(identity)" } ?? identity
    }

    public mutating func addSource(_ host: String) {
        guard !sources.contains(host) else { return }
        sources.append(host)
    }

    /// A tag matches case-insensitively, so it is kept in one form: NFC, lowercased,
    /// without the `#`. `#Swift` and `swift` are one tag, and the first spelling keeps
    /// its place in line.
    static func normalisedTags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        return raw.compactMap { tag in
            var name = tag.precomposedStringWithCanonicalMapping.lowercased()
            if name.hasPrefix("#") { name.removeFirst() }
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}

/// An account a post names.
///
/// The URI is the name — the same stable actor URI `Post.authorId` is — because a handle is
/// what a profile renames. The handle rides along because it is what a reader would type and
/// what a screen would show, and it is spelled the way the post's own server spelled it.
///
/// It is not a reference to an account we hold: a post routinely names people this device has
/// never seen and may never see, which is why `post_mentions.mention_uri` is no foreign key.
public struct Mention: Sendable, Hashable, Codable {
    public let uri: String
    /// `@user@host`, as the post's own server spelled it.
    public let handle: String

    public init(uri: String, handle: String) {
        self.uri = uri
        self.handle = handle
    }

    /// Each account once, in the order first named. A post may name the same person twice.
    static func folded(_ raw: [Mention]) -> [Mention] {
        var seen: Set<String> = []
        return raw.filter { !$0.uri.isEmpty && seen.insert($0.uri).inserted }
    }
}

public extension Post {
    /// Further down the timeline than `other`: the one order a timeline is in. Newest first,
    /// `mergeKey` breaking the ties, so that two posts sharing a millisecond still have a
    /// below and an above and a page boundary can fall between them.
    ///
    /// Written once here because it is otherwise written everywhere — as the store's page cut
    /// and its `ORDER BY` in `LocalStore.timeline(limit:before:)`, as the sort in `merged()`,
    /// as the tail of `TimelineLoader.mergedByRank` under the ranks the servers gave, and
    /// wherever a screen joins one page to the one before it. Every extra spelling is another
    /// chance for two of them to disagree, and the post that falls between two spellings is
    /// skipped without anybody being told.
    static func isOlder(_ post: Post, than other: Post) -> Bool {
        post.createdAt == other.createdAt ? post.mergeKey > other.mergeKey
                                          : post.createdAt < other.createdAt
    }
}

public extension Array where Element == Post {
    /// One post from several places is one row. Collapse on `mergeKey`, keep every source,
    /// and leave the order to the timestamp — nothing here ranks anything.
    ///
    /// `order` is not redundant with the sort: Swift's sort is not stable, and two posts
    /// sharing a timestamp are common. Without it, equal-time rows would shuffle between
    /// refreshes for no reason a reader could see — and the tiebreak `Post.isOlder` gives
    /// them is what makes this the same order the store reads its pages back in, so a page
    /// boundary falling inside one millisecond lands in the same place on both sides.
    func merged() -> [Post] {
        merged(orderedBy: { Post.isOlder($1, than: $0) })
    }

    /// The fold itself: collapse on `mergeKey`, keep every source, then sort by `areInOrder`
    /// from first-seen order.
    internal func merged(orderedBy areInOrder: (Post, Post) -> Bool) -> [Post] {
        var order: [String] = []
        var merged: [String: Post] = [:]
        for post in self {
            let key = post.mergeKey
            if var existing = merged[key] {
                for host in post.sources { existing.addSource(host) }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = post
            }
        }
        return order.compactMap { merged[$0] }.sorted(by: areInOrder)
    }
}
