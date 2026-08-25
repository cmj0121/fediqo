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

/// A timeline the reader made: one base source, any number of rules, a name and the line
/// under it.
///
/// One base source and not several. Two would leave the order undecided — order comes from
/// the source — and "which of my sources is this post here for" is a question a reader would
/// then have to answer for every post they saw.
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
    /// Whose home this is. Nil unless `source` is `.home`.
    public var account: String?
    public var template: String
    public var position: Int
    public var filters: [TimelineFilter]

    public init(id: String = UUID().uuidString, name: String, summary: String = "",
                source: BaseSource, account: String? = nil, template: String,
                position: Int = 0, filters: [TimelineFilter] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.source = source
        self.account = source.needsAccount ? account : nil
        self.template = template
        self.position = position
        self.filters = filters
    }

    /// What to ask the store for. The identity of a reading, without the name anybody gave it:
    /// two timelines called different things that ask the same question are one page of posts,
    /// and the screens hold their own place in each anyway.
    public var query: TimelineQuery {
        TimelineQuery(source: source, account: account, filters: filters)
    }
}

/// A reading: where the posts come from, and which of them are kept.
public struct TimelineQuery: Sendable, Hashable {
    public let source: BaseSource
    public let account: String?
    public let filters: [TimelineFilter]

    public init(source: BaseSource, account: String? = nil, filters: [TimelineFilter] = []) {
        self.source = source
        self.account = account
        self.filters = filters
    }

    /// The whole of the rules, applied to posts that have not been through the store — a page
    /// straight off the network. The store answers the same question in SQL.
    public func admitted(_ posts: [Post]) -> [Post] {
        guard !filters.isEmpty else { return posts }
        return posts.filter { post in filters.allSatisfy { $0.admits(post) } }
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
    public let parameter: Parameter

    public static let all: [TimelineTemplate] = [
        TimelineTemplate(id: "public", source: .public, parameter: .none),
        TimelineTemplate(id: "home", source: .home, parameter: .none),
        TimelineTemplate(id: "trend", source: .trend, parameter: .none),
        TimelineTemplate(id: "tag", source: .public, parameter: .tag),
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
        switch parameter {
        case .none: break
        case .tag: filters.append(TimelineFilter(kind: .tag, value: value))
        case .author: filters.append(TimelineFilter(kind: .author, value: value))
        case .mention: filters.append(TimelineFilter(kind: .mention, value: value))
        }
        return Timeline(name: name, summary: summary, source: source, account: account,
                        template: id, position: position, filters: filters)
    }
}
