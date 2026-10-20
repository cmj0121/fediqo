import FediqoCore
import Foundation
import Observation

// The tabs of somebody's page (F9): which tabs a page has, which is in front, where each
// tab's lamp stands, and what they pinned — what is asked for it, and when.
//
// **Which tabs a page has is decided here, and by nothing that draws.** A source that does not
// say who people are — a forum — has their posts alone, and then no strip is drawn. One that
// does has About and Posts until it has said who they are, and for good where it has not heard
// of them, could not be asked, or suspended them; once it has said, whom they follow, who
// follows them and what they pinned arrive between the two. **A list the account says it hides
// has no tab** — absent, never grey — and on the reader's own page both are always there: a
// source gives a reader their own lists. Pinned is a tab wherever the two lists could be:
// whether anything is pinned is not known until it is asked.
//
// **The tab in front, and each tab's lamp, are kept with the page — by who they are, and not
// in the step of the walk**: a tab is not a step, leaving never passes through another tab,
// and somebody met twice in one walk is one page, on the tab it was left on. About is in front
// on opening.
//
// **A tab asks when it is first in front, and never before** (`ShellPersonPages.fronted`): a
// tab never brought in front costs its source nothing. About asks nothing; their posts and
// what they pinned ask one stretch; a list of people its first stretch and how the reader
// stands to those people (`ShellPeoplePages`). Brought in front again, a tab is drawn from
// what was answered.
//
// **What they pinned is asked as their posts are** — numbered on the one count, landing only
// where its number is still the one awaited, as whoever asked, let go with their sign-in, and
// held nowhere (`ShellPersonPages` gives each reason). **In the source's own order**, never
// sorted. **A source with no such thing is written down for the run** (`ShellHostsKnown`):
// the tab says the source gave none, and that host is not asked for it again.

