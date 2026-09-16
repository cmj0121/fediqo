import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
    private var notes: [String: Note] = [:]

    public init() {}

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

    public func ingest(_ incoming: [Note]) {
        for note in incoming {
            if var existing = notes[note.id] {
                existing.origins.formUnion(note.origins)
                notes[note.id] = existing
            } else {
                notes[note.id] = note
            }
        }
    }

    public func sources() -> [Source] {
        sourceList
    }

    public func all() -> [Note] {
        notes.values.sorted(by: Self.storeOrder)
    }

    public func trends() -> [Note] {
        all().filter { $0.origins.contains(.trending) }
    }

    private static func storeOrder(_ a: Note, _ b: Note) -> Bool {
        if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
        return a.id < b.id
    }
}
