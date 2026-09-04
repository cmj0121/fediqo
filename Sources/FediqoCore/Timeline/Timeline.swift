import Foundation

/// One rule between what arrived and what you see.
///
/// It adds or it removes; it never moves anything (#6). `negate` is which of the two: false
/// keeps only what matches, true removes what matches. Order is not reachable from here at
/// all — that belongs to the base source, where neither a rule nor a reader can touch it.
public struct TimelineFilter: Sendable, Hashable, Codable {
    /// What a rule can be about. Rows in `filter_kinds`, cases here, and a test holds the two
    /// lists identical — the same arrangement `BaseSource` has with `feeds`.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// A hashtag, matched the way the store keeps one: NFC, lowercased, no `#`.
        case tag
        /// An author, by the stable actor URI or by the handle a reader would type.
        case author
        /// An account the post names, by URI or by handle.
        case mention
        /// The server that handed the post over, by endpoint or by bare host.
        case server
        /// The post carries at least one attachment. The whole rule; `value` is empty.
        case media
    }

    public let kind: Kind
    public let value: String
    public let negate: Bool

    public init(kind: Kind, value: String = "", negate: Bool = false) {
        self.kind = kind
        // A tag is kept the one way the store keeps tags, so that a rule written `#Swift`
        // and a tag stored `swift` are the same rule. Everything else is kept as typed:
        // a handle and a URI are matched as themselves.
        self.value = kind == .tag ? Post.normalisedTags([value]).first ?? "" : value
        self.negate = negate
    }

    /// Whether this rule lets `post` through.
    ///
    /// **This is the definition**, and the SQL in `TimelineStore` is the same rule spelled for
    /// the store to run. They are two spellings of one thing, which is a standing invitation
    /// to disagree — so `TimelineFilterDriftTests` runs a corpus through both and holds them
    /// to the same answer, the way the schema files are held to their bundled copies.
    public func admits(_ post: Post) -> Bool {
        let matched = switch kind {
        case .tag: post.tags.contains(value)
        case .author: post.authorId == value || post.authorHandle == value
        case .mention: post.mentions.contains { $0.uri == value || $0.handle == value }
        case .server: post.sourceURL == value || post.sourceURL == "https://\(value)"
        case .media: !post.mediaURLs.isEmpty
        }
        return negate ? !matched : matched
    }
}

/// A timeline the reader made: where its posts are asked for, any number of rules, a name and
/// the line under it.
///
/// **One order, and it is time.** This used to say one base source and not several, and gave the
/// order as the reason: two sources would leave it undecided, because the order came from the
/// source. That reason had already stopped being true when it was written — a timeline has always
/// fanned out across every server the reader added and merged what came back by timestamp, so the
/// order was never any one source's. What the rule was really protecting is the sentence after
/// it, and that one still holds: a reader must never have to work out *which of my sources is
/// this post here for*. They do not have to. `post_origins` records how each post arrived, per
/// account, and a row says so; the reader is told rather than left to deduce.
///
/// So a timeline is a base reading and the tags it subscribes to, merged and sorted by time
/// (#104). The one source that still hands its own order over is `trend`, and a ranked reading
/// cannot be merged with anything without one of the two orders being thrown away — so it is not.
///
/// `template` is where it came from and nothing more. A template seeds a timeline when it is
/// made and has no say in it afterwards, so that shipping a new version of a template cannot
/// rewrite a list somebody named and described.
public struct Timeline: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    /// The line under the name. Longer than the name is the point of it: a tab is named in
    /// two words, and two words are not an explanation.
    public var summary: String
    public var source: BaseSource
    /// Which writers this is asked for. Only `public` has an answer other than `everyone`;
    /// see `Writers` (#113).
    public var writers: Writers
    /// The hashtags this timeline subscribes to, kept the one way the store keeps a tag: NFC,
    /// lowercased, no `#`. So `#Swift`, `#swift` and `＃swift` are one subscription (#104).
    ///
    /// **Asked for, not sieved.** A tag rule over the public timeline shows the posts carrying
    /// that tag *which the public timeline happened to hand over* — on a busy server, almost
    /// none of them, and a reader is left thinking the tag is quiet. These are a question put to
    /// every server the reader has added.
    public var tags: [String]
    /// What a search is for. Empty unless `source` is `.search` (#105).
    public var words: String
    /// Whose home this is. Nil unless `source` is `.home`.
    public var account: String?
    public var template: String
    public var position: Int
    public var filters: [TimelineFilter]

    public init(id: String = UUID().uuidString, name: String, summary: String = "",
                source: BaseSource, writers: Writers = .everyone, tags: [String] = [],
                words: String = "", account: String? = nil, template: String, position: Int = 0,
                filters: [TimelineFilter] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.source = source
        // A cut only the public timeline has. Kept rather than refused, the same way `account`
        // is dropped for a source with no account: a value that cannot mean anything here is
        // not a value to carry around waiting to be believed.
        self.writers = source == .public ? writers : .everyone
        // Normalised here rather than trusted, and deduplicated: two spellings of one tag are
        // one subscription, and asking twice would be one server told twice and every post
        // arriving to be merged with itself.
        self.tags = Post.normalisedTags(tags).reduce(into: []) { kept, tag in
            if !kept.contains(tag) { kept.append(tag) }
        }
        self.words = source == .search ? words : ""
        self.account = source.needsAccount ? account : nil
        self.template = template
        self.position = position
        self.filters = filters
    }

    /// What to ask the store for. The identity of a reading, without the name anybody gave it:
    /// two timelines called different things that ask the same question are one page of posts,
    /// and the screens hold their own place in each anyway.
    public var query: TimelineQuery {
        TimelineQuery(source: source, writers: writers, tags: tags, words: words,
                      account: account, filters: filters)
    }
}

