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

    public var id: String { rawValue }

    /// Whether the source hands its posts over already ordered, and that order is kept.
    public var ranked: Bool { self == .trend }

    /// Whether there is nothing to read here without a credential. A server nobody is signed
    /// in to cannot be asked for `home` at all — not as a stranger, not with anything else
    /// quietly put in its place.
    public var needsAccount: Bool { self == .home }

    /// Whether a page from here is a stretch of time, and so can be evidence that a post the
    /// store holds has gone. A trending list is a snapshot somebody curated: it covers no
    /// stretch, leaves nothing out of one, and pages nowhere.
    public var isThreadOfTime: Bool { self != .trend }
}
