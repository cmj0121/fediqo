import Foundation
import Synchronization

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

    /// Whether a source of this kind has the timelines every Mastodon-shaped server shares —
    /// public, trends, home — so that a category naming one of them can mean this source.
    ///
    /// **The one list**, read by a timeline's rules and by `hasTrends`, which starts from it: a
    /// second list is how a tab and a rule come to disagree about a server. No `default:`, so a kind
    /// added later has to be answered here rather than inheriting somebody else's answer.
    /// Whether a post read from a source of this kind says whether it quotes one (#214): a read
    /// that says nothing of a quote is then a post with none, not a source that never said.
    public var saysQuotes: Bool { self == .mastodon }

    /// Whether a source of this kind says what its signed-in reader has done to a post (#285).
    public var saysReaderMarks: Bool { self == .mastodon }

    public var hasTimelines: Bool {
        switch self {
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial:
            true
        // Neither forum has one. A forum's categories are its boards.
        case .discourse, .discuz, .unknown:
            false
        }
    }

    /// Whether a source of this kind has something trending — so that `.trends` can mean it, the
    /// Trends tab can be offered for it, and a reload of a timeline that reaches its Trends reads
    /// them.
    ///
    /// **Every kind with timelines, and a Discuz! beside them without them.** A Discuz! forum
    /// ranks its threads and its blogs by the week (`DiscuzRanklist`), which is exactly what a
    /// microblog's trending read is: what everybody else is reading. It still has no public or
    /// home timeline, so `hasTimelines` stays false for it and those still never reach a forum.
    /// A Discourse has no ranking this app reads. No `default:`, `hasTimelines`' rule.
    public var hasTrends: Bool {
        switch self {
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discuz:
            true
        case .discourse, .unknown:
            false
        }
    }

    /// Whether this is a forum, whose authors are that forum's and nobody else's.
    public var isForum: Bool { self == .discourse || self == .discuz }

    /// Whether Fediqo can write to a source of this kind at all (#69).
    ///
    /// **`hasTimelines`' shape and for its reason** — one list per protocol fact, here beside the
    /// others rather than beside the feature that first needed it, so a protocol added later is
    /// answered in one place. No `default:`.
    ///
    /// **A forum is `false` although it signs in**, and the two are unrelated: a Discuz! sign-in is
    /// a cookie and a saved password that let this device *read* a board a signed-out reader may
    /// not, and this app has no way at all to post to a forum. So a forum row says read only, for a
    /// reason that is about the protocol rather than about anything its reader chose.
    public var canWrite: Bool {
        switch self {
        // Signed in on the server's own page, and the writing part is what #69 lets a reader buy.
        case .mastodon: true
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .discourse, .discuz, .unknown:
            false
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

/// One Mastodon list the reader chose to read (#25), the way a board is chosen.
///
/// **The id is the subscription and the name is the label**, as with a board: a list renamed on
/// the server is still this list, and only `name` changes.
public struct ListSubscription: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A server this device reads. Unsigned: the host is the source.
///
/// **One source per host, carrying the boards the reader chose — never one source per board**
/// (D26). Everything per-server in this app is keyed by host: the picture cache's tags, the emoji
/// catalogue, `Clear`, the join list. A reader subscribing to eight boards would otherwise become
/// eight servers in every one of them, and pressing Clear on one of the eight would mean
/// something nobody could predict. A board only chooses what a source fetches — the timelines
/// are All and Trends, not one per board — so `id` stays the host and the subscriptions ride along.
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
    /// The Mastodon lists chosen to be read, in the order they were picked; at most one per id.
    /// Empty for every source that is not a signed-in Mastodon, and kept through a sign-out.
    public let lists: [ListSubscription]

    public init(
        host: String,
        kind: ProtocolKind,
        boards: [BoardSubscription] = [],
        lists: [ListSubscription] = []
    ) {
        self.host = host.lowercased()
        self.kind = kind
        var seen: Set<Int> = []
        self.boards = boards.filter { seen.insert($0.fid).inserted }
        var seenLists: Set<String> = []
        self.lists = lists.filter { seenLists.insert($0.id).inserted }
    }

    public func subscribes(to fid: Int) -> Bool {
        boards.contains { $0.fid == fid }
    }
}

/// How the source itself divides what it serves, and what a post arrived through (#25).
///
/// **Known by id; a name is only a label** and lives on the source (`boards`, `lists`), never on
/// the note — a board or list renamed on the server is still the same category. A category means
/// nothing without its note's `source.host`: a board id is one forum's, while public and trends
/// mean the same thing on every Mastodon source.
///
/// **Every kind 0.2.0 knows is here from the first 0.2.0 store on.** A store must never hold a
/// kind the build reading it cannot name: that build would drop it on load and lose it at the
/// next save. A kind added after a release must also
/// register a new store migration — an empty one will do — so an older build refuses the store
/// rather than silently dropping what it cannot read.
public enum Category: Hashable, Sendable {
    /// A Mastodon source's public timeline.
    case `public`
    /// A Mastodon source's trending statuses — and a Discuz! forum's ranking lists, its threads
    /// and blogs ranked for the week (`DiscuzRanklist`).
    case trends
    /// A signed-in Mastodon account's home timeline.
    case home
    /// A Mastodon list, by the id the server gives it; its name is only a label.
    case list(id: String)
    /// A forum section, by the id the source gives it — Discuz!'s `fid` as a string.
    case board(id: String)
}

/// How a row came to be held, and so whether a timeline may show it (#175).
///
/// **Holding a post is not the same as it arriving.** A post a source handed over as part of a
/// timeline it serves arrived, and All draws it. A post this device went and fetched for one
/// place — a search hit, an answer read inside a thread, a post brought under a hashtag — is held
/// so it can be read where it was found, and All does not grow because a search was made. #90 said
/// this in passing about a thread's answers; here it is a fact of the store, said once, so the
/// tasks that need it do not each invent their own.
///
/// **It only ever widens.** A row held aside that later arrives through a timeline is a row that
/// arrived, and nothing takes that back — `Note.categories`' rule, for its reason: what a copy
/// arrived through is a fact about it, and a later read that did not come through a timeline is
/// not that fact going away.
public enum Holding: String, Sendable, Hashable {
    /// It arrived through a read of a source's timeline. Every timeline may show it.
    case arrived
    /// This device holds it, and no timeline shows it.
    case aside

    /// The wider of the two.
    func widened(by other: Holding) -> Holding {
        self == .arrived || other == .arrived ? .arrived : .aside
    }
}

public enum Audience: String, Sendable, Hashable, CaseIterable {
    case everyone
    case unlisted
    case followers
    case mentioned

    /// What a Mastodon source calls this on the wire.
    public var mastodon: String {
        switch self {
        case .everyone: "public"
        case .unlisted: "unlisted"
        case .followers: "private"
        case .mentioned: "direct"
        }
    }

    public init?(mastodon raw: String) {
        switch raw {
        case "public": self = .everyone
        case "unlisted": self = .unlisted
        case "private": self = .followers
        case "direct": self = .mentioned
        default: return nil
        }
    }

    /// How far a post travels, as a rank: the people who are mentioned are the fewest, everyone
    /// is the most. Unlisted sits above followers because anybody may read it who looks.
    ///
    /// **No `default:`**, so a fifth audience has to say where it stands.
    public var reach: Int {
        switch self {
        case .mentioned: 0
        case .followers: 1
        case .unlisted: 2
        case .everyone: 3
        }
    }

    /// Whether this goes further than `other`.
    public func isWider(than other: Audience) -> Bool { reach > other.reach }

    /// Where an answer's reach starts (#108): **never wider than the post it answers.**
    ///
    /// A followers-only post answered in public would carry a private conversation to everybody
    /// on the first press, and the reader would learn it from the replies. So the answer starts
    /// where the post is, and widening it is a choice the reader makes where they can see it.
    ///
    /// **A post whose reach this device was never told starts at the narrowest**, because that is
    /// the only start that cannot be wider than whatever the truth is.
    public static func answering(_ answered: Audience?) -> Audience {
        answered ?? .mentioned
    }
}

public struct Reply: Hashable, Sendable {
    public let handle: String?
    /// The id **that post's own server** gave the post this one answers, where it named one.
    ///
    /// The same spelling as `Note.statusID` and for the same reason: a thread is nested by
    /// matching a post's parent against the parents already placed, and a URI cannot do that —
    /// `in_reply_to_id` is a status id and the two are different strings for one post.
    ///
    /// **Nothing where the source has no such idea.** A forum reply is not a `Note` at all and a
    /// microblog that does not send one leaves this nil, which reads as "answered something this
    /// device cannot name" — the same thing `handle: nil` says about who.
    public let inReplyToId: String?

    public init(handle: String? = nil, inReplyToId: String? = nil) {
        self.handle = handle
        self.inReplyToId = inReplyToId
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

    /// These counts, with each one they do not state taken from `other` (#208). A count nobody
    /// stated is a source that never said, and never a zero.
    func filled(from other: Counts) -> Counts {
        Counts(
            replies: replies ?? other.replies,
            reblogs: reblogs ?? other.reblogs,
            favourites: favourites ?? other.favourites
        )
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

/// When the read that brought a copy of a post was sent, as a place in the order this run's
/// reads and the reader's own acts happened in (#291) — or nothing, where a copy cannot say.
///
/// **What tells a read already on its way from one asked afterwards.** A post never edited
/// carries no moment of its own to order two copies by (`Note.editedAt`), so a timeline asked
/// before the reader favourited a post and landing after the source answered would put the mark
/// back to what it was. The store marks the post with the next place as the act's answer lands
/// (`ItemStore.refresh(_:ifSourceHere:acted:)`), and a copy sent before that place says nothing of
/// what the reader did that the row does not say more lately.
///
/// **Counted, not clocked**, for `ItemStore.arrival`'s reason: the order two things happened in
/// is the only thing asked, and a clock can say two of them happened at once. One count for the
/// whole run rather than one per store, because a read is sent by a client that holds no store;
/// two stores that share the count each still see their own reads and acts in a true order.
///
/// **For the run, and never written down.** A relaunch has no read on its way.
///
/// **No part of what a note is.** Two copies that say the same things are the same note whenever
/// each was asked for, so every `ReadMoment` equals every other and hashes to nothing: a row
/// compared with a later copy of itself does not look changed by when the copy was sent.
public struct ReadMoment: Hashable, Sendable {
    /// The place in the run's order, or nothing where this copy cannot say when it was sent.
    public let place: UInt64?

    /// A copy that cannot say when it was sent: one made by hand, read back from disk, or from a
    /// source whose posts say nothing of the reader. **Never taken for one sent just now** — on a
    /// post the reader has acted on, it says nothing of what they did.
    public static let unsaid = ReadMoment(place: nil)

    private static let places = Mutex<UInt64>(0)

    /// The next place in the run's order: later than every one handed out before it. What a read
    /// takes as it is sent, and what the store marks a post with as an act's answer lands.
    public static func now() -> ReadMoment {
        ReadMoment(place: places.withLock { count in
            count += 1
            return count
        })
    }

    public static func == (_: ReadMoment, _: ReadMoment) -> Bool { true }
    public func hash(into _: inout Hasher) {}
}

/// One of the three things a source says its signed-in reader has done to a post (#285).
public enum ReaderMark: Hashable, Sendable, CaseIterable {
    case boosted, favourited, bookmarked
}

/// A note this device has stored. Its categories remember what it arrived through.
public struct Note: Identifiable, Hashable, Sendable {
    public let id: String
    /// Which server handed this copy over, and **what future fetches about it are tagged with**.
    ///
    /// Two jobs in one field, and since two sources became two rows (#10) they no longer pull
    /// apart. As a record of parsing it is exact: the handle, the reply and the emoji in this copy
    /// were all resolved against this host. As fetch provenance it is what `DummyItemRow` and
    /// `FediqoRootView` stamp on every avatar and emoji request they make for this row — and a
    /// Mastodon status two instances both carry is two notes, one stamped with each, so removing
    /// one instance takes its copy away with it rather than leaving a row that goes on asking a
    /// server nobody chose.
    ///
    /// **`let`, because nothing rewrites where a note says it came from.** The stamp is part of
    /// what the store keys a row by — `ItemStore` holds one row per host and id — so a note that
    /// changed its stamp would be a different row wearing an old one's key.
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
    /// Every category this copy arrived through. Only grows: a later fetch that did not come
    /// through one takes nothing away (#25). Empty is a post from a cross-board listing — a forum's
    /// front page — which a source rule still reaches.
    public var categories: Set<Category>
    public let reply: Reply?
    /// The name of whoever boosted this copy, as drawn.
    public let boostedBy: String?
    /// Who boosted this copy, as `@user@instance`, so an author rule can match the booster (#26).
    ///
    /// **Only as good as the first copy.** A boost and its original share one row per host, and
    /// the first copy to arrive is the one kept, so a boost that arrives after its original
    /// leaves no booster here and matches on its author alone. Nothing fills it in afterwards,
    /// and a note stored before this existed has none.
    public let boosterHandle: String?
    /// Whether the reader this copy was fetched as has boosted it, **as the source said** — not
    /// as this device remembers pressing anything (#106).
    ///
    /// **Nothing is not `false`**, `sensitive`'s rule and for its reason. A public timeline read
    /// signed out carries no such field at all, and reading that silence as a no would draw every
    /// post in it as one the reader has not boosted — which is a claim nobody made. Nothing means
    /// the source never said, so the mark is not offered; `false` means it said no.
    ///
    /// It is a fact about this copy through this source, which is what makes it survive a
    /// relaunch honestly: the row is stored with what the server last said, and every later fetch
    /// of the same post overwrites it with what the server says then.
    public let boosted: Bool?
    /// Whether the reader this copy was fetched as has favourited it, as the source said (#107).
    ///
    /// `boosted`'s shape, for `boosted`'s reasons: nothing is a source that never said, which is
    /// every unsigned read, and it is the server's answer that is kept rather than a press. A
    /// favourite is a note to the author and to oneself, and a list of them this device kept on
    /// its own would be a list no other app agrees with.
    public let favourited: Bool?
    /// Whether the reader this copy was fetched as has bookmarked it, as the source said (#285).
    ///
    /// `favourited`'s shape, for its reasons: nothing is a source that never said, which is every
    /// unsigned read, and it is the server's answer that is kept rather than a press. A bookmark
    /// is the source's to hold; what this device holds of its own is `kept`.
    public let bookmarked: Bool?
    /// Who the post was written for, as the source said (#208), or nothing where it never said —
    /// every forum post, and a row kept before 0.5.0 wrote this down until a read says it again.
    ///
    /// `boosted`'s shape: kept with the row, and a later read that says nothing leaves it.
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
    /// What the source last counted of answers, boosts and favourites, each nothing where it
    /// never said. Kept with the row (#208): a figure of the moment it was read, and still the
    /// source's latest word on it until a read says otherwise, which beats drawing none.
    ///
    /// **Unlike every other fact here, a later timeline copy's figure wins** — a count is only
    /// ever the source's latest, and the first copy's would be days stale by the end of the
    /// keep-for window. A count the later copy does not state keeps the one held. A `var` for
    /// `holding`'s reason: the store sets it on a row it already holds, and draws the new figure
    /// without writing the store down for it alone (`ItemStore.ingest`).
    public var counts: Counts
    /// The id the server this copy came through gives the status, where it is a microblog's —
    /// what reading the post again (#29) asks for. Nothing on a row stored before 0.2.0 learned
    /// it, and on every forum post.
    public let statusID: String?
    /// A forum thread's opening post as this device last read it — its words, what it quoted,
    /// and its author's picture (#154). Nothing on every other post, and on a forum row nobody
    /// has reached yet.
    ///
    /// **Kept with the row, and only what was read.** A thread table carries no part of the
    /// opening post, so this is filled in by the one read D30 already makes when a row is reached,
    /// and never by reading ahead. A post the forum withheld is not an opening to keep, and never
    /// arrives here (`ForumOpening.init?(_:)`). It goes when the row goes — a Remove, or the
    /// reader's keep-for window — and stays when a Clear keeps the row.
    public let opening: ForumOpening?
    /// Whether a timeline may show this row, or whether this device only holds it (#175).
    ///
    /// **A `var`, as `categories` is, and for its reason**: the store widens it where the same
    /// post arrives a second time through a timeline, and that is the one way it moves.
    public var holding: Holding
    /// When a read of this one post heard its source say it no longer has it (#179), or nothing
    /// while the source has said no such thing.
    ///
    /// **Only a read of the post itself sets it.** A post missing from a listing merely did not
    /// arrive, and a listing is never a statement about any one post — so nothing that reads a
    /// timeline, a search or a thread's page touches it. What the reader took back themselves
    /// (#109) is let go, not marked: `ItemStore.forget` is that path, and it sets this only on a
    /// post they keep (#284), which stays.
    ///
    /// A `var` for `holding`'s reason: the store sets it on a row it already holds, and a read
    /// that finds the post again takes it off.
    public var goneSince: Date?
    /// Where a timeline this post arrived through is not whole next to it (#201): newer posts
    /// that remain above it, or posts that may be missing below it. Empty on nearly every post.
    ///
    /// A `var` for `holding`'s reason: the store sets it on a row it already holds, as a read
    /// lands. Kept with the row, so it goes when the row goes and outlives a relaunch with it.
    public var gaps: Set<TimelineGap>
    /// The id each timeline listed this post under when a read of that timeline brought it — a
    /// boost's own, not the boosted post's (#201). What a timeline is read on from, and the only
    /// thing that moves where: a post the reader wrote, a search's find or a thread's answer was
    /// listed by no timeline, and so is never read on from.
    ///
    /// A `var` for `holding`'s reason: the store grows it as the same post is listed again.
    public var listed: [Category: String]
    /// The post this one quotes, as its source said (#214), or nothing where it quotes none or
    /// the source has no such idea. Kept with the row, so the quoted post shows offline.
    public let quote: Quote?
    /// Whether the person keeps this item (#284). A kept item is never let go: no purge, no limit
    /// and no removal of its source takes it, until the person un-keeps it.
    ///
    /// **This device's own, and nobody else's word.** No source says it and nothing is sent to
    /// one, so no read sets it or takes it off: a copy that arrives again, and a post read again,
    /// leave it as it was. Only `ItemStore.setKept` moves it.
    ///
    /// A `var` for `holding`'s reason: the store sets it on a row it already holds.
    public var kept: Bool
    /// When its source says the post was last changed after it was published (#286), or nothing
    /// where it says it never was — and on a source that says no such thing at all.
    ///
    /// **The source's word, and the one thing that tells a later copy from an earlier one.** A
    /// copy that says a later moment than the one held is the post as it is now; one that says an
    /// earlier moment, or none where the held copy says one, was read before the copy held and
    /// is still on its way in. **Never where the item stands**: `postedAt` is when it was
    /// published, and that is what every timeline orders by.
    public let editedAt: Date?
    /// What the post said before, as this device held it, oldest first (#286): each wording with
    /// the moment its source said it changed. Empty on a post never seen to change — and on one
    /// already changed when it was first read, since nothing is asked of the source for what
    /// this device never held.
    ///
    /// **Part of the row, and nowhere else.** It is written with the row, rides where the row
    /// rides, and is gone when the row is: there is no second place a wording its author took
    /// back could be left behind in.
    public let earlier: [Wording]
    /// The language the post says it is in, as its source spelled it and folded to lower case
    /// (#287), or nothing where the source said none — which is not a language, and matches no
    /// rule on one.
    public let language: String?
    /// When the read that brought this copy was sent (#291), or `unsaid`. **A fact about the
    /// copy on its way in, not about the post**: the store reads it as the copy lands and keeps
    /// none of it, and every note made from another starts again from `unsaid`.
    public var asked: ReadMoment = .unsaid

    public init(
        id: String,
        source: Source,
        author: String,
        handle: String,
        body: String,
        title: String? = nil,
        board: String? = nil,
        postedAt: Date,
        categories: Set<Category>,
        reply: Reply? = nil,
        boostedBy: String? = nil,
        boosterHandle: String? = nil,
        boosted: Bool? = nil,
        favourited: Bool? = nil,
        bookmarked: Bool? = nil,
        audience: Audience? = nil,
        avatarURL: URL? = nil,
        attachments: [Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil,
        counts: Counts = Counts(),
        statusID: String? = nil,
        opening: ForumOpening? = nil,
        holding: Holding = .arrived,
        goneSince: Date? = nil,
        gaps: Set<TimelineGap> = [],
        listed: [Category: String] = [:],
        quote: Quote? = nil,
        kept: Bool = false,
        editedAt: Date? = nil,
        earlier: [Wording] = [],
        language: String? = nil
    ) {
        self.id = id
        self.source = source
        self.author = author
        self.handle = handle
        self.body = body
        self.title = title
        self.board = board
        self.postedAt = postedAt
        self.categories = categories
        self.reply = reply
        self.boostedBy = boostedBy
        self.boosterHandle = boosterHandle
        self.boosted = boosted
        self.favourited = favourited
        self.bookmarked = bookmarked
        self.audience = audience
        self.avatarURL = avatarURL
        self.attachments = attachments
        self.sensitive = sensitive
        self.spoiler = spoiler
        self.emojis = emojis
        self.url = url
        self.counts = counts
        self.statusID = statusID
        self.opening = opening
        self.holding = holding
        self.goneSince = goneSince
        self.gaps = gaps
        self.listed = listed
        self.quote = quote
        self.kept = kept
        self.editedAt = editedAt
        self.earlier = earlier
        // Held to what a language tag looks like wherever a note is made (#287) — off the wire,
        // back from the store, in a test — so nothing that is not one is ever on a row.
        self.language = SourceField.languageTag(language)
    }

    /// What this post's words weigh, in the bytes they are written in (#294): its body, title and
    /// warning, and every earlier wording held with it. What `Holdings.Kept` adds up.
    var wordBytes: Int {
        body.utf8.count + (title?.utf8.count ?? 0) + (spoiler?.utf8.count ?? 0)
            + earlier.reduce(0) { $0 + $1.bytes }
    }

    /// What the post says, as a wording: its words and its author's warning, and whether it was
    /// covered. See `Wording`.
    func wording(until moment: Date) -> Wording {
        Wording(body: body, spoiler: spoiler, sensitive: sensitive, until: moment)
    }

    /// A moment as two copies are compared by: whole milliseconds, which is what a store keeps.
    /// A date read off the wire and the same date read back from disk are not always one
    /// `Double`, and compared as they are the copy just read would look a hair later than the row
    /// it is — a change every reload, written down every time.
    private static func moment(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Whether this copy was read before `held` was, **by its source's own word** (#286): it says
    /// an earlier change than the one held, or none where the held copy says one. Such a copy is
    /// a read still on its way in when a later one landed, and takes nothing of the held one's.
    func isEarlier(than held: Note) -> Bool {
        switch (editedAt, held.editedAt) {
        case (nil, .some): true
        case (let mine?, let theirs?): Self.moment(mine) < Self.moment(theirs)
        default: false
        }
    }

    /// Whether this copy is the post as its source changed it after `held` was read: it says a
    /// change, and a later one than the copy held says.
    func isLater(than held: Note) -> Bool {
        switch (editedAt, held.editedAt) {
        case (.some, nil): true
        case (let mine?, let theirs?): Self.moment(mine) > Self.moment(theirs)
        default: false
        }
    }

    /// The earlier wordings of `held`, with what it said until `self` — a later copy — changed
    /// it, where the two say different things. Bounded (`Wording.bounded`), oldest going first.
    private func earlier(after held: Note) -> [Wording] {
        guard let editedAt, isLater(than: held) else { return held.earlier }
        let was = held.wording(until: editedAt)
        guard was.body != body || (was.spoiler ?? "") != (spoiler ?? "") else { return held.earlier }
        return Wording.bounded(held.earlier + [was])
    }

    /// The moment this copy says it changed, spelled as `held` spells it where the two are the
    /// same moment — so a copy that says nothing new is equal to the row it is, and rewrites
    /// nothing.
    private func editedAt(over held: Note) -> Date? {
        isLater(than: held) || isEarlier(than: held) ? editedAt : held.editedAt ?? editedAt
    }

    /// This held note as `stale` restates it — a copy its source's own word says was read before
    /// this one (#286). **No word of it is taken.** Its counts are, as any copy's are; and what
    /// it says the reader did is taken only where `acted` — the source's answer to an act the
    /// reader has just made, which is the latest word there is on that whatever the copy's age.
    /// A timeline's or a thread's stale copy says nothing of the reader this row does not say
    /// more lately. `taking` is which of the three the copy's word is taken for: none for a read,
    /// and for an answer the act's own mark and whichever others it is not older on (#291).
    func restated(by stale: Note, taking: Set<ReaderMark>) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, title: title,
            board: board, postedAt: postedAt, categories: categories, reply: reply,
            boostedBy: boostedBy, boosterHandle: boosterHandle,
            boosted: taking.contains(.boosted) ? stale.boosted ?? boosted : boosted,
            favourited: taking.contains(.favourited) ? stale.favourited ?? favourited : favourited,
            bookmarked: taking.contains(.bookmarked) ? stale.bookmarked ?? bookmarked : bookmarked,
            audience: audience, avatarURL: avatarURL, attachments: attachments,
            sensitive: sensitive, spoiler: spoiler, emojis: emojis, url: url,
            counts: stale.counts.filled(from: counts), statusID: statusID, opening: opening,
            holding: holding, goneSince: goneSince, gaps: gaps, listed: listed, quote: quote,
            kept: kept, editedAt: editedAt, earlier: earlier, language: language
        )
    }

    /// This held note as `later` — a copy its source changed since — now says it (#286): the
    /// later copy's words, warning, cover, attachments, emoji and quote, with what this one said
    /// kept as an earlier wording. **Everything about where the row stands is this one's**: its
    /// publish time, the timelines it arrived through, how it is held, and what this device
    /// keeps of its own. What an ordinary reload does to a held row its source has changed.
    ///
    /// `was` is the row as it was held before this copy touched it — what it said is read off
    /// that, never off `self`, which `filled(from:)` may already have given the later copy's
    /// words (a quote arriving brings its words with it).
    func revised(by later: Note, was: Note) -> Note {
        Note(
            id: id, source: source, author: later.author, handle: handle, body: later.body,
            title: later.title ?? title, board: board, postedAt: postedAt, categories: categories,
            reply: reply, boostedBy: boostedBy, boosterHandle: boosterHandle, boosted: boosted,
            favourited: favourited, bookmarked: bookmarked, audience: later.audience ?? audience,
            avatarURL: later.avatarURL ?? avatarURL, attachments: later.attachments,
            sensitive: later.sensitive ?? sensitive, spoiler: later.spoiler ?? spoiler,
            emojis: later.emojis, url: url, counts: counts, statusID: statusID, opening: opening,
            holding: holding, goneSince: goneSince, gaps: gaps, listed: listed,
            quote: source.kind.saysQuotes
                ? later.quote.flatMap { Quote.later($0, over: quote) }
                : Quote.later(later.quote, over: quote),
            kept: kept, editedAt: later.editedAt, earlier: later.earlier(after: was),
            // The language the post says it is in **now**, nothing included: a post changed to
            // state none no longer matches a rule on the one it used to state.
            language: later.language
        )
    }

    /// This copy, read again, laid over the one held for the same row (#29): what the server says
    /// now — text, cover, attachments, counts — with the categories the held copy arrived through
    /// kept (and grown), its booster kept, and its board where this read names none.
    ///
    /// **`boosted`, `favourited` and `bookmarked` fall back to what was held, rather than being overwritten with
    /// nothing.** A
    /// re-read made signed out — the public timeline, a thread asked of a host with no token —
    /// carries no such field, and letting that silence replace a yes the same server gave an hour
    /// ago would draw the post as unboosted because nobody asked, which is the one thing #106
    /// says the mark must never do. A read made as the reader always says something, so it always
    /// wins.
    func refreshed(over held: Note, taking: Set<ReaderMark> = Set(ReaderMark.allCases)) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, title: title,
            board: board ?? held.board, postedAt: postedAt,
            categories: held.categories.union(categories), reply: reply,
            boostedBy: held.boostedBy, boosterHandle: held.boosterHandle,
            // A mark not among `taking` is one this copy is older on (#291): it was sent before
            // the reader's own act on the post landed, or before a sign-in there ended.
            boosted: taking.contains(.boosted) ? boosted ?? held.boosted : held.boosted,
            favourited: taking.contains(.favourited) ? favourited ?? held.favourited : held.favourited,
            bookmarked: taking.contains(.bookmarked) ? bookmarked ?? held.bookmarked : held.bookmarked,
            // Who it was for, whether it is covered and with what, and each count: what this read
            // left unsaid is what was held (#208), for `boosted`'s reason. A Mastodon source
            // always sends its cover line, empty where there is none, so a nil spoiler here is a
            // source that has no such idea — and a cover the author took off reads as "" and wins.
            audience: audience ?? held.audience, avatarURL: avatarURL, attachments: attachments,
            sensitive: sensitive ?? held.sensitive, spoiler: spoiler ?? held.spoiler, emojis: emojis,
            url: url, counts: counts.filled(from: held.counts),
            statusID: statusID ?? held.statusID,
            // A read of the row that says nothing of its opening post — a board listing, which
            // never does — leaves the one this device read where it is (#154).
            opening: opening ?? held.opening,
            // Where the row is held does not move on a read again (#175): a post read again is
            // not a post a timeline brought, so a row held aside stays aside and one in All stays
            // there. Only `ItemStore.ingest` widens it.
            holding: held.holding,
            // **No mark survives a read that found the post** (#179): the source has just handed
            // it over, which is the one thing a post gone from it cannot be.
            goneSince: nil,
            // What a read of this one post says is nothing about where its timeline is whole.
            gaps: held.gaps,
            listed: held.listed.later(listed),
            // The quote as the source says it now (#214) — a quote taken back reads so, and one an
            // edit took away is gone. Only a source that never says a quote leaves the held one.
            quote: source.kind.saysQuotes
                ? quote.flatMap { Quote.later($0, over: held.quote) }
                : Quote.later(quote, over: held.quote),
            // The person's own mark, which no read says anything about (#284).
            kept: held.kept,
            // What it said before this read changed it, kept (#286) — only where the source says
            // it changed since, and only what this device held.
            editedAt: editedAt(over: held), earlier: earlier(after: held),
            // A read of the post itself is the whole of what its source says of it now, so the
            // language is this copy's even where it states none — unlike the reader's marks,
            // which a signed-out read leaves unsaid rather than says no to.
            language: language
        )
    }

    /// This held note, with every fact it does not state taken from `other` — a later copy of the
    /// same post (#208). What it does state stays: the first copy wins, as `ItemStore.ingest`
    /// says, and a copy that says more only fills in where this one said nothing.
    ///
    /// **Only facts about the post, and only where nothing is "never said".** Not the booster,
    /// which is a fact about one copy and would draw an original as a boost; not `reply`, where
    /// nothing is an answer ("not a reply"); not attachments or emoji, where empty is an answer
    /// too; not the opening post, which no listing carries (#154). A title, the post's address
    /// and its author's picture are not here either: a source that has them sent them with the
    /// first copy, and one that did not has none to send. Nor the counts, where the later copy
    /// wins rather than fills (`counts`) — and nor what the reader has done to the post, where the
    /// later copy's word wins wherever it says one (#285).
    ///
    /// **A quote filled in brings its words with it** (#214). A row held before this device read
    /// quotes was read with the quote spelled into its words as an `RE:` address; the copy that
    /// says the quote has its words without it. Keeping the held words would draw the quote twice.
    func filled(from other: Note, marksStand: Bool = false) -> Note {
        let quoteArrives = quote == nil && other.quote != nil
        // A copy its source's own word says was read before this one (#286) says nothing of the
        // reader that this row does not say more lately: a reload still on its way when the
        // reader pressed, landing after the source answered the press. And so one the store
        // knows was sent before the reader's act landed (#291), which is `marksStand`.
        let stale = marksStand || other.isEarlier(than: self)
        return Note(
            id: id, source: source, author: author, handle: handle,
            body: quoteArrives ? other.body : body, title: title,
            board: board ?? other.board, postedAt: postedAt, categories: categories, reply: reply,
            boostedBy: boostedBy, boosterHandle: boosterHandle,
            // **What the reader has done to it is the source's latest word** (#285), as its
            // counts are: where the later copy says, it wins, so a boost, a favourite or a
            // bookmark taken off elsewhere reads as off after an ordinary reload. Where it says
            // nothing — a read made signed out — what was held stands.
            boosted: stale ? boosted : other.boosted ?? boosted,
            favourited: stale ? favourited : other.favourited ?? favourited,
            bookmarked: stale ? bookmarked : other.bookmarked ?? bookmarked,
            audience: audience ?? other.audience, avatarURL: avatarURL, attachments: attachments,
            sensitive: sensitive ?? other.sensitive, spoiler: spoiler ?? other.spoiler,
            emojis: emojis, url: url, counts: counts,
            statusID: statusID ?? other.statusID, opening: opening, holding: holding,
            goneSince: goneSince, gaps: gaps, listed: listed,
            // The later copy's quote wins, as its counts do (#214) — see `Quote.later`.
            quote: Quote.later(other.quote, over: quote),
            kept: kept, editedAt: editedAt, earlier: earlier, language: language ?? other.language
        )
    }

    /// This note with nothing said of what the reader has done to it (#285): not boosted, not
    /// favourited, not bookmarked, and not the opposite either — the state of a post no signed-in
    /// read has brought. What a row goes back to when the sign-in those words were said to ends.
    func withoutReaderMarks() -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, title: title,
            board: board, postedAt: postedAt, categories: categories, reply: reply,
            boostedBy: boostedBy, boosterHandle: boosterHandle, boosted: nil,
            favourited: nil, bookmarked: nil, audience: audience, avatarURL: avatarURL,
            attachments: attachments, sensitive: sensitive, spoiler: spoiler, emojis: emojis,
            url: url, counts: counts, statusID: statusID, opening: opening, holding: holding,
            goneSince: goneSince, gaps: gaps, listed: listed, quote: quote, kept: kept,
            editedAt: editedAt, earlier: earlier, language: language
        )
    }

    /// This note with its opening post as just read. Everything else is as it was.
    public func with(opening: ForumOpening) -> Note {
        Note(
            id: id, source: source, author: author, handle: handle, body: body, title: title,
            board: board, postedAt: postedAt, categories: categories, reply: reply,
            boostedBy: boostedBy, boosterHandle: boosterHandle, boosted: boosted,
            favourited: favourited, bookmarked: bookmarked, audience: audience, avatarURL: avatarURL,
            attachments: attachments, sensitive: sensitive, spoiler: spoiler, emojis: emojis,
            url: url, counts: counts, statusID: statusID, opening: opening, holding: holding,
            goneSince: goneSince, gaps: gaps, listed: listed, quote: quote, kept: kept,
            editedAt: editedAt, earlier: earlier, language: language
        )
    }
}

