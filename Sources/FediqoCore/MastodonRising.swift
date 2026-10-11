import Foundation

// The hashtags and the links rising on a Mastodon (#320): `trends/tags` and `trends/links`.
//
// **Asked of a real one first** (`MastodonRisingCaptures`). Both are given to anyone, so they
// are asked with no sign-in. A new server answers each with an empty list — and **so does one
// whose administrator has switched what is rising off**: the two cannot be told apart, and
// nothing in the host's document says which. So an empty answer is the source giving none, and
// is never taken for the source having no such thing. Every figure of how much a hashtag or a
// link was used is a string, a day at a time, newest first.
//
// **A stranger's word, bounded where it enters.** A hashtag is its name held to the letters a
// hashtag is written in (`PostTag`), or it is not listed. A link is an address this device
// would follow from a post's words (`PostLink`: https, a host, nobody's credentials, the host
// in ASCII), or it is not listed; what the source says of it — a title, a line about it — is
// text, made fit for a line of ours. **Nothing about a link is fetched by listing it**: no
// picture is read, no page is asked, and the address the source gives for a preview picture is
// not kept at all.
//
// **The figures are the source's counts**, read leniently (`MastodonFigure`) and added over the
// two newest days it gives — as it adds them on its own pages. Somebody who used a hashtag on
// both days is counted on each: it is the source's sum, said as the source's.

/// How much a hashtag or a link was used of late, as its source counts.
public struct RisingUse: Sendable, Hashable {
    /// The posts that used it, and the people who did, over `days` — each the source's count
    /// added over those days, or nothing where it said none that is a count.
    public let posts: Int?
    public let people: Int?
    /// How many days the figures are of: the newest the source gave, two at most. None where
    /// it gave no day at all, and then no figure.
    public let days: Int

    /// How many of the newest days are added.
    public static let span = 2

    public static let unsaid = RisingUse(posts: nil, people: nil, days: 0)

    public init(posts: Int?, people: Int?, days: Int) {
        self.posts = posts
        self.people = people
        self.days = max(0, min(days, Self.span))
    }

    /// Whether there is any figure to say.
    public var isSaid: Bool { days > 0 && (posts != nil || people != nil) }
}

/// A hashtag a source says is rising.
public struct RisingTag: Sendable, Hashable {
    /// The hashtag, as the source wrote it and as a post's words would carry it.
    public let tag: PostTag
    public let use: RisingUse

    public init(tag: PostTag, use: RisingUse = .unsaid) {
        self.tag = tag
        self.use = use
    }
}

/// A link a source says is rising.
public struct RisingLink: Sendable, Hashable {
    /// Where it leads: an address this device would follow from a post's words, and the host
    /// a reader is told they are taken to.
    public let link: PostLink
    /// What the source says the page is called, fit for a line of ours. Empty where it says
    /// nothing: the address is then what the row is called.
    public let title: String
    /// What the source says of the page, fit for a line. Empty where it says nothing.
    public let words: String
    public let use: RisingUse

    public static let titleLength = 200
    public static let wordsLength = 300

    public init(link: PostLink, title: String = "", words: String = "", use: RisingUse = .unsaid) {
        self.link = link
        self.title = LineText.oneLine(title, limit: Self.titleLength)
        self.words = LineText.oneLine(words, limit: Self.wordsLength)
        self.use = use
    }
}

