import FediqoCore
import Foundation
import Observation

// Somebody's page as their source says it (#310): what is asked, when, and what the page holds
// of the answers.
//
// **Asked when the page opens, when a tab is first in front, and when the person presses.**
// Opening asks who they are, and nothing else: a source allows a few hundred in five minutes,
// shared with everything else the sign-in does there, and a page is opened by one press.
// **Their posts are asked for when the tab that lists them is first in front** (`postsOpened`)
// — one stretch, and a tab never brought in front costs the source nothing. Reading on is the
// foot's press; `r` and the page's "Try again" ask who they are again and the tab in front
// from its top, every other tab forgetting what it held (`again`), and a press while an ask is
// on the wire is taken and asks nothing. Nothing is asked while no page is open, and nothing
// by itself.
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
// **Told by the sign-in itself, and then by name.** A reader the source has not named — one it
// gave no handle of its own, one a package brought until its check answers — is not told from
// another by a handle.
// So at every press that reads a page (`opened`, `again`, `readOn`, `holding`) the sign-in held
// now is looked at once, and where it is not the one the pages of that host were last read
// through, every page of that host is let go and its ask called off before anything else is
// done (`PageReaders`). The handle stays the second check, and the one a page is drawn by.
//
// **And between presses, by a count.** Drawing looks at no sign-in: a Keychain read a frame is
// not paid. So the sign-in code counts each time the sign-in held at a host becomes another
// (`MastodonSessions.changes`), and a page remembers the count it was asked under: where the
// two differ the page is not drawn (`standing`), and its opening is another, so the pane asks
// again by itself — and that ask's look at the sign-in is what lets the page go, or keeps it.
// **The count only stops a page being drawn.** It lets nothing go and asks nothing.
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

/// The rows last built of each page's posts, and what they were built from: each post the
/// source gave, **drawn from what this device holds where it holds it** — so a mark pressed
/// elsewhere, a cover lifted, a change the store took in are the ones shown — and from the
/// page's own memory otherwise. Built once for what was read and what is held, and kept.
@MainActor
struct PageRows {
    private struct Key: Equatable {
        let read: PostsRead
        let notes: Int
    }

    private var built: [String: (key: Key, items: [DummyItem])] = [:]

    mutating func rows(of id: String, _ read: PostsRead, in session: ShellSession) -> [DummyItem] {
        let key = Key(read: read, notes: session.notesRevision)
        if let rows = built[id], rows.key == key { return rows.items }
        let brought = ReblogTargets(read.posts + read.carried)
        let items = read.posts.map { note in
            session.heldNote(note.key.rowID).map { DummyItem($0, among: session.reblogTargets) }
                ?? DummyItem(note, among: brought)
        }
        built[id] = (key, items)
        return items
    }

    mutating func forget(_ id: String) {
        built[id] = nil
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
        /// Whether who they are is on the wire.
        var asking = false
        /// Whether their newest stretch of posts is.
        var askingPosts = false
        var readingOn = false
        var footFailed = false
        /// The source stopped handing its posts on in order: the list ends where it is.
        var notPaging = false
        /// The number of the ask of who they are whose answer this page awaits.
        var awaits = 0
        /// The number of the ask for their posts, or the reading-on, whose answer it awaits.
        var awaitsPosts = 0
        /// How often the sign-in at its host had become another when it was last asked.
        var under = 0

        /// Whether asking who they are came to something: that they are not known, a failure,
        /// or who they are. **It waits on no posts**: those are asked for by their tab. A page
        /// that is not settled and has nothing on the wire — an ask that was stopped — is
        /// asked again when it is opened.
        var settled: Bool { reading != .asking }

        /// Whether their posts are still to ask for: nothing answered, nothing on the wire,
        /// and no stretch that did not come — that one is the foot's press to ask again.
        var owesPosts: Bool { !answered && !askingPosts && !readingOn && !footFailed }

        /// What the page held of their posts let go, so they are asked for when their tab is
        /// next in front. `errand` is a number no ask awaits: whatever is on the wire lands
        /// nowhere.
        mutating func forgetPosts(_ errand: Int) {
            read = PostsRead()
            answered = false
            askingPosts = false
            readingOn = false
            footFailed = false
            notPaging = false
            awaitsPosts = errand
        }
    }

