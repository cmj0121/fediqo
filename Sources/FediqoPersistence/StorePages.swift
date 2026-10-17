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

extension StoreFile {
    /// The indexes the pages and the reads by key go by (#357). **Made with `IF NOT EXISTS`
    /// outside the migrator**: no migration id, so a build before this one still opens the store
    /// — it keeps an index up to date without knowing of it — and `isNewer` is as it was.
    static let pageIndexes = [
        "CREATE INDEX IF NOT EXISTS note_page ON note(posted_at DESC, id ASC)",
        "CREATE INDEX IF NOT EXISTS note_status ON note(host, \(statusIDExpression))",
        "CREATE INDEX IF NOT EXISTS note_owing ON note(host) WHERE refs_due",
        "CREATE INDEX IF NOT EXISTS note_kept ON note(kept) WHERE kept",
        "CREATE INDEX IF NOT EXISTS note_gone ON note(gone_at) WHERE gone_at IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS note_cites ON note(host, \(firstCited)) WHERE instr(refs, '\"id\"') > 0",
        "CREATE INDEX IF NOT EXISTS note_cites_many ON note(host) WHERE instr(refs, '\"id\"') > 0 AND \(citesMany)",
        // `note_cites` and `note_cites_many` answer what `note_refers` did (#360).
        "DROP INDEX IF EXISTS note_refers",
        "CREATE INDEX IF NOT EXISTS note_marked ON note(host) WHERE \(readerSaidOrOwing)",
    ]

    /// The id a row's first reference names, as `note_cites` holds it (#360): a row with one
    /// reference — nearly every row that has any — is found by what it names, not by reading
    /// the references of every row of its host. Nothing for references that are not JSON.
    static let firstCited = "(CASE WHEN json_valid(refs) THEN json_extract(refs, '$[0].id') END)"

    /// A row whose references are more than one, or not a list: read whole by `referring`, as
    /// its first reference is not all it names (`note_cites_many`).
    static let citesMany = "(CASE WHEN json_valid(refs) THEN json_type(refs) <> 'array' OR json_array_length(refs) > 1 ELSE 0 END)"

    /// A row's `statusID`, as `note_status` holds it; a read by it must spell it the same way
    /// for the index to be used. Nothing for facts that are not JSON, so neither the index nor a
    /// write of such a row can fail on one.
    static let statusIDExpression = "(CASE WHEN json_valid(facts) THEN json_extract(facts, '$.statusID') END)"

    /// Makes the indexes where the file lacks them, on GRDB's queue and never the caller's: on a
    /// large store it takes seconds the first time (0.3–2.9 s at 270k rows), and nothing after.
    /// **Each a write of its own, the pages' first**: a page asked meanwhile waits for the one
    /// being made, not for all of them.
    public func makeIndexes() async throws {
        for sql in Self.pageIndexes {
            try await db.write { db in try db.execute(sql: sql) }
        }
    }

    /// The pages' own index alone, where the file lacks it: what a launch's first page waits for
    /// on a store an older build left (#357). The rest are made once the timeline shows
    /// (`makeIndexes`): until then a read by key or a letting go reads without them, slower.
    ///
    /// **Its cost is one read of every row** — the table, its words with it — so it is what the
    /// disk gives: 0.7 s with the file in memory, 3–6 s where it is not, at 270k rows.
    ///
    /// **Read beside while it is made** (#357, C15): the reads by key a pool makes go to a
    /// connection of their own for as long as it takes (`beside`), and so does a provisional
    /// page, so that nothing waits on it but a page that needs it. Its pages are held in memory
    /// until it commits (`cache_spill` off), so the file is not locked against them before then.
    ///
    /// **Made once, whoever asks** — the launch and a first page alike wait for the one making,
    /// with the one connection beside it — and that connection is let go, never closed under a
    /// read that still holds it.
    public func makePageIndex() async throws {
        let file = self
        let build = pageIndexBuild {
            Task {
                defer { file.pageIndexEnded() }
                try await file.buildPageIndex()
            }
        }
        try await build.value
    }

    private func buildPageIndex() async throws {
        guard try await !db.read(Self.hasPageIndex) else { return }
        beside = try? readingConnection()
        defer { beside = nil }
        try await db.writeWithoutTransaction { db in
            guard try !Self.hasPageIndex(db) else { return }
            try db.execute(sql: "PRAGMA cache_spill = OFF")
            defer { try? db.execute(sql: "PRAGMA cache_spill = ON") }
            try db.inTransaction {
                try db.execute(sql: Self.pageIndexes[0])
                return .commit
            }
        }
    }

