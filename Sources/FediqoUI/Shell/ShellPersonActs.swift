import FediqoCore
import Foundation
import Observation

// How the reader stands to somebody at a source (#310), and following them there (#313): what
// is asked for it, when, and how a press is guarded.
//
// **Only where somebody is followed at that kind of source** — the one fact per kind there is
// (`SourceOffers.follows`), read here and by nobody who draws — **and only for a signed-in
// reader, of somebody else**: with no sign-in nothing is drawn and nobody is asked, and the
// reader's own page has no standing to itself. A reader the source has not named yet is told
// from nobody, so nothing is drawn for them until it has.
//
// **Asked when the page says who they are, and when the person presses.** How the reader
// stands is asked by the id the source knows them by, which the page learns from its first
// answer: one ask a page, and none again while it stands. `r` and a failure's "Try again" ask
// once more, and what was said before stays drawn until the answer lands.
//
// **Where the sign-in does not see who the reader follows, nothing is asked and nothing is
// guessed**: the page has the lock of how that sign-in stands (`PartWords.place`), whose press
// only raises the question. A sign-in that sees and may not change is shown how the reader
// stands, and its Follow is the lock.
//
// **A press is shown first, and guarded as a mark on a post is** — by `PressGuard`, the one
// guard a bookmark, a notice dismissed and a hashtag followed are pressed under: one request
// out a person, a press while it is out sends nothing, and the answer is taken only by the
// press that began it. What the source answers is what the page then says; a press that did
// not arrive leaves the page as the source last said and says so under the heading.
//
// **A read on its way does not undo an act.** While a press is out the page draws the press,
// whatever a read brings meanwhile. And when the press is answered, a read still out set out
// before that answer: it is called off and awaited no longer, so what it brings lands nowhere.
//
// **Following somebody of another server is settled by a read, and by nothing else.** A source
// answers that press "followed" and then says "asked" until their server agrees (asked of a
// real one: `MastodonStandingCaptures`), so the answer to the press is not how it stands and
// is never drawn. The source is read while the press is still out, and what it says is what
// the press came to; where that read fails the page says it could not ask, and offers asking
// again — it does not say "followed".
//
// **Every answer lands only where it is still the one awaited**, as whoever asked, and is let
// go with their sign-in (`PageReaders`); **held nowhere**. Each for the reason given where a
// person's page keeps the same rule (`ShellPersonPages`).
//
// **These reads conclude no sign-out** but the one the signed-in door confirmed by its own
// check (`ShellPersonPages.concluded`). A press refused because the sign-in's hold on follows
// was taken back elsewhere is said as any press that did not arrive.

