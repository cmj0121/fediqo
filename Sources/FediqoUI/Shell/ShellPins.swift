import FediqoCore
import Foundation
import SwiftUI

// What the screens draw, said to the store (#359, C16, G-4).
//
// **A store over a file lets go of the rows it has seen least lately**, never of the file, once
// its pool is past its cap (`ItemStore.hold`) — and of no row the screens draw. The store knows
// what must stay for its own reasons (a change not written, a kept row, what a staying row holds
// with it); **what is drawn is the screens' to say**, and this is the one place it is said: the
// timeline in front as last drawn, the stretch each timeline put behind another keeps
// (`TimelineCoverage.pinned`), and every page open over the timeline — in front or under another
// — each row by every copy it merges and the post it quotes. A page that drew rows and said
// nothing would see them go at the next landing; a row said and not drawn only stays a while.
//
// **Said after each drawing that moved it**: each adopt of the store, each new drawing of the
// timeline in front, each page opened or left, an answer begun or ended. Each saying waits for
// the one before, so the store hears them in the order they were made, and nothing is said where
// nothing moved. Nothing where the store is whole (`readPage` nil), and nothing before the store
// was first read: no row leaves the pool before the screens have first said what they draw.

/// The pages open over the timeline, as the root has them (#359): the steps of its walk, in
/// front and under one another, whether its search is open, for what and whether it has folded
/// what it searches, and the latest date its timeline is drawn to — what a tag's page and the
/// search's results are drawn through.
struct OpenPages: Equatable {
    var steps: [ShellStep] = []
    var searching = false
    var pattern = ""
    var indexed = false
    var latest: LatestDate?
}

/// What the pages over the timeline that walk the pool draw was worked out from (#359): worked
/// out again only where one of these moved, not at each landing.
struct PagePinsKey: Equatable {
    let notesRevision: Int
    let definition: TimelineDefinition
    let pages: OpenPages
    let searchOpen: Bool
}

extension ShellSession {
    /// The pages open over the timeline moved — a step taken or left, the search opened, closed
    /// or typed into — and what they draw is said again.
    func pagesOpened(_ pages: OpenPages) {
        guard pages != openPages else { return }
        openPages = pages
        pinsMoved()
    }

    /// What the screens draw may have moved: said to the store once the drawing in hand is done,
    /// and not waited for. Nothing where the store is whole, or the window is gone.
    func pinsMoved() {
        guard readPage != nil, !screenClosed else { return }
        Task { await self.holdDrawn() }
    }

    /// What the screens draw now said to the store (`ItemStore.hold`), where it moved since it
    /// was last said — and waited for, behind any saying still on its way. **Nothing once the
    /// window is gone** (`screenGone`): a saying made after would keep, in the store, a drawing
    /// nobody draws.
    func holdDrawn() async {
        guard !screenClosed, let now = drawnNow(), heldLast?.pins != now.pins || heldLast?.at != now.at else { return }
        heldLast = now
        let before = pinsOnTheirWay
        let store = store
        let screen = screen
        let saying = Task {
            await before?.value
            await store.hold(now.pins, drawnAt: now.at, by: screen)
        }
        pinsOnTheirWay = saying
        await saying.value
    }

    /// The window follows its store again (`followStore`): where it had gone, it is a new screen
    /// to the store, with nothing said yet — the store hears nothing more from the one that went.
    func screenOpened() {
        guard screenClosed else { return }
        screen = UUID()
        screenClosed = false
        heldLast = nil
    }

    /// The window is gone — its following of the store ended: nothing more is said, and once
    /// whatever was on its way has been, the store is told that what it drew is drawn nowhere.
    func screenGone() async {
        let gone = screen
        screenClosed = true
        heldLast = nil
        await pinsOnTheirWay?.value
        await store.letGoOfPins(by: gone)
    }

