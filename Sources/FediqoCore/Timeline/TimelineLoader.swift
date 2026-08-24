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

    public init(posts: [Post], failures: [String: SourceFailure]) {
        self.posts = posts
        self.failures = failures
    }

    public var isEmpty: Bool { posts.isEmpty }
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
    private let secrets: any SecretStore

    /// With a `store`, what each server hands over is kept before it is merged; without one,
    /// nothing is remembered between loads — and nobody is signed in either, so a loader
    /// without a store reads every server as a stranger and never opens `secrets`.
    public init(registry: SourceRegistry = .standard(), limit: Int = 40, store: LocalStore? = nil,
                secrets: any SecretStore = KeychainSecretStore()) {
        self.registry = registry
        self.limit = limit
        self.store = store
        self.secrets = secrets
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

    public func load(servers: [Server], mode: FeedMode) async -> TimelineResult {
        var failures: [String: SourceFailure] = [:]
        var collected: [[Post]] = []
        // Once per load, not once per server: the rows and the Keychain are asked before
        // anything is asked of the network.
        let tokens = await tokensByEndpoint()

        // Each task answers with what arrived and, separately, what went wrong — a store that
        // would not keep the posts is a failure worth reporting, but the posts still arrived.
        await withTaskGroup(of: Turn.self) { group in
            for server in servers {
                guard let client = registry.client(for: server.socialProtocol) else {
                    failures[server.endpoint] = .unsupported(server.socialProtocol)
                    continue
                }
                let token = tokens[server.endpoint]
                group.addTask {
                    let signedIn = await ask(client, server, mode: mode, token: token)
                    // A token the server turned down is the account's problem, not the
                    // server's, so the same read goes out once more as a stranger and the
                    // column shows whatever anyone would see. What is reported stays
                    // `.tokenRejected`, so the screen marks the account rather than the
                    // server — and stays one failure for this server on this load, so a
                    // backoff counting failures per server never counts the retry as a second.
                    guard case .tokenRejected? = signedIn.failure else { return signedIn }
                    let anonymous = await ask(client, server, mode: mode, token: nil)
                    // A retry that read fine but would not store replaces `.tokenRejected`
                    // with `.store`, and the account goes unmarked this round. That is the
                    // trade taken knowingly: one host can only carry one reason, and the
                    // store failing is the newer news. It heals by itself — the next load
                    // asks as the account again and is rejected again, and the launch check
                    // marks it regardless of what any load reported.
                    guard anonymous.failure == nil else { return anonymous }
                    return (server.endpoint, anonymous.posts, signedIn.failure)
                }
            }
            for await (endpoint, posts, failure) in group {
                if !posts.isEmpty { collected.append(posts) }
                if let failure { failures[endpoint] = failure }
            }
        }

        let posts = switch mode {
        case .timeline: collected.flatMap { $0 }.merged()
        case .trending: Self.mergedByRank(collected)
        }
        return TimelineResult(posts: posts, failures: failures)
    }

    /// One server's turn: what arrived from it, and separately what went wrong. Named by
    /// its endpoint, so two protocols on one hostname stay two servers.
    private typealias Turn = (endpoint: String, posts: [Post], failure: SourceFailure?)

    /// Read one server as `token`'s owner, then keep what it handed over. Written apart from
    /// the task above because a rejected token asks it a second time, as nobody.
    private func ask(_ client: any SourceClient, _ server: Server, mode: FeedMode, token: String?) async -> Turn {
        let posts: [Post]
        do {
            posts = switch mode {
            case .timeline: try await client.timeline(host: server.host, limit: limit, token: token)
            case .trending: try await client.trending(host: server.host, limit: limit, token: token)
            }
        } catch let failure as SourceFailure {
            return (server.endpoint, [], failure)
        } catch {
            return (server.endpoint, [], .transport(error.localizedDescription))
        }
        do {
            try await store?.save(posts, from: server)
            if mode == .trending { try await store?.recordTrending(posts, from: server) }
        } catch {
            // What SQLite said, in full, is for the log; the screen gets the message.
            LocalStore.log.error("save failed for \(server.host, privacy: .public): \(String(describing: error), privacy: .public)")
            let reason = (error as? DatabaseError)?.message ?? error.localizedDescription
            return (server.endpoint, posts, .store(reason))
        }
        return (server.endpoint, posts, nil)
    }

    /// The token to read each server as, keyed by the endpoint that owns the account — the
    /// rows say who is signed in where, the Keychain says what proves it. A store that cannot
    /// be read, or a secret that cannot be fetched, costs the token and nothing else: the
    /// read goes out as a stranger, which is what it did before anyone signed in.
    private func tokensByEndpoint() async -> [String: String] {
        guard let store else { return [:] }
        do {
            return try await store.signedInByServer().reduce(into: [:]) { tokens, entry in
                do {
                    tokens[entry.key] = try secrets.token(for: entry.value.authorId)?.accessToken
                } catch {
                    LocalStore.log.error("token lookup failed for \(entry.key, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            LocalStore.log.error("signed-in lookup failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
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
