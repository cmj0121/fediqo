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
///
/// `CaseIterable` so that what is drawn for an audience can be asserted over all of them rather
/// than over the four somebody remembered to write down: an audience added here and left out of
/// the colour ramp is then a test that stops, not a mark that quietly takes a neighbour's hue.
public enum DummyAudience: String, Sendable, Hashable, CaseIterable {
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

/// What this device has done to a dummy item, and kept to itself.
///
/// **The favourite left this type with #107, and the bookmark with #285.** Each was a mark kept
/// in Fediqo that nobody else could see and no other app agreed with; they are now
/// `DummyItem.favourited` and `DummyItem.bookmarked`, which are what the source says. What is
/// left here is what really is this device's own: what the reader chose to keep.
///
/// **`kept` is the store's word** (#284): `Note.kept`, carried on the item, and moved only by
/// `ShellSession.setKept`.
public struct DummyMarks: Hashable, Sendable {
    public var kept: Bool

    public init(kept: Bool = false) {
        self.kept = kept
    }
}

public struct DummyItem: Identifiable, Hashable, Sendable {
    /// Unique across sources: two hosts carrying one URI are two rows (#10). Core's `NoteKey`,
    /// spelled as a string, so the list and the store tell rows apart by one rule.
    public let id: String
    /// The item's id as the source sent it.
    public let noteID: String
    /// The id **this post's own server** gives it — `Note.statusID`, where the row has one.
    ///
    /// **Carried rather than looked up.** A row that cannot be named on its server offers none of
    /// #54's acts, and the mark is drawn per row on every pass: a search back through the session's
    /// notes to answer it would be a scan of everything held, once a row, for a fact the row was
    /// built from. Nothing on a forum post and on a row kept before 0.2.0 learned it.
    public var statusID: String?

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
    /// Whether the reader has boosted it, **as the source said** — `Note.boosted`, carried rather
    /// than derived, so the mark under the post and the row in the store cannot come to disagree.
    /// Nothing where the source never said, which is what makes the mark absent rather than off.
    public var boosted: Bool?
    /// Whether the reader has favourited it, as the source said — `Note.favourited`, in `boosted`'s
    /// shape and for its reasons (#107).
    public var favourited: Bool?
    /// Whether the reader has bookmarked it, as the source said — `Note.bookmarked`, in
    /// `boosted`'s shape and for its reasons (#285).
    public var bookmarked: Bool?
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
    /// A forum thread's opening post as this device last read it — `Note.opening`, carried so a
    /// row reached before this run draws its words without asking (#154). Nothing elsewhere.
    public var opening: ForumOpening?
    /// What this post arrived through — `Note.categories`, carried so a forum row knows whether it
    /// was ranked and which board it is in, which is what decides whether reaching it may read
    /// its opening post (`ForumPosts.readsWhenReached`). Empty on a fixture.
    public var categories: Set<FediqoCore.Category> = []
    /// When this copy's source said it no longer has this post — `Note.goneSince`, carried so
    /// every place a row is drawn marks it the same way (#179). Nothing on a post its source still
    /// has. **This copy's fact**, which is what its acts are read off; what the row says is
    /// `goneEverywhere`.
    public var goneSince: Date?
    /// When this copy's source says the post was last changed — `Note.editedAt`, carried so every
    /// place a row is drawn marks it the same way (#286). Nothing on a post never changed.
    /// **Never when it was posted**: `postedAt` is that, and it is what the row's age reads.
    public var editedAt: Date?
    /// What this copy said before, as this device held it, oldest first — `Note.earlier`, carried
    /// so the pane a post is opened in can show it with nothing asked of anybody (#286).
    ///
    /// **This copy's, on a row two sources carried** (#114): each server tells its own copy's
    /// changes when it hears of them, and the row is drawn as one copy — so what it says it said
    /// before is what that copy said before.
    public var earlier: [Wording] = []
    /// Where a timeline this copy arrived through is not whole next to it — `Note.gaps`, carried
    /// so the list can say so at its place (#201). **This copy's**, of its own source's timelines.
    public var gaps: Set<TimelineGap> = []
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
    /// The post this one quotes (#214) — `Note.quote`, carried so every place a row is drawn
    /// draws the quote the same way. Nothing on a post that quotes none, which is most.
    public var quote: Quote?
    /// The row the quoted post is, where the quote came with the post in full: what opening the
    /// quote walks to. Nothing where it may not be shown, or came as an id alone.
    public var quotedRowID: String?
    /// Every other copy of this post this device holds, from the other sources that carried it,
    /// in the order they arrived (#114). Empty for a post held from one source, which is most.
    ///
    /// **The row is the first copy and these ride along; nothing is blended.** Each is drawn as
    /// its own source carried it — its own words, its own cover, its own pictures — because two
    /// copies of one post can differ (an edit that reached one server and not the other, an
    /// emoji one server spells differently), and a reader who wants to know why is owed both as
    /// they came rather than one this app assembled out of the two. What counts as the same post
    /// is `SamePost`'s answer, a fact the sources stated; this only carries it.
    public private(set) var otherCopies: [DummyItem] = []

