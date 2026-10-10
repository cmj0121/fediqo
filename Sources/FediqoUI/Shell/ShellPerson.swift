import FediqoCore
import Foundation
import Observation

// Somebody's page as their source says it (#310): what is asked, when, and what the page holds
// of the answers.
//
// **Asked when the page opens, and when the person presses.** Opening asks who they are and
// their newest stretch of posts — two asks, and no more: a source allows a few hundred in five
// minutes, shared with everything else the sign-in does there, and a page is opened by one
// press. Reading on is the foot's press; `r` and the page's "Try again" ask the same two again,
// and a press while they are on the wire is taken and asks nothing. Nothing is asked while no
// page is open, and nothing by itself.
//
// **An ask is the pages', and not the pane's.** The pane that opened a page may leave before the
// source answers — a step back, a row pressed — and an ask that died with it would leave the
// page saying "Asking…" for the rest of the run. So the ask goes on, bounded by its deadline,
// and lands for the next visit; and a page whose ask ended with nothing answered and nothing
// on the wire is asked again when it is opened again.
//
// **Every answer lands only where it is still the one awaited.** Each ask and each reading-on
// is numbered; what it needs is taken before it waits, and what it brings is written only where
// the page still awaits that number — so a slow answer cannot overwrite a newer one, and an ask
// begun since has already put the page's marks where they belong.
//
// **For the page, and held nowhere.** What a source says of somebody, and their posts, are kept
// here for this run and written to no store. A post read for the page becomes an item when the
// person opens it or presses a mark on it (`holding`), or where this device already holds it —
// and then the row is drawn from what is held, so its marks are the held ones.
//
// **As whoever asked.** A page says what the source gave *that reader* — posts for their
// followers among them. So each page remembers who it was asked as, and is not there for
// anybody else: a sign-in that ends, begins or changes asks afresh.
//
// **Told by the sign-in itself, and then by name.** A reader the source has not named — every
// sign-in that only reads, and any in its first moment — is not told from another by a handle.
// So at every press that reads a page (`opened`, `again`, `readOn`, `holding`) the sign-in held
// now is looked at once, and where it is not the one the pages of that host were last read
// through, every page of that host is let go and its ask called off before anything else is
// done (`PageReaders`). The handle stays the second check, and the one a page is drawn by.
//
// **What that leaves, for the unit that owns the sign-in.** Drawing looks at no sign-in: a
// Keychain read a frame is not paid. So a sign-in replaced by another unnamed one, while a page
// stays where it can be drawn and nothing is pressed, is drawn that page until the next press
// or the next time it opens — at most the frame before its pane's own opening asks. Closing
// that needs a count kept where the sign-in code already notes that a host's reader may have
// changed, bumped there and compared here in `standing`; these files do not own that code.
//
// **Only where the source says who people are** (`SourceOffers.people`), and only for somebody
// with a handle: a forum's author is a name on a host, and is asked of nobody.
//
// **These reads conclude no sign-out.** A source answers them to a token it no longer honours
// as it answers nobody, so an answer says nothing of the sign-in — and a refusal is a page that
// failed, nothing more. Where the signed-in door itself confirmed a sign-out by its own check,
// the session is told, as it is for any read.

/// Whose sign-in the pages of each host were last read through, so a page given to one reader
/// is never there for the next — whether or not the source has named either.
///
/// **A sign-in is told from another by its token, and the token is not kept**: what is held is
/// a hash of it made for this run alone, in memory, compared and never written, logged or
/// shown. Nobody's sign-in is its own mark, so signing in and signing out are both a change.
@MainActor
final class PageReaders {
    /// A sign-in's mark: nothing for nobody.
    private struct Seal: Equatable {
        let print: Int?
    }

    private var seals: [String: Seal] = [:]
    private var letGo: [(String) -> Void] = []

    /// Whoever keeps pages says how the pages of one host are let go.
    func whenChanged(_ drop: @escaping (String) -> Void) {
        letGo.append(drop)
    }

    /// The one look a press makes at who is signed in to `host`: the sign-in held now — what
    /// the press's door is then built with, so it is read once — and whether it is another
    /// than the pages of that host were last read through. **Where it is, they are let go here,
    /// before the press does anything else.**
    func look(at host: String, in session: ShellSession) -> (held: MastodonToken?, changed: Bool) {
        let held = session.mastodon.token(host: host)
        let seal = Seal(print: held.map { $0.accessToken.hashValue })
        let changed = seals[host].map { $0 != seal } ?? false
        seals[host] = seal
        if changed { for drop in letGo { drop(host) } }
        return (held, changed)
    }
}

