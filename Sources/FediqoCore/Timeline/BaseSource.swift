import Foundation

/// What a timeline is built on: the one thing a server is asked for, before any rule of the
/// reader's is applied to what came back.
///
/// The three are rows in the store's `feeds` table as well as cases here, and a test holds
/// the two lists identical — the rows are what a `timelines` row points at, and adding a
/// fourth (a server's hashtag timeline, a server's list) is a row and a case, never a column.
///
/// **Order lives here**, and that is the whole reason `ranked` is a property of the source
/// rather than of a timeline. #6 says every timeline is in timestamp order and that nothing
/// in the app can change that; a server's trending list is the one thing handed over already
/// ordered, and sorting somebody else's ranking by time would throw away the only thing it
/// was carrying. So the reader has no switch for it and a rule cannot reach it: what decides
/// is which of these a timeline was built on.
/// Which writers a public timeline is asked for.
///
/// `/api/v1/timelines/public` answers with everything a server sees — its own writers and
/// everything that reached it from elsewhere. Mastodon lets that be cut two ways, and both are
/// questions a person actually asks (#113):
///
/// - **`here`** is the room itself: who is on this server, what this place is like. It is how
///   somebody decides whether they want to join, and how somebody who has joined keeps up with
///   their neighbours.
/// - **`elsewhere`** is what the wider network is saying without the server's own conversation
///   on top of it.
///
/// **Not a base source.** It does not change where the posts come from, only which of them the
/// server is asked for — so `feeds` gains no row, `post_origins` still records `public`, and a
/// post that arrived this way arrived by the public timeline, which is the truth.
///
/// Nothing but `public` is asked this. A home timeline is already one account's, a trending list
/// is the server's own, and a conversation is one post's — none of them has a room to be cut out
/// of, so the question is not asked and `everyone` is what they carry.
public enum Writers: String, Sendable, Hashable, CaseIterable, Codable {
    /// Everything the server sees. What `public` has always meant, and what a timeline written
    /// down before this existed still means.
    case everyone
    /// Only the accounts on this server.
    case here
    /// Everything except them.
    case elsewhere

    /// The query Mastodon knows this by, or nothing where the whole timeline is wanted.
    ///
    /// Spoken here rather than in the client for the reason `max_id` is spoken in the client and
    /// not here: this is the *name of the cut*, which every protocol will need a word for, and
    /// `local` is Mastodon's word. When a second protocol arrives it says its own.
    public var mastodonQuery: (name: String, value: String)? {
        switch self {
        case .everyone: nil
        case .here: ("local", "true")
        case .elsewhere: ("remote", "true")
        }
    }
}

public enum BaseSource: String, Sendable, CaseIterable, Identifiable, Codable {
    /// What the server publishes to anyone — read as whoever is signed in where there is
    /// somebody, which is still the public timeline and never substituted for by anything else.
    case `public`
    /// What the server shows the account signed in to it, and nothing without one.
    case home
    /// What the server says is rising, in the order it said it.
    case trend
    /// The conversation around one post, asked for when a reader opens it.
    ///
    /// Not a timeline anybody can build: no template offers it, and there is nothing to page
    /// through. It is here because posts arrive this way and an arrival has to be able to say
    /// how it arrived — `post_origins` keeps a source for every one of them.
    case thread
    /// A post somebody aimed at the reader, which arrived inside a notification.
    ///
    /// Here for the same reason `thread` is: posts arrive this way, and an arrival has to be
    /// able to say how it arrived. No template offers it either — an inbox is not a stretch of
    /// time somebody can page through, and a post missing from one is not evidence of anything.
    case notice
    /// What one person has written, asked for when a reader opens them (#88).
    ///
    /// The third with no template, for the reason the two above have none: posts arrive this
    /// way and an arrival has to be able to say how it arrived, but nobody can build a
    /// timeline out of it. #1 does promise a timeline "by author" — one a reader names, orders
    /// and gives rules to — and this is not that promise being kept. It is the narrower thing
    /// a page about somebody needs: an origin for the posts on it.
    case author

    public var id: String { rawValue }

    /// Whether the source hands its posts over already ordered, and that order is kept.
    public var ranked: Bool { self == .trend }

    /// Whether there is nothing to read here without a credential. A server nobody is signed
    /// in to cannot be asked for `home` at all — not as a stranger, not with anything else
    /// quietly put in its place. An inbox is the same: it belongs to somebody, and there is no
    /// anonymous reading of what was aimed at a person.
    public var needsAccount: Bool { self == .home || self == .notice }

    /// Whether a page from here is a stretch of time, and so can be evidence that a post the
    /// store holds has gone. A trending list is a snapshot somebody curated and a conversation
    /// is a shape of its own: neither covers a stretch, neither leaves anything out of one,
    /// and neither pages anywhere.
    ///
    /// **`author` is a stretch of time and is still not counted as one.** A page of somebody's
    /// posts really is chronological and really does leave out what they deleted — the evidence
    /// is there. What is not there yet is the certainty that `suspectMissing` reads it against
    /// the right stretch, and the cost of being wrong is this app deciding somebody's post is
    /// gone when it is not. A post the author deleted waits for rotation instead, which is what
    /// a post seen only in a thread already does.
    public var isThreadOfTime: Bool { self == .public || self == .home }
}
