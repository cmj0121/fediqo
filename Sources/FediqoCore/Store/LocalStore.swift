import Foundation
import GRDB

/// The one SQLite database everything Fediqo remembers lives in.
///
/// The schema is `docs/schema.sql`, shipped as a resource and executed verbatim by migration
/// `001`; a test holds the two copies identical so the document never drifts from the code.
/// `DatabaseQueue` already serialises access, so this is a thin `Sendable` wrapper rather than
/// an actor — a second lock around the first would only add waiting.
public final class LocalStore: Sendable {
    private let queue: DatabaseQueue

    /// Opens (and migrates) the database at `path`, creating it on first use.
    public init(path: String) throws {
        queue = try DatabaseQueue(path: path, configuration: Self.configuration())
        // WAL lets a read proceed while a refresh writes. Set outside any transaction, once;
        // SQLite remembers it in the file.
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try Self.migrator().migrate(queue)
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator().migrate(queue)
    }

    /// A store that lives only as long as this object. For tests and previews.
    public static func inMemory() throws -> LocalStore {
        try LocalStore(queue: DatabaseQueue(configuration: configuration()))
    }

    public func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await queue.read(block)
    }

    public func write<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await queue.write(block)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        // GRDB's default, but the schema says it out loud, so the code does too.
        config.foreignKeysEnabled = true
        return config
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001") { db in
            try db.execute(sql: schema())
            // The file seeds created_at = 0; the migration is what knows when it ran.
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try db.execute(sql: "UPDATE protocols SET created_at = ?", arguments: [now])
        }
        return migrator
    }

    /// The bundled copy of `docs/schema.sql`. Missing means a broken build, not a runtime case.
    static func schema() throws -> String {
        let url = Bundle.module.url(forResource: "schema", withExtension: "sql")!
        return try String(contentsOf: url, encoding: .utf8)
    }
}
