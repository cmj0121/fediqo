import Foundation

/// A Mastodon read of a hashtag followed that this device could not make sense of.
public enum MastodonTagFollowError: Error, Equatable, Sendable {
    /// The server answered, and not with what was asked for: a body that is no hashtag or no
    /// list of them, or a hashtag it does not say the reader follows or not.
    case unreadable
}

/// How the reader stands to a hashtag at one source, as its answer to the hashtag says.
public struct TagStanding: Hashable, Sendable {
    /// The reader follows it.
    public let following: Bool
    /// The reader features it on their profile (#318). **Nothing where the answer does not say**
    /// — a GoToSocial's never does (`servers/gotosocial/FINDINGS.md` item 13): the reader's own
    /// featured hashtags are where to look then (`MastodonFeaturing.ownFeaturedTags`).
    public let featuring: Bool?

    public init(following: Bool, featuring: Bool? = nil) {
        self.following = following
        self.featuring = featuring
    }
}

/// One stretch of the hashtags somebody follows, as their source handed it over.
public struct FollowedTagsStretch: Hashable, Sendable {
    /// In the source's own order: the one followed last comes first.
    public let tags: [PostTag]
    /// What the next stretch is asked by: the source's own word for where this one stopped.
    /// Nothing where it named no next — the end of the list.
    public let next: String?

    public init(tags: [PostTag], next: String?) {
        self.tags = tags
        self.next = next
    }
}

/// The hashtags somebody follows as far as they have been read — `PeopleRead`'s rule, for
/// hashtags: every place the source named as its next is kept, so one that sends a reader
/// round in a ring, or on for ever with nothing new, is stopped.
public struct FollowedTagsRead: Hashable, Sendable {
    /// Every hashtag read so far, in the source's order, none twice however it is written.
    public private(set) var tags: [PostTag] = []
    /// What the next stretch is asked by. Nothing before the first stretch, and at the end.
    public private(set) var next: String?
    /// Whether a stretch has been read and the source named no next.
    public private(set) var ended = false
    private var paging = PagingGuard()

    public init() {}

    /// This list with `stretch` read on to. Throws `PagingError.notPaging`, changing nothing,
    /// where the source is not handing the list on in order (`PagingGuard`).
    public func readingOn(_ stretch: FollowedTagsStretch) throws -> FollowedTagsRead {
        var read = self
        var seen = Set(tags.map(MastodonRising.folded))
        read.tags += stretch.tags.filter { seen.insert(MastodonRising.folded($0)).inserted }
        read.next = stretch.next
        read.ended = stretch.next == nil
        try read.paging.step(to: stretch.next, addingNothing: read.tags.count == tags.count)
        return read
    }
}

