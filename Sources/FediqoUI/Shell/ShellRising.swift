import FediqoCore
import Foundation
import Observation

// The hashtags and the links rising on the sources (#320): what is asked, when, and what the
// two tabs of Trends are handed of the answers.
//
// **Asked when a tab comes in front, and when the person presses.** The two are tabs of Trends
// (F10, decision 2); bringing Hashtags in front asks each source that has them for one stretch, and
// Links likewise: one ask a source, and none when the tab comes in front again this run. **A
// tab never in front has asked nothing.** `r` asks every source again,
// and a failure's "Try again" asks that source; a press while a source is being asked asks it
// nothing. Nothing reads on, nothing is asked while neither tab is in front, and nothing by itself.
//
// **Each source for itself.** The answers are never merged: a source's rows stand under its own
// band, in its own order, and a source that fails says so under its band while the others land.
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

    /// The row itself: the same hashtag or address under two sources is two rows.
    var id: String {
        switch self {
        case .tag(let tag, let source): "\(source)\u{1e}rising\u{1e}tag\u{1e}\(MastodonRising.folded(tag.tag))"
        case .link(let link, let source): "\(source)\u{1e}rising\u{1e}link\u{1e}\(link.link.url.absoluteString)"
        }
    }
}

/// What a page of what is rising is handed: one band a source, in the order the sources stand.
struct RisingSaid: Equatable {
    struct Band: Equatable, Identifiable {
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
    var bands: [Band]

    /// Every row, top to bottom as the page draws them.
    var rows: [RisingRow] { bands.flatMap(\.rows) }
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
        var reading: RisingSaid.Band.Reading = .asking
        var rows: [RisingRow] = []
        var asking = false
        /// The number of the ask whose answer this source's band awaits.
        var awaits = 0
    }

    private var pages: [String: Page] = [:]
    /// The ask on the wire for each source's band.
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
        let bands = sources(of: which, in: session).map { source -> RisingSaid.Band in
            guard let page = self.standing(which, at: source.host, in: session) else { return RisingSaid.Band(source: source.host) }
            return RisingSaid.Band(source: source.host, reading: page.reading, asking: page.asking, rows: page.rows)
        }
        return bands.isEmpty ? nil : RisingSaid(which: which, bands: bands)
    }

    /// The rows `j` and `k` walk on the page `which`, top to bottom.
    func walked(_ which: RisingWhich, in session: ShellSession) -> [String] {
        said(which, in: session)?.rows.map(\.id) ?? []
    }

    /// The row `id` of the page `which`, where the page as it is drawn holds it.
    func row(_ id: String, of which: RisingWhich, in session: ShellSession) -> RisingRow? {
        said(which, in: session)?.rows.first { $0.id == id }
    }

    /// Whether the page `which` has anybody to ask again — what `r` and its mark go by: a
    /// source that says who people are, one left out for the run among them, **and nothing of
    /// the page on the wire**: a reload pressed while its asks are out is refused.
    func canAskAgain(_ which: RisingWhich, in session: ShellSession) -> Bool {
        let any = session.sources.contains { ShellPersonPages.source(at: $0.host, in: session) != nil }
        return any && !pages.contains { $0.key.hasPrefix(which.rawValue + "\u{1e}") && $0.value.asking }
    }

    /// Where the lamp stands once a row was pressed to open: on the row where it opened, and
    /// where it was where the press opened nothing — a press that opens nothing moves nothing.
    static func lamp(after opened: Bool, of row: RisingRow, before: String?) -> String? {
        opened ? row.id : before
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

    /// `r`, and a band's "Try again": the sources of the page asked again — every one, or the
    /// one named. What a band holds stays drawn until its answer lands. **A press while a
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
                // The host's own word that the address is not there: no band, for the run.
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
