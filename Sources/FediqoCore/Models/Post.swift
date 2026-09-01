import Foundation

/// One row of the timeline, whatever protocol it arrived by and however many servers
/// handed it over. `sources` is the list of those servers — the seed of "merged, not
/// repeated": two servers carrying the same post produce one `Post` with two sources.
///
/// Everything a network hands over is carried from the first read, because the store
/// writes it once and never backfills: a field left out today is an empty column on every
/// post already stored, forever.
public struct Post: Sendable, Hashable, Identifiable {
    /// The address we were handed — a server's local number for the post.
    public let uri: String
    /// The post's own canonical id, the same everywhere; `nil` when a source gives none.
    public let originURI: String?
    public let socialProtocol: SocialProtocol
    /// Normalised endpoint of the first server to hand it over, `https://<host>` for Mastodon.
    public let sourceURL: String
    public let createdAt: Date
    /// Stable actor URI / did / npub — never the handle, which a profile may rename.
    public let authorId: String
    public let authorName: String
    public let authorHandle: String
    public let authorAvatarURL: URL?
    public let text: String
    /// What came attached, in the order the source gave them.
    public let attachments: [Attachment]
    /// Whether the source said the attachments arrive covered. `nil` where it never said —
    /// which is every post stored before there was anywhere to keep the answer, and is not
    /// the same fact as "it said no".
    public let sensitive: Bool?
    /// The line the author put in front of the words, where there is one. `nil` where the
    /// source never said; `""` where it said and there was none.
    public let spoiler: String?
    /// Who the author wrote it for — `posts.visibility`, which is the word the wire uses.
    ///
    /// `nil` where the source never said, which is every post stored before 009 and every
    /// protocol that has no such idea. Never read as "public": that would be a claim about
    /// somebody's post that nobody made.
    public let audience: Audience?
    /// The three numbers under a post, each `nil` where we were never told. A number we do
    /// not have is never shown as a zero: zero means nobody, and this means no idea.
    public let counts: Counts
    /// What the post was written with, where the server said. Nearly always `nil` for a post
    /// that reached its server by federation — Mastodon only tells you about its own — and a
    /// `nil` here is never drawn as "unknown app": that would be a fact about somebody's
    /// client that nobody told us.
    public let application: Application?
    public let webURL: URL?
    /// The parent's address. Not a reference: a reply routinely arrives before its parent.
    public let inReplyToURI: String?
    /// NFC, lowercased, no leading `#`, no repeats, in the order the source gave them.
    public let tags: [String]
    /// The accounts the post names, in the order the source gave them. Carried from the first
    /// read like everything else here: the store writes a post once and never backfills it.
    public let mentions: [Mention]
    /// The pictures this post is partly written in: a shortcode, and the address of what it
    /// means. Both the status's own and its author's, folded into one list — a shortcode means
    /// one picture on one server, so `:blobcat:` in a display name is `:blobcat:` in the words
    /// under it. Empty where the source said nothing, which is every post stored before 008.
    public let emojis: [CustomEmoji]
    /// The booster's display name — what the row shows.
    public let boostedBy: String?
    /// The booster's `authorId` — what identity is built on.
    public let boostedById: String?
    public private(set) var sources: [String]

    public var isBoost: Bool { boostedById != nil }

    /// What each attachment can be drawn as, in order — the still where there is one, the file
    /// otherwise. The rules read this, and so does anything that only wants to know whether a
    /// post carries anything at all.
    public var mediaURLs: [URL] { attachments.compactMap(\.displayURL) }

    /// What counts as "the same post": identity only, two tiers, first match wins — the
    /// same two the store keys on. Two servers carrying one post agree on its canonical id,
    /// so they collapse; a boost carries the original's id but is a different row, so who
    /// boosted it is part of the key. Merging those two would be exactly the silent
    /// collapse #5 forbids. The booster is named by id rather than display name, because
    /// names change and two people may share one.
    ///
    /// Worked out once, in `init`, and kept — because it is asked for constantly and computing
    /// it allocates a string for every boost, every time. A merged page asks it of every post,
    /// so does the sort under it, so does the reconciler's diff, and a screen asks it once per
    /// row per pass of its body. Nothing it is made of can change after `init`: `uri`,
    /// `originURI` and `boostedById` are all `let`, and `sources` — the one field that moves —
    /// is no part of identity.
    public let mergeKey: String

