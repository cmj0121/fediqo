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
        let url = directory.appendingPathComponent(Self.indexName)
        db = try DatabaseQueue(path: url.path)
        try migrator.migrate(db)
    }

    public init(database: DatabaseQueue) throws {
        db = database
        try migrator.migrate(db)
    }

    /// What a launch found on disk: the file to write back to, if there is one to trust, and
    /// what it held.
    public struct Opened: Sendable {
        /// Where saves go. `nil` means this run must not write at all — see `open(at:now:)`.
        public let file: StoreFile?
        public let sources: [Source]
        public let notes: [Note]
        /// Where an unreadable index was moved, when one was. It is left there for a person, or a
        /// later version of this code, to look at; nothing in the app reads it again.
        public let setAside: URL?
    }

    /// Opens the index in `directory` and reads it, failing closed.
    ///
    /// **An index that cannot be read is never written over.** `save` begins by emptying both
    /// tables, so a launch that shrugged off a failed read — a corrupt page, a migration this
    /// build cannot run, a row it cannot decode — and started empty would, at the first save,
    /// turn one bad launch into everything the reader had, gone. So a failure here moves the
    /// file aside under a timestamped name before a fresh one is made in its place, and when it
    /// cannot even do that the run gets no file at all: it reads nothing and saves nothing, and
    /// whatever is on disk is still there next launch.
    ///
    /// The decision lives here rather than in the app so it can be tested against a real file.
    public static func open(at directory: URL, now: Date = Date()) -> Opened {
        do {
            let file = try StoreFile(at: directory)
            let snapshot = try file.load()
            return Opened(file: file, sources: snapshot.sources, notes: snapshot.notes, setAside: nil)
        } catch {
            guard let aside = try? setAside(in: directory, now: now),
                  let fresh = try? StoreFile(at: directory)
            else {
                return Opened(file: nil, sources: [], notes: [], setAside: nil)
            }
            return Opened(file: fresh, sources: [], notes: [], setAside: aside)
        }
    }

    /// `open(at:now:)` on the index this app keeps in Application Support.
    public static func openApplicationSupport() -> Opened {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return open(at: root.appendingPathComponent("Fediqo", isDirectory: true))
    }

    /// Moves `index.sqlite` and any journal SQLite left beside it to `index-unreadable-<time>`.
    /// Throws when there is no index to move, which is the case where the directory itself could
    /// not be made: then there is nothing to protect by moving, and nowhere safe to write either.
    private static func setAside(in directory: URL, now: Date) throws -> URL {
        let manager = FileManager.default
        let index = directory.appendingPathComponent(indexName)
        guard manager.fileExists(atPath: index.path) else { throw CocoaError(.fileNoSuchFile) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: now)
        var base = "index-unreadable-\(stamp)"
        var attempt = 1
        while manager.fileExists(atPath: directory.appendingPathComponent(base + ".sqlite").path) {
            attempt += 1
            base = "index-unreadable-\(stamp)-\(attempt)"
        }
        let aside = directory.appendingPathComponent(base + ".sqlite")
        try manager.moveItem(at: index, to: aside)
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = directory.appendingPathComponent(indexName + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try manager.moveItem(at: sidecar, to: directory.appendingPathComponent(base + ".sqlite" + suffix))
            }
        }
        return aside
    }

    private static let indexName = "index.sqlite"

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

private var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-index") { db in
        try db.create(table: "source") { t in
            t.primaryKey("host", .text)
            t.column("kind", .text).notNull()
            // A JSON array of `BoardRow`: a board name can hold any character, so no separator
            // chosen here could be trusted to stay one.
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
