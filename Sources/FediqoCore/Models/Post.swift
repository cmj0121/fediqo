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
    public var mergeKey: String {
        let identity = originURI ?? uri
        guard let boostedById else { return identity }
        return "boost:\(boostedById)|\(identity)"
    }

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
        self.boostedBy = boostedBy
        self.boostedById = boostedById
        self.sources = sources
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

public extension Array where Element == Post {
    /// One post from several places is one row. Collapse on `mergeKey`, keep every source,
    /// and leave the order to the timestamp — nothing here ranks anything.
    ///
    /// `order` is not redundant with the sort: Swift's sort is not stable, and two posts
    /// sharing a timestamp are common. Without it, equal-time rows would shuffle between
    /// refreshes for no reason a reader could see.
    func merged() -> [Post] {
        merged(orderedBy: { $0.createdAt > $1.createdAt })
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
