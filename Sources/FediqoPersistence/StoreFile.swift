import FediqoCore
import Foundation
import GRDB
import SQLite3

/// The on-device index. Lives in Application Support and is excluded from backup.
public struct StoreFile: Sendable {
    let db: DatabaseQueue

    /// `busyWait` is how long this connection waits on another before a read or a write fails
    /// as busy (#295): another copy of the app saving into the same folder is an ordinary thing,
    /// and a store that is merely being written is not one to give up on at the first ask.
    public init(at directory: URL, busyWait: TimeInterval = StoreFile.busyWait) throws {
        try makeExcludedFromBackup(directory)
        let path = directory.appendingPathComponent(Self.indexName).path
        if Self.isNewer(at: path) { throw Newer() }
        var waiting = Configuration()
        waiting.busyMode = .timeout(busyWait)
        try self.init(database: DatabaseQueue(path: path, configuration: waiting))
        // **A store that can be read and not written is not one this run may use** (#295).
        // SQLite opens a file it may not write for reading alone and says nothing until the
        // first write — which would be the first save, failing into a log after the person had
        // read on for an hour. Asked here, where the answer can be said, and of the connection
        // and the folder themselves, so that asking writes nothing: whether SQLite opened the
        // file for reading alone, and whether the folder its journal is made in takes a file.
        let readOnly = try db.read { db in sqlite3_db_readonly(db.sqliteConnection, "main") == 1 }
        guard !readOnly, FileManager.default.isWritableFile(atPath: directory.path) else {
            throw DatabaseError(resultCode: .SQLITE_READONLY)
        }
    }

    public init(database: DatabaseQueue) throws {
        // Asked before `migrate`: GRDB migrates a superseded store without complaint, and the
        // first save would then empty tables this build only half understands.
        if try database.read(migrator.hasBeenSuperseded) { throw Newer() }
        db = database
        // Before anything is written, a migration's rewriting of rows included.
        try db.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        try migrator.migrate(db)
    }

