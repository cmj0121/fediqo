import FediqoCore
import Foundation
import Observation
import Synchronization

/// What is new in Home arrives as it happens, while a timeline that reads it is in front (#325).
///
/// **The person's choice, one source at a time, and off until it is made.** Kept in this
/// device's preferences, beside the wait (`prefs.askEvery`): a choice about how often a source is
/// asked, not something the store holds or a take-away carries.
///
/// **One line a source, held only while it is wanted** (`wanted`): the source is chosen, signed
/// in, a Mastodon, and the timeline in front reads its Home — and the window is not in the
/// background. Anything else lets the line go at once. The wait and `r` read as they always did
/// beside it.
///
/// **And while notices are told of** (#324, `ShellNoticesTold`): a source whose notices the person
/// asked to be told of holds the same line while Fediqo runs, whatever page is in front. One line
/// a source, whatever it is held for (`Want`): a change of what it is held for opens it again.
///
/// **And what else the line says** (#427): an announcement coming, changing or going, and a filter
/// changing, are each read again from the source as its own page reads them, on whatever line is
/// held. **No line is held that nobody chose**: a source the person chose holds it while its own page
/// is in front (`sourcePage`), and its direct line while its conversations are up (`directWanted`).
///
/// **What it brings lands as a read would** (`MastodonLine.land`), and only over a Home read
/// through to now: as the line opens, Home is read on first (`MastodonAccount.catchUp`), so what
/// was missed while no line was open is read or said to be missing, and only then is anything the
/// line told let land above it. Where that read could not come back whole, the line is let go and
/// asked again later — never a post landed over a place said not to be whole.
///
/// **A drop says nothing.** The line is asked again after a wait that doubles to `longestWait`,
/// and reading goes on as it does without it. **A refusal is said** on the source's page, where
/// the choice is, and the source is not asked again this run; nothing this device holds changes.
/// A sign-in the source has ended is heard by the reads, as it always is: a line's 401 is no
/// proof of it (`MastodonLine.open`).
@MainActor
@Observable
final class ShellLines {
    /// How a source's line stands, as its place on the source's page says it.
    enum Standing: Equatable {
        /// Being opened, or Home being read up to now.
        case opening
        /// Open since then.
        case open(since: Date)
        /// Dropped, and asked again after a wait. Said as nothing being wrong.
        case waiting
        /// Refused by the source with this answer: not asked again this run.
        case refused(Int)
    }

    /// The preferences key the chosen hosts are kept under.
    nonisolated static let key = "fediqo.lines"
    /// The first wait after a drop; each one after doubles it, to `longestWait`.
    nonisolated static let firstWait: Duration = .seconds(5)
    nonisolated static let longestWait: Duration = .seconds(300)
    /// A line open this long has held: the next drop waits the first wait again.
    nonisolated static let held: Duration = .seconds(60)

    /// The hosts whose Home arrives as it happens, folded.
    private(set) var chosen: Set<String>
    /// Each source's line as it stands now; nothing for one not held.
    private(set) var standing: [String: Standing] = [:]
    /// The hosts whose Home this line tells as it happens now: open, held for Home, and Home read up
    /// to now as it opened. **The wait does not ask these for Home** (#457) — the line already says
    /// it — and asks again the moment the line drops, as a line opened again reads Home up to now
    /// before anything lands. Not observed: nothing is drawn from it.
    ///
    /// Kept by which opening holds it, so a line let go as another to the same source opens takes
    /// only its own mark away.
    var homeHeard: Set<String> { Set(homeHeardBy.keys) }
    @ObservationIgnored private var homeHeardBy: [String: UUID] = [:]
    /// Posts arrived on a line above where the reader is, since they were last at the top.
    private(set) var above = 0
    /// The newest row that arrived so, by its row id.
    @ObservationIgnored private(set) var newestAbove: String?
    /// Bumped by the press that goes up to them: the list in front goes to its top.
    private(set) var wentUp = 0

    /// The timeline in front, and whether it is in front of the reader now: told by the timeline's
    /// pane (`ShowsLineFront`), nothing while that pane is not drawn.
    var front: Front?

