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

    public init(
        accountID: String, following: Bool = false, followedBy: Bool = false, requested: Bool = false,
        muting: Bool = false, mutedUntil: Date? = nil, blocking: Bool = false, blockedBy: Bool = false
    ) {
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

    /// Follows the account `accountID` names — asks to, where they must agree — or with `on`
    /// false stops following them and withdraws a request, and hands back how the reader stands
    /// to them afterwards. **Asked twice it answers the same.**
    public func follow(_ accountID: String, _ on: Bool = true) async throws -> PersonStanding {
        guard ListSubscription.isPathSegment(accountID) else { throw MastodonRequestError.invalidURL }
        let body = try await door.post(path: "/api/v1/accounts/\(accountID)/\(on ? "follow" : "unfollow")", form: [])
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

        /// The standing, where the source said every part of it.
        var standing: PersonStanding? {
            guard let following, let followedBy, let requested, let muting, let blocking, let blockedBy else { return nil }
            return PersonStanding(
                accountID: id, following: following, followedBy: followedBy, requested: requested, muting: muting,
                mutedUntil: muting ? mutingExpiresAt?.value : nil, blocking: blocking, blockedBy: blockedBy
            )
        }
    }
}
