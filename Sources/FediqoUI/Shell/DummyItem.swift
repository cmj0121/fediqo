import FediqoCore
import Foundation

/// An item in the dummy store. Somebody's words, a named discussion, or a film — never a
/// protocol row.
public enum DummyItemKind: String, Sendable, Hashable {
    case note
    case thread
    /// **Here so that `DummyItem.kind` is not forced to lie.** Without it a `.video` source has
    /// to be answered with `.note` or `.thread`, and a film drawn as somebody's words is the
    /// identical silent wrong answer the no-`default:` rule exists against — arriving through an
    /// exhaustive switch instead of through a `default:`, which honours the rule in letter and
    /// breaks it in fact.
    ///
    /// **It is an honest answer, not a trap, and the difference matters to whoever adds
    /// PeerTube.** Nothing in this target switches over `DummyItemKind` — `DummyItem.kind` is
    /// written and never read — so this case sets no compiler stop anywhere, and adding one more
    /// would still set none. Provisional and unreachable in this milestone, like `.video` itself.
    case video
}

/// Who the author wrote it for, where the dummy said so. Nothing means the shape has no such idea.
public enum DummyAudience: String, Sendable, Hashable {
    case everyone
    case unlisted
    case followers
    case mentioned

    var symbolName: String {
        switch self {
        case .everyone: "globe"
        case .unlisted: "moon"
        case .followers: "lock"
        case .mentioned: "at"
        }
    }

    init(_ audience: Audience) {
        switch audience {
        case .everyone: self = .everyone
        case .unlisted: self = .unlisted
        case .followers: self = .followers
        case .mentioned: self = .mentioned
        }
    }
}

/// What a row says about this item being an answer.
public enum DummyAnswering: Sendable, Hashable {
    case nothing
    case somebody
    case handle(String)
}

public struct DummyCounts: Hashable, Sendable {
    public var replies: Int?
    public var reblogs: Int?
    public var favourites: Int?

    public init(replies: Int? = nil, reblogs: Int? = nil, favourites: Int? = nil) {
        self.replies = replies
        self.reblogs = reblogs
        self.favourites = favourites
    }
}

/// What this device has done to a dummy item. Remote marks are still local in this mock.
public struct DummyMarks: Hashable, Sendable {
    public var favourited: Bool
    public var bookmarked: Bool
    public var kept: Bool

    public init(favourited: Bool = false, bookmarked: Bool = false, kept: Bool = false) {
        self.favourited = favourited
        self.bookmarked = bookmarked
        self.kept = kept
    }
}

public struct DummyItem: Identifiable, Hashable, Sendable {
    /// Unique across sources: two hosts carrying one URI are two rows (#10).
    public let id: String
    /// The item's id as the source sent it.
    public let noteID: String

    public static func rowID(host: String, note: String) -> String {
        "\(host.lowercased())\u{1e}\(note)"
    }
    public let source: DummySource
    public let author: String
    public let handle: String?
    public let titleKey: String?
    /// The same thing a stranger's server actually sent, where one did.
    ///
    /// **Two fields for one line, because they are two different things.** `titleKey` names a
    /// line this app wrote and will translate; this is a line somebody else wrote, in whatever
    /// language they wrote it, and translating it would be rewriting their post. A fixture sets
    /// the first, a forum sets the second, and nothing sets both.
    public var titleText: String?
    public let body: String
    public let boardKey: String?
    /// The section name a forum sent, as against `boardKey`'s translated one. See `titleText`.
    public var boardText: String?
    public let postedAt: Date
    public let workRelated: Bool
    public let answering: DummyAnswering
    public let boostedBy: String?
    public let audience: DummyAudience?
    /// The author's picture, where the source sent an address for one.
    public let avatarURL: URL?
    /// Where this post lives on the web it came from — the canonical address, as its own server
    /// spells it, for the reader who wants to go and read it there.
    ///
    /// **Carried, not rebuilt.** A Discuz! thread's is assembled in Core out of a parsed host and
    /// an integer; a Discourse topic's is assembled the same way; a Mastodon status's comes out of
    /// that instance's JSON and is admitted by `Host.fetchableURL` at the wire boundary. Which of
    /// the three it is stops mattering by the time it is here, which is the point of a `Note`
    /// carrying it. Nothing where the source named no address, or named one this device will not
    /// go to.
    public let url: URL?
    public let attachments: [Attachment]
    /// Whether the author covered it, or nothing where the source never said. Carried as the
    /// three answers it has, not folded down to two — see `covered`.
    public let sensitive: Bool?
    /// The line the author covered it with, where there is one.
    public let spoiler: String?
    /// The pictures this post is partly written in, as the post itself carried them.
    ///
    /// The post's own list and not the reading server's: `:blobcat:` registered on two servers
    /// is two different pictures, and a row that drew the reader's over the author's would be
    /// quietly rewriting somebody's post. The reading server's catalogue is the fallback behind
    /// these, and `EmojiAlphabet` is the only thing that puts the two in that order.
    public let emojis: [CustomEmoji]
    public let counts: DummyCounts
    public let marks: DummyMarks
    /// Other hosts that also carried this item. Empty while two sources are two rows (#10).
    public let alsoFrom: [DummySource]

