import Foundation

/// One file waiting to go with a post: its bytes, what kind they are, the description the person
/// wrote, and the id its source gave it once the upload landed.
///
/// **The bytes stay here until the post lands or is discarded**, so a try that failed part-way
/// can be tried again without asking for the file a second time. A file the source already
/// accepted is not sent again: `remoteID` is what the later try of the post carries.
///
/// Prints as its size. The bytes and the description are the person's, and neither belongs in a log.
public struct UnsentMedia: Identifiable, Hashable, Sendable, CustomDebugStringConvertible {
    public let id: UUID
    public var bytes: Data
    public var mime: String
    public var name: String
    /// The description as typed. Not trimmed: a description over the source's limit is a refusal,
    /// and the words are what the person wrote.
    public var description: String
    /// The id the source gave this file, once it accepted the upload. Nothing until then.
    public var remoteID: String?

    public var debugDescription: String { "\(bytes.count) bytes" }

    public init(
        id: UUID = UUID(), bytes: Data, mime: String, name: String, description: String = "",
        remoteID: String? = nil
    ) {
        self.id = id
        self.bytes = bytes
        self.mime = mime
        self.name = name
        self.description = description
        self.remoteID = remoteID
    }
}

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
    /// The cover line, where one was written. Empty is none.
    public var spoiler: String?
    /// The language, folded as a note's is, or nothing where none was chosen.
    public var language: String?
    /// Whether the post covers its media, where that was chosen. Nothing is not a no.
    public var sensitive: Bool?
    /// The files that go with it, in the order they were added.
    public var media: [UnsentMedia]
    /// The poll it is written with (#331), or nothing. Never beside media: a Mastodon takes no
    /// post with both, and the composer offers one or the other.
    public var poll: NewPoll?

    public init(
        id: UUID = UUID(), host: String, text: String, audience: Audience,
        answers: NoteKey? = nil, root: NoteKey? = nil, pressedAt: Date = Date(), standing: Standing = .fresh,
        writerID: String? = nil, writer: String? = nil, askedAt: Date? = nil,
        spoiler: String? = nil, language: String? = nil, sensitive: Bool? = nil, media: [UnsentMedia] = [],
        poll: NewPoll? = nil
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
        let line = spoiler?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.spoiler = line?.isEmpty == false ? line : nil
        self.language = SourceField.languageTag(language)
        self.sensitive = sensitive
        self.media = media
        self.poll = poll
    }
}

/// The texts a store holds, as one moment of it (`ItemStore.unsentView`).
public struct UnsentView: Sendable {
    /// In the order pressed.
    public let texts: [Unsent]
    /// Who is sending each text that is being sent (`ItemStore.claim`).
    public let senders: [UUID: UUID]
    /// The names let go of this run: landed, discarded, their source removed.
    public let gone: Set<UUID>
    /// The store's `unsentMark` at this moment: a later view has a greater one.
    public let mark: Int
}
