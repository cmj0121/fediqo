import FediqoCore
import Foundation
import Observation

// The hashtags and the links rising on the sources (#320): what is asked, when, and what the
// two tabs of Trends are handed of the answers.
//
// **Asked when a tab comes in front, and when the person presses.** The two are tabs of Trends
// (F10, decision 2); bringing Hashtags in front asks each source that has them for one stretch, and
// Links likewise: one ask a source, and none when the tab comes in front again this run. **A
// tab never in front has asked nothing.** `r`, the mark and a pull ask every source again; a
// press while a source is being asked asks it nothing, and Stop calls off every source on the
// wire. Nothing reads on, nothing is asked while neither tab is in front, and nothing by itself.
//
// **Each source asked for itself, and one list drawn of them** (decision 22). A source's answer
// is kept as its own, in its own order; what a tab is handed is those answers woven into one
// list (`RisingListed.merged`) — every source's first, in the order the sources stand, then
// every second — a hashtag or an address once, naming every source that said it, its uses
// added. Fediqo ranks nothing of its own. A source still being asked, or failed, is named in the
// tab's toast while what the others said is drawn.
//
// **With no sign-in, of that source alone.** Anyone is given what is rising, so no token rides
// on these asks: they go out on the plain client, held to the small body's ceiling and to the
// host they are asked at, listed in the run's record and ended within the deadline.
//
// **Never absent for being empty.** A source that has switched what is rising off answers as
// one with nothing rising does, so an empty answer is said as the source giving none. A source
// is left out only where its own address answered that there is no such address, which is
// written down for the run where every such answer is (`ShellHostsKnown`).
//
// **An ask is this object's, and not the pane's**, numbered on the one count every page's asks
// are numbered on and landing only where its number is still the one awaited; **as whoever
// asked**, and let go with their sign-in; **held nowhere**. Each for the reason given where a
// person's page keeps the same rule (`ShellPersonPages`).
//
// **Only of a source that says who people are** — the one fact per kind there is, read where a
// person's page reads it. A forum has no such page and is asked nothing; what is rising on a
// forum is its ranking, read as posts as it always was.

/// Which of the two pages.
enum RisingWhich: String, Hashable, Sendable, CaseIterable {
    case tags, links

    /// What a host may say it has none of.
    var thing: MastodonHostThing {
        switch self {
        case .tags: .risingTags
        case .links: .risingLinks
        }
    }
}

/// One row of a page of what is rising: a hashtag or a link, and the source that says so.
enum RisingRow: Hashable, Sendable, Identifiable {
    case tag(RisingTag, source: String)
    case link(RisingLink, source: String)

    /// The host of the source that listed it.
    var source: String {
        switch self {
        case .tag(_, let source), .link(_, let source): source
        }
    }

    /// What it is, whoever listed it: a hashtag folded, a link its address.
    var key: String {
        switch self {
        case .tag(let tag, _): "rising\u{1e}tag\u{1e}\(MastodonRising.folded(tag.tag))"
        case .link(let link, _): "rising\u{1e}link\u{1e}\(link.link.url.absoluteString)"
        }
    }

    /// The row under its source: the same hashtag or address under two sources is two rows, as
    /// a list of one source's holds them (the hashtags followed).
    var id: String { "\(source)\u{1e}\(key)" }
}

/// One row of a tab of what is rising on Trends: a hashtag or a link, once however many
/// sources say it is rising (decision 22).
struct RisingListed: Hashable, Sendable, Identifiable {
    /// It as the first source to name it lists it — and so the door a link goes through — with
    /// its uses added over every source that named it.
    let row: RisingRow
    /// Every source that named it, in the order they came on the list: the first is `row`'s.
    let sources: [String]

    /// What it is, and of no source: the same row whichever source answered first, and while
    /// an answer asked again moves it, so the lamp on it stays.
    var id: String { row.key }