    /// Hosts to name on the row, stable and unique. First is drawn; the rest are +n.
    public var shownHosts: [String] {
        var seen = Set<String>()
        return ([source] + alsoFrom)
            .map(\.host)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    /// Whether the row fills its slot. One answer for the whole post, because the slot is one
    /// square however many things came attached.
    ///
    /// **This asks a wider question than it used to, on purpose.** It was "the first attachment
    /// had a `preview_url`"; it is now "the post brought something with an address at all", so
    /// an audio clip a server sent no cover art for fills the slot instead of leaving it blank.
    /// A post that brought something should say so whether or not a still came with it.
    public var hasThumb: Bool { !attachments.isEmpty }

    public var hasAvatar: Bool { avatarURL != nil }

    /// Whether the row arrives covered: the author flagged it, or wrote a line to put in front
    /// of it. One answer for the whole row, because there is one cover over the whole row.
    ///
    /// **`sensitive == true`, never `sensitive ?? false`.** They read the same and mean different
    /// things: the first asks "did the source say yes", the second turns "the source never said"
    /// into "the source said no". A `Bool?` already *is* the three-case type — nothing, yes, no —
    /// so a named enum here would buy a third spelling of the same three cases and one more
    /// conversion for a wire boundary to get wrong. What was ever dangerous is `??`, and `??` is
    /// only dangerous at the one place that asks the question. This is that place, and it does
    /// not use it.
    ///
    /// A source that never said has not said the post is safe to look at, so nothing is uncovered
    /// on its silence — but neither is it covered on it: silence plus no spoiler line is a post
    /// with nothing to say about itself, and covering every such post would cover the timeline.
    public var covered: Bool {
        sensitive == true || !(spoiler ?? "").isEmpty
    }

    public var kind: DummyItemKind {
        switch source.kind {
        case .microblog: .note
        case .forum, .board: .thread
        // Provisional: an answer that exists so no film is called somebody's words, not a row
        // anybody has drawn, and nothing reaches it in this milestone. M2's PeerTube unit replaces
        // it. **It will not be stopped here** — this switch is already exhaustive and nothing
        // reads what it returns — so the word provisional is the whole of the warning.
        case .video: .video
        }
    }

    public var title: String? { titleKey.map { L10n.t($0) } ?? titleText }
    public var board: String? { boardKey.map { L10n.t($0) } ?? boardText }

    /// Where this row's way out goes, or nothing where there is nowhere to go.
    ///
    /// **Both halves of the control are named here, and that is the point of the property.**
    /// Three times in M1 a control shipped wired to something that did not do what its name said
    /// and every test stayed green, because what decided it sat in a `View` body no test could
    /// reach — once a dead `Back` button under 405 of them. *Whether* a row offers the way out
    /// and *what address* it opens are one question with one answer, and it is answered where
    /// `DummyItemTests` can ask it.
    ///
    /// **`Host.allowsFetch`, at a boundary that is not a fetch.** `DummyThreadPane.outward` wrote
    /// down why and this is the same reading of the same one function rather than a second rule:
    /// `URL(string:)` will build `javascript:`, `data:` and `file:///` out of a stranger's JSON,
    /// and `openURL` would do as it was told with any of them. Core admits `url` at ingestion and
    /// this admits it again at the door — one function read twice, not one rule written twice,
    /// which is the difference between belt and braces and the drift this branch warns about.
    ///
    /// It applies to all three protocols and not only the lifted one. Discuz! *builds* its
    /// `viewthread` address in Core out of a parsed host and an integer rather than lifting one
    /// from the page, and says there why it still does not trust it; a built address reaching
    /// this property is checked exactly like a lifted one, because the check is about what will
    /// be handed to the system browser and not about who wrote it.
    ///
    /// **Nothing, rather than an address that will not open** — decision 4 on this repo's
    /// controls. A row whose note named nowhere offers no way out at all, not a greyed one: a
    /// control the reader cannot press is a question about this app, and nothing is the honest
    /// answer to "this post named nowhere to go".
    public var outwardURL: URL? {
        guard let url, Host.allowsFetch(url) else { return nil }
        return url
    }

    /// What the way out is called, wherever it is drawn: the act, and the host it leads to.
    ///
    /// **`thread.open` reused, not twinned.** The key is named for the pane that first needed it
    /// and the sentence it holds — "Open on %@" — is exactly as true of a row. A second key
    /// saying the same thing in three bundles is one more pair to keep in step and one more
    /// chance for two surfaces to word one act differently.
    ///
    /// **It names the host and not "the browser".** `source.host` is parsed by `Host.parse` and
    /// never lifted from anybody's markup, so it is the one thing this app knows for certain
    /// about where an outward link ends up — and where it ends up is the fact a reader checks
    /// before following one.
    public var outwardName: String { Self.wayOutName(host: source.host) }

    /// The same sentence, for a surface that has a host but no `DummyItem` — a Discuz! reply,
    /// which is a `DiscuzPost` and not a `Note`. Shared rather than spelled twice for the reason
    /// the key is shared: two surfaces wording one act differently is how a reader comes to think
    /// they are two acts.
    ///
    /// `language` resolves the way `shapeWord` above resolves, and is here for the same reason —
    /// so a test can *ask* for a language rather than assign `L10n.language`, which suites running
    /// in parallel share.
    static func wayOutName(host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("thread.open", language: language), host)
    }

