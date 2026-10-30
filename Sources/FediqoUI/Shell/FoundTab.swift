import Foundation

/// The tabs of what a search found at one source (F10), in the order they stand: the people it
/// found, and the hashtags.
///
/// **A tab is the step's own value** (`ShellStep.found`): which one is in front is the walk's,
/// turned in place (`ShellWalk.turned(to:)`), so leaving never passes through the other tab and
/// turning adds no step — as what is rising turns its two. **Which tabs the page has is decided
/// where the answer is held** (`ShellSearchFound.tabs`): one for each kind the source's answer
/// gave any of, while it can still be drawn. Where only one is left, the page is that one list,
/// with no strip: absent, never grey.
enum FoundWhich: String, ShellTab, CaseIterable, Sendable {
    case people
    case tags

    var id: String { rawValue }

    var titleKey: String { "search.found.tab.\(rawValue)" }

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .tags: "number.square"
        }
    }

    /// The tabs of a page whose source gave `gave`, each kept only where `drawable` says it can
    /// still be drawn. **The one place it is decided.**
    static func tabs(gave: [FoundWhich], drawable: (FoundWhich) -> Bool) -> [FoundWhich] {
        allCases.filter { gave.contains($0) && drawable($0) }
    }

    /// What Tab or ⇧Tab does on the page, as every page with tabs decides it.
    static func keyed(_ tabs: [FoundWhich], front: FoundWhich, by step: Int, covered: Bool) -> PageKeyed<FoundWhich> {
        PageFrame.keyed(tabs, front: front, by: step, covered: covered)
    }

    /// The tab drawn in front with the walk standing on `step`'s tab, among the `tabs` the page
    /// has: that one where the page still has it, the one left where it has lost everything its
    /// source gave — the walk is then turned to it — and nothing where no tab is left, when the
    /// stream is drawn. **The one place it is decided.**
    static func front(_ step: FoundWhich, among tabs: [FoundWhich]) -> FoundWhich? {
        tabs.contains(step) ? step : tabs.first
    }

    /// The tab `to` brought in front on the page `walk` stands on, among the `tabs` it has: the
    /// step in front turned in place, the lamp of the tab left kept in `lamps` and the one `to`
    /// was left with handed back where it is still on one of `rows`, the rows `to` walks — or
    /// no lamp. Whether anything changed: a tab the page has not, the tab already in front, and
    /// a walk that is not standing on such a page change nothing.
    static func turned(
        _ walk: inout ShellWalk, to: FoundWhich, among tabs: [FoundWhich], rows: [String],
        lamps: inout [FoundWhich: String], lamp: inout String?
    ) -> Bool {
        guard let from = walk.openedFound, tabs.contains(to), walk.turned(to: .found(from.at, to)) else { return false }
        lamps[from.which] = lamp
        lamp = PageFrame.lamp(lamps[to], among: rows)
        return true
    }
}

/// What a search found at one source, as a step of the walk names its page: the source, the
/// words it was asked, and which kinds its answer gave when the page was opened — the most
/// tabs the page can have.
struct FoundAt: Hashable, Sendable {
    /// The host of the source that found them.
    let source: String
    /// The words it was asked, as they were sent.
    let words: String
    /// The kinds the source's answer gave any of, when the page was opened.
    let gave: [FoundWhich]

    /// The people it found: a list like any other, asked when its tab first comes in front.
    var people: PeopleList { PeopleList(foundAt: source, words: words) }
    /// The hashtags it found: what its answer already holds.
    var tags: FoundTags { FoundTags(source: source, words: words) }

    var id: String { "\(source)\u{1e}found\u{1e}\(words)" }

    // MARK: - Words

    /// What the page is called, whichever tab is in front.
    static func title(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("search.found.title", language: language), source)
    }

    /// The one line under the title: what was asked. **What was typed is set in a sentence of
    /// ours**, cut and made one line.
    func headLine(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("search.found.line", language: language), tags.lineWords)
    }
}

/// What the page of what a search found is handed, where it is drawn: its tabs, the tab drawn
/// in front, and what that tab lists — the people list's own word, or the hashtags the answer
/// held.
struct FoundSaid {
    let at: FoundAt
    let tabs: [FoundWhich]
    /// The tab drawn in front: the one the walk stands on, or the one left.
    let which: FoundWhich
    var people: PeopleSaid?
    var tags: FoundTagsSaid?
}

