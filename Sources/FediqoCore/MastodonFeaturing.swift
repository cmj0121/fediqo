import Foundation

// People and hashtags featured on a profile at a Mastodon (#315, #318): the reader's own featured
// and taken off, and what anyone features read.
//
// **Every write rides the account part** (`MastodonPart.account`, `write:accounts`), and so does
// telling the source not to suggest somebody (`MastodonSuggestions.dismiss`). **The lock is the
// held words', never a 403's text**, as for a change to the account (`MastodonOwnAccount`): a
// GoToSocial's 403 names no missing word (`servers/gotosocial/FINDINGS.md` item 2), so a 403 is
// the part's lock only where the sign-in does not hold the part.
//
// **Featuring somebody the reader does not follow is the source's refusal**, and said as the
// source says it: a 422 whose sentence is carried whole, made fit for a line. Nothing here asks
// first whether the reader follows them — the source is who decides.
//
// **Not every host has these** (item 8: a GoToSocial answers a not-found for every ask about
// people featured). A not-found of the address is thrown as `MastodonHostMoreError.noSuchAddress`,
// for whoever keeps what the run knows (`MastodonHostsKnown`, `.featuredPeople` /
// `.featuredTags`) — never a version string. **An empty list is nothing featured**, never that
// (item 7).
//
// **Whether a hashtag is featured** is the hashtag's answer's `featuring` where it says
// (`TagStanding`), and otherwise the reader's own list, matched by its folded name: a
// GoToSocial's hashtag has no `featuring` and no id (item 13). Taking one off is by the id of
// the featuring, which only that list gives.
//
// **Nothing here writes anywhere on this device**: what is read lands in what it returns.

/// A write of the account part refused or not understood.
public enum AccountPartError: Error, Equatable, Sendable {
    /// The sign-in does not hold the account part: asking for it is what changes this.
    case locked
    /// The source refused a sign-in that holds the account part (403).
    case forbidden
    /// The source would not do it (422), in its own sentence made fit for a line — empty where
    /// it sent none. Nothing changed there.
    case refused(sentence: String)
    /// The source answered, and not with what was asked for.
    case unreadable

    /// How much of a refusal is read: a sentence, not a page.
    static let refusalLength = 16_384
    /// How long the source's sentence is kept.
    static let sentenceLength = 200

    /// `method` sent to `path` through `door`, with the account part's lock and the source's
    /// refusal told apart; a not-found of the address is `MastodonHostMoreError.noSuchAddress`.
    static func act(
        _ door: MastodonAuthorized, path: String, method: String, form: [(String, String)]? = nil
    ) async throws -> Data {
        do {
            return try await door.actAtAddress(path: path, method: method, form: form)
        } catch let refused as MastodonUnprocessable {
            throw refusal(from: refused.body)
        } catch MastodonAuthError.http(403) {
            throw MastodonParts.holds(.account, in: door.token.scopes) ? AccountPartError.forbidden : .locked
        }
    }

    /// What a 422 says: its `error`, made fit for a line.
    static func refusal(from body: Data) -> AccountPartError {
        guard body.count <= refusalLength,
              let said = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let sentence = said["error"] as? String
        else { return .refused(sentence: "") }
        return .refused(sentence: LineText.oneLine(sentence, limit: sentenceLength).trimmingCharacters(in: .whitespaces))
    }
}

/// A hashtag featured on somebody's profile, as their source lists it.
public struct FeaturedTag: Hashable, Sendable {
    /// The source's id of the featuring — not of the hashtag — which is what takes it off.
    /// Nothing where the source gave none that could stand in a path.
    public let id: String?
    public let tag: PostTag
    /// How many of their posts carry it, where the source says.
    public let count: Int?
    /// The day the last of them was posted, where the source says: a day, not a moment —
    /// midnight of it, in UTC.
    public let last: Date?

    public init(id: String?, tag: PostTag, count: Int? = nil, last: Date? = nil) {
        self.id = id
        self.tag = tag
        self.count = count
        self.last = last
    }

    /// The hashtag's name, without its mark.
    public var name: String { tag.name }

    /// The most a list of them is read to: a host states ten, and a stranger may send more.
    public static let most = 100

    /// The featuring of `tag` in `list`, matched however either is written.
    public static func of(_ tag: PostTag, in list: [FeaturedTag]) -> FeaturedTag? {
        let folded = MastodonRising.folded(tag)
        return list.first { MastodonRising.folded($0.tag) == folded }
    }

    /// A list as a source answers it. Entry by entry: one that is no hashtag this app reads is
    /// not listed, one given twice is listed once. `unreadable` where the body is no list.
    static func list(from body: Data) throws -> [FeaturedTag] {
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Wire>].self, from: body) else {
            throw AccountPartError.unreadable
        }
        var seen: Set<String> = []
        var listed: [FeaturedTag] = []
        for entry in wire.prefix(most) {
            guard let featured = entry.value.flatMap(\.featured), seen.insert(MastodonRising.folded(featured.tag)).inserted
            else { continue }
            listed.append(featured)
        }
        return listed
    }

    /// One as a source answers it, alone: what featuring a hashtag hands back.
    static func one(from body: Data) throws -> FeaturedTag {
        guard let wire = try? MastodonJSON.decoder.decode(Wire.self, from: body), let featured = wire.featured else {
            throw AccountPartError.unreadable
        }
        return featured
    }

    /// A featuring as the source spells it.
    struct Wire: Decodable, Sendable {
        let id: StatusDTO.Lenient<String>?
        let name: String
        let statusesCount: StatusDTO.Lenient<Count>?
        let lastStatusAt: StatusDTO.Lenient<String>?

        var featured: FeaturedTag? {
            guard name.unicodeScalars.count <= MastodonTagFollows.nameLength, let tag = PostTag("#" + name) else { return nil }
            let id = id?.value.flatMap { ListSubscription.isPathSegment($0) ? $0 : nil }
            return FeaturedTag(
                id: id, tag: tag, count: statusesCount?.value?.figure,
                last: lastStatusAt?.value.flatMap(FeaturedTag.day(from:))
            )
        }
    }

    /// A day as a Mastodon writes it here (`2026-10-14`), or a moment as another host may send.
    static func day(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.utf8.count == 10, parts.count == 3,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return MastodonJSON.date(from: text) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// A count a Mastodon sends as a string here (`"0"`), and another host may send as a number.
    struct Count: Decodable, Sendable {
        let figure: Int?

        init(from decoder: any Decoder) throws {
            let one = try decoder.singleValueContainer()
            let said = (try? one.decode(Int.self)) ?? (try? one.decode(String.self)).flatMap { Int($0) }
            figure = said.flatMap { $0 >= 0 ? $0 : nil }
        }
    }
}

