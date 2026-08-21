import Foundation

public struct SuggestedServer: Sendable, Hashable, Identifiable {
    public let host: String
    public let summary: String
    public let region: String?
    public let totalUsers: Int?
    public let languages: [String]

    public var id: String { host }

    public init(host: String, summary: String, region: String? = nil, totalUsers: Int? = nil, languages: [String] = []) {
        self.host = host
        self.summary = summary
        self.region = region
        self.totalUsers = totalUsers
        self.languages = languages
    }
}

/// Where the suggested-server list comes from, so the picker can say it on screen.
public enum DirectoryOrigin: Sendable, Hashable {
    /// `api.joinmastodon.org` — the list the official server picker uses.
    case joinMastodon
    /// The short list compiled into this build, used when the directory cannot be reached.
    case builtIn
}

public struct DirectoryResult: Sendable {
    public let origin: DirectoryOrigin
    public let servers: [SuggestedServer]
}

/// Fetches the suggested-server list.
///
/// This is the one request in the app that goes somewhere other than a server the user
/// chose, so it is confined to the picker, happens only when the picker is opened, and
/// falls back to a compiled-in list rather than blocking the flow.
public struct ServerDirectory: Sendable {
    private let session: URLSession
    private let endpoint: URL

    public static let joinMastodon = URL(string: "https://api.joinmastodon.org/servers")!

    public init(session: URLSession = .shared, endpoint: URL = ServerDirectory.joinMastodon) {
        self.session = session
        self.endpoint = endpoint
    }

    public func suggested(limit: Int = 12) async -> DirectoryResult {
        guard let servers = try? await fetch(), !servers.isEmpty else {
            return DirectoryResult(origin: .builtIn, servers: Array(Self.builtIn.prefix(limit)))
        }
        let ranked = servers
            .sorted { ($0.totalUsers ?? 0) > ($1.totalUsers ?? 0) }
            .prefix(limit)
        return DirectoryResult(origin: .joinMastodon, servers: Array(ranked))
    }

    /// The directory's own decoder, shared with the test that pins its shape: reading this
    /// list wrongly once already looked exactly like being offline.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func fetch() async throws -> [SuggestedServer] {
        let data = try await JSONTransport.get(endpoint, on: session, timeout: 10)
        return try Self.decoder.decode([Entry].self, from: data).map(\.asSuggestion)
    }

    struct Entry: Decodable {
        let domain: String
        let description: String?
        let region: String?
        let languages: [String]?
        let totalUsers: Int?

        var asSuggestion: SuggestedServer {
            SuggestedServer(
                host: domain,
                summary: HTMLText.plain(description ?? ""),
                region: (region?.isEmpty ?? true) ? nil : region,
                totalUsers: totalUsers,
                languages: languages ?? []
            )
        }
    }

    /// Enough to get started with no network, and small enough to stay honest about being a guess.
    public static let builtIn: [SuggestedServer] = [
        SuggestedServer(host: "mastodon.social", summary: "The server run by the Mastodon project itself.", languages: ["en"]),
        SuggestedServer(host: "mastodon.online", summary: "The Mastodon project's second general-purpose server.", languages: ["en"]),
        SuggestedServer(host: "g0v.social", summary: "Taiwanese civic-tech community.", region: "asia", languages: ["zh"]),
        SuggestedServer(host: "mstdn.jp", summary: "A large Japanese general-purpose server.", region: "asia", languages: ["ja"]),
        SuggestedServer(host: "fosstodon.org", summary: "Free and open source software.", languages: ["en"]),
        SuggestedServer(host: "hachyderm.io", summary: "Technology professionals.", languages: ["en"]),
    ]
}
