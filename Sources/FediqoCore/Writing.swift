// What may be done on a source, and the one place that decides it (#69).
//
// Two questions live here because they are two questions and were being answered as one: *what
// did this reader agree to* is about a sign-in, and *what may be done on this source* is about a
// protocol, a sign-in and whatever the server has said since. A source with no sign-in and a
// forum that could not write whatever its reader agreed to are the same sentence on a row and
// are not the same fact.

/// What one Mastodon sign-in bought.
///
/// **`unasked` is a real state and not a missing one.** A token kept before this app asked about
/// writing carries no scopes, and a reader who was offered the writing part and refused it carries
/// the reading scopes written down. Both read and neither writes — and only the first is owed the
/// question, which is the whole reason the two are not one case.
public enum MastodonGrant: Sendable, Equatable, CaseIterable {
    /// Kept before a sign-in asked about writing. Reads exactly as it did; has never been asked.
    case unasked
    /// Reading, asked for and agreed to. The writing part was not taken.
    case reading
    /// Reading and writing.
    case writing

    /// What a token's recorded scopes say it is.
    public static func of(scopes: String?) -> MastodonGrant {
        guard scopes != nil else { return .unasked }
        return MastodonOAuth.writes(scopes) ? .writing : .reading
    }
}

extension MastodonToken {
    /// What this sign-in bought, from what it wrote down.
    public var grant: MastodonGrant { MastodonGrant.of(scopes: scopes) }
}

/// What may be done on one source, in the four states a row can say.
///
/// **`never` and `reads` are kept apart although both mean nothing is written.** A Discuz! cannot
/// be written from this app whatever anybody agrees to; a Mastodon read-only sign-in is a choice
/// its reader made and can make differently. Folded into one case, a row would tell a Mastodon
/// reader their protocol cannot write, which is untrue, or tell a forum reader to sign in again
/// for something that is not there.
public enum SourceWriting: Sendable, Equatable, CaseIterable {
    /// Read only, because this protocol has no writing here at all.
    case never
    /// Read. Writing was not asked for, was refused, or there is no sign-in to carry it.
    case reads
    /// Read and write.
    case writes
    /// The writing part was bought and the source turned a write away. **Marked until it is signed
    /// in again**, because nothing this device holds can tell whether the refusal was the token,
    /// the account or the server's mind, and a row that went on claiming writing would be lying
    /// about the next press.
    case refused

    /// What a row says about one source: its protocol, what its sign-in bought, and whether a
    /// write has been turned away since.
    ///
    /// `grant` is nothing where this device holds no sign-in for the source, which is a Mastodon
    /// read on the public timeline and is `reads`.
    public static func of(kind: ProtocolKind, grant: MastodonGrant?, refused: Bool) -> SourceWriting
    {
        guard kind.canWrite else { return .never }
        guard grant == .writing else { return .reads }
        return refused ? .refused : .writes
    }
}

/// One thing a reader does to a post on the source they read it through — #54's acts, named so
/// that the rule about which of them a post offers is a value rather than a run of conditions
/// inside a view body.
///
/// **`CaseIterable` so the offering can be asserted over all of them** rather than over the ones
/// somebody remembered: an act added here and left out of `PostActs.on` is then a test that
/// stops, which is `DummyAudience`'s reason for the same conformance.
public enum PostAct: Sendable, Hashable, CaseIterable {
    /// Carried onward to whoever follows the reader on that source (#106).
    case boost
    /// A note to the author and to oneself, kept on that source (#107).
    case favourite
    /// Words written back to the post, from inside the conversation it belongs to (#108).
    case answer
}

/// Why a post offers none of the acts. Nothing is a post that offers them.
///
/// **Four reasons and not one silence**, because each sends the reader somewhere different: three
/// are about the source and one is about this row alone, and a row that said "cannot" for all
/// four would be telling a Mastodon reader to give up where signing in again is the whole answer.
public enum PostActRefusal: Sendable, Hashable, CaseIterable {
    /// This protocol has no writing here at all. Nothing the reader does changes it.
    case protocolCannot
    /// There is no sign-in carrying the writing part. Signing in again is what changes it.
    case notSignedIn
    /// The writing part was bought and the source turned a write away since.
    case turnedAway
    /// This device cannot name the post on its own server, so there is nothing to point an act
    /// at — a row kept before its server id was, and every forum post.
    case unnameable
}

/// What may be done to one post, and why not where nothing may.
///
/// **The two halves are one value on purpose.** "Which marks are drawn" and "what the row says
/// instead" are one question with one answer, and the milestone has already shipped three
/// controls whose *whether* and whose *what* were decided in two places — see
/// `DummyItem.outwardURL`, which says so at length. Answered here, both can be asserted without
/// standing a view up.
public struct PostActs: Sendable, Hashable {
    /// The acts this post offers. Empty where `refused` says why.
    public let offered: Set<PostAct>
    /// Why the acts are absent, where they are. Nothing where they are there to press.
    public let refused: PostActRefusal?

    public init(offered: Set<PostAct>, refused: PostActRefusal? = nil) {
        self.offered = offered
        self.refused = refused
    }

    public func offers(_ act: PostAct) -> Bool { offered.contains(act) }

    /// What a post read through a source with this standing offers.
    ///
    /// `nameable` is whether this device can point at the post on its own server — `Note.statusID`
    /// present. It is asked last, because a forum row is `.never` before it is unnameable and the
    /// reader is owed the reason that is about their source rather than the one about our
    /// bookkeeping.
    ///
    /// **No `default:`**, this package's standing rule: a fifth `SourceWriting` has to say what a
    /// post on such a source offers.
    public static func on(_ writing: SourceWriting, nameable: Bool) -> PostActs {
        switch writing {
        case .never: return PostActs(offered: [], refused: .protocolCannot)
        case .reads: return PostActs(offered: [], refused: .notSignedIn)
        case .refused: return PostActs(offered: [], refused: .turnedAway)
        case .writes:
            guard nameable else { return PostActs(offered: [], refused: .unnameable) }
            return PostActs(offered: Set(PostAct.allCases))
        }
    }

    /// A post nothing may be done to and nothing to say about it: a fixture, a preview, a row in
    /// a list that is not the reader's own timeline.
    public static let none = PostActs(offered: [], refused: nil)
}