/// The tabs of every person's page opened this run, by who they are.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellPersonTabs {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// What somebody pinned, as far as the tab has read it.
    private struct Pinned {
        let host: String
        /// The id the source knows them by: whose posts were asked for.
        let accountID: String
        var askedAs: AskedAs
        /// How often the sign-in at its host had become another when it was asked.
        let under: Int
        var read = PostsRead()
        var answered = false
        /// Whether the posts are being asked for from the top.
        var asking = false
        /// Whether asking from the top last came to a failure.
        var failed = false
        var readingOn = false
        var footFailed = false
        /// The source stopped handing the posts on in order: the list ends where it is.
        var notPaging = false
        /// The number of the ask or the reading-on whose answer this tab awaits.
        var awaits = 0
    }

    /// The tab in front on each page, where it is not the page's first.
    private var fronts: [String: PersonTab] = [:]
    /// Where the lamp stood on each tab of each page when the tab was left. Not observed: it
    /// is read only as a tab is brought in front.
    @ObservationIgnored private var lamps: [String: [PersonTab: String]] = [:]
    private var pinned: [String: Pinned] = [:]
    /// The pages whose last ask for what they pinned was stopped, until it is asked again.
    private var halted: Set<String> = []
    @ObservationIgnored private var built = PageRows()
    /// The one ask on the wire for what each person pinned — from the top, or a reading-on.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// What this run knows each host has: where a source with no pinned posts is written down.
    @ObservationIgnored private let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    // MARK: - Which tabs, and which is in front

    /// The tabs of the page of `who`, in the order they stand, given what their source said —
    /// `said`, or nothing where it is not asked who people are — and whether the page is the
    /// reader's own.
    static func tabs(said: PersonSaid?, own: Bool) -> [PersonTab] {
        guard let said else { return [.posts] }
        guard let person = said.person, !person.suspended else { return [.about, .posts] }
        let lists: [PersonTab] = own || !person.hidesLists ? [.following, .followers] : []
        return [.about] + lists + [.pinned, .posts]
    }

    /// The tabs of the page of `who`, as it stands for whoever would ask now.
    static func tabs(of who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> [PersonTab] {
        // Whether their source says who people are is read where a page's source is found.
        guard ShellPersonPages.source(of: who, in: session) != nil else { return tabs(said: nil, own: false) }
        return tabs(said: said, own: ShellPersonPages.own(at: who.host, in: session)?.id == who.id)
    }

    /// The tab in front on the page `id` names, among the tabs it has: the one last brought in
    /// front where the page still has it, and its first otherwise — About, on any page that
    /// has one.
    func front(of id: String, among tabs: [PersonTab]) -> PersonTab {
        fronts[id].flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .posts
    }

    /// Brings `tab` in front on the page `id` names: the lamp is written down for the tab
    /// left, and is the one `tab` was left with. Whether anything changed — a tab the page
    /// has not, and the one already in front, change nothing.
    func turn(_ id: String, to tab: PersonTab, among tabs: [PersonTab], lamp: inout String?) -> Bool {
        let from = front(of: id, among: tabs)
        guard tabs.contains(tab), tab != from else { return false }
        lamps[id, default: [:]][from] = lamp
        fronts[id] = tab
        lamp = lamps[id]?[tab]
        return true
    }

    /// The walk has left the page `id` names: which tab was in front, and each tab's lamp,
    /// are forgotten — opened afresh it opens on its first tab, About. What its tabs read
    /// is kept with the page, as before.
    func left(_ id: String) {
        fronts[id] = nil
        lamps[id] = nil
    }

    /// The walk has ended in one go: every page's tab in front is forgotten — but those of the
    /// pages `kept` names, still steps of the other stream place's walk.
    func leftAll(but kept: Set<String> = []) {
        fronts = fronts.filter { kept.contains($0.key) }
        lamps = lamps.filter { kept.contains($0.key) }
    }

    /// Everything kept of the page `id` names let go: it is no longer one of the pages kept.
    func forget(_ id: String) {
        fronts[id] = nil
        lamps[id] = nil
        forgetPinned(id)
    }

    /// Everything of `host` that was a reader's let go, and its asks called off: that reader
    /// is no longer who asks (`PageReaders`). **Which tab is in front stays**: it is the
    /// person's, whoever reads.
    func letGo(at host: String) {
        for (id, page) in pinned where page.host == host { forgetPinned(id) }
    }

    // MARK: - What they pinned

    /// What the page `id` names held of what they pinned let go, and its ask called off: it is
    /// asked for when the tab is next in front.
    func forgetPinned(_ id: String) {
        asks[id]?.cancel()
        asks[id] = nil
        pinned[id] = nil
        built.forget(id)
    }

    /// The pinned posts of `who` as their page read them, for whoever holds or opens one —
    /// **as it stands for whoever would ask now**, and nothing where it was read as somebody
    /// else: a post another reader was given is not this one's to hold.
    func pinnedRead(of who: DummyPerson, beside said: PersonSaid?, in session: ShellSession) -> PostsRead? {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session) else { return nil }
        return self.standing(who.id, of: person.accountID, at: source.host, in: session)?.read
    }

    /// What is held of what the account `accountID` names pinned, **for whoever would ask now**.
    private func standing(_ id: String, of accountID: String, at host: String, in session: ShellSession) -> Pinned? {
        pinned[id].flatMap { page in
            page.accountID == accountID && page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    /// What the Pinned tab of the page of `who` is handed, or nothing until their source has
    /// said who they are.
    func said(of who: DummyPerson, beside said: PersonSaid?, in session: ShellSession) -> PersonPinnedSaid? {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session) else { return nil }
        var handed = PersonPinnedSaid(source: source.host)
        // A source with no such thing gave none, and is not asked again this run.
        if hosts.has(.pinnedPosts, at: source.host) == .absent {
            handed.answered = true
            return handed
        }
        guard let page = self.standing(who.id, of: person.accountID, at: source.host, in: session) else { return handed }
        handed.answered = page.answered
        handed.posts = page.answered ? built.rows(of: who.id, page.read, in: session) : []
        handed.foot = Self.foot(of: page)
        return handed
    }

    /// What stands under what they pinned. **Nothing while a stretch is on the wire**, and a
    /// stretch that did not come is the foot that reads on again: both are the toast's to say.
    private static func foot(of page: Pinned) -> PersonSaid.Foot? {
        guard page.answered, !page.readingOn else { return nil }
        if page.notPaging { return .stopped }
        if page.read.next != nil { return .more }
        // Nothing under no posts: what stands there says the source gave none.
        return page.read.posts.isEmpty ? nil : .end
    }

    /// What the Pinned tab of the page of `who` says in its toast (DESIGN-reload): asked from the
    /// top — a wait Stop stops — or read on, which is not; that the last ask did not come; or
    /// that it was stopped.
    func ask(
        of who: DummyPerson, beside said: PersonSaid?, in session: ShellSession, language: DummyLanguage? = nil
    ) -> PageAsking {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session),
              let page = self.standing(who.id, of: person.accountID, at: source.host, in: session)
        else { return PageAsking() }
        let asking = page.asking
            ? TimelineToast.waiting("person.pinned.asking", hosts: [source.host], language: language)
            : page.readingOn ? L10n.t("person.foot.reading", language: language) : nil
        return PageAsking(
            asking: asking, stoppable: page.asking,
            failed: !page.asking && !page.readingOn && (page.failed || page.footFailed) ? [source.host] : [],
            stopped: halted.contains(who.id)
        )
    }

    /// The Pinned tab's Stop: the ask from the top for what the page `id` names pinned called
    /// off, what the tab held standing, and whatever is on the wire landing nowhere. A
    /// reading-on is not stopped. Whether anything was.
    @discardableResult
    func stopPinned(_ id: String) -> Bool {
        guard pinned[id]?.asking == true else { return false }
        asks[id]?.cancel()
        asks[id] = nil
        pinned[id]?.awaits = errands.next()
        pinned[id]?.asking = false
        halted.insert(id)
        return true
    }

    /// The Pinned tab of the page of `who` in front: what they pinned is asked for, once.
    /// Brought in front again it is drawn from what was answered — or from the failure, which
    /// `r` asks about; while the ask is on the wire it is waited on. `again` is the
    /// person's own press: asked from the top whatever was answered, with what the tab holds
    /// drawn until the answer lands. **A press while it is being asked asks nothing.**
    func asked(_ who: DummyPerson, beside said: PersonSaid?, again: Bool, in session: ShellSession) async {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        guard hosts.has(.pinnedPosts, at: source.host) != .absent else { return }
        let id = who.id
        if let page = self.standing(id, of: person.accountID, at: source.host, in: session) {
            if page.asking {
                await asks[id]?.value
                return
            }
            if !again, page.answered || page.failed { return }
        } else {
            // Nobody's yet, or another reader's: what was given to them is not given to this one.
            forgetPinned(id)
            pinned[id] = Pinned(
                host: source.host, accountID: person.accountID, askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
                under: ShellPersonPages.signIns(at: source.host, in: session)
            )
        }
        let errand = errands.next()
        pinned[id]?.awaits = errand
        pinned[id]?.asking = true
        halted.remove(id)
        // A reading-on still on the wire is this ask's to supersede: it is called off, so one
        // ask is out, and whatever it brings late does not land.
        asks[id]?.cancel()
        pinned[id]?.readingOn = false
        let through = self.door(to: source, with: held, in: session)
        let askedAs = pinned[id]?.askedAs ?? .nobody
        let round = hosts.round(at: source.host)
        let accountID = person.accountID
        let task = Task {
            await self.ask(id, of: accountID, through: through, at: source, as: askedAs, errand: errand, round: round, in: session)
        }
        asks[id] = task
        await task.value
    }

    private func ask(
        _ id: String, of accountID: String, through: MastodonPerson, at source: Source, as askedAs: AskedAs, errand: Int,
        round: Int, in session: ShellSession
    ) async {
        defer { if pinned[id]?.awaits == errand { asks[id] = nil } }
        do {
            let first = try await through.pinned(of: accountID, source: source)
            guard pinned[id]?.awaits == errand else { return }
            guard let first else {
                // The source has no such thing: written down for the run, and nothing is kept.
                hosts.notFound(.pinnedPosts, at: source.host, round: round)
                pinned[id] = nil
                asks[id] = nil
                built.forget(id)
                return
            }
            // From the top: what was read before is replaced whole, in the order it came.
            pinned[id]?.read = PostsRead().renewed(by: first)
            pinned[id]?.answered = true
            pinned[id]?.failed = false
            pinned[id]?.footFailed = false
            pinned[id]?.notPaging = false
        } catch {
            guard pinned[id]?.awaits == errand else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                // What it gave before stands: a failure takes nothing away.
                pinned[id]?.failed = true
            }
        }
        pinned[id]?.asking = false
    }

    /// The foot's press under what they pinned: the stretch after what the tab holds, by the
    /// place the source named, or a stretch that did not come asked for again. One at a time,
    /// and none while the posts are being asked for from the top.
    ///
    /// **Pressed by a reader the posts were not given to, it reads nothing on**: they are let
    /// go, and asked for afresh as them when the tab next asks.
    func readOn(_ who: DummyPerson, beside said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session) else { return }
        let looked = readers.look(at: source.host, in: session)
        let id = who.id
        guard !looked.changed,
              let page = self.standing(id, of: person.accountID, at: source.host, in: session),
              page.answered, !page.readingOn, !page.asking, !page.notPaging, let next = page.read.next
        else { return }
        let errand = errands.next()
        pinned[id]?.awaits = errand
        pinned[id]?.readingOn = true
        halted.remove(id)
        pinned[id]?.footFailed = false
        let through = self.door(to: source, with: looked.held, in: session)
        let accountID = person.accountID, askedAs = page.askedAs
        let task = Task {
            do {
                let stretch = try await through.pinned(of: accountID, source: source, after: next)
                guard self.pinned[id]?.awaits == errand, let held = self.pinned[id]?.read else { return }
                // A source that answers a later stretch with something else has stopped.
                guard let stretch else { throw PagingError.notPaging }
                let further = try held.readingOn(stretch)
                self.pinned[id]?.read = further
            } catch {
                guard self.pinned[id]?.awaits == errand else { return }
                if error is PagingError {
                    self.pinned[id]?.notPaging = true
                } else if !Cancellation.happened(error) {
                    ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                    self.pinned[id]?.footFailed = true
                }
            }
            self.pinned[id]?.readingOn = false
            if self.pinned[id]?.awaits == errand { self.asks[id] = nil }
        }
        asks[id] = task
        await task.value
    }

    /// The door to `source`, as a person's page has it: as the reader where they are signed
    /// in to it, and with no token — listed, bounded, and under the small body's ceiling —
    /// where they are not.
    private func door(to source: Source, with held: MastodonToken?, in session: ShellSession) -> MastodonPerson {
        if let held {
            return session.reach.person(session.mastodon.authorized(token: held, within: deadline, for: .person))
        }
        return session.reach.unsignedPerson(source.host, for: .person, within: deadline)
    }
}

