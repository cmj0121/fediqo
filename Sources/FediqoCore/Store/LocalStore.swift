import Foundation
import GRDB
import os

/// The one SQLite database everything Fediqo remembers lives in.
///
/// The schema is `docs/schema.sql`, shipped as a resource and executed verbatim by migration
/// `001`; each later migration is a `docs/schema-<version>.sql` run the same way. A test holds
/// every pair of copies identical so the documents never drift from the code.
/// `DatabaseQueue` already serialises access, so this is a thin `Sendable` wrapper rather than
/// an actor — a second lock around the first would only add waiting.
public final class LocalStore: Sendable {
    /// Where the store talks about itself. Never a post, never a row — paths, errors, counts.
    ///
    /// Public because a write can be started from outside Core and finish long after the
    /// caller has gone: the reader's timelines are saved from the app, in a task nobody is
    /// waiting on, and a failure there is a fact about this store rather than about a screen.
    public static let log = Logger(subsystem: "fediqo", category: "store")

    private let queue: DatabaseQueue

    /// Where the database is, as it was opened. Kept because a file has a size and the
    /// statistics screen asks for it; `:memory:` for a store that has no file, which
    /// `FileManager` reads as "not there" without anyone having to test for it.
    let path: String

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
        self.path = path
        let migrated = try Self.migrate(queue)
        Self.log.info("opened \(path, privacy: .public), migrations run: \(migrated, privacy: .public)")
    }

    /// Yesterday's database: migrated up to `version` and no further. A test hook, so an
    /// upgrade test can build the store an older app left behind before reopening it here.
    init(path: String, upTo version: String) throws {
        self.queue = try DatabaseQueue(path: path, configuration: Self.configuration())
        self.path = path
        try Self.migrator().migrate(queue, upTo: version)
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

    /// Everything this store holds, gone — and the schema built again behind it, so what is
    /// left is the database a first launch would have opened.
    ///
    /// Rows rather than the file: the connection stays the one every screen is already holding,
    /// so nothing has to be told that the store it was given has been replaced. Every table
    /// goes, migrations included, and then the migrator runs from 001 as it did on the first
    /// launch — which is also what makes this the one place in the app allowed to destroy
    /// anything a network handed over. It is the reader asking for a fresh install; every other
    /// path still obeys append-only.
    public func eraseEverything() async throws {
        try await queue.erase()
        try Self.migrate(queue)
        Self.log.info("erased \(self.path, privacy: .public) and built the schema again")
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
            try db.execute(sql: schema(named: "schema"))
            // The file seeds created_at = 0; the migration is what knows when it ran.
            try db.execute(sql: "UPDATE protocols SET created_at = ?", arguments: [milliseconds(Date())])
        }
        migrator.registerMigration("002") { db in
            try db.execute(sql: schema(named: "schema-002"))
        }
        migrator.registerMigration("003") { db in
            try db.execute(sql: schema(named: "schema-003"))
        }
        migrator.registerMigration("004") { db in
            try db.execute(sql: schema(named: "schema-004"))
            // Two more seeded lookups, stamped the way 001 stamps protocols: the file writes
            // the rows, the migration is what knows when they arrived.
            let now = milliseconds(Date())
            try db.execute(sql: "UPDATE feeds SET created_at = ?", arguments: [now])
            try db.execute(sql: "UPDATE filter_kinds SET created_at = ?", arguments: [now])
        }
        return migrator
    }

    /// The bundled copy of `docs/<name>.sql`. Missing means a broken build, not a runtime case.
    static func schema(named name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "sql")!
        return try String(contentsOf: url, encoding: .utf8)
    }
}
