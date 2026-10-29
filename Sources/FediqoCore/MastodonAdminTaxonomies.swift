import Foundation

// The hashtags a Mastodon knows and the sites its rising links come from (#419), read and let
// rise or kept back by those who answer for it. Asked of a real one first
// (`MastodonAdminTaxonomiesCaptures`); nothing here writes anywhere on this device, and every
// change answers with what the server now holds.
//
// **Every hashtag, not only what rises.** What waits to rise one at a time is
// `MastodonAdminServer.rising`; here each hashtag the server has ever seen is listed, and each
// is let rise or kept back, let be used in posts or not, and let be listed in its directory or
// not. A change marks it reviewed: it no longer waits.
//
// **A site is decided for all its links.** One kept back keeps every link from it from rising;
// one never decided says so — neither let rise nor kept back — until somebody does.

/// A hashtag as the server keeps it for those who answer for it.
public struct AdminTag: Sendable, Equatable, Identifiable {
    /// The server's id of it: what it is changed by.
    public let id: String
    /// The hashtag and how much it was used, day by day.
    public let tag: RisingTag
    /// Whether it may rise.
    public let rises: Bool
    /// Whether posts may carry it.
    public let usable: Bool
    /// Whether it is shown in the server's directory and its searches.
    public let listable: Bool
    /// Whether it waits for somebody to say whether it may rise.
    public let waiting: Bool

    public init(id: String, tag: RisingTag, rises: Bool, usable: Bool, listable: Bool, waiting: Bool) {
        self.id = id
        self.tag = tag
        self.rises = rises
        self.usable = usable
        self.listable = listable
        self.waiting = waiting
    }
}

/// A site the server's links come from.
public struct LinkSite: Sendable, Equatable, Identifiable {
    /// The server's id of it: what it is let rise or kept back by.
    public let id: String
    public let domain: String
    /// Whether its links may rise; nothing where nobody has said yet.
    public let rises: Bool?
    /// Whether it waits for somebody to say.
    public let waiting: Bool
    /// When somebody last said.
    public let reviewedAt: Date?

    public init(id: String, domain: String, rises: Bool?, waiting: Bool, reviewedAt: Date? = nil) {
        self.id = id
        self.domain = domain
        self.rises = rises
        self.waiting = waiting
        self.reviewedAt = reviewedAt
    }
}

