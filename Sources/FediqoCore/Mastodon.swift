import Foundation

public struct MastodonClient: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    /// The public timeline's newest page, or where `olderThan` names a post, the page of posts
    /// older than it — the next stretch of a listing read toward its end (#87).
    public func publicTimeline(source: Source, olderThan maxID: String? = nil) async throws -> [Note] {
        try await statuses(
            path: "/api/v1/timelines/public",
            limit: MastodonReadOn.limit,
            olderThan: maxID,
            source: source,
            category: .public
        )
    }

    /// The public timeline read on from `anchor`, the newest post held of it (#201): stretch
    /// after stretch toward the newest, or the newest stretch alone where nothing is held.
    /// `held` is the posts held of it, which a read with no anchor looks for (`MastodonReadOn`).
    public func publicTimeline(
        source: Source, readingOnFrom anchor: String?, holding held: Set<NoteKey> = []
    ) async throws -> ReadOn {
        try await MastodonReadOn.read(from: anchor, holding: held) { minID in
            try await listed(
                path: "/api/v1/timelines/public", limit: MastodonReadOn.limit,
                query: try MastodonPage.newer(than: minID), source: source, category: .public
            )
        } older: { maxID in
            try await listed(
                path: "/api/v1/timelines/public", limit: MastodonReadOn.limit,
                query: try MastodonPage.older(than: maxID), source: source, category: .public
            )
        }
    }

    /// The public timeline read down from a place posts may be missing (#204), toward what is held
    /// below it (`MastodonReadOn.readDown`).
    public func publicTimeline(source: Source, readingDownFrom place: MissingPlace) async throws -> ReadDown {
        try await MastodonReadOn.readDown(from: place) { maxID in
            try await listed(
                path: "/api/v1/timelines/public", limit: MastodonReadOn.limit,
                query: try MastodonPage.older(than: maxID), source: source, category: .public
            )
        }
    }

    /// How many trending posts one ask brings: a stretch of what is rising.
    public static let trendsStretch = 20

    /// What is rising on this source: one stretch of its trending posts, `offset` posts into the
    /// list — the top of it where 0 (#288).
    ///
    /// **By how far into the list, not by a post**: a ranking has no "older than", and a source
    /// pages it by an offset. It gives as far down as it chooses to and no further; a stretch
    /// shorter than was asked for, or empty, is its "no more". The list moves between two asks,
    /// so a post may come twice or be skipped — which the store settles, holding one row per
    /// post, and which nothing here tries to repair.
    public func trending(source: Source, offset: Int = 0) async throws -> [Note] {
        try await listed(
            path: "/api/v1/trends/statuses",
            limit: Self.trendsStretch,
            query: offset > 0 ? [URLQueryItem(name: "offset", value: String(offset))] : [],
            source: source,
            category: .trends
        ).landing
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
        let data: Data
        do {
            data = try await instanceDocument()
        } catch MastodonRequestError.invalidURL {
            // Nothing was asked, so nothing answered badly. `unreadable` would claim a
            // server sent something unreadable when no request was ever built.
            throw ProfileError.unreachable
        } catch MastodonRequestError.http(let status) {
            throw ProfileError.of(status: status)
        }
        return try MastodonJSON.decoder.decode(InstanceDTO.self, from: data).asProfile(host: host)
    }

    /// `/api/v2/instance`, fetched — **the one place its address is built and its status read**.
    ///
    /// Three readers want this document for three different things: what the server says about
    /// itself, what it says it is, and how long a post on it may be. They wanted it through
    /// three copies of the same four lines, each of which had to remember the same rule.
    ///
    /// **The status is read before the body is, and that ordering is the whole guard.** A
    /// Mastodon older than 4.0 does not have this endpoint and answers 404 with a page of HTML;
    /// a decoder handed that reports a corrupt profile for a server whose only fault is its age.
    /// Nothing non-2xx reaches `JSONDecoder` from here.
    ///
    /// The failure is spelled in this type's own error, and the one caller that owes its reader
    /// a different vocabulary — `profile()`, which speaks `ProfileError` — translates it at the
    /// call. That is one translation rather than three spellings of one rule.
    private func instanceDocument() async throws -> Data {
        guard let url = Host.httpsURL(host: host, path: "/api/v2/instance") else {
            throw MastodonRequestError.invalidURL
        }
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonRequestError.http(response.statusCode)
        }
        return data
    }

    /// **What this server says it is, now** — the flavour, asked of the server rather than read
    /// off what was written down when it was joined.
    ///
    /// The same document, the same rule and the same one endpoint the detector's probe reads:
    /// `Probe.kind(from:)` is shared rather than spelled again here, so a server that a join
    /// would name one thing cannot be named another by a read. A host is joined once and read
    /// for as long as the reader keeps it, and in between it can be migrated, replaced, or
    /// upgraded into a different program — the name is the server's to tell, and this is the
    /// asking.
    ///
    /// **Non-2xx throws rather than answering `.unknown`.** "It would not say" and "it said
    /// something this app does not know" are different facts about a server and only one of them
    /// is the server's own answer; a caller that cannot tell them apart would start treating an
    /// outage as a migration.
    public func flavour() async throws -> ProtocolKind {
        Probe.kind(from: try await instanceDocument())
    }

    /// `flavour()`, and what the same document says the server is like (#188) — one request,
    /// two readings. The profile is nothing where the document named a kind and nothing more
    /// this app could decode, so a read that could say what the server is still says it.
    ///
    /// The profile carries the kind the probe read rather than `.mastodon` flat, so what is
    /// written down about a Pleroma is written down as a Pleroma's word. How long a post may be
    /// is `profile?.statusLimit`, through `MastodonWrite.limit(advertised:)` — Mastodon's 500
    /// where the server answered without saying.
    ///
    /// **Throws where the document did not come**, so a caller that remembers the answer can tell
    /// a dark network, which is worth asking again, from a server that answered (#222).
    public func introduction() async throws -> (kind: ProtocolKind, profile: SourceProfile?) {
        let data = try await instanceDocument()
        let kind = Probe.kind(from: data)
        let profile = (try? MastodonJSON.decoder.decode(InstanceDTO.self, from: data))?
            .asProfile(host: host, kind: kind)
        return (kind, profile)
    }

    private func statuses(
        path: String,
        limit: Int,
        olderThan maxID: String? = nil,
        source: Source,
        category: Category
    ) async throws -> [Note] {
        try await listed(
            path: path, limit: limit, query: try MastodonPage.older(than: maxID), source: source, category: category
        ).landing
    }

    /// One page, each post with the id the timeline lists it under — a boost's own.
    private func listed(
        path: String,
        limit: Int,
        query: [URLQueryItem],
        source: Source,
        category: Category
    ) async throws -> [Listed] {
        guard let url = Host.httpsURL(
            host: host,
            path: path,
            query: [URLQueryItem(name: "limit", value: String(limit))] + query
        ) else {
            throw MastodonRequestError.invalidURL
        }
        let sent = ReadMoment.now()
        let (data, response) = try await http.data(from: url)
        guard (200..<300).contains(response.statusCode) else {
            throw MastodonRequestError.http(response.statusCode)
        }
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data).map {
            $0.listed(source: source, category: category, sent: sent)
        }
    }
}