    /// The sources' lists, in the order the sources stand, woven into one: every source's
    /// first, then every second, and so on — a hashtag or an address once, where it first
    /// comes, and each later saying of it folded into that row. **The same lists give the same
    /// list**, whichever of them answered first.
    static func merged(_ lists: [[RisingRow]]) -> [RisingListed] {
        var listed: [RisingListed] = []
        var at: [String: Int] = [:]
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count {
                let row = list[rank]
                if let index = at[row.key] {
                    listed[index] = listed[index].folding(row)
                } else {
                    at[row.key] = listed.count
                    listed.append(RisingListed(row: row, sources: [row.source]))
                }
            }
        }
        return listed
    }

    /// It with another source's saying of it folded in: that source named after the others,
    /// its uses added, and — for a link the first source said nothing of — the first title and
    /// words a source gave. A source already named adds nothing.
    private func folding(_ other: RisingRow) -> RisingListed {
        guard !sources.contains(other.source) else { return self }
        let sources = sources + [other.source]
        switch (row, other) {
        case (.tag(let tag, let source), .tag(let more, _)):
            return RisingListed(row: .tag(RisingTag(tag: tag.tag, use: tag.use.adding(more.use)), source: source), sources: sources)
        case (.link(let link, let source), .link(let more, _)):
            let folded = RisingLink(
                link: link.link, title: link.title.isEmpty ? more.title : link.title,
                words: link.words.isEmpty ? more.words : link.words, use: link.use.adding(more.use)
            )
            return RisingListed(row: .link(folded, source: source), sources: sources)
        default:
            return self
        }
    }
}

extension RisingUse {
    /// Two sources' counts of one thing as one: each figure the sum of those said, and nothing
    /// where neither said it, over the longer of the two stretches of days.
    func adding(_ other: RisingUse) -> RisingUse {
        func sum(_ one: Int?, _ two: Int?) -> Int? { one.map { $0 + (two ?? 0) } ?? two }
        return RisingUse(posts: sum(posts, other.posts), people: sum(people, other.people), days: max(days, other.days))
    }
}

/// What a tab of what is rising is handed: what each source answered, in the order the sources
/// stand, and the one list woven of it.
struct RisingSaid: Equatable {
    struct Answer: Equatable, Identifiable {
        enum Reading: Equatable {
            /// Not answered yet: on the wire, or about to be.
            case asking
            /// The ask was stopped before it answered, and nothing is on the wire.
            case stopped
            /// The source answered: `rows` is what it gave, which may be nothing.
            case said
            /// The source refused, failed, or sent what could not be read.
            case failed
        }

        /// The host of the source.
        let source: String
        var reading: Reading = .asking
        /// Whether this source is on the wire.
        var asking = false
        var rows: [RisingRow] = []

        var id: String { source }
    }

    let which: RisingWhich
    var answers: [Answer]

    /// The one list, top to bottom as the tab draws it.
    var rows: [RisingListed] { RisingListed.merged(answers.map(\.rows)) }
}

