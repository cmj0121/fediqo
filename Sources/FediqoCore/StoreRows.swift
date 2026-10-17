import Foundation

/// What a save writes (#357): **only what changed since the last write that landed**, by row —
/// the rows to write as they stand now, the rows to delete by key, and the sources where any of
/// them moved. Taken from the store by `ItemStore.takeChanges()`, written by
/// `StoreFile.save(_:)` in one transaction, and handed back by `ItemStore.putBack(_:)` where
/// that write failed.
public struct RowChanges: Sendable, Equatable {
    /// The rows written as they stand, oldest arrival first: a row new to the file is added in
    /// the order the rows arrived, which is the order the next launch reads them in (#114).
    public var upserts: [Note] = []
    /// The rows no longer held, by key — and the rows let go and taken in again since the
    /// last write, deleted before they are written among `upserts`: added again, a row goes
    /// where it now arrived, after every row before it (#114), and not where it once stood.
    public var deletes: [NoteKey] = []
    /// Every source, where any of them — or what one last said of itself — changed; nil where
    /// none did. A source is a handful of rows, so it is written whole or not at all.
    public var sources: [Source]?
    /// What each source last said about itself (#188), written on its source's row: with
    /// `sources`, and nothing without them.
    public var said: [SourceProfile] = []
    /// The sources removed, by host.
    public var removedHosts: [String] = []
    /// Changes to rows the store does not hold, each made on the file as one statement, in the
    /// order they were made: after `deletes` and before `upserts`, so a row the store holds is
    /// written as the store holds it.
    public var ops: [StoreOp] = []

    public init(
        upserts: [Note] = [], deletes: [NoteKey] = [], sources: [Source]? = nil, said: [SourceProfile] = [],
        removedHosts: [String] = [], ops: [StoreOp] = []
    ) {
        self.upserts = upserts
        self.deletes = deletes
        self.sources = sources
        self.said = said
        self.removedHosts = removedHosts
        self.ops = ops
    }

    public var isEmpty: Bool {
        upserts.isEmpty && deletes.isEmpty && sources == nil && removedHosts.isEmpty && ops.isEmpty
    }
}

/// A change to every row of the file it names, made by the file in one statement (#357): what a
/// store holding only some of the rows cannot make row by row, for rows too many to read in.
/// Each is numbered as it is made, so one handed back after a failed write is the same one.
public struct StoreOp: Sendable, Equatable {
    public let number: Int
    public let kind: Kind

    public init(number: Int, kind: Kind) {
        self.number = number
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        /// What a reader's reads said they did to these hosts' posts taken back, and what those
        /// reads left owing (`ItemStore.forgetReaderMarks`).
        case forgetReaderMarks(Hosts)
    }

    /// The hosts an op is about.
    public enum Hosts: Sendable, Equatable {
        case only(String)
        case allBut(Set<String>)

        public func contains(_ host: String) -> Bool {
            switch self {
            case .only(let only): host == only
            case .allBut(let kept): !kept.contains(host)
            }
        }
    }
}

/// Which rows of the file a letting go names (#357), **never a kept one**: the file answers
/// with their keys, and the store lets go of each by key.
public enum RowSelection: Sendable, Equatable {
    /// Every row of a host.
    case host(String)
    /// Every row posted inside a span, of one host or of every one.
    case span(Range<Date>, host: String?)
    /// Every row marked gone from its source, at or before a moment or at any.
    case gone(markedBy: Date?)
}

/// A row of the file that refers to another (`Note.heldWith`), as the room limit asks of it:
/// the row, where it stands in the order rows go in, whether it is kept — and what it refers to.
public struct Referrer: Sendable, Equatable {
    public let key: NoteKey
    public let target: NoteKey
    public let postedAt: Date
    public let arrival: Int64
    public let kept: Bool

