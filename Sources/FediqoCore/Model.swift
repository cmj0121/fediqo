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

/// One board of a forum the reader subscribed to.
///
/// **The number is the subscription and the name is the label.** A forum renames a board when a
/// moderator decides to; the `fid` it is served at does not change. Both are kept because a rail
/// listing `fid 34` is no use to anybody, and only one of them is the identity.
public struct BoardSubscription: Identifiable, Hashable, Sendable {
    public var id: Int { fid }
    public let fid: Int
    public let name: String

    public init(fid: Int, name: String) {
        self.fid = fid
        self.name = name
    }
}

/// A server this device reads. Unsigned: the host is the source.
///
/// **One source per host, carrying the boards the reader chose — never one source per board**
/// (D26). Everything per-server in this app is keyed by host: the picture cache's tags, the emoji
/// catalogue, `Clear`, the join list. A reader subscribing to eight boards would otherwise become
/// eight servers in every one of them, and pressing Clear on one of the eight would mean
/// something nobody could predict. A board is a *query within* a source — which is the thing the
/// rail already draws (D27) — so `id` stays the host and the subscriptions ride along.
///
/// **A note's copy of this is a stamp, not a live view.** `Note.source` records which server the
/// note came from; the subscription list that matters is the one on the source in the store,
/// which is the only copy anything updates. Reading `boards` off a note would be reading what was
/// true when the note was parsed.
public struct Source: Identifiable, Hashable, Sendable {
    public var id: String { host }
    public let host: String
    public let kind: ProtocolKind
    /// The boards subscribed to, in the order they were picked. Empty for every source that has
    /// no such idea, which is every microblog and every Discourse.
    ///
    /// **At most one entry per `fid`, enforced here.** The guarantee is in the data rather than
    /// in a convention each caller remembers — this branch's second earned convention — because a
    /// forum that renamed a board between two reads would otherwise give a reader two
    /// subscriptions to one board, with two names, and no way to tell which.
    public let boards: [BoardSubscription]

    public init(host: String, kind: ProtocolKind, boards: [BoardSubscription] = []) {
        self.host = host.lowercased()
        self.kind = kind
        var seen: Set<Int> = []
        self.boards = boards.filter { seen.insert($0.fid).inserted }
    }

    public func subscribes(to fid: Int) -> Bool {
        boards.contains { $0.fid == fid }
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
    /// Which server handed this copy over, and **what future fetches about it are tagged with**.
    ///
    /// Two jobs in one field, and decision 16 is the ruling that they cannot be separated cheaply
    /// enough to bother. As a record of parsing it is exact: the handle, the reply and the emoji in
    /// this copy were all resolved against this host. As fetch provenance it is what
    /// `DummyItemRow` and `FediqoRootView` stamp on every avatar and emoji request they make for
    /// this row — so a stamp naming a server the reader has removed keeps this device asking that
    /// server for pictures, in an app whose whole claim is that nothing leaves it except to the
    /// servers the reader chose.
    ///
    /// **`internal(set)` for that one writer**, the same door `hosts` below keeps shut and for a
    /// stricter reason: `ItemStore.remove(host:)` re-stamps a surviving note to a source that
    /// remains, and nothing outside this module may rewrite where a note says it came from.
    public internal(set) var source: Source
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
    /// What the source calls that section, as against what it *shows* the reader.
    ///
    /// **A name is not an identity and must not be used as one.** A board's heading on its own
    /// page and its name in the forum's index are written by hand and are free to differ — they
    /// were byte-identical on all twenty-two boards measured, which is exactly the kind of fact
    /// that is true until it is not. Matching a subscription to its threads by name turns any
    /// such difference, or an administrator renaming a board between two reads, into a tab that
    /// silently draws nothing: visibly wrong, but wrong with no error anywhere to explain it.
    ///
    /// A `String` rather than the number Discuz! uses, because a section id is whatever the
    /// source says it is and Discourse's is its own; this is the identity, not the format.
    /// Nothing where the page carried no id — a forum's cross-board listing names no section per
    /// row — and a reader of this must fall back to the name rather than assume.
    public let boardID: String?
    public let postedAt: Date
    public var origins: Set<FetchOrigin>
    /// Every server this note arrived through. Never empty.
    ///
    /// **`source` is a stamp and this is the provenance, and a Mastodon status is the case that
    /// makes them two different things.** A Discourse topic's id and a Discuz! thread's are
    /// host-prefixed, so a row of theirs can only ever have come from the one host that stamped
    /// it. A Mastodon status's id is its canonical URI, which names the server that *wrote* it and
    /// says nothing about the server this device *read* it from — so two joined instances both
    /// carrying one status are one stored row, stamped with whichever joined first (see
    /// `ItemStore.ingest`).
    ///
    /// That is why removing a source cannot go by the stamp. Doing so would delete rows the
    /// remaining instance is still showing, and leave behind every row the removed instance was
    /// the only route to. `ItemStore.ingest` unions each arrival's host in here, `remove(host:)`
    /// takes one out, and a note goes only when the set empties (decision 9).
    ///
    /// Seeded from `source` rather than passed in, because a wire boundary has one host to declare
    /// and no way to know of a second — the second arrives later, through `ingest`, which is the
    /// only place that can see both. Seeding it from `self.source.host` also means the set is
    /// folded by the one rule `Source.init` already applies, so it compares to `remove(host:)`'s
    /// argument by `==` with no second folding rule to keep in step; a parameter would let a caller
    /// declare a host that disagrees with the stamp.
    ///
    /// **`internal(set)` where `origins` beside it is freely settable, and the asymmetry is the
    /// point rather than an oversight.** `origins` is a union of enum members with no invariant
    /// riding on it — a note with no origins is simply a note in no timeline, which is a state the
    /// app can hold and draw. This set is never empty, and emptiness is not a state here: it is the
    /// signal `remove(host:)` deletes on. A caller outside this module assigning `note.hosts = []`
    /// would therefore be arming a deletion rather than describing a note, so the two writers that
    /// may touch it — `ItemStore.ingest` and `ItemStore.remove` — are both in this module and the
    /// door is shut behind them.
    public internal(set) var hosts: Set<String>
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
        boardID: String? = nil,
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
        self.boardID = boardID
        self.postedAt = postedAt
        self.origins = origins
        // `Source.init` has already folded the case, so every host in this set is comparable to
        // every other by ==, which is what `remove(host:)` relies on.
        self.hosts = [self.source.host]
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