/// One count for every ask a page makes this run — a person's page or a list of people's, an
/// opening or a reading-on — so no two asks anywhere share a number, and an answer lands only
/// where its own number is still the one awaited.
@MainActor
final class PageErrands {
    private var count = 0

    /// The number of the ask about to go out.
    func next() -> Int {
        count += 1
        return count
    }
}

/// Which pages are kept, oldest first: the walk is seldom deeper than a few, and a page left
/// long ago is asked again when it is opened again.
struct PageOrder {
    private var order: [String] = []

    mutating func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    mutating func forget(_ id: String) {
        order.removeAll { $0 == id }
    }

    /// Notes `id` as the newest, and hands back the pages let go to keep `kept` — the oldest,
    /// but never one that is `busy`: its ask is still on the wire.
    mutating func keep(_ id: String, among kept: Int, busy: (String) -> Bool) -> [String] {
        touch(id)
        let gone = order.dropLast(kept).filter { !busy($0) }
        order.removeAll(where: gone.contains)
        return gone
    }
}

/// Every person's page opened this run, by who they are.
///
/// Held by the root beside the walk, and handed the session at each ask: the session's own
/// stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellPersonPages {
    /// Who a page was asked as: nobody, or the reader signed in to that source — by the handle
    /// the source gave them, where it has said.
    enum AskedAs: Hashable, Sendable {
        case nobody
        case reader(String?)

        /// Whether a page asked as this was asked as `other`. **A reader the source has not
        /// named yet is the same reader once it has**: who they are there is learnt a moment
        /// after a sign-in, and a page asked in that moment is theirs all the same. Two
        /// readers each named are the same only by the same name.
        func isTheSame(as other: AskedAs) -> Bool {
            switch (self, other) {
            case (.nobody, .nobody): true
            case (.reader(let one), .reader(let two)): one == nil || two == nil || one == two
            default: false
            }
        }
    }

    /// One page: what the source said, and how far its posts were read.
    private struct Page {
        /// The host of the source asked: what its pages are let go by when its reader changes.
        let host: String
        var askedAs: AskedAs
        var reading: PersonSaid.Reading = .asking
        /// What asking again came to, where the source had said who they are before: the
        /// person and their posts stand, and this is said beside them.
        var again: PersonSaid.Trouble?
        var read = PostsRead()
        /// Whether a stretch of posts has answered, or failed to.
        var answered = false
        /// Whether who they are and their newest posts are on the wire.
        var asking = false
        var readingOn = false
        var footFailed = false
        /// The source stopped handing its posts on in order: the list ends where it is.
        var notPaging = false
        /// The number of the ask or the reading-on whose answer this page awaits.
        var awaits = 0

        /// Whether the page's two asks came to something: that they are not known, a failure,
        /// or who they are **and** an answer about their posts. A page that is not settled and
        /// has nothing on the wire — an ask that was stopped, before either answer or between
        /// the two — is asked again when it is opened.
        var settled: Bool {
            switch reading {
            case .asking: false
            case .unheardOf, .failed: true
            case .said: answered
            }
        }
    }

    private struct RowsKey: Equatable {
        let read: PostsRead
        let notes: Int
    }

    /// How many pages are kept: the walk is seldom deeper, and a page left long ago is asked
    /// again when it is opened again.
    static let kept = 8

    private var pages: [String: Page] = [:]
    /// The rows last built of each page, and what they were built from. Not observed: it is
    /// written while a page is drawn.
    @ObservationIgnored private var built: [String: (key: RowsKey, items: [DummyItem])] = [:]
    @ObservationIgnored private var order = PageOrder()
    /// The asks on the wire, by page: what a second opening waits on, and asks nothing.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    /// One count for every page's asks and readings-on, and for the lists' beside them.
    @ObservationIgnored private let errands: PageErrands
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Whose sign-in each host's pages were last read through.
    @ObservationIgnored private let readers: PageReaders
    /// The lists of people opened this run (#311): pages of the same kind, asked the same way,
    /// numbered on the same count, and let go with the same reader.
    let lists: ShellPeoplePages
    /// What a source says of itself beyond its document, for that source's own page (#321):
    /// asked the same way, numbered on the same count, and let go with the same reader. It
    /// holds the one keeper of what this run knows each host has (`ShellHostsKnown`).
    let more: ShellSourceMore
    /// The hashtags and the links rising on the sources (#320): pages asked the same way,
    /// numbered on the same count, and let go with the same reader.
    let rising: ShellRising

    init() {
        let count = PageErrands(), looks = PageReaders()
        errands = count
        readers = looks
        let lists = ShellPeoplePages(errands: count, readers: looks)
        self.lists = lists
        let hosts = ShellHostsKnown(errands: count)
        let more = ShellSourceMore(errands: count, readers: looks, hosts: hosts)
        self.more = more
        let rising = ShellRising(errands: count, readers: looks, hosts: hosts)
        self.rising = rising
        looks.whenChanged { [weak self] host in self?.letGo(at: host) }
        looks.whenChanged { [weak lists] host in lists?.letGo(at: host) }
        looks.whenChanged { [weak more] host in more?.letGo(at: host) }
        looks.whenChanged { [weak rising] host in rising?.letGo(at: host) }
    }

    /// A page opening, as its pane's task is named: who they are **and who asks**, so a page
    /// in front whose reader ends, begins or changes opens again by itself, and is asked.
    struct Opening: Hashable {
        let id: String
        let askedAs: AskedAs
    }

    static func opening(_ who: DummyPerson, in session: ShellSession) -> Opening {
        Opening(id: who.id, askedAs: askedAs(at: who.host, in: session))
    }

    /// Every page of `host` let go, and its ask called off: its reader is no longer who they
    /// were given to. Whatever an ask already out brings, it brings to no page.
    private func letGo(at host: String) {
        for (id, page) in pages where page.host == host {
            asks[id]?.cancel()
            asks[id] = nil
            pages[id] = nil
            built[id] = nil
            order.forget(id)
        }
    }

    // MARK: - What the page is handed

    /// The source `who` is asked of, where it says who people are and they have a handle.
    static func source(of who: DummyPerson, in session: ShellSession) -> Source? {
        who.handle == nil ? nil : source(at: who.host, in: session)
    }

    /// The source at `host`, where there is one and it says who people are: **the one place
    /// that fact is read**, for a person's page and for a list of people alike.
    static func source(at host: String, in session: ShellSession) -> Source? {
        session.sources.first { source in source.host == host && saysPeople(source) }
    }

    /// Whether `source` says who people are: the fact itself, read here and by nobody else —
    /// of a source held (`source(at:)`), and of a host as its own document has just named what
    /// it speaks (`ShellHostsKnown`).
    static func saysPeople(_ source: Source) -> Bool {
        source.kind.offers.people
    }

    /// The signed-in reader's own page at `host` (#310) — the page of anybody, opened for
    /// their own account — or nothing: the source there does not say who people are, nobody is
    /// signed in to it, or it has not yet said who the reader is there. **By the handle the
    /// source gave them**, so it is the very page a row of their own opens.
    ///
    /// **A sign-in that only reads has no such page, and no entry to one.** Who the reader is at
    /// a source is learnt only for a sign-in that may write (`MastodonSessions.signedIn`), so a
    /// reading one has no handle here to open a page by. Offering it means learning who every
    /// sign-in is, which is the sign-in's own unit to do.
    static func own(at host: String, in session: ShellSession) -> DummyPerson? {
        guard session.mastodon.signedInHosts.contains(host), let handle = session.mastodon.handles[host],
              let me = DummyPerson(handle: handle, host: host), source(of: me, in: session) != nil
        else { return nil }
        return me
    }

    /// Who an ask of `host` is made as now.
    static func askedAs(at host: String, in session: ShellSession) -> AskedAs {
        session.mastodon.signedInHosts.contains(host) ? .reader(session.mastodon.handles[host]) : .nobody
    }

    /// The page of `who` as it stands **for whoever would ask now**, or nothing: none was
    /// opened, or it was asked as somebody else.
    private func standing(of who: DummyPerson, at source: Source, in session: ShellSession) -> Page? {
        pages[who.id].flatMap { $0.askedAs.isTheSame(as: Self.askedAs(at: source.host, in: session)) ? $0 : nil }
    }

    /// What the page of `who` is handed, or nothing where their source is not asked who people
    /// are: the page then draws what it always drew.
    func said(of who: DummyPerson, in session: ShellSession) -> PersonSaid? {
        guard let source = Self.source(of: who, in: session) else { return nil }
        guard let page = self.standing(of: who, at: source, in: session) else {
            return PersonSaid(source: source.host, reading: .asking)
        }
        return PersonSaid(
            source: source.host, reading: page.reading, again: page.again,
            posts: page.answered ? rows(of: who.id, page, in: session) : nil,
            askingPosts: page.asking, foot: page.answered ? Self.foot(of: page) : nil
        )
    }

    private static func foot(of page: Page) -> PersonSaid.Foot? {
        if page.readingOn { return .reading }
        if page.notPaging { return .stopped }
        if page.footFailed { return .failed }
        if page.read.next != nil { return .more }
        // Nothing under no posts: what stands there says the source gave none.
        return page.read.posts.isEmpty ? nil : .end
    }

    /// The rows of a page: each post the source gave, **drawn from what this device holds
    /// where it holds it** — so a mark pressed elsewhere, a cover lifted, a change the store
    /// took in are the ones shown — and from the page's own memory otherwise.
    private func rows(of id: String, _ page: Page, in session: ShellSession) -> [DummyItem] {
        let key = RowsKey(read: page.read, notes: session.notesRevision)
        if let rows = built[id], rows.key == key { return rows.items }
        let brought = ReblogTargets(page.read.posts + page.read.carried)
        let items = page.read.posts.map { note in
            session.heldNote(note.key.rowID).map { DummyItem($0, among: session.reblogTargets) }
                ?? DummyItem(note, among: brought)
        }
        built[id] = (key, items)
        return items
    }

    /// The rows `j` and `k` walk on the page of `who`: the source's posts where they are what
    /// the page draws, and what this device holds of theirs where it draws that.
    func walked(of who: DummyPerson, in session: ShellSession) -> [DummyItem] {
        said(of: who, in: session)?.posts ?? session.heldPosts(of: who)
    }

    // MARK: - The lists the page opens

    /// The lists the page of `who` opens (#311), in the order their figures are drawn — whom
    /// they follow, who follows them — **as the page stands for whoever would ask now**: none
    /// until the source has said who they are, and none on a page handed nothing.
    func lists(of who: DummyPerson, in session: ShellSession) -> [PeopleList] {
        guard let person = said(of: who, in: session)?.person else { return [] }
        return PersonSaid.counts(of: person).compactMap(\.opens)
    }

    /// The list the line `id` of the page of `who` opens, where `id` is such a line: what
    /// Return opens with the lamp on it.
    func list(_ id: String, of who: DummyPerson, in session: ShellSession) -> PeopleList? {
        lists(of: who, in: session).first { $0.id == id }
    }

    /// Every row `j` and `k` walk on the page of `who`, top to bottom as it is drawn: the
    /// figures that open a list, and under them their posts.
    func walkedIDs(of who: DummyPerson, in session: ShellSession) -> [String] {
        lists(of: who, in: session).map(\.id) + walked(of: who, in: session).map(\.id)
    }

    /// Where the lamp lands when it is first brought down onto the page of `who`: their first
    /// post, as before there was anything above it. The figures stand over it, a `k` away.
    func entry(of who: DummyPerson, in session: ShellSession) -> String? {
        walked(of: who, in: session).first?.id
    }

    /// Whether `rowID` is a post on the page of `who` that this device does not hold.
    func isOnlyOnPage(_ rowID: String, of who: DummyPerson, in session: ShellSession) -> Bool {
        session.heldNote(rowID) == nil && pages[who.id]?.read.posts.contains { $0.key.rowID == rowID } == true
    }

    /// Whether the page of `who` has anybody to ask again — what `r` and its mark go by.
    func canAskAgain(_ who: DummyPerson, in session: ShellSession) -> Bool {
        Self.source(of: who, in: session) != nil
    }

    // MARK: - Asking

    /// The page of `who` opening. Asked once: opened again, it is drawn from what was answered;
    /// opened while its ask is on the wire, it waits on that ask and starts none; opened after
    /// an ask that came to nothing, or as somebody else, it is asked again.
    func opened(_ who: DummyPerson, in session: ShellSession) async {
        guard let source = Self.source(of: who, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        if let page = self.standing(of: who, at: source, in: session) {
            order.touch(who.id)
            named(who.id, as: Self.askedAs(at: source.host, in: session))
            if page.asking {
                await asks[who.id]?.value
                return
            }
            if page.settled { return }
        }
        await begin(who, at: source, with: held, in: session)?.value
    }

    /// `r` and "Try again": who they are, and their newest stretch, asked again. What the page
    /// holds stays drawn until the answers land. **A press while an ask is on the wire asks
    /// nothing**, as a second press of any reload asks nothing.
    func again(_ who: DummyPerson, in session: ShellSession) async {
        guard let source = Self.source(of: who, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        if self.standing(of: who, at: source, in: session)?.asking == true { return }
        await begin(who, at: source, with: held, in: session)?.value
    }

    /// Starts the two asks of a page, and hands back the task they run in. Everything they
    /// need is taken here, before anything waits: the source, the handle, who asks, the door.
    private func begin(
        _ who: DummyPerson, at source: Source, with held: MastodonToken?, in session: ShellSession
    ) -> Task<Void, Never>? {
        guard let handle = who.handle else { return nil }
        let id = who.id
        let askedAs = Self.askedAs(at: source.host, in: session)
        if pages[id]?.askedAs.isTheSame(as: askedAs) != true {
            // Nobody's page yet, or somebody else's: what was said to them is not said to this one.
            pages[id] = Page(host: source.host, askedAs: askedAs)
            built[id] = nil
        }
        named(id, as: askedAs)
        keep(id)
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.asking = true
        // A reading-on still on the wire is this ask's to supersede: its answer will not land.
        pages[id]?.readingOn = false
        let through = self.door(to: source, with: held, in: session)
        let task = Task {
            await self.ask(id, handle: handle, of: through, at: source, as: askedAs, errand: errand, in: session)
        }
        asks[id] = task
        return task
    }

    private func ask(
        _ id: String, handle: String, of through: MastodonPerson, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        defer { if pages[id]?.awaits == errand { asks[id] = nil } }
        let person: Person
        do {
            person = try await through.person(handle: handle, source: source)
        } catch {
            guard pages[id]?.awaits == errand else { return }
            pages[id]?.asking = false
            if Cancellation.happened(error) { return }
            Self.concluded(error, at: source, askedAs: askedAs, in: session)
            let trouble: PersonSaid.Trouble = (error as? PersonReadError) == .unheardOf ? .unheardOf : .failed
            if case .said = pages[id]?.reading {
                // What it said before stands, and this is said beside it.
                pages[id]?.again = trouble
            } else {
                pages[id]?.reading = trouble == .unheardOf ? .unheardOf : .failed
            }
            return
        }
        guard pages[id]?.awaits == errand else { return }
        pages[id]?.reading = .said(person)
        pages[id]?.again = nil

        do {
            let newest = try await through.posts(of: person.accountID, source: source)
            guard pages[id]?.awaits == errand else { return }
            // Read first and written after: the two are not one access.
            let renewed = (pages[id]?.read ?? PostsRead()).renewed(by: newest)
            pages[id]?.read = renewed
            pages[id]?.answered = true
            pages[id]?.footFailed = false
            pages[id]?.notPaging = false
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if !Cancellation.happened(error) {
                Self.concluded(error, at: source, askedAs: askedAs, in: session)
                // Who they are stands; their posts are a stretch that did not come.
                pages[id]?.answered = true
                pages[id]?.footFailed = true
            }
        }
        pages[id]?.asking = false
    }

    /// The foot's press: the stretch older than what the page holds. One at a time, none while
    /// the page is being asked again, and none where the source named no next or stopped
    /// handing its posts on.
    ///
    /// **Pressed by a reader the page was not given to, it reads nothing on**: the page is let
    /// go, and asked afresh as them — begun here, and waited on by whoever opens it.
    func readOn(_ who: DummyPerson, in session: ShellSession) async {
        guard let source = Self.source(of: who, in: session) else { return }
        let looked = readers.look(at: source.host, in: session)
        if looked.changed {
            _ = begin(who, at: source, with: looked.held, in: session)
            return
        }
        guard let page = self.standing(of: who, at: source, in: session),
              !page.readingOn, !page.asking, !page.notPaging, case .said(let person) = page.reading
        else { return }
        // A stretch that did not come is asked again from where the page stands.
        let next = page.read.next
        guard next != nil || page.footFailed else { return }
        let id = who.id
        let askedAs = page.askedAs
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.readingOn = true
        pages[id]?.footFailed = false
        let through = self.door(to: source, with: looked.held, in: session)
        do {
            let stretch = try await through.posts(of: person.accountID, source: source, after: next)
            guard pages[id]?.awaits == errand, let held = pages[id]?.read else { return }
            let further = next == nil ? held.renewed(by: stretch) : try held.readingOn(stretch)
            pages[id]?.read = further
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if error is PagingError {
                pages[id]?.notPaging = true
            } else if !Cancellation.happened(error) {
                Self.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[id]?.footFailed = true
            }
        }
        pages[id]?.readingOn = false
    }

    // MARK: - A post becoming an item

    /// Makes an item of a post that is on the page only, because the person opened it or
    /// pressed a mark on it: held as a thread's posts are held, with the post it boosts where
    /// it is a boost. The row it now is — or nothing, **and then the person is told**: the
    /// store would not take it, which it will not for a post older than this device keeps.
    ///
    /// **Pressed by a reader the page was not given to, nothing is held**: the row was another
    /// reader's. The page is let go and asked afresh, and the press does nothing more.
    func holding(_ rowID: String, of who: DummyPerson, in session: ShellSession) async -> DummyItem? {
        if let source = Self.source(of: who, in: session) {
            let looked = readers.look(at: source.host, in: session)
            if looked.changed {
                _ = begin(who, at: source, with: looked.held, in: session)
                return nil
            }
        }
        if session.heldNote(rowID) == nil, let read = pages[who.id]?.read,
           let note = read.posts.first(where: { $0.key.rowID == rowID })
        {
            let boosted = note.reblogKey.flatMap { key in read.carried.first { $0.key == key } }
            await session.store.ingest([note] + [boosted].compactMap { $0 }, ifSourceHere: note.source.host)
            session.saveSoon()
            await session.reloadFromStore()
        }
        // Read again after the wait: what is held now, whoever held it.
        guard let held = session.held(rowID) else {
            session.showToast(L10n.t("person.unheld"))
            return nil
        }
        return held
    }

    /// A row of this page as it acts: a held post's own acting, and for one that is on the page
    /// only the same marks, each **holding the post first and then acting on what is held** —
    /// so pressing a mark is choosing the post, as opening it is.
    func acting(
        _ item: DummyItem, of who: DummyPerson, in session: ShellSession, held acting: @escaping (DummyItem) -> ItemActing
    ) -> ItemActing {
        var marks = acting(item)
        guard isOnlyOnPage(item.id, of: who, in: session) else { return marks }
        func held(_ then: @escaping @MainActor (ItemActing) -> Void) {
            Task { if let now = await self.holding(item.id, of: who, in: session) { then(acting(now)) } }
        }
        if marks.perform != nil { marks.perform = { act in held { $0.perform?(act) } } }
        if marks.keep != nil { marks.keep = { held { $0.keep?() } } }
        if marks.ask != nil { marks.ask = { act in held { $0.ask?(act) } } }
        // Taking back is asked of a post held: it is offered once this one is.
        marks.withdraw = nil
        return marks
    }

    /// The door to `source`: as the person where they are signed in to it, and with no token
    /// — listed, bounded, and under the small body's ceiling — where they are not.
    private func door(to source: Source, with held: MastodonToken?, in session: ShellSession) -> MastodonPerson {
        if let held {
            return session.reach.person(session.mastodon.authorized(token: held, within: deadline, for: .person))
        }
        return session.reach.unsignedPerson(source.host, for: .person, within: deadline)
    }

    /// The one thing a failed read here may conclude about the sign-in: nothing, unless the
    /// signed-in door confirmed by its own check that the source took the token back — **and
    /// whoever asks now is still who the ask was made as**. An answer come late says nothing of
    /// a sign-in that has since ended, begun or changed.
    static func concluded(_ error: any Error, at source: Source, askedAs: AskedAs, in session: ShellSession) {
        guard (error as? MastodonAuthError) == .signedOut,
              Self.askedAs(at: source.host, in: session).isTheSame(as: askedAs)
        else { return }
        session.mastodon.endedByServer(host: source.host)
    }

    /// Writes down the name the source has since given the reader a page was asked as, so the
    /// page is theirs by name from then on and nobody else's.
    private func named(_ id: String, as now: AskedAs) {
        if case .reader(nil) = pages[id]?.askedAs, case .reader(.some) = now { pages[id]?.askedAs = now }
    }

    // MARK: - Which pages are kept

    /// Keeps the page `id` among the newest `kept`, letting the oldest go — but never one
    /// whose ask is still on the wire.
    private func keep(_ id: String) {
        for gone in order.keep(id, among: Self.kept, busy: { pages[$0]?.asking == true }) {
            pages[gone] = nil
            built[gone] = nil
            asks[gone] = nil
        }
    }
}
