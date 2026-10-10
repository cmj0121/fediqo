import Foundation

// Somebody as a source says them (#310), and a stretch of such people (#311).
//
// **Not an item, and held nowhere.** A person stands in no timeline and is written to no store:
// what a source said of somebody is what a page draws while it is open, asked again when it is
// opened again. What this device holds of them is their posts, which are items already.

/// Somebody as one source says them: who they are there, what they say of themselves, and what
/// the source counts of them.
///
/// **One source's word, and it may be about somebody who lives elsewhere.** A source says of a
/// person on another server only what has reached it: its counts are the ones their own server
/// last told it, and its lists and their posts are the part it has seen (`livesHere`).
///
/// **Everything here is a stranger's word**, made fit where it enters, as a notice's names are
/// (`LineText`): a name, a handle and a field stand in one line of ours; their own words are
/// bounded; the server they live on is a host or nothing; a picture is an address this device
/// may fetch or none; a count that is not a count is one the source did not say.
///
/// **For whoever draws one:**
/// - `words` is as many lines as they wrote. A row that shows only their first line makes it
///   one line there (`LineText.oneLine`), as it would any other stranger's sentence.
/// - A field's `verifiedAt` is the source's word that it checked the address. The mark that
///   says so is drawn where nothing in `name` or `value` — a custom emoji least of all — can
///   stand in its place.
/// - `hidesLists` is about the lists as anybody is given them. An empty answer for the
///   reader's **own** list is not "hidden" unless the sign-in it was asked through is known to
///   be live: a source answers these reads to a token it no longer honours as it answers
///   nobody (200), so a dead sign-in reads its own hidden list as an empty one.
public struct Person: Hashable, Sendable, Identifiable {
    /// One of the lines somebody filled in about themselves: a label and what stands under it.
    public struct Field: Hashable, Sendable {
        /// Both made fit to stand in a line of ours, and written in letters: a value the source
        /// sent as a link is the link's own words.
        public let name: String
        public let value: String
        /// When the source checked that the address in `value` names them back. Nothing where
        /// it has not: which is not "it does not", only "nobody checked".
        public let verifiedAt: Date?

        public init(name: String, value: String, verifiedAt: Date? = nil) {
            self.name = LineText.oneLine(name)
            self.value = LineText.oneLine(value, limit: Person.fieldLength)
            self.verifiedAt = verifiedAt
        }
    }

    /// What the source counts of them. **A count nobody stated is a source that never said, and
    /// never a zero** — as a post's are (`Counts`).
    public struct Tally: Hashable, Sendable {
        public let posts: Int?
        public let following: Int?
        public let followers: Int?

        public init(posts: Int? = nil, following: Int? = nil, followers: Int? = nil) {
            self.posts = posts
            self.following = following
            self.followers = followers
        }
    }

    /// What kind of account it says it is.
    public enum Sort: Hashable, Sendable {
        case person
        /// Something that posts by itself.
        case automated
        /// An account many people post through.
        case group
    }

    /// Where somebody who moved went, as the source names them: enough to say it, and to open
    /// them at this source.
    public struct Moved: Hashable, Sendable {
        public let accountID: String
        /// `@user@host`, as sent, and made fit to stand in a line of ours.
        public let handle: String
        public let lineHandle: String

        public init(accountID: String, handle: String) {
            self.accountID = accountID
            self.handle = handle
            lineHandle = LineText.oneLine(handle)
        }
    }

    /// How many fields are kept of somebody, how long a field's value may run, and how long
    /// their own words may: a Mastodon allows four, 255 and 500, and a source may send any
    /// number of any length.
    public static let fieldCount = 16
    public static let fieldLength = 255
    public static let wordsLength = 5_000
    /// How many pictures are kept for the name, the words and the fields together.
    public static let emojiCount = 64
    /// How long a host's name may be (RFC 1035).
    public static let hostLength = 253

    /// The source that said this.
    public let source: Source
    /// The source's own name for the account: what their posts and their lists are asked by
    /// there, and nowhere else — two sources number theirs apart.
    public let accountID: String
    /// `@user@host`, the spelling `Note.handle` takes. **As sent**: what they are matched to
    /// their posts by. A line of ours says `lineHandle`.
    public let handle: String
    public let name: String
    public let avatarURL: URL?
    /// The picture at the head of their profile, where they set one.
    public let headerURL: URL?
    /// Their own words about themselves, without the markup, as a post's body is.
    public let words: String
    public let fields: [Field]
    /// The pictures the name, the words and the fields are partly written in.
    public let emojis: [CustomEmoji]
    public let tally: Tally
    /// Whether the source says they hide who they follow and who follows them. **Only its yes
    /// is a word**: a Mastodon says nothing at all (`null`) of an account that never touched
    /// the setting, which is everybody who does not hide. A hidden list arrives as an empty
    /// one, so this is the one thing that tells the two apart.
    public let hidesLists: Bool
    /// Whether they must agree before anybody may follow them.
    public let locked: Bool
    public let sort: Sort
    /// Where they went, where the source says they moved.
    public let moved: Moved?
    /// Whether the source says the account is suspended: it names them, and says nothing else.
    public let suspended: Bool
    /// The server they live on, as a host this device could name and reach: the last part of
    /// their handle, lower case, in the one spelling a name that is not ASCII has (`xn--…`).
    /// **A host or nothing.** A handle whose last part is no host — a direction override, a
    /// space, a line, a name longer than a name may be — names no home: what is said of them
    /// is then the handle alone, and nothing offers to ask a server by that name.
    public let home: String?
    /// The name and the handle made fit to stand in a line (`LineText.oneLine`), once, where
    /// they enter.
    public let lineName: String
    public let lineHandle: String
    /// Their identity: the host that said them and its name for them, as a notice's is.
    public let id: String

