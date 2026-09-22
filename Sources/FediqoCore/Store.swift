import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
    /// One row per `NoteKey`: two hosts carrying the same Mastodon URI are two rows (#10).
    private var notes: [NoteKey: Note] = [:]
    /// When each row first arrived, as a count that only goes up. Nothing reads the number; what
    /// is read is which of two is the smaller.
    ///
    /// **Which copy a merged row is drawn as** (#114). Two sources carrying one post are two rows
    /// here and one row on screen, and the row is the copy that arrived first — so the store has
    /// to be able to say which that was. It could not before: a dictionary hands its values back
    /// in whatever order it likes, and the two copies agree on the hour they were posted and on
    /// the name their servers gave the post, which is every other thing `storeOrder` compares.
    ///
    /// **Counted, not clocked.** A moment would be a fact about this device's clock, which can go
    /// backwards; the order two copies were taken in is a fact about this store, and it is the
    /// only one being asked for.
    ///
    /// It survives a relaunch as an order rather than as a number: `snapshot` hands the rows over
    /// oldest first, a save writes them in that order, and `init(sources:notes:)` counts the rows
    /// back in the order it is given them. So the numbers a second run uses are not the first
    /// run's, and the answer they give is.
    private var arrival: [NoteKey: Int] = [:]
    private var arrivals = 0
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
        // The order the rows are handed over is the order they arrived in: the run that wrote
        // this snapshot wrote them oldest first. A row named twice keeps the first mention's
        // place, the way `ingest` keeps a row's place when it is met again.
        for note in incoming where arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
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
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: boards, lists: existing.lists
        )
        revision += 1
    }

    /// Restates which Mastodon lists a source reads — a choice, or the same lists relabelled with
    /// the names the server gives them now. `subscribe(host:to:)`'s rules: replaces the set, and
    /// is silent where the host is not here.
    public func subscribe(host: String, toLists lists: [ListSubscription]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: existing.boards, lists: lists
        )
        revision += 1
    }

    /// Gives the lists a source reads **now** the names in `names`, by id. Only relabels: a list
    /// chosen or unchosen while the names were on the wire stays as that choice left it. Silent
    /// where the host is not here or nothing changes.
    public func relabel(host: String, lists names: [String: String]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        let lists = existing.lists.map { ListSubscription(id: $0.id, name: names[$0.id] ?? $0.name) }
        guard lists != existing.lists else { return }
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: existing.boards, lists: lists
        )
        revision += 1
    }

    /// `ingest(_:)`, only while `host` is still a source here — in the same step, so a source
    /// removed while its reads were on the wire does not get their posts back.
    public func ingest(_ incoming: [Note], ifSourceHere host: String) {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        ingest(incoming)
    }

    /// Takes notes in. The same item through one source stays one row: the first copy wins and
    /// categories grow, so All and Trends of one host share a row. A fetch with fewer takes none
    /// away: a category is what the copy arrived through, and that stays true (#25). The same
    /// item through two sources is two rows (#10) here, whatever the timeline draws them as: a
    /// merge (#114) is a way of drawing what is held, never a way of holding less of it.
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
                arrival[key] = arrivals
                arrivals += 1
            }
        }
    }

    /// Posts read again (#29), only while `host` is still a source here and only those stamped
    /// with it. Unlike `ingest`, a row already held is **replaced** by what the server says now —
    /// an edited post shows its new words — keeping the categories it arrived through and its
    /// booster (`Note.refreshed(over:)`). **A post not held is dropped**: reading one post again
    /// updates what is here, and brings in nothing the reader did not already have.
    public func refresh(_ incoming: [Note], ifSourceHere host: String) {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        let held = incoming.filter { $0.source.host == host && notes[$0.key] != nil }
        guard !held.isEmpty else { return }
        revision += 1
        for note in held {
            notes[note.key] = notes[note.key].map(note.refreshed(over:))
        }
    }

    /// Lets go of one server: the source, the boards the reader picked on it, and the notes it
    /// carried here. Each source is its own rows, so this host's copy goes and the other source's
    /// copy of the same content stays (#10).
    ///
    /// **Nothing here knows about merged rows, and that is what makes letting go right** (#115).
    /// A post two sources carried is drawn as one row but held as two, so taking one server's
    /// copies away leaves the other's exactly as it arrived, and the row it was merged into is
    /// drawn again from what is left — as that source carried it. A merge stores nothing of its
    /// own, so nothing of one outlives the copies it was drawn from.
    ///
    /// Silent where the host is not here, for the reason `subscribe(host:to:)` is: nothing in this
    /// package puts a source in the list, or takes one out of it, by a side door.
    public func remove(host raw: String) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        notes = notes.filter { $0.key.host != host }
        arrival = arrival.filter { $0.key.host != host }
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
        if notes.count != before {
            arrival = arrival.filter { notes[$0.key] != nil }
            revision += 1
        }
        return before - notes.count
    }

    /// Everything this store holds, read in one hop — what a save writes to disk.
    ///
    /// **In the order the rows arrived, and taken at one moment.** A save does not draw anything,
    /// so it has no use for `all()`'s order; what it does need is the order the rows came in, so
    /// that the run reading them back knows which copy of a post arrived first (#114). And asking
    /// for the sources and the notes in two awaits would let an ingest or a remove land between
    /// them, writing notes whose source is gone. This is the counterpart of
    /// `init(sources:notes:)`. `revision` is the one this snapshot is of, read in the same hop.
    public func snapshot() -> (sources: [Source], notes: [Note], revision: Int) {
        let arrival = self.arrival
        let ordered = notes.values.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
        return (sourceList, ordered, revision)
    }

    public func all() -> [Note] {
        let arrival = self.arrival
        return notes.values.sorted { Self.storeOrder($0, $1, arrival) }
    }

    /// Lets go of one row — a post its author took back (#109). Silent where it is not held.
    ///
    /// **One row and never a host's worth.** `remove(host:)` is the reader letting go of a server;
    /// this is a server saying one post no longer exists, and the other copies of it through other
    /// sources are theirs to say about.
    public func forget(_ key: NoteKey) {
        guard notes.removeValue(forKey: key) != nil else { return }
        revision += 1
    }

    /// One row, or nothing where this store does not hold it.
    ///
    /// **So that an act can hand back the row as the store has it** rather than as it decoded it
    /// (#106): `refresh` lays the server's answer over what was held, and a caller reading its own
    /// decode back would be holding a note that disagrees with the store about the categories the
    /// row arrived through and about who boosted it.
    public func note(_ key: NoteKey) -> Note? {
        notes[key]
    }

    public func trends() -> [Note] {
        all().filter { $0.categories.contains(.trends) }
    }

    private static func storeOrder(_ a: Note, _ b: Note, _ arrival: [NoteKey: Int]) -> Bool {
        if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
        if a.id != b.id { return a.id < b.id }
        // Two copies of one post from two sources (#10): the one this store took first comes
        // first, so a merged row drawn from the first of its copies is the copy that arrived
        // first (#114). The host stays behind it only so the order is total.
        let mine = arrival[a.key] ?? 0
        let theirs = arrival[b.key] ?? 0
        if mine != theirs { return mine < theirs }
        return a.source.host < b.source.host
    }
}
