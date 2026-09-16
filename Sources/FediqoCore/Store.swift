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

    /// Takes notes in, keeping the first of any id and unioning what the later arrivals know.
    ///
    /// **The first copy wins and only the sets grow.** Two servers that both carry one Mastodon
    /// status send two readings of it, minutes or hours apart, and neither is more true than the
    /// other; picking the first is the one rule that does not make the timeline flicker as the
    /// joins land. What the later copy does carry that the first cannot is *how it arrived* — the
    /// origin, and since decision 9 the host — and those are unioned rather than dropped, because
    /// they are facts about the reading and not about the post.
    ///
    /// `hosts` is the half that makes `remove(host:)` answerable; see `Note.hosts` for why the
    /// stamp cannot do that job.
    public func ingest(_ incoming: [Note]) {
        for note in incoming {
            if var existing = notes[note.id] {
                existing.origins.formUnion(note.origins)
                existing.hosts.formUnion(note.hosts)
                notes[note.id] = existing
            } else {
                notes[note.id] = note
            }
        }
    }

    /// Lets go of one server: the source, the boards the reader picked on it, and the notes it
    /// carried here.
    ///
    /// **This is the other half of `ShellSession.clear`'s argument, and the half that takes the
    /// boards.** Clear keeps them on purpose — they are the reader's choice rather than anything
    /// the server left behind, and a button promising "what goes comes back" must not take a pick
    /// of eight boards out of forty that does not come back by itself. Remove makes no such
    /// promise: it is the reader saying they have stopped reading this server, so the source, the
    /// picks made on it and the threads it served all go together, because that is one decision.
    ///
    /// **A note goes when its last host does, never when its stamp does.** `Note.source` names
    /// whichever server handed the note over first, and for a Mastodon status that is an accident
    /// of join order rather than a route — see `Note.hosts`. Removing by the stamp would take rows
    /// away from an instance still showing them and strand rows the removed instance was the only
    /// way to. So each note is struck off for this host, and only a note nobody is left reading is
    /// dropped.
    ///
    /// Silent where the host is not here, for the reason `subscribe(host:to:)` is: nothing in this
    /// package puts a source in the list, or takes one out of it, by a side door.
    public func remove(host raw: String) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        notes = notes.compactMapValues { note in
            var note = note
            guard note.hosts.remove(host) != nil else { return note }
            return note.hosts.isEmpty ? nil : note
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
