import FediqoCore
import Foundation
import Observation

/// What is new in Home arrives as it happens, while a timeline that reads it is in front (#325).
///
/// **The person's choice, one source at a time, and off until it is made.** Kept in this
/// device's preferences, beside the wait (`prefs.askEvery`): a choice about how often a source is
/// asked, not something the store holds or a take-away carries.
///
/// **One line a source, held only while it is wanted** (`wanted`): the source is chosen, signed
/// in, a Mastodon, and the timeline in front reads its Home — and the window is not in the
/// background. Anything else lets the line go at once (`HearsLines` is a task of the timeline's
/// own: the timeline leaving takes it). The wait and `r` read as they always did beside it.
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
    /// Posts arrived on a line above where the reader is, since they were last at the top.
    private(set) var above = 0
    /// The newest row that arrived so, by its row id.
    @ObservationIgnored private(set) var newestAbove: String?
    /// Bumped by the press that goes up to them: the list in front goes to its top.
    private(set) var wentUp = 0

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let opener: any LineOpener
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults? = nil, opener: any LineOpener = URLSessionLines.signedIn(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.opener = opener
        self.sleep = sleep
        self.now = now
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

    /// The timeline in front changed: what arrived above the last is not said over this one.
    func forgetAbove() {
        above = 0
        newestAbove = nil
    }

    // MARK: - Holding lines

    /// Holds each of `hosts`' lines until cancelled — when what is wanted changes, the timeline
    /// leaves, or the window goes to the background — and lets every one go then.
    func hear(_ hosts: [String], in session: ShellSession) async {
        let held = hosts.map { host in Task { await self.keep(host, in: session) } }
        await withTaskCancellationHandler {
            for line in held { await line.value }
        } onCancel: {
            for line in held { line.cancel() }
        }
        for host in hosts {
            if case .refused? = standing[host] { continue }
            standing[host] = nil
        }
    }

    /// One source's line, opened, heard, and opened again after a drop, until cancelled or
    /// refused.
    private func keep(_ host: String, in session: ShellSession) async {
        var wait = Self.firstWait
        while !Task.isCancelled {
            let opened = now()
            let end = await once(host, in: session)
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
                if now().timeIntervalSince(opened) >= Double(Self.held.components.seconds) { wait = Self.firstWait }
                do { try await sleep(wait) } catch { return }
                wait = min(wait * 2, Self.longestWait)
            }
        }
    }

    private enum End {
        case dropped
        case refused(Int)
        /// Nothing left to hold it for: the sign-in or the source is gone.
        case over
    }

    /// One line: opened through the gate and on the record for as long as it is open, Home read
    /// up to now, then each event landed as it comes.
    private func once(_ host: String, in session: ShellSession) async -> End {
        guard let token = session.mastodon.token(host: host),
              let source = session.sources.first(where: { $0.host.lowercased() == host })
        else { return .over }
        standing[host] = .opening
        let work = session.mastodon.work
        // **The gate** (#220), as every request's: a line belongs to the source it is of.
        guard let admission = work.admission(reached: host, source: nil, for: .line), work.spend(admission, at: host) else {
            return .over
        }
        let record = work.begin(host: host, for: .line, name: .home, allowedBy: admission.allowedBy)
        defer { work.endLine(record) }
        let line = MastodonLine(token: token, opener: opener)
        let events: AsyncThrowingStream<LineEvent, any Error>
        do {
            events = try await Outward.$admitted.withValue(true) { try await line.open() }
        } catch let refused as MastodonLineRefused where (400..<500).contains(refused.status) {
            return .refused(refused.status)
        } catch {
            return .dropped
        }
        // Home up to now, before anything the line tells lands over it.
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
        standing[host] = .open(since: now())
        do {
            for try await event in events {
                guard MastodonLine.homeEvents.contains(event.name) else { continue }
                let landed = await MastodonLine.land(event, of: source, in: session.store)
                if case .arrived(let key, true) = landed {
                    above += 1
                    newestAbove = key.rowID
                }
                await session.reloadFromStore()
            }
        } catch {
            return .dropped
        }
        return .dropped
    }
}