/// The hashtags a Mastodon knows and the sites its links come from, read and changed by those
/// who answer for it (#419). **Only ever as the reader**, through the signed-in door.
public struct MastodonAdminTaxonomies: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let tagsPath = "/api/v1/admin/tags"
    static let sitesPath = "/api/v1/admin/trends/links/publishers"

    // MARK: - Hashtags

    /// A stretch of the hashtags the server knows, newest first.
    public func tags(after next: String? = nil) async throws -> FederationStretch<AdminTag> {
        try await list(Self.tagsPath, after: next) { (said: TagDTO) in said.tag }
    }

    public func tag(_ id: String) async throws -> AdminTag {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        let body = try await asked { try await door.get(path: "\(Self.tagsPath)/\(id)", query: []) }
        return try read(body) { (said: TagDTO) in said.tag }
    }

    /// The hashtag `id` let rise or kept back, let be used or not, let be listed or not — each
    /// left as it is where it is not named: what the server holds of it after.
    public func changeTag(_ id: String, rises: Bool? = nil, usable: Bool? = nil, listable: Bool? = nil) async throws -> AdminTag {
        let form = [("trendable", rises), ("usable", usable), ("listable", listable)]
            .compactMap { name, value in value.map { (name, String($0)) } }
        guard ListSubscription.isPathSegment(id), !form.isEmpty else { throw MastodonAdminError.invalid }
        return try read(try await write("\(Self.tagsPath)/\(id)", "PUT", form: form)) { (said: TagDTO) in said.tag }
    }

    // MARK: - Sites

    /// A stretch of the sites the server's links come from, newest first.
    public func sites(after next: String? = nil) async throws -> FederationStretch<LinkSite> {
        try await list(Self.sitesPath, after: next) { (said: SiteDTO) in said.site }
    }

    /// The site `id` let rise — or, with `rise` false, kept back, and every link from it with
    /// it: what the server holds of it after.
    public func reviewSite(_ id: String, rise: Bool) async throws -> LinkSite {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        let body = try await write("\(Self.sitesPath)/\(id)/\(rise ? "approve" : "reject")", "POST", form: [])
        return try read(body) { (said: SiteDTO) in said.site }
    }

    // MARK: - The wire

    private func list<DTO: Decodable & Sendable, Item: Sendable & Equatable>(
        _ path: String, after next: String?, _ made: (DTO) -> Item?
    ) async throws -> FederationStretch<Item> {
        let (body, link) = try await asked { try await door.getLinked(path: path, query: try MastodonPage.older(than: next)) }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<DTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonAdminError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        return FederationStretch(items: read.compactMap { $0.value.flatMap(made) }, next: onward)
    }

    private func read<DTO: Decodable, Item>(_ body: Data, _ made: (DTO) -> Item?) throws -> Item {
        guard let said = try? MastodonJSON.decoder.decode(DTO.self, from: body), let item = made(said) else {
            throw MastodonAdminError.unreadable
        }
        return item
    }

    private func write(_ path: String, _ method: String, form: [(String, String)]) async throws -> Data {
        try await asked {
            do {
                return try await door.actAtAddress(path: path, method: method, form: form)
            } catch let refused as MastodonUnprocessable {
                guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else {
                    throw MastodonAdminError.unreadable
                }
                throw MastodonAdminError.refused(sentence: sentence)
            } catch MastodonHostMoreError.noSuchAddress {
                throw MastodonAuthError.http(404)
            }
        }
    }

    private func asked<T>(_ ask: () async throws -> T) async throws -> T {
        do {
            return try await ask()
        } catch MastodonAuthError.http(403) {
            throw MastodonAdminError.notAllowed
        }
    }

    struct TagDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        let id: String
        let name: String
        let history: Lenient<[Lenient<MastodonRising.Day>]>?
        let trendable: Lenient<Bool>?
        let usable: Lenient<Bool>?
        let listable: Lenient<Bool>?
        let requiresReview: Lenient<Bool>?

        var tag: AdminTag? {
            guard ListSubscription.isPathSegment(id), name.unicodeScalars.count <= MastodonRising.nameLength,
                  let tag = PostTag("#" + name)
            else { return nil }
            return AdminTag(
                id: id, tag: RisingTag(tag: tag, use: MastodonRising.Day.use(history?.value)), rises: trendable?.value ?? false,
                usable: usable?.value ?? true, listable: listable?.value ?? true, waiting: requiresReview?.value ?? false
            )
        }
    }

    struct SiteDTO: Decodable, Sendable {
        let id: MastodonFigure?
        let textID: String?
        let domain: String
        let trendable: StatusDTO.Lenient<Bool>?
        let requiresReview: StatusDTO.Lenient<Bool>?
        let reviewedAt: StatusDTO.LenientMoment?

        private enum Keys: String, CodingKey { case id, domain, trendable, requiresReview, reviewedAt }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            // A number on the wire, unlike every other id the server sends.
            textID = try? container.decode(String.self, forKey: .id)
            id = try? container.decode(MastodonFigure.self, forKey: .id)
            domain = try container.decode(String.self, forKey: .domain)
            trendable = try? container.decode(StatusDTO.Lenient<Bool>.self, forKey: .trendable)
            requiresReview = try? container.decode(StatusDTO.Lenient<Bool>.self, forKey: .requiresReview)
            reviewedAt = try? container.decode(StatusDTO.LenientMoment.self, forKey: .reviewedAt)
        }

        var site: LinkSite? {
            guard let named = textID ?? id?.value.map(String.init), ListSubscription.isPathSegment(named) else { return nil }
            let domain = LineText.oneLine(domain, limit: 253)
            guard !domain.isEmpty else { return nil }
            return LinkSite(
                id: named, domain: domain, rises: trendable?.value, waiting: requiresReview?.value ?? false, reviewedAt: reviewedAt?.value
            )
        }
    }
}
