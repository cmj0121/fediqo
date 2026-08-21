import Foundation

/// One row of the timeline, whatever protocol it arrived by and however many servers
/// handed it over. `sources` is the list of those servers — the seed of "merged, not
/// repeated": two servers carrying the same `uri` produce one `Post` with two sources.
public struct Post: Sendable, Hashable, Identifiable {
    public let uri: String
    public let createdAt: Date
    public let authorName: String
    public let authorHandle: String
    public let authorAvatarURL: URL?
    public let text: String
    public let mediaURLs: [URL]
    public let webURL: URL?
    public let boostedBy: String?
    public private(set) var sources: [String]

    public var isBoost: Bool { boostedBy != nil }

    /// What counts as "the same post". Two servers carrying one post agree on `uri`, so
    /// they collapse; a boost carries the original's `uri` but is a different row, so who
    /// boosted it is part of the key. Merging those two would be exactly the silent
    /// collapse #5 forbids.
    public var mergeKey: String {
        guard let boostedBy else { return uri }
        return "boost:\(boostedBy)|\(uri)"
    }

    public var id: String { mergeKey }

    public init(
        uri: String,
        createdAt: Date,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        text: String,
        mediaURLs: [URL] = [],
        webURL: URL? = nil,
        boostedBy: String? = nil,
        sources: [String] = []
    ) {
        self.uri = uri
        self.createdAt = createdAt
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.mediaURLs = mediaURLs
        self.webURL = webURL
        self.boostedBy = boostedBy
        self.sources = sources
    }

    public mutating func addSource(_ host: String) {
        guard !sources.contains(host) else { return }
        sources.append(host)
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
        return order.compactMap { merged[$0] }.sorted { $0.createdAt > $1.createdAt }
    }
}
