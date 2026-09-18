import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
    /// One row per `NoteKey`: two hosts carrying the same Mastodon URI are two rows (#10).
    private var notes: [NoteKey: Note] = [:]
    /// The oldest a note may be posted and still be held, or nil to keep everything forever —
    /// the default. The reader's drop by time (#7), held here so every way in obeys it.
    private(set) var retention: Date?
    /// Counts the changes to what a save writes: every call that may have changed a source or a
    /// note bumps it. A saver that remembers the revision it last wrote skips a save with nothing
    /// new in it. Starts at 0 for any store, a relaunched one included.
    public private(set) var revision = 0

    public init() {}

    /// A store holding what a relaunch read back from disk — the one way a snapshot gets in.
    ///
    /// **A snapshot is taken as it is, but never trusted to be well-formed.** It is whatever the
    /// last run wrote, read through a file format that can be older than this code; a duplicate
    /// in it is a bug somewhere else, and trapping at launch over it would turn that bug into an
    /// app that does not open. So the rules `add` and `ingest` keep hold here too: one source per
    /// host, the first one winning as `add` has it, and one row per `NoteKey`, the later copy
    /// winning outright — a snapshot is one moment written once, not two reads to merge.
    public init(sources: [Source], notes incoming: [Note]) {
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        notes = Dictionary(incoming.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func add(_ source: Source) {
        if sourceList.contains(where: { $0.host == source.host }) { return }
        sourceList.append(source)
        revision += 1
    }

    /// Restates which boards a source is subscribed to, where that source is here.
    ///
    /// **`add` is deliberately not the place for this.** Adding a host twice keeps the first, and
    /// that is the right contract for a call that means "this server is one of the reader's" — it
    /// is what stops a second join clobbering a source with a differently-spelled kind. But a
    /// reader who opens the picker again and chooses a ninth board is not adding a server, they
    /// are changing one, and D26 says there is only ever the one to change: a board is a query
    /// *within* a source, so the set of them is a property of the host and not a new host.
    ///
    /// Silent where the host is not here, because subscribing to boards of a server nobody
    /// joined would put a source in the list by a side door — and every join in this package
    /// reads before it adds, on purpose.
    public func subscribe(host: String, to boards: [BoardSubscription]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        sourceList[index] = Source(host: existing.host, kind: existing.kind, boards: boards)
        revision += 1
    }

    /// Takes notes in. The same item through one source stays one row: the first copy wins and
    /// categories grow, so All and Trends of one host share a row. A fetch with fewer takes none
    /// away: a category is what the copy arrived through, and that stays true (#25). The same
    /// item through two sources is two rows (#10). Merging those into one thread is later.
    ///
    /// A note posted before the retention window is refused: the reader chose not to keep it.
    public func ingest(_ incoming: [Note]) {
        guard !incoming.isEmpty else { return }
        revision += 1
        for note in incoming where retention.map({ note.postedAt >= $0 }) ?? true {
            let key = note.key
            if var existing = notes[key] {
                existing.categories.formUnion(note.categories)
                notes[key] = existing
            } else {
                notes[key] = note
            }
        }
    }

    /// Lets go of one server: the source, the boards the reader picked on it, and the notes it
    /// carried here. Each source is its own rows, so this host's copy goes and the other source's
    /// copy of the same content stays (#10).
    ///
    /// Silent where the host is not here, for the reason `subscribe(host:to:)` is: nothing in this
    /// package puts a source in the list, or takes one out of it, by a side door.
    public func remove(host raw: String) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        notes = notes.filter { $0.key.host != host }
        revision += 1
    }

    public func sources() -> [Source] {
        sourceList
    }

    /// Keeps only the latest `months` months as of `now` from here on, or everything where
    /// `months` is nil — forever, the default (#7). Drops what is already older, and returns how
    /// many notes went, so a caller writes and redraws only when something did. Sources are
    /// untouched: a source with nothing left inside the window stays joined.
    @discardableResult
    public func setRetention(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> Int {
        retention = KeepPolicy.cutoff(keepingMonths: months, from: now, calendar: calendar)
        guard let retention else { return 0 }
        let before = notes.count
        notes = notes.filter { $0.value.postedAt >= retention }
        if notes.count != before { revision += 1 }
        return before - notes.count
    }

    /// Everything this store holds, read in one hop — what a save writes to disk.
    ///
    /// **Unsorted, and taken at one moment.** A save does not draw anything, so it has no use for
    /// `all()`'s order and should not pay for it; and asking for the sources and the notes in two
    /// awaits would let an ingest or a remove land between them, writing notes whose source is
    /// gone. This is the counterpart of `init(sources:notes:)`.
    /// `revision` is the one this snapshot is of, read in the same hop.
    public func snapshot() -> (sources: [Source], notes: [Note], revision: Int) {
        (sourceList, Array(notes.values), revision)
    }

    public func all() -> [Note] {
        notes.values.sorted(by: Self.storeOrder)
    }

    public func trends() -> [Note] {
        all().filter { $0.categories.contains(.trends) }
    }

    private static func storeOrder(_ a: Note, _ b: Note) -> Bool {
        if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
        if a.id != b.id { return a.id < b.id }
        return a.source.host < b.source.host
    }
}
