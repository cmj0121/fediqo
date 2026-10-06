import Foundation
@testable import FediqoCore

// **For tests only.** Since #293 an item says what it refers to by its references alone, and
// `Note.init` takes those and nothing else. The tests written before that say a reply and a quote
// the old way — `reply:` and `quote:` — and this is what reads them: one initialiser that turns
// the two into the references the source's own decode builds, and hands the quoted post over
// beside the note, as that decode does. So those tests go on describing a post in their own
// words, and what they assert is asserted of the same note a status would have made.
extension Note {
    init(
        id: String,
        source: Source,
        author: String,
        handle: String,
        body: String,
        title: String? = nil,
        board: String? = nil,
        postedAt: Date,
        categories: Set<FediqoCore.Category>,
        reply: Reply?,
        boostedBy: String? = nil,
        boosterHandle: String? = nil,
        boosted: Bool? = nil,
        favourited: Bool? = nil,
        bookmarked: Bool? = nil,
        audience: Audience? = nil,
        avatarURL: URL? = nil,
        attachments: [Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil,
        counts: Counts = Counts(),
        statusID: String? = nil,
        opening: ForumOpening? = nil,
        goneSince: Date? = nil,
        gaps: Set<TimelineGap> = [],
        listed: [FediqoCore.Category: String] = [:],
        quote: Quote? = nil,
        kept: Bool = false,
        editedAt: Date? = nil,
        earlier: [Wording] = [],
        language: String? = nil,
        refs: [Reference]? = nil,
        refsDue: Bool = false
    ) {
        self.init(
            id: id, source: source, author: author, handle: handle, body: body, title: title, board: board,
            postedAt: postedAt, categories: categories, boostedBy: boostedBy, boosterHandle: boosterHandle,
            boosted: boosted, favourited: favourited, bookmarked: bookmarked, audience: audience,
            avatarURL: avatarURL, attachments: attachments, sensitive: sensitive, spoiler: spoiler,
            emojis: emojis, url: url, counts: counts, statusID: statusID, opening: opening,
            goneSince: goneSince, gaps: gaps, listed: listed, kept: kept, editedAt: editedAt,
            earlier: earlier, language: language,
            refs: refs ?? Self.references(reply: reply, quote: quote), refsDue: refsDue
        )
        brought = quote?.post.map { [$0.note(through: source)] } ?? []
    }

    /// The same, for a note that says a quote and no reply.
    init(
        id: String,
        source: Source,
        author: String,
        handle: String,
        body: String,
        title: String? = nil,
        board: String? = nil,
        postedAt: Date,
        categories: Set<FediqoCore.Category>,
        boostedBy: String? = nil,
        boosterHandle: String? = nil,
        boosted: Bool? = nil,
        favourited: Bool? = nil,
        bookmarked: Bool? = nil,
        audience: Audience? = nil,
        avatarURL: URL? = nil,
        attachments: [Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil,
        counts: Counts = Counts(),
        statusID: String? = nil,
        opening: ForumOpening? = nil,
        goneSince: Date? = nil,
        gaps: Set<TimelineGap> = [],
        listed: [FediqoCore.Category: String] = [:],
        quote: Quote?,
        kept: Bool = false,
        editedAt: Date? = nil,
        earlier: [Wording] = [],
        language: String? = nil,
        refs: [Reference]? = nil,
        refsDue: Bool = false
    ) {
        self.init(
            id: id, source: source, author: author, handle: handle, body: body, title: title, board: board,
            postedAt: postedAt, categories: categories, reply: nil, boostedBy: boostedBy,
            boosterHandle: boosterHandle, boosted: boosted, favourited: favourited, bookmarked: bookmarked,
            audience: audience, avatarURL: avatarURL, attachments: attachments, sensitive: sensitive,
            spoiler: spoiler, emojis: emojis, url: url, counts: counts, statusID: statusID, opening: opening,
            goneSince: goneSince, gaps: gaps, listed: listed, quote: quote, kept: kept, editedAt: editedAt,
            earlier: earlier, language: language, refs: refs, refsDue: refsDue
        )
    }

    /// The post this copy's source handed over beside it as the one it quotes (`brought`), under
    /// the name the tests written before #293 ask for it by.
    var quotedNote: Note? { brought.first }

    /// What a status that answers `reply` and quotes `quote` refers to, as its decode says it.
    static func references(reply: Reply?, quote: Quote?) -> [Reference] {
        [
            reply.map { Reference.answers($0.inReplyToId, to: $0.handle) },
            quote.map { Reference.quotes($0.state, id: $0.post?.id, statusID: $0.statusID) },
        ].compactMap { $0 }
    }
}