extension ShellPersonPages {
    // MARK: - The tabs of a page

    /// The tabs of the page of `who`, as it stands for whoever would ask now.
    func tabs(of who: DummyPerson, in session: ShellSession) -> [PersonTab] {
        ShellPersonTabs.tabs(of: who, said: said(of: who, in: session), in: session)
    }

    /// The tab in front on the page of `who`.
    func front(of who: DummyPerson, in session: ShellSession) -> PersonTab {
        tabs.front(of: who.id, among: tabs(of: who, in: session))
    }

    /// A tab pressed, or the figure that counts it: brought in front, each tab keeping its
    /// own lamp. Whether anything changed.
    @discardableResult
    func turn(_ who: DummyPerson, to tab: PersonTab, lamp: inout String?, in session: ShellSession) -> Bool {
        tabs.turn(who.id, to: tab, among: tabs(of: who, in: session), lamp: &lamp)
    }

    /// Tab and ⇧Tab on the page of `who`: the tab beside, round the ring. Nothing on a page
    /// with one tab — it has no strip, and the key is not the timelines' while a page is in
    /// front.
    func rotate(_ who: DummyPerson, by step: Int, lamp: inout String?, in session: ShellSession) -> Bool {
        let all = tabs(of: who, in: session)
        guard all.count > 1 else { return false }
        let to = DummyCommand.advanced(all, from: tabs.front(of: who.id, among: all), by: step)
        return tabs.turn(who.id, to: to, among: all, lamp: &lamp)
    }