/// What a post said before its source changed it (#286), as this device held it.
///
/// **The words and the author's warning, and nothing else.** Those are what a post says. Its
/// pictures, a poll and its emoji are not kept here: a change to those alone still marks the post
/// as changed, and offers no earlier wording. Counts and what the reader did to it are no part
/// of what it says at all.
public struct Wording: Hashable, Sendable {
    /// How many earlier wordings a post keeps. A post rewritten more often than this lets its
    /// oldest go, so a source restating one post at every read cannot grow one row without end.
    public static let kept = 50
    /// How much the earlier wordings of one post may weigh together, as UTF-8: 128 KB. Fifty
    /// wordings of an ordinary post — five hundred characters, a kilobyte or two each — fit
    /// several times over, and so do the last few of the longest post a large server allows;
    /// what it stops is a source handing over a megabyte at every read and having each one kept.
    public static let budget = 128 * 1024

    public let body: String
    /// The line the author covered it with then. Nothing where the source said none.
    public let spoiler: String?
    /// Whether the author had covered it then, or nothing where the source never said — the
    /// post's own three answers (`Note.sensitive`), kept so a wording that was covered with no
    /// line of warning is still known to have been covered once the post no longer is.
    public let sensitive: Bool?
    /// When its source said the post changed from this — the moment this stopped being what it
    /// says.
    public let until: Date

