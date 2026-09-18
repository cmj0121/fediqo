import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
    /// One row per `NoteKey`: two hosts carrying the same Mastodon URI are two rows (#10).
    private var notes: [NoteKey: Note] = [:]

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
    }

    /// Takes notes in. The same item through one source stays one row: the first copy wins and
    /// origins grow, so All and Trends of one host share a row. The same item through two sources
    /// is two rows (#10). Merging those into one thread is later.
    public func ingest(_ incoming: [Note]) {
        for note in incoming {
            let key = note.key
            if var existing = notes[key] {
                existing.origins.formUnion(note.origins)
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
    }

    public func sources() -> [Source] {
        sourceList
    }

    /// Drops this host's notes. The source stays joined: this is Clear, not Remove (#7).
    public func dropNotes(host raw: String) {
        let host = raw.lowercased()
        notes = notes.filter { $0.key.host != host }
    }

    /// Drops notes posted before `date` — the time drop. Nothing calls this unless the reader
    /// chose to keep only the latest months; keeping everything forever is the default.
    public func dropPosted(before date: Date) {
        notes = notes.filter { $0.value.postedAt >= date }
    }

    /// Everything this store holds, read in one hop — what a save writes to disk.
    ///
    /// **Unsorted, and taken at one moment.** A save does not draw anything, so it has no use for
    /// `all()`'s order and should not pay for it; and asking for the sources and the notes in two
    /// awaits would let an ingest or a remove land between them, writing notes whose source is
    /// gone. This is the counterpart of `init(sources:notes:)`.
    public func snapshot() -> (sources: [Source], notes: [Note]) {
        (sourceList, Array(notes.values))
    }

    public func all() -> [Note] {
        notes.values.sorted(by: Self.storeOrder)
    }

    public func trends() -> [Note] {
        all().filter { $0.origins.contains(.trending) }
    }

    private static func storeOrder(_ a: Note, _ b: Note) -> Bool {
        if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
        if a.id != b.id { return a.id < b.id }
        return a.source.host < b.source.host
    }
}