    /// A step of the walk was left. **The tab in front is kept while the page's step is in
    /// the walk, and forgotten when the walk leaves it** — so stepping from somebody's page
    /// into somebody else and back keeps the tab, and a page opened afresh opens on About.
    /// Somebody met twice in one walk is one page: theirs is forgotten when the last of
    /// their steps goes.
    ///
    /// **A hashtag's page keeps its tab the same way** (F10), and forgets it with the last of
    /// its steps. **And what a search found its tabs' lamps** — the tab in front is the step's
    /// own. **`besides` is the other stream place's walk** (DESIGN-trends): a page still one of
    /// its steps keeps its tab there.
    func left(_ step: ShellStep, of walk: ShellWalk, besides other: ShellWalk = ShellWalk()) {
        if case .tag(let tag) = step, !walk.holdsTag(tag), !other.holdsTag(tag) { tags.left(tag) }
        if case .found = step, !other.steps.contains(where: \.isFound) { found.left() }
        guard case .person(let who) = step, !walk.holdsPerson(who.id), !other.holdsPerson(who.id) else { return }
        tabs.left(who.id)
    }

    /// A walk ended in one go — `keeping` the hashtag's page left standing on it, where one is
    /// (#197) — with `other`, the other stream place's walk, still as it was: every page's tab
    /// in front forgotten but those still steps of `other`.
    func leftAll(keeping kept: PostTag? = nil, besides other: ShellWalk = ShellWalk()) {
        tabs.leftAll(but: Set(other.steps.compactMap { step in
            if case .person(let who) = step { return who.id }
            return nil
        }))
        tags.leftAll(but: [kept].compactMap { $0 } + other.steps.compactMap { step in
            if case .tag(let tag) = step { return tag }
            return nil
        })
        if !other.steps.contains(where: \.isFound) { found.left() }
    }