    public init(
        source: Source, accountID: String, handle: String, name: String, avatarURL: URL? = nil,
        headerURL: URL? = nil, words: String = "", fields: [Field] = [], emojis: [CustomEmoji] = [],
        tally: Tally = Tally(), hidesLists: Bool = false, locked: Bool = false, sort: Sort = .person,
        moved: Moved? = nil, suspended: Bool = false
    ) {
        self.source = source
        self.accountID = accountID
        self.handle = handle
        self.name = name
        self.avatarURL = avatarURL
        self.headerURL = headerURL
        // By scalars, as a name is: a letter under a thousand marks is one character.
        let scalars = words.unicodeScalars
        self.words = scalars.count > Self.wordsLength
            ? String(String.UnicodeScalarView(scalars.prefix(Self.wordsLength))) + "…" : words
        self.fields = Array(fields.prefix(Self.fieldCount))
        self.emojis = Array(emojis.prefix(Self.emojiCount))
        self.tally = tally
        self.hidesLists = hidesLists
        self.locked = locked
        self.sort = sort
        self.moved = moved
        self.suspended = suspended
        home = Self.host(named: handle)
        lineName = LineText.oneLine(name)
        lineHandle = LineText.oneLine(handle)
        id = "\(source.host)\u{1e}person\u{1e}\(accountID)"
    }

    /// The host a handle names — what follows its last `@` — or nothing where that is no host.
    ///
    /// Bounded before it is read; held to what is seen (`namesAHost`); taken through
    /// `Host.parse`, which admits no space, path or second `@`; folded to the spelling an address has, so a name that is not ASCII is its
    /// punycode; and then held to the letters a host's name is made of. What comes out can be
    /// set in a sentence of ours and handed to a request, or there is none.
    static func host(named handle: String) -> String? {
        let parts = handle.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count > 2 || (parts.count == 2 && !handle.hasPrefix("@")), let last = parts.last,
              last.unicodeScalars.count <= hostLength, last.unicodeScalars.allSatisfy(Self.namesAHost),
              let parsed = try? Host.parse(String(last)),
              let folded = URL(string: "https://" + parsed)?.host(percentEncoded: false)?.lowercased(),
              !folded.isEmpty, folded.count <= hostLength, !folded.hasPrefix("."), !folded.hasPrefix("-"),
              folded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }
        return folded
    }

    /// Whether a scalar may stand in a host's name as it is written in a handle: no scheme or
    /// port (`:`), no escape (`%`), and nothing unseen — what an address folds away or decodes
    /// would name one server while the handle spells another.
    private static func namesAHost(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: false
        default: scalar != ":" && scalar != "%"
        }
    }

    /// Whether they live on the source that said this. Where they do not — or where their
    /// handle names no server at all — what it says of them is the part that has reached it.
    public var livesHere: Bool { home != nil && home == Self.host(named: "here@\(source.host)") }
}

/// One stretch of a list of people, as one source handed it over.
public struct PeopleStretch: Hashable, Sendable {
    /// In the source's own order.
    public let people: [Person]
    /// What the next stretch is asked by: the source's own word for where this one stopped.
    /// Nothing where it named no next — which is the end of what it has, or will show.
    public let next: String?

    public init(people: [Person], next: String?) {
        self.people = people
        self.next = next
    }
}

/// A list of people as far as it has been read: who it has brought, where the source said the
/// next stretch begins, and every such place it has named — so a source that sends a reader
/// round in a ring, or on for ever with nobody new, is stopped and not read without end while
/// the list's foot is in view.
public struct PeopleRead: Hashable, Sendable {
    /// How many stretches in a row may bring nobody new and still name a next. One alone is
    /// ordinary — signed in, a source leaves out of a stretch the people the reader blocks or
    /// mutes, and may leave out all of them — so it does not end a list; this many is a source
    /// that is not paging.
    public static let barren = 4

    /// Everybody read so far, in the source's order, nobody twice.
    public private(set) var people: [Person] = []
    /// What the next stretch is asked by. Nothing before the first stretch, and at the end.
    public private(set) var next: String?
    /// Whether a stretch has been read and the source named no next: the end of what it has,
    /// or will show.
    public private(set) var ended = false
    private var named: Set<String> = []
    private var barrenRun = 0

    public init() {}

    /// This list with `stretch` read on to. Throws `MastodonPeopleError.notPaging`, changing
    /// nothing, where the stretch names a next the list was already sent to, or is one too many
    /// in a row to bring nobody new and name a next all the same.
    public func readingOn(_ stretch: PeopleStretch) throws -> PeopleRead {
        var read = self
        read.people = people.readingOn(stretch.people)
        read.next = stretch.next
        read.ended = stretch.next == nil
        guard let onward = stretch.next else { return read }
        guard read.named.insert(onward).inserted else { throw MastodonPeopleError.notPaging }
        read.barrenRun = read.people.count == people.count ? barrenRun + 1 : 0
        guard read.barrenRun < Self.barren else { throw MastodonPeopleError.notPaging }
        return read
    }
}

extension [Person] {
    /// These people with a further stretch read on to: each of it added below, **and nobody
    /// twice** — somebody the list gained or lost between two asks moves where a stretch ends,
    /// and the one already here stands where they stood.
    public func readingOn(_ further: [Person]) -> [Person] {
        var seen = Set(map(\.id))
        return self + further.filter { seen.insert($0.id).inserted }
    }
}