    public init(key: NoteKey, target: NoteKey, postedAt: Date, arrival: Int64, kept: Bool) {
        self.key = key
        self.target = target
        self.postedAt = postedAt
        self.arrival = arrival
        self.kept = kept
    }
}

/// A row of the file as it was read (#357): the note, and where it stands in the order the
/// rows arrived in — its `rowid`, which a row written again keeps (`StoreFile.save(_:)`).
public struct HeldRow: Sendable, Equatable {
    public let note: Note
    public let arrival: Int64
    /// Where the row stands in the file's order, to ask a page before or after it by. Nothing
    /// for a row not read from the file.
    public let place: PageCursor?

    public init(note: Note, arrival: Int64, place: PageCursor? = nil) {
        self.note = note
        self.arrival = arrival
        self.place = place
    }
}

/// Where a row stands in the file's order (#357) — its time as the file holds it, its id, and
/// its `rowid` — so that a page asked before or after it starts at the row next to it, and never
/// at it again. Made only by whoever reads the file; opaque to everyone else.
public struct PageCursor: Sendable, Hashable {
    /// The row's `posted_at` as the file writes it, never a `Date` written out again: what the
    /// file's order is made of is what the next page is asked by.
    package let postedAt: String
    public let id: String
    public let rowid: Int64

    package init(postedAt: String, id: String, rowid: Int64) {
        self.postedAt = postedAt
        self.id = id
        self.rowid = rowid
    }

    /// The row's time as a moment: the file's `YYYY-MM-DD HH:MM:SS.SSS`, in UTC, to the
    /// millisecond it holds. Nothing for a time the file did not write that way.
    public var moment: Date? {
        let parts = postedAt.split(whereSeparator: { "- :.".contains($0) }).map { Int($0) }
        guard parts.count >= 6, parts.allSatisfy({ $0 != nil }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let fields = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]
        )
        guard let whole = calendar.date(from: fields) else { return nil }
        let milliseconds = parts.count > 6 ? Double(parts[6] ?? 0) : 0
        return whole.addingTimeInterval(milliseconds / 1000)
    }
}

/// The file's rows, read by key where the store's pool lacks them (#357): what lets `ItemStore`
/// hold only what was read and still merge, keep and let go as the whole store did.
/// **Synchronous**, called from inside the store's actor and never the main actor: each call is
/// a few lookups by index. A row that holds no item, or will not decode, is not handed back.
public protocol HeldRows: Sendable {
    /// The rows under `keys` that the file holds.
    func rows(_ keys: [NoteKey]) throws -> [HeldRow]
    /// Every row of `host` whose id starts `idPrefix`: a forum topic's kept replies.
    func rows(host: String, idPrefix: String) throws -> [HeldRow]
    /// Every row of `host` its source names by one of `statusIDs` — what a reference names
    /// before it knows the row's key (`Reference.statusID`).
    func rows(host: String, statusIDs: [String]) throws -> [HeldRow]
    /// Every row the person keeps (`Note.kept`): few, and what a post kept reblogs is held for.
    func keptRows() throws -> [HeldRow]
    /// What the rows under `keys` reblog, read off their references alone: what a kept row
    /// that will not decode still holds.
    func reblogged(by keys: [NoteKey]) throws -> [NoteKey]
    /// The keys of the rows `selection` names, none of them kept.
    func keys(_ selection: RowSelection) throws -> [NoteKey]
    /// At most `limit` rows not kept, the oldest posted first and two of one moment in the order
    /// they arrived, from past `after` on — and where the next are asked from, or nothing where
    /// none are left. A row that will not decode is passed over.
    func oldest(_ limit: Int, after: PageCursor?) throws -> (rows: [HeldRow], next: PageCursor?)
    /// Every row that refers to one of `keys` (`Note.heldWith`).
    func referring(to keys: [NoteKey]) throws -> [Referrer]
    /// Whether a row of `hosts` says what a reader did, or owes a load as one
    /// (`StoreOp.Kind.forgetReaderMarks`).
    func marked(_ hosts: StoreOp.Hosts) throws -> Bool
    /// How many rows the file holds.
    func rowCount() throws -> Int
}

