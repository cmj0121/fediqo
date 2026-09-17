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

    /// Whether this app has a list of servers to suggest for a protocol — the browser's second
    /// step, decision 19.
    ///
    /// **Here rather than in the UI, for the reason `SourceJoin.reads` is public.** This type *is*
    /// the only directory there is, so the answer is a fact about this file: a predicate written in
    /// a view would be a second answer to a question this module owns, and the day M3 adds a second
    /// directory the fetch and the predicate would change in two modules with the compiler linking
    /// neither.
    ///
    /// **A protocol with no list is a real state, and until M3 it is the majority one.** Three
    /// protocols are readable and exactly one of them has a directory behind it, so the browser's
    /// second step draws a sentence rather than an empty list.
    ///
    /// **No `default:`.** A protocol added has to say whether anything suggests servers for it,
    /// rather than inheriting Mastodon's yes and drawing joinmastodon's Mastodons under the name of
    /// a forum.
    public static func covers(_ kind: ProtocolKind) -> Bool {
        switch kind {
        case .mastodon: true
        // Discourse and Discuz! publish no directory anybody aggregates, and the nine protocols
        // this app cannot read are not offered at all. M3's unit 9 is what changes this.
        case .discourse, .discuz, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube,
            .friendica, .gotosocial, .unknown:
            false
        }
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
