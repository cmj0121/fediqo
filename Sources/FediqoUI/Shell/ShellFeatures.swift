import FediqoCore
import Foundation
import Observation

// What somebody features on their profile (#315, #318), and a hashtag featured on the reader's
// own: what is asked for it, when, and how a press there is guarded.
//
// **Somebody's page asks two things more when it opens** (B7): the hashtags they feature, and
// whether they feature anybody — one stretch of one person, enough to say whether the line to
// the list is drawn. **The line is drawn only where somebody is**, and the hashtags only where
// the source gave some: an empty answer is said by nothing, since a host may answer the same
// for "none" and for "not kept". Asked as the reader where they are signed in there, and with
// no token otherwise.
//
// **What is absent for the run, and from what alone.** A host with no people featured says so
// by the address of the list (`noSuchAddress`): written down (`ShellHostsKnown`), and neither
// the line nor the act of featuring somebody is offered there again. **Featured hashtags are
// written down as absent only from the reader's own** — their list, or a featuring refused as
// an address the host does not have (a 405 on featuring one): somebody else's answering
// not-found, or a refusal of a reader with no sign-in, says nothing of the host (a host that
// states it keeps them may still answer so of an account), and only draws no block.
//
// **A hashtag's page** has a feature row under each source's follow row, where the host keeps
// hashtags featured. Whether it is featured is the hashtag's own answer where it says
// (`ShellTagFollow`), and otherwise the reader's own featured hashtags, **asked once a run a
// source**. A press is shown first, guarded by the one guard of a press (`PressGuard`), and
// **its answer is the newer word**: a read of the hashtag already on its way does not undo it.
//
// **Every answer lands only where it is still the one awaited**, as whoever asked, and is let
// go with their sign-in (`PageReaders`); **held nowhere**.

/// What somebody features, the reader's own featured hashtags at each source, and the presses
/// that feature a hashtag or take it off.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask.
@MainActor
@Observable
final class ShellFeatures {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// What one person features, as their source said it.
    private struct Theirs {
        let host: String
        let accountID: String
        let askedAs: AskedAs
        let under: Int
        var tags: [FeaturedTag] = []
        var tagsAsking = false
        var tagsFailed = false
        /// Whether the source gave somebody among the people they feature.
        var anyFeatured = false
        var awaits = 0
    }

    /// Which page a `.task` is: who, by the id their source knows them by, and who asks.
    struct Opening: Hashable {
        let id: String
        let accountID: String
        let askedAs: AskedAs
        let under: Int
    }

    /// The reader's own featured hashtags at one source.
    private struct Own {
        let askedAs: AskedAs
        let under: Int
        var tags: [FeaturedTag]?
        var asking = false
        var failed = false
        var awaits = 0
    }

    private var theirs: [String: Theirs] = [:]
    private var own: [String: Own] = [:]
    /// Whether a hashtag is featured at a source as a press there was answered, by the key of
    /// both: the newer word than any read.
    private var answered: [String: Bool] = [:]
    private var presses = PressGuard<String, Bool>()
    private var pressedUnder: [String: Int] = [:]
    /// What each press that did not arrive wanted, and what the source said of it.
    private var missed: [String: Bool] = [:]
    private var refused: [String: String] = [:]
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ownAsks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    @ObservationIgnored private let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    private static func key(_ tag: PostTag, _ host: String) -> String {
        "\(host)\u{1e}\(MastodonRising.folded(tag))"
    }

    /// Whether the sign-in at `host` holds the account part, which featuring wants.
    static func features(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(.account, host: host) == .held
    }

    // MARK: - Letting go

