import FediqoCore
import Foundation
import SwiftUI

// A timeline read from the file a page at a time (#357, C4), and drawn as a window (#359, C18).
//
// **What is held is a pool, and a timeline is the pool through its rules.** Nothing reads the
// whole store: the timeline in front asks the file for its newest page, which is laid into the
// store's pool (`ItemStore.paged`) with what its rows hold, and the screen draws the pool as it
// always drew the store.
//
// **Drawn between two edges** (`TimelineCoverage.floor`, `ceiling`): only as far down as it was
// read, and only as far up as it is kept. A post held for another reason — a thread opened,
// another timeline's page, what a row quotes — would otherwise stand outside a stretch not read,
// as if nothing lay between; and a timeline read deep would draw every row above the reader.
//
// **The place moves the window** (C19): the row at the top of the list, every twenty rows it
// moves (`scrolled`), reads the stretch ahead again — a post may have landed in it since — reads
// the page below or above where fewer than two hundred rows are left that way, and lets the far
// side go where more than three hundred and fifty are. A timeline switched away from keeps fifty
// rows each side of where it was left, drawn at once on the way back and read again then (C7).
// Only once the file has nothing further below does the foot ask the timeline's sources
// (`ShellReload.more`).
//
// **Nothing of this where the store is whole** (`ShellSession.readPage` nil): a test's, a
// preview's, a run with no file. Every timeline is then what is held, as before.

/// How far one timeline has been read from the file, which stretch of it is drawn, and what for.
struct TimelineCoverage: Equatable, Sendable {
    /// What a timeline is read for: its rules, the latest date it stops at and the months limit.
    /// A page read for one is no page of another, so a change to any of them reads it afresh.
    struct Key: Equatable, Sendable {
        let definition: TimelineDefinition
        let latestEnd: Date?
        let keepFrom: Date?
    }

    /// One edge of what is drawn, **in the store's order** (`ItemStore.storeOrder`): a moment to
    /// the millisecond the file holds it, and an id. Not by the moment alone: an edge may fall
    /// inside a run of rows of one moment, and only the part of the run on its side is drawn.
    struct Clip: Equatable, Sendable {
        let millisecond: Int64
        /// Nothing for every row of the moment.
        let id: String?

        init(_ at: Date, id: String?) {
            self.init(millisecond: Self.millisecond(of: at), id: id)
        }

        init(millisecond: Int64, id: String?) {
            self.millisecond = millisecond
            self.id = id
        }

        static func millisecond(of at: Date) -> Int64 {
            Int64((at.timeIntervalSince1970 * 1000).rounded())
        }

        /// Whether `note` stands at this edge or above it: newer, or of its moment and not after it.
        func under(_ note: Note) -> Bool {
            let at = Self.millisecond(of: note.postedAt)
            if at != millisecond { return at > millisecond }
            return id.map { note.id <= $0 } ?? true
        }

        /// Whether `note` stands at this edge or below it.
        func over(_ note: Note) -> Bool {
            let at = Self.millisecond(of: note.postedAt)
            if at != millisecond { return at < millisecond }
            return id.map { note.id >= $0 } ?? true
        }
    }

    /// An edge of the window, and where a page past it is asked from: the place a page handed
    /// back (`cursor`), or — an edge drawn in where rows were let go — the moment and id of the
    /// row it stands on. **Never the row's key**: a row the file has since let go would leave
    /// no place to read past it from, and the timeline would stop there for good.
    struct Edge: Equatable, Sendable {
        let cursor: PageCursor?
        let millisecond: Int64
        let id: String

        init?(_ cursor: PageCursor) {
            guard let at = cursor.moment else { return nil }
            self.cursor = cursor
            millisecond = Clip.millisecond(of: at)
            id = cursor.id
        }

        init(_ note: Note) {
            cursor = nil
            millisecond = Clip.millisecond(of: note.postedAt)
            id = note.id
        }