    /// Whether this row is a reblog (#290): an item of its own, standing at the time of the
    /// reblog, that shows the post it reblogs. Its id, its time, what it arrived through and
    /// whether the person keeps it are the reblog's; `boostedBy` is who reblogged; everything
    /// drawn of a post on it — words, author, pictures, cover, counts, what the reader did — is
    /// the reblogged post's, read from that post's own item.
    ///
    /// **`statusID` is nothing on a reblog's row.** The id a source gave the reblog names the
    /// reblog, and nothing a reader presses on this row is meant for the reblog: so the row
    /// carries no id an act could be sent with, and what is pressed goes to `reblogged`.
    public private(set) var isReblog = false
    /// The post this reblog reblogs, as its own row — what an act pressed on this row is done
    /// to, and what opening it opens. Empty on anything but a reblog, and on a reblog whose post
    /// this device no longer holds (`reblogUnheld`).
    public private(set) var reblogged: [DummyItem] = []
    /// Whether this is a reblog of a post no longer held here: the row says who reblogged and
    /// when, and that the post is not here, and draws nothing of a post.
    public var reblogUnheld: Bool { isReblog && reblogged.isEmpty && !reblogOnItsWay }
    /// Whether this is a reblog whose post is not here yet and has been asked for (#293): the
    /// reblog still owes the one load an item is given when it first arrives (`Note.refsDue`).
    /// The row says the post is on its way, in the place it will stand. Nothing sets that mark
    /// on a reblog until loading is built; the row is drawn for it already.
    public private(set) var reblogOnItsWay = false
    /// Who reblogged, as a person to open — the reblog's own maker, whose page a press on the
    /// row's first line opens. Nothing on anything but a reblog.
    public private(set) var reblogger: DummyPerson?
    /// When the post this row draws was published: the post's own time. The same as `postedAt`
    /// on every row but a reblog's, where `postedAt` is when it was reblogged — the time the row
    /// stands at — and this is the time its header says, beside the author it belongs to.
    public private(set) var publishedAt: Date = .distantPast
    /// Whether the post this row draws is marked gone from its source (#179): the row's own
    /// mark, and on a reblog the mark of the post it reblogs — a fact about the words shown.
    public var postGone: Bool {
        isReblog ? (reblogged.first?.goneEverywhere ?? false) : goneEverywhere
    }
    /// Whether this reblog was taken back at its source: the reblog itself is marked gone,
    /// whatever became of the post. The first line says so; the post is drawn as it is held.
    public var reblogUndone: Bool { isReblog && goneEverywhere }
    /// Whether this row is a post held from before a reblog was an item of its own, which
    /// arrived as a reblog by `boostedBy` (#290): it stands at its own publish time and says so,
    /// until a timeline brings that reblog again.
    public var arrivedAsReblog: Bool { !isReblog && boostedBy != nil }

    /// The rows an act pressed on this one goes to (#290): its own copies, or — for a reblog —
    /// the post each copy reblogs. A reblog whose post is not held offers nothing to press.
    public var actCopies: [DummyItem] {
        isReblog ? copies.flatMap(\.reblogged) : copies
    }

    /// Whether the row is marked as gone from its source (#179): **every** copy's source has said
    /// so. A post one server deleted and another still carries is still there to read and to act
    /// on through the other, and a row saying nothing can be sent while its acts go through the
    /// live copy would be the mark and the acts disagreeing about one post.
    public var goneEverywhere: Bool {
        goneSince != nil && otherCopies.allSatisfy { $0.goneSince != nil }
    }

    /// Whether the person keeps this row (#284): **any** copy of it is kept. A post two sources
    /// carried is one row, and keeping the row keeps every copy (`ShellSession.setKept`) — so a
    /// row drawn as kept while one copy is not is a store moved from outside, and the next press
    /// un-keeps them all.
    public var kept: Bool {
        marks.kept || otherCopies.contains { $0.marks.kept }
    }

    /// Every source this post came through, the row's own first. One for most rows.
    public var sources: [DummySource] { [source] + otherCopies.map(\.source) }

