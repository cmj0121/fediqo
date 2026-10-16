import FediqoCore
import Foundation
import GRDB

// A timeline read from the file a page at a time (#357), so that nothing reads the whole store
// to draw a part of it.
//
// **SQL narrows, the rules decide.** SQL asks only what it can say exactly of a row's own
// columns (`CompiledTimeline.Prefilter`) — and so never drops a row the timeline would show; every
// row it lets through is judged by `CompiledTimeline.verdict`, the one place a timeline's rules
// are. A rule on words or a field is asked in Swift alone.
//
// **In the order the store holds its items** (`ItemStore.storeOrder`): newest first, then by id,
// then in the order the rows arrived — `posted_at DESC, id ASC, rowid ASC`, which is the order
// of `note_page` read forward, so no page sorts.
//
// **Ids are ordered by their UTF-8 bytes**, as SQLite compares text. Swift's `<`, which
// `storeOrder` uses, compares ids as normalised (NFC), and holds two canonically equivalent
// spellings of one id as equal. The two orders can differ only for an id not in NFC against
// another of the same time — which of two posts of one moment is drawn first, nothing more.

public enum PageAsk: Sendable, Hashable {
    case newest
    /// The rows after the cursor in the store's order: older.
    case before(PageCursor)
    /// The rows before it: newer.
    case after(PageCursor)
    /// The rows after the row under this key, wherever the file has it — a row of the pool, by
    /// its key alone. A key the file does not hold has no place: `StoreFile.NotOnDisk`.
    case beforeRow(NoteKey)
    /// The rows before the row under this key, as `beforeRow`.
    case afterRow(NoteKey)
}

/// What a page is asked for: one timeline as compiled now, and what every timeline is cut by.
public struct PageQuery: Sendable {
    public let timeline: TimelineID
    /// Whose ask this is, handed back on the page so a page that came back for an ask since
    /// replaced can be told apart.
    public let generation: Int
    public let compiled: CompiledTimeline
    /// `LatestDate.end(in:)`: nothing posted at it or after it is shown. Nil for no latest date.
    public let latestEnd: Date?
    /// Nothing posted before it is shown but what is kept: the months a store is kept for.
    public let keepFrom: Date?

    public init(timeline: TimelineID, generation: Int, compiled: CompiledTimeline, latestEnd: Date? = nil, keepFrom: Date? = nil) {
        self.timeline = timeline
        self.generation = generation
        self.compiled = compiled
        self.latestEnd = latestEnd
        self.keepFrom = keepFrom
    }
}

public struct Page: Sendable {
    public let timeline: TimelineID
    public let generation: Int
    /// The rows the timeline shows, in the store's order. **Copies of one post are never split**
    /// between two pages: a page that reaches its limit inside a run of rows with one time and
    /// one id reads the run to its end.
    public let rows: [HeldRow]
    /// What `rows` hold with them and are not themselves shown — the post a reblog reblogs, the
    /// post a quote or an answer names, a forum reply's topic — and what those hold in turn,
    /// where the file has them.
    public let carried: [HeldRow]
    /// The last row looked at, shown or not: where the next page in the same direction starts.
    /// Nil only where nothing was there to look at and nothing was asked after.
    public let next: PageCursor?
    /// The newest and the oldest row looked at, shown or not: a page newer than this one is
    /// asked after `newest`, an older one before `oldest`. Nil where nothing was looked at.
    public let newest: PageCursor?
    public let oldest: PageCursor?
    /// Nothing further on disk in the direction asked. A page that stopped at its budget is not
    /// exhausted, however few rows it has.
    public let exhausted: Bool
}

extension StoreFile {
    /// The indexes the pages and the reads by key go by (#357). **Made with `IF NOT EXISTS`
    /// outside the migrator**: no migration id, so a build before this one still opens the store
    /// — it keeps an index up to date without knowing of it — and `isNewer` is as it was.
    static let pageIndexes = [
        "CREATE INDEX IF NOT EXISTS note_page ON note(posted_at DESC, id ASC)",
        "CREATE INDEX IF NOT EXISTS note_status ON note(host, \(statusIDExpression))",
        "CREATE INDEX IF NOT EXISTS note_owing ON note(host) WHERE refs_due",
    ]

