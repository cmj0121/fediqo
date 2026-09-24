import Foundation

// A post that quotes another (#214).
//
// **What a source said about the quote, and what it handed over of the quoted post.** A
// Mastodon-shaped server (4.4 on) sends a `quote` beside a status that quotes one: a state, and —
// where the quote may be shown — the quoted status in full, or where the quote sits a level down
// inside another quote, only its id. Nothing of the quoted post is kept where the state is one
// that may not be shown: the reader is told which state it is, and shown nothing of it.
//
// **One level, and never more.** The quoted post keeps what a row draws of it, and of its own
// quote only the state and the id — the rest is a post of its own, opened as one.

/// A post's quote of another post, as its source said it.
public struct Quote: Hashable, Sendable {
    /// Where the quote stands, in the source's own words. `unknown` is a word this build has not
    /// heard of, which is shown as a quote that cannot be shown rather than guessed at.
    public enum State: String, Hashable, Sendable, CaseIterable {
        /// The quoted post's author has not answered yet.
        case pending
        /// It may be shown.
        case accepted
        /// The quoted post's author said no.
        case rejected
        /// The quoted post's author said yes, and took it back.
        case revoked
        /// The quoted post is gone.
        case deleted
        /// This reader may not see the quoted post.
        case unauthorized
        /// This reader blocked the quoted post's author.
        case blockedAccount = "blocked_account"
        /// This reader blocked the quoted post's server.
        case blockedDomain = "blocked_domain"
        /// This reader muted the quoted post's author.
        case mutedAccount = "muted_account"
        case unknown

        /// The state a source spelled, or `unknown` where the spelling is none this build knows.
        public init(wire: String?) {
            self = wire.flatMap(State.init(rawValue:)) ?? .unknown
        }
    }

    public let state: State
    /// The quoted post, where the state is `accepted` and the source handed it over in full.
    /// Nothing otherwise — including where a source sent it beside a state that may not be shown.
    public let post: QuotedPost?
    /// The quoted post's id on the source it came through, where the state is `accepted`: what
    /// opens a quote that came with an id alone. Nothing otherwise.
    public let statusID: String?

    public init(state: State, post: QuotedPost? = nil, statusID: String? = nil) {
        self.state = state
        let shows = state == .accepted
        self.post = shows ? post : nil
        self.statusID = shows ? (statusID ?? post?.statusID) : nil
    }

    /// Whether the quoted post is here to be drawn.
    public var shows: Bool { post != nil }
}

/// A quoted post, in what a row draws of it — and of its own quote, only the state and the id.
public struct QuotedPost: Hashable, Sendable {
    /// What the post was minted as, where its source said — a `Note.id`, and its row's.
    public let id: String
    public let statusID: String?
    public let author: String
    public let handle: String
    public let body: String
    public let postedAt: Date
    public let avatarURL: URL?
    public let attachments: [Attachment]
    public let sensitive: Bool?
    public let spoiler: String?
    public let emojis: [CustomEmoji]
    public let url: URL?
    public let audience: Audience?
    public let reply: Reply?
    /// The quoted post's own quote, one level down: its state and its id, and nothing of it.
    public let quoting: NestedQuote?

    public init(
        id: String, statusID: String? = nil, author: String, handle: String, body: String,
        postedAt: Date, avatarURL: URL? = nil, attachments: [Attachment] = [],
        sensitive: Bool? = nil, spoiler: String? = nil, emojis: [CustomEmoji] = [],
        url: URL? = nil, audience: Audience? = nil, reply: Reply? = nil, quoting: NestedQuote? = nil
    ) {
        self.id = id
        self.statusID = statusID
        self.author = author
        self.handle = handle
        self.body = body
        self.postedAt = postedAt
        self.avatarURL = avatarURL
        self.attachments = attachments
        self.sensitive = sensitive
        self.spoiler = spoiler
        self.emojis = emojis
        self.url = url
        self.audience = audience
        self.reply = reply
        self.quoting = quoting
    }

    /// A note read as the post it quotes: what a row draws of it, its own quote cut to one level.
    public init(_ note: Note) {
        self.init(
            id: note.id, statusID: note.statusID, author: note.author, handle: note.handle,
            body: note.body, postedAt: note.postedAt, avatarURL: note.avatarURL,
            attachments: note.attachments, sensitive: note.sensitive, spoiler: note.spoiler,
            emojis: note.emojis, url: note.url, audience: note.audience, reply: note.reply,
            quoting: note.quote.map { NestedQuote(state: $0.state, statusID: $0.statusID) }
        )
    }

    /// Whether the author covered it. `DummyItem.covered`'s rule: a yes, or a line.
    public var covered: Bool { sensitive == true || !(spoiler ?? "").isEmpty }

    /// This post as a note of its own, through `source` — **held aside** and arrived through no
    /// timeline, so holding it never grows All. Its own quote is its id alone, which a read of
    /// the post itself fills in.
    public func note(through source: Source) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body,
            postedAt: postedAt, categories: [], reply: reply, audience: audience,
            avatarURL: avatarURL, attachments: attachments, sensitive: sensitive, spoiler: spoiler,
            emojis: emojis, url: url, statusID: statusID, holding: .aside,
            quote: quoting.map { Quote(state: $0.state, statusID: $0.statusID) }
        )
    }
}

/// A quote inside a quoted post: which state, and which post, and nothing of it.
public struct NestedQuote: Hashable, Sendable {
    public let state: Quote.State
    /// The id of the post it quotes, where the state is `accepted`.
    public let statusID: String?

    public init(state: Quote.State, statusID: String? = nil) {
        self.state = state
        self.statusID = state == .accepted ? statusID : nil
    }
}

extension Quote {
    /// The quote a later copy of the same post states, laid over the one held (#214).
    ///
    /// **The later copy wins**, as a count does: a quote's state is the source's latest word on
    /// it, so a quote taken back, deleted, blocked or muted since is drawn as that — and nothing of
    /// the quoted post with it — and one pending is accepted when the source says so. A copy that
    /// says nothing of a quote leaves the held one. **The one exception is the same quote said
    /// again**: accepted both times, of the same post, where the later copy came as an id alone
    /// (the quoted post's own copy, held aside) — the held post stays rather than being lost.
    static func later(_ later: Quote?, over held: Quote?) -> Quote? {
        guard let later else { return held }
        guard let held, later.state == .accepted, held.state == .accepted,
              later.statusID == nil || held.statusID == nil || later.statusID == held.statusID
        else { return later }
        return Quote(
            state: .accepted, post: later.post ?? held.post, statusID: later.statusID ?? held.statusID
        )
    }
}

extension Note {
    /// The post this one quotes, as a note of its own through the same source — **held aside**,
    /// so opening it works with the network off and it never grows All. Nothing where the quote
    /// may not be shown.
    public var quotedNote: Note? {
        quote?.post?.note(through: source)
    }

    /// The row the quoted post is, where it is here to open.
    public var quotedKey: NoteKey? {
        quote?.post.map { NoteKey(host: source.host, id: $0.id) }
    }
}
