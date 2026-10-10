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
// page says, in one sentence, that this sign-in was not given it. Asking a sign-in for more is
// another unit's, and nothing here pretends to.
//
// **An ask is this object's, and not the sheet's**, numbered on the one count every page's asks
// are numbered on and landing only where its number is still the one awaited. **Held nowhere**:
// for this run, in memory. **Read, and never written** — and nothing here starts a post from it.
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

    private var pages: [String: Page] = [:]
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
    static func opening(_ host: String, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: host, askedAs: ShellPersonPages.askedAs(at: host, in: session))
    }

    /// What was told of `host` let go, and its ask called off: its reader is no longer who
    /// asked (`PageReaders`). Whatever an ask already out brings, it brings to nobody.
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
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

    /// Writes down the name the source has since given the reader a page was asked as.
    private func named(_ host: String, as now: AskedAs) {
        if case .reader(nil) = pages[host]?.askedAs, case .reader(.some) = now { pages[host]?.askedAs = now }
    }
}
