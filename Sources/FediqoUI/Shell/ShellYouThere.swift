import FediqoCore
import Foundation
import Observation

// What the person set at a source for the posts they write there (#321) — who a new post is
// for, its language, whether its media is covered — for that source's own page: what is asked,
// when, and what the page is handed of the answer.
//
// **Asked when the source's page opens, once a run for a host, and only of a source the reader
// is signed in to**: one small ask, through the one signed-in door, to the host the sign-in is
// of. Opened again, the page is drawn from what was answered; a failure's "Try again" asks
// once more, and a press while the ask is on the wire asks nothing. Nothing is asked while no
// such page is open, nothing by itself, and nothing at all where nobody is signed in.
//
// **As whoever asked, and nobody else's.** What a source says somebody set there is theirs:
// each answer remembers who it was asked as, is not there for anybody else, and is let go —
// its ask called off — when the sign-in to that host ends, begins or changes (`PageReaders`).
// And an answer lands only while whoever would ask now is still who it was asked as: one that
// arrives after its reader signed out is nobody's, and is kept for nobody.
//
// **A sign-in that was not given this says so, and no press stands beside it.** A source that refuses the
// address to this sign-in is not a failure to try again and not the end of the sign-in: the
// page says, in one sentence, that this sign-in was not given it. Only the row below asks a
// sign-in for more, for what that row itself needs.
//
// **An ask is this object's, and not the sheet's**, numbered on the one count every page's asks
// are numbered on and landing only where its number is still the one awaited. **Held nowhere**:
// for this run, in memory. **Read, and never written, but for one row** — and nothing here starts
// a post from it.
//
// **Who may quote a new post is the one row that changes (#437)**, only at a source with quotes,
// and only from the account as its owner sees it: where the sign-in lacks the account part it is
// the part's lock, with what the source said beside it. **One change at a time**, and a press
// while one is out does nothing. A change is never called off, not even by the reader going: when
// it ends what was told is let go, so a read already out lands nowhere and a new post's menu and this
// page ask again. A refusal changes nothing; no answer may have changed it, so it is read again.
//
// **Only where the source is one that says who people are** — the one fact per kind there is,
// read where a person's page reads it. A forum's page is handed nothing and asks nobody.

/// What a source's page is handed of what the person set there.
struct YouThereSaid: Equatable {
    /// Where asking has got to.
    enum Reading: Equatable {
        /// Not answered yet: on the wire, about to be, or stopped before it answered.
        case asking
        /// The source answered, and this is what it says the person set.
        case said(PostingDefaults)
        /// The source refused this sign-in the address: it was not given this.
        case notGiven
        /// The source failed, or sent what could not be read.
        case failed
    }

    /// The host of the source that says.
    let source: String
    var reading: Reading = .asking
    /// Whether the ask is on the wire.
    var asking = false
}

/// The row of who may quote a new post, as a source's page is handed it.
struct YouThereQuotes: Equatable {
    /// What became of the last change, said under the row.
    enum Told: Equatable {
        /// The source would not take it: its words, empty where it sent none.
        case refused(String)
        /// The source refused this sign-in the change, though it holds the part.
        case forbidden
        /// No answer came: what is drawn was asked again.
        case missed
        /// The source says this sign-in does not hold the part, though it was held at the press.
        case partGone
    }

    enum Shape: Equatable {
        /// The sign-in lacks the account part: the lock's sentence, and what the source said.
        case locked(String, set: QuotePolicy?)
        case asking
        case failed
        /// What the source holds, or the choice on its way there.
        case held(QuotePolicy, sending: Bool, told: Told?)
    }

    /// The host of the source that says.
    let source: String
    let shape: Shape

    /// What the row's task is named by: it runs again for another reader, a host heard from, a
    /// lock lifted, or a setting changed.
    struct Opening: Hashable {
        let page: ShellPersonPages.Opening
        /// Which sign-in: one filed anew under the same name is another, and is read for itself.
        let signIns: Int
        let offered: Bool?
        let locked: Bool
    }
}