    public init(body: String, spoiler: String? = nil, sensitive: Bool? = nil, until: Date) {
        self.body = body
        self.spoiler = spoiler
        self.sensitive = sensitive
        self.until = until
    }

    /// Whether the author had covered this wording: `DummyItem.covered`'s rule, asked of then.
    public var covered: Bool { sensitive == true || !(spoiler ?? "").isEmpty }

    /// What this wording weighs against `budget`.
    var bytes: Int { body.utf8.count + (spoiler?.utf8.count ?? 0) }

    /// `wordings` held to both bounds, the oldest going first: no more than `kept` of them, and
    /// no more than `budget` between them. **The one rule, for a wording being kept and for a
    /// row being read back**, so a store written by anything else is held to it too.
    ///
    /// **A wording heavier than the whole budget goes first, wherever it stands**: it could never
    /// be kept, and trimmed oldest-first it would take every lighter wording before it on its
    /// way out — one oversized rewrite costing a post everything it had said.
    public static func bounded(_ wordings: [Wording]) -> [Wording] {
        var held = Array(wordings.filter { $0.bytes <= budget }.suffix(kept))
        var weight = held.reduce(0) { $0 + $1.bytes }
        while weight > budget, let oldest = held.first {
            weight -= oldest.bytes
            held.removeFirst()
        }
        return held
    }
}

