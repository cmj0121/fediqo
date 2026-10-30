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
// to anyone with no sign-in, so they are read unsigned; a sign-in's own, and every change, are
// `MastodonCollectionWrites`. What a thread is gathering is read off the
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
    /// Whether it warns of what is in it, where the source said.
    public let sensitive: Bool?
    /// Whether it may be found by others, where the source said.
    public let discoverable: Bool?
    /// Who is in it as the asker may see: each by the id a removal or a taking out goes by.
    public let items: [CollectionItem]

    public init(
        id: String, name: String, words: String?, count: Int, sensitive: Bool? = nil, discoverable: Bool? = nil,
        items: [CollectionItem] = []
    ) {
        self.id = id
        self.name = name
        self.words = words
        self.count = count
        self.sensitive = sensitive
        self.discoverable = discoverable
        self.items = items
    }
}

/// One place in a collection: whose, and how it stands.
public struct CollectionItem: Hashable, Sendable, Identifiable {
    /// The source's words for it. Any other is nothing, and is said as neither.
    public enum State: String, Sendable {
        /// Waits on the person's consent. Only the owner's signed read shows it.
        case pending
        case accepted
        case rejected
        case revoked
    }

    public let id: String
    /// Whose, where the source says: never of one rejected or revoked.
    public let accountID: String?
    public let state: State?

    public init(id: String, accountID: String?, state: State?) {
        self.id = id
        self.accountID = accountID
        self.state = state
    }
}

/// Somebody in a collection: the person, and their place in it.
public struct CollectionMember: Hashable, Sendable, Identifiable {
    public let item: CollectionItem
    public let person: Person

    public var id: String { item.id }
}

/// A collection read whole.
public struct CollectionRead: Hashable, Sendable {
    public let collection: PersonCollection
    public let members: [CollectionMember]

    public init(collection: PersonCollection, members: [CollectionMember]) {
        self.collection = collection
        self.members = members
    }
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
        guard let read = CollectionWire.list(body) else { throw MastodonPeopleError.unreadable }
        return read
    }

    /// The people in one, in its order — not who put it together, unless they put themselves in.
    public func people(in collectionID: String, source: Source) async throws -> [Person] {
        guard source.host == door.host, ListSubscription.isPathSegment(collectionID) else { throw MastodonRequestError.invalidURL }
        let (body, _) = try await door.getAtAddress(path: "/api/v1/collections/\(collectionID)")
        guard let read = CollectionWire.whole(body, source: source) else { throw MastodonPeopleError.unreadable }
        return read.members.map(\.person)
    }
}

/// What a source's answers about collections are read by, signed or not.
enum CollectionWire {
    static func list(_ body: Data) -> [PersonCollection]? {
        (try? MastodonJSON.decoder.decode(CollectionsDTO.self, from: body)).map { ($0.collections ?? []).compactMap { $0.value?.collection } }
    }

    static func one(_ body: Data) -> PersonCollection? {
        (try? MastodonJSON.decoder.decode(CollectionDTO.self, from: body))?.collection.collection
    }

    /// The people in one, in its order — not who put it together, unless they put themselves in.
    static func whole(_ body: Data, source: Source) -> CollectionRead? {
        guard let read = try? MastodonJSON.decoder.decode(CollectionDTO.self, from: body), let collection = read.collection.collection else {
            return nil
        }
        let accounts = Dictionary(
            (read.accounts ?? []).compactMap { $0.value }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return CollectionRead(collection: collection, members: collection.items.compactMap { item in
            guard let person = item.accountID.flatMap({ accounts[$0] })?.asPerson(source: source) else { return nil }
            return CollectionMember(item: item, person: person)
        })
    }

    static func item(_ body: Data) -> CollectionItem? {
        (try? MastodonJSON.decoder.decode(ItemDTO.self, from: body))?.collectionItem.item
    }
}

private struct ItemDTO: Decodable {
    let collectionItem: CollectionDTO.Item
}

private struct CollectionsDTO: Decodable {
    let collections: [StatusDTO.Lenient<CollectionDTO.Body>]?
}

private struct CollectionDTO: Decodable {
    struct Item: Decodable {
        let id: String?
        let accountId: String?
        let state: String?

        var item: CollectionItem? {
            guard let id, ListSubscription.isPathSegment(id) else { return nil }
            return CollectionItem(
                id: id, accountID: accountId.flatMap { ListSubscription.isPathSegment($0) ? $0 : nil },
                state: state.flatMap(CollectionItem.State.init(rawValue:))
            )
        }
    }

    struct Body: Decodable {
        let id: String
        let name: String
        let description: String?
        let itemCount: Int?
        let sensitive: Bool?
        let discoverable: Bool?
        let items: [StatusDTO.Lenient<Item>]?

        var collection: PersonCollection? {
            guard ListSubscription.isPathSegment(id) else { return nil }
            return PersonCollection(
                id: id, name: LineText.oneLine(name), words: description.map(HTMLText.plain).flatMap { $0.isEmpty ? nil : $0 },
                count: max(0, itemCount ?? items?.count ?? 0), sensitive: sensitive, discoverable: discoverable,
                items: (items ?? []).compactMap { $0.value?.item }
            )
        }
    }

    let collection: Body
    let accounts: [StatusDTO.Lenient<AccountDTO>]?
}