/// How the reader stands to each person whose page was opened this run, and the presses out.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellPersonActs {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// How the reader stands to one person at one source.
    private struct Page {
        let host: String
        /// The id the source knows them by: who was asked about.
        let accountID: String
        /// Whether they live on another server: following them is settled only by a read.
        let far: Bool
        var askedAs: AskedAs
        /// How often the sign-in at its host had become another when the page was made.
        let under: Int
        /// Which page this is, of all made this run: a page let go and made again is another.
        let number: Int
        /// As the source last said, or nothing where it has not.
        var said: PersonStanding?
        /// Whether the last read was answered with nothing about them.
        var unsaid = false
        /// Whether the last read failed.
        var failed = false
        /// Whether a read is on the wire.
        var asking = false
        /// The number of the read whose answer this page awaits.
        var awaits = 0
    }

    /// Which page a `.task` is: who they are to the source, who asks, and whether their
    /// sign-in sees how they stand — so a reader who ends, begins or changes, and a sign-in
    /// given follows, each open the page again by themselves.
    struct Opening: Hashable {
        let id: String
        let accountID: String
        let askedAs: AskedAs
        let under: Int
    }

    /// What a press out is drawn as, and whose it is.
    private struct Pressed {
        let host: String
        /// How often the sign-in at its host had become another when it was pressed: a press
        /// is drawn only for the reader who made it.
        let under: Int
    }

    /// How many pages are kept, as a person's pages are (`ShellPersonPages.kept`).
    static let kept = ShellPersonPages.kept

    private var pages: [String: Page] = [:]
    /// The presses out, each with the act on its way, by the page's own key: the one guard of
    /// a press (`PressGuard`), as a mark on a post has.
    private var presses = PressGuard<String, PersonAct>()
    private var pressed: [String: Pressed] = [:]
    /// The press that did not arrive, by the page's key: said under the heading until it is
    /// pressed again, or the page is let go.
    private var missed: [String: PersonAct] = [:]
    /// The read on the wire for each page.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var order = PageOrder()
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    // MARK: - Who has a standing

    /// The source at which the reader stands to `who`, or nothing: it is not one where
    /// somebody is followed, nobody is signed in to it, it has not said who the reader is
    /// there, or `who` is the reader.
    private static func source(of who: DummyPerson, in session: ShellSession) -> Source? {
        guard let source = ShellPersonPages.source(of: who, in: session), offersFollowing(source),
              let own = ShellPersonPages.own(at: source.host, in: session), own.id != who.id
        else { return nil }
        return source
    }

    /// Whether somebody is followed at `source`: the fact itself, read here and by nobody else.
    static func offersFollowing(_ source: Source) -> Bool {
        source.kind.offers.follows
    }

    /// Whether the sign-in at `host` may follow and unfollow: it holds all of following.
    private static func changes(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(PersonAct.follow.needs, host: host) == .held
    }

    /// Whether the sign-in at `host` sees how the reader stands to people: it holds all of
    /// following, or the half of it that sees.
    private static func sees(at host: String, in session: ShellSession) -> Bool {
        changes(at: host, in: session)
            || MastodonParts.half(of: .follows, in: session.mastodon.heldParts[host.lowercased()]?.scopes) == .seeing
    }

    /// The page as it stands **for whoever would ask now** about the account `accountID`
    /// names, or nothing.
    private func standing(_ key: String, of accountID: String, at host: String, in session: ShellSession) -> Page? {
        pages[key].flatMap { page in
            page.accountID == accountID && page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    // MARK: - What the page is handed

    /// The opening of the page of `who`, once their source has said who they are — or nothing
    /// where nobody is asked how the reader stands to them.
    func opening(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> Opening? {
        guard let person = said?.person, let source = Self.source(of: who, in: session),
              Self.sees(at: source.host, in: session)
        else { return nil }
        return Opening(
            id: who.id, accountID: person.accountID, askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
            under: ShellPersonPages.signIns(at: source.host, in: session)
        )
    }

    /// What the page of `who` is handed about how the reader stands to them, or nothing: the
    /// source has not said who they are, or nobody stands to them here.
    func acting(of who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> PersonActing? {
        guard let person = said?.person else { return nil }
        return acting(of: who, as: person, in: session)
    }

    private func acting(of who: DummyPerson, as person: Person, in session: ShellSession) -> PersonActing? {
        guard let source = Self.source(of: who, in: session) else { return nil }
        let host = source.host, key = who.id
        let changes = Self.changes(at: host, in: session)
        var acting = PersonActing(
            source: host, named: person.lineHandle, asksFirst: person.locked,
            followable: !person.suspended && person.moved == nil,
            // Held in part with the rest not to be asked for has no place of its own: said, unpressed.
            lock: changes ? nil : session.mastodon.place(.follows, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly"),
            changes: changes
        )
        guard Self.sees(at: host, in: session) else { return acting }
        if let out = presses.shown(key), pressed[key]?.under == ShellPersonPages.signIns(at: host, in: session) {
            acting.doing = out
        }
        guard let page = self.standing(key, of: person.accountID, at: host, in: session) else {
            acting.reading = .asking
            return acting
        }
        if let said = page.said {
            acting.reading = .said(said)
        } else if page.asking {
            acting.reading = .asking
        } else if page.unsaid {
            acting.reading = .unsaid
        } else {
            acting.reading = page.failed ? .failed : .asking
        }
        acting.missed = missed[key]
        return acting
    }

    // MARK: - Letting go

    /// Everything of `host` let go, and its reads called off: its reader is no longer who
    /// asked (`PageReaders`). A press still out comes back to nothing of its own.
    func letGo(at host: String) {
        for (key, page) in pages where page.host == host { drop(key) }
        let gone = Set(pressed.filter { $0.value.host == host }.keys)
        presses.letGo { key, _ in gone.contains(key) }
        for key in gone { pressed[key] = nil }
    }

    private func drop(_ key: String) {
        asks[key]?.cancel()
        asks[key] = nil
        pages[key] = nil
        missed[key] = nil
        order.forget(key)
    }

    // MARK: - Reading

    /// The page of `who` saying who they are: the source is asked how the reader stands to
    /// them. Asked once: a page that answered or failed is drawn from that; one being asked is
    /// waited on and asked nothing more.
    func opened(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = Self.source(of: who, in: session) else { return }
        // The one look at the sign-in: a reader who changed lets what the last was given go.
        guard let held = readers.look(at: source.host, in: session).held, Self.sees(at: source.host, in: session) else { return }
        if let page = self.standing(who.id, of: person.accountID, at: source.host, in: session) {
            order.touch(who.id)
            if page.asking {
                await asks[who.id]?.value
                return
            }
            if page.said != nil || page.unsaid || page.failed { return }
        }
        await begin(who.id, of: person.accountID, far: !person.livesHere, at: source, with: held, in: session).value
    }

    /// `r` and a failure's "Try again": the source asked once more. What it said before stays
    /// drawn until the answer lands. **A press while it is being asked asks nothing.**
    func again(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = Self.source(of: who, in: session),
              let held = readers.look(at: source.host, in: session).held, Self.sees(at: source.host, in: session)
        else { return }
        if self.standing(who.id, of: person.accountID, at: source.host, in: session)?.asking == true { return }
        await begin(who.id, of: person.accountID, far: !person.livesHere, at: source, with: held, in: session).value
    }

    /// Starts the read, and hands back the task it runs in. Everything it needs is taken here,
    /// before anything waits: the source, who asks, the door.
    private func begin(
        _ key: String, of accountID: String, far: Bool, at source: Source, with held: MastodonToken,
        in session: ShellSession
    ) -> Task<Void, Never> {
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        if self.standing(key, of: accountID, at: source.host, in: session) == nil {
            // Nobody's page yet, or another reader's: what was said to them is not said to this one.
            asks[key]?.cancel()
            missed[key] = nil
            pages[key] = Page(
                host: source.host, accountID: accountID, far: far, askedAs: askedAs,
                under: ShellPersonPages.signIns(at: source.host, in: session), number: errands.next()
            )
        }
        for gone in order.keep(key, among: Self.kept, busy: { pages[$0]?.asking == true || presses.isOut($0) }) { drop(gone) }
        let errand = errands.next()
        pages[key]?.awaits = errand
        pages[key]?.asking = true
        // One read out a page: a read begun over another supersedes it.
        asks[key]?.cancel()
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        let task = Task { await self.read(key, of: accountID, through: through, at: source, as: askedAs, errand: errand, in: session) }
        asks[key] = task
        return task
    }

    private func read(
        _ key: String, of accountID: String, through: MastodonStanding, at source: Source, as askedAs: AskedAs,
        errand: Int, in session: ShellSession
    ) async {
        defer { if pages[key]?.awaits == errand { asks[key] = nil } }
        do {
            let said = try await through.standing(to: accountID)
            guard stillTheirs(key, of: accountID, errand: errand, at: source, in: session) else { return }
            pages[key]?.said = said
            pages[key]?.unsaid = said == nil
            pages[key]?.failed = false
        } catch {
            guard stillTheirs(key, of: accountID, errand: errand, at: source, in: session) else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                // What it said before stands: a failure takes nothing away.
                pages[key]?.failed = true
            }
        }
        // Nothing is left asking with nothing on the wire.
        pages[key]?.asking = false
    }

    /// Whether a read's answer may land: it is still the one the page awaits, **the source is
    /// still here, and whoever would ask now is still who it was asked as**. Otherwise what
    /// was kept is let go, and the answer lands nowhere.
    private func stillTheirs(_ key: String, of accountID: String, errand: Int, at source: Source, in session: ShellSession) -> Bool {
        guard pages[key]?.awaits == errand else { return false }
        guard ShellPersonPages.source(at: source.host, in: session) != nil,
              self.standing(key, of: accountID, at: source.host, in: session) != nil
        else {
            pages[key] = nil
            return false
        }
        return true
    }

    // MARK: - The press

    /// A press on the page of `who`: follows them, stops, or takes a request back.
    ///
    /// **Only what the page offers, over what the source said, as the reader it said it to**
    /// (`PersonActing.press`, `.more`): where it has not answered, where the sign-in may not
    /// change who the reader follows or is no longer the one the page was read through, the
    /// press does nothing. **One request out a person** (`PressGuard.begin`): pressed again
    /// meanwhile, nothing more is sent.
    func press(_ act: PersonAct, on who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = Self.source(of: who, in: session) else { return }
        let looked = readers.look(at: source.host, in: session)
        let key = who.id
        guard let held = looked.held, !looked.changed,
              let page = self.standing(key, of: person.accountID, at: source.host, in: session),
              let offered = acting(of: who, as: person, in: session),
              act == .follow ? offered.press == .follow : offered.more.contains(act),
              let flight = presses.begin(key, showing: act)
        else { return }
        missed[key] = nil
        pressed[key] = Pressed(host: source.host, under: page.under)
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .write))
        // The door the read after a follow of somebody of another server goes through (`act`).
        let settling = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        // The request is this object's and not the pane's: a page left does not call it off.
        await Task {
            await self.act(
                act, flight: flight, on: page, key: key, through: through, settling: settling, with: held, at: source,
                in: session
            )
        }.value
    }

    /// Sends the press and takes its answer, if it is still this press's to take.
    ///
    /// **Under the one guard of a press** (`PressGuard`), as `ShellSession.perform` is for a
    /// post's acts, `ShellNoticeActs.perform` for a notice's and `ShellTagFollow.act` for a
    /// hashtag's: sent, and then the guard is asked whether the entry is still this press's
    /// before anything lands or fails. As a hashtag's, a second press meanwhile sends nothing
    /// and keeps no turn, and a failure is said on the page. **Its own:** the answer calls off
    /// whatever read of the page is still out, which set out before the answer was known; and
    /// a follow of somebody of another server is read once more before it is taken (`settling`).
    private func act(
        _ act: PersonAct, flight: PressNumber, on pressedOn: Page, key: String, through: MastodonStanding,
        settling: MastodonStanding, with held: MastodonToken, at source: Source, in session: ShellSession
    ) async {
        /// What the press came to: the source's word, that it has none of them, that the
        /// press did not arrive, or that it did and how it stands could not then be read.
        enum Outcome {
            case said(PersonStanding)
            case unsaid, missed, unread
        }
        var outcome = Outcome.missed
        do {
            outcome = .said(try await through.follow(pressedOn.accountID, act == .follow))
        } catch {
            ShellPersonPages.concluded(error, at: source, askedAs: pressedOn.askedAs, in: session)
        }
        // Let go of with its reader meanwhile: the entry, if any, is another press's.
        guard presses.isStill(flight, key) else { return }
        // Somebody of another server is answered "followed" at the press, and is asked until
        // their server agrees: the answer is not how it stands, and is drawn nowhere. The
        // source is read now, **while the press is still out** — so the page goes on drawing
        // the press and nothing else — and what that read says is what the press came to.
        if act == .follow, pressedOn.far, case .said(let answer) = outcome, answer.following {
            do {
                outcome = try await settling.standing(to: pressedOn.accountID).map(Outcome.said) ?? .unsaid
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: pressedOn.askedAs, in: session)
                outcome = .unread
            }
            guard presses.isStill(flight, key) else { return }
        }
        // The press is answered, or did not arrive: either way it is out no longer.
        presses.settle(key)
        pressed[key] = nil
        let sameReader = session.mastodon.token(host: source.host)?.accessToken == held.accessToken
        guard sameReader, let page = self.standing(key, of: pressedOn.accountID, at: source.host, in: session),
              page.number == pressedOn.number
        else {
            // Not the page pressed on, or not its reader: the answer is written nowhere. A page
            // of theirs made since is asked afresh: whatever it read was asked before this landed.
            if sameReader, self.standing(key, of: pressedOn.accountID, at: source.host, in: session) != nil,
               Self.sees(at: source.host, in: session)
            {
                _ = begin(key, of: pressedOn.accountID, far: pressedOn.far, at: source, with: held, in: session)
            }
            return
        }
        if case .missed = outcome {
            missed[key] = act
            return
        }
        // A read still out set out before this answer: it is awaited no longer.
        asks[key]?.cancel()
        asks[key] = nil
        pages[key]?.awaits = errands.next()
        pages[key]?.asking = false
        switch outcome {
        case .said(let answer):
            pages[key]?.said = answer
            pages[key]?.unsaid = false
            pages[key]?.failed = false
            // The source's word stands either way; one that is not what was pressed is said as not done.
            if !Self.did(act, answer) { missed[key] = act }
        case .unsaid:
            pages[key]?.said = nil
            pages[key]?.unsaid = true
            pages[key]?.failed = false
        case .unread:
            // The press arrived, so what the source said before it is so no longer, and what it
            // says now is not known: nothing is drawn of either, and the page says it could
            // not ask, with the press that asks again.
            pages[key]?.said = nil
            pages[key]?.unsaid = false
            pages[key]?.failed = true
        case .missed:
            break
        }
    }

    /// Whether what the source answered is what `act` was pressed for.
    private static func did(_ act: PersonAct, _ answer: PersonStanding) -> Bool {
        switch act {
        case .follow: answer.following || answer.requested
        case .unfollow: !answer.following
        case .withdraw: !answer.requested
        }
    }
}