    /// Everything of `host` let go, and its reads called off: its reader is no longer who asked.
    func letGo(at host: String) {
        for (id, page) in theirs where page.host == host {
            asks[id]?.cancel()
            asks[id] = nil
            theirs[id] = nil
        }
        ownAsks[host]?.cancel()
        ownAsks[host] = nil
        own[host] = nil
        let prefix = host + "\u{1e}"
        answered = answered.filter { !$0.key.hasPrefix(prefix) }
        presses.letGo { key, _ in key.hasPrefix(prefix) }
        pressedUnder = pressedUnder.filter { !$0.key.hasPrefix(prefix) }
        missed = missed.filter { !$0.key.hasPrefix(prefix) }
        refused = refused.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The page of `tag` left: what its presses came to is let go at every source. A press
    /// still out stays out, and its answer lands nowhere.
    func closed(_ tag: PostTag) {
        let suffix = "\u{1e}" + MastodonRising.folded(tag)
        answered = answered.filter { !$0.key.hasSuffix(suffix) }
        missed = missed.filter { !$0.key.hasSuffix(suffix) }
        refused = refused.filter { !$0.key.hasSuffix(suffix) }
    }

    // MARK: - What somebody features

    private func standing(_ id: String, of accountID: String, at host: String, in session: ShellSession) -> Theirs? {
        theirs[id].flatMap { page in
            page.accountID == accountID && page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    /// The opening of the page of `who` once their source has said who they are, or nothing.
    func opening(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) -> Opening? {
        guard let person = said?.person, !person.suspended, let source = ShellPersonPages.source(of: who, in: session)
        else { return nil }
        return Opening(
            id: who.id, accountID: person.accountID, askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
            under: ShellPersonPages.signIns(at: source.host, in: session)
        )
    }

    /// What About of the page of `who` is handed of what they feature, or nothing.
    func said(of who: DummyPerson, said: PersonSaid?, own isOwn: Bool, in session: ShellSession) -> FeaturedSaid? {
        guard let person = said?.person, !person.suspended, let source = ShellPersonPages.source(of: who, in: session),
              let page = standing(who.id, of: person.accountID, at: source.host, in: session)
        else { return nil }
        var handed = FeaturedSaid(source: source.host, own: isOwn)
        if hosts.has(.featuredTags, at: source.host) != .absent {
            handed.tags = page.tags
            handed.tagsAsking = page.tagsAsking
            handed.tagsFailed = page.tagsFailed && !page.tagsAsking
        }
        if page.anyFeatured, hosts.has(.featuredPeople, at: source.host) != .absent {
            handed.people = PeopleList(featuredBy: person)
        }
        return handed
    }

    /// The page of `who` has said who they are: what they feature is asked, once a page.
    func opened(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, !person.suspended, let source = ShellPersonPages.source(of: who, in: session)
        else { return }
        let held = readers.look(at: source.host, in: session).held
        if standing(who.id, of: person.accountID, at: source.host, in: session) != nil {
            await asks[who.id]?.value
            return
        }
        await begin(who.id, of: person, at: source, with: held, in: session).value
    }

    /// "Try again" beside a failure to ask for their hashtags: asked once more.
    func again(_ who: DummyPerson, said: PersonSaid?, in session: ShellSession) async {
        guard let person = said?.person, let source = ShellPersonPages.source(of: who, in: session),
              let page = standing(who.id, of: person.accountID, at: source.host, in: session), !page.tagsAsking
        else { return }
        let held = readers.look(at: source.host, in: session).held
        await begin(who.id, of: person, at: source, with: held, in: session).value
    }

    private func begin(
        _ id: String, of person: Person, at source: Source, with held: MastodonToken?, in session: ShellSession
    ) -> Task<Void, Never> {
        asks[id]?.cancel()
        let errand = errands.next()
        var page = Theirs(
            host: source.host, accountID: person.accountID, askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
            under: ShellPersonPages.signIns(at: source.host, in: session)
        )
        page.awaits = errand
        let tagsWanted = hosts.has(.featuredTags, at: source.host) != .absent
        let peopleWanted = hosts.has(.featuredPeople, at: source.host) != .absent
        page.tagsAsking = tagsWanted
        theirs[id] = page
        let through = held.map { session.reach.featured(session.mastodon.authorized(token: $0, within: deadline, for: .person)) }
            ?? session.reach.unsignedFeatured(source.host, for: .person, within: deadline)
        let round = hosts.round(at: source.host)
        let accountID = person.accountID, askedAs = page.askedAs
        let task = Task {
            async let tags: Void = tagsWanted
                ? self.readTags(id, of: accountID, through: through, at: source, as: askedAs, errand: errand, in: session) : ()
            async let people: Void = peopleWanted
                ? self.readPeople(id, of: accountID, through: through, at: source, round: round, errand: errand, in: session) : ()
            _ = await (tags, people)
        }
        asks[id] = task
        return task
    }

    private func readTags(
        _ id: String, of accountID: String, through: MastodonFeatured, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        do {
            let tags = try await through.featuredTags(of: accountID, source: source)
            guard theirs[id]?.awaits == errand else { return }
            theirs[id]?.tags = tags
            theirs[id]?.tagsFailed = false
        } catch {
            guard theirs[id]?.awaits == errand else { return }
            // Not found, or refused to a reader with no sign-in: no block, and nothing of the host.
            if !Cancellation.happened(error), !Self.saysNothingOfThem(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                theirs[id]?.tagsFailed = true
            }
        }
        theirs[id]?.tagsAsking = false
    }

    private func readPeople(
        _ id: String, of accountID: String, through: MastodonFeatured, at source: Source, round: Int, errand: Int,
        in session: ShellSession
    ) async {
        do {
            let stretch = try await through.featuredPeople(of: accountID, source: source, limit: 1)
            guard theirs[id]?.awaits == errand else { return }
            theirs[id]?.anyFeatured = !stretch.people.isEmpty
        } catch {
            guard theirs[id]?.awaits == errand else { return }
            if (error as? MastodonHostMoreError) == .noSuchAddress { hosts.notFound(.featuredPeople, at: source.host, round: round) }
        }
    }

    /// Whether `error` from asking what somebody features says only that there is nothing to
    /// draw: an address or an account not found, or a refusal of a reader with no sign-in.
    private static func saysNothingOfThem(_ error: any Error) -> Bool {
        if (error as? MastodonHostMoreError) == .noSuchAddress { return true }
        let status: Int? = switch error {
        case MastodonAuthError.http(let code): code
        case MastodonRequestError.http(let code): code
        default: nil
        }
        return status == 401 || status == 404
    }

    // MARK: - A hashtag's page

    /// The feature rows of the page of `tag`, one under each of `follows` that is not absent,
    /// where the host keeps hashtags featured. `featuring` is what the hashtag's own answer
    /// said at a host, where it said.
    func lines(
        of tag: PostTag, beside follows: [TagFollowLine], featuring: (String) -> Bool?, in session: ShellSession
    ) -> [TagFeatureLine] {
        follows.compactMap { follow in
            let host = follow.host
            guard follow.standing != .absent, hosts.has(.featuredTags, at: host) != .absent else { return nil }
            guard Self.features(at: host, in: session) else {
                let place = session.mastodon.place(.account, host: host) ?? PartWords.Place(kind: .none, key: "part.account.unasked")
                return TagFeatureLine(host: host, tag: tag, standing: .locked(place))
            }
            let key = Self.key(tag, host)
            if let to = presses.shown(key), pressedUnder[key] == ShellPersonPages.signIns(at: host, in: session) {
                return TagFeatureLine(host: host, tag: tag, standing: .doing(to))
            }
            var line = TagFeatureLine(host: host, tag: tag, standing: .asking, missed: missed[key], refused: refused[key])
            if let said = answered[key] ?? featuring(host) {
                line.standing = .said(said)
            } else if let page = ownList(at: host, in: session) {
                if let tags = page.tags {
                    line.standing = .said(FeaturedTag.of(tag, in: tags) != nil)
                } else if page.failed, !page.asking {
                    line.standing = .unknown
                }
            }
            return line
        }
    }

    private func ownList(at host: String, in session: ShellSession) -> Own? {
        own[host].flatMap { page in
            page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    /// The page of `tag` in front, once its sources have said whether it is followed: where a
    /// hashtag's own answer did not say whether it is featured, the reader's own featured
    /// hashtags are asked of that source — once a run.
    func opened(_ tag: PostTag, beside follows: [TagFollowLine], featuring: (String) -> Bool?, in session: ShellSession) async {
        var waited: [Task<Void, Never>] = []
        for line in lines(of: tag, beside: follows, featuring: featuring, in: session) where line.standing == .asking {
            if let task = askOwn(at: line.host, again: false, in: session) { waited.append(task) }
        }
        for task in waited { await task.value }
    }

    /// The reader's own featured hashtags at `host` asked for: where they were not this run,
    /// or `again` after a failure. A second caller while it is on the wire waits on that ask.
    private func askOwn(at host: String, again: Bool, in session: ShellSession) -> Task<Void, Never>? {
        guard let source = ShellPersonPages.source(at: host, in: session), let held = readers.look(at: host, in: session).held
        else { return nil }
        if let page = ownList(at: host, in: session) {
            if page.asking { return ownAsks[host] }
            if page.tags != nil || (page.failed && !again) { return nil }
        }
        let errand = errands.next()
        var page = Own(askedAs: ShellPersonPages.askedAs(at: host, in: session), under: ShellPersonPages.signIns(at: host, in: session))
        page.asking = true
        page.awaits = errand
        own[host] = page
        let through = session.reach.featuring(session.mastodon.authorized(token: held, within: deadline, for: .person))
        let round = hosts.round(at: host)
        let task = Task {
            do {
                let tags = try await through.ownFeaturedTags()
                guard self.own[host]?.awaits == errand else { return }
                self.own[host]?.tags = tags
                self.own[host]?.failed = false
            } catch {
                guard self.own[host]?.awaits == errand else { return }
                if (error as? MastodonHostMoreError) == .noSuchAddress {
                    // The reader's own list's address: the host keeps no hashtags featured.
                    self.hosts.notFound(.featuredTags, at: host, round: round)
                } else if !Cancellation.happened(error) {
                    ShellPersonPages.concluded(error, at: source, askedAs: page.askedAs, in: session)
                    self.own[host]?.failed = true
                }
            }
            self.own[host]?.asking = false
        }
        ownAsks[host] = task
        return task
    }

    /// The reader's own featured hashtags at `host` asked for again, after a failure.
    @discardableResult
    func again(at host: String, in session: ShellSession) -> Task<Void, Never>? {
        askOwn(at: host, again: true, in: session)
    }

    /// Features `tag` at `host`, or with `to` false takes it off — **only over what its row
    /// says now** (`now`, as whoever holds the row works it out at the press), **as the reader
    /// it said it to, with the account part held**; one request out a hashtag and source.
    func press(_ tag: PostTag, at host: String, to: Bool, now line: TagFeatureLine?, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session), Self.features(at: host, in: session) else { return }
        let looked = readers.look(at: host, in: session)
        let key = Self.key(tag, host)
        guard let held = looked.held, !looked.changed, line?.standing == .said(!to),
              let flight = presses.begin(key, showing: to)
        else { return }

        missed[key] = nil
        refused[key] = nil
        let under = ShellPersonPages.signIns(at: host, in: session)
        pressedUnder[key] = under
        let through = session.reach.featuring(session.mastodon.authorized(token: held, within: deadline, for: .write))
        let round = hosts.round(at: host)
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        await Task {
            var done = false, absent = false
            var refusal: String?
            var made: FeaturedTag?
            do {
                if to { made = try await through.feature(tag: tag) } else { try await through.unfeature(tag: tag) }
                done = true
            } catch {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                if case .refused(let sentence) = error as? AccountPartError { refusal = sentence }
                absent = Self.hasNoSuchThing(error)
            }
            guard self.presses.isStill(flight, key) else { return }
            self.presses.settle(key)
            self.pressedUnder[key] = nil
            guard session.mastodon.token(host: host)?.accessToken == held.accessToken,
                  ShellPersonPages.signIns(at: host, in: session) == under
            else { return }
            if absent {
                // Refused as a thing the host does not have: absent for the run, and nothing failed.
                self.hosts.notFound(.featuredTags, at: host, round: round)
                return
            }
            guard done else {
                self.missed[key] = to
                self.refused[key] = refusal
                return
            }
            self.answered[key] = to
            if var tags = self.own[host]?.tags {
                tags.removeAll { MastodonRising.folded($0.tag) == MastodonRising.folded(tag) }
                if let made { tags.append(made) }
                self.own[host]?.tags = tags
            }
        }.value
    }

    /// Whether a refusal of featuring a hashtag says the host has no such thing: the address
    /// not there, or not taken at all (405).
    private static func hasNoSuchThing(_ error: any Error) -> Bool {
        if (error as? MastodonHostMoreError) == .noSuchAddress { return true }
        switch error {
        case MastodonAuthError.http(405), MastodonRequestError.http(405): return true
        default: return false
        }
    }
}
