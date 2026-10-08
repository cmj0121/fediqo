import Foundation

/// A post or an answer the person pressed to send, held until its source says it landed or the
/// person discards it.
///
/// **The person's own words, and this device's alone**: no source can say them again, so they
/// are held from the press — in the store, and on disk before the request leaves — and are let
/// go only by a landing or by the person. Nothing here is an item (#282): it has no ID of its
/// source's and no publish time until the source gives it both, and then it is a post like any
/// other and this goes.
///
/// **Tied to who wrote it** (`writerID`, `writer`): the account at its source that was signed
/// in at the press. It is sent, and sent again, only as that account — never under whoever is
/// signed in at that host when its turn comes, in this run or a later one.
///
/// **Never sent again by itself.** What is held says whether its source was asked (`Standing`),
/// so a run that finds one from before knows whether it may have landed, and asks the person.
public struct Unsent: Hashable, Sendable, Identifiable {
    /// What is known of the last try, as it is written down.
    public enum Standing: String, Sendable {
        /// Pressed, and its source not asked yet.
        case fresh
        /// The request was about to leave, or left: it may have landed.
        case asked
        /// The source answered, and said this sign-in may not.
        case refused
        /// Nothing was sent, or nothing answered.
        case unreachable
        /// The source answered, and did not take it.
        case declined
    }

    /// Its name here, and the `Idempotency-Key` every request for it carries: sent again, a
    /// source that honours the key answers with the post it already made.
    public let id: UUID
    /// The folded host of the source it was written for.
    public let host: String
    public var text: String
    public var audience: Audience
    /// The post answered; nothing for a post.
    public let answers: NoteKey?
    /// The post the conversation it was written from is about; nothing for a post.
    public let root: NoteKey?
    public let pressedAt: Date
    public var standing: Standing
    /// Who wrote it, by the id its source gives that account, and their handle there as
    /// `@user@host`. Nothing where the source had not yet said who was signed in at the press;
    /// filled in when it does, while the sign-in is still the one it was pressed under.
    public var writerID: String?
    public var writer: String?
    /// When its source was first asked: no post published before this can be it, and the key
    /// it was sent under is only kept by a source for so long after.
    public var askedAt: Date?

    public init(
        id: UUID = UUID(), host: String, text: String, audience: Audience,
        answers: NoteKey? = nil, root: NoteKey? = nil, pressedAt: Date = Date(), standing: Standing = .fresh,
        writerID: String? = nil, writer: String? = nil, askedAt: Date? = nil
    ) {
        self.writerID = writerID
        self.writer = writer
        self.askedAt = askedAt
        self.id = id
        self.host = host.lowercased()
        self.text = text
        self.audience = audience
        self.answers = answers
        self.root = root
        self.pressedAt = pressedAt
        self.standing = standing
    }
}
