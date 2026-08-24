import Foundation
import GRDB

/// Which stream a screen is asking for. They are two different things and neither stands in
/// for the other: the timeline is the timeline, ordered by time; trending is a place you go
/// to, in the order the servers put it. Nothing is ranked by us — a server's ranking is kept.
///
/// The raw values name the screens too, so a mode carries its own titles rather than having
/// them handed to it.
public enum FeedMode: String, Sendable {
    case timeline
    case trending
}

/// Who asked for a load, which is the whole of what a backoff is for.
///
/// A reader who asked is answered at once, because they asked. A clock that asked is a guest
/// on other people's machines: it leaves alone whatever could not answer last time, and
/// lengthens that wait every time nothing arrives.
public enum Refresh: Sendable {
    /// The reader asked. Every server is asked, whatever it did last time, and a server that
    /// still cannot answer is not punished for it — only the clock's own failures lengthen
    /// the clock's own wait. An answer here still forgives, so pulling to refresh is how a
    /// backed-off server comes back at once.
    case manual
    /// The clock asked, every `every`. A server still inside its wait is not asked at all,
    /// and one that gives nothing waits twice as long next time, starting at `every`.
    case automatic(every: Duration)
}

public struct TimelineResult: Sendable {
    /// One row per post. The timeline is in timestamp order; trending is in the servers' own
    /// rank order. Nothing here is ranked by us, and nothing is re-ordered after the fact.
    public let posts: [Post]
    /// Why a server gave what it gave, at most one reason per server — keyed by
    /// `Server.endpoint`, not by hostname: one host can be a source twice under two
    /// protocols, and their fates are not the same fact. The reason inside still names the
    /// bare host, because that is what a screen says to the reader.
    ///
    /// Every case but `.tokenRejected` and `.store` means that server gave nothing; those
    /// two ride alongside posts that did arrive, so a caller reading a server's fate reads
    /// `posts` for whether anything came and `failures` for whether anything needs attention.
    public let failures: [String: SourceFailure]
    /// The servers this load did not ask at all, by `Server.endpoint`, because they were
    /// still inside a wait. They are not failing now and they are not answering either, so
    /// they are in neither `posts` nor `failures` — and a caller that draws a server's fate
    /// needs to be told the difference between a server that had nothing to say and one
    /// that was never asked.
    public let skipped: Set<String>

    public init(posts: [Post], failures: [String: SourceFailure], skipped: Set<String> = []) {
        self.posts = posts
        self.failures = failures
        self.skipped = skipped
    }

    public var isEmpty: Bool { posts.isEmpty }

    /// Every server's standing reason: what `known` already said, carried through this load.
    ///
    /// A server inside its wait is absent from `failures` because it was not asked, so
    /// taking a load's failures alone would strike its reason off the screen and put it
    /// back a tick later, though nothing about the server changed. Here a skipped server
    /// keeps whatever was already known about it; a server that was asked is judged by this
    /// load alone, so answering clears its line; and a server no longer among `servers` is
    /// forgotten, since it is nobody's source now.
    public func failures(carrying known: [String: SourceFailure],
                         of servers: [Server]) -> [String: SourceFailure] {
        let ours = Set(servers.map(\.endpoint))
        var standing = known.filter { ours.contains($0.key) && skipped.contains($0.key) }
        for (endpoint, failure) in self.failures where ours.contains(endpoint) {
            standing[endpoint] = failure
        }
        return standing
    }

    /// What the screen should show, given what it was already showing.
    ///
    /// A refresh that came back with nothing has not emptied anything: the store still holds
    /// what it held, and the promise this app makes is that a server being down leaves every
    /// existing row where it was and simply adds nothing. Replacing the screen with a refresh
    /// that failed would make an unreachable server look like an empty one, which is the one
    /// thing an empty screen is supposed to mean.
    ///
    /// Asking nobody is different from asking and being told nothing: with no sources left
    /// there is nothing whose rows these would be, so they go.
    public func posts(carrying shown: [Post], asked servers: [Server]) -> [Post] {
        if !posts.isEmpty || servers.isEmpty { return posts }
        return shown
    }
}

/// Reads every server at once and hands back one stream in one order.
///
/// It knows about `SourceClient`, never about a protocol. A source this build cannot yet read
/// is a reported failure, not a quiet omission — the same rule the rest of the file follows.
///
/// The timeline is merged by time. A trending list is the server's own order, kept: a post's
/// rank is its place in the list the server handed over, and across servers the best rank
/// wins — the same order the store reads trends back in, so the page that opened from the
/// store and the page that just refreshed do not trade places.
public struct TimelineLoader: Sendable {
    private let registry: SourceRegistry
    private let limit: Int
    private let store: LocalStore?
    /// Who each server is read as. Nil without a store: nobody is signed in anywhere, so
    /// there is nothing to resolve and the Keychain is never opened.
    private let tokenSource: TokenSource?
    /// How long each server is to be left alone. One per loader, so a timeline that could
    /// not be had says nothing about the same server's trending list.
    private let backoff = ServerBackoff()

