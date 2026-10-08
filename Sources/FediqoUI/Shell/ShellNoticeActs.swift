import FediqoCore
import Foundation
import Observation

/// What is done to a source's notices from the notices page (#323), and what each source says
/// it holds back: dismissing one line, dismissing all a source has, and letting a held-back
/// request through or go.
///
/// **Nothing here changes what is drawn before the source has answered.** A line leaves the
/// list, and a request its own, only on the source's yes; a refusal or a failure leaves both
/// as they were and is said, by source, above the list (`said`).
///
/// **An answer is taken only where the token it was asked with is still the one held** — the
/// list's own rule (`ShellNoticeList.land`): an answer for a sign-in the reader has since
/// replaced, or signed out of, changes nothing and says nothing. And an act goes to the door
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

    /// What is said of the last act at one source that changed nothing.
    struct Said: Equatable, Sendable {
        let act: Act
        let why: WriteWhy
    }

    /// The last act at each source that changed nothing, by folded host. Taken down by the
    /// next act there, and by the page reading again.
    private(set) var said: [String: Said] = [:]
    /// What each source last said it holds back. One that answered `absent` is not asked again.
    private(set) var holdings: [String: NoticeHolding] = [:]
    /// The requests each source handed over when its held-back line was last opened.
    private(set) var requests: [String: [NoticeRequest]] = [:]
    /// The sources whose held-back line is open.
    private(set) var opened: Set<String> = []
    /// The sources whose requests are on the wire.
    private(set) var readingRequests: Set<String> = []
    /// What is on the wire now: a line's id, a request's, or a source's own for dismissing all.
    private(set) var acting: Set<String> = []
    private var onWay: [String: [NoticeRequest]] = [:]
    /// The destructive item of a menu on the notices page that was chosen and not yet answered.
    /// Held here and not by a row, for `ShellSession.rowAsk`'s reason: a row scrolled away must
    /// not drop a question still open, and the key that asks puts the same one.
    var asked: ShellMoreAsk?
    @ObservationIgnored private var looking: Set<String> = []

    /// What dismissing all at one source is on the wire under.
    static func all(_ host: String) -> String { "all\u{1e}" + host.lowercased() }

    // MARK: - What the page reads

    /// What one source says it holds back just now, or nothing: it has no such thing, was not
    /// asked, or holds none.
    func held(host: String) -> NoticesHeld? {
        holdings[host.lowercased()]?.held
    }

    /// The sources holding something back, in host order.
    var holders: [String] {
        holdings.filter { $0.value.held != nil }.keys.sorted()
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
        guard case .yes(let holding) = await ask(host, for: .notices, in: session, { try await $0.held(known: known) })
        else { return }
        holdings[host] = holding
        if holding.held == nil {
            requests[host] = nil
            opened.remove(host)
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
        switch await ask(host, for: .notices, in: session, { try await $0.requests(source: source) }) {
        case .yes(let listed): requests[host] = listed
        case .no(let why): said[host] = Said(act: .requests, why: why)
        case .nothing: break
        }
    }

    // MARK: - Acting

    /// Dismisses one line at its source — a gathered line as the line it is, every notice it
    /// stands for at once. The line leaves the list once the source has answered, and stands,
    /// with the reason said, where it refused or did not answer.
    ///
    /// Nothing for a line that is not held, or whose source's sign-in may not dismiss.
    func dismiss(_ notice: Notice, in session: ShellSession) async {
        let host = notice.source.host.lowercased()
        let list = session.noticeList
        // The line as it is held now: one that has folded since it was drawn is the same line.
        guard let line = list.reaches[host]?.notices.first(where: { $0.id == notice.id }) else { return }
        await perform(.dismiss, at: host, as: line.id, in: session, { try await $0.dismiss(line) }) {
            list.took(line)
        }
    }

    /// Dismisses every notice one source has for the person, shown here or not: one request,
    /// and its lines leave the list once it has answered.
    func dismissAll(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        await perform(.dismissAll, at: host, as: Self.all(host), in: session, { try await $0.dismissAll() }) {
            session.noticeList.tookAll(host: host)
        }
    }

    /// Lets one held-back request through. The source's yes means the request is gone and its
    /// notices are on their way, not that they have arrived: it is said so until a later read
    /// shows them.
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
        await perform(act, at: host, as: request.id, in: session, work) {
            self.requests[host]?.removeAll { $0.id == request.id }
            // What the source said it holds, less this: its own count comes with the next look.
            if let held = self.holdings[host]?.held {
                self.holdings[host] = .holds(NoticesHeld(
                    requests: max(0, held.requests - 1), notices: max(0, held.notices - request.count)
                ))
            }
            if self.held(host: host) == nil { self.opened.remove(host) }
            then()
        }
    }

    /// One act at one source, on the wire under `name`: sent only where the sign-in may act and
    /// the same act is not out already, `done` on the source's yes, and a refusal or a failure
    /// said in its place. What was said of the act before goes as this one sets out.
    private func perform(
        _ act: Act, at host: String, as name: String, in session: ShellSession,
        _ work: @escaping @Sendable (MastodonNotices) async throws -> Void, done: () -> Void
    ) async {
        guard session.mastodon.dismisses(host: host), acting.insert(name).inserted else { return }
        defer { acting.remove(name) }
        said[host] = nil
        switch await ask(host, for: .write, in: session, work) {
        case .yes: done()
        case .no(let why): said[host] = Said(act: act, why: why)
        case .nothing: break
        }
    }

    /// Says, or takes down, what an act at one source came to. The ask for notices is the
    /// session's (`allowNotices`), and says its failure here beside the others.
    func say(_ word: Said?, host: String) {
        said[host.lowercased()] = word
    }

    /// Lets go of everything about one source: with its sign-in, as the list lets go of its lines.
    func forget(host raw: String) {
        let host = raw.lowercased()
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