/// A forum thread's opening post, as it is kept with its row (#154).
///
/// **What a row draws of it, and nothing else**: the words, what they quoted, and the author's
/// picture the same page carried. Not the floor, the post number or when it was posted — the row
/// already has its author and its date from the thread table, and a second copy of either would
/// be a second answer to a question the row has already answered.
///
/// **A reply kept from a thread read to its end (#177) is the one exception**, and carries its
/// floor and its own date too: a reply is not a row, has no thread table to answer either, and
/// its note's date may be only when it was read (`DiscuzPost.asNote`). Nothing for an opening post.
public struct ForumOpening: Hashable, Sendable {
    /// The author's own words. Empty where the post has none — a picture, a poll — which is an
    /// answer, and is kept as one so the row is not asked again for words that do not exist.
    public let words: String
    public let quoted: [DiscuzQuotation]
    public let avatarURL: URL?
    /// A kept reply's floor, where its page numbered it. Never an opening post's.
    public let floor: Int?
    /// A kept reply's own date, or a read blog's (#209), where its page gave one a device can
    /// read. Never a thread's opening post's.
    public let postedAt: Date?

    public init(
        words: String, quoted: [DiscuzQuotation] = [], avatarURL: URL? = nil,
        floor: Int? = nil, postedAt: Date? = nil
    ) {
        self.words = words
        self.quoted = quoted
        self.avatarURL = avatarURL
        self.floor = floor
        self.postedAt = postedAt
    }

