import Foundation

// What a Mastodon announces to the people signed in to it (#321), and the reader's three acts on
// an announcement: dismissing it, and putting a reaction on it and taking it back.
//
// **Only the server's own acts and words.** A Mastodon has one act for an announcement having
// been dealt with — dismissing it, after which it says the announcement is `read` for this
// reader. What "seen" and "dismissed" each mean on a page is not decided here: the read hands
// back the source's `read` as it said it, and dismissing is the one act that changes it.
//
// **An empty list is not "the host has none"** (`servers/gotosocial/FINDINGS.md` item 7): a
// GoToSocial answers `200 []` whether or not it has announcements at all, and a Mastodon with
// nothing announced answers the same. So nothing is concluded from one: the thing is absent
// only by the host's own account of itself, or by a not-found of its address remembered for the
// run by whoever asked (`MastodonHostsKnown`) — which `read` throws as
// `MastodonHostMoreError.noSuchAddress`, and nothing else does.
//
// **The lock is the held words', never a 403's text** (item 2), as `MastodonOwnAccount` reads
// it: dismissing rides the account part (`write:accounts`), a reaction the acting part
// (`write:favourites`) — **never asked for on its own**. A 403 is the part's lock only where the
// sign-in does not hold the part, and the source forbidding it where it does.
//
// **A stranger's word, bounded where it enters.** The words are an administrator's markup, cut
// before it is taken out of its markup as a post's are; a list, and an announcement's
// reactions, are held to a length; a reaction's name is put in a path only where it is one
// segment that is a name and nothing else; every picture goes through `Host.fetchableURL`.
//
// **Nothing here writes anywhere on this device**: what is read lands in what it returns.

/// One thing a source announces to the people signed in to it.
public struct Announcement: Sendable, Hashable {
    /// One reaction on an announcement: which, how many put it there, and whether the reader did.
    public struct Reaction: Sendable, Hashable {
        /// The source's name for it: an emoji itself, or a custom one's shortcode.
        public let name: String
        /// How many put it there, as the source counts them.
        public let count: Int
        /// Whether the reader is one of them. Nothing where the source did not say.
        public let me: Bool?
        /// The picture of a custom one, where the source gave one that may be fetched.
        public let picture: CustomEmoji?

        public init(name: String, count: Int, me: Bool?, picture: CustomEmoji? = nil) {
            self.name = name
            self.count = count
            self.me = me
            self.picture = picture
        }
    }

    /// The source's own id for it: what the acts are asked by.
    public let id: String
    /// Its words, out of their markup as a post's are.
    public let words: String
    /// The custom emoji its words name, where the source gave them.
    public let emojis: [CustomEmoji]
    /// When it was announced, and when it was last changed, where the source says.
    public let publishedAt: Date?
    public let updatedAt: Date?
    /// The stretch of time it is about, where it names one, and whether that is whole days.
    public let startsAt: Date?
    public let endsAt: Date?
    public let allDay: Bool
    /// The source's `read`: true once this reader dismissed it. Nothing where it did not say.
    public let read: Bool?
    /// Its reactions, in the source's order.
    public let reactions: [Reaction]

    public init(
        id: String, words: String, emojis: [CustomEmoji] = [], publishedAt: Date? = nil, updatedAt: Date? = nil,
        startsAt: Date? = nil, endsAt: Date? = nil, allDay: Bool = false, read: Bool? = nil, reactions: [Reaction] = []
    ) {
        self.id = id
        self.words = words
        self.emojis = emojis
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.read = read
        self.reactions = reactions
    }
}

public enum AnnouncementError: Error, Equatable, Sendable {
    /// The sign-in does not hold the part the act rides: the account part for dismissing, the
    /// acting part for a reaction. Asking for it is what changes this.
    case locked(MastodonPart)
    /// The source refused a sign-in that holds the part (403), or refused to read them.
    case forbidden
    /// The source would not take the reaction (422): its sentence, made fit for a line — empty
    /// where it sent none.
    case refused(sentence: String)
    /// The source has no such announcement (404): withdrawn, or never there.
    case gone
    /// The source answered, and not with announcements.
    case unreadable
}

