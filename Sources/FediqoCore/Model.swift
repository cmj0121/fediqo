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
    /// A forum rather than a microblog. Kept in the same list because what this app asks a
    /// host is "what do you speak", and a forum is an answer to that question — the shape of
    /// what comes back differs, not the question.
    case discourse
    /// The other forum, and a different program with a different answer to "how do I read you":
    /// Discourse publishes JSON, Discuz! publishes a page. Same question, same list.
    case discuz
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
        case .discourse: "Discourse"
        // With the exclamation mark. It is part of the product's name rather than punctuation
        // this app added, and it is how the software writes itself in its own generator tag.
        case .discuz: "Discuz!"
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

/// One thing that came attached to a post.
///
/// `kind` is what the server said it was, and `unknown` is a real answer rather than a missing
/// one: what is true of an attachment a server described by nothing but its address is that it
/// can be drawn, not that it is a photograph.
///
/// `url` is the file and `previewURL` is a still to draw in its place. A photograph often has
/// only the file and an audio clip often has no still, so either may be absent — and one with
/// neither is an attachment there is nothing at all to draw for. See `isEmpty`.
public struct Attachment: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case image, video, audio, unknown
    }

    public let kind: Kind
    public let url: URL?
    public let previewURL: URL?
    /// What the author wrote for somebody who cannot see it. Empty where they wrote none.
    public let alt: String
    /// What shape it is, in the pixels the server said, or nothing where it said nothing.
    ///
    /// Pixels rather than an aspect, because pixels are what a server sends: an aspect is what
    /// a view wants, and the arithmetic belongs where it is used rather than stored already
    /// divided where nobody can check it back against the file.
    ///
    /// **Nothing is not a square.** It is a server that did not say, and what a view does about
    /// that is the view's decision. See `aspect`.
    public let width: Int?
    public let height: Int?

    public init(
        kind: Kind,
        url: URL? = nil,
        previewURL: URL? = nil,
        alt: String = "",
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.kind = kind
        self.url = url
        self.previewURL = previewURL
        self.alt = alt
        // A shape needs both halves and both of them positive. One number on its own, or a
        // zero, is a server that said something useless rather than one that said a shape.
        let both = (width ?? 0) > 0 && (height ?? 0) > 0
        self.width = both ? width : nil
        self.height = both ? height : nil
    }

    /// How tall it is for its width, or nothing where the server did not say.
    ///
    /// Height over width, so 0.56 is a landscape photograph and 1.5 a portrait one.
    public var aspect: CGFloat? {
        guard let width, let height else { return nil }
        return CGFloat(height) / CGFloat(width)
    }

    /// What to draw: the still where there is one, the file otherwise.
    public var displayURL: URL? { previewURL ?? url }

    /// Whether this can be played here rather than handed to a browser.
    ///
    /// Two things have to be true, and the second is why this is a property rather than a
    /// glance at `kind`: it has to be something that plays, and **we have to hold the file
    /// itself**. A still with nothing behind it cannot be played, however obviously it is a
    /// film to look at.
    public var isPlayable: Bool {
        guard url != nil else { return false }
        return kind == .video || kind == .audio
    }

    /// Whether there is anything to draw at all. A slot with neither address is left empty.
    public var isEmpty: Bool { displayURL == nil }
}

/// A note this device has stored. Origins remember how it arrived.
public struct Note: Identifiable, Hashable, Sendable {
    public let id: String
    public let source: Source
    public let author: String
    public let handle: String
    public let body: String
    /// What the post is called, where the source has such a thing.
    ///
    /// **A microblog has none and a forum's is the post.** A Mastodon status is its words; a
    /// forum topic is a title with a discussion under it, and `/latest.json` often sends no
    /// excerpt at all — so a row that dropped this would draw a forum as a column of blank
    /// posts. Optional rather than empty-string, because "this source has no such idea" and
    /// "the author left it blank" are different facts and only the first is true here.
    public let title: String?
    /// The section of the source this was posted in — a forum's category. Nothing where the
    /// source has no such division, which is every microblog.
    public let board: String?
    public let postedAt: Date
    public var origins: Set<FetchOrigin>
    public let reply: Reply?
    public let boostedBy: String?
    public let audience: Audience?
    public let avatarURL: URL?
    /// What came attached, in the order the server listed it. Empty is a post that brought
    /// nothing, which is most of them.
    public let attachments: [Attachment]
    /// Whether the author covered it, or nothing where the source never said.
    ///
    /// **Nothing is not `false`.** A source with no such idea has not told us the post is safe
    /// to look at, and reading its silence as a no would uncover what nobody uncovered.
    public let sensitive: Bool?
    /// The line the author covered it with. Nothing where the source never said; empty where
    /// it said there was none.
    public let spoiler: String?
    /// The pictures this post is partly written in, one per shortcode.
    public let emojis: [CustomEmoji]
    public let url: URL?
    public let counts: Counts

    public init(
        id: String,
        source: Source,
        author: String,
        handle: String,
        body: String,
        title: String? = nil,
        board: String? = nil,
        postedAt: Date,
        origins: Set<FetchOrigin>,
        reply: Reply? = nil,
        boostedBy: String? = nil,
        audience: Audience? = nil,
        avatarURL: URL? = nil,
        attachments: [Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil,
        counts: Counts = Counts()
    ) {
        self.id = id
        self.source = source
        self.author = author
        self.handle = handle
        self.body = body
        self.title = title
        self.board = board
        self.postedAt = postedAt
        self.origins = origins
        self.reply = reply
        self.boostedBy = boostedBy
        self.audience = audience
        self.avatarURL = avatarURL
        self.attachments = attachments
        self.sensitive = sensitive
        self.spoiler = spoiler
        self.emojis = emojis
        self.url = url
        self.counts = counts
    }
}