    /// How many pages are kept: the walk is seldom deeper, and a page left long ago is asked
    /// again when it is opened again.
    static let kept = 8

    private var pages: [String: Page] = [:]
    /// The rows last built of each page, and what they were built from. Not observed: it is
    /// written while a page is drawn.
    @ObservationIgnored private var built = PageRows()
    @ObservationIgnored private var order = PageOrder()
    /// The asks on the wire, by page: what a second opening waits on, and asks nothing.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    /// The asks for a page's newest posts on the wire, by page.
    @ObservationIgnored private var postAsks: [String: Task<Void, Never>] = [:]
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
    /// What the person set at a source for the posts they write there, for that source's own
    /// page (#321): asked the same way, numbered on the same count, and let go with the same
    /// reader.
    let you: ShellYouThere
    /// The people and the hashtags a search found at the sources, and an address looked up
    /// through one (#319): numbered on the same count, and let go with the same reader.
    let found: ShellSearchFound
    /// The server somebody lives on, asked what it says of them at their page's press (#310):
    /// numbered on the same count. Asked with no sign-in, so no reader's change lets it go.
    let home: ShellPersonHome
    /// Whether the reader follows a hashtag at each source, for that hashtag's page (#318):
    /// numbered on the same count, and let go with the same reader.
    let tags: ShellTagFollow
    /// The hashtags the reader follows at each source, as a list (#318): numbered on the same
    /// count, let go with the same reader, and pressed through `tags`.
    let followed: ShellFollowedTags
    /// How the reader stands to whoever's page is open, and following them (#310, #313):
    /// numbered on the same count, and let go with the same reader.
    let acts: ShellPersonActs
    /// The tabs of each page (F9): which is in front, each tab's lamp, and what they pinned —
    /// numbered on the same count, and let go with the same reader.
    let tabs: ShellPersonTabs

    init() {
        let count = PageErrands(), looks = PageReaders()
        errands = count
        readers = looks
        let hosts = ShellHostsKnown(errands: count)
        let lists = ShellPeoplePages(errands: count, readers: looks, hosts: hosts)
        self.lists = lists
        let more = ShellSourceMore(errands: count, readers: looks, hosts: hosts)
        self.more = more
        let rising = ShellRising(errands: count, readers: looks, hosts: hosts)
        self.rising = rising
        let you = ShellYouThere(errands: count, readers: looks)
        self.you = you
        let found = ShellSearchFound(errands: count, readers: looks)
        self.found = found
        home = ShellPersonHome(errands: count)
        let tags = ShellTagFollow(errands: count, readers: looks)
        self.tags = tags
        let followed = ShellFollowedTags(errands: count, readers: looks, tags: tags)
        self.followed = followed
        let acts = ShellPersonActs(errands: count, readers: looks)
        self.acts = acts
        let tabs = ShellPersonTabs(errands: count, readers: looks, hosts: hosts)
        self.tabs = tabs
        looks.whenChanged { [weak tabs] host in tabs?.letGo(at: host) }
        looks.whenChanged { [weak acts] host in acts?.letGo(at: host) }
        looks.whenChanged { [weak followed] host in followed?.letGo(at: host) }
        looks.whenChanged { [weak found] host in found?.letGo(at: host) }
        looks.whenChanged { [weak self] host in self?.letGo(at: host) }
        looks.whenChanged { [weak lists] host in lists?.letGo(at: host) }
        looks.whenChanged { [weak more] host in more?.letGo(at: host) }
        looks.whenChanged { [weak rising] host in rising?.letGo(at: host) }
        looks.whenChanged { [weak you] host in you?.letGo(at: host) }
        looks.whenChanged { [weak tags] host in tags?.letGo(at: host) }
    }