    /// A reply's words kept, with the two things only a reply needs. Withheld or not, which is
    /// the caller's to decide: `DiscuzPost.asNote` keeps none for a withheld one.
    public init(reply post: DiscuzPost) {
        self.init(
            words: post.body, quoted: post.quoted, avatarURL: post.avatarURL,
            floor: post.floor, postedAt: post.postedAt
        )
    }

    /// The opening post worth keeping, or nothing where it is not: **a post the forum withheld
    /// is the forum's notice, not the author's words**, and keeping it would draw a signed-in
    /// reader's row as locked for as long as the row is kept.
    public init?(_ post: DiscuzPost) {
        guard !post.isWithheld else { return nil }
        self.init(words: post.body, quoted: post.quoted, avatarURL: post.avatarURL)
    }
}

/// Which row a note is: the host it came through and the id that host gave it.
///
/// **One rule, stated here and read everywhere.** Two instances carrying one Mastodon status send
/// the same id, so the id alone is not a row (#10); the host beside it is. `ItemStore` keys its
/// rows by this and a drawn row takes its `id` from `rowID`, so the store and the list cannot
/// disagree about when two notes are one.
///
/// **Nothing is folded here.** `Note.key` builds this from `source.host`, which `Source.init` has
/// already folded; a second fold would be a second rule that only agrees with the first today.
/// A caller building one by hand is handing over a host it has already parsed.
public struct NoteKey: Hashable, Sendable {
    public let host: String
    public let id: String

    public init(host: String, id: String) {
        self.host = host
        self.id = id
    }

    /// The same key as one string, for a surface whose identity has to be a `String`. Joined on
    /// the record separator, which neither a hostname nor any id a server sends can contain.
    public var rowID: String { "\(host)\u{1e}\(id)" }

    /// The key a row id was built from, or nothing where the string is no row id.
    ///
    /// Split at the first separator: a host cannot contain one, so that is where the host ends,
    /// and two keys are equal exactly where their row ids are. So a caller holding a row id can
    /// compare keys rather than build a row id for every note it walks past.
    public init?(rowID: String) {
        guard let cut = rowID.firstIndex(of: "\u{1e}") else { return nil }
        self.init(host: String(rowID[..<cut]), id: String(rowID[rowID.index(after: cut)...]))
    }
}

extension Note {
    /// This note's row. See `NoteKey`.
    public var key: NoteKey { NoteKey(host: source.host, id: id) }
}
