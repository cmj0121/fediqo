import FediqoCore
import Foundation
import Observation

// A list of people a source keeps — whom somebody follows, who follows them (#311), and the
// people in its directory (#315): what is asked, when, and what the page holds of the answers.
//
// **Asked when the list opens, and when the person presses** — a person's page's own rules
// (`ShellPersonPages`), kept here for a list. Opening asks one stretch; the foot's press asks
// the next, by the place the source named and no other; `r`, the mark and a pull ask from the
// top, and Stop calls that ask off.
// **One ask a press, and never two on the wire for one list**: a source allows a few hundred in
// five minutes, shared with everything else the sign-in does there. A press while the list is
// being asked asks nothing; asking from the top calls off a reading-on still out, and whatever
// that brings late does not land.
//
// **From the top, whole.** A list is in the order somebody followed, and the place a stretch
// begins is the source's own word, which no row carries — so a list asked again is read again
// from its head, and what was read before is replaced by what comes.
//
// **An ask is the lists', and not the pane's**, numbered on the one count every page's asks are
// numbered on, and landing only where its number is still the one awaited; **as whoever asked**,
// and there for nobody else; **held nowhere**. Each for the reason given where a person's page
// keeps the same rule.
//
// **Its length is not the source's count.** Signed in, a source leaves out of a list the people
// the reader blocks or mutes; of somebody living elsewhere it holds only who reached it; a list
// its owner hides, the list of somebody who blocks the reader and an empty one all arrive as
// nothing, alike. So the count is said as the source's figure, what was given is said at the
// end, and "hidden" is said only where the account says so.
//
// **A source's directory is such a list, of nobody's** (#315): the same page, the same rules,
// and three things of its own. It is **asked as the reader where they are signed in to that
// source** — a source then leaves out the people the reader blocks or mutes, as it does from
// the lists beside it — and with no sign-in otherwise, on the plain client held to the small
// body's ceiling and to that host. It is
// **read on by how many people were passed over**, the only way on a source has for it, so a
// stretch that brings somebody already listed lists them once. And it has **an order, and the
// choice of only the people who live there**: choosing asks from the top, as asking again
// does, and is refused while the list is being asked. **Where the host says the address is not
// there, the directory is absent**: written down for the run where every such answer is
// (`ShellHostsKnown`), said on the page in one sentence, and not offered on the source's page
// again until the host is asked afresh. An empty answer is a directory nobody is in.
//
// **The people a source suggests the reader are such a list too** (#315), and the reader's
// alone: asked only as somebody signed in, through the signed-in door, since a source suggests
// nobody anything unsigned. Read on by how many were passed over, as a directory is — but
// **ended by a stretch shorter than was asked for**: a real server gives as many as it was asked
// for while it has them, so a shorter one is all it had, and an ask after it would be answered
// with nobody — or with a failure, where what it suggests grew shorter meanwhile. **The known
// limit**: a host that gives fewer in a stretch than it was asked for is cut short there, and
// that is called the end. Absent by the host's own address, as a directory is.
// **Telling the source not to suggest somebody** (`dismiss`) rides the account part, asked in
// place from the row's `…` where it is not held: the row leaves at the yes, comes back with a
// line under it where the press did not arrive, and is gone once the source has answered — and
// a read from the top already on its way when it answered does not bring it back.
//
// **The people somebody features on their profile are such a list too** (#315), of somebody's:
// read on by the source's own next, as whom they follow is, and absent by the host's own
// address, as a directory is.
//
// **A stretch that lands is asked about once more: how the reader stands to the people in it**
// (#310, #313) — one ask for each eighty people of a stretch, which is one ask a stretch as
// these lists ask for them, naming them, through the door and on the record the stretch itself
// was asked by. **Only where a person's page would be told** (`ShellPersonActs`): the
// source is one where somebody is followed, the reader is signed in to it and named by it, and
// their sign-in sees who they follow; and never about the reader themselves. Otherwise nobody
// is asked and a row is as it was. **Nobody is asked about twice**: reading on asks about the
// new stretch only, and an ask that fails is not made again until the list is asked from the
// top — its rows stay without a word, and nothing is said of the failure or guessed in its
// place. **An answer is the list's and the reader's it was asked for**: it lands only on the
// page that asked, as it was last read from the top, while that page is still whoever would
// ask now's. Asked from the top, what the source said before stands for whoever is still
// listed until it answers again — and then its answer is its whole word of them: whoever it
// says nothing of has none.

/// A list of people a source keeps, as a step of the walk names it: which list, of whom, at
/// which source — and what that source said of the account when the list was opened.
struct PeopleList: Hashable, Sendable, Identifiable {
    enum Which: String, Hashable, Sendable, CaseIterable {
        /// Whom they follow.
        case following
        /// Who follows them.
        case followers
        /// The people in the source's own directory (#315): nobody's list.
        case directory
        /// The people the source found for a search's words (#319): nobody's list either.
        case found
        /// The people the source suggests whoever is signed in (#315): nobody's list either.
        case suggested
        /// The people who ask to follow whoever is signed in (#313): the reader's own, asked
        /// only as them.
        case requests
        /// The people somebody features on their profile (#315).
        case featured
        /// The people whoever is signed in mutes, and blocks (#314): the reader's own, asked
        /// only as them.
        case muted
        case blocked
        /// Who boosted a post, and who favourited it (#334): the post's, by the id its source
        /// gave it, and given to anyone.
        case boostedBy
        case favouritedBy

        /// The two lists that are somebody's, in the order their page counts them.
        static let ofSomebody: [Which] = [.following, .followers]
    }

    let which: Which
    /// The host of the source that keeps the list, and is asked for it.
    let host: String
    /// The source's own name for the account the list is of.
    let accountID: String
    /// Whose list it is, by their handle as the source sent it. A line of ours says `lineHandle`.
    let handle: String
    /// What the source counts in this list, where it said: **its figure, never a promise of rows**.
    let counted: Int?
    /// Whether the account says it hides its lists — the one thing that tells a hidden list
    /// from an empty one.
    let hidden: Bool
    /// The words a source was asked to find people for, as they were sent: nothing on any
    /// other list.
    var words = ""

