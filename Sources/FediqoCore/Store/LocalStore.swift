import Foundation
import GRDB
import os

/// The one SQLite database everything Fediqo remembers lives in.
///
/// The schema is `docs/schema.sql`, shipped as a resource and executed verbatim by migration
/// `001`; a test holds the two copies identical so the document never drifts from the code.
/// `DatabaseQueue` already serialises access, so this is a thin `Sendable` wrapper rather than
/// an actor — a second lock around the first would only add waiting.
public final class LocalStore: Sendable {
    /// Where the store talks about itself. Never a post, never a row — paths, errors, counts.
    static let log = Logger(subsystem: "fediqo", category: "store")

    private let queue: DatabaseQueue

    /// Opens (and migrates) the database at `path`, creating it on first use.
    public convenience init(path: String) throws {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration())
        // WAL lets a read proceed while a refresh writes. Set outside any transaction, once;
        // SQLite remembers it in the file.
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try self.init(queue: queue, path: path)
    }

    /// A store that lives only as long as this object. For tests and previews.
    public static func inMemory() throws -> LocalStore {
        try LocalStore(queue: DatabaseQueue(configuration: configuration()), path: ":memory:")
    }

    private init(queue: DatabaseQueue, path: String) throws {
        self.queue = queue
        let migrated = try Self.migrate(queue)
        Self.log.info("opened \(path, privacy: .public), migrations run: \(migrated, privacy: .public)")
    }

    /// The app's database, at `<Application Support>/Fediqo/store.sqlite`. The store never
    /// blocks the screen: a file that is not a database is set aside and replaced; anything
    /// else is logged, and the app runs without a store and simply remembers nothing.
    public static func openDefault() -> LocalStore? {
        var path = "<Application Support>/Fediqo/store.sqlite"
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Fediqo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appending(path: "store.sqlite").path(percentEncoded: false)
            return try openRecovering(path: path)
        } catch {
            log.error("could not open \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `init(path:)`, and — if the file there is not a database SQLite can read — the file is
    /// set aside as `store.sqlite.corrupt-<seconds>` and a fresh one opened in its place. A
    /// store that cannot be read is worth less than an empty one; the old bytes stay on disk
    /// for whoever wants to look. Any other failure is thrown as it is.
    public static func openRecovering(path: String, now: Date = Date()) throws -> LocalStore {
        do {
            return try LocalStore(path: path)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            let aside = "\(path).corrupt-\(Int(now.timeIntervalSince1970))"
            log.error("\(path, privacy: .public) is not a database (\(error.resultCode.rawValue)); setting it aside as \(aside, privacy: .public)")
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try FileManager.default.moveItem(atPath: path + suffix, toPath: aside + suffix)
            }
            return try LocalStore(path: path)
        }
    }

    public func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await queue.read(block)
    }

    public func write<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await queue.write(block)
    }

    /// `read` / `write` without the hop. `ServerStore` is a synchronous `@MainActor` protocol
    /// — the screens read `servers` as a plain property — so its SQLite implementation needs
    /// the queue's blocking entry. Reserved for the server list's few one-row statements;
    /// posts keep going through the async pair.
    func readSync<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    func writeSync<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.write(block)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        // GRDB's default, but the schema says it out loud, so the code does too.
        config.foreignKeysEnabled = true
        return config
    }

    /// Runs what has not run yet and says how many that was. A migration that fails is logged
    /// here, where the path and the version are known, and thrown to whoever opened the store.
    @discardableResult
    private static func migrate(_ queue: DatabaseQueue) throws -> Int {
        let migrator = migrator()
        do {
            let pending = try queue.read { db in try migrator.completedMigrations(db) }
            try migrator.migrate(queue)
            return migrator.migrations.count - pending.count
        } catch {
            log.error("migration failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001") { db in
            try db.execute(sql: schema())
            // The file seeds created_at = 0; the migration is what knows when it ran.
            try db.execute(sql: "UPDATE protocols SET created_at = ?", arguments: [milliseconds(Date())])
        }
        return migrator
    }

    /// The bundled copy of `docs/schema.sql`. Missing means a broken build, not a runtime case.
    static func schema() throws -> String {
        let url = Bundle.module.url(forResource: "schema", withExtension: "sql")!
        return try String(contentsOf: url, encoding: .utf8)
    }
}
