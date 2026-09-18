import FediqoCore
import Foundation
import os

/// Where a save writes a snapshot of the store. `StoreFile` is the one the app uses; a test hands
/// in one that is slow, or that fails, to pin what the saver does about it.
public protocol IndexWriter: Sendable {
    func write(sources: [Source], notes: [Note]) async throws
}

extension StoreFile: IndexWriter {
    public func write(sources: [Source], notes: [Note]) async throws {
        try await db.write { db in try Self.replaceAll(in: db, sources: sources, notes: notes) }
    }
}

/// The one owner of writing the store to disk. The app's scene phase, its quit, and a drop by
/// time all call `save()`, and nothing else writes the index.
///
/// **Saves are serialized, and each one reads the store only once the save before it is
/// written.** Two saves that each took a snapshot and then raced to write could land in either
/// order, and the older snapshot landing last would put back what the newer one had dropped. So
/// every save waits for the one before it and only then takes its snapshot: whatever lands last
/// was read last.
///
/// **The write is off the main actor.** It runs here, on this actor, into GRDB's own queue, so a
/// quit or a backgrounding waits for it without the interface stopping while it runs.
///
/// **A failure is logged and thrown.** A save that did not land is the reader's posts at risk,
/// and a `try?` at the call site would make that invisible; a caller with nothing to do about it
/// may still drop the error, because it is already in the log.
public actor StoreSaver {
    private let store: ItemStore
    private let index: (any IndexWriter)?
    /// The save queued last. The next save waits for it before reading the store.
    private var last: Task<Void, any Error>?

    static let log = Logger(subsystem: "Fediqo", category: "index")

    /// `index` is `nil` when this run must not write at all — the fail-closed case of
    /// `StoreFile.open(at:now:)`. Every save is then a logged no-op.
    public init(store: ItemStore, index: (any IndexWriter)?) {
        self.store = store
        self.index = index
        if index == nil {
            Self.log.error("No index this run: nothing read will be saved")
        }
    }

    /// Writes what the store holds now, after every save asked for before this one.
    public func save() async throws {
        let previous = last
        let task = Task {
            _ = await previous?.result
            try await self.write()
        }
        last = task
        try await task.value
    }

    private func write() async throws {
        guard let index else { return }
        let snapshot = await store.snapshot()
        do {
            try await index.write(sources: snapshot.sources, notes: snapshot.notes)
        } catch {
            Self.log.error("Saving the index failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