    /// **What this device lets go is not left readable in its index** (#292).
    ///
    /// SQLite frees a deleted row's pages for the next insert and, left to itself, leaves what
    /// was written on them where it was: a save with fewer rows than the last would keep the
    /// words of every post let go — and each earlier wording its author took away (#286) — in
    /// the file's free pages until something happened to be written over them. `secure_delete`
    /// set to `ON` has SQLite write zeroes over everything it frees, as it frees it, in the same
    /// transaction as the save that let the rows go. Set on the one connection a `DatabaseQueue`
    /// has, and asked for by name: the system's own default is `FAST`, which zeroes only inside
    /// pages it was writing anyway and leaves the free ones.
    ///
    /// **The index is the one file.** It keeps a rollback journal and never a write-ahead log
    /// (`isNewer`), and the journal — which holds each replaced page as it was — is deleted as
    /// the save commits, so nothing lies beside the index once a save has returned or the store
    /// has closed. A run killed mid-save leaves its journal, and the rows it was letting go are
    /// then still held: the next open rolls the save back and deletes it.
    ///
    /// **What this does not reach**, and does not claim to: what the file system keeps of a file
    /// that was deleted or cut short — the journal, a rebuild's temporary copy, the tail of an
    /// index made smaller, an index a read back replaced. That is the system's, beneath this
    /// app's files. **A store put aside as damaged is kept only until the person has been told
    /// of it** and what took its place has been saved (`dropWhatWasReplaced`, #295); one that
    /// could not be opened for the moment's reasons is not put aside at all.
    ///
    /// A store written by a build before this one may already hold such words in its free
    /// pages, where zeroing what is freed from now on would never reach: `scrub()` rebuilds such
    /// a file whole.
    ///
    /// **Asked only once the store has been read** — by `open(at:now:)`, and where a package's
    /// index is read back — and never by `init`: an index that cannot be read is never written
    /// over, and a rebuild is a write of every page.
    ///
    /// **Whenever the file has free pages, and the first time whatever it has.** A build before
    /// this one frees pages without zeroing them, and may do so again after this build has had
    /// the store — a person going back a version and forward again — so a mark that the file was
    /// once rebuilt cannot be the whole of the question. Free pages can be asked for, and a
    /// store with any is rebuilt. The ones this build frees are zeroed already, so after a save
    /// that let a good deal go the next open rebuilds for nothing: a fifth of a second at fifty
    /// thousand posts, at launch, before any limit has measured the file. The mark is kept for
    /// the first open alone, when an older file with no page free is rebuilt regardless — what
    /// such a build left inside its pages is not this one's to vouch for.
    ///
    /// A rebuild copies the rows held and nothing else into a file made afresh. Marked only once
    /// it has happened: one that failed — a full disk — is tried again at the next open, and the
    /// store is used either way, since what is held is as readable as it was.
    func scrub() {
        let (version, free) = (try? db.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0, try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
        }) ?? (0, 1)
        guard version < Self.scrubbed || free > 0 else { return }
        try? db.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA user_version = \(Self.scrubbed)")
        }
    }

    /// The index's `user_version` once this build has rebuilt it. **A number in the file's
    /// header and not a migration**: the tables are as they were, so a build before this one
    /// still opens the store — a migration id would have made it refuse to.
    static let scrubbed = 1

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

    /// Whether the index standing at `path` holds nothing — no source and no post — or `nil`
    /// where that cannot be asked. Asked on a read-only connection, so asking changes nothing.
    static func holdsNothing(indexAt path: String) -> Bool? {
        var readOnly = Configuration()
        readOnly.readonly = true
        guard let probe = try? DatabaseQueue(path: path, configuration: readOnly) else { return nil }
        return try? probe.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            for table in ["source", "note"] where tables.contains(table) {
                if try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0 > 0 { return false }
            }
            return true
        }
    }

    /// What a launch found on disk: the file to write back to, if there is one to trust, and
    /// what it held.
    public struct Opened: Sendable {
        /// Where saves go. `nil` means this run must not write at all — see `open(at:now:)`.
        public let file: StoreFile?
        public let sources: [Source]
        public let notes: [Note]
        /// What each source last said about itself, as of when (#188).
        public let said: [SourceProfile]
        /// Where an unreadable index was moved by this launch, when one was. Nothing in the app
        /// reads it again; it is deleted once the person has been told and what took its place
        /// has been saved (`trouble`, `StoreFile.told(in:)`).
        public let setAside: URL?
        /// What the person is to be told about the store, where anything (#295).
        public let trouble: StoreTrouble?
        /// The index was written by a newer build. It was left exactly as found — not read, not
        /// set aside — and `file` is `nil`, so this run does not write over it either.
        public let storeIsNewer: Bool

        init(
            file: StoreFile?, sources: [Source] = [], notes: [Note] = [], said: [SourceProfile] = [],
            setAside: URL? = nil, storeIsNewer: Bool = false, trouble: StoreTrouble? = nil
        ) {
            self.trouble = trouble
            self.file = file
            self.sources = sources
            self.notes = notes
            self.said = said
            self.setAside = setAside
            self.storeIsNewer = storeIsNewer
        }
    }

    /// Opens the index in `directory` and reads it, failing closed — and says what it found
    /// where that is anything but a store opened (`Opened.trouble`, #295).
    ///
    /// **An index that cannot be read is never written over.** `save` begins by emptying both
    /// tables, so a launch that shrugged off a failed read and started empty would, at the first
    /// save, turn one bad launch into everything the reader had, gone.
    ///
    /// **Why it could not be read decides what is done** (`cause(of:)`):
    ///
    /// - **Damaged** — not a database, a page that does not add up, a migration this build
    ///   cannot run, a row it cannot decode. The file is moved aside under a timestamped name
    ///   and a fresh one is made in its place. Where it cannot be moved, nothing is made.
    /// - **Out of reach for now** — in use by another copy of the app, no room, a folder or a
    ///   file that would not be read or written. **Nothing is moved and nothing is made**: the
    ///   run gets no file at all, reads nothing and saves nothing, and whatever is on disk is
    ///   there, untouched, at the next launch.
    ///
    /// **An index from a newer build is neither**, and is not set aside. It is left where it is,
    /// byte for byte, and the run gets no file and `storeIsNewer`.
    ///
    /// **A read back left unsettled opens nothing** (#292): see `StorePackager.settleHalfCommits`.
    ///
    /// The decision lives here rather than in the app so it can be tested against a real file.
    public static func open(at directory: URL, now: Date = Date(), busyWait: TimeInterval = StoreFile.busyWait) -> Opened {
        open(at: directory, now: now) { try StoreFile(at: $0, busyWait: busyWait) }
    }

    /// `open(at:now:busyWait:)`, with the opening itself handed in: the one failure a test
    /// cannot make a real file give — a disk with no room — is made here instead.
    static func open(at directory: URL, now: Date, opening: (URL) throws -> StoreFile) -> Opened {
        // A read back's old index is aside here, neither replaced nor put back (#292): the store
        // this device held is that one, and no index is opened or made beside it. The run reads
        // nothing and saves nothing, and the next launch tries to settle it again.
        if let unsettled = StorePackager.unsettledReadBack(in: directory) {
            return Opened(file: nil, trouble: unsettled)
        }
        do {
            let file = try opening(directory)
            let snapshot = try file.load()
            // Read, and so not about to be set aside: only now is it rewritten (#292).
            file.scrub()
            // One put aside by a launch that was quit before it could say so is said now — and
            // said truly: where the other of two stores took its place, not that an empty one did.
            let untold = putAside(in: directory).filter { !$0.told }
            let restored = untold.contains { aside in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(aside.base + restoredSuffix).path)
            }
            return Opened(
                file: file, sources: snapshot.sources, notes: snapshot.notes, said: snapshot.said,
                trouble: untold.isEmpty ? nil : .damaged(replacedBy: restored ? .otherStore : .empty)
            )
        } catch is Newer {
            return Opened(file: nil, storeIsNewer: true)
        } catch {
            switch cause(of: error) {
            case .unreachable(let why):
                return Opened(file: nil, trouble: .unreachable(why))
            case .damaged:
                guard let aside = try? setAside(in: directory, now: now) else {
                    return Opened(file: nil, trouble: .unreachable(.outOfReach))
                }
                // The store the person chose of two (`StorePackager.choose`) is the one that
                // turned out damaged: the other, kept only until this one had opened and saved,
                // is the store again. Nothing is made in the damaged one's place — the next
                // launch puts the other back there.
                if StorePackager.reinstateDisplaced(in: directory) {
                    // Written down beside the damaged one, so that the launch that comes to say
                    // it was damaged says what took its place.
                    let base = aside.deletingPathExtension().lastPathComponent
                    try? Data().write(to: directory.appendingPathComponent(base + restoredSuffix))
                    return Opened(file: nil, setAside: aside, trouble: .unreachable(.otherComesBack))
                }
                guard let fresh = try? opening(directory) else {
                    return Opened(file: nil, setAside: aside, trouble: .unreachable(.putAsideOnly))
                }
                return Opened(file: fresh, setAside: aside, trouble: .damaged(replacedBy: .empty))
            }
        }
    }

    /// `open(at:now:)` on the index this app keeps in Application Support.
    public static func openApplicationSupport() -> Opened {
        open(at: applicationSupportDirectory)
    }

    /// Where the index this app keeps lives, and what sits beside it (the limits' account, #251).
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fediqo", isDirectory: true)
    }

    /// What the rows held weigh, whatever the file does (#249): the pages in use, without the
    /// free ones a deleted row leaves behind until `compact()`. **What a limit judges each round
    /// by**: `bytesOnDisk()` does not move until the file is rebuilt, and a rebuild that failed —
    /// a full disk, a run cancelled — would otherwise read as rows that never went. Zero where it
    /// cannot be asked.
    public func bytesHeld() -> Int {
        (try? db.read { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let size = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return max(0, pages - free) * size
        }) ?? 0
    }

    /// Gives back the room that rows let go of left in the file (#249). SQLite keeps a deleted
    /// row's pages for the next insert, so a save with fewer rows weighs what the last one did
    /// until the file is rebuilt — and a limit judged by `bytesOnDisk()` would never see the
    /// posts it let go of. Asked only after a limit acted, never on the ordinary save: it
    /// rewrites the whole index. **Room, and nothing else**: what the rows let go said is already
    /// gone from those pages by the save that freed them (`scrub`).
    public func compact() async throws {
        try await db.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
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
        let base = "\(unreadablePrefix)\(formatter.string(from: now))-\(random)"
        let aside = directory.appendingPathComponent(base + ".sqlite")
        try manager.moveItem(at: index, to: aside)
        for suffix in sidecars {
            let sidecar = directory.appendingPathComponent(indexName + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try manager.moveItem(at: sidecar, to: directory.appendingPathComponent(base + ".sqlite" + suffix))
            }
        }
        // The limits' account (#251) is about this index and goes aside with it: lines naming
        // what was let go of a store that is no longer there would be lines about nothing.
        let account = directory.appendingPathComponent(LimitAccountFile.name)
        if manager.fileExists(atPath: account.path) {
            try? manager.moveItem(at: account, to: directory.appendingPathComponent(base + "-" + LimitAccountFile.name))
        }
        return aside
    }

    private static let indexName = "index.sqlite"
    /// What SQLite may leave beside the index: moved with it, and weighed with it.
    static let sidecars = ["-journal", "-wal", "-shm"]

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
        return ([""] + sidecars).reduce(0) { sum, suffix in
            let values = try? URL(fileURLWithPath: path + suffix).resourceValues(forKeys: [.fileSizeKey])
            return sum + (values?.fileSize ?? 0)
        }
    }

    /// Takes the mark that its references are still to be asked for off every row (#293): what
    /// a read back does to the store a package carried before that store becomes this device's
    /// (`ItemStore.replace`), on the file itself where the file is moved into place as it is.
    func settleReferences() throws {
        try db.writeWithoutTransaction { db in try db.execute(sql: "UPDATE note SET refs_due = 0 WHERE refs_due") }
    }

    /// How many rows the index holds as kept (#284), asked of the table and not of the notes read
    /// out of it: what a read back checks a package's header against (#294), so it is every row
    /// the file carries, whether or not this build can draw it.
    func keptCount() throws -> Int {
        try db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE kept") ?? 0 }
    }

    public func load() throws -> (sources: [Source], notes: [Note], said: [SourceProfile]) {
        try db.read { db in
            let records = try SourceRecord.fetchAll(db)
            let sources = records.map(\.source)
            let said = records.compactMap(\.saidProfile)
            let byHost = Dictionary(uniqueKeysWithValues: sources.map { ($0.host, $0) })
            // In the order they were written, which `ItemStore.snapshot` made the order they
            // arrived in: the copy of a post a merged row is drawn as is the one that came
            // first (#114), and a table read in no stated order is read in whatever order
            // SQLite likes. Stated, so that it is a guarantee rather than a habit.
            let notes = try NoteRecord.order(Column.rowID).fetchAll(db).compactMap { record in
                (byHost[record.host] ?? record.formerSource).flatMap(record.note(from:))
            }
            return (sources, notes, said)
        }
    }

    /// Empties both tables and writes `sources` and `notes` in their place, in one transaction,
    /// on GRDB's queue rather than the caller's. `said` is what each source last said about
    /// itself (#188), written on its source's row; one of a host not in `sources` goes nowhere.
    /// The app saves through `StoreSaver`.
    public func save(sources: [Source], notes: [Note], said: [SourceProfile] = []) async throws {
        let saidByHost = Dictionary(said.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
        try await db.write { db in
            try NoteRecord.deleteAll(db)
            try SourceRecord.deleteAll(db)
            for source in sources {
                try SourceRecord(source, said: saidByHost[source.host]).insert(db)
            }
            for note in notes {
                try NoteRecord(note).insert(db)
            }
        }
        // Only here, the write having returned: a save that threw has replaced nothing.
        dropWhatWasReplaced()
    }

    /// Deletes every earlier store kept beside this one that this one has now outlived (#292,
    /// #295), this index having just been saved:
    ///
    /// - **A store a read back replaced**, where a run was killed before clearing it away: an
    ///   `incoming-aside-…` folder whose marker says replaced, beside this index.
    /// - **A store the person chose against**, of two a read back left (`StorePackager.choose`):
    ///   one whose marker says displaced. The one they chose is this one, opened and now saved.
    /// - **A store put aside because it was damaged** (`index-unreadable-…`, with what SQLite and
    ///   the limits kept beside it), by this run or any before it — **only once the person has
    ///   been told** (`told(in:)`). One they have not been told of is kept, whatever is saved.
    ///
    /// **An earlier store must not outlive the store that took its place.** Such a copy holds
    /// every post that store held, and nothing this device lets go afterwards reaches it. But
    /// it is the only other copy there is, so it goes only when both things are true: this
    /// index has been saved, which is why this is asked from `save`; and nobody is waiting to be
    /// told. There is no period in which it can be got back, and the notice says so.
    ///
    /// **Never an aside that was only moved out of the way.** One whose marker says neither
    /// replaced nor displaced is the store this device held and the only copy of it.
    ///
    /// Deleting is unlinking; what the file system keeps beneath is the system's, as above. Each
    /// store's mark goes last, so a deleting cut short is finished by the next save.
    private func dropWhatWasReplaced() {
        let path = db.path
        guard path != ":memory:", !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(Self.readBackAsidePrefix) {
            let kept = folder.appendingPathComponent(name)
            if StorePackager.wasReplaced(kept, in: folder) || StorePackager.wasDisplaced(kept) {
                try? manager.removeItem(at: kept)
            }
        }
        for aside in Self.putAside(in: folder) where aside.told {
            for ending in [".sqlite"] + Self.sidecars.map({ ".sqlite" + $0 }) + ["-" + LimitAccountFile.name, Self.restoredSuffix, Self.toldSuffix] {
                try? manager.removeItem(at: folder.appendingPathComponent(aside.base + ending))
            }
        }
    }

    /// What a store set aside as unreadable, and the folder a read back moves the index it is
    /// replacing into, are named by.
    static let unreadablePrefix = "index-unreadable-"
    static let readBackAsidePrefix = "incoming-aside-"
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
            t.add(column: "holding", .text).notNull().defaults(to: "arrived")
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
    // What a source last said about itself, and when (#188), or NULL. Every source already stored
    // is one whose word this device kept nowhere, so the NULL each row takes is the truth, and
    // the first ask after this build opens the store writes one in.
    //
    // **A migration id for `v3-holding`'s reason.** An older build ignores columns it does not
    // read, so it would open this store without complaint and then, at its first save, write the
    // source table back without them — a relaunch under this build finding every word gone. The
    // id makes it refuse the store instead.
    migrator.registerMigration("v5-said") { db in
        try db.alter(table: "source") { t in
            // A JSON `SaidRow`: what a row draws and nothing reads by, so one column.
            t.add(column: "said", .text)
            t.add(column: "said_at", .datetime)
        }
    }
    // Whether the person keeps a row (#284). Every row already stored is one nobody kept, which
    // is what the column's default says.
    //
    // **A migration id for `v3-holding`'s reason.** An older build knows nothing of this column:
    // its limits would let a kept post go like any other, and its first save would write every
    // row back without the mark. The id makes it refuse the store instead.
    migrator.registerMigration("v6-kept") { db in
        try db.alter(table: "note") { t in
            t.add(column: "kept", .boolean).notNull().defaults(to: false)
        }
    }
    // Whether the reader has bookmarked a row at its source, as the source last said (#285), or
    // NULL where it never said. Every row already stored is one no source was heard about, so
    // the NULL each takes is the truth.
    //
    // **A migration id for `v3-holding`'s reason.** An older build's first save would write
    // every row back without what the source said, and a relaunch under this build would draw
    // posts bookmarked at their source as not bookmarked. The id makes it refuse the store.
    migrator.registerMigration("v7-bookmarked") { db in
        try db.alter(table: "note") { t in
            t.add(column: "bookmarked", .boolean)
        }
    }
    // When a row's source says it was last changed, and what the row said before each change this
    // device saw (#286) — both NULL on every row already stored, which is the truth: none was
    // seen to change.
    //
    // **A migration id for `v3-holding`'s reason.** An older build's first save would write every
    // row back without either, and worse than losing them: its next read of a changed post would
    // be told nothing was changed. The id makes it refuse the store instead.
    //
    // **On the note's own row and in no table of its own**, so an earlier wording cannot outlive
    // its post: whatever lets the row go has let these go with it.
    migrator.registerMigration("v8-revisions") { db in
        try db.alter(table: "note") { t in
            t.add(column: "edited_at", .datetime)
            // A JSON array of `WordingRow`, oldest first.
            t.add(column: "earlier", .text)
        }
    }
    // The language a row's source says it is in (#287), or NULL where it said none — which every
    // row already stored takes, and is the truth: none was read for it.
    //
    // **A migration id for `v3-holding`'s reason.** A timeline may now be made of the posts that
    // say one language; an older build's first save would write every row back without what it
    // said, and that timeline would be empty under this build until every post was read again.
    // The id makes it refuse the store instead.
    migrator.registerMigration("v9-language") { db in
        try db.alter(table: "note") { t in
            t.add(column: "language", .text)
        }
    }
    // What a row refers to (#290, #293), and whether that has been asked for.
    //
    // `refs` is a JSON array of `ReferenceRow`: for each, its kind and whichever of the target's
    // ID and its source's own id for it the source said, with whom an answer is to and where a
    // quote stands. Every row already held is given the references its reply and its quote
    // state, in this migration's transaction, so that from here on the column is where a row's
    // references are read from.
    //
    // **A row whose facts will not read is left with no references written, and the migration
    // goes on.** It is not this step's to judge the store: a cell that is not text, or not the
    // JSON a row's facts are, is found by `load()` as it was before this step — which is what
    // decides whether the store is damaged — and a row that `load()` takes after all is read
    // leniently (`ReferenceRow.references`). A migration that threw here would be a stricter
    // and an earlier judge than the load, and since #295 a store judged damaged is deleted.
    //
    // `refs_due` is whether a row's references are still to be asked for (`Note.refsDue`), and
    // is **false for every row already held**: what an item refers to is asked for once, when
    // the item first arrives, and these arrived before there was any asking. So the first launch
    // of a build that loads does not go and fetch for every post on the device at once.
    //
    // **A migration id for `v3-holding`'s reason.** An older build's first save would write
    // every row back without either column's value — a row whose references were still to be
    // asked for would never have them asked — and, once a reblog is an item whose only content
    // is its reference, without the one thing that row says.
    //
    // **Frozen code**, as `v2-categories` is: it reads the facts by the names they were written
    // under and spells the references itself, so a later change to the live records cannot
    // change what this step did to a v9 store.
    migrator.registerMigration("v10-references") { db in
        struct V9Facts: Decodable {
            struct Reply: Decodable {
                var handle: String?
                var inReplyToId: String?
            }
            struct Quote: Decodable {
                struct Post: Decodable { var id: String }
                var state: String
                var statusID: String?
                var post: Post?
            }
            var reply: Reply?
            var quote: Quote?
        }
        struct V10Reference: Encodable {
            var kind: String
            var id: String?
            var statusID: String?
            var handle: String?
            var state: String?
        }
        try db.alter(table: "note") { t in
            t.add(column: "refs", .text)
            t.add(column: "refs_due", .boolean).notNull().defaults(to: false)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let update = try db.makeStatement(sql: "UPDATE note SET refs = ? WHERE rowid = ?")
        let rows = try Row.fetchAll(db, sql: "SELECT rowid AS rowid, facts AS facts FROM note")
        for row in rows {
            // Asked for as a value and turned into text here, so a cell that is not text is
            // nothing rather than a trap.
            guard let text = String.fromDatabaseValue(row["facts"] as DatabaseValue),
                  let facts = try? JSONDecoder().decode(V9Facts.self, from: Data(text.utf8))
            else { continue }
            var references: [V10Reference] = []
            if let reply = facts.reply {
                references.append(V10Reference(kind: "answers", statusID: reply.inReplyToId, handle: reply.handle))
            }
            if let quote = facts.quote {
                references.append(V10Reference(
                    kind: "quotes", id: quote.post?.id, statusID: quote.statusID, state: quote.state
                ))
            }
            let written = String(decoding: try encoder.encode(references), as: UTF8.self)
            try update.execute(arguments: [written, row["rowid"] as Int64])
        }
    }
    // One way of holding (#296): everything this device holds is an item and stands in its
    // timelines, so the column that said which rows were held apart from them goes. Dropped, not
    // left: nothing remains in the file that means "held apart" — no value to be honoured by a
    // build that still reads it, and none to be mistaken for a fact later.
    //
    // Every row is kept. One that was held apart is, from here, a row like any other; a forum
    // topic's kept reply is told by its own id (`Note.isTopicReply`), as it always could be — and
    // whether its forum dated it by the date kept with it since replies were kept (#297).
    //
    // **A migration id for `v3-holding`'s reason, turned round.** A build that knows the column
    // would write `aside` into it again for what a search or a thread brought, and this build
    // would then show in All what that build meant to hold apart — or, opening this store, it
    // would find no column and fail. The id makes it refuse the store instead.
    migrator.registerMigration("v11-one-holding") { db in
        try db.alter(table: "note") { t in
            t.drop(column: "holding")
        }
    }
    return migrator
}

/// One `Reference` as `note.refs` writes it, a JSON array of these in the order the item holds
/// them. The kind and a quote's state are in the spellings Core gives them; a name the source
/// did not say is left out.
///
/// **A new kind is a new migration** (`Reference`): this build reads only the kinds it knows.
private struct ReferenceRow: Codable {
    var kind: String
    var id: String?
    var statusID: String?
    var handle: String?
    var state: String?
    /// `Reference.gone` (#293): written only where true, so every cell written before it — and
    /// every reference that is not gone — is the text it always was. **A key, and no migration**:
    /// this reader takes a cell with keys it does not know and ignores them, so a build from
    /// before this key reads such a cell as the same references, not gone. (No such build opens
    /// this store — it is past `v11-one-holding` — but the cell would not stop one.)
    var gone: Bool?

    init(_ reference: Reference) {
        kind = reference.kind.rawValue
        id = reference.id
        statusID = reference.statusID
        handle = reference.handle
        state = reference.state?.rawValue
        gone = reference.gone ? true : nil
    }

    /// The most text a cell of references is read from: far past what `Reference.most` of them
    /// at `Reference.longest` each could spell, and a bound on what a carried store can make
    /// this device parse for one row.
    static let longestCell = 64 * 1024

    /// `references` as the cell's text. Keys in one order, so one set is always written one way.
    static func text(_ references: [Reference]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(references.map(ReferenceRow.init))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The references a cell holds — or nothing where it holds none this build can read: no
    /// cell, one too long, one that is not this JSON, or one naming a kind this build does not
    /// know. **Read leniently, as `earlier` is and for its reason**: a row whose references will
    /// not read is whole in every other way, and still says what it answers and quotes in its
    /// facts, so it is given those (`Reference.derived`) rather than the reader's whole store
    /// being set aside for one cell.
    static func references(_ text: String?) -> [Reference]? {
        guard let text, text.utf8.count <= longestCell,
              let rows = try? JSONDecoder().decode([ReferenceRow].self, from: Data(text.utf8))
        else { return nil }
        var references: [Reference] = []
        for row in rows {
            guard let kind = Reference.Kind(rawValue: row.kind) else { return nil }
            references.append(Reference(
                kind: kind, id: row.id, statusID: row.statusID, handle: row.handle,
                state: kind == .quotes ? Quote.State(wire: row.state) : nil, gone: row.gone == true
            ))
        }
        return references
    }
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
    /// What this source last said about itself (#188), or nothing where it has not been heard.
    /// A column behind its own migration id, for the reason given on `NoteRecord.kept`: an older build must refuse
    /// this store rather than save it back without every word.
    var said: SaidRow?
    /// When `said` was said. Nothing where `said` is nothing.
    var said_at: Date?

    init(_ source: Source, said profile: SourceProfile?) {
        host = source.host
        kind = source.kind.rawValue
        boards = source.boards.map(SubscriptionRow.init) + source.lists.map(SubscriptionRow.init)
        said = profile.map(SaidRow.init)
        said_at = profile?.asOf
    }

    /// The word this row keeps, marked as of when — or nothing where either half is missing, or
    /// the kind is one this build cannot name: a word with no moment is one nothing could draw as
    /// said then.
    var saidProfile: SourceProfile? {
        guard let said, let said_at else { return nil }
        return said.profile(host: host, asOf: said_at)
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

/// `SourceProfile` as `source.said` writes it (#188): every field the page draws, and none of
/// the host or the moment, which are the row's own columns. Core's `SourceProfile` stays free of
/// a storage format; this is the storage format.
///
/// **Every field optional, so a word written before a field existed still reads.** A registration
/// this build does not know reads as nothing said, never as a guess; a kind it does not know is
/// no word at all (`profile(host:asOf:)`), because a kept `.unknown` would silence the ask that
/// could correct it.
private struct SaidRow: Codable {
    var kind: String?
    var title: String?
    var summary: String?
    var thumbnail: URL?
    var activeMonth: Int?
    var statusLimit: Int?
    var people: Int?
    var posts: Int?
    var registration: String?
    var readsWithoutAccount: Bool?
    var rules: [String]?

    init(_ profile: SourceProfile) {
        kind = profile.kind.rawValue
        title = profile.title
        summary = profile.summary
        thumbnail = profile.thumbnail
        activeMonth = profile.activeMonth
        statusLimit = profile.statusLimit
        people = profile.people
        posts = profile.posts
        registration = profile.registration?.rawValue
        readsWithoutAccount = profile.readsWithoutAccount
        rules = profile.rules.isEmpty ? nil : profile.rules
    }

    func profile(host: String, asOf: Date) -> SourceProfile? {
        guard let kind = kind.flatMap(ProtocolKind.init(rawValue:)), kind != .unknown else { return nil }
        return SourceProfile(
            host: host, kind: kind, title: title,
            summary: summary,
            // Admitted through `Host.fetchableURL` before it was written, as every address in
            // `NoteFacts` was; read back as the rows' pictures are.
            thumbnail: thumbnail,
            activeMonth: activeMonth, statusLimit: statusLimit, people: people, posts: posts,
            registration: registration.flatMap(SourceProfile.Registration.init(rawValue:)),
            readsWithoutAccount: readsWithoutAccount, rules: rules ?? [], asOf: asOf
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
    /// `Note.source.kind` (#250), so a note kept after its source was removed still knows what
    /// kind of server it was read through: `load()` has no source row to take that from. Written
    /// on every row and read only where the host has no source row. Additive and optional for
    /// `boosted`'s reasons: a row written before reads as none, and such a row always has a
    /// source row, since nothing before this kept a note past its source.
    var kind: String?
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

/// `Wording` as `note.earlier` writes it.
private struct WordingRow: Codable {
    var body: String
    var spoiler: String?
    /// Absent where the source never said, which is `Wording.sensitive`'s own nothing.
    var sensitive: Bool?
    /// Milliseconds since 1970, the precision the row's own dates are kept at.
    var until: Int64

    init(_ wording: Wording) {
        body = wording.body
        spoiler = wording.spoiler
        sensitive = wording.sensitive
        until = Int64((wording.until.timeIntervalSince1970 * 1000).rounded())
    }

    var wording: Wording {
        Wording(
            body: body, spoiler: spoiler, sensitive: sensitive,
            until: Date(timeIntervalSince1970: Double(until) / 1000)
        )
    }

    /// `wordings` as the cell's text, or nothing for none.
    static func text(_ wordings: [Wording]) -> String? {
        guard !wordings.isEmpty, let data = try? JSONEncoder().encode(wordings.map(WordingRow.init)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The wordings a cell holds, or none where it holds nothing this build can read.
    static func wordings(_ text: String?) -> [Wording] {
        guard let text, let rows = try? JSONDecoder().decode([WordingRow].self, from: Data(text.utf8)) else {
            return []
        }
        return rows.map(\.wording)
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
    /// `Note.goneSince` (#179). A column behind its own migration id, for the reason given on `kept`.
    var gone_at: Date?
    /// `Note.kept` (#284). **A column behind its own migration id**, as every column added after
    /// the first is: a build that does not know the column must refuse the store, because its
    /// first save would write each row back without it — and what the column said would be gone.
    var kept: Bool
    /// `Note.bookmarked` (#285). A column behind its own migration id, for the reason given on `kept`.
    var bookmarked: Bool?
    /// `Note.editedAt` (#286). A column behind its own migration id, for the reason given on `kept`.
    var edited_at: Date?
    /// `Note.earlier` (#286) as a JSON array of `WordingRow`, or nothing where the row holds
    /// none. With `edited_at`'s id.
    ///
    /// **Kept as text and read leniently, unlike `facts`.** A `facts` that is not JSON fails the
    /// load closed, because a row with no words is not a row; a damaged `earlier` is a row that
    /// has lost what it said before and is whole in every other way, and setting the reader's
    /// whole store aside for that would cost them far more than the cell held.
    var earlier: String?
    /// `Note.language` (#287). A column behind its own migration id, for the reason given on `kept`.
    var language: String?
    /// `Note.refs` (#290, #293) as a JSON array of `ReferenceRow`. A column behind its own
    /// migration id, for the reason given on `kept`. Kept as text and read leniently: `ReferenceRow`.
    var refs: String?
    /// `Note.refsDue` (#293). With `refs`' id.
    var refs_due: Bool

    init(_ note: Note) {
        host = note.source.host
        id = note.id
        posted_at = note.postedAt
        gone_at = note.goneSince
        kept = note.kept
        bookmarked = note.bookmarked
        edited_at = note.editedAt
        earlier = WordingRow.text(note.earlier)
        language = note.language
        refs = ReferenceRow.text(note.refs)
        refs_due = note.refsDue
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
            quote: note.quote.map(QuoteRow.init),
            kind: note.source.kind.rawValue
        )
    }

    /// The source a note kept past its source's removal is stamped with (#250): the host, and
    /// the kind `facts` wrote down. Its boards and lists are gone with the source row, which is
    /// right — a row draws by host and kind, and a category is the note's own. Nothing where the
    /// row wrote no kind, which is a row from before this and a host nobody follows: nothing
    /// should draw it, as before.
    var formerSource: Source? {
        facts.kind.flatMap(ProtocolKind.init(rawValue:)).map { Source(host: host, kind: $0) }
    }

    /// The note this row holds, stamped with `source` — the row `load()` read for this host, or
    /// `formerSource` where that row has gone and the reader kept the posts (#250). The note
    /// table keeps no copy of a source's boards; `load()` drops a note whose host has neither,
    /// since a note from a server nobody follows is one nothing should draw.
    ///
    /// Categories come back as they went in, an empty set included: what a note arrived through
    /// is a fact about it, and filling in `.public` for none would put it somewhere it was never
    /// read from.
    ///
    /// **Nothing for a row that is no item** (#290): one whose references will not read and that
    /// holds no words, no title, no cover, no picture, no reply, no quote and no opening post. A
    /// reblog is exactly such a row but for its reference, so one whose cell is damaged, too long
    /// or names a kind this build does not know would otherwise open as an empty post by whoever
    /// reblogged — under the reblog's name, with the reblog's own id as an id to send. It is left
    /// out of the load instead, as a note whose host is gone is: the store is read and never set
    /// aside for it, and since a save writes the rows held, the next one writes the file without
    /// it. Nothing a reader could see is lost: the row had nothing to show and nothing to name.
    func note(from source: Source) -> Note? {
        let references = ReferenceRow.references(refs)
        if references == nil, facts.body.isEmpty, (facts.title ?? "").isEmpty, (facts.spoiler ?? "").isEmpty,
           facts.attachments.isEmpty, facts.reply == nil, facts.quote == nil, facts.opening == nil {
            return nil
        }
        return Note(
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
            bookmarked: bookmarked,
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
            goneSince: gone_at,
            gaps: Set(facts.gaps?.compactMap(\.gap) ?? []),
            listed: Dictionary(
                (facts.listed ?? []).compactMap { row in row.category.category.map { ($0, row.id) } },
                uniquingKeysWith: { a, _ in a }
            ),
            quote: facts.quote?.quote,
            kept: kept,
            editedAt: edited_at,
            // Held to the bounds every kept wording is held to, whoever wrote the cell.
            earlier: Wording.bounded(WordingRow.wordings(earlier)),
            language: language,
            // Nothing readable in the cell is the references its reply and quote state.
            refs: ReferenceRow.references(refs),
            refsDue: refs_due
        )
    }
}
