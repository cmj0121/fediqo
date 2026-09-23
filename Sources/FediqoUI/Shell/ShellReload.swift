import FediqoCore
import Foundation
import Observation
import SwiftUI

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
//
// **One of each kind at a time, not one at a time** (#175): a thread read again does not wait on
// the timeline's reload, nor the timeline's on the thread. So what each kind last said is kept as
// that kind's, and a thread starting or ending neither clears nor overwrites the timeline's.
//
// **The third ask is nobody's press** (#95): every source this device holds, each for its usual
// reads, asked again each time the wait this device keeps has passed — a minute unless a person
// picks another. It says what it is doing in the same toast as `r`, lands through the store like
// every other ask, and leaves the page where the reader had it: the list keeps its top row
// (`HoldsPlace`) and only a pressed timeline re-centres the lamp. Esc does not stop it, since
// nobody started it; the next wait simply asks again.

/// One reload of each kind at a time, and the sources the last one could not read.
@MainActor
@Observable
final class ShellReload {
    /// What a reload asks for. Two of the same kind are one too many — the second would ask the
    /// same servers the same thing — and two of different kinds are two errands, each let run.
    enum Ask: Hashable, Sendable {
        /// The timeline in front: its sources, each for what its rules draw.
        case timeline
        /// The open thread: its post and what is around it.
        case thread
        /// Every source this device holds, each for its usual reads, on the wait it keeps (#95).
        case held
        /// The next, older stretch of the timeline in front, asked as the reader nears its end
        /// (#87). See `ShellMore.swift`.
        case more
    }

    /// The kinds of reload on the wire now. A second `r` of a kind already here starts nothing.
    private(set) var asking: Set<Ask> = []
    /// Whether any reload is on the wire.
    var running: Bool { !asking.isEmpty }
    /// Whether the only reload on the wire is the wait's, which nobody pressed for (#95).
    var onlyWaiting: Bool { asking == [.held] }
    /// The hosts the last reload of each kind could not read, the timeline's first and each in
    /// the order they were asked — a host both missed named once.
    var failed: [String] {
        var named: Set<String> = []
        return [Ask.timeline, .more, .thread, .held].flatMap { failures[$0] ?? [] }
            .filter { named.insert($0).inserted }
    }
    /// Each kind's own `failed`, cleared as that kind starts again — and a host's name let go of
    /// as soon as another timeline read, `r`'s or the wait's, reads it whole.
    private(set) var failures: [Ask: [String]] = [:]
    /// Bumped as each reload of the timeline ends, so the list can centre the selected post again.
    /// A thread read again leaves the list under it where it was.
    private(set) var landed = 0
    /// An open post the last thread reload could not find on its server, and why. Never guessed at.
    private(set) var unfindable: Unfindable?
    /// A source the last reload found speaking something this app does not read (#86). One, not
    /// a list, for `unfindable`'s reason: the sentence names one host and there is one line to
    /// say it on. The timeline's first, then the wait's.
    var unspoken: Unspoken? { unspokens[.timeline] ?? unspokens[.held] }
    /// Each kind's own `unspoken`, as `failures` is kept: a wait starting does not take back what
    /// the timeline's `r` found, nor the reverse (#95).
    private var unspokens: [Ask: Unspoken] = [:]
    /// The last reload of some kind was stopped by the reader before it finished.
    var stopped: Bool { !halted.isEmpty }
    /// The kinds whose last reload was stopped, each cleared as that kind starts again. Never
    /// `.held`: Esc stops what was pressed, and nobody pressed for that one.
    private var halted: Set<Ask> = []
    /// What the running reloads' own pieces of work are listed as on `SourceWork` (#170): a
    /// timeline's reads, an open thread's, or both. The toast names one of those and counts the
    /// rest, and nothing else that happens to be on the wire meanwhile — a picture, an emoji, a
    /// server asked what it is.
    var reading: Set<SourceWork.Purpose> {
        asking.reduce(into: []) { $0.formUnion(Self.purposes(of: $1)) }
    }

    /// How long one request of a reload may take before it counts as failed.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Where each stretch a listing reads toward its end has got to (#87).
    @ObservationIgnored var stretches = ShellStretches()

    /// Each running reload's work, and its waiter — resumed when the work ends or is stopped.
    @ObservationIgnored private var runs: [Ask: Run] = [:]
    /// Counts every run started. A stopped run's work goes on until it notices; when it ends it
    /// must not end whichever run of its kind started after it.
    @ObservationIgnored private var generation = 0