/// What every source's page was told this run of what the person set there, by host.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellYouThere {
    typealias AskedAs = ShellPersonPages.AskedAs

    private struct Page {
        var askedAs: AskedAs
        var reading: YouThereSaid.Reading = .asking
        var asking = false
        /// The number of the ask whose answer this page awaits.
        var awaits = 0

        /// Whether asking came to something. A page that is not settled and has nothing on
        /// the wire — an ask that was stopped — is asked again when it opens.
        var settled: Bool { reading != .asking }
    }

    /// The account as its owner sees it, read for the row of who may quote a new post.
    private struct Quotes {
        var askedAs: AskedAs
        /// Which sign-in at the host that was: a reader not named yet is known by this alone.
        var under: Int
        /// What a change starts from. Nothing until the read lands.
        var account: OwnAccount?
        var failed = false
        var asking = false
        var awaits = 0
        var told: YouThereQuotes.Told?
    }

    private var pages: [String: Page] = [:]
    private var quotes: [String: Quotes] = [:]
    /// A change on its way, and whose: drawn only for that sign-in, which alone it holds back.
    private struct Sending {
        let policy: QuotePolicy
        let askedAs: AskedAs
        let under: Int
        let errand: Int
    }

    /// The last change sent to each host. One of a sign-in since gone may still be out behind it.
    private var quotesSending: [String: Sending] = [:]
    /// The read of the account on the wire for each host.
    @ObservationIgnored private var quotesAsks: [String: Task<Void, Never>] = [:]
    /// How many times each host's settings were changed from here: part of a block's opening.
    private var settingsTurned: [String: Int] = [:]
    /// The ask on the wire for each host: what a second opening waits on, and asks nothing.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long the ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to what a source says the person set, where a test reaches it by one — a
    /// wire that goes on answering an ask that was called off. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonToken) -> MastodonSettings)?

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    /// A source's page opening, as this block's task is named: which host **and who asks**, so
    /// a page in front whose reader ends, begins or changes opens again by itself.
    func opening(_ host: String, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: host, askedAs: ShellPersonPages.askedAs(at: host, in: session), under: settingsTurned[host] ?? 0)
    }

    /// What was told of `host` let go, and its ask called off: its reader is no longer who
    /// asked (`PageReaders`). Whatever an ask already out brings, it brings to nobody.
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        quotesAsks[host]?.cancel()
        quotesAsks[host] = nil
        quotes[host] = nil
    }

    /// What was told of `host` let go because the setting itself changed, **and a block already
    /// up told to ask**: its opening is another from here on, so its task runs again.
    func settingsChanged(at host: String) {
        letGo(at: host)
        settingsTurned[host, default: 0] += 1
    }

    // MARK: - What the page is handed

    /// The source at `host` and who would ask it now, where there is something to draw: the
    /// source says who people are, **and the reader is signed in to it**.
    private func asker(at host: String, in session: ShellSession) -> (source: Source, askedAs: AskedAs)? {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return nil }
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        return askedAs == .nobody ? nil : (source, askedAs)
    }

    private func standing(at host: String, as askedAs: AskedAs) -> Page? {
        pages[host].flatMap { $0.askedAs.isTheSame(as: askedAs) ? $0 : nil }
    }

    /// What the page of the source at `host` is handed, or nothing: nobody is signed in there,
    /// or the source is not one that says who people are. Nothing is then drawn of this.
    func said(at host: String, in session: ShellSession) -> YouThereSaid? {
        guard let (source, askedAs) = asker(at: host, in: session) else { return nil }
        let page = standing(at: source.host, as: askedAs)
        return YouThereSaid(source: source.host, reading: page?.reading ?? .asking, asking: page?.asking ?? false)
    }

    // MARK: - Asking

    /// The page of the source at `host` opening. Asked once a run: opened again, it is drawn
    /// from what was answered; opened while the ask is on the wire, it waits on that ask and
    /// starts none; opened after an ask that was stopped, or as somebody else, it is asked.
    func opened(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return }
        // The one look at the sign-in: a reader who changed lets what the last was given go.
        guard let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session)
        else { return }
        if let page = standing(at: source.host, as: askedAs) {
            named(source.host, as: askedAs)
            if page.asking {
                await asks[source.host]?.value
                return
            }
            if page.settled { return }
        }
        await begin(source, as: askedAs, with: held, in: session).value
    }

    /// A failure's "Try again": asked once more. **A press while the ask is on the wire asks
    /// nothing**, and so does one where the source answered, or refused this sign-in.
    func again(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session),
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session)
        else { return }
        if let page = standing(at: source.host, as: askedAs), page.asking || page.reading != .failed { return }
        await begin(source, as: askedAs, with: held, in: session).value
    }

    /// Starts the ask, and hands back the task it runs in. Everything it needs is taken here,
    /// before anything waits: the host, who asks, the door.
    private func begin(
        _ source: Source, as askedAs: AskedAs, with held: MastodonToken, in session: ShellSession
    ) -> Task<Void, Never> {
        let host = source.host
        if pages[host]?.askedAs.isTheSame(as: askedAs) != true { pages[host] = Page(askedAs: askedAs) }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        let through = reaching?(held)
            ?? session.reach.settings(session.mastodon.authorized(token: held, within: deadline, for: .ownSettings))
        let task = Task { await self.ask(source, of: through, as: askedAs, errand: errand, in: session) }
        asks[host] = task
        return task
    }

    private func ask(
        _ source: Source, of through: MastodonSettings, as askedAs: AskedAs, errand: Int, in session: ShellSession
    ) async {
        let host = source.host
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let set = try await through.postingDefaults()
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            pages[host]?.reading = .said(set)
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if Self.wasNotGiven(error) {
                pages[host]?.reading = .notGiven
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[host]?.reading = .failed
            }
        }
        // Nothing is left asking with nothing on the wire.
        pages[host]?.asking = false
    }

    /// Whether an answer may land: its ask is still the one the page awaits, **and whoever would
    /// ask now is still who it was asked as**. Where the reader has gone since — signed out
    /// with nothing pressed — what was kept for them is let go, and the answer lands nowhere.
    private func stillTheirs(_ host: String, errand: Int, askedAs: AskedAs, in session: ShellSession) -> Bool {
        guard pages[host]?.awaits == errand else { return false }
        guard ShellPersonPages.askedAs(at: host, in: session).isTheSame(as: askedAs) else {
            pages[host] = nil
            return false
        }
        return true
    }

    /// Whether `error` is the source refusing this sign-in the address — asked of a real one:
    /// 403, for a sign-in that lacks the word for reading the person's own account.
    static func wasNotGiven(_ error: any Error) -> Bool {
        (error as? MastodonAuthError) == .http(403)
    }

    // MARK: - Who may quote a new post

    func quotesOpening(_ host: String, in session: ShellSession) -> YouThereQuotes.Opening {
        YouThereQuotes.Opening(
            page: opening(host, in: session), signIns: ShellPersonPages.signIns(at: host, in: session),
            offered: session.quotesOffered(host: host),
            locked: session.mastodon.place(.account, host: host) != nil
        )
    }

    private func standingQuotes(at host: String, in session: ShellSession) -> Quotes? {
        quotes[host].flatMap { ShellPersonPages.stillAsked(host: host, askedAs: $0.askedAs, under: $0.under, in: session) ? $0 : nil }
    }

    /// The change out for whoever would ask now: nothing where the one out is another sign-in's.
    private func sending(at host: String, in session: ShellSession) -> Sending? {
        quotesSending[host].flatMap { ShellPersonPages.stillAsked(host: host, askedAs: $0.askedAs, under: $0.under, in: session) ? $0 : nil }
    }

    /// The row for the source at `host`, or nothing: nobody is signed in, the source has no
    /// quotes or has not said, or its account says nothing of this.
    func quotes(at host: String, in session: ShellSession) -> YouThereQuotes? {
        guard let (source, askedAs) = asker(at: host, in: session), session.quotesOffered(host: source.host) == true else { return nil }
        if let place = session.mastodon.place(.account, host: source.host) {
            let words = L10n.t(place.key)
            var set: QuotePolicy?
            if case .said(let said)? = standing(at: source.host, as: askedAs)?.reading { set = said.quotePolicy }
            let sentence = words.contains("%@") ? String(format: words, source.host) : words
            return YouThereQuotes(source: source.host, shape: .locked(sentence, set: set))
        }
        guard let read = standingQuotes(at: source.host, in: session) else {
            return YouThereQuotes(source: source.host, shape: .asking)
        }
        if read.failed, !read.asking { return YouThereQuotes(source: source.host, shape: .failed) }
        guard let account = read.account else { return YouThereQuotes(source: source.host, shape: .asking) }
        guard let held = account.quotePolicy else { return nil }
        let out = sending(at: source.host, in: session)
        return YouThereQuotes(source: source.host, shape: .held(out?.policy ?? held, sending: out != nil, told: read.told))
    }

    /// The row up: whether the source has quotes heard, and the account read, once a run.
    func quotesOpened(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return }
        await session.quoting.hosts?.hear(source.host, in: session)
        guard session.quotesOffered(host: source.host) == true,
              session.mastodon.place(.account, host: source.host) == nil,
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session)
        else { return }
        if let read = standingQuotes(at: source.host, in: session) {
            if read.asking {
                await quotesAsks[source.host]?.value
                return
            }
            if read.account != nil || read.failed { return }
        }
        await beginQuotes(source, as: askedAs, with: held, in: session).value
    }

    /// A failed read's "Try again". A press while a read is out asks nothing.
    func quotesAgain(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session),
              session.mastodon.place(.account, host: source.host) == nil,
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session),
              let read = standingQuotes(at: source.host, in: session), read.failed, !read.asking
        else { return }
        await beginQuotes(source, as: askedAs, with: held, in: session).value
    }

    private func beginQuotes(
        _ source: Source, as askedAs: AskedAs, with held: MastodonToken, in session: ShellSession
    ) -> Task<Void, Never> {
        let host = source.host
        if standingQuotes(at: host, in: session) == nil {
            quotes[host] = Quotes(askedAs: askedAs, under: ShellPersonPages.signIns(at: host, in: session))
        }
        let errand = errands.next()
        quotes[host]?.awaits = errand
        quotes[host]?.asking = true
        quotes[host]?.failed = false
        let own = session.reach.ownAccount(session.mastodon.authorized(token: held, within: deadline, for: .ownSettings))
        let task = Task { await self.readQuotes(source, through: own, as: askedAs, errand: errand, in: session) }
        quotesAsks[host] = task
        return task
    }

    private func readQuotes(
        _ source: Source, through own: MastodonOwnAccount, as askedAs: AskedAs, errand: Int, in session: ShellSession
    ) async {
        let host = source.host
        defer { if quotes[host]?.awaits == errand { quotesAsks[host] = nil } }
        do {
            let account = try await own.read()
            guard quotesStillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            quotes[host]?.account = account
        } catch {
            guard quotesStillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                quotes[host]?.failed = true
            }
        }
        quotes[host]?.asking = false
    }

    private func quotesStillTheirs(_ host: String, errand: Int, askedAs: AskedAs, in session: ShellSession) -> Bool {
        guard quotes[host]?.awaits == errand else { return false }
        guard standingQuotes(at: host, in: session) != nil,
              ShellPersonPages.askedAs(at: host, in: session).isTheSame(as: askedAs)
        else {
            quotes[host] = nil
            return false
        }
        return true
    }

    /// `policy` chosen on the row: sent as a change of that alone, from the account as read. The
    /// task it runs in; nothing where it cannot go — one of theirs is out, the read has not landed,
    /// or it is what the source holds.
    @discardableResult
    func chooseQuotes(_ policy: QuotePolicy, at host: String, in session: ShellSession) -> Task<Void, Never>? {
        guard let source = ShellPersonPages.source(at: host, in: session),
              session.quotesOffered(host: source.host) == true,
              session.mastodon.place(.account, host: source.host) == nil,
              let held = readers.look(at: source.host, in: session).held,
              let (_, askedAs) = asker(at: source.host, in: session),
              sending(at: source.host, in: session) == nil,
              let read = standingQuotes(at: source.host, in: session), !read.asking,
              let before = read.account, let was = before.quotePolicy, was != policy
        else { return nil }
        var after = before
        after.quotePolicy = policy
        quotes[source.host]?.told = nil
        let errand = errands.next()
        let under = ShellPersonPages.signIns(at: source.host, in: session)
        quotesSending[source.host] = Sending(policy: policy, askedAs: askedAs, under: under, errand: errand)
        let own = session.reach.ownAccount(session.mastodon.authorized(token: held, within: deadline, for: .write))
        return Task { await self.sendQuotes(from: before, to: after, at: source, through: own, as: askedAs, under: under, errand: errand, in: session) }
    }

    private func sendQuotes(
        from before: OwnAccount, to after: OwnAccount, at source: Source, through own: MastodonOwnAccount,
        as askedAs: AskedAs, under: Int, errand: Int, in session: ShellSession
    ) async {
        let host = source.host
        defer { if quotesSending[host]?.errand == errand { quotesSending[host] = nil } }
        func theirs() -> Bool { ShellPersonPages.stillAsked(host: host, askedAs: askedAs, under: under, in: session) }
        do {
            let answer = try await own.change(from: before, to: after)
            ShellPersonPages.settingsChanged(at: host, in: session)
            guard let answer, theirs() else { return }
            quotes[host] = Quotes(askedAs: askedAs, under: under, account: answer.account)
        } catch OwnAccountError.refused(let sentence, let rows) {
            guard theirs() else { return }
            let row = rows[.quotePolicy] ?? ""
            quotes[host]?.told = .refused(row.isEmpty ? sentence : row)
        } catch OwnAccountError.forbidden {
            guard theirs() else { return }
            quotes[host]?.told = .forbidden
        } catch OwnAccountError.locked {
            // The row is the part's lock where the words held say so; where they do not, this says it.
            guard theirs() else { return }
            quotes[host]?.told = .partGone
        } catch {
            ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
            // No answer: it may have landed, so everything told is let go and asked again.
            ShellPersonPages.settingsChanged(at: host, in: session)
            guard theirs() else { return }
            quotes[host] = Quotes(askedAs: askedAs, under: under, told: .missed)
        }
    }

    /// Writes down the name the source has since given the reader a page was asked as.
    private func named(_ host: String, as now: AskedAs) {
        if case .reader(nil) = pages[host]?.askedAs, case .reader(.some) = now { pages[host]?.askedAs = now }
    }
}
