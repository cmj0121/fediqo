import Foundation

// What a source hides or warns of for the person, by their own filters there (#338).
//
// **The server's, and never a rule.** A filter is kept at the source, made and changed there, and
// says itself which posts it caught (`Status.filtered`, `MastodonFilterCaptures`): this device
// matches no word of it. A timeline's rules are Fediqo's and the device's; these stay the
// server's, and neither becomes the other.

/// What a filter does to a post it catches, in the source's own word.
public enum ServerFilterAction: Hashable, Sendable {
    /// Shown covered, naming the filter, and opened on asking.
    case warn
    /// Not shown: its place says the filter hid it.
    case hide
    /// Shown with its pictures covered (Mastodon 4.4 on).
    case blur
    /// A word this build does not know: shown covered, as a warning is — never shown bare.
    case unknown(String)

    public init(word: String) {
        switch word {
        case "warn": self = .warn
        case "hide": self = .hide
        case "blur": self = .blur
        default: self = .unknown(word)
        }
    }

    public var word: String {
        switch self {
        case .warn: "warn"
        case .hide: "hide"
        case .blur: "blur"
        case .unknown(let word): word
        }
    }
}

/// One filter of the person's that the source said caught a post, as the post was read.
public struct ServerFilterHit: Hashable, Sendable {
    public let filterID: String
    public let title: String
    public let action: ServerFilterAction
    /// Where the filter applies, in the source's words: `home`, `notifications`, `public`,
    /// `thread`, `account`.
    public let context: Set<String>
    public let expiresAt: Date?

    public init(filterID: String, title: String, action: ServerFilterAction, context: Set<String>, expiresAt: Date?) {
        self.filterID = filterID
        self.title = title
        self.action = action
        self.context = context
        self.expiresAt = expiresAt
    }

    /// Whether it stands at `now` where a post is shown in `places` — any of them.
    public func applies(in places: Set<String>, at now: Date = Date()) -> Bool {
        guard expiresAt.map({ now < $0 }) ?? true else { return false }
        return !context.isDisjoint(with: places)
    }

    /// Where a timeline's posts are shown, in the source's words: its home and its public ones.
    public static let timelines: Set<String> = ["home", "public"]
}

extension [ServerFilterHit] {
    /// The hit that stands over a post shown in `places` at `now`: a hiding one before a warning,
    /// a warning before a blur — what does the most is what is done.
    public func standing(in places: Set<String>, at now: Date = Date()) -> ServerFilterHit? {
        filter { $0.applies(in: places, at: now) }.min { Self.rank($0.action) < Self.rank($1.action) }
    }

    private static func rank(_ action: ServerFilterAction) -> Int {
        switch action {
        case .hide: 0
        case .warn, .unknown: 1
        case .blur: 2
        }
    }
}

/// One filter of the person's, as the source keeps it.
public struct ServerFilter: Hashable, Sendable, Identifiable {
    public struct Keyword: Hashable, Sendable {
        public let id: String?
        public var keyword: String
        public var wholeWord: Bool

        public init(id: String? = nil, keyword: String, wholeWord: Bool) {
            self.id = id
            self.keyword = keyword
            self.wholeWord = wholeWord
        }
    }

    public let id: String
    public var title: String
    public var context: Set<String>
    public var action: ServerFilterAction
    public var expiresAt: Date?
    public var keywords: [Keyword]
    /// How many posts it names by themselves.
    public var statuses: Int

    public init(
        id: String, title: String, context: Set<String>, action: ServerFilterAction, expiresAt: Date?,
        keywords: [Keyword], statuses: Int = 0
    ) {
        self.id = id
        self.title = title
        self.context = context
        self.action = action
        self.expiresAt = expiresAt
        self.keywords = keywords
        self.statuses = statuses
    }

    /// Every place a filter may apply, in the order a choice lists them.
    public static let places = ["home", "notifications", "public", "thread", "account"]
}

/// A filter as it is to be made or changed: what the person set.
public struct ServerFilterDraft: Hashable, Sendable {
    public var title: String
    public var context: Set<String>
    public var action: ServerFilterAction
    /// How long from now it lasts, in seconds; nothing for for good; `unchanged` for as it is.
    public var lasts: Int?
    /// A lasting a change leaves as the source has it.
    public static let unchanged = -1
    public var keywords: [ServerFilter.Keyword]

    public init(
        title: String, context: Set<String>, action: ServerFilterAction, lasts: Int? = nil,
        keywords: [ServerFilter.Keyword]
    ) {
        self.title = title
        self.context = context
        self.action = action
        self.lasts = lasts
        self.keywords = keywords
    }
}