    /// The list itself: two openings of one list are one page, whatever was counted each time.
    /// The people found for other words are another list.
    var id: String { "\(host)\u{1e}\(which.rawValue)\u{1e}\(accountID)" + (which == .found ? "\u{1e}" + words : "") }

    /// The words as a line of ours says them.
    var lineWords: String { LineText.oneLine(words, limit: SearchBands.wordsShown) }

    var lineHandle: String { LineText.oneLine(handle) }

    /// One of the two lists of somebody, as their source said them.
    init(_ which: Which, of person: Person) {
        self.which = which
        host = person.source.host
        accountID = person.accountID
        handle = person.handle
        switch which {
        case .following: counted = person.tally.following
        case .followers: counted = person.tally.followers
        // Not somebody's: a directory is made by `init(directoryAt:)`, and counts nobody.
        case .directory, .found, .suggested, .requests, .featured, .muted, .blocked, .boostedBy, .favouritedBy: counted = nil
        }
        hidden = person.hidesLists
    }

    /// Who boosted or favourited the post `id` at `host` (#334), written by `author`: the post's
    /// list and nobody's account, counted as the source last counted the post, hidden by nobody.
    init(_ which: Which, ofPost id: String, at host: String, by author: String, counted: Int?) {
        self.which = which
        self.host = host
        accountID = id
        handle = author
        self.counted = counted
        hidden = false
    }

    /// The people whoever is signed in to the source at `host` mutes, or blocks (#314): of no
    /// account named here, counted by nobody — the source gives no figure — and hidden by nobody.
    init(_ which: Which, at host: String) {
        self.which = which
        self.host = host
        accountID = ""
        handle = ""
        counted = nil
        hidden = false
    }

    /// Whether the list is the reader's own whoever's page it was reached from, and is asked
    /// only as them: who asks to follow them, and whom they mute and block (#314).
    var isReadersOwn: Bool { which == .requests || which == .muted || which == .blocked }

    /// The people who ask to follow whoever is signed in to the source at `host` (#313): of
    /// no account named here, counted by nobody on the list itself, and hidden by nobody.
    init(requestsAt host: String) {
        which = .requests
        self.host = host
        accountID = ""
        handle = ""
        counted = nil
        hidden = false
    }

    /// The people the source at `host` found for `words` (#319): of no account, counted by
    /// nobody, and hidden by nobody.
    init(foundAt host: String, words: String) {
        which = .found
        self.host = host
        accountID = ""
        handle = ""
        counted = nil
        hidden = false
        self.words = words
    }

    /// The directory of the source at `host` (#315): of no account, counted by nobody, and
    /// hidden by nobody.
    init(directoryAt host: String) {
        which = .directory
        self.host = host
        accountID = ""
        handle = ""
        counted = nil
        hidden = false
    }

    /// The people `person` features on their profile (#315), as their source said them:
    /// counted by nobody — the source gives no figure of them — and hidden by nobody.
    init(featuredBy person: Person) {
        which = .featured
        host = person.source.host
        accountID = person.accountID
        handle = person.handle
        counted = nil
        hidden = false
    }

    /// The people the source at `host` suggests whoever is signed in there (#315): of no
    /// account, counted by nobody, and hidden by nobody.
    init(suggestedAt host: String) {
        which = .suggested
        self.host = host
        accountID = ""
        handle = ""
        counted = nil
        hidden = false
    }

    /// Whether this is a source's directory, and not a list of somebody's.
    var isDirectory: Bool { which == .directory }

    /// What the source is asked for, where the list is somebody's. A directory is asked for by
    /// a reader of its own.
    var asked: MastodonPeople.List? {
        switch which {
        case .following: .following(of: accountID)
        case .followers: .followers(of: accountID)
        case .requests: .requests
        case .featured: .featured(by: accountID)
        case .muted: .muted
        case .blocked: .blocked
        case .boostedBy: .boostedBy(post: accountID)
        case .favouritedBy: .favouritedBy(post: accountID)
        case .directory, .found, .suggested: nil
        }
    }

    /// Whether the list is read on by how many people were passed over, and so only as far
    /// as such a list is read: a directory, the people a search found, and the people suggested.
    var readByCount: Bool { which == .directory || which == .found || which == .suggested }

    /// The thing of a host this list is, where a host may have it or not — and says which by
    /// its own address (`ShellHostsKnown`). Nothing for a list every such host has.
    var thing: MastodonHostThing? {
        switch which {
        case .directory: .directory
        case .suggested: .suggestions
        case .featured: .featuredPeople
        case .following, .followers, .found, .requests, .muted, .blocked, .boostedBy, .favouritedBy: nil
        }
    }
}

/// How a source's directory is asked for: in which order, and whether only of the people who
/// live there.
struct DirectoryChoice: Hashable, Sendable {
    var order: DirectoryOrder = .active
    var localOnly = false
}