    /// Every copy, the row's own first, each as its source carried it — what opening the row
    /// shows (#114). A copy here carries no copies of its own.
    public var copies: [DummyItem] {
        var own = self
        own.otherCopies = []
        return [own] + otherCopies
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

    /// The forum's own page for this row, where there is one worth offering beside what the app
    /// reads of it: a forum's ranked blog. Opening the row reads the blog in the app (#209); this
    /// is what its pane offers where that read could not be had — read in the app's own reader
    /// (#34), in place on a Mac (#169). Nothing for every other row.
    public var page: URL? {
        DiscuzBlogRow.isBlog(noteID) ? outwardURL : nil
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

    /// This post alone — **what a thread reads as before its conversation is here, and where
    /// there is no conversation to be had.**
    ///
    /// Not a placeholder and not a failure: a forum thread's answers are `ForumPosts`', a post
    /// nobody answered really is one post, and a microblog thread that has not landed yet says
    /// so for itself. The pane draws whichever of the three it is; this is the shape they share.
    public func dummyConversation() -> DummyConversation {
        DummyConversation(ancestors: [], post: self, descendants: [])
    }

    /// Every copy of one post, drawn as one row: the first copy, naming the rest (#114).
    ///
    /// `copies` are one post's by `SamePost.gathered` and in the order they arrived, which is the
    /// store's; the first is the row. **The row's identity is the lead copy's own row**, so a
    /// post held from one source keeps exactly the id it always had, and whatever is keyed by a
    /// row — the lamp, a mark, a place — acts on the merged row once.
    ///
    /// **Drawn as the first copy whose source is still here** (#250, `here`): a copy from a source
    /// since removed leads only where every copy's source has gone, so a post another source
    /// still carries is drawn, named and acted on through that source. Nothing said of what is
    /// here is every host here — the order the copies arrived in, as before. **The id follows
    /// the lead**, so it changes once when the first-arrived copy's source is removed and once
    /// more if that source is added again: a lamp or a place keyed by the old id is lost at
    /// that moment, as it would be for any row redrawn under a new key, and never otherwise.
    init(merging copies: [Note], here: Set<String>? = nil, targets: ReblogTargets = ReblogTargets([])) {
        let lead = here.flatMap { here in copies.firstIndex { here.contains($0.source.host) } } ?? 0
        self.init(copies[lead], reblogging: targets.target(of: copies[lead]))
        otherCopies = copies.enumerated().filter { $0.offset != lead }
            .map { DummyItem($0.element, reblogging: targets.target(of: $0.element)) }
    }

    /// Notes, in the order they are to be drawn, as rows: one per post, however many sources
    /// carried it. The one place a list of held notes becomes a list of rows, so the timeline and
    /// the search cannot come to disagree about when two copies are one. `here` is the hosts
    /// still on this device, for `init(merging:here:)`.
    ///
    /// `held` is everything this device holds, where `notes` is only what is to be drawn of it:
    /// a reblog's row shows the post it reblogs (#290), which is looked up there — a post the
    /// timeline's rules left out is still what its reblog shows.
    /// `targets` is that lookup already built, where the caller holds one — the session's, built
    /// once where its notes were replaced.
    static func merged(
        _ notes: [Note], here: Set<String>? = nil, among held: [Note]? = nil, targets: ReblogTargets? = nil
    ) -> [DummyItem] {
        let targets = targets ?? ReblogTargets(held ?? notes)
        return SamePost.gathered(notes).map { DummyItem(merging: $0, here: here, targets: targets) }
    }

    /// One stored note, drawn as a row. **A reblog drawn this way is drawn as one whose post is
    /// not held**: what it reblogs is another item, which `init(_:reblogging:)` is handed.
    public init(_ note: Note) {
        self.init(content: note, as: note)
        isReblog = note.isReblog
        reblogOnItsWay = note.isReblog && note.refsDue
        reblogger = note.isReblog ? DummyPerson(making: note) : nil
    }

    /// One stored note drawn as a row, with the post it reblogs where it is a reblog and that
    /// post is held (#290). Anything but a reblog is `init(_:)`, whatever `target` is.
    public init(_ note: Note, reblogging target: Note?) {
        guard note.isReblog, let target, !target.isReblog, target.source.host == note.source.host else {
            self.init(note)
            return
        }
        self.init(content: target, as: note)
        isReblog = true
        reblogged = [DummyItem(target)]
        reblogger = DummyPerson(making: note)
    }

    /// `content` drawn as a row that is `identity`'s: the same note for every row but a reblog's,
    /// where the post reblogged is what is drawn and the reblog is what the row is — its id, its
    /// time, what it arrived through, where its timeline is not whole, whether it is kept.
    private init(content note: Note, as identity: Note) {
        let reblog = identity.isReblog && identity.key != note.key
        noteID = identity.id
        id = identity.key.rowID
        source = DummySource.unsigned(note.source.host, kind: Self.shape(of: note.source.kind))
        author = note.author
        handle = note.handle
        titleKey = nil
        titleText = note.title
        // **A ranked blog read is drawn from what was read of it** (#209): its words, its date and
        // its author's picture, where its page gave them, over what the ranking list wrote. A
        // thread's opening post is not — its row draws it through `ForumPostBand`, which also
        // knows when it is on its way.
        let blog = DiscuzBlogRow.isBlog(note.id) ? note.opening : nil
        // A blog read and found to hold no words keeps what the list wrote of it: the excerpt is
        // still the forum's own line about it, and the pane says the page had no words.
        body = blog.map(\.words).flatMap { $0.isEmpty ? nil : $0 } ?? note.body
        boardKey = nil
        boardText = note.board
        postedAt = reblog ? identity.postedAt : blog?.postedAt ?? note.postedAt
        publishedAt = blog?.postedAt ?? note.postedAt
        workRelated = false
        answering = Self.answering(note.reply)
        boostedBy = reblog ? identity.author : note.boostedBy
        boosted = note.boosted
        favourited = note.favourited
        bookmarked = note.bookmarked
        // Never a reblog's own id (`isReblog`): not on a reblog showing its post, and not on
        // one whose post is gone.
        statusID = identity.isReblog ? nil : note.statusID
        audience = note.audience.map(DummyAudience.init)
        avatarURL = note.avatarURL ?? blog?.avatarURL
        url = note.url
        attachments = note.attachments
        opening = note.opening
        categories = identity.categories
        goneSince = identity.goneSince
        editedAt = note.editedAt
        earlier = note.earlier
        gaps = identity.gaps
        sensitive = note.sensitive
        spoiler = note.spoiler
        emojis = note.emojis
        counts = DummyCounts(
            replies: note.counts.replies,
            reblogs: note.counts.reblogs,
            favourites: note.counts.favourites
        )
        marks = DummyMarks(kept: identity.kept)
        quote = note.quote
        quotedRowID = note.quotedKey?.rowID
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

extension DummyConversation {
    /// The conversation a source handed back, around the post the reader opened.
    ///
    /// **The post itself is the one the pane was already given, not the one the thread carries.**
    /// A source's answer to "the thread around this post" may or may not include the post, and
    /// where it does it is a second copy of a row this device already holds — with its own marks,
    /// its own deck and its own id. Drawing that copy would move the lamp off the row the reader
    /// pressed. So `root` stands, and anything in either half that *is* the root is dropped.
    ///
    /// **Ancestors keep the source's order and are not nested.** They are one chain by
    /// construction — each answers the one before it — so a rail per generation says nothing a
    /// reader cannot already see, and `DummyConversation.depth(of:)` reads their depth off their
    /// position for exactly that reason.
    ///
    /// **Answers are nested by who they answer, and the chain is walked in one pass.** An answer
    /// whose parent has already been placed is one deeper than it; an answer whose parent this
    /// device cannot name — no `inReplyToId`, or a parent the source did not send — is a direct
    /// answer to the post. That fallback is the honest one: the source says it belongs to this
    /// thread, and the only place left to put it is under the post. It is also what keeps the
    /// pass linear, since the order a server walks its own tree already puts parents first.
    ///
    /// `rootID` is the id **the post's own server** gave the post — `Note.statusID`. It is passed
    /// in rather than read off `root.statusID`, although the row now carries one, because the
    /// caller has the id the thread was actually *fetched* by and this must be the same string:
    /// a conversation nested against one id and asked for under another would place every answer
    /// at the first generation and look like a server that sends flat threads. Nothing where it
    /// could not be known, and then every answer does stand at the first generation, which is the
    /// honest fallback rather than an accident.
    public static func around(
        _ root: DummyItem, rootID: String?, ancestors: [Note], descendants: [Note]
    ) -> DummyConversation {
        var depths: [String: Int] = [:]
        if let rootID { depths[rootID] = 0 }
        var entries: [DummyThreadEntry] = []
        // A reblog is in no thread (#290): it answers nothing. None reaches here — a thread's
        // reads are of posts — and one that did would be drawn with no post, as a reblog made
        // from one note alone is (`init(_:)`), so it is left out rather than drawn wrong.
        for note in descendants where note.key.rowID != root.id && !note.isReblog {
            let parent = note.reply?.inReplyToId.flatMap { depths[$0] }
            let depth = (parent ?? 0) + 1
            if let id = note.statusID { depths[id] = depth }
            entries.append(DummyThreadEntry(item: DummyItem(note), depth: depth))
        }
        return DummyConversation(
            ancestors: ancestors.filter { $0.key.rowID != root.id && !$0.isReblog }.map(DummyItem.init),
            post: root,
            descendants: entries
        )
    }
}

public struct DummyThreadEntry: Hashable, Sendable {
    public let item: DummyItem
    public let depth: Int

    public init(item: DummyItem, depth: Int) {
        self.item = item
        self.depth = depth
    }
}
