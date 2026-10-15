import FediqoCore
import Foundation
import Observation

// What a source announces to the people signed in to it (#321), for that source's own page and
// the mark on its row: what is asked, when, what is kept of it, and how a press on one is guarded.
//
// **Asked when the source's page opens, and with each round that reads that source** — the run's
// first read, `r`, a pull and every round of the wait under Preferences (`ShellReload`) — **at
// most once every fifteen minutes a source**, whichever asked last. Only of a source the reader
// is signed in to that says who people are; never because Account appeared (Decision 37), and
// never on a clock of its own: the fifteen minutes only hold a round back. A round that did not
// reach the source asks nothing. A failure's "Try again" asks at once.
//
// **Seen is this device's, for this run, and nothing is sent for it.** An announcement drawn on
// the page stops lighting the row's mark; it is marked "New" for as long as that page stays
// open. **Dismissed is the source's**: the reader's press, asked first, rides the account part
// and is sent; from then on the source lists it as `read`, and it folds under "N dismissed" —
// so one dismissed elsewhere, or read on the source's own web page, arrives folded too.
//
// **An empty answer is not "the host has none"**: it draws no block and lights nothing. Absent
// is the host's own word, or a not-found of its address remembered for the run
// (`ShellHostsKnown`). A source that will not show this sign-in its announcements says so, once
// a run, and lights nothing.
//
// **A reaction rides the acting part, and is never asked for.** A sign-in without it draws the
// reactions as words. Every press is guarded by `PressGuard`: one out an announcement, drawn
// at once, and a press while it is out sends nothing. **A read already on its way undoes
// nothing**: a reaction landed stays drawn over every read begun before it landed, and a
// dismissal stays for the run.
//
// **As whoever asked, and nobody else's** (`PageReaders`), as every page's asks are; **held
// nowhere** — for this run, in memory.

/// What a source's page is handed of what it announces.
struct AnnouncementsSaid: Equatable {
    /// Where asking has got to.
    enum Reading: Equatable {
        /// Not answered yet: on the wire, about to be, or stopped before it answered.
        case asking
        /// The source answered; what it listed is `shown` and `dismissed`.
        case said
        /// The source would not show this sign-in its announcements.
        case forbidden
        /// The source failed, or sent what could not be read. What was held stays drawn.
        case failed
    }

    /// One reaction as it is drawn: the source's count and whether it is the reader's, with any
    /// press out or landed since the source last said.
    struct Reaction: Equatable, Identifiable {
        let name: String
        var count: Int
        var mine: Bool
        let picture: CustomEmoji?
        var id: String { name }
    }

    /// A press that did not arrive, said under its announcement.
    enum Missed: Equatable {
        case dismiss
        case react(String)
        case unreact(String)
    }

    /// One announcement as it is drawn.
    struct Shown: Equatable, Identifiable {
        let announcement: Announcement
        var reactions: [Reaction]
        /// Not seen on this device before the page opened.
        var new = false
        /// A press on it is out.
        var pressing = false
        var missed: Missed?
        var id: String { announcement.id }
    }

    /// The host of the source that announces.
    let source: String
    var reading: Reading = .asking
    /// Whether the ask is on the wire.
    var asking = false
    /// Not dismissed, in the source's order.
    var shown: [Shown] = []
    /// Dismissed, in the source's order: folded under one line.
    var dismissed: [Shown] = []
    var folded = true
    /// Whether the sign-in holds the acting part, which a reaction rides.
    var reacts = false
    /// How the sign-in stands to the account part, where Dismiss is not offered for it.
    var dismissLock: PartWords.Place?
}

/// A press on an announcement, as it is drawn while it is out.
enum AnnouncementAct: Equatable {
    case dismiss
    /// A reaction put on (`true`) or taken back.
    case react(String, Bool)

    var missed: AnnouncementsSaid.Missed {
        switch self {
        case .dismiss: .dismiss
        case .react(let name, let wanted): wanted ? .react(name) : .unreact(name)
        }
    }
}

/// What every source's page was told this run of what it announces, by host.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask.
@MainActor
@Observable
final class ShellAnnouncements {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// The least time between two asks of one source, but for a page's "Try again".
    static let between: Duration = .seconds(15 * 60)

    /// A reaction landed: drawn over every read begun before it (`since`).
    private struct Turned {
        let wanted: Bool
        let since: Int
    }

    private struct Named: Hashable {
        let id: String
        let name: String
    }

    /// What a press is known by: one out an announcement.
    struct PressName: Hashable {
        let host: String
        let id: String
    }

