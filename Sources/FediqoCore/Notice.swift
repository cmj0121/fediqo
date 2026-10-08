import Foundation

// What a source says happened to the person (#323): somebody answered, mentioned, boosted,
// favoured, followed or quoted them, a poll of theirs ended, a post they boosted changed.
//
// **Not an item.** A notice stands in no timeline and is held in no store: it is read each run
// and kept in memory. The post one is about is only *carried* here, as the `Note` any other read
// would have made of it, and becomes an item when somebody opens it and not before.

/// One thing a source says happened to the person: one line of the page.
///
/// **One shape for both reads.** A source that gathers says "these three favoured that post" as
/// one line; one that does not says it three times. A single notice is a gathered line of one
/// person and a count of one, so nothing that draws or orders a notice knows which read brought
/// it — only `handle` does, because the two are dismissed by different names.
public struct Notice: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case mention
        case reblog
        case favourite
        case follow
        case followRequest
        case quote
        case poll
        case update
        /// The server speaking for itself, under its own word: `severed_relationships`,
        /// `moderation_warning`, `admin.sign_up`, `admin.report`.
        case server(String)
        /// A type this build does not know, kept under the word the source used.
        case unknown(String)

        private static let servers: Set<String> = [
            "severed_relationships", "moderation_warning", "admin.sign_up", "admin.report",
        ]

        /// **Total: it never fails and never drops.** A word nobody here has heard of is a
        /// notice of an unknown kind, which is a truthful line; a notice left out is a thing
        /// that happened to the person and was hidden from them.
        public init(type: String) {
            switch type {
            case "mention": self = .mention
            case "reblog": self = .reblog
            case "favourite": self = .favourite
            case "follow": self = .follow
            case "follow_request": self = .followRequest
            case "quote": self = .quote
            case "poll": self = .poll
            case "update": self = .update
            default: self = Self.servers.contains(type) ? .server(type) : .unknown(type)
            }
        }

        /// The source's word back, as it was sent.
        public var type: String {
            switch self {
            case .mention: "mention"
            case .reblog: "reblog"
            case .favourite: "favourite"
            case .follow: "follow"
            case .followRequest: "follow_request"
            case .quote: "quote"
            case .poll: "poll"
            case .update: "update"
            case .server(let word), .unknown(let word): word
            }
        }
    }

    /// How it is named at its source — the one thing the two reads leave different.
    public enum Handle: Hashable, Sendable {
        /// One notice, by its id: the single read.
        case one(id: String)
        /// A gathered line, by its group key: the gathered read.
        case gathered(key: String)
    }

    public let source: Source
    public let handle: Handle
    public let kind: Kind
    /// Who, newest first. From the gathered read this is the sample the source sent, which may
    /// be fewer than `count`.
    public let people: [NoticePerson]
    /// How many notices it stands for; 1 from the single read.
    public let count: Int
    /// What it is about, where it is about a post: the answer or the mention itself, the quoting
    /// post, the person's own post that was boosted or favoured. Nothing for a follow.
    public let post: Note?
    /// When: the notice's own moment, or the latest notice of a gathered line.
    public let at: Date
    /// The newest notice id it stands for.
    public let newestID: String
    /// The oldest notice id it stands for **on the pages read so far**: a gathered line the
    /// source cut at a page edge reaches further down once the next page is folded in.
    public let oldestID: String
    /// The line's identity: its host, which read named it, and the name. Two sources number
    /// their notices from one, and a group key is not an id, so none of the three can be left
    /// out. Made once, as the line is: a list asks every line for it at every draw.
    public let id: String

    public init(
        source: Source, handle: Handle, kind: Kind, people: [NoticePerson], count: Int = 1, post: Note? = nil,
        at: Date, newestID: String, oldestID: String
    ) {
        self.source = source
        self.handle = handle
        self.kind = kind
        self.people = people
        self.count = count
        self.post = post
        self.at = at
        self.newestID = newestID
        self.oldestID = oldestID
        id = switch handle {
        case .one(let id): "\(source.host)\u{1e}one\u{1e}\(id)"
        case .gathered(let key): "\(source.host)\u{1e}gathered\u{1e}\(key)"
        }
    }

    /// Whether the person was answered and not only mentioned. **Not a kind**: a source sends an
    /// answer as a `mention`, and what tells the two apart is the post, which answers something.
    public var answers: Bool { kind == .mention && post?.reply != nil }

    /// This line with `older` folded in: the same line, come back on the next page because the
    /// source cut it where the page before ended.
    ///
    /// The people are the two samples joined, newest first and nobody twice; the count is the
    /// larger, since each page says how many the whole line stands for or how many it reached;
    /// the line reaches down to the older of the two and stands at the moment of the newer.
    public func folding(_ older: Notice) -> Notice {
        var seen = Set(people.map(\.handle))
        return Notice(
            source: source, handle: handle, kind: kind,
            people: people + older.people.filter { seen.insert($0.handle).inserted },
            count: max(count, older.count), post: post ?? older.post, at: max(at, older.at),
            newestID: StatusID.later(older.newestID, than: newestID) ? older.newestID : newestID,
            oldestID: StatusID.later(oldestID, than: older.oldestID) ? older.oldestID : oldestID
        )
    }
}

