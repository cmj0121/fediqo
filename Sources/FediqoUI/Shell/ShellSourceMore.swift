import FediqoCore
import Foundation
import Observation

// What a source says of itself beyond its one document (#321) — its longer account, the servers
// it knows, how busy it has been — for that source's own page: what is asked, when, and what
// the page is handed of the answers.
//
// **Asked when the source's page opens, and when the person presses.** Opening asks for the
// longer account and for the weeks, each at its own address, one after the other: two small
// asks the first time a run opens a source's page, and none when it is opened again. **The
// servers it knows are asked for at their own line's press, and not before**: a large host
// names tens of thousands, and nobody who only opened the page asked for that. One ask a
// press; a press while it is out, or once it has answered, asks nothing. "Ask again" lets go
// of what the run knew of that host and asks the two afresh, and the servers at their next
// press. Nothing is asked while no such page is open, and nothing by itself.
//
// **With no sign-in, of that host alone.** Anyone is given all three, so no token rides on
// these asks: they go out on the plain client, held to the small body's ceiling and to the host
// they are asked at, listed in the run's record and ended within the deadline. The list of
// servers has a ceiling of its own, larger and still held as the body arrives; one past it is
// said as that, and only so many names are kept whatever arrives.
//
// **Absent where the host says the address is not there.** Two of the three can be switched off
// by whoever runs a host, and then answer a not-found of their own address. That is written
// down for the run where every such answer is (`ShellHostsKnown`), the thing is then handed to
// the page as nothing at all — not dim, not a failure — and it is not asked for again until the
// host is asked afresh. Any other refusal is a failure, said with a way to ask again.
//
// **An ask is this object's, and not the sheet's**, numbered on the one count every page's asks
// are numbered on and landing only where its number is still the one awaited; **as whoever
// asked**, and let go with their sign-in, which also asks the host afresh — what a host keeps
// from nobody it may give to somebody. Each for the reason given where a person's page keeps
// the same rule (`ShellPersonPages`). **Held nowhere**: for this run, in memory.
//
// **Two lines open a page of people, and ask nothing by being drawn** (#315): the source's
// directory, offered to anyone, and the people it suggests, offered only to somebody signed in
// there. Each is asked for by the page it opens, and is not offered where the host said, this
// run, that its address is not there.
//
// **Only where the source is one that says who people are** — the one fact per kind there is,
// read where a person's page reads it. A forum's page is handed nothing and asks nobody.

/// What a source's page is handed of what the host says of itself beyond its document.
struct SourceMoreSaid: Equatable {
    /// Where one of the three has got to.
    enum Told<Value: Equatable>: Equatable {
        /// Not answered yet: on the wire, about to be, or stopped before it answered.
        case waiting
        /// The host answered, and this is what it said — which may be nothing written.
        case said(Value)
        /// The host refused, failed, or sent what could not be read.
        case failed
        /// The host sent more than is read here: the answer was cut off as it arrived.
        case tooLarge
    }

    /// The host of the source that says.
    let source: String
    /// Each of the three, or **nothing where the host says it has no such thing**.
    var account: Told<HostAccount>? = .waiting
    var servers: Told<HostServers>? = .waiting
    var weeks: Told<[HostWeek]>? = .waiting
    /// Whether the asks made at the page's opening are on the wire.
    var asking = false
    /// Whether the servers it knows are being asked for: their line was pressed.
    var askingServers = false
    /// Whether its directory of people is offered (#315): everywhere but where the host said,
    /// this run, that the directory's address is not there. Asked for by the page it opens.
    var directory = true
    /// Whether the people it suggests are offered (#315): only to somebody signed in there —
    /// a source suggests nobody anything unsigned — and not where the host said, this run, that
    /// their address is not there. Asked for by the page it opens.
    var suggested = false

    /// Whether the host has none of the three, and no page of people that this page can open:
    /// there is then nothing to list, and one sentence says so.
    func isAbsent(opensDirectory: Bool) -> Bool {
        account == nil && servers == nil && weeks == nil && !((directory || suggested) && opensDirectory)
    }
}

