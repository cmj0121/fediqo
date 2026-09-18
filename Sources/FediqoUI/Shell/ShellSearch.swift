import FediqoCore
import Foundation
import Observation

/// The search `/` opens (#32): what is typed, what is searched, and the selection to give back.
///
/// **A layer, not a query.** While it is open its results stand in for the stream — `j`, `k` and
/// Return walk them — and leaving it puts back the timeline and the post selected before it
/// opened. So does emptying the field. It reads the notes the session holds and asks no source
/// anything.
///
/// **Typing only matches.** The notes are folded into a `SearchIndex` off the main actor as the
/// search opens, not in the first redraw after a keystroke; what is searched trails what is typed
/// by a short pause (`settle`), so a large store is not re-read on every key.
@MainActor
@Observable
final class ShellSearch {
    private(set) var isOpen = false
    /// The field's text. Emptied, it searches nothing and the timeline is back at once.
    var text = "" {
        didSet { if text.isEmpty { pattern = "" } }
    }
    /// The pattern the results are for: the text, once typing pauses.
    private(set) var pattern = ""
    /// The field has the keys, so the shell's single-letter keys must leave them alone.
    var fieldFocused = false
    /// Bumped to hand the field the keys again.
    private(set) var focusTick = 0
    /// The timeline's selection when the search opened: what closing or emptying it gives back.
    private(set) var selectionBefore: String?
    /// Whether the index for the notes the search opened over has landed.
    private(set) var isIndexed = false

    @ObservationIgnored private var index = SearchIndex([])
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private var cached: (key: Key, items: [DummyItem])?

    private struct Key: Equatable {
        let pattern: String
        /// `ShellSession.notesRevision`: bumped whenever the notes are replaced, so comparing it
        /// costs nothing however many notes there are.
        let revision: Int
        let sources: [Source]
        let latest: LatestDate?
    }

    /// How long typing has to pause before the results follow it.
    static let pause = Duration.milliseconds(120)

    /// The names public, trends and home are drawn with, in every language the app speaks — so
    /// `趨勢` and `Trends` both find a trending post whichever language the app is set to.
    static let labels: [FediqoCore.Category: [String]] = {
        let languages: [DummyLanguage] = [.english, .taiwanese]
        return [FediqoCore.Category.public, .trends, .home].reduce(into: [:]) { labels, category in
            labels[category] = languages.map { RuleText.categoryName(category, host: nil, sources: [], language: $0) }
        }
    }()

    /// A pattern is being searched: something other than spaces has settled in the field.
    var isSearching: Bool { isOpen && !pattern.allSatisfy(\.isWhitespace) }

    /// Opens an empty search, keeping the timeline's selection to give back, and starts folding
    /// `notes` for it. The last index is reused, so notes that did not change are not folded again.
    func open(from selection: String?, over notes: [Note]) {
        isOpen = true
        text = ""
        selectionBefore = selection
        focusTick += 1
        isIndexed = false
        let old = index
        indexing?.cancel()
        indexing = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { SearchIndex(notes, reusing: old) }.value
            guard let self, !Task.isCancelled else { return }
            index = built
            isIndexed = true
        }
    }

    /// Waits for the index `open` started. For tests.
    func indexed() async {
        await indexing?.value
    }

    func focus() {
        focusTick += 1
    }

    /// Closes it and hands back the selection the timeline had when it opened. An index still
    /// being folded for it is not wanted any more.
    func close() -> String? {
        indexing?.cancel()
        indexing = nil
        let selection = selectionBefore
        isOpen = false
        text = ""
        fieldFocused = false
        selectionBefore = nil
        return selection
    }

    /// The field emptied: `restore` is handed the selection to give back — but only while the
    /// search is open. Closing empties the field too, and the selection close gave back must not
    /// be taken away again by the emptying it caused.
    func cleared(_ restore: (String?) -> Void) {
        guard isOpen else { return }
        restore(selectionBefore)
    }

    /// Whether moving to `place` closes the search. It belongs to the timeline, and one left
    /// open behind another page would be closed by an Escape pressed there, for nothing seen.
    func closes(leavingFor place: ShellPlace) -> Bool {
        isOpen && place != .timeline
    }

    /// Searches for `typed` if it is still what the field says.
    func settle(_ typed: String) {
        if isOpen, typed == text { pattern = typed }
    }

    /// The posts found, newest first, cut at the latest date as every timeline is (#22) — or
    /// nothing while there is no search, so the timeline is drawn as it was.
    ///
    /// Found nothing yet, too, until the index has landed — the list stands empty and says it is
    /// searching, rather than showing the timeline the pattern has not been matched against. The
    /// pause before a pattern settles is about as long as folding takes, and folding here would
    /// stall the typing it is meant to spare. Notes that arrive while the search is open are
    /// folded as they are read (`SearchIndex.entry`).
    ///
    /// Asked on every body pass, so the answer is kept until the pattern, the notes — as
    /// `revision` counts them — the sources or the date change.
    func items(from notes: [Note], revision: Int, sources: [Source], latest: LatestDate?) -> [DummyItem]? {
        guard isOpen, let search = NoteSearch(pattern, sources: sources, labels: Self.labels) else {
            return nil
        }
        guard isIndexed else { return [] }
        let key = Key(pattern: pattern, revision: revision, sources: sources, latest: latest)
        if let cached, cached.key == key { return cached.items }
        let found = search.found(notes, index)
        let items = (latest?.shown(found) ?? found).map { DummyItem($0) }
        cached = (key, items)
        return items
    }
}