        var clip: Clip { Clip(millisecond: millisecond, id: id) }

        /// The page past it, older. From its row's moment and id, **a millisecond wide**: the
        /// file writes a time to the millisecond and a row held since it arrived may say more,
        /// so a few rows on the edge are read twice rather than any past it missed.
        var below: PageAsk {
            .before(cursor ?? PageCursor(millisecond: millisecond + 1, id: id, rowid: .max))
        }

        /// The page past it, newer, as `below`.
        var above: PageAsk {
            .after(cursor ?? PageCursor(millisecond: millisecond - 1, id: id, rowid: .min))
        }
    }

    /// Which stretch is drawn: from `floor` up to `ceiling` — to the bottom where there is no
    /// floor, the file having nothing further below, and to the newest and every arrival where
    /// there is no ceiling.
    struct Reach: Equatable, Sendable {
        let generation: Int
        let floor: Clip?
        let ceiling: Clip?

        /// Whether `note` stands inside it.
        func holds(_ note: Note) -> Bool {
            (floor?.under(note) ?? true) && (ceiling?.over(note) ?? true)
        }

        /// Whether `note` stands within a second of it: what is drawn is merged from these, and
        /// a row is drawn where any copy it merges stands inside (`holds`) — **so a post is
        /// never split at an edge**, one copy drawn and another, of the same moment or near it,
        /// left out, and the row drawn as another copy than it is everywhere else.
        func nears(_ note: Note) -> Bool {
            let at = Clip.millisecond(of: note.postedAt)
            return (floor.map { at >= $0.millisecond - Self.near } ?? true) && (ceiling.map { at <= $0.millisecond + Self.near } ?? true)
        }

        private static let near: Int64 = 1_000

        /// Whether the row `item` draws stands inside it: any of the copies it merges.
        func holds(_ item: DummyItem, held: (String) -> Note?) -> Bool {
            ([item.id] + item.otherCopies.map(\.id)).contains { held($0).map(holds) ?? false }
        }
    }

    let key: Key
    /// Which reading this is: a page that comes back for one since replaced changes nothing here.
    /// **Not moved by a page or an edge let go**: those are `floorMoved` and `ceilingMoved`.
    let generation: Int
    /// The lowest row drawn, and where the next page down starts: the last row looked at.
    var floor: Edge?
    /// The highest row drawn, and where the next page up starts. Nothing while the timeline is
    /// drawn to its newest: live.
    var ceiling: Edge?
    /// Its first page is in.
    var landed = false
    /// Drawn from a provisional page until the first lands (C15): down to the oldest of its
    /// rows. Nothing where none came, or once the first page is in. **No place to read on from**:
    /// the edges are the first page's alone.
    var provisional: Date?
    /// The row a reader moved to while only a provisional page was drawn: the window moved round
    /// it once the first page lands, for a reader who is already there.
    var placeReached: String?
    /// The file has nothing below what was read.
    var exhausted = false
    /// A page below is on its way.
    var reading = false
    /// A page above is on its way.
    var readingUp = false
    /// Raised each time an edge moves, by a page or by rows let go: **a page that comes back to
    /// an edge since moved is laid in and changes nothing here** — its rows are true rows, and
    /// its place is no longer the edge's.
    var floorMoved = 0
    var ceilingMoved = 0
    /// What the timeline drew as it was switched away from (G-4): the keys of its rows and of
    /// every copy they merge.
    var pinned: Set<NoteKey> = []
    /// Switched away from, and not read again since: what coming back to it reads.
    var behind = false

    func reach(for asked: Key) -> Reach? {
        guard asked == key else { return nil }
        if landed { return Reach(generation: generation, floor: exhausted ? nil : floor?.clip, ceiling: ceiling?.clip) }
        return provisional.map { Reach(generation: generation, floor: Clip($0, id: nil), ceiling: nil) }
    }
}

