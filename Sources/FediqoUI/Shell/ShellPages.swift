import FediqoCore
import Foundation
import SwiftUI

// A timeline read from the file a page at a time (#357, C4).
//
// **What is held is a pool, and a timeline is the pool through its rules.** Nothing reads the
// whole store: the timeline in front asks the file for its newest page, which is laid into the
// store's pool (`ItemStore.take`) with what its rows hold, and the screen draws the pool as it
// always drew the store. Reaching the rows near its foot asks for the page below — reading the
// last stretch again on the way, where a post may have landed since — and only once the file
// has nothing further does the foot ask the timeline's sources (`ShellReload.more`).
//
// **Drawn only as far down as it was read** (`TimelineDrawn`): a post held for another reason —
// a thread opened, another timeline's page, what a row quotes — would otherwise stand below a
// stretch not yet read, as if nothing lay between.
//
// **Nothing of this where the store is whole** (`ShellSession.readPage` nil): a test's, a
// preview's, a run with no file. Every timeline is then what is held, as before.

/// How far down the file one timeline has been read, and what for.
struct TimelineCoverage: Equatable, Sendable {
    /// What a timeline is read for: its rules, the latest date it stops at and the months limit.
    /// A page read for one is no page of another, so a change to any of them reads it afresh.
    struct Key: Equatable, Sendable {
        let definition: TimelineDefinition
        let latestEnd: Date?
        let keepFrom: Date?
    }

    /// How far down it is drawn: from `floor` up, or all of it where `floor` is nothing — the
    /// file has nothing further below.
    struct Reach: Equatable, Sendable {
        let generation: Int
        let floor: Date?
    }

    let key: Key
    /// Which reading this is: a page that comes back for one since replaced changes nothing here.
    let generation: Int
    /// Where the next page down starts: the last row looked at.
    var next: PageCursor?
    /// That row's time, read once as its page lands: how far down the timeline is drawn.
    var floor: Date?
    /// Its first page is in.
    var landed = false
    /// Drawn from a provisional page until the first lands (C15): down to the oldest of its
    /// rows. Nothing where none came, or once the first page is in. **No place to read on from**:
    /// `next` is the first page's alone.
    var provisional: Date?
    /// The row near the foot a reader reached while only a provisional page was drawn: read on
    /// from once the first page lands, for a reader who is already there.
    var footReached: String??
    /// The file has nothing below what was read.
    var exhausted = false
    /// A page is on its way.
    var reading = false