    /// Not the live stream. Named queries do not read this.
    public static let stored: [DummyItem] = []

    /// One note as root; conversation fetch is out of this branch.
    public func dummyConversation() -> DummyConversation {
        DummyConversation(ancestors: [], post: self, descendants: [])
    }

    /// One stored note, drawn as a row.
    ///
    /// **`among` has no default, for the reason `DummySource.unsigned`'s `kind` has none.** A
    /// note knows every host it arrived through and none of their protocols, so `alsoFrom` cannot
    /// be built here without being told what this device reads — and an empty default would be
    /// the right answer at every test call site and a silent wrong one at the two that reach a
    /// screen, which is exactly the shape that drew a globe over every joined forum. `[]` is a
    /// real answer, meaning "nothing else is joined", and it should be written down where it is
    /// true rather than inherited by omission where it is not.
    public init(_ note: Note, among sources: [Source]) {
        noteID = note.id
        id = Self.rowID(host: note.source.host, note: note.id)
        source = DummySource.unsigned(note.source.host, kind: Self.shape(of: note.source.kind))
        author = note.author
        handle = note.handle
        titleKey = nil
        titleText = note.title
        body = note.body
        boardKey = nil
        boardText = note.board
        postedAt = note.postedAt
        workRelated = false
        answering = Self.answering(note.reply)
        boostedBy = note.boostedBy
        audience = note.audience.map(DummyAudience.init)
        avatarURL = note.avatarURL
        url = note.url
        attachments = note.attachments
        sensitive = note.sensitive
        spoiler = note.spoiler
        emojis = note.emojis
        counts = DummyCounts(
            replies: note.counts.replies,
            reblogs: note.counts.reblogs,
            favourites: note.counts.favourites
        )
        marks = DummyMarks()
        alsoFrom = Self.others(note, among: sources)
    }

    /// The hosts this note also arrived through, as sources a row can draw.
    ///
    /// **Sorted, because `Note.hosts` is a `Set` and has no order to inherit.** `shownHosts` sorts
    /// again for what it draws; this sorts so that two `DummyItem`s built from one note are equal,
    /// which `Hashable` promises and a `Set`'s iteration order does not give.
    ///
    /// **A host with no source behind it is left out, and that is not a swallowed case.**
    /// `ItemStore.remove` strikes a host out of `hosts` at the same moment it takes the source out
    /// of the list, and `ingest` only ever unions a host that a join had already added — so a host
    /// in this set with nothing joined under it is a state the store does not produce. What it
    /// would take to draw one is a protocol name for a server this device is not reading, which is
    /// a shape nothing here has.
    private static func others(_ note: Note, among sources: [Source]) -> [DummySource] {
        // The overwhelmingly common note arrived through one server, and the work below is three
        // collections and a linear scan per survivor to say so. This whole function is rebuilt
        // once per timeline build, which is itself per visible row.
        guard note.hosts.count > 1 else { return [] }
        return note.hosts
            .subtracting([note.source.host])
            .sorted()
            .compactMap { host in
                guard let kind = sources.first(where: { $0.host == host })?.kind else { return nil }
                return DummySource.unsigned(host, kind: Self.shape(of: kind))
            }
    }

