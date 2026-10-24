import FediqoCore
import Foundation
import Observation

// A link rising on the sources, opened as the posts that share it (#379): what is asked, when,
// and what the page holds of the answers.
//
// **Offered only where a source says it can.** A link's row opens its posts where some source
// that named it rising says, in its own document, that it lists the posts sharing a link
// (`MastodonHostThing.linkPosts`) — and is asked of those sources alone. Where none does — an
// older server, one whose document has not come, one whose address answered that it is not
// there — the row opens the link's page, as it always did, and nothing else is offered. On the
// page, the link's own page is one press away (`SharedLinkHead`).
//
// **Asked as the page opens, and read on as any timeline is.** Opening asks each source for its
// newest stretch, once a run; reaching the foot of the list reads the next stretch of every
// source that named one, as reaching the end of a timeline does, and the foot's press does the
// same — and asks again a stretch that did not come. `r`, the bar's mark and a pull ask every
// source from its top; a press while a source is asked asks it nothing, and Stop calls the
// page's asks from the top off. Nothing is asked while the page is not open, and nothing by itself.
//
// **What comes lands in the store first** (#296), an item like any other — as what a hashtag's
// page brings: it stands in All, and in no timeline made of a category. The page draws what
// this device holds of what each source listed, newest first, a post two sources listed once;
// a post the store would not take is not drawn. **Every answer lands only where it is still the
// one awaited**: each ask is numbered on the pages' one count, and an answer to an ask stopped,
// or asked again since, is held nowhere and changes nothing here.
//
// **A source that lists no posts of this link says so** — the link no longer rising there, or
// its address gone since its document said — at the foot of the list, and the others' stand.

/// A rising link, opened as the posts that share it: the link as the first source named it, and
/// the sources asked — each that named it rising and says it lists them, in the order they
/// named it.
struct SharedLink: Hashable, Sendable, Identifiable {
    let link: RisingLink
    let sources: [String]

    var id: String { link.link.url.absoluteString }
}

/// What the page of a rising link's posts is handed.
struct SharedLinkSaid: Equatable {
    let page: SharedLink
    /// What this device holds of what the sources listed, newest first.
    var items: [DummyItem] = []
    /// What stands where rows would, and under them: each source that lists none of it, or gave none.
    var quiet: [String] = []
    var foot: PersonSaid.Foot?

    /// The sources whose foot this is: those asked.
    var footWords: String? {
        foot.map { $0.words(page.sources.joined(separator: ", ")) }
    }
}