extension ShellPersonPages {
    /// What the page of `who` is handed about how the reader stands to them (#310, #313).
    func stands(to who: DummyPerson, in session: ShellSession) -> PersonActing? {
        acts.acting(of: who, said: said(of: who, in: session), in: session)
    }

    /// Which opening the asking of how the reader stands to `who` is, or nothing where nobody
    /// is asked.
    func standsOpening(to who: DummyPerson, in session: ShellSession) -> ShellPersonActs.Opening? {
        acts.opening(who, said: said(of: who, in: session), in: session)
    }

    /// The page of `who` has said who they are: how the reader stands to them is asked.
    func standsOpened(to who: DummyPerson, in session: ShellSession) async {
        await acts.opened(who, said: said(of: who, in: session), in: session)
    }

    /// A failure's "Try again" under the heading.
    func standsAgain(to who: DummyPerson, in session: ShellSession) async {
        await acts.again(who, said: said(of: who, in: session), in: session)
    }

    /// A press on the page of `who`: its heading's Follow, or an item of its `…`.
    func act(_ act: PersonAct, on who: DummyPerson, in session: ShellSession) async {
        await acts.press(act, on: who, said: said(of: who, in: session), in: session)
    }

    /// `l` on the page of `who`: follows them where the page offers that, and raises the
    /// sign-in's question where the page's Follow is its lock. Whether the key did anything.
    func followByKey(_ who: DummyPerson, in session: ShellSession) -> Bool {
        guard let standing = stands(to: who, in: session) else { return false }
        switch standing.press {
        case .follow: Task { await act(.follow, on: who, in: session) }
        case .ask: session.askFor([PersonAct.follow.needs], host: standing.source)
        case nil: return false
        }
        return true
    }

    /// `l`, wherever it is pressed: follows whoever's page is in front — `person` — or the
    /// hashtag whose page is — `tag`, at the first source whose line offers it. **Only where a
    /// page of the walk may be in front**: on the timeline's place, with nothing over the walk
    /// — as a row there opens. Whether the key did anything.
    func followByKey(
        place: ShellPlace, open: Set<DummyLayer>, person: DummyPerson?, tag: PostTag?, in session: ShellSession
    ) -> Bool {
        guard place == .timeline, DummyCommand.canWalk(whenOpen: open) else { return false }
        if let person { return followByKey(person, in: session) }
        guard let tag else { return false }
        return tags.followByKey(tag, in: session) != nil
    }
}
