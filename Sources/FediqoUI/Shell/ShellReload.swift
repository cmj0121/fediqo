import FediqoCore
import Foundation
import Observation

// `r` (#29): what the reader is looking at, asked for again, and nothing else.
//
// A timeline asks exactly the sources its rules draw from — `CompiledTimeline.sourcesToAsk()` —
// and each for the categories named, or for its usual reads where none are. An open thread asks
// for that thread alone. Posts land through the store, which never takes a row away — a post read
// again replaces its own row — so the rows drawn keep their ids and the selected post stays
// selected.
//
// Every request a reload makes has its own deadline, and a reload can be stopped: a server that
// trickles cannot hold `r` for ever. What is read as the reader is registered per host, so a
// sign-out, Clear or Remove stops it before anything it brings lands.

/// One reload at a time, and the sources the last one could not read.
@MainActor
@Observable
final class ShellReload {
    /// Whether a reload is on the wire. A second `r` meanwhile starts nothing.
    private(set) var running = false
    /// The hosts the last reload could not read, in the order they were asked.
    private(set) var failed: [String] = []
    /// Bumped as each reload ends, so the list can centre the selected post again.
    private(set) var landed = 0
    /// An open post the last reload could not find on its server, and why. Never guessed at.
    private(set) var unfindable: Unfindable?
    /// A source the last reload found speaking something this app does not read (#86). One, not
    /// a list, for `unfindable`'s reason: the sentence names one host and there is one line to
    /// say it on.
    private(set) var unspoken: Unspoken?
    /// The last reload was stopped by the reader before it finished.
    private(set) var stopped = false

    /// How long one request of a reload may take before it counts as failed.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    /// The running reload's work, and its waiter — resumed when the work ends or is stopped.
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?
    /// Which run `work` and `waiter` belong to. A stopped run's work goes on until it notices;
    /// when it ends it must not end whichever run started after it.
    @ObservationIgnored private var generation = 0
    /// Work read as the reader, per host, so `stop(host:)` can end it.
    @ObservationIgnored private var asYou: [String: [UUID: () -> Void]] = [:]

    /// A source this device holds as a Mastodon whose **own server now answers as something this
    /// app does not read** — #86.
    ///
    /// Not a failure and not a guess. The host answered, it named itself, and the name is one
    /// `SourceJoin.reads` says no to; what was written down when the reader joined it is simply
    /// no longer what is there. The source stays, its rows stay, and this run does not go on
    /// speaking Mastodon to a server that has stopped being one.
    struct Unspoken: Equatable, Sendable {
        let host: String
        let kind: ProtocolKind

        var sentence: String {
            String(format: L10n.t("timeline.reload.unspoken"), host, kind.displayName)
        }
    }

    /// Why an open Mastodon post, held without its server id, could not be read again.
    enum Unfindable: Equatable, Sendable {
        /// Signed out, so nobody may look it up.
        case signedOut(host: String)
        /// Looked up, and what came back was not this post.
        case notFound(host: String)
        /// The token cannot search: it was issued before `read:search` was asked for.
        case cannotSearch(host: String)

        var sentence: String {
            switch self {
            case .signedOut(let host): String(format: L10n.t("thread.reload.unfindable"), host)
            case .notFound(let host): String(format: L10n.t("thread.reload.notfound"), host)
            case .cannotSearch(let host): String(format: L10n.t("thread.reload.scope"), host)
            }
        }
    }

    /// The timeline's one quiet line about `r`: on the wire, stopped, or what did not answer.
    /// Nothing once a reload has landed whole.
    var line: String? {
        if running { return L10n.t("timeline.reload.progress") }
        if stopped { return L10n.t("timeline.reload.stopped") }
        if let unfindable { return unfindable.sentence }
        // **Before the failures, because it is the more particular fact.** A server that told
        // this app what it now speaks answered perfectly well; saying "did not answer" about it
        // would be this device reporting its own refusal to read as the server's silence.
        if let unspoken { return unspoken.sentence }
        guard !failed.isEmpty else { return nil }
        return String(format: L10n.t("timeline.reload.failed"), failed.joined(separator: ", "))
    }