    /// The joined source whose own page is drawn: what it announces is said there as it happens,
    /// where the person chose that source's line.
    var sourcePage: String?
    /// What the line saying something of announcements does: handed in with the one keeper of them,
    /// which is not the session's. Nothing in a session that has none.
    @ObservationIgnored var announced: (String) async -> Void = { _ in }
    /// The streams for what is in front refused for good this run (#460): not asked again.
    @ObservationIgnored var frontRefused: Set<FrontWant> = []
    /// The sources whose direct line was refused for good, by the sign-in refused: not asked again
    /// under that sign-in. Another is asked afresh.
    private var directRefused: [String: String] = [:]
    /// The answers that say a direct line will not be had by asking again. A sign-in doubted (401, which
    /// reads settle) and a source busy (429) are drops, and waited out.
    nonisolated static let directRefusals: Set<Int> = [400, 403, 404, 410]

    struct Front: Equatable {
        let timeline: TimelineQuery
        let inFront: Bool
    }

    /// One source's line and what it is held for: Home landing as it happens, notices told, or
    /// both.
    struct Want: Hashable {
        let host: String
        var home: Bool
        var notices: Bool
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let opener: any LineOpener
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    /// How long a burst is gathered from its first event before it lands (#458): `gathering` but
    /// for a test, which ends it by hand.
    @ObservationIgnored let gather: @Sendable () async throws -> Void
    /// The one line to each source that carries everything heard of it (#459); a line of its own for
    /// each stream where there is none.
    @ObservationIgnored let sockets: ShellSockets
    /// The moment a burst is gathered for: short enough that one post alone still shows at once.
    nonisolated static let gathering: Duration = .milliseconds(250)

