import Foundation

public struct MastodonClient: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    public func publicTimeline(source: Source) async throws -> [Note] {
        try await statuses(
            path: "/api/v1/timelines/public",
            limit: 40,
            source: source,
            origin: .publicTimeline
        )
    }

    public func trending(source: Source) async throws -> [Note] {
        try await statuses(
            path: "/api/v1/trends/statuses",
            limit: 20,
            source: source,
            origin: .trending
        )
    }

    private func statuses(
        path: String,
        limit: Int,
        source: Source,
        origin: FetchOrigin
    ) async throws -> [Note] {
        guard let url = Host.httpsURL(
            host: host,
            path: path,
            query: [URLQueryItem(name: "limit", value: String(limit))]
        ) else {
            throw MastodonRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonRequestError.http(response.statusCode)
        }
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data).map {
            $0.asNote(source: source, origin: origin)
        }
    }
}

enum MastodonRequestError: Error, Equatable {
    case invalidURL
    case http(Int)
}

enum MastodonJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()

    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}

struct StatusDTO: Decodable, Sendable {
    let id: String
    let uri: String?
    let url: String?
    let createdAt: Date
    let content: String
    let account: Account
    let reblog: Box<StatusDTO>?
    let inReplyToId: String?
    let mentions: [Mention]?
    let visibility: String?
    let repliesCount: Int?
    let reblogsCount: Int?
    let favouritesCount: Int?
    let mediaAttachments: [MediaAttachment]?

    struct Account: Decodable, Sendable {
        let displayName: String
        let acct: String
        let username: String?
        let avatar: String?
    }

    struct Mention: Decodable, Sendable {
        let acct: String
    }

    struct MediaAttachment: Decodable, Sendable {
        let previewUrl: String?
        let url: String?
    }

    func asNote(source: Source, origin: FetchOrigin) -> Note {
        let subject = reblog?.value ?? self
        let host = source.host
        return Note(
            id: subject.uri ?? "https://\(host)/statuses/\(subject.id)",
            source: source,
            author: subject.account.name,
            handle: Self.handle(subject.account.acct, host: host),
            body: HTMLText.plain(subject.content),
            postedAt: subject.createdAt,
            origins: [origin],
            reply: Self.reply(inReplyToId: subject.inReplyToId, mentions: subject.mentions, host: host),
            boostedBy: reblog == nil ? nil : account.name,
            audience: Self.audience(subject.visibility),
            avatarURL: subject.account.avatar.flatMap(URL.init(string:)),
            previewURL: subject.mediaAttachments?.first?.previewUrl.flatMap(URL.init(string:)),
            url: subject.url.flatMap(URL.init(string:)),
            counts: Counts(
                replies: subject.repliesCount,
                reblogs: subject.reblogsCount,
                favourites: subject.favouritesCount
            )
        )
    }

    static func handle(_ acct: String, host: String) -> String {
        acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
    }

    private static func reply(inReplyToId: String?, mentions: [Mention]?, host: String) -> Reply? {
        guard inReplyToId != nil else { return nil }
        if let acct = mentions?.first?.acct {
            return Reply(handle: handle(acct, host: host))
        }
        return Reply(handle: nil)
    }

    private static func audience(_ visibility: String?) -> Audience? {
        switch visibility {
        case "public": .everyone
        case "unlisted": .unlisted
        case "private": .followers
        case "direct": .mentioned
        default: nil
        }
    }
}

extension StatusDTO.Account {
    var name: String {
        displayName.isEmpty ? (username ?? acct) : displayName
    }
}

/// `reblog` nests a status inside itself; a class box keeps the type finite.
final class Box<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped
    init(from decoder: any Decoder) throws {
        value = try Wrapped(from: decoder)
    }
}