/// What a read of a Mastodon server, made without a token, ended in.
///
/// **Public because a pane has to tell a refusal from the dark.** A thread that the server said
/// no to and a thread that nothing answered are two different sentences and only one of them is
/// worth a second press — `ShellConversations.Absence` is where that judgement is made, and it
/// cannot make it against an error it cannot name.
public enum MastodonRequestError: Error, Equatable, Sendable {
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
    let configuration: Configuration?
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

    struct Configuration: Decodable, Sendable {
        let statuses: Statuses?

        struct Statuses: Decodable, Sendable {
            let maxCharacters: Int?
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

    func asProfile(host: String, kind: ProtocolKind = .mastodon) -> SourceProfile {
        SourceProfile(
            host: host,
            kind: kind,
            title: title,
            summary: description,
            // A stranger's address, admitted under the rule every other address in this package
            // is admitted under.
            thumbnail: Host.fetchableURL(thumbnail?.url),
            activeMonth: usage?.users?.activeMonth,
            statusLimit: Self.statusLimit(configuration?.statuses?.maxCharacters),
            registration: Self.registration(registrations),
            // The rules a server did not send and the rules a server has none of are the same
            // nothing to draw. See `SourceProfile.rules`.
            rules: (rules ?? []).compactMap(\.text)
        )
    }

