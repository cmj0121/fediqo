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
/// **Asked of the timeline in front** (#145). What it finds is what that timeline lets through —
/// its sources, its categories, its rules, and the latest date — matched against the pattern
/// #32 settled. A search that ignored the one thing the reader already said about a timeline
/// would show them, from Trends or from a timeline written to leave a topic out, exactly the
/// posts it was written to keep away. On All that is everything, as it always was.
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
        /// The timeline searched: switching with the search open searches the new one.
        let timeline: TimelineDefinition
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
        litWhenIndexed = false
        letGo = nil
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
        litWhenIndexed = false
        letGo = nil
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
        letGo = nil
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

    /// The timeline under the search changed (#145): the post parked for it is written down as
    /// the place of the one left, and the one arrived at hands over its own, to come back when the
    /// search closes.
    ///
    /// **The parked post and not the lamp.** With the search open the lamp is on a result, and a
    /// result is never a timeline's place (#100) — so the one thing moved between timelines here
    /// is what was parked, and closing the search gives back the post of the timeline the reader
    /// is now in, rather than one from the timeline they opened the search in.
    func switched(_ place: (_ parked: String?) -> String?) {
        guard isOpen else { return }
        selectionBefore = place(selectionBefore)
    }

    /// Whether moving to `place` closes the search. It belongs to the timeline, and one left
    /// open behind another page would be closed by an Escape pressed there, for nothing seen.
    func closes(leavingFor place: ShellPlace) -> Bool {
        isOpen && place != .timeline
    }

    /// Return in the field (#163): what it says is searched now, and the keys go back to the list.
    ///
    /// **Now, not after the pause.** The pause spares a large store a search on every key; Return
    /// is the reader saying the typing is over, and waiting on it would hand the list the results
    /// for an earlier part of the pattern — or, typed quickly enough that nothing had settled yet,
    /// the timeline's own rows, so the lit row was not a result at all.
    ///
    /// **The keys are handed back here too**, not only through the field losing its focus, because
    /// that is the platform's and arrives when it arrives; a `j` pressed in between must already be
    /// the list's. `submits` counts it for whatever holds the list's keys to take them back (iOS).
    func submit() {
        guard isOpen else { return }
        pattern = text
        fieldFocused = false
        submits += 1
        litWhenIndexed = !isIndexed
    }

    /// Counts Returns in the field: each one asks the list to take the keys back.
    private(set) var submits = 0

    /// The press the field let go of the keys on, while nothing has been pressed since (#168).
    ///
    /// **A Mac text field takes the keys back after Return by itself.** AppKit sends the field's
    /// action — which is where Return hands the keys to the list — and then selects the field's
    /// text again, making it first responder once more, whatever the action did. In a key window
    /// SwiftUI hears that as the field being focused, so the keys went straight back to the
    /// field: `j` replaced the pattern instead of moving the light, and the light was on a result
    /// the new pattern no longer found. A focus that arrives on the very press that let go of it
    /// is that reselection, and nobody asked for it; a later press — a click on the field, `/` —
    /// is the reader asking, and is let through.
    @ObservationIgnored private var letGo: LetGo?

    /// One press, as the platform names it: `nil` where it names none.
    private struct LetGo {
        let press: AnyHashable?
    }

    /// Return has handed the keys back during `press`. Recorded where the field is one that
    /// takes them back by itself — a Mac's — so the focus it takes on that press can be refused.
    func letGo(during press: AnyHashable?) {
        guard isOpen else { return }
        letGo = LetGo(press: press)
    }

    /// The field's focus changed during `press`: whether it may have it. Losing it always may;
    /// gaining it may, unless it is the field taking back on the same press the keys it has just
    /// let go of. Where it may, `fieldFocused` follows it, which is what the shell's keys read.
    func fieldFocus(_ on: Bool, during press: AnyHashable?) -> Bool {
        guard on else {
            fieldFocused = false
            return true
        }
        if let letGo, letGo.press == press { return false }
        letGo = nil
        fieldFocused = true
        return true
    }

    /// Return came before the index: its first result is still to be lit when it lands.
    @ObservationIgnored private var litWhenIndexed = false

    /// Whether a Return is still waiting for the index to light its first result — true once,
    /// and never once `/` has handed the field the keys again.
    func takeLitWhenIndexed() -> Bool {
        guard litWhenIndexed, isIndexed, isOpen else { return false }
        litWhenIndexed = false
        return true
    }

    /// Searches for `typed` if it is still what the field says.
    func settle(_ typed: String) {
        if isOpen, typed == text { pattern = typed }
    }

    /// The posts found in `timeline`, newest first, cut at the latest date as every timeline is
    /// (#22) — or nothing while there is no search, so the timeline is drawn as it was.
    ///
    /// **The timeline's rules first, then the pattern, then the date, then the merge** — the
    /// timeline's own order with the pattern in it (#145, #114). A copy a rule keeps out is never
    /// matched, so however well it matches it is not found; and a post two sources carried is
    /// drawn once, from the copies both let through. `text` is the session's folded text, which a
    /// keyword or author rule reads; the caller builds it only for a timeline that has one.
    ///
    /// Found nothing yet, too, until the index has landed — the list stands empty and says it is
    /// searching, rather than showing the timeline the pattern has not been matched against. The
    /// pause before a pattern settles is about as long as folding takes, and folding here would
    /// stall the typing it is meant to spare. Notes that arrive while the search is open are
    /// folded as they are read (`SearchIndex.entry`).
    ///
    /// Asked on every body pass, so the answer is kept until the pattern, the notes — as
    /// `revision` counts them — the timeline, the sources or the date change.
    func items(
        in timeline: TimelineDefinition,
        text: @autoclosure () -> TextIndex,
        from notes: [Note],
        revision: Int,
        sources: [Source],
        latest: LatestDate?
    ) -> [DummyItem]? {
        guard isOpen, let search = NoteSearch(pattern, sources: sources, labels: Self.labels) else {
            return nil
        }
        guard isIndexed else { return [] }
        let key = Key(pattern: pattern, timeline: timeline, revision: revision, sources: sources, latest: latest)
        if let cached, cached.key == key { return cached.items }
        let shown = CompiledTimeline(timeline, sources: []).shown(notes, timeline.readsText ? text() : TextIndex([]))
        let found = search.found(shown, index)
        // One post is one row here as it is on the timeline (#114): a search that drew a merged
        // row twice would be the complaint #10 left for later, arriving through the search field.
        let items = DummyItem.merged(latest?.shown(found) ?? found)
        cached = (key, items)
        return items
    }
}
