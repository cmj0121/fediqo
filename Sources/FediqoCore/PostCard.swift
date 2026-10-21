import Foundation

/// The preview of the page a post links to (#335), as its source fetched it: what the page says it
/// is called and is about, who publishes and wrote it, where it leads, and its picture with the
/// picture's size.
///
/// **A stranger's page, read by a stranger's server**, so every word is cleaned and bounded here,
/// where it stops being theirs, and every address goes through this package's rules: where it
/// leads is a link only as a link in the words is (`PostLink.followable`), and its picture is an
/// address this device fetches only as it fetches an attachment (`Host.fetchableURL`) — through
/// the allowance its source's pictures are asked under. A preview whose page this device would
/// not follow keeps its words, and leads nowhere.
public struct PostCard: Hashable, Sendable {
    /// What the page is called. Never empty: a preview with no title is no preview.
    public let title: String
    /// What the page says it is about, or nothing where it says nothing.
    public let description: String?
    /// Who publishes the page, and who wrote it, where the page says.
    public let provider: String?
    public let author: String?
    /// Where the preview leads, where this device follows it.
    public let url: URL?
    /// The page's picture, where it has one this device fetches, and its size where the source
    /// said one.
    public let image: URL?
    public let width: Int?
    public let height: Int?
    /// Whether the source says the page names an author it could not credit (Mastodon 4.6), or
    /// nothing where it says nothing of it.
    public let missingAttribution: Bool?

    /// How long each part may run: a title and a name are lines; a description a few.
    public static let titleLength = 200
    public static let descriptionLength = 500
    public static let nameLength = 100
    /// The largest side a picture is believed to have.
    public static let largestSide = 16_384

    public init(
        title: String, description: String? = nil, provider: String? = nil, author: String? = nil, url: URL? = nil,
        image: URL? = nil, width: Int? = nil, height: Int? = nil, missingAttribution: Bool? = nil
    ) {
        self.title = title
        self.description = description
        self.provider = provider
        self.author = author
        self.url = url
        self.image = image
        self.width = width
        self.height = height
        self.missingAttribution = missingAttribution
    }

    /// The longest address kept, of where a card leads and of its picture, in bytes — refused
    /// before it is parsed (`MastodonRising.addressLength`'s bound).
    public static let addressLength = MastodonRising.addressLength

    /// A card read off the wire, cleaned and bounded. **Nothing where it has nothing to draw**: no
    /// title and no page this device follows. A card with no title of its own — a page that says
    /// only what it is about, a picture's — is called by the host it leads to.
    init?(
        reading title: String?, description: String?, provider: String?, author: String?, url: String?, image: String?,
        width: Int?, height: Int?, missingAttribution: Bool?
    ) {
        self.init(
            checking: Self.line(title, limit: Self.titleLength), description: Self.line(description, limit: Self.descriptionLength),
            provider: Self.line(provider, limit: Self.nameLength), author: Self.line(author, limit: Self.nameLength),
            url: url, image: image, width: width, height: height, missingAttribution: missingAttribution
        )
    }

    /// A card as a store kept it, **held to the bounds again, whoever wrote the cell**: each line
    /// made one line of its length (and the mark that says it was cut), its sides and addresses by
    /// the rules a card is read under. Its words are not stripped of markup a second time: they
    /// were stripped on the way in, and an entity would be decoded twice.
    public init?(
        stored title: String?, description: String?, provider: String?, author: String?, url: String?, image: String?,
        width: Int?, height: Int?, missingAttribution: Bool?
    ) {
        func again(_ text: String?, _ limit: Int) -> String? {
            guard let text else { return nil }
            let said = LineText.oneLine(text, limit: limit + 1).trimmingCharacters(in: .whitespaces)
            return said.isEmpty ? nil : said
        }
        self.init(
            checking: again(title, Self.titleLength), description: again(description, Self.descriptionLength),
            provider: again(provider, Self.nameLength), author: again(author, Self.nameLength),
            url: url, image: image, width: width, height: height, missingAttribution: missingAttribution
        )
    }

    /// The card from lines already cleaned, and addresses and sides not yet checked.
    private init?(
        checking title: String?, description: String?, provider: String?, author: String?, url: String?, image: String?,
        width: Int?, height: Int?, missingAttribution: Bool?
    ) {
        let link = Self.link(url)
        guard let title = title ?? link.flatMap({ PostLink($0.absoluteString)?.host }) else { return nil }
        let side = { (value: Int?) in value.flatMap { $0 > 0 && $0 <= Self.largestSide ? $0 : nil } }
        let (width, height) = (side(width), side(height))
        // A size only where both sides were said: one alone is no shape.
        let sized = width != nil && height != nil
        self.init(
            title: title, description: description, provider: provider, author: author, url: link,
            image: Self.picture(image), width: sized ? width : nil, height: sized ? height : nil,
            missingAttribution: missingAttribution
        )
    }

    /// Where a card leads, where this device follows it: bounded before it is parsed, and a link as
    /// a link in the words is (`PostLink.followable`).
    static func link(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= addressLength else { return nil }
        return PostLink.followable(raw)
    }

    /// A card's picture, where this device fetches it: bounded before it is parsed, fetched as an
    /// attachment is (`Host.isFetchable`), and never an address carrying somebody's credentials.
    static func picture(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= addressLength, let url = URL(string: raw), Host.isFetchable(url),
              url.user() == nil, url.password() == nil
        else { return nil }
        return url
    }

    /// What its words weigh, in the bytes they are written in: what a post's weight adds (#294).
    var bytes: Int {
        title.utf8.count + (description?.utf8.count ?? 0) + (provider?.utf8.count ?? 0) + (author?.utf8.count ?? 0)
    }

    /// `raw` with its markup and entities taken out, made one line of at most `limit`, or nothing
    /// where nothing is left.
    private static func line(_ raw: String?, limit: Int) -> String? {
        LineText.cleanLine(raw, limit: limit)
    }
}

extension StatusDTO {
    /// Mastodon's `PreviewCard`, in the fields a preview is made of. Every one read leniently: a
    /// stranger's server sends a field of another shape, and that costs the field.
    struct CardDTO: Decodable, Sendable {
        let url: Lenient<String>?
        let title: Lenient<String>?
        let description: Lenient<String>?
        let providerName: Lenient<String>?
        let authorName: Lenient<String>?
        /// 4.3 on: the authors the page names, each with a name; the first is the one kept where
        /// `author_name` says none.
        let authors: Lenient<[Lenient<Author>]>?
        let image: Lenient<String>?
        let width: Lenient<Int>?
        let height: Lenient<Int>?
        let missingAttribution: Lenient<Bool>?

        struct Author: Decodable, Sendable {
            let name: Lenient<String>?
        }

        var card: PostCard? {
            let named = authorName?.value.flatMap { $0.isEmpty ? nil : $0 }
                ?? authors?.value?.lazy.compactMap { $0.value?.name?.value }.first { !$0.isEmpty }
            return PostCard(
                reading: title?.value, description: description?.value, provider: providerName?.value, author: named,
                url: url?.value, image: image?.value, width: width?.value, height: height?.value,
                missingAttribution: missingAttribution?.value
            )
        }
    }
}
