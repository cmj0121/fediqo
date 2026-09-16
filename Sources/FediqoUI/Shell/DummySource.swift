/// What kind of source this is. The protocol stays behind; the timeline sees a shape.
public enum DummySourceKind: String, Sendable, Hashable {
    case microblog
    case forum
    /// **Not a shape a protocol has — a query inside a source.** No host answers "board" to
    /// "what do you speak"; a reader picked one section out of a forum and this is the row that
    /// draws that. `DummySource.board` builds one and `DummyItemRow` asks for it twice.
    /// `DummyItem.shape(of:)` must never return it: a whole host drawn as one section of itself
    /// is the same silent wrong answer as a forum drawn as microblog posts.
    case board
    /// A source whose posts are films.
    ///
    /// **Provisional, and unreachable in this milestone.** `shape(of:)` answers `.peertube` with
    /// it, and `.peertube` is refused at every join door with `unsupportedKind`, so nothing can
    /// build a `.video` source yet. The point of adding it early is that it broke every switch
    /// over this type **on the day it was added**, while the answers were cheap and provisional,
    /// rather than leaving `.microblog` sitting in those places as a plausible answer nothing
    /// would ever break on. Those switches now answer, so the unit adding PeerTube is not stopped
    /// by the compiler here — it is stopped by its own brief, and by the word *provisional* on
    /// each of the three answers.
    case video
}

/// A server this dummy timeline reads. An account is present only after sign-in.
public struct DummyAccount: Hashable, Sendable {
    public let displayName: String
    public let handle: String
}

public struct DummySource: Identifiable, Hashable, Sendable {
    public let id: String
    public let host: String
    public let kind: DummySourceKind
    public let account: DummyAccount?

    public var isSignedIn: Bool { account != nil }

    /// A source nobody is signed in to.
    ///
    /// **No default on the kind, on purpose**, for the same reason `RemoteImage.tier` has none:
    /// a `.microblog` default is the right answer for most call sites and a silent wrong one for
    /// the rest, and the rest are the whole point — every joined forum, Discourse and Discuz!
    /// alike, drew with the globe icon because one call site said nothing and the default
    /// answered for it. Fixing that call site fixes today's globe; deleting the default fixes
    /// every call site not yet written. The compiler asks instead.
    public static func unsigned(_ host: String, kind: DummySourceKind) -> DummySource {
        DummySource(id: host, host: host, kind: kind, account: nil)
    }

    public static let unsignedPublic = DummySource(
        id: "first.example",
        host: "first.example",
        kind: .microblog,
        account: nil
    )

    public static let signedIn = DummySource(
        id: "second.example",
        host: "second.example",
        kind: .microblog,
        account: DummyAccount(displayName: "You", handle: "@you@second.example")
    )

    public static let forum = DummySource(
        id: "forum.example",
        host: "forum.example",
        kind: .forum,
        account: nil
    )

    public static let board = DummySource(
        id: "board.example",
        host: "board.example",
        kind: .board,
        account: nil
    )
}