    /// A row's `statusID`, as `note_status` holds it; a read by it must spell it the same way
    /// for the index to be used. Nothing for facts that are not JSON, so neither the index nor a
    /// write of such a row can fail on one.
    static let statusIDExpression = "(CASE WHEN json_valid(facts) THEN json_extract(facts, '$.statusID') END)"

    /// Makes the indexes where the file lacks them, on GRDB's queue and never the caller's: on a
    /// large store it takes seconds the first time (0.3–2.9 s at 270k rows), and nothing after.
    public func makeIndexes() async throws {
        try await db.write { db in
            for sql in Self.pageIndexes { try db.execute(sql: sql) }
        }
    }

    /// One page of `query`'s timeline: at most `limit` rows it shows — more only to finish a run
    /// of one post's copies — the newest, or the next ones past a cursor.
    ///
    /// **At most `scanBudget` rows are looked at**, shown or not, so a timeline that shows little
    /// costs a bounded read and comes back short with a cursor, not exhausted. Rows are looked at
    /// in chunks, each a read of its own, so a save waits for one chunk and not for the page; a
    /// cancelled task stops between them.
    ///
    /// A row that holds no item is passed over, as `load` passed it over; one that will not
    /// decode is passed over and logged, never a reason to set the store aside. A forum reply
    /// with no date of its own (`Note.isPartOfTopic`) is no row of any timeline.
    public func page(_ query: PageQuery, _ ask: PageAsk, limit: Int = 100, scanBudget: Int = 20_000) async throws -> Page {
        let indexed = try await db.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'note_page'") ?? false
        }
        if !indexed { try await makeIndexes() }
        let prefilter = query.compiled.prefilter
        let (hit, hitArguments) = Self.hit(prefilter, keepFrom: query.keepFrom)
        let newer: Bool
        var cursor: PageCursor?
        switch ask {
        case .newest: (newer, cursor) = (false, nil)
        case .before(let from): (newer, cursor) = (false, from)
        case .after(let from): (newer, cursor) = (true, from)
        case .beforeRow(let key): (newer, cursor) = (false, try await place(of: key))
        case .afterRow(let key): (newer, cursor) = (true, try await place(of: key))
        }
        var first: PageCursor?
        let sources = try await db.read(Self.sourcesByHost)
        let index = TextIndex([])
        var shown: [HeldRow] = []
        var looked = 0
        var closing: (String, String)?
        var exhausted = false
        var chunk = 256
        // **Each chunk is a read of its own**, and so is each decode: a save between two may
        // move a row whose time changed past the cursor — read twice, or not this time. Pages
        // land in a pool that holds a row once by its key, and a moved row is read again where
        // it now stands.
        scan: while true {
            try Task.checkCancellation()
            let asked = chunk
            let from = cursor
            let entries = try await db.read { db in
                try Self.entries(db, after: from, newer: newer, latestEnd: query.latestEnd, hit: hit, hitArguments, limit: asked)
            }
            chunk = min(chunk * 2, 4096)
            var at = 0
            while at < entries.count {
                // The rows to decode next: as many hits as could still be shown, and a few
                // where only a run is being finished.
                let need = closing == nil ? max(limit - shown.count, 1) : 4
                var end = at
                var hits: [Int64] = []
                while end < entries.count, hits.count < need {
                    if entries[end].hit { hits.append(entries[end].rowid) }
                    end += 1
                }
                let asking = hits
                let judged = asking.isEmpty ? [:] : try await db.read { db in
                    try Self.judged(db, asking, query.compiled, prefilter, index, sources)
                }
                for entry in entries[at..<end] {
                    if let closing, closing != (entry.postedAt, entry.id) { break scan }
                    looked += 1
                    cursor = PageCursor(postedAt: entry.postedAt, id: entry.id, rowid: entry.rowid)
                    if first == nil { first = cursor }
                    if let row = judged[entry.rowid] { shown.append(row) }
                    if closing == nil, shown.count >= limit || looked >= scanBudget {
                        closing = (entry.postedAt, entry.id)
                    }
                }
                at = end
            }
            if entries.count < asked {
                exhausted = true
                break
            }
        }
        if newer { shown.reverse() }
        let rows = shown
        let carried = try await db.read { db in try Self.carried(db, of: rows, sources) }
        return Page(
            timeline: query.timeline, generation: query.generation, rows: rows, carried: carried,
            next: cursor, newest: newer ? (first == nil ? nil : cursor) : first,
            oldest: newer ? first : (first == nil ? nil : cursor), exhausted: exhausted
        )
    }

    /// No row under the key a page was asked before or after.
    public struct NotOnDisk: Error {}

    /// Where the row under `key` stands in the file's order.
    private func place(of key: NoteKey) async throws -> PageCursor {
        let found = try await db.read { db in
            try Row.fetchOne(
                db, sql: "SELECT posted_at, rowid FROM note WHERE host = ? AND id = ? AND typeof(posted_at) = 'text'",
                arguments: [key.host, key.id]
            ).map { PageCursor(postedAt: $0["posted_at"], id: key.id, rowid: $0["rowid"]) }
        }
        guard let found else { throw NotOnDisk() }
        return found
    }

    /// One row of the index as a page looks at it: its place, and whether SQL let it through.
    private struct Entry {
        let rowid: Int64
        let postedAt: String
        let id: String
        let hit: Bool
    }

    /// The next `limit` rows of the index past `cursor` — older, or `newer` — below `latestEnd`.
    /// **By `note_page`, named**: left to choose, SQLite takes the primary key's prefix on host
    /// for a timeline of one source and sorts the whole of it (96 ms against 8 ms, measured).
    private static func entries(
        _ db: Database, after cursor: PageCursor?, newer: Bool, latestEnd: Date?,
        hit: String, _ hitArguments: StatementArguments, limit: Int
    ) throws -> [Entry] {
        // A time the file holds as anything but text is none GRDB wrote, and no row of a page:
        // SQLite orders it apart from every text, where no cursor of text could step past it.
        var bounds = ["typeof(posted_at) = 'text'"]
        var arguments = hitArguments
        if let latestEnd {
            bounds.append("posted_at < ?")
            arguments += [latestEnd]
        }
        if let cursor {
            // Past the cursor in the order read: older, or ahead of it among rows of its time.
            bounds.append(newer
                ? "posted_at >= ? AND NOT (posted_at = ? AND (id > ? OR (id = ? AND rowid >= ?)))"
                : "posted_at <= ? AND NOT (posted_at = ? AND (id < ? OR (id = ? AND rowid <= ?)))")
            arguments += [cursor.postedAt, cursor.postedAt, cursor.id, cursor.id, cursor.rowid]
        }
        arguments += [limit]
        let order = newer ? "posted_at ASC, id DESC, rowid DESC" : "posted_at DESC, id ASC, rowid ASC"
        let sql = """
            SELECT rowid, posted_at, id, (\(hit)) AS hit FROM note INDEXED BY note_page
            WHERE \(bounds.joined(separator: " AND "))
            ORDER BY \(order) LIMIT ?
            """
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            Entry(rowid: row["rowid"], postedAt: row["posted_at"], id: row["id"], hit: row["hit"])
        }
    }

    /// The rows of `rowids` the timeline shows, by rowid: decoded, and asked of `verdict` — a
    /// reblog with the post it reblogs, read by its key, where a rule asks of that post.
    private static func judged(
        _ db: Database, _ rowids: [Int64], _ compiled: CompiledTimeline, _ prefilter: CompiledTimeline.Prefilter,
        _ index: TextIndex, _ sources: [String: Source]
    ) throws -> [Int64: HeldRow] {
        let marks = Array(repeating: "?", count: rowids.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db, sql: "SELECT rowid AS rowid, * FROM note WHERE rowid IN (\(marks))", arguments: StatementArguments(rowids)
        ).compactMap { row in decoded(row, sources) }
        var shown: [Int64: HeldRow] = [:]
        for row in rows where !row.note.isPartOfTopic {
            let reblogged = prefilter.readsWhatIsSaid ? try row.note.reblogKey.flatMap { try held(db, $0, sources) }?.note : nil
            if compiled.verdict(row.note, index, reblogged: reblogged) == .shown { shown[row.arrival] = row }
        }
        return shown
    }

    /// What `rows` hold with them (`Note.heldWith`, `Note.topicKey`), and what that holds in
    /// turn, that the file has and `rows` are not.
    private static func carried(_ db: Database, of rows: [HeldRow], _ sources: [String: Source]) throws -> [HeldRow] {
        var seen = Set(rows.map(\.note.key))
        var wanted = rows.map(\.note)
        var carried: [HeldRow] = []
        while let note = wanted.popLast() {
            for key in note.heldWith + [note.topicKey].compactMap({ $0 }) where seen.insert(key).inserted {
                guard let row = try held(db, key, sources) else { continue }
                carried.append(row)
                wanted.append(row.note)
            }
        }
        return carried
    }

    /// The row under `key`, where the file has one that holds an item.
    private static func held(_ db: Database, _ key: NoteKey, _ sources: [String: Source]) throws -> HeldRow? {
        let statement = try db.cachedStatement(sql: "SELECT rowid AS rowid, * FROM note WHERE host = ? AND id = ?")
        return try Row.fetchOne(statement, arguments: [key.host, key.id]).flatMap { decoded($0, sources) }
    }

    private static func decoded(_ row: Row, _ sources: [String: Source]) -> HeldRow? {
        do {
            return try heldRow(row, sources: sources)
        } catch {
            NetLog.index.error("A row that will not decode was passed over: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// `prefilter` as an SQL expression over a row of `note`, and its arguments: true for every
    /// row the timeline may show. **A cell that is not JSON is let through**, for the decode to
    /// judge, and never hidden by a rule that cannot be asked of it.
    static func hit(_ prefilter: CompiledTimeline.Prefilter, keepFrom: Date?) -> (String, StatementArguments) {
        var terms: [String] = []
        var arguments = StatementArguments()
        func member(_ member: CompiledTimeline.Prefilter.Member, certain: Bool) -> String {
            let (host, own, values): (String?, String?, [any DatabaseValueConvertible]) = switch member {
            case .host(let host): (host, nil, [])
            case .category(let category, let host): (host, Self.category(category, certain: certain), {
                let row = CategoryRow(category)
                return [row.kind] + (row.id.map { [$0] } ?? [])
            }())
            case .handle(let handle, let host): (host, Self.handle(certain: certain), [handle])
            }
            arguments += StatementArguments((host.map { [$0] } ?? []) + values)
            return "(" + ([host.map { _ in "host = ?" }, own].compactMap { $0 }.joined(separator: " AND ")) + ")"
        }
        if !prefilter.excludes.isEmpty {
            terms.append("NOT (" + prefilter.excludes.map { member($0, certain: true) }.joined(separator: " OR ") + ")")
        }
        for group in prefilter.groups {
            terms.append("(" + group.map { member($0, certain: false) }.joined(separator: " OR ") + ")")
        }
        if let keepFrom {
            terms.append("(kept OR posted_at >= ?)")
            arguments += [keepFrom]
        }
        // Whatever SQL could not answer of a row is let through.
        return (terms.isEmpty ? "1" : "COALESCE(" + terms.joined(separator: " AND ") + ", 1)", arguments)
    }

    /// Whether a row arrived through a category: one argument, its kind, or two with its id. A
    /// cell that is not JSON is `certain`ly not of it, and of it where it only may be.
    private static func category(_ category: FediqoCore.Category, certain: Bool) -> String {
        let kind = "(CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.kind') END) = ?"
        let id = " AND (CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.id') END) = ?"
        return """
            (CASE WHEN json_valid(categories) \
            THEN EXISTS (SELECT 1 FROM json_each(categories) j WHERE \(kind)\(CategoryRow(category).id == nil ? "" : id)) \
            ELSE \(certain ? 0 : 1) END)
            """
    }

    /// Whether a row was made by a handle, one argument: folded as a rule folds it. `Fold.handle`
    /// of a handle all of printable ASCII is its lower case less one leading `@`, which SQL can
    /// say; any other handle is `certain`ly not the one, and may be it otherwise.
    private static func handle(certain: Bool) -> String {
        let raw = "json_extract(facts, '$.handle')"
        let text = "json_valid(facts) AND json_type(facts, '$.handle') = 'text'"
        let ascii = "\(raw) NOT GLOB '*[^ -~]*'"
        let folded = "(CASE WHEN substr(\(raw), 1, 1) = '@' THEN lower(substr(\(raw), 2)) ELSE lower(\(raw)) END) = ?"
        return certain
            ? "(CASE WHEN \(text) THEN \(ascii) AND \(folded) ELSE 0 END)"
            : "(CASE WHEN \(text) THEN NOT (\(ascii)) OR \(folded) ELSE 1 END)"
    }
}
