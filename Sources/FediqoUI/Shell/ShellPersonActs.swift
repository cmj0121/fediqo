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
    /// What the source said where it would not do that press, by the page's key.
    private var refused: [String: String] = [:]
    /// The read on the wire for each page.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var order = PageOrder()
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// What this run knows each host has: where a host with no people featured is written
    /// down (#315). Handed in by whoever holds both.
    @ObservationIgnored var hosts: ShellHostsKnown?
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    /// Whether the sign-in at `host` may feature people and take them off (#315): it holds
    /// the account part.
    static func features(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(PersonAct.feature.needs, host: host) == .held
    }

    // MARK: - Who has a standing

    /// The source at which the reader stands to `who`, or nothing: it is not one where
    /// somebody is followed, nobody is signed in to it, it has not said who the reader is
    /// there, or `who` is the reader.
    private static func source(of who: DummyPerson, in session: ShellSession) -> Source? {
        guard let source = ShellPersonPages.source(of: who, in: session), stands(to: who.id, at: source, in: session)
        else { return nil }
        return source
    }

    /// Whether the reader stands to the person `id` names at `source`: somebody is followed
    /// there, it has said who the reader is, and they are not the reader.
    private static func stands(to id: String, at source: Source, in session: ShellSession) -> Bool {
        guard offersFollowing(source), let own = ShellPersonPages.own(at: source.host, in: session) else { return false }
        return own.id != id
    }

    /// Whether `source` is asked how the reader stands to the person `id` names: the reader
    /// stands to them there, and their sign-in sees it. **The one rule**, for somebody's page
    /// and for their row on a list of people.
    static func isTold(of id: String, at source: Source, in session: ShellSession) -> Bool {
        stands(to: id, at: source, in: session) && sees(at: source.host, in: session)
    }

    /// Whether somebody is followed at `source`: the fact itself, read here and by nobody else.
    static func offersFollowing(_ source: Source) -> Bool {
        source.kind.offers.follows
    }

    /// Whether the sign-in at `host` may follow and unfollow: it holds all of following.
    static func changes(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(PersonAct.follow.needs, host: host) == .held
    }

    /// Whether the sign-in at `host` sees how the reader stands to people: it holds all of
    /// following, or the half of it that sees.
    static func sees(at host: String, in session: ShellSession) -> Bool {
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
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session),
              Self.isTold(of: who.id, at: source, in: session)
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
        acting.featurable = hosts?.has(.featuredPeople, at: host) != .absent
        if !Self.features(at: host, in: session) {
            acting.accountLock = session.mastodon.place(PersonAct.feature.needs, host: host)
                ?? PartWords.Place(kind: .none, key: "part.account.unasked")
        }
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
        acting.refused = refused[key]
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
        refused[key] = nil
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
    ///
    /// `listed` is the list a row's press came from, where it came from one: the acts of a
    /// row (#313) are offered there and nowhere else. Whether the source answered that the
    /// press was done.
    @discardableResult
    func press(
        _ act: PersonAct, on who: DummyPerson, said: PersonSaid?, listed: PeopleList.Which? = nil, in session: ShellSession
    ) async -> Bool {
        guard let person = said?.person, let source = Self.source(of: who, in: session) else { return false }
        let looked = readers.look(at: source.host, in: session)
        let key = who.id
        guard let held = looked.held, !looked.changed,
              let page = self.standing(key, of: person.accountID, at: source.host, in: session),
              let offered = acting(of: who, as: person, in: session),
              Self.offers(act, on: offered, listed: listed),
              let flight = presses.begin(key, showing: act)
        else { return false }
        missed[key] = nil
        refused[key] = nil
        pressed[key] = Pressed(host: source.host, under: page.under)
        let writing = session.mastodon.authorized(token: held, within: deadline, for: .write)
        let through = Doors(standing: session.reach.standing(writing), featuring: session.reach.featuring(writing))
        let round = hosts?.round(at: source.host) ?? 0
        // The door the read after a follow of somebody of another server goes through (`act`).
        let settling = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        // The request is this object's and not the pane's: a page left does not call it off.
        return await Task {
            await self.act(
                act, flight: flight, on: page, key: key, through: through, settling: settling, with: held, at: source,
                round: round, in: session
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
    ///
    /// **A switch of what is taken from them is a follow at the source, so it is sent only to
    /// somebody the source says the reader follows now** (#313): the page offered it over what
    /// the source last said, and the reader may have unfollowed them elsewhere since. So how
    /// the reader stands is read once more first — one ask more a press of a switch, through
    /// `settling`, while the press is out. Where the source says the reader does not follow
    /// them, or has only asked, **nothing is sent**: what it said is what the page then says,
    /// and nothing is said to have failed, because nothing did. Where that read fails nothing
    /// is sent either, and the press is one that did not arrive. Following, unfollowing and
    /// taking a request back are sent as they always were, with no such read.
    private func act(
        _ act: PersonAct, flight: PressNumber, on pressedOn: Page, key: String, through: Doors,
        settling: MastodonStanding, with held: MastodonToken, at source: Source, round: Int, in session: ShellSession
    ) async -> Bool {
        /// What the press came to: the source's word, that it has none of them, that the
        /// press did not arrive, or that it did and how it stands could not then be read.
        enum Outcome {
            case said(PersonStanding)
            case unsaid, missed, unread
        }
        var outcome = Outcome.missed
        // Whether the request is made, and whether the page turns to what a read said in its
        // place: a switch for somebody the reader no longer follows.
        var sends = true, turned = false
        // What the source said where it would not, and whether it said it has no such thing.
        var refusal: String?, absent = false
        if Self.isSwitch(act) {
            do {
                let now = try await settling.standing(to: pressedOn.accountID)
                if now?.following != true {
                    outcome = now.map(Outcome.said) ?? .unsaid
                    sends = false
                    turned = true
                }
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: pressedOn.askedAs, in: session)
                sends = false
            }
            // Let go of with its reader while the read was out: nothing is sent for them.
            guard presses.isStill(flight, key) else { return false }
        }
        if sends {
            do {
                outcome = .said(try await Self.send(act, about: pressedOn.accountID, through: through))
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: pressedOn.askedAs, in: session)
                if case .refused(let sentence) = error as? AccountPartError { refusal = sentence }
                absent = (error as? MastodonHostMoreError) == .noSuchAddress && PersonActing.features(act)
            }
        }
        // Let go of with its reader meanwhile: the entry, if any, is another press's.
        guard presses.isStill(flight, key) else { return false }
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
            guard presses.isStill(flight, key) else { return false }
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
            return false
        }
        if absent {
            // The host has no people featured: the item goes, for the run, and nothing failed.
            hosts?.notFound(.featuredPeople, at: source.host, round: round)
            return false
        }
        if case .missed = outcome {
            missed[key] = act
            refused[key] = refusal
            return false
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
            // The source's word stands either way; one that is not what was pressed is said as
            // not done — but not where nothing was sent: then nothing failed.
            if !turned, !Self.did(act, answer) { missed[key] = act }
            return !turned && Self.did(act, answer)
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
        return false
    }

    // MARK: - A row of a list (#313)

    /// Whether `act` is one a row of a list offers, and no page of somebody's.
    static func isOfARow(_ act: PersonAct) -> Bool {
        switch act {
        // Taking somebody off the reader's profile is a row's too, on the people they feature (#315).
        case .acceptRequest, .refuseRequest, .removeFollower, .unfeature: true
        case .follow, .unfollow, .withdraw, .showBoosts, .hideBoosts, .notify, .stopNotifying, .feature,
             .dismissSuggestion: false
        }
    }

    /// A press on the row of `person` in a list of the reader's own: their request accepted
    /// or refused, or they are removed from following the reader — **sent through the one
    /// sequence a press on somebody's page is** (`press`), under the same guard: one request
    /// out a person, whichever page or row it was pressed on. Whether the source answered
    /// that it was done.
    ///
    /// **Somebody on a row has no page of their own open**, so what the list was told of how
    /// the reader stands to them — `standing`, which may be nothing — is written down as what
    /// the source last said, with nobody asked for it.
    ///
    /// **Each names them by the id the source gave, so a row gone stale can only fail or do
    /// nothing** (asked of a real source: a request that is no longer there is refused as not
    /// found, and removing somebody who already left changes nothing): no read is made first.
    func pressRow(
        _ act: PersonAct, on person: Person, standing said: PersonStanding?, listed: PeopleList.Which, in session: ShellSession
    ) async -> Bool {
        let who = DummyPerson(person)
        guard Self.isOfARow(act), let source = Self.source(of: who, in: session), Self.sees(at: source.host, in: session)
        else { return false }
        if self.standing(who.id, of: person.accountID, at: source.host, in: session) == nil {
            asks[who.id]?.cancel()
            missed[who.id] = nil
            pages[who.id] = Page(
                host: source.host, accountID: person.accountID, far: !person.livesHere,
                askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
                under: ShellPersonPages.signIns(at: source.host, in: session), number: errands.next(), said: said
            )
            for gone in order.keep(who.id, among: Self.kept, busy: { pages[$0]?.asking == true || presses.isOut($0) }) { drop(gone) }
        }
        return await press(act, on: who, said: PersonSaid(source: source.host, reading: .said(person)), listed: listed, in: session)
    }

    /// Whether `act` is one that takes a row off the list `which`: a request answered off the
    /// requests, a follower off the followers, somebody taken off the reader's profile off the
    /// people they feature.
    static func isOfARow(_ act: PersonAct, on which: PeopleList.Which) -> Bool {
        switch act {
        case .acceptRequest, .refuseRequest: which == .requests
        case .removeFollower: which == .followers
        case .unfeature: which == .featured
        default: false
        }
    }

    /// Whether the row of the person `key` names is leaving the list `which`: a press of
    /// theirs that takes them off it is out, made by whoever would ask now.
    func isLeaving(_ key: String, from which: PeopleList.Which, at host: String, in session: ShellSession) -> Bool {
        guard let out = presses.shown(key), Self.isOfARow(out, on: which) else { return false }

        return pressed[key]?.under == ShellPersonPages.signIns(at: host, in: session)
    }

    /// The press on a row of the person `key` names that did not arrive is said no longer:
    /// their list `which`, the one that act takes them off, was read again from the top.
    func forgetMissedOnARow(_ key: String, on which: PeopleList.Which) {
        if let act = missedOnARow(key), Self.isOfARow(act, on: which) { missed[key] = nil }
    }

    /// The press on a row of the person `key` names that did not arrive, where one did not.
    func missedOnARow(_ key: String) -> PersonAct? {
        missed[key].flatMap { Self.isOfARow($0) ? $0 : nil }
    }

    /// Whether the page offers `act` now: Follow where the head's press is that, an item of
    /// the `…` where it lists it, and a switch of what is taken from them (#313) where About
    /// draws that switch turned the other way and takes a press.
    ///
    /// **An act of a row is offered only from the list it belongs on** — a request answered
    /// from the requests, a follower removed from the followers — to a sign-in that may change
    /// who follows whom, and with no press out; and nobody is removed whom the source said
    /// does not follow the reader.
    private static func offers(_ act: PersonAct, on offered: PersonActing, listed: PeopleList.Which?) -> Bool {
        switch act {
        case .acceptRequest, .refuseRequest: listed == .requests && offered.changes && offered.doing == nil
        case .removeFollower:
            // From a row of the reader's own followers; and from the `…` of the page of
            // somebody the source said follows the reader, where the page lists it.
            listed == nil
                ? offered.more.contains(.removeFollower)
                : listed == .followers && offered.changes && offered.doing == nil && offered.shown?.followedBy != false
        case .follow: offered.press == .follow
        case .unfollow, .withdraw: offered.more.contains(act)
        case .feature: listed == nil && offered.more.contains(act) && !offered.asksForPart(act)
        case .unfeature:
            (listed == nil || listed == .featured) && offered.more.contains(act) && !offered.asksForPart(act)

        case .showBoosts, .hideBoosts, .notify, .stopNotifying:
            offered.narrowsTakePress && offered.narrows().contains { $0.act == act }
        // A suggestion is told apart on its list, and never from here (`ShellPeoplePages.dismiss`).
        case .dismissSuggestion: false
        }
    }

    /// Whether `act` is a switch of what is taken from somebody followed.
    private static func isSwitch(_ act: PersonAct) -> Bool {
        switch act {
        case .follow, .unfollow, .withdraw, .acceptRequest, .refuseRequest, .removeFollower, .feature, .unfeature,
             .dismissSuggestion: false
        case .showBoosts, .hideBoosts, .notify, .stopNotifying: true
        }
    }

    /// The two ways a press is sent: following, and featuring on the reader's profile.
    private struct Doors {
        let standing: MastodonStanding
        let featuring: MastodonFeaturing
    }

    /// The one request `act` is, sent: a follow, the taking back of one, or a follow said
    /// again with the one word that changed (#313) — the other is left as the source has it;
    /// or a featuring on the reader's profile, or its taking off (#315).
    private static func send(_ act: PersonAct, about accountID: String, through doors: Doors) async throws -> PersonStanding {
        let through = doors.standing
        return switch act {
        case .follow: try await through.follow(accountID, true)
        case .unfollow, .withdraw: try await through.follow(accountID, false)
        case .showBoosts: try await through.narrow(accountID, boosts: true)
        case .hideBoosts: try await through.narrow(accountID, boosts: false)
        case .notify: try await through.narrow(accountID, notify: true)
        case .stopNotifying: try await through.narrow(accountID, notify: false)
        case .acceptRequest: try await through.answer(accountID, accept: true)
        case .refuseRequest: try await through.answer(accountID, accept: false)
        case .removeFollower: try await through.removeFollower(accountID)
        case .feature: try await doors.featuring.feature(accountID: accountID)
        case .unfeature: try await doors.featuring.unfeature(accountID: accountID)
        case .dismissSuggestion: throw MastodonRequestError.invalidURL
        }
    }

    /// Whether what the source answered is what `act` was pressed for.
    private static func did(_ act: PersonAct, _ answer: PersonStanding) -> Bool {
        switch act {
        case .follow: answer.following || answer.requested
        case .unfollow: !answer.following
        case .withdraw: !answer.requested
        case .showBoosts: answer.showsBoosts == true
        case .hideBoosts: answer.showsBoosts == false
        case .notify: answer.notifies == true
        case .stopNotifying: answer.notifies == false
        case .acceptRequest: answer.followedBy
        case .refuseRequest, .removeFollower: !answer.followedBy
        case .feature: answer.featured == true
        case .unfeature: answer.featured != true
        case .dismissSuggestion: false
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

    /// A press on the page of `who`: its heading's Follow, or an item of its `…`. **Featuring
    /// where the sign-in lacks the account part only asks for it**: nothing is sent.
    func act(_ act: PersonAct, on who: DummyPerson, in session: ShellSession) async {
        if let standing = stands(to: who, in: session), standing.asksForPart(act) {
            if standing.accountLock?.asks == true { session.askFor([act.needs], host: standing.source) }
            return
        }
        await acts.press(act, on: who, said: said(of: who, in: session), in: session)
    }


    /// `l` on the page of `who`: follows them where the page offers that, and raises the
    /// sign-in's question where the page's Follow is its lock — and on the reader's own page
    /// does what a press on Change does. Whether the key did anything.
    func followByKey(_ who: DummyPerson, in session: ShellSession) -> Bool {
        if changeOwn(who, in: session) { return true }
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