    /// Every key the screens draw now, and the store's `drawn` what they are drawn from was read
    /// at. Nothing where the store is whole, or before it was first read.
    func drawnNow() -> (pins: Set<NoteKey>, at: Int)? {
        guard readPage != nil, let at = notesDrawnAt else { return nil }
        var pins = Set<NoteKey>()
        // The timeline in front as last drawn — the list on screen — and, where that drawing is
        // of rows read before, as it is drawn from what is read now: what the list is about to
        // become, which no pane may draw for a while (another place in front, a window behind).
        // Worked out once: the pane's next drawing takes it as it is (`timelineDrawn`).
        let front = drawnTimelines[currentTimeline.id]
        if let front { pins.formUnion(keys(of: front.items)) }
        let now = timelineDrawingKey(latest: front?.key.latest ?? openPages.latest)
        if front?.key != now { pins.formUnion(keys(of: timelineItemsKept(under: now))) }
        // Every timeline put behind another: the stretch round where it was left.
        for held in coverage.values { pins.formUnion(held.pinned) }
        pins.formUnion(pagePins())
        for step in openPages.steps {
            switch step {
            case .thread(let id):
                pins.formUnion(threadKeys(id))
            case .person(let who):
                pins.formUnion(personPages?.postKeys(of: who, in: self) ?? [])
            case .tag, .link, .people, .rising, .found, .followedTags:
                break
            }
        }
        // What an answer being written is written to, and what each text waiting to be sent
        // answers: looked up again as it goes.
        if let answering { pins.formUnion(keys(of: [answering.item, answering.root])) }
        for sending in outbox.sendings {
            pins.formUnion([sending.unsent.answers, sending.unsent.root].compactMap { $0 })
        }
        // A press not settled, and a post whose taking back is out: looked up again as each is
        // answered, and drawn again where it fails.
        pins.formUnion(acts.standings.keys.compactMap { NoteKey(rowID: $0.row) })
        pins.formUnion(acts.leaving.compactMap(NoteKey.init(rowID:)))
        return (pins, at)
    }

    /// The rows the timeline in front draws under `key`, as `timelineItems(under:)`, kept for
    /// the one drawing to come (`pinnedDrawing`): a landing merges the timeline once.
    func timelineItemsKept(under key: DrawnTimeline.Key) -> [DummyItem] {
        if let pinnedDrawing, pinnedDrawing.key == key { return pinnedDrawing.items }
        let items = timelineItems(under: key)
        if key.reach != nil { timelineEvaluations += 1 }
        pinnedDrawing = (key, items)
        return items
    }

    /// What the pages that walk the whole pool draw — somebody's page, a hashtag's, the search's
    /// results — worked out again only where what is held, the timeline they are drawn through,
    /// or the pages open moved. Pages of people, hashtags, links and words draw no post.
    private func pagePins() -> Set<NoteKey> {
        let search = openSearch.flatMap { $0.isOpen ? $0 : nil }
        let key = PagePinsKey(
            notesRevision: notesRevision, definition: definition(of: currentTimeline), pages: openPages,
            searchOpen: search != nil
        )
        if let pagePinsKept, pagePinsKept.key == key { return pagePinsKept.pins }
        var pins = Set<NoteKey>()
        for step in openPages.steps {
            switch step {
            case .person(let who): pins.formUnion(keys(of: heldPosts(of: who)))
            case .tag(let tag): pins.formUnion(keys(of: heldPosts(under: tag, latest: openPages.latest)))
            case .thread, .link, .people, .rising, .found, .followedTags: break
            }
        }
        if let search { pins.formUnion(keys(of: searched(search, latest: openPages.latest) ?? [])) }
        pagePinsKept = (key, pins)
        return pins
    }

