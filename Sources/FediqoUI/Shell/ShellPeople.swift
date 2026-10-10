import FediqoCore
import Foundation
import Observation

// A list of people a source keeps (#311) — whom somebody follows, who follows them: what is
// asked, when, and what the page holds of the answers.
//
// **Asked when the list opens, and when the person presses** — a person's page's own rules
// (`ShellPersonPages`), kept here for a list. Opening asks one stretch; the foot's press asks
// the next, by the place the source named and no other; `r` and "Try again" ask from the top.
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

/// A list of people a source keeps, as a step of the walk names it: which list, of whom, at
/// which source — and what that source said of the account when the list was opened.
struct PeopleList: Hashable, Sendable, Identifiable {
    enum Which: String, Hashable, Sendable, CaseIterable {
        /// Whom they follow.
        case following
        /// Who follows them.
        case followers
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

    /// The list itself: two openings of one list are one page, whatever was counted each time.
    var id: String { "\(host)\u{1e}\(which.rawValue)\u{1e}\(accountID)" }

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
        }
        hidden = person.hidesLists
    }

    /// What the source is asked for.
    var asked: MastodonPeople.List {
        switch which {
        case .following: .following(of: accountID)
        case .followers: .followers(of: accountID)
        }
    }
}

extension ShellWalk {
    /// A list opened from the figure that counts it, on somebody's page (#311): one more step
    /// of the walk. **The lamp and the step in one turn**, as a row opens: the figure is lit
    /// and is what the walk remembers, so leaving the list gives it back — pressed by a pointer
    /// or a finger too, where the lamp was elsewhere or nowhere. A step that is not taken
    /// moves nothing.
    mutating func open(_ list: PeopleList, lamp: inout String?) -> Bool {
        guard walk(to: .people(list), from: list.id) else { return false }
        lamp = list.id
        return true
    }
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
        /// The number of the ask or the reading-on whose answer this list awaits.
        var awaits = 0

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
    @ObservationIgnored private var order = PageOrder()
    /// The one ask on the wire for each list — from the top, or a reading-on.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    /// Whose sign-in each host's pages were last read through: a person's pages' own, so a
    /// reader who changes lets the lists and the pages of that host go together.
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a source's lists, where a test reaches them by one — a wire that goes on
    /// answering an ask that was called off, as a transfer already ended does. Nothing in the app.
    @ObservationIgnored var reaching: ((Source) -> MastodonPeople)?

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    /// A list opening, as its pane's task is named: which list **and who asks**, so a list in
    /// front whose reader ends, begins or changes opens again by itself, and is asked.
    static func opening(_ list: PeopleList, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: list.id, askedAs: ShellPersonPages.askedAs(at: list.host, in: session))
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

    // MARK: - What the page is handed

