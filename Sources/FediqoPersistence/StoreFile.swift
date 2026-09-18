import FediqoCore
import Foundation
import GRDB

/// The on-device index. Lives in Application Support and is excluded from backup.
public struct StoreFile: Sendable {
    let db: DatabaseQueue

    public init(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(excluded)
        let url = directory.appendingPathComponent("index.sqlite")
        db = try DatabaseQueue(path: url.path)
        try migrator.migrate(db)
    }

    public init(database: DatabaseQueue) throws {
        db = database
        try migrator.migrate(db)
    }

    public static func applicationSupport() throws -> StoreFile {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try StoreFile(at: root.appendingPathComponent("Fediqo", isDirectory: true))
    }

    public func load() throws -> (sources: [Source], notes: [Note]) {
        try db.read { db in
            let sources = try SourceRecord.fetchAll(db).map { try $0.source() }
            let notes = try NoteRecord.fetchAll(db).map(\.note)
            return (sources, notes)
        }
    }

    public func save(sources: [Source], notes: [Note]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM source")
            for source in sources {
                try SourceRecord(source).insert(db)
            }
            for note in notes {
                try NoteRecord(note).insert(db)
            }
        }
    }
}

/// Internal rather than private so a test can stop it part-way and write what an older build left.
var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-index") { db in
        try db.create(table: "source") { t in
            t.primaryKey("host", .text)
            t.column("kind", .text).notNull()
            t.column("boards", .text).notNull()
        }
        try db.create(table: "note") { t in
            t.column("host", .text).notNull()
            t.column("id", .text).notNull()
            t.primaryKey(["host", "id"])
            t.column("kind", .text).notNull()
            t.column("author", .text).notNull()
            t.column("body", .text).notNull()
            t.column("title", .text)
            t.column("posted_at", .datetime).notNull()
            t.column("origins", .text).notNull()
        }
    }
    // The board list was a hand-rolled `fid<US>name<RS>…` string, which a board name holding
    // either separator broke without a word. It is JSON now; this rewrites what the old form
    // left, reading it the way the old code did.
    migrator.registerMigration("v2-boards-json") { db in
        let rows = try Row.fetchAll(db, sql: "SELECT host, boards FROM source")
        for row in rows {
            let host: String = row["host"]
            let raw: String = row["boards"]
            let boards: [BoardRow] = raw.isEmpty ? [] : raw.split(separator: "\u{1e}").compactMap { part in
                let bits = part.split(separator: "\u{1f}", maxSplits: 1)
                guard bits.count == 2, let fid = Int(bits[0]) else { return nil }
                return BoardRow(fid: fid, name: String(bits[1]))
            }
            try db.execute(
                sql: "UPDATE source SET boards = ? WHERE host = ?",
                arguments: [try BoardRow.encode(boards), host]
            )
        }
    }
    return migrator
}

/// One board subscription as it is written into `source.boards`, a JSON array of these.
/// Core's `BoardSubscription` stays free of a storage format; this is the storage format.
private struct BoardRow: Codable {
    var fid: Int
    var name: String

    static func encode(_ boards: [BoardRow]) throws -> String {
        String(decoding: try JSONEncoder().encode(boards), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> [BoardRow] {
        try JSONDecoder().decode([BoardRow].self, from: Data(text.utf8))
    }
}

private struct SourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"
    var host: String
    var kind: String
    var boards: String

    init(_ source: Source) throws {
        host = source.host
        kind = source.kind.rawValue
        boards = try BoardRow.encode(source.boards.map { BoardRow(fid: $0.fid, name: $0.name) })
    }

    /// Throws on a board list that is not JSON, so a damaged row fails the load — and the load
    /// fails closed — rather than coming back as a source with no boards.
    func source() throws -> Source {
        Source(
            host: host,
            kind: ProtocolKind(rawValue: kind) ?? .unknown,
            boards: try BoardRow.decode(boards).map { BoardSubscription(fid: $0.fid, name: $0.name) }
        )
    }
}

private struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"
    var host: String
    var id: String
    var kind: String
    var author: String
    var body: String
    var title: String?
    var posted_at: Date
    var origins: String

    init(_ note: Note) {
        host = note.source.host
        id = note.id
        kind = note.source.kind.rawValue
        author = note.author
        body = note.body
        title = note.title
        posted_at = note.postedAt
        origins = note.origins.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Origins come back as they went in, an empty set included: which lists a note was seen in
    /// is a fact about it, and filling in `.publicTimeline` for none would put it in a list it
    /// was never read from.
    var note: Note {
        let originSet = Set(
            origins.split(separator: ",").compactMap { FetchOrigin(rawValue: String($0)) }
        )
        return Note(
            id: id,
            source: Source(host: host, kind: ProtocolKind(rawValue: kind) ?? .unknown),
            author: author,
            handle: "",
            body: body,
            title: title,
            postedAt: posted_at,
            origins: originSet
        )
    }
}
