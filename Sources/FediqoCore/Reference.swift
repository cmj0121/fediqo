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

    /// Whether the target's source said it no longer exists when it was asked for (#293): gone,
    /// which is said where the reference is shown and never asked about again. A fact of this
    /// item's reference, learned once; nothing of the target is kept to remember it by.
    public let gone: Bool

    public init(
        kind: Kind, id: String? = nil, statusID: String? = nil, handle: String? = nil, state: Quote.State? = nil,
        gone: Bool = false
    ) {
        self.kind = kind
        self.id = id
        self.statusID = statusID
        self.handle = kind == .answers ? handle : nil
        self.state = kind == .quotes ? state : nil
        self.gone = gone
    }

    /// This reference with its target named, or said to be gone.
    func settled(id: String? = nil, gone: Bool = false) -> Reference {
        Reference(kind: kind, id: id ?? self.id, statusID: statusID, handle: handle, state: state, gone: gone || self.gone)
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
    /// **A reblog is not among them.** That an item reblogs another is said by nothing but its
    /// reference (#290) — a reblog has no `reply` or `quote` to say it with — so it is carried
    /// from note to note by name (`carried`), and never worked out again.
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

extension Reference {
    /// The references a note made anew from one that held `held` carries, where the new note's
    /// `reply` and `quote` are these (#290): what those two state, and **every reference of
    /// `held` that they cannot state** — a reblog's. Each place a note is rebuilt from another
    /// names its references this way, so one that `reply` and `quote` cannot re-derive survives a
    /// reload, a read again, a revision and the reader-marks sweep.
    ///
    /// **And the target's name, where a load found it** (#293). What an item answers is named by
    /// its source's own id until the post itself has been read; once it has, the reference
    /// carries the post's `Note.id` too, and that is not in `reply` to be worked out again. So a
    /// reference `held` had named is still named, where it is still the same reference.
    public static func carried(_ held: [Reference], reply: Reply?, quote: Quote?) -> [Reference] {
        derived(reply: reply, quote: quote).map { fresh in
            guard fresh.id == nil, let statusID = fresh.statusID,
                  let known = held.first(where: { $0.kind == fresh.kind && $0.statusID == statusID && ($0.id != nil || $0.gone) })
            else { return fresh }
            return fresh.settled(id: known.id, gone: known.gone)
        } + held.filter { $0.kind == .reblogs }
    }
}

extension ProtocolKind {
    /// Whether what an item of this kind of source refers to is loaded for it (#293). A
    /// Mastodon's, and no other's: #293 is about no other source.
    public var loadsReferences: Bool { self == .mastodon }
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
    /// Whether this item is a reblog (#290): it refers to another by reblogging it. It says who
    /// reblogged and when, and nothing of its own besides — its words, pictures, counts and what
    /// the reader did are the reblogged item's.
    public var isReblog: Bool { refs.contains { $0.kind == .reblogs } }

    /// The item this one reblogs, as the store keys it, or nothing for anything but a reblog —
    /// and for a reblog whose source named its target by the source's own id alone.
    ///
    /// **Within this item's own source, always.** A reference's id is a name, and it is looked
    /// up among what this source handed over; it is never an address to ask.
    public var reblogKey: NoteKey? {
        refs.first { $0.kind == .reblogs }?.id.map { NoteKey(host: source.host, id: $0) }
    }

    /// The id a request about this item is made with, at its source: `statusID`, **and nothing
    /// for a reblog** (#290). A reblog's `statusID` is the id its source gave the reblog; it is
    /// kept on the note because it is what tells a name this device made up from one a server
    /// minted (`Note.post`), and it is never what the reader means to act on, read again or
    /// answer — that is the post, which has an id of its own on its own item. Every place that
    /// puts an id into a request reads this and not `statusID`.
    public var sendableID: String? { isReblog ? nil : statusID }

    /// The items held for as long as this one is, whatever their own age: the post it quotes
    /// (#214) and the post it reblogs (#290). What the limits leave while this item stays.
    ///
    /// **And the post it answers, once that post was loaded for it** (#293): the reference then
    /// names it, and a post fetched because this item arrived is not let go from under it.
    var heldWith: [NoteKey] {
        var keys = [quotedKey, reblogKey].compactMap { $0 }
        for reference in refs where reference.kind != .reblogs {
            if let id = reference.id { keys.append(NoteKey(host: source.host, id: id)) }
        }
        return keys
    }

    /// What this item would have loaded for it (#293): the source's own id of each post it
    /// refers to that could be asked for by that id — the post it answers, and a post it quotes
    /// that did not come with it. **Never a reblog's target**: that comes in the reblog's own
    /// payload or not at all, and a reference to it is not a thing to ask for.
    ///
    /// **Only what could be asked for.** A reference already named or said to be gone is
    /// settled. And an id that is no path segment — which is all a request for one post can be
    /// made of — is nothing to ask for, so such a reference owes nothing: it is left out here,
    /// at the door, and never takes a place in a source's line.
    public var askable: [(kind: Reference.Kind, statusID: String)] {
        refs.compactMap { reference in
            guard let statusID = reference.statusID, reference.id == nil, !reference.gone,
                  ListSubscription.isPathSegment(statusID)
            else { return nil }
            switch reference.kind {
            case .answers: return (.answers, statusID)
            case .quotes: return reference.state == .accepted ? (.quotes, statusID) : nil
            case .reblogs: return nil
            }
        }
    }

    /// Whether this row, held from before a reblog was an item of its own, says it arrived as
    /// the reblog `reblog` is: by the same person, as far as the row wrote down who.
    func arrived(asReblogBy reblog: Note) -> Bool {
        guard boostedBy != nil else { return false }
        if let boosterHandle { return Fold.handle(boosterHandle) == Fold.handle(reblog.handle) }
        return boostedBy == reblog.author
    }
}