    // MARK: - What each part of the page is handed

    /// The head of the page of `who`.
    func head(of who: DummyPerson, in session: ShellSession) -> PersonHeadSaid {
        var head = PersonHeadSaid.made(
            of: who, said: said(of: who, in: session), tabs: tabs(of: who, in: session),
            held: session.heldPosts(of: who).count, heldAtLeast: session.heldAtLeast, standing: stands(to: who, in: session)
        )
        head.change = changeEntry(of: who, in: session)
        return head
    }

    /// What the About tab of the page of `who` is handed, or nothing where their source is not
    /// asked who people are: such a page has no About.
    func about(of who: DummyPerson, in session: ShellSession) -> PersonAboutSaid? {
        guard let said = said(of: who, in: session) else { return nil }
        let hidden = said.person.map { person in
            person.hidesLists && !person.suspended && !tabs(of: who, in: session).contains(.following)
        } ?? false
        let home = homeSaid(of: who, in: session)
        var about = PersonAboutSaid.made(
            of: said, home: home, homeLine: homeLine(of: who, in: session),
            standing: stands(to: who, in: session), followed: followedEntry(of: who, in: session), hidden: hidden,
            requests: requestsEntry(of: who, in: session)
        )
        // What they feature is the added source's: not drawn while their own server's word is.
        if home == nil { about.featured = featured(of: who, in: session) }
        about.keeping = keepingEntries(of: who, in: session)
        return about
    }

