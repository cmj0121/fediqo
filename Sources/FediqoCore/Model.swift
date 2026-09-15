import Foundation

/// A protocol a host might speak. Unknown is a name, not a silence.
public enum ProtocolKind: String, Sendable, Hashable, CaseIterable {
    case mastodon
    case pleroma
    case akkoma
    case misskey
    case pixelfed
    case lemmy
    case peertube
    case friendica
    case gotosocial
    case unknown

    public var displayName: String {
        switch self {
        case .mastodon: "Mastodon"
        case .pleroma: "Pleroma"
        case .akkoma: "Akkoma"
        case .misskey: "Misskey"
        case .pixelfed: "Pixelfed"
        case .lemmy: "Lemmy"
        case .peertube: "PeerTube"
        case .friendica: "Friendica"
        case .gotosocial: "GoToSocial"
        case .unknown: "unknown protocol"
        }
    }
}

/// A server this device reads. Unsigned: the host is the source.
public struct Source: Identifiable, Hashable, Sendable {
    public var id: String { host }
    public let host: String
    public let kind: ProtocolKind

    public init(host: String, kind: ProtocolKind) {
        self.host = host.lowercased()
        self.kind = kind
    }
}

public enum FetchOrigin: String, Sendable, Hashable {
    case publicTimeline
    case trending
}

public enum Audience: String, Sendable, Hashable {
    case everyone
    case unlisted
    case followers
    case mentioned
}

public struct Reply: Hashable, Sendable {
    public let handle: String?

    public init(handle: String? = nil) {
        self.handle = handle
    }
}

public struct Counts: Hashable, Sendable {
    public var replies: Int?
    public var reblogs: Int?
    public var favourites: Int?

    public init(replies: Int? = nil, reblogs: Int? = nil, favourites: Int? = nil) {
        self.replies = replies
        self.reblogs = reblogs
        self.favourites = favourites
    }
}

/// A note this device has stored. Origins remember how it arrived.
public struct Note: Identifiable, Hashable, Sendable {
    public let id: String
    public let source: Source
    public let author: String
    public let handle: String
    public let body: String
    public let postedAt: Date
    public var origins: Set<FetchOrigin>
    public let reply: Reply?
    public let boostedBy: String?
    public let audience: Audience?
    public let avatarURL: URL?
    public let previewURL: URL?
    public let url: URL?
    public let counts: Counts

    public init(
        id: String,
        source: Source,
        author: String,
        handle: String,
        body: String,
        postedAt: Date,
        origins: Set<FetchOrigin>,
        reply: Reply? = nil,
        boostedBy: String? = nil,
        audience: Audience? = nil,
        avatarURL: URL? = nil,
        previewURL: URL? = nil,
        url: URL? = nil,
        counts: Counts = Counts()
    ) {
        self.id = id
        self.source = source
        self.author = author
        self.handle = handle
        self.body = body
        self.postedAt = postedAt
        self.origins = origins
        self.reply = reply
        self.boostedBy = boostedBy
        self.audience = audience
        self.avatarURL = avatarURL
        self.previewURL = previewURL
        self.url = url
        self.counts = counts
    }
}