    init(
        defaults: UserDefaults? = nil, opener: any LineOpener = URLSessionLines.signedIn(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        gather: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: ShellLines.gathering) },
        sockets: ShellSockets = ShellSockets()
    ) {
        self.defaults = defaults
        self.opener = opener
        self.sleep = sleep
        self.now = now
        self.gather = gather
        self.sockets = sockets
        chosen = Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    /// The choice for `host`, kept.
    func choose(_ on: Bool, host raw: String) {
        let host = raw.lowercased()
        if on { chosen.insert(host) } else { chosen.remove(host) }
        defaults?.set(chosen.sorted(), forKey: Self.key)
        if !on { standing[host] = nil }
    }

    // MARK: - Which lines are wanted

    /// The hosts whose line is wanted now, sorted: chosen, signed in, a Mastodon, not refused this
    /// run, and read for Home by `timeline` — its usual reads, or a rule naming Home. Nothing for
    /// Trends, and nothing where the timeline is not `inFront`.
    func wanted(timeline: TimelineQuery, inFront: Bool, in session: ShellSession) -> [String] {
        guard inFront, timeline != .trends, !chosen.isEmpty else { return [] }
        let asks = CompiledTimeline(timeline.definition(among: session.written), sources: session.sources).sourcesToAsk()
        let mastodons = Set(session.sources.filter { $0.kind == .mastodon }.map { $0.host.lowercased() })
        return asks.compactMap { ask -> String? in
            let host = ask.host.lowercased()
            guard chosen.contains(host), mastodons.contains(host), session.mastodon.isSignedIn(host: host) else { return nil }
            if case .refused? = standing[host] { return nil }
            guard ask.categories == nil || ask.categories?.contains(.home) == true else { return nil }
            return host
        }.sorted()
    }

    /// Every line wanted now, by host: Home's (`wanted`) for the timeline in front, and the
    /// sources whose notices are told (`ShellNoticesTold.hosts`) — only while Fediqo is `running`,
    /// and neither from a source refused this run.
    func wants(running: Bool, in session: ShellSession) -> [Want] {
        guard running else { return [] }
        let home = front.map { wanted(timeline: $0.timeline, inFront: $0.inFront, in: session) } ?? []
        let notices = session.noticesTold.hosts(in: session).filter { host in
            if case .refused? = standing[host] { return false }
            return true
        }
        return Set(home).union(notices).union(page(in: session)).sorted().map {
            Want(host: $0, home: home.contains($0), notices: notices.contains($0))
        }
    }

    /// The source whose own page is in front, as a line wanted: where its line was chosen, it is
    /// signed in, a Mastodon, and not refused this run.
    private func page(in session: ShellSession) -> [String] {
        guard let host = sourcePage?.lowercased(), mayHold(host, in: session) else { return [] }
        return [host]
    }

    /// Whether the person chose `host`'s line, one way or the other, and it can be held.
    private func mayHold(_ host: String, in session: ShellSession) -> Bool {
        guard chosen.contains(host) || session.noticesTold.hosts(in: session).contains(host),
              session.sources.contains(where: { $0.host.lowercased() == host && $0.kind == .mastodon }),
              session.mastodon.isSignedIn(host: host)
        else { return false }
        if case .refused? = standing[host] { return false }
        return true
    }

    /// The host whose direct line is wanted now: its conversations are up, they can be read, and
    /// the person chose its line. Nothing else holds one: a list not up is read as it opens.
    func directWanted(running: Bool, in session: ShellSession) -> String? {
        guard running, let host = session.directs.shown?.lowercased(), session.directsReads(host: host),
              mayHold(host, in: session)
        else { return nil }
        if let refused = directRefused[host], refused == session.mastodon.token(host: host)?.accessToken { return nil }
        return host
    }

    // MARK: - The source's page

    /// What the source's page offers for `host`: the switch, or why there is none.
    enum Offer: Equatable {
        /// The switch, with how its line stands where it is held.
        case choice(on: Bool, standing: Standing?)
        /// Not signed in: the sentence, and the press asks to sign in.
        case signIn(String)
        /// A source that tells nothing as it happens: the sentence.
        case cannot(String)
    }

    func offer(host raw: String, in session: ShellSession) -> Offer? {
        let host = raw.lowercased()
        guard let source = session.sources.first(where: { $0.host.lowercased() == host }) else { return nil }
        guard source.kind == .mastodon else {
            return .cannot(String(format: L10n.t("source.line.cannot"), source.host))
        }
        guard session.mastodon.isSignedIn(host: host) else {
            return .signIn(String(format: L10n.t("source.line.signIn"), source.host))
        }
        return .choice(on: chosen.contains(host), standing: standing[host])
    }

    /// The press on the dim line of a source not signed in: the read-or-act question, which says
    /// what will be asked before the source's page opens. Nothing is chosen before that.
    func pressSignIn(host: String, in session: ShellSession) {
        session.askSignIn(host: host)
    }

    // MARK: - What arrived above

    /// The reader is at `top` of the list: where that is the newest that arrived, nothing is
    /// above them any more.
    func seen(top: String?) {
        guard above > 0, let top, top == newestAbove else { return }
        above = 0
        newestAbove = nil
    }

    /// The press that goes up to what arrived: the list goes to its top.
    func goUp() {
        above = 0
        newestAbove = nil
        wentUp += 1
    }

    /// The sources a line is held to now: the reader's own open, or the one socket held (#461).
    var heldHosts: Set<String> {
        var hosts = sockets.heldHosts
        for (host, standing) in standing {
            if case .open = standing { hosts.insert(host) }
        }
        return hosts
    }

    /// A post new here arrived on a line, above where the reader is.
    func arrivedAbove(_ key: NoteKey) {
        above += 1
        newestAbove = key.rowID
    }

    /// The timeline in front changed: what arrived above the last is not said over this one.
    func forgetAbove() {
        above = 0
        newestAbove = nil
    }

    // MARK: - Holding lines

    /// Holds each of `hosts`' lines until cancelled — when what is wanted changes, the timeline
    /// leaves, or the window goes to the background — and lets every one go then.
    func hear(_ hosts: [String], in session: ShellSession) async {
        await hear(hosts.map { Want(host: $0, home: true, notices: false) }, in: session)
    }

    /// `hear(_:in:)` of lines held for what each is wanted for.
    func hear(_ wants: [Want], in session: ShellSession) async {
        await holdEach(wants) { await self.keep($0, in: session) }
        for want in wants {
            if case .refused? = standing[want.host] { continue }
            standing[want.host] = nil
        }
    }

    /// `keep` of each of `items` at once, until cancelled, when every one is let go.
    func holdEach<Item: Sendable>(_ items: [Item], _ keep: @escaping @MainActor (Item) async -> Void) async {
        let held = items.map { item in Task { await keep(item) } }
        await withTaskCancellationHandler {
            for line in held { await line.value }
        } onCancel: {
            for line in held { line.cancel() }
        }
    }

    /// The wait after a line dropped, then `wait` doubled for the next, up to the longest. **A line
    /// held a while before it dropped starts over from the first wait.** False where cancelled.
    func waitAfterDrop(_ wait: inout Duration, opened: Date) async -> Bool {
        if now().timeIntervalSince(opened) >= Double(Self.held.components.seconds) { wait = Self.firstWait }
        do { try await sleep(wait) } catch { return false }
        wait = min(wait * 2, Self.longestWait)
        return true
    }

    /// One source's line, opened, heard, and opened again after a drop, until cancelled or
    /// refused.
    private func keep(_ want: Want, in session: ShellSession) async {
        let host = want.host
        var wait = Self.firstWait
        while !Task.isCancelled {
            let opened = now()
            let end = await once(want, in: session)
            guard !Task.isCancelled else { return }
            switch end {
            case .refused(let status):
                standing[host] = .refused(status)
                return
            case .over:
                standing[host] = nil
                return
            case .dropped:
                standing[host] = .waiting
                guard await waitAfterDrop(&wait, opened: opened) else { return }
            }
        }
    }

    /// `host`'s direct line, held until cancelled or refused, and its list read for what was missed
    /// each time it opens, the first of a holding too. **It has no standing of its own**: reading goes on beside it, and
    /// the place on the source's page speaks of the reader's own line.
    func hearDirect(_ host: String, in session: ShellSession) async {
        var wait = Self.firstWait
        while !Task.isCancelled {
            guard let token = session.mastodon.token(host: host) else { return }
            let opened = now()
            do {
                guard let (events, end) = try await heard(.direct, host: host, token: token, name: nil, in: session) else { return }
                defer { end() }
                await session.directs.heard(host, in: session)
                for try await event in events where event.name == MastodonLine.conversationEvent {
                    await session.directs.heard(host, in: session)
                }
            } catch let refused as MastodonLineRefused where Self.directRefusals.contains(refused.status) {
                directRefused[host] = token.accessToken
                return
            } catch {}
            guard !Task.isCancelled, await waitAfterDrop(&wait, opened: opened) else { return }
        }
    }

    /// `stream` of `host` as it happens: on the source's one socket where it carries it (#459), on a
    /// line of its own where not — through **the gate** (#220) as every request is, and on the record
    /// for as long as it is heard: a socket's act is the socket's, and a line's ends with `end`.
    /// Nothing where the gate does not let it out.
    func heard(
        _ stream: MastodonStream, host: String, token: MastodonToken, name: SourceWork.Name?, in session: ShellSession
    ) async throws -> (events: AsyncThrowingStream<LineEvent, any Error>, end: () -> Void)? {
        let work = session.mastodon.work
        do {
            if let events = try await sockets.hear(stream, host: host, token: token, work: work) { return (events, {}) }
        } catch is ShellSockets.Shut {
            return nil
        }
        let opener = opener
        let line = try await work.openLine(host: host, name: name) {
            try await MastodonLine(token: token, opener: opener).open(stream)
        }
        return line.map { ($0.opened, $0.end) }
    }

    private enum End {
        case dropped
        case refused(Int)
        /// Nothing left to hold it for: the sign-in or the source is gone.
        case over
    }

    /// One line: opened through the gate and on the record for as long as it is open, Home read
    /// up to now where it is held for Home, then each event landed or told as it comes.
    private func once(_ want: Want, in session: ShellSession) async -> End {
        let host = want.host
        guard let token = session.mastodon.token(host: host),
              let source = session.sources.first(where: { $0.host.lowercased() == host })
        else { return .over }
        standing[host] = .opening
        // However this line ends, its Home is the wait's to ask again from then on.
        let opening = UUID()
        defer { if homeHeardBy[host] == opening { homeHeardBy[host] = nil } }
        let events: AsyncThrowingStream<LineEvent, any Error>
        let end: () -> Void
        do {
            guard let heard = try await heard(.user, host: host, token: token, name: want.home ? .home : nil, in: session) else {
                return .over
            }
            (events, end) = heard
        } catch let refused as MastodonLineRefused where (400..<500).contains(refused.status) {
            return .refused(refused.status)
        } catch {
            return .dropped
        }
        defer { end() }
        // Home up to now, before anything the line tells lands over it.
        if want.home {
            let door = session.mastodon.authorized(token: token, for: .timeline, name: .home)
            do {
                guard try await MastodonAccount(door: door, store: session.store).catchUp() else { return .dropped }
            } catch MastodonAuthError.signedOut {
                session.mastodon.endedByServer(host: host)
                return .over
            } catch {
                return .dropped
            }
            guard !Task.isCancelled else { return .dropped }
            await session.reloadFromStore()
        }
        // What was told while no line was open, read now the line is hearing what comes after (#426).
        if want.notices {
            guard !Task.isCancelled else { return .dropped }
            await session.noticesTold.caughtUp(host: host, in: session)
        }
        standing[host] = .open(since: now())
        if want.home { homeHeardBy[host] = opening }
        do {
            for try await burst in Self.bursts(of: events, gathered: gather) {
                // Home's events of the burst, landed together once the rest is said (#458). What
                // the source is asked again for — notices merged, announcements, filters — is asked
                // once a burst, however often the burst says it.
                var home: [LineEvent] = []
                var merged = false, announcements = false, filters = false
                for event in burst {
                    if want.notices, let notice = MastodonNotices.told(event, source: source) {
                        await session.noticesTold.told(notice, in: session)
                    } else if want.notices, MastodonNotices.saysMerged(event) {
                        merged = true
                    } else if MastodonLine.announcementEvents.contains(event.name) {
                        announcements = true
                    } else if event.name == MastodonLine.filtersEvent {
                        filters = true
                    } else if want.home, MastodonLine.homeEvents.contains(event.name) {
                        home.append(event)
                    }
                }
                if merged { await session.noticesTold.caughtUp(host: host, in: session) }
                if announcements { await announced(host) }
                if filters { await session.serverFilters.heard(host: host, in: session) }
                guard !home.isEmpty else { continue }
                for case .arrived(let key, true) in await MastodonLine.land(home, of: source, in: session.store) {
                    arrivedAbove(key)
                }
                await session.reloadFromStore()
            }
        } catch {
            return .dropped
        }
        return .dropped
    }

    /// `events` handed on in bursts (#458): from the first event after a quiet, everything told
    /// until `gathered` returns goes on as one, in the order told. A line that ends or drops hands
    /// on what it was gathering first, then ends or drops as it did. Let go, it lets the line go.
    nonisolated static func bursts(
        of events: AsyncThrowingStream<LineEvent, any Error>,
        gathered: @escaping @Sendable () async throws -> Void
    ) -> AsyncThrowingStream<[LineEvent], any Error> {
        let (bursts, out) = AsyncThrowingStream<[LineEvent], any Error>.makeStream()
        // What is gathered so far, and whether a gathering is under way for it.
        let held = Mutex<(events: [LineEvent], gathering: Bool)>(([], false))
        let handOn: @Sendable () -> Void = {
            let burst = held.withLock { state in
                defer { state = ([], false) }
                return state.events
            }
            if !burst.isEmpty { out.yield(burst) }
        }
        let hearing = Task {
            do {
                for try await event in events {
                    let first = held.withLock { state in
                        state.events.append(event)
                        defer { state.gathering = true }
                        return !state.gathering
                    }
                    guard first else { continue }
                    Task {
                        try? await gathered()
                        handOn()
                    }
                }
                handOn()
                out.finish()
            } catch {
                handOn()
                out.finish(throwing: error)
            }
        }
        out.onTermination = { _ in hearing.cancel() }
        return bursts
    }
}
