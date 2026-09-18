import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    /// One row per source and item. Two hosts carrying the same Mastodon URI are two rows (#10).
    private struct NoteKey: Hashable, Sendable {
        let host: String
        let id: String
    }

    private var sourceList: [Source] = []
    private var notes: [NoteKey: Note] = [:]

    public init() {}

    public init(sources: [Source], notes incoming: [Note]) {
        sourceList = sources
        notes = Dictionary(uniqueKeysWithValues: incoming.map { (Self.key(of: $0), $0) })
    }

    private static func key(of note: Note) -> NoteKey {
        NoteKey(host: note.source.host, id: note.id)
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
            let key = Self.key(of: note)
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

    /// Replaces what this device holds. Used to load a snapshot after a relaunch.
    public func replace(sources: [Source], notes incoming: [Note]) {
        sourceList = sources
        notes = Dictionary(uniqueKeysWithValues: incoming.map { (Self.key(of: $0), $0) })
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
