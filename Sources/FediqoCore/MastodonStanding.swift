import Foundation

/// How the reader stands to somebody at a source, as that source last said (#310, #313).
///
/// **The source's word, whole, and nothing worked out from it.** Each of these is said of the
/// two accounts by the source that holds both, and none follows from another: somebody may be
/// followed and muted, asked and blocked by them.
public struct PersonStanding: Hashable, Sendable {
    /// The id the source knows them by: whose standing this is.
    public let accountID: String
    /// The reader follows them.
    public var following: Bool
    /// They follow the reader.
    public var followedBy: Bool
    /// The reader asked to follow them, and they have not answered.
    public var requested: Bool
    /// The reader mutes them — until `mutedUntil`, where the source named an end.
    public var muting: Bool
    public var mutedUntil: Date?
    /// The reader blocks them.
    public var blocking: Bool
    /// They block the reader: the source then gives the reader none of their posts or lists.
    public var blockedBy: Bool
    /// Whether their boosts are shown to the reader, and whether the reader is told of each
    /// of their posts (#313): what is taken from somebody followed. **Said of a follow, and of
    /// nothing else** — nothing where the reader does not follow them, and nothing where the
    /// source did not say: never a "no" made up for it.
    public var showsBoosts: Bool?
    public var notifies: Bool?
    /// The reader features them on their own profile (#315) — the source's `endorsed`. **Said
    /// of a follow, and of nothing else**, as what is taken from them is: only somebody followed
    /// can be featured, and unfollowing takes them off. Nothing where the source did not say.
    public var featured: Bool?

    public init(
        accountID: String, following: Bool = false, followedBy: Bool = false, requested: Bool = false,
        muting: Bool = false, mutedUntil: Date? = nil, blocking: Bool = false, blockedBy: Bool = false,
        showsBoosts: Bool? = nil, notifies: Bool? = nil, featured: Bool? = nil
    ) {
        self.featured = featured
        self.showsBoosts = showsBoosts
        self.notifies = notifies
        self.accountID = accountID
        self.following = following
        self.followedBy = followedBy
        self.requested = requested
        self.muting = muting
        self.mutedUntil = mutedUntil
        self.blocking = blocking
        self.blockedBy = blockedBy
    }
}

/// A Mastodon read of how the reader stands to somebody that this device could not make sense of.
public enum MastodonStandingError: Error, Equatable, Sendable {
    /// The server answered, and not with what was asked for: a body that is no standing or no
    /// list of them, one that leaves out a thing every standing says, or one about somebody
    /// else than was asked about.
    case unreadable
}

