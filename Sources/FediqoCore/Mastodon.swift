import Foundation

public struct MastodonClient: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    public func publicTimeline(source: Source) async throws -> [Note] {
        try await statuses(
            path: "/api/v1/timelines/public",
            limit: 40,
            source: source,
            category: .public
        )
    }

    public func trending(source: Source) async throws -> [Note] {
        try await statuses(
            path: "/api/v1/trends/statuses",
            limit: 20,
            source: source,
            category: .trends
        )
    }

    /// Every shortcode this server has registered, folded the way a status's own list is.
    ///
    /// This is what resolves a shortcode that arrived with no list beside it. A status carries
    /// its own pictures and costs nothing extra, but a name also turns up where no such list
    /// came with it, and only the server's own catalogue can answer for those.
    ///
    /// Unauthenticated on every Mastodon server, and **optional**: a fork that does not serve it
    /// answers 404, which is thrown here for the caller to survive. A source with no catalogue
    /// simply has none.
    ///
    /// `visible_in_picker` and `category` are on the wire and are not read. Both exist to
    /// arrange an emoji picker — which ones to offer, and under which heading — and this app has
    /// no picker: a reader here never chooses an emoji, only reads one somebody else wrote.
    /// Keeping them would put two fields in `CustomEmoji` that no screen can draw and every test
    /// would have to carry. A build that grows a composer with a picker adds them then, against
    /// a screen that uses them.
    public func customEmojis() async throws -> [CustomEmoji] {
        guard let url = Host.httpsURL(host: host, path: "/api/v1/custom_emojis") else {
            throw MastodonRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonRequestError.http(response.statusCode)
        }
        // The same wire object a status carries, with the same rule applied to its addresses:
        // an emoji this device will not fetch a picture for is a shortcode that can never
        // resolve, and is dropped rather than indexed.
        let wire = try MastodonJSON.decoder.decode([StatusDTO.Emoji].self, from: data)
        return CustomEmoji.folded(wire.compactMap(\.asEmoji))
    }

    /// What this server says about itself: `GET /api/v2/instance`.
    ///
    /// Unauthenticated, and the one document Mastodon publishes for this. **No `/api/v1/instance`
    /// fallback**, deliberately: v1 is deprecated, it carries a different shape, and a server old
    /// enough to need it previews as `.unread(.unreadable)` rather than being read through a
    /// second decoder nobody can test against a live server any more.
    ///
    /// `people`, `posts` and `readsWithoutAccount` come back nothing, because Mastodon has no such
    /// idea — see `SourceProfile.activeMonth`.
    public func profile() async throws -> SourceProfile {
        guard let url = Host.httpsURL(host: host, path: "/api/v2/instance") else {
            // Nothing was asked, so nothing answered badly. `unreadable` would claim a
            // server sent something unreadable when no request was ever built.
            throw ProfileError.unreachable
        }
        let (data, response) = try await http.data(from: url)
        // **The status is read before the body is, and that ordering is the whole guard.** A
        // Mastodon older than 4.0 does not have this endpoint and answers 404 with a page of
        // HTML; a decoder handed that reports a corrupt profile for a server whose only fault is
        // its age. Nothing non-2xx reaches `JSONDecoder` from here.
        guard (200..<300).contains(response.statusCode) else {
            throw ProfileError.of(status: response.statusCode)
        }
        return try MastodonJSON.decoder.decode(InstanceDTO.self, from: data).asProfile(host: host)
    }

    private func statuses(
        path: String,
        limit: Int,
        source: Source,
        category: Category
    ) async throws -> [Note] {
        guard let url = Host.httpsURL(
            host: host,
            path: path,
            query: [URLQueryItem(name: "limit", value: String(limit))]
        ) else {
            throw MastodonRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonRequestError.http(response.statusCode)
        }
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data).map {
            $0.asNote(source: source, category: category)
        }
    }
}

enum MastodonRequestError: Error, Equatable {
    case invalidURL
    case http(Int)
}

enum MastodonJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()

    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}

/// `/api/v2/instance`, in the fields a preview draws.
///
/// Every one of them is Optional here even where Mastodon's own documentation calls it
/// guaranteed. This is a stranger's server and a fork's server: a field that is always present on
/// mastodon.social is a field that is missing on the install this app is actually pointed at, and
/// one absent string must not cost the reader the whole profile.
struct InstanceDTO: Decodable, Sendable {
    let title: String?
    let description: String?
    let thumbnail: Thumbnail?
    let usage: Usage?
    let registrations: Registrations?
    let rules: [Rule]?

    struct Thumbnail: Decodable, Sendable {
        let url: String?
    }

    struct Usage: Decodable, Sendable {
        let users: Users?

        struct Users: Decodable, Sendable {
            /// The only count v2 carries. There is no total here: the registered-account number
            /// left with v1's `stats` block and did not come back.
            let activeMonth: Int?
        }
    }