/// What the timeline in front is read for, as its pane's task is keyed: the task is begun again,
/// and the reading in flight given up, whenever this changes — and whenever every timeline is
/// to be read afresh (`epoch`, `forgetCoverage`).
struct TimelineAsk: Equatable, Sendable {
    let query: TimelineQuery
    let key: TimelineCoverage.Key
    let epoch: Int
}

extension ShellSession {
    /// How many rows a page reads.
    static let pageRows = 100
    /// How many rows the place moves before it is an anchor (C19), and how many rows ahead of it
    /// are read again there.
    static let readAhead = 20
    /// How many rows are kept drawn each side of the place (C18): two pages and a half.
    static let windowRows = 250
    /// Fewer rows than this left one way of the place, and the page that way is read.
    static let readWithin = 200
    /// More rows than this one way of the place, and the far side is let go, back to `windowRows`.
    static let trimOver = 350
    /// How many rows a timeline switched away from keeps each side of where it was left (C7).
    static let keptAway = 50

    func coverageKey(of query: TimelineQuery, latest: LatestDate?) -> TimelineCoverage.Key {
        TimelineCoverage.Key(definition: definition(of: query), latestEnd: latest?.end(), keepFrom: keepFrom)
    }

    func timelineAsk(latest: LatestDate?) -> TimelineAsk {
        TimelineAsk(query: currentTimeline, key: coverageKey(of: currentTimeline, latest: latest), epoch: coverageEpoch)
    }

    /// Whether the timeline in front is being read from the file: before its first page, drawn
    /// as being read and not as empty; after it, a page on its way below.
    func timelineLoading(latest: LatestDate?) -> Bool {
        guard readPage != nil else { return false }
        guard let coverage = coverage[currentTimeline], coverage.key == coverageKey(of: currentTimeline, latest: latest) else {
            return true
        }
        return !coverage.landed || coverage.reading
    }

    /// Whether the timeline in front is drawn short of its newest: the rows above its head are
    /// read as the reader comes up to them, and the head says so. **Not whether a page is on its
    /// way**, which would put a row over the list and take it away again with every page.
    func timelineReadsAbove(latest: LatestDate?) -> Bool {
        guard readPage != nil, let coverage = coverage[currentTimeline], coverage.landed else { return false }
        return coverage.key == coverageKey(of: currentTimeline, latest: latest) && coverage.ceiling != nil
    }

    /// Whether reaching the foot of `query` is the file's to answer — the place reads the page
    /// below (`placed`) — before anything asks a source: a timeline paged from the file with more
    /// below what it read.
    func readsOnFromFile(_ query: TimelineQuery) -> Bool {
        readPage != nil && coverage[query]?.exhausted != true
    }

    /// The first page of the timeline in front, where it has none for what it now is — asked by
    /// its pane's task, and given up with it (`TimelineAsk`). Read off the main actor; the rows
    /// are laid into the pool, and drawn.
    ///
    /// **One come back to is drawn at once** from what is held, between the edges it was left
    /// with (`timelineLeft`), and its stretch is read again: what reached the file meanwhile
    /// shows (`readAgain`).
    ///
    /// **A first page still on its way is asked again, and not waited for**: it may be one
    /// given up with a task since gone — a switch away and back — whose read has yet to hear so.
    /// Its page, when it comes, is of a reading since replaced, and changes nothing here.
    func cover(latest: LatestDate?) async {
        guard readPage != nil else { return }
        let query = currentTimeline
        let key = coverageKey(of: query, latest: latest)
        if let held = coverage[query], held.key == key, held.landed {
            // Drawn a moment ago and never left — a pane built again — it reads nothing.
            guard held.behind else { return }
            await readAgain(query, latest: latest)
            return
        }
        pageGenerations += 1
        let generation = pageGenerations
        coverage[query] = TimelineCoverage(key: key, generation: generation, reading: true)
        anchors[query] = nil
        // Beside it, where the file's pages' index is still being made: rows to draw meanwhile.
        let early = readEarly.map { read in Task { await readProvisional(read, query, key: key, generation: generation) } }
        await readDown(query, key: key, from: .newest, generation: generation, moved: 0)
        early?.cancel()
        guard coverage[query]?.generation == generation, coverage[query]?.landed == true else { return }
        // The file's index is made: nothing is provisional again this run.
        readEarly = nil
        if let reached = coverage[query]?.placeReached {
            coverage[query]?.placeReached = nil
            await placed(query, at: reached, latest: latest)
        }
        guard !firstPageDrawn else { return }
        firstPageDrawn = true
        // What waits for the timeline to show (C1): not waited for here.
        if let after = afterFirstPage { Task.detached(priority: .utility) { await after() } }
    }