    /// The list as it stands **for whoever would ask now**, or nothing: it was never opened, or
    /// it was asked as somebody else.
    private func standing(_ list: PeopleList, at source: Source, in session: ShellSession) -> Page? {
        pages[list.id].flatMap {
            $0.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: source.host, in: session)) ? $0 : nil
        }
    }

    /// What the page of `list` is handed, or nothing where its source is not one that says who
    /// people are: there is then no such list to draw.
    func said(of list: PeopleList, in session: ShellSession) -> PeopleSaid? {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return nil }
        let now = ShellPersonPages.askedAs(at: source.host, in: session)
        // **Whose own list this is is known by handle and no other way**: a reader the source
        // has not named — a sign-in that only reads — is not known to be looking at their own.
        var handed = PeopleSaid(list: list, signedIn: now != .nobody, own: now == .reader(list.handle))
        guard let page = self.standing(list, at: source, in: session) else { return handed }
        handed.reading = page.answered ? .said : page.failed ? .failed : .asking
        handed.againFailed = page.answered && page.failed
        handed.people = page.read.people
        handed.asking = page.asking
        handed.foot = Self.foot(of: page)
        return handed
    }

    private static func foot(of page: Page) -> PeopleSaid.Foot? {
        guard page.answered else { return nil }
        if page.readingOn { return .reading }
        if page.notPaging { return .stopped }
        if page.footFailed { return .failed }
        if page.read.next != nil { return .more }
        // Nothing under nobody: what stands there says what the source gave.
        return page.read.people.isEmpty ? nil : .end
    }

    /// The rows `j` and `k` walk on the page of `list`, by who they are.
    func walked(_ list: PeopleList, in session: ShellSession) -> [String] {
        said(of: list, in: session)?.people.map(\.id) ?? []
    }

    /// The person on the row `id` of `list`, where the list as it is drawn holds them.
    func person(_ id: String, on list: PeopleList, in session: ShellSession) -> Person? {
        said(of: list, in: session)?.people.first { $0.id == id }
    }

    /// Whether the page of `list` has anybody to ask again — what `r` and its mark go by.
    func canAskAgain(_ list: PeopleList, in session: ShellSession) -> Bool {
        ShellPersonPages.source(at: list.host, in: session) != nil
    }

    // MARK: - Asking

    /// The list opening. Asked once: opened again, it is drawn from what was answered; opened
    /// while it is being asked, it waits on that ask and starts none; opened after an ask that
    /// came to nothing, or as somebody else, it is asked again.
    func opened(_ list: PeopleList, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
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

    /// `r` and "Try again": the list asked from the top. What the page holds stays drawn until
    /// the answer lands, and is then replaced by it. **A press while the list is being asked
    /// asks nothing.**
    func again(_ list: PeopleList, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: list.host, in: session) else { return }
        let held = readers.look(at: source.host, in: session).held
        if self.standing(list, at: source, in: session)?.asking == true { return }
        await begin(list, at: source, with: held, in: session).value
    }

    /// Starts the ask from the top, and hands back the task it runs in. Everything it needs is
    /// taken here, before anything waits: the source, who asks, the door.
    private func begin(
        _ list: PeopleList, at source: Source, with held: MastodonToken?, in session: ShellSession
    ) -> Task<Void, Never> {
        let id = list.id
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        if pages[id]?.askedAs.isTheSame(as: askedAs) != true {
            // Nobody's list yet, or somebody else's: what was given to them is not given to this one.
            pages[id] = Page(host: source.host, askedAs: askedAs)
        }
        named(id, as: askedAs)
        keep(id)
        let errand = errands.next()
        pages[id]?.awaits = errand
        pages[id]?.asking = true
        // A reading-on still on the wire is this ask's to supersede: it is called off, so one
        // ask is out for the list, and whatever it brings late does not land.
        asks[id]?.cancel()
        pages[id]?.readingOn = false
        let through = self.door(to: source, with: held, in: session)
        let task = Task {
            await self.ask(list, of: through, at: source, as: askedAs, errand: errand, in: session)
        }
        asks[id] = task
        return task
    }

    private func ask(
        _ list: PeopleList, of through: MastodonPeople, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        let id = list.id
        defer { if pages[id]?.awaits == errand { asks[id] = nil } }
        do {
            let first = try await through.stretch(list.asked, source: source, limit: Self.stretchLength)
            guard pages[id]?.awaits == errand else { return }
            // From the top: what was read before is replaced whole.
            let fresh = try PeopleRead().readingOn(first)
            pages[id]?.read = fresh
            pages[id]?.answered = true
            pages[id]?.failed = false
            pages[id]?.footFailed = false
            pages[id]?.notPaging = false
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[id]?.failed = true
            }
        }
        pages[id]?.asking = false
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
        pages[id]?.footFailed = false
        let through = self.door(to: source, with: looked.held, in: session)
        let task = Task {
            await self.read(list, after: next, of: through, at: source, as: askedAs, errand: errand, in: session)
        }
        asks[id] = task
        await task.value
    }

    private func read(
        _ list: PeopleList, after next: String, of through: MastodonPeople, at source: Source, as askedAs: AskedAs,
        errand: Int, in session: ShellSession
    ) async {
        let id = list.id
        defer { if pages[id]?.awaits == errand { asks[id] = nil } }
        do {
            let came = try await through.stretch(list.asked, source: source, after: next, limit: Self.stretchLength)
            guard pages[id]?.awaits == errand, let held = pages[id]?.read else { return }
            // Read first and written after: the two are not one access.
            let further = try held.readingOn(came)
            pages[id]?.read = further
        } catch {
            guard pages[id]?.awaits == errand else { return }
            if error is PagingError {
                pages[id]?.notPaging = true
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[id]?.footFailed = true
            }
        }
        pages[id]?.readingOn = false
    }

    /// The door to `source`: as the person where they are signed in to it, and with no token
    /// — listed, bounded, and under the small body's ceiling — where they are not.
    private func door(to source: Source, with held: MastodonToken?, in session: ShellSession) -> MastodonPeople {
        if let reaching { return reaching(source) }
        if let held {
            return session.reach.people(session.mastodon.authorized(token: held, within: deadline, for: .people))
        }
        return session.reach.unsignedPeople(source.host, for: .people, within: deadline)
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
