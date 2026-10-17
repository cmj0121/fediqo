import FediqoCore
import Foundation
import SwiftUI

// The open search read from the file a page at a time (#360, K-5, C25).
//
// **Everything held, not only what was read.** While a search is open over a store held in part,
// the file is asked for pages of what the timeline in front shows and the pattern matches
// (`StoreFile.search`), each laid into the pool as a timeline's page is (`ItemStore.paged`). The
// results are what the pool finds, as they always were (`ShellSearch.items`): drawn at once from
// what is held, and the file's joining them as they land — and kept, as everything a search draws
// is, while it is open (`ShellSession.pagePins`), and let go as any row once it closes.
//
// **Read on as the reader nears their foot**, a page's worth at a time, and not to the end at
// once: a pattern found in tens of thousands of posts would otherwise hold them all. Until the
// file has nothing further, the count says "at least".
//
// **Where the file cannot narrow the pattern**, only the pool is searched, and the field says so:
// a pattern that names a category, one of wildcards alone, or a file with no words index whole —
// one this SQLite cannot keep, or an older build's not made yet. **An index still being built is
// asked all the same**: a row it has not reached passes it and is matched in Swift, so it finds no
// less, only slower.

/// What the open search is read from the file for: its pattern, the timeline in front as a page
/// of it is read, and the sources whose categories' names it is matched against. A change to any
/// reads it afresh.
struct SearchAsk: Equatable, Sendable {
    let pattern: String
    let key: TimelineCoverage.Key
    let sources: [Source]
    let epoch: Int
}

/// How far the open search has been read from the file.
struct SearchReading: Equatable, Sendable {
    let ask: SearchAsk
    /// Which reading this is: a page that comes back for one since replaced changes nothing.
    let generation: Int
    /// Where the next page starts.
    var next: PageCursor?
    /// A page has come back.
    var landed = false
    /// The file has nothing further.
    var exhausted = false
    /// Pages are on their way.
    var reading = false
    /// The file could not narrow the pattern: only what was read so far was searched.
    var poolOnly = false
}

extension ShellSession {
    /// What the open search reads from the file for now, or nothing — none open, no pattern, or
    /// a store whole, with no file to ask.
    func searchAsk(_ search: ShellSearch?, latest: LatestDate?) -> SearchAsk? {
        guard readSearch != nil, let search, search.isSearching else { return nil }
        return SearchAsk(
            pattern: search.pattern, key: coverageKey(of: currentTimeline, latest: latest), sources: sources, epoch: coverageEpoch
        )
    }

    /// The first pages of what `ask` finds, where it has none yet: read off the main actor, laid
    /// into the pool and drawn, until a page's worth is found or the file has no more. Nothing,
    /// and nothing kept, for no ask.
    func coverSearch(_ ask: SearchAsk?) async {
        guard let ask else {
            searchReading = nil
            return
        }
        if let held = searchReading, held.ask == ask, held.landed || held.poolOnly { return }
        pageGenerations += 1
        searchReading = SearchReading(ask: ask, generation: pageGenerations, reading: true)
        await readSearchDown(generation: pageGenerations)
    }

    /// The foot of the search's results came into view: the next pages read, where the file has
    /// more and none is on its way.
    @discardableResult
    func searchFootReached() -> Task<Void, Never>? {
        guard let held = searchReading, held.landed, !held.reading, !held.exhausted, !held.poolOnly, held.next != nil
        else { return nil }
        searchReading?.reading = true
        let generation = held.generation
        return Task { await readSearchDown(generation: generation) }
    }

    /// What the search bar says of `found` results: whether only at least so many are held, and
    /// the line that says only what was read so far was searched — exactly when it was, naming
    /// how many posts that was (`searched`, `ShellSearch.searchedCount`).
    /// Nothing is said of what was searched until how many is known.
    func searchCount(found: Int, searched: Int?) -> (atLeast: Bool, readSoFar: String?) {
        guard readSearch != nil, store.heldInPart else { return (false, nil) }
        guard let held = searchReading else { return (true, nil) }
        if held.poolOnly { return (false, searched.map { L10n.count("search.readSoFar", $0) }) }
        return (!held.exhausted, nil)
    }

    /// Pages read down from where the search's reading stands, each laid in and drawn as it
    /// lands, until a page's worth of rows is found or the file has no more.
    private func readSearchDown(generation: Int) async {
        guard let readSearch, let held = searchReading, held.generation == generation else { return }
        let ours = { self.searchReading?.generation == generation }
        defer { if ours() { searchReading?.reading = false } }
        guard let search = NoteSearch(held.ask.pattern, sources: held.ask.sources, labels: ShellSearch.labels) else {
            searchReading?.poolOnly = true
            return
        }
        let query = Self.pageQuery(held.ask.key, generation: generation)
        let rows = Self.pageRows
        var ask = held.next.map { PageAsk.before($0) } ?? .newest
        var found = 0
        while !Task.isCancelled {
            let page: Page?
            do {
                let at = ask
                page = try await store.pagedIfAny { try await readSearch(query, search, at, rows) }
            } catch {
                // Given up: asked again when next wanted. A file that would not be read: where a
                // page came back before, what was found stands, said as at least so many, and the
                // next foot reached asks again from where it stood; where none did, there is no
                // place to ask from, and what is held is all that was searched, said so.
                guard ours(), !(error is CancellationError), !Task.isCancelled else { return }
                // A later page that failed leaves `landed` and `next` as they were: the count
                // stays "at least", and `searchFootReached` asks again from that cursor.
                if searchReading?.landed != true { searchReading?.poolOnly = true }
                return
            }
            guard ours() else { return }
            guard let page else {
                searchReading?.poolOnly = true
                return
            }
            searchReading?.landed = true
            searchReading?.exhausted = page.exhausted
            if let next = page.next { searchReading?.next = next }
            found += page.rows.count
            await reloadFromStore()
            guard !page.exhausted, found < rows, let next = page.next, ours() else { return }
            ask = .before(next)
        }
    }
}

/// Reads the open search from the file as its pattern or the timeline in front changes (#360):
/// a modifier of its own, so the task's closure is not spelled inline in the root's chain.
struct CoversSearch: ViewModifier {
    let session: ShellSession
    let ask: SearchAsk?

    func body(content: Content) -> some View {
        content.task(id: ask) {
            await session.coverSearch(ask)
        }
    }
}

/// A result row near the foot of the search's results, coming into view, reads the next pages
/// of the search from the file (#360).
struct SearchReadsOn: ViewModifier {
    let asks: Bool
    let session: ShellSession

    func body(content: Content) -> some View {
        content.onAppear {
            guard asks else { return }
            session.searchFootReached()
        }
    }
}
