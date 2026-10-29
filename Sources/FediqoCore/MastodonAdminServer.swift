import Foundation

// A server's own page of tending (#384): what waits to rise on it — hashtags, links, posts —
// let rise or kept back; how it is doing, as a few of its own figures over a span; and its
// rules, read. Asked of a real one first (`MastodonAdminServerCaptures`).
//
// **What the server lists is everything rising it counted**, whether it lets it rise yet or
// not, each saying whether it waits for somebody to review it. A link or a post answered after
// a review says only that it no longer waits, not which way it went; a hashtag says which.
//
// **The figures are the server's**, each over whole days of its own calendar (UTC): the span
// asked ends the day after the last, since the server's total counts up to and not including
// its end day — though its day-by-day series includes it, which is why only totals are kept.
// A span of no days at all is not asked: a server answers it with a failure of its own.
//
// **The rules are not changed here**: the server has no way for that but its own page
// (`rulesPage`), where they are written, changed, ordered and taken off.

/// Which of what is rising: hashtags, links or posts.
public enum RisingKind: String, CaseIterable, Sendable {
    case tags, links, posts

    /// The word the server's address names it by.
    var path: String {
        switch self {
        case .tags: "tags"
        case .links: "links"
        case .posts: "statuses"
        }
    }
}

/// One of what is rising, as the server lists it to those who review it.
public struct RisingReview: Sendable, Hashable, Identifiable {
    public enum What: Sendable, Hashable {
        case tag(RisingTag)
        case link(RisingLink)
        case post(Note)
    }

    /// The server's id of it: what it is let rise or kept back by.
    public let id: String
    public let what: What
    /// Whether it waits for somebody to say whether it may rise.
    public let waiting: Bool
    /// Whether the server lets it rise — said of a hashtag only; nothing where it did not say.
    public let rises: Bool?

    public init(id: String, what: What, waiting: Bool, rises: Bool? = nil) {
        self.id = id
        self.what = what
        self.waiting = waiting
        self.rises = rises
    }

    public var kind: RisingKind {
        switch what {
        case .tag: .tags
        case .link: .links
        case .post: .posts
        }
    }
}

/// A stretch of what is rising: the next is asked from where this one ended, where there may be more.
public struct RisingStretch: Sendable, Equatable {
    public let items: [RisingReview]
    /// Where the next stretch starts, counted from the first; nothing where this was the last.
    public let next: Int?

    public init(items: [RisingReview], next: Int?) {
        self.items = items
        self.next = next
    }
}

/// One of the server's figures over a span.
public struct ServerMeasure: Sendable, Equatable, Identifiable {
    public enum Key: String, CaseIterable, Sendable {
        /// Who signed up.
        case joined = "new_users"
        /// Who was active.
        case active = "active_users"
        /// What was reported.
        case reported = "opened_reports"
    }

    public let key: Key
    public let total: Int
    /// The same over the span before, where the server says it.
    public let before: Int?

    public var id: Key { key }

    public init(key: Key, total: Int, before: Int? = nil) {
        self.key = key
        self.total = total
        self.before = before
    }
}

/// The server's figures over the last `days` days, as it said them `asOf`.
public struct ServerMeasures: Sendable, Equatable {
    public let days: Int
    public let asOf: Date
    public let measures: [ServerMeasure]

    public init(days: Int, asOf: Date, measures: [ServerMeasure]) {
        self.days = days
        self.asOf = asOf
        self.measures = measures
    }
}