    func reach(for asked: Key) -> Reach? {
        guard asked == key else { return nil }
        if landed { return Reach(generation: generation, floor: exhausted ? nil : floor) }
        return provisional.map { Reach(generation: generation, floor: $0) }
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
    /// How many rows from a timeline's foot the next page is read (C4): the anchor, read again
    /// from on the way down.
    static let readAhead = 20

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

    /// Whether reaching the foot of `query` reads the file before anything asks a source: a
    /// timeline paged from the file with more below what it read.
    func readsOnFromFile(_ query: TimelineQuery) -> Bool {
        readPage != nil && coverage[query]?.exhausted != true
    }

    /// The first page of the timeline in front, where it has none for what it now is — asked by
    /// its pane's task, and given up with it (`TimelineAsk`). Read off the main actor; the rows
    /// are laid into the pool, and drawn.
    ///
    /// **A first page still on its way is asked again, and not waited for**: it may be one
    /// given up with a task since gone — a switch away and back — whose read has yet to hear so.
    /// Its page, when it comes, is of a reading since replaced, and changes nothing here.
    func cover(latest: LatestDate?) async {
        guard readPage != nil else { return }
        let query = currentTimeline
        let key = coverageKey(of: query, latest: latest)
        if let held = coverage[query], held.key == key, held.landed { return }
        pageGenerations += 1
        let generation = pageGenerations
        coverage[query] = TimelineCoverage(key: key, generation: generation, reading: true)
        // Beside it, where the file's pages' index is still being made: rows to draw meanwhile.
        let early = readEarly.map { read in Task { await readProvisional(read, query, key: key, generation: generation) } }
        await readDown(query, key: key, from: .newest, generation: generation)
        early?.cancel()
        guard coverage[query]?.generation == generation, coverage[query]?.landed == true else { return }
        // The file's index is made: nothing is provisional again this run.
        readEarly = nil
        if let foot = coverage[query]?.footReached {
            coverage[query]?.footReached = nil
            await readOn(query, from: foot, latest: latest)
        }
        guard !firstPageDrawn else { return }
        firstPageDrawn = true
        // What waits for the timeline to show (C1): not waited for here.
        if let after = afterFirstPage { Task.detached(priority: .utility) { await after() } }
    }

    /// The rows near the foot of `query` came into view (C4): the stretch from `anchor` down read
    /// again — a post may have landed in it since — and the page below it read. Where the file
    /// has nothing further, the timeline's sources are asked (`ShellReload.more`).
    func readOn(_ query: TimelineQuery, from anchor: String?, latest: LatestDate?) async {
        guard let readPage, let held = coverage[query], held.key == coverageKey(of: query, latest: latest) else { return }
        guard held.landed else {
            // Only a provisional page drawn: no place to read on from yet, so the reach is kept.
            if held.provisional != nil { coverage[query]?.footReached = .some(anchor) }
            return
        }
        guard !held.reading else { return }
        guard !held.exhausted, let next = held.next else {
            await reload.more(query, in: self)
            return
        }
        coverage[query]?.reading = true
        if let anchor, let key = NoteKey(rowID: anchor) {
            // A row not in the file yet — arrived this run, not saved — has no place there: the
            // page below is read all the same.
            let asked = Self.pageQuery(held.key, generation: held.generation)
            let ahead = Self.readAhead
            _ = try? await store.paged { try await readPage(asked, .beforeRow(key), ahead) }
        }
        let shown = await readDown(query, key: held.key, from: .before(next), generation: held.generation)
        if shown == 0, coverage[query]?.exhausted == true, !Task.isCancelled {
            await reload.more(query, in: self)
        }
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
        drawnTimelines = [:]
        drawnOrder = []
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

    private static func pageQuery(_ key: TimelineCoverage.Key, generation: Int) -> PageQuery {
        PageQuery(
            timeline: key.definition.id, generation: generation, compiled: CompiledTimeline(key.definition, sources: []),
            latestEnd: key.latestEnd, keepFrom: key.keepFrom
        )
    }

    /// Pages of `query` read down from `first`, each laid into the pool and drawn as it lands,
    /// until a page's worth of rows is shown or the file has no more. **Asked again where a page
    /// comes back short**: one that met its budget before its rows (`StoreFile.page`). Returns
    /// how many rows the pages showed.
    @discardableResult
    private func readDown(_ query: TimelineQuery, key: TimelineCoverage.Key, from first: PageAsk, generation: Int) async -> Int {
        guard let readPage else { return 0 }
        defer { if coverage[query]?.generation == generation { coverage[query]?.reading = false } }
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
                // what is held rather than a wait that never ends.
                guard coverage[query]?.generation == generation else { return shown }
                if error is CancellationError || Task.isCancelled {
                    if coverage[query]?.landed == false { coverage[query] = nil }
                } else {
                    coverage[query]?.landed = true
                }
                return shown
            }
            // Laid in (`paged`) whatever came of the ask since: what was read is what the file holds.
            guard coverage[query]?.generation == generation else { return shown }
            if let next = page.next {
                coverage[query]?.next = next
                coverage[query]?.floor = next.moment
            }
            coverage[query]?.exhausted = page.exhausted
            coverage[query]?.landed = true
            coverage[query]?.provisional = nil
            shown += page.rows.count
            await reloadFromStore()
            guard !page.exhausted, shown < Self.pageRows, let next = page.next, !Task.isCancelled else { return shown }
            ask = .before(next)
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