    /// The row at the top of the list as it is scrolled (`KeepsTopRow`): **an anchor once it is
    /// `readAhead` rows from the last** (C19), and the window is then moved round it (`placed`),
    /// not waited for — so the scroll pays a lookup a report.
    ///
    /// **And wherever fewer than `readWithin` rows are drawn below it with none on their way**:
    /// a page counts the file's rows, and copies merged or a short page may draw it as a few — a
    /// list that fits the window with room to spare, whose top never moves twenty rows.
    @discardableResult
    func scrolled(to top: String, of query: TimelineQuery, latest: LatestDate?) -> Task<Void, Never>? {
        guard readPage != nil, query == currentTimeline, let held = coverage[query],
              let drawn = drawnTimelines[query.id], let at = drawn.index[top]
        else { return nil }
        let was = anchors[query].flatMap { drawn.index[$0] } ?? 0
        let short = held.landed && !held.reading && !held.exhausted && drawn.ids.count - 1 - at < Self.readWithin
        guard abs(at - was) >= Self.readAhead || (short && placing[query] == nil) else { return nil }
        anchors[query] = top
        return place(query, at: top, latest: latest)
    }

    /// The foot of `query` came into view while the file has more below it (`AsksForMore`): the
    /// window moved round the place it has, as `scrolled` would, where nothing is on its way —
    /// so a list too short to scroll still reads on.
    @discardableResult
    func footReached(_ query: TimelineQuery, latest: LatestDate?) -> Task<Void, Never>? {
        guard readsOnFromFile(query), query == currentTimeline, let held = coverage[query], !held.reading,
              placing[query] == nil, let drawn = drawnTimelines[query.id], let first = drawn.ids.first
        else { return nil }
        let drawnRow = { (row: String?) in row.flatMap { drawn.index[$0] == nil ? nil : $0 } }
        return place(query, at: drawnRow(anchors[query]) ?? drawnRow(scrolledTop) ?? first, latest: latest)
    }

    /// `placed`, begun and not waited for, and counted while it runs (`placing`).
    private func place(_ query: TimelineQuery, at row: String, latest: LatestDate?) -> Task<Void, Never> {
        placing[query, default: 0] += 1
        return Task {
            await placed(query, at: row, latest: latest)
            let left = (placing[query] ?? 1) - 1
            placing[query] = left > 0 ? left : nil
        }
    }

    /// The reader's place in `query` moved to `row` (C19): the far side let go where more than
    /// `trimOver` rows lie that way, the stretch ahead of the row read again — a post may have
    /// landed there since — and the page below or above read where fewer than `readWithin` rows
    /// lie that way. Where the page below finds the file has nothing further, the timeline's
    /// sources are asked (`ShellReload.more`).
    func placed(_ query: TimelineQuery, at row: String, latest: LatestDate?) async {
        guard let readPage, query == currentTimeline, let held = coverage[query],
              held.key == coverageKey(of: query, latest: latest)
        else { return }
        guard held.landed else {
            // Only a provisional page drawn: no place to read on from yet, so the place is kept.
            if held.provisional != nil { coverage[query]?.placeReached = row }
            return
        }
        anchors[query] = row
        trim(query, drawn: timelineDrawn(latest: latest), around: row, keeping: Self.windowRows, over: Self.trimOver)
        if let key = NoteKey(rowID: row) {
            // A row not in the file yet — arrived this run, not saved — has no place there: the
            // rest is done all the same.
            let asked = Self.pageQuery(held.key, generation: held.generation)
            let ahead = Self.readAhead
            _ = try? await store.paged { try await readPage(asked, .beforeRow(key), ahead) }
            guard coverage[query]?.generation == held.generation else { return }
            await reloadFromStore()
        }
        // The file has nothing below: the sources are asked now, wherever the place is — the
        // foot may be on screen already, and come into view no more.
        let shown = await extend(query, latest: latest)
        if shown == 0, coverage[query]?.exhausted == true, !Task.isCancelled {
            await reload.more(query, in: self)
        }
    }