    private struct Page {
        var askedAs: AskedAs
        /// What the source last listed. Nothing before it has.
        var list: [Announcement]?
        var reading: AnnouncementsSaid.Reading = .asking
        var asking = false
        /// The number of the ask whose answer this page awaits.
        var awaits = 0
        /// When it was last asked: what holds a round back.
        var askedAt: ContinuousClock.Instant?
        /// Seen on this device this run.
        var seen: Set<String> = []
        /// Not seen before the page opened: marked New while it stays open.
        var newHere: Set<String> = []
        var showing = false
        var folded = true
        /// Dismissed by a press of this run's.
        var dismissedHere: Set<String> = []
        var turned: [Named: Turned] = [:]
        var missed: [String: AnnouncementsSaid.Missed] = [:]
    }

    private var pages: [String: Page] = [:]
    private var presses = PressGuard<PressName, AnnouncementAct>()
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    @ObservationIgnored private let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// The clock the fifteen minutes are read on. A test turns it by hand.
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// Another way to a source's announcements, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonToken) -> MastodonAnnouncements)?

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    /// A source's page opening, as the block's task is named: which host **and who asks**.
    static func opening(_ host: String, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: host, askedAs: ShellPersonPages.askedAs(at: host, in: session))
    }

    /// What was told of `host` let go, its ask called off and its presses' answers told to
    /// nobody: its reader is no longer who asked (`PageReaders`).
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        presses.letGo { name, _ in name.host == host }
    }

    // MARK: - What the page and the row are handed

    private func asker(at host: String, in session: ShellSession) -> (source: Source, askedAs: AskedAs)? {
        guard let source = ShellPersonPages.source(at: host, in: session),
              hosts.has(.announcements, at: source.host) != .absent
        else { return nil }
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        return askedAs == .nobody ? nil : (source, askedAs)
    }

    private func standing(at host: String, as askedAs: AskedAs) -> Page? {
        pages[host].flatMap { $0.askedAs.isTheSame(as: askedAs) ? $0 : nil }
    }

    /// What the page of the source at `host` is handed, or nothing: nobody is signed in there,
    /// the source does not say who people are, the host has none, or it listed none.
    func said(at host: String, in session: ShellSession) -> AnnouncementsSaid? {
        guard let (source, askedAs) = asker(at: host, in: session) else { return nil }
        let page = standing(at: source.host, as: askedAs)
        var said = AnnouncementsSaid(
            source: source.host, reading: page?.reading ?? .asking, asking: page?.asking ?? false,
            folded: page?.folded ?? true,
            reacts: session.mastodon.place(.acting, host: source.host) == nil,
            dismissLock: session.mastodon.place(.account, host: source.host)
        )
        guard said.reading != .forbidden else { return said }
        for announcement in page?.list ?? [] {
            let shown = drawn(announcement, at: source.host, on: page)
            if dismissed(announcement, at: source.host, on: page) {
                said.dismissed.append(shown)
            } else {
                said.shown.append(shown)
            }
        }
        if said.reading == .said, said.shown.isEmpty, said.dismissed.isEmpty { return nil }
        return said
    }

    /// How many announcements the source at `host` holds that are neither seen on this device
    /// nor dismissed, as last asked — or nothing where there are none. **Asks nothing.**
    func mark(at host: String, in session: ShellSession) -> Int? {
        guard let (source, askedAs) = asker(at: host, in: session),
              let page = standing(at: source.host, as: askedAs), page.reading != .forbidden, let list = page.list
        else { return nil }
        let unseen = list.filter { !page.seen.contains($0.id) && !dismissed($0, at: source.host, on: page) }.count
        return unseen > 0 ? unseen : nil
    }

    private func dismissed(_ announcement: Announcement, at host: String, on page: Page?) -> Bool {
        announcement.read == true || page?.dismissedHere.contains(announcement.id) == true
            || presses.shown(PressName(host: host, id: announcement.id)) == .dismiss
    }

    private func drawn(_ announcement: Announcement, at host: String, on page: Page?) -> AnnouncementsSaid.Shown {
        var reactions = announcement.reactions.map {
            AnnouncementsSaid.Reaction(name: $0.name, count: $0.count, mine: $0.me == true, picture: $0.picture)
        }
        for (named, turned) in page?.turned ?? [:] where named.id == announcement.id {
            Self.turn(named.name, to: turned.wanted, in: &reactions)
        }
        let out = presses.shown(PressName(host: host, id: announcement.id))
        if case .react(let name, let wanted) = out { Self.turn(name, to: wanted, in: &reactions) }
        return AnnouncementsSaid.Shown(
            announcement: announcement, reactions: reactions, new: page?.newHere.contains(announcement.id) == true,
            pressing: out != nil, missed: page?.missed[announcement.id]
        )
    }

    /// The reader's reaction `name` put on or taken back in what is drawn: once, whatever the
    /// source already said of it.
    static func turn(_ name: String, to wanted: Bool, in reactions: inout [AnnouncementsSaid.Reaction]) {
        if let at = reactions.firstIndex(where: { $0.name == name }) {
            guard reactions[at].mine != wanted else { return }
            reactions[at].mine = wanted
            reactions[at].count = max(0, reactions[at].count + (wanted ? 1 : -1))
            if reactions[at].count == 0 { reactions.remove(at: at) }
        } else if wanted {
            reactions.append(AnnouncementsSaid.Reaction(name: name, count: 1, mine: true, picture: nil))
        }
    }

    // MARK: - Seen, and folded

    /// What the page shows is seen: whatever was not seen before is New while it stays open.
    private func see(_ host: String) {
        guard let page = pages[host], page.showing, let list = page.list else { return }
        let fresh = list.filter { !page.seen.contains($0.id) && $0.read != true }.map(\.id)
        pages[host]?.newHere.formUnion(fresh)
        pages[host]?.seen.formUnion(list.map(\.id))
    }

    /// The page of `host` put away: what was New there is not New when it opens again.
    func left(_ host: String) {
        pages[host]?.showing = false
        pages[host]?.newHere = []
    }

    /// The line over the dismissed ones pressed: they open in place, or fold again.
    func fold(_ host: String) {
        pages[host]?.folded.toggle()
    }

    // MARK: - Asking

    private func due(_ page: Page) -> Bool {
        if page.asking || page.reading == .forbidden { return false }
        guard let askedAt = page.askedAt, page.reading != .asking else { return true }
        return now() - askedAt >= Self.between
    }

    /// The page of the source at `host` opening: what it holds is seen, and the source is asked
    /// unless it was within the last fifteen minutes. Opened while an ask is on the wire, it
    /// waits on that ask and starts none.
    func opened(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session),
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session)
        else { return }
        let key = source.host
        if pages[key]?.askedAs.isTheSame(as: askedAs) != true { pages[key] = Page(askedAs: askedAs) }
        named(key, as: askedAs)
        pages[key]?.showing = true
        pages[key]?.folded = true
        pages[key]?.newHere = []
        see(key)
        guard let page = pages[key] else { return }
        if page.asking {
            await asks[key]?.value
            return
        }
        if due(page) { await begin(source, as: askedAs, with: held, in: session).value }
    }

    /// A round of reading answered from `host` (`ShellReload`): the source is asked, unless it
    /// was within the last fifteen minutes, an ask is on the wire, or nobody is signed in there.
    /// The task the ask runs in, where one began.
    @discardableResult
    func checked(_ host: String, in session: ShellSession) -> Task<Void, Never>? {
        guard let source = ShellPersonPages.source(at: host, in: session),
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session)
        else { return nil }
        if let page = standing(at: source.host, as: askedAs), !due(page) { return nil }
        return begin(source, as: askedAs, with: held, in: session)
    }

    /// A failure's "Try again": asked at once. Nothing while the ask is on the wire, or where
    /// the source did not fail.
    func again(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session),
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session),
              let page = standing(at: source.host, as: askedAs), !page.asking, page.reading == .failed
        else { return }
        await begin(source, as: askedAs, with: held, in: session).value
    }

    private func door(_ held: MastodonToken, for purpose: SourceWork.Purpose, in session: ShellSession) -> MastodonAnnouncements {
        reaching?(held) ?? session.reach.announcements(session.mastodon.authorized(token: held, within: deadline, for: purpose))
    }

    private func begin(
        _ source: Source, as askedAs: AskedAs, with held: MastodonToken, in session: ShellSession
    ) -> Task<Void, Never> {
        let host = source.host
        if pages[host]?.askedAs.isTheSame(as: askedAs) != true { pages[host] = Page(askedAs: askedAs) }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        pages[host]?.askedAt = now()
        let round = hosts.round(at: host)
        let through = door(held, for: .announcements, in: session)
        let task = Task { await self.ask(source, of: through, as: askedAs, errand: errand, round: round, in: session) }
        asks[host] = task
        return task
    }

    private func ask(
        _ source: Source, of through: MastodonAnnouncements, as askedAs: AskedAs, errand: Int, round: Int,
        in session: ShellSession
    ) async {
        let host = source.host
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let list = try await through.read()
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            pages[host]?.list = list
            pages[host]?.reading = .said
            // What landed before this read began is in what it says.
            let kept = pages[host]?.turned.filter { $0.value.since > errand } ?? [:]
            pages[host]?.turned = kept
            see(host)
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if (error as? MastodonHostMoreError) == .noSuchAddress {
                hosts.notFound(.announcements, at: host, round: round)
                pages[host]?.list = nil
                pages[host]?.reading = .said
            } else if let refused = error as? AnnouncementError, refused == .forbidden || refused == .outsideScope {
                pages[host]?.list = nil
                pages[host]?.reading = .forbidden
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[host]?.reading = .failed
            }
        }
        pages[host]?.asking = false
    }

    private func stillTheirs(_ host: String, errand: Int, askedAs: AskedAs, in session: ShellSession) -> Bool {
        guard pages[host]?.awaits == errand else { return false }
        guard ShellPersonPages.askedAs(at: host, in: session).isTheSame(as: askedAs) else {
            pages[host] = nil
            return false
        }
        return true
    }

    private func named(_ host: String, as now: AskedAs) {
        if case .reader(nil) = pages[host]?.askedAs, case .reader(.some) = now { pages[host]?.askedAs = now }
    }

    // MARK: - Pressing

    /// The announcement `id` at `host` as the page stands for whoever would press now, and the
    /// sign-in to press through — or nothing where there is no such announcement drawn.
    private func pressable(
        _ id: String, at host: String, in session: ShellSession
    ) -> (source: Source, askedAs: AskedAs, held: MastodonToken)? {
        guard let (source, askedAs) = asker(at: host, in: session) else { return nil }
        let looked = readers.look(at: source.host, in: session)
        guard let held = looked.held, !looked.changed,
              let page = standing(at: source.host, as: askedAs), page.list?.contains(where: { $0.id == id }) == true
        else { return nil }
        return (source, askedAs, held)
    }

    /// The yes to Dismiss's question: the announcement folds at once and is sent dismissed.
    /// Nothing where the sign-in does not hold the account part, or a press on it is out.
    func dismiss(_ id: String, at host: String, in session: ShellSession) async {
        guard let (source, askedAs, held) = pressable(id, at: host, in: session),
              session.mastodon.place(.account, host: source.host) == nil,
              let flight = presses.begin(PressName(host: source.host, id: id), showing: .dismiss)
        else { return }
        await send(.dismiss, on: id, flight: flight, at: source, as: askedAs, with: held, in: session)
    }

    /// A press on the reaction `name` of `id`: the reader's put on, or taken back where it is
    /// theirs. With `adding`, only ever put on — nothing where it is theirs already. Nothing
    /// where the sign-in does not hold the acting part, or a press on it is out.
    func react(_ name: String, on id: String, at host: String, adding: Bool = false, in session: ShellSession) async {
        guard let (source, askedAs, held) = pressable(id, at: host, in: session),
              session.mastodon.place(.acting, host: source.host) == nil,
              let shown = said(at: source.host, in: session).flatMap({ said in
                  (said.shown + said.dismissed).first { $0.id == id }
              })
        else { return }
        let mine = shown.reactions.first { $0.name == name }?.mine ?? false
        if adding, mine { return }
        guard let flight = presses.begin(PressName(host: source.host, id: id), showing: .react(name, !mine)) else { return }
        await send(.react(name, !mine), on: id, flight: flight, at: source, as: askedAs, with: held, in: session)
    }

    /// Sends a press and takes its answer, if it is still this press's to take. The request is
    /// this object's and not the page's: a page put away does not call it off.
    private func send(
        _ act: AnnouncementAct, on id: String, flight: PressNumber, at source: Source, as askedAs: AskedAs,
        with held: MastodonToken, in session: ShellSession
    ) async {
        let host = source.host
        pages[host]?.missed[id] = nil
        let through = door(held, for: .write, in: session)
        await Task {
            var failure: (any Error)?
            do {
                switch act {
                case .dismiss: try await through.dismiss(id)
                case .react(let name, true): try await through.react(id, with: name)
                case .react(let name, false): try await through.unreact(id, with: name)
                }
            } catch {
                failure = error
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
            }
            self.landed(act, on: id, flight: flight, failure: failure, at: source, as: askedAs, in: session)
        }.value
    }

    private func landed(
        _ act: AnnouncementAct, on id: String, flight: PressNumber, failure: (any Error)?, at source: Source,
        as askedAs: AskedAs, in session: ShellSession
    ) {
        let host = source.host, name = PressName(host: host, id: id)
        guard presses.isStill(flight, name) else { return }
        presses.settle(name)
        guard standing(at: host, as: ShellPersonPages.askedAs(at: host, in: session)) != nil,
              ShellPersonPages.askedAs(at: host, in: session).isTheSame(as: askedAs)
        else { return }
        // Withdrawn meanwhile, a dismissal has nothing left to dismiss: it is done.
        let withdrawn = act == .dismiss && (failure as? AnnouncementError) == .gone
        if let failure, !withdrawn {
            pages[host]?.missed[id] = act.missed
            session.said.announce(AnnouncementsSaid.missed(act.missed, source.host))
            return
        }
        switch act {
        case .dismiss: pages[host]?.dismissedHere.insert(id)
        case .react(let reaction, let wanted):
            pages[host]?.turned[Named(id: id, name: reaction)] = Turned(wanted: wanted, since: errands.next())
        }
    }
}