/// Every list of people opened this run, by which list it is.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellPeoplePages {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// One list: who the source gave, and how far it was read.
    private struct Page {
        /// The host of the source asked: what its lists are let go by when its reader changes.
        let host: String
        var askedAs: AskedAs
        /// The count of that host's sign-ins when the list was asked: what tells a reader no
        /// handle tells from the one before, so a list given to one is not there for the next.
        let under: Int
        var read = PeopleRead()
        /// Whether a first stretch has answered: what is drawn is then the source's word.
        var answered = false
        /// Whether the list is being asked from the top.
        var asking = false
        /// Whether asking from the top last came to a failure. With nothing answered that is
        /// the page; with a list already given, it is said beside the list, which stands.
        var failed = false
        var readingOn = false
        var footFailed = false
        /// The source stopped handing the list on in order: it ends where it is.
        var notPaging = false
        /// How a directory was asked for, for the people that stand; and how the ask from the
        /// top now on the wire asks for it, where that is another way.
        var choice = DirectoryChoice()
        var wanted: DirectoryChoice?
        /// The host answered that it has no such address: there is no directory to draw.
        var absent = false
        /// A directory's last stretch brought people and named no next: it was read as far as
        /// one is read, which is not its end — only a stretch with nobody is that.
        var farthest = false
        /// The number of the ask or the reading-on whose answer this list awaits.
        var awaits = 0
        /// Which page this is, of all made this run: a page let go and made again is another.
        let number: Int
        /// How the reader stands to the people listed, as the source last said, by the id it
        /// knows each by: only whom it has said of.
        var stands: [String: PersonStanding] = [:]
        /// Whom the source was asked about since the list was last read from the top: nobody
        /// is asked about twice.
        var stood: Set<String> = []
        /// How often the list was read from the top: what an answer about an earlier reading
        /// is told by.
        var round = 0
        /// Who left the list by a press the source answered (#313) — a request answered, a
        /// follower removed, a suggestion dismissed (#315) — by the id it knows each by, each
        /// with the number the count stood at when the source answered: **a read from the top
        /// begun before that does not bring them back**, and one begun after is the list.
        var gone: [String: Int] = [:]

        /// Whether asking came to something. A list that is not settled and has nothing on the
        /// wire — an ask that was stopped — is asked again when it is opened.
        var settled: Bool { answered || failed }
    }

    /// How many lists are kept.
    static let kept = 8
    /// How long a stretch is asked to be: the most a source gives in one, so a long list costs
    /// the fewest asks.
    static let stretchLength = 80

    private var pages: [String: Page] = [:]
    /// The lists whose last ask from the top was stopped (`stop`), until they are asked again.
    private var halted: Set<String> = []
    /// The account check at each host whose count of who asks to follow the reader a request
    /// answered here has made old (`MastodonSessions.askingCheck`). **Kept for the host, not
    /// the page**: a page let go and made again does not bring the old figure back; the next
    /// check does, with its own.
    private var askingOld: [String: Int] = [:]
    /// The suggestions being dismissed, by list and the id the source knows each by: the row
    /// is off the list while the press is out (#315). The one guard of a press.
    private var dismissing = PressGuard<String, Bool>()
    /// The dismissals that did not arrive, by list and id: said under the row until the list
    /// is read again from the top, or the row is pressed again.
    private var dismissMissed: Set<String> = []
    @ObservationIgnored private var order = PageOrder()
    /// The one ask on the wire for each list — from the top, or a reading-on.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    /// Whose sign-in each host's pages were last read through: a person's pages' own, so a
    /// reader who changes lets the lists and the pages of that host go together.
    @ObservationIgnored private let readers: PageReaders
    /// What this run knows each host has: where a directory's not-found is written down.
    @ObservationIgnored private let hosts: ShellHostsKnown
    /// Where a press on a row is sent (#313): the one sequence a press on somebody's page
    /// goes through. Handed in by whoever holds both, once both are made; it holds no way
    /// back to these lists.
    @ObservationIgnored var acts: ShellPersonActs?
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a source's lists, where a test reaches them by one — a wire that goes on
    /// answering an ask that was called off, as a transfer already ended does. Nothing in the app.
    @ObservationIgnored var reaching: ((Source) -> MastodonPeople)?
    /// The same, to a source's directory.
    @ObservationIgnored var reachingDirectory: ((Source) -> MastodonDirectory)?
    /// The same, to the people a source suggests.
    @ObservationIgnored var reachingSuggestions: ((Source) -> MastodonSuggestions)?

    /// One stretch of a list, by whichever reader its kind of list has: the first, or the one
    /// after the place the source named.
    private typealias Stretches = @Sendable (_ next: String?) async throws -> PeopleStretch

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    /// A list opening, as its pane's task is named: which list **and who asks**, so a list in
    /// front whose reader ends, begins or changes opens again by itself, and is asked.
    static func opening(_ list: PeopleList, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(
            id: list.id, askedAs: ShellPersonPages.askedAs(at: list.host, in: session),
            under: ShellPersonPages.signIns(at: list.host, in: session)
        )
    }

    /// Every list of `host` let go, and its ask called off — from the top or a reading-on: its
    /// reader is no longer who they were given to (`PageReaders`). Whatever an ask already out
    /// brings, it brings to no list.
    func letGo(at host: String) {
        for (id, page) in pages where page.host == host {
            asks[id]?.cancel()
            asks[id] = nil
            pages[id] = nil
            order.forget(id)
        }
    }

    /// One list let go, and its ask called off: somebody's page was asked again with another
    /// tab in front (`ShellPersonPages.again`), so this one asks when it is next in front.
    func forget(_ list: PeopleList) {
        asks[list.id]?.cancel()
        asks[list.id] = nil
        pages[list.id] = nil
        order.forget(list.id)
    }

    // MARK: - What the page is handed

    /// The list as it stands **for whoever would ask now**, or nothing: it was never opened, or
    /// it was asked as somebody else.
    private func standing(_ list: PeopleList, at source: Source, in session: ShellSession) -> Page? {
        pages[list.id].flatMap {
            $0.under == ShellPersonPages.signIns(at: source.host, in: session)
                && $0.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: source.host, in: session)) ? $0 : nil
        }
    }

    /// What the page of `list` is handed, or nothing where its source is not one that says who
    /// people are: there is then no such list to draw.
    func said(of list: PeopleList, in session: ShellSession) -> PeopleSaid? {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return nil }
        let now = ShellPersonPages.askedAs(at: source.host, in: session)
        // **Whose own list this is is known by handle and no other way**: a reader the source
        // has not named — a sign-in that only reads — is not known to be looking at their own.
        // Who asks to follow the reader is said to the reader, and drawn for nobody else.
        if list.isReadersOwn, now == .nobody { return nil }
        var handed = PeopleSaid(list: list, signedIn: now != .nobody, own: Self.isOwn(list, as: now, in: session))
        handed.acts = Self.rowActs(of: handed, at: source, in: session)
        handed.lock = Self.rowLock(of: handed, at: source, in: session)
        if list.which == .suggested { handed.dismissing = Self.dismissOffer(at: source.host, in: session) }
        if Self.takesOff(handed, at: source), !ShellPersonActs.features(at: source.host, in: session) {
            handed.accountLock = session.mastodon.place(PersonAct.unfeature.needs, host: source.host)
                ?? PartWords.Place(kind: .none, key: "part.account.unasked")
        }
        let page = self.standing(list, at: source, in: session)
        // How many ask is the source's word only where the sign-in's account check said it: the
        // figure the way to this list carried, said again over it, and never worked out from rows.
        // **Only while it holds**: once a request is answered here it is old until the check
        // runs again, and it is not counted down — the next check may already count the answer.
        if list.which == .requests, askingOld[source.host] != session.mastodon.askingCheck(host: source.host) {
            handed.tally = session.mastodon.asking(host: source.host)
        }
        if list.isDirectory { handed.sorting = page.map { $0.wanted ?? $0.choice } ?? DirectoryChoice() }
        // The host's own word that it has no such address, as the run or this page heard it.
        if let thing = list.thing, page?.absent == true || hosts.has(thing, at: source.host) == .absent {
            handed.reading = .absent
            handed.asking = page?.asking ?? false
            return handed
        }
        guard let page else { return handed }
        handed.reading = page.answered ? .said : page.failed ? .failed : .asking
        handed.people = page.read.people.filter { person in
            page.gone[person.accountID] == nil && dismissing.shown(Self.dismissKey(list, person.accountID)) == nil
                && acts?.isLeaving(DummyPerson(person).id, from: list.which, at: source.host, in: session) != true
        }
        handed.missed = Self.missed(among: handed.people, of: list.which, by: acts, at: source.host)
        for person in handed.people where dismissMissed.contains(Self.dismissKey(list, person.accountID)) {
            handed.missed[person.accountID] = PersonActing.missedWords(.dismissSuggestion, named: person.lineHandle, at: source.host)
        }
        handed.stands = page.stands
        handed.asking = page.asking
        handed.foot = Self.foot(of: page)
        return handed
    }

    /// What stands under the rows. **Nothing while a stretch is on the wire**, and a stretch
    /// that did not come is the foot that reads on again: both are the toast's to say.
    private static func foot(of page: Page) -> PeopleSaid.Foot? {
        guard page.answered, !page.readingOn else { return nil }
        if page.notPaging { return .stopped }
        // A directory read as far as one is read: more may be there, and no press reads it.
        if page.farthest, page.read.next == nil { return .farthest }
        if page.read.next != nil { return .more }
        // Nothing under nobody: what stands there says what the source gave.
        return page.read.people.isEmpty ? nil : .end
    }

    /// Whether `list` is the reader's own: who asks to follow them, and the two lists of the
    /// account their sign-in is of. **By the id the source's own check gave that sign-in,
    /// where it is held** — a handle is a name, and another account may be shown under the
    /// same one; by the handle only where no id is held, as it always was.
    private static func isOwn(_ list: PeopleList, as now: AskedAs, in session: ShellSession) -> Bool {
        if list.isReadersOwn { return now != .nobody }
        guard now != .nobody else { return false }
        if let reader = session.mastodon.reader(host: list.host) { return reader.id == list.accountID }
        return now == .reader(list.handle)
    }

    /// Which lists have rows that offer something (#313): the requests, and the reader's own
    /// followers, at a source where somebody is followed.
    private static func offersRows(_ said: PeopleSaid, at source: Source) -> Bool {
        guard said.own, ShellPersonActs.offersFollowing(source) else { return false }
        return said.list.which == .requests || said.list.which == .followers || mutesOrBlocks(said.list)
    }

    /// Whether `list` is whom the reader mutes or blocks (#314): its rows are taken back under
    /// muting and blocking's part, and not following's.
    private static func mutesOrBlocks(_ list: PeopleList) -> Bool {
        list.which == .muted || list.which == .blocked
    }

    /// How the sign-in stands where such a list's rows would offer something and it may not
    /// change who follows whom: its place for following, or — held in part with the rest not
    /// to be asked for — the sentence that says so, unpressed.
    private static func rowLock(of said: PeopleSaid, at source: Source, in session: ShellSession) -> PartWords.Place? {
        guard offersRows(said, at: source) else { return nil }
        if mutesOrBlocks(said.list) {
            guard !ShellPersonActs.blocks(at: source.host, in: session) else { return nil }
            return session.mastodon.place(.blocks, host: source.host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
        }
        guard !ShellPersonActs.changes(at: source.host, in: session) else { return nil }
        return session.mastodon.place(.follows, host: source.host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
    }

    /// What a row of the list offers (#313), in the order it is drawn: accepting and refusing
    /// on the requests, removing on the reader's own followers — and nothing on anybody
    /// else's list, on any other, or to a sign-in that may not change who follows whom.
    private static func rowActs(of said: PeopleSaid, at source: Source, in session: ShellSession) -> [PersonAct] {
        if takesOff(said, at: source) { return ShellPersonActs.features(at: source.host, in: session) ? [.unfeature] : [] }
        guard offersRows(said, at: source) else { return [] }
        if mutesOrBlocks(said.list) {
            guard ShellPersonActs.blocks(at: source.host, in: session) else { return [] }
            return said.list.which == .muted ? [.unmute] : [.unblock]
        }
        guard ShellPersonActs.changes(at: source.host, in: session) else { return [] }
        switch said.list.which {
        case .requests: return [.acceptRequest, .refuseRequest]
        case .followers: return [.removeFollower]
        case .following, .directory, .found, .suggested, .featured, .muted, .blocked, .boostedBy, .favouritedBy: return []
        }
    }

    /// Whether the rows of `said` offer Take off your profile (#315): the reader's own people
    /// featured, at a source where somebody is followed — only somebody followed is featured.
    private static func takesOff(_ said: PeopleSaid, at source: Source) -> Bool {
        said.own && said.list.which == .featured && ShellPersonActs.offersFollowing(source)
    }

    /// How "Don't suggest" stands on a row of the people a source suggests (#315): offered
    /// where the sign-in holds the account part, and otherwise dim with that part's lock.
    private static func dismissOffer(at host: String, in session: ShellSession) -> PeopleSaid.Dismissing {
        guard session.mastodon.standing(PersonAct.dismissSuggestion.needs, host: host) != .held else { return .offered }
        return .locked(
            session.mastodon.place(PersonAct.dismissSuggestion.needs, host: host)
                ?? PartWords.Place(kind: .none, key: "part.account.unasked")
        )
    }

    private static func dismissKey(_ list: PeopleList, _ accountID: String) -> String {
        list.id + "\u{1e}" + accountID
    }

    /// The sentence of each row whose press did not arrive, by the id the source knows them by.
    private static func missed(
        among people: [Person], of which: PeopleList.Which, by acts: ShellPersonActs?, at host: String
    ) -> [String: String] {
        guard let acts else { return [:] }
        var said: [String: String] = [:]
        for person in people {
            guard let act = acts.missedOnARow(DummyPerson(person).id), ShellPersonActs.isOfARow(act, on: which) else { continue }

            said[person.accountID] = PersonActing.missedWords(act, named: person.lineHandle, at: host)
        }
        return said
    }

    /// A press on the row of `person` in `list` (#313): their request accepted or refused, or
    /// they are removed from following the reader. **Only what that list offers its rows, of
    /// somebody it lists**; sent through the one sequence a press on somebody's page is
    /// (`ShellPersonActs.pressRow`). The row leaves at the press, comes back where the press
    /// did not arrive, and is gone for good once the source has answered — **where the list
    /// is still the one pressed on, for the same reader**. One read again from the top while
    /// the press was out was answered before the source had taken the press, and may still
    /// list them: the answer to the press is the newer word, so they stay off it. A read that
    /// lands after the answer is newer still, and is the list.
    func press(_ act: PersonAct, on person: Person, of list: PeopleList, in session: ShellSession) async {
        if act == .dismissSuggestion {
            await dismiss(person, of: list, in: session)
            return
        }
        // Take off your profile where the sign-in lacks the account part only asks for it.
        if act == .unfeature, let lock = said(of: list, in: session)?.accountLock {
            if lock.asks { session.askFor([act.needs], host: list.host) }
            return
        }

        guard let acts, let source = ShellPersonPages.source(at: list.host, in: session),
              let page = self.standing(list, at: source, in: session),
              let offered = said(of: list, in: session), offered.acts.contains(act),
              offered.people.contains(where: { $0.accountID == person.accountID })
        else { return }
        let came = await acts.pressRowCame(act, on: person, standing: page.stands[person.accountID], listed: list.which, in: session)
        // A mute or a block taken back from the reader's list of them: what was hidden shows (#314)
        // once the source did it, whatever became of the row.
        if came.sourceDid { ShellPersonPages.undone(act, of: person, in: session) }
        guard came.taken else { return }
        // Answered: the count of who asks is old, whichever page now stands for the list.
        if list.which == .requests { askingOld[source.host] = session.mastodon.askingCheck(host: source.host) }
        guard self.standing(list, at: source, in: session)?.number == page.number else { return }
        pages[list.id]?.gone[person.accountID] = errands.next()
    }

    /// "Don't suggest" on the row of `person` among the people a source suggests (#315): the
    /// source told not to suggest them to the reader again. **Only where the sign-in holds
    /// the account part** — otherwise the press only raises the question that asks for it —
    /// **of somebody the list holds, with no such press out for them.**
    ///
    /// The row leaves at the press; where the press did not arrive it comes back with the
    /// sentence that says so under it. Answered, they are gone from the list: a read from the
    /// top already on its way then was answered before the source took the press, and does
    /// not bring them back. The next read begun after it is the source's word.
    func dismiss(_ person: Person, of list: PeopleList, in session: ShellSession) async {
        guard list.which == .suggested, let source = ShellPersonPages.source(at: list.host, in: session),
              let offered = said(of: list, in: session), offered.people.contains(where: { $0.accountID == person.accountID })
        else { return }
        guard offered.dismissing == .offered else {
            if case .locked(let place) = offered.dismissing, place.asks {
                session.askFor([PersonAct.dismissSuggestion.needs], host: source.host)
            }
            return
        }
        let looked = readers.look(at: source.host, in: session)
        let key = Self.dismissKey(list, person.accountID)
        guard let held = looked.held, !looked.changed, let page = self.standing(list, at: source, in: session),
              let flight = dismissing.begin(key, showing: true)
        else { return }
        dismissMissed.remove(key)
        let through = reachingSuggestions?(source)
            ?? session.reach.suggestions(session.mastodon.authorized(token: held, within: deadline, for: .write))
        let accountID = person.accountID
        await Task {
            var done = false
            do {
                try await through.dismiss(accountID: accountID)
                done = true
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: page.askedAs, in: session)
            }
            guard self.dismissing.isStill(flight, key) else { return }
            self.dismissing.settle(key)
            guard session.mastodon.token(host: source.host)?.accessToken == held.accessToken,
                  self.standing(list, at: source, in: session)?.number == page.number
            else { return }
            if done {
                self.pages[list.id]?.gone[accountID] = self.errands.next()
            } else {
                self.dismissMissed.insert(key)
            }
        }.value
    }

    /// The rows `j` and `k` walk on the page of `list`, by who they are.
    func walked(_ list: PeopleList, in session: ShellSession) -> [String] {
        said(of: list, in: session)?.people.map(\.id) ?? []
    }

    /// The person on the row `id` of `list`, where the list as it is drawn holds them.
    func person(_ id: String, on list: PeopleList, in session: ShellSession) -> Person? {
        said(of: list, in: session)?.people.first { $0.id == id }
    }

    /// Whether the people a search found at `list`'s source can be answered to whoever would
    /// ask now: their list can be said, somebody is signed in there — a search is answered to
    /// nobody else — and that sign-in's own words do not say it may not search. **One whose
    /// words were never written down is not known to lack it**, as the look-up reads a sign-in
    /// (`ShellSearchFound.note`). With none of that, a tab of them could only ever say it could
    /// not be asked.
    func searchable(_ list: PeopleList, in session: ShellSession) -> Bool {
        guard let said = said(of: list, in: session), said.signedIn else { return false }
        return session.mastodon.heldParts[list.host.lowercased()]?.scopes.map(MastodonOAuth.searches) ?? true
    }

    /// Whether the page of `list` has anybody to ask again — what `r` and its mark go by.
    func canAskAgain(_ list: PeopleList, in session: ShellSession) -> Bool {
        ShellPersonPages.source(at: list.host, in: session) != nil
    }

    /// What the page of `list` says in its toast (DESIGN-reload), in the words its kind of list
    /// has: asked from the top — a wait Stop stops — or read on, which is not; that the last
    /// ask did not come; or that it was stopped. A list the source says it has not is no
    /// failure: that is said over its rows.
    func ask(of list: PeopleList, in session: ShellSession, language: DummyLanguage? = nil) -> PageAsking {
        guard let source = ShellPersonPages.source(at: list.host, in: session),
              let page = self.standing(list, at: source, in: session)
        else { return PageAsking() }
        let asking = page.asking
            ? TimelineToast.waiting(PeopleSaid.words(list.which) + ".asking", hosts: [source.host], language: language)
            : page.readingOn ? L10n.t("people.foot.reading", language: language) : nil
        return PageAsking(
            asking: asking, stoppable: page.asking,
            failed: !page.asking && !page.readingOn && (page.failed || page.footFailed) ? [source.host] : [],
            stopped: halted.contains(list.id)
        )
    }

    /// The list's Stop, and `Escape` on it: the ask from the top called off, the list as it was
    /// asked before, and whatever is on the wire landing nowhere. A stop is never a failure,
    /// and a reading-on is not stopped. Whether anything was.
    @discardableResult
    func stop(_ list: PeopleList) -> Bool {
        let id = list.id
        guard pages[id]?.asking == true else { return false }
        asks[id]?.cancel()
        asks[id] = nil
        pages[id]?.awaits = errands.next()
        pages[id]?.asking = false
        pages[id]?.wanted = nil
        halted.insert(id)
        return true
    }

    // MARK: - Asking

    /// The list opening. Asked once: opened again, it is drawn from what was answered; opened
    /// while it is being asked, it waits on that ask and starts none; opened after an ask that
    /// came to nothing, or as somebody else, it is asked again.
    func opened(_ list: PeopleList, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        // Who asks to follow the reader is asked of the source as them, and never unsigned.
        if list.isReadersOwn, held == nil { return }
        // A thing the host said it has not is not asked for by being opened.
        if let thing = list.thing, hosts.has(thing, at: source.host) == .absent { return }
        if let page = self.standing(list, at: source, in: session) {
            order.touch(list.id)
            named(list.id, as: ShellPersonPages.askedAs(at: source.host, in: session))
            if page.asking {
                await asks[list.id]?.value
                return
            }
            if page.settled { return }
        }
        await begin(list, at: source, with: held, in: session).value
    }

    /// `r`, the mark and a pull: the list asked from the top. What the page holds stays drawn until
    /// the answer lands, and is then replaced by it. **A press while the list is being asked
    /// asks nothing.**
    func again(_ list: PeopleList, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        if self.standing(list, at: source, in: session)?.asking == true { return }
        // The person's own asking again of a thing the host said it has not: what the run
        // knew of that host is let go, so nothing stays absent until the app is quit.
        if let thing = list.thing, hosts.has(thing, at: source.host) == .absent { hosts.askAfresh(source.host) }
        await begin(list, at: source, with: held, in: session).value
    }

    /// The order of a directory chosen, or only the people who live there: the directory asked
    /// from the top that way. What the page holds stays drawn until the answer lands, and is
    /// then replaced by it; an ask that fails leaves the page as it was asked before. **A
    /// choice made while the list is being asked asks nothing and changes nothing**, and so
    /// does the choice the page already stands by.
    func choose(_ choice: DirectoryChoice, for list: PeopleList, in session: ShellSession) async {
        guard list.isDirectory, let source = ShellPersonPages.source(at: list.host, in: session),
              hosts.has(.directory, at: source.host) != .absent
        else { return }
        let held = readers.look(at: source.host, in: session).held
        let page = self.standing(list, at: source, in: session)
        if page?.asking == true || (page?.choice ?? DirectoryChoice()) == choice { return }
        await begin(list, at: source, with: held, choosing: choice, in: session).value
    }

    /// Starts the ask from the top, and hands back the task it runs in. Everything it needs is
    /// taken here, before anything waits: the source, who asks, the door.
    private func begin(
        _ list: PeopleList, at source: Source, with held: MastodonToken?, choosing: DirectoryChoice? = nil,
        in session: ShellSession
    ) -> Task<Void, Never> {
        let id = list.id
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        if self.standing(list, at: source, in: session) == nil {
            // Nobody's list yet, or somebody else's: what was given to them is not given to this one.
            pages[id] = Page(
                host: source.host, askedAs: askedAs, under: ShellPersonPages.signIns(at: source.host, in: session),
                number: errands.next()
            )
        }
        named(id, as: askedAs)
        keep(id)
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.asking = true
        halted.remove(id)
        // A reading-on still on the wire is this ask's to supersede: it is called off, so one
        // ask is out for the list, and whatever it brings late does not land.
        asks[id]?.cancel()
        pages[id]?.readingOn = false
        let choice = choosing ?? pages[id]?.choice ?? DirectoryChoice()
        pages[id]?.wanted = choice
        // An ask begun is an ask not yet answered: what the page last heard of the address is
        // not said while it is out, nor after it if it fails another way.
        pages[id]?.absent = false
        let through = self.door(to: list, asked: choice, at: source, with: held, in: session)
        let round = hosts.round(at: source.host)
        let task = Task {
            await self.ask(
                list, of: through, asked: choice, at: source, as: askedAs, with: held, errand: errand, round: round,
                in: session
            )
        }
        asks[id] = task
        return task
    }

    private func ask(
        _ list: PeopleList, of through: Stretches, asked choice: DirectoryChoice, at source: Source,
        as askedAs: AskedAs, with held: MastodonToken?, errand: Int, round: Int, in session: ShellSession
    ) async {
        let id = list.id
        defer { if pages[id]?.awaits == errand { asks[id] = nil } }
        var reached: [Person] = []
        do {
            let first = try await through(nil)
            guard pages[id]?.awaits == errand else { return }
            // From the top: what was read before is replaced whole.
            let fresh = try PeopleRead().readingOn(first)
            pages[id]?.read = fresh
            // And everybody in it is asked about afresh. What the source said of whoever is
            // still listed stands until it says again.
            let listed = Set(fresh.people.map(\.accountID))
            let standing = pages[id]?.stands.filter { listed.contains($0.key) } ?? [:]
            pages[id]?.stands = standing
            pages[id]?.stood = []
            // And a press on a row that did not arrive is said no longer: the rows are new.
            for person in fresh.people {
                acts?.forgetMissedOnARow(DummyPerson(person).id, on: list.which)
                dismissMissed.remove(Self.dismissKey(list, person.accountID))
            }
            // Whoever left by a press answered after this read set out stays off it.
            let stillGone = pages[id]?.gone.filter { $0.value > errand } ?? [:]
            pages[id]?.gone = stillGone
            pages[id]?.round += 1
            reached = fresh.people
            pages[id]?.answered = true
            pages[id]?.failed = false
            pages[id]?.footFailed = false
            pages[id]?.notPaging = false
            pages[id]?.absent = false
            pages[id]?.choice = choice
            pages[id]?.farthest = Self.stoppedShortOfTheEnd(first, of: list, after: nil)
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if Self.saysNoSuchAddress(error) {
                gone(list, at: source, round: round)
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[id]?.failed = true
            }
        }
        // The way asked for stands only once it has answered: failed or stopped, the page is
        // as it was asked before.
        pages[id]?.wanted = nil
        pages[id]?.asking = false
        await stand(to: reached, on: list, at: source, with: held, in: session)
    }

    // MARK: - How the reader stands to them

    /// Whether an answer about the people of the page numbered `number`, as it was read from
    /// the top the `round`th time, is still that page's to take: it stands **for whoever would
    /// ask now**, and is that page and that reading of it.
    private func isStill(_ number: Int, round: Int, of list: PeopleList, at source: Source, in session: ShellSession) -> Bool {
        self.standing(list, at: source, in: session).map { $0.number == number && $0.round == round } ?? false
    }

    /// The stretch `people` came in has landed: the source is asked how the reader stands to
    /// whoever of them it was not yet asked about — in one ask where they are no more than one
    /// ask names, and in one after another where a source sent a longer stretch than that.
    /// Nobody is asked about whom a person's page would not be told of
    /// (`ShellPersonActs.isTold`), and nobody for a list whose reader is no longer who the
    /// stretch was asked as.
    ///
    /// **An answer is the source's whole word of whoever it named**: somebody it says nothing
    /// of — no entry, or one that cannot be read — has no word here from then on, whatever it
    /// said of them before. An ask that fails takes nothing away.
    private func stand(
        to people: [Person], on list: PeopleList, at source: Source, with held: MastodonToken?,
        in session: ShellSession
    ) async {
        let id = list.id
        guard let held, let page = self.standing(list, at: source, in: session) else { return }
        var named: [String] = []
        for person in people where !page.stood.contains(person.accountID) && !named.contains(person.accountID) {
            if ShellPersonActs.isTold(of: DummyPerson(person).id, at: source, in: session) { named.append(person.accountID) }
        }
        guard !named.isEmpty else { return }
        pages[id]?.stood.formUnion(named)
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .people))
        let ticket = session.hides.ticket()
        var left = named[...]
        while !left.isEmpty {
            let asked = Array(left.prefix(MastodonStanding.most))
            left = left.dropFirst(asked.count)
            do {
                let said = try await through.standings(to: asked)
                guard isStill(page.number, round: page.round, of: list, at: source, in: session) else { return }
                for silent in asked where said[silent] == nil { pages[id]?.stands[silent] = nil }
                pages[id]?.stands.merge(said) { _, now in now }
                // A mute or a block the source says is no longer there hides nothing more (#314).
                for person in people {
                    if let now = said[person.accountID] {
                        ShellPersonActs.heard(now, key: DummyPerson(person).id, at: source.host, since: ticket, in: session)
                    }
                }
            } catch {
                // The rows stay as they are: nothing is said of it, and nothing is drawn in its
                // place. What it says of the sign-in is told whatever became of the list — to
                // whoever is still the reader it was asked as, and to nobody else (`concluded`).
                if !Cancellation.happened(error) {
                    ShellPersonPages.concluded(error, at: source, askedAs: page.askedAs, in: session)
                }
                return
            }
        }
    }

    /// Whether `stretch`, asked for after `next` and which brought people and named no next, is
    /// where the reading of `list` stopped and not where the list ends. A directory and the
    /// people a search found end only at a stretch with nobody; the people a source suggests
    /// end at a stretch shorter than was asked for, so theirs is the furthest read only where
    /// what was asked for reached it — by the place asked from, since how many of a stretch
    /// could be read says nothing of how many the source sent.
    private static func stoppedShortOfTheEnd(_ stretch: PeopleStretch, of list: PeopleList, after next: String?) -> Bool {
        guard stretch.next == nil, !stretch.people.isEmpty else { return false }
        switch list.which {
        case .directory, .found: return true
        case .suggested:
            let passed = next.flatMap(MastodonSuggestions.passed) ?? 0
            return passed + stretchLength >= MastodonSuggestions.furthest
        case .following, .followers, .requests, .featured, .muted, .blocked, .boostedBy, .favouritedBy: return false

        }
    }

    private static func saysNoSuchAddress(_ error: any Error) -> Bool {
        (error as? MastodonHostMoreError) == .noSuchAddress
    }

    /// The host's own word that the list's address is not there — **heard by the ask the
    /// page still awaits, and by no other**: absent for the run, and nobody it gave before is
    /// drawn as that list.
    private func gone(_ list: PeopleList, at source: Source, round: Int) {
        if let thing = list.thing { hosts.notFound(thing, at: source.host, round: round) }
        pages[list.id]?.absent = true
        pages[list.id]?.answered = false
        pages[list.id]?.failed = false
        pages[list.id]?.footFailed = false
        pages[list.id]?.read = PeopleRead()
        pages[list.id]?.stands = [:]
    }

    /// The foot's press: the stretch after what the page holds, by the place the source named.
    /// One at a time, none while the list is being asked from the top, and none where the
    /// source named no next or stopped handing the list on.
    ///
    /// **Pressed by a reader the list was not given to, it reads nothing on**: the list is let
    /// go, and asked afresh as them — begun here, and waited on by whoever opens it.
    func readOn(_ list: PeopleList, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return }
        let looked = readers.look(at: source.host, in: session)
        if looked.changed {
            _ = begin(list, at: source, with: looked.held, in: session)
            return
        }
        guard let page = self.standing(list, at: source, in: session),
              page.answered, !page.readingOn, !page.asking, !page.notPaging, let next = page.read.next
        else { return }
        let id = list.id
        let askedAs = page.askedAs
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.readingOn = true
        halted.remove(id)
        pages[id]?.footFailed = false
        // On in the way the people that stand were asked for.
        let through = self.door(to: list, asked: page.choice, at: source, with: looked.held, in: session)
        let round = hosts.round(at: source.host)
        let task = Task {
            await self.read(
                list, after: next, of: through, at: source, as: askedAs, with: looked.held, errand: errand, round: round,
                in: session
            )
        }
        asks[id] = task
        await task.value
    }

    private func read(
        _ list: PeopleList, after next: String, of through: Stretches, at source: Source, as askedAs: AskedAs,
        with held: MastodonToken?, errand: Int, round: Int, in session: ShellSession
    ) async {
        let id = list.id
        defer { if pages[id]?.awaits == errand { asks[id] = nil } }
        var reached: [Person] = []
        do {
            let came = try await through(next)
            guard pages[id]?.awaits == errand, let held = pages[id]?.read else { return }
            // Read first and written after: the two are not one access.
            let further = try held.readingOn(came)
            pages[id]?.read = further
            pages[id]?.farthest = Self.stoppedShortOfTheEnd(came, of: list, after: next)
            reached = came.people
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if error is PagingError {
                pages[id]?.notPaging = true
            } else if Self.saysNoSuchAddress(error) {
                gone(list, at: source, round: round)
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[id]?.footFailed = true
            }
        }
        pages[id]?.readingOn = false
        await stand(to: reached, on: list, at: source, with: held, in: session)
    }

    /// The way to the stretches of `list` at `source`. **A list of somebody's**: as the person
    /// where they are signed in to it, and with no token — listed, bounded, and under the small
    /// body's ceiling — where they are not. **A directory the same way**: as the reader through
    /// the signed-in door, which has its own ceiling and goes to its own host, so the source
    /// leaves out whom they block or mute; and with no token, small and of that host alone.
    private func door(
        to list: PeopleList, asked choice: DirectoryChoice, at source: Source, with held: MastodonToken?,
        in session: ShellSession
    ) -> Stretches {
        let length = Self.stretchLength
        if list.which == .found {
            // A search is answered only to somebody signed in: with no sign-in there is no way to it.
            guard let held else { return { _ in throw MastodonAuthError.http(401) } }
            let search = session.reach.search(session.mastodon.authorized(token: held, within: deadline, for: .search))
            let words = list.words
            return { next in
                var passed = 0
                if let next {
                    guard let count = MastodonSearch.passed(next) else { throw PagingError.notPaging }
                    passed = count
                }
                return try await search.people(matching: words, source: source, after: passed)
            }
        }
        if list.which == .suggested {
            // A source suggests nobody anything unsigned: with no sign-in there is no way to it.
            let suggestions: MastodonSuggestions
            if let reachingSuggestions {
                suggestions = reachingSuggestions(source)
            } else if let held {
                suggestions = session.reach.suggestions(session.mastodon.authorized(token: held, within: deadline, for: .people))
            } else {
                return { _ in throw MastodonAuthError.http(401) }
            }
            return { next in
                var passed = 0
                if let next {
                    guard let count = MastodonSuggestions.passed(next) else { throw PagingError.notPaging }
                    passed = count
                }
                return try await suggestions.stretch(source: source, after: passed, limit: length)
            }
        }
        guard let asked = list.asked else {
            let directory = reachingDirectory?(source)
                ?? held.map { session.reach.directory(session.mastodon.authorized(token: $0, within: deadline, for: .people)) }
                ?? session.reach.unsignedDirectory(source.host, for: .people, within: deadline)
            return { next in
                // A next that is no count of people passed over is not one this page was handed.
                var passed = 0
                if let next {
                    guard let count = MastodonDirectory.passed(next) else { throw PagingError.notPaging }
                    passed = count
                }
                return try await directory.stretch(
                    source: source, order: choice.order, localOnly: choice.localOnly, after: passed, limit: length
                )
            }
        }
        let people: MastodonPeople
        if let reaching {
            people = reaching(source)
        } else if let held {
            people = session.reach.people(session.mastodon.authorized(token: held, within: deadline, for: .people))
        } else {
            people = session.reach.unsignedPeople(source.host, for: .people, within: deadline)
        }
        return { next in try await people.stretch(asked, source: source, after: next, limit: length) }
    }

    /// Writes down the name the source has since given the reader a list was asked as.
    private func named(_ id: String, as now: AskedAs) {
        if case .reader(nil) = pages[id]?.askedAs, case .reader(.some) = now { pages[id]?.askedAs = now }
    }

    /// Keeps the list `id` among the newest `kept`, letting the oldest go — but never one with
    /// an ask still on the wire.
    private func keep(_ id: String) {
        let busy: (String) -> Bool = { self.pages[$0]?.asking == true || self.pages[$0]?.readingOn == true }
        for gone in order.keep(id, among: Self.kept, busy: busy) {
            pages[gone] = nil
            asks[gone] = nil
        }
    }
}
