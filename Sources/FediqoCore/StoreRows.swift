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

    public init(
        upserts: [Note] = [], deletes: [NoteKey] = [], sources: [Source]? = nil, said: [SourceProfile] = [],
        removedHosts: [String] = []
    ) {
        self.upserts = upserts
        self.deletes = deletes
        self.sources = sources
        self.said = said
        self.removedHosts = removedHosts
    }

    public var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty && sources == nil && removedHosts.isEmpty }
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
        }
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
