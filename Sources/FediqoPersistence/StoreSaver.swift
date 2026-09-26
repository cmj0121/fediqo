import FediqoCore
import Foundation
import os
import Synchronization

/// The one owner of writing the store to disk. The app's scene phase, its quit, and a drop by
/// time all come here, and nothing else writes the index.
///
/// **Saves are serialized, and each one reads the store only once the write before it has
/// landed.** Two saves that each took a snapshot and then raced to write could land in either
/// order, and the older snapshot landing last would put back what the newer one had dropped. So
/// every save waits for the one before it and only then takes its snapshot: whatever lands last
/// was read last.
///
/// **At most one save waits.** A save asked for while another is already waiting to start joins
/// that one: it will read the store after this call anyway, so a second copy would write the same
/// thing twice. And a save that finds the store at the revision it last wrote writes nothing.
///
/// **The write is off the main actor**, on GRDB's own queue, so a quit or a backgrounding waits
/// for it without the interface stopping while it runs.
///
/// **A failure is logged and thrown.** A save that did not land is the reader's posts at risk,
/// and a `try?` at the call site would make that invisible; a caller with nothing to do about it
/// may still drop the error, because it is already in the log.
public actor StoreSaver {
    /// Writes one snapshot to the index.
    public typealias Write = @Sendable (
        _ sources: [Source], _ notes: [Note], _ said: [SourceProfile]
    ) async throws -> Void

    /// How a `flush(deadline:)` ended.
    public enum Outcome: Equatable, Sendable {
        case saved
        case failed
        case timedOut
    }

    /// Long enough for any index this app writes; short enough that a hung write reads as a slow
    /// quit rather than a broken one.
    public static let deadline: Duration = .seconds(3)

    private static let log = Logger(subsystem: "Fediqo", category: "index")

    private let store: ItemStore
    private let write: Write?
    /// The save queued last, running or waiting. The next save starts after it.
    private var tail: Task<Void, any Error>?
    /// The save waiting to start, if one is; a new `save()` joins it.
    private var waiting: (id: Int, task: Task<Void, any Error>)?
    private var nextID = 0
    /// The store revision the last write landed, or nil before the first.
    private var written: Int?

    /// `write` is `nil` when this run must not write at all — the fail-closed case of
    /// `StoreFile.open(at:now:)`. Every save is then a logged no-op.
    public init(store: ItemStore, write: Write?) {
        self.store = store
        self.write = write
        if write == nil {
            Self.log.error("No index this run: nothing read will be saved")
        }
    }

    /// Saves into `file`, or nowhere when it is `nil`.
    public init(store: ItemStore, file: StoreFile?) {
        var write: Write?
        if let file {
            write = { sources, notes, said in
                try await file.save(sources: sources, notes: notes, said: said)
            }
        }
        self.init(store: store, write: write)
    }

    /// Runs `body` where a save would run: after every save asked for before it, and before any
    /// asked for after — so a read back that writes the index and replaces the store inside it
    /// (#247) is never raced by a save writing the old snapshot over the new index.
    public func exclusively<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            _ = await previous?.result
            return try await body()
        }
        tail = Task { _ = try await task.value }
        return try await task.value
    }

    /// What a launch's sweep found of a read back killed between moving the old index aside
    /// and finishing (#247): said here, where the index's log is, and only as a count.
    public static func reportHalfCommits(_ count: Int) {
        guard count > 0 else { return }
        log.notice("Found \(count, privacy: .public) read back(s) that did not finish; the old index is kept aside")
    }

    /// Writes what the store holds now, after every save asked for before this one.
    public func save() async throws {
        if let waiting { return try await waiting.task.value }
        nextID += 1
        let id = nextID
        let previous = tail
        let task = Task {
            _ = await previous?.result
            self.started(id)
            try await self.writeNow()
        }
        waiting = (id, task)
        tail = task
        try await task.value
    }

    /// `save()`, but answered by `deadline` whatever the write is doing: a write that hangs — a
    /// locked file, a disk that stopped answering — must not turn a quit into one that never
    /// happens. Past the deadline the write is left running and the caller goes on.
    public nonisolated func flush(deadline: Duration = StoreSaver.deadline) async -> Outcome {
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once(continuation)
            let timer = Task {
                try await Task.sleep(for: deadline)
                once.resume(.timedOut)
            }
            Task {
                let outcome: Outcome
                do {
                    try await self.save()
                    outcome = .saved
                } catch {
                    outcome = .failed
                }
                timer.cancel()
                once.resume(outcome)
            }
        }
        if outcome == .timedOut {
            Self.log.error("Saving the index did not finish within the deadline")
        }
        return outcome
    }

    private func started(_ id: Int) {
        if waiting?.id == id { waiting = nil }
    }

    private func writeNow() async throws {
        guard let write else { return }
        let snapshot = await store.snapshot()
        guard snapshot.revision != written else { return }
        do {
            try await write(snapshot.sources, snapshot.notes, snapshot.said)
            written = snapshot.revision
        } catch {
            Self.log.error("Saving the index failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

/// One answer to a flush, whichever of the save and the deadline comes first.
private final class Once: Sendable {
    private let continuation: Mutex<CheckedContinuation<StoreSaver.Outcome, Never>?>

    init(_ continuation: CheckedContinuation<StoreSaver.Outcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ outcome: StoreSaver.Outcome) {
        continuation.withLock { $0.take() }?.resume(returning: outcome)
    }
}
