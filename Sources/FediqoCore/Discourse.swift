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

    /// The front page, newest topic first.
    ///
    /// **`order=created`, not the default.** `/latest.json` on its own is ordered by the last
    /// activity, and a row stores when the topic was created — so a topic bumped by today's reply
    /// would take a place on the page that belongs to one posted today, and push it off.
    ///
    /// The category names are fetched beside it and are **allowed to fail**. A forum that will not
    /// answer `/site.json` — an old version, a plugin, a permission — still has a readable front
    /// page, and a topic with no section named is a topic with one less line on it rather than a
    /// topic nobody can read.
    public func latest(source: Source) async throws -> [Note] {
        async let sections: [Int: String] = {
            do {
                return try await categories()
            } catch {
                // Lifted out ahead of the swallow, and through `Cancellation.happened`: a reader
                // who walked away arrives here looking exactly like a forum with no `/site.json`,
                // and the difference is that one of them is still waiting for a timeline.
                if Cancellation.happened(error) { throw CancellationError() }
                return [:]
            }
        }()

        guard let url = Host.httpsURL(
            host: host,
            path: "/latest.json",
            query: [URLQueryItem(name: "order", value: "created")]
        ) else {
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

    /// One topic read again (#29): `/t/{id}.json`, as the row `latest` draws for it, with the
    /// opening post's own words for its body and the reply count as the post stream has it now.
    /// `board` is the section name the held row carries — this read names its section by number
    /// only, and `/site.json` is not asked a second time for it.
    public func topic(_ id: Int, source: Source, board: String?) async throws -> Note {
        guard let url = Host.httpsURL(host: host, path: "/t/\(id).json") else {
            throw DiscourseRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        try Self.check(response.statusCode)
        return try DiscourseJSON.decoder.decode(TopicDTO.self, from: data)
            .asNote(source: source, host: host, board: board)
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

    /// What this forum says about itself: `/site/basic-info.json`, with `/about.json` beside it.
    ///
    /// **`/site/basic-info.json` and not `/site.json`**, which is the document `categories()`
    /// above reads and the obvious thing to reach for. `/site.json` is the Ember bootstrap
    /// payload — 285 KB measured, carrying every category, every group and every setting the web
    /// client needs — and it has neither the forum's title nor its description in it. Basic-info
    /// is 873 bytes, is in Discourse's own OpenAPI specification with `security: none`, and is
    /// never gated. Spending a third of a megabyte of somebody's bandwidth to not get the two
    /// fields the preview exists to show is the trade this comment is here to stop being made
    /// again.
    ///
    /// **The counts are fetched beside it and are allowed to fail**, which is `latest` above, word
    /// for word and for the same reason: a forum that will not answer `/about.json` — an old
    /// version, a plugin, a permission — still has a name and a description, and a preview
    /// missing two numbers is a preview with two fewer lines rather than one nobody can read.
    ///
    /// `activeMonth` and `registration` come back nothing and `rules` empty, because Discourse has
    /// no such idea — see `SourceProfile.activeMonth`.
    public func profile() async throws -> SourceProfile {
        async let counts: AboutDTO.Stats? = {
            do {
                return try await about()
            } catch {
                // **Through `Cancellation.happened` rather than `catch is CancellationError`.**
                // The second was what `latest` above wrote until unit 1b, and against a real
                // `URLSession` it never fires: a cancelled transfer arrives as
                // `URLError(.cancelled)`, falls into the swallow below, and the preview then
                // returns a profile — for a reader who is no longer there — instead of the
                // `CancellationError` `SourceProfiles.answer` promises in its signature. The
                // twin above now reads the same way; the two are deliberately identical.
                if Cancellation.happened(error) { throw CancellationError() }
                return nil
            }
        }()

        guard let url = Host.httpsURL(host: host, path: "/site/basic-info.json") else {
            // Nothing was asked, so nothing answered badly. `unreadable` would claim a
            // server sent something unreadable when no request was ever built.
            throw ProfileError.unreachable
        }
        let (data, response) = try await http.data(from: url)
        // The status before the body, for the reason `MastodonClient.profile` states: a forum
        // that does not have this endpoint answers with a page, not with JSON.
        guard (200..<300).contains(response.statusCode) else {
            throw ProfileError.of(status: response.statusCode)
        }
        let basic = try DiscourseJSON.decoder.decode(BasicInfoDTO.self, from: data)
        return basic.asProfile(host: host, stats: try await counts)
    }

    /// The forum's own numbers. Optional in every sense: the document may not answer, and the
    /// block inside it may not be there.
    private func about() async throws -> AboutDTO.Stats? {
        guard let url = Host.httpsURL(host: host, path: "/about.json") else {
            throw DiscourseRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        try Self.check(response.statusCode)
        return try DiscourseJSON.decoder.decode(AboutDTO.self, from: data).about?.stats
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
                // `/latest.json` is a cross-board listing: the topic names its section but did
                // not arrive through it, so it carries no category (#31).
                categories: [],
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
        static func attachments(_ raw: String?) -> [Attachment] {
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

/// `/t/{id}.json`: the topic, and its post stream's first page — the opening post first.
struct TopicDTO: Decodable, Sendable {
    let id: Int
    let title: String?
    let slug: String?
    let createdAt: Date?
    let postsCount: Int?
    let replyCount: Int?
    let likeCount: Int?
    let imageUrl: String?
    let postStream: PostStream

    struct PostStream: Decodable, Sendable {
        let posts: [Post]
    }

    struct Post: Decodable, Sendable {
        let postNumber: Int?
        let username: String?
        let name: String?
        let avatarTemplate: String?
        let cooked: String?
        let createdAt: Date?
    }

    /// The same row `LatestDTO.Topic.asNote` builds for this topic, under the same id.
    func asNote(source: Source, host: String, board: String?) -> Note {
        let opening = postStream.posts.first { $0.postNumber == 1 } ?? postStream.posts.first
        let username = opening?.username ?? ""
        return Note(
            id: "discourse:\(host):\(id)",
            source: source,
            author: opening?.name?.isEmpty == false ? opening!.name! : username,
            handle: username.isEmpty ? "" : "@\(username)@\(host)",
            body: HTMLText.plain(opening?.cooked ?? ""),
            title: (title?.isEmpty == false) ? title : nil,
            board: board,
            postedAt: createdAt ?? opening?.createdAt ?? .distantPast,
            categories: [],
            avatarURL: LatestDTO.Topic.avatarURL(opening?.avatarTemplate, host: host),
            attachments: LatestDTO.Topic.attachments(imageUrl),
            url: Host.httpsURL(host: host, path: "/t/\(slug ?? "topic")/\(id)"),
            counts: Counts(
                replies: replyCount ?? postsCount.map { max($0 - 1, 0) },
                reblogs: nil,
                favourites: likeCount
            )
        )
    }
}

struct SiteDTO: Decodable, Sendable {
    let categories: [Category]?

    struct Category: Decodable, Sendable {
        let id: Int
        let name: String
    }
}

/// `/site/basic-info.json` — the small, ungated document a forum publishes about itself.
struct BasicInfoDTO: Decodable, Sendable {
    let title: String?
    let description: String?
    let logoUrl: String?
    let faviconUrl: String?
    /// Whether the forum shows nothing at all to a signed-out reader.
    let loginRequired: Bool?

    func asProfile(host: String, stats: AboutDTO.Stats?) -> SourceProfile {
        SourceProfile(
            host: host,
            kind: .discourse,
            title: title,
            summary: description,
            // The logo where the forum set one, and the favicon where it did not. Both are
            // absolute — Discourse builds them through its own `UrlHelper.absolute` — and both go
            // through the rule this package admits a stranger's addresses under.
            thumbnail: Host.fetchableURL(logoUrl) ?? Host.fetchableURL(faviconUrl),
            people: stats?.people,
            posts: stats?.posts,
            // Inverted at the boundary rather than at each reader: what a preview has to say is
            // whether this can be read, and `login_required` is the name of a setting.
            readsWithoutAccount: loginRequired.map { !$0 }
        )
    }
}

/// `/about.json`, for the two numbers a preview shows.
struct AboutDTO: Decodable, Sendable {
    let about: About?

    struct About: Decodable, Sendable {
        let stats: Stats?
    }

    /// **Two spellings of each count are read, and that is not belt and braces.** Discourse's
    /// about payload has carried both the singular `post_count`/`user_count` form and the plural
    /// `posts_count`/`users_count` form across its versions, and this app holds no capture of a
    /// running forum to settle which one the installs it meets send (`f421fea`). Getting it wrong
    /// is invisible: the document is allowed to fail, so a key that never matches looks exactly
    /// like a forum that did not answer, and the preview quietly shows two fewer lines forever.
    /// Two Optionals and a `??` cost less than that silence.
    struct Stats: Decodable, Sendable {
        let userCount: Int?
        let usersCount: Int?
        let postCount: Int?
        let postsCount: Int?

        var people: Int? { userCount ?? usersCount }
        var posts: Int? { postCount ?? postsCount }
    }
}
