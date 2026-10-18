import FediqoCore
import Foundation

/// The one build of a store's words index for a run (#360, K-3): started once the timeline
/// shows, set going again whenever there is more to do, and stood down while the device locks.
///
/// - **Each of its writes is where a save would run** (`StoreSaver.exclusively`): after every save
///   asked for before it, never beside a read back's commit or a connection being made again
///   (`StoreFile.remakeConnection`). A pause after each, so pages and saves go between.
/// - **Set going again** whenever a save left more due than it makes the docs of itself — an
///   older build's rewrite, a read back — and at every wake-up of the device; where it is running
///   it goes round once more when it ends. What is built already costs one read to find so.
/// - **Stood down while protected data is unavailable**: it stops before its next write, without
///   a word, and the next wake-up sets it going from where it stood.
/// - **A failure is said in the log**, by kind alone, and the build tried again at the next
///   asking. **Ended with the run**: cancelled, and never set going again.
public actor WordsBuilder {
    /// Runs one write of the build where a save would run.
    typealias Exclusively = @Sendable (@escaping @Sendable () async throws -> Bool) async throws -> Bool

    private let file: StoreFile
    private let exclusively: Exclusively
    private let protected: ProtectedData
    private let chunk: Int
    private let pause: Duration
    private let capable: Bool
    private var running: Task<Void, Never>?
    private var listening: Task<Void, Never>?
    /// Asked for again while running: it goes round once more.
    private var again = false
    private var ended = false
    /// How many builds stopped on a failure, for a test to read.
    private(set) var failures = 0
    /// How many times a build was set going, for a test to read.
    private(set) var runs = 0

    public init(file: StoreFile, saver: StoreSaver?, protected: ProtectedData = .always) {
        self.init(
            file: file,
            exclusively: { body in
                guard let saver else { return try await body() }
                return try await saver.exclusively(body)
            },
            protected: protected, chunk: StoreFile.wordsChunk, pause: StoreFile.wordsPause, capable: StoreFile.wordsCapable
        )
    }

    init(file: StoreFile, exclusively: @escaping Exclusively, protected: ProtectedData, chunk: Int, pause: Duration, capable: Bool) {
        self.file = file
        self.exclusively = exclusively
        self.protected = protected
        self.chunk = chunk
        self.pause = pause
        self.capable = capable
    }

    /// Sets the build going, and keeps it going from here: a save that leaves much due, and a
    /// wake-up of the device, set it going again.
    public func begin() {
        guard !ended, listening == nil else { return }
        file.onWordsLeftDue { [weak self] in
            guard let self else { return }
            Task { await self.start() }
        }
        let changes = protected.changes()
        listening = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.start()
            }
        }
        start()
    }

    /// Stops it for good: the run is ending.
    public func end() {
        ended = true
        running?.cancel()
        listening?.cancel()
        file.onWordsLeftDue(nil)
    }

    /// Sets a build going unless one is; where one is, it goes round once more.
    func start() {
        guard !ended, capable else { return }
        guard running == nil else {
            again = true
            return
        }
        runs += 1
        running = Task(priority: .utility) { [weak self] in
            await self?.build()
        }
    }

    /// Until the build in hand, and any it set going again, has ended: for a test.
    func idle() async {
        while let running {
            await running.value
        }
    }

    private func build() async {
        let (file, chunk, pause, capable, protected, exclusively) = (file, chunk, pause, capable, protected, exclusively)
        do {
            guard protected.flag(), try await exclusively({
                try await file.db.write { db in try StoreFile.makeWords(db, capable: capable) }
            }) else { return finished() }
            _ = try await exclusively {
                try await file.db.write { db in
                    // Both, as `buildWords` makes them: a read back's file comes with neither
                    // (`dropDerived`), and a keyword page without the odd ones reads slowly.
                    try db.execute(sql: StoreFile.reblogsIndex)
                    try db.execute(sql: StoreFile.oddReblogsIndex)
                }
                return true
            }
            for step in [{ try await file.buildWordsStep(chunk: chunk) }, { try await file.mergeWordsStep() }] as [@Sendable () async throws -> Bool] {
                while !Task.isCancelled, protected.flag(), try await exclusively(step) {
                    if pause > .zero { try await Task.sleep(for: pause) }
                }
            }
        } catch is CancellationError {
        } catch {
            failures += 1
            NetLog.index.error("Building the words index stopped: \(StoreSaver.kind(of: error), privacy: .public)")
        }
        finished()
    }

    private func finished() {
        running = nil
        if again, !ended {
            again = false
            start()
        }
    }
}