/// The posts that share each rising link opened this run, by link and source.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellSharedLinks {
    /// One source's reading of one link.
    private struct Reading {
        let host: String
        var read = PostsRead()
        /// Whether a stretch has answered.
        var answered = false
        /// Whether the newest stretch is on the wire.
        var asking = false
        var readingOn = false
        /// The last stretch did not come.
        var failed = false
        /// The source refused to say (422): said at the foot, as a stretch that did not come.
        var refused = false
        /// A reading-on was stopped: the foot waits for a press, and asks nothing by itself.
        var held = false
        /// The source lists no posts of this link.
        var unlisted = false
        /// The source stopped handing its posts on in order: its list ends where it is.
        var notPaging = false
        /// The number of the ask whose answer this reading awaits.
        var awaits = 0

        /// Whether a reading-on may be asked of it: a next named, or a stretch after the first
        /// that did not come, and nothing on the wire.
        var readsOn: Bool {
            !asking && !readingOn && !unlisted && !notPaging && answered && (read.next != nil || failed)
        }

        /// Whether reaching the foot reads it on by itself: **only after a stretch that came**,
        /// with a next named, and not after a stop. After a failure or a stop the foot waits
        /// for a press — otherwise a source that fails would be asked again each time the foot
        /// comes back into view, with no wait between and nothing to stop it.
        var reachesOn: Bool { readsOn && !failed && !held && read.next != nil }
    }

    private var readings: [String: Reading] = [:]
    /// The pages whose last ask from the top was stopped, until they are asked again.
    private var halted: Set<String> = []
    /// The asks on the wire, by link and source.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    /// The rows last built of each page, and what they were built from.
    @ObservationIgnored private var built: [String: (key: Built, items: [DummyItem])] = [:]
    @ObservationIgnored private let errands: PageErrands
    /// What this run knows each host has: whether it lists a link's posts, and where its own
    /// address answered that it does not.
    @ObservationIgnored let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a host's posts of a link, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((String) -> MastodonLinkPosts)?

    private struct Built: Equatable {
        let keys: [NoteKey]
        let notes: Int
        let hosts: Set<String>
    }

    init(errands: PageErrands, hosts: ShellHostsKnown) {
        self.errands = errands
        self.hosts = hosts
    }

    private static func key(_ page: SharedLink, _ host: String) -> String { "\(page.id)\u{1e}\(host)" }

    // MARK: - Whether a link opens its posts

    /// The page a press on `listed` opens, where it is a link some source that named it says it
    /// lists the posts of; nothing otherwise, and then the press opens the link's page.
    func page(opening listed: RisingListed, in session: ShellSession) -> SharedLink? {
        guard case .link(let link, _) = listed.row else { return nil }
        let sources = listed.sources.filter { host in
            ShellPersonPages.source(at: host, in: session) != nil && hosts.has(.linkPosts, at: host) == .present
        }
        return sources.isEmpty ? nil : SharedLink(link: link, sources: sources)
    }

    /// Each of `hosts` heard, where this run has not had its document: what says whether a link
    /// of it opens its posts. Asked once a run a host, as Links comes in front.
    func hear(_ hosts: [String], in session: ShellSession) async {
        await withTaskGroup(of: Void.self) { group in
            for host in unheard(hosts) {
                group.addTask { await self.hosts.hear(host, in: session) }
            }
        }
    }

    /// Those of `hosts` whose document this run has not had, or has let go.
    func unheard(_ hosts: [String]) -> [String] {
        hosts.filter { !self.hosts.heard($0) }
    }

    // MARK: - What the page is handed

    private func readings(of page: SharedLink) -> [Reading] {
        page.sources.compactMap { readings[Self.key(page, $0)] }
    }

    /// Every post the sources listed of `page`, and what those boost: drawn from the store's
    /// copy, and so kept in its pool while the page is open (#359).
    func keys(of page: SharedLink) -> Set<NoteKey> {
        Set(readings(of: page).flatMap { $0.read.posts.map(\.key) + $0.read.carried.map(\.key) })
    }

    /// The rows of `page`: what this device holds of each post listed, newest first, a post
    /// two sources listed one row. Built once for what was read and what is held, and kept.
    func items(of page: SharedLink, in session: ShellSession) -> [DummyItem] {
        let keys = readings(of: page).flatMap { $0.read.posts.map(\.key) }
        let here = Set(session.sources.map(\.host))
        let key = Built(keys: keys, notes: session.notesRevision, hosts: here)
        if let rows = built[page.id], rows.key == key { return rows.items }
        let notes = keys.compactMap { session.heldNote(key: $0) }.sorted { $0.postedAt > $1.postedAt }
        let items = DummyItem.merged(notes, here: here, targets: session.reblogTargets)
        built[page.id] = (key, items)
        return items
    }

    /// The rows `j` and `k` walk on `page`, top to bottom.
    func walked(_ page: SharedLink, in session: ShellSession) -> [String] {
        items(of: page, in: session).map(\.id)
    }

    func said(of page: SharedLink, in session: ShellSession, language: DummyLanguage? = nil) -> SharedLinkSaid {
        let readings = readings(of: page)
        let quiet = readings.compactMap { reading -> String? in
            if reading.unlisted { return String(format: L10n.t("shared.unlisted", language: language), reading.host) }
            if reading.refused, !reading.asking, !reading.readingOn {
                return String(format: L10n.t("shared.refused", language: language), reading.host)
            }
            guard reading.answered, reading.read.posts.isEmpty, !reading.asking else { return nil }
            return String(format: L10n.t("shared.none", language: language), reading.host)
        }
        return SharedLinkSaid(page: page, items: items(of: page, in: session), quiet: quiet, foot: Self.foot(of: readings))
    }

    /// What stands under the posts: **nothing while a stretch is on the wire, or before any
    /// source has answered** — the wait and a miss are the toast's to say — a press that reads on where any
    /// source has more or missed a stretch, the end where every source has sent all it gives,
    /// and that the list stops where a source stopped handing its posts on in order.
    private static func foot(of readings: [Reading]) -> PersonSaid.Foot? {
        guard !readings.contains(where: { $0.asking || $0.readingOn }) else { return nil }
        let answered = readings.filter { $0.answered && !$0.unlisted }
        if answered.contains(where: \.readsOn) { return .more }
        if answered.contains(where: \.notPaging) { return .stopped }
        return answered.contains(where: { !$0.read.posts.isEmpty }) ? .end : nil
    }

    /// What the page says in its toast (DESIGN-reload): the sources asked from the top, or that
    /// it reads on — each a wait Stop stops; those whose last stretch did not come; and that the
    /// last ask was stopped.
    func ask(of page: SharedLink, language: DummyLanguage? = nil) -> PageAsking {
        let readings = readings(of: page)
        let asking = readings.filter(\.asking).map(\.host).sorted()
        let readingOn = readings.contains(where: \.readingOn)
        return PageAsking(
            asking: TimelineToast.waiting("shared.asking", hosts: asking, extra: [page.link.link.host], language: language)
                ?? (readingOn ? L10n.t("person.foot.reading", language: language) : nil),
            stoppable: !asking.isEmpty || readingOn,
            failed: readings.filter { $0.failed && !$0.asking && !$0.readingOn }.map(\.host),
            stopped: halted.contains(page.id)
        )
    }

    /// Whether `page` has anybody to ask again — what `r` and its mark go by: a source it is of
    /// still here. Still true while its asks are out, as every page's is.
    func canAskAgain(_ page: SharedLink, in session: ShellSession) -> Bool {
        page.sources.contains { ShellPersonPages.source(at: $0, in: session) != nil }
    }

    /// The page's Stop, and `Escape` on it: every source asked — from the top, or reading on —
    /// called off, what it listed before standing, and whatever is on the wire landing nowhere. A
    /// reading-on stopped holds its foot until it is pressed. A stop is never a failure. Whether
    /// anything was stopped.
    @discardableResult
    func stop(_ page: SharedLink) -> Bool {
        var stopped = false
        for host in page.sources {
            let key = Self.key(page, host)
            guard let reading = readings[key], reading.asking || reading.readingOn else { continue }
            asks[key]?.cancel()
            asks[key] = nil
            readings[key]?.awaits = errands.next()
            if reading.readingOn { readings[key]?.held = true }
            readings[key]?.asking = false
            readings[key]?.readingOn = false
            stopped = true
        }
        if stopped { halted.insert(page.id) }
        return stopped
    }

    // MARK: - Asking

    /// The page opening: each source not yet answered asked for its newest stretch. **Once a
    /// run**: opened again it is drawn from what was held; a source on the wire is waited on and
    /// asked nothing more; one whose ask was stopped, or came to nothing, is asked.
    func opened(_ page: SharedLink, in session: ShellSession) async {
        var waited: [Task<Void, Never>] = []
        for host in page.sources where ShellPersonPages.source(at: host, in: session) != nil {
            let key = Self.key(page, host)
            if let reading = readings[key] {
                if reading.asking || reading.readingOn {
                    if let running = asks[key] { waited.append(running) }
                    continue
                }
                if reading.answered || reading.unlisted { continue }
            }
            waited.append(begin(page, at: host, fromTop: true, in: session))
        }
        for task in waited { await task.value }
    }

    /// `r`, the mark and a pull: every source asked from its top again. What it listed stays
    /// drawn until the answer lands. **A press while a source is asked asks it nothing.**
    func again(_ page: SharedLink, in session: ShellSession) async {
        var waited: [Task<Void, Never>] = []
        for host in page.sources where ShellPersonPages.source(at: host, in: session) != nil {
            if readings[Self.key(page, host)]?.asking == true { continue }
            waited.append(begin(page, at: host, fromTop: true, in: session))
        }
        for task in waited { await task.value }
    }

    /// The foot pressed — `pressed` — or reached: the next stretch of every source that named
    /// one, and, pressed, again the stretch that did not come or was stopped. Reached, only a
    /// source whose last stretch came reads on (`reachesOn`). One at a time a source, and none
    /// while it is asked from its top.
    func readOn(_ page: SharedLink, pressed: Bool, in session: ShellSession) async {
        var waited: [Task<Void, Never>] = []
        for host in page.sources where ShellPersonPages.source(at: host, in: session) != nil {
            let key = Self.key(page, host)
            guard let reading = readings[key], pressed ? reading.readsOn : reading.reachesOn else { continue }
            readings[key]?.held = false
            waited.append(begin(page, at: host, fromTop: false, after: reading.read.next, in: session))
        }
        for task in waited { await task.value }
    }

    /// Starts one source's ask — from its top, or read on after `next` — and hands back the task
    /// it runs in. Everything it needs is taken here, before anything waits: the host, the door,
    /// the number its answer is awaited by.
    private func begin(
        _ page: SharedLink, at host: String, fromTop: Bool, after next: String? = nil, in session: ShellSession
    ) -> Task<Void, Never> {
        let key = Self.key(page, host)
        if readings[key] == nil { readings[key] = Reading(host: host) }
        let errand = errands.next()
        readings[key]?.awaits = errand
        if fromTop {
            readings[key]?.asking = true
            // A reading-on still on the wire is this ask's to supersede: its answer will not land.
            readings[key]?.readingOn = false
            readings[key]?.held = false
        } else {
            readings[key]?.readingOn = true
        }
        halted.remove(page.id)
        readings[key]?.failed = false
        readings[key]?.refused = false
        let name = SourceWork.Name.called(RisingSaid.called(page.link))
        let through = reaching?(host)
            ?? session.mastodon.authorized(host: host, within: deadline, for: .timeline, name: name).map { session.reach.linkPosts($0) }
            ?? session.reach.unsignedLinkPosts(host, name: name, within: deadline)
        let stamp = Source(host: host, kind: session.sources.first { $0.host == host }?.kind ?? .mastodon)
        let round = hosts.round(at: host)
        let link = page.link.link
        let task = Task {
            await self.ask(key, of: link, through: through, from: stamp, after: next, errand: errand, round: round, in: session)
        }
        asks[key] = task
        return task
    }

    private func ask(
        _ key: String, of link: PostLink, through: MastodonLinkPosts, from source: Source, after next: String?,
        errand: Int, round: Int, in session: ShellSession
    ) async {
        defer { if readings[key]?.awaits == errand { asks[key] = nil } }
        do {
            let stretch = try await through.posts(sharing: link, source: source, after: next)
            guard readings[key]?.awaits == errand, let held = readings[key]?.read else { return }
            // Read first and written after: the two are not one access.
            let further = next == nil ? held.renewed(by: stretch) : try held.readingOn(stretch)
            await session.store.ingest(stretch.posts + stretch.carried, ifSourceHere: source.host)
            // A stop, or an ask begun since, while the store took them: what it took is an item
            // like any other, and this page's reading is the newer ask's.
            guard readings[key]?.awaits == errand else { return }
            readings[key]?.read = further
            readings[key]?.answered = true
            readings[key]?.unlisted = false
            readings[key]?.refused = false
            readings[key]?.notPaging = false
            session.saveSoon()
            await session.reloadFromStore()
        } catch {
            guard readings[key]?.awaits == errand else { return }
            switch error {
            case LinkPostsError.notListed:
                readings[key]?.unlisted = true
            case MastodonHostMoreError.noSuchAddress:
                // The host's own word that the address is not there: not offered there again this run.
                hosts.notFound(.linkPosts, at: source.host, round: round)
                readings[key]?.unlisted = true
            case is PagingError:
                readings[key]?.notPaging = true
            case MastodonRequestError.http(422), MastodonAuthError.http(422):
                // Refused, not "lists none": the source may give it to somebody signed in.
                readings[key]?.refused = true
                readings[key]?.failed = true
            case MastodonAuthError.signedOut:
                session.mastodon.endedByServer(host: source.host)
                readings[key]?.failed = true
            default:
                if !Cancellation.happened(error) { readings[key]?.failed = true }
            }
        }
        readings[key]?.asking = false
        readings[key]?.readingOn = false
    }

    /// What was asked of `host` let go, and its asks called off: the source is gone, or who
    /// reads it changed, and what it listed is asked afresh when its page is next opened.
    func letGo(at host: String) {
        for (key, reading) in readings where reading.host == host {
            asks[key]?.cancel()
            asks[key] = nil
            readings[key] = nil
        }
        built = [:]
    }
}