    /// The newest posts for `query`, from its own sources only — a written timeline's as the
    /// session holds it now. Each source lands as it answers, so one that fails or is slow holds
    /// back none of the others. Nothing while the timeline editor is up: it owns the keys.
    func timeline(_ query: TimelineQuery, in session: ShellSession) async {
        guard !running, session.editing == nil else { return }
        await run {
            let sources = session.sources
            let asks = CompiledTimeline(query.definition(among: session.written), sources: sources)
                .sourcesToAsk()
            // What the last run found is not this run's fact about any server. Cleared here
            // rather than at the end, so a run that is stopped halfway leaves nothing standing.
            self.unspoken = nil

            // **Every server is asked what it is before any of them is spoken to** — #86.
            //
            // Here and not inside each read, for two reasons. They go out together, so the whole
            // reload waits one round trip rather than each source waiting its own; and the
            // answers are in before `reloadFromStore` below projects them onto the sources, so
            // the reads under it work from what the servers just said. A host answers this once
            // and is not asked again until a Clear or a Remove.
            await withTaskGroup(of: Void.self) { group in
                for ask in asks where sources.first(where: { $0.host == ask.host })?.kind.hasTimelines == true {
                    group.addTask { await session.flavours.ask(ask.host, through: self.timed(session.http)) }
                }
            }
            guard !Task.isCancelled else { return }
            await session.reloadFromStore()
            let spoken = session.sources

            var unread: Set<String> = []
            await withTaskGroup(of: (String, Bool).self) { group in
                for ask in asks {
                    guard let source = spoken.first(where: { $0.host == ask.host }) else { continue }
                    // It answered, and it answered as something this app does not read. Nothing
                    // failed, so it is not reported silent; it is its own sentence, said once.
                    guard SourceJoin.reads(source.kind) else {
                        self.unspoken = self.unspoken ?? Unspoken(host: source.host, kind: source.kind)
                        continue
                    }
                    group.addTask { (ask.host, await self.read(source, for: ask.categories, in: session)) }
                }
                for await (host, read) in group {
                    if !read { unread.insert(host) }
                    await session.reloadFromStore()
                }
            }
            guard !Task.isCancelled else { return }
            self.failed = asks.map(\.host).filter(unread.contains)
        }
    }

    /// The open thread's post and its thread, from the host it came through, and not the
    /// timeline under it.
    ///
    /// A Discuz! thread's opening post and replies are the forum page's, held by `ForumPosts`,
    /// whose pane draws them. A Mastodon post is read again, then its context, and a Discourse
    /// topic from its own page; both replace only rows already held (`ItemStore.refresh`), so an
    /// edited post shows its new words and a post this device never held does not arrive in All.
    func thread(_ item: DummyItem, in session: ShellSession) async {
        guard !running, session.editing == nil else { return }
        await run {
            if let ref = ForumThreadRef(item) {
                let read = await session.posts.reload(ref, within: self.deadline)
                if !read, !Task.isCancelled { self.failed = [ref.host] }
                return
            }
            guard let held = session.notes.first(where: { $0.key.rowID == item.id }) else { return }
            let again = await self.again(held, in: session)
            guard !Task.isCancelled else { return }
            switch again {
            case .read:
                // The post's own words, and then the thread around it — one ask each, and the
                // thread's is `ShellConversations`', which is the one place that reads it (#90).
                // Its failure is its own sentence in the pane and does not fail the reload: a
                // post read again is a post read again whatever its thread did.
                // The store first, then the thread. A post held without its server id has just
                // been found by its URI and the id kept; asking the store for the rows again
                // before the thread is read is what lets the thread read use that id instead of
                // paying for the same search a second time. What the thread read itself lands is
                // adopted by that read — see `ShellConversations.read`.
                await session.reloadFromStore()
                await session.conversations.again(item, in: session)
            case .failed: self.failed = [held.source.host]
            case .unfindable(let why): self.unfindable = why
            }
        }
    }

    /// `r`: a reload of `thread` where one is open, or else of `query` — unless one is running,
    /// which a second press leaves alone: it starts nothing and stops nothing (#29). Esc stops it.
    func press(thread: DummyItem?, timeline query: TimelineQuery, in session: ShellSession) {
        guard !running else { return }
        Task {
            if let thread {
                await self.thread(thread, in: session)
            } else {
                await self.timeline(query, in: session)
            }
        }
    }

    /// Stops the running reload — Esc. What it had not landed does not land.
    @discardableResult
    func stop() -> Bool {
        guard running, let work else { return false }
        work.cancel()
        stopped = true
        finish(generation)
        return true
    }

    /// Stops whatever a reload is reading as the reader on `host`: signed out, cleared or
    /// removed, nothing it brings may land afterwards, nor its token be used again.
    func stop(host: String) {
        for cancel in asYou.removeValue(forKey: host.lowercased())?.values.map({ $0 }) ?? [] { cancel() }
    }

    /// One reload: its state set, its work started, and this waiting until it ends or is stopped.
    private func run(_ body: @escaping @MainActor () async -> Void) async {
        generation += 1
        let mine = generation
        running = true
        failed = []
        unfindable = nil
        stopped = false
        await withCheckedContinuation { continuation in
            waiter = continuation
            work = Task { @MainActor in
                await body()
                self.finish(mine)
            }
        }
    }

