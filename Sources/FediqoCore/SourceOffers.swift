import Foundation

// What a kind of source offers, said once (#299).
//
// A screen that offers a choice — which categories a rule may name, which fields, for which
// sources — reads it here and does not decide by knowing which kind of source it is talking
// to. Every fact below was a predicate of its own on `ProtocolKind`, each a list of kinds;
// those predicates are now readers of this one value, so a kind added later is answered in one
// place and cannot be answered two ways.

/// What one kind of source offers: the categories it serves, the fields it names, and what its
/// answers say.
///
/// **Data, and nothing else.** Making one asks nobody anything: no request, no read of a
/// sign-in. What depends on the particular source — the boards and lists chosen on it — and on
/// the sign-in of the moment is handed in by whoever holds those (`categories(of:signedIn:)`),
/// so the value itself is the same for every source of one kind, at every moment.
public struct SourceOffers: Hashable, Sendable {
    /// Whether it has the timelines every microblog shares: a public one, and for a signed-in
    /// reader Home and their lists. So `.public`, `.home` and a list can mean this source.
    public let timelines: Bool
    /// Whether it has something rising — a microblog's trending posts, a forum's ranking
    /// lists — so `.trends` can mean this source.
    public let trends: Bool
    /// Whether what it serves is divided into boards the reader picks: a forum's. So a board
    /// can mean this source.
    public let boards: Bool
    /// Whether its authors are its own and nobody else's: the same name on another source of
    /// this kind is somebody else, so a rule on one of its authors is for this source alone.
    public let authorsAreItsOwn: Bool
    /// Whether this app can write to it at all (#69) — given a sign-in that may.
    public let writes: Bool
    /// The fields it says of an item beyond the ones every source has (#287), in the order they
    /// are offered. None for a kind that declares none.
    public let fields: [SourceField]
    /// Whether what an item of it refers to is loaded for the item (#293).
    public let loadsReferences: Bool
    /// Whether it says what its signed-in reader has done to a post (#285).
    public let saysReaderMarks: Bool
    /// Whether a post read from it says whether it quotes one (#214): a read that says nothing
    /// of a quote is then a post with none, not a source that never said.
    public let saysQuotes: Bool
    /// Whether it says what happened to its signed-in reader (#323) — who answered, boosted,
    /// favoured or followed them — so the notices page can ask this source.
    public let notices: Bool

    public init(
        timelines: Bool = false, trends: Bool = false, boards: Bool = false, authorsAreItsOwn: Bool = false,
        writes: Bool = false, fields: [SourceField] = [], loadsReferences: Bool = false,
        saysReaderMarks: Bool = false, saysQuotes: Bool = false, notices: Bool = false
    ) {
        self.timelines = timelines
        self.trends = trends
        self.boards = boards
        self.authorsAreItsOwn = authorsAreItsOwn
        self.writes = writes
        self.fields = fields
        self.loadsReferences = loadsReferences
        self.saysReaderMarks = saysReaderMarks
        self.saysQuotes = saysQuotes
        self.notices = notices
    }

    /// The field it declares under `name`, or nothing.
    public func field(named name: String) -> SourceField? {
        fields.first { $0.name == name }
    }

    /// Whether a category of this kind can mean a source that offers this: public, Home and a
    /// list where it has timelines, what is rising where it has that, a board where it has
    /// boards. **Which** list or board is the particular source's (`categories(of:signedIn:)`).
    /// No `default:`, so a category added later has to be answered here.
    public func serves(_ category: Category) -> Bool {
        switch category {
        case .public, .home, .list: timelines
        case .trends: trends
        case .board: boards
        }
    }

    /// The categories `source` can be read by now, in the order they are offered: its public
    /// timeline, what is rising, Home where somebody is signed in to it, every list chosen on
    /// it, every board subscribed on it. **A read of the source that names none covers each of
    /// these**, and nothing else that has a name.
    ///
    /// **Completed by the caller, who holds what this cannot know**: `source` carries the lists
    /// and boards chosen on it, and `signedIn` is whether somebody is signed in to it at this
    /// moment — asked of whoever keeps sign-ins, never here.
    public func categories(of source: Source, signedIn: Bool) -> [Category] {
        var served: [Category] = timelines ? [.public] : []
        if trends { served.append(.trends) }
        if timelines, signedIn { served.append(.home) }
        served += source.lists.map { .list(id: $0.id) }
        served += source.boards.map { .board(id: String($0.fid)) }
        return served
    }
}

extension ProtocolKind {
    /// What a source of this kind offers. **The one list of kinds** these facts are answered
    /// by, and with no `default:` — a kind added later has to say what it offers here, rather
    /// than inherit somebody else's answer.
    public var offers: SourceOffers {
        switch self {
        case .mastodon:
            // Signed in on the server's own page; the writing part is what #69 lets a reader buy.
            SourceOffers(
                timelines: true, trends: true, writes: true,
                fields: [.audience, .language, .covered, .reblog, .reblogOf],
                loadsReferences: true, saysReaderMarks: true, saysQuotes: true, notices: true
            )
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial:
            SourceOffers(timelines: true, trends: true)
        // A forum's categories are its boards, and neither forum has a public or a home
        // timeline. **A forum is read only although it signs in**: a Discuz! sign-in is a cookie
        // and a saved password that let this device read a board a signed-out reader may not,
        // and this app has no way at all to post to a forum.
        case .discuz:
            // It ranks its threads and its blogs by the week (`DiscuzRanklist`), which is what
            // a microblog's trending read is: what everybody else is reading.
            SourceOffers(trends: true, boards: true, authorsAreItsOwn: true)
        case .discourse:
            // No ranking this app reads.
            SourceOffers(boards: true, authorsAreItsOwn: true)
        case .unknown:
            SourceOffers()
        }
    }
}