    /// The newest rows **by the order they arrived in** that `query`'s timeline shows (#357,
    /// C15) — what can be drawn at once on a file whose pages' index is still being made, and
    /// nothing where it is made: then the page itself is as quick. Read on a connection of its
    /// own, beside the index being made, by the primary key alone, a chunk at a time, through
    /// the same prefilter and the same rules a page has.
    ///
    /// **Provisional, and said to be**: nearly the newest by time, never surely so — a post that
    /// arrived late with an older time is not among them, and a row that arrived early with a
    /// newer one may be missed. So it carries no place to read on from (`next` and its ends are
    /// nothing): a timeline drawn from it waits for its first true page before it reads further.
    public func provisionalPage(_ query: PageQuery, limit: Int = 100, scanBudget: Int = 20_000) async throws -> Page? {
        let side = try readingConnection()
        defer { try? side.close() }
        guard try await !side.read(Self.hasPageIndex) else { return nil }
        let prefilter = query.compiled.prefilter
        // Row by row, never by the index's answer: a file still making its pages' index is one
        // whose words are not built either.
        let words = try await side.read { db in try Self.wordsAsk(db, prefilter, most: 0) }
        let (hit, hitArguments) = Self.hit(prefilter, keepFrom: query.keepFrom, words: words)
        let sources = try await side.read(Self.sourcesByHost)
        let index = TextIndex([])
        var shown: [HeldRow] = []
        var below: Int64?
        var looked = 0
        var chunk = 256
        while shown.count < limit, looked < scanBudget {
            try Task.checkCancellation()
            var bounds = ["typeof(posted_at) = 'text'"]
            var arguments = hitArguments
            if let latestEnd = query.latestEnd {
                bounds.append("posted_at < ?")
                arguments += [latestEnd]
            }
            if let below {
                bounds.append("rowid < ?")
                arguments += [below]
            }
            arguments += [chunk]
            let sql = """
                SELECT rowid, (\(hit)) AS hit FROM note WHERE \(bounds.joined(separator: " AND "))
                ORDER BY rowid DESC LIMIT ?
                """
            let asked = arguments
            let entries = try await side.read { db in
                try Row.fetchAll(db, sql: sql, arguments: asked).map { (rowid: $0["rowid"] as Int64, hit: $0["hit"] as Bool) }
            }
            let hits = entries.filter(\.hit).map(\.rowid)
            if !hits.isEmpty {
                let judged = try await side.read { db in try Self.judged(db, hits, query.compiled, prefilter, index, sources) }
                shown += hits.compactMap { judged[$0] }
            }
            looked += entries.count
            guard entries.count == chunk, let last = entries.last else { break }
            below = last.rowid
            chunk = min(chunk * 2, Self.largestChunk)
        }
        let rows = Array(shown.prefix(limit))
        let carried = try await side.read { db in try Self.carried(db, of: rows, sources) }
        return Page(
            timeline: query.timeline, generation: query.generation, rows: rows, carried: carried,
            next: nil, newest: nil, oldest: nil, exhausted: false
        )
    }

    /// The most rows of the index one read of a page looks at.
    static let largestChunk = 4096

    /// The rows of the index one read looks at where a keyword is asked of the words index row
    /// by row: some 20 ms holding the queue at 270,000 rows.
    static let wordsChunkRead = 8192

