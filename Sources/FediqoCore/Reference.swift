import Foundation

/// One thing an item refers to (#290, #293): another item on the same source, and what kind of
/// reference it is — this answers that, this quotes that, this reblogs that.
///
/// **By ID, as far as the source has said one.** A reference's target is an item, and an item's
/// ID is `Note.id`. But a source does not always say it: what a post answers is named by the
/// source's own id for it (`statusID`), which is a different string for the same post, and the
/// target's ID is then known only once the target itself has been read. So a reference carries
/// both, either of which may be missing, and at least one of which a reference worth keeping has.
///
/// **What belongs to the reference rides on it, and nothing of the target does.** Whom an answer
/// is to, as its source said, and where a quote stands, are facts about this item's saying so.
/// The target's words, author and time are the target's own item's.
///
/// **A new kind is a new migration**, for `CategoryRow`'s reason: a build that does not know a
/// kind cannot keep it, so it must refuse the store rather than save the row back without it.
public struct Reference: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case answers
        case quotes
        case reblogs
    }

    public let kind: Kind
    /// The target's `Note.id`, where known.
    public let id: String?
    /// What the source itself calls the target — `Note.statusID`'s spelling — where it said.
    public let statusID: String?
    /// Whom an answer is to, as the source named them (`Reply.handle`). Nothing on other kinds.
    public let handle: String?
    /// Where a quote stands (`Quote.state`). Nothing on other kinds.
    public let state: Quote.State?

    public init(
        kind: Kind, id: String? = nil, statusID: String? = nil, handle: String? = nil, state: Quote.State? = nil
    ) {
        self.kind = kind
        self.id = id
        self.statusID = statusID
        self.handle = kind == .answers ? handle : nil
        self.state = kind == .quotes ? state : nil
    }

    /// How many references an item may carry. A status says at most one of each kind; this is
    /// room to spare, and a ceiling on what a stored or carried row can make an item hold.
    public static let most = 8
    /// How long any one name in a reference may be, in the bytes it is written in: an address, an
    /// id, a handle. **Bytes and not characters**: one character can be a letter under any
    /// number of combining marks, so a count of characters bounds nothing.
    public static let longest = 2_048

    /// `references` as an item may hold them: none with a name longer than a name is, no more
    /// than `most`, and none said twice. Held to this wherever a note is made — off the wire,
    /// back from the store, in a test — as `Note.language` is held to what a tag looks like.
    public static func bounded(_ references: [Reference]) -> [Reference] {
        var kept: [Reference] = []
        for reference in references where kept.count < most {
            let names = [reference.id, reference.statusID, reference.handle]
            guard names.allSatisfy({ ($0?.utf8.count ?? 0) <= longest }), !kept.contains(reference) else { continue }
            kept.append(reference)
        }
        return kept
    }

    /// What an item's `reply` and `quote` say it refers to — the two an item says today.
    ///
    /// **A boost is not among them.** A post that arrived as a boost is, today, the post itself
    /// with a line saying who boosted it (`Note.boostedBy`): there is no item that is the boost,
    /// so nothing here refers by reblogging. That changes when a reblog becomes an item (#290).
    public static func derived(reply: Reply?, quote: Quote?) -> [Reference] {
        var references: [Reference] = []
        if let reply {
            references.append(Reference(kind: .answers, statusID: reply.inReplyToId, handle: reply.handle))
        }
        if let quote {
            references.append(Reference(kind: .quotes, id: quote.post?.id, statusID: quote.statusID, state: quote.state))
        }
        return references
    }
}

extension Reply {
    /// The reply an `answers` reference says, or nothing for any other kind.
    public init?(_ reference: Reference) {
        guard reference.kind == .answers else { return nil }
        self.init(handle: reference.handle, inReplyToId: reference.statusID)
    }
}

extension Quote {
    /// The quote a `quotes` reference says — its state and which post — or nothing for any other
    /// kind. **Without the quoted post's copy**: that is the target's content, which a reference
    /// does not carry.
    public init?(_ reference: Reference) {
        guard reference.kind == .quotes else { return nil }
        self.init(state: reference.state ?? .unknown, statusID: reference.statusID)
    }
}

extension Note {
    /// Whether this item is a reblog: it refers to another by reblogging it. No item is, until
    /// a reblog is an item of its own (#290).
    public var isReblog: Bool { refs.contains { $0.kind == .reblogs } }
}
