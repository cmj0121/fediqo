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
/// **Nobody has to ask.** `follow()` listens to the store and saves behind it — late and seldom,
/// because a save writes every note down again — so a landing no caller thought to save is on
/// disk within the minute. What is this device's alone, and whoever is about to read the file,
/// still asks: `save()` and `flush(deadline:)` write at once and take the followed save with them.
///
/// **The texts the person pressed to send are a part of their own** (`Unsent`): written before
/// the items by every save that finds them moved, and by themselves by `saveUnsent()`, which
/// writes that handful of rows and no post — what a send waits for before its request leaves.
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

    /// Writes the texts the person pressed to send, in the place of the ones written before.
    public typealias WriteUnsent = @Sendable (_ unsent: [Unsent]) async throws -> Void

    /// How a `flush(deadline:)` ended.
    public enum Outcome: Equatable, Sendable {
        case saved
        case failed
        case timedOut
    }

    /// Long enough for any index this app writes; short enough that a hung write reads as a slow
    /// quit rather than a broken one.
    public static let deadline: Duration = .seconds(3)

    /// After a change, before the save that follows it starts: a read lands page after page, and
    /// the burst is one write.
    public static let quiet: Duration = .seconds(2)
    /// The least time between two followed saves. A save is every note written again, so reading
    /// on for an hour is at most sixty of them; the one knob, set against the durations logged.
    public static let gap: Duration = .seconds(60)

    private static let log = Logger(subsystem: "Fediqo", category: "index")

    private let store: ItemStore
    private let write: Write?
    private let writeUnsent: WriteUnsent?
    /// The save queued last, running or waiting. The next save starts after it.
    private var tail: Task<Void, any Error>?
    /// The save waiting to start, if one is; a new `save()` joins it.
    private var waiting: (id: Int, task: Task<Bool, any Error>)?
    private var nextID = 0
    /// The store revision the last write landed, or nil before the first.
    private var written: Int?
    /// The revision of the texts the last write of them landed (`ItemStore.unsentRevision`).
    /// A store starts at 0 with what it read back, which is what the file holds.
    private var writtenUnsent = 0

    /// `write` is `nil` when this run must not write at all — the fail-closed case of
    /// `StoreFile.open(at:now:)`. Every save is then a logged no-op.
    public init(store: ItemStore, write: Write?, writeUnsent: WriteUnsent? = nil) {
        self.store = store
        self.write = write
        self.writeUnsent = writeUnsent
        if write == nil {
            Self.log.error("No index this run: nothing read will be saved")
        }
    }

    /// Saves into `file`, or nowhere when it is `nil`.
    public init(store: ItemStore, file: StoreFile?) {
        var write: Write?
        var writeUnsent: WriteUnsent?
        if let file {
            write = { sources, notes, said in
                try await file.save(sources: sources, notes: notes, said: said)
            }
            writeUnsent = { try await file.save(unsent: $0) }
        }
        self.init(store: store, write: write, writeUnsent: writeUnsent)
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

    /// What a launch's sweep found of a read back killed after moving the old index aside and
    /// before the new one was in its place (#247): how many had the old index put back, and how
    /// many could not be settled — said here, where the index's log is, and only as counts.
    public static func reportHalfCommits(putBack: Int, unsettled: Int) {
        if putBack > 0 {
            log.notice("Found \(putBack, privacy: .public) read back(s) that did not finish; the index is put back as it was")
        }
        if unsettled > 0 {
            log.error("Found \(unsettled, privacy: .public) read back(s) that did not finish and could not be settled; no index is opened this run")
        }
    }

    /// Writes what the store holds now, after every save asked for before this one.
    public func save() async throws {
        _ = try await saveAndTell()
    }

    /// Writes the texts the person pressed to send, where they have moved, and nothing else:
    /// where a save would run — after every save asked for before it, and never inside a read
    /// back's commit — but no post is written again for it. **What a send waits for** before
    /// its request leaves, so that a text the source may have taken is on disk first; a full
    /// save would have the request wait for every note to be written.
    ///
    /// **Says whether the texts are on disk as the store holds them**: false where this run
    /// writes nowhere, and a write that failed throws. A send asks, and does not leave on a no.
    ///
    /// **A read back needs nothing cleared here.** It replaces the posts through the open file
    /// (`StoreFile.save(sources:notes:said:)`), which touches no text, and `ItemStore.replace`
    /// leaves the texts held: the table and the store agree before it and after, so the
    /// revision last written stays true. Where this run has no file it writes no text at all.
    @discardableResult
    public func saveUnsent() async throws -> Bool {
        try await exclusively { try await self.writeUnsentNow() }
    }

    @discardableResult
    private func writeUnsentNow() async throws -> Bool {
        guard let writeUnsent else { return false }
        let snapshot = await store.unsentSnapshot()
        guard snapshot.revision != writtenUnsent else { return true }
        do {
            try await writeUnsent(snapshot.unsent)
            writtenUnsent = snapshot.revision
            return true
        } catch {
            Self.log.error("Saving what waits to be sent failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// `save()`, and whether the save this call made or joined wrote anything: false where it
    /// found the store at the revision last written.
    private func saveAndTell() async throws -> Bool {
        if let waiting { return try await waiting.task.value }
        nextID += 1
        let id = nextID
        let previous = tail
        let task = Task {
            _ = await previous?.result
            self.started(id)
            return try await self.writeNow()
        }
        waiting = (id, task)
        tail = Task { _ = try await task.value }
        return try await task.value
    }

    /// `save()`, written whether or not the store has changed since the last write (#295): what
    /// a save does besides writing rows — dropping a store put aside, once the person has been
    /// told — has to be able to happen in a run where nothing new arrives.
    public func resave() async throws {
        written = nil
        try await save()
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

    /// The store, followed: each change that moved the revision a save writes is saved by itself,
    /// with nobody asking. Runs until the task it runs in is cancelled; the app starts it once.
    ///
    /// **One save a burst, and one a `gap`.** A change arms a save `quiet` from now, or `gap`
    /// after the followed save before it where that is later. Changes landing while one is armed
    /// do not push it out — it reads the store when it starts — and those landing while one
    /// writes, or inside the gap after it, arm the next.
    ///
    /// **A save asked for meanwhile takes the armed one with it**: the follower wakes to a store
    /// already written — or finds it so once the asked save under way has landed — writes nothing
    /// and owes no gap. Only a followed save that wrote is owed one. A change that moved no
    /// written revision (#208) arms nothing. A followed save that fails is in the log and is not
    /// tried again by itself; the next change, or the next ask, is.
    ///
    /// `sleep` is `Task.sleep` but for a test, which drives it by hand. Every hop here is on this
    /// actor but the store's own, so nothing of it touches the main actor.
    public func follow(
        quiet: Duration = StoreSaver.quiet, gap: Duration = StoreSaver.gap,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        // Listening before the first look, so a change between the two is not missed; and the
        // first look is for what changed before anything listened — since the last write, or
        // since the store was made where nothing has been written yet: a store starts at
        // revision 0, one a launch read back included (`ItemStore.revision`).
        let changes = await store.changes()
        var heard = written ?? 0
        do {
            heard = try await follow(from: heard, quiet: quiet, gap: gap, sleep: sleep)
            for await _ in changes {
                heard = try await follow(from: heard, quiet: quiet, gap: gap, sleep: sleep)
            }
        } catch {
            // Cancelled in a wait: whoever stopped this flushes, as a quit does.
        }
    }

    /// One change heard: the save it arms, and the gap that save is owed. Returns the revision
    /// the store was at when this last looked; throws only what `sleep` throws.
    private func follow(
        from heard: Int, quiet: Duration, gap: Duration,
        sleep: @Sendable (Duration) async throws -> Void
    ) async throws -> Int {
        let revision = await store.revision
        guard revision != heard, revision != written else { return revision }
        try await sleep(quiet)
        let armed = await store.revision
        guard armed != written else { return armed }
        // A failure is already in the log, and there is nobody here to tell.
        let wrote = (try? await saveAndTell()) ?? false
        if wrote { try await sleep(gap - quiet) }
        return armed
    }

    private func started(_ id: Int) {
        if waiting?.id == id { waiting = nil }
    }

    /// Whether anything of the items was written. The texts go first, where they moved.
    private func writeNow() async throws -> Bool {
        try await writeUnsentNow()
        guard let write else { return false }
        let snapshot = await store.snapshot()
        guard snapshot.revision != written else { return false }
        do {
            let began = ContinuousClock.now
            try await write(snapshot.sources, snapshot.notes, snapshot.said)
            written = snapshot.revision
            // Only a count and a time: what `gap` is set by.
            let took = ContinuousClock.now - began
            Self.log.info("Saved \(snapshot.notes.count, privacy: .public) note(s) in \(String(describing: took), privacy: .public)")
            return true
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