    /// To the newest of `query`, where the rows above where it is read were let go (C22, the
    /// person's (a)): **its newest page read afresh and the timeline drawn there**, as it is
    /// the first time it is opened — the place left, and every page of the old window out
    /// disowned. What a jump to the top and a pull mean: the newest, now, and not a read up a
    /// page at a time from deep down. Says whether it went; nothing where the timeline is drawn
    /// to its newest already, which a jump or a pull reaches as before.
    @discardableResult
    func readNewest(_ query: TimelineQuery) async -> Bool {
        guard readPage != nil, let held = coverage[query], held.landed, held.ceiling != nil else { return false }
        pageGenerations += 1
        let generation = pageGenerations
        coverage[query] = TimelineCoverage(key: held.key, generation: generation, reading: true)
        anchors[query] = nil
        await readDown(query, key: held.key, from: .newest, generation: generation, moved: 0)
        return coverage[query]?.generation == generation && coverage[query]?.landed == true
    }

    /// `query` put behind another (G-3): **its edges drawn in to `keptAway` rows each side of
    /// `row`** — the post it was left at — or of its last anchor, in one step and with nothing
    /// read, and what those rows draw kept as what it holds (`pinned`). A page out past either
    /// edge is disowned; its pages in flight are given up with its pane's task.
    func timelineLeft(_ query: TimelineQuery, at row: String?) {
        guard readPage != nil, let held = coverage[query], held.landed else { return }
        coverage[query]?.behind = true
        guard let drawn = drawnTimelines[query.id], drawn.key.reach?.generation == held.generation, !drawn.ids.isEmpty else { return }
        let at = row.flatMap { drawn.index[$0] } ?? anchors[query].flatMap { drawn.index[$0] } ?? 0
        let place = drawn.ids[at]
        anchors[query] = place
        trim(query, drawn: drawn, around: place, keeping: Self.keptAway, over: Self.keptAway)
        let kept = drawn.items[max(0, at - Self.keptAway)...min(drawn.items.count - 1, at + Self.keptAway)]
        coverage[query]?.pinned = Set(kept.flatMap { [$0.id] + $0.otherCopies.map(\.id) }.compactMap(NoteKey.init(rowID:)))
    }

    /// Every row the person keeps read in from the file, on the store's actor and never the main
    /// one, and what is held adopted: what Usage's kept section asks before it says anything.
    /// Read once a run where it read; tried again where it could not.
    func readKeptRows() async {
        guard keptRowsRead != true else { return }
        guard store.heldInPart else {
            keptRowsRead = true
            return
        }
        keptRowsRead = nil
        let read = await store.readKept()
        if read { await reloadFromStore() }
        keptRowsRead = read
    }

    /// Every timeline read again from its first page: the pool was laid in afresh (a read back).
    /// The pane's task is keyed on the epoch, so the timeline in front is asked again at once.
    func forgetCoverage() {
        coverageEpoch += 1
        coverage = [:]
        anchors = [:]
        drawnTimelines = [:]
        drawnOrder = []
    }