    struct Registrations: Decodable, Sendable {
        let enabled: Bool?
        let approvalRequired: Bool?
    }

    /// `id` and `hint` are on the wire and are not read: the first orders a list this app shows
    /// in the order it arrived, and the second is a second paragraph written for a sign-up form
    /// this app does not have.
    struct Rule: Decodable, Sendable {
        let text: String?
    }

    func asProfile(host: String) -> SourceProfile {
        SourceProfile(
            host: host,
            kind: .mastodon,
            title: title,
            summary: description,
            // A stranger's address, admitted under the rule every other address in this package
            // is admitted under.
            thumbnail: Host.fetchableURL(thumbnail?.url),
            activeMonth: usage?.users?.activeMonth,
            registration: Self.registration(registrations),
            // The rules a server did not send and the rules a server has none of are the same
            // nothing to draw. See `SourceProfile.rules`.
            rules: (rules ?? []).compactMap(\.text)
        )
    }

    /// Two booleans into the three answers a reader can act on.
    ///
    /// **Closed is read off `enabled` alone.** A server with registrations off has said no, and
    /// whether it would also have required approval is a setting nobody can act on. Where
    /// `enabled` is absent the server has said nothing, and nothing is what this returns —
    /// guessing `open` would invite a reader to sign up somewhere that may not take them.
    private static func registration(_ wire: Registrations?) -> SourceProfile.Registration? {
        guard let enabled = wire?.enabled else { return nil }
        guard enabled else { return .closed }
        return wire?.approvalRequired == true ? .byApproval : .open
    }
}

struct StatusDTO: Decodable, Sendable {
    let id: String
    let uri: String?
    let url: String?
    let createdAt: Date
    let content: String
    let account: Account
    let reblog: Box<StatusDTO>?
    let inReplyToId: String?
    let mentions: [Mention]?
    let visibility: String?
    let repliesCount: Int?
    let reblogsCount: Int?
    let favouritesCount: Int?
    let mediaAttachments: [MediaAttachment]?
    /// Whether the author covered it, and the line they covered it with. Optional because a
    /// server that did not send them has told us nothing, which is not the same as telling us
    /// there is nothing: `"spoiler_text": ""` is a server saying there is no line, and absent
    /// is a server that never had the idea. `Note` keeps the two apart, so neither is folded
    /// into the other on the way there.
    let sensitive: Bool?
    let spoilerText: String?
    /// The pictures the words are partly written in. Absent on the odd server, which is a post
    /// written in letters alone rather than a status worth failing.
    let emojis: [Emoji]?

    struct Account: Decodable, Sendable {
        let displayName: String
        let acct: String
        let username: String?
        let avatar: String?
        /// The pictures the display name is partly written in. A shortcode means one picture
        /// on one server, so these and the status's own are one alphabet and not two.
        let emojis: [Emoji]?
    }

    /// One custom emoji: the name between the colons, and the picture it stands for.
    ///
    /// Both addresses go through `Host.fetchableURL`, because an emoji is fetched by exactly
    /// the same cache that fetches an attachment and so carries exactly the same risk. An
    /// emoji whose `url` this device will not go to is an emoji with no picture, and is
    /// dropped: keeping it would put a shortcode in the dictionary that can never resolve,
    /// which draws a blank where the author wrote a word. A refused `static_url` is only a
    /// still we have not got, which the animated file already covers.
    struct Emoji: Decodable, Sendable {
        let shortcode: String
        let url: String?
        let staticUrl: String?

        var asEmoji: CustomEmoji? {
            guard !shortcode.isEmpty, let address = Host.fetchableURL(url) else { return nil }
            return CustomEmoji(
                shortcode: shortcode,
                url: address,
                staticURL: Host.fetchableURL(staticUrl)
            )
        }
    }

    struct Mention: Decodable, Sendable {
        let acct: String
    }

    /// What came attached. `type` is the server's own word for it, kept rather than guessed
    /// at from the address, which rarely says.
    struct MediaAttachment: Decodable, Sendable {
        let type: String?
        let url: String?
        let previewUrl: String?
        /// What the author wrote for somebody who cannot see it.
        let description: String?
        /// What shape the file is. Mastodon nests it, and only `original` is read: `small` is
        /// the shape of the still, and the slot is drawn from the file's own shape.
        let meta: Meta?

        struct Meta: Decodable, Sendable {
            let original: Size?

            struct Size: Decodable, Sendable {
                let width: Int?
                let height: Int?
            }
        }

