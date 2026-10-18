import FediqoCore
import Foundation
import GRDB
@preconcurrency import SQLite3

// The words index (#360, K-3, C24, C29): every row's tokens (`WordGrams`), so a keyword asks the
// file for the rows that may hold it rather than reading them all.
//
// **No writer can make it lie.** Triggers in plain SQL mark a row due whenever it is written,
// deleted, or its words change — by this build, by an older one (which knows nothing of the
// index and keeps the triggers firing all the same), by a read back, by `sqlite3` — and Swift
// makes the row's doc again from what the row says. A due row, and every row below `floor` (not
// built yet), is let through by whatever asks, so the index is a superset at every moment.
//
// **Outside the migrator, `IF NOT EXISTS`**, as the pages' indexes are (C8): no migration id, so
// an older build still opens the store and its saves still mark rows due. Made by the builder
// the launch starts once the timeline shows (`WordsBuilder`), and only where the SQLite this runs
// on has what it needs (`wordsCapable`): elsewhere the feature is off for the run, and nothing
// is made.

extension StoreFile {
    /// A row's indexed fields from its own cells, by name: nothing for facts that are not JSON or a
    /// field that is not there.
    private static func field(_ row: String, _ name: String) -> String {
        "(CASE WHEN json_valid(\(row).facts) THEN json_extract(\(row).facts, '$.\(name)') END)"
    }

    /// The fields a doc is made of (`WordGrams.doc`), as `NoteFacts` writes them.
    private static let wordFields = ["body", "handle", "author", "boosterHandle", "boostedBy"]

    /// A trigger's marking of `row` due. **Not `INSERT OR IGNORE`**: inside a trigger the
    /// statement that fired it decides what a conflict does — an upsert's aborts — so a row
    /// already due would fail the save that wrote it, an older build's included.
    private static func due(_ row: String) -> String {
        "INSERT INTO note_words_due SELECT \(row).rowid WHERE NOT EXISTS (SELECT 1 FROM note_words_due WHERE rowid = \(row).rowid);"
    }

    /// The words index's own objects, each made where the file lacks it.
    static let wordsSchema: [String] = [
        "CREATE VIRTUAL TABLE IF NOT EXISTS note_words USING fts5(g, tokenize='ascii', content='', contentless_delete=1, detail=none)",
        // Rows whose doc is stale or missing.
        "CREATE TABLE IF NOT EXISTS note_words_due(rowid INTEGER PRIMARY KEY)",
        // `floor`: rows below it are not built yet; 0 once every row has been.
        "CREATE TABLE IF NOT EXISTS note_words_state(k TEXT PRIMARY KEY, v)",
        "CREATE TRIGGER IF NOT EXISTS note_words_ins AFTER INSERT ON note BEGIN \(due("new")) END",
        "CREATE TRIGGER IF NOT EXISTS note_words_del AFTER DELETE ON note BEGIN \(due("old")) END",
        // **Only where an indexed field changed**: a reader's mark, a count, a gap rewrites `facts`
        // and marks nothing due.
        """
        CREATE TRIGGER IF NOT EXISTS note_words_upd AFTER UPDATE OF facts, host ON note
        WHEN old.host IS NOT new.host OR (old.facts IS NOT new.facts AND (\(
            wordFields.map { "\(field("old", $0)) IS NOT \(field("new", $0))" }.joined(separator: " OR ")
        )))
        BEGIN \(due("new")) END
        """,
    ]

    /// Whether the SQLite this process runs on keeps the words index (K-3): 3.43 or later, for
    /// `contentless_delete`, and FTS5 built in. Asked once, of the library: no connection made.
    /// Should the making fail all the same, it fails the build, never a save.
    static let wordsCapable = sqlite3_libversion_number() >= 3_043_000 && sqlite3_compileoption_used("ENABLE_FTS5") == 1

    /// Whether this file has the words index.
    /// The triggers that keep the index in step: **without any one of them it is not trusted**.
    /// A rebuild of `note` — a table rewritten by some migration, by `sqlite3` — drops them, and
    /// rows written before they are made again were never marked due.
    static let wordsTriggers = ["note_words_ins", "note_words_del", "note_words_upd"]