    /// The edges of `query` drawn in to `kept` rows each side of `row`, on each side where more
    /// than `over` lie as `drawn` has them — **onto a row, never between two**: the page past it
    /// is asked by the row's key. Any page out past an edge moved is disowned (`floorMoved`,
    /// `ceilingMoved`); nothing is read.
    private func trim(_ query: TimelineQuery, drawn: DrawnTimeline, around row: String, keeping kept: Int, over: Int) {
        guard var held = coverage[query], let at = drawn.index[row] else { return }
        let ids = drawn.ids
        var moved = false
        if at > over, let note = note(ofRow: ids[at - kept]) {
            held.ceiling = TimelineCoverage.Edge(note)
            held.ceilingMoved += 1
            held.readingUp = false
            moved = true
        }
        if ids.count - 1 - at > over, let note = note(ofRow: ids[at + kept]) {
            held.floor = TimelineCoverage.Edge(note)
            held.exhausted = false
            held.floorMoved += 1
            held.reading = false
            moved = true
        }
        if moved { coverage[query] = held }
    }

    /// The stretch `query` was left with read again from its head down, a page — what reached
    /// the file while it was behind another eases in — and then its window grown back round
    /// its place.
    private func readAgain(_ query: TimelineQuery, latest: LatestDate?) async {
        guard let readPage, let held = coverage[query] else { return }
        let asked = Self.pageQuery(held.key, generation: held.generation)
        let from = held.ceiling?.below ?? .newest
        let rows = Self.pageRows
        _ = try? await store.paged { try await readPage(asked, from, rows) }
        // Given up with its task — switched away again — it is read again on the next return.
        guard coverage[query]?.generation == held.generation, !Task.isCancelled else { return }
        coverage[query]?.behind = false
        await reloadFromStore()
        await extend(query, latest: latest)
    }

    /// The page below and the page above the place in `query` read, each where fewer than
    /// `readWithin` rows lie that way. Says how many rows the page below showed — nothing where
    /// none was read.
    @discardableResult
    private func extend(_ query: TimelineQuery, latest: LatestDate?) async -> Int? {
        guard query == currentTimeline, let held = coverage[query], held.landed else { return nil }
        let drawn = timelineDrawn(latest: latest)
        let at = anchors[query].flatMap { drawn.index[$0] } ?? 0
        let below = max(drawn.ids.count - 1 - at, 0)
        var shown: Int?
        if below < Self.readWithin, !held.reading, !held.exhausted, let ask = held.floor?.below {
            coverage[query]?.reading = true
            shown = await readDown(query, key: held.key, from: ask, generation: held.generation, moved: held.floorMoved)
        }
        if at < Self.readWithin, let now = coverage[query], now.generation == held.generation, !now.readingUp,
           let ask = now.ceiling?.above, !Task.isCancelled {
            coverage[query]?.readingUp = true
            await readUp(query, key: now.key, from: ask, generation: now.generation, moved: now.ceilingMoved)
        }
        return shown
    }

    /// A provisional page of `query` (C15), drawn until its first page lands — and never after,
    /// nor for a reading since replaced. Its rows are true rows, and stay in the pool whatever.
    private func readProvisional(
        _ read: @Sendable (PageQuery, Int) async throws -> Page?, _ query: TimelineQuery,
        key: TimelineCoverage.Key, generation: Int
    ) async {
        let asked: Page?
        let ask = Self.pageQuery(key, generation: generation)
        let rows = Self.pageRows
        do {
            asked = try await store.pagedIfAny { try await read(ask, rows) }
        } catch {
            return
        }
        guard let page = asked else {
            // None to give: the file's index is made, and none will be this run.
            readEarly = nil
            return
        }
        guard let oldest = page.rows.map(\.note.postedAt).min() else { return }
        guard coverage[query]?.generation == generation, coverage[query]?.landed == false else { return }
        coverage[query]?.provisional = oldest
        await reloadFromStore()
    }