/// A Mastodon asked whether the reader follows a hashtag, to follow one or stop, and for the
/// hashtags they follow a stretch at a time (#318): `/api/v1/tags/:name`, its `/follow` and
/// `/unfollow`, and `/api/v1/followed_tags`.
///
/// **Asked of a real one first** (`MastodonTagFollowCaptures`). A hashtag is told to anyone;
/// whether *the reader* follows it is said only to a sign-in, and to any sign-in. Following
/// and unfollowing want the word to change who the reader follows, and the list the word to
/// see it. So everything here goes **through the one signed-in door**, which sends the token
/// to its own host and nowhere else, holds an answer to its ceiling as it arrives, and
/// refuses a redirect off that host.
///
/// **A hashtag's name is a stranger's word both ways.** Going out, it is the last segment of
/// the path or the one before the act, and nothing else: a name that would add a segment,
/// climb one, end the path early or run on without end is refused before anything is asked
/// (`path`). Coming back, a name is listed only where it is a hashtag as this app reads one
/// (`PostTag`) and no longer than `nameLength` — so it is one word on one line — and what the
/// answer to a single hashtag calls it is not read at all: the page draws the name pressed.
///
/// **Read on by the source's own word and no other**, as a list of people is
/// (`MastodonPeople`): the list is in the order of the follows, under ids no row carries, so
/// only the answer's `Link` header says where the next stretch begins.
///
/// **Nothing here writes anywhere on this device.** An ask that is refused or fails throws
/// what the door threw and changes nothing.
public struct MastodonTagFollows: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let followedPath = "/api/v1/followed_tags"
    /// How long a hashtag's name may be, to be asked about and to be listed.
    public static let nameLength = MastodonRising.nameLength
    /// How many hashtags a stretch is asked to be: half of the most a Mastodon gives in one.
    public static let stretch = 100

    /// What is done to a hashtag, as the last segment of its address.
    enum Act: String, Sendable {
        case follow, unfollow
    }

    /// Whether the reader follows `tag`, as the source says now.
    public func isFollowed(_ tag: PostTag) async throws -> Bool {
        try Self.followed(in: try await door.get(path: try Self.path(of: tag, host: door.token.host)))
    }

    /// How the reader stands to `tag`, as the source says now: whether they follow it, and
    /// whether they feature it where the answer says. The same one ask as `isFollowed`.
    public func standing(of tag: PostTag) async throws -> TagStanding {
        let body = try await door.get(path: try Self.path(of: tag, host: door.token.host))
        struct Said: Decodable, Sendable {
            let featuring: StatusDTO.Lenient<Bool>?
        }
        let featuring = (try? MastodonJSON.decoder.decode(Said.self, from: body))?.featuring?.value
        return TagStanding(following: try Self.followed(in: body), featuring: featuring)
    }

    /// Follows `tag`, or with `on` false stops following it, and hands back what the source
    /// says of it afterwards. **Asked twice it answers the same**: a Mastodon follows a
    /// hashtag already followed, and unfollows one that is not, without complaint.
    public func follow(_ tag: PostTag, _ on: Bool = true) async throws -> Bool {
        let path = try Self.path(of: tag, on ? .follow : .unfollow, host: door.token.host)
        return try Self.followed(in: try await door.post(path: path, form: []))
    }

    /// The first stretch of the hashtags the reader follows, or with `next` the stretch after
    /// the one that handed it back. Never asked for a length of less than one, which a
    /// Mastodon answers with a failure of its own (500).
    ///
    /// **Entry by entry**: one that is no hashtag, or names one too long, is that one not
    /// listed. A hashtag given twice, however it is written, is listed once.
    public func followed(after next: String? = nil, limit: Int = MastodonTagFollows.stretch) async throws -> FollowedTagsStretch {
        let length = [URLQueryItem(name: "limit", value: String(max(1, limit)))]
        let (body, link) = try await door.getLinked(path: Self.followedPath, query: length + (try MastodonPage.older(than: next)))
        struct Named: Decodable, Sendable {
            let name: String
        }
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Named>].self, from: body) else {
            throw MastodonTagFollowError.unreadable
        }
        let onward = try MastodonLink.next(in: link)
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        var seen: Set<String> = []
        var listed: [PostTag] = []
        // No more is read than was asked for, whatever was sent.
        for entry in wire.prefix(max(1, limit)) {
            guard let name = entry.value?.name, name.unicodeScalars.count <= Self.nameLength,
                  let tag = PostTag("#" + name), seen.insert(MastodonRising.folded(tag)).inserted
            else { continue }
            listed.append(tag)
        }
        return FollowedTagsStretch(tags: listed, next: onward)
    }

    /// What one hashtag's answer says of whether the reader follows it. `unreadable` where it
    /// does not say: a source says so to every sign-in, so an answer without it is not one
    /// to go by — and is never read as "not followed".
    static func followed(in body: Data) throws -> Bool {
        struct Said: Decodable, Sendable {
            let following: StatusDTO.Lenient<Bool>?
        }
        guard let said = (try? MastodonJSON.decoder.decode(Said.self, from: body))?.following?.value else {
            throw MastodonTagFollowError.unreadable
        }
        return said
    }

    /// A hashtag's address, or with `act` the address that follows or unfollows it: a path
    /// whose segment after `tags` is the name and nothing else.
    ///
    /// **Refused rather than trusted**, as a hashtag's timeline is (`MastodonTag.path`):
    /// `PostTag` admits no `/`, `?`, `#`, `%` or `.` into a name, and this does not lean on
    /// that alone. The path is built as the request will build it, and is refused unless it
    /// is exactly the segments before the name, the name, and the act — so a name that would
    /// add a segment, climb one or end the path early never reaches a server with the
    /// reader's token beside it. And a name longer than `nameLength` is not asked about.
    static func path(of tag: PostTag, _ act: Act? = nil, host: String) throws -> String {
        let name = tag.name
        let after = act.map { [$0.rawValue] } ?? []
        let path = (["/api/v1/tags", name] + after).joined(separator: "/")
        guard name.unicodeScalars.count <= nameLength, name != ".", name != "..",
              !name.contains(where: { "/?#%\\".contains($0) }),
              let url = Host.httpsURL(host: host, path: path),
              url.pathComponents == ["/", "api", "v1", "tags", name] + after
        else { throw MastodonRequestError.invalidURL }
        return path
    }
}