    /// A positive advertised ceiling, or nothing — zero and below are a server that said
    /// something useless, not a status that may be no characters at all.
    private static func statusLimit(_ advertised: Int?) -> Int? {
        guard let advertised, advertised > 0 else { return nil }
        return advertised
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
    /// When the status was last edited (#286), or nothing where it never was — and on a server
    /// older than editing, which sends no such field.
    ///
    /// **Read leniently**, as `quote` is: a moment this build cannot read is no word about a
    /// change, and never costs the reader the status — or the page it is on, which one status
    /// that will not decode takes with it.
    let editedAt: LenientMoment?

    /// A moment in the spelling this decoder reads dates in, or nothing where it is spelled any
    /// other way — rather than a failed decode. Its own type and not `Lenient<Date>`: a `Date`
    /// decoded by itself reads a number, not the decoder's date strategy.
    struct LenientMoment: Decodable, Sendable {
        let value: Date?

        init(from decoder: any Decoder) throws {
            value = (try? decoder.singleValueContainer().decode(String.self)).flatMap(MastodonJSON.date(from:))
        }
    }
    let content: String
    let account: Account
    let reblog: Box<StatusDTO>?
    let inReplyToId: String?
    let mentions: [Mention]?
    let visibility: String?
    let repliesCount: Int?
    let reblogsCount: Int?
    let favouritesCount: Int?
    /// Whether the account this was fetched as has boosted it (#106). Absent on every unsigned
    /// read, which Mastodon does not send this field on at all — see `Note.boosted`, which keeps
    /// absent and `false` apart for that reason.
    let reblogged: Bool?
    /// Whether the account this was fetched as has favourited it (#107). Absent on an unsigned
    /// read, as `reblogged` is.
    let favourited: Bool?
    /// The language the status says it is in (#287), or nothing where it says none. Read
    /// leniently: a value of another shape is no language, and never costs the status.
    let language: Lenient<String>?
    /// Whether the account this was fetched as has bookmarked it (#285). Absent on an unsigned
    /// read, as `reblogged` is.
    let bookmarked: Bool?
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
    /// The post this one quotes (#214), on a server that has quotes (Mastodon 4.4 on). Absent on
    /// one that has none, and `null` on a status that quotes nothing: both are no quote.
    ///
    /// **Read leniently** (`Lenient`): a `quote` of a shape this build cannot read — a fork's own
    /// idea, a string — is no quote, and never costs the reader the status or the page it is on.
    let quote: Lenient<QuoteDTO>?

    /// A value read where it can be and nothing where it cannot, rather than a failed decode.
    struct Lenient<Wrapped: Decodable & Sendable>: Decodable, Sendable {
        let value: Wrapped?

        init(from decoder: any Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    /// The quote this status states, or nothing — including a `quote` that names no state, which
    /// is no quote this app can say anything about (and whose `RE:` line is then kept).
    func quote(source: Source) -> Quote? {
        quote?.value?.asQuote(source: source)
    }

    /// Mastodon's `Quote`, or its `ShallowQuote` a level down: a state, and the quoted status in
    /// full or by its id alone.
    struct QuoteDTO: Decodable, Sendable {
        let state: String?
        let quotedStatus: Box<StatusDTO>?
        let quotedStatusId: String?

        /// What a note keeps of it. The quoted status is read the way any status is, through
        /// the same source, and cut to what a row draws of it (`QuotedPost`). Nothing where no
        /// state was said.
        func asQuote(source: Source) -> Quote? {
            guard state != nil else { return nil }
            let quoted = quotedStatus?.value
            return Quote(
                state: Quote.State(wire: state),
                post: quoted.map { QuotedPost($0.unstamped(source: source, categories: [])) },
                statusID: quoted?.id ?? quotedStatusId
            )
        }
    }

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

    /// This status as a timeline listed it (#201): the item, carrying the id the listing gave it
    /// as that timeline's — and, where the status is a reblog (#290), the post it reblogs beside
    /// it, which the listing brought in the same payload and did not list.
    func listed(source: Source, category: Category, sent: ReadMoment) -> Listed {
        let arrived = arrival(source: source, categories: [category], sent: sent)
        var note = arrived.item
        note.listed = [category: id]
        return (id, note, arrived.reblogged.map { [$0] } ?? [])
    }

    /// This status as it arrives through `categories` (#290): the item it is, and the post it
    /// reblogs where it is a reblog.
    ///
    /// **A reblog is two things.** The reblog is an item of its own: who reblogged, when, and a
    /// reference to what — under the id its source gave the reblog, at the reblog's own time,
    /// through the categories it arrived through. It has no words, pictures, cover, counts or
    /// reader's marks: those are the post's. The post it reblogs is an ordinary item at its own
    /// publish time, **through no category**: it came in the payload and not through the
    /// timeline, so a rule on a category shows it only if it also arrives on its own.
    ///
    /// **Everything here is a stranger's word, and the reblog's identity is made from it**, so:
    /// - a reblog its source gave no `uri` is held under a name this device makes of the host and
    ///   the reblog's own id (`Note.inventedID`), which merges with nothing;
    /// - a name longer than a name may be is no name (`StatusDTO.name`): the reblog, or its
    ///   target, is held under the made-up one;
    /// - a reblog named as the very post it reblogs is given that made-up name instead, and one
    ///   that would still be the same row, or whose target's own id at its source is longer than
    ///   a name is (`Reference.bounded`), is no reblog: the post it carries arrives as itself;
    /// - a reblog of a reblog — which no server sends — refers to the inner one by name and
    ///   brings nothing with it: what is not a post is not taken in as one, and what lies under
    ///   the second `reblog` is never decoded (`Box`);
    /// - the target's id is a name looked up within this source (`Note.reblogKey`), whatever
    ///   host it spells. Nothing is ever asked of it.
    func arrival(source: Source, categories: Set<Category>, sent: ReadMoment) -> (item: Note, reblogged: Note?) {
        guard let inner = reblog?.value else {
            return (asNote(source: source, categories: categories, sent: sent), nil)
        }
        let host = source.host
        let targetID = inner.name ?? Note.inventedID(host: host, statusID: inner.id)
        let invented = Note.inventedID(host: host, statusID: id)
        let ownID = name.flatMap { $0 == targetID ? nil : $0 } ?? invented
        let reference = Reference(kind: .reblogs, id: targetID, statusID: inner.id)
        guard ownID != targetID, Reference.bounded([reference]) == [reference] else {
            return (asNote(source: source, categories: categories, sent: sent), nil)
        }
        // `statusID` is the reblog's own id at its source: what tells a made-up name from a
        // minted one (`Note.post`). It is never an id to send — see `Note.sendableID`.
        var item = Note(
            id: ownID, source: source, author: account.name,
            handle: Self.handle(account.acct, host: host), body: "", postedAt: createdAt,
            categories: categories, avatarURL: Host.fetchableURL(account.avatar),
            // The pictures the reblogger's name is written in, and no others: the post's own
            // are on the post.
            emojis: CustomEmoji.folded((account.emojis ?? []).compactMap(\.asEmoji)),
            statusID: id, refs: [reference]
        )
        item.asked = sent
        guard inner.reblog == nil else { return (item, nil) }
        var post = inner.post(source: source, categories: [])
        post.asked = sent
        return (item, post)
    }

    func asNote(source: Source, category: Category, sent: ReadMoment) -> Note {
        asNote(source: source, categories: [category], sent: sent)
    }

    /// This status as a note, and **when the read that brought it was sent** (#291) — taken
    /// before the request went out, by whoever sent it. Asked for by name and never defaulted:
    /// a status is the one thing that says what the reader did to a post, so every way one
    /// becomes a note says how old that word is, and a new way cannot forget to. The note must
    /// reach the store as this returns it: one made anew from it has lost the moment.
    func asNote(source: Source, categories: Set<Category>, sent: ReadMoment) -> Note {
        var note = unstamped(source: source, categories: categories)
        note.asked = sent
        return note
    }

    /// `asNote` without the moment: the post a status quotes, which is cut to what a row draws
    /// of it (`QuotedPost`) — and that is nothing of what the reader did to it.
    ///
    /// **The post, wherever the status is a reblog** (#290): a search, a tag, a thread, one post
    /// read again and the source's answer to an act all want the post a status is about, and a
    /// reblog is about the post it carries. Only a timeline's listing makes the reblog an item
    /// (`arrival`), since only there did somebody's reblog bring the post.
    fileprivate func unstamped(source: Source, categories: Set<Category>) -> Note {
        (reblog?.value ?? self).post(source: source, categories: categories)
    }

    /// This status as the post it is, reading nothing through a reblog it may carry.
    fileprivate func post(source: Source, categories: Set<Category>) -> Note {
        let subject = self
        let quote = subject.quote(source: source)
        let host = source.host
        return Note(
            // The name the post was minted under, where this server sent one — the fact two
            // servers carrying one status both state, and the whole of what #113 merges on.
            // Where it sent none, a name this device made up: `Note.inventedID` mints it and is
            // also what recognises it again, so a copy held under a made-up name is merged with
            // nothing rather than with whatever else happens to spell the same.
            id: subject.name ?? Note.inventedID(host: host, statusID: subject.id),
            source: source,
            author: subject.account.name,
            handle: Self.handle(subject.account.acct, host: host),
            // A quoting post's `RE:` line is the quote spelled as an address for readers that draw
            // none (#214); this one draws the quote. A post with no quote keeps every word.
            body: HTMLText.plain(
                quote == nil ? subject.content : HTMLText.withoutQuoteLine(subject.content)
            ),
            postedAt: subject.createdAt,
            categories: categories,
            reply: Self.reply(inReplyToId: subject.inReplyToId, mentions: subject.mentions, host: host),
            // **The post's own flag and never a reblog's**: what a reader means by "have I boosted
            // this" is about the post, and a reblog's own `reblogged` is about the reblog.
            boosted: subject.reblogged,
            favourited: subject.favourited,
            bookmarked: subject.bookmarked,
            audience: Self.audience(subject.visibility),
            avatarURL: Host.fetchableURL(subject.account.avatar),
            attachments: subject.mediaAttachments?.compactMap { $0.asAttachment } ?? [],
            sensitive: subject.sensitive,
            spoiler: subject.spoilerText,
            emojis: Self.emojis(of: subject),
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
            ),
            // The post's own id on this server: what the row is.
            statusID: subject.id,
            quote: quote,
            editedAt: Self.edited(subject.editedAt?.value, posted: subject.createdAt, now: Date()),
            language: subject.language?.value
        )
    }

    /// How far ahead of this device's clock a source's edit moment may be: a clock a few minutes
    /// out is ordinary, and anything past that is not a moment a post was changed at.
    static let editSkew: TimeInterval = 300

    /// When a status says it was changed, as this device will take it (#286): what it says, or
    /// **when it was published** where what it says is later than `now` and a little — a moment
    /// nothing was changed at.
    ///
    /// **The one thing two copies of a post are ordered by**, so a source naming a year far ahead
    /// would otherwise make every true copy that followed look older than the one held, and the
    /// row would never say anything new again. **And a value that does not move with the clock**:
    /// the same impossible moment read again is the same moment here, so the row is marked as
    /// changed once and rewritten for nothing after — and any true change, which cannot be
    /// earlier than the post, is later than it.
    static func edited(_ said: Date?, posted: Date, now: Date) -> Date? {
        said.map { $0 > now.addingTimeInterval(editSkew) ? posted : $0 }
    }

    /// Every alphabet the post's row can need, folded into one list: the status's own, which
    /// spell its words and its cover line, and its author's, which spell the name. A reblogger's
    /// are on the reblog (`arrival`), where the reblogger's name is.
    private static func emojis(of subject: StatusDTO) -> [CustomEmoji] {
        CustomEmoji.folded(((subject.emojis ?? []) + (subject.account.emojis ?? [])).compactMap(\.asEmoji))
    }

    static func handle(_ acct: String, host: String) -> String {
        acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
    }

    private static func reply(inReplyToId: String?, mentions: [Mention]?, host: String) -> Reply? {
        guard let inReplyToId else { return nil }
        if let acct = mentions?.first?.acct {
            return Reply(handle: handle(acct, host: host), inReplyToId: inReplyToId)
        }
        return Reply(handle: nil, inReplyToId: inReplyToId)
    }

    private static func audience(_ visibility: String?) -> Audience? {
        visibility.flatMap(Audience.init(mastodon:))
    }
}

extension StatusDTO.Account {
    var name: String {
        displayName.isEmpty ? (username ?? acct) : displayName
    }
}

/// `reblog` and a quote's `quoted_status` nest a status inside a status; a class box keeps the
/// type finite.
///
/// **One deep of each, by construction** (#290). A status inside a status is decoded; a status
/// under a second `reblog`, or a second `quoted_status`, is not decoded at all — `value` is
/// nothing, and no initialiser is entered for it. So however deep a stranger's JSON nests, what
/// is built from it is at most a status, the status it reblogs and the one that quotes: the
/// depth is this type's, never the payload's. No server sends a reblog of a reblog.
final class Box<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped?
    init(from decoder: any Decoder) throws {
        let path = decoder.codingPath.map(\.stringValue)
        let reblogs = path.filter { $0 == "reblog" }.count
        let quoted = path.filter { $0 == "quotedStatus" || $0 == "quoted_status" }.count
        value = reblogs > 1 || quoted > 1 ? nil : try Wrapped(from: decoder)
    }
}

extension StatusDTO {
    /// The name this status was minted under, where its server sent one **no longer than a name
    /// may be** (`Reference.longest`, in bytes). A longer one is not a name this device will key
    /// a row by or refer to: the status is then held under the name this device makes of the
    /// host and the status's own id (`Note.inventedID`), as one sent with no `uri` is.
    var name: String? {
        uri.flatMap { $0.utf8.count <= Reference.longest ? $0 : nil }
    }
}

/// The one way a Mastodon read asks for the stretch before a post (#87): `max_id`, checked as a
/// list id is, since the id came back out of the store. **One that is not an id asks nothing**:
/// dropping it would ask for the newest page instead, which is not the page anybody asked for.
enum MastodonPage {
    static func older(than maxID: String?) throws -> [URLQueryItem] {
        guard let maxID else { return [] }
        guard ListSubscription.isPathSegment(maxID) else { throw MastodonRequestError.invalidURL }
        return [URLQueryItem(name: "max_id", value: maxID)]
    }
}