    /// A page opening, as its pane's task is named: who they are **and who asks**, so a page
    /// in front whose reader ends, begins or changes opens again by itself, and is asked.
    /// `under` is the count of that host's sign-ins, for a reader no handle tells from the
    /// one before.
    struct Opening: Hashable {
        let id: String
        let askedAs: AskedAs
        var under = 0
    }

    static func opening(_ who: DummyPerson, in session: ShellSession) -> Opening {
        Opening(id: who.id, askedAs: askedAs(at: who.host, in: session), under: signIns(at: who.host, in: session))
    }

    /// How often the sign-in held at `host` has become another, as the session last looked:
    /// read to draw, and to nothing else. **The one place the count is read**, for every page
    /// that is drawn by it.
    static func signIns(at host: String, in session: ShellSession) -> Int {
        session.mastodon.changes[host, default: 0]
    }

    /// Every page of `host` let go, and its ask called off: its reader is no longer who they
    /// were given to. Whatever an ask already out brings, it brings to no page.
    private func letGo(at host: String) {
        for (id, page) in pages where page.host == host {
            asks[id]?.cancel()
            asks[id] = nil
            postAsks[id]?.cancel()
            postAsks[id] = nil
            pages[id] = nil
            built.forget(id)
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
    /// **Every sign-in has one, a sign-in that only reads included**: who the reader is at a
    /// source is what the sign-in's own check said (`MastodonSessions.handles`). None where
    /// the source gave the account no handle of its own there.
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
        pages[who.id].flatMap { page in
            page.under == Self.signIns(at: source.host, in: session)
                && page.askedAs.isTheSame(as: Self.askedAs(at: source.host, in: session)) ? page : nil
        }
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
            posts: page.answered ? built.rows(of: who.id, page.read, in: session) : nil,
            asking: page.asking, askingPosts: page.askingPosts, foot: Self.foot(of: page)
        )
    }

    /// What stands under their posts. **Before a stretch has answered, only that one is on
    /// its way, or did not come**: what this device holds of theirs is drawn meanwhile, and
    /// stays where the stretch failed.
    private static func foot(of page: Page) -> PersonSaid.Foot? {
        if page.readingOn || (page.askingPosts && !page.answered) { return .reading }
        if page.notPaging { return .stopped }
        if page.footFailed { return .failed }
        guard page.answered else { return nil }
        if page.read.next != nil { return .more }
        // Nothing under no posts: what stands there says the source gave none.
        return page.read.posts.isEmpty ? nil : .end
    }

    /// The posts the Posts tab of the page of `who` draws: the source's where it has
    /// answered, and what this device holds of theirs until then.
    func posts(of who: DummyPerson, in session: ShellSession) -> [DummyItem] {
        said(of: who, in: session)?.posts ?? session.heldPosts(of: who)
    }

    // MARK: - On their own page

    /// The way to the hashtags the reader follows (#318), where the page of `who` is their own
    /// — drawn under the figures, and so only where they are: none until the source has said
    /// who they are, and none while the page draws what their own server says.
    func followedEntry(of who: DummyPerson, in session: ShellSession) -> FollowedTagsEntry? {
        let said = said(of: who, in: session)
        guard said?.person != nil, home.said(of: who, beside: said, in: session) == nil else { return nil }
        return followed.entry(on: who, in: session)
    }

    /// The post `rowID` names as a page of `who` read it for one of its tabs — their posts, or
    /// the ones they pinned — and the post it boosts, where it is a boost.
    private func note(_ rowID: String, of who: DummyPerson, in session: ShellSession) -> (note: Note, boosted: Note?)? {
        let pinned = tabs.pinnedRead(of: who, beside: said(of: who, in: session), in: session)
        for read in [pages[who.id]?.read, pinned].compactMap({ $0 }) {
            guard let note = read.posts.first(where: { $0.key.rowID == rowID }) else { continue }
            return (note, note.reblogKey.flatMap { key in read.carried.first { $0.key == key } })
        }
        return nil
    }

