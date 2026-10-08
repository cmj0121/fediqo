import FediqoCore
import Foundation
import Observation

/// What is done to a source's notices from the notices page (#323), and what each source says
/// it holds back: dismissing one line, dismissing all a source has, and letting a held-back
/// request through or go.
///
/// **Nothing here changes what is held before the source has answered.** A line leaves what
/// is drawn, and a request its own, at the person's yes; a refusal or a failure draws both
/// again and is said on every page (`ShellSaid`). `said` keeps the ask and the reading of
/// requests. What is on its way is this object's (`acting`) and is never written down: the
/// list and the requests underneath move only on the source's word.
///
/// **An answer is taken only where the token it was asked with is still the one held** — the
/// list's own rule (`ShellNoticeList.land`): an answer for a sign-in the reader has since
/// replaced, or signed out of, changes nothing and says nothing; what it had hidden is drawn
/// again, where it is still held. And an act goes to the door
/// of the notice's own source and no other; a line of a source that is not held here, or
/// whose sign-in may not act, is sent nowhere.
///
/// **Nothing is asked by itself.** What a source holds back is looked at when the page reads
/// (`readPage`), its requests when the person opens them, and a request let through is said to
/// be on its way until a later read brings its notices — nothing here waits or asks again.
@MainActor
@Observable
final class ShellNoticeActs {
    enum Act: Equatable, Sendable {
        /// The ask for notices itself, on the source's own page.
        case ask
        case dismiss, dismissAll
        /// Reading the requests a source holds.
        case requests
        case letThrough, letGo
    }

    /// What is said of an act at one source that changed nothing.
    struct Said: Equatable, Sendable {
        let act: Act
        let why: WriteWhy
    }

    /// The last ask for notices, or reading of requests, at each source that changed
    /// nothing, by folded host: what the page says of itself, above its list. Taken down by
    /// the next act there, and by the page reading again. **Never one of the four acts that
    /// change a source** — those are said on every page (`ShellSession.said`), since the line
    /// or the request they were about left the page at the yes.
    private(set) var said: [String: Said] = [:]
    /// What each source last said it holds back. One that answered `absent` is not asked again.
    private(set) var holdings: [String: NoticeHolding] = [:]
    /// The requests each source handed over when its held-back line was last opened.
    private(set) var requests: [String: [NoticeRequest]] = [:]
    /// The sources whose held-back line is open.
    private(set) var opened: Set<String> = []
    /// The sources whose requests are on the wire.
    private(set) var readingRequests: Set<String> = []
    /// One act the person said yes to, on its way to its source: which source, which act, and
    /// which press — a number no other press shares, so an answer that comes back to a name
    /// let go of meanwhile, or begun again since, is known not to be that entry's.
    private struct Out: Equatable {
        let host: String
        let act: Act
        let flight: Int
    }

    /// What is on its way, by name: a line's id, a request's, or a source's own for
    /// dismissing all. **Each is left out of what is drawn from the yes** (`hidden`,
    /// `listed`) and held underneath as it was.
    private var out: [String: Out] = [:]
    @ObservationIgnored private var flights = 0
    /// One thing an act did not take: its name, and what a line names it by.
    private struct Miss {
        let name: String
        let about: FediqoUI.Said.About?
    }

    /// What each line on the strip stands for, by the line's own name (`Said.id`, one an act
    /// a source): every name that act failed for there and that is still held, oldest first.
    /// **The line stands until this is empty.** A name leaves when the same thing later
    /// lands, when a read shows it gone, and with its source; the line then says how many are
    /// left, names the one where one is, and goes with the last.
    @ObservationIgnored private var missed: [String: [Miss]] = [:]
    /// The lines whose dismissal went out and was not confirmed in time, each with its host:
    /// asked again, a source that says it knows no such line is saying the first ask landed
    /// (`MastodonNotices.dismiss(_:afterUnconfirmed:)`).
    @ObservationIgnored private var unconfirmed: [String: String] = [:]
    /// When each source last said yes to letting a request through or go, in the run's order
    /// of reads (`ReadMoment`): a reading of what it holds back sent before that was asked
    /// for before the request left, and is not taken (`outrun`) — the list's own guard
    /// (`ShellNoticeList.took`), for requests.
    @ObservationIgnored private var moved: [String: UInt64] = [:]
    private var onWay: [String: [NoticeRequest]] = [:]
    /// The destructive item of a menu on the notices page that was chosen and not yet answered.
    /// Held here and not by a row, for `ShellSession.rowAsk`'s reason: a row scrolled away must
    /// not drop a question still open, and the key that asks puts the same one.
    var asked: ShellMoreAsk?
    @ObservationIgnored private var looking: Set<String> = []

