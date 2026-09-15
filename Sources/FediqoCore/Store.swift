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