    /// With a `store`, what each server hands over is kept before it is merged; without one,
    /// nothing is remembered between loads — and nobody is signed in either, so a loader
    /// without a store reads every server as a stranger and never opens `secrets`.
    ///
    /// Pass `tokens` to share one resolver with everything else that needs to know who is
    /// signed in — the launch check, in practice, and the other feed. Without one the loader
    /// keeps its own, which is right for a preview and for a test and for nothing else.
    public init(registry: SourceRegistry = .standard(), limit: Int = 40, store: LocalStore? = nil,
                secrets: any SecretStore = KeychainSecretStore(),
                tokens: TokenSource? = nil) {
        self.registry = registry
        self.limit = limit
        self.store = store
        self.tokenSource = tokens ?? store.map { TokenSource(store: $0, secrets: secrets) }
    }

    /// What the store already holds for `mode`, newest first — the screen before any server
    /// answers. Trending is what servers listed in the last day. Nothing without a store.
    public func stored(mode: FeedMode, now: Date = Date()) async throws -> [Post] {
        guard let store else { return [] }
        return switch mode {
        case .timeline: try await store.timeline()
        case .trending: try await store.trending(since: now.addingTimeInterval(-24 * 60 * 60))
        }
    }

    /// Every server asked at once, merged into one stream in one order.
    ///
    /// `refresh` says who asked, and the default is the reader — so a caller that has no
    /// clock asks everyone, which is what every caller did before there was one.
    public func load(servers: [Server], mode: FeedMode,
                     refresh: Refresh = .manual, now: Date = Date()) async -> TimelineResult {
        var failures: [String: SourceFailure] = [:]
        var collected: [[Post]] = []
        // A server still inside its wait is not asked, and is not reported either: it is not
        // failing now, it is being left alone. What it said last time is not lost with it —
        // it comes back named in `skipped`, so a screen can keep showing the reason rather
        // than blinking it off and on as the server enters and leaves its wait.
        let (asked, skipped) = await askable(servers, refresh: refresh, now: now)
        // Once per load, not once per server: the rows and the Keychain are asked before
        // anything is asked of the network, and only about the servers being read.
        let tokens = await tokensByEndpoint(for: asked)
        // Which servers a request actually went to, so the bookkeeping below judges only
        // the ones that were given a chance to answer.
        var reached: Set<String> = []

        // Each task answers with what arrived and, separately, what went wrong — a store that
        // would not keep the posts is a failure worth reporting, but the posts still arrived.
        await withTaskGroup(of: (endpoint: String, answer: Answer).self) { group in
            for server in asked {
                guard let client = registry.client(for: server.socialProtocol) else {
                    // Nothing was sent anywhere, so there is nothing to back off from: a
                    // protocol this build cannot read will not start speaking it in a minute.
                    failures[server.endpoint] = .unsupported(server.socialProtocol)
                    continue
                }
                let token = tokens[server.endpoint]
                reached.insert(server.endpoint)
                group.addTask {
                    (server.endpoint, await ask(client, server, mode: mode, token: token))
                }
            }
            for await (endpoint, answer) in group {
                if !answer.posts.isEmpty { collected.append(answer.posts) }
                if let failure = answer.failure { failures[endpoint] = failure }
            }
        }
        await record(failures, from: reached, refresh: refresh, now: now)

        let posts = switch mode {
        case .timeline: collected.flatMap { $0 }.merged()
        case .trending: Self.mergedByRank(collected)
        }
        return TimelineResult(posts: posts, failures: failures, skipped: skipped)
    }

    /// What one server handed over, and separately what went wrong — a store that would not
    /// keep the posts is a failure worth reporting, but the posts still arrived.
    private typealias Answer = (posts: [Post], failure: SourceFailure?)

    /// How one server is asked: as `token`'s owner, and — where that is turned down — once
    /// more as nobody. The whole of the retry policy is here, so the fan-out above only has
    /// to name the servers and collect what each one answered.
    private func ask(_ client: any SourceClient, _ server: Server, mode: FeedMode, token: String?) async -> Answer {
        let signedIn = await read(client, server, mode: mode, token: token)
        // A token the server turned down is the account's problem, not the server's, so the
        // same read goes out once more as a stranger and the column shows whatever anyone
        // would see. What is reported stays `.tokenRejected`, so the screen marks the account
        // rather than the server — and stays one failure for this server on this load, so a
        // backoff counting failures per server never counts the retry as a second.
        guard case .tokenRejected? = signedIn.failure else { return signedIn }
        let anonymous = await read(client, server, mode: mode, token: nil)
        // A retry that read fine but would not store replaces `.tokenRejected` with `.store`,
        // and the account goes unmarked this round. That is the trade taken knowingly: one
        // host can only carry one reason, and the store failing is the newer news. It heals
        // by itself — nothing was reported, so nothing told `TokenSource` to stop sending the
        // credential, and the next load carries it again and is rejected again.
        guard anonymous.failure == nil else { return anonymous }
        return (anonymous.posts, signedIn.failure)
    }