    /// What dismissing all at one source is on the wire under.
    static func all(_ host: String) -> String { "all\u{1e}" + host.lowercased() }

    /// The names of what is on the wire now.
    var acting: Set<String> { Set(out.keys) }

    /// The notices left out of what is drawn while their act is out: single lines by id, and
    /// every line of a source that was asked to dismiss all.
    struct Hidden: Equatable, Sendable {
        var lines: Set<String> = []
        var hosts: Set<String> = []

        var isEmpty: Bool { lines.isEmpty && hosts.isEmpty }

        func hides(_ notice: Notice) -> Bool {
            lines.contains(notice.id) || hosts.contains(notice.source.host.lowercased())
        }
    }

    /// What the list leaves out of what it draws just now (`ShellNoticeList.rebuild`).
    var hidden: Hidden {
        var hidden = Hidden()
        for (name, out) in out {
            switch out.act {
            case .dismiss: hidden.lines.insert(name)
            case .dismissAll: hidden.hosts.insert(out.host)
            case .ask, .requests, .letThrough, .letGo: break
            }
        }
        return hidden
    }

    // MARK: - What the page reads

    /// What one source says it holds back just now, or nothing: it has no such thing, was not
    /// asked, or holds none.
    func held(host: String) -> NoticesHeld? {
        holdings[host.lowercased()]?.held
    }

    /// The requests of one source the page lists: those it handed over, less each the person
    /// has let through or let go that its source has not answered for yet.
    func listed(host raw: String) -> [NoticeRequest] {
        let host = raw.lowercased()
        return (requests[host] ?? []).filter { out[$0.id] == nil }
    }

    /// What the page says one source holds back: what the source said (`held`), less what
    /// is on its way out of it — so the count beside the requests listed is the count of
    /// those, and a source whose last request is leaving is not said to hold any.
    func shownHeld(host raw: String) -> NoticesHeld? {
        let host = raw.lowercased()
        guard let held = held(host: host) else { return nil }
        let leaving = (requests[host] ?? []).filter { out[$0.id] != nil }
        guard !leaving.isEmpty else { return held }
        return NoticeHolding.holds(NoticesHeld(
            requests: max(0, held.requests - leaving.count),
            notices: max(0, held.notices - leaving.reduce(0) { $0 + $1.count })
        )).held
    }

    /// The sources the page says are holding something back (`shownHeld`), in host order.
    var shownHolders: [String] {
        holdings.keys.filter { shownHeld(host: $0) != nil }.sorted()
    }

    /// The requests let through and said to be on their way, in host order. **Never asked
    /// after**: each stands until that source's newest stretch is next read and lands
    /// (`read(host:)`) — the read that shows what the source has moved, whatever it brings.
    var onItsWay: [NoticeRequest] {
        onWay.keys.sorted().flatMap { onWay[$0] ?? [] }
    }

    /// One source's newest stretch was read and landed: what was on its way from there is
    /// what that read shows, and is no longer said to be coming.
    func read(host: String) {
        onWay[host.lowercased()] = nil
    }

    // MARK: - Reading

    /// The page read, as its opening, its reload mark and a pull read it: every source's
    /// newest stretch, and then what each holds back. What was said of an earlier act goes.
    func readPage(in session: ShellSession) async {
        said = [:]
        await session.noticeList.read(in: session)
        guard !Task.isCancelled else { return }
        await look(in: session)
    }

