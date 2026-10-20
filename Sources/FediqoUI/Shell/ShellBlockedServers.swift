import FediqoCore
import Foundation
import Observation

// The whole servers the reader blocks at a source (#314): what is asked, when, and what the sheet
// holds of the answers — and taking a block back from it.
//
// **Asked when the sheet opens, and when the person presses**, as a list of people is
// (`ShellPeoplePages`): one stretch at the opening, the next at the foot's press by the place the
// source named, from the top again at Try again. **One ask on the wire for the sheet**; a press
// while one is out asks nothing; an ask from the top calls a reading-on off.
//
// **As the reader, and there for nobody else.** The list is the reader's own: asked only through
// the signed-in door, let go when their sign-in at that host ends or changes (`PageReaders`), and
// held nowhere.
//
// **A server's block taken back leaves the list at the press**, under the one guard of a press
// (`PressGuard`): a second press meanwhile sends nothing, the row comes back saying so where the
// press did not arrive, and once the source has answered it is gone — **a read from the top that
// set out before that answer does not bring it back**; one that set out after is the list. What
// this device hid of everybody there shows again (`ShellHides`).

/// Every list of servers blocked opened this run, by host.
@MainActor
@Observable
final class ShellBlockedServers {
    typealias AskedAs = ShellPersonPages.AskedAs

    private struct Page {
        let host: String
        let askedAs: AskedAs
        let under: Int
        var servers: [String] = []
        var next: String?
        var answered = false
        var asking = false
        var failed = false
        var readingOn = false
        var footFailed = false
        var notPaging = false
        var awaits = 0
        /// The servers whose block was taken back here, each with the number the count stood at
        /// when the source answered: a read begun before that does not bring them back.
        var gone: [String: Int] = [:]
        /// The number of the read from the top now standing: what `gone` is held against.
        var readNumber = 0
    }

    /// The host whose list is up on its sheet, where one is.
    var open: String?