    public var id: String { mergeKey }

    public init(
        uri: String,
        originURI: String? = nil,
        socialProtocol: SocialProtocol,
        sourceURL: String,
        createdAt: Date,
        authorId: String,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        text: String,
        attachments: [Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        audience: Audience? = nil,
        counts: Counts = Counts(),
        application: Application? = nil,
        webURL: URL? = nil,
        inReplyToURI: String? = nil,
        tags: [String] = [],
        mentions: [Mention] = [],
        emojis: [CustomEmoji] = [],
        boostedBy: String? = nil,
        boostedById: String? = nil,
        sources: [String] = []
    ) {
        self.uri = uri
        self.originURI = originURI
        self.socialProtocol = socialProtocol
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.authorId = authorId
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.attachments = attachments
        self.sensitive = sensitive
        self.spoiler = spoiler
        self.audience = audience
        self.counts = counts
        self.application = application
        self.webURL = webURL
        self.inReplyToURI = inReplyToURI
        self.tags = Self.normalisedTags(tags)
        self.mentions = Mention.folded(mentions)
        self.emojis = CustomEmoji.folded(emojis)
        self.boostedBy = boostedBy
        self.boostedById = boostedById
        self.sources = sources
        let identity = originURI ?? uri
        self.mergeKey = boostedById.map { "boost:\($0)|\(identity)" } ?? identity
    }

    public mutating func addSource(_ host: String) {
        guard !sources.contains(host) else { return }
        sources.append(host)
    }

    /// A tag matches case-insensitively, so it is kept in one form: NFC, lowercased,
    /// without the `#`. `#Swift` and `swift` are one tag, and the first spelling keeps
    /// its place in line.
    static func normalisedTags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        return raw.compactMap { tag in
            var name = tag.precomposedStringWithCanonicalMapping.lowercased()
            if name.hasPrefix("#") { name.removeFirst() }
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}

/// One thing that came attached to a post.
///
/// **`kind` is what the source said it was, and `unknown` is a real answer** rather than a
/// missing one: every attachment stored before migration 005 is one URL and nothing else, and
/// what is true of it is that it can be drawn, not that it is a photograph.
///
/// `url` is the file and `previewURL` is a still to draw in its place; at least one is there.
/// A photo often has only the file, an audio clip often has no still, and what the store kept
/// before 005 was whichever of the two the server offered first — so those arrive here as a
/// preview with no file behind it, which is exactly what they are.
public struct Attachment: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case image, video, audio, unknown
    }

    public let kind: Kind
    public let url: URL?
    public let previewURL: URL?
    /// What the author wrote for somebody who cannot see it. Empty where they wrote none.
    public let alt: String

    public init(kind: Kind, url: URL? = nil, previewURL: URL? = nil, alt: String = "") {
        self.kind = kind
        self.url = url
        self.previewURL = previewURL
        self.alt = alt
    }

    /// What to draw: the still where there is one, the file otherwise.
    public var displayURL: URL? { previewURL ?? url }

    /// Whether this can be played here rather than handed to a browser.
    ///
    /// Two things have to be true and the second is why this is a property rather than a
    /// guess: it has to be something that plays, and **we have to hold the file itself**. An
    /// attachment stored before migration 005 is a still with nothing behind it — 001 kept
    /// `preview_url ?? url` and never asked for the film — so it cannot be played, however
    /// obviously it is a film to look at.
    public var isPlayable: Bool {
        guard url != nil else { return false }
        return kind == .video || kind == .audio
    }

    /// Whether there is anything to draw at all — a row with neither is not written.
    public var isEmpty: Bool { displayURL == nil }

