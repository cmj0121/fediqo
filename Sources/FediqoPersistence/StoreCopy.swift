import FediqoCore
import Foundation
import GRDB

// The store as a take-away carries it (#360, K-9): the file copied whole by SQLite at one moment,
// on a connection of its own, and the copy made into what a package's store is — nothing a row
// of it was let go of, no text waiting to be sent, no notice, nothing still owed a load, and none
// of what this build makes beside the tables. No row passes through Swift.

extension StoreFile {
    /// What a copy holds, read of the copy itself by SQL: what a package's header says.
    struct TakenCopy: Sendable {
        let sources: [Source]
        let said: [SourceProfile]
        /// Every row the copy holds, as a whole store held every one of them as an item.
        let posts: Int
        /// The rows held as kept (#284), as a read back counts them (`keptCount`).
        let kept: Int
    }

    /// Every index this build makes beside the tables, by name, and every one it once made
    /// (`note_refers`): what a receiver makes again of its own, and what a copy carries none of.
    /// Read off the statements that make them, so a new one cannot be missed here.
    static let derivedIndexes: [String] = {
        let made = (pageIndexes + [reblogsIndex, oddReblogsIndex]).compactMap { sql -> String? in
            guard let range = sql.range(of: "CREATE INDEX IF NOT EXISTS ") else { return nil }
            return sql[range.upperBound...].split(separator: " ", maxSplits: 1).first.map(String.init)
        }
        return made + ["note_refers"]
    }()

    /// The words index's tables (K-3): `note_words`'s own shadow tables go with it.
    static let derivedTables = ["note_words", "note_words_due", "note_words_state"]

    /// This file copied into `folder` at one moment (#360, K-9): the first half of a take-away's
    /// copy, and the only one that reads the file. **Asked where a save would run, after every
    /// owed save** (`StoreSaver.afterSaving`): nothing of the saver's writes meanwhile, and the
    /// rest of the copy is `takenCopy(in:)`'s, done once saves may run again.
    ///
    /// **Read beside the store.** `VACUUM INTO` on a connection of its own that only reads
    /// (`readingConnection`): it holds the file's read lock while it copies, as a page's read
    /// does, so the store's own connection goes on reading pages meanwhile. A write beside the
    /// saver would wait the copy's length for its lock — and every read queued behind it on the
    /// store's connection with it — so the making of the pages' index on its way is waited for
    /// first (`pageIndexSettled`), and the other indexes are made where a save would run
    /// (`makeIndexes(in:)`). `VACUUM INTO` copies no free page of the file (#292). Cancelled, it
    /// is interrupted, and what it left is the caller's scratch to remove.
    func snapshot(into folder: URL) async throws {
        await pageIndexSettled()
        try Task.checkCancellation()
        let side = try readingConnection()
        do {
            try await side.vacuum(into: folder.appendingPathComponent(Self.indexName).path)
            try side.close()
        } catch {
            try? side.close()
            throw error
        }
    }

    /// The copy `snapshot(into:)` made in `folder`, made into what a take-away carries, and what
    /// it then holds — **the copy alone**, on a connection of its own, the store's file and its
    /// saver untouched.
    ///
    /// `secure_delete` on, so what it lets go is zeroed; **no journal** (`journal_mode = OFF`):
    /// the copy is scratch, thrown away whole on any failure, so a journal would only hold
    /// another copy of the pages changed — the texts, the notices and the indexes going among
    /// them — and make the peak on disk the copy, a rebuild's temporary copy and a journal at
    /// once. Without it the peak is the copy and its rebuild: twice the file at most.
    ///
    /// Every derived object goes first — the words index's triggers, so the rows changed after
    /// mark nothing, and every derived index and table (`derivedIndexes`, `derivedTables`) — so
    /// the copy is the shape of a store any build reads, and the receiver builds its own. Then
    /// the texts waiting to be sent and the notices, as a store written afresh from memory never
    /// had them; and no row owes a load, as a read back would settle anyway (`settleReferences`).
    /// Then it is rebuilt (`VACUUM`), in no `auto_vacuum` mode — as a file written afresh is — so
    /// no page of what went is left in it. Cancellation is asked between each, and interrupts
    /// each.
    static func takenCopy(in folder: URL) async throws -> TakenCopy {
        let path = folder.appendingPathComponent(indexName).path
        let copy = try DatabaseQueue(path: path, configuration: Self.configuration())
        defer { try? copy.close() }
        try await copy.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_mode = OFF")
        }
        try Task.checkCancellation()
        try await copy.writeWithoutTransaction { db in
            try db.inTransaction {
                try dropDerived(db)
                try db.execute(sql: "DELETE FROM unsent")
                try db.execute(sql: "DELETE FROM notice")
                try db.execute(sql: "DELETE FROM notice_reach")
                try db.execute(sql: "UPDATE note SET refs_due = 0 WHERE refs_due")
                return .commit
            }
        }
        try Task.checkCancellation()
        try await copy.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA auto_vacuum = NONE")
            try db.execute(sql: "VACUUM")
        }
        try Task.checkCancellation()
        return try await copy.read { db in
            let (sources, said) = try Self.sources(db)
            return TakenCopy(
                sources: sources, said: said,
                posts: try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0,
                kept: try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE kept") ?? 0
            )
        }
    }

    /// The words index's triggers, every derived index and every derived table of the file, in the
    /// caller's transaction.
    static func dropDerived(_ db: Database) throws {
        for name in wordsTriggers {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name.quotedDatabaseIdentifier)")
        }
        for name in derivedIndexes {
            try db.execute(sql: "DROP INDEX IF EXISTS \(name.quotedDatabaseIdentifier)")
        }
        for name in derivedTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(name.quotedDatabaseIdentifier)")
        }
    }
}