    private var pages: [String: Page] = [:]
    /// The servers whose block is being taken back, by host and server: off the list while out.
    private var unblocking = PressGuard<String, Bool>()
    /// The ones that did not arrive: said under the row until it is pressed again or read afresh.
    private var missed: Set<String> = []
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// How long a stretch is asked to be.
    static let stretchLength = 80

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    /// Everything of `host` let go, and its ask called off: its reader is no longer who asked.
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        unblocking.letGo { name, _ in name.hasPrefix(host + "\u{1e}") }
        missed = missed.filter { !$0.hasPrefix(host + "\u{1e}") }
    }

    private static func key(_ host: String, _ server: String) -> String { host + "\u{1e}" + server }

    private func standing(at host: String, in session: ShellSession) -> Page? {
        pages[host].flatMap {
            $0.under == ShellPersonPages.signIns(at: host, in: session)
                && $0.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? $0 : nil
        }
    }

    // MARK: - What the sheet is handed

    /// What the sheet of `host`'s list draws, or nothing where nobody is signed in there.
    func said(at host: String, in session: ShellSession) -> BlockedServersSaid? {
        guard ShellPersonPages.source(at: host, in: session) != nil, session.mastodon.token(host: host) != nil else { return nil }
        var said = BlockedServersSaid(host: host)
        if !ShellPersonActs.blocks(at: host, in: session) {
            said.lock = session.mastodon.place(.blocks, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
        }
        said.unblocks = said.lock == nil
        guard let page = standing(at: host, in: session) else { return said }
        said.reading = page.answered ? .said : page.failed ? .failed : .asking
        said.servers = page.servers.filter { server in
            page.gone[server].map { $0 < page.readNumber } != false && unblocking.shown(Self.key(host, server)) == nil
        }
        said.missed = Set(said.servers.filter { missed.contains(Self.key(host, $0)) })
        said.foot = !page.answered || page.readingOn || page.asking ? nil
            : page.notPaging ? .stopped : page.footFailed ? .failed : page.next != nil ? .more : .end
        said.asking = page.asking || page.readingOn
        return said
    }

    // MARK: - Asking

    /// The sheet put up for `host`, and its list asked where it was not answered yet.
    func show(_ host: String, in session: ShellSession) async {
        open = host
        if let page = standing(at: host, in: session), page.answered || page.asking { return }
        await again(host, in: session)
    }

    /// The list of `host` asked from the top. **A press while it is asked asks nothing.**
    func again(_ host: String, in session: ShellSession) async {
        let looked = readers.look(at: host, in: session)
        guard let held = looked.held, ShellPersonActs.seesBlocks(at: host, in: session) else { return }
        if standing(at: host, in: session)?.asking == true { return }
        if standing(at: host, in: session) == nil {
            pages[host] = Page(
                host: host, askedAs: ShellPersonPages.askedAs(at: host, in: session),
                under: ShellPersonPages.signIns(at: host, in: session)
            )
        }
        asks[host]?.cancel()
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        pages[host]?.readingOn = false
        let door = session.reach.serverBlocks(session.mastodon.authorized(token: held, within: deadline, for: .people))
        let ticket = session.hides.ticket()
        let task = Task { await self.read(host, through: door, after: nil, errand: errand, ticket: ticket, in: session) }
        asks[host] = task
        await task.value
    }

    /// The foot's press: the stretch after what is drawn, by the place the source named.
    func readOn(_ host: String, in session: ShellSession) async {
        let looked = readers.look(at: host, in: session)
        guard let held = looked.held, let page = standing(at: host, in: session), page.answered, !page.asking,
              !page.readingOn, let next = page.next
        else { return }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.readingOn = true
        pages[host]?.footFailed = false
        let door = session.reach.serverBlocks(session.mastodon.authorized(token: held, within: deadline, for: .people))
        let task = Task { await self.read(host, through: door, after: next, errand: errand, ticket: session.hides.ticket(), in: session) }
        asks[host] = task
        await task.value
    }

    private func read(
        _ host: String, through door: MastodonServerBlocks, after next: String?, errand: Int, ticket: Int, in session: ShellSession
    ) async {
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        let askedAs = pages[host]?.askedAs ?? .nobody
        do {
            let stretch = try await door.stretch(after: next, limit: Self.stretchLength)
            guard pages[host]?.awaits == errand, standing(at: host, in: session) != nil else { return }
            if next == nil {
                pages[host]?.servers = stretch.servers
                pages[host]?.readNumber = errand
                // The whole list in one stretch: a server hidden here and not in it is blocked no
                // longer — taken back elsewhere — and hides nothing more (#314).
                if stretch.next == nil {
                    let listed = Set(stretch.servers)
                    for hide in session.hides.hides where hide.host == host.lowercased() && hide.why == .server {
                        if let server = hide.server, !listed.contains(server) { session.hides.show(server: server, at: host, since: ticket) }
                    }
                }
                missed = missed.filter { !$0.hasPrefix(host + "\u{1e}") }
            } else {
                let had = Set(pages[host]?.servers ?? [])
                pages[host]?.servers += stretch.servers.filter { !had.contains($0) }
            }
            pages[host]?.next = stretch.next
            pages[host]?.answered = true
            pages[host]?.failed = false
            pages[host]?.notPaging = false
        } catch {
            guard pages[host]?.awaits == errand, let source = ShellPersonPages.source(at: host, in: session) else { return }
            if Cancellation.happened(error) { return }
            ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
            if (error as? PagingError) == .notPaging {
                pages[host]?.notPaging = true
            } else if next == nil {
                pages[host]?.failed = true
            } else {
                pages[host]?.footFailed = true
            }
        }
        pages[host]?.asking = false
        pages[host]?.readingOn = false
    }

    // MARK: - Taking a block back

    /// Unblock on the row of `server`: the source told to block it no longer. **Only of a server
    /// the sheet lists, to a sign-in that may, with no such press out.** Whether it was done.
    @discardableResult
    func unblock(_ server: String, at host: String, in session: ShellSession) async -> Bool {
        guard let said = said(at: host, in: session), said.unblocks, said.servers.contains(server) else { return false }
        let looked = readers.look(at: host, in: session)
        let key = Self.key(host, server)
        guard let held = looked.held, !looked.changed, let page = standing(at: host, in: session),
              let flight = unblocking.begin(key, showing: true)
        else { return false }
        missed.remove(key)
        let door = session.reach.serverBlocks(session.mastodon.authorized(token: held, within: deadline, for: .write))
        var done = false
        do {
            try await door.unblock(server)
            done = true
        } catch {
            if let source = ShellPersonPages.source(at: host, in: session) {
                ShellPersonPages.concluded(error, at: source, askedAs: page.askedAs, in: session)
            }
        }
        // Taken back at the source: what this device hid of everybody there shows, whatever
        // became of the sheet or its reader meanwhile.
        if done { session.hides.show(server: server, at: host) }
        guard unblocking.isStill(flight, key) else { return false }
        unblocking.settle(key)
        guard session.mastodon.token(host: host)?.accessToken == held.accessToken, standing(at: host, in: session) != nil else {
            return false
        }
        if done {
            pages[host]?.gone[server] = errands.next()
        } else {
            missed.insert(key)
        }
        return done
    }
}