    /// An attachment as the store held one before migration 005: an address that can be drawn,
    /// and no idea what is behind it.
    public static func unknown(displaying url: URL) -> Attachment {
        Attachment(kind: .unknown, previewURL: url)
    }
}

/// The client a post was written with: a name, and the website its author registered for it.
///
/// It says nothing about the person and nothing about the words — which is exactly why it sits
/// at the foot of a row, under everything that does.
public struct Application: Sendable, Hashable, Codable {
    public let name: String
    public let website: URL?

    public init(name: String, website: URL? = nil) {
        self.name = name
        self.website = website
    }
}

/// The three numbers under a post, as the source last said them. Each is `nil` where it never
/// did — which is what stops a screen inventing a zero.
public struct Counts: Sendable, Hashable, Codable {
    public let replies: Int?
    public let reblogs: Int?
    public let favourites: Int?

    public init(replies: Int? = nil, reblogs: Int? = nil, favourites: Int? = nil) {
        self.replies = replies
        self.reblogs = reblogs
        self.favourites = favourites
    }

    /// Whether the source said anything at all about how this post has been received.
    public var areKnown: Bool { replies != nil || reblogs != nil || favourites != nil }
}

/// Who a post was written for.
///
/// The four ActivityPub offers, and the raw values are the words the wire uses so that nothing
/// is translated on the way in or out — the same words `visibilities` is keyed by. The Swift
/// names are who can read it, because that is the fact: two of the four are Swift keywords and
/// backticks would have been a worse answer than saying the thing plainly.
///
/// **Not `Visibility`**, which is SwiftUI's own type and one every screen in this app may want.
/// The schema and the wire keep their word for it; what a reader is being told is who the post
/// was for, and that is what this is called.
///
/// A word this build does not know decodes as `nil`, which is the same answer as never having
/// been told. A server inventing a fifth kind of audience is a server this app cannot describe
/// to a reader, and guessing at it would be worse than saying nothing.
public enum Audience: String, Sendable, Hashable, Codable, CaseIterable {
    /// On the public timelines, and anybody may find it.
    case everyone = "public"
    /// Anybody may read it, and it is on no public timeline.
    case unlisted
    /// The author's followers, and nobody else.
    case followers = "private"
    /// The accounts it names, and nobody else.
    case mentioned = "direct"
}

/// An account a post names.
///
/// The URI is the name — the same stable actor URI `Post.authorId` is — because a handle is
/// what a profile renames. The handle rides along because it is what a reader would type and
/// what a screen would show, and it is spelled the way the post's own server spelled it.
///
/// It is not a reference to an account we hold: a post routinely names people this device has
/// never seen and may never see, which is why `post_mentions.mention_uri` is no foreign key.
public struct Mention: Sendable, Hashable, Codable {
    public let uri: String
    /// `@user@host`, as the post's own server spelled it.
    public let handle: String

    public init(uri: String, handle: String) {
        self.uri = uri
        self.handle = handle
    }

    /// Each account once, in the order first named. A post may name the same person twice.
    static func folded(_ raw: [Mention]) -> [Mention] {
        var seen: Set<String> = []
        return raw.filter { !$0.uri.isEmpty && seen.insert($0.uri).inserted }
    }
}

public extension Array where Element == Post {
    /// One post from several places is one row. Collapse on `mergeKey`, keep every source,
    /// and leave the order to the timestamp — nothing here ranks anything.
    ///
    /// `order` is not redundant with the sort: Swift's sort is not stable, and two posts
    /// sharing a timestamp are common. Without it, equal-time rows would shuffle between
    /// refreshes for no reason a reader could see — and the tiebreak `TimelineOrder` gives
    /// them is what makes this the same order the store reads its pages back in, so a page
    /// boundary falling inside one millisecond lands in the same place on both sides.
    func merged() -> [Post] {
        merged(orderedBy: { TimelineOrder.isOlder($1, than: $0) })
    }