/// What every source's page was told this run of what its host says of itself, by host.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellSourceMore {
    typealias AskedAs = ShellPersonPages.AskedAs
    typealias Told = SourceMoreSaid.Told

    private struct Page {
        var askedAs: AskedAs
        var account: Told<HostAccount> = .waiting
        var servers: Told<HostServers> = .waiting
        var weeks: Told<[HostWeek]> = .waiting
        var asking = false
        /// The number of the round of asks whose answers this page awaits.
        var awaits = 0
        var askingServers = false
        /// The number of the ask for the servers whose answer this page awaits.
        var awaitsServers = 0
    }

    private var pages: [String: Page] = [:]
    /// The round on the wire for each host: what a second opening waits on, and asks nothing.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    /// The ask for the servers on the wire for each host.
    @ObservationIgnored private var serverAsks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// What this run knows each host has: where a not-found of an address is written down.
    let hosts: ShellHostsKnown
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to what a host says of itself, where a test reaches it by one — a wire that
    /// goes on answering an ask that was called off, as a transfer already ended does. Nothing
    /// in the app.
    @ObservationIgnored var reaching: ((String) -> MastodonHostMore)?

    init(errands: PageErrands, readers: PageReaders, hosts: ShellHostsKnown) {
        self.errands = errands
        self.readers = readers
        self.hosts = hosts
    }

    /// A source's page opening, as its task is named: which host **and who asks**, so a page in
    /// front whose reader ends, begins or changes opens again by itself, and is asked.
    static func opening(_ host: String, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: host, askedAs: ShellPersonPages.askedAs(at: host, in: session))
    }

    /// What was told of `host` let go, its round called off, and the host itself asked afresh:
    /// its reader is no longer who asked (`PageReaders`).
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        serverAsks[host]?.cancel()
        serverAsks[host] = nil
        pages[host] = nil
        hosts.askAfresh(host)
    }

    // MARK: - What the page is handed

    private func standing(at source: Source, in session: ShellSession) -> Page? {
        pages[source.host].flatMap {
            $0.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: source.host, in: session)) ? $0 : nil
        }
    }

    /// What the page of the source at `host` is handed, or nothing where that source is not
    /// one that says who people are — or is no longer there: nothing is then drawn of this.
    func said(at host: String, in session: ShellSession) -> SourceMoreSaid? {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return nil }
        let page = self.standing(at: source, in: session)
        func told<Value>(_ thing: MastodonHostThing, _ value: Told<Value>?) -> Told<Value>? {
            hosts.has(thing, at: source.host) == .absent ? nil : value ?? .waiting
        }
        return SourceMoreSaid(
            source: source.host, account: told(.longerAccount, page?.account), servers: told(.knownServers, page?.servers),
            weeks: told(.activity, page?.weeks), asking: page?.asking ?? false, askingServers: page?.askingServers ?? false,
            directory: hosts.has(.directory, at: source.host) != .absent,
            suggested: ShellPersonPages.askedAs(at: source.host, in: session) != .nobody
                && hosts.has(.suggestions, at: source.host) != .absent
        )
    }

    /// Whether each thing asked for at the opening was answered, or failed: a page that is not settled
    /// and has nothing on the wire — a round that was stopped — is asked again when it opens.
    private func settled(_ page: Page, at host: String) -> Bool {
        func waits<Value>(_ thing: MastodonHostThing, _ value: Told<Value>) -> Bool {
            value == .waiting && hosts.has(thing, at: host) != .absent
        }
        return !waits(.longerAccount, page.account) && !waits(.activity, page.weeks)
    }

    // MARK: - Asking

    /// The page of the source at `host` opening. Asked once a run: opened again, it is drawn
    /// from what was answered; opened while its round is on the wire, it waits on that round
    /// and starts none; opened after a round that was stopped, or as somebody else, it is asked.
    func opened(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return }
        _ = readers.look(at: source.host, in: session)
        if let page = self.standing(at: source, in: session) {
            if page.asking {
                await asks[source.host]?.value
                return
            }
            if settled(page, at: source.host) { return }
        }
        await begin(source, afresh: false, in: session).value
    }

    /// "Ask again", and a failure's "Try again": everything this run knew of the host is let
    /// go — so a thing it said it has not is asked for once more — and the two are asked
    /// afresh; the servers it knows go back to being asked for at their press. What else the
    /// page holds stays drawn until the answers land. **A press while a round is on the wire
    /// asks nothing.**
    func again(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session) else { return }
        _ = readers.look(at: source.host, in: session)
        if self.standing(at: source, in: session)?.asking == true { return }
        await begin(source, afresh: true, in: session).value
    }

    /// Starts a round, and hands back the task it runs in. Everything it needs is taken here,
    /// before anything waits: the host, who asks, the way to it.
    private func begin(_ source: Source, afresh: Bool, in session: ShellSession) -> Task<Void, Never> {
        let host = source.host
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        if pages[host]?.askedAs.isTheSame(as: askedAs) != true { pages[host] = Page(askedAs: askedAs) }
        if afresh {
            hosts.askAfresh(host)
            serverAsks[host]?.cancel()
            serverAsks[host] = nil
            pages[host]?.servers = .waiting
            pages[host]?.askingServers = false
            pages[host]?.awaitsServers = 0
        }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        let through = reaching?(host) ?? session.reach.unsignedHost(host, for: .serverSays, within: deadline)
        // Taken after this round's own asking afresh: what it hears is of the host as asked now.
        let round = hosts.round(at: host)
        let task = Task { await self.ask(host, of: through, errand: errand, round: round) }
        asks[host] = task
        return task
    }

    private func ask(_ host: String, of through: MastodonHostMore, errand: Int, round: Int) async {
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        if await take(.longerAccount, at: host, errand: errand, round: round, into: \.account, { try await through.longerAccount() }) {
            _ = await take(.activity, at: host, errand: errand, round: round, into: \.weeks) { try await through.activity() }
        }
        // Nothing is left asking with nothing on the wire — and a newer round's mark is its own.
        if pages[host]?.awaits == errand { pages[host]?.asking = false }
    }

    /// The press on "Servers it knows": the one ask for them, under a ceiling of its own.
    /// **Asked once**: a press while it is out waits on it, and one after it has answered asks
    /// nothing — so folding the line and unfolding it again costs no ask. A failure, or an
    /// answer past the ceiling, is asked for again at the next press.
    func servers(_ host: String, in session: ShellSession) async {
        guard let source = ShellPersonPages.source(at: host, in: session),
              hosts.has(.knownServers, at: source.host) != .absent
        else { return }
        _ = readers.look(at: source.host, in: session)
        let host = source.host
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        if pages[host]?.askedAs.isTheSame(as: askedAs) != true { pages[host] = Page(askedAs: askedAs) }
        if pages[host]?.askingServers == true {
            await serverAsks[host]?.value
            return
        }
        if case .said = pages[host]?.servers { return }
        let errand = errands.next()
        pages[host]?.awaitsServers = errand
        pages[host]?.askingServers = true
        let through = reaching?(host) ?? session.reach.unsignedHostServers(host, for: .serverSays, within: deadline)
        let round = hosts.round(at: host)
        let task = Task { await self.askServers(host, of: through, errand: errand, round: round) }
        serverAsks[host] = task
        await task.value
    }

    private func askServers(_ host: String, of through: MastodonHostMore, errand: Int, round: Int) async {
        defer { if pages[host]?.awaitsServers == errand { serverAsks[host] = nil } }
        do {
            let said = try await through.knownServers()
            guard pages[host]?.awaitsServers == errand else { return }
            pages[host]?.servers = .said(said)
        } catch {
            guard pages[host]?.awaitsServers == errand else { return }
            if (error as? MastodonHostMoreError) == .noSuchAddress {
                hosts.notFound(.knownServers, at: host, round: round)
                pages[host]?.servers = .waiting
            } else if (error as? URLError)?.code == .dataLengthExceedsMaximum {
                pages[host]?.servers = .tooLarge
            } else if !Cancellation.happened(error) {
                pages[host]?.servers = .failed
            }
        }
        pages[host]?.askingServers = false
    }

    /// One of the two asked, and its answer written where this round is still the one
    /// awaited. False where the round is over: superseded, or stopped — and a thing stopped
    /// before it answered is left waiting, to be asked when the page next opens.
    private func take<Value>(
        _ thing: MastodonHostThing, at host: String, errand: Int, round: Int, into slot: WritableKeyPath<Page, Told<Value>>,
        _ read: () async throws -> Value
    ) async -> Bool {
        guard hosts.has(thing, at: host) != .absent else { return true }
        do {
            let value = try await read()
            guard pages[host]?.awaits == errand else { return false }
            pages[host]?[keyPath: slot] = .said(value)
        } catch {
            guard pages[host]?.awaits == errand else { return false }
            if Cancellation.happened(error) { return false }
            if (error as? MastodonHostMoreError) == .noSuchAddress {
                // The host's own word that the address is not there: absent, for the run.
                hosts.notFound(thing, at: host, round: round)
                pages[host]?[keyPath: slot] = .waiting
            } else {
                pages[host]?[keyPath: slot] = .failed
            }
        }
        return true
    }
}