    static func hasPageIndex(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'note_page'") ?? false
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
    ///
    /// **A timeline with keywords is read by the words index** (#360, K-4): where the index is
    /// whole and its keywords find few rows (`wordsCandidatesMost`), only those rows — with the
    /// reblogs of them, and the rows due — are read, in the same order and by the same cursor;
    /// otherwise each row is asked of the index as it is read, a row not built yet or due let
    /// through. The rules judge every row either way.
    public func page(_ query: PageQuery, _ ask: PageAsk, limit: Int = 100, scanBudget: Int = 20_000) async throws -> Page {
        try await page(query, ask, limit: limit, scanBudget: scanBudget, candidatesMost: Self.wordsCandidatesMost)
    }

    /// How a page reads the file: its keywords' plan (`wordsAsk`), the prefilter as SQL, the
    /// rows it reads only, where it reads only some — and where the file stood when it was made
    /// (`Stamp`). **Made again for the next chunk once that moves**: a save, a build's step, the
    /// rowid guard after a `VACUUM` that renumbered, another copy of the app saving into the
    /// same file, the connection made again — any may have made a row hold a keyword, or a
    /// rowid name another row, so rows read by an older plan could be missed for good.
    private struct PagePlan: Sendable {
        /// Where the file stood: which connection read it, that connection's own count of
        /// changes, and the file's count of changes made through any other (`data_version`).
        struct Stamp: Equatable, Sendable {
            let connection: Int
            let changes: Int
            let others: Int

            init(_ db: Database) throws {
                connection = db.sqliteConnection.map { Int(bitPattern: $0) } ?? 0
                changes = db.totalChangesCount
                others = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
            }
        }

        let words: WordsAsk
        let hit: String
        let hitArguments: StatementArguments
        let within: String?
        let stamp: Stamp
        /// Whether rows the index has not reached yet are asked of their bodies here: only while
        /// it is being built, since a due row is one of few.
        let unbuilt: Bool

        init(_ db: Database, _ prefilter: CompiledTimeline.Prefilter, keepFrom: Date?, most: Int, at stamp: Stamp) throws {
            self.stamp = stamp
            words = try StoreFile.wordsAsk(db, prefilter, most: most)
            unbuilt = try words == .index && !StoreFile.keywords(prefilter).isEmpty
                && (Int64.fetchOne(db, sql: "SELECT v FROM note_words_state WHERE k = 'floor'") ?? 0) > 0
            (hit, hitArguments) = StoreFile.hit(prefilter, keepFrom: keepFrom, words: words)
            within = if case .candidates(let rowids) = words {
                String(decoding: try JSONEncoder().encode(rowids), as: UTF8.self)
            } else {
                nil
            }
        }
    }

    /// `page`, with the most rows a timeline's keywords may find for it to read only those, and
    /// `betweenChunks` run after each chunk is read, given its number: for a test, the writes
    /// another may make meanwhile.
    func page(
        _ query: PageQuery, _ ask: PageAsk, limit: Int, scanBudget: Int, candidatesMost: Int,
        betweenChunks: (@Sendable (Int) async throws -> Void)? = nil
    ) async throws -> Page {
        if try await !db.read(Self.hasPageIndex) { try await makePageIndex() }
        let prefilter = query.compiled.prefilter
        var plan = try await db.read { db in
            try PagePlan(db, prefilter, keepFrom: query.keepFrom, most: candidatesMost, at: PagePlan.Stamp(db))
        }
        // A row not built yet passes the index, and is then asked of its body here before it is
        // decoded: a keyword timeline read while the index is built decodes what may be shown.
        let keywords = Self.keywords(prefilter)
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
        var held: Set<NoteKey> = []
        var looked = 0
        var closing: (String, String)?
        var exhausted = false
        // **Asked of the index row by row, in large chunks from the first**: each read asks the
        // index for the keyword's rows once, some milliseconds for a keyword found in tens of
        // thousands, so fewer reads are what make the page quick (70 ms against 45, measured).
        var chunk = plan.words == .index ? Self.wordsChunkRead : 256
        var chunks = 0
        // **Each chunk is a read of its own**, and so is each decode: a save between two may
        // move a row whose time changed past the cursor — read twice, or not this time. Pages
        // land in a pool that holds a row once by its key, and a moved row is read again where
        // it now stands.
        scan: while true {
            try Task.checkCancellation()
            let asked = chunk
            let from = cursor
            let planned = plan
            let (read, replanned) = try await db.read { db -> ([Entry], PagePlan?) in
                let stamp = try PagePlan.Stamp(db)
                let moved = stamp != planned.stamp
                let now = moved ? try PagePlan(db, prefilter, keepFrom: query.keepFrom, most: candidatesMost, at: stamp) : planned
                let entries = try Self.entries(
                    db, after: from, newer: newer, latestEnd: query.latestEnd, within: now.within,
                    unbuilt: now.unbuilt, hit: now.hit, now.hitArguments, limit: asked
                )
                return (entries, moved ? now : nil)
            }
            if let replanned { plan = replanned }
            let entries = read.map { entry in
                entry.hit && !Self.mayHold(entry, keywords) ? entry.missed : entry
            }
            chunk = min(chunk * 2, plan.words == .index ? Self.wordsChunkRead : Self.largestChunk)
            chunks += 1
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
                    // Once by its key: a row renumbered under the cursor (`PagePlan`) is met again.
                    if let row = judged[entry.rowid], held.insert(row.note.key).inserted { shown.append(row) }
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
            try await betweenChunks?(chunks)
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

    /// One row of the index as a page looks at it: its place, and whether SQL let it through —
    /// and, where it is not in the words index yet and no reblog, its host and body.
    private struct Entry {
        let rowid: Int64
        let postedAt: String
        let id: String
        let hit: Bool
        var host: String? = nil
        var body: String? = nil

        var missed: Entry { Entry(rowid: rowid, postedAt: postedAt, id: id, hit: false) }
    }

    /// Whether a row SQL let through may hold one of `keywords`: always, unless it is one the
    /// index has no words of yet (it carries its body then), which is asked here as `verdict`
    /// asks a post — the body folded, a keyword within it, of the keyword's own source.
    private static func mayHold(_ entry: Entry, _ keywords: [(folded: String, host: String?)]) -> Bool {
        guard let body = entry.body else { return true }
        let text = Fold.key(body)
        return keywords.contains { keyword in
            (keyword.host == nil || keyword.host == entry.host) && (keyword.folded.isEmpty || Fold.contains(text, keyword.folded))
        }
    }

    /// The next `limit` rows of the index past `cursor` — older, or `newer` — below `latestEnd`,
    /// and only those of `within` (a JSON array of rowids) where it is given.
    /// **By `note_page`, named**: left to choose, SQLite takes the primary key's prefix on host
    /// for a timeline of one source and sorts the whole of it (96 ms against 8 ms, measured).
    /// **By rowid among `within`**, which is few, sorted here: never a walk of `note_page`.
    private static func entries(
        _ db: Database, after cursor: PageCursor?, newer: Bool, latestEnd: Date?, within: String?, unbuilt: Bool,
        hit: String, _ hitArguments: StatementArguments, limit: Int
    ) throws -> [Entry] {
        // A time the file holds as anything but text is none GRDB wrote, and no row of a page:
        // SQLite orders it apart from every text, where no cursor of text could step past it.
        var bounds = ["typeof(posted_at) = 'text'"]
        var arguments = hitArguments
        if let within {
            bounds.append("rowid IN (SELECT value FROM json_each(?))")
            arguments += [within]
        }
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
        var sql = """
            SELECT rowid, posted_at, id, (\(hit)) AS hit\(unbuilt ? ", host, \(Self.unbuilt) AS unbuilt" : "")
            FROM note \(within == nil ? "INDEXED BY note_page" : "NOT INDEXED")
            WHERE \(bounds.joined(separator: " AND "))
            ORDER BY \(order) LIMIT ?
            """
        if unbuilt {
            // The body of a row let through with no words in the index yet, and no reblog: read
            // only for those.
            sql = """
                SELECT s.*, CASE WHEN s.hit AND s.unbuilt THEN (SELECT CASE WHEN instr(n.refs, '"reblogs"') = 0 \
                AND json_valid(n.facts) AND json_type(n.facts, '$.body') = 'text' THEN json_extract(n.facts, '$.body') END \
                FROM note n WHERE n.rowid = s.rowid) END AS body
                FROM (\(sql)) s ORDER BY \(order.split(separator: ",").map { "s." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
                """
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            Entry(
                rowid: row["rowid"], postedAt: row["posted_at"], id: row["id"], hit: row["hit"],
                host: unbuilt ? row["host"] : nil, body: unbuilt ? row["body"] : nil
            )
        }
    }

    /// Whether a row has no words in the index to go by: below `floor`, or due.
    private static let unbuilt = """
        COALESCE(rowid < (SELECT v FROM note_words_state WHERE k = 'floor') OR rowid IN (SELECT rowid FROM note_words_due), 1)
        """

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

    /// How many names one statement asks for, well under SQLite's limit on arguments.
    private static let asked = 500

    /// `rows` asked `asked` names at a time, of one host.
    private static func held(
        _ db: Database, host: String, _ names: [String], by column: String, _ sources: [String: Source]
    ) throws -> [HeldRow] {
        var found: [Row] = []
        for start in stride(from: 0, to: names.count, by: asked) {
            let some = Array(names[start..<min(start + asked, names.count)])
            let marks = Array(repeating: "?", count: some.count).joined(separator: ",")
            found += try Row.fetchAll(
                db, sql: "SELECT rowid AS rowid, * FROM note WHERE host = ? AND \(column) IN (\(marks))",
                arguments: StatementArguments([host] + some)
            )
        }
        return try read(found, sources)
    }

    /// `rows` as the pool takes them: a row that holds no item is no row; **one that will not
    /// decode is no answer** — `RowsUnread` names it, with every row that did decode — never a
    /// row that is not there, which a copy landing would then be written over.
    private static func read(_ rows: [Row], _ sources: [String: Source]) throws -> [HeldRow] {
        var read: [HeldRow] = []
        var unread: [NoteKey] = []
        for row in rows {
            do {
                if let held = try heldRow(row, sources: sources) { read.append(held) }
            } catch {
                unread.append(NoteKey(host: row["host"], id: row["id"]))
            }
        }
        guard unread.isEmpty else { throw RowsUnread(keys: unread, rows: read) }
        return read
    }

    /// `prefilter` as an SQL expression over a row of `note`, and its arguments: true for every
    /// row the timeline may show. **A cell that is not JSON is let through**, for the decode to
    /// judge, and never hidden by a rule that cannot be asked of it.
    ///
    /// A keyword is asked as `words` says (`wordsAsk`): of the words index row by row, or of
    /// nothing — where there is no index, or the page reads only the rows the index gave.
    static func hit(_ prefilter: CompiledTimeline.Prefilter, keepFrom: Date?, words: WordsAsk = .open) -> (String, StatementArguments) {
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
            // **Never certain**, so never a hide (a prefilter holds none): as one, it hides nothing.
            case .words(let folded, let host):
                if certain {
                    (host, "0", [])
                } else if words == .index, let tokens = WordGrams.asked(folded) {
                    (host, Self.mayHold, [WordGrams.match(tokens), WordGrams.match(tokens)])
                } else {
                    (host, nil, [])
                }
            }
            arguments += StatementArguments((host.map { [$0] } ?? []) + values)
            let said = [host.map { _ in "host = ?" }, own].compactMap { $0 }
            return said.isEmpty ? "1" : "(" + said.joined(separator: " AND ") + ")"
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

/// The file read by key for `ItemStore`'s pool (#357): by the primary key, a forum topic's
/// replies by the key's prefix, and a source's own id by `note_status`, once a page has made it.
extension StoreFile: HeldRows {
    /// A read for the pool, on the connection beside a long write while there is one
    /// (`makePageIndex`), and on this store's own otherwise. `beside` says which.
    ///
    /// **A read the connection beside could not make is made on this store's own**: SQLite's
    /// own failure there — busy past its wait, a connection gone — is no answer about the rows,
    /// and answering none for it would turn an arrival away for the run.
    private func poolRead<T>(_ body: (Database, Bool) throws -> T) throws -> T {
        if let side = beside {
            do {
                return try side.read { db in try body(db, true) }
            } catch is DatabaseError {
                return try db.read { db in try body(db, false) }
            }
        }
        return try db.read { db in try body(db, false) }
    }

    /// The sources a pool read stamps its rows with: kept between reads of this store's own
    /// connection (`sourcesByHost(cached:)`), whose `data_version` that keeps count by; read
    /// afresh beside it.
    private func poolSources(_ db: Database, _ beside: Bool) throws -> [String: Source] {
        beside ? try Self.sourcesByHost(db) : try sourcesByHost(cached: db)
    }

    public func rows(_ keys: [NoteKey]) throws -> [HeldRow] {
        try poolRead { db, beside in
            let sources = try poolSources(db, beside)
            var found: [HeldRow] = []
            var unread: [NoteKey] = []
            for (host, keys) in Dictionary(grouping: keys, by: \.host).sorted(by: { $0.key < $1.key }) {
                do {
                    found += try Self.held(db, host: host, keys.map(\.id), by: "id", sources)
                } catch let partly as RowsUnread {
                    found += partly.rows
                    unread += partly.keys
                }
            }
            guard unread.isEmpty else { throw RowsUnread(keys: unread, rows: found) }
            return found
        }
    }

    public func rows(host: String, idPrefix: String) throws -> [HeldRow] {
        try poolRead { db, beside in
            try Self.read(
                Row.fetchAll(
                    db, sql: "SELECT rowid AS rowid, * FROM note WHERE host = ? AND substr(id, 1, length(?)) = ?",
                    arguments: [host, idPrefix, idPrefix]
                ),
                poolSources(db, beside)
            )
        }
    }

    public func rows(host: String, statusIDs: [String]) throws -> [HeldRow] {
        try poolRead { db, beside in
            try Self.held(db, host: host, statusIDs, by: Self.statusIDExpression, poolSources(db, beside))
        }
    }

    /// By `note_kept`, where a page has made it: asked once a run, by the first letting go that
    /// must know what a kept post holds.
    public func keptRows() throws -> [HeldRow] {
        try poolRead { db, beside in
            try Self.read(Row.fetchAll(db, sql: "SELECT rowid AS rowid, * FROM note WHERE kept"), poolSources(db, beside))
        }
    }

    /// Off `refs` alone, as `ReferenceRow` writes it, of the row's own host: nothing of a row
    /// whose references are not JSON.
    public func reblogged(by keys: [NoteKey]) throws -> [NoteKey] {
        try poolRead { db, beside in
            var reblogged: [NoteKey] = []
            for (host, keys) in Dictionary(grouping: keys, by: \.host).sorted(by: { $0.key < $1.key }) {
                let ids = keys.map(\.id)
                for start in stride(from: 0, to: ids.count, by: Self.asked) {
                    let some = Array(ids[start..<min(start + Self.asked, ids.count)])
                    let marks = Array(repeating: "?", count: some.count).joined(separator: ",")
                    reblogged += try String.fetchAll(db, sql: """
                        SELECT json_extract(r.value, '$.id') FROM note n, json_each(CASE WHEN json_valid(n.refs) THEN n.refs ELSE '[]' END) r
                        WHERE n.host = ? AND n.id IN (\(marks)) AND r.type = 'object'
                        AND json_extract(r.value, '$.kind') = 'reblogs' AND json_type(r.value, '$.id') = 'text'
                        """, arguments: StatementArguments([host] + some)).map { NoteKey(host: host, id: $0) }
                }
            }
            return reblogged
        }
    }
}

/// What the file lets go of and changes itself (#357): the rows a letting go names, the oldest
/// the room limit lets go, what refers to them, and a reader's marks taken back — **asked of
/// every row of the file**, so a store that holds only some of them lets go of what the whole
/// store would.
extension StoreFile {
    public func keys(_ selection: RowSelection) throws -> [NoteKey] {
        var sql = "SELECT host, id FROM note WHERE NOT kept"
        var arguments: [any DatabaseValueConvertible] = []
        switch selection {
        case .host(let host):
            sql += " AND host = ?"
            arguments = [host]
        case .span(let span, let host):
            sql += " AND posted_at >= ? AND posted_at < ?"
            arguments = [span.lowerBound, span.upperBound]
            if let host {
                sql += " AND host = ?"
                arguments.append(host)
            }
        case .gone(let cutoff):
            sql += " AND gone_at IS NOT NULL"
            if let cutoff {
                sql += " AND gone_at <= ?"
                arguments = [cutoff]
            }
        }
        return try poolRead { db, beside in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { NoteKey(host: $0["host"], id: $0["id"]) }
        }
    }

    /// By `note_page`, sorting only the rows of one moment by when they arrived.
    public func oldest(_ limit: Int, after: PageCursor?) throws -> (rows: [HeldRow], next: PageCursor?) {
        try poolRead { db, beside in
            // A range on `posted_at` alone, so `note_page` answers it; the moment it starts at is cut by rowid.
            let past = after == nil ? "" : " AND posted_at >= ? AND NOT (posted_at = ? AND rowid <= ?)"
            let arguments: StatementArguments = after.map { [$0.postedAt, $0.postedAt, $0.rowid, limit] } ?? [limit]
            let found = try Row.fetchAll(
                db, sql: "SELECT rowid AS rowid, * FROM note WHERE NOT kept\(past) ORDER BY posted_at ASC, rowid ASC LIMIT ?",
                arguments: arguments
            )
            let sources = try poolSources(db, beside)
            let next = found.count < limit ? nil : found.last.flatMap { row in
                String.fromDatabaseValue(row["posted_at"] as DatabaseValue)
                    .map { PageCursor(postedAt: $0, id: row["id"], rowid: row["rowid"]) }
            }
            return (found.compactMap { Self.decoded($0, sources) }, next)
        }
    }

    /// By `note_page` read from its oldest end, as `oldest` reads it, and the rows' cells left
    /// whole: a key and a reblog's one reference are all a step of the months limit asks (#360).
    public func beyond(_ cutoff: Date, limit: Int, after: PageCursor?) throws -> (rows: [PastLimit], next: PageCursor?) {
        try poolRead { db, _ in
            let past = after == nil ? "" : " AND posted_at >= ? AND NOT (posted_at = ? AND rowid <= ?)"
            var arguments: [any DatabaseValueConvertible] = [cutoff]
            if let after { arguments += [after.postedAt, after.postedAt, after.rowid] }
            arguments.append(limit)
            let found = try Row.fetchAll(db, sql: """
                SELECT rowid AS rowid, host, id, posted_at,
                (instr(refs, 'reblogs') > 0 AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(refs) THEN refs ELSE '[]' END) r
                 WHERE r.type = 'object' AND json_extract(r.value, '$.kind') = 'reblogs')) AS reblogs
                FROM note WHERE NOT kept AND posted_at < ?\(past) ORDER BY posted_at ASC, rowid ASC LIMIT ?
                """, arguments: StatementArguments(arguments))
            let next = found.count < limit ? nil : found.last.flatMap { row in
                String.fromDatabaseValue(row["posted_at"] as DatabaseValue)
                    .map { PageCursor(postedAt: $0, id: row["id"], rowid: row["rowid"]) }
            }
            return (found.map { PastLimit(key: NoteKey(host: $0["host"], id: $0["id"]), reblogs: $0["reblogs"]) }, next)
        }
    }

    /// Off `refs` alone, as `ReferenceRow` writes it: a reference names a row of its own host.
    /// Only a cell that names an id is taken apart — a row of one reference found by the id it
    /// names (`note_cites`), and only a row of several read whole (`note_cites_many`).
    public func referring(to keys: [NoteKey]) throws -> [Referrer] {
        try referring(to: keys, staying: nil)
    }

    /// Only a row that stays is taken apart: a kept one, or one inside the limit, its cut asked
    /// before its references are read.
    public func referring(to keys: [NoteKey], stayingFrom cutoff: Date) throws -> [Referrer] {
        try referring(to: keys, staying: cutoff)
    }

    private func referring(to keys: [NoteKey], staying cutoff: Date?) throws -> [Referrer] {
        guard !keys.isEmpty else { return [] }
        let staying = cutoff == nil ? "" : " AND (kept OR posted_at >= ?)"
        return try poolRead { db, beside in
            var found: [Referrer] = []
            for (host, keys) in Dictionary(grouping: keys, by: \.host).sorted(by: { $0.key < $1.key }) {
                let ids = try Self.json(keys.map(\.id))
                var arguments: [any DatabaseValueConvertible] = [host, ids]
                if let cutoff { arguments.append(cutoff) }
                arguments.append(host)
                if let cutoff { arguments.append(cutoff) }
                arguments.append(ids)
                // A row is in one half or the other, never both.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT n.arrival AS rowid, n.id AS id, n.posted_at AS posted_at, n.kept AS kept,
                    json_extract(r.value, '$.id') AS target
                    FROM (SELECT rowid AS arrival, id, posted_at, kept, refs FROM note
                          WHERE host = ? AND instr(refs, '"id"') > 0 AND \(Self.firstCited) IN (SELECT value FROM json_each(?))
                          AND NOT \(Self.citesMany)\(staying)
                          UNION ALL
                          SELECT rowid AS arrival, id, posted_at, kept, refs FROM note
                          WHERE host = ? AND instr(refs, '"id"') > 0 AND \(Self.citesMany)\(staying)) n,
                    json_each(CASE WHEN json_valid(n.refs) THEN n.refs ELSE '[]' END) r
                    WHERE r.type = 'object' AND json_type(r.value, '$.id') = 'text'
                    AND json_extract(r.value, '$.id') IN (SELECT value FROM json_each(?))
                    """, arguments: StatementArguments(arguments))
                for row in rows {
                    let posted: Date? = row["posted_at"]
                    guard let posted else { continue }
                    found.append(Referrer(
                        key: NoteKey(host: host, id: row["id"]), target: NoteKey(host: host, id: row["target"]),
                        postedAt: posted, arrival: row["rowid"], kept: row["kept"]
                    ))
                }
            }
            return found
        }
    }

    public func marked(_ hosts: StoreOp.Hosts) throws -> Bool {
        let (named, arguments) = try Self.rows(of: hosts)
        return try poolRead { db, beside in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM note WHERE \(named) AND \(Self.readerSaidOrOwing) AND \(Self.readerMarked))",
                arguments: arguments
            ) ?? false
        }
    }

    public func rowCount() throws -> Int {
        try poolRead { db, beside in try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? 0 }
    }

    public func rowCounts() throws -> [String: HostRows] {
        try poolRead { db, beside in
            var counts: [String: HostRows] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT host, count(*) AS rows FROM note GROUP BY host") {
                let host: String = row["host"]
                // One row's word on its source's kind, by the host's index: a source removed is
                // named by what its posts wrote down (`formerSource`).
                let kind = try String.fetchOne(db, sql: """
                    SELECT kind FROM (SELECT CASE WHEN json_valid(facts) THEN json_extract(facts, '$.kind') END AS kind
                    FROM note WHERE host = ?) WHERE kind IS NOT NULL LIMIT 1
                    """, arguments: [host])
                counts[host] = HostRows(count: row["rows"], kind: kind.flatMap(ProtocolKind.init(rawValue:)))
            }
            return counts
        }
    }

    public func oldestStatusID(host: String, category: FediqoCore.Category) throws -> String? {
        let row = CategoryRow(category)
        let status = Self.statusIDExpression
        return try poolRead { db, beside in
            try String.fetchOne(db, sql: """
                SELECT \(status) FROM note
                WHERE host = ? AND \(status) IS NOT NULL AND \(Self.category(category, certain: true))
                ORDER BY length(\(status)), \(status) LIMIT 1
                """, arguments: StatementArguments([host, row.kind] + (row.id.map { [$0] } ?? [])))
        }
    }

    /// `op`, made on every row it names, inside the save's transaction.
    static func make(_ op: StoreOp, in db: Database) throws {
        switch op.kind {
        case .forgetReaderMarks(let hosts):
            // Every cell is read as it stood before this statement: what a row owed is judged
            // by the marks it is losing, as `ItemStore.forgetReaderMarks` judges it.
            let (named, arguments) = try rows(of: hosts)
            try db.execute(sql: """
                UPDATE note SET bookmarked = NULL,
                facts = CASE WHEN json_valid(facts) THEN json_remove(facts, '$.boosted', '$.favourited') ELSE facts END,
                refs_due = CASE WHEN refs_due AND \(arrivedAsReader) THEN 0 ELSE refs_due END
                WHERE \(named) AND \(readerSaidOrOwing) AND \(readerMarked)
                """, arguments: arguments)
        }
    }

    /// The rows of `hosts`, and its one argument.
    private static func rows(of hosts: StoreOp.Hosts) throws -> (String, StatementArguments) {
        switch hosts {
        case .only(let host): ("host = ?", [host])
        case .allBut(let kept): ("host NOT IN (SELECT value FROM json_each(?))", [try json(kept.sorted())])
        }
    }

    private static func json(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    /// What a reader's reads said they did: a boost, a favourite, a bookmark — any word on it.
    static let readerSaid = """
        (bookmarked IS NOT NULL OR (CASE WHEN json_valid(facts) THEN \
        json_extract(facts, '$.boosted') IS NOT NULL OR json_extract(facts, '$.favourited') IS NOT NULL ELSE 0 END))
        """

    /// Whether a row arrived by a signed read (`ItemStore.arrivedAsReader`): through no public
    /// timeline nor Trends, and through home or a list or saying what the reader did.
    private static let arrivedAsReader = """
        (NOT EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(categories) THEN categories ELSE '[]' END) j \
        WHERE j.type = 'object' AND json_extract(j.value, '$.kind') IN ('public', 'trends')) \
        AND (EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(categories) THEN categories ELSE '[]' END) j \
        WHERE j.type = 'object' AND json_extract(j.value, '$.kind') IN ('home', 'list')) OR \(readerSaid)))
        """

    /// Every row the taking back of a reader's marks may change, as `note_marked` holds them: a
    /// statement names it word for word for the index to answer it.
    static let readerSaidOrOwing = "(\(readerSaid) OR refs_due)"

    /// A row the taking back of a reader's marks changes.
    private static let readerMarked = "(\(readerSaid) OR (refs_due AND \(arrivedAsReader)))"
}