/// What a `HeldRows` read throws where some rows it found will not decode: those, by key, and
/// every row it could read. The pool takes the rows and **answers for none of the keys** — it
/// cannot say what such a row holds, so a copy of it is not taken over it.
public struct RowsUnread: Error {
    public let keys: [NoteKey]
    public let rows: [HeldRow]

    public init(keys: [NoteKey], rows: [HeldRow]) {
        self.keys = keys
        self.rows = rows
    }
}

/// What `ItemStore.restoring()` throws where rows let go of the pool since a read back could
/// not be read in again (#359): the file is not to be put back, or they would be lost to it.
public struct RowsNotReadBack: Error, Equatable {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }
}

/// The store's rows, **with every key a change reached remembered until a save takes it**
/// (`ItemStore.takeChanges`). Read as the dictionary it wraps; a row set to what it already
/// was is no change, and a row set to nothing is a row to delete.
///
/// So nothing that changes a row has to say so: every way into a row is this subscript.
struct HeldNotes: Sequence {
    private(set) var rows: [NoteKey: Note]
    /// The keys changed since the last take: held now, a row to write; not, one to delete.
    private(set) var touched: Set<NoteKey> = []
    /// The keys let go since the last take, whether or not taken in again since: one held
    /// again is deleted and then written, so it is added where it arrived the second time.
    private(set) var dropped: Set<NoteKey> = []
    /// When each row was last seen (#359) — laid in, changed, or drawn (`saw`) — as a tick that
    /// only goes up, and the `drawing` it was last laid in or changed under: what a pool over
    /// the file lets go of first, and what it keeps for screens drawn before it came.
    private(set) var seen: [NoteKey: Seen] = [:]
    private var clock = 0
    /// The store's `drawn` now: what a row laid in or changed is stamped with.
    var drawing = 0

    struct Seen {
        let tick: Int
        let drawn: Int
    }

    /// `rows` as they are on disk — nothing owed — or, `owed`, every one of them owed a write.
    init(_ rows: [NoteKey: Note] = [:], owed: Bool = false) {
        self.rows = rows
        if owed { touched = Set(rows.keys) }
    }

    subscript(key: NoteKey) -> Note? {
        get { rows[key] }
        set {
            guard rows[key] != newValue else { return }
            if newValue == nil { dropped.insert(key) }
            rows[key] = newValue
            touched.insert(key)
            if newValue == nil { seen[key] = nil } else { stamp(key) }
        }
    }

    /// `note` as the file holds it, laid in under a key that holds nothing: read, and so owed
    /// no write.
    mutating func lay(_ note: Note) {
        rows[note.key] = note
        stamp(note.key)
    }

    private mutating func stamp(_ key: NoteKey) {
        clock += 1
        seen[key] = Seen(tick: clock, drawn: drawing)
    }

    /// The rows under `keys` drawn now: seen, and changed no more than they were.
    mutating func saw(_ keys: some Sequence<NoteKey>) {
        for key in keys where rows[key] != nil {
            clock += 1
            seen[key] = Seen(tick: clock, drawn: seen[key]?.drawn ?? -1)
        }
    }

    /// Every row laid in now, as `lay` stamps one: what a pool laid in whole (`replace`) is
    /// newer than any drawing made before it, and none of it leaves before the next is made.
    mutating func stampAll() {
        for key in rows.keys { stamp(key) }
    }

    /// The row under `key` let go of the pool and not of the file (#359): owed nothing, as it
    /// is the file's. Only of a row no take is owed — the file would not have it otherwise.
    mutating func evict(_ key: NoteKey) {
        assert(!touched.contains(key), "a row let go of the pool before a save took it")
        rows[key] = nil
        seen[key] = nil
    }