    /// What `who` features on their profile (#315, #318), as About is handed it.
    func featured(of who: DummyPerson, in session: ShellSession) -> FeaturedSaid? {
        features.said(of: who, said: said(of: who, in: session), own: Self.own(at: who.host, in: session)?.id == who.id, in: session)
    }

    /// Which opening the asking of what `who` features is, or nothing where nobody is asked.
    func featuredOpening(of who: DummyPerson, in session: ShellSession) -> ShellFeatures.Opening? {
        features.opening(who, said: said(of: who, in: session), in: session)
    }

    /// The page of `who` has said who they are: what they feature is asked (B7).
    func featuredOpened(_ who: DummyPerson, in session: ShellSession) async {
        await features.opened(who, said: said(of: who, in: session), in: session)
    }

    /// The way to the people who ask to follow the reader (#313), where the page of `who` is
    /// their own at a source where somebody is followed — once it has said who they are, and
    /// not while the page draws what their own server says: as the way to the hashtags they
    /// follow is. Where the sign-in does not see who follows them, the line is its lock.
    func requestsEntry(of who: DummyPerson, in session: ShellSession) -> RequestsEntry? {
        let said = said(of: who, in: session)
        guard said?.person != nil, home.said(of: who, beside: said, in: session) == nil,
              let source = Self.source(of: who, in: session), ShellPersonActs.offersFollowing(source),
              Self.own(at: who.host, in: session)?.id == who.id
        else { return nil }
        let place = session.mastodon.place(.follows, host: who.host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
        // The source's own check said nobody asks: no line, and nothing for the lamp to stop on.
        let counted = session.mastodon.asking(host: who.host)
        if counted == 0 { return nil }
        return RequestsEntry(
            list: PeopleList(requestsAt: source.host), counted: counted,
            locked: ShellPersonActs.sees(at: who.host, in: session) ? nil : place
        )
    }

    /// The ways to whom the reader mutes and blocks, and the servers they block (#314), where the
    /// page of `who` is their own at a source where somebody is muted and blocked — once it has
    /// said who they are, and not while the page draws what their own server says. Where the
    /// sign-in does not see them, the one lock in their place.
    func keepingEntries(of who: DummyPerson, in session: ShellSession) -> [KeepingEntry] {
        let said = said(of: who, in: session)
        guard said?.person != nil, home.said(of: who, beside: said, in: session) == nil,
              let source = Self.source(of: who, in: session), source.kind.offers.blocks,
              Self.own(at: who.host, in: session)?.id == who.id
        else { return [] }
        guard ShellPersonActs.seesBlocks(at: who.host, in: session) else {
            let place = session.mastodon.place(.blocks, host: who.host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
            return [KeepingEntry(which: .muted, host: source.host, locked: place)]
        }
        return KeepingEntry.Which.allCases.map { KeepingEntry(which: $0, host: source.host) }
    }

    /// The list of people `tab` is on the page of `who`, where it is one and the page has it.
    func list(_ tab: PersonTab, of who: DummyPerson, in session: ShellSession) -> PeopleList? {
        guard let which = tab.list, tabs(of: who, in: session).contains(tab),
              let person = said(of: who, in: session)?.person
        else { return nil }
        return PeopleList(which, of: person)
    }

    /// What the Pinned tab of the page of `who` is handed.
    func pinned(of who: DummyPerson, in session: ShellSession) -> PersonPinnedSaid? {
        tabs.said(of: who, beside: said(of: who, in: session), in: session)
    }

    /// The foot's press under what they pinned.
    func pinnedReadOn(_ who: DummyPerson, in session: ShellSession) async {
        await tabs.readOn(who, beside: said(of: who, in: session), in: session)
    }

    // MARK: - What the keys walk

    /// The posts `j` and `k` walk on the page of `who`, and a mark's key acts on: the rows of
    /// the tab in front where it lists posts, and none on About or a list of people.
    func walked(of who: DummyPerson, in session: ShellSession) -> [DummyItem] {
        switch front(of: who, in: session) {
        case .posts: posts(of: who, in: session)
        case .pinned: pinned(of: who, in: session)?.posts ?? []
        case .about, .following, .followers: []
        }
    }

    /// Every row `j` and `k` walk on the page of `who`, top to bottom as the tab in front
    /// draws it: About's blocks, the people of a list, or posts.
    func walkedIDs(of who: DummyPerson, in session: ShellSession) -> [String] {
        let front = front(of: who, in: session)
        switch front {
        case .about: return about(of: who, in: session)?.walked ?? []
        case .following, .followers: return list(front, of: who, in: session).map { lists.walked($0, in: session) } ?? []
        case .pinned, .posts: return walked(of: who, in: session).map(\.id)
        }
    }

    /// Where the lamp lands when it is first brought down onto the page of `who`: the first
    /// row of the tab in front.
    func entry(of who: DummyPerson, in session: ShellSession) -> String? {
        walkedIDs(of: who, in: session).first
    }

    /// Return with the lamp on the block `id` of About, on the page of `who`: its press,
    /// where it is one. Whether the key did anything.
    func pressAbout(_ id: String, of who: DummyPerson, in session: ShellSession) -> Bool {
        guard front(of: who, in: session) == .about, let press = about(of: who, in: session)?.press(on: id) else { return false }
        switch press {
        case .home(let asked): Task { await homePressed(asked, on: who, in: session) }
        case .askFollows: session.askFor([PersonAct.follow.needs], host: who.host)
        case .act(let pressed): Task { await act(pressed, on: who, in: session) }
        // A hashtag's page and the list of people are steps of the walk: whoever holds it takes them.
        case .featured(.tag), .featured(.people), .featured(.takeOff): return false
        }
        return true
    }

    // MARK: - What a tab asks, and when

    /// Which tab is in front on which page, for whom: what the page's task is named by, so a
    /// tab brought in front, the source saying who they are, and a reader who ends, begins or
    /// changes each ask what that tab needs — and nothing else does.
    struct Fronting: Hashable {
        let opening: Opening
        let tab: PersonTab
        /// The id the source knows them by, once it has said: what their posts and lists are
        /// asked by.
        let accountID: String?
    }

    func fronting(_ who: DummyPerson, in session: ShellSession) -> Fronting {
        Fronting(
            opening: Self.opening(who, in: session), tab: front(of: who, in: session),
            accountID: said(of: who, in: session)?.person?.accountID
        )
    }

    /// The tab in front on the page of `who` asks what it needs, where it has not: nothing
    /// for About, one stretch of their posts or of what they pinned, and for a list of people
    /// its first stretch and how the reader stands to those in it. `again` is the person's own
    /// press — `r`, the bar's mark, a pull — and asks that tab from its top.
    func fronted(_ who: DummyPerson, again: Bool = false, in session: ShellSession) async {
        let front = front(of: who, in: session)
        switch front {
        case .about:
            break
        case .posts:
            await postsAsked(who, again: again, in: session)
        case .pinned:
            await tabs.asked(who, beside: said(of: who, in: session), again: again, in: session)
        case .following, .followers:
            guard let list = list(front, of: who, in: session) else { return }
            if again { await lists.again(list, in: session) } else { await lists.opened(list, in: session) }
        }
    }

    /// Every tab of the page of `who` but `front` forgets what it held of their lists and of
    /// what they pinned, so each asks when it is next in front.
    func forgetTabs(of who: DummyPerson, but front: PersonTab, in session: ShellSession) {
        if front != .pinned { tabs.forgetPinned(who.id) }
        guard let person = said(of: who, in: session)?.person else { return }
        for which in PeopleList.Which.ofSomebody where front.list != which {
            lists.forget(PeopleList(which, of: person))
        }
    }
}
