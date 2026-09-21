import FediqoCore
import Foundation
import GRDB

/// The on-device index. Lives in Application Support and is excluded from backup.
public struct StoreFile: Sendable {
    let db: DatabaseQueue

    public init(at directory: URL) throws {
        try makeExcludedFromBackup(directory)
        let path = directory.appendingPathComponent(Self.indexName).path
        if Self.isNewer(at: path) { throw Newer() }
        try self.init(database: DatabaseQueue(path: path))
    }

    public init(database: DatabaseQueue) throws {
        // Asked before `migrate`: GRDB migrates a superseded store without complaint, and the
        // first save would then empty tables this build only half understands.
        if try database.read(migrator.hasBeenSuperseded) { throw Newer() }
        db = database
        try migrator.migrate(db)
    }

    /// The index records a migration this build does not know: a newer build wrote it.
    struct Newer: Error {}

    /// Whether the index at `path` was written by a newer build, asked on a read-only connection
    /// so that asking changes nothing on disk.
    ///
    /// The index is a rollback-journal `DatabaseQueue`, never WAL: a read-only connection to it
    /// makes no `-wal` or `-shm` file and has no log to checkpoint, which is what lets this probe
    /// leave a newer build's store byte for byte as it found it. A probe that cannot answer — no
    /// file yet, or a hot journal only a writer can roll back — is not the newer-store case; it
    /// falls through to the read-write open, whose own check still stands behind it.
    private static func isNewer(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var readOnly = Configuration()
        readOnly.readonly = true
        guard let probe = try? DatabaseQueue(path: path, configuration: readOnly) else { return false }
        return (try? probe.read(migrator.hasBeenSuperseded)) ?? false
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
        /// The index was written by a newer build. It was left exactly as found — not read, not
        /// set aside — and `file` is `nil`, so this run does not write over it either.
        public let storeIsNewer: Bool

        init(
            file: StoreFile?, sources: [Source] = [], notes: [Note] = [], setAside: URL? = nil,
            storeIsNewer: Bool = false
        ) {
            self.file = file
            self.sources = sources
            self.notes = notes
            self.setAside = setAside
            self.storeIsNewer = storeIsNewer
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
    /// **An index from a newer build is not unreadable, and is not set aside.** It is left where
    /// it is, byte for byte, and the run gets no file and `storeIsNewer`, so the newer build finds
    /// it as it left it.
    ///
    /// The decision lives here rather than in the app so it can be tested against a real file.
    public static func open(at directory: URL, now: Date = Date()) -> Opened {
        do {
            let file = try StoreFile(at: directory)
            let snapshot = try file.load()
            return Opened(file: file, sources: snapshot.sources, notes: snapshot.notes)
        } catch is Newer {
            return Opened(file: nil, storeIsNewer: true)
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

    /// Empties both tables and writes `sources` and `notes` in their place, in one transaction,
    /// on GRDB's queue rather than the caller's. The app saves through `StoreSaver`.
    public func save(sources: [Source], notes: [Note]) async throws {
        try await db.write { db in
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
    // The one 0.2.0 schema change (#25, #31): `origins` becomes `categories`, and every row
    // already held is carried forward in place, in this migration's transaction — a throw rolls
    // it all back and `open` sets the untouched file aside. Nothing is fetched to do it.
    //
    // **Frozen code.** It reads raw rows and writes JSON it spells itself rather than going
    // through `NoteRecord`, so a later change to the live record cannot change what this step
    // did to a 0.1.0 store.
    migrator.registerMigration("v2-categories") { db in
        struct V1Facts: Decodable { var boardID: String? }
        struct V2Category: Encodable { var kind: String; var id: String? }
        try db.alter(table: "note") { t in t.rename(column: "origins", to: "categories") }
        let rows = try Row.fetchAll(db, sql: """
            SELECT note.rowid AS rowid, note.categories AS origins, note.facts AS facts,
                   source.kind AS kind
            FROM note LEFT JOIN source USING (host)
            """)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for row in rows {
            let rowid: Int64 = row["rowid"]
            let origins = try decoder.decode([String].self, from: Data((row["origins"] as String).utf8))
            let kind: String? = row["kind"]
            var categories: [V2Category] = []
            if kind == "discuz" || kind == "discourse" {
                // A forum's 0.1.0 `publicTimeline` meant only "read from its front page"; its
                // categories are its boards, and only a board's own page recorded one.
                let facts = try decoder.decode(V1Facts.self, from: Data((row["facts"] as String).utf8))
                if let id = facts.boardID { categories = [V2Category(kind: "board", id: id)] }
            } else {
                if origins.contains("publicTimeline") { categories.append(V2Category(kind: "public")) }
                if origins.contains("trending") { categories.append(V2Category(kind: "trends")) }
            }
            let json = String(decoding: try encoder.encode(categories), as: UTF8.self)
            try db.execute(sql: "UPDATE note SET categories = ? WHERE rowid = ?", arguments: [json, rowid])
        }
    }
    return migrator
}

/// One category as it is written into `note.categories`, a JSON array of these sorted by kind
/// then id, so one set is always written one way. Core's `Category` stays free of a storage
/// format; this is the storage format.
///
/// **A new kind is a new migration.** `category` drops a kind it does not know, and the next
/// save would then lose it for good; the `v2-categories` migration id is what makes a build
/// that knows fewer kinds refuse the store instead. So a kind added after a release must also
/// register a new migration id, even an empty one.
private struct CategoryRow: Codable, Comparable {
    var kind: String
    var id: String?

    init(_ category: FediqoCore.Category) {
        switch category {
        case .public: kind = "public"
        case .trends: kind = "trends"
        case .home: kind = "home"
        case .list(let list): kind = "list"; id = list
        case .board(let board): kind = "board"; id = board
        }
    }

    /// Nothing for a kind this build does not know, so an unknown one is dropped, not guessed.
    var category: FediqoCore.Category? {
        switch (kind, id) {
        case ("public", _): .public
        case ("trends", _): .trends
        case ("home", _): .home
        case ("list", let id?): .list(id: id)
        case ("board", let id?): .board(id: id)
        default: nil
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        (a.kind, a.id ?? "") < (b.kind, b.id ?? "")
    }
}

/// One subscription as it is written into `source.boards`, a JSON array of these that GRDB
/// encodes and decodes as a Codable column: a board `{"fid":37,"name":…}` or a Mastodon list
/// `{"list":"42","name":…}` (#25). Core's `BoardSubscription` and `ListSubscription` stay free of
/// a storage format; this is the storage format.
///
/// **Lists ride in the boards column rather than a column of their own**, so they cost no schema
/// change: a board is written exactly as before, and a row that is neither a board nor a list
/// throws, so the load fails closed.
///
/// **A new subscription shape is a new migration**, as a new `CategoryRow` kind is. A 0.2.0
/// build throws on a shape it does not know and sets the whole store aside, so a shape added
/// after 0.2.0 must also register a new migration id — an empty one will do — so a 0.2.0 build
/// refuses that store as newer instead.
///
/// A list id read back here is not trusted with a path: `MastodonAccount` asks only for ids
/// that are one path segment.
private struct SubscriptionRow: Codable {
    var fid: Int?
    var list: String?
    var name: String

    init(_ board: BoardSubscription) {
        fid = board.fid
        name = board.name
    }

    init(_ list: ListSubscription) {
        self.list = list.id
        name = list.name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fid = try container.decodeIfPresent(Int.self, forKey: .fid)
        list = try container.decodeIfPresent(String.self, forKey: .list)
        name = try container.decode(String.self, forKey: .name)
        guard (fid == nil) != (list == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fid, in: container, debugDescription: "neither a board nor a list"
            )
        }
    }
}

private struct SourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"
    var host: String
    var kind: String
    /// A board list that is not JSON throws when the row is fetched, so a damaged row fails the
    /// load — and the load fails closed — rather than coming back as a source with no boards.
    var boards: [SubscriptionRow]

    init(_ source: Source) {
        host = source.host
        kind = source.kind.rawValue
        boards = source.boards.map(SubscriptionRow.init) + source.lists.map(SubscriptionRow.init)
    }

    var source: Source {
        Source(
            host: host,
            kind: ProtocolKind(rawValue: kind) ?? .unknown,
            boards: boards.compactMap { row in
                row.fid.map { BoardSubscription(fid: $0, name: row.name) }
            },
            lists: boards.compactMap { row in
                row.list.map { ListSubscription(id: $0, name: row.name) }
            }
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
    /// `nil` is not a reply; a `ReplyRow` with no handle is a reply whose parent was never named.
    var reply: ReplyRow?
    var boostedBy: String?
    /// Absent in a row written before 0.2.0 learned it, which reads as no booster. See
    /// `Note.boosterHandle`.
    var boosterHandle: String?
    var sensitive: Bool?
    var spoiler: String?
    var avatarURL: URL?
    var attachments: [AttachmentRow]
    var emojis: [EmojiRow]
    var url: URL?
    /// `Note.statusID`. Additive and optional, so no migration id (Decision 11): a row written
    /// before 0.2.0 learned it reads as none, and an older build ignores the key.
    var statusID: String?
    /// `Note.boosted` — what the source last said about this reader having boosted it (#106).
    /// Additive and optional, so no migration id, and a row written before 0.4.0 learned it reads
    /// as a source that never said, which is what it is.
    ///
    /// **Kept here because the acceptance turns on it.** A boost that landed has to show as
    /// boosted after a relaunch, and it is the *server's* answer that is being written down —
    /// every later read of the post overwrites it with what the server says then, and nothing
    /// here records that a button was pressed.
    var boosted: Bool?
    /// `Note.favourited` (#107), for `boosted`'s reasons and in its shape: additive, optional, no
    /// migration id, and the source's answer rather than a press.
    var favourited: Bool?
}

private struct ReplyRow: Codable {
    var handle: String?
    /// Absent in a row written before 0.4.0 learned it, which reads as a reply whose parent was
    /// never named — the same thing `handle` says about who. See `Note.boosterHandle`.
    var inReplyToId: String?
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
    /// A JSON array of `CategoryRow`. Not JSON throws when the row is fetched, so the load fails
    /// closed.
    var categories: [CategoryRow]
    /// A `facts` that is not JSON throws when the row is fetched, so the load fails closed.
    var facts: NoteFacts

    init(_ note: Note) {
        host = note.source.host
        id = note.id
        posted_at = note.postedAt
        categories = note.categories.map(CategoryRow.init).sorted()
        facts = NoteFacts(
            author: note.author,
            handle: note.handle,
            body: note.body,
            title: note.title,
            board: note.board,
            reply: note.reply.map { ReplyRow(handle: $0.handle, inReplyToId: $0.inReplyToId) },
            boostedBy: note.boostedBy,
            boosterHandle: note.boosterHandle,
            sensitive: note.sensitive,
            spoiler: note.spoiler,
            avatarURL: note.avatarURL,
            attachments: note.attachments.map(AttachmentRow.init),
            emojis: note.emojis.map(EmojiRow.init),
            url: note.url,
            statusID: note.statusID,
            boosted: note.boosted,
            favourited: note.favourited
        )
    }

    /// The note this row holds, stamped with `source` — the row `load()` read for this host.
    /// The note table keeps no copy of a source; `load()` drops a note whose host has no source
    /// row, since a note from a server nobody follows is one nothing should draw.
    ///
    /// Categories come back as they went in, an empty set included: what a note arrived through
    /// is a fact about it, and filling in `.public` for none would put it somewhere it was never
    /// read from.
    func note(from source: Source) -> Note {
        Note(
            id: id,
            source: source,
            author: facts.author,
            handle: facts.handle,
            body: facts.body,
            title: facts.title,
            board: facts.board,
            postedAt: posted_at,
            categories: Set(categories.compactMap(\.category)),
            reply: facts.reply.map { Reply(handle: $0.handle, inReplyToId: $0.inReplyToId) },
            boostedBy: facts.boostedBy,
            boosterHandle: facts.boosterHandle,
            boosted: facts.boosted,
            favourited: facts.favourited,
            avatarURL: facts.avatarURL,
            attachments: facts.attachments.map(\.attachment),
            sensitive: facts.sensitive,
            spoiler: facts.spoiler,
            emojis: facts.emojis.map(\.emoji),
            url: facts.url,
            statusID: facts.statusID
        )
    }
}
