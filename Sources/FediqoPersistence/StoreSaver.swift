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
/// **So are the notices** (`NoticeReach`): written by every save that finds them moved, after the
/// texts and before the items, and followed like the items, rewriting no post: a page of notices
/// read is on disk `quiet` after it lands where the follower is listening, and no later than
/// `gap` after the followed save before it where the follower is sleeping that out.
///
/// **The write is off the main actor**, on GRDB's own queue, so a quit or a backgrounding waits
/// for it without the interface stopping while it runs.
///
/// **A failure is logged and thrown.** A save that did not land is the reader's posts at risk,
/// and a `try?` at the call site would make that invisible; a caller with nothing to do about it
/// may still drop the error, because it is already in the log.
///
/// **Each part is written whatever became of the others.** The texts, the notices and the items
/// each have their own write, their own outcome and their own revision last written: a notices
/// write that fails does not keep a post from being saved, at a quit least of all. The save
/// throws afterwards, the first failure it met.
///
/// **And a write that failed is owed another** (`follow`): tried again by the follower, with
/// nobody asking, a `gap` later — `retries` times at most, until one lands.
public actor StoreSaver {
    /// Writes one snapshot to the index.
    public typealias Write = @Sendable (
        _ sources: [Source], _ notes: [Note], _ said: [SourceProfile]
    ) async throws -> Void

    /// Writes the texts the person pressed to send, in the place of the ones written before.
    public typealias WriteUnsent = @Sendable (_ unsent: [Unsent]) async throws -> Void

    /// Writes what each source said happened to the person, in the place of what was written.
    public typealias WriteNotices = @Sendable (_ notices: [NoticeReach]) async throws -> Void

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
    /// How many times running a write that failed is tried again by the follower, a `gap`
    /// apart, before it is left to the next change or the next ask.
    public static let retries = 5

    private static let log = Logger(subsystem: "Fediqo", category: "index")

    private let store: ItemStore
    private let write: Write?
    private let writeUnsent: WriteUnsent?
    private let writeNotices: WriteNotices?
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
    /// The same, of the notices (`ItemStore.noticesRevision`).
    private var writtenNotices = 0
    /// Whether a write of any part has failed since the last save that wrote every part: what
    /// the follower owes another try for.
    private var unlanded = false
    /// How many tries running the follower has made of a write that failed.
    private var retried = 0
    /// Wakes the follower, where one runs: the store changed, or a write failed.
    private var wake: AsyncStream<Void>.Continuation?
    /// Everyone told when a save has written every part after a write had failed. See `landings()`.
    private var landingListeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Each time a save writes every part **after a write of some part had failed**: whoever
    /// told the person that something could not be taken off this device yet learns here that
    /// it now has been — whichever window asked, and where it was the follower's own retry
    /// that landed, with nobody asking. Each call is its own stream, and only the newest is
    /// kept; one nobody reads any more drops itself.
    public func landings() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        landingListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopTelling(id) }
        }
        return stream
    }

    private func stopTelling(_ id: UUID) {
        landingListeners[id] = nil
    }

    /// A write of one part failed: the follower is told, and owes another.
    private func owe() {
        unlanded = true
        wake?.yield()
    }

    /// `write` is `nil` when this run must not write at all — the fail-closed case of
    /// `StoreFile.open(at:now:)`. Every save is then a logged no-op.
    public init(
        store: ItemStore, write: Write?, writeUnsent: WriteUnsent? = nil, writeNotices: WriteNotices? = nil
    ) {
        self.store = store
        self.write = write
        self.writeUnsent = writeUnsent
        self.writeNotices = writeNotices
        if write == nil {
            Self.log.error("No index this run: nothing read will be saved")
        }
    }

    /// Saves into `file`, or nowhere when it is `nil`.
    public init(store: ItemStore, file: StoreFile?) {
        var write: Write?
        var writeUnsent: WriteUnsent?
        var writeNotices: WriteNotices?
        if let file {
            write = { sources, notes, said in
                try await file.save(sources: sources, notes: notes, said: said)
            }
            writeUnsent = { try await file.save(unsent: $0) }
            writeNotices = { try await file.save(notices: $0) }
        }
        self.init(store: store, write: write, writeUnsent: writeUnsent, writeNotices: writeNotices)
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
            owe()
            throw error
        }
    }

    /// Writes the notices where they have moved. **Only a count is logged, and of a failure only
    /// what the store said of it**: a notice is other people's names and words.
    private func writeNoticesNow() async throws {
        guard let writeNotices else { return }
        let snapshot = await store.noticesSnapshot()
        guard snapshot.revision != writtenNotices else { return }
        do {
            try await writeNotices(snapshot.notices)
            writtenNotices = snapshot.revision
        } catch {
            Self.log.error("Saving the notices failed: \(String(describing: error), privacy: .public)")
            owe()
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
    /// written revision (#208) arms nothing.
    ///
    /// **A write that failed is tried again, by itself** (`retry`): any part's, a followed save's
    /// or one somebody asked for — a `gap` after the failure, and a `gap` after each try that
    /// fails too, `retries` times running. Past that nothing is slept for or written until the
    /// store next changes or somebody asks; a change, and a save that writes every part, each
    /// start the count again.
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
        // One thing to wait on for the two that wake this: the store changing, and a write
        // failing (`owe`). Only the newest is kept, as the store keeps only its newest change.
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        let heardChanges = Task {
            for await _ in changes { wake.yield() }
        }
        defer {
            heardChanges.cancel()
            self.wake = nil
        }
        var heard = Followed(items: written ?? 0, notices: writtenNotices)
        wake.yield()
        do {
            for await _ in wakes {
                heard = try await follow(from: heard, quiet: quiet, gap: gap, sleep: sleep)
                try await retry(gap: gap, sleep: sleep)
            }
        } catch {
            // Cancelled in a wait: whoever stopped this flushes, as a quit does.
        }
    }

    /// The try a failed write is owed: a `gap` on, every part that has moved since it was last
    /// written. Nothing where no write has failed since the last whole save, where one landed
    /// while this waited, or where `retries` have been made running — **so a disk that will not
    /// be written is asked a handful of times, a minute apart, and then let be**. A try that
    /// fails wakes the follower again (`owe`), which is what makes the next one.
    private func retry(gap: Duration, sleep: @Sendable (Duration) async throws -> Void) async throws {
        guard unlanded, retried < Self.retries else { return }
        retried += 1
        try await sleep(gap)
        // Read after the wait: a save somebody asked for meanwhile may have written it all.
        guard unlanded else { return }
        // A failure is already in the log, and is tried again from the top of the loop.
        if (try? await saveAndTell()) == true { try await sleep(gap) }
    }

    /// One change heard: the save it arms, and the gap that save is owed. Returns the revision
    /// the store was at when this last looked; throws only what `sleep` throws.
    ///
    /// **A page of notices arms a save as a landing does** and owes no gap: the gap is the price
    /// of writing every note again, and a save that found only the notices moved wrote none.
    ///
    /// **Only a change arms one.** A wake that is a write having failed finds no revision moved
    /// since this last looked and arms nothing here, whichever part failed: every part's
    /// failure is `retry`'s, under its one bound. The texts are never armed here at all — each
    /// is written by whoever pressed (`saveUnsent`) — so a write of them that fails is `retry`'s too.
    private func follow(
        from heard: Followed, quiet: Duration, gap: Duration,
        sleep: @Sendable (Duration) async throws -> Void
    ) async throws -> Followed {
        let revision = await followed()
        let itemsMoved = revision.items != heard.items && revision.items != written
        // Moved since this last looked, as the items are asked: a write of them that failed
        // has woken this too (`owe`), and that is `retry`'s to try again, within its bound —
        // not a change, which would be tried here a `quiet` apart for as long as it failed.
        let noticesMoved = revision.notices != heard.notices && revision.notices != writtenNotices
        guard itemsMoved || noticesMoved else { return revision }
        // The store changed: what is owed a write that failed is counted afresh.
        retried = 0
        try await sleep(quiet)
        let armed = await followed()
        guard armed.items != written, itemsMoved || armed.items != revision.items else {
            // Only the notices moved, or a save asked for meanwhile took the items with it.
            if armed.notices != writtenNotices { try? await exclusively { try await self.writeNoticesNow() } }
            return armed
        }
        // A failure is already in the log, and there is nobody here to tell.
        let wrote = (try? await saveAndTell()) ?? false
        if wrote { try await sleep(gap - quiet) }
        return armed
    }

    /// The two revisions a followed save writes by, read in one hop.
    private struct Followed: Equatable {
        var items: Int
        var notices: Int
    }

    /// Where this run writes no notices they are never found moved.
    private func followed() async -> Followed {
        let revisions = await store.revisions
        return Followed(items: revisions.items, notices: writeNotices == nil ? writtenNotices : revisions.notices)
    }

    private func started(_ id: Int) {
        if waiting?.id == id { waiting = nil }
    }

    /// Whether anything of the items was written. The texts go first, where they moved, then
    /// the notices, then the items — **each whatever became of the one before it**, so a part
    /// that cannot be written keeps no other from the file. Throws the first failure, after
    /// every part has had its turn.
    private func writeNow() async throws -> Bool {
        var failure: (any Error)?
        do { try await writeUnsentNow() } catch { failure = error }
        do { try await writeNoticesNow() } catch { failure = failure ?? error }
        var wrote = false
        do { wrote = try await writeItemsNow() } catch { failure = failure ?? error }
        if let failure { throw failure }
        if unlanded {
            unlanded = false
            for listener in landingListeners.values { listener.yield() }
        }
        retried = 0
        return wrote
    }

    private func writeItemsNow() async throws -> Bool {
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
            owe()
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