/// A Mastodon asked how the reader stands to somebody, and to follow them or stop (#310, #313):
/// `/api/v1/accounts/relationships`, and an account's `/follow` and `/unfollow`.
///
/// **Asked of a real one first** (`MastodonStandingCaptures`). How the reader stands is said
/// only to a sign-in that holds the word to see who they follow, and following and unfollowing
/// want the word to change it. So everything here goes **through the one signed-in door**,
/// which sends the token to its own host and nowhere else, holds an answer to its ceiling as it
/// arrives, and refuses a redirect off that host.
///
/// **Somebody is named by the id the source gave, and by nothing else.** Going out, the id is
/// one segment of a path or one value of a query, and one that would add a segment is refused
/// before anything is asked. Coming back, a standing is taken only where it is about the id
/// asked: a source that answers about somebody else has not answered.
///
/// **A stretch of a list is asked about in one ask** (`standings`), naming everybody in it:
/// the source answers for as many as are named, and leaves out whom it has nothing to say of.
///
/// **Unfollowing withdraws a request too**: the source has one address for both, and answers
/// each the same way.
///
/// **Nothing here writes anywhere on this device.** An ask that is refused or fails throws
/// what the door threw and changes nothing.
public struct MastodonStanding: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/accounts/relationships"

    /// How the reader stands to the account `accountID` names, as the source says now — or
    /// nothing where it answered with no entry for them: an id nobody has there, or an account
    /// it suspended.
    public func standing(to accountID: String) async throws -> PersonStanding? {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        // `id[]`, spelled as the wire carries it: a query's name goes out as it is written here.
        let body = try await door.get(path: Self.path, query: [URLQueryItem(name: "id%5B%5D", value: accountID)])
        return try Self.standing(to: accountID, in: body)
    }

    /// How many people one ask names at most: as many as the longest stretch of a list
    /// brings. **This app's bound, not the server's** — a real one counts nobody and refuses an
    /// ask only by its length, past some six hundred names (`MastodonStandingSaysTests`).
    public static let most = 80

    /// How the reader stands to each of the accounts `accountIDs` name, as the source says
    /// now, **in one ask**: by the id of each, for those it said every part of. Nobody is
    /// there who was not asked about, an id that is no segment of a path is asked of nobody,
    /// and an account the source has no entry for — one it suspended, an id nobody has — or
    /// whose entry could not be read has no standing here, which is never "not followed".
    /// Naming nobody asks nothing, and naming more than `most` is refused before anything is
    /// asked. `unreadable` where the body is no list.
    public func standings(to accountIDs: [String]) async throws -> [String: PersonStanding] {
        var asked: [String] = []
        for id in accountIDs where ListSubscription.isPathSegment(id) && !asked.contains(id) { asked.append(id) }
        guard !asked.isEmpty else { return [:] }
        guard asked.count <= Self.most else { throw MastodonRequestError.invalidURL }
        let body = try await door.get(path: Self.path, query: asked.map { URLQueryItem(name: "id%5B%5D", value: $0) })
        return try Self.standings(to: asked, in: body)
    }

    /// The standings to `accountIDs` in the answer to `relationships`: each entry that is
    /// about one of them and says every part.
    static func standings(to accountIDs: [String], in body: Data) throws -> [String: PersonStanding] {
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Said>].self, from: body) else {
            throw MastodonStandingError.unreadable
        }
        let asked = Set(accountIDs)
        var said: [String: PersonStanding] = [:]
        for standing in wire.compactMap({ $0.value?.standing }) where asked.contains(standing.accountID) {
            said[standing.accountID] = standing
        }
        return said
    }

    /// Follows the account `accountID` names — asks to, where they must agree — or with `on`
    /// false stops following them and withdraws a request, and hands back how the reader stands
    /// to them afterwards. **Asked twice it answers the same.**
    public func follow(_ accountID: String, _ on: Bool = true) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        let body = try await door.post(path: "/api/v1/accounts/\(accountID)/\(on ? "follow" : "unfollow")", form: [])
        return try Self.answered(about: accountID, body)
    }

    /// The words a follow is sent with to say what is taken from them.
    static let boostsWord = "reblogs"
    static let notifyWord = "notify"

    /// Says what is taken from the account `accountID` names, whom the reader follows (#313):
    /// whether their boosts are shown — `boosts` — and whether the reader is told of each of
    /// their posts — `notify` — and hands back how the reader stands to them afterwards.
    /// **Each is sent only where it is handed in**: one left out is left as it stands at the
    /// source (asked of a real one: `MastodonStandingCaptures`). **With neither it is refused
    /// before anything is asked**: that would be a bare follow, which is `follow`'s to send.
    ///
    /// **It is a follow, said again with the words**: the source has no other address for it.
    /// So of somebody the reader does not follow it follows them — whoever calls it has seen
    /// that the reader does.
    public func narrow(_ accountID: String, boosts: Bool? = nil, notify: Bool? = nil) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID), boosts != nil || notify != nil else {
            throw MastodonRequestError.invalidURL
        }
        let form = [boosts.map { (Self.boostsWord, String($0)) }, notify.map { (Self.notifyWord, String($0)) }].compactMap { $0 }
        return try Self.answered(about: accountID, try await door.post(path: "/api/v1/accounts/\(accountID)/follow", form: form))
    }

    /// Answers the request of the account `accountID` names to follow the reader (#313): lets
    /// them, or with `accept` false refuses, and hands back how the reader stands to them
    /// afterwards. **Only a request that is there**: where they have not asked, took it back,
    /// or were answered already, the source says it knows no such request and nothing is
    /// changed (asked of a real one: `MastodonRequestsCaptures`) — it is thrown as the door
    /// threw it.
    public func answer(_ accountID: String, accept: Bool) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        let path = "\(MastodonPeople.List.requestsPath)/\(accountID)/\(accept ? "authorize" : "reject")"
        return try Self.answered(about: accountID, try await door.post(path: path, form: []))
    }

    /// Has the account `accountID` names follow the reader no longer (#313), and hands back
    /// how the reader stands to them afterwards. **Of somebody who does not follow the reader
    /// it changes nothing**, and is answered the same.
    public func removeFollower(_ accountID: String) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        return try Self.answered(
            about: accountID, try await door.post(path: "/api/v1/accounts/\(accountID)/remove_from_followers", form: [])
        )
    }

    /// The standing a press was answered with, where it is about whom the press was about.
    static func answered(about accountID: String, _ body: Data) throws -> PersonStanding {
        guard let said = try? MastodonJSON.decoder.decode(Said.self, from: body), let standing = said.standing,
              standing.accountID == accountID
        else { throw MastodonStandingError.unreadable }
        return standing
    }

    /// The standing to `accountID` in the answer to `relationships`: its entry, or nothing
    /// where the list has none for them. `unreadable` where the body is no list, or their
    /// entry leaves out a thing every standing says — never read as "not followed".
    static func standing(to accountID: String, in body: Data) throws -> PersonStanding? {
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Said>].self, from: body) else {
            throw MastodonStandingError.unreadable
        }
        guard let entry = wire.first(where: { $0.value?.id == accountID }) else {
            // An entry that could not be read may have been theirs: nothing is concluded from it.
            if wire.contains(where: { $0.value == nil }) { throw MastodonStandingError.unreadable }
            return nil
        }
        guard let standing = entry.value?.standing else { throw MastodonStandingError.unreadable }
        return standing
    }

    /// One standing as the source spells it.
    private struct Said: Decodable, Sendable {
        let id: String
        let following: Bool?
        let followedBy: Bool?
        let requested: Bool?
        let muting: Bool?
        let mutingExpiresAt: StatusDTO.LenientMoment?
        let blocking: Bool?
        let blockedBy: Bool?
        let showingReblogs: Bool?
        let notifying: Bool?
        let endorsed: StatusDTO.Lenient<Bool>?

        /// The standing, where the source said every part of it. What is taken from them is
        /// no such part: a source that leaves it out has said the rest.
        var standing: PersonStanding? {
            guard let following, let followedBy, let requested, let muting, let blocking, let blockedBy else { return nil }
            return PersonStanding(
                accountID: id, following: following, followedBy: followedBy, requested: requested, muting: muting,
                mutedUntil: muting ? mutingExpiresAt?.value : nil, blocking: blocking, blockedBy: blockedBy,
                showsBoosts: following ? showingReblogs : nil, notifies: following ? notifying : nil,
                featured: following ? endorsed?.value : nil
            )
        }
    }
}