    /// The keys rows draw: each one's own, every copy it merges, the post a reblog shows, and the
    /// post it quotes — **by its source's id too** (`quotedRow(of:)`), where the quote came as
    /// that alone and no reference holds the post with it.
    func keys(of items: [DummyItem]) -> Set<NoteKey> {
        var keys = Set<NoteKey>()
        for item in items {
            keys.formUnion(Self.keys(of: item))
            guard item.quotedRowID == nil, let quote = item.quote, quote.state == .accepted, let statusID = quote.statusID
            else { continue }
            if let quoted = heldRow(host: item.source.host, statusID: statusID) { keys.insert(quoted) }
        }
        return keys
    }

    /// The keys one row draws, but a post it quotes by its source's id alone.
    static func keys(of item: DummyItem) -> [NoteKey] {
        ([item.id, item.quotedRowID].compactMap { $0 } + item.otherCopies.map(\.id) + item.reblogged.map(\.id))
            .compactMap(NoteKey.init(rowID:))
    }

    /// The row of `host` its source gives `statusID`, among what is held — the first, as
    /// `quotedRow(of:)` finds it — by an index made once as `notes` changes.
    func heldRow(host: String, statusID: String) -> NoteKey? {
        let name = { (host: String, id: String) in host + "\u{1e}" + id }
        if let statusIndex, statusIndex.revision == notesRevision { return statusIndex.rows[name(host, statusID)] }
        var rows: [String: NoteKey] = [:]
        for note in notes {
            guard let id = note.statusID, rows[name(note.source.host, id)] == nil else { continue }
            rows[name(note.source.host, id)] = note.key
        }
        statusIndex = (notesRevision, rows)
        return rows[name(host, statusID)]
    }

    /// What the conversation opened from `id` draws: the post itself, every post round it, the
    /// reblogs of it and the posts its rows quote.
    func threadKeys(_ id: String) -> [NoteKey] {
        var keys = [NoteKey(rowID: id)].compactMap { $0 }
        guard let view = conversations.views[id] else { return keys }
        keys += (view.rows + view.reblogs + Array(view.quoted.values)).map(\.key)
        return keys
    }

    // MARK: - Counted from the file (#359, C23)

    /// How many posts this device holds of `host`, and whether that is only at least so many:
    /// **as the file counts them** where it has been (`rowsOnFile`) — the pool holds only the
    /// rows lately seen — and never fewer than the pool holds, which may have some the next save
    /// has yet to write. At least what the pool holds where the file was not counted.
    func postsHeld(host: String) -> (count: Int, atLeast: Bool) {
        let pooled = holdings.posts(host: host)
        guard let rowsOnFile else { return (pooled, store.heldInPart) }
        return (max(rowsOnFile[host.lowercased()]?.count ?? 0, pooled), false)
    }

    /// Every post this device holds, as `postsHeld(host:)` counts each source's.
    var postsHeldTotal: (count: Int, atLeast: Bool) {
        guard let rowsOnFile else { return (holdings.posts, store.heldInPart) }
        let hosts = Set(rowsOnFile.keys).union(holdings.bySource.keys)
        return (hosts.reduce(0) { $0 + postsHeld(host: $1).count }, false)
    }

    /// Every host this device holds posts of: the pool's, and the file's where it was counted.
    var hostsHeld: Set<String> {
        Set(holdings.bySource.keys).union(rowsOnFile.map { Set($0.filter { $0.value.count > 0 }.keys) } ?? [])
    }

    /// The source the posts of `host` were written down from, as the file says: what a source
    /// removed whose posts stayed is named by where the pool holds none of them (#250).
    func keptSource(of host: String) -> Source? {
        rowsOnFile?[host]?.kind.map { Source(host: host, kind: $0) }
    }
}

/// The pages open over the timeline handed to the session as they move (#359): the root's walk
/// and search, which the session draws nothing of itself. A modifier of its own, so the root's
/// long chain gains no closure the type-checker must read with the rest.
struct PinsPages: ViewModifier {
    let session: ShellSession
    let pages: OpenPages

    func body(content: Content) -> some View {
        content.onChange(of: pages, initial: true) { _, now in session.pagesOpened(now) }
    }
}