    /// Ends run `run`, once, and only while it is still the current one.
    private func finish(_ run: Int) {
        guard run == generation, let waiter else { return }
        self.waiter = nil
        work = nil
        running = false
        landed += 1
        waiter.resume()
    }

    /// Work read as the reader on `host`, registered so `stop(host:)` can end it, and ended too
    /// if the reload is stopped.
    private func asReader<T: Sendable>(
        _ host: String, _ read: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let host = host.lowercased()
        let id = UUID()
        let task = Task { @MainActor in try await read() }
        asYou[host, default: [:]][id] = { task.cancel() }
        defer { asYou[host]?[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private enum Again: Sendable {
        case read
        case failed
        case unfindable(Unfindable)
    }

    /// One post read again into the store, as its protocol reads a single post.
    private func again(_ held: Note, in session: ShellSession) async -> Again {
        let host = held.source.host
        let stamp = Source(host: host, kind: held.source.kind)
        do {
            // **What the server says it is, not what the note remembers** — #86. The stamp above
            // keeps the stored kind, because what a note records is where it came from and this
            // device is not rewriting that; what is switched on is who to speak to now.
            switch session.flavours.speaking(host, storedAs: held.source.kind) {
            case .mastodon:
                return try await againOnMastodon(held, stamp: stamp, in: session)
            case .discourse:
                // The topic's own page brings its whole opening post, where `/latest` gave only an
                // excerpt, so the refreshed row's body is longer than the one it replaces — and a
                // keyword rule, which reads the body, may now match it or stop matching it.
                guard let topic = held.id.split(separator: ":").last.flatMap({ Int($0) }) else {
                    return .failed
                }
                let client = DiscourseClient(http: timed(transport(host, in: session)), host: host)
                let note = try await client.topic(topic, source: stamp, board: held.board)
                try Task.checkCancellation()
                await session.store.refresh([note], ifSourceHere: host)
            case .discuz, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
                 .gotosocial, .unknown:
                // A Discuz! thread is `ForumPosts`'; nothing else is joined.
                return .read
            }
            return .read
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            return .failed
        } catch {
            return Cancellation.happened(error) ? .read : .failed
        }
    }

    /// The post first, landed on its own; then its context, whose failure — a busy thread past
    /// the signed-in ceiling, say — keeps the post's refresh rather than failing it.
    ///
    /// Signed in, the whole sequence is one piece of work read as the reader, so a sign-out or
    /// Clear between two of its requests ends it before the next goes out on a forgotten token.
    private func againOnMastodon(_ held: Note, stamp: Source, in session: ShellSession) async throws -> Again {
        let host = stamp.host
        guard let door = session.mastodon.authorized(host: host, within: deadline) else {
            let post = MastodonPost(http: timed(session.http), host: host)
            return try await Self.again(held, stamp: stamp, through: post, signedIn: false, in: session)
        }
        let post = MastodonPost(door: door)
        return try await asReader(host) {
            try await Self.again(held, stamp: stamp, through: post, signedIn: true, in: session)
        }
    }

    private static func again(
        _ held: Note, stamp: Source, through post: MastodonPost, signedIn: Bool, in session: ShellSession
    ) async throws -> Again {
        let host = stamp.host
        let found: String?
        do {
            found = try await post.id(of: held)
        } catch MastodonAuthError.http(403) {
            return .unfindable(.cannotSearch(host: host))
        }
        guard let id = found else {
            return .unfindable(signedIn ? .notFound(host: host) : .signedOut(host: host))
        }
        try Task.checkCancellation()
        let note = try await post.post(id: id, source: stamp)
        try Task.checkCancellation()
        await session.store.refresh([note], ifSourceHere: host)
        // **The thread around it is not asked for here.** It was, until #90 gave the conversation
        // a home of its own: the pane reads it, holds it and says for itself when it could not be
        // had, and a second copy of the request living here would put the same page on the wire
        // twice for one press of `r`. What that read landed in the store — held rows refreshed,
        // nothing admitted — it still lands; see `ShellConversations.read`.
        return .read
    }

    /// Reads one source for `categories`, or for its usual reads where nil, into the store.
    /// Returns whether it came back.
    private func read(
        _ source: Source, for categories: Set<FediqoCore.Category>?, in session: ShellSession
    ) async -> Bool {
        let host = source.host
        // What a note records is which server it came from, not that server's subscriptions.
        let stamp = Source(host: host, kind: source.kind)
        switch source.kind {
        case .mastodon:
            let client = MastodonClient(http: timed(session.http), host: host)
            let publicRead = { try await client.publicTimeline(source: stamp) }
            let trendsRead = { try await client.trending(source: stamp) }
            var read: Bool
            if let categories {
                read = true
                if categories.contains(.public) { read = await land(host, in: session, publicRead) && read }
                if categories.contains(.trends) { read = await land(host, in: session, trendsRead) && read }
            } else {
                // The join's rule: a server with no trends still has a timeline, and the reverse.
                let publicCame = await land(host, in: session, publicRead)
                let trendsCame = await land(host, in: session, trendsRead)
                read = publicCame || trendsCame
            }
            return await readAsYou(source, for: categories, in: session) && read
        case .discuz:
            let client = DiscuzClient(http: timed(transport(host, in: session)), host: host)
            let read: Bool
            if let categories {
                let asked = source.boards.filter { categories.contains(.board(id: String($0.fid))) }
                read = await boards(asked, of: stamp, through: client, in: session)
            } else if source.boards.isEmpty {
                read = await land(host, in: session) { try await client.latest(source: stamp) }
            } else {
                read = await boards(source.boards, of: stamp, through: client, in: session)
            }
            // **A board read again reads its rows' opening posts again too** (#154) — when each
            // row is reached, not now. The words kept with a row are what the forum said the
            // last time; a reader who pressed `r` asked what it says now. Only where the forum
            // answered: a reload that did not get through leaves the kept words standing.
            if read, !Task.isCancelled { session.posts.revisit(host: host) }
            return read
        case .discourse:
            // A Discourse's front page is its one read; it has no boards this app picks.
            guard categories == nil else { return true }
            let client = DiscourseClient(http: timed(transport(host, in: session)), host: host)
            return await land(host, in: session) { try await client.latest(source: stamp) }
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
             .unknown:
            // Nothing of these is joined, so there is nothing to ask.
            return true
        }
    }

    /// Home and the chosen lists, as the reader — only where signed in, and only what was asked.
    private func readAsYou(
        _ source: Source, for categories: Set<FediqoCore.Category>?, in session: ShellSession
    ) async -> Bool {
        let home = categories?.contains(.home) ?? true
        let lists = categories.map { asked in
            Set(asked.compactMap { category -> String? in
                if case .list(let id) = category { return id }
                return nil
            })
        }
        guard home || lists?.isEmpty == false,
              let door = session.mastodon.authorized(host: source.host, within: deadline)
        else { return true }
        let account = MastodonAccount(door: door, store: session.store)
        do {
            return try await asReader(source.host) {
                if let lists { return try await account.read(home: home, lists: lists) }
                return try await account.read()
            }
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: source.host)
            return false
        } catch {
            return Cancellation.happened(error)
        }
    }

    /// One board after another, as a pick reads them: a stranger's forum is not asked in parallel.
    private func boards(
        _ boards: [BoardSubscription], of source: Source, through client: DiscuzClient,
        in session: ShellSession
    ) async -> Bool {
        var read = true
        for board in boards {
            // The same one request as before, read for the boards around this one too (#161):
            // a sub-board the forum's front page never names is written here, and the picker
            // then offers it with no request of its own.
            read = await land(source.host, in: session) {
                let page = try await client.boardPage(board.fid, source: source, named: board.name)
                session.learn(page, of: board, host: source.host)
                return page.notes
            } && read
        }
        return read
    }

    /// One read into the store, while its source is still here and the reload is not stopped.
    /// A reader walking away is not a failure; anything else is.
    private func land(
        _ host: String, in session: ShellSession, _ fetch: () async throws -> [Note]
    ) async -> Bool {
        do {
            let notes = try await fetch()
            try Task.checkCancellation()
            await session.store.ingest(notes, ifSourceHere: host)
            return true
        } catch {
            return Cancellation.happened(error)
        }
    }

    private func timed(_ http: any HTTPClient) -> any HTTPClient {
        Deadline(http, within: deadline)
    }

    /// A forum signed in to is read through its own browser, as a join reads it.
    private func transport(_ host: String, in session: ShellSession) -> any HTTPClient {
        guard session.forums.readsThroughEngine(host: host) else { return session.http }
        return ForumJoinTransport(session.forums.transport(host: host))
    }
}

/// Every request through it ends within `limit`: past it, the request is cancelled and fails as
/// timed out. For a reload (#29), whose reader is waiting on a key they pressed.
struct Deadline: HTTPClient, HTTPSender {
    private let get: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))?
    private let sender: (any HTTPSender)?
    private let limit: Duration

    init(_ inner: any HTTPClient, within limit: Duration) {
        get = { try await inner.data(from: $0) }
        sender = nil
        self.limit = limit
    }

    init(_ inner: any HTTPSender, within limit: Duration) {
        get = nil
        sender = inner
        self.limit = limit
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard let get else { return try await send(URLRequest(url: url)) }
        return try await Self.within(limit) { try await get(url) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let sender else { throw URLError(.unsupportedURL) }
        return try await Self.within(limit) { try await sender.send(request) }
    }

    private static func within<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
