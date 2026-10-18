import FediqoCore
import Foundation
import GRDB

// A read back into a run that has its file open (#360, K-10): the file this run holds is set
// aside by `VACUUM INTO` (`snapshot(into:)`), the package's staged file is copied into it page by
// page by SQLite's backup, and an undo copies the aside back the same way. No row passes through
// Swift, and the open connection — the saver's, the pool's, the pages' — is the one written.

extension StoreFile {
    /// The staged file of a read back made what it is to become (#360): every derived object
    /// dropped — a package carries none, and one that came all the same is not this build's to
    /// trust — so the file this run holds makes its own after the commit (`makePageIndex`, the
    /// words builder). In one transaction, on the staged file alone, before it is rebuilt.
    func dropDerivedObjects() throws {
        try db.write { db in try Self.dropDerived(db) }
    }

    /// The hosts this file holds a source row of, read by SQL: what a read back's undo owes the
    /// removal of once the file is put back (`ItemStore.oweEverything`).
    func sourceHosts() throws -> [String] {
        try db.read { db in try String.fetchAll(db, sql: "SELECT host FROM source ORDER BY rowid") }
    }

    /// The key of every row this file holds, read by SQL and nothing decoded: what a store held
    /// whole — never the app's, which is held in part — is told the file holds once a read back
    /// is undone (`ItemStore.oweEverything`).
    func noteKeys() throws -> [NoteKey] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT host, id FROM note ORDER BY rowid").map { NoteKey(host: $0["host"], id: $0["id"]) }
        }
    }

    /// `other`'s file copied into this one whole, by SQLite's backup (#360, K-10): one write on
    /// this store's own connection, in the rollback journal as any save — all of it or, cut
    /// short, none. What this file held is gone from it, pages and all: it is now a page for page
    /// copy of `other`, which holds no page free (`scrub`, `VACUUM INTO`), and a file longer
    /// than `other` is cut to its length.
    ///
    /// **The texts waiting to be sent are this file's, not `other`'s** (`Unsent`): untouched by a
    /// read back and by its undo, they are copied into `other` first — a scratch copy, the
    /// staging or the aside — in place of what it holds, `secure_delete` on there too.
    ///
    /// **Called where a save would run** (`StoreSaver.exclusively`): nothing of the saver's is in
    /// flight on this connection. Readers on connections of their own wait for the backup's lock
    /// as for any write, and find the file changed under the schema they knew.
    func copy(from other: DatabaseQueue) async throws {
        defer { wroteWhole() }
        try await db.writeWithoutTransaction { dest in try Self.copy(other, into: dest) }
    }

    /// `copy(from:)` on a connection `dest` already has: the texts of `dest` carried into
    /// `other`, then `other` copied into `dest` by SQLite's backup.
    static func copy(_ other: DatabaseQueue, into dest: Database) throws {
        let texts = try Row.fetchAll(dest, sql: "SELECT * FROM unsent ORDER BY rowid").map { row in
            (columns: Array(row.columnNames), values: Array(row.databaseValues))
        }
        try other.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM unsent")
                for text in texts {
                    let names = text.columns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
                    let marks = Array(repeating: "?", count: text.columns.count).joined(separator: ", ")
                    try db.execute(
                        sql: "INSERT INTO unsent (\(names)) VALUES (\(marks))",
                        arguments: StatementArguments(text.values)
                    )
                }
                return .commit
            }
        }
        try other.read { source in try source.backup(to: dest) }
    }

    /// The file set aside by a read back (`snapshot(into:)`) in `folder`, copied back into this
    /// one (`copy(from:)`): a read back's undo.
    ///
    /// **An aside that is not there is a refusal**, never an empty store: SQLite would make one
    /// at the path and copy it over the file.
    func putBack(from folder: URL) async throws {
        let aside = try Self.aside(in: folder)
        defer { try? aside.close() }
        try await copy(from: aside)
    }

    /// The file a read back set aside in `folder`, opened; a refusal where it is not there.
    private static func aside(in folder: URL) throws -> DatabaseQueue {
        let path = folder.appendingPathComponent(indexName).path
        guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
        return try DatabaseQueue(path: path, configuration: Self.configuration())
    }

    /// `putBack(from:)` with no store open (#360): what a launch does with an aside whose undo a
    /// run named and did not live to do, before the index in `directory` is opened. The index
    /// standing there is copied over in one write — or, where none stands, the aside's is moved
    /// into its place.
    static func putBack(from folder: URL, into directory: URL) throws {
        let target = directory.appendingPathComponent(indexName)
        let aside = try aside(in: folder)
        defer { try? aside.close() }
        guard FileManager.default.fileExists(atPath: target.path) else {
            try aside.close()
            return try FileManager.default.moveItem(at: folder.appendingPathComponent(indexName), to: target)
        }
        let dest = try DatabaseQueue(path: target.path, configuration: Self.configuration())
        defer { try? dest.close() }
        try dest.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try copy(aside, into: db)
        }
    }
}