/// A Mastodon asked for what it announces and to act on one: `/api/v1/announcements`,
/// `…/:id/dismiss` and `…/:id/reactions/:name` — **through the one signed-in door**, to the
/// host the sign-in is of.
public struct MastodonAnnouncements: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/announcements"
    /// The most announcements read of one answer, and the most reactions of one announcement.
    public static let longest = 100
    public static let reactionsLongest = 100
    /// How much of an announcement's markup is read before it is taken out of its markup.
    static let markupLength = 40_000
    /// How long a reaction's name may be: an emoji of several joined, or a shortcode.
    static let nameLength = 64
    /// How much of a refusal is read, and how long its sentence is kept.
    static let refusalLength = 4_096
    static let sentenceLength = 200

    /// What the source announces to the reader now, in its order. **An empty list is that the
    /// source gave none, not that the host has none.**
    ///
    /// Throws `MastodonHostMoreError.noSuchAddress` where the host says it has no such address,
    /// `.forbidden` for a 403, `.unreadable` for an answer that is no list, and what the door
    /// threw otherwise. **Entry by entry**: one this build cannot read is that one left out.
    public func read() async throws -> [Announcement] {
        let body: Data
        do {
            body = try await door.getAtAddress(path: Self.path)
        } catch MastodonAuthError.http(403) {
            throw AnnouncementError.forbidden
        }
        return try Self.announcements(from: body)
    }

    /// Dismisses `id` for the reader: the source says it is `read` from then on. Rides the
    /// account part.
    public func dismiss(_ id: String) async throws {
        guard ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        try await act(part: .account) {
            _ = try await door.post(path: "\(Self.path)/\(id)/dismiss", form: [])
        }
    }

    /// Puts the reaction `name` on `id` as the reader. Rides the acting part.
    public func react(_ id: String, with name: String) async throws {
        let path = try Self.reactionPath(id, name)
        try await act(part: .acting) {
            _ = try await door.put(path: path)
        }
    }

    /// Takes the reader's reaction `name` off `id`. Rides the acting part.
    public func unreact(_ id: String, with name: String) async throws {
        let path = try Self.reactionPath(id, name)
        try await act(part: .acting) {
            _ = try await door.delete(path: path)
        }
    }

    /// One act, its refusals told apart: a 403 by the held words, a 404 as the announcement
    /// gone, a 422 as the source's refusal of it.
    private func act(part: MastodonPart, _ send: () async throws -> Void) async throws {
        do {
            try await send()
        } catch MastodonAuthError.http(403) {
            throw MastodonParts.holds(part, in: door.token.scopes) ? AnnouncementError.forbidden : .locked(part)
        } catch MastodonAuthError.http(404) {
            throw AnnouncementError.gone
        } catch let refused as MastodonUnprocessable {
            throw AnnouncementError.refused(sentence: Self.sentence(from: refused.body))
        }
    }

    static func reactionPath(_ id: String, _ name: String) throws -> String {
        guard ListSubscription.isPathSegment(id), isReactionName(name) else { throw MastodonRequestError.invalidURL }
        return "\(path)/\(id)/reactions/\(name)"
    }

    /// Whether `name` can stand in a path as one segment that is a reaction's name: a shortcode
    /// of letters, digits and underscores, or an emoji — no space, no mark of a path, nothing
    /// that turns a line round.
    static func isReactionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= nameLength else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            if scalar.isASCII { return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) }
            let p = scalar.properties
            return p.isEmoji || p.isEmojiPresentation || p.isEmojiModifier || p.isVariationSelector
                || scalar.value == 0x200D || scalar.value == 0x20E3 || (0xE0020...0xE007F).contains(scalar.value)
        }
    }

    /// The announcements an answer carries, each bounded. `unreadable` where it is no list.
    static func announcements(from body: Data) throws -> [Announcement] {
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Wire>].self, from: body) else {
            throw AnnouncementError.unreadable
        }
        return Array(wire.lazy.compactMap { $0.value?.announcement }.prefix(longest))
    }

    private static func sentence(from body: Data) -> String {
        guard body.count <= refusalLength,
              let said = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = said["error"] as? String
        else { return "" }
        return LineText.oneLine(error, limit: sentenceLength).trimmingCharacters(in: .whitespaces)
    }

    /// One announcement as the source sends it, every field read leniently.
    private struct Wire: Decodable, Sendable {
        typealias L = StatusDTO.Lenient
        struct Reaction: Decodable, Sendable {
            let name: L<String>?
            let count: MastodonFigure?
            let me: L<Bool>?
            let url: L<String>?
            let staticUrl: L<String>?
        }
        let id: L<String>?
        let content: L<String>?
        let publishedAt: StatusDTO.LenientMoment?
        let updatedAt: StatusDTO.LenientMoment?
        let startsAt: StatusDTO.LenientMoment?
        let endsAt: StatusDTO.LenientMoment?
        let allDay: L<Bool>?
        let read: L<Bool>?
        let emojis: L<[L<StatusDTO.Emoji>]>?
        let reactions: L<[L<Reaction>]>?

        /// Nothing where it has no id an act could be asked by.
        var announcement: Announcement? {
            guard let id = id?.value, ListSubscription.isPathSegment(id) else { return nil }
            let reactions = (reactions?.value ?? []).compactMap(\.value).compactMap { reaction -> Announcement.Reaction? in
                guard let name = reaction.name?.value, MastodonAnnouncements.isReactionName(name) else { return nil }
                let picture = Host.fetchableURL(reaction.url?.value).map {
                    CustomEmoji(shortcode: name, url: $0, staticURL: Host.fetchableURL(reaction.staticUrl?.value))
                }
                return Announcement.Reaction(name: name, count: reaction.count?.value ?? 0, me: reaction.me?.value, picture: picture)
            }
            return Announcement(
                id: id,
                words: HTMLText.plain(AccountDTO.cut(content?.value ?? "", to: MastodonAnnouncements.markupLength)),
                emojis: CustomEmoji.folded((emojis?.value ?? []).compactMap { $0.value?.asEmoji }),
                publishedAt: publishedAt?.value, updatedAt: updatedAt?.value,
                startsAt: startsAt?.value, endsAt: endsAt?.value,
                allDay: allDay?.value ?? false, read: read?.value,
                reactions: Array(reactions.prefix(MastodonAnnouncements.reactionsLongest))
            )
        }
    }
}
