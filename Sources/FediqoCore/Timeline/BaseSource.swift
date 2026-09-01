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
    public var isThreadOfTime: Bool { self == .public || self == .home }
}