    /// Whether this file has the words index whole: its tables, a floor, and every trigger.
    static func hasWords(_ db: Database) throws -> Bool {
        guard try db.tableExists("note_words_state"), try db.tableExists("note_words_due"), try db.tableExists("note_words"),
              try Int64.fetchOne(db, sql: "SELECT v FROM note_words_state WHERE k = 'floor'") != nil
        else { return false }
        let triggers = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'note'
            AND name IN (SELECT value FROM json_each(?))
            """, arguments: [String(decoding: try JSONEncoder().encode(wordsTriggers), as: UTF8.self)]) ?? 0
        return triggers == wordsTriggers.count
    }

    /// Makes the index where the file lacks it, in the caller's transaction: every row then
    /// held is below `floor`, and every row written after is due by its trigger. **Where it is
    /// there but not whole** — a trigger or the floor lost — it is started again the same way,
    /// no doc kept and nothing due: what was written meanwhile may have been marked by nothing.
    /// False where this SQLite cannot keep it.
    static func makeWords(_ db: Database, capable: Bool) throws -> Bool {
        guard capable else { return false }
        let whole = try hasWords(db)
        for sql in wordsSchema { try db.execute(sql: sql) }
        if !whole {
            // No row below a floor has a doc (`writeDocs`).
            try db.execute(sql: "INSERT INTO note_words(note_words) VALUES ('delete-all')")
            try db.execute(sql: "DELETE FROM note_words_due")
            try setFloor(db, to: Int64.fetchOne(db, sql: "SELECT COALESCE(max(rowid), 0) + 1 FROM note") ?? 1)
        }
        return true
    }

    private static func floor(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT v FROM note_words_state WHERE k = 'floor'") ?? Int64.max
    }

    private static func setFloor(_ db: Database, to floor: Int64) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO note_words_state(k, v) VALUES ('floor', ?)", arguments: [floor])
    }

    /// A row's fields as its doc is made of them, as the file holds them: nothing for a row no
    /// longer there.
    private struct DocFields: Equatable, Sendable {
        let rowid: Int64
        let host: String?
        let body: String?
        let handle: String?
        let author: String?
        let boosterHandle: String?
        let boostedBy: String?

        init(_ row: Row) {
            func text(_ name: String) -> String? { String.fromDatabaseValue(row[name] as DatabaseValue) }
            rowid = row["rowid"]
            host = text("host")
            body = text("body")
            handle = text("handle")
            author = text("author")
            boosterHandle = text("boosterHandle")
            boostedBy = text("boostedBy")
        }

        /// The row's doc, or nothing for a row that is gone.
        var doc: String? {
            guard let host else { return nil }
            return WordGrams.doc(
                body: body ?? "", handle: handle ?? "", author: author ?? "",
                boosterHandle: boosterHandle, boostedBy: boostedBy, host: host
            )
        }
    }

    /// A row's fields as a doc is made of them, from the table `n`.
    private static let docColumns = (["n.host AS host"] + wordFields.map { "\(field("n", $0)) AS \($0)" }).joined(separator: ", ")

    /// The docs written again, each under its row: `replacing` deletes the one there first, since
    /// a contentless table takes a second doc under one rowid without a word.
    ///
    /// **A row below `floor` has no doc**: the builder makes it as `floor` passes it, a due mark
    /// below it is only taken off, and a new floor drops every doc — so the build only adds. A
    /// delete is no saving to pass up: it rewrites its segment's tombstones, milliseconds on a
    /// large index, where an insert costs microseconds.
    ///
    /// **A doc taken out for a row that is gone owes a rewrite** (`oweLetGo`), whoever deleted the
    /// row — an older build, `sqlite3`, a save whose own marking was swallowed: its tokens stay in
    /// the file until `letWordsGo`.
    private static func writeDocs(_ db: Database, _ docs: [(rowid: Int64, doc: String?)], replacing: Bool) throws {
        let delete = try db.cachedStatement(sql: "DELETE FROM note_words WHERE rowid = ?")
        let insert = try db.cachedStatement(sql: "INSERT INTO note_words(rowid, g) VALUES (?, ?)")
        var gone = false
        for (rowid, doc) in docs {
            if replacing { try delete.execute(arguments: [rowid]) }
            if let doc, !doc.isEmpty { try insert.execute(arguments: [rowid, doc]) }
            gone = gone || (replacing && doc == nil)
        }
        if gone { try oweLetGo(db) }
    }

    /// The due rows at or above `floor`, newest first, as they stand.
    private static func dueRows(_ db: Database, from floor: Int64, limit: Int) throws -> [DocFields] {
        try Row.fetchAll(db, sql: """
            SELECT d.rowid AS rowid, \(docColumns) FROM note_words_due d LEFT JOIN note n ON n.rowid = d.rowid
            WHERE d.rowid >= ? ORDER BY d.rowid DESC LIMIT ?
            """, arguments: [floor, limit]).map(DocFields.init)
    }

    /// Makes the docs of up to `limit` due rows, newest first; a due row below `floor` is only
    /// unmarked, the builder making its doc when it gets there. Returns how many it made.
    @discardableResult
    static func drainWords(_ db: Database, limit: Int) throws -> Int {
        let floor = try floor(db)
        try db.execute(sql: "DELETE FROM note_words_due WHERE rowid < ?", arguments: [floor])
        let rows = try dueRows(db, from: floor, limit: limit)
        try writeDocs(db, rows.map { ($0.rowid, $0.doc) }, replacing: true)
        let done = try db.cachedStatement(sql: "DELETE FROM note_words_due WHERE rowid = ?")
        for row in rows { try done.execute(arguments: [row.rowid]) }
        return rows.count
    }

    /// The most due rows a save makes the docs of in its own transaction: what an ordinary save
    /// marks. More — an older build's whole rewrite, a read back — are the builder's.
    static let drainedInSave = 500

    /// Inside a save's transaction: the docs of what it wrote, where they are few, so a page
    /// after the save never meets a stale one. **Never the save's failure**: in a savepoint of its
    /// own, and what it could not make stays due.
    ///
    /// Returns whether it left more due than it drains — an older build's rewrite, a read back —
    /// for the save to hand to the builder (`StoreFile.wordsLeftDue`).
    ///
    /// `letGo`: the save deleted rows, whose tokens the index keeps until it is rewritten —
    /// owed (`oweLetGo`) in the same transaction, for `letWordsGo` to take out.
    @discardableResult
    static func drainWordsInSave(_ db: Database, letGo: Bool = false) -> Bool {
        guard wordsCapable, (try? hasWords(db)) == true else { return false }
        if letGo { try? oweLetGo(db) }
        var many = false
        try? db.inSavepoint {
            try db.execute(sql: "DELETE FROM note_words_due WHERE rowid < ?", arguments: [floor(db)])
            let due = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM note_words_due LIMIT ?)", arguments: [drainedInSave + 1]) ?? 0
            if due > 0, due <= drainedInSave { try drainWords(db, limit: drainedInSave) }
            many = due > drainedInSave
            return .commit
        }
        return many
    }

    // MARK: - The words of what was let go (K-11, C27)

    /// **A deleted doc's tokens stay in the file until its segment is merged.** FTS5 deletes
    /// lazily: a delete is a tombstone, and the doc's tokens stay in the segment they were
    /// written in — a page in use, so `secure_delete` has nothing to zero. FTS5's own
    /// `secure-delete` needs SQLite 3.44, and the targets ship 3.43.2. So a save that deletes
    /// rows marks the index owed (`letgo` in `note_words_state`, in the save's own transaction,
    /// so a quit before the rewrite leaves it owed for the next), and `letWordsGo`, after the act
    /// that let the posts go, rewrites the index whole: the old segments freed, and zeroed as
    /// they are.
    static func oweLetGo(_ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO note_words_state(k, v) VALUES ('letgo', 1)")
    }

    private static func letGoOwed(_ db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT v FROM note_words_state WHERE k = 'letgo'") != nil
    }

    /// Whether a save let rows go whose tokens `letWordsGo` has not taken out of the file yet.
    func wordsLetGoOwed() throws -> Bool {
        try db.read { db in try Self.hasWords(db) && Self.letGoOwed(db) }
    }

    /// What the words index is made of in the file: its segments, and the pages of tombstones —
    /// docs deleted whose tokens a segment still holds. **Clean** is one segment at most and no
    /// tombstone: every token in the file is a live doc's. Read off `note_words_data`'s ids,
    /// where a segment's pages sit under its id from bit 37 up, and a tombstone page's above
    /// 65,535.
    struct WordsShape: Equatable, Sendable {
        let segments: Int
        let tombstonePages: Int
        var isClean: Bool { segments <= 1 && tombstonePages == 0 }
    }

    static func wordsShape(_ db: Database) throws -> WordsShape {
        WordsShape(
            segments: try Int.fetchOne(db, sql: """
                SELECT count(DISTINCT id >> 37) FROM note_words_data WHERE (id >> 37) BETWEEN 1 AND 65535
                """) ?? 0,
            tombstonePages: try Int.fetchOne(db, sql: "SELECT count(*) FROM note_words_data WHERE (id >> 37) > 65535") ?? 0
        )
    }

    func wordsShape() throws -> WordsShape? {
        try db.read { db in try Self.hasWords(db) ? Self.wordsShape(db) : nil }
    }

    /// One merge step of the rewrite, in the caller's write: at most `mergedPages` of the index's
    /// pages written (`merge`, negative so segments merge whatever their level). Whether it
    /// changed anything — false once there is nothing left to merge.
    private static func mergeWordsPages(_ db: Database, pages: Int) throws -> Bool {
        let before = db.totalChangesCount
        try db.execute(sql: "INSERT INTO note_words(note_words, rank) VALUES ('merge', ?)", arguments: [-pages])
        return db.totalChangesCount - before >= 2
    }

    /// The last of a pass, in the caller's write: what the merge steps left merged into one
    /// (`optimize`) — nothing to do where they left one segment with no tombstone — and the
    /// shape read in the same write.
    private static func finishWordsPass(_ db: Database) throws -> WordsShape {
        try db.execute(sql: "INSERT INTO note_words(note_words) VALUES ('optimize')")
        return try wordsShape(db)
    }

    /// The most passes one `letWordsGo` makes before it leaves the index owed for the next: a
    /// pass's last `optimize` may finish a merge FTS5 had begun (`deletemerge`, as a large
    /// letting go is drained) and keep the tombstones added meanwhile, and another clears them.
    static let rewritePasses = 4

    /// The most merge steps one pass makes before its `optimize`: a bound, never met in practice.
    static let mergeStepsMost = 10_000

    /// The due rows a write of `letWordsGo` makes the docs of: fewer than a save drains, so a page
    /// waits for one write of them and not for a long one.
    static let drainedWhileLetGo = 100

    /// Runs one write of the rewrite where a save would run, where there is a saver — **each step
    /// on its own**, so the saves asked meanwhile go between two — and in the caller's place
    /// otherwise (`compact()`, which holds the saver already).
    private func step<T: Sendable>(_ saver: StoreSaver?, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let saver else { return try await body() }
        return try await saver.exclusively(body)
    }

    /// Takes the tokens of every row let go out of the file (C27, in steps): the docs of the rows
    /// still due made first — a row let go and not drained yet still has its doc —
    /// `drainedWhileLetGo` rows a write; then the index merged a step a write (`merge`,
    /// `mergedPages` pages), `wordsPause` between two, until a step changes nothing; then, in one
    /// last write, what is left merged into one (`optimize`) and its shape read (`WordsShape`). A
    /// pass not clean is made again, at most `rewritePasses`. Every segment the rewrite leaves
    /// behind is freed, zeroed by `secure_delete`. Returns whether it rewrote.
    ///
    /// **The mark comes off in the last write, and only where the index is clean**: a quit, an
    /// interruption or a failure on the way leaves it owed, and the next launch takes it up again
    /// (`letWordsGoIfOwed`); a step done is never done again.
    ///
    /// **Each write where a save would run, on its own** (`saver`, `StoreSaver.exclusively`):
    /// saves asked meanwhile go between two, and a page waits for one step and not for the
    /// rewrite. Without a saver, in the caller's place — `compact()`, which holds it already.
    /// Never on the main thread.
    ///
    /// **Once for however many acts asked**: nothing where nothing is owed, so acts one after
    /// another rewrite the index once. Nothing where this SQLite cannot keep the index, or the
    /// file has none whole. `compact()` runs it first, before it gives the room back.
    @discardableResult
    public func letWordsGo(in saver: StoreSaver? = nil) async throws -> Bool {
        try await letWordsGo(capable: Self.wordsCapable, in: saver)
    }

    /// `letWordsGo(in:)`, as though this SQLite could keep the index or not, with at most
    /// `passes`, `pause` between two writes, and `meanwhile` run once between the first two merge
    /// steps — for a test, the writes another may make. `steps: false` is no merge step, only
    /// the `optimize` of each pass.
    @discardableResult
    func letWordsGo(
        capable: Bool, in saver: StoreSaver? = nil, passes: Int = StoreFile.rewritePasses, steps: Bool = true,
        pause: Duration = StoreFile.wordsPause, meanwhile: (@Sendable () async throws -> Void)? = nil
    ) async throws -> Bool {
        guard capable, try await db.read({ db in try Self.hasWords(db) && Self.letGoOwed(db) }) else { return false }
        let db = self.db
        while try await step(saver, {
            try await db.write { db in
                precondition(!Thread.isMainThread, "the words index is rewritten off the main thread")
                guard try Self.hasWords(db) else { return false }
                return try Self.drainWords(db, limit: Self.drainedWhileLetGo) == Self.drainedWhileLetGo
            }
        }) {
            if pause > .zero { try await Task.sleep(for: pause) }
        }
        var rewrote = false
        var meanwhile = meanwhile
        for _ in 0..<max(1, passes) {
            for _ in 0..<(steps ? Self.mergeStepsMost : 0) {
                let merged = try await step(saver, {
                    try await db.write { db -> Bool? in
                        precondition(!Thread.isMainThread, "the words index is rewritten off the main thread")
                        guard try Self.hasWords(db), try Self.letGoOwed(db) else { return nil }
                        return try Self.mergeWordsPages(db, pages: Self.mergedPages)
                    }
                })
                guard let merged else { return rewrote }
                rewrote = true
                guard merged else { break }
                if pause > .zero { try await Task.sleep(for: pause) }
                if let asked = meanwhile {
                    meanwhile = nil
                    try await asked()
                }
            }
            let clean = try await step(saver, {
                try await db.write { db -> Bool? in
                    precondition(!Thread.isMainThread, "the words index is rewritten off the main thread")
                    guard try Self.hasWords(db), try Self.letGoOwed(db) else { return nil }
                    guard try Self.finishWordsPass(db).isClean else { return false }
                    try db.execute(sql: "DELETE FROM note_words_state WHERE k = 'letgo'")
                    return true
                }
            })
            guard let clean else { break }
            rewrote = true
            if clean { break }
            if pause > .zero { try await Task.sleep(for: pause) }
        }
        return rewrote
    }

    /// `letWordsGo(in:)` where a mark was left — a quit or a crash before the rewrite ended, a
    /// rewrite that failed, the first save dropping rows nothing could draw — **asked once the
    /// first page shows**, each step where a save would run, before the file is scrubbed.
    /// Nothing where none is owed.
    public func letWordsGoIfOwed(in saver: StoreSaver?) async {
        guard (try? wordsLetGoOwed()) == true else { return }
        _ = try? await letWordsGo(in: saver)
    }

    /// Inside a save that empties `note` — a read back, or its undo: every doc goes with the rows
    /// at once (`delete-all`, its pages freed and zeroed), and nothing deleted is left due or
    /// owed. The rows written after are due by their triggers, or below `floor`, as any row is.
    /// **Never the save's failure**: in a savepoint of its own — and owed first, outside it, so
    /// one that failed leaves the old docs owed a rewrite.
    static func emptyWordsInSave(_ db: Database) {
        guard wordsCapable, (try? hasWords(db)) == true else { return }
        try? oweLetGo(db)
        try? db.inSavepoint {
            try db.execute(sql: "INSERT INTO note_words(note_words) VALUES ('delete-all')")
            try db.execute(sql: "DELETE FROM note_words_due")
            try db.execute(sql: "DELETE FROM note_words_state WHERE k = 'letgo'")
            return .commit
        }
    }

    /// The rows a build makes the docs of in one write: some 50 ms holding the queue at 270,000
    /// rows, which is what a read beside it waits at most.
    static let wordsChunk = 250

    /// How long the build stands aside after each write. **What keeps a page quick beside it**:
    /// a page is several reads one after another, each queued behind whatever write is in
    /// flight, and a build that queued its next write at once would put one of its writes in
    /// front of every one of them.
    static let wordsPause = Duration.milliseconds(30)

    /// The reblogs of a post, by the post's name (K-4): what a keyword page adds to the posts it
    /// matches. A reblog's `refs` is its one `reblogs` reference (`Note.init`), so the first is
    /// its target; the page asks the kind again. A write of its own, before the build.
    static let reblogsIndex = """
        CREATE INDEX IF NOT EXISTS note_reblogs ON note(host, (CASE WHEN json_valid(refs) THEN json_extract(refs, '$[0].id') END)) \
        WHERE instr(refs, '"reblogs"') > 0
        """

    /// The rows that say they reblog and whose first reference is not the reblog — or whose
    /// references are not JSON — word for word as `oddReblogsIndex` holds them. `note_reblogs`
    /// finds a reblog by its first reference, and `Note.reblogKey` reads the first that reblogs,
    /// so where these differ a page reads every such row rather than miss one. None that this
    /// build writes (`Note.init` keeps a reblog's one reference); an older build's may be.
    static let oddReblog = """
        instr(refs, '"reblogs"') > 0 AND (CASE WHEN json_valid(refs) THEN json_extract(refs, '$[0].kind') END) IS NOT 'reblogs'
        """

    /// The rows of `oddReblog`: few or none, so a page asks for them at the cost of a lookup.
    static let oddReblogsIndex = "CREATE INDEX IF NOT EXISTS note_reblogs_odd ON note(host) WHERE \(oddReblog)"

    /// Builds the words index (K-3), making it first where the file lacks it — or where it is not
    /// whole — and `note_reblogs`: the due rows, then the rows below `floor`, newest arrivals
    /// first, `chunk` a write transaction, a pause after each — then its segments merged, in
    /// steps. **Resumable**: `floor` is in the file, and a build stopped — by its task's
    /// cancelling, or a quit — goes on from there at the next. Nothing where this SQLite cannot
    /// keep the index. About two minutes at 270,000 rows. The app's is `WordsBuilder`'s, which
    /// makes each write where a save would run.
    func buildWords(chunk: Int, capable: Bool, pause: Duration = .zero) async throws {
        guard try await db.write({ db in try Self.makeWords(db, capable: capable) }) else { return }
        try await db.write { db in try db.execute(sql: Self.reblogsIndex) }
        try await db.write { db in try db.execute(sql: Self.oddReblogsIndex) }
        while !Task.isCancelled, try await buildWordsStep(chunk: chunk) {
            if pause > .zero { try await Task.sleep(for: pause) }
        }
        while !Task.isCancelled, try await mergeWordsStep() {
            if pause > .zero { try await Task.sleep(for: pause) }
        }
    }

    /// The index's pages a merge step writes at most: tens of milliseconds holding the queue.
    static let mergedPages = 400

    /// One step of merging the index's segments, a write of its own; false once there was
    /// nothing to merge. **What a build leaves is hundreds of small segments**, and every save
    /// after would then pay to merge them a little at a time — 60 ms for forty rows at 270,000,
    /// against 12 once merged. Merged here in steps rather than by one `optimize`, which held
    /// the queue for seconds.
    func mergeWordsStep(pages: Int = StoreFile.mergedPages) async throws -> Bool {
        try await db.write { db in
            guard try Self.hasWords(db) else { return false }
            let before = db.totalChangesCount
            try db.execute(sql: "INSERT INTO note_words(note_words, rank) VALUES ('merge', ?)", arguments: [-pages])
            return db.totalChangesCount - before >= 2
        }
    }

    /// One chunk of the build; false once nothing is left to do.
    ///
    /// **The words are cut off the queue**: the rows are read, their docs made in Swift between
    /// the read and the write, and the write holds the queue only for the index's own work — so a
    /// page waits for that and not for the cutting. In the write each row is read again, and one
    /// that changed meanwhile is cut again there; and nothing is written where `floor` moved.
    ///
    /// `meanwhile` runs between the read and the write: for a test, the writes another may make.
    func buildWordsStep(chunk: Int = StoreFile.wordsChunk, meanwhile: (@Sendable () async throws -> Void)? = nil) async throws -> Bool {
        let planned = try await db.read { db -> (due: Bool, floor: Int64, rows: [DocFields])? in
            guard try Self.hasWords(db) else { return nil }
            let floor = try Self.floor(db)
            let due = try Self.dueRows(db, from: floor, limit: chunk)
            if !due.isEmpty { return (true, floor, due) }
            guard floor > 0 else { return (false, floor, []) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.rowid AS rowid, \(Self.docColumns) FROM note n WHERE n.rowid < ? ORDER BY n.rowid DESC LIMIT ?
                """, arguments: [floor, chunk]).map(DocFields.init)
            return (false, floor, rows)
        }
        guard let planned, planned.due || planned.floor > 0 else { return false }
        let made = planned.rows.map { ($0, $0.doc) }
        try await meanwhile?()
        return try await db.write { db in
            guard try Self.hasWords(db), try Self.floor(db) == planned.floor else { return true }
            let rowids = String(decoding: try JSONEncoder().encode(planned.rows.map(\.rowid)), as: UTF8.self)
            var now: [Int64: DocFields] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT n.rowid AS rowid, \(Self.docColumns) FROM note n WHERE n.rowid IN (SELECT value FROM json_each(?))
                """, arguments: [rowids]) {
                let fields = DocFields(row)
                now[fields.rowid] = fields
            }
            try Self.writeDocs(db, made.map { read, doc in
                guard let current = now[read.rowid] else { return (read.rowid, nil) }
                return (read.rowid, current == read ? doc : current.doc)
            }, replacing: planned.due)
            try db.execute(sql: "DELETE FROM note_words_due WHERE rowid < ?", arguments: [planned.floor])
            if planned.due {
                let done = try db.cachedStatement(sql: "DELETE FROM note_words_due WHERE rowid = ?")
                for row in planned.rows { try done.execute(arguments: [row.rowid]) }
                return true
            }
            let floor = planned.rows.count < chunk ? 0 : planned.rows.last?.rowid ?? 0
            // A row written below the old floor since the read — its mark taken off, being below
            // — and not read is above the new one with no doc: due again.
            try db.execute(sql: """
                INSERT INTO note_words_due SELECT rowid FROM note WHERE rowid >= ? AND rowid < ?
                AND rowid NOT IN (SELECT value FROM json_each(?)) AND rowid NOT IN (SELECT rowid FROM note_words_due)
                """, arguments: [floor, planned.floor, rowids])
            try Self.setFloor(db, to: floor)
            return planned.rows.count == chunk
        }
    }

    /// Where the words index stands, or nothing where the file has none or this SQLite cannot
    /// read it.
    struct WordsState: Equatable {
        /// Rows below this are not built yet; 0 once every row has been.
        let floor: Int64
        let due: Int
    }

    func wordsState() throws -> WordsState? {
        try db.read { db in
            guard Self.wordsCapable, try Self.hasWords(db) else { return nil }
            return WordsState(floor: try Self.floor(db), due: try Int.fetchOne(db, sql: "SELECT count(*) FROM note_words_due") ?? 0)
        }
    }

    /// The rows that may hold `folded` (a keyword as `Fold.key` makes it) in their body: those it
    /// matches, those due, those below `floor`. Nothing where every row may, or the file has no
    /// words index.
    func wordCandidates(_ folded: String) throws -> Set<Int64>? {
        guard let tokens = WordGrams.asked(folded) else { return nil }
        return try db.read { db in
            guard Self.wordsCapable, try Self.hasWords(db) else { return nil }
            return Set(try Int64.fetchAll(db, sql: """
                SELECT rowid FROM note WHERE rowid < (SELECT v FROM note_words_state WHERE k = 'floor')
                OR rowid IN (SELECT rowid FROM note_words_due)
                OR rowid IN (SELECT rowid FROM note_words WHERE note_words MATCH ?)
                """, arguments: [WordGrams.match(tokens)]))
        }
    }

    // MARK: - A keyword's page (K-4)

    /// How a page asks a timeline's keywords (`Prefilter.Member.words`) of the file.
    enum WordsAsk: Equatable, Sendable {
        /// Of nothing: every row may hold them — the feature is off, the file has no index whole,
        /// or a keyword is one every row holds.
        case open
        /// Of the index, row by row as the page reads them (`mayHold`): a row not built yet or
        /// due passes, and a reblog passes by the post it reblogs.
        case index
        /// Only these rows may hold them: the posts the index finds, the rows due, and the
        /// reblogs of either — read by rowid, and sorted, rather than walking the timeline.
        case candidates([Int64])
    }

    /// The most posts a timeline's keywords may find for a page to read only them (K-4): more,
    /// and the page walks the timeline asking each row of the index, which a keyword found that
    /// often makes quick. **Counted capped**, so asking costs at most this many.
    static let wordsCandidatesMost = 5_000

    /// Whether a row is one the index gives for a keyword or may not have built yet — `r` the
    /// row's table, one argument: the keyword's tokens (`WordGrams.match`).
    private static func mayHoldOwn(_ r: String) -> String {
        """
        (\(r).rowid < (SELECT v FROM note_words_state WHERE k = 'floor') OR \(r).rowid IN (SELECT rowid FROM note_words_due) \
        OR \(r).rowid IN (SELECT rowid FROM note_words WHERE note_words MATCH ?))
        """
    }

    /// Whether a row of `note` may hold a keyword, as `verdict` reads one: in its own body, or —
    /// a reblog — in the body of the post it reblogs, looked up by key within its own host as
    /// `Note.reblogKey` looks it up. Two arguments, the keyword's tokens twice. **A reblog
    /// whose references are not JSON passes**, for the decode to judge.
    ///
    /// **The reference first, then the post by its key** (`CROSS JOIN`): left to choose, SQLite
    /// walks every row of the host for each reblog — seconds a chunk, measured.
    static let mayHold = """
        (\(mayHoldOwn("note")) OR (instr(note.refs, '"reblogs"') > 0 AND (CASE WHEN json_valid(note.refs) THEN EXISTS (\
        SELECT 1 FROM json_each(note.refs) r CROSS JOIN note t WHERE r.type = 'object' AND json_extract(r.value, '$.kind') = 'reblogs' \
        AND t.host = note.host AND t.id = json_extract(r.value, '$.id') AND \(mayHoldOwn("t"))) ELSE 1 END)))
        """

    /// Whether this file has the indexes a page's reblogs of the posts it found are read by,
    /// `note_reblogs` and `note_reblogs_odd`: made by the build, and by nothing else.
    private static func hasReblogsIndexes(_ db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name IN ('note_reblogs', 'note_reblogs_odd')
            """) == 2
    }

    /// The keywords of `prefilter`'s keyword group, folded: rules of one kind are one group, so
    /// there is one at most.
    static func keywords(_ prefilter: CompiledTimeline.Prefilter) -> [(folded: String, host: String?)] {
        prefilter.groups.first { group in
            group.allSatisfy { if case .words = $0 { true } else { false } }
        }?.compactMap { member -> (String, String?)? in if case .words(let folded, let host) = member { (folded, host) } else { nil } } ?? []
    }

    /// How a page asks `prefilter`'s keywords (K-4): `candidates` where the index is whole —
    /// built to the bottom, `note_reblogs` and `note_reblogs_odd` there — and its keywords, the
    /// rows due and the odd reblogs come to at most `most` rows, **counted as fetched**, before
    /// one found twice is set aside: a fetch cut at its limit is never taken for all there is;
    /// `index` where it is there but not so; `open` where there is none, or no keyword to ask.
    static func wordsAsk(_ db: Database, _ prefilter: CompiledTimeline.Prefilter, most: Int, capable: Bool = wordsCapable) throws -> WordsAsk {
        let keywords = keywords(prefilter).map(\.folded)
        guard !keywords.isEmpty else { return .open }
        let asked = keywords.map { WordGrams.asked($0) }
        // An empty keyword: every row holds it.
        let matches = asked.contains { $0 == nil } ? nil : asked.compactMap { $0.map(WordGrams.match) }
        return try wordsAsk(db, matches: matches, most: most, capable: capable)
    }

    /// How a page asks the index for the rows any of `matches` — FTS5 queries of tokens — may
    /// find, as `wordsAsk(_:_:most:capable:)` says; `matches` nothing where one is a query every
    /// row answers. What a keyword timeline and a search (`searchMatch`) both ask by.
    ///
    /// `also`: rows found by their own cells besides — a search's categories — each a condition
    /// on a row of `note` and its arguments, fetched capped and counted toward `most` as the
    /// index's answers are.
    static func wordsAsk(
        _ db: Database, matches: [String]?, also: [(sql: String, arguments: StatementArguments)] = [], most: Int,
        capable: Bool = wordsCapable
    ) throws -> WordsAsk {
        guard capable, try hasWords(db) else { return .open }
        guard most > 0, try floor(db) <= 0, try hasReblogsIndexes(db) else { return .index }
        guard let matches else { return .open }
        var found: [Int64] = []
        var seen = Set<Int64>()
        var fetched = 0
        func add(_ rowids: [Int64]) {
            for rowid in rowids where seen.insert(rowid).inserted { found.append(rowid) }
        }
        /// Adds what `sql` gives, one argument and the limit, and says whether it all fits.
        func fetch(_ sql: String, _ arguments: StatementArguments = []) throws -> Bool {
            let rows = try Int64.fetchAll(db, sql: sql + " LIMIT ?", arguments: arguments + [most + 1 - fetched])
            fetched += rows.count
            add(rows)
            return fetched <= most
        }
        guard try fetch("SELECT rowid FROM note_words_due") else { return .index }
        guard try fetch("SELECT rowid FROM note INDEXED BY note_reblogs_odd WHERE \(oddReblog)") else { return .index }
        for match in matches {
            guard try fetch("SELECT rowid FROM note_words WHERE note_words MATCH ?", [match]) else { return .index }
        }
        for (condition, arguments) in also {
            guard try fetch("SELECT rowid FROM note WHERE \(condition)", arguments) else { return .index }
        }
        // Their reblogs, by `note_reblogs`: by the first reference, which for every reblog but
        // the odd ones — all here already — is the one `Note.reblogKey` reads.
        // Counted toward the cap as every fetch is.
        let posts = String(decoding: try JSONEncoder().encode(found), as: UTF8.self)
        guard try fetch("""
            SELECT r.rowid FROM note t, note r INDEXED BY note_reblogs
            WHERE t.rowid IN (SELECT value FROM json_each(?)) AND r.host = t.host
            AND (CASE WHEN json_valid(r.refs) THEN json_extract(r.refs, '$[0].id') END) = t.id AND instr(r.refs, '"reblogs"') > 0
            """, [posts]) else { return .index }
        return .candidates(found)
    }

    // MARK: - A search's page (K-5, C25)

    /// What a search for a pattern of `literals` (`WildcardPattern.literals`) asks the index, as
    /// one FTS5 query: **every run in one field**, as the pattern matches one field whole — the
    /// body's tokens (`b`), or those of the names beside it (`o`), which are cut of several fields
    /// and so only ever let more through. Nothing for a pattern of wildcards alone, which no
    /// index narrows.
    static func searchMatch(_ literals: [String]) -> String? {
        let runs = literals.filter { !$0.isEmpty }
        guard !runs.isEmpty else { return nil }
        let sides = [WordGrams.Field.body, .other].map { field -> String in
            var seen = Set<String>()
            let tokens = runs.flatMap { WordGrams.asked($0, in: field) ?? [] }.filter { seen.insert($0).inserted }
            return "(" + WordGrams.match(tokens) + ")"
        }
        return sides.joined(separator: " OR ")
    }

    // MARK: - The rowid guard

    /// Runs `body` — a `VACUUM` — and, where it renumbered the rows (SQLite says it may, for a
    /// table with no `INTEGER PRIMARY KEY`, and the index is keyed by rowid), builds the words
    /// index again from the start: every row below a new `floor`, nothing due, no doc kept. By
    /// the rows' count, lowest, highest and sum of rowids, before and after. Outside any
    /// transaction, as `VACUUM` is.
    static func guardingRowids(_ db: Database, _ body: () throws -> Void) throws {
        let watched = try hasWords(db)
        let before = watched ? try rowidPrint(db) : nil
        try body()
        guard let before, try rowidPrint(db) != before else { return }
        try db.inTransaction {
            if wordsCapable { try db.execute(sql: "INSERT INTO note_words(note_words) VALUES ('delete-all')") }
            try db.execute(sql: "DELETE FROM note_words_due")
            try setFloor(db, to: Int64.fetchOne(db, sql: "SELECT COALESCE(max(rowid), 0) + 1 FROM note") ?? 1)
            return .commit
        }
    }

    private static func rowidPrint(_ db: Database) throws -> [Int64?] {
        guard let row = try Row.fetchOne(db, sql: "SELECT count(*), min(rowid), max(rowid), sum(rowid) FROM note") else { return [] }
        return (0..<4).map { (column: Int) -> Int64? in row[column] }
    }
}