    /// The fold itself: collapse on `mergeKey`, keep every source, then sort by `areInOrder`
    /// from first-seen order.
    internal func merged(orderedBy areInOrder: (Post, Post) -> Bool) -> [Post] {
        var order: [String] = []
        var merged: [String: Post] = [:]
        for post in self {
            let key = post.mergeKey
            if var existing = merged[key] {
                for host in post.sources { existing.addSource(host) }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = post
            }
        }
        return order.compactMap { merged[$0] }.sorted(by: areInOrder)
    }
}

/// One picture a post is partly written in, and the shortcode it is spelled by.
///
/// The shortcode arrives without its colons and is kept that way: `:blobcat:` in the words is
/// `blobcat` here, because the colons are punctuation the server put round a name rather than
/// part of it.
public struct CustomEmoji: Sendable, Hashable, Codable {
    public let shortcode: String
    public let url: URL
    /// The still of an animated one, where the server offered it. `nil` is not "it does not
    /// move" — it is a server that did not say.
    public let staticURL: URL?

    public init(shortcode: String, url: URL, staticURL: URL? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.staticURL = staticURL
    }

    /// One shortcode, one picture, first spelling wins. Two lists arrive for every post — the
    /// status's and its author's — and a server saying `blobcat` twice is saying it once.
    static func folded(_ raw: [CustomEmoji]) -> [CustomEmoji] {
        var seen: Set<String> = []
        return raw.filter { !$0.shortcode.isEmpty && seen.insert($0.shortcode).inserted }
    }
}

/// A line of text, cut into what is written in letters and what is written in pictures.
///
/// The cut is made here rather than on the screen so it can be tested without one, and so the
/// two screens that draw a post — the row and the opened page — cannot come to disagree about
/// what a shortcode is.
public enum EmojiRun: Sendable, Hashable {
    case text(String)
    case emoji(CustomEmoji)
}

extension CustomEmoji {
    /// Cuts `text` into runs, replacing only the shortcodes this post was actually given a
    /// picture for.
    ///
    /// A shortcode is `:name:`, where the name is letters, digits and underscores. A colon
    /// standing on its own, a smiley typed by hand, and a `:name:` nobody sent a picture for
    /// are all left exactly as they were typed — a screen drawing a blank where a reader wrote
    /// a colon would be inventing something.
    ///
    /// Scanned by hand rather than by a regular expression, because a `Regex` cannot be a
    /// shared constant in a concurrent program and building one per post is a cost paid on
    /// every row of every page. An empty list means one run of text, which is the fast path
    /// and the common one: most posts have no custom emoji at all.
    public static func runs(in text: String, from emojis: [CustomEmoji]) -> [EmojiRun] {
        guard !emojis.isEmpty, text.contains(":") else { return text.isEmpty ? [] : [.text(text)] }
        let byShortcode = Dictionary(emojis.map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
        var runs: [EmojiRun] = []
        var plain = ""
        var index = text.startIndex
        var wordStart = text.startIndex          // the colon that may open a shortcode

        while index < text.endIndex {
            guard text[index] == ":" else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            wordStart = index
            var cursor = text.index(after: index)
            while cursor < text.endIndex, text[cursor].isShortcodeCharacter { cursor = text.index(after: cursor) }
            guard cursor < text.endIndex, cursor > text.index(after: wordStart), text[cursor] == ":",
                  let emoji = byShortcode[String(text[text.index(after: wordStart)..<cursor])] else {
                // Not a shortcode, or not one of ours. The colon is text, and the scan starts
                // again at the character after it — the next colon may open a real one.
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            if !plain.isEmpty { runs.append(.text(plain)); plain = "" }
            runs.append(.emoji(emoji))
            index = text.index(after: cursor)
        }
        if !plain.isEmpty { runs.append(.text(plain)) }
        return runs
    }
}

private extension Character {
    var isShortcodeCharacter: Bool { isASCII && (isLetter || isNumber || self == "_") }
}