extension ShellWalk {
    /// The page of what a search found in front, and the tab the walk stands on there (F10).
    var openedFound: (at: FoundAt, which: FoundWhich)? {
        guard case .found(let at, let which) = standing else { return nil }
        return (at, which)
    }
}

extension ShellSearchFound {
    /// The step a press for all of one kind opens (#319, F10): the page of that source's
    /// answer on that kind's tab, with the kinds the answer gave — or nothing where the row is
    /// no such press, or its answer is no longer held.
    func step(opening row: SearchFoundRow, in session: ShellSession) -> ShellStep? {
        let which: FoundWhich, page: FoundTags
        switch row {
        case .allPeople(let list, _): (which, page) = (.people, FoundTags(source: list.host, words: list.words))
        case .allTags(let tags, _): (which, page) = (.tags, tags)
        case .person, .tag: return nil
        }
        guard let bands = bands(of: page, in: session) else { return nil }
        let gave = FoundWhich.allCases.filter { $0 == .people ? !bands.people.isEmpty : !bands.tags.isEmpty }
        return .found(FoundAt(source: page.source, words: page.words, gave: gave), which)
    }

    /// The tabs of the page of `at`: each kind its source gave, while it can be drawn — the
    /// people while their source can answer the search for them to whoever would ask now
    /// (`ShellPeoplePages.searchable`: signed in there, by a sign-in whose words do not say it
    /// may not search) and the source has not refused it search this run (`searches(at:)`);
    /// the hashtags while the answer is held. Otherwise a People tab could only ever say it
    /// could not be asked.
    func tabs(of at: FoundAt, in session: ShellSession) -> [FoundWhich] {
        FoundWhich.tabs(gave: at.gave) { which in
            switch which {
            case .people: lists.searchable(at.people, in: session) && searches(at: at.source)
            case .tags: said(of: at.tags, in: session)?.tags.isEmpty == false
            }
        }
    }

    /// What the page stood on at `which`'s tab is handed, where it is drawn: that tab's, or the
    /// one left (`FoundWhich.front`) — nothing where none is.
    func drawn(_ at: FoundAt, at which: FoundWhich, in session: ShellSession) -> FoundSaid? {
        let tabs = tabs(of: at, in: session)
        guard let front = FoundWhich.front(which, among: tabs) else { return nil }
        var said = FoundSaid(at: at, tabs: tabs, which: front)
        switch front {
        case .people: said.people = lists.said(of: at.people, in: session)
        case .tags: said.tags = self.said(of: at.tags, in: session)
        }
        return said
    }

    /// The rows `to`'s tab walks.
    private func walked(_ at: FoundAt, _ to: FoundWhich, in session: ShellSession) -> [String] {
        switch to {
        case .people: lists.walked(at.people, in: session)
        case .tags: walked(at.tags, in: session)
        }
    }

    /// A tab's pill pressed, or a swipe: brought in front on the page `walk` stands on, each
    /// tab keeping its own lamp. Whether anything changed (`FoundWhich.turned`).
    @discardableResult
    func turn(_ walk: inout ShellWalk, to which: FoundWhich, lamp: inout String?, in session: ShellSession) -> Bool {
        guard let at = walk.openedFound?.at else { return false }
        return FoundWhich.turned(
            &walk, to: which, among: tabs(of: at, in: session), rows: walked(at, which, in: session), lamps: &lamps, lamp: &lamp
        )
    }

    /// Tab and ⇧Tab on the page `walk` stands on, as `FoundWhich.keyed` answers for it: the
    /// tab beside; taken, and nothing turned, with one tab; and not the page's at all while it
    /// is `covered`. Whether the key was taken.
    func rotate(_ walk: inout ShellWalk, by step: Int, covered: Bool, lamp: inout String?, in session: ShellSession) -> Bool {
        guard let opened = walk.openedFound else { return false }
        switch FoundWhich.keyed(tabs(of: opened.at, in: session), front: opened.which, by: step, covered: covered) {
        case .turn(let tab):
            turn(&walk, to: tab, lamp: &lamp, in: session)
            return true
        case .taken: return true
        case .unheard: return false
        }
    }

    /// The walk has left the page: each tab's lamp is forgotten, and opened afresh it is lit
    /// nowhere but where the press that opened it says.
    func left() { lamps = [:] }
}