    /// Whether `rowID` is a post on the page of `who` that this device does not hold.
    func isOnlyOnPage(_ rowID: String, of who: DummyPerson, in session: ShellSession) -> Bool {
        session.heldNote(rowID) == nil && note(rowID, of: who, in: session) != nil
    }

    /// Whether the page of `who` has anybody to ask again — what `r` and its mark go by.
    func canAskAgain(_ who: DummyPerson, in session: ShellSession) -> Bool {
        Self.source(of: who, in: session) != nil
    }

    // MARK: - Their own server (#310)

    /// What the server `who` lives on said of them, where the press on this page brought it.
    func homeSaid(of who: DummyPerson, in session: ShellSession) -> PersonHomeSaid? {
        home.said(of: who, beside: said(of: who, in: session), in: session)
    }

    /// The line on the page of `who` about asking the server they live on.
    func homeLine(of who: DummyPerson, in session: ShellSession) -> PersonHomeLine? {
        home.line(of: who, beside: said(of: who, in: session), in: session)
    }

    /// The line's press: that server asked, or the way back to what the source says.
    func homePressed(_ press: PersonHomeLine.Press, on who: DummyPerson, in session: ShellSession) async {
        switch press {
        case .ask: await home.ask(who, beside: said(of: who, in: session), in: session)
        case .back: home.letGo(of: who)
        }
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

    /// `r`, the bar's mark, a pull and "Try again": who they are and how the reader stands to
    /// them asked again, and the tab in front from its top. What that tab holds stays drawn
    /// until the answers land; **every other tab forgets what it held, and asks when it is
    /// next in front** — once the source has said who they are again, and not before: where
    /// it fails, or knows them no longer, nothing held changes. **A press while an ask is on
    /// the wire asks nothing**, as a second press of any reload asks nothing.
    func again(_ who: DummyPerson, in session: ShellSession) async {
        guard let source = Self.source(of: who, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        if let page = self.standing(of: who, at: source, in: session), page.asking || page.askingPosts { return }
        await begin(who, at: source, with: held, in: session)?.value
        // And how the reader stands to them (#310), by the id the page now says they have.
        await acts.again(who, said: said(of: who, in: session), in: session)
        // The tabs, where the source said who they are this time: one that failed, or knows
        // them no longer, is asked nothing more for the press, and nothing held is let go.
        guard let page = self.standing(of: who, at: source, in: session), case .said = page.reading, page.again == nil
        else { return }
        let front = front(of: who, in: session)
        if front != .posts {
            postAsks[who.id]?.cancel()
            postAsks[who.id] = nil
            pages[who.id]?.forgetPosts(errands.next())
            built.forget(who.id)
        }
        forgetTabs(of: who, but: front, in: session)
        await fronted(who, again: true, in: session)
    }

    /// The Posts tab of the page of `who` in front: their newest stretch is asked for, where
    /// the source has said who they are and none was asked for yet. **Once**: brought in front
    /// again it is drawn from what was answered; while the ask is on the wire it is waited on
    /// and nothing more is asked; a stretch that did not come is the foot's press to ask again.
    /// Until it answers, what this device holds of theirs stays drawn.
    func postsOpened(_ who: DummyPerson, in session: ShellSession) async {
        await postsAsked(who, again: false, in: session)
    }

    /// Their newest stretch asked for: where it is owed, and — `again` — where the person
    /// pressed for it, from the top, with what the page holds drawn until it lands.
    func postsAsked(_ who: DummyPerson, again: Bool, in session: ShellSession) async {
        guard let source = Self.source(of: who, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        guard let page = self.standing(of: who, at: source, in: session), case .said(let person) = page.reading else { return }
        if page.askingPosts {
            await postAsks[who.id]?.value
            return
        }
        guard again || page.owesPosts else { return }
        let id = who.id
        let askedAs = page.askedAs
        keep(id)
        let errand = errands.next()
        pages[id]?.awaitsPosts = errand
        pages[id]?.askingPosts = true
        // A reading-on still on the wire is this ask's to supersede: its answer will not land.
        pages[id]?.readingOn = false
        let through = self.door(to: source, with: held, in: session)
        let task = Task {
            await self.askPosts(id, of: person.accountID, through: through, at: source, as: askedAs, errand: errand, in: session)
        }
        postAsks[id] = task
        await task.value
    }

    private func askPosts(
        _ id: String, of accountID: String, through: MastodonPerson, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        defer { if pages[id]?.awaitsPosts == errand { postAsks[id] = nil } }
        do {
            let newest = try await through.posts(of: accountID, source: source)
            guard pages[id]?.awaitsPosts == errand else { return }
            // Read first and written after: the two are not one access.
            let renewed = (pages[id]?.read ?? PostsRead()).renewed(by: newest)
            pages[id]?.read = renewed
            pages[id]?.answered = true
            pages[id]?.footFailed = false
            pages[id]?.notPaging = false
        } catch {
            guard pages[id]?.awaitsPosts == errand else { return }
            if !Cancellation.happened(error) {
                Self.concluded(error, at: source, askedAs: askedAs, in: session)
                // Who they are stands; their posts are a stretch that did not come, and what
                // was drawn before it stays drawn.
                pages[id]?.footFailed = true
            }
        }
        pages[id]?.askingPosts = false
    }

    /// Starts the ask of who they are, and hands back the task it runs in. Everything it
    /// needs is taken here, before anything waits: the source, the handle, who asks, the door.
    private func begin(
        _ who: DummyPerson, at source: Source, with held: MastodonToken?, in session: ShellSession
    ) -> Task<Void, Never>? {
        guard let handle = who.handle else { return nil }
        let id = who.id
        let askedAs = Self.askedAs(at: source.host, in: session)
        if pages[id]?.askedAs.isTheSame(as: askedAs) != true {
            // Nobody's page yet, or somebody else's: what was said to them is not said to this one.
            pages[id] = Page(host: source.host, askedAs: askedAs)
            built.forget(id)
        }
        named(id, as: askedAs)
        // Asked through the sign-in the press has just looked at: the count is where it stands.
        pages[id]?.under = Self.signIns(at: source.host, in: session)
        keep(id)
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.asking = true
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
              !page.readingOn, !page.asking, !page.askingPosts, !page.notPaging, case .said(let person) = page.reading
        else { return }
        // A stretch that did not come is asked again from where the page stands.
        let next = page.read.next
        guard next != nil || page.footFailed else { return }
        let id = who.id
        let askedAs = page.askedAs
        let errand = errands.next()
        pages[id]?.awaitsPosts = errand
        pages[id]?.readingOn = true
        pages[id]?.footFailed = false
        let through = self.door(to: source, with: looked.held, in: session)
        do {
            let stretch = try await through.posts(of: person.accountID, source: source, after: next)
            guard pages[id]?.awaitsPosts == errand, let held = pages[id]?.read else { return }
            let further = next == nil ? held.renewed(by: stretch) : try held.readingOn(stretch)
            pages[id]?.read = further
            pages[id]?.answered = true
        } catch {
            guard pages[id]?.awaitsPosts == errand else { return }
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
        if session.heldNote(rowID) == nil, let (note, boosted) = self.note(rowID, of: who, in: session) {
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
        let busy: (String) -> Bool = { id in
            self.pages[id].map { $0.asking || $0.askingPosts || $0.readingOn } ?? false
        }
        for gone in order.keep(id, among: Self.kept, busy: busy) {
            pages[gone] = nil
            built.forget(gone)
            asks[gone] = nil
            postAsks[gone] = nil
            tabs.forget(gone)
        }
    }
}
