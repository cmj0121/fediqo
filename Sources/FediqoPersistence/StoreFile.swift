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

    /// What the index weighs on disk right now: the file and any journal SQLite left beside it
    /// (#194). **The one measure of the store's size**: Usage's figure is this, and a limit on
    /// the store is held to the same call, so the two cannot disagree. Zero where there is no
    /// file, or for a store not on disk at all.
    public func bytesOnDisk() -> Int {
        Self.bytesOnDisk(indexAt: db.path)
    }

    /// `bytesOnDisk()` for the index at `path`, and what SQLite keeps beside it.
    static func bytesOnDisk(indexAt path: String) -> Int {
        guard path != ":memory:", !path.isEmpty else { return 0 }
        return ([""] + ["-journal", "-wal", "-shm"]).reduce(0) { sum, suffix in
            let values = try? URL(fileURLWithPath: path + suffix).resourceValues(forKeys: [.fileSizeKey])
            return sum + (values?.fileSize ?? 0)
        }
    }

    public func load() throws -> (sources: [Source], notes: [Note]) {
        try db.read { db in
            let sources = try SourceRecord.fetchAll(db).map(\.source)
            let byHost = Dictionary(uniqueKeysWithValues: sources.map { ($0.host, $0) })
            // In the order they were written, which `ItemStore.snapshot` made the order they
            // arrived in: the copy of a post a merged row is drawn as is the one that came
            // first (#114), and a table read in no stated order is read in whatever order
            // SQLite likes. Stated, so that it is a guarantee rather than a habit.
            let notes = try NoteRecord.order(Column.rowID).fetchAll(db).compactMap { record in
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
    // Whether a timeline may show a row, or whether this device only holds it (#175). Nothing
    // already stored is disturbed: every row on disk arrived through a timeline read, which is the
    // only way a row could get here before this existed, and the column's default says so.
    //
    // **A migration id rather than an optional field in `facts`.** An older build knows nothing of
    // this column, and an older build that read this store would draw every search hit and every
    // thread answer in All — silently putting rows somewhere nobody read them from. The id is what
    // makes it refuse the store instead, which is `CategoryRow`'s rule reaching a second marker.
    migrator.registerMigration("v3-holding") { db in
        try db.alter(table: "note") { t in
            t.add(column: "holding", .text).notNull().defaults(to: Holding.arrived.rawValue)
        }
    }
    // When a read of one post heard its source say it no longer has it (#179), or NULL. Every row
    // already stored is one no source has said that of, so the NULL every row takes is the truth.
    //
    // **A migration id for `v3-holding`'s reason.** An older build reading this store would draw
    // a post its source deleted with no mark and every act offered on it — a boost pressed on a
    // post that is not there. The id makes it refuse the store instead.
    migrator.registerMigration("v4-gone") { db in
        try db.alter(table: "note") { t in
            t.add(column: "gone_at", .datetime)
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
    /// `Note.opening` (#154): a forum row's opening post as this device last read it. Additive
    /// and optional, so no migration id, and the refuse-a-newer-store rule is not reached: a row
    /// written before 0.4.0 learned it reads as a row nobody has reached, which it is to this
    /// build, and an earlier build decoding this row ignores the key.
    var opening: OpeningRow?
    /// `Note.gaps` (#201): where a timeline this row came through is not whole next to it.
    /// Additive and optional, so no migration id, for `opening`'s reasons: a row written before
    /// reads as one no read said that of, and an older build ignores the key and draws no mark,
    /// which is all it drew before. A kind or a category this build does not know is dropped.
    var gaps: [GapRow]?
    /// `Note.listed` (#201): the id each timeline listed this row under, which is what that
    /// timeline is read on from. Additive and optional for `gaps`' reasons: a row written before
    /// reads as listed by nothing, which leaves its timeline to be read as one held nowhere.
    var listed: [ListedRow]?
    /// `Note.audience` (#208), as `Audience`'s own spelling. Additive and optional for `boosted`'s
    /// reasons: a row written before reads as a source that never said, which the next read that
    /// does say fills in, and a spelling this build does not know reads the same way.
    var audience: String?
    /// `Note.counts` (#208), or nothing where the source counted nothing. Additive and optional
    /// for `boosted`'s reasons: a row written before reads as counted by nobody.
    var counts: CountsRow?
    /// `Note.quote` (#214): the post this row quotes, what a row draws of it, so it shows with
    /// the network off. Additive and optional for `boosted`'s reasons: a row written before reads
    /// as one that quotes nothing until a read says otherwise, and an older build ignores the key.
    var quote: QuoteRow?
}

/// `Quote` as `NoteFacts` writes it: the state in the source's spelling, and the quoted post.
private struct QuoteRow: Codable {
    var state: String
    var statusID: String?
    var post: QuotedRow?

    init(_ quote: Quote) {
        state = quote.state.rawValue
        statusID = quote.statusID
        post = quote.post.map(QuotedRow.init)
    }

    var quote: Quote {
        Quote(state: Quote.State(wire: state), post: post?.post, statusID: statusID)
    }
}

/// `QuotedPost` as `NoteFacts` writes it: every fact a row draws, and its own quote as a state
/// and an id — one level, as it was read.
private struct QuotedRow: Codable {
    var id: String
    var statusID: String?
    var author: String
    var handle: String
    var body: String
    var postedAt: Date
    var avatarURL: URL?
    var attachments: [AttachmentRow]
    var sensitive: Bool?
    var spoiler: String?
    var emojis: [EmojiRow]
    var url: URL?
    var audience: String?
    var reply: ReplyRow?
    var quotingState: String?
    var quotingStatusID: String?

    init(_ post: QuotedPost) {
        id = post.id
        statusID = post.statusID
        author = post.author
        handle = post.handle
        body = post.body
        postedAt = post.postedAt
        avatarURL = post.avatarURL
        attachments = post.attachments.map(AttachmentRow.init)
        sensitive = post.sensitive
        spoiler = post.spoiler
        emojis = post.emojis.map(EmojiRow.init)
        url = post.url
        audience = post.audience?.rawValue
        reply = post.reply.map { ReplyRow(handle: $0.handle, inReplyToId: $0.inReplyToId) }
        quotingState = post.quoting?.state.rawValue
        quotingStatusID = post.quoting?.statusID
    }

    var post: QuotedPost {
        QuotedPost(
            id: id, statusID: statusID, author: author, handle: handle, body: body,
            postedAt: postedAt, avatarURL: avatarURL, attachments: attachments.map(\.attachment),
            sensitive: sensitive, spoiler: spoiler, emojis: emojis.map(\.emoji), url: url,
            audience: audience.flatMap(Audience.init(rawValue:)),
            reply: reply.map { Reply(handle: $0.handle, inReplyToId: $0.inReplyToId) },
            quoting: quotingState.map { NestedQuote(state: Quote.State(wire: $0), statusID: quotingStatusID) }
        )
    }
}

/// `Counts` as `NoteFacts` writes it.
private struct CountsRow: Codable {
    var replies: Int?
    var reblogs: Int?
    var favourites: Int?

    /// Nothing for counts that state nothing, so a row with none writes no key.
    init?(_ counts: Counts) {
        guard counts != Counts() else { return nil }
        replies = counts.replies
        reblogs = counts.reblogs
        favourites = counts.favourites
    }

    var counts: Counts { Counts(replies: replies, reblogs: reblogs, favourites: favourites) }
}

/// One timeline's listing of a row, as `NoteFacts` writes it.
private struct ListedRow: Codable {
    var category: CategoryRow
    var id: String
}

/// `TimelineGap` as `NoteFacts` writes it.
private struct GapRow: Codable {
    var kind: String
    var category: CategoryRow
    /// `TimelineGap.since` (#204): when a settled place was said, which the wait counts from.
    /// Additive and optional for `NoteFacts.gaps`' reasons; an older build drops the kind anyway.
    var since: Date?
    /// `TimelineGap.from` (#204): the id a moved place reads down from, for `since`'s reasons.
    /// An older build reads the place as where its post was listed, which is where it read before.
    var from: String?

    init(_ gap: TimelineGap) {
        kind = gap.kind.rawValue
        category = CategoryRow(gap.category)
        since = gap.since
        from = gap.from
    }

    /// Nothing for a settled place with no moment, which no wait could ever reach.
    var gap: TimelineGap? {
        guard let kind = TimelineGap.Kind(rawValue: kind), let category = category.category,
              kind != .settled || since != nil
        else { return nil }
        return TimelineGap(
            kind, in: category, since: kind == .settled ? since : nil, from: kind == .mayBeMissing ? from : nil
        )
    }
}

/// `ForumOpening` as `NoteFacts` writes it.
private struct OpeningRow: Codable {
    var words: String
    var quoted: [QuotationRow]
    var avatarURL: URL?
    /// A kept reply's floor and date (#177). Additive and optional, for `opening`'s reasons: a row
    /// written before reads as an opening post, which it is, and an older build ignores the keys.
    var floor: Int?
    var postedAt: Date?

    init(_ opening: ForumOpening) {
        words = opening.words
        quoted = opening.quoted.map(QuotationRow.init)
        avatarURL = opening.avatarURL
        floor = opening.floor
        postedAt = opening.postedAt
    }

    var opening: ForumOpening {
        ForumOpening(
            words: words, quoted: quoted.map(\.quotation), avatarURL: avatarURL,
            floor: floor, postedAt: postedAt
        )
    }
}

/// One level of a quotation, and the levels it quoted. As deep as what was read, which Core
/// bounds at `DiscuzQuotation.deepest` levels before anything is kept.
private struct QuotationRow: Codable {
    var words: String
    var quoting: [QuotationRow]

    init(_ quotation: DiscuzQuotation) {
        words = quotation.words
        quoting = quotation.quoting.map(QuotationRow.init)
    }

    var quotation: DiscuzQuotation {
        DiscuzQuotation(words: words, quoting: quoting.map(\.quotation))
    }
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
    /// `Note.holding` (#175). A column rather than a field in `facts`, and with a migration id
    /// behind it, because an older build must refuse this store rather than show a row nobody
    /// read from a timeline in All.
    var holding: String
    /// `Note.goneSince` (#179). A column behind its own migration id, for `holding`'s reason.
    var gone_at: Date?

    init(_ note: Note) {
        host = note.source.host
        id = note.id
        posted_at = note.postedAt
        holding = note.holding.rawValue
        gone_at = note.goneSince
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
            favourited: note.favourited,
            opening: note.opening.map(OpeningRow.init),
            gaps: note.gaps.isEmpty ? nil : note.gaps.map(GapRow.init).sorted { ($0.kind, $0.category) < ($1.kind, $1.category) },
            listed: note.listed.isEmpty ? nil : note.listed
                .map { ListedRow(category: CategoryRow($0.key), id: $0.value) }
                .sorted { $0.category < $1.category },
            audience: note.audience?.rawValue,
            counts: CountsRow(note.counts),
            quote: note.quote.map(QuoteRow.init)
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
            audience: facts.audience.flatMap(Audience.init(rawValue:)),
            avatarURL: facts.avatarURL,
            attachments: facts.attachments.map(\.attachment),
            sensitive: facts.sensitive,
            spoiler: facts.spoiler,
            emojis: facts.emojis.map(\.emoji),
            url: facts.url,
            counts: facts.counts?.counts ?? Counts(),
            statusID: facts.statusID,
            opening: facts.opening?.opening,
            // A spelling this build does not know cannot reach here — the migration id makes an
            // older store's rows carry the default and a newer store be refused outright — so the
            // fallback is the one every row written before this column had.
            holding: Holding(rawValue: holding) ?? .arrived,
            goneSince: gone_at,
            gaps: Set(facts.gaps?.compactMap(\.gap) ?? []),
            listed: Dictionary(
                (facts.listed ?? []).compactMap { row in row.category.category.map { ($0, row.id) } },
                uniquingKeysWith: { a, _ in a }
            ),
            quote: facts.quote?.quote
        )
    }
}