    /// Asks every source whose sign-in may read notices what it holds back, beside one
    /// another. **Never a source that said it has no such thing** (`NoticeHolding.absent`):
    /// that answer is kept for the run and nothing is sent. A refusal or a failure leaves what
    /// was known and says nothing — nobody pressed for this, and the list's own read has said
    /// what there is to say of a source that does not answer.
    func look(in session: ShellSession) async {
        let hosts = ShellNoticeList.asked(in: session).map { $0.host.lowercased() }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { await self.look(host: host, in: session) }
            }
        }
    }

    private func look(host: String, in session: ShellSession) async {
        let known = holdings[host] ?? .unasked
        guard known != .absent, looking.insert(host).inserted else { return }
        defer { looking.remove(host) }
        let sent = ReadMoment.now().place
        guard case .yes(let holding) = await ask(host, for: .notices, in: session, { try await $0.held(known: known) }),
              !outrun(sent, at: host)
        else { return }
        holdings[host] = holding
        if holding.held == nil {
            requests[host] = nil
            opened.remove(host)
            settle(host: host, in: session)
        } else if opened.contains(host) {
            await readRequests(host: host, in: session)
        }
    }

    /// Opens one source's held-back line, and reads the requests it holds.
    func open(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard held(host: host) != nil else { return }
        opened.insert(host)
        await readRequests(host: host, in: session)
    }

    func close(host: String) {
        opened.remove(host.lowercased())
    }

    private func readRequests(host: String, in session: ShellSession) async {
        guard held(host: host) != nil,
              let source = ShellNoticeList.asked(in: session).first(where: { $0.host.lowercased() == host }),
              readingRequests.insert(host).inserted
        else { return }
        defer { readingRequests.remove(host) }
        if said[host]?.act == .requests { said[host] = nil }
        let sent = ReadMoment.now().place
        switch await ask(host, for: .notices, in: session, { try await $0.requests(source: source) }) {
        // Read again here: a look that landed meanwhile may have said it holds nothing now.
        case .yes(let listed):
            if held(host: host) != nil, !outrun(sent, at: host) {
                requests[host] = listed
                settle(host: host, in: session)
            }
        case .no(let why): said[host] = Said(act: .requests, why: why)
        case .nothing: break
        }
    }

    /// Whether a reading of what one source holds back, sent at `sent`, set out before that
    /// source last said yes to an act on a request: it may still name a request that has
    /// left, and count it, so it changes nothing. The next reading says what is held now.
    private func outrun(_ sent: UInt64?, at host: String) -> Bool {
        guard let moved = moved[host], let sent else { return false }
        return sent < moved
    }

    // MARK: - Acting

    /// Dismisses one line at its source — a gathered line as the line it is, every notice it
    /// stands for at once. Called at the person's yes: the line leaves what is drawn at once,
    /// what is held once the source has answered, and is drawn again where it was, with the
    /// reason said, where the source refused or did not answer.
    ///
    /// Nothing for a line that is not held, or whose source's sign-in may not dismiss.
    func dismiss(_ notice: Notice, in session: ShellSession) async {
        let host = notice.source.host.lowercased()
        let list = session.noticeList
        // The line as it is held now: one that has folded since it was drawn is the same line.
        guard let line = list.reaches[host]?.notices.first(where: { $0.id == notice.id }) else { return }
        // As the request sets out: whether this source was asked for this once already and
        // nobody heard its answer. What it says to this ask is read by that.
        let again = unconfirmed[line.id] != nil
        await perform(
            .dismiss, at: host, as: line.id, about: .notice(line), in: session,
            { try await $0.dismiss(line, afterUnconfirmed: again) },
            held: { list.reaches[host]?.notices.contains { $0.id == line.id } == true }
        ) {
            list.took(line)
        }
    }

    /// Dismisses every notice one source has for the person, shown here or not: one request.
    /// Its lines leave what is drawn at the person's yes and what is held once the source has
    /// answered; a refusal or a failure draws them again as they were, each in its place.
    func dismissAll(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        let list = session.noticeList
        // Every line went with its yes, so one said not to have gone has gone since (`settle`).
        await perform(
            .dismissAll, at: host, as: Self.all(host), about: nil, in: session, { try await $0.dismissAll() },
            held: { list.reaches[host] != nil }
        ) {
            list.tookAll(host: host)
        }
    }

    /// Lets one held-back request through. It leaves the requests listed at the person's
    /// yes. The source's yes means the request is gone and its notices are on their way, not
    /// that they have arrived: it is said so from then until a later read shows them.
    func letThrough(_ request: NoticeRequest, in session: ShellSession) async {
        let host = request.source.host.lowercased()
        await answer(request, .letThrough, in: session, { try await $0.letThrough(request) }) {
            self.onWay[host, default: []].append(request)
        }
    }

    /// Lets one held-back request go: that person's held notices are dismissed at the source.
    func letGo(_ request: NoticeRequest, in session: ShellSession) async {
        await answer(request, .letGo, in: session, { try await $0.letGo(request) }) {}
    }

    private func answer(
        _ request: NoticeRequest, _ act: Act, in session: ShellSession,
        _ work: @escaping @Sendable (MastodonNotices) async throws -> Void, then: () -> Void
    ) async {
        let host = request.source.host.lowercased()
        guard requests[host]?.contains(request) == true else { return }
        await perform(
            act, at: host, as: request.id, about: .person(request.person), in: session, work,
            held: { self.requests[host]?.contains { $0.id == request.id } == true }
        ) {
            // The request as it is listed now, where a reading meanwhile brought it again:
            // that one's count is the source's later word on how many it stood for.
            let count = self.requests[host]?.first { $0.id == request.id }?.count ?? request.count
            self.requests[host]?.removeAll { $0.id == request.id }
            self.moved[host] = ReadMoment.now().place
            // What the source said it holds, less this: its own count comes with the next look.
            if let held = self.holdings[host]?.held {
                self.holdings[host] = .holds(NoticesHeld(
                    requests: max(0, held.requests - 1), notices: max(0, held.notices - count)
                ))
            }
            if self.held(host: host) == nil { self.opened.remove(host) }
            then()
        }
    }

    /// One act at one source, on its way under `name`: sent only where the sign-in may act
    /// and the same act is not out already.
    ///
    /// **Shown first.** This is called at the person's yes — every one of the four is asked
    /// first — and what `name` stands for leaves what is drawn before anything is sent. The
    /// states of one name (`out`), and every way between them:
    ///
    /// | From | What happens | To |
    /// | ---- | ------------ | -- |
    /// | settled (no entry) | the yes, where the sign-in may act: an entry with a flight of its own; the line, the source's lines or the request left out of what is drawn; the request goes | out |
    /// | out | the same name asked again | out, nothing sent |
    /// | out | a read of the source lands | out: what is held underneath is what that read says, and nothing hidden is drawn |
    /// | out | the source's yes, for the sign-in it was sent with | settled: `done` takes it out of what is held — struck by that moment against every read sent before it (`ShellNoticeList.took`) — and only then does the entry go; this name leaves what the strip's line stands for (`missed`), and the line goes with the last of them |
    /// | out | a refusal, a failure, or no answer in time | settled: the entry goes, so it is drawn again where it was, as the source last said it; said on the strip with the cause, naming it or saying how many — but only where it is still held, since a read or a dismissing of all may have taken it meanwhile |
    /// | out | the sign-in ends, is signed out of, or its source is cleared or removed (`forget`) | settled, nothing said; the answer comes back to no entry of its own and does nothing |
    /// | out | the sign-in is replaced with nobody told, or the asker walks away | settled, nothing said, nothing held changed: drawn again where it is still held |
    ///
    /// **Not confirmed in time is a failure like the others**: the line is drawn again and the
    /// strip says it may have gone all the same. What settles it is the source's next word on
    /// that line: a read from the top that replaces what is held, or whose stretch reaches down
    /// to the line (`ShellNoticeList.land` — a line below a joined stretch stands as it was);
    /// or the dismissal asked again, where "no such line" now means the first ask landed.
    ///
    /// **Between the answer and the entry going there is no wait**, and what is held moves
    /// before the entry does, so nothing is drawn for a moment as it was before the yes.
    /// Everything read after the one wait is read again there: whose entry `name` is, which
    /// sign-in is held, and whether what was asked about is still held.
    private func perform(
        _ act: Act, at host: String, as name: String, about: FediqoUI.Said.About?, in session: ShellSession,
        _ work: @escaping @Sendable (MastodonNotices) async throws -> Void,
        held: () -> Bool, done: () -> Void
    ) async {
        guard session.mastodon.dismisses(host: host), out[name] == nil else { return }
        flights += 1
        let flight = flights
        let sent = session.mastodon.token(host: host)?.accessToken
        let list = session.noticeList
        out[name] = Out(host: host, act: act, flight: flight)
        said[host] = nil
        list.redraw(atYes: true)
        let answer = await ask(host, for: .write, in: session, work)
        // Let go of with its sign-in, and perhaps begun again since: not this press's entry.
        guard out[name]?.flight == flight else { return }
        switch answer {
        case .yes where session.mastodon.token(host: host)?.accessToken == sent:
            done()
            out[name] = nil
            list.redraw()
            settle(host: host, in: session)
            // A dismissal is the person asking for a line to be gone: its words are off this
            // device's disk before the act is over (#292). Last, so nothing above waits for it.
            if act == .dismiss || act == .dismissAll { await list.gone(in: session) }
        case .no(let why) where session.mastodon.token(host: host)?.accessToken == sent:
            out[name] = nil
            list.redraw()
            guard held() else { break }
            if act == .dismiss, why == .unconfirmed { unconfirmed[name] = host }
            miss(Miss(name: name, about: about), act, why, at: host, in: session)
        case .yes, .no, .nothing:
            out[name] = nil
            list.redraw()
        }
    }

    // MARK: - What the strip's lines stand for

    /// The acts whose failures are counted by name. Dismissing all is one thing a source.
    private static let counted: [Act] = [.dismiss, .dismissAll, .letThrough, .letGo]

    /// The line that says `act` did not take `misses` at `host`: the one named, where it
    /// is one, and how many where there are more.
    private func line(_ act: Act, _ why: WriteWhy, at host: String, for misses: [Miss]) -> FediqoUI.Said {
        FediqoUI.Said(
            .notice(act), why, host: host, about: misses.count == 1 ? misses[0].about : nil, many: max(1, misses.count)
        )
    }

    /// One more thing `act` did not take at `host`: said, aloud, on the line that stands for
    /// all of them. A line the person took down has been answered, and counts afresh.
    private func miss(_ miss: Miss, _ act: Act, _ why: WriteWhy, at host: String, in session: ShellSession) {
        let name = FediqoUI.Said.id(.notice(act), host: host)
        var misses = session.said.lines.contains { $0.id == name } ? missed[name] ?? [] : []
        misses.removeAll { $0.name == miss.name }
        misses.append(miss)
        missed[name] = misses
        session.said.say(line(act, why, at: host, for: misses))
    }

    /// What the strip's lines about one source stand for brought into line with what is
    /// held now: a name that is no longer held — its own act landed, a read showed it gone, its
    /// source dismissed everything — is no longer missed, and a line left standing for
    /// nothing is taken down. Called wherever what is held of a source has just moved.
    ///
    /// **Never by a name still held.** A read that still names the line leaves it missed:
    /// nothing has said it went.
    func settle(host raw: String, in session: ShellSession) {
        let host = raw.lowercased()
        let lines = Set(session.noticeList.reaches[host]?.notices.map(\.id) ?? [])
        let listed = Set((requests[host] ?? []).map(\.id))
        for (name, at) in unconfirmed where at == host && !lines.contains(name) { unconfirmed[name] = nil }
        for act in Self.counted {
            let name = FediqoUI.Said.id(.notice(act), host: host)
            guard let misses = missed[name] else { continue }
            let left = misses.filter { miss in
                switch act {
                case .dismiss: lines.contains(miss.name)
                case .letThrough, .letGo: listed.contains(miss.name)
                case .dismissAll: session.noticeList.reaches[host]?.notices.isEmpty == false
                case .ask, .requests: true
                }
            }
            guard left.count != misses.count else { continue }
            missed[name] = left.isEmpty ? nil : left
            // Taken down by the person already: there is no line to change.
            guard let standing = session.said.lines.first(where: { $0.id == name }) else { continue }
            if left.isEmpty {
                session.said.takeDown(name)
            } else {
                session.said.amend(line(act, standing.why, at: host, for: left))
            }
        }
    }

    /// Says, or takes down, what the ask for notices at one source came to. The ask is the
    /// session's (`allowNotices`), and says its failure here: on the page, where the press
    /// for it is.
    func say(_ word: Said?, host: String) {
        said[host.lowercased()] = word
    }

    /// Lets go of everything about one source: with its sign-in, as the list lets go of its
    /// lines. **What was on its way to it is let go of too**, so nothing stays hidden under a
    /// name a later sign-in may read again, and the answer still to come finds no entry.
    func forget(host raw: String) {
        let host = raw.lowercased()
        out = out.filter { $0.value.host != host }
        moved[host] = nil
        missed = missed.filter { !$0.key.hasPrefix(host + "\u{1e}") }
        unconfirmed = unconfirmed.filter { $0.value != host }
        said[host] = nil
        holdings[host] = nil
        requests[host] = nil
        onWay[host] = nil
        opened.remove(host)
    }

    // MARK: - One request, and whether its answer still counts

    private enum Answer<Value: Sendable> {
        case yes(Value)
        case no(WriteWhy)
        /// Nothing is to change or be said: the sign-in it was asked with is no longer the one
        /// held, or the asker walked away.
        case nothing
    }

    /// One request of one source through a door built here, on the main actor, from the token
    /// held; the request, the wait and the decoding off it.
    private func ask<Value: Sendable>(
        _ host: String, for purpose: SourceWork.Purpose, in session: ShellSession,
        _ work: @escaping @Sendable (MastodonNotices) async throws -> Value
    ) async -> Answer<Value> {
        guard let sent = session.mastodon.token(host: host) else { return .no(.locked) }
        let door = session.mastodon.authorized(token: sent, within: session.noticeList.deadline, for: purpose)
        let result = await Self.run(session.reach.notices(door), work)
        guard Self.counts(result, of: host, sentWith: sent, in: session) == .held else { return .nothing }
        switch result {
        case .success(let value): return .yes(value)
        case .failure(let error) where Cancellation.happened(error): return .nothing
        case .failure(let error): return .no(WriteWhy(error, wrote: purpose == .write))
        }
    }

    /// Whether an answer still counts, by the token it was asked with.
    enum Counts: Equatable {
        /// The token is still the one held: the answer is taken.
        case held
        /// Another sign-in is held now, or none: the answer changes nothing and says nothing.
        case replaced
        /// The server ended the sign-in, which the door took the token for: it has gone the
        /// way every ended sign-in goes, and the list has let go of the source.
        case ended
    }

    /// **The one check that an answer is for the sign-in still held** (`refusedBookmark`'s
    /// rule), for the list's read and for every act. The one answer that leaves no token to
    /// compare is the server ending the sign-in, and that is done here.
    static func counts<Value>(
        _ result: Result<Value, any Error>, of host: String, sentWith sent: MastodonToken, in session: ShellSession
    ) -> Counts {
        let held = session.mastodon.token(host: host)?.accessToken
        if case .failure(MastodonAuthError.signedOut) = result, held == nil {
            session.mastodon.endedByServer(host: host)
            session.noticeList.forget(host: host)
            return .ended
        }
        return held == sent.accessToken ? .held : .replaced
    }

    /// The request, the wait and the decoding: off the main actor.
    nonisolated static func run<Value: Sendable>(
        _ notices: MastodonNotices, _ work: @Sendable (MastodonNotices) async throws -> Value
    ) async -> Result<Value, any Error> {
        do {
            return .success(try await work(notices))
        } catch {
            return .failure(error)
        }
    }
}