        /// Nothing where neither address survived the wire — there is no screen that can draw
        /// such an attachment and no reader who can open it, whatever else it carried. An alt
        /// text with no picture under it is words about nothing.
        var asAttachment: Attachment? {
            let attachment = Attachment(
                kind: Self.kind(of: type),
                url: Host.fetchableURL(url),
                previewURL: Host.fetchableURL(previewUrl),
                alt: description ?? "",
                width: meta?.original?.width,
                height: meta?.original?.height
            )
            return attachment.isEmpty ? nil : attachment
        }

        /// **A `gifv` is a video.** It is a silent looping MP4 that Mastodon made out of
        /// somebody's GIF, not a GIF, and it is the commonest moving thing on a timeline —
        /// filed as anything else it becomes a still that will not play.
        ///
        /// A word this build has never heard of is `unknown`, which is a truthful answer and
        /// not a failure: one strange attachment must never cost the reader the page.
        private static func kind(of type: String?) -> Attachment.Kind {
            switch type {
            case "image": .image
            case "video", "gifv": .video
            case "audio": .audio
            default: .unknown
            }
        }
    }

    func asNote(source: Source, category: Category) -> Note {
        let subject = reblog?.value ?? self
        // Named once, so the name the row draws and the pictures that name is written in
        // cannot come to disagree about whether there is a booster at all.
        let booster = reblog == nil ? nil : account
        let host = source.host
        return Note(
            id: subject.uri ?? "https://\(host)/statuses/\(subject.id)",
            source: source,
            author: subject.account.name,
            handle: Self.handle(subject.account.acct, host: host),
            body: HTMLText.plain(subject.content),
            postedAt: subject.createdAt,
            categories: [category],
            reply: Self.reply(inReplyToId: subject.inReplyToId, mentions: subject.mentions, host: host),
            boostedBy: booster?.name,
            audience: Self.audience(subject.visibility),
            avatarURL: Host.fetchableURL(subject.account.avatar),
            attachments: subject.mediaAttachments?.compactMap { $0.asAttachment } ?? [],
            sensitive: subject.sensitive,
            spoiler: subject.spoilerText,
            emojis: Self.emojis(of: subject, boostedBy: booster),
            // **Decision 9's rule, at the field it had been missed at.** The avatar two lines up,
            // the attachments and the emoji all go through `Host.fetchableURL`; this one went
            // through bare `URL(string:)`, so `javascript:`, `data:` and `file:///` all survived
            // out of a stranger's JSON into a `Note`. It had been harmless only because nothing
            // opened it — unit F7 gives the reader a button that does, and a check added at that
            // button alone would be the rule enforced at the consumer's door that this branch has
            // twice written down as the shape it gets wrong. So it is fixed here, where the data
            // stops being ours, and checked there as well.
            url: Host.fetchableURL(subject.url),
            counts: Counts(
                replies: subject.repliesCount,
                reblogs: subject.reblogsCount,
                favourites: subject.favouritesCount
            )
        )
    }

    /// Every alphabet the row can actually need, folded into one list.
    ///
    /// **Three accounts are in play on a boost, and the row draws words from all three.**
    /// `subject.emojis` spell the boosted status's body and its spoiler line;
    /// `subject.account.emojis` spell the name the row draws as the author; and the booster's
    /// own `account.emojis` spell the name it draws as `boostedBy`. Leave the third out and a
    /// booster called `:blobcat:` is drawn as eight letters and two colons on every boost they
    /// make. On anything else `subject` is `self`, so the third list *is* the second and the
    /// fold takes the copy back out.
    ///
    /// One shortcode can mean one picture on the booster's server and a different one on the
    /// author's, and a single list per note cannot hold both. The boosted status's own list is
    /// offered first and first spelling wins, because that status is the post: its body and
    /// its spoiler line are nearly all the words on the row, and a name is a few.
    private static func emojis(of subject: StatusDTO, boostedBy booster: Account?) -> [CustomEmoji] {
        let raw = (subject.emojis ?? []) + (subject.account.emojis ?? []) + (booster?.emojis ?? [])
        return CustomEmoji.folded(raw.compactMap(\.asEmoji))
    }

    static func handle(_ acct: String, host: String) -> String {
        acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
    }

    private static func reply(inReplyToId: String?, mentions: [Mention]?, host: String) -> Reply? {
        guard inReplyToId != nil else { return nil }
        if let acct = mentions?.first?.acct {
            return Reply(handle: handle(acct, host: host))
        }
        return Reply(handle: nil)
    }

    private static func audience(_ visibility: String?) -> Audience? {
        switch visibility {
        case "public": .everyone
        case "unlisted": .unlisted
        case "private": .followers
        case "direct": .mentioned
        default: nil
        }
    }
}

extension StatusDTO.Account {
    var name: String {
        displayName.isEmpty ? (username ?? acct) : displayName
    }
}

/// `reblog` nests a status inside itself; a class box keeps the type finite.
final class Box<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped
    init(from decoder: any Decoder) throws {
        value = try Wrapped(from: decoder)
    }
}
