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
        var marked = directory
        try marked.setResourceValues(excluded)
        try self.init(database: DatabaseQueue(path: directory.appendingPathComponent(Self.indexName).path))
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

        init(file: StoreFile?, sources: [Source] = [], notes: [Note] = [], setAside: URL? = nil) {
            self.file = file
            self.sources = sources
            self.notes = notes
            self.setAside = setAside
        }
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
            return Opened(file: file, sources: snapshot.sources, notes: snapshot.notes)
        } catch {
            guard let aside = try? setAside(in: directory, now: now),
                  let fresh = try? StoreFile(at: directory)
            else { return Opened(file: nil) }
            return Opened(file: fresh, setAside: aside)
        }
    }

    /// `open(at:now:)` on the index this app keeps in Application Support.
    public static func openApplicationSupport() -> Opened {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return open(at: root.appendingPathComponent("Fediqo", isDirectory: true))
    }

    /// Moves `index.sqlite` and any journal SQLite left beside it to
    /// `index-unreadable-<time>-<random>`. The time, to the millisecond, is for the person who
    /// finds it; the random part is what makes the name unique, so a second failed launch in the
    /// same instant never lands on the first one's copy.
    /// Throws when there is no index to move, which is the case where the directory itself could
    /// not be made: then there is nothing to protect by moving, and nowhere safe to write either.
    private static func setAside(in directory: URL, now: Date) throws -> URL {
        let manager = FileManager.default
        let index = directory.appendingPathComponent(indexName)
        guard manager.fileExists(atPath: index.path) else { throw CocoaError(.fileNoSuchFile) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withFractionalSeconds, .withTimeZone]
        let random = UUID().uuidString.prefix(8).lowercased()
        let base = "index-unreadable-\(formatter.string(from: now))-\(random)"
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
            let sources = try SourceRecord.fetchAll(db).map(\.source)
            let byHost = Dictionary(uniqueKeysWithValues: sources.map { ($0.host, $0) })
            let notes = try NoteRecord.fetchAll(db).compactMap { record in
                byHost[record.host].map(record.note(from:))
            }
            return (sources, notes)
        }
    }

    public func save(sources: [Source], notes: [Note]) throws {
        try db.write { db in
            try NoteRecord.deleteAll(db)
            try SourceRecord.deleteAll(db)
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
            t.column("posted_at", .datetime).notNull()
            t.column("origins", .text).notNull()
            // A JSON `NoteFacts`: what a row draws and nothing reads by, so it is one column
            // rather than one per field.
            t.column("facts", .text).notNull()
        }
    }
    return migrator
}

/// One board subscription as it is written into `source.boards`, a JSON array of these that
/// GRDB encodes and decodes as a Codable column. Core's `BoardSubscription` stays free of a
/// storage format; this is the storage format.
private struct BoardRow: Codable {
    var fid: Int
    var name: String
}

private struct SourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"
    var host: String
    var kind: String
    /// A board list that is not JSON throws when the row is fetched, so a damaged row fails the
    /// load — and the load fails closed — rather than coming back as a source with no boards.
    var boards: [BoardRow]

    init(_ source: Source) {
        host = source.host
        kind = source.kind.rawValue
        boards = source.boards.map { BoardRow(fid: $0.fid, name: $0.name) }
    }

    var source: Source {
        Source(
            host: host,
            kind: ProtocolKind(rawValue: kind) ?? .unknown,
            boards: boards.map { BoardSubscription(fid: $0.fid, name: $0.name) }
        )
    }
}

/// What a row draws about a note, written into `note.facts` as JSON that GRDB encodes and
/// decodes as a Codable column. Only what the index keys or orders by has a column of its own;
/// everything else is here, so a new fact is a new field rather than a new migration step.
private struct NoteFacts: Codable {
    var author: String
    var handle: String
    var body: String
    var title: String?
    var board: String?
    var boardID: String?
    /// `nil` is not a reply; a `ReplyRow` with no handle is a reply whose parent was never named.
    var reply: ReplyRow?
    var boostedBy: String?
    var sensitive: Bool?
    var spoiler: String?
    var avatarURL: URL?
    var attachments: [AttachmentRow]
    var emojis: [EmojiRow]
    var url: URL?
}

private struct ReplyRow: Codable {
    var handle: String?
}

/// One attachment as `NoteFacts` writes it: every field, so what a row drew before a relaunch
/// — the alt text, the shape it reserved — is what it draws after.
private struct AttachmentRow: Codable {
    var kind: String
    var url: URL?
    var previewURL: URL?
    var alt: String
    var width: Int?
    var height: Int?

    init(_ attachment: Attachment) {
        kind = attachment.kind.rawValue
        url = attachment.url
        previewURL = attachment.previewURL
        alt = attachment.alt
        width = attachment.width
        height = attachment.height
    }

    var attachment: Attachment {
        Attachment(
            kind: Attachment.Kind(rawValue: kind) ?? .unknown,
            url: url,
            previewURL: previewURL,
            alt: alt,
            width: width,
            height: height
        )
    }
}

/// One custom emoji as `NoteFacts` writes it.
private struct EmojiRow: Codable {
    var shortcode: String
    var url: URL
    var staticURL: URL?

    init(_ emoji: CustomEmoji) {
        shortcode = emoji.shortcode
        url = emoji.url
        staticURL = emoji.staticURL
    }

    var emoji: CustomEmoji { CustomEmoji(shortcode: shortcode, url: url, staticURL: staticURL) }
}

private struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"
    var host: String
    var id: String
    var posted_at: Date
    /// A JSON array of `FetchOrigin` raw values, sorted so one set is always written one way.
    var origins: [String]
    /// A `facts` that is not JSON throws when the row is fetched, so the load fails closed.
    var facts: NoteFacts

    init(_ note: Note) {
        host = note.source.host
        id = note.id
        posted_at = note.postedAt
        origins = note.origins.map(\.rawValue).sorted()
        facts = NoteFacts(
            author: note.author,
            handle: note.handle,
            body: note.body,
            title: note.title,
            board: note.board,
            boardID: note.boardID,
            reply: note.reply.map { ReplyRow(handle: $0.handle) },
            boostedBy: note.boostedBy,
            sensitive: note.sensitive,
            spoiler: note.spoiler,
            avatarURL: note.avatarURL,
            attachments: note.attachments.map(AttachmentRow.init),
            emojis: note.emojis.map(EmojiRow.init),
            url: note.url
        )
    }

    /// The note this row holds, stamped with `source` — the row `load()` read for this host.
    /// The note table keeps no copy of a source; `load()` drops a note whose host has no source
    /// row, since a note from a server nobody follows is one nothing should draw.
    ///
    /// Origins come back as they went in, an empty set included: which lists a note was seen in
    /// is a fact about it, and filling in `.publicTimeline` for none would put it in a list it
    /// was never read from.
    func note(from source: Source) -> Note {
        Note(
            id: id,
            source: source,
            author: facts.author,
            handle: facts.handle,
            body: facts.body,
            title: facts.title,
            board: facts.board,
            boardID: facts.boardID,
            postedAt: posted_at,
            origins: Set(origins.compactMap(FetchOrigin.init(rawValue:))),
            reply: facts.reply.map { Reply(handle: $0.handle) },
            boostedBy: facts.boostedBy,
            avatarURL: facts.avatarURL,
            attachments: facts.attachments.map(\.attachment),
            sensitive: facts.sensitive,
            spoiler: facts.spoiler,
            emojis: facts.emojis.map(\.emoji),
            url: facts.url
        )
    }
}
