import Foundation

/// Somebody, as a server describes them.
///
/// Asked of a server that has already handed one of their posts over rather than of their own
/// (#88). That is a server the reader added and already reads; their own is not, and opening a
/// person is not a reason to tell their home server that somebody looked.
///
/// So this is one server's account of somebody rather than the truth about them, and the two can
/// differ — a display name changed an hour ago reaches different servers at different times.
/// `authorId` is the one part that does not: an actor URI survives a rename, which is why the
/// store keys people by it and this carries it beside the id it was found under.
public struct Profile: Sendable, Hashable, Identifiable {
    /// The id on the server that was asked, and meaningless on any other. Every request about
    /// this person to *that* server takes it; no request to another server may.
    public let id: String
    /// The actor URI. What this app keys people by, and what two servers agree on.
    public let authorId: String
    public let name: String
    /// `@somebody@their.server`, always qualified, the way a row spells it.
    public let handle: String
    public let avatarURL: URL?
    /// What they wrote about themselves, as words rather than as the markup a server sent.
    public let note: String
    /// The custom emoji their name and their words are partly written in, so a profile draws
    /// the picture where a row would rather than the shortcode.
    public let emojis: [CustomEmoji]

    /// Three counts, and **nil is not zero** (S5). A server that did not say leaves these
    /// unanswered, and a screen that drew `0` for one of them would be making something up
    /// about how many people somebody knows.
    public let posts: Int?
    public let followers: Int?
    public let following: Int?
    /// When the account was made, where the server said. Nothing where it did not.
    public let joined: Date?

    /// Whether they approve their followers by hand. A follow of one of these is a request that
    /// somebody has to answer, and a control that said "following" the moment it was pressed
    /// would be claiming an answer nobody has given.
    public let locked: Bool

    public init(id: String, authorId: String, name: String, handle: String, avatarURL: URL? = nil,
                note: String = "", emojis: [CustomEmoji] = [], posts: Int? = nil,
                followers: Int? = nil, following: Int? = nil, joined: Date? = nil,
                locked: Bool = false) {
        self.id = id
        self.authorId = authorId
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.note = note
        self.emojis = CustomEmoji.folded(emojis)
        self.posts = posts
        self.followers = followers
        self.following = following
        self.joined = joined
        self.locked = locked
    }
}

/// What the reader is to somebody, as the reader's own server has it.
///
/// There is nowhere else it could come from. A relationship is a fact about an account, this app
/// reads a great many servers nobody here has an account on, and the server that handed a post
/// over has no idea who is reading it. So this is asked of `acting(on:)`'s account and of nothing
/// else — and where the reader has no account anywhere, there is no answer rather than a false one.
///
/// Every field is a plain `Bool` and not an optional, because the endpoint answers about all of
/// them at once: a relationship this server did not mention is one it says is not there. That is
/// different from a count, which a server may simply decline to publish.
public struct Relationship: Sendable, Hashable {
    public let following: Bool
    public let followedBy: Bool
    /// Asked and not yet answered, which only a `locked` account can leave anybody in. It is
    /// neither following nor not: a control that drew it as either would be answering for
    /// somebody who has not.
    public let requested: Bool
    public let muting: Bool
    public let blocking: Bool

    public init(following: Bool = false, followedBy: Bool = false, requested: Bool = false,
                muting: Bool = false, blocking: Bool = false) {
        self.following = following
        self.followedBy = followedBy
        self.requested = requested
        self.muting = muting
        self.blocking = blocking
    }

    /// What a control says it will do next. `requested` is not "following" and pressing it again
    /// is a withdrawal, which Mastodon takes on the same `unfollow` it takes for a real one.
    public var isOn: Bool { following || requested }
}

/// A list of people, and which list it is.
///
/// The two are one screen with one difference, and the difference is worth naming rather than
/// carrying as a `Bool`: a caller writing `people(true, of:)` is a caller nobody can read.
public enum People: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// The people this person follows.
        case following
        /// The people who follow them.
        case followers

        public var id: String { rawValue }
        /// What Mastodon calls it in an address. The same word, and said here so that a screen
        /// naming the list and a request asking for it cannot come to disagree.
        public var path: String { rawValue }
    }

    /// Why a list is empty, which is not a thing a list can say about itself.
    ///
    /// Somebody who has asked their server not to publish their network is answered with an empty
    /// array and a 200, exactly as somebody who follows nobody is — the endpoint cannot tell them
    /// apart and neither can the profile. What can is the count beside it: a server that publishes
    /// *89 followers* and then hands over none of them has been told not to.
    ///
    /// S5 lives here. Drawing "nobody" over a hidden list would be this app inventing a fact about
    /// somebody, and drawing "hidden" over a genuinely empty one would be inventing a different
    /// one — so a count nobody sent leaves this `unknown` rather than picking.
    public enum Reason: Sendable, Hashable {
        /// There are people, and here they are.
        case some
        /// The server published a count above zero and handed over nobody: they have chosen not
        /// to publish this list.
        case withheld
        /// The server published a count of zero, so the list is empty because it is empty.
        case none
        /// No count was sent, so why the list is empty is not something this device knows.
        case unknown
    }

    /// Which of the four an empty list is, given what the profile says about it.
    public static func reason(forEmpty kind: Kind, on profile: Profile?) -> Reason {
        let count = kind == .following ? profile?.following : profile?.followers
        guard let count else { return .unknown }
        return count > 0 ? .withheld : .none
    }
}