/// A reading: where the posts come from, and which of them are kept.
public struct TimelineQuery: Sendable, Hashable {
    public let source: BaseSource
    /// Which writers the public timeline is asked for. `everyone` everywhere else (#113).
    public let writers: Writers
    /// The hashtags asked for alongside the base, normalised (#104).
    public let tags: [String]
    /// What a search is for, where this reading is one (#105).
    public let words: String
    public let account: String?
    public let filters: [TimelineFilter]

    public init(source: BaseSource, writers: Writers = .everyone, tags: [String] = [],
                words: String = "", account: String? = nil, filters: [TimelineFilter] = []) {
        self.source = source
        self.writers = source == .public ? writers : .everyone
        self.tags = tags
        self.words = source == .search ? words : ""
        self.account = account
        self.filters = filters
    }

    /// Every reading this timeline is made of: the base, unless the base *is* its tags, and then
    /// one for each tag. What the loader fans out across the servers, and what a post's origin
    /// is recorded as.
    ///
    /// A timeline based on `tag` with no tags has nothing here at all, and asks nobody — which
    /// is what #104 means by a base of nothing being empty rather than quietly the public
    /// timeline.
    /// A search asks nobody, so it has no readings at all — what it is about is what this
    /// device already holds, and the store is asked directly (#105).
    public var readings: [Reading] {
        (source == .tag || source == .search ? [] : [Reading.base(source)]) + tags.map(Reading.tag)
    }

    /// One question this timeline puts to a server.
    public enum Reading: Sendable, Hashable {
        case base(BaseSource)
        case tag(String)

        /// How a post that arrived by this reading is written down.
        public var source: BaseSource {
            switch self {
            case .base(let source): source
            case .tag: .tag
            }
        }
    }

    /// The whole of the rules, applied to posts that have not been through the store — a page
    /// straight off the network. The store answers the same question in SQL.
    public func admitted(_ posts: [Post]) -> [Post] {
        sifted(posts).admitted
    }

    /// The same, and what it turned away, with the reason attached.
    ///
    /// #6 asks that every hidden post can say which rule hid it, and a rule that removes things
    /// silently is one nobody can check. So the filtering answers both halves at once rather
    /// than throwing one away: what is left, and what is not and why.
    ///
    /// **The first rule that refused it, not all of them.** A post has to satisfy every rule, so
    /// the first refusal is the whole reason it is not here — the rest were never asked, and
    /// listing them would be inventing reasons after the fact.
    public func sifted(_ posts: [Post]) -> (admitted: [Post], hidden: [Hidden]) {
        guard !filters.isEmpty else { return (posts, []) }
        var admitted: [Post] = []
        var hidden: [Hidden] = []
        for post in posts {
            if let refused = filters.first(where: { !$0.admits(post) }) {
                hidden.append(Hidden(post: post, because: .rule(refused)))
            } else {
                admitted.append(post)
            }
        }
        return (admitted, hidden)
    }
}

