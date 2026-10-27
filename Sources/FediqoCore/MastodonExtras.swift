import Foundation

// What else a Mastodon keeps for the person (#340), as `MastodonExtrasCaptures` records 4.6.6
// answering: a thread still being gathered from elsewhere, a year looked back on, and the
// collections of people somebody put together.
//
// **Each absent with no error where a host lacks it.** A thread a host gathers nothing for says
// nothing; a year or a collection is at an address a host older than it answers not-found of its
// own (`MastodonHostThing.yearsLookedBack`, `.collections`), remembered for the run — never a
// version string.
//
// **No part beyond reading.** The years are read with `read:accounts`, which reading holds.
// Collections want `read:collections` of any sign-in — one without it is refused — and are given
// to anyone with no sign-in, so they are read unsigned. What a thread is gathering is read off the
// answer to its own read; the source's own address for it wants the whole of `read` and is never
// asked.

/// What a source says it is still gathering for an answer (`Mastodon-Async-Refresh`): when to ask
/// again, and how much it has found so far, where it says.
public struct MastodonGathering: Hashable, Sendable {
    public static let header = "Mastodon-Async-Refresh"
    /// How long to wait before asking again, in seconds, as the source says it — never less than
    /// one, never more than `longest`.
    public let retry: Int
    public let found: Int?

    public static let longest = 60

    public init(retry: Int, found: Int? = nil) {
        self.retry = retry
        self.found = found
    }

    /// The header read, or nothing where there is none or it says no wait.
    /// `id="…", retry=3, result_count=0`.
    public init?(header: String?) {
        guard let header, !header.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for part in header.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            fields[pair[0].lowercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let wait = fields["retry"].flatMap(Int.init) else { return nil }
        retry = min(max(wait, 1), Self.longest)
        found = fields["result_count"].flatMap(Int.init)
    }
}

/// A year the source looked back on for the person.
public struct YearLookedBack: Hashable, Sendable, Identifiable {
    public struct Month: Hashable, Sendable {
        public let month: Int
        public let posts: Int
        public let followers: Int
    }

    public struct Tag: Hashable, Sendable {
        public let name: String
        public let posts: Int
    }

    public let year: Int
    /// The source's word for the kind of poster the person was (`lurker`, `booster`, …).
    public let archetype: String?
    public let months: [Month]
    public let tags: [Tag]
    /// The person's posts most boosted, answered and favourited, where the source named them and
    /// sent them.
    public let mostBoosted: Note?
    public let mostAnswered: Note?
    public let mostFavourited: Note?
    /// Where the source shows it to anybody.
    public let shared: URL?

    public var id: Int { year }
}

/// The years a signed-in Mastodon looked back on for the person.
public struct MastodonYears: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/annual_reports"

    /// Every year it has looked back on and the person has not yet read, newest first — each read
    /// whole, its posts among it. Throws `MastodonHostMoreError.noSuchAddress` where the host has
    /// no such address.
    public func years(source: Source) async throws -> [YearLookedBack] {
        let sent = ReadMoment.now()
        let body = try await door.getAtAddress(path: Self.path)
        guard let read = try? MastodonJSON.decoder.decode(YearsDTO.self, from: body) else { throw MastodonPeopleError.unreadable }
        let posts = Dictionary(
            (read.statuses ?? []).compactMap { $0.value }.map { ($0.id, $0.asNote(source: source, categories: [], sent: sent)) },
            uniquingKeysWith: { first, _ in first }
        )
        return (read.annualReports ?? []).compactMap { $0.value?.year(posts: posts) }.sorted { $0.year > $1.year }
    }
}

private struct YearsDTO: Decodable {
    let annualReports: [StatusDTO.Lenient<YearDTO>]?
    let statuses: [StatusDTO.Lenient<StatusDTO>]?
}

private struct YearDTO: Decodable {
    struct DataDTO: Decodable {
        struct MonthDTO: Decodable {
            let month: Int
            let statuses: Int?
            let followers: Int?
        }

