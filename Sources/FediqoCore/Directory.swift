import Foundation

public struct CatalogServer: Hashable, Sendable, Identifiable {
    public var id: String { domain }
    public let domain: String
    public let summary: String
    public let language: String
    public let region: String
    public let category: String
    /// Registered accounts. Not activity.
    public let users: Int
    /// Weekly active users from the directory (`last_week_users`).
    public let weekUsers: Int
    public let approvalRequired: Bool
    public let thumbnail: URL?

    public init(
        domain: String,
        summary: String,
        language: String,
        region: String,
        category: String,
        users: Int,
        weekUsers: Int,
        approvalRequired: Bool,
        thumbnail: URL?
    ) {
        self.domain = domain
        self.summary = summary
        self.language = language
        self.region = region
        self.category = category
        self.users = users
        self.weekUsers = weekUsers
        self.approvalRequired = approvalRequired
        self.thumbnail = thumbnail
    }
}

/// The joinmastodon catalog. Picks still go through join; this list does not fetch thumbnails.
public struct ServerDirectory: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func servers() async throws -> [CatalogServer] {
        guard let url = Host.httpsURL(host: "api.joinmastodon.org", path: "/servers") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try MastodonJSON.decoder.decode([Entry].self, from: data).map(\.asCatalog)
    }

    struct Entry: Decodable {
        let domain: String
        let description: String?
        let language: String?
        let region: String?
        let category: String?
        let totalUsers: Int?
        let lastWeekUsers: Int?
        let approvalRequired: Bool?
        let proxiedThumbnail: String?

        var asCatalog: CatalogServer {
            CatalogServer(
                domain: domain,
                summary: HTMLText.plain(description ?? ""),
                language: language ?? "",
                region: region ?? "",
                category: category ?? "",
                users: totalUsers ?? 0,
                weekUsers: lastWeekUsers ?? 0,
                approvalRequired: approvalRequired ?? false,
                thumbnail: proxiedThumbnail.flatMap(URL.init(string:))
            )
        }
    }
}
