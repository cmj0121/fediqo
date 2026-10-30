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
        /// The reader's own note on them, as the source last said it (#377).
        var note: String?
        /// A note written here and on its way, drawn at once until the source answers.
        var noteSending: String?
        /// Whether the last note written here did not arrive.
        var noteMissed = false
        /// What the source said where it would not keep the last note written here.
        var noteRefused: String?
        /// When the source last answered a note written here, in the run's order of reads: a read
        /// sent before that names the note as it stood before, and its note is not taken.
        var noteMoved: UInt64?
        /// Whether a note is on its way: one at a time a page, the newest waiting behind it.
        var noteOut = false
        /// Which of the people the reader follows also follow them (#377), as last read.
        var familiar: [Person] = []
        /// How many times how the reader stands has been read and answered on this page: who is
        /// in common is read again each time it is.
        var reads = 0
        /// Which of those reads who is in common was last asked with.
        var familiarRead: Int?
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
    /// The pages whose last read of how the reader stands was stopped, until it is read again.
    private var halted: Set<String> = []
    /// The presses out, each with the act on its way, by the page's own key: the one guard of
    /// a press (`PressGuard`), as a mark on a post has.
    private var presses = PressGuard<String, PersonAct>()
    private var pressed: [String: Pressed] = [:]
    /// The press that did not arrive, by the page's key: said under the heading until it is
    /// pressed again, or the page is let go.
    private var missed: [String: PersonAct] = [:]
    /// What the source said where it would not do that press, by the page's key.
    private var refused: [String: String] = [:]
    /// The languages a choice out says (#378), by the page's key: drawn while it is out.
    private var languagesOut: [String: [String]] = [:]
    /// The languages each host said it knows (#378), by host: asked once a run, where a page
    /// of somebody followed there is open, and kept for the run.
    private var languagesKnown: [String: [FollowLanguage]] = [:]
    @ObservationIgnored private var languagesAsked: Set<String> = []
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

    /// Whether the sign-in at `host` may mute and block people and servers (#314): it holds all
    /// of that part.
    static func blocks(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(PersonAct.mute.needs, host: host) == .held
    }

    /// Whether the sign-in at `host` sees whom the reader mutes and blocks (#314): it holds all
    /// of that part, or the half of it that sees.
    static func seesBlocks(at host: String, in session: ShellSession) -> Bool {
        blocks(at: host, in: session)
            || MastodonParts.half(of: .blocks, in: session.mastodon.heldParts[host.lowercased()]?.scopes) == .seeing
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
        // Muting and blocking (#314), where its kind has them: the server they live on, where it
        // is not this source's.
        acting.blockable = source.kind.offers.blocks
        acting.server = person.livesHere ? nil : person.home
        // Reporting them (#339), where its kind has it.
        acting.reportable = source.kind.offers.reports && ShellReports.isSomebodyElse(person, at: host, in: session)
        if session.mastodon.standing(PersonAct.report.needs, host: host) != .held {
            acting.reportsLock = session.mastodon.place(PersonAct.report.needs, host: host)
                ?? PartWords.Place(kind: .none, key: "part.reports.unasked")
        }
        // Lists they can be put on (#337), where the source keeps them. A sign-in that was not
        // asked for them still offers the item, dim, and the press only asks.
        acting.lists = source.kind.offers.tendsLists
        if !MastodonParts.holds(.lists, in: session.mastodon.token(host: host)?.scopes) {
            acting.listsLock = session.mastodon.place(.lists, host: host)
                ?? PartWords.Place(kind: .unasked, key: "part.lists.unasked")
        }
        // Collections they can be put in (#433), the same way.
        acting.collections = source.kind.offers.tendsCollections && hosts?.has(.collections, at: host) != .absent
        acting.collectionsLock = session.mastodon.collectionsLock(host: host)
        if !Self.blocks(at: host, in: session) {
            acting.blocksLock = session.mastodon.place(PersonAct.mute.needs, host: host)
                ?? PartWords.Place(kind: .none, key: "part.ask.partly")
        }
        guard Self.sees(at: host, in: session) else { return acting }
        if let out = presses.shown(key), pressed[key]?.under == ShellPersonPages.signIns(at: host, in: session) {
            acting.doing = out
            if out == .chooseLanguages { acting.languagesSending = languagesOut[key] }
        }
        acting.languagesOffered = languagesKnown[host.lowercased()] ?? PersonLanguagesWords.known
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
        acting.notes = true
        acting.note = page.noteSending ?? page.note
        acting.noteSending = page.noteSending != nil
        acting.noteMissed = page.noteMissed
        acting.noteRefused = page.noteRefused
        acting.familiar = page.familiar
        return acting
    }

    /// Whether a read sent at `sent` set out before `moved`.
    private static func before(_ sent: UInt64?, _ moved: UInt64?) -> Bool {
        guard let sent, let moved else { return false }
        return sent < moved
    }

    // MARK: - Who is known in common (#377)

    /// Which page a `.task` asking who is in common is: the page as it stands for whoever would
    /// ask now, and which read of how the reader stands it follows — so it is asked again each time
    /// that is — or nothing before the source has said, and nothing is asked.
    func familiarOpening(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> String? {
        guard let person = said?.person, let source = Self.source(of: who, in: session), Self.sees(at: source.host, in: session),
              let page = self.standing(who.id, of: person.accountID, at: source.host, in: session), page.said != nil
        else { return nil }
        return "\(page.number):\(page.reads)"
    }

    /// Asks which of the people the reader follows also follow them, once each read of how the
    /// reader stands. **A failure takes nothing away and says nothing**, and is asked again with the
    /// next read; an answer lands only on the page it was asked for, for the reader it was asked as.
    func familiarOpened(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = Self.source(of: who, in: session),
              let held = readers.look(at: source.host, in: session).held, Self.sees(at: source.host, in: session),
              let page = self.standing(who.id, of: person.accountID, at: source.host, in: session),
              page.said != nil, page.familiarRead != page.reads
        else { return }
        let key = who.id
        pages[key]?.familiarRead = page.reads
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        guard let familiar = try? await through.familiarFollowers(of: person.accountID, at: source) else {
            if self.standing(key, of: person.accountID, at: source.host, in: session)?.number == page.number,
               pages[key]?.familiarRead == page.reads {
                pages[key]?.familiarRead = nil
            }
            return
        }
        guard self.standing(key, of: person.accountID, at: source.host, in: session)?.number == page.number,
              session.mastodon.token(host: source.host)?.accessToken == held.accessToken
        else { return }
        pages[key]?.familiar = familiar
    }

    // MARK: - Which languages reach Home (#378)

    /// Which host a `.task` asking what languages it knows is: the page's, once the source has
    /// said the reader follows them and only until that host has been asked this run — or nothing.
    func languagesOpening(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> String? {
        guard let acting = acting(of: who, said: said, in: session), acting.changes, acting.languages != nil,
              !languagesAsked.contains(acting.source.lowercased())
        else { return nil }
        return acting.source.lowercased()
    }

    /// Asks the page's host once a run which languages it knows a post to be in, to choose among.
    /// **A failure says nothing**: the languages this device knows stand in for them, and the
    /// host is asked again by the next page opened there.
    func languagesOpened(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let host = languagesOpening(who, said: said, in: session),
              let held = readers.look(at: host, in: session).held
        else { return }
        languagesAsked.insert(host)
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        guard let known = try? await through.languages(), !known.isEmpty else {
            languagesAsked.remove(host)
            return
        }
        languagesKnown[host] = known
    }

    // MARK: - The reader's note (#377)

    /// Writes the reader's own note on `who` — empty clears it — kept at the source, so another
    /// device reads it too. **Drawn at once**, and the source's answer is what is then drawn,
    /// **numbered as it lands** so a read sent before it does not put the old note back, and only
    /// where this is still the latest note written on this page under the sign-in it was written
    /// under. Needs the account part: without it the press only asks for it.
    func writeNote(_ words: String, of who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = Self.source(of: who, in: session) else { return }
        let key = who.id, host = source.host
        guard Self.features(at: host, in: session) else {
            if session.mastodon.place(PersonAct.feature.needs, host: host)?.asks == true {
                _ = session.askFor([PersonAct.feature.needs], host: host)
            }
            return
        }
        guard let held = readers.look(at: host, in: session).held, Self.sees(at: host, in: session),
              let page = self.standing(key, of: person.accountID, at: host, in: session)
        else { return }
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // The note as drawn now: words that change nothing are not sent.
        guard words != (page.noteSending ?? page.note ?? "") else { return }
        pages[key]?.noteSending = words
        pages[key]?.noteMissed = false
        pages[key]?.noteRefused = nil
        // **One note at a time a page**: the one out sends this once its answer lands.
        guard !page.noteOut else { return }
        pages[key]?.noteOut = true
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .write))
        func stillThisPage() -> Bool {
            self.standing(key, of: person.accountID, at: host, in: session)?.number == page.number
                && session.mastodon.token(host: host)?.accessToken == held.accessToken
        }
        while let wanted = pages[key]?.noteSending {
            let answer: (standing: PersonStanding, note: String?)
            do {
                answer = try await through.note(wanted, on: person.accountID)
            } catch {
                guard stillThisPage() else { return }
                pages[key]?.noteOut = false
                pages[key]?.noteSending = nil
                if case .refused(let sentence) = error as? AccountPartError {
                    pages[key]?.noteRefused = sentence
                } else if !Cancellation.happened(error) {
                    ShellPersonPages.concluded(error, at: source, askedAs: page.askedAs, in: session)
                    pages[key]?.noteMissed = true
                }
                return
            }
            // Only on this very page, for the reader it was written as.
            guard stillThisPage() else { return }
            pages[key]?.note = answer.note
            pages[key]?.noteMoved = ReadMoment.now().place
            // Taken: off what is waiting, unless newer words were written meanwhile — then those go.
            if pages[key]?.noteSending == wanted { pages[key]?.noteSending = nil }
        }
        pages[key]?.noteOut = false
    }

    /// What the page of `who` says in its toast of how the reader stands to them (DESIGN-reload):
    /// the source being asked — a wait Stop stops — that its last answer did not come, or that
    /// it was stopped. Nothing where nobody is asked.
    func ask(of who: DummyPerson, said: PersonSaid?, in session: ShellSession, language: DummyLanguage? = nil) -> PageAsking {
        guard let person = said?.person, let source = Self.source(of: who, in: session),
              let page = self.standing(who.id, of: person.accountID, at: source.host, in: session)
        else { return PageAsking() }
        return PageAsking(
            asking: page.asking ? TimelineToast.waiting("person.stands.asking", hosts: [source.host], language: language) : nil,
            stoppable: page.asking,
            failed: page.failed && !page.asking ? [source.host] : [],
            stopped: halted.contains(who.id)
        )
    }

    /// Stop on the page of `who`: how the reader stands to them is asked no further, what the
    /// source said before stands, and whatever is on the wire lands nowhere. Whether a read was
    /// out.
    @discardableResult
    func stop(_ who: DummyPerson) -> Bool {
        let key = who.id
        guard pages[key]?.asking == true else { return false }
        asks[key]?.cancel()
        asks[key] = nil
        pages[key]?.awaits = errands.next()
        pages[key]?.asking = false
        halted.insert(key)
        return true
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

    /// `r`, the bar's mark and a pull: the source asked once more. What it said before stays
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
        halted.remove(key)
        // One read out a page: a read begun over another supersedes it.
        asks[key]?.cancel()
        let through = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        let ticket = session.hides.ticket()
        let task = Task {
            await self.read(key, of: accountID, through: through, at: source, as: askedAs, errand: errand, ticket: ticket, in: session)
        }
        asks[key] = task
        return task
    }

    private func read(
        _ key: String, of accountID: String, through: MastodonStanding, at source: Source, as askedAs: AskedAs,
        errand: Int, ticket: Int, in session: ShellSession
    ) async {
        defer { if pages[key]?.awaits == errand { asks[key] = nil } }
        let sent = ReadMoment.now().place
        do {
            let (said, note) = try await through.standingNoted(to: accountID)
            guard stillTheirs(key, of: accountID, errand: errand, at: source, in: session) else { return }
            if let said { Self.heard(said, key: key, at: source.host, since: ticket, in: session) }
            pages[key]?.said = said
            pages[key]?.unsaid = said == nil
            pages[key]?.failed = false
            // A note written here and answered after this read set out stands as written.
            if !Self.before(sent, pages[key]?.noteMoved) { pages[key]?.note = note }
            pages[key]?.reads += 1
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
    ///
    /// `choice` is what the person answered on the sheet a mute or a block is asked on (#314):
    /// how long a mute is for, and whether it keeps their notices too. Nothing for any other.
    @discardableResult
    func press(
        _ act: PersonAct, on who: DummyPerson, said: PersonSaid?, listed: PeopleList.Which? = nil,
        choice: StandingChoice? = nil, in session: ShellSession
    ) async -> Bool {
        await pressCame(act, on: who, said: said, listed: listed, choice: choice, in: session).taken
    }

    /// What a press came to (#314): whether **the source said it did it** — whatever became of
    /// the page meanwhile, and whether how it stands could be read after — and whether the page
    /// pressed on took the answer. What this device does with what it held of somebody hangs on
    /// the first: a press the source did is done, though its page was let go or renumbered.
    struct PressCame: Equatable {
        var taken = false
        var sourceDid = false
        /// The source's word of how the reader stands afterwards, where it gave one.
        var said: PersonStanding?
    }

    /// `press`, answering what it came to.
    func pressCame(
        _ act: PersonAct, on who: DummyPerson, said: PersonSaid?, listed: PeopleList.Which? = nil,
        choice: StandingChoice? = nil, in session: ShellSession
    ) async -> PressCame {
        guard let person = said?.person, let source = Self.source(of: who, in: session) else { return PressCame() }
        let looked = readers.look(at: source.host, in: session)
        let key = who.id
        guard let held = looked.held, !looked.changed,
              let page = self.standing(key, of: person.accountID, at: source.host, in: session),
              let offered = acting(of: who, as: person, in: session),
              Self.offers(act, on: offered, listed: listed),
              let flight = presses.begin(key, showing: act)
        else { return PressCame() }
        missed[key] = nil
        refused[key] = nil
        pressed[key] = Pressed(host: source.host, under: page.under)
        languagesOut[key] = act == .chooseLanguages ? choice?.languages ?? [] : nil
        let ticket = session.hides.ticket()
        let writing = session.mastodon.authorized(token: held, within: deadline, for: .write)
        let through = Doors(
            standing: session.reach.standing(writing), featuring: session.reach.featuring(writing),
            servers: session.reach.serverBlocks(writing), server: offered.server, choice: choice ?? StandingChoice()
        )
        let round = hosts?.round(at: source.host) ?? 0
        // The door the read after a follow of somebody of another server goes through (`act`).
        let settling = session.reach.standing(session.mastodon.authorized(token: held, within: deadline, for: .person))
        // The request is this object's and not the pane's: a page left does not call it off.
        return await Task {
            await self.act(
                act, flight: flight, on: page, key: key, through: through, settling: settling, with: held, at: source,
                round: round, ticket: ticket, in: session
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
        settling: MastodonStanding, with held: MastodonToken, at source: Source, round: Int, ticket: Int,
        in session: ShellSession
    ) async -> PressCame {
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
            guard presses.isStill(flight, key) else { return PressCame() }
        }
        // A server's block is answered with nothing of how it stands: it is read after (#314).
        var serverDone = false
        if sends {
            do {
                if Self.isOfAServer(act) {
                    guard let server = through.server else { throw MastodonRequestError.invalidURL }
                    act == .blockServer ? try await through.servers.block(server) : try await through.servers.unblock(server)
                    serverDone = true
                    outcome = try await settling.standing(to: pressedOn.accountID).map(Outcome.said) ?? .unsaid
                } else {
                    outcome = .said(try await Self.send(act, about: pressedOn.accountID, through: through))
                }
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: pressedOn.askedAs, in: session)
                if case .refused(let sentence) = error as? AccountPartError { refusal = sentence }
                absent = (error as? MastodonHostMoreError) == .noSuchAddress && PersonActing.features(act)
                // Done at the source, and how it stands now could not be read.
                if serverDone { outcome = .unread }
            }
        }
        // What the source now says of how the reader stands, taken to what is hidden of them.
        if case .said(let answer) = outcome, session.mastodon.token(host: source.host)?.accessToken == held.accessToken {
            Self.heard(answer, key: key, at: source.host, since: ticket, in: session)
        }
        // Whether the source did it, whatever becomes of the page from here (#314).
        var came = PressCame()
        if Self.isOfAServer(act) {
            came.sourceDid = serverDone
            if case .said(let answer) = outcome { came.said = answer }
        } else if case .said(let answer) = outcome, !turned, Self.did(act, answer, choice: through.choice) {
            came.sourceDid = true
            came.said = answer
        }
        // Let go of with its reader meanwhile: the entry, if any, is another press's.
        guard presses.isStill(flight, key) else { return came }
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
            guard presses.isStill(flight, key) else { return came }
        }
        // The press is answered, or did not arrive: either way it is out no longer.
        presses.settle(key)
        pressed[key] = nil
        languagesOut[key] = nil
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
            return came
        }
        if absent {
            // The host has no people featured: the item goes, for the run, and nothing failed.
            hosts?.notFound(.featuredPeople, at: source.host, round: round)
            return came
        }
        if case .missed = outcome {
            missed[key] = act
            refused[key] = refusal
            return came
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
            if !turned, !Self.did(act, answer, choice: through.choice) { missed[key] = act }
            came.taken = !turned && Self.did(act, answer, choice: through.choice)
            return came
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
        return came
    }

    // MARK: - A row of a list (#313)

    /// Whether `act` is one a row of a list offers, and no page of somebody's.
    static func isOfARow(_ act: PersonAct) -> Bool {
        switch act {
        // Taking somebody off the reader's profile is a row's too, on the people they feature (#315).
        // Muting and blocking taken back are a row's on the reader's lists of them (#314).
        case .acceptRequest, .refuseRequest, .removeFollower, .unfeature, .unmute, .unblock: true
        case .follow, .unfollow, .withdraw, .showBoosts, .hideBoosts, .notify, .stopNotifying, .chooseLanguages, .feature,
             .dismissSuggestion, .mute, .block, .blockServer, .unblockServer, .report: false
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
        await pressRowCame(act, on: person, standing: said, listed: listed, in: session).taken
    }

    /// `pressRow`, answering what it came to (`PressCame`).
    func pressRowCame(
        _ act: PersonAct, on person: Person, standing said: PersonStanding?, listed: PeopleList.Which, in session: ShellSession
    ) async -> PressCame {
        let who = DummyPerson(person)
        guard Self.isOfARow(act), let source = Self.source(of: who, in: session), Self.sees(at: source.host, in: session)
        else { return PressCame() }
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
        return await pressCame(act, on: who, said: PersonSaid(source: source.host, reading: .said(person)), listed: listed, in: session)
    }

    /// Whether `act` is one that takes a row off the list `which`: a request answered off the
    /// requests, a follower off the followers, somebody taken off the reader's profile off the
    /// people they feature.
    static func isOfARow(_ act: PersonAct, on which: PeopleList.Which) -> Bool {
        switch act {
        case .acceptRequest, .refuseRequest: which == .requests
        case .removeFollower: which == .followers
        case .unfeature: which == .featured
        case .unmute: which == .muted
        case .unblock: which == .blocked
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
        // Which languages reach Home (#378): where About draws them, of somebody followed.
        case .chooseLanguages: listed == nil && offered.narrowsTakePress && offered.languages != nil
        // Muting and blocking (#314): from the page's `…` where it lists them and the sign-in
        // holds what they need; taken back from a row of the reader's list of them too.
        case .mute, .block, .blockServer, .unblockServer:
            listed == nil && offered.keeping.contains(act) && !offered.asksForPart(act)
        case .unmute, .unblock:
            listed == nil
                ? offered.keeping.contains(act) && !offered.asksForPart(act)
                : listed == (act == .unmute ? .muted : .blocked) && offered.blocksLock == nil && offered.doing == nil
        // A suggestion is told apart on its list, and never from here (`ShellPeoplePages.dismiss`);
        // a report is sent from its sheet (`ShellReports`).
        case .dismissSuggestion, .report: false
        }
    }

    /// Whether `act` is a switch of what is taken from somebody followed.
    private static func isSwitch(_ act: PersonAct) -> Bool {
        switch act {
        case .follow, .unfollow, .withdraw, .acceptRequest, .refuseRequest, .removeFollower, .feature, .unfeature,
             .dismissSuggestion, .mute, .unmute, .block, .unblock, .blockServer, .unblockServer, .report: false
        case .showBoosts, .hideBoosts, .notify, .stopNotifying, .chooseLanguages: true
        }
    }

    /// What a read of how the reader stands to the person whose page is `key` said, taken to what
    /// this device hides of them (`ShellHides.heard`): their handle is the page's own name for
    /// them, and their server the last part of it.
    static func heard(_ standing: PersonStanding, key: String, at host: String, since ticket: Int, in session: ShellSession) {
        guard let handle = key.split(separator: "\u{1e}").last.map(String.init), handle.contains("@") else { return }
        let server = handle.split(separator: "@").last.flatMap { MastodonServerBlocks.server(String($0)) }
        session.hides.heard(standing, of: handle, server: server == host.lowercased() ? nil : server, at: host, since: ticket)
    }

    /// Whether `act` is about the whole server somebody lives on (#314), and not about them.
    private static func isOfAServer(_ act: PersonAct) -> Bool {
        act == .blockServer || act == .unblockServer
    }

    /// The ways a press is sent: following, featuring on the reader's profile, and blocking a
    /// whole server (#314) — with the server it names, and what the person answered on a mute's
    /// sheet.
    private struct Doors {
        let standing: MastodonStanding
        let featuring: MastodonFeaturing
        let servers: MastodonServerBlocks
        let server: String?
        let choice: StandingChoice
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
        case .chooseLanguages: try await through.narrow(accountID, languages: doors.choice.languages)
        case .acceptRequest: try await through.answer(accountID, accept: true)
        case .refuseRequest: try await through.answer(accountID, accept: false)
        case .removeFollower: try await through.removeFollower(accountID)
        case .feature: try await doors.featuring.feature(accountID: accountID)
        case .unfeature: try await doors.featuring.unfeature(accountID: accountID)
        case .mute: try await through.mute(accountID, notices: doors.choice.notices, for: doors.choice.seconds)
        case .unmute: try await through.unmute(accountID)
        case .block: try await through.block(accountID, true)
        case .unblock: try await through.block(accountID, false)
        // Sent through `servers`, and never from here.
        case .dismissSuggestion, .blockServer, .unblockServer, .report: throw MastodonRequestError.invalidURL
        }
    }

    /// Whether what the source answered is what `act` was pressed for.
    private static func did(_ act: PersonAct, _ answer: PersonStanding, choice: StandingChoice) -> Bool {
        switch act {
        case .follow: answer.following || answer.requested
        case .unfollow: !answer.following
        case .withdraw: !answer.requested
        case .showBoosts: answer.showsBoosts == true
        case .hideBoosts: answer.showsBoosts == false
        case .notify: answer.notifies == true
        case .stopNotifying: answer.notifies == false
        // Still a follow, in what was chosen: none and every language are one.
        case .chooseLanguages: answer.following && Set(answer.languages ?? []) == Set(choice.languages)
        case .acceptRequest: answer.followedBy
        case .refuseRequest, .removeFollower: !answer.followedBy
        case .feature: answer.featured == true
        case .unfeature: answer.featured != true
        case .mute: answer.muting
        case .unmute: !answer.muting
        case .block: answer.blocking
        case .unblock: !answer.blocking
        case .blockServer: answer.serverBlocked
        case .unblockServer: !answer.serverBlocked
        case .dismissSuggestion, .report: false
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

    /// A press on the page of `who`: its heading's Follow, or an item of its `…`. **Featuring
    /// where the sign-in lacks the account part only asks for it**: nothing is sent.
    ///
    /// **A mute and a block are asked on a sheet first** (#314): the press puts the sheet up and
    /// sends nothing; its yes is `answer`. Taking either back is sent at the press, and what this
    /// device hid of them is shown again once the source says it is done.
    func act(_ act: PersonAct, on who: DummyPerson, in session: ShellSession) async {
        if let standing = stands(to: who, in: session), standing.asksForPart(act) {
            if standing.lock(of: act)?.asks == true { session.askFor([act.needs], host: standing.source) }
            return
        }
        if PersonActing.asksOnASheet(act) {
            ask(act, of: who, in: session)
            return
        }
        // A report is written on a sheet of its own, and sent only from there (#339).
        if act == .report {
            if stands(to: who, in: session)?.reporting.contains(.report) == true { await reports.start(who, people: self, in: session) }
            return
        }
        let came = await acts.pressCame(act, on: who, said: said(of: who, in: session), in: session)
        // What this device hid of them shows once the source has taken the mute or block back,
        // whatever became of the page meanwhile.
        if came.sourceDid, let person = said(of: who, in: session)?.person { Self.undone(act, of: person, in: session) }
    }

    /// The languages of the posts of `who` that reach Home, chosen on About (#378) — none, every
    /// language: **a follow said again, so sent as a switch is**, under the one guard of a press
    /// and only once a read says the reader still follows them.
    func chooseLanguages(_ codes: [String], of who: DummyPerson, in session: ShellSession) async {
        await acts.press(.chooseLanguages, on: who, said: said(of: who, in: session), choice: StandingChoice(languages: codes), in: session)
    }

    /// The sheet of a mute or a block put up (#314), over what the page offers now: only where
    /// its `…` lists the act, the sign-in holds what it needs, and — for a whole server — the
    /// page names one.
    func ask(_ act: PersonAct, of who: DummyPerson, in session: ShellSession) {
        guard PersonActing.asksOnASheet(act), standingAsk == nil, let standing = stands(to: who, in: session),
              standing.keeping.contains(act), !standing.asksForPart(act), let person = said(of: who, in: session)?.person
        else { return }
        let server = act == .blockServer ? standing.server : nil
        if act == .blockServer, server == nil { return }
        let held = server.map { server in
            session.notes.filter(HeldAuthors.server(server, at: standing.source).wrote).count
        } ?? session.heldPosts(of: who).count
        standingAsk = StandingAsk(
            act: act, who: who, named: person.lineHandle, handle: person.handle, source: standing.source, server: server,
            held: held
        )
    }

    /// The sheet's yes (#314): the act sent as answered, and — **once the source says it is
    /// done, and only then** — what this device holds of them treated as the person chose. A
    /// press that did not arrive changes nothing here: the page says so under its heading.
    func answer(_ ask: StandingAsk, _ choice: StandingChoice, in session: ShellSession) async {
        guard standingAsk == ask else { return }
        standingAsk = nil
        let came = await acts.pressCame(ask.act, on: ask.who, said: said(of: ask.who, in: session), choice: choice, in: session)
        // The source did it: what is held is treated as answered, whatever became of the page.
        guard came.sourceDid else { return }
        let authors = ask.server.map { HeldAuthors.server($0, at: ask.source) } ?? .person(ask.handle, at: ask.source)
        switch choice.held {
        case .hide:
            if let server = ask.server {
                session.hides.hide(server: server, at: ask.source)
            } else {
                // A mute for a time hides until the end the source named.
                let until = ask.act == .mute ? (came.said ?? stands(to: ask.who, in: session)?.shown)?.mutedUntil : nil
                session.hides.hide(ask.handle, at: ask.source, ask.act == .mute ? .muted : .blocked, until: until)
            }
        case .letGo:
            _ = await session.letGo(by: authors)
        case .leave:
            break
        }
    }

    /// What this device hid of `person` shown again: their mute, their block, or their server's
    /// block, taken back at the source (#314).
    static func undone(_ act: PersonAct, of person: Person, in session: ShellSession) {
        let host = person.source.host
        switch act {
        case .unmute: session.hides.show(person.handle, at: host, .muted)
        case .unblock: session.hides.show(person.handle, at: host, .blocked)
        case .unblockServer: if let server = person.home { session.hides.show(server: server, at: host) }
        default: break
        }
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
        guard place.isStream, DummyCommand.canWalk(whenOpen: open) else { return false }
        if let person { return followByKey(person, in: session) }
        guard let tag else { return false }
        return tags.followByKey(tag, in: session) != nil
    }
}