extension [Notice] {
    /// These lines with an older stretch read on to: each line of it added below, **and one
    /// already held folded into the line that holds it** — a gathered line the source cut at a
    /// page edge, or a notice asked for twice. So reading on never draws a thing twice.
    public func readingOn(_ older: [Notice]) -> [Notice] {
        var lines = self
        var places = Dictionary(lines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for notice in older {
            if let place = places[notice.id] {
                lines[place] = lines[place].folding(notice)
            } else {
                places[notice.id] = lines.count
                lines.append(notice)
            }
        }
        return lines
    }
}

/// Somebody a notice names, as the source says them: what a row draws of a post's author.
public struct NoticePerson: Hashable, Sendable {
    /// `@user@host`, the spelling `Note.handle` takes.
    /// **As sent**: what they are matched to their posts by. A line of ours says `lineHandle`.
    public let handle: String
    public let name: String
    public let avatarURL: URL?
    /// The pictures the name is partly written in.
    public let emojis: [CustomEmoji]
    /// The name and the handle made fit to stand in a line (`LineText.oneLine`), once, where
    /// they enter: what every sentence and every row says of them.
    public let lineName: String
    public let lineHandle: String

    public init(handle: String, name: String, avatarURL: URL? = nil, emojis: [CustomEmoji] = []) {
        self.handle = handle
        self.name = name
        self.avatarURL = avatarURL
        self.emojis = emojis
        lineName = LineText.oneLine(name)
        lineHandle = LineText.oneLine(handle)
    }
}

/// What a stranger's server sent, made fit to stand in one line of ours.
public enum LineText {
    /// How long a name a source sent may run on a line of ours. A Mastodon allows thirty
    /// characters; a source may send any number.
    public static let nameLength = 64

    /// A name or a handle a source sent, made fit to stand in one line of ours: no control or
    /// format character — a direction override or isolate, a zero-width mark — no line break,
    /// and no longer than `nameLength`. **What a stranger's server sent is set inside a
    /// sentence the person answers**, and a name left as sent can turn that sentence round, end
    /// it early or push it off the card.
    ///
    /// A joiner between two pictures stays: it is what makes one picture of several, and it
    /// hides nothing between two that are drawn.
    public static func oneLine(_ text: String, limit: Int = nameLength) -> String {
        // Bounded before it is walked: a name of any length costs what a long one costs.
        let scalars = Array(text.unicodeScalars.prefix(limit * 16))
        var kept = String.UnicodeScalarView()
        for (place, scalar) in scalars.enumerated() {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                kept.append(" ")
            case .format:
                let joins = scalar == "\u{200D}" && place > 0 && place + 1 < scalars.count
                    && pictured(scalars[place - 1]) && pictured(scalars[place + 1])
                if joins { kept.append(scalar) }
            default:
                kept.append(scalar)
            }
        }
        let words = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit)) + "…" : words
    }

    /// Whether a scalar is part of a picture a joiner may stand beside.
    private static func pictured(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{FE0F}" || (scalar.properties.isEmoji && scalar.value > 0xFF)
    }
}

