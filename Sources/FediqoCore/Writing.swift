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