/// A Mastodon asked for what is rising on it beside posts: `trends/tags` and `trends/links`,
/// each with no sign-in, one stretch.
///
/// **Whoever reads hands in a client that is watched, admitted and small** — in the app, one
/// made by `SourceReach.unsignedRising`, never a bare `URLSessionClient()`.
///
/// **Nothing here writes anywhere on this device.** A read lands in what it returns; one that
/// is refused or fails throws and changes nothing.
public struct MastodonRising: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    static let tagsPath = "/api/v1/trends/tags"
    static let linksPath = "/api/v1/trends/links"
    /// How many are asked for, and the most that are listed: what a Mastodon gives at most.
    public static let stretch = 20
    /// How long a hashtag's name, and an address, may be to be listed.
    static let nameLength = 100
    static let addressLength = 2_048

    /// The hashtags rising, in the source's order. **Entry by entry**: one that is no hashtag
    /// is that one not listed. A hashtag given twice, however it is written, is listed once.
    public func tags() async throws -> [RisingTag] {
        let body = try await get(Self.tagsPath)
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<TagSaid>].self, from: body) else {
            throw MastodonHostMoreError.unreadable
        }
        return Self.listed(wire, most: Self.stretch)
    }

    /// One hashtag as a Mastodon sends it, wherever it lists hashtags: its name without the
    /// mark, and how much it was used, a day at a time.
    struct TagSaid: Decodable, Sendable {
        let name: String
        let history: StatusDTO.Lenient<[StatusDTO.Lenient<Day>]>?
    }

    /// The hashtags a source listed, in its order and `most` at most — **the one reader of a
    /// list of hashtags**, for what is rising and for what a search found (#319). Entry by
    /// entry: one that is no hashtag is that one not listed, and a hashtag given twice,
    /// however it is written, is listed once.
    static func listed(_ wire: [StatusDTO.Lenient<TagSaid>], most: Int) -> [RisingTag] {
        var seen: Set<String> = []
        var listed: [RisingTag] = []
        for entry in wire.prefix(most * 4) {
            guard listed.count < most, let said = entry.value, said.name.unicodeScalars.count <= Self.nameLength,
                  let tag = PostTag("#" + said.name), seen.insert(Self.folded(tag)).inserted
            else { continue }
            listed.append(RisingTag(tag: tag, use: Day.use(said.history?.value)))
        }
        return listed
    }

    /// The links rising, in the source's order. **Entry by entry**: one whose address this
    /// device would not follow is that one not listed. An address given twice is listed once.
    public func links() async throws -> [RisingLink] {
        struct Wire: Decodable, Sendable {
            let url: String
            let title: StatusDTO.Lenient<String>?
            let description: StatusDTO.Lenient<String>?
            let history: StatusDTO.Lenient<[StatusDTO.Lenient<Day>]>?
        }
        let body = try await get(Self.linksPath)
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Wire>].self, from: body) else {
            throw MastodonHostMoreError.unreadable
        }
        var seen: Set<URL> = []
        var listed: [RisingLink] = []
        for entry in wire.prefix(Self.stretch * 4) {
            guard listed.count < Self.stretch, let said = entry.value, said.url.utf8.count <= Self.addressLength,
                  let link = Self.link(said.url), seen.insert(link.url).inserted
            else { continue }
            listed.append(RisingLink(
                link: link, title: Self.bounded(said.title?.value, to: RisingLink.titleLength),
                words: Self.bounded(said.description?.value, to: RisingLink.wordsLength), use: Day.use(said.history?.value)
            ))
        }
        return listed
    }

    /// A hashtag folded as the servers this app reads treat one: whatever case and width it
    /// was written in. What a page of hashtags tells its rows apart by, and so what one is
    /// listed once by.
    public static func folded(_ tag: PostTag) -> String {
        tag.name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// An address a source gave, as a link a post's words could carry: **spelled as the wire
    /// spells it** — a host's name not in ASCII is its punycode, so the host a reader is told
    /// is the name asked for and never a picture of another — and then held to `PostLink`'s
    /// rule. Nothing where it is not such an address.
    static func link(_ raw: String) -> PostLink? {
        guard let spelled = URL(string: raw)?.absoluteString, spelled.utf8.allSatisfy({ $0 < 128 }),
              let link = PostLink(spelled), link.host.utf8.allSatisfy({ $0 < 128 && $0 != UInt8(ascii: "%") })
        else { return nil }
        return link
    }

    /// What a source said, cut before it is cleaned: cleaning costs its length.
    private static func bounded(_ said: String?, to length: Int) -> String {
        String(String.UnicodeScalarView((said ?? "").unicodeScalars.prefix(length * 4)))
    }

    /// One day of use, as a Mastodon sends it: the day a moment in seconds, and each figure a
    /// string.
    struct Day: Decodable, Sendable {
        let day: MastodonFigure?
        let accounts: MastodonFigure?
        let uses: MastodonFigure?

        /// The newest `RisingUse.span` days the source named, added. A day named by no moment
        /// is not a day; a figure that is no count is left out of its sum, and a sum of none
        /// is not said.
        static func use(_ history: [StatusDTO.Lenient<Day>]?) -> RisingUse {
            let days = (history ?? []).prefix(32).compactMap(\.value)
                .filter { $0.day?.value != nil }
                .sorted { ($0.day?.value ?? 0) > ($1.day?.value ?? 0) }
                .prefix(RisingUse.span)
            func sum(_ figures: [Int]) -> Int? {
                figures.isEmpty ? nil : min(figures.reduce(0, +), MastodonFigure.most)
            }
            return RisingUse(
                posts: sum(days.compactMap { $0.uses?.value }), people: sum(days.compactMap { $0.accounts?.value }),
                days: days.count
            )
        }
    }

    /// One of the two, fetched — asked for `stretch`: `noSuchAddress` where the host says the
    /// address is not there, and what an unsigned read throws for any other refusal.
    private func get(_ path: String) async throws -> Data {
        let length = [URLQueryItem(name: "limit", value: String(Self.stretch))]
        guard let url = Host.httpsURL(host: host, path: path, query: length) else { throw MastodonRequestError.invalidURL }
        let (body, response) = try await http.data(from: url)
        if MastodonHostNotFound.isOfTheAddress(status: response.statusCode, body: body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        guard (200..<300).contains(response.statusCode) else { throw MastodonRequestError.http(response.statusCode) }
        return body
    }
}