/// A Mastodon asked to feature people and hashtags on the reader's profile and take them off,
/// and which hashtags the reader features — **through the one signed-in door**, to the host the
/// sign-in is of. Whether the reader features somebody is their standing's `featured`; whom
/// the reader features is `MastodonPeople.List.featuredByReader`; what anyone else features,
/// `MastodonFeatured`.
public struct MastodonFeaturing: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let tagsPath = "/api/v1/featured_tags"

    /// Features the account `accountID` names on the reader's profile and hands back how the
    /// reader stands to them afterwards, as the source answers.
    ///
    /// Throws `AccountPartError.refused` where the source will not — somebody the reader does
    /// not follow — `.locked` / `.forbidden` for a 403, and `noSuchAddress` where the host has
    /// no such thing.
    public func feature(accountID: String) async throws -> PersonStanding {
        try await endorse(accountID, "endorse")
    }

    /// Takes the account `accountID` names off the reader's profile, as `feature(accountID:)`.
    public func unfeature(accountID: String) async throws -> PersonStanding {
        try await endorse(accountID, "unendorse")
    }

    private func endorse(_ accountID: String, _ act: String) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        let body = try await AccountPartError.act(door, path: "/api/v1/accounts/\(accountID)/\(act)", method: "POST", form: [])
        guard let standing = try? MastodonStanding.answered(about: accountID, body) else { throw AccountPartError.unreadable }
        return standing
    }

    /// The hashtags the reader features, in the source's order. `noSuchAddress` where the host
    /// has no such thing; an empty list is nothing featured.
    public func ownFeaturedTags() async throws -> [FeaturedTag] {
        try FeaturedTag.list(from: try await door.getAtAddress(path: Self.tagsPath))
    }

    /// Features `tag` on the reader's profile and hands back the featuring the source made —
    /// the one already there, where it was. `refused` where the source will not: a limit of
    /// its own reached, a name it does not take.
    public func feature(tag: PostTag) async throws -> FeaturedTag {
        guard tag.name.unicodeScalars.count <= MastodonTagFollows.nameLength else { throw MastodonRequestError.invalidURL }
        return try FeaturedTag.one(from: try await AccountPartError.act(door, path: Self.tagsPath, method: "POST", form: [("name", tag.name)]))
    }

    /// Takes `tag` off the reader's profile: the reader's own featured hashtags are read for
    /// the featuring's id — a hashtag's own answer has none — and that is taken off. **Where
    /// it is not among them nothing more is asked**: it is not featured, which is what was wanted.
    public func unfeature(tag: PostTag) async throws {
        guard let featured = FeaturedTag.of(tag, in: try await ownFeaturedTags()) else { return }
        try await unfeature(featured)
    }

    /// Takes `featured` off the reader's profile, by the id of the featuring. One with no id
    /// asks nothing: there is no address to take it off at.
    public func unfeature(_ featured: FeaturedTag) async throws {
        guard let id = featured.id, ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        _ = try await AccountPartError.act(door, path: "\(Self.tagsPath)/\(id)", method: "DELETE")
    }
}

/// A Mastodon asked what somebody features (#315, #318): `/api/v1/accounts/:id/featured_tags`
/// and `/endorsements`, as the reader where signed in, unsigned otherwise — given to anyone.
public struct MastodonFeatured: Sendable {
    private let door: MastodonReading
    private let people: MastodonPeople

    /// Unsigned: whoever reads so hands in a client that is watched and admitted.
    public init(http: any HTTPClient, host: String) {
        door = MastodonReading(http: http, host: host)
        people = MastodonPeople(http: http, host: host)
    }

    /// As the reader, through the one signed-in door.
    public init(door: MastodonAuthorized) {
        self.door = MastodonReading(door: door)
        people = MastodonPeople(door: door)
    }

    /// The hashtags the account `accountID` names features at `source`, in its order. Throws
    /// `MastodonHostMoreError.noSuchAddress` where the host says it has no such address, and a
    /// 404 for an id nobody has as the door threw it.
    public func featuredTags(of accountID: String, source: Source) async throws -> [FeaturedTag] {
        guard source.host == door.host, ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        return try FeaturedTag.list(from: try await door.getAtAddress(path: "/api/v1/accounts/\(accountID)/featured_tags").body)
    }

    /// A stretch of the people the account `accountID` names features at `source`, read on by
    /// the source's own next as the other lists of people are (`MastodonPeople.List.featured`).
    public func featuredPeople(
        of accountID: String, source: Source, after next: String? = nil, limit: Int? = nil
    ) async throws -> PeopleStretch {
        try await people.stretch(.featured(by: accountID), source: source, after: next, limit: limit)
    }
}