        struct TagDTO: Decodable {
            let name: String
            let count: Int?
        }

        struct TopDTO: Decodable {
            let byReblogs: String?
            let byReplies: String?
            let byFavourites: String?
        }

        let archetype: String?
        let timeSeries: [MonthDTO]?
        let topHashtags: [StatusDTO.Lenient<TagDTO>]?
        let topStatuses: TopDTO?
    }

    let year: Int
    let data: DataDTO?
    let shareUrl: String?

    func year(posts: [String: Note]) -> YearLookedBack? {
        guard (1970...9999).contains(year) else { return nil }
        let top = data?.topStatuses
        return YearLookedBack(
            year: year, archetype: data?.archetype,
            months: (data?.timeSeries ?? []).filter { (1...12).contains($0.month) }
                .map { .init(month: $0.month, posts: max(0, $0.statuses ?? 0), followers: max(0, $0.followers ?? 0)) },
            tags: (data?.topHashtags ?? []).compactMap { $0.value }.map { .init(name: $0.name, posts: max(0, $0.count ?? 0)) },
            mostBoosted: top?.byReblogs.flatMap { posts[$0] },
            mostAnswered: top?.byReplies.flatMap { posts[$0] },
            mostFavourited: top?.byFavourites.flatMap { posts[$0] },
            shared: Host.fetchableURL(shareUrl)
        )
    }
}

/// A collection of people somebody put together, as their source lists it.
public struct PersonCollection: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let words: String?
    /// How many people the source counts in it.
    public let count: Int
}

/// The collections a Mastodon keeps of somebody's, and the people in one — read unsigned, which
/// every reader is given (`MastodonExtrasCaptures`).
public struct MastodonCollections: Sendable {
    private let door: MastodonReading

    public init(http: any HTTPClient, host: String) {
        door = MastodonReading(http: http, host: host)
    }

    /// Their collections, newest first, the ones they let be found. Throws
    /// `MastodonHostMoreError.noSuchAddress` where the host has no such address.
    public func of(_ accountID: String, source: Source) async throws -> [PersonCollection] {
        guard source.host == door.host, ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        let (body, _) = try await door.getAtAddress(path: "/api/v1/accounts/\(accountID)/collections")
        guard let read = try? MastodonJSON.decoder.decode(CollectionsDTO.self, from: body) else { throw MastodonPeopleError.unreadable }
        return (read.collections ?? []).compactMap { $0.value?.collection }
    }

    /// The people in one, in its order — not who put it together, unless they put themselves in.
    public func people(in collectionID: String, source: Source) async throws -> [Person] {
        guard source.host == door.host, ListSubscription.isPathSegment(collectionID) else { throw MastodonRequestError.invalidURL }
        let (body, _) = try await door.getAtAddress(path: "/api/v1/collections/\(collectionID)")
        guard let read = try? MastodonJSON.decoder.decode(CollectionDTO.self, from: body) else { throw MastodonPeopleError.unreadable }
        let accounts = Dictionary(
            (read.accounts ?? []).compactMap { $0.value }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return (read.collection.items ?? []).compactMap { item in
            item.accountId.flatMap { accounts[$0] }?.asPerson(source: source)
        }
    }
}

private struct CollectionsDTO: Decodable {
    let collections: [StatusDTO.Lenient<CollectionDTO.Body>]?
}

private struct CollectionDTO: Decodable {
    struct Item: Decodable {
        let accountId: String?
    }

    struct Body: Decodable {
        let id: String
        let name: String
        let description: String?
        let itemCount: Int?
        let items: [Item]?

        var collection: PersonCollection? {
            guard ListSubscription.isPathSegment(id) else { return nil }
            return PersonCollection(
                id: id, name: LineText.oneLine(name), words: description.map(HTMLText.plain).flatMap { $0.isEmpty ? nil : $0 },
                count: max(0, itemCount ?? items?.count ?? 0)
            )
        }
    }

    let collection: Body
    let accounts: [StatusDTO.Lenient<AccountDTO>]?
}