    private struct Run {
        let generation: Int
        let work: Task<Void, Never>
        let waiter: CheckedContinuation<Void, Never>
    }
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
        guard !asking.contains(.timeline), session.editing == nil else { return }
        await run(.timeline) {
            let asks = CompiledTimeline(query.definition(among: session.written), sources: session.sources)
                .sourcesToAsk()
            await self.read(asks, as: .timeline, in: session)
        }
    }

    /// Every source this device holds, each for its usual reads — the ask nobody presses (#95).
    /// Each lands as it answers, as a timeline's do, and one that fails is named while the others
    /// land. Nothing while one is already on its way, and nothing where no source is held.
    ///
    /// **Nor while `r` reads the timeline.** Both would read the same servers at once — a
    /// stranger's forum, which is never asked in parallel, among them — for what `r` is already
    /// bringing; the next wait asks again. **Nor while an ask for more is out** (#87), which may be
    /// on a forum's next page.
    func held(in session: ShellSession) async {
        guard asking.isDisjoint(with: [.held, .timeline, .more]), !session.sources.isEmpty else { return }
        await run(.held) {
            let asks = session.sources.map { FetchAsk(host: $0.host, categories: nil) }
            await self.read(asks, as: .held, in: session)
        }
    }

    /// `held(in:)` each time `wait` has passed, until the task running this is cancelled — the
    /// root view's, so a window closed or a wait chosen anew ends this one, and an ask of it
    /// still on the wire with it (#95). That is not the reader stopping it, so it says nothing.
    ///
    /// **The wait is counted from the end of the last ask**, not on a clock of its own: a slow
    /// round cannot pile the next one up behind it, and an ask still running as the wait comes
    /// round starts nothing. `sleep` is `Task.sleep` but for a test, which drives it by hand.
    ///
    /// **One clock per store, not per window.** Every window of the app reads the one store, and
    /// each runs this; the wait is the device's, so only the window that asked first asks
    /// (`WaitKeeper`), and the rest renew from what it lands. It closing hands the clock on.
    func keepAsking(
        every wait: Duration, in session: ShellSession,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        let me = UUID()
        defer { WaitKeeper.release(session.store, from: me) }
        while true {
            do { try await sleep(wait) } catch { return }
            guard WaitKeeper.claim(session.store, for: me) else { continue }
            await withTaskCancellationHandler {
                await held(in: session)
            } onCancel: {
                Task { @MainActor in self.end(.held) }
            }
        }
    }

    /// `asks`, each source read into the store as it answers, as `kind`: what did not answer is
    /// that kind's to say.
    private func read(_ asks: [FetchAsk], as kind: Ask, in session: ShellSession) async {
        let sources = session.sources
        // What the last run found is not this run's fact about any server. Cleared here
        // rather than at the end, so a run that is stopped halfway leaves nothing standing.
        unspokens[kind] = nil

        // **Every server is asked what it is before any of them is spoken to** — #86.
        //
        // Here and not inside each read, for two reasons. They go out together, so the whole
        // reload waits one round trip rather than each source waiting its own; and the
        // answers are in before `reprojectSources` below projects them onto the sources, so
        // the reads under it work from what the servers just said. A host answers this once
        // and is not asked again until a Clear or a Remove.
        await withTaskGroup(of: Void.self) { group in
            for ask in asks where sources.first(where: { $0.host == ask.host })?.kind.hasTimelines == true {
                let asking = self.timed(session.http, for: .serverCheck, in: session)
                group.addTask { await session.flavours.ask(ask.host, through: asking) }
            }
        }
        guard !Task.isCancelled else { return }
        await session.reprojectSources()
        let spoken = session.sources

        var unread: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for ask in asks {
                guard let source = spoken.first(where: { $0.host == ask.host }) else { continue }
                // It answered, and it answered as something this app does not read. Nothing
                // failed, so it is not reported silent; it is its own sentence, said once.
                guard SourceJoin.reads(source.kind) else {
                    self.unspokens[kind] = self.unspokens[kind] ?? Unspoken(host: source.host, kind: source.kind)
                    continue
                }
                group.addTask {
                    (ask.host, await self.read(source, for: ask.categories, revisits: kind != .held, in: session))
                }
            }
            for await (host, read) in group {
                if !read { unread.insert(host) }
                await session.reloadFromStore()
            }
        }
        guard !Task.isCancelled else { return }
        failures[kind] = asks.map(\.host).filter(unread.contains)
        // **A host that answered now is not still failing** (#95): what `r` said about it goes
        // when a wait reads it whole, and the reverse, rather than standing until that kind runs
        // again. A thread's failure is about its post, which this did not read.
        let answered = Set(asks.map(\.host)).subtracting(unread)
        for other in [Ask.timeline, .held, .more] where other != kind {
            if let named = failures[other], named.contains(where: answered.contains) {
                failures[other] = named.filter { !answered.contains($0) }
            }
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
        guard !asking.contains(.thread), session.editing == nil else { return }
        await run(.thread) {
            if let ref = ForumThreadRef(item) {
                let read = await session.posts.reload(ref, within: self.deadline)
                if !read, !Task.isCancelled { self.failures[.thread] = [ref.host] }
                return
            }
            guard let held = session.heldNote(item.id) else { return }
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
            case .gone: break
            case .failed: self.failures[.thread] = [held.source.host]
            case .unfindable(let why): self.unfindable = why
            }
        }
    }

    /// `r`: a reload of `thread` where one is open, or else of `query` — unless that one is
    /// running, which a second press leaves alone: it starts nothing and stops nothing (#29). A
    /// reload of the other kind running meanwhile is no reason to refuse (#175). Esc stops both.
    func press(thread: DummyItem?, timeline query: TimelineQuery, in session: ShellSession) {
        guard !asking.contains(thread == nil ? .timeline : .thread) else { return }
        Task {
            if let thread {
                await self.thread(thread, in: session)
            } else {
                await self.timeline(query, in: session)
            }
        }
    }

    /// What the last reload of `ask` said, let go of — as it starts again, and as the thread it
    /// was about is closed, so a line about a thread nobody is reading does not stand under the
    /// timeline.
    /// What `ask` could not read, as it ends.
    func record(_ hosts: [String], for ask: Ask) {
        failures[ask] = hosts
    }

    func forget(_ ask: Ask) {
        failures[ask] = nil
        halted.remove(ask)
        if ask == .thread { unfindable = nil }
    }

    /// Stops every running reload that was pressed for — Esc. What they had not landed does not
    /// land. The ask on a wait goes on: nobody started it, and Esc has a thread or a search to
    /// close instead of being spent on it once a minute (#95). Nor the ask for more: scrolling
    /// started it, not a key (#87).
    @discardableResult
    func stop() -> Bool {
        let pressed = asking.subtracting([.held, .more])
        guard !pressed.isEmpty else { return false }
        halted.formUnion(pressed)
        for (ask, run) in runs where pressed.contains(ask) {
            run.work.cancel()
            finish(ask, run.generation)
        }
        return true
    }

    /// Stops whatever a reload is reading as the reader on `host`: signed out, cleared or
    /// removed, nothing it brings may land afterwards, nor its token be used again.
    func stop(host: String) {
        for cancel in asYou.removeValue(forKey: host.lowercased())?.values.map({ $0 }) ?? [] { cancel() }
    }

    /// One reload: its state set, its work started, and this waiting until it ends or is stopped.
    ///
    /// What the last reload of this kind said is cleared as this one starts: a failure it named
    /// is asked again now. **A timeline's start clears the thread's too**, since `r` reaches the
    /// timeline only with no thread in front, and a thread left behind has nothing left to say
    /// about it. A thread's start leaves the timeline's standing, which is still true (#175).
    func run(_ ask: Ask, _ body: @escaping @MainActor () async -> Void) async {
        generation += 1
        let mine = generation
        asking.insert(ask)
        forget(ask)
        if ask == .timeline {
            forget(.thread)
            // And what asking for more said, and where a forum's pages had got to: the newest
            // page read again moves every page under it along by what it brought (#87).
            forget(.more)
            stretches.restart()
        }
        await withCheckedContinuation { continuation in
            let work = Task { @MainActor in
                await body()
                self.finish(ask, mine)
            }
            runs[ask] = Run(generation: mine, work: work, waiter: continuation)
        }
    }

    /// Ends `ask`'s run, if one is running, without saying it was stopped: nobody stopped it,
    /// its window went (#95).
    private func end(_ ask: Ask) {
        guard let run = runs[ask] else { return }
        run.work.cancel()
        finish(ask, run.generation)
    }

    /// Ends run `generation` of `ask`, once, and only while it is still that kind's current one.
    private func finish(_ ask: Ask, _ generation: Int) {
        guard let run = runs[ask], run.generation == generation else { return }
        runs[ask] = nil
        asking.remove(ask)
        if ask == .timeline { landed += 1 }
        run.waiter.resume()
    }

    private static func purposes(of ask: Ask) -> Set<SourceWork.Purpose> {
        switch ask {
        case .timeline: [.timeline]
        case .thread: [.conversation, .forumPost, .forumReplies]
        case .held: [.timeline]
        case .more: [.timeline]
        }
    }

    /// Work read as the reader on `host`, registered so `stop(host:)` can end it, and ended too
    /// if the reload is stopped.
    func asReader<T: Sendable>(
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
        /// Its source said it no longer has the post, and the row is marked so (#179). There is
        /// no thread to ask for around a post that is not there, and nothing failed.
        case gone
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
                let client = DiscourseClient(
                    http: timed(transport(host, in: session), for: .conversation, in: session), host: host
                )
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
        let (post, signedIn) = session.conversationPost(host: host, within: deadline)
        guard signedIn else {
            return try await Self.again(held, stamp: stamp, through: post, signedIn: false, in: session)
        }
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
        let note: Note
        do {
            note = try await post.post(id: id, source: stamp)
        } catch {
            // The source has just said, of this one post, that it no longer has it (#179). The
            // post stays, marked; what the reader asked for — the post read again — was answered.
            guard await session.sourceSaysGone(
                error, of: held, id: id, signedIn: signedIn, within: session.reload.deadline
            ) else { throw error }
            try Task.checkCancellation()
            await session.markGone(held.key)
            return .gone
        }
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
    /// Returns whether it came back. `revisits` is whether a forum's rows read their opening posts
    /// again when reached: a press asks what the forum says now, and a wait does not (#95).
    private func read(
        _ source: Source, for categories: Set<FediqoCore.Category>?, revisits: Bool,
        in session: ShellSession
    ) async -> Bool {
        let host = source.host
        // What a note records is which server it came from, not that server's subscriptions.
        let stamp = Source(host: host, kind: source.kind)
        switch source.kind {
        case .mastodon:
            // Each read is shown under the name the reader knows it by while it runs (#170).
            let client = { (name: SourceWork.Name) in
                MastodonClient(
                    http: self.timed(session.http, for: .timeline, name: name, in: session), host: host
                )
            }
            let publicRead = { try await client(.public).publicTimeline(source: stamp) }
            let trendsRead = { try await client(.trends).trending(source: stamp) }
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
            // A board's read is shown under that board's name (#164); the front page names none.
            let http = transport(host, in: session)
            let client = { (board: BoardSubscription?) in
                DiscuzClient(
                    http: self.timed(
                        http, for: .timeline, name: board.map { .called($0.name) }, in: session
                    ),
                    host: host
                )
            }
            let read: Bool
            // Whether a board or the front page was read at all — a Trends-only ask reads neither.
            let listed: Bool
            if let categories {
                let asked = source.boards.filter { categories.contains(.board(id: String($0.fid))) }
                read = await boards(asked, of: stamp, through: client, in: session)
                listed = !asked.isEmpty
            } else if source.boards.isEmpty {
                read = await land(host, in: session) { try await client(nil).latest(source: stamp) }
                listed = true
            } else {
                read = await boards(source.boards, of: stamp, through: client, in: session)
                listed = true
            }
            // **Its Trends, where the timeline reaches them** — the Trends tab, All, and a written
            // timeline whose rules can show them: `categories` names `.trends`, or is nil for the
            // source's usual reads, which on a Discuz! are its boards and its ranking lists as on
            // a Mastodon they are its public timeline and its trends. After the boards, so a
            // ranked thread lands on the row its board already made rather than first.
            if categories?.contains(.trends) ?? true, !Task.isCancelled {
                await ranked(stamp, through: http, in: session)
            }
            // **A board read again reads its rows' opening posts again too** (#154) — when each
            // row is reached, not now. The words kept with a row are what the forum said the
            // last time; a reader who pressed `r` asked what it says now. Only where the forum
            // answered: a reload that did not get through leaves the kept words standing.
            if revisits, listed, read, !Task.isCancelled { session.posts.revisit(host: host) }
            return read
        case .discourse:
            // A Discourse's front page is its one read; it has no boards this app picks.
            guard categories == nil else { return true }
            let client = DiscourseClient(http: timed(transport(host, in: session), for: .timeline, in: session), host: host)
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
        // The door reads the lists' names again, where every list is read; each timeline is read
        // through a door of its own, shown under the name the reader knows it by (#170). The
        // token is read from the Keychain once and every door is built from it.
        guard home || lists?.isEmpty == false,
              let token = session.mastodon.token(host: source.host)
        else { return true }
        let mastodon = session.mastodon
        let door = mastodon.authorized(token: token, within: deadline, for: .lists)
        let named = Self.names(of: source)
        let plain = mastodon.authorized(token: token, within: deadline, for: .timeline)
        var doors: [FediqoCore.Category: MastodonAuthorized] = [:]
        for category in [.home] + source.lists.map({ FediqoCore.Category.list(id: $0.id) }) {
            doors[category] = mastodon.authorized(
                token: token, within: deadline, for: .timeline, name: named(category)
            )
        }
        let account = MastodonAccount(door: door, store: session.store) { [doors] category in
            doors[category] ?? plain
        }
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
        _ boards: [BoardSubscription], of source: Source,
        through client: (BoardSubscription?) -> DiscuzClient, in session: ShellSession
    ) async -> Bool {
        var read = true
        for board in boards {
            // The same one request as before, read for the boards around this one too (#161):
            // a sub-board the forum's front page never names is written here, and the picker
            // then offers it with no request of its own.
            read = await land(source.host, in: session) {
                let page = try await client(board).boardPage(board.fid, source: source, named: board.name)
                session.learn(page, of: board, host: source.host)
                return page.notes
            } && read
        }
        return read
    }

    /// A Discuz!'s Trends: the week's ranked threads, then the week's ranked blogs, one page each
    /// and one after the other, through the forum's own transport — shown as its Trends while they
    /// run (#164, #170).
    ///
    /// **Never a failure.** A forum may switch its ranking lists off, keep them for members, or
    /// have nothing ranked this week, and none of that is the forum not answering: the reader
    /// asked for its boards and its Trends, and a Trends that is not there is simply no rows.
    /// So what these two pages bring lands, and what they could not bring is not reported.
    private func ranked(
        _ source: Source, through http: any HTTPClient, in session: ShellSession
    ) async {
        let client = DiscuzClient(
            http: timed(http, for: .timeline, name: .trends, in: session), host: source.host
        )
        _ = await land(source.host, in: session) { try await client.rankedThreads(source: source) }
        guard !Task.isCancelled else { return }
        _ = await land(source.host, in: session) { try await client.rankedBlogs(source: source) }
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

    /// Bounded by the reload's deadline, and on `SourceWork` for what it is (#164) while it runs.
    /// `name` is the timeline or board it reads, by the name the reader knows, where it reads one.
    func timed(
        _ http: any HTTPClient, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil,
        in session: ShellSession
    ) -> any HTTPClient {
        Deadline(
            WatchedHTTP(http, for: purpose, name: name, in: session.work) as any HTTPClient,
            within: deadline
        )
    }

    /// The name a reader knows each of a Mastodon source's timelines by, as it stands when the
    /// reload starts: a list by its own title, and never by its id — a list this source no
    /// longer names is named nothing.
    private static func names(of source: Source) -> (FediqoCore.Category) -> SourceWork.Name? {
        let titles = Dictionary(source.lists.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return { category in
            switch category {
            case .home: .home
            case .public: .public
            case .trends: .trends
            case .list(let id): titles[id].map { .called($0) }
            case .board: nil
            }
        }
    }

    /// A forum signed in to is read through its own browser, as a join reads it.
    func transport(_ host: String, in session: ShellSession) -> any HTTPClient {
        session.forums.readTransport(host: host, else: session.http)
    }
}

/// Which window's wait asks, per store (#95). The first to reach its wait takes the clock and
/// keeps it until its loop ends; every other window's wait passes and asks nothing, and renews
/// from what the store is brought all the same. Keyed on the store rather than held on it, since
/// the store is an actor of the core and knows nothing of windows.
@MainActor
enum WaitKeeper {
    private static var keepers: [ObjectIdentifier: UUID] = [:]

    /// Whether `me` asks on `store`'s wait: it already does, or nobody does.
    static func claim(_ store: ItemStore, for me: UUID) -> Bool {
        let key = ObjectIdentifier(store)
        if let keeper = keepers[key], keeper != me { return false }
        keepers[key] = me
        return true
    }

    /// `me`'s loop ended: the next window to reach its wait asks.
    static func release(_ store: ItemStore, from me: UUID) {
        let key = ObjectIdentifier(store)
        if keepers[key] == me { keepers[key] = nil }
    }
}

/// While this window is open, the sources this device holds are asked again each time `minutes`
/// have passed (#95). A wait chosen anew starts counting again from the choice. A modifier of its
/// own so the root view's chain, long enough already for the compiler the CI builds with, does
/// not grow a closure.
struct AsksOnAWait: ViewModifier {
    let session: ShellSession
    let minutes: Int

    func body(content: Content) -> some View {
        content.task(id: minutes) {
            await session.reload.keepAsking(every: Self.wait(minutes), in: session)
        }
    }

    static func wait(_ minutes: Int) -> Duration { .seconds(minutes * 60) }
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