    var values: Dictionary<NoteKey, Note>.Values { rows.values }
    var keys: Dictionary<NoteKey, Note>.Keys { rows.keys }
    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }

    func makeIterator() -> Dictionary<NoteKey, Note>.Iterator { rows.makeIterator() }

    /// The keys changed since the last take and the keys let go among them, and none any more.
    mutating func take() -> (touched: Set<NoteKey>, dropped: Set<NoteKey>) {
        defer {
            touched = []
            dropped = []
        }
        return (touched, dropped.intersection(touched))
    }

    /// `keys` owed a write again: one whose write did not land, or a row the file does not hold
    /// as the store does. `dropped`, those of them owed a delete first.
    mutating func owe(_ keys: some Sequence<NoteKey>, dropped gone: some Sequence<NoteKey> = []) {
        touched.formUnion(keys)
        dropped.formUnion(gone)
    }
}

// MARK: - A timeline read a page at a time (#357)

public enum PageAsk: Sendable, Hashable {
    case newest
    /// The rows after the cursor in the store's order: older.
    case before(PageCursor)
    /// The rows before it: newer.
    case after(PageCursor)
    /// The rows after the row under this key, wherever the file has it — a row of the pool, by
    /// its key alone. A key the file does not hold has no place: `StoreFile.NotOnDisk`.
    case beforeRow(NoteKey)
    /// The rows before the row under this key, as `beforeRow`.
    case afterRow(NoteKey)
}

/// What a page is asked for: one timeline as compiled now, and what every timeline is cut by.
public struct PageQuery: Sendable {
    public let timeline: TimelineID
    /// Whose ask this is, handed back on the page so a page that came back for an ask since
    /// replaced can be told apart.
    public let generation: Int
    public let compiled: CompiledTimeline
    /// `LatestDate.end(in:)`: nothing posted at it or after it is shown. Nil for no latest date.
    public let latestEnd: Date?
    /// Nothing posted before it is shown but what is kept: the months a store is kept for.
    public let keepFrom: Date?

    public init(timeline: TimelineID, generation: Int, compiled: CompiledTimeline, latestEnd: Date? = nil, keepFrom: Date? = nil) {
        self.timeline = timeline
        self.generation = generation
        self.compiled = compiled
        self.latestEnd = latestEnd
        self.keepFrom = keepFrom
    }
}

public struct Page: Sendable {
    public let timeline: TimelineID
    public let generation: Int
    /// The rows the timeline shows, in the store's order. **Copies of one post are never split**
    /// between two pages: a page that reaches its limit inside a run of rows with one time and
    /// one id reads the run to its end.
    public let rows: [HeldRow]
    /// What `rows` hold with them and are not themselves shown — the post a reblog reblogs, the
    /// post a quote or an answer names, a forum reply's topic — and what those hold in turn,
    /// where the file has them.
    public let carried: [HeldRow]
    /// The last row looked at, shown or not: where the next page in the same direction starts.
    /// Nil only where nothing was there to look at and nothing was asked after.
    public let next: PageCursor?
    /// The newest and the oldest row looked at, shown or not: a page newer than this one is
    /// asked after `newest`, an older one before `oldest`. Nil where nothing was looked at.
    public let newest: PageCursor?
    public let oldest: PageCursor?
    /// Nothing further on disk in the direction asked. A page that stopped at its budget is not
    /// exhausted, however few rows it has.
    public let exhausted: Bool

    public init(
        timeline: TimelineID, generation: Int, rows: [HeldRow], carried: [HeldRow], next: PageCursor?,
        newest: PageCursor?, oldest: PageCursor?, exhausted: Bool
    ) {
        self.timeline = timeline
        self.generation = generation
        self.rows = rows
        self.carried = carried
        self.next = next
        self.newest = newest
        self.oldest = oldest
        self.exhausted = exhausted
    }
}