/// One stretch of one source's notices.
public struct NoticePage: Hashable, Sendable {
    /// Newest first.
    public let notices: [Notice]
    /// Which read answered: the gathered one, or the single one.
    public let gathered: Bool
    /// The id the next, older stretch is asked before. Nothing where the source had no more.
    public let before: String?
    /// When the read that brought this stretch was sent, in the run's order (`ReadMoment`):
    /// what tells a stretch asked for before a line was dismissed from one asked for after.
    /// Unsaid for a page made by hand, which is never taken for one sent just now.
    public let sent: ReadMoment

    public init(notices: [Notice], gathered: Bool, before: String?, sent: ReadMoment = .unsaid) {
        self.notices = notices
        self.gathered = gathered
        self.before = before
        self.sent = sent
    }
}

extension [Notice] {
    /// These lines without the one its source has dismissed.
    public func without(_ notice: Notice) -> [Notice] {
        filter { $0.id != notice.id }
    }

    /// These lines without any of `source`'s: what dismissing all there leaves. Another source's
    /// lines stand — the request went to one source, and took that one's notices only.
    public func without(all source: Source) -> [Notice] {
        filter { $0.source != source }
    }
}

/// How much a source is holding back from the person: notices it did not put in the list, from
/// people it was told to be wary of, gathered into one request for each such person.
public struct NoticesHeld: Hashable, Sendable {
    /// How many people's notices are waiting.
    public let requests: Int
    /// How many notices that is in all.
    public let notices: Int

    public init(requests: Int, notices: Int) {
        self.requests = requests
        self.notices = notices
    }

    public var isEmpty: Bool { requests <= 0 && notices <= 0 }
}

/// What is known, this run, of whether one source holds notices back.
///
/// **A source that has no such thing is asked once and not again.** Whoever asks keeps the
/// answer and hands it back with the next ask, as a page's `gathered` is handed back: `absent`
/// is then answered on this device, with no request made.
public enum NoticeHolding: Hashable, Sendable {
    /// Not asked yet.
    case unasked
    /// The source has no held-back notices at all: an older one, with no policy to hold by.
    case absent
    /// What it said it holds, which may be nothing just now.
    case holds(NoticesHeld)

    /// What there is to offer the person: nothing where the source has no such thing, was not
    /// asked, or holds nothing — so its requests are not asked for either.
    public var held: NoticesHeld? {
        if case .holds(let held) = self, !held.isEmpty { held } else { nil }
    }
}

/// One person's notices a source is holding back, waiting to be let through or let go.
public struct NoticeRequest: Hashable, Sendable, Identifiable {
    /// The source's own name for the request: what letting it through or go is asked by. Two
    /// sources may use the same one, so it is not the request's identity.
    public let requestID: String
    public let source: Source
    /// Whose notices are held.
    public let person: NoticePerson
    /// How many of theirs are held.
    public let count: Int
    /// The latest post of theirs among them, where the source sent one.
    public let lastPost: Note?
    /// When the request last grew.
    public let at: Date

    public init(
        requestID: String, source: Source, person: NoticePerson, count: Int = 1, lastPost: Note? = nil, at: Date
    ) {
        self.requestID = requestID
        self.source = source
        self.person = person
        self.count = count
        self.lastPost = lastPost
        self.at = at
    }

    /// The request's identity: its host and the name, as a notice's is its host and its own.
    public var id: String { "\(source.host)\u{1e}request\u{1e}\(requestID)" }
}
