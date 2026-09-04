import Foundation

/// What a server said somebody did, aimed at an account the reader owns.
///
/// Called a notice rather than a notification because half of Apple's frameworks own that
/// word: `Notification` is Foundation's, `UNNotification` is the operating system's banner,
/// and neither is this. This is the server's word about an event, kept the way posts are kept.
///
/// **Not merged.** Two servers carrying one post is one row in `posts`, because it is one
/// post. Two servers telling the reader about it is two notices, because they are two events
/// on two machines aimed at two different accounts — collapsing them would throw away which
/// inbox was written to, which is the one thing a reader signed in three places needs.
public struct Notice: Sendable, Hashable, Identifiable {
    /// The server's own id for the event. Unique on that server and nowhere else, which is
    /// why `id` below is the pair.
    public let remoteId: String
    /// The server that said it happened, as a `servers.url` endpoint.
    public let serverURL: String
    public let kind: NoticeKind
    /// Whose inbox this arrived in — an account the reader owns, as its actor URI.
    public let ownerId: String

    /// Who did it. Carried inline, the way a post carries its author: a row has to be drawable
    /// from the thing itself, without a second read to find out whose face goes on it.
    public let actorId: String
    public let actorName: String
    public let actorHandle: String
    public let actorAvatarURL: URL?

    /// The post it is about, where there is one. A follow is about nobody's post.
    ///
    /// Nil for a second reason as well, and the two must not be confused: **the event is about a
    /// post this device does not hold.** The store keeps the key on the notice's own row and
    /// joins to `posts`; a post that has rotated away, or one that never arrived, leaves this
    /// nil while the event still knows perfectly well which post it was about.
    public let post: Post?
    /// Which post it is about, whether or not this device holds it (#124).
    ///
    /// The key and not the post, because the key is what the notice itself carries. Two
    /// favourites are on the same post when they name the same key — asking `post?.mergeKey`
    /// would have said *no* for every post the store had let go of, and drawn six rows where
    /// there was one thing that happened.
    public let postKey: String?

    /// When the server says it happened. What a list is ordered by.
    public let noticedAt: Date
    /// When this device learned of it. A live arrival and a catch-up read differ here and
    /// nowhere else, which is what lets a screen say how late a notice was rather than guess.
    public let arrivedAt: Date
    /// When the reader looked. Ours, local, and never sent anywhere.
    public let seenAt: Date?

    /// One event on one server. `remoteId` alone is not an identity: two servers number their
    /// own events from one, and a list drawn from both would collapse the pair into one row.
    public var id: String { "\(serverURL)#\(remoteId)" }

    /// Whether the reader has looked at it yet.
    public var isUnseen: Bool { seenAt == nil }

    /// How long it took to reach this device. Zero where it arrived live, minutes where the
    /// app was in a pocket and the system chose when to wake it.
    ///
    /// Negative where a server's clock is ahead of ours, which happens and is not an error;
    /// clamped, because "arrived nine seconds before it happened" is not a thing to show a
    /// reader.
    public var lateness: TimeInterval { max(0, arrivedAt.timeIntervalSince(noticedAt)) }

    public init(
        remoteId: String,
        serverURL: String,
        kind: NoticeKind,
        ownerId: String,
        actorId: String,
        actorName: String = "",
        actorHandle: String = "",
        actorAvatarURL: URL? = nil,
        post: Post? = nil,
        postKey: String? = nil,
        noticedAt: Date,
        arrivedAt: Date,
        seenAt: Date? = nil
    ) {
        self.remoteId = remoteId
        self.serverURL = serverURL
        self.kind = kind
        self.ownerId = ownerId
        self.actorId = actorId
        self.actorName = actorName
        self.actorHandle = actorHandle
        self.actorAvatarURL = actorAvatarURL
        self.post = post
        // What was handed in, or the post's own where it was handed a post. One of the two is
        // always known and they never disagree.
        self.postKey = postKey ?? post?.mergeKey
        self.noticedAt = noticedAt
        self.arrivedAt = arrivedAt
        self.seenAt = seenAt
    }
}

/// The kinds of event this build can draw.
///
/// A closed set, and rows in `notice_kinds` that a test holds identical to these cases — the
/// same arrangement `SocialProtocol`, `Audience` and `TimelineFilter.Kind` have. A server
/// sends more than these: Mastodon has `follow_request`, `admin.sign_up`, `admin.report` and
/// `severed_relationships`, and a client that is not a moderation console has nothing to say
/// about any of them. They are dropped where they are decoded rather than stored as a kind no
/// screen can draw.
///
/// **`mention` is a reply too**, and that is the API's doing rather than a simplification of
/// ours: a reply to you is a mention of you, and Mastodon sends one kind for both. #9's
/// "replies and mentions arrive" is this one case.
public enum NoticeKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// Somebody wrote to the reader — a mention, or a reply, which is a mention.
    case mention
    case favourite
    case boost
    case follow
    /// A poll the reader voted in or wrote has closed.
    case poll
    /// A post the reader interacted with was edited.
    case update

    /// Whether this kind is somebody addressing the reader, rather than reacting to something
    /// already written. #9's first line is about these two: they are what has to arrive while
    /// the app is open, and what a bell is really for.
    public var isAddressed: Bool { self == .mention }

    /// Whether the event is about a post. A follow is about a person, and a row for one has
    /// nothing to quote.
    public var isAboutAPost: Bool { self != .follow }
}
