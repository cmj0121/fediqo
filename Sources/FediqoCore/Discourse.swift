import Foundation

/// A forum, read the way this app reads everything else: one unauthenticated GET of a documented
/// endpoint, and what comes back turned into `Note`s.
///
/// **A forum is a different shape, not a different question.** A microblog's timeline is a list of
/// what people wrote; a forum's is a list of *discussions*, each with a name, a section it was
/// posted in and a count of how many have answered. `Note` grew a `title` and a `board` for that,
/// and a row that already knew how to draw a thread draws this one.
///
/// **What is read, and what is not.** `/latest.json` is the front page, and it is the whole of the
/// timeline: it carries the topics and, beside them, the handful of people who wrote in them.
/// `/site.json` is read once for the category names, because a topic names its section by number
/// and a number is not something to show a reader. Nothing else is asked for — no per-topic fetch,
/// no post bodies, no search — because the front page is what a reader opened the app to see and
/// every extra request is a stranger's bandwidth spent on something nobody asked for yet.
public struct DiscourseClient: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    /// The front page: the most recently active discussions, newest activity first.
    ///
    /// The category names are fetched beside it and are **allowed to fail**. A forum that will not
    /// answer `/site.json` — an old version, a plugin, a permission — still has a readable front
    /// page, and a topic with no section named is a topic with one less line on it rather than a
    /// topic nobody can read.
    public func latest(source: Source) async throws -> [Note] {
        async let sections: [Int: String] = {
            do {
                return try await categories()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return [:]
            }
        }()

        guard let url = Host.httpsURL(host: host, path: "/latest.json") else {
            throw DiscourseRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        try Self.check(response.statusCode)

        let page = try DiscourseJSON.decoder.decode(LatestDTO.self, from: data)
        let people = Dictionary(page.users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let named = try await sections
        return page.topicList.topics.map {
            $0.asNote(source: source, host: host, people: people, sections: named)
        }
    }

    /// Every category this forum has, by the number a topic names it with.
    ///
    /// `/site.json` rather than `/categories.json`: the first is one document a client is expected
    /// to read at startup and the second is paginated, so reading the second properly means a loop
    /// over a stranger's server for names that fit in one answer.
    public func categories() async throws -> [Int: String] {
        guard let url = Host.httpsURL(host: host, path: "/site.json") else {
            throw DiscourseRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        try Self.check(response.statusCode)
        let site = try DiscourseJSON.decoder.decode(SiteDTO.self, from: data)
        return Dictionary(
            (site.categories ?? []).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Turns a status code into the one distinction that changes what a reader should be told.
    ///
    /// **A challenge is not a 404 and must not be reported as one.** A forum sitting behind a
    /// filter that has decided this app is a robot answers 403, and sometimes 503 or 429 with a
    /// page of HTML; a forum that simply does not have the endpoint answers 404. The first is a
    /// door the owner closed and the reader may be able to open with a key; the second is a host
    /// that is not a forum. Telling a reader to check their spelling when the truth is "that
    /// server refused us" sends them to look for a fault that is not theirs.
    static func check(_ status: Int) throws {
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 401, 403, 429, 503: throw DiscourseRequestError.refused(status)
        default: throw DiscourseRequestError.http(status)
        }
    }
}

public enum DiscourseRequestError: Error, Equatable, Sendable {
    case invalidURL
    /// The server answered with a status that says no, in the way a filter says it. See `check`.
    case refused(Int)
    case http(Int)
}

enum DiscourseJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Discourse sends the same ISO 8601 Mastodon does, fractional seconds and all, so the
        // parsing that was already written and already tested is the parsing used here.
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = MastodonJSON.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()
}

struct LatestDTO: Decodable, Sendable {
    let users: [User]
    let topicList: TopicList

    struct TopicList: Decodable, Sendable {
        let topics: [Topic]
    }

    struct User: Decodable, Sendable {
        let id: Int
        let username: String
        let name: String?
        /// Where this person's picture is, with `{size}` still in it. See `avatarURL`.
        let avatarTemplate: String?
    }

    struct Poster: Decodable, Sendable {
        let userId: Int?
        /// What this person did in the topic, in the forum's own words — "Original Poster",
        /// "Most Recent Poster". Read rather than assumed, because the list is ordered by
        /// recency on some forums and by role on others.
        let description: String?
    }

    struct Topic: Decodable, Sendable {
        let id: Int
        let title: String?
        let slug: String?
        let createdAt: Date?
        let bumpedAt: Date?
        let postsCount: Int?
        let replyCount: Int?
        let likeCount: Int?
        let categoryId: Int?
        let excerpt: String?
        let imageUrl: String?
        let posters: [Poster]?

        /// Who to put on the row: whoever the forum called the original poster, and the first
        /// person listed where it named nobody.
        ///
        /// **Not the most recent poster**, though that is who the front page is ordered by. A row
        /// says who wrote a thing; attributing a discussion to the last person who answered in it
        /// puts a stranger's name on somebody else's question.
        var author: Int? {
            guard let posters, !posters.isEmpty else { return nil }
            let original = posters.first {
                $0.description?.range(of: "Original Poster", options: .caseInsensitive) != nil
            }
            return (original ?? posters[0]).userId
        }

        func asNote(
            source: Source,
            host: String,
            people: [Int: LatestDTO.User],
            sections: [Int: String]
        ) -> Note {
            let person = author.flatMap { people[$0] }
            let username = person?.username ?? ""
            return Note(
                // Prefixed, because a forum's topic numbers and a microblog's status ids share
                // one store and `17` is a plausible id on both.
                id: "discourse:\(host):\(id)",
                source: source,
                author: person?.name?.isEmpty == false ? person!.name! : username,
                handle: username.isEmpty ? "" : "@\(username)@\(host)",
                // The excerpt where the forum sent one, and nothing where it did not — most of
                // `/latest.json` has none, and the title is what the reader is there to read.
                body: HTMLText.plain(excerpt ?? ""),
                title: (title?.isEmpty == false) ? title : nil,
                board: categoryId.flatMap { sections[$0] },
                // When it was written, not when it was last answered. The front page is ordered
                // by the second; a row that showed it would date somebody's question by a
                // stranger's reply.
                postedAt: createdAt ?? bumpedAt ?? .distantPast,
                origins: [.publicTimeline],
                avatarURL: Self.avatarURL(person?.avatarTemplate, host: host),
                attachments: Self.attachments(imageUrl),
                url: Host.httpsURL(host: host, path: "/t/\(slug ?? "topic")/\(id)"),
                counts: Counts(
                    // `reply_count` is answers; `posts_count` counts the question itself. The
                    // fallback subtracts it back off rather than quietly showing one more answer
                    // than the topic has.
                    replies: replyCount ?? postsCount.map { max($0 - 1, 0) },
                    reblogs: nil,
                    favourites: likeCount
                )
            )
        }

        /// The picture the forum chose for the topic, where there is one.
        ///
        /// No shape is sent with it, and `Attachment` is built to say so rather than to guess:
        /// nothing is not a square. The deck scales what arrives.
        private static func attachments(_ raw: String?) -> [Attachment] {
            guard let url = Host.fetchableURL(raw) else { return [] }
            return [Attachment(kind: .image, url: url, previewURL: url)]
        }

        /// A person's picture, at the one size the deck and the row ask for.
        ///
        /// Two things make this more than a string substitution. The template is **relative** —
        /// `/user_avatar/host/name/{size}/123_2.png` — so it is resolved against the forum;
        /// and it arrives from a stranger's JSON, so it goes through the same rule every other
        /// address in this package does and a `javascript:` template resolves to nothing.
        static func avatarURL(_ template: String?, host: String, size: Int = 96) -> URL? {
            guard let template, !template.isEmpty else { return nil }
            let path = template.replacingOccurrences(of: "{size}", with: String(size))
            if path.hasPrefix("/") { return Host.httpsURL(host: host, path: path) }
            return Host.fetchableURL(path)
        }
    }
}

struct SiteDTO: Decodable, Sendable {
    let categories: [Category]?

    struct Category: Decodable, Sendable {
        let id: Int
        let name: String
    }
}