    /// Which shape of row a protocol gets. **The protocol stays behind; the timeline sees a
    /// shape** — that is `DummySourceKind`'s own rule, and this is the one place it is applied.
    ///
    /// Everything federated is a microblog whatever its software, because what they have in
    /// common is that a post is somebody's words. A forum is the other shape: a named discussion
    /// with a section and a count of answers, which the row already knows how to draw as a
    /// thread.
    ///
    /// **Both forums, and they are listed rather than defaulted.** Discourse and Discuz! are
    /// different programs — one publishes JSON and one publishes a page — and the difference is
    /// entirely behind this line: by here they are both a title, a board and an answer count,
    /// which is the whole of what `.forum` means. That is what the `default:` underneath used to
    /// swallow: a forum added to `ProtocolKind` and not to this switch still built, the source
    /// joined, the threads arrived, and every one of them was drawn as somebody's words with its
    /// title nowhere. `DummyItemTests` pins every protocol, one by one, for the same reason.
    ///
    /// **A film is the third shape, and it is answered before anything can ask.** `.peertube`
    /// maps to `.video` while `.peertube` is still refused at every join door, so no reader sees
    /// it this milestone. It is here because the alternative is `.microblog` sitting in its place
    /// as a plausible answer that nothing would break on.
    ///
    /// **Never `.board`.** That case is a query inside a source, not a protocol's shape — see
    /// `DummySourceKind.board`.
    ///
    /// Internal rather than private because the source page asks the same question of a `Source`
    /// it never turned into an item: `AccountPane` hard-coded `.microblog` and drew every joined
    /// forum — Discourse and Discuz! alike — with the globe icon.
    static func shape(of kind: ProtocolKind) -> DummySourceKind {
        // **No `default:`, and this one was written down as fixed while it was not.** The rule
        // exists because this exact function once mapped only `.discourse` and drew a whole
        // Discuz! forum as microblog posts with every title missing, and the compiler said
        // nothing. A `default:` here is that failure waiting for the next protocol; every case is
        // named, so the next one breaks the build at the place that has to decide.
        switch kind {
        case .discourse, .discuz: .forum
        case .peertube: .video
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .friendica,
             .gotosocial, .unknown:
            .microblog
        }
    }

    /// The shape, said in the one word a reader is shown.
    ///
    /// **One function, so the same server is described in the same words before and after the
    /// press.** The preview says "Mastodon · microblog" and the source row says it again; two
    /// spellings of that is two translations that drift.
    ///
    /// **No `default:`**, the rule `shape(of:)` above states. `.board` is unreachable — that
    /// function never returns it — and is still named rather than swept in, because a case swept
    /// into somebody else's answer is how this file shipped a forum drawn as microblog posts.
    /// `.video`'s string ships in M1 although nothing draws it, so unit 8 is not a build break
    /// waiting on a translator.
    /// `language` resolves the way `L10n.t(_:language:)` resolves — nothing means the shell's
    /// current language. It is here so a test can ask for a language instead of **assigning** one:
    /// `L10n.language` is a `nonisolated(unsafe) static var` that nine suite `init`s write and that
    /// suites running in parallel share, so a test that sets it mid-test can be read by another
    /// suite's test between two of its own lines. This file's own `everyShapeHasAWord` was doing
    /// exactly that, which is the flake this parameter retires.
    static func shapeWord(_ shape: DummySourceKind, language: DummyLanguage? = nil) -> String {
        switch shape {
        case .microblog: L10n.t("source.shape.microblog", language: language)
        case .forum, .board: L10n.t("source.shape.forum", language: language)
        case .video: L10n.t("source.shape.video", language: language)
        }
    }

    private static func answering(_ reply: Reply?) -> DummyAnswering {
        guard let reply else { return .nothing }
        if let handle = reply.handle { return .handle(handle) }
        return .somebody
    }
}

/// Ancestors, the post, then answers. Depth is generations below the post.
public struct DummyConversation: Hashable, Sendable {
    public let ancestors: [DummyItem]
    public let post: DummyItem
    public let descendants: [DummyThreadEntry]

    public var inOrder: [DummyItem] {
        ancestors + [post] + descendants.map(\.item)
    }

    public func depth(of id: String) -> Int {
        if let index = ancestors.firstIndex(where: { $0.id == id }) { return index }
        if post.id == id { return ancestors.count }
        if let entry = descendants.first(where: { $0.item.id == id }) {
            return ancestors.count + entry.depth
        }
        return 0
    }
}

public struct DummyThreadEntry: Hashable, Sendable {
    public let item: DummyItem
    public let depth: Int
}