    static func pageQuery(_ key: TimelineCoverage.Key, generation: Int) -> PageQuery {
        PageQuery(
            timeline: key.definition.id, generation: generation, compiled: CompiledTimeline(key.definition, sources: []),
            latestEnd: key.latestEnd, keepFrom: key.keepFrom
        )
    }

    /// Pages of `query` read down from `first`, each laid into the pool and drawn as it lands,
    /// until a page's worth of rows is shown or the file has no more. **Asked again where a page
    /// comes back short**: one that met its budget before its rows (`StoreFile.page`). Returns
    /// how many rows the pages showed. `moved` is the floor's count as the read began: **a page
    /// that comes back to a floor since moved is laid in and changes nothing here**.
    @discardableResult
    private func readDown(
        _ query: TimelineQuery, key: TimelineCoverage.Key, from first: PageAsk, generation: Int, moved: Int
    ) async -> Int {
        guard let readPage else { return 0 }
        var floor = moved
        let ours = { self.coverage[query]?.generation == generation && self.coverage[query]?.floorMoved == floor }
        defer { if ours() { coverage[query]?.reading = false } }
        let asked = Self.pageQuery(key, generation: generation)
        let rows = Self.pageRows
        var ask = first
        var shown = 0
        while true {
            let page: Page
            do {
                let at = ask
                page = try await store.paged { try await readPage(asked, at, rows) }
            } catch {
                // Given up — a switch, a change — its first page is read again when next asked,
                // and nothing stands in for it meanwhile; a file that would not be read draws
                // what is held rather than a wait that never ends. An edge on a row not written
                // yet is read past once it is, from the next anchor.
                guard coverage[query]?.generation == generation else { return shown }
                if error is CancellationError || Task.isCancelled {
                    if coverage[query]?.landed == false { coverage[query] = nil }
                } else {
                    coverage[query]?.landed = true
                }
                return shown
            }
            // Laid in (`paged`) whatever came of the ask since: what was read is what the file holds.
            guard ours() else { return shown }
            if let next = page.next, let edge = TimelineCoverage.Edge(next) { coverage[query]?.floor = edge }
            floor += 1
            coverage[query]?.floorMoved = floor
            coverage[query]?.exhausted = page.exhausted
            coverage[query]?.landed = true
            coverage[query]?.provisional = nil
            shown += page.rows.count
            await reloadFromStore()
            guard !page.exhausted, shown < Self.pageRows, let next = page.next, !Task.isCancelled, ours() else { return shown }
            ask = .before(next)
        }
    }

    /// Pages of `query` read up from `first`, as `readDown` reads down, until a page's worth of
    /// rows is shown or the newest on file is reached — and the timeline is then drawn to its
    /// newest, live. The rows land above the place, which `HoldsPlace` keeps where it is.
    private func readUp(
        _ query: TimelineQuery, key: TimelineCoverage.Key, from first: PageAsk, generation: Int, moved: Int
    ) async {
        guard let readPage else { return }
        var ceiling = moved
        let ours = { self.coverage[query]?.generation == generation && self.coverage[query]?.ceilingMoved == ceiling }
        defer { if ours() { coverage[query]?.readingUp = false } }
        let asked = Self.pageQuery(key, generation: generation)
        let rows = Self.pageRows
        var ask = first
        var shown = 0
        while true {
            let page: Page
            do {
                let at = ask
                page = try await store.paged { try await readPage(asked, at, rows) }
            } catch {
                return
            }
            guard ours() else { return }
            if page.exhausted {
                coverage[query]?.ceiling = nil
            } else if let next = page.next, let edge = TimelineCoverage.Edge(next) {
                coverage[query]?.ceiling = edge
            }
            ceiling += 1
            coverage[query]?.ceilingMoved = ceiling
            shown += page.rows.count
            await reloadFromStore()
            guard !page.exhausted, shown < Self.pageRows, let next = page.next, !Task.isCancelled, ours() else { return }
            ask = .after(next)
        }
    }
}