/// What waits to rise on a Mastodon, its figures and its rules, read — and what rises let rise
/// or kept back — by those who answer for it (#384). **Only ever as the reader**, through the
/// signed-in door.
public struct MastodonAdminServer: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let trendsPath = "/api/v1/admin/trends"
    static let measuresPath = "/api/v1/admin/measures"
    /// How many are asked for at once: what a server gives at most for each.
    public static let stretch = 20
    /// The spans a person chooses among, in days.
    public static let spans = [7, 30, 90]

    // MARK: - What waits to rise

    /// A stretch of `kind`, from `offset`: the server's order, entry by entry — one this build
    /// cannot read is that one not listed.
    public func rising(_ kind: RisingKind, from offset: Int = 0) async throws -> RisingStretch {
        guard offset >= 0, offset < 10_000 else { throw MastodonAdminError.invalid }
        var query = [URLQueryItem(name: "limit", value: String(Self.stretch))]
        if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        let body = try await door.adminAsked { try await door.get(path: "\(Self.trendsPath)/\(kind.path)", query: query) }
        guard let reviews = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<ReviewDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let items: [RisingReview]
        switch kind {
        case .tags:
            let tags = (try? MastodonJSON.decoder.decode([StatusDTO.Lenient<MastodonRising.TagSaid>].self, from: body)) ?? []
            items = zip(reviews, tags).compactMap { review, tag in
                guard let review = review.value, let tag = tag.value else { return nil }
                return review.tag(tag)
            }
        case .links:
            let links = (try? MastodonJSON.decoder.decode([StatusDTO.Lenient<LinkDTO>].self, from: body)) ?? []
            items = zip(reviews, links).compactMap { review, link in
                guard let review = review.value, let link = link.value else { return nil }
                return review.link(link)
            }
        case .posts:
            let posts = (try? MastodonJSON.decoder.decode([StatusDTO.Lenient<StatusDTO>].self, from: body)) ?? []
            let source = Source(host: door.token.host, kind: .mastodon)
            let sent = ReadMoment.now()
            items = zip(reviews, posts).compactMap { review, post in
                guard let review = review.value, let post = post.value else { return nil }
                return review.post(post.arrival(source: source, categories: [], sent: sent).item)
            }
        }
        // A full stretch may be followed by more; the server names no next of its own.
        return RisingStretch(items: items, next: reviews.count >= Self.stretch ? offset + reviews.count : nil)
    }

    /// The one `id` of `kind` let rise — or, with `rise` false, kept back: what the server holds
    /// of it after.
    public func review(_ kind: RisingKind, _ id: String, rise: Bool) async throws -> RisingReview {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        let path = "\(Self.trendsPath)/\(kind.path)/\(id)/\(rise ? "approve" : "reject")"
        let body = try await door.adminWrite(path, "POST", form: [])
        guard let review = try? MastodonJSON.decoder.decode(ReviewDTO.self, from: body), review.named == id else {
            throw MastodonAdminError.unreadable
        }
        let read: RisingReview?
        switch kind {
        case .tags: read = (try? MastodonJSON.decoder.decode(MastodonRising.TagSaid.self, from: body)).flatMap(review.tag)
        case .links: read = (try? MastodonJSON.decoder.decode(LinkDTO.self, from: body)).flatMap(review.link)
        case .posts:
            let source = Source(host: door.token.host, kind: .mastodon)
            read = (try? MastodonJSON.decoder.decode(StatusDTO.self, from: body))
                .flatMap { review.post($0.arrival(source: source, categories: [], sent: .now()).item) }
        }
        guard let read else { throw MastodonAdminError.unreadable }
        // A link or a post answered says it no longer waits, not which way: the way asked is it.
        return RisingReview(id: read.id, what: read.what, waiting: read.waiting, rises: read.rises ?? rise)
    }

    // MARK: - Figures

    /// The server's figures over the last `days` days, the last of them the day `now` falls on
    /// by the server's calendar (UTC), said as of `now`.
    public func measures(days: Int, now: Date = Date()) async throws -> ServerMeasures {
        guard let span = Self.span(days: days, now: now) else { throw MastodonAdminError.invalid }
        let form = ServerMeasure.Key.allCases.map { ("keys[]", $0.rawValue) } + [("start_at", span.start), ("end_at", span.end)]
        let body = try await door.adminFigures(Self.measuresPath, form: form)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<MeasureDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        var seen = Set<ServerMeasure.Key>()
        let measures = read.compactMap { $0.value?.measure }.filter { seen.insert($0.key).inserted }
        return ServerMeasures(days: days, asOf: now, measures: ServerMeasure.Key.allCases.compactMap { key in measures.first { $0.key == key } })
    }

    /// The server's calendar: days of UTC.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The last `days` days, the last of them the day `now` falls on by the server's calendar,
    /// as the server is asked them: its first day, and the day after its last. Nothing for a
    /// span of no days, or of more than a year.
    static func span(days: Int, now: Date) -> (start: String, end: String)? {
        guard (1...366).contains(days) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today)
        else { return nil }
        return (day(start), day(end))
    }

    /// `date`'s day by the server's calendar, as it is asked (`2026-10-22`).
    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Rules

    /// The server's rules, in its order, as anyone may read them.
    public func rules() async throws -> [ServerRule] {
        do {
            return try await MastodonReports(door: door).rules()
        } catch MastodonReportError.unreadable {
            throw MastodonAdminError.unreadable
        }
    }

    /// The server's own page of its rules, where they are written, changed, ordered and taken off.
    public static func rulesPage(host: String) -> URL? {
        Host.httpsURL(host: host, path: "/admin/rules")
    }

    // MARK: - The wire

    /// What every one of the three says of its review: its id — a number for a link — whether
    /// it waits, and, of a hashtag, whether it may rise.
    struct ReviewDTO: Decodable, Sendable {
        let id: MastodonFigure?
        let textID: String?
        let requiresReview: StatusDTO.Lenient<Bool>?
        let trendable: StatusDTO.Lenient<Bool>?

        private enum Keys: String, CodingKey { case id, requiresReview, trendable }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            textID = try? container.decode(String.self, forKey: .id)
            id = try? container.decode(MastodonFigure.self, forKey: .id)
            requiresReview = try? container.decode(StatusDTO.Lenient<Bool>.self, forKey: .requiresReview)
            trendable = try? container.decode(StatusDTO.Lenient<Bool>.self, forKey: .trendable)
        }

        /// The id as it stands in an address: the server's words for it, or its number.
        var named: String? {
            let named = textID ?? id?.value.map(String.init)
            return named.flatMap { ListSubscription.isPathSegment($0) ? $0 : nil }
        }

        private func made(_ what: RisingReview.What, rises: Bool? = nil) -> RisingReview? {
            named.map { RisingReview(id: $0, what: what, waiting: requiresReview?.value ?? false, rises: rises) }
        }

        func tag(_ said: MastodonRising.TagSaid) -> RisingReview? {
            guard said.name.unicodeScalars.count <= MastodonRising.nameLength, let tag = PostTag("#" + said.name) else { return nil }
            return made(.tag(RisingTag(tag: tag, use: MastodonRising.Day.use(said.history?.value))), rises: trendable?.value)
        }

        func link(_ said: LinkDTO) -> RisingReview? {
            guard said.url.utf8.count <= MastodonRising.addressLength, let link = MastodonRising.link(said.url) else { return nil }
            return made(.link(RisingLink(
                link: link, title: said.title?.value ?? "", words: said.description?.value ?? "",
                use: MastodonRising.Day.use(said.history?.value)
            )))
        }

        func post(_ note: Note) -> RisingReview? {
            made(.post(note))
        }
    }

    struct LinkDTO: Decodable, Sendable {
        let url: String
        let title: StatusDTO.Lenient<String>?
        let description: StatusDTO.Lenient<String>?
        let history: StatusDTO.Lenient<[StatusDTO.Lenient<MastodonRising.Day>]>?
    }

    struct MeasureDTO: Decodable, Sendable {
        let key: String
        let total: MastodonFigure?
        let previousTotal: MastodonFigure?

        var measure: ServerMeasure? {
            guard let key = ServerMeasure.Key(rawValue: key), let total = total?.value else { return nil }
            return ServerMeasure(key: key, total: total, before: previousTotal?.value)
        }
    }
}