/// A post that arrived and is not on the screen, and what kept it off.
///
/// #6's last promise: *"Every hidden post can say which rule hid it, or which server did."* Four
/// of its five lines are rules the app follows silently — timestamp order, add or remove but
/// never move, no rules means everything — and this is the one that says a reader must be able
/// to hold it to them.
///
/// It is only ever the reader's own doing. A post a server never handed over is not here to say
/// anything about, and that half of the sentence is answered somewhere else entirely: a server
/// that gave nothing is in `TimelineResult.failures`, and one that was never asked is in
/// `unasked`. What can be attributed post by post is what this app itself took out.
public struct Hidden: Sendable, Hashable {
    /// Why a post that arrived is not on the screen.
    public enum Because: Sendable, Hashable {
        /// A rule the reader wrote on this timeline, and the first one that turned it away.
        case rule(TimelineFilter)
        /// The reader asked not to be shown boosts.
        case boostsHidden
        /// The reader asked for posts with something attached, and this had nothing.
        case mediaOnly
    }

    public let post: Post
    public let because: Because

    public init(post: Post, because: Because) {
        self.post = post
        self.because = because
    }
}

/// What a new timeline is made from: a base source, and — where the template is about
/// something in particular — one thing the reader has to name.
///
/// The list is short on purpose. A template is a starting point, not a category system: what
/// distinguishes a timeline afterwards is the reader's own name for it, its description, and
/// the rules they put on it.
public struct TimelineTemplate: Sendable, Hashable, Identifiable {
    /// What the reader has to supply, if anything.
    public enum Parameter: String, Sendable, Hashable {
        case none, tag, author, mention
    }

    public let id: String
    public let source: BaseSource
    /// Which writers the template starts a timeline asking for. Two templates differ by nothing
    /// else, which is #113's own line: it is the same reading with a parameter, not a third base
    /// source.
    public let writers: Writers
    public let parameter: Parameter

    /// `writers` defaults, so that adding the cut did not touch the six templates that have no
    /// room to cut out of.
    public init(id: String, source: BaseSource, writers: Writers = .everyone,
                parameter: Parameter) {
        self.id = id
        self.source = source
        self.writers = source == .public ? writers : .everyone
        self.parameter = parameter
    }

    public static let all: [TimelineTemplate] = [
        TimelineTemplate(id: "public", source: .public, parameter: .none),
        TimelineTemplate(id: "home", source: .home, parameter: .none),
        TimelineTemplate(id: "trend", source: .trend, parameter: .none),
        TimelineTemplate(id: "local", source: .public, writers: .here, parameter: .none),
        TimelineTemplate(id: "remote", source: .public, writers: .elsewhere, parameter: .none),
        TimelineTemplate(id: "tag", source: .tag, parameter: .tag),
        TimelineTemplate(id: "author", source: .public, parameter: .author),
        TimelineTemplate(id: "mentions", source: .home, parameter: .mention),
    ]

    /// The three a fresh install starts with, in the order they sit in.
    public static let shipped = ["public", "home", "trend"]

    public static func named(_ id: String) -> TimelineTemplate? {
        all.first { $0.id == id }
    }

    /// A timeline seeded from this template. The name and the line under it are the caller's,
    /// because they are words in the reader's language and this layer has none.
    public func timeline(named name: String, summary: String = "", about value: String = "",
                         account: String? = nil, position: Int = 0) -> Timeline {
        var filters: [TimelineFilter] = []
        var tags: [String] = []
        switch parameter {
        case .none: break
        // A subscription and not a sieve (#104). This wrote a rule over the public timeline,
        // which showed the posts carrying the tag that the public timeline happened to hand
        // over — on a busy server, almost none of them.
        case .tag: tags.append(value)
        case .author: filters.append(TimelineFilter(kind: .author, value: value))
        case .mention: filters.append(TimelineFilter(kind: .mention, value: value))
        }
        return Timeline(name: name, summary: summary, source: source, writers: writers,
                        tags: tags, account: account, template: id, position: position,
                        filters: filters)
    }
}