    /// One request to one server as `token`'s owner, and what it handed over kept.
    private func read(_ client: any SourceClient, _ server: Server, mode: FeedMode, token: String?) async -> Answer {
        let posts: [Post]
        do {
            posts = switch mode {
            case .timeline: try await client.timeline(host: server.host, limit: limit, token: token)
            case .trending: try await client.trending(host: server.host, limit: limit, token: token)
            }
        } catch let failure as SourceFailure {
            return ([], failure)
        } catch {
            return ([], .transport(error.localizedDescription))
        }
        do {
            try await store?.save(posts, from: server)
            if mode == .trending { try await store?.recordTrending(posts, from: server) }
        } catch {
            // What SQLite said, in full, is for the log; the screen gets the message.
            LocalStore.log.error("save failed for \(server.host, privacy: .public): \(String(describing: error), privacy: .public)")
            let reason = (error as? DatabaseError)?.message ?? error.localizedDescription
            return (posts, .store(reason))
        }
        return (posts, nil)
    }

    /// Which of `servers` this load is allowed to ask, and which of them it is leaving
    /// alone. Everyone is asked where the reader asked; everyone not still inside a wait
    /// where the clock did — which is also everyone, almost always, so the healthy load
    /// does no work, and allocates nothing, to find that out.
    private func askable(_ servers: [Server], refresh: Refresh,
                         now: Date) async -> (asked: [Server], skipped: Set<String>) {
        guard case .automatic = refresh else { return (servers, []) }
        let blocked = await backoff.blocked(at: now)
        guard !blocked.isEmpty else { return (servers, []) }
        return (servers.filter { !blocked.contains($0.endpoint) },
                blocked.intersection(servers.map(\.endpoint)))
    }

    /// What this load's answers do to how long each server is left alone next time.
    ///
    /// Whether an answer arrived at all is `SourceFailure.arrivedAnyway`'s to say, so the
    /// rule lives with the cases rather than here. Silence is what a wait is for; anything
    /// that arrived forgives whatever wait had been building.
    ///
    /// Only the clock lengthens the clock's wait. A reader who asked and got nothing has not
    /// made a schedule for anybody — but their answer still forgives, so pulling to refresh
    /// brings a server back at once.
    private func record(_ failures: [String: SourceFailure], from reached: Set<String>,
                        refresh: Refresh, now: Date) async {
        var answered: Set<String> = []
        var silent: Set<String> = []
        for endpoint in reached {
            guard let failure = failures[endpoint] else { answered.insert(endpoint); continue }
            if case .tokenRejected = failure {
                // The credential is spent; sending it again every refresh is asking a server
                // to say no on a timer. The read still goes out, as a stranger.
                await tokenSource?.markRejected(endpoint)
            }
            if failure.arrivedAnyway { answered.insert(endpoint) } else { silent.insert(endpoint) }
        }
        if !answered.isEmpty { await backoff.answered(answered) }
        guard case .automatic(let every) = refresh, !silent.isEmpty else { return }
        await backoff.failed(silent, base: every, at: now)
    }

    /// The access token to read each of `servers` as. `TokenSource` answers who is signed in
    /// and what proves it; a read with no token here goes out as a stranger, which is what
    /// it did before anyone signed in.
    private func tokensByEndpoint(for servers: [Server]) async -> [String: String] {
        guard let tokenSource else { return [:] }
        return await tokenSource.tokens(for: servers).mapValues(\.accessToken)
    }

    /// Several servers' trending lists as one: a post's rank is its index in its server's
    /// list, a post on several lists takes its best rank and keeps every source, and the
    /// rest of the order (newest first, then `mergeKey`) only breaks ties the servers did not.
    static func mergedByRank(_ lists: [[Post]]) -> [Post] {
        var ranks: [String: Int] = [:]
        for list in lists {
            for (rank, post) in list.enumerated() {
                ranks[post.mergeKey] = min(ranks[post.mergeKey] ?? rank, rank)
            }
        }
        return lists.flatMap { $0 }.merged(orderedBy: {
            let (a, b) = (ranks[$0.mergeKey]!, ranks[$1.mergeKey]!)
            if a != b { return a < b }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.mergeKey < $1.mergeKey
        })
    }

    /// The only thing between what arrived and what you see. It adds and removes; it never moves.
    public static func apply(showBoosts: Bool, mediaOnly: Bool, to posts: [Post]) -> [Post] {
        posts.filter { post in
            if !showBoosts, post.isBoost { return false }
            if mediaOnly, post.mediaURLs.isEmpty { return false }
            return true
        }
    }
}
