import Foundation

/// Which stream a screen is asking for. They are two different things and neither stands in
/// for the other: the timeline is the timeline, and trending is a place you go to.
///
/// The raw values name the screens too, so a mode carries its own titles rather than having
/// them handed to it.
public enum FeedMode: String, Sendable {
    case timeline
    case trending
}

public struct TimelineResult: Sendable {
    /// One row per post, in timestamp order. Never ranked, never re-ordered.
    public let posts: [Post]
    /// Servers that gave nothing, and why. Reported rather than substituted for.
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
public struct TimelineLoader: Sendable {
    private let registry: SourceRegistry
    private let limit: Int

    public init(registry: SourceRegistry = .standard(), limit: Int = 40) {
        self.registry = registry
        self.limit = limit
    }

    public func load(servers: [Server], mode: FeedMode) async -> TimelineResult {
        var failures: [String: SourceFailure] = [:]
        var collected: [Post] = []

        await withTaskGroup(of: (String, Result<[Post], SourceFailure>).self) { group in
            for server in servers {
                guard let client = registry.client(for: server.socialProtocol) else {
                    failures[server.host] = .unsupported(server.socialProtocol)
                    continue
                }
                group.addTask {
                    do {
                        let posts = switch mode {
                        case .timeline: try await client.timeline(host: server.host, limit: limit)
                        case .trending: try await client.trending(host: server.host, limit: limit)
                        }
                        return (server.host, .success(posts))
                    } catch let failure as SourceFailure {
                        return (server.host, .failure(failure))
                    } catch {
                        return (server.host, .failure(.transport(error.localizedDescription)))
                    }
                }
            }
            for await (host, result) in group {
                switch result {
                case .success(let posts): collected.append(contentsOf: posts)
                case .failure(let failure): failures[host] = failure
                }
            }
        }

        return TimelineResult(posts: collected.merged(), failures: failures)
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