/// What every source said is rising on it this run, by page and source.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellRising {
    typealias AskedAs = ShellPersonPages.AskedAs

    private struct Page {
        let host: String
        var askedAs: AskedAs
        var reading: RisingSaid.Answer.Reading = .asking
        var rows: [RisingRow] = []
        var asking = false
        /// The number of the ask whose answer this source's row of the page awaits.
        var awaits = 0
    }

    private var pages: [String: Page] = [:]
    /// The pages whose last ask was stopped (`stop`), until they are asked again.
    private var halted: Set<RisingWhich> = []
    /// The ask on the wire for each source of each page.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// What this run knows each host has: where a not-found of an address is written down.
    @ObservationIgnored private let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to what is rising on a host, where a test reaches it by one — a wire that
    /// goes on answering an ask that was called off, as a transfer already ended does. Nothing
    /// in the app.
    @ObservationIgnored var reaching: ((String) -> MastodonRising)?

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    private static func key(_ which: RisingWhich, _ host: String) -> String { "\(which.rawValue)\u{1e}\(host)" }

    /// A page opening, as its pane's task is named: which page **and who asks at each source**,
    /// so a page in front whose reader ends, begins or changes opens again by itself, and is asked.
    func opening(_ which: RisingWhich, in session: ShellSession) -> [ShellPersonPages.Opening] {
        sources(of: which, in: session).map {
            ShellPersonPages.Opening(id: Self.key(which, $0.host), askedAs: ShellPersonPages.askedAs(at: $0.host, in: session))
        }
    }

    /// What was told of `host` let go, and its asks called off: its reader is no longer who
    /// asked (`PageReaders`).
    func letGo(at host: String) {
        for (key, page) in pages where page.host == host {
            asks[key]?.cancel()
            asks[key] = nil
            pages[key] = nil
        }
    }

    // MARK: - What the pages are handed

    /// The sources a page is of, in the order they stand: each one that says who people are,
    /// but for one whose own address answered that it has no such thing this run.
    private func sources(of which: RisingWhich, in session: ShellSession) -> [Source] {
        session.sources.compactMap { ShellPersonPages.source(at: $0.host, in: session) }
            .filter { hosts.has(which.thing, at: $0.host) != .absent }
    }

    /// The tabs of Trends that list what is rising (F10): each kind of thing some source has a
    /// ranking of. Posts is not this object's; see `TrendsTab.tabs(in:)`.
    func tabs(in session: ShellSession) -> [RisingWhich] {
        RisingWhich.tabs { !sources(of: $0, in: session).isEmpty }
    }

    private func standing(_ which: RisingWhich, at host: String, in session: ShellSession) -> Page? {
        pages[Self.key(which, host)].flatMap {
            $0.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? $0 : nil
        }
    }

    /// What the page `which` is handed, or nothing where no source has such a page: there is
    /// then nothing to draw.
    func said(_ which: RisingWhich, in session: ShellSession) -> RisingSaid? {
        let answers = sources(of: which, in: session).map { source -> RisingSaid.Answer in
            guard let page = self.standing(which, at: source.host, in: session) else { return RisingSaid.Answer(source: source.host) }
            return RisingSaid.Answer(source: source.host, reading: page.reading, asking: page.asking, rows: page.rows)
        }
        return answers.isEmpty ? nil : RisingSaid(which: which, answers: answers)
    }

    /// The rows `j` and `k` walk on the page `which`, top to bottom.
    func walked(_ which: RisingWhich, in session: ShellSession) -> [String] {
        said(which, in: session)?.rows.map(\.id) ?? []
    }

    /// The row `id` of the page `which`, where the page as it is drawn holds it.
    func row(_ id: String, of which: RisingWhich, in session: ShellSession) -> RisingListed? {
        said(which, in: session)?.rows.first { $0.id == id }
    }

    /// Whether the page `which` has anybody to ask again — what `r` and its mark go by: a
    /// source that says who people are, one left out for the run among them. **Still true while
    /// its asks are out**, as every page's is (`TimelineWays.canReload`): the mark keeps its
    /// place and is Stop meanwhile, and a press then asks no source already being asked.
    func canAskAgain(_ which: RisingWhich, in session: ShellSession) -> Bool {
        session.sources.contains { ShellPersonPages.source(at: $0.host, in: session) != nil }
    }

    /// What the tab `which` says in its toast (DESIGN-reload): the sources on the wire, in host
    /// order; the ones whose last ask failed; and whether the last was stopped. **Every ask of
    /// it was pressed for** — the tab coming in front, `r`, the mark, a pull — so a wait is
    /// one Stop stops.
    func ask(of which: RisingWhich, in session: ShellSession, language: DummyLanguage? = nil) -> PageAsking {
        let standing = sources(of: which, in: session).compactMap { self.standing(which, at: $0.host, in: session) }
        let asking = standing.filter(\.asking).map(\.host).sorted()
        return PageAsking(
            asking: TimelineToast.waiting("rising.asking", hosts: asking, language: language),
            stoppable: !asking.isEmpty,
            failed: standing.filter { $0.reading == .failed && !$0.asking }.map(\.host),
            stopped: halted.contains(which)
        )
    }

    /// The tab's Stop, and `Escape` on it: every source of `which` on the wire called off, what
    /// it said as it was — or stopped, where it had not answered — and whatever is on the wire
    /// lands nowhere. A stop is never a failure. Whether anything was stopped.
    @discardableResult
    func stop(_ which: RisingWhich) -> Bool {
        let running = pages.filter { $0.key.hasPrefix(which.rawValue + "\u{1e}") && $0.value.asking }.keys
        for key in running {
            asks[key]?.cancel()
            asks[key] = nil
            pages[key]?.awaits = errands.next()
            pages[key]?.asking = false
            if pages[key]?.reading == .asking { pages[key]?.reading = .stopped }
        }
        guard !running.isEmpty else { return false }
        halted.insert(which)
        return true
    }

    /// Where the lamp stands once a row was pressed to open: on the row where it opened, and
    /// where it was where the press opened nothing — a press that opens nothing moves nothing.
    static func lamp(after opened: Bool, of row: String, before: String?) -> String? {
        opened ? row : before
    }

    // MARK: - Asking

    /// The page `which` opening: each of its sources asked for one stretch, each for itself.
    /// Asked once a run: a source that answered is drawn from what it said; one being asked is
    /// waited on and asked nothing more; one whose ask was stopped, or was made as somebody
    /// else, is asked.
    func opened(_ which: RisingWhich, in session: ShellSession) async {
        var waited: [Task<Void, Never>] = []
        for source in sources(of: which, in: session) {
            _ = readers.look(at: source.host, in: session)
            if let page = self.standing(which, at: source.host, in: session) {
                if page.asking {
                    if let running = asks[Self.key(which, source.host)] { waited.append(running) }
                    continue
                }
                if page.reading == .said || page.reading == .failed { continue }
            }
            waited.append(begin(which, at: source.host, in: session))
        }
        for task in waited { await task.value }
    }

    /// `r`, the mark and a pull: the sources of the page asked again — every one, or the one
    /// named. What a source said stays drawn until its answer lands. **A press while a
    /// source is being asked asks it nothing.**
    func again(_ which: RisingWhich, at host: String? = nil, in session: ShellSession) async {
        // Asked of every source, a source left out for the run is asked afresh too: `r` is
        // the person's reload, and nothing is absent until the app is quit.
        if host == nil {
            for source in session.sources where ShellPersonPages.source(at: source.host, in: session) != nil
                && hosts.has(which.thing, at: source.host) == .absent
            {
                hosts.askAfresh(source.host)
            }
        }
        var waited: [Task<Void, Never>] = []
        for source in sources(of: which, in: session) where host == nil || host == source.host {
            _ = readers.look(at: source.host, in: session)
            if self.standing(which, at: source.host, in: session)?.asking == true { continue }
            waited.append(begin(which, at: source.host, in: session))
        }
        for task in waited { await task.value }
    }

    /// Starts one source's ask, and hands back the task it runs in. Everything it needs is
    /// taken here, before anything waits: the host, who asks, the way to it.
    private func begin(_ which: RisingWhich, at host: String, in session: ShellSession) -> Task<Void, Never> {
        let key = Self.key(which, host)
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        if pages[key]?.askedAs.isTheSame(as: askedAs) != true { pages[key] = Page(host: host, askedAs: askedAs) }
        let errand = errands.next()
        pages[key]?.awaits = errand
        pages[key]?.asking = true
        halted.remove(which)
        let through = reaching?(host) ?? session.reach.unsignedRising(host, for: .rising, within: deadline)
        let round = hosts.round(at: host)
        let task = Task { await self.ask(which, at: host, of: through, errand: errand, round: round) }
        asks[key] = task
        return task
    }

    private func ask(_ which: RisingWhich, at host: String, of through: MastodonRising, errand: Int, round: Int) async {
        let key = Self.key(which, host)
        defer { if pages[key]?.awaits == errand { asks[key] = nil } }
        do {
            let rows: [RisingRow]
            switch which {
            case .tags: rows = try await through.tags().map { .tag($0, source: host) }
            case .links: rows = try await through.links().map { .link($0, source: host) }
            }
            guard pages[key]?.awaits == errand else { return }
            pages[key]?.rows = rows
            pages[key]?.reading = .said
        } catch {
            guard pages[key]?.awaits == errand else { return }
            if (error as? MastodonHostMoreError) == .noSuchAddress {
                // The host's own word that the address is not there: left out, for the run.
                hosts.notFound(which.thing, at: host, round: round)
            } else if Cancellation.happened(error) {
                // Stopped before it answered: what was said before stands, and nothing is.
                if pages[key]?.reading == .asking { pages[key]?.reading = .stopped }
            } else {
                pages[key]?.reading = .failed
            }
        }
        // Nothing is left asking with nothing on the wire.
        pages[key]?.asking = false
    }
}