/// Reads the first page of the timeline in front as the pane shows it, and again whenever what it
/// is read for changes (#357): a modifier of its own, so the task's closure is not spelled inline
/// in the pane's chain.
struct CoversTimeline: ViewModifier {
    let session: ShellSession
    let latest: LatestDate?

    func body(content: Content) -> some View {
        content.task(id: session.timelineAsk(latest: latest)) {
            await session.cover(latest: latest)
        }
    }
}

/// A row new to the timeline as drawn — a provisional page's rows given way to the first page's,
/// a page landed at the foot, a post read in inside what was read, an arrival from a source —
/// **eases in where it stands** (#357, C15): its own opacity and nothing else, so no row moves,
/// and the row being read is held where it is by `HoldsPlace`. A row that was there already, or
/// one scrolled into view, is simply there. **Where motion is to be reduced, nothing eases**: the
/// row is there at once.
struct EasesIn: ViewModifier {
    let arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// How long a row takes to come in: the shell's own quick step.
    static let duration = 0.2

    /// Whether a row starts unseen and comes in: only one that arrived, and only with motion.
    static func startsHidden(arrived: Bool, reduceMotion: Bool) -> Bool {
        arrived && !reduceMotion
    }

    func body(content: Content) -> some View {
        let hidden = Self.startsHidden(arrived: arrived, reduceMotion: reduceMotion)
        content
            .opacity(hidden && !shown ? 0 : 1)
            .onAppear {
                guard hidden, !shown else { return }
                withAnimation(.easeOut(duration: Self.duration)) { shown = true }
            }
    }
}

/// A row that left the timeline as drawn, shown where it stood while it **eases out** (#357):
/// its opacity and nothing else, and nothing a press reaches. Under reduced motion no row that
/// left is shown at all (`ShellSession.timelineShown`), so this never runs there.
struct EasesOut: ViewModifier {
    let leaving: Bool
    @State private var gone = false

    func body(content: Content) -> some View {
        content
            .opacity(leaving && gone ? 0 : 1)
            .allowsHitTesting(!leaving)
            .accessibilityHidden(leaving)
            .onChange(of: leaving, initial: true) { _, now in
                guard now else {
                    gone = false
                    return
                }
                withAnimation(.easeOut(duration: ShellSession.leavingFor)) { gone = true }
            }
    }
}

/// What stands in the place of a timeline's rows while its first page is read from this device
/// (#357, C2): the shape of rows to come, breathing one after another down the pane, and a line
/// that says what is happening. The rail and the rest are there to use meanwhile; nothing here is
/// pressed. **Still where motion is to be reduced.**
struct TimelineReading: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// How many rows are sketched: enough to read as a timeline, few enough to say it is not one.
    static let rows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<Self.rows, id: \.self) { row in
                ghost(row)
                ShellRule()
            }
            Text(L10n.t("timeline.reading"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .padding(ShellSpace.pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("timeline.reading"))
        .onAppear { if !reduceMotion { breathing = true } }
    }

    /// One row as a row is laid out — a face, a name, two lines of words — in the well's ink.
    private func ghost(_ row: Int) -> some View {
        let well = ShellChrome.well(colorScheme)
        let breath: Animation? = reduceMotion
            ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(row) * 0.18)
        return HStack(alignment: .top, spacing: ShellSpace.snug) {
            Circle().fill(well).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Capsule().fill(well).frame(width: 120, height: 10)
                Capsule().fill(well).frame(maxWidth: .infinity).frame(height: 8)
                Capsule().fill(well).frame(maxWidth: row.isMultiple(of: 2) ? 220 : 160).frame(height: 8)
            }
            .padding(.top, ShellSpace.tight)
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .opacity(breathing ? 0.45 : 1)
        .animation(breath, value: breathing)
    }
}

/// The foot of a timeline while the page below is read from this device (#357).
struct TimelineReadingOn: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            ProgressView().controlSize(.small)
            Text(L10n.t("timeline.reading.on"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
        .padding(ShellSpace.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
